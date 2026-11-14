# Auditoría KRAKER MASTER v2.0 — Puertos, desconexiones y BadVPN

**Repo:** `underkraker/krakerscriptmx` (commit `7a52460`)
**Fecha:** 2026-11-14
**Método:** lectura completa de los 19 scripts (1.852 líneas) + **pruebas reales** de compilación y ejecución del binario BadVPN en un entorno Debian 13.

---

## Resumen ejecutivo

Tus tres síntomas no son tres fallos distintos: son **cuatro bugs de fondo** que se combinan.

| Síntoma que reportas | Causa raíz real |
|---|---|
| "Los puertos dicen que sí pero no se abren" | El panel **nunca abre el puerto 22** y **no existe un módulo de puertos**: cada script abre los suyos y el **443 nunca se abre**. Además `get_active_ports()` busca BadVPN en **UDP** cuando BadVPN escucha en **TCP**. |
| "Se cierran / se desconectan" | Cron duplicado que **reinicia Dropbear y Stunnel cada 30 minutos** + `pkill -9 -f` y `fuser -k 80/443` que matan protocolos que **no** elegiste. |
| "BadVPN no funciona" | El servicio se declara con `Nice=-20` + `CPUSchedulingPolicy=fifo`, que en VPS OpenVZ/LXC **el kernel deniega** → unidad en `failed` → puerto cerrado. Y el Watchdog lanza una **segunda instancia en `screen`** que pelea por el mismo puerto. |

---

## Verificaciones que hice de verdad (no es teoría)

### 1. BadVPN compila sin problema
Compilé `badvpn-1.999.130` con las mismas flags del script en Debian 13 / gcc 14 / OpenSSL 3.5:

```
cmake .. -DBUILD_NOTHING_BY_DEFAULT=1 -DBUILD_UDPGW=1 -DCMAKE_C_FLAGS="-Wno-error" ...
make -> [100%] Built target badvpn-udpgw      ✅
```
**Descartado:** el fallo de compilación que el script intenta parchear no ocurre. El problema es posterior (arranque/servicio).

### 2. `--listen-addr` repetido SÍ está soportado
Leí el parser (`udpgw.c:482`, `MAX_LISTEN_ADDRS 16`): se pueden pasar varias direcciones. El `ExecStart` con 7100+7200+7300 es sintácticamente válido.
**Descartado:** que los 3 puertos en un solo servicio sea el error.

### 3. BadVPN escucha por **TCP**, no por UDP
```
LISTEN 0 128 0.0.0.0:7100  users:(("badvpn-udpgw",pid=2650,fd=6))
LISTEN 0 128 0.0.0.0:7200  users:(("badvpn-udpgw",pid=2650,fd=9))
LISTEN 0 128 0.0.0.0:7300  users:(("badvpn-udpgw",pid=2650,fd=10))
=== UDP === (nada)
TCP 7300 ACEPTA CONEXIONES
```
`badvpn-udpgw` es un gateway **UDP-sobre-TCP**. Todo el panel lo monitoriza como UDP:

- `scripts/utils.sh:162` → `for p in 443 53 5300 36712 7100 7200 7300; do ss -nulp ...`
- Resultado: **el panel siempre muestra "DETENIDO"** aunque esté funcionando, y el comprobante del usuario (`KRAKER_User.sh:44`) nunca imprime la línea de BADVPN.

### 4. Los cron se duplican en cada arranque del panel
`scripts/utils.sh:134` compara con `grep -q "clean_vps_ram"` pero la línea que escribe es `--ram-clean`:

```
Entrada real : 0 */2 * * * /usr/bin/kraker --ram-clean
grep "clean_vps_ram"  -> NO matchea  => añade DUPLICADO
grep "purge_ghost_sessions" -> NO matchea => añade DUPLICADO
```
Y `menu.sh:53` llama a `setup_auto_clean` **en cada arranque**. Abres el panel 10 veces = 10 líneas de `--cpu-clean` = 10 purgas cada 30 min.

---

## Bug #1 (CRÍTICO) — `purge_ghost_sessions` desconecta a todos cada 30 minutos

`scripts/utils.sh:123-130`

