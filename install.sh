#!/bin/bash
# KRAKER MASTER - Instalador v3.0 (auditado)
#
# Instalación rápida:
#   bash <(curl -fsSL https://raw.githubusercontent.com/lorunder/Script-kraker-/main/install.sh)
# Sin interacción (para automatizar):
#   bash <(curl -fsSL .../install.sh) --yes
#
# Diferencias con el instalador anterior:
#   - NO ejecuta "apt-get upgrade": actualizar todo el sistema en producción rompe servicios.
#   - NO modifica /etc/sysctl.conf: el tuneo de red vive en KRAKER_Gaming.sh (opcional).
#   - NO borra una instalación existente sin preguntar.
#   - NO abre el menú interactivo al final (bloqueaba las instalaciones desatendidas).
#   - Abre el puerto 22 en ufw antes que nada.
#   - Verifica cada paso en vez de dar por hecho que funcionó.

set -u
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; GRAY='\033[0;90m'; NC='\033[0m'

REPO_URL="https://github.com/lorunder/Script-kraker-.git"
REPO_DIR="/root/kraker_master"
ASSUME_YES=0
for a in "$@"; do [[ "$a" == "--yes" || "$a" == "-y" ]] && ASSUME_YES=1; done

ok()   { echo -e "  ${GREEN}✔${NC} $1"; }
info() { echo -e "  ${GRAY}·${NC} $1"; }
warn() { echo -e "  ${YELLOW}!${NC} $1"; }
err()  { echo -e "  ${RED}✘${NC} $1"; }

echo -e "${CYAN}======================================================${NC}"
echo -e "${GREEN}    KRAKER MASTER PANEL v3.0 — INSTALADOR AUDITADO${NC}"
echo -e "${CYAN}======================================================${NC}"

# ---------- 1. Root ----------
if [[ $EUID -ne 0 ]]; then
    err "Debes ejecutar como ROOT."
    echo -e "   ${GRAY}sudo bash install.sh${NC}"
    exit 1
fi
ok "Ejecutando como root"

# ---------- 2. Sistema ----------
if ! command -v apt-get > /dev/null 2>&1; then
    err "Este instalador requiere Debian/Ubuntu (apt-get)."
    exit 1
fi
ok "Sistema compatible: $(. /etc/os-release 2>/dev/null && echo "$PRETTY_NAME")"

# ---------- 3. Dependencias (sin upgrade del sistema) ----------
echo -e "\n${YELLOW}[*] Instalando dependencias...${NC}"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq > /dev/null 2>&1
DEPS="curl wget git jq lsof net-tools openssl screen python3 psmisc"
MISSING=""
for d in $DEPS; do
    dpkg -s "$d" > /dev/null 2>&1 || MISSING="$MISSING $d"
done
if [[ -n "$MISSING" ]]; then
    info "Instalando:$MISSING"
    # shellcheck disable=SC2086
    apt-get install -y $MISSING > /dev/null 2>&1
fi
FAIL=""
for d in $DEPS; do dpkg -s "$d" > /dev/null 2>&1 || FAIL="$FAIL $d"; done
if [[ -n "$FAIL" ]]; then err "No se pudieron instalar:$FAIL"; exit 1; fi
ok "Dependencias listas"

# ---------- 4. Clonar / actualizar el repo ----------
echo -e "\n${YELLOW}[*] Código del panel...${NC}"
if [[ -d "$REPO_DIR/.git" ]]; then
    warn "Ya existe una instalación en $REPO_DIR"
    if [[ $ASSUME_YES -eq 1 ]]; then
        REPLY="a"
    else
        echo -e "     ${YELLOW}[a]${NC} Actualizar conservando la configuración (recomendado)"
        echo -e "     ${YELLOW}[b]${NC} Reinstalar desde cero (borra la carpeta)"
        echo -e "     ${YELLOW}[c]${NC} Cancelar"
        read -r -p "     Opción [a/b/c]: " REPLY
        REPLY=${REPLY:-a}
    fi
    case "${REPLY,,}" in
        b)
            BACKUP="${REPO_DIR}.bak.$(date +%Y%m%d-%H%M%S)"
            mv "$REPO_DIR" "$BACKUP"
            ok "Instalación anterior guardada en $BACKUP"
            git clone --depth 1 "$REPO_URL" "$REPO_DIR" > /dev/null 2>&1 || { err "git clone falló"; exit 1; }
            ;;
        c) info "Cancelado."; exit 0 ;;
        *)
            if git -C "$REPO_DIR" pull --ff-only > /dev/null 2>&1; then
                ok "Repositorio actualizado ($(git -C "$REPO_DIR" rev-parse --short HEAD))"
            else
                warn "No se pudo actualizar por git (cambios locales). Se conservan los scripts actuales."
            fi
            ;;
    esac
