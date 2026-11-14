#!/bin/bash
# KRAKER MASTER - SSL GATEWAY MANAGER  [VERSIÓN CORREGIDA]
#
# Bugs corregidos respecto al original:
#  1) El "Gateway Nativo" (Python) estaba COMENTADO: las opciones 03 y 04 del menú
#     hacían exactamente lo mismo (solo Stunnel). Ahora puedes elegir de verdad.
#  2) NO existía ninguna unidad systemd: stunnel se lanzaba a mano, así que al
#     reiniciar el VPS el 443 no volvía. Ahora hay unidades reales con Restart=always.
#  3) openssl REGENERABA el certificado autofirmado en cada ejecución, MACHACANDO
#     el certificado real de Let's Encrypt de /etc/ws_ssl. Ahora solo se genera si
#     no existe, y nunca se sobrescribe uno válido.
#  4) Hacía "systemctl stop apache2 nginx xray stunnel4" a lo bruto. Ahora solo se
#     libera el 443 diciendo quién lo ocupaba, sin tocar Dropbear ni el 80.
#  5) No se abría el 443 en el firewall. Ahora sí (y se recuerda el 22).
#  6) Verifica que el DESTINO (Dropbear) esté vivo: si no, el cliente conecta y se
#     cae al instante, que es justo el síntoma de "se desconecta".

SOURCE_DIR=$(dirname "$(readlink -f "$0")")
[[ -f "$SOURCE_DIR/utils.sh" ]] && source "$SOURCE_DIR/utils.sh" || exit 1

CERT=/etc/ws_ssl/server.crt
KEY=/etc/ws_ssl/server.key
STUNNEL_CONF=/etc/stunnel/kraker.conf
PY_SCRIPT="$SOURCE_DIR/KRAKER_SSL_Gateway.py"

# ---------- utilidades ----------
detect_target() {
    # Puerto real donde escucha SSH/Dropbear
    for p in 80 143 442 22; do
        if ss -ntl 2>/dev/null | grep -q ":$p "; then
            echo "$p"; return 0
        fi
    done
    return 1
}

who_has_443() {
    ss -ntlp 2>/dev/null | awk '/:443 /{print $NF}' | head -1
}

ensure_cert() {
    mkdir -p /etc/ws_ssl
    if [[ -s "$CERT" && -s "$KEY" ]]; then
        local exp subj
        exp=$(openssl x509 -enddate -noout -in "$CERT" 2>/dev/null | cut -d= -f2)
        subj=$(openssl x509 -subject -noout -in "$CERT" 2>/dev/null | sed 's/.*CN *= *//')
        echo -e "${GREEN}[✔] Certificado existente conservado (CN=$subj, expira: $exp).${NC}"
        # Aviso si es autofirmado y caduca pronto
        if openssl x509 -noout -issuer -subject -in "$CERT" 2>/dev/null | \
           awk -F'=' 'NR==1{i=$2} NR==2{s=$2} END{exit (i==s)?0:1}'; then
            echo -e "${YELLOW}[!] Es AUTOFIRMADO: los clientes deben usar 'insecure/allow all'.${NC}"
            echo -e "${YELLOW}    Para quitar el aviso, emite uno real en Sistema > Dominio (ACME).${NC}"
        fi
        return
    fi
    local ip
    ip=$(get_ip); [[ -z $ip ]] && ip="kraker.local"
    echo -e "${YELLOW}[*] Generando certificado autofirmado (CN=$ip)...${NC}"
    openssl req -x509 -nodes -newkey rsa:2048 -keyout "$KEY" -out "$CERT" \
        -subj "/CN=$ip" -days 3650 2>/dev/null
}

write_units() {
    # --- Unidad del GATEWAY PYTHON ---
    cat > /etc/systemd/system/kraker-gateway.service <<EOF
[Unit]
Description=KRAKER MASTER - SSL Gateway (Python)
After=network-online.target
Wants=network-online.target
Conflicts=kraker-ssl.service
StartLimitIntervalSec=0

[Service]
Type=simple
User=root
Environment=KRAKER_MAX_CONNS=800
Environment=KRAKER_ALLOW_OLD_TLS=1
ExecStart=/usr/bin/python3 $PY_SCRIPT 443 $CERT $KEY 127.0.0.1 $1
Restart=always
RestartSec=3
LimitNOFILE=65535
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

    # --- Unidad de STUNNEL (nativa, más rápida) ---
    cat > /etc/systemd/system/kraker-ssl.service <<EOF
[Unit]
Description=KRAKER MASTER - SSL Gateway (Stunnel)
After=network-online.target
Wants=network-online.target
Conflicts=kraker-gateway.service
StartLimitIntervalSec=0

[Service]
Type=simple
User=root
ExecStart=/usr/bin/stunnel4 $STUNNEL_CONF
Restart=always
RestartSec=3
LimitNOFILE=65535
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
}

