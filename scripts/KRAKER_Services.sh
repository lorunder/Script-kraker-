#!/bin/bash
# KRAKER MASTER - Service Manager Utility  [VERSIÓN CORREGIDA]
# Cambios:
#  1) "DETENER SERVICIO" hacía  fuser -k 443/tcp 80/tcp 442/tcp 8080/tcp  -> mataba
#     TAMBIÉN los demás protocolos que compartían esos puertos (Xray, Stunnel,
#     Dropbear...). Eso es lo que hacía que "se cerraran puertos" que no tocabas.
#  2) "INICIAR" hacía  pkill -9 -f "$service"  -> el patrón podía coincidir con
#     otros procesos y mataba de más. Ahora solo se usa systemctl.
#  3) Se muestra el estado real leyendo puertos (ss) además de systemd.

SOURCE_DIR=$(dirname "$(readlink -f "$0")")
[[ -f "$SOURCE_DIR/utils.sh" ]] && source "$SOURCE_DIR/utils.sh" || exit 1

SERVICES=("xray" "hysteria-server" "kraker-udp" "kraker-dns" "stunnel4" "dropbear")
LABELS=("Xray (Reality/VMess/Trojan)" "Hysteria v2 (UDP)" "BadVPN UDP Gaming (7100-7300 TCP)" "SlowDNS (UDP 53)" "SSL Gateway (Stunnel 443)" "SSH Dropbear (80/143/442)")
TYPES=("systemd" "systemd" "systemd" "systemd" "systemd" "systemd")
PORTS=("443" "443" "7100 7200 7300" "53" "443" "80 143 442")

# Estado combinado: unidad systemd + puerto escuchando
svc_status() {
    local name=$1 ports=$2
    local unit_state port_state=""
    if systemctl list-unit-files "${name}.service" > /dev/null 2>&1 && systemctl cat "$name" > /dev/null 2>&1; then
        unit_state=$(systemctl is-active "$name" 2>/dev/null)
    else
        unit_state="no-existe"
    fi
    for p in $ports; do
        if ss -ntl 2>/dev/null | grep -q ":$p " || ss -nul 2>/dev/null | grep -q ":$p "; then
            port_state+="$p "
        fi
    done

    case "$unit_state" in
        active)   echo -e "${GREEN}[ACTIVO]${NC} ${GRAY}puertos: ${port_state:-ninguno}${NC}" ;;
        failed)   echo -e "${RED}[FALLÓ]${NC} ${GRAY}${port_state:+puertos: $port_state}${NC}" ;;
        no-existe) echo -e "${RED}[NO INSTALADO]${NC}" ;;
        *)        echo -e "${YELLOW}[$unit_state]${NC} ${GRAY}${port_state:+puertos: $port_state}${NC}" ;;
    esac
}

service_diag() {
    local name=$1
    echo -e "${BARRA}"
    echo -e "  ${YELLOW}Últimas líneas del log de $name:${NC}"
    journalctl -u "$name" -n 8 --no-pager 2>/dev/null | sed 's/^/    /' || \
        echo -e "    ${GRAY}(sin journal disponible)${NC}"
    echo -e "${BARRA}"
}

manage_service() {
    local service=$1 label=$2 ports=$3
    while true; do
        clear
        msg_banner
        msg_header "GESTIONANDO: $label"
        echo -e "Estado: $(svc_status "$service" "$ports")"
        echo -e "${BARRA}"
        echo -e " Estado: $(svc_status "$service" "$ports")"
        echo -e "  ${YELLOW}[1]${NC} INICIAR SERVICIO"
        echo -e "  ${YELLOW}[2]${NC} DETENER SERVICIO (solo este)"
        echo -e "  ${YELLOW}[3]${NC} REINICIAR SERVICIO"
        echo -e "  ${YELLOW}[4]${NC} VER LOG / DIAGNÓSTICO"
        echo -e "  ${YELLOW}[0]${NC} VOLVER"
        echo -e "${BARRA}"
        echo -en "Seleccione una acción: "
        read -r cmd

        case $cmd in
            1)
                systemctl start "$service" 2>&1 | sed 's/^/  /'
                sleep 1
                echo -e "  -> $(svc_status "$service" "$ports")"
                [[ $(systemctl is-active "$service" 2>/dev/null) != "active" ]] && service_diag "$service"
                ;;
            2)
                # FIX: se eliminó "fuser -k <puertos compartidos>" y "pkill -9 -f"
                systemctl stop "$service" 2>&1 | sed 's/^/  /'
                ;;
            3)
                systemctl restart "$service" 2>&1 | sed 's/^/  /'
                sleep 1
                echo -e "  -> $(svc_status "$service" "$ports")"
                [[ $(systemctl is-active "$service" 2>/dev/null) != "active" ]] && service_diag "$service"
                ;;
            4) service_diag "$service" ;;
            0) return 0 ;;
        esac
        echo -e "${YELLOW}Presiona ENTER para continuar...${NC}"
        read -r
    done
}

main_service_menu() {
    clear
    msg_banner
    msg_header "GESTOR DE SERVICIOS KRAKER (CORREGIDO)"
    echo -e "Estado real de cada protocolo:"
    echo -e "${BARRA}"
    for i in "${!SERVICES[@]}"; do
        printf "  ${YELLOW}[%02d]${NC} %-34s %b\n" $((i+1)) "${LABELS[$i]}" "$(svc_status "${SERVICES[$i]}" "${PORTS[$i]}")"
    done
    echo -e "${BARRA}"
    echo -e "  ${YELLOW}[00]${NC} VOLVER AL MENU PRINCIPAL"
    echo -e "${BARRA}"
    echo -en "Opción: "
    read -r opt

    [[ $opt == "0" || $opt == "00" ]] && return 1

    index=$((opt - 1))
    if [[ $index -ge 0 && $index -lt ${#SERVICES[@]} ]]; then
        manage_service "${SERVICES[$index]}" "${LABELS[$index]}" "${PORTS[$index]}"
    else
        echo -e "${RED}Opción inválida!${NC}"
        sleep 1
    fi
    return 0
}

while main_service_menu; do :; done