```bash
purge_ghost_sessions() {
    systemctl restart dropbear  > /dev/null 2>&1   # ← TIRA TODAS LAS SESIONES
    systemctl restart stunnel4 > /dev/null 2>&1   # ← TIRA TODO EL SSL
    clean_vps_ram
}
```

Registrado en cron como `*/30 * * * * /usr/bin/kraker --cpu-clean` (`utils.sh:139`).

**Esto es la causa número uno de "se desconectan".** Cada 30 minutos se reinicia Dropbear (todos los usuarios SSH del 80/143/442 pierden la conexión) y Stunnel (todo el tráfico SSL del 443). Y como el cron se duplica (ver punto 4), al tiempo tienes **varios reinicios por hora**.

**Arreglo:** ya aplicado en `scripts/utils.sh` — la función solo libera RAM; nunca reinicia servicios.

---

## Bug #2 (CRÍTICO) — Abrir el panel desconecta a los usuarios

`menu.sh:54` llama a `setup_kraker_banner` en **cada** arranque, y esa función hace:

```bash
systemctl restart ssh       # utils.sh:188
systemctl restart dropbear  # utils.sh:198
```

Es decir: **cada vez que entras a `kraker`, expulsas a todos los conectados**. Lo mismo pasa en `setup_motd` (`utils.sh:111`) que se ejecuta desde el instalador de Dropbear, el de UDP y el de SlowDNS.

**Arreglo:** en `scripts/utils.sh` los reinicios son condicionales (solo si el archivo de configuración cambió) y se usa `systemctl reload ssh` en vez de `restart`.

---

## Bug #3 (CRÍTICO) — "DETENER SERVICIO" mata los demás protocolos

`scripts/KRAKER_Services.sh`

```bash
# opción 2 (detener)
pkill -9 -f "$service"
fuser -k 443/tcp 80/tcp 442/tcp 8080/tcp    # ← ¡mata TODO lo que esté en esos puertos!
```
```bash
# opción 1 (iniciar)
systemctl stop "$service"
pkill -9 -f "$service"                       # ← patrón amplio, mata de más
```

Si detienes "SlowDNS", el `fuser -k 443/tcp` **también tumba Xray y Stunnel**. Eso es exactamente "cierro un puerto y se me cierran otros".

**Arreglo:** ya aplicado — solo `systemctl start/stop/restart` del servicio elegido y un menú de diagnóstico.

---

## Bug #4 (CRÍTICO) — BadVPN: el servicio puede quedar en `failed`

`scripts/KRAKER_UDP.sh:99-102`

```ini
Nice=-20
CPUSchedulingPolicy=fifo
CPUSchedulingPriority=99
```

`SCHED_FIFO` + nice -20 requieren `CAP_SYS_NICE` **y** que el kernel/host lo permita. En **OpenVZ / LXC / algunos KVM con kernel restringido** systemd no puede aplicarlo y **deja la unidad en `failed`** → los puertos 7100/7200/7300 nunca se abren. Es el escenario clásico de "dice que sí pero no abre".

Además:

| Línea | Bug | Consecuencia |
|---|---|---|
| `KRAKER_UDP.sh:77` | `[[ ! -s /usr/bin/badvpn-udpgw ]]` solo valida que **pese >0 bytes** | Una página HTML de error 404 de GitHub es ">0 bytes" → se instala como binario → `Exec format error` |
| `KRAKER_Watchdog.sh:55` | Si el servicio falla, lanza `screen -dmS UDP_Gaming badvpn-udpgw ... 7300` | Segunda instancia peleando por el puerto → `Address already in use` → **el puerto aparece y desaparece** |
| `KRAKER_UDP.sh:120-121` | `ufw allow 7100:7300/udp` y `/tcp` | Correcto, pero **nunca** se comprueba si UFW está activo ni se abre el 22 |
| `KRAKER_UDP.sh:16` | `net.ipv4.tcp_low_latency = 1` | Sysctl **eliminado del kernel en 4.12**; solo genera errores silenciosos |
| `KRAKER_UDP.sh:22` | `default_qdisc = fq_codel` en `99-kraker-gaming.conf` | **Pelea** con `default_qdisc=fq` de `/etc/sysctl.conf` (que gana, se carga al final) → el "tuneo gaming" nunca se aplica |

