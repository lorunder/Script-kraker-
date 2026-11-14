#!/bin/bash
# KRAKER MASTER - DIAGNÓSTICO (SOLO LECTURA)
# No modifica nada. Ejecuta en tu VPS como root:
#   bash diagnostico.sh > reporte.txt 2>&1
# y pásame el reporte.txt

R='\033[0;31m'; G='\033[0;32m'; Y='\033[1;33m'; C='\033[0;36m'; N='\033[0m'
sec() { echo; echo -e "${C}══════════════════════════════════════════════════════════════${N}"; echo -e "${C} $1${N}"; echo -e "${C}══════════════════════════════════════════════════════════════${N}"; }
ok()  { echo -e " ${G}[OK]${N} $1"; }
bad() { echo -e " ${R}[!!]${N} $1"; }
warn(){ echo -e " ${Y}[~]${N} $1"; }

[[ $EUID -ne 0 ]] && echo -e "${Y}AVISO: ejecuta como root para un diagnóstico completo.${N}"

sec "1. SISTEMA Y VIRTUALIZACIÓN"
echo "Sistema : $(cat /etc/os-release 2>/dev/null | grep PRETTY_NAME | cut -d'"' -f2)"
echo "Kernel  : $(uname -r)"
VIRT=$(systemd-detect-virt 2>/dev/null || echo desconocido)
echo "Virt    : $VIRT"
case "$VIRT" in
  openvz|lxc|lxc-libvirt) warn "Contenedor: Nice=-20 / CPUSchedulingPolicy=fifo se DENIEGAN -> el servicio kraker-udp puede quedar en 'failed' y no abrir puertos." ;;
esac

sec "2. PUERTOS ESCUCHANDO (esto es la verdad, no lo que dice el panel)"
echo "-- TCP --"; ss -ntlp 2>/dev/null | awk 'NR==1 || /LISTEN/'
echo "-- UDP --"; ss -nulp 2>/dev/null | awk 'NR==1 || /UNCONN/'
echo
echo "Puertos clave:"
for p in 22 80 143 442 443 7100 7200 7300; do
  if ss -ntl 2>/dev/null | grep -q ":$p "; then ok "TCP $p escuchando"
  elif ss -nul 2>/dev/null | grep -q ":$p "; then ok "UDP $p escuchando"
  else bad "puerto $p NO escucha"; fi
done

sec "3. SERVICIOS SYSTEMD"
for s in kraker-udp kraker-dns xray hysteria-server stunnel4 dropbear ssh fail2ban; do
  if systemctl cat "$s" > /dev/null 2>&1; then
    ST=$(systemctl is-active "$s" 2>/dev/null)
    EN=$(systemctl is-enabled "$s" 2>/dev/null)
    case "$ST" in
      active) ok "$s -> activo (enabled=$EN)" ;;
      *)      bad "$s -> $ST (enabled=$EN)" ;;
    esac
    systemctl status "$s" --no-pager -n 0 2>/dev/null | grep -E "Loaded|Active|Main PID" | sed 's/^/      /'
  else
    warn "$s no está instalado como unidad systemd"
  fi
done

