#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

DOMAIN="cloudmigration.blog"
EXPECTED_IP="46.139.14.94"
RESOLVERS=("8.8.8.8" "1.1.1.1" "9.9.9.9")
TIMEOUT_SEC=900         # 15 minutes max wait
INTERVAL_SEC=15
AUTO_RUN_CERT=${1:-""}  # pass --run-cert to auto-run 07_enable_lets_encrypt.sh

need(){ command -v "$1" >/dev/null 2>&1 || { echo "[ERR] missing: $1"; exit 2; }; }
say(){  echo -e "\e[34m[INFO]\e[0m  $*"; }
ok(){   echo -e "\e[32m[OK]\e[0m    $*"; }
warn(){ echo -e "\e[33m[WARN]\e[0m  $*"; }
err(){  echo -e "\e[31m[ERR]\e[0m   $*"; exit 1; }

need dig
need curl
need awk
need date
if command -v apache2 >/dev/null 2>&1; then :; else warn "apache2 not found in PATH (OK if using another server)"; fi

# 1) DNS loop: wait until ALL resolvers return EXPECTED_IP
say "Waiting for DNS A ${DOMAIN} ⇒ ${EXPECTED_IP} (resolvers: ${RESOLVERS[*]})…"
deadline=$(( $(date +%s) + TIMEOUT_SEC ))
while true; do
  all_ok=1
  out=""
  for r in "${RESOLVERS[@]}"; do
    a=$(dig +short @"$r" A "$DOMAIN" | tail -n1 || true)
    out+="$r → ${a:-<none>}\n"
    [[ "$a" == "$EXPECTED_IP" ]] || all_ok=0
  done
  printf "%b" "$out" | sed 's/^/[DNS] /'
  if [[ $all_ok -eq 1 ]]; then
    ok "All resolvers return ${EXPECTED_IP}."
    break
  fi
  [[ $(date +%s) -ge $deadline ]] && err "DNS did not propagate within ${TIMEOUT_SEC}s."
  sleep "$INTERVAL_SEC"
done

# 2) Quick local service checks (best-effort)
if command -v ss >/dev/null 2>&1; then
  say "Checking listeners on :80 and :443…"
  ss -ltn '( sport = :80 or sport = :443 )' || true
fi

if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "Status: active"; then
  say "UFW status (expect 80/tcp, 443/tcp allowed)…"
  ufw status | sed 's/^/[UFW] /'
fi

# 3) HTTP/HTTPS reachability (from here this tests via your current route; external reach must still be validated)
say "Testing HTTP from here (should return 200/301/302)…"
set +e
HTTP_H=$(curl -sSI "http://${DOMAIN}" | head -n 1)
HTTPS_H=$(curl -sSI "https://${DOMAIN}" | head -n 1)
set -e
echo "[HTTP]  $HTTP_H"
echo "[HTTPS] $HTTPS_H"

# 4) Final recommendation
ok "DNS ready for Let's Encrypt HTTP-01."

if [[ "$AUTO_RUN_CERT" == "--run-cert" ]]; then
  if [[ -x ./07_enable_lets_encrypt.sh ]]; then
    say "Running ./07_enable_lets_encrypt.sh …"
    ./07_enable_lets_encrypt.sh
  else
    err "./07_enable_lets_encrypt.sh not found or not executable in current directory."
  fi
else
  say "You can now run: sudo ./07_enable_lets_encrypt.sh"
  warn "Note: These HTTP checks are from *this* host. True external reachability depends on your MikroTik port-forward."
  echo "Tip: From a mobile network you can verify:"
  echo "  curl -I http://${DOMAIN}    &&   curl -I https://${DOMAIN}"
fi