**Arreglo:** `scripts/KRAKER_UDP.sh` valida el ELF + `--version`, quita FIFO/nice, añade `network-online.target`, abre TCP+UDP y **verifica de verdad** con `ss -ntl`.

---

## Bug #5 (ALTO) — No existe módulo de puertos y el 22 nunca se abre

```bash
$ grep -rn "allow 22\|allow OpenSSH" scripts/
NO HAY regla para el 22 en NINGÚN script
```

- `KRAKER_Dropbear.sh` abre 80, 143, 442. **Nunca el 22.**
- `KRAKER_SSL.sh` no abre el 443 en el firewall (solo lo bindea).
- Nadie abre 2053/2083/2087/2096/4433 aunque el comprobante del usuario los anuncie.
- Nadie hace `ufw enable`, y nadie verifica si UFW ya estaba activo.

**Consecuencia:** si en algún momento activas UFW, pierdes el acceso SSH al VPS. Y si UFW está inactivo, las reglas que añade el panel **no filtran nada** (no son la causa de que "no abran": en ese caso el bloqueo está en el **firewall del proveedor**: AWS Security Group, Hetzner, OVH, Vultr, Contabo).

**Arreglo:** nuevo `scripts/KRAKER_Firewall.sh` que abre 22 primero, luego todo lo demás en TCP y UDP, y explica la diferencia firewall local vs. firewall del hosting.

---

## Bug #6 (ALTO) — AntiMultiLogin nunca funcionó (y cuando lo hace, corta a todos)

`scripts/KRAKER_AntiMulti.sh:33`

```bash
sesiones=$(ps -u "$user" -o comm= | grep -E "(dropbear|sshd)" | wc -l)
```

El proceso `dropbear`/`sshd` corre como **root**; del usuario aparece la **shell** (`bash`, `sh`). Por tanto `sesiones` = **0 siempre** → el limitador **nunca se dispara**.

Y cuando algo lo dispara:

```bash
pkill -u "$user"    # mata TODAS las sesiones del usuario, incluidas las legítimas
```

**Arreglo:** `scripts/KRAKER_AntiMulti.sh` cuenta TTYs reales (`ps -u user -o tty=`) y cierra solo las sesiones que exceden el límite.

---

## Bug #7 (ALTO) — Protocolos anunciados que no existen

El menú y el README prometen:

> Xray REALITY (VLESS) · Hysteria v2 · Trojan/VMess WS+TLS · Shadowsocks WS+TLS

**Realidad en el código:**

```bash
$ grep -rn "reality\|vless\|vmess\|hysteria" scripts/*.sh | grep -i install
(nada)
```

- `install_xray_modular()` existe en `utils.sh:203` pero **ningún script la llama**.
- No hay **ningún** `inbound` de Xray en todo el repo: el archivo que se crea (`00_outbounds.json`) solo define la salida. **Aunque instales Xray, nada escucha en el 443.**
- `hysteria-server` aparece en `KRAKER_Services.sh:11` y en el comprobante, pero **no hay instalador**.
- `menu.sh` opciones **03 y 04 llaman al mismo script** (`KRAKER_SSL.sh`); la opción "Gateway Nativo" (Python) está comentada, así que hacen exactamente lo mismo.

Esto explica por qué "el 443 dice abierto y no hay nada": **no hay nada que escuchar ahí** salvo que instales Stunnel (opción 03).

---

## Bug #8 (MEDIO) — Stunnel peleando consigo mismo

- `KRAKER_SSL.sh:74` lanza `stunnel4 /etc/stunnel/kraker.conf` **a mano** (fuera de systemd), con su propio `pid = /var/run/stunnel-kraker.pid`.
- `KRAKER_Watchdog.sh:42` comprueba `pgrep -x stunnel4` y si no lo ve, **vuelve a lanzar otra instancia** cada minuto.
- `stop_protocol` hace `killall stunnel4` (mata todas).
- Y el paquete Debian trae la unidad `stunnel4.service` que, si se reinicia desde el panel, lee **otro** archivo de config.

Resultado: instancias duplicadas, `pidfile` huérfano y el 443 abriéndose/cerrándose.

---

## Bug #9 (MEDIO) — Los usuarios creados no pueden conectarse

`scripts/KRAKER_User.sh:114`

```bash
useradd -M -s /bin/false -e $EXP_DATE $USERNAME
```

