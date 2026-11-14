#!/bin/bash
# KRAKER MASTER - UDP GAMING (BadVPN)  [VERSIÓN CORREGIDA]
# Cambios respecto al original:
#  1) BadVPN escucha por TCP (udpgw = UDP-sobre-TCP). El panel lo buscaba en UDP y lo
#     reportaba como "DETENIDO" aunque estuviera corriendo.
#  2) Se valida que el binario sea un ELF real y que ejecute --version (antes se daba
#     por bueno cualquier archivo >0 bytes, incluida una página HTML de error 404).
#  3) Se quita Nice=-20 + CPUSchedulingPolicy=fifo: en VPS OpenVZ/LXC el kernel lo
#     deniega y systemd deja la unidad en failed -> el puerto nunca abre.
#  4) Se abre el rango 7100-7300 en TCP y UDP en el firewall, y se garantiza el 22.
#  5) Verificación final real con ss -ntl (no con "systemctl is-active" ciego).

SOURCE_DIR=$(dirname "$(readlink -f "$0")")
[[ -f "$SOURCE_DIR/utils.sh" ]] && source "$SOURCE_DIR/utils.sh" || exit 1

PORTS="7100 7200 7300"

# 1. Optimización Kernel
tune_network() {
    msg_header "CARGANDO MÓDULOS DE BAJA LATENCIA"
    echo -e "${YELLOW}[*] Optimizando Stack de Red para Ping Mínimo...${NC}"

    cat << 'EOF' > /etc/sysctl.d/99-kraker-gaming.conf
# Buffers de red optimizados para Gaming UDP
net.core.rmem_default = 524288
net.core.rmem_max = 2097152
net.core.wmem_default = 524288
net.core.wmem_max = 2097152
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_fin_timeout = 15
# NOTA: net.ipv4.tcp_low_latency fue ELIMINADO del kernel en 4.12;
# dejarlo solo generaba errores silenciosos en "sysctl --system".
# El qdisc se deja en manos de /etc/sysctl.conf (fq + BBR) para no pelear con él.
EOF
    sysctl -p /etc/sysctl.d/99-kraker-gaming.conf > /dev/null 2>&1
    echo -e "${GREEN}[✔] Kernel tuneado para Gaming.${NC}"
}

# 2. Instalación BadVPN
badvpn_ok() {
    # Un binario válido: existe, es ejecutable, es ELF y responde a --version
    [[ -x "$1" ]] || return 1
    head -c4 "$1" 2>/dev/null | grep -q $'\x7fELF' || return 1
    "$1" --version 2>&1 | grep -qi "badvpn" || return 1
    return 0
}

install_badvpn() {
    msg_header "INSTALANDO BADVPN UDPGW"

    for cand in /usr/bin/badvpn-udpgw /usr/local/bin/badvpn-udpgw; do
        if [[ -f "$cand" ]] && ! badvpn_ok "$cand"; then
            echo -e "${YELLOW}[!] Binario inválido en $cand (corrupto / HTML / 0 bytes). Eliminando...${NC}"
            rm -f "$cand"
        fi
    done

    if badvpn_ok /usr/bin/badvpn-udpgw || badvpn_ok /usr/local/bin/badvpn-udpgw; then
        echo -e "${GREEN}[✔] BadVPN ya está instalado y verificado.${NC}"
        [[ -x /usr/bin/badvpn-udpgw ]] || ln -sf /usr/local/bin/badvpn-udpgw /usr/bin/badvpn-udpgw
        return
    fi

    echo -e "${YELLOW}[*] Instalando dependencias...${NC}"
    apt-get update -y > /dev/null 2>&1
    apt-get install -y cmake build-essential wget tar libssl-dev pkg-config > /dev/null 2>&1

    echo -e "${YELLOW}[*] Compilando BadVPN (garantiza compatibilidad con tu kernel)...${NC}"
    rm -rf /tmp/badvpn-build && mkdir -p /tmp/badvpn-build && cd /tmp/badvpn-build || return 1
    if wget -q https://github.com/ambrop72/badvpn/archive/1.999.130.tar.gz; then
        tar xzf 1.999.130.tar.gz
        cd badvpn-1.999.130 || return 1
        mkdir -p build && cd build || return 1
        cmake .. -DBUILD_NOTHING_BY_DEFAULT=1 -DBUILD_UDPGW=1 \
                 -DCMAKE_C_FLAGS="-Wno-error" -DCMAKE_CXX_FLAGS="-Wno-error" > /dev/null 2>&1
        make -j"$(nproc)" > /dev/null 2>&1 && make install > /dev/null 2>&1
        if badvpn_ok /usr/local/bin/badvpn-udpgw; then
            ln -sf /usr/local/bin/badvpn-udpgw /usr/bin/badvpn-udpgw
            echo -e "${GREEN}[✔] BadVPN compilado con éxito.${NC}"
            cd / || true
            return
        fi
    fi

    echo -e "${RED}[!] Falló la compilación. Probando binario estático de emergencia...${NC}"
    rm -f /usr/bin/badvpn-udpgw
    wget -q -O /usr/bin/badvpn-udpgw "https://github.com/itxtutor/badvpn/raw/master/badvpn-udpgw-x86_64" 2>/dev/null
    chmod +x /usr/bin/badvpn-udpgw 2>/dev/null

    # FIX: antes bastaba con que el archivo pesara >0 bytes (un HTML 404 pasaba el filtro)
    if ! badvpn_ok /usr/bin/badvpn-udpgw; then
        echo -e "${RED}[!!!] ERROR: no se obtuvo un binario válido de BadVPN.${NC}"
        echo -e "${YELLOW}[!] Instálalo a mano:  apt install -y git && git clone https://github.com/ambrop72/badvpn && compila udpgw${NC}"
        exit 1
    fi
    cd / || true
}