else
    git clone --depth 1 "$REPO_URL" "$REPO_DIR" > /dev/null 2>&1
    if [[ ! -d "$REPO_DIR/scripts" ]]; then err "git clone falló (revisa conexión a GitHub)"; exit 1; fi
    ok "Repositorio clonado en $REPO_DIR ($(git -C "$REPO_DIR" rev-parse --short HEAD))"
fi

# ---------- 5. Permisos y comandos ----------
echo -e "\n${YELLOW}[*] Configurando comandos...${NC}"
chmod +x "$REPO_DIR/menu.sh" 2>/dev/null
chmod +x "$REPO_DIR/scripts"/*.sh 2>/dev/null
chmod +x "$REPO_DIR/scripts"/*.py 2>/dev/null
ln -sf "$REPO_DIR/menu.sh" /usr/bin/kraker
ln -sf "$REPO_DIR/menu.sh" /usr/bin/menu
chmod +x /usr/bin/kraker /usr/bin/menu
ok "Comandos 'kraker' y 'menu' disponibles"

# ---------- 6. Firewall: el 22 SIEMPRE primero ----------
echo -e "\n${YELLOW}[*] Protegiendo el acceso SSH...${NC}"
if command -v ufw > /dev/null 2>&1; then
    ufw allow 22/tcp > /dev/null 2>&1
    ufw allow OpenSSH > /dev/null 2>&1
    ok "Puerto 22 permitido en UFW (aunque UFW esté inactivo, no habrá bloqueo)"
else
    info "UFW no instalado (opcional)"
fi

# ---------- 7. Verificación ----------
echo -e "\n${YELLOW}[*] Verificando instalación...${NC}"
ERRS=0
for f in utils.sh KRAKER_SSL.sh KRAKER_SSL_Gateway.py KRAKER_Dropbear.sh KRAKER_UDP.sh KRAKER_Firewall.sh KRAKER_Gaming.sh KRAKER_PingMonitor.sh; do
    [[ -f "$REPO_DIR/scripts/$f" ]] || { err "Falta scripts/$f"; ERRS=$((ERRS+1)); }
done
[[ $ERRS -eq 0 ]] && ok "Los 8 módulos clave están presentes"

python3 -m py_compile "$REPO_DIR/scripts/KRAKER_SSL_Gateway.py" 2>/dev/null \
    && ok "Gateway de Python compila correctamente" \
    || warn "El gateway de Python no compiló (revisa python3)"
rm -rf "$REPO_DIR/scripts/__pycache__" 2>/dev/null

systemctl daemon-reload 2>/dev/null

# ---------- 8. Resumen ----------
echo -e "\n${CYAN}======================================================${NC}"
echo -e "${GREEN}   INSTALACIÓN COMPLETADA${NC}"
echo -e "${CYAN}======================================================${NC}"
echo -e "  Panel        : ${CYAN}kraker${NC}  (o ${CYAN}menu${NC})"
echo -e "  Directorio   : $REPO_DIR"
echo -e "  Log          : ${GRAY}$REPO_DIR/AUDITORIA_KRAKER.md${NC}"
echo
echo -e "  ${YELLOW}ORDEN RECOMENDADO LA PRIMERA VEZ:${NC}"
echo -e "   ${GRAY}1)${NC} ${CYAN}[10]${NC} Dropbear Manager   ${GRAY}(el destino del túnel)${NC}"
echo -e "   ${GRAY}2)${NC} ${CYAN}[17]${NC} Abrir Puertos"
echo -e "   ${GRAY}3)${NC} ${CYAN}[03]${NC} SSL Gateway        ${GRAY}(elige modo PYTHON si hay clientes mixtos)${NC}"
echo -e "   ${GRAY}4)${NC} ${CYAN}[08]${NC} UDP Gaming         ${GRAY}(BadVPN, para Free Fire)${NC}"
echo -e "   ${GRAY}5)${NC} ${CYAN}[18]${NC} Tuner Gaming       ${GRAY}(BBR + fq_codel)${NC}"
echo
echo -e "  ${YELLOW}Comprobar que los puertos escuchan de verdad:${NC}"
echo -e "   ${GRAY}ss -ntl | grep -E ':(22|80|143|442|443|7100|7200|7300) '${NC}"
echo -e "${CYAN}======================================================${NC}"

# ---------- 9. Abrir el panel (solo si hay terminal real) ----------
if [[ $ASSUME_YES -eq 0 && -t 0 && -t 1 ]]; then
    echo -en "\n  ¿Abrir el panel ahora? (s/n): "
    read -r R
    [[ "${R,,}" == "s" ]] && exec "$REPO_DIR/menu.sh"
fi
echo
