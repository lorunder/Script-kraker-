#!/bin/bash
# KRAKER MASTER - GESTOR DE PUERTOS (NUEVO)
# El panel original NO tenía ningún módulo que abriera los puertos de forma global:
# cada instalador abría los suyos (y el 443 NUNCA se abría). Además nunca se permitía
# el puerto 22, con lo que activar ufw dejaba el VPS inaccesible.
# Este script abre todo lo que el panel necesita, en TCP y UDP, con el 22 protegido
# SIEMPRE primero.

SOURCE_DIR=$(dirname "$(readlink -f "$0")")
[[ -f "$SOURCE_DIR/utils.sh" ]] && source "$SOURCE_DIR/utils.sh" || exit 1

msg_header "GESTOR DE PUERTOS / FIREWALL"

if ! command -v ufw > /dev/null 2>&1; then
    echo -e "${YELLOW}[*] Instalando UFW...${NC}"
    apt-get install -y ufw > /dev/null 2>&1
fi

# Orden IMPORTANTE: 22 primero, siempre
PORTS_TCP=(22 80 143 442 443 2053 2083 2087 2096 4433 7100 7200 7300)
PORTS_UDP=(53 443 5300 7100 7200 7300)

echo -e "${YELLOW}[*] Permitiendo puerto 22 (SSH) antes que nada...${NC}"
ufw allow 22/tcp > /dev/null 2>&1

echo -e "${YELLOW}[*] Abriendo puertos TCP: ${PORTS_TCP[*]}${NC}"
for p in "${PORTS_TCP[@]}"; do
    ufw allow "$p/tcp" > /dev/null 2>&1
    # También en iptables por si ufw está inactivo y hay reglas sueltas
    iptables -C INPUT -p tcp --dport "$p" -j ACCEPT 2>/dev/null || \
        iptables -I INPUT -p tcp --dport "$p" -j ACCEPT 2>/dev/null
done

echo -e "${YELLOW}[*] Abriendo puertos UDP: ${PORTS_UDP[*]}${NC}"
for p in "${PORTS_UDP[@]}"; do
    ufw allow "$p/udp" > /dev/null 2>&1
    iptables -C INPUT -p udp --dport "$p" -j ACCEPT 2>/dev/null || \
        iptables -I INPUT -p udp --dport "$p" -j ACCEPT 2>/dev/null
done

echo -e "${GREEN}[✔] Reglas aplicadas.${NC}"
echo -e "${BARRA}"

if ufw status 2>/dev/null | grep -qi "Status: active"; then
    echo -e "${GREEN}[✔] UFW está ACTIVO y los puertos ya están permitidos.${NC}"
else
    echo -e "${YELLOW}[!] UFW está INACTIVO. Los puertos están abiertos (sin firewall local).${NC}"
    echo -e -n "    ¿Quieres activar UFW ahora? (el 22 ya está permitido) (s/n): "
    read -r R
    if [[ "${R,,}" == "s" ]]; then
        ufw --force enable
        echo -e "${GREEN}[✔] UFW activado.${NC}"
        echo -e "${YELLOW}[!] NO cierres esta sesión SSH todavía: abre otra ventana y comprueba${NC}"
        echo -e "${YELLOW}    que puedes entrar antes de desconectarte.${NC}"
    fi
fi

echo -e "${BARRA}"
echo -e "${YELLOW}[!] RECUERDA: el firewall del proveedor (AWS Security Group, Hetzner,${NC}"
echo -e "${YELLOW}    OVH, Vultr, Contabo) es INDEPENDIENTE. Si los puertos no abren desde${NC}"
echo -e "${YELLOW}    fuera pero aquí sí escuchan, el bloqueo está en el panel del hosting.${NC}"
echo -e "${BARRA}"
echo -e "${CYAN}Puertos que escuchan AHORA en este VPS:${NC}"
ss -ntl 2>/dev/null | awk 'NR>1 {print $4}' | grep -oE '[0-9]+$' | sort -n -u | tr '\n' ' '
echo
ss -nul 2>/dev/null | awk 'NR>1 {print $4}' | grep -oE '[0-9]+$' | sort -n -u | sed 's/^/UDP /' | tr '\n' ' '
echo