# 3. Servicio systemd
create_service() {
    msg_header "ACTIVANDO SERVICIO UDP MASTER"
    cat << 'EOF' > /etc/systemd/system/kraker-udp.service
[Unit]
Description=KRAKER MASTER - UDP Gateway (BadVPN udpgw)
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=0

[Service]
Type=simple
User=root
# --client-socket-sndbuf: el valor por defecto de badvpn es 1 MB POR CONEXIÓN.
# Con 1 MB cada cliente puede acumular ~1 segundo de datos en cola antes de enviar,
# y eso se traduce en ping inestable (ráfagas + picos). 128 KB lo corta de raíz.
# Es el propio comentario del código fuente: "else our scheduling is pointless".
ExecStart=/usr/bin/badvpn-udpgw --listen-addr 0.0.0.0:7100 --listen-addr 0.0.0.0:7200 --listen-addr 0.0.0.0:7300 --max-clients 500 --client-socket-sndbuf 131072
Restart=always
RestartSec=3
StandardOutput=append:/var/log/kraker-udp.log
StandardError=append:/var/log/kraker-udp.log
LimitNOFILE=65535
# FIX: se eliminaron Nice=-20 y CPUSchedulingPolicy=fifo/99.
# En VPS con OpenVZ/LXC el kernel los deniega y systemd deja la unidad en failed,
# por lo que los puertos NUNCA se abrían aunque el panel dijera que sí.

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable kraker-udp > /dev/null 2>&1
    systemctl restart kraker-udp
    sleep 2
}

# 4. Firewall (siempre TCP + UDP, y nunca cerrar el 22)
open_firewall() {
    if command -v ufw > /dev/null 2>&1; then
        # CRÍTICO: sin esto, al activar ufw te quedas fuera del VPS
        ufw allow 22/tcp > /dev/null 2>&1
        ufw allow 7100:7300/tcp > /dev/null 2>&1
        ufw allow 7100:7300/udp > /dev/null 2>&1
        if ufw status 2>/dev/null | grep -qi "Status: active"; then
            echo -e "${GREEN}[✔] Reglas aplicadas en UFW (activo).${NC}"
        else
            echo -e "${YELLOW}[!] UFW está instalado pero INACTIVO. Las reglas no filtran nada${NC}"
            echo -e "${YELLOW}    (no hace falta activarlo; si lo activas, el 22 ya está permitido).${NC}"
        fi
    fi
    # iptables/nftables directos, por si no usas ufw
    if command -v iptables > /dev/null 2>&1; then
        for p in $PORTS; do
            iptables -C INPUT -p tcp --dport "$p" -j ACCEPT 2>/dev/null || \
                iptables -I INPUT -p tcp --dport "$p" -j ACCEPT 2>/dev/null
        done
    fi
}

# 5. Verificación REAL
verify() {
    msg_header "VERIFICACIÓN DE PUERTOS"
    local ok=0
    for p in $PORTS; do
        if ss -ntl 2>/dev/null | grep -q ":$p "; then
            echo -e "  ${GREEN}[✔] TCP $p ESCUCHANDO${NC}"
            ok=$((ok+1))
        else
            echo -e "  ${RED}[✘] TCP $p NO escucha${NC}"
        fi
    done
    if [[ $ok -eq 0 ]]; then
        echo -e "${RED}[!] El servicio no está escuchando. Últimas líneas del log:${NC}"
        tail -n 15 /var/log/kraker-udp.log 2>/dev/null
        echo -e "${YELLOW}[!] Diagnóstico rápido:${NC}"
        echo -e "    systemctl status kraker-udp --no-pager"
        echo -e "    journalctl -u kraker-udp -n 30 --no-pager"
    else
        echo -e "${GREEN}[✔] BadVPN activo en ${ok}/3 puertos.${NC}"
        echo -e "${CYAN}Recuerda: BadVPN es UDP-sobre-TCP, se conecta por TCP 7100/7200/7300.${NC}"
    fi
}

msg_header "UDP GAMING OPTIMIZER (CORREGIDO)"
tune_network
install_badvpn
create_service
open_firewall
verify

echo -e "${YELLOW}[!] Si desde fuera sigue sin conectar, revisa el Firewall del proveedor${NC}"
echo -e "${YELLOW}    (Security Group de AWS / Firewall de Hetzner / OVH / Vultr).${NC}"
echo -e "${BARRA}"
