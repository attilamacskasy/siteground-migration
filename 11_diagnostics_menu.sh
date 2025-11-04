#!/usr/bin/env bash
# WordPress diagnostics menu for cloudmigration.blog

set -Eeuo pipefail
shopt -s lastpipe

DOMAIN="${DOMAIN:-cloudmigration.blog}"
VHOST_LOG_DIR="/var/log/apache2"
ACCESS_CANDIDATES=(
  "${VHOST_LOG_DIR}/${DOMAIN}-access.log"
  "${VHOST_LOG_DIR}/access.log"
)
ERROR_CANDIDATES=(
  "${VHOST_LOG_DIR}/${DOMAIN}-error.log"
  "${VHOST_LOG_DIR}/error.log"
)

RED=$'\e[31m'; GRN=$'\e[32m'; BLU=$'\e[34m'; YLW=$'\e[33m'; CLR=$'\e[0m'

need() { command -v "$1" >/dev/null 2>&1 || { echo "${RED}[ERR]${CLR} Missing: $1"; exit 1; }; }
need awk; need sed; need tail; need grep; need ss; need curl
command -v mysql >/dev/null 2>&1 || echo "${YLW}[WARN]${CLR} 'mysql' client not found; MySQL menu will be limited."

ACCESS_LOG=""; for f in "${ACCESS_CANDIDATES[@]}"; do [[ -f "$f" ]] && ACCESS_LOG="$f" && break; done
ERROR_LOG="";  for f in "${ERROR_CANDIDATES[@]}";  do [[ -f "$f" ]] && ERROR_LOG="$f"  && break; done

pause(){ read -rp $'\nPress ENTER to return to menu… '; }
header(){ clear; printf "${BLU}== %s ==${CLR}\n" "$1"; }

show_load(){
  header "Server Load & Health"
  echo -e "${GRN}Host:${CLR} $(hostname)    ${GRN}Uptime:${CLR} $(uptime -p)"
  echo -e "${GRN}Load:${CLR}  $(uptime | awk -F'load average: ' '{print $2}')"
  echo -e "${GRN}CPU:${CLR}   $(grep -m1 'model name' /proc/cpuinfo | cut -d: -f2- | sed 's/^ //')"
  echo -e "${GRN}Mem:${CLR}"; free -h
  echo; echo -e "${GRN}Disk usage:${CLR}"; df -hT | awk 'NR==1 || $2!="tmpfs"'
  echo; echo -e "${GRN}Listeners (80/443):${CLR}"
  ss -ltn '( sport = :80 or sport = :443 )' || true
  echo; echo -e "${GRN}Quick HTTPS check:${CLR}"
  { time -p curl -skI "https://${DOMAIN}" | sed 's/^/  /'; } 2>&1 | sed 's/^/  /'
  pause
}

tail_http_logs(){
  header "Tail Website HTTP Logs (${DOMAIN})"
  [[ -n "$ACCESS_LOG" ]] || echo "${YLW}[WARN]${CLR} Access log not found."
  [[ -n "$ERROR_LOG"  ]] || echo "${YLW}[WARN]${CLR} Error log not found."
  echo "1) Follow access log   (${ACCESS_LOG:-missing})"
  echo "2) Follow error log    (${ERROR_LOG:-missing})"
  echo "3) Follow both (prefixed)"
  echo "4) Show last 200 lines (both)"
  echo "0) Back"; echo
  read -rp "Choose: " c
  case "$c" in
    1) [[ -n "$ACCESS_LOG" ]] && tail -n 50 -F "$ACCESS_LOG" || echo "No access log." ;;
    2) [[ -n "$ERROR_LOG"  ]] && tail -n 50 -F "$ERROR_LOG"  || echo "No error log."  ;;
    3)
      [[ -n "$ACCESS_LOG" ]] && tail -n 10 -F "$ACCESS_LOG" | sed "s/^/[ACCESS] /" & P1=$!
      [[ -n "$ERROR_LOG"  ]] && tail -n 10 -F "$ERROR_LOG"  | sed "s/^/[ERROR ] /"  & P2=$!
      trap 'kill ${P1:-0} ${P2:-0} 2>/dev/null || true' INT TERM
      wait
      trap - INT TERM
      ;;
    4)
      [[ -n "$ACCESS_LOG" ]] && { echo "--- ACCESS (last 200) ---"; tail -n 200 "$ACCESS_LOG"; echo; }
      [[ -n "$ERROR_LOG"  ]] && { echo "--- ERROR  (last 200) ---"; tail -n 200 "$ERROR_LOG";  echo; }
      pause
      ;;
  esac
}

