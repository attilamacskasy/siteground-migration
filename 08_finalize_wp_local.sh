#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# ---------- SETTINGS ----------
WP_PATH="${WP_PATH:-/var/www/cloudmigration.blog}"   # Root of your WP (contains wp-config.php)
APACHE_VHOST="/etc/apache2/sites-available/cloudmigration.blog.conf"
WWW_USER="www-data"
WWW_GROUP="www-data"

# If you want to also disable "WP File Manager" (risky plugin), set:
DISABLE_WP_FILE_MANAGER="${DISABLE_WP_FILE_MANAGER:-yes}"   # yes|no

# ---------- Helpers ----------
i(){ echo -e "\e[36m[INFO]\e[0m  $*"; }
o(){ echo -e "\e[32m[OK]\e[0m    $*"; }
w(){ echo -e "\e[33m[WARN]\e[0m  $*"; }
e(){ echo -e "\e[31m[ERR]\e[0m   $*" >&2; exit 1; }

require() { command -v "$1" >/dev/null 2>&1 || e "Missing command: $1"; }

[[ -f "${WP_PATH}/wp-config.php" ]] || e "wp-config.php not found under ${WP_PATH}"

# ---------- 0) Ensure wp-cli ----------
if ! command -v wp >/dev/null 2>&1; then
  i "Installing wp-cli…"
  curl -fsSL https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar -o /usr/local/bin/wp
  chmod +x /usr/local/bin/wp
fi
require wp

# ---------- 1) List & purge SiteGround plugins ----------
i "Scanning installed plugins…"
PLUGIN_LIST=$(sudo -u "$WWW_USER" wp plugin list --path="$WP_PATH" --field=name)

# Known SG slugs (we also match by author string later just in case)
SG_CANDIDATES=( sg-security sg-cachepress siteground-migrator siteground-optimizer siteground-central )
TO_REMOVE=()

for slug in "${SG_CANDIDATES[@]}"; do
  if echo "$PLUGIN_LIST" | grep -q "^${slug}$"; then
    TO_REMOVE+=("$slug")
  fi
done

# Heuristic: anything with "siteground" in the name
while IFS= read -r p; do
  TO_REMOVE+=("$p")
done < <(sudo -u "$WWW_USER" wp plugin list --path="$WP_PATH" --fields=name,author \
         | awk 'BEGIN{IGNORECASE=1}/siteground/{print $1}' | sort -u)

if [[ "${#TO_REMOVE[@]}" -gt 0 ]]; then
  i "Removing SiteGround-specific plugins: ${TO_REMOVE[*]}"
  for p in "${TO_REMOVE[@]}"; do
    sudo -u "$WWW_USER" wp plugin deactivate "$p" --path="$WP_PATH" --quiet || true
    sudo -u "$WWW_USER" wp plugin delete "$p"     --path="$WP_PATH" --quiet || true
  done
  o "SiteGround plugins removed."
else
  o "No SiteGround plugins detected."
fi

# Optional: deactivate WP File Manager (high-risk)
if [[ "$DISABLE_WP_FILE_MANAGER" == "yes" ]]; then
  if echo "$PLUGIN_LIST" | grep -q '^wp-file-manager$'; then
    i "Deactivating wp-file-manager (recommended for security)…"
    sudo -u "$WWW_USER" wp plugin deactivate wp-file-manager --path="$WP_PATH" --quiet || true
    o "wp-file-manager deactivated. (Set DISABLE_WP_FILE_MANAGER=no to keep it.)"
  fi
fi

# ---------- 2) Fix ownership & permissions ----------
i "Fixing ownership and permissions…"
chown -R "$WWW_USER":"$WWW_GROUP" "$WP_PATH"

# Safe defaults: 755 dirs, 644 files
find "$WP_PATH" -type d -exec chmod 755 {} \;
find "$WP_PATH" -type f -exec chmod 644 {} \;

# wp-config tighter
chmod 640 "$WP_PATH/wp-config.php" || true

# Ensure uploads exists & writable by web user (775 dirs, 664 files inside uploads)
mkdir -p "$WP_PATH/wp-content/uploads"
chown -R "$WWW_USER":"$WWW_GROUP" "$WP_PATH/wp-content/uploads"
find "$WP_PATH/wp-content/uploads" -type d -exec chmod 775 {} \;
find "$WP_PATH/wp-content/uploads" -type f -exec chmod 664 {} \;

o "Permissions fixed."

# ---------- 3) Block PHP execution in uploads ----------
UPLOADS_HT="$WP_PATH/wp-content/uploads/.htaccess"
if [[ ! -f "$UPLOADS_HT" ]] || ! grep -q "FilesMatch" "$UPLOADS_HT"; then
  i "Adding .htaccess to block PHP execution in uploads/…"
  cat > "$UPLOADS_HT" <<'HT'
# Security: disallow executing PHP in uploads
<FilesMatch "\.php$">
  Require all denied
</FilesMatch>
HT
  chown "$WWW_USER":"$WWW_GROUP" "$UPLOADS_HT"
  chmod 644 "$UPLOADS_HT"
  o "uploads/.htaccess added."
else
  o "uploads/.htaccess already present."
fi

# ---------- 4) Add DISALLOW_FILE_EDIT in wp-config.php ----------
if ! grep -q "DISALLOW_FILE_EDIT" "$WP_PATH/wp-config.php"; then
  i "Disabling theme/plugin editor in wp-admin…"
  sed -i "/\/\* That's all, stop editing! Happy publishing. \*\//i define('DISALLOW_FILE_EDIT', true);" "$WP_PATH/wp-config.php"
  o "DISALLOW_FILE_EDIT enabled."
else
  o "DISALLOW_FILE_EDIT already set."
fi

# ---------- 5) Apache security headers (conf-enabled & reload) ----------
SEC_HDR_CONF="/etc/apache2/conf-available/secure-headers.conf"
if [[ ! -f "$SEC_HDR_CONF" ]]; then
  i "Adding common security headers via ${SEC_HDR_CONF}…"
  cat > "$SEC_HDR_CONF" <<'CONF'
<IfModule mod_headers.c>
  Header always set X-Content-Type-Options "nosniff"
  Header always set X-Frame-Options "SAMEORIGIN"
  Header always set Referrer-Policy "strict-origin-when-cross-origin"
  Header always set Permissions-Policy "geolocation=(), microphone=(), camera=()"
  # Enable HSTS only if HTTPS is active; adjust max-age as needed
  Header always set Strict-Transport-Security "max-age=31536000; includeSubDomains" env=HTTPS
</IfModule>
CONF
  a2enmod headers >/dev/null || true
  a2enconf secure-headers >/dev/null
  systemctl reload apache2
  o "Security headers enabled and Apache reloaded."
else
  o "Security headers conf already exists."
fi

# ---------- 6) Flush permalinks / rewrite rules ----------
i "Flushing rewrite rules…"
sudo -u "$WWW_USER" wp rewrite flush --hard --path="$WP_PATH" >/dev/null || true
o "Rewrite rules flushed."

# ---------- 7) Quick health summary ----------
i "Active plugins now:"
sudo -u "$WWW_USER" wp plugin list --path="$WP_PATH" --status=active

echo
o "Finalization complete."
echo "• SiteGround plugins removed (if present)."
echo "• Permissions hardened (uploads writable)."
echo "• PHP execution blocked in uploads/."
echo "• DISALLOW_FILE_EDIT set."
echo "• Security headers enabled; Apache reloaded."
echo "• Rewrites flushed."
