#!/bin/bash
# KRAKER MASTER - MONITOR DE ESTABILIDAD DE PING  (NUEVO)
#
# Objetivo: detectar POR QUÉ el ping no es estable, no solo que no lo es.
# Mide y correlaciona:
#   1. ICMP  : media, jitter (mdev), máximo y pérdida  -> lo que siente el jugador
#   2. TCP   : retransmisiones, out-of-order, ListenDrops  -> "TCP meltdown"
#   3. Colas : drops en softnet (backlog) y en el qdisc -> ráfagas descartadas
#   4. UDP   : RcvbufErrors / InErrors -> buffer udpgw insuficiente
#
# El tráfico del juego viaja como UDP -> TCP -> TCP (SSL). Si la primera capa TCP
# pierde paquetes, las dos se frenan entre sí y el ping da saltos: eso es meltdown.
#
# Uso:
#   bash KRAKER_PingMonitor.sh            -> mide una vez y da veredicto
#   bash KRAKER_PingMonitor.sh --watch    -> bucle continuo (cada 60s)
#   bash KRAKER_PingMonitor.sh --install  -> instala como servicio systemd
#   bash KRAKER_PingMonitor.sh --summary  -> resumen del log histórico

SOURCE_SCRIPT="$(readlink -f "$0")"
if [[ -w /var/log && -w /run ]]; then
    LOG=/var/log/kraker-ping.log; CSV=/var/log/kraker-ping.csv; PREV=/run/kraker-ping-prev
else
    LOG=/tmp/kraker-ping.log; CSV=/tmp/kraker-ping.csv; PREV=/tmp/kraker-ping-prev
fi
TARGET_1="${KRAKER_PING_TARGET1:-8.8.8.8}"
TARGET_2="${KRAKER_PING_TARGET2:-1.1.1.1}"
INTERVAL="${KRAKER_PING_INTERVAL:-60}"

# Umbrales (ajustables por entorno)
JITTER_WARN=15        # ms de desviación
LOSS_WARN=1           # % de pérdida
RETRANS_WARN=2        # % de segmentos retransmitidos
SOFTNET_WARN=10       # drops acumulados por minuto

R='\033[0;31m'; G='\033[0;32m'; Y='\033[1;33m'; C='\033[0;36m'; N='\033[0m'

# ---------- lectura de contadores del kernel ----------
tcp_stat() { # tcp_stat RetransSegs
    local proto=$1 key=$2
    awk -v p="$proto:" -v k="$key" '
        $0==p { hdr=1; next }
        hdr==1 { for(i=1;i<=NF;i++) if($i==k){print $(i+1); exit} ; exit }
    ' /proc/net/snmp 2>/dev/null
}

udp_stat() { # udp_stat RcvbufErrors
    awk -v p="Udp:" -v k="$1" '
        $0==p { hdr=1; next }
        hdr==1 { for(i=1;i<=NF;i++) if($i==k){print $(i+1); exit} ; exit }
    ' /proc/net/snmp 2>/dev/null
}

softnet_drops() { # columna 2 de /proc/net/softnet_stat = drops
    awk '{s+=$2} END{printf "%d", s}' /proc/net/softnet_stat 2>/dev/null
}

qdisc_drops() {
    if command -v tc > /dev/null 2>&1; then
        tc -s qdisc show 2>/dev/null | awk '/dropped/{s+=$2} END{print s+0}'
    else
        echo 0
    fi
}

ping_stats() { # imprime: media jitter max loss
    if ! command -v ping > /dev/null 2>&1; then echo "0 0 0 0"; return; fi
    local out
    out=$(ping -c 20 -i 0.2 -W 2 -q "$1" 2>/dev/null)
    if [[ -z "$out" ]]; then echo "0 0 0 100"; return; fi
    local avg mdev max loss
    avg=$(echo "$out"  | awk -F'/' '/rtt|round-trip/{print $5}')
    mdev=$(echo "$out" | awk -F'/' '/rtt|round-trip/{print $7}' | cut -d' ' -f1)
    max=$(echo "$out"  | awk -F'/' '/rtt|round-trip/{print $6}')
    loss=$(echo "$out" | grep -oE '[0-9]+(?=% packet loss)' | head -1)
    [[ -z "$loss" ]] && loss=$(echo "$out" | grep -oE '([0-9]+)%' | head -1 | tr -d '%')
    echo "${avg:-0} ${mdev:-0} ${max:-0} ${loss:-0}"
}

