#!/usr/bin/env bash
set -euo pipefail

# === EDIT ME ===
DOMAIN="cloudmigration.blog"
WWW_ROOT="/var/www/${DOMAIN}"

# Database to create on THIS server
DB_NAME="wp_cloudmigration"
DB_USER="wp_cloudmigration"
DB_PASS="ChangeMe_StrongPass1!"

# Path to the SQL dump produced in step 2
DUMP_FILE="/root/${DOMAIN}_$(date +%F).sql"     # adjust to your actual file if needed

# URL replacement
OLD_URL="https://cloudmigration.blog"           # or http:// if old site used it
NEW_URL="https://cloudmigration.blog"           # keep https for this server (self-signed or LE)

# Let’s Encrypt settings (set ENABLE_LETSENCRYPT=true when DNS points here)
ENABLE_LETSENCRYPT=false
LE_EMAIL="you@example.com"
# ===============================

assert_cmd() { command -v "$1" >/dev/null 2>&1 || { echo "[-] Missing command: $1"; exit 1; }; }
assert_cmd mysql
assert_cmd php

echo "[+] Installing WP-CLI (if missing)…"
if ! command -v wp >/dev/null 2>&1; then
  curl -fsSL https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar -o /usr/local/bin/wp
  chmod +x /usr/local/bin/wp
fi

echo "[+] Creating DB and user (idempotent)…"
mysql -uroot <<SQL
CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'localhost';
FLUSH PRIVILEGES;
SQL

if [ -f "${DUMP_FILE}" ]; then
  echo "[+] Importing ${DUMP_FILE} into ${DB_NAME}…"
  mysql -u"${DB_USER}" -p"${DB_PASS}" -D "${DB_NAME}" < "${DUMP_FILE}"
else
  echo "[!] Dump file not found at ${DUMP_FILE}. Skipping import."
fi

echo "[+] Updating wp-config.php with local DB credentials (if present)…"
WP_CONFIG="${WWW_ROOT}/wp-config.php"
if [ -f "${WP_CONFIG}" ]; then
  sed -i "s/define(\s*'DB_NAME'.*/define('DB_NAME', '${DB_NAME}');/;" "${WP_CONFIG}" || true
  sed -i "s/define(\s*'DB_USER'.*/define('DB_USER', '${DB_USER}');/;" "${WP_CONFIG}" || true
  sed -i "s/define(\s*'DB_PASSWORD'.*/define('DB_PASSWORD', '${DB_PASS}');/;" "${WP_CONFIG}" || true
  sed -i "s/define(\s*'DB_HOST'.*/define('DB_HOST', 'localhost');/;" "${WP_CONFIG}" || true
fi
chown -R www-data:www-data "${WWW_ROOT}"

echo "[+] Removing SiteGround-specific plugins and cache drop-ins…"
rm -f  "${WWW_ROOT}/wp-content/object-cache.php" \
       "${WWW_ROOT}/wp-content/advanced-cache.php" || true
rm -rf "${WWW_ROOT}/wp-content/cache" || true
rm -rf "${WWW_ROOT}/wp-content/mu-plugins/"*siteground* 2>/dev/null || true
# If WP-CLI can run, remove plugins by slug
if [ -f "${WWW_ROOT}/wp-load.php" ]; then
  sudo -u www-data wp --path="${WWW_ROOT}" plugin deactivate sg-cachepress siteground-security siteground-migrator --allow-root || true
  sudo -u www-data wp --path="${WWW_ROOT}" plugin delete sg-cachepress siteground-security siteground-migrator --allow-root || true
fi

echo "[+] Flushing and fixing URLs with WP-CLI (if WP is bootable)…"
if [ -f "${WWW_ROOT}/wp-load.php" ]; then
  sudo -u www-data wp --path="${WWW_ROOT}" option update home "${NEW_URL}" --allow-root || true
  sudo -u www-data wp --path="${WWW_ROOT}" option update siteurl "${NEW_URL}" --allow-root || true
  # Full search-replace to catch serialized data
  sudo -u www-data wp --path="${WWW_ROOT}" search-replace "${OLD_URL}" "${NEW_URL}" --all-tables --precise --recurse-objects --allow-root || true
  # Regenerate .htaccess/permalinks
  sudo -u www-data wp --path="${WWW_ROOT}" rewrite structure '/%postname%/' --hard --allow-root || true
  sudo -u www-data wp --path="${WWW_ROOT}" rewrite flush --hard --allow-root || true
fi

echo "[+] Tightening permissions…"
find "${WWW_ROOT}" -type d -exec chmod 755 {} \;
find "${WWW_ROOT}" -type f -exec chmod 644 {} \;
chown -R www-data:www-data "${WWW_ROOT}"

echo "[+] Restarting services…"
systemctl reload apache2
systemctl restart php${PHP_VER:-8.2}-fpm || true

if $ENABLE_LETSENCRYPT; then
  echo "[+] Enabling Let’s Encrypt for ${DOMAIN}…"
  apt-get update -y
  apt-get install -y certbot python3-certbot-apache
  certbot --apache -d "${DOMAIN}" -d "www.${DOMAIN}" \
          --non-interactive --agree-tos -m "${LE_EMAIL}" --redirect || {
    echo "[!] certbot failed. Check DNS and that ports 80/443 are reachable."
  }
fi

echo "[✓] Finalization done."
echo "Open: https://${DOMAIN}  (self-signed warning unless you enabled Let’s Encrypt)."

