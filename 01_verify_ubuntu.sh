#!/usr/bin/env bash
set -euo pipefail

# ====== EDIT THESE IF NEEDED ======
DOMAIN="cloudmigration.blog"
PHP_VER="8.2"
WWW_ROOT="/var/www/${DOMAIN}"
VHOST_FILE="/etc/apache2/sites-available/${DOMAIN}.conf"
SSL_KEY="/etc/ssl/private/${DOMAIN}.key"
SSL_CRT="/etc/ssl/certs/${DOMAIN}.crt"
# ==================================

OKS=0
FAILS=0
warn() { echo -e "\e[33m[WARN]\e[0m $*"; }
pass() { echo -e "\e[32m[PASS]\e[0m $*"; ((OKS++)); }
fail() { echo -e "\e[31m[FAIL]\e[0m $*"; ((FAILS++)); }

check_cmd() {
  if command -v "$1" >/dev/null 2>&1; then
    pass "command '$1' is present"
  else
    fail "command '$1' missing"
  fi
}

echo "=== Verifying base system for ${DOMAIN} (no QEMU Agent checks) ==="

# Commands presence
for c in apache2 a2query a2enmod a2ensite curl openssl php "php-fpm${PHP_VER}" mysql; do
  check_cmd "${c}" || true
done

# Services
systemctl is-active --quiet apache2                && pass "apache2 service active"            || fail "apache2 service NOT active"
systemctl is-active --quiet "php${PHP_VER}-fpm"    && pass "php${PHP_VER}-fpm service active"  || fail "php${PHP_VER}-fpm service NOT active"
systemctl is-active --quiet mariadb                && pass "mariadb service active"            || fail "mariadb service NOT active"

# PHP version and socket
php -v | grep -q "PHP ${PHP_VER}" && pass "PHP ${PHP_VER} installed" || fail "PHP ${PHP_VER} not detected"

SOCK="/run/php/php${PHP_VER}-fpm.sock"
[[ -S "$SOCK" ]] && pass "PHP-FPM socket present at ${SOCK}" || fail "PHP-FPM socket missing: ${SOCK}"

# PHP overrides
INI="/etc/php/${PHP_VER}/fpm/conf.d/99-local-overrides.ini"
if [[ -f "$INI" ]]; then
  pass "PHP overrides file exists: ${INI}"
  for k in memory_limit upload_max_filesize post_max_size max_execution_time max_input_time max_input_vars date.timezone; do
    grep -Eq "^\s*${k}\s*=" "$INI" && pass "php.ini override '${k}' set" || warn "php.ini override '${k}' not found"
  done
else
  fail "PHP overrides file missing: ${INI}"
fi

# Apache modules expected by 01 script
mods="$(apache2ctl -M 2>/dev/null || true)"
for m in ssl_module headers_module rewrite_module http2_module proxy_fcgi_module; do
  grep -q "$m" <<<"$mods" && pass "Apache module enabled: ${m}" || fail "Apache module NOT enabled: ${m}"
done

# Apache FPM conf enabled
a2query -c "php${PHP_VER}-fpm" 2>/dev/null | grep -q enabled \
  && pass "Apache conf php${PHP_VER}-fpm enabled" \
  || fail "Apache conf php${PHP_VER}-fpm NOT enabled"

# Vhost existence & basic checks
if [[ -f "$VHOST_FILE" ]]; then
  pass "VHost file exists: ${VHOST_FILE}"
  grep -q "ServerName ${DOMAIN}" "$VHOST_FILE" && pass "VHost has ServerName ${DOMAIN}" || fail "VHost missing ServerName ${DOMAIN}"
  grep -q "DocumentRoot ${WWW_ROOT}" "$VHOST_FILE" && pass "VHost DocumentRoot ${WWW_ROOT}" || fail "VHost missing DocumentRoot ${WWW_ROOT}"
  grep -q "SSLCertificateFile" "$VHOST_FILE" && pass "VHost has SSL config" || warn "VHost SSL directive not found"