Con shell `/bin/false` el usuario **no puede abrir sesión SSH** — y los túneles SSH (HTTP Custom / HTTP Injector / SlowDNS) necesitan una shell válida. El script además añade `/bin/false` a `/etc/shells` para saltarse la validación.

**Arreglo sugerido:** `-s /bin/bash` (o `/usr/bin/false` con `ForceCommand` sólo si el túnel es puramente de reenvío).

---

## Bug #10 (MEDIO) — fail2ban mal configurado

`scripts/KRAKER_Security.sh:13-32`

| Problema | Detalle |
|---|---|
| `logpath = /var/log/auth.log` para dropbear | En Debian 12/13 sin rsyslog **ese archivo no existe** → el jail falla |
| `%('sshd_log')s` + `%(sshd_backend)s` | En Debian con backend systemd puede no resolver |
| `banaction = iptables-multiport` | En sistemas 100% nftables conviene `nftables-multiport` |
| `port = 22,80,143,442`, `maxretry = 3` | Clientes que reconectan agresivamente (apps de túnel) **se autobanean** → "se me desconecta y no vuelve" |

Comprueba en tu VPS: `fail2ban-client status dropbear` y `iptables -S | grep f2b`. Si hay IPs baneadas de tus propios usuarios, ese es el problema.

---

## Bug #11 (MEDIO/BAJO) — Anti-Torrent roto y peligroso

`scripts/KRAKER_TorrentBlock.sh`

- Reglas en la cadena **`FORWARD`**. El tráfico de tus túneles (Xray/SSH/Dropbear) es **INPUT/OUTPUT local**, no FORWARD → **no bloquea nada** del tráfico real.
- No se persisten (`netfilter-persistent` no está instalado) → se pierden al reiniciar.
- `-m string --string "torrent"` y `"announce"` bloquean cualquier página que contenga esas palabras → navegación rota.

---

## Bug #12 (BAJO) — Detalles de instalador

| Archivo | Bug |
|---|---|
| `install.sh:9,18,20` | Usa `${CYAN}` y `${NC}` pero **nunca** hace `source utils.sh` → los colores no salen (variables vacías) |
| `install.sh:60` | Termina con `kraker`: abre el menú interactivo y **bloquea** cualquier instalación desatendida |
| `install.sh:74-88` | `sed -i` **borra** líneas de `/etc/sysctl.conf` del usuario antes de escribir las suyas (destructivo, sin backup) |
| `utils.sh:88` | `install_deps` busca un *comando* con el nombre del *paquete*: `net-tools`, `psmisc`, `cron` no existen como comando → reinstala en cada llamada |
| `menu.sh:39` | `apt install speedtest-cli` no está en Debian → el test de velocidad falla |
| `utils.sh:268` | `crontab -l \| grep -v kraker` revienta si el crontab está vacío |
| `utils.sh:271` | `rm -rf "$ROOT_DIR"` en el desinstalador borra la carpeta del proyecto entera (irreversible) |
| `KRAKER_DNS.sh:33` | Sobrescribe `/etc/resolv.conf` sin backup |
| `KRAKER_DNS.sh:38-39` | `iptables -t nat REDIRECT` **sin persistencia** y sin limpiar → reglas duplicadas en cada ejecución |
| `KRAKER_ACME.sh:32` | `fuser -k 80/tcp` suelta a los usuarios de Dropbear (que vive en el 80) para emitir el certificado |

---

## Bug #13 (CRÍTICO para tu caso) — SSL + Python Gateway

Si solo usas **SSL (443)** y el **Gateway de Python**, estos son tus fallos reales:

### a) El Gateway de Python NUNCA se arranca
`scripts/KRAKER_SSL.sh:55-56`

```bash
# (Desactivado) 4. Iniciar Python Gateway en segundo plano
# screen -dmS "kraker_ssl" python3 "$SOURCE_DIR/KRAKER_SSL_Gateway.py" "443" ...
```

Está **comentado**. Y en `menu.sh`, las opciones **03 y 04 lanzan el mismo script**, que
solo levanta Stunnel. Es decir: *si crees que estás usando el gateway de Python,
en realidad estás usando Stunnel* — o no hay nada, según el día.

