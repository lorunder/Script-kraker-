#!/bin/bash
# KRAKER MASTER - GAMING LATENCY TUNER  (NUEVO)
#
# IMPORTANTE - ALCANCE REAL:
#   Este stack es un TÚNEL SSH/SSL (TCP). Sirve para juegos MÓVILES que toleran
#   UDP-sobre-TCP (Free Fire vía BadVPN udpgw en 7100/7200/7300).
#   NO sirve para Fortnite / LoL / Valorant en PC: esos necesitan UDP real
#   (WireGuard / OpenVPN / Hysteria2). Ningún ajuste de sysctl cambia eso.
#
# Lo que SÍ hace este script (todo medible):
#   1. qdisc fq_codel/cake  -> mata el bufferbloat (picos de ping)
#   2. BBR + fq             -> menos retransmisiones en el túnel TCP
#   3. tcp_notsent_lowat    -> baja la latencia de los paquetes pequeños
#   4. tcp_slow_start_after_idle=0 -> evita el "frenazo" tras pausas
#   5. Buffers UDP grandes  -> clave para udpgw (Free Fire)
#   6. Límites de ficheros y backlog
#   7. CPU governor a performance (si el VPS lo expone)
#   8. RPS/RFS y ring buffers (si el VPS lo permite)
#
# Uso:   bash KRAKER_Gaming.sh          -> aplicar + medir
#        bash KRAKER_Gaming.sh --revert -> deshacer

SOURCE_DIR=$(dirname "$(readlink -f "$0")")
[[ -f "$SOURCE_DIR/utils.sh" ]] && source "$SOURCE_DIR/utils.sh" || exit 1

CONF=/etc/sysctl.d/99-kraker-gaming.conf
BACKUP=/root/kraker_sysctl_backup_$(date +%Y%m%d-%H%M%S).tar.gz

# ---------- utilidades ----------
has()  { [[ -e "/proc/sys/$(echo "$1" | tr '.' '/')" ]]; }
setkv(){ # setkv clave valor
    if has "$1"; then
        echo "$1 = $2" >> "$CONF"
    else
        echo "# (omitido: $1 no existe en este kernel)" >> "$CONF"
    fi
}

medir() {
    local host="${1:-8.8.8.8}"
    if ! command -v ping > /dev/null 2>&1; then echo "  (sin ping instalado)"; return; fi
    local out
    out=$(ping -c 20 -i 0.2 -q "$host" 2>/dev/null)
    if [[ -z "$out" ]]; then echo "  (sin respuesta de $host)"; return; fi
    local avg mdev loss
    avg=$(echo "$out" | awk -F'/' '/rtt|round-trip/{print $5}')
    mdev=$(echo "$out" | awk -F'/' '/rtt|round-trip/{print $7}' | cut -d' ' -f1)
    loss=$(echo "$out" | grep -oE '[0-9]+% packet loss')
    echo "  ping $host -> media ${avg:-?} ms | jitter ${mdev:-?} ms | $loss"
}

# ---------- revertir ----------
if [[ "$1" == "--revert" ]]; then
    msg_header "REVIRTIENDO TUNEO DE GAMING"
    rm -f "$CONF"
    sysctl --system > /dev/null 2>&1
    echo -e "${GREEN}[✔] $CONF eliminado y sysctl recargado.${NC}"
    sleep 2
    exit 0
fi

msg_header "GAMING LATENCY TUNER"

# ---------- 0. Backup ----------
tar -czf "$BACKUP" /etc/sysctl.conf /etc/sysctl.d 2>/dev/null
echo -e "${GREEN}[✔] Backup de sysctl en: $BACKUP${NC}"

# ---------- 1. Antes ----------
echo -e "\n${CYAN}── MEDICIÓN INICIAL ──${NC}"
echo "  qdisc actual: $(cat /proc/sys/net/core/default_qdisc 2>/dev/null)"
echo "  congestión  : $(cat /proc/sys/net/ipv4/tcp_congestion_control 2>/dev/null)"
medir 8.8.8.8
medir 1.1.1.1

# ---------- 2. Escribir sysctl (solo claves existentes) ----------
echo -e "\n${YELLOW}[*] Generando $CONF...${NC}"
cat > "$CONF" <<'EOF'
# ===== KRAKER GAMING LATENCY PROFILE =====
EOF

# --- Control de congestión y colas (lo que más afecta al ping) ---
setkv net.core.default_qdisc fq_codel
setkv net.ipv4.tcp_congestion_control bbr

# --- Latencia interactiva ---
setkv net.ipv4.tcp_notsent_lowat 131072   # no acumular datos "en cola" del socket
setkv net.ipv4.tcp_slow_start_after_idle 0 # no reiniciar ventana tras inactividad
setkv net.ipv4.tcp_mtu_probing 1
setkv net.ipv4.tcp_ecn 1
setkv net.ipv4.tcp_fastopen 3
setkv net.ipv4.tcp_fin_timeout 15
setkv net.ipv4.tcp_tw_reuse 1
setkv net.ipv4.tcp_max_syn_backlog 8192
setkv net.core.somaxconn 8192
setkv net.ipv4.ip_local_port_range 1024 65000