mysql_menu(){
  header "Monitor MySQL/MariaDB"
  if ! command -v mysql >/dev/null 2>&1; then
    echo "${YLW}[WARN]${CLR} mysql client not installed. Install with: sudo apt install mariadb-client"
    pause; return
  fi
  echo "1) Live processlist (refresh every 2s)"
  echo "2) InnoDB engine status (once)"
  echo "3) Key metrics snapshot (Threads, Connections, QPS)"
  echo "4) Tail slow query log (if enabled)"
  echo "5) Toggle GENERAL LOG (temp) + follow"
  echo "0) Back"; echo
  read -rp "Choose: " m
  case "$m" in
    1) header "SHOW FULL PROCESSLIST (Ctrl+C to exit)"
       while true; do
         mysql -e "SHOW FULL PROCESSLIST\G" | sed 's/^/  /'
         echo "---- $(date) ----"; sleep 2
       done ;;
    2) header "SHOW ENGINE INNODB STATUS"
       mysql -e "SHOW ENGINE INNODB STATUS\G" | less ;;
    3) header "Key Metrics Snapshot"
       mysql -e "
         SHOW VARIABLES LIKE 'version';
         SHOW GLOBAL STATUS WHERE Variable_name IN
           ('Threads_connected','Threads_running','Connections','Aborted_connects','Uptime','Questions','Queries','Slow_queries');
       " ; pause ;;
    4) header "Slow Query Log"
       SLOW_FILE=$(mysql -N -e "SHOW VARIABLES LIKE 'slow_query_log_file';" | awk '{print $2}')
       SLOW_ON=$(mysql -N -e "SHOW VARIABLES LIKE 'slow_query_log';" | awk '{print $2}')
       echo "slow_query_log         : $SLOW_ON"
       echo "slow_query_log_file    : ${SLOW_FILE:-unset}"
       if [[ "$SLOW_ON" == "ON" && -n "$SLOW_FILE" && -f "$SLOW_FILE" ]]; then
         tail -n 100 -F "$SLOW_FILE"
       else
         echo "${YLW}[WARN]${CLR} Slow log disabled or file missing."
         pause
       fi ;;
    5) header "GENERAL LOG (temporary)"
       TMP_GEN="/var/log/mysql/general-temp.log"
       echo "Enabling general_log to $TMP_GEN (Ctrl+C to stop & disable)…"
       mysql -e "SET GLOBAL general_log_file='${TMP_GEN}'; SET GLOBAL general_log=ON;"
       trap 'mysql -e "SET GLOBAL general_log=OFF;" >/dev/null 2>&1 || true' INT TERM
       tail -n 50 -F "$TMP_GEN"
       mysql -e "SET GLOBAL general_log=OFF;" || true
       echo "General log disabled."; pause ;;
  esac
}

more_tools(){
  header "Extras"
  echo "1) Service status (apache2, php-fpm*, mariadb)"
  echo "2) SSL cert info for ${DOMAIN}"
  echo "3) WP-CLI site health (basic)"
  echo "0) Back"; echo
  read -rp "Choose: " x
  case "$x" in
    1) systemctl --no-pager status apache2 mariadb php8.2-fpm php-fpm 2>/dev/null | sed 's/^/  /' || true; pause ;;
    2) echo | openssl s_client -connect "${DOMAIN}:443" -servername "${DOMAIN}" 2>/dev/null \
         | openssl x509 -noout -issuer -subject -dates -fingerprint -sha256; pause ;;
    3) if command -v wp >/dev/null 2>&1; then
         WP_PATH="/var/www/${DOMAIN}"; [[ -d "$WP_PATH/public_html" ]] && WP_PATH="$WP_PATH/public_html"
         echo "WP path: $WP_PATH"
         sudo -u www-data wp --path="$WP_PATH" core version
         sudo -u www-data wp --path="$WP_PATH" plugin status
       else
         echo "${YLW}[WARN]${CLR} wp-cli not installed."
       fi; pause ;;
  esac
}

while true; do
  header "CloudMigration.blog – Diagnostics Menu"
  echo "1) Show server load & health"
  echo "2) Tail website HTTP logs"
  echo "3) Monitor MySQL/MariaDB activity"
  echo "4) Extras"
  echo "q) Quit"; echo
  read -rp "Choose: " choice
  case "$choice" in
    1) show_load ;;
    2) tail_http_logs ;;
    3) mysql_menu ;;
    4) more_tools ;;
    q|Q) clear; exit 0 ;;
  esac
done
