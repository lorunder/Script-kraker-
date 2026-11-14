#!/bin/bash
# Aplica los parches de la auditoría sobre una instalación de KRAKER MASTER.
# Uso:  sudo bash aplicar_parches.sh [ruta_del_repo]
# Por defecto: /root/kraker_master

set -u
R='\033[0;31m'; G='\033[0;32m'; Y='\033[1;33m'; C='\033[0;36m'; N='\033[0m'

TARGET="${1:-/root/kraker_master}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

[[ $EUID -ne 0 ]] && echo -e "${R}Ejecuta como root.${N}" && exit 1
[[ ! -d "$TARGET/scripts" ]] && echo -e "${R}No encuentro $TARGET/scripts${N}" && exit 1

echo -e "${C}=== APLICANDO PARCHES KRAKER ===${N}"
echo "Destino: $TARGET"

# 1. Backup
BK="$TARGET.bak.$(date +%Y%m%d-%H%M%S)"
cp -a "$TARGET" "$BK"
echo -e "${G}✔ Backup creado: $BK${N}"

# 2. Copiar scripts corregidos
for f in utils.sh KRAKER_UDP.sh KRAKER_Services.sh KRAKER_Dropbear.sh KRAKER_AntiMulti.sh KRAKER_Firewall.sh KRAKER_SSL.sh KRAKER_SSL_Gateway.py KRAKER_Gaming.sh KRAKER_PingMonitor.sh; do
    if [[ -f "$HERE/$f" ]]; then
        cp "$HERE/$f" "$TARGET/scripts/$f"
        echo -e "${G}✔ $f${N}"
    fi
done
chmod +x "$TARGET/scripts"/*.sh

# 3. Limpiar cron duplicados
if command -v crontab > /dev/null 2>&1; then
    BEFORE=$(crontab -l 2>/dev/null | wc -l)
    crontab -l 2>/dev/null | grep -v -- "--ram-clean" | grep -v -- "--cpu-clean" | crontab -
    AFTER=$(crontab -l 2>/dev/null | wc -l)
    echo -e "${G}✔ Crontab limpiado: $BEFORE -> $AFTER líneas${N}"
fi

# 4. Recargar systemd
systemctl daemon-reload 2>/dev/null

echo
echo -e "${C}=== SIGUIENTE PASO ===${N}"
echo "  bash $TARGET/scripts/KRAKER_Firewall.sh    # abre puertos (22 primero)"
echo "  bash $TARGET/scripts/KRAKER_UDP.sh         # reinstala BadVPN bien"
echo
echo -e "${Y}Verificación real:${N}"
echo "  ss -ntl | grep -E ':(22|80|143|442|443|7100|7200|7300) '"