### b) No existe ninguna unidad systemd → el 443 no sobrevive a un reinicio
```bash
$ grep -rn "systemd/system.*ssl" scripts/
(vacío)
```
`stunnel4 /etc/stunnel/kraker.conf` se lanza **a mano**. Al reiniciar el VPS, el 443
no vuelve. Nada lo restaura salvo el cron del Watchdog, que compite con la unidad
`stunnel4.service` del paquete Debian (que lee **otro** archivo de configuración).

### c) Cada vez que abres la opción 03 se REGENERA el certificado
`KRAKER_SSL.sh:53` ejecuta `openssl req -x509` **siempre**, sobrescribiendo
`/etc/ws_ssl/server.crt`. Si ya habías emitido un certificado real con
**ACME/Let's Encrypt** (`KRAKER_Acme.sh:47`), lo **machaca** con uno autofirmado.

### d) Si Dropbear está caído, el 443 "abre y cierra"
El gateway/stunnel escucha en 443 y reenvía a `127.0.0.1:80`. Si Dropbear no está
escuchando, el cliente **completa el handshake TLS y la conexión muere al instante**:
exactamente tu síntoma de "se conecta y se desconecta". El script original **no
verificaba nunca** que el destino estuviera vivo.

### e) Bugs del gateway Python (`KRAKER_SSL_Gateway.py`)
| Línea | Bug | Consecuencia |
|---|---|---|
| `:85` | `context.wrap_socket()` dentro del bucle `accept()` | Un cliente con handshake lento **bloquea a todos** los demás |
| `:87-89` | `except: time.sleep(1)` global | Un solo cliente malo **congela el servidor 1 segundo** |
| `:86` | Hilo por conexión sin límite | Agota el VPS con cientos de conexiones |
| `:66` | Comentario "Bug corregido: Inicializar el socket 'server'" pero sin `listen` en el `try` correcto | Sin log de diagnóstico: si falla, no sabes por qué |
| — | `main()` recibe `port` como str y hace `int(port)` al bind, pero lo imprime como str | Cosmético |

**Probado en el sandbox contra un Dropbear falso, ya corregido — los 5 escenarios:**

| Escenario (todos por el mismo 443) | Resultado |
|---|---|
| SSL puro, el cliente habla primero (`SSH-2.0-...`) | `SSH-2.0-FakeDropbear` + `ECHO:SSH-2.0-MiCliente` ✅ |
| SSL puro **mudo** (el cliente espera al servidor) | banner del servidor entregado ✅ |
| WS con cabeceras **y** datos SSH en el mismo paquete | `101` + banner + `ECHO:SSH-2.0-EnElMismoPaquete` ✅ |
| WS con cabeceras **partidas** en varios paquetes | `101` + banner + `ECHO:SSH-2.0-Partido` ✅ |
| Cliente sin payload que manda SSH directo | banner + `ECHO` ✅ |

Esto es lo que hace viable tener **los dos tipos de cliente en el mismo puerto 443**:
el gateway mira los primeros bytes y decide. Stunnel **no** puede hacer esto (no
responde `101`), por eso queda como opción solo para flotas 100% SSL puro.