stop_all() {
    systemctl stop kraker-gateway kraker-ssl > /dev/null 2>&1
    systemctl disable kraker-gateway kraker-ssl > /dev/null 2>&1
    # Instancias manuales antiguas (las que lanzaba el panel a mano)
    if [[ -f /var/run/stunnel-kraker.pid ]]; then
        kill "$(cat /var/run/stunnel-kraker.pid)" 2>/dev/null
        rm -f /var/run/stunnel-kraker.pid
    fi
    pkill -f "KRAKER_SSL_Gateway.py" 2>/dev/null
}

open_fw() {
    if command -v ufw > /dev/null 2>&1; then
        ufw allow 22/tcp > /dev/null 2>&1
        ufw allow 443/tcp > /dev/null 2>&1
        ufw status 2>/dev/null | grep -qi "Status: active" || \
            echo -e "${YELLOW}[!] UFW inactivo: el 443 está abierto sin filtro local.${NC}"
    fi
    iptables -C INPUT -p tcp --dport 443 -j ACCEPT 2>/dev/null || \
        iptables -I INPUT -p tcp --dport 443 -j ACCEPT 2>/dev/null
}

verify_443() {
    echo -e "${BARRA}"
    if ss -ntl 2>/dev/null | grep -q ":443 "; then
        echo -e "${GREEN}[✔] Puerto 443 ESCUCHANDO${NC}"
        ss -ntlp 2>/dev/null | grep ":443 " | sed 's/^/    /'
        local t
        t=$(detect_target)
        if [[ -n "$t" ]]; then
            echo -e "${GREEN}[✔] Destino interno (SSH/Dropbear) vivo en :$t${NC}"
            echo -e "${CYAN}    -> El túnel debe conectar: SOLO TLS en 443, sin SNI obligatorio.${NC}"
        else
            echo -e "${RED}[✘] No hay ningún SSH/Dropbear escuchando: el 443 abrirá y CERRARÁ al instante.${NC}"
            echo -e "${YELLOW}    Arréglalo primero con: Opción 10 (Dropbear Manager)${NC}"
        fi
        # Prueba TLS real
        if command -v openssl > /dev/null 2>&1; then
            if echo | timeout 5 openssl s_client -connect 127.0.0.1:443 -quiet > /dev/null 2>&1; then
                echo -e "${GREEN}[✔] Handshake TLS correcto en 127.0.0.1:443${NC}"
            else
                echo -e "${YELLOW}[~] Handshake TLS no completó (normal si el destino espera SSH primero)${NC}"
            fi
        fi
    else
        echo -e "${RED}[✘] NADA escuchando en 443.${NC}"
        echo -e "${YELLOW}    Logs:${NC}"
        journalctl -u kraker-ssl -u kraker-gateway -n 20 --no-pager 2>/dev/null | sed 's/^/    /'
    fi
    echo -e "${BARRA}"
}

# ---------- arranque de modos ----------
start_stunnel() {
    msg_header "SSL GATEWAY - MODO STUNNEL (NATIVO)"
    local TARGET_PORT
    TARGET_PORT=$(detect_target) || {
        echo -e "${RED}[!] No hay SSH/Dropbear activo. Instálalo primero (opción 10).${NC}"
        sleep 3; return
    }
    echo -e "${GREEN}[✔] Destino detectado: 127.0.0.1:$TARGET_PORT${NC}"

    local ocupado
    ocupado=$(who_has_443)
    if [[ -n "$ocupado" ]]; then
        echo -e "${YELLOW}[!] El 443 lo está usando: $ocupado${NC}"
        echo -e "${YELLOW}    Se detendrá para liberar el puerto.${NC}"
        read -r -p "    ¿Continuar? (s/n): " R
        [[ "${R,,}" != "s" ]] && return
    fi
    stop_all
    fuser -k 443/tcp > /dev/null 2>&1
    sleep 1

    ensure_cert

    mkdir -p /etc/stunnel
    cat > "$STUNNEL_CONF" <<EOF
# KRAKER MASTER - Stunnel SSL Gateway
foreground = yes
pid = /var/run/stunnel-kraker.pid
cert = $CERT
key = $KEY
client = no
sslVersion = all
options = NO_SSLv2
options = NO_SSLv3
socket = a:SO_REUSEADDR=1
socket = l:TCP_NODELAY=1
socket = r:TCP_NODELAY=1
debug = 4
output = /var/log/kraker-stunnel.log

[kraker_ssl]
accept = 443
connect = 127.0.0.1:$TARGET_PORT
EOF

    write_units "$TARGET_PORT"
    systemctl enable kraker-ssl > /dev/null 2>&1
    systemctl restart kraker-ssl
    sleep 2
    open_fw
    verify_443
    echo -e "${CYAN}Modo activo: STUNNEL (nativo, el más rápido para SSL Tunnel).${NC}"
    echo -e "${YELLOW}Log: journalctl -u kraker-ssl -f   ó   tail -f /var/log/kraker-stunnel.log${NC}"
}

