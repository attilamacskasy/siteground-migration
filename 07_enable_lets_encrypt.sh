#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

DOMAIN="cloudmigration.blog"
PUBLIC_IP_EXPECTED="46.139.14.94"
VHOST_FILE="/etc/apache2/sites-available/${DOMAIN}.conf"
EMAIL_OPT="--register-unsafely-without-email"   # avoids prompting for email

# If you prefer to register with an email, set e.g.:
# EMAIL_OPT="--email you@example.com --no-eff-email"

log()  { echo -e "\e[34m[INFO]\e[0m  $*"; }
ok()   { echo -e "\e[32m[OK]\e[0m    $*"; }
warn() { echo -e "\e[33m[WARN]\e[0m  $*"; }
err()  { echo -e "\e[31m[ERR]\e[0m   $*" >&2; exit 1; }

need() { command -v "$1" >/dev/null 2>&1 || { err "Missing command: $1"; }; }

[[ $EUID -eq 0 ]] || err "Please run as root (sudo)."

log "Checking prerequisites…"
apt-get update -y >/dev/null
apt-get install -y curl dnsutils certbot python3-certbot-apache >/dev/null
need apache2
need certbot
need a2query
need dig

# 0) DNS check (public A record should point to your public IP)
log "Verifying DNS A record for ${DOMAIN}…"
DNS_A="$(dig +short A ${DOMAIN} | tail -n1 || true)"
if [[ -z "$DNS_A" ]]; then
  warn "No A record found for ${DOMAIN}. HTTP-01 validation will fail unless DNS is updated."
else
  if [[ "$DNS_A" != "$PUBLIC_IP_EXPECTED" ]]; then
    warn "DNS A for ${DOMAIN} is ${DNS_A}, expected ${PUBLIC_IP_EXPECTED}.
If you *just* changed it, propagation can take a bit; continuing anyway."
  else
    ok "DNS A matches expected public IP (${PUBLIC_IP_EXPECTED})."
  fi
fi

# 1) Apache sanity
systemctl is-active --quiet apache2 || err "Apache2 is not running."
a2query -s "${DOMAIN}" >/dev/null 2>&1 || warn "Apache site '${DOMAIN}' is not enabled yet."
[[ -f "$VHOST_FILE" ]] || err "VHost file not found: ${VHOST_FILE}"
grep -q -E "ServerName\s+${DOMAIN}\b" "$VHOST_FILE" || warn "ServerName ${DOMAIN} not present in ${VHOST_FILE} (certbot may add it)."

# Ensure needed modules
for m in ssl headers rewrite; do
  if ! a2query -m "$m" | grep -q enabled; then
    log "Enabling Apache module: $m"
    a2enmod "$m" >/dev/null
  fi
done
ok "Apache modules ready."

# 2) UFW (just in case)
if command -v ufw >/dev/null 2>&1; then
  if ufw status | grep -q "Status: active"; then
    ufw allow 80/tcp >/dev/null || true
    ufw allow 443/tcp >/dev/null || true
    ok "UFW allows 80/443."
  fi
fi

# 3) Backup vhost
BACKUP="/etc/apache2/sites-available/${DOMAIN}.conf.$(date +%F_%H%M%S).bak"
cp -a "$VHOST_FILE" "$BACKUP"
ok "Backed up vhost to: $BACKUP"

# 4) Cert issuance via Apache plugin (HTTP-01)
log "Requesting Let's Encrypt certificate for ${DOMAIN} (HTTP-01)…"
# --redirect will add HTTP->HTTPS
if ! certbot --apache -d "${DOMAIN}" --non-interactive --agree-tos $EMAIL_OPT --redirect; then
  err "Certbot failed. Check DNS/port 80 reachability from the internet and try again."
fi
ok "Certificate obtained and Apache config updated."

# 5) Config test + reload
apache2ctl configtest
systemctl reload apache2
ok "Apache reloaded."

# 6) Verify certificate
log "Verifying HTTPS with curl (certificate validation)…"
set +e
CURL_OUT="$(curl -sSIL "https://${DOMAIN}" 2>&1)"
RC=$?
set -e
if [[ $RC -ne 0 ]]; then
  warn "curl reported an error contacting https://${DOMAIN} :"
  echo "$CURL_OUT"
  warn "If you’re testing from LAN with a hosts override, ensure the hosts entry points to 172.22.22.247 and Apache now serves the LE cert."
else
  ok "HTTPS is reachable. Response headers:"
  echo "$CURL_OUT" | sed -n '1,20p'
fi

# 7) Enable auto-renewal + dry-run
log "Enabling certbot.timer and testing renewal…"
systemctl enable certbot.timer >/dev/null || true
systemctl start certbot.timer  >/dev/null || true
certbot renew --dry-run || warn "Dry-run renewal had warnings; check '/var/log/letsencrypt/'."
ok "Auto-renew set."

echo
ok "All done. If you need to rollback TLS config, restore: $BACKUP"
echo "LE cert files are under: /etc/letsencrypt/live/${DOMAIN}/"