# --- Buffers TCP (túnel SSL = TCP) ---
setkv net.ipv4.tcp_rmem 4096 87380 33554432
setkv net.ipv4.tcp_wmem 4096 65536 33554432

# --- Buffers UDP: CRÍTICO para BadVPN udpgw / Free Fire ---
setkv net.core.rmem_max 33554432
setkv net.core.wmem_max 33554432
setkv net.core.rmem_default 1048576
setkv net.core.wmem_default 1048576
setkv net.core.netdev_max_backlog 16384
setkv net.ipv4.udp_rmem_min 16384
setkv net.ipv4.udp_wmem_min 16384

# --- Memoria: no mandar nada a swap (un swap = pico de 300ms) ---
setkv vm.swappiness 10
setkv vm.dirty_ratio 15
setkv vm.dirty_background_ratio 5
EOF

sysctl -p "$CONF" 2>&1 | grep -vE "^$" | sed 's/^/  /' || true
sysctl --system > /dev/null 2>&1

# ---------- 3. CPU governor ----------
echo -e "\n${YELLOW}[*] CPU governor...${NC}"
if compgen -G "/sys/devices/system/cpu/cpu*/cpufreq/scaling_governor" > /dev/null; then
    for f in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
        echo performance > "$f" 2>/dev/null
    done
    echo -e "  ${GREEN}[✔] governor = performance${NC}"
else
    echo -e "  ${YELLOW}[~] Este VPS no expone cpufreq (lo controla el host). Normal en KVM/OpenVZ.${NC}"
fi

# ---------- 4. RPS/RFS (reparto de softirq entre cores) ----------
echo -e "\n${YELLOW}[*] RPS/RFS...${NC}"
NCORES=$(nproc)
if [[ -d /sys/class/net ]] && [[ $NCORES -gt 1 ]]; then
    MASK=$(printf '%x' $(( (1 << NCORES) - 1 )))
    applied=0
    for iface in $(ls /sys/class/net | grep -vE '^(lo|docker|veth|br-)'); do
        for q in /sys/class/net/$iface/queues/rx-*/rps_cpus; do
            [[ -w "$q" ]] && { echo "$MASK" > "$q" 2>/dev/null && applied=1; }
        done
        for f in /sys/class/net/$iface/queues/rx-*/rps_flow_cnt; do
            [[ -w "$f" ]] && echo 32768 > "$f" 2>/dev/null
        done
    done
    [[ $applied -eq 1 ]] && echo -e "  ${GREEN}[✔] RPS activado en $NCORES cores${NC}" \
                         || echo -e "  ${YELLOW}[~] RPS no disponible en este VPS (virtio sin multiqueue)${NC}"
else
    echo -e "  ${YELLOW}[~] 1 core o sin /sys/class/net útil${NC}"
fi

# ---------- 5. Límites de ficheros ----------
echo -e "\n${YELLOW}[*] Límites de ficheros...${NC}"
cat > /etc/security/limits.d/99-kraker.conf <<'EOF'
* soft nofile 65535
* hard nofile 65535
root soft nofile 65535
root hard nofile 65535
EOF
echo -e "  ${GREEN}[✔] nofile = 65535${NC}"

# ---------- 6. Aplicar a los servicios ya instalados ----------
echo -e "\n${YELLOW}[*] Reiniciando servicios para que tomen los cambios...${NC}"
for s in kraker-gateway kraker-ssl kraker-udp dropbear; do
    if systemctl is-active --quiet "$s" 2>/dev/null; then
        systemctl restart "$s" > /dev/null 2>&1 && echo -e "  ${GREEN}[✔] $s reiniciado${NC}"
    fi
done

# ---------- 7. Después ----------
echo -e "\n${CYAN}── MEDICIÓN FINAL ──${NC}"
echo "  qdisc actual: $(cat /proc/sys/net/core/default_qdisc 2>/dev/null)"
echo "  congestión  : $(cat /proc/sys/net/ipv4/tcp_congestion_control 2>/dev/null)"
medir 8.8.8.8
medir 1.1.1.1

echo -e "\n${BARRA}"
echo -e "${CYAN}QUÉ ESPERAR DE VERDAD:${NC}"
echo -e "  • El ${GREEN}jitter${NC} (variación del ping) baja: eso es lo que se nota en juegos."
echo -e "  • El ${GREEN}ping mínimo${NC} NO baja: eso depende de la distancia física al servidor"
echo -e "    y de la ruta de tu proveedor. Ningún script acorta la fibra."
echo -e "  • Para Free Fire el ${GREEN}udpgw${NC} tiene que estar arriba:"
echo -e "    ${GRAY}ss -ntl | grep -E ':(7100|7200|7300) '${NC}"
echo -e "  • Fortnite/LoL ${RED}no pueden pasar${NC} por un túnel TCP. Necesitan WireGuard."
echo -e "${BARRA}"
echo -e "${YELLOW}Para deshacer:${NC} bash $0 --revert"
read -r -p "ENTER para continuar..." _