sec "4. BADVPN (udpgw) - CAUSA MÁS PROBABLE DE 'NO FUNCIONA'"
if [[ -f /usr/bin/badvpn-udpgw || -f /usr/local/bin/badvpn-udpgw ]]; then
  BIN=$(command -v badvpn-udpgw || echo /usr/local/bin/badvpn-udpgw)
  echo "Binario : $BIN ($(stat -c%s "$BIN" 2>/dev/null) bytes)"
  if head -c4 "$BIN" 2>/dev/null | grep -q $'\x7fELF'; then
    ok "Es un ELF válido"
    "$BIN" --version 2>&1 | head -1 | sed 's/^/      /'
  else
    bad "NO es un binario ELF (probablemente se descargó una página HTML de error). Reinstala compilando."
  fi
  echo "Procesos:"; pgrep -ax badvpn-udpgw || warn "ningún proceso badvpn-udpgw corriendo"
  echo "Escuchando (BadVPN escucha por TCP, NO por UDP):"
  ss -ntlp 2>/dev/null | grep -E ":(7100|7200|7300) " || bad "no hay listeners en 7100/7200/7300"
  echo "Últimas líneas de log:"
  tail -n 15 /var/log/kraker-udp.log 2>/dev/null | sed 's/^/      /'
  journalctl -u kraker-udp -n 15 --no-pager 2>/dev/null | sed 's/^/      /'
  echo "Unidad systemd:"
  systemctl cat kraker-udp 2>/dev/null | grep -E "ExecStart|Nice|Scheduling" | sed 's/^/      /'
else
  bad "badvpn-udpgw no está instalado"
fi

sec "5. FIREWALL"
if command -v ufw > /dev/null 2>&1; then
  ufw status verbose 2>/dev/null | head -25
  if ufw status 2>/dev/null | grep -qi "Status: active"; then
    ok "UFW activo"
    ufw status 2>/dev/null | grep -q "22" || bad "¡UFW activo y el puerto 22 NO está permitido! Riesgo de perder el acceso."
  else
    warn "UFW instalado pero INACTIVO (los puertos están abiertos sin filtro local)"
  fi
else
  warn "UFW no instalado"
fi
echo "-- iptables INPUT --"
iptables -S INPUT 2>/dev/null | head -25 | sed 's/^/   /'
echo "-- nftables --"
nft list ruleset 2>/dev/null | head -30 | sed 's/^/   /' || warn "nft no disponible"

sec "6. CRONTAB (comprobación de DUPLICADOS)"
CRON=$(crontab -l 2>/dev/null)
if [[ -z "$CRON" ]]; then
  warn "crontab vacío"
else
  echo "$CRON" | sed 's/^/   /'
  DUP_RAM=$(echo "$CRON" | grep -c -- "--ram-clean")
  DUP_CPU=$(echo "$CRON" | grep -c -- "--cpu-clean")
  echo
  [[ $DUP_RAM -gt 1 ]] && bad "$DUP_RAM entradas '--ram-clean' DUPLICADAS (bug del panel: se añade una cada vez que abres el menú)" || ok "1 entrada --ram-clean"
  [[ $DUP_CPU -gt 1 ]] && bad "$DUP_CPU entradas '--cpu-clean' DUPLICADAS -> reinicios de dropbear/stunnel en cascada -> desconexiones" || ok "1 entrada --cpu-clean"
  echo "$CRON" | grep -q "/etc/kraker/scripts" && bad "cron apunta a /etc/kraker/scripts (esa ruta NO existe: limpieza de expirados rota)"
fi

sec "7. STUNNEL / PUERTO 443 (conflictos = puerto que 'se cierra')"
pgrep -ax stunnel4 || warn "stunnel4 no corre"
[[ -f /var/run/stunnel-kraker.pid ]] && echo "pidfile: $(cat /var/run/stunnel-kraker.pid)" || warn "sin pidfile /var/run/stunnel-kraker.pid"
systemctl is-active stunnel4 2>/dev/null | sed 's/^/systemd stunnel4: /'
ss -ntlp 2>/dev/null | grep ":443 " || warn "nada escuchando en 443"
grep -E "^(accept|connect|pid|cert)" /etc/stunnel/kraker.conf 2>/dev/null | sed 's/^/   /'

