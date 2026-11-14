#!/bin/bash
# KRAKER MASTER - DROPBEAR SSH (v2.2 CORREGIDO)
# Cambios:
#  1) Antes de nada se permite el puerto 22 en UFW. El original NUNCA abría el 22:
#     si activabas el firewall te quedabas fuera del VPS (los "puertos que se cierran").
#  2) "fuser -k 80/tcp" mataba silenciosamente lo que hubiera en el 80 (incluido
#     el propio túnel WS de otro protocolo). Ahora solo se avisa y se pregunta.
#  3) Se comprueba el resultado real con ss en vez de dar por hecho que quedó activo.

SOURCE_DIR=$(dirname "$(readlink -f "$0")")
[[ -f "$SOURCE_DIR/utils.sh" ]] && source "$SOURCE_DIR/utils.sh" || exit 1

msg_header "DROPBEAR SSH SETUP"
install_deps dropbear coreutils ufw lsof

# --- FIX CRÍTICO: proteger el acceso SSH ANTES de tocar nada ---
if command -v ufw > /dev/null 2>&1; then
    ufw allow 22/tcp > /dev/null 2>&1
    ufw allow OpenSSH > /dev/null 2>&1
    if ufw status 2>/dev/null | grep -qi "Status: active"; then
        echo -e "${GREEN}[✔] Puerto 22 asegurado en UFW (firewall activo).${NC}"
    else
        echo -e "${YELLOW}[!] UFW inactivo: tus puertos están abiertos de par en par ahora mismo.${NC}"
        echo -e "${YELLOW}    Si vas a activarlo, YA se añadió la regla del 22 para no perder el acceso.${NC}"
    fi
fi

# --- Puerto 80: ocupado por otro servicio? ---
if ss -ntl 2>/dev/null | grep -q ":80 "; then
    local_owner=$(ss -ntlp 2>/dev/null | awk '/:80 /{print $NF}' | head -1)
    echo -e "${YELLOW}[!] El puerto 80 ya está en uso por: ${local_owner:-desconocido}${NC}"
    echo -e "${YELLOW}    Si sigues, se detendrá (apache/nginx/otro túnel) y esos usuarios se desconectan.${NC}"
    read -r -p "    ¿Continuar? (s/n): " R
    [[ "${R,,}" != "s" ]] && echo -e "${RED}Cancelado.${NC}" && sleep 2 && exit 0
fi

systemctl stop apache2 nginx lighttpd > /dev/null 2>&1
fuser -k 80/tcp > /dev/null 2>&1

# Socket de Dropbear que causa conflictos en Ubuntu 24.04
systemctl stop dropbear.socket > /dev/null 2>&1
systemctl disable dropbear.socket > /dev/null 2>&1

# Configuración: 80 principal + 143 y 442 extra
cat << EOF > /etc/default/dropbear
# KRAKER MASTER - Dropbear Config
NO_START=0
DROPBEAR_PORT=80
DROPBEAR_EXTRA_ARGS="-p 143 -p 442"
DROPBEAR_BANNER="/etc/motd"
DROPBEAR_RECEIVE_WINDOW=65536
EOF

setup_motd
ufw allow 80/tcp  > /dev/null 2>&1
ufw allow 143/tcp > /dev/null 2>&1
ufw allow 442/tcp > /dev/null 2>&1

systemctl daemon-reload
systemctl enable dropbear > /dev/null 2>&1
systemctl restart dropbear > /dev/null 2>&1
sleep 2

msg_header "VERIFICACIÓN DROPBEAR"
ACTIVE=0
for p in 80 143 442; do
    if ss -ntl 2>/dev/null | grep -q ":$p "; then
        echo -e "  ${GREEN}[✔] Puerto $p ESCUCHANDO${NC}"
        ACTIVE=$((ACTIVE+1))
    else
        echo -e "  ${RED}[✘] Puerto $p NO escucha${NC}"
    fi
done

if [[ $ACTIVE -eq 0 ]]; then
    echo -e "${RED}[!] Dropbear no arrancó. Revisa:${NC}"
    echo -e "    systemctl status dropbear --no-pager"
    echo -e "    journalctl -u dropbear -n 30 --no-pager"
else
    echo -e "${GREEN}[✔] Dropbear activo en $ACTIVE/3 puertos.${NC}"
fi
echo -e "${YELLOW}[!] En VPS con firewall del proveedor (AWS/Hetzner/OVH/Vultr) abre también${NC}"
echo -e "${YELLOW}    80, 143 y 442 en el panel del proveedor.${NC}"
echo -e "${BARRA}"
