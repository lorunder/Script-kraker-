# Parches KRAKER MASTER

Correcciones derivadas de la auditoría (`../AUDITORIA_KRAKER.md`). Cada archivo aquí
es una **versión corregida** del correspondiente en `../scripts/`.

## Instalación

```bash
sudo bash parches/aplicar_parches.sh /root/kraker_master
```

Crea backup automático, copia los archivos y limpia los cron duplicados.

## Contenido

| Archivo | Tipo | Corrige |
|---|---|---|
| `utils.sh` | modificado | Cron duplicado en cada arranque; `purge_ghost_sessions` reiniciaba Dropbear/Stunnel cada 30 min (desconexiones masivas); restarts innecesarios de sshd |
| `KRAKER_UDP.sh` | modificado | BadVPN en `failed` por `CPUSchedulingPolicy=fifo`; validación real del binario (ELF + `--version`); `--client-socket-sndbuf 128K` para ping estable; verificación con `ss -ntl` |
| `KRAKER_Services.sh` | modificado | `fuser -k 80/443` y `pkill -9 -f` mataban protocolos ajenos al detener un servicio |
| `KRAKER_Dropbear.sh` | modificado | Abre el puerto 22 antes de tocar el firewall (evita quedarse fuera del VPS); verificación real de puertos |
| `KRAKER_AntiMulti.sh` | modificado | El contador daba siempre 0 (contaba el proceso de root); `pkill -u` cortaba sesiones legítimas |
| `KRAKER_SSL.sh` | modificado | El gateway Python estaba comentado y nunca arrancaba; sin unidades systemd; regeneraba y machacaba el certificado ACME; no verificaba que el destino estuviera vivo |
| `KRAKER_SSL_Gateway.py` | modificado | `wrap_socket()` bloqueaba el bucle `accept()`; `sleep(1)` global; tiraba los bytes SSH pegados a las cabeceras WS; añadido multiproceso `SO_REUSEPORT` |
| `KRAKER_Firewall.sh` | **nuevo** | El panel no tenía módulo de puertos y nunca abría el 22 ni el 443 |
| `KRAKER_Gaming.sh` | **nuevo** | `fq_codel` + BBR + buffers UDP grandes; solo aplica claves existentes en el kernel; mide antes/después; `--revert` |
| `KRAKER_PingMonitor.sh` | **nuevo** | Detección de *TCP meltdown*, drops de cola y desbordes de buffer UDP, con sonda TCP si el VPS filtra ICMP |
| `aplicar_parches.sh` | **nuevo** | Instalador con backup automático |

## Alcance real (importante)

Este panel es un túnel **TCP** (SSL → Dropbear):

- **Free Fire** y juegos móviles UDP → sirven, vía BadVPN `udpgw` (UDP-sobre-TCP).
- **Fortnite / LoL / Valorant** (PC) → **no** pueden pasar por aquí. Necesitan
  WireGuard u otro transporte UDP real.