else
  fail "VHost file missing: ${VHOST_FILE}"
fi

# Site enabled
if a2query -s "${DOMAIN}" 2>/dev/null | grep -q enabled; then
  pass "Apache site '${DOMAIN}' enabled"
else
  a2query -s 2>/dev/null | grep -q "${DOMAIN}.*enabled" \
    && pass "Apache site '${DOMAIN}' enabled (list)" \
    || fail "Apache site '${DOMAIN}' NOT enabled"
fi

# Web root
[[ -d "$WWW_ROOT" ]] && pass "Document root exists: ${WWW_ROOT}" || fail "Document root missing: ${WWW_ROOT}"

# SSL files
[[ -f "$SSL_CRT" && -f "$SSL_KEY" ]] && pass "Self-signed cert and key exist" || fail "Missing SSL cert/key: ${SSL_CRT} / ${SSL_KEY}"

# UFW status (not fatal if ufw disabled). Accept explicit rules OR Apache app profile.
if command -v ufw >/dev/null 2>&1; then
  UFW_STATUS="$(ufw status || true)"
  if grep -q "Status: active" <<<"$UFW_STATUS"; then
    pass "UFW active"

    # Acknowledge Apache profile if present
    if echo "$UFW_STATUS" | grep -qE '^[[:space:]]*Apache( Full)?[[:space:]]+ALLOW'; then
      pass "UFW Apache app profile active (covers 80/443)"
    fi

    check_port_allow() {
      local port="$1"
      # Match "80/tcp ALLOW ..." and "80/tcp (v6) ALLOW ..."
      if echo "$UFW_STATUS" | grep -qE "^[[:space:]]*${port}/tcp( \(v6\))?[[:space:]]+ALLOW"; then
        pass "UFW allows ${port}/tcp"
      else
        # Robust fallback using awk for columnar spacing
        if echo "$UFW_STATUS" | awk -v p="${port}/tcp" '
          $1==p && $2=="ALLOW" {found=1}
          $1==p" (v6)" && $2=="ALLOW" {found=1}
          END {exit(!found)}'
        then
          pass "UFW allows ${port}/tcp"
        else
          warn "UFW does NOT show ${port}/tcp allowed"
        fi
      fi
    }

    check_port_allow 80
    check_port_allow 443
  else
    warn "UFW not active"
  fi
fi

# MariaDB local ping
mysqladmin ping -uroot --silent && pass "MariaDB responds to local ping" || warn "MariaDB ping failed (check root auth method)"

# Live HTTPS test via loopback + Host header (ignore self-signed)
echo "[i] Performing HTTPS check to ${DOMAIN} via 127.0.0.1 (ignore self-signed errors)…"
if curl -skI --resolve "${DOMAIN}:443:127.0.0.1" "https://${DOMAIN}/" | grep -qE "^HTTP/.* (200|301|302)"; then
  pass "HTTPS responds for ${DOMAIN} on localhost"
else
  fail "HTTPS did not respond for ${DOMAIN} on localhost"
fi

# Quick PHP execution test
TMP_PHP="${WWW_ROOT}/__verify_phpinfo.php"
cleanup() { rm -f "${TMP_PHP}" 2>/dev/null || true; }
trap cleanup EXIT

echo "<?php echo 'OKPHP-'.PHP_MAJOR_VERSION.'.'.PHP_MINOR_VERSION; ?>" > "${TMP_PHP}"
chown www-data:www-data "${TMP_PHP}"
if out="$(curl -sk --resolve "${DOMAIN}:443:127.0.0.1" "https://${DOMAIN}/__verify_phpinfo.php")"; then
  grep -q "OKPHP-${PHP_VER%.*}" <<<"$out" \
    && pass "PHP executed via FPM for ${DOMAIN} (got: ${out})" \
    || fail "PHP did not execute as expected (output: ${out})"
else
  fail "Failed to fetch PHP test page over HTTPS"
fi

echo "=== Summary: ${OKS} PASS, ${FAILS} FAIL ==="
exit $(( FAILS > 0 ))

