#!/bin/bash
# KRAKER MASTER - ANTI MULTI-LOGIN  [VERSIÓN CORREGIDA]
# Bugs del original:
#  1) Contaba sesiones con:
#        ps -u "$user" -o comm= | grep -E "(dropbear|sshd)" | wc -l
#     El proceso "dropbear"/"sshd" corre como ROOT, y como usuario aparece la shell
#     (bash/sh), no dropbear. Resultado: el contador daba SIEMPRE 0 -> el limitador
#     NUNCA funcionaba.
#  2) Cuando por casualidad se disparaba, hacía "pkill -u $user", que mata TODAS las
#     sesiones del usuario (también las legítimas) de golpe -> desconexiones masivas.
#  Ahora: se cuentan TTYs reales del usuario y se matan solo las sesiones sobrantes,
#  las más nuevas, dejando intactas las primeras (limit).

SOURCE_DIR=$(dirname "$(readlink -f "$0")")
[[ -f "$SOURCE_DIR/utils.sh" ]] && source "$SOURCE_DIR/utils.sh" || exit 1
USER_DB="/etc/kraker_users.db"

if [[ "$1" != "cron" ]]; then
    msg_header "LIMITADOR DE TRÁFICO (ANTI-ABUSO)"
    echo -e "${YELLOW}[*] Acoplando limitador al Watchdog Global...${NC}"
    if ! crontab -l 2>/dev/null | grep -q "KRAKER_AntiMulti.sh cron"; then
        (crontab -l 2>/dev/null; echo "*/2 * * * * bash $SOURCE_DIR/KRAKER_AntiMulti.sh cron > /dev/null 2>&1") | crontab -
    fi
    echo -e "${GREEN}✔ SISTEMA ANTI-MULTILOGIN ACTIVADO.${NC}"
    echo -e "${CYAN}Revisará conexiones clonadas cada 2 minutos.${NC}"
    echo -e "${BARRA}"
    sleep 3
    exit 0
fi

[[ ! -f "$USER_DB" ]] && exit 0

# MODO CRON
while IFS='|' read -r user pass exp uuid limit; do
    [[ -z "$user" || -z "$limit" ]] && continue
    id "$user" > /dev/null 2>&1 || continue

    # TTYs reales del usuario = sesiones SSH/Dropbear abiertas
    mapfile -t TTYS < <(ps -u "$user" -o tty= 2>/dev/null | tr -d ' ' | grep -v '^?' | sort -u)
    sesiones=${#TTYS[@]}

    if (( sesiones > limit )); then
        echo "[$(date '+%F %T')] $user: $sesiones sesiones (límite $limit). Cortando sobrantes." >> /var/log/kraker_antimulti.log
        # Se conservan las primeras $limit TTYs; se cortan las demás (las más nuevas)
        for ((i=limit; i<sesiones; i++)); do
            tty="${TTYS[$i]}"
            # Matar solo los procesos de esa TTY concreta de ese usuario
            pkill -KILL -u "$user" -t "$tty" 2>/dev/null
            echo "    -> cerrada tty $tty" >> /var/log/kraker_antimulti.log
        done
    fi
done < "$USER_DB"