tcp_probe() { # tcp_probe host puerto -> "media jitter max loss%"
    python3 - "$1" "$2" <<'PYEOF' 2>/dev/null
import socket, sys, time
h, p = sys.argv[1], int(sys.argv[2])
ts = []; fail = 0
for _ in range(10):
    t0 = time.perf_counter()
    try:
        s = socket.create_connection((h, p), timeout=2); s.close()
        ts.append((time.perf_counter() - t0) * 1000)
    except Exception:
        fail += 1
if not ts:
    print("0 0 0 100")
else:
    avg = sum(ts) / len(ts)
    mdev = (sum((x - avg) ** 2 for x in ts) / len(ts)) ** 0.5
    print(f"{avg:.1f} {mdev:.1f} {max(ts):.1f} {fail*10}")
PYEOF
}

# ---------- un muestreo ----------
sample() {
    local ts; ts=$(date '+%F %T')

    # ICMP
    read -r a1 j1 m1 l1 <<< "$(ping_stats "$TARGET_1")"
    read -r a2 j2 m2 l2 <<< "$(ping_stats "$TARGET_2")"

    # Si el VPS filtra ICMP (habitual), medimos con handshake TCP:443
    local via_tcp=0
    if [[ "${l1%.*}" -ge 100 && "${l2%.*}" -ge 100 ]]; then
        read -r a1 j1 m1 l1 <<< "$(tcp_probe 1.1.1.1 443)"
        read -r a2 j2 m2 l2 <<< "$(tcp_probe 8.8.8.8 443)"
        via_tcp=1
    fi

    # Contadores instantáneos (delta contra la muestra anterior guardada)
    local prev_file="$PREV"
    local retrans=0 listeners=0 rcverr=0 inerr=0 droprate=0
    local cur_retrans=0 cur_listen=0 cur_rcverr=0 cur_inerr=0

    # índices: Tcp OutSegs es la 11ª columna aprox; buscamos por nombre en la cabecera
    cur_retrans=$(tcp_stat Tcp RetransSegs); cur_retrans=${cur_retrans:-0}
    cur_listen=$(tcp_stat Tcp ListenDrops);   cur_listen=${cur_listen:-0}
    cur_rcverr=$(udp_stat RcvbufErrors);      cur_rcverr=${cur_rcverr:-0}
    cur_inerr=$(udp_stat InErrors);           cur_inerr=${cur_inerr:-0}
    local cur_soft cur_qd
    cur_soft=$(softnet_drops); cur_qd=$(qdisc_drops)

    if [[ -f "$prev_file" ]]; then
        local p_retrans p_listen p_rcverr p_inerr p_soft p_qd p_ts
        read -r p_retrans p_listen p_rcverr p_inerr p_soft p_qd p_ts < "$prev_file"
        local dt=$(( $(date +%s) - ${p_ts:-0} )); (( dt < 1 )) && dt=1
        retrans=$((  cur_retrans - ${p_retrans:-0} ))
        listeners=$(( cur_listen  - ${p_listen:-0}  ))
        rcverr=$((   cur_rcverr  - ${p_rcverr:-0}   ))
        inerr=$((    cur_inerr   - ${p_inerr:-0}    ))
        local dsoft=$(( cur_soft - ${p_soft:-0} )) dqd=$(( cur_qd - ${p_qd:-0} ))
        droprate=$(( (dsoft + dqd) * 60 / dt ))
    fi
    echo "$cur_retrans $cur_listen $cur_rcverr $cur_inerr $cur_soft $cur_qd $(date +%s)" > "$prev_file"

    # Salida CSV (para graficar después)
    mkdir -p "$(dirname "$CSV")" 2>/dev/null
    [[ -f "$CSV" ]] || echo "fecha,avg1,jitter1,max1,loss1,avg2,jitter2,max2,loss2,retrans,listendrops,udprcvbuf,drops_min" > "$CSV"
    echo "$ts,$a1,$j1,$m1,$l1,$a2,$j2,$m2,$l2,$retrans,$listeners,$rcverr,$droprate" >> "$CSV"

    # ---------- veredicto ----------
    local problemas=() consejos=()
    (( ${j1%.*} > JITTER_WARN )) && { problemas+=("jitter ${j1}ms"); consejos+=("Jitter alto: revisa fq_codel (KRAKER_Gaming.sh) y saturación de CPU en el VPS."); }
    (( ${l1%.*} > LOSS_WARN )) && { problemas+=("pérdida ${l1}%"); consejos+=("Pérdida ICMP: enlace saturado o filtrado del proveedor."); }
    (( retrans > 0 )) && problemas+=("retransmisiones TCP +$retrans")
    (( listeners > 0 )) && problemas+=("ListenDrops +$listeners")
    (( rcverr > 0 )) && problemas+=("UDP RcvbufErrors +$rcverr")
    (( droprate > SOFTNET_WARN )) && problemas+=("drops de cola ~$droprate/min")

    (( retrans > 0 )) && consejos+=("Retransmisiones = meltdown UDP->TCP->TCP: sube netdev_max_backlog y baja --client-socket-sndbuf de udpgw.")
    (( listeners > 0 )) && consejos+=("ListenDrops: sube somaxconn/max_syn_backlog, o hay ráfaga de reconexiones.")
    (( rcverr > 0 )) && consejos+=("RcvbufErrors: el buffer UDP se desborda -> sube rmem_max/udp_rmem_min.")
    (( droprate > SOFTNET_WARN )) && consejos+=("Drops de cola: el VPS no procesa tan rápido como recibe -> revisa CPU.");

    (( ${l1%.*} >= 100 )) && problemas+=("sin conectividad de salida")

    local estado color
    if [[ ${#problemas[@]} -eq 0 ]]; then
        estado="ESTABLE"; color="$G"
    elif [[ ${#problemas[@]} -le 1 ]]; then
        estado="ACEPTABLE"; color="$Y"
    else
        estado="INESTABLE"; color="$R"
    fi

    printf "%b[%s] %s%b\n" "$color" "$ts" "$estado" "$N"
    if (( via_tcp )); then
        printf "   ${Y}[ICMP filtrado por el VPS -> midiendo por handshake TCP:443]${N}\n"
        printf "   TCP  1.1.1.1:443  media %sms  jitter %sms  max %sms  fallo %s%%\n" "$a1" "$j1" "$m1" "$l1"
        printf "   TCP  8.8.8.8:443  media %sms  jitter %sms  max %sms  fallo %s%%\n" "$a2" "$j2" "$m2" "$l2"
    else
        printf "   ICMP %s  media %sms  jitter %sms  max %sms  perdida %s%%\n" "$TARGET_1" "$a1" "$j1" "$m1" "$l1"
        printf "   ICMP %s  media %sms  jitter %sms  max %sms  perdida %s%%\n" "$TARGET_2" "$a2" "$j2" "$m2" "$l2"
    fi
    printf "   TCP retrans=%s  ListenDrops=%s | UDP RcvbufErr=%s InErr=%s | drops/min=%s\n" \
           "$retrans" "$listeners" "$rcverr" "$inerr" "$droprate"
    if [[ ${#problemas[@]} -gt 0 ]]; then
        printf "   Problemas: %s\n" "${problemas[*]}"
        for c in "${consejos[@]}"; do printf "   -> %s\n" "$c"; done
    fi

    {
        echo "[$ts] $estado | avg=${a1}ms jitter=${j1}ms max=${m1}ms loss=${l1}% | retrans=$retrans listenDrops=$listeners udpRcvbuf=$rcverr drops/min=$droprate"
        printf '   %s\n' "${problemas[@]}" "${consejos[@]}" 2>/dev/null
    } >> "$LOG"

    [[ "$estado" == "INESTABLE" ]] && return 2
    return 0
}

# ---------- modos ----------
case "${1:-}" in
    --install)
        cat > /etc/systemd/system/kraker-pingmon.service <<EOF
[Unit]
Description=KRAKER MASTER - Monitor de estabilidad de ping
After=network-online.target

[Service]
Type=simple
ExecStart=/bin/bash $SOURCE_SCRIPT --watch
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable --now kraker-pingmon
        echo -e "${G}[✔] Monitor instalado.${N}"
        echo "  Ver en vivo : journalctl -u kraker-pingmon -f"
        echo "  Log         : $LOG"
        echo "  CSV         : $CSV"
        exit 0
        ;;
    --summary)
        [[ -f "$CSV" ]] || { echo "Aún no hay datos en $CSV"; exit 1; }
        echo -e "${C}=== RESUMEN HISTÓRICO ===${N}"
        awk -F, 'NR>1 {
            n++; j+=$3; a+=$2; l+=$5; r+=$10; d+=$13;
            if($3>mj)mj=$3; if($5>ml)ml=$5;
            if($3>15)jit++;
        } END {
            if(n==0){print "sin muestras"; exit}
            printf "  Muestras        : %d\n", n;
            printf "  Ping medio      : %.1f ms\n", a/n;
            printf "  Jitter medio    : %.1f ms (máx %.1f)\n", j/n, mj;
            printf "  Pérdida media   : %.2f %% (máx %.1f)\n", l/n, ml;
            printf "  Retransmisiones : %d en total\n", r;
            printf "  Drops de cola   : %d\n", d;
            printf "  Muestras con jitter >15ms: %d (%.0f%%)\n", jit, jit*100/n;
        }' "$CSV"
        exit 0
        ;;
    --watch)
        echo -e "${C}Monitor de estabilidad KRAKER — cada ${INTERVAL}s (Ctrl+C para salir)${N}"
        while true; do sample; sleep "$INTERVAL"; done
        ;;
    *)
        sample
        exit $?
        ;;
esac