### f) `KRAKER_Services.sh` al tocar "SSL" mata Dropbear
La opción "detener" ejecutaba `fuser -k 443/tcp 80/tcp 442/tcp 8080/tcp`.
Como Dropbear vive en el **80**, al reiniciar el SSL **se mataba el destino del túnel**.
El puerto 443 seguía abierto, pero todo lo que entraba moría. *(Bug #3)*

**Arreglo:** `scripts/KRAKER_SSL.sh` + `scripts/KRAKER_SSL_Gateway.py`
— dos unidades systemd reales (`kraker-ssl.service`, `kraker-gateway.service`) que se
excluyen entre sí en el 443, certificado que **no** se sobrescribe, verificación de que
el destino está vivo, y gateway no bloqueante con límite de conexiones.

---

## Bug #14 — "Optimización para gaming": qué es real y qué es humo

### Alcance real del stack (esto es lo importante)

| Juego | Transporte | ¿Funciona con este panel? |
|---|---|---|
| **Free Fire** (móvil) | UDP | **Sí**, vía BadVPN `udpgw` (UDP-sobre-TCP) en 7100/7200/7300 |
| Juegos móviles varios | UDP | Parcial, si el cliente soporta UDP-over-TCP |
| **Fortnite / LoL / Valorant** (PC) | UDP multi-puerto | **No.** Un túnel SSH/SSL es TCP; no transporta el UDP del juego |

Ningún `sysctl` cambia eso: es una limitación del **protocolo**, no de la configuración.
Para PC hace falta **WireGuard** (UDP, en kernel) o **Hysteria2** (UDP/QUIC) — que el
README anuncia pero el repo **no instala**.

### Lo que el panel llamaba "optimización" y no servía

| Código | Problema |
|---|---|
| `KRAKER_UDP.sh:16` | `net.ipv4.tcp_low_latency = 1` — clave **eliminada del kernel hace años**; solo generaba un error silencioso |
| `KRAKER_UDP.sh:22` | `default_qdisc = fq_codel` en `99-kraker-gaming.conf`, mientras `install.sh` pone `fq` en `/etc/sysctl.conf`. **sysctl.conf se carga al final y gana** → el tuneo gaming nunca se aplicaba |
| `KRAKER_Services.sh:11` | `CPUSchedulingPolicy=fifo` + `Nice=-20` en el servicio UDP: en OpenVZ/LXC el kernel lo deniega y el servicio **queda caído** |
| `utils.sh:270` (`--cpu-clean`) | "Liberar CPU" reiniciando Dropbear cada 30 min: **no libera CPU, corta a los usuarios** |
| `menu.sh:39` | "Test de velocidad" con `speedtest-cli`, que **no está en los repos de Debian** → siempre falla |

### `scripts/KRAKER_Gaming.sh` (nuevo) — lo que sí mueve la aguja

Aplica **solo las claves que existen en tu kernel** (comprueba `/proc/sys` antes de escribir):

| Ajuste | Efecto medible |
|---|---|
| `default_qdisc = fq_codel` | Mata el **bufferbloat** → el ping deja de dar picos. Es lo que se nota jugando |
| `tcp_congestion_control = bbr` | Menos retransmisiones en el túnel TCP (el SSL gateway es TCP) |
| `tcp_notsent_lowat = 131072` | Evita que se acumulen datos en el socket → paquetes pequeños salen ya |
| `tcp_slow_start_after_idle = 0` | Elimina el "frenazo" tras pausas (típico en lobbies) |
| `rmem_max/wmem_max = 32 MB` + `udp_rmem_min` | **Crítico para udpgw**: sin buffer UDP grande, Free Fire pierde paquetes |
| `netdev_max_backlog = 16384` | Absorbe ráfagas sin descartes |
| `somaxconn` / `max_syn_backlog` = 8192 | Cientos de clientes conectando a la vez sin colas |
| `vm.swappiness = 10` | Un solo swap = pico de 300 ms |
| CPU governor `performance` | Si el VPS expone cpufreq (muchos **no**, lo controla el host) |
| RPS/RFS por cores | Reparte las interrupciones de red (si virtio tiene multiqueue) |
| `nofile = 65535` | Muchas conexiones simultáneas |

Incluye **medición antes/después** (ping + jitter a 8.8.8.8 y 1.1.1.1) y `--revert`.

### El ajuste que más estabiliza el ping: `--client-socket-sndbuf`

Leyendo el código de badvpn (`udpgw.c:647`):

```c
// limit socket send buffer, else our scheduling is pointless
if (options.client_socket_sndbuf > 0) { BConnection_SetSendBuffer(...); }
```
```c
#define CLIENT_DEFAULT_SOCKET_SEND_BUFFER 1048576   // 1 MB POR CONEXIÓN
```

El valor por defecto son **1 MB de buffer de envío por cada conexión de cliente**.
Eso significa que un cliente puede tener ~1 segundo de datos encolados esperando turno:
el servidor los suelta en ráfaga y el ping da saltos. **El propio autor del código
avisa de que sin limitarlo, la planificación no sirve de nada.**

`scripts/KRAKER_UDP.sh` ahora arranca con `--client-socket-sndbuf 131072` (128 KB).

### `scripts/KRAKER_PingMonitor.sh` (nuevo) — saber POR QUÉ el ping no es estable

No basta con medir; hay que correlacionar. Cada muestra reporta:

| Métrica | Qué delata |
|---|---|
| ICMP media / **jitter** / máx / pérdida | lo que siente el jugador |
| Sonda **TCP:443** si hay ICMP filtrado | muchos VPS bloquean ping: sin esto el monitor sería ciego |
| `RetransSegs` (delta) | **TCP meltdown**: UDP→TCP→TCP perdiendo paquetes |
| `ListenDrops` / `ListenOverflows` | ráfagas de reconexión o `somaxconn` bajo |
| `Udp: RcvbufErrors` / `InErrors` | buffer UDP desbordado (udpgw perdiendo datagramas) |
| drops de `softnet_stat` + qdisc | el VPS no procesa tan rápido como recibe |

Veredicto `ESTABLE / ACEPTABLE / INESTABLE` + **la causa concreta y qué subir**.
Modos: `--watch` (bucle), `--install` (servicio systemd), `--summary` (histórico).
Además guarda CSV en `/var/log/kraker-ping.csv` para ver la evolución.

### `KRAKER_SSL_Gateway.py` — cuello de botella de CPU resuelto

El gateway es Python: con muchos clientes, el **GIL** lo convierte en el límite antes
que la red. Se añadió **multiproceso con `SO_REUSEPORT`**:

```
Modo multiproceso: 4 workers con SO_REUSEPORT
LISTEN 0.0.0.0:4445  users:(("python3",pid=3255))   <- 4 procesos en el MISMO puerto
LISTEN 0.0.0.0:4445  users:(("python3",pid=3254))
LISTEN 0.0.0.0:4445  users:(("python3",pid=3253))
LISTEN 0.0.0.0:4445  users:(("python3",pid=3252))

200 conexiones concurrentes -> exitosas=200  fallidas=0  tiempo=0.34s
```

El kernel reparte las conexiones entre procesos (adiós GIL), y el padre **revive
cualquier worker que muera**. Se controla con `KRAKER_WORKERS` (por defecto
`min(4, núcleos)`).

---

## Lo que NO es el problema (descartado con pruebas)

- ❌ Que BadVPN no compile en Ubuntu/Debian modernos → **compila**.
- ❌ Que `--listen-addr` repetido sea inválido → **es válido**.
- ❌ Que falte `make` antes de `make install` → CMake lo resuelve.
- ❌ Que el repo sea malware → **no lo es**: no hay exfiltración, mineros, reverse shells ni claves ajenas. Es un panel de túneles legítimo en su propósito (aunque muy frágil).

---

## Cómo está organizado ahora

Los archivos corregidos **ya son** los de `scripts/`. Ya no existe la carpeta `parches/`:
lo que se instala es directamente la versión arreglada.

```bash
# Instalación nueva
bash <(curl -fsSL https://raw.githubusercontent.com/lorunder/Script-kraker-/main/install.sh)

# Actualizar un VPS que ya tiene el panel
sudo bash /root/kraker_master/update.sh
```

`update.sh` hace backup, `git pull`, limpia los cron duplicados que dejaba la versión
anterior y reinicia los servicios que estuvieran activos. No borra configuración.

Los módulos nuevos están accesibles desde el menú: `[17]` Abrir Puertos, `[18]` Tuner
Gaming, `[19]` Monitor de Ping.

---

## Orden de trabajo recomendado

1. **Parar el sangrado:** los cron duplicados y el `restart` de `purge_ghost_sessions`
   ya están corregidos en `scripts/utils.sh` → se acaban las desconexiones cada 30 min.
2. **Dropbear:** menú `[10]` — el destino del túnel debe estar vivo antes que nada.
3. **Puertos:** menú `[17]` y revisar también el firewall del **proveedor**.
4. **Túnel:** menú `[03]` en modo **Python** (clientes mixtos WS + SSL).
5. **BadVPN:** menú `[08]` y comprobar `ss -ntl` en 7100/7200/7300.
6. **Latencia:** menú `[18]` para el tuneo y `[19]` para vigilar la estabilidad.
7. **Usuarios:** cambiar `/bin/false` por `/bin/bash` en las cuentas nuevas.
8. **fail2ban:** revisar baneos de tus propios clientes.
9. **Pendiente:** instaladores de Xray REALITY/VMess/Trojan y Hysteria v2. El README
   antiguo los anunciaba, pero **nunca existieron** en el repo.