sec "8. XRAY / PROTOCOLOS"
if command -v xray > /dev/null 2>&1 || [[ -f /usr/local/bin/xray ]]; then
  ok "xray instalado: $(/usr/local/bin/xray version 2>/dev/null | head -1)"
  echo "Inbounds configurados:"
  grep -rhoE '"(protocol|port|listen)": *("[a-z0-9]+"|[0-9]+)' /usr/local/etc/xray/conf.d/*.json /usr/local/etc/xray/config.json 2>/dev/null | sed 's/^/   /'
  ls -la /usr/local/etc/xray/conf.d/ 2>/dev/null | sed 's/^/   /'
  [[ -s /usr/local/etc/xray/config.json ]] || warn "No hay config.json principal"
  systemctl is-active xray 2>/dev/null | sed 's/^/systemd xray: /'
else
  bad "Xray NO está instalado (el panel anuncia Reality/VMess/Trojan pero ningún script lo instala)"
fi
[[ -f /etc/hysteria/config.yaml ]] && ok "config de Hysteria existe" || warn "Hysteria no instalado (el menú lo lista igual)"

sec "9. FAIL2BAN (posible causa de cortes a clientes)"
if systemctl cat fail2ban > /dev/null 2>&1; then
  systemctl is-active fail2ban | sed 's/^/estado: /'
  fail2ban-client status 2>/dev/null | sed 's/^/   /'
  for j in sshd dropbear; do
    fail2ban-client status $j 2>/dev/null | grep -E "Banned|Total" | sed "s/^/   [$j] /"
  done
  echo "Reglas de baneo actuales:"
  iptables -S 2>/dev/null | grep -i "f2b" | head -10 | sed 's/^/   /'
else
  warn "fail2ban no instalado"
fi

sec "10. USUARIOS DEL PANEL (/bin/false rompe el login SSH)"
if [[ -f /etc/kraker_users.db ]]; then
  while IFS='|' read -r u p e uid limit; do
    [[ -z "$u" ]] && continue
    SH=$(getent passwd "$u" | cut -d: -f7)
    if [[ "$SH" == "/bin/false" || "$SH" == "/usr/sbin/nologin" ]]; then
      bad "$u tiene shell $SH -> NO puede iniciar sesión SSH/túnel"
    else
      ok "$u shell=$SH exp=$e"
    fi
  done < /etc/kraker_users.db
else
  warn "no existe /etc/kraker_users.db"
fi
echo
echo "Usuarios con shell válida en el sistema:"
awk -F: '$3>=1000 && $7!="/bin/false" && $7!="/usr/sbin/nologin" {print "   "$1" -> "$7}' /etc/passwd

sec "11. KERNEL / SYSCTL (conflictos del instalador)"
echo "qdisc actual : $(sysctl -n net.core.default_qdisc 2>/dev/null)"
echo "congestión   : $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)"
[[ -f /etc/sysctl.d/99-kraker-gaming.conf ]] && grep -E "qdisc|low_latency" /etc/sysctl.d/99-kraker-gaming.conf | sed 's/^/   99-gaming: /'
grep -E "qdisc|congestion|rmem|wmem|somaxconn" /etc/sysctl.conf 2>/dev/null | sed 's/^/   sysctl.conf: /'
sysctl net.ipv4.tcp_low_latency 2>/dev/null || warn "net.ipv4.tcp_low_latency no existe en este kernel (fue eliminado en Linux 4.12)"

sec "12. DROPBEAR CONFIG"
grep -vE '^\s*#|^\s*$' /etc/default/dropbear 2>/dev/null | sed 's/^/   /'
systemctl cat dropbear 2>/dev/null | grep -E "ExecStart" | sed 's/^/   /'

sec "13. RECURSOS"
echo "RAM   : $(free -m | awk '/Mem:/{print $3"/"$2" MB"}')"
echo "Disco : $(df -h / | awk 'NR==2{print $3"/"$2" ("$5")"}')"
echo "Carga : $(cat /proc/loadavg)"
echo "Top CPU:"; ps -eo pcpu,pmem,comm --sort=-pcpu 2>/dev/null | head -6 | sed 's/^/   /'

sec "FIN DEL DIAGNÓSTICO"
echo "Copia todo este texto y pásamelo para interpretarlo."