start_gateway() {
    msg_header "SSL GATEWAY - MODO PYTHON (WS + DIRECT)"
    local TARGET_PORT
    TARGET_PORT=$(detect_target) || {
        echo -e "${RED}[!] No hay SSH/Dropbear activo. Instálalo primero (opción 10).${NC}"
        sleep 3; return
    }
    echo -e "${GREEN}[✔] Destino detectado: 127.0.0.1:$TARGET_PORT${NC}"

    local ocupado
    ocupado=$(who_has_443)
    if [[ -n "$ocupado" ]]; then
        echo -e "${YELLOW}[!] El 443 lo está usando: $ocupado${NC}"
        read -r -p "    ¿Detenerlo para liberar el puerto? (s/n): " R
        [[ "${R,,}" != "s" ]] && return
    fi
    stop_all
    fuser -k 443/tcp > /dev/null 2>&1
    sleep 1

    ensure_cert
    [[ -f "$PY_SCRIPT" ]] || { echo -e "${RED}[!] Falta $PY_SCRIPT${NC}"; sleep 3; return; }

    write_units "$TARGET_PORT"
    systemctl enable kraker-gateway > /dev/null 2>&1
    systemctl restart kraker-gateway
    sleep 2
    open_fw
    verify_443
    echo -e "${CYAN}Modo activo: PYTHON GATEWAY.${NC}"
    echo -e "${CYAN}  Detecta automáticamente en el mismo puerto 443:${NC}"
    echo -e "${CYAN}   - 'GET / HTTP/1.1...'  -> responde 101 y quita las cabeceras (payload WS)${NC}"
    echo -e "${CYAN}   - 'SSH-2.0-...' o mudo -> passthrough SSL puro${NC}"
    echo -e "${YELLOW}Log: journalctl -u kraker-gateway -f${NC}"
}

# ---------- menú ----------
install_deps screen openssl net-tools psmisc python3 stunnel4 > /dev/null 2>&1

while true; do
    msg_header "SSL GATEWAY MANAGER (CORREGIDO)"
    local_state=""
    if systemctl is-active kraker-gateway > /dev/null 2>&1; then local_state="${GREEN}PYTHON GATEWAY activo${NC}"
    elif systemctl is-active kraker-ssl > /dev/null 2>&1; then local_state="${GREEN}STUNNEL activo${NC}"
    elif ss -ntl 2>/dev/null | grep -q ":443 "; then local_state="${YELLOW}443 ocupado por proceso manual${NC}"
    else local_state="${RED}443 cerrado${NC}"; fi

    echo -e "  Estado: $local_state"
    echo -e "  Puerto 443: $(ss -ntl 2>/dev/null | grep -q ':443 ' && echo -e "${GREEN}ESCUCHANDO${NC}" || echo -e "${RED}CERRADO${NC}")"
    echo -e "${BARRA}"
    echo -e "  ${YELLOW}[1]${NC} STUNNEL  ${GRAY}(SOLO SSL puro — si TODOS tus clientes usan SSL Tunnel)${NC}"
    echo -e "  ${YELLOW}[2]${NC} PYTHON   ${GREEN}<< RECOMENDADO si hay clientes MIXTOS${NC}"
    echo -e "      ${GRAY}acepta en el MISMO 443: SSL puro  y  payload WebSocket/HTTP${NC}"
    echo -e "  ${YELLOW}[3]${NC} DETENER TODO (liberar 443)"
    echo -e "  ${YELLOW}[4]${NC} VER ESTADO Y LOGS"
    echo -e "  ${YELLOW}[5]${NC} REGENERAR CERTIFICADO AUTOFIRMADO"
    echo -e "  ${YELLOW}[0]${NC} VOLVER"
    echo -e "${BARRA}"
    echo -en "  Opción: "
    read -r OPC
    case $OPC in
        1) start_stunnel ;;
        2) start_gateway ;;
        3) stop_all; echo -e "${GREEN}[✔] 443 liberado.${NC}"; sleep 2 ;;
        4) verify_443; journalctl -u kraker-ssl -u kraker-gateway -n 25 --no-pager 2>/dev/null | sed 's/^/    /'; read -r -p "ENTER..." _ ;;
        5) rm -f "$CERT" "$KEY"; ensure_cert; echo -e "${GREEN}[✔] Certificado regenerado. Reinicia el modo para aplicarlo.${NC}"; sleep 2 ;;
        0) break ;;
    esac
done
