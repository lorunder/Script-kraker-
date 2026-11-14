# 🐲 KRAKER MASTER — Panel de Gestión VPS v3.0

Panel para montar túneles **SSL / SSH** con soporte de **payload WebSocket**, más
**BadVPN (UDP-over-TCP)** para juegos móviles. Versión auditada: se corrigieron 14 bugs
del panel original (ver [`AUDITORIA_KRAKER.md`](AUDITORIA_KRAKER.md)).

---

## 📦 Instalación

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/lorunder/Script-kraker-/main/install.sh)
```

Sin interacción (para automatizar / provisioning):

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/lorunder/Script-kraker-/main/install.sh) --yes
```

Una vez instalado, el panel se abre con:

```bash
kraker
```

### Actualizar una instalación existente

```bash
sudo bash /root/kraker_master/update.sh
```

Hace backup, trae la última versión, limpia los cron duplicados y reinicia los servicios
que ya estuvieran activos. **No** reinstala ni borra configuración.

---

## 🚀 Orden recomendado la primera vez

| Paso | Opción del menú | Qué hace |
|---|---|---|
| 1 | `[10]` Dropbear Manager | Crea el destino del túnel (puertos 80 / 143 / 442) |
| 2 | `[17]` Abrir Puertos | Abre 22, 80, 143, 442, 443 y 7100-7300 en firewall |
| 3 | `[03]` SSL Gateway | Modo **Python** si hay clientes mixtos (WS + SSL) |
| 4 | `[08]` UDP Gaming | BadVPN `udpgw` para Free Fire |
| 5 | `[18]` Tuner Gaming | BBR + `fq_codel` + buffers UDP |

Verificación real (no lo que diga el panel):

```bash
ss -ntl | grep -E ':(22|80|143|442|443|7100|7200|7300) '
```

---

## 🔌 Protocolos y puertos

| Servicio | Puerto | Notas |
|---|---|---|
| **SSL Gateway (Python)** | 443/TCP | Detecta solo: SSL puro **y** payload WS `GET / HTTP/1.1` |
| **SSL Gateway (Stunnel)** | 443/TCP | Más rápido, solo SSL puro |
| **Dropbear SSH** | 80, 143, 442/TCP | Destino de los túneles |
| **BadVPN udpgw** | 7100, 7200, 7300/**TCP** | UDP-over-TCP para juegos móviles |
| **SlowDNS** | 53, 5300/UDP | Requiere configurar NS en tu dominio |

> ⚠️ Los puertos 7100-7300 son **TCP**, aunque el servicio se llame "UDP Gaming".
> `udpgw` encapsula UDP dentro de TCP: por eso el cliente se conecta por TCP.

---

## 🎮 Alcance real en juegos

| Juego | ¿Funciona? | Por qué |
|---|---|---|
| **Free Fire** (móvil) | ✅ Sí | UDP encapsulado con BadVPN `udpgw` |
| Juegos móviles varios | ⚠️ Parcial | Solo si el cliente soporta UDP-over-TCP |
| **Fortnite / LoL / Valorant** (PC) | ❌ No | Necesitan UDP real (WireGuard / Hysteria2). Un túnel TCP no los transporta |

Ningún ajuste de `sysctl` cambia esto: es una limitación del protocolo.

---

## 🛠️ Herramientas incluidas

- **`[14] Gestor de Servicios`** — estado real de cada protocolo leyendo puertos, no solo systemd.
- **`[17] Abrir Puertos`** — abre todo lo necesario; el 22 siempre primero.
- **`[18] Tuner Gaming`** — BBR, `fq_codel`, buffers UDP grandes. Mide antes/después y tiene `--revert`.
- **`[19] Monitor de Ping`** — detecta *TCP meltdown*, drops de cola y desbordes de buffer UDP.
- **`diagnostico.sh`** — diagnóstico de solo lectura para revisar un VPS entero:
  ```bash
  bash /root/kraker_master/diagnostico.sh > reporte.txt
  ```

---

## 📋 Requisitos

- **SO:** Debian 11/12/13 o Ubuntu 20.04/22.04/24.04
- **RAM:** 512 MB mínimo (1 GB recomendado)
- **Acceso:** root
- **Puertos del proveedor:** además del firewall local, ábrelos en el panel del hosting
  (AWS Security Group, Hetzner, OVH, Vultr, Contabo). El firewall del proveedor es
  independiente y es la causa más común de "el puerto dice abierto pero no conecta".

---

## 🔐 Seguridad

- El instalador **nunca** deja el puerto 22 fuera del firewall.
- Las unidades systemd nuevas (`kraker-ssl`, `kraker-gateway`, `kraker-udp`) tienen
  `Restart=always` y arrancan solas al reiniciar el VPS.
- Los certificados existentes **no** se sobrescriben: el autofirmado solo se genera si
  falta, así que un certificado de Let's Encrypt (ACME) se conserva.

---

## 📚 Documentación

- [`AUDITORIA_KRAKER.md`](AUDITORIA_KRAKER.md) — los 14 bugs encontrados, con archivo:línea,
  causa y arreglo, más las pruebas empíricas que se hicieron.

---

**KRAKER VPS** — versión auditada.
