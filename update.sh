#!/bin/bash
# KRAKER MASTER - Actualizador para instalaciones existentes
#
# Uso:  sudo bash /root/kraker_master/update.sh
#
# Qué hace:
#   1. Backup de la instalación actual
#   2. Trae la última versión del repo (git pull)
#   3. Limpia los cron duplicados que dejaba el panel viejo
#   4. Recarga systemd y reinicia los servicios que ya estuvieran activos
#   5. Verifica puertos y muestra el estado real
#
# No toca /etc/sysctl.conf ni instala nada nuevo.

set -u
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; GRAY='\033[0;90m'; NC='\033[0m'
ok()   { echo -e "  ${GREEN}✔${NC} $1"; }
info() { echo -e "  ${GRAY}·${NC} $1"; }
warn() { echo -e "  ${YELLOW}!${NC} $1"; }
err()  { echo -e "  ${RED}✘${NC} $1"; }

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DIR" || exit 1

echo -e "${CYAN}======================================================${NC}"
echo -e "${GREEN}    KRAKER MASTER — ACTUALIZADOR${NC}"
echo -e "${CYAN}======================================================${NC}"

[[ $EUID -ne 0 ]] && { err "Ejecuta como root."; exit 1; }

# 1. Backup
BK="${DIR}.bak.$(date +%Y%m%d-%H%M%S)"
if cp -a "$DIR" "$BK" 2>/dev/null; then
    ok "Backup: $BK"
else
    warn "No se pudo crear el backup (se continúa)"
fi

# 2. Actualizar
echo -e "\n${YELLOW}[*] Actualizando código...${NC}"
if [[ -d "$DIR/.git" ]]; then
    ANTES=$(git rev-parse --short HEAD 2>/dev/null)
    if git pull --ff-only > /dev/null 2>&1; then
        DESPUES=$(git rev-parse --short HEAD 2>/dev/null)
        if [[ "$ANTES" == "$DESPUES" ]]; then
            info "Ya estabas en la última versión ($ANTES)"
        else
            ok "Actualizado: $ANTES -> $DESPUES"
        fi
    else
        warn "git pull falló (¿cambios locales?). Se usan los scripts actuales."
    fi
else
    warn "No es un repo git; se usan los scripts presentes en $DIR"
fi

chmod +x "$DIR/menu.sh" 2>/dev/null
chmod +x "$DIR/scripts"/*.sh 2>/dev/null
ln -sf "$DIR/menu.sh" /usr/bin/kraker 2>/dev/null
ln -sf "$DIR/menu.sh" /usr/bin/menu 2>/dev/null
ok "Permisos y comandos listos"

# 3. Limpiar cron duplicados del panel viejo
echo -e "\n${YELLOW}[*] Limpiando cron duplicados...${NC}"
if command -v crontab > /dev/null 2>&1 && crontab -l > /dev/null 2>&1; then
    ANTES_N=$(crontab -l 2>/dev/null | grep -c -- "--ram-clean\|--cpu-clean")
    crontab -l 2>/dev/null | grep -v -- "--ram-clean" | grep -v -- "--cpu-clean" | crontab -
    if [[ "$ANTES_N" -gt 0 ]]; then
        ok "Eliminadas $ANTES_N líneas de limpieza automática (las vuelve a crear el panel, ya sin duplicarse)"
    else
        info "Sin duplicados que limpiar"
    fi
else
    info "Sin crontab definido"
fi

# 4. Recargar servicios
echo -e "\n${YELLOW}[*] Reiniciando servicios activos...${NC}"
systemctl daemon-reload 2>/dev/null
for s in kraker-gateway kraker-ssl kraker-udp kraker-dns dropbear; do
    if systemctl is-active --quiet "$s" 2>/dev/null; then
        systemctl restart "$s" > /dev/null 2>&1 && ok "$s reiniciado" || warn "$s no reinició"
    fi
done

# 5. Estado real
echo -e "\n${CYAN}── ESTADO REAL ──${NC}"
for p in 22 80 143 442 443 7100 7200 7300; do
    if ss -ntl 2>/dev/null | grep -q ":$p "; then
        echo -e "  ${GREEN}✔${NC} TCP $p escuchando"
    elif ss -nul 2>/dev/null | grep -q ":$p "; then
        echo -e "  ${GREEN}✔${NC} UDP $p escuchando"
    else
        echo -e "  ${GRAY}·${NC} puerto $p cerrado"
    fi
done

echo -e "\n${CYAN}======================================================${NC}"
echo -e "  Panel: ${CYAN}kraker${NC}"
echo -e "  Si el 443 está cerrado: ${CYAN}[03] SSL Gateway${NC} en el menú"
echo -e "  Si 7100-7300 están cerrados: ${CYAN}[08] UDP Gaming${NC}"
echo -e "${CYAN}======================================================${NC}"
