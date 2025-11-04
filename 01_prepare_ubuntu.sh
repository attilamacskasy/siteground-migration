#!/usr/bin/env bash
set -euo pipefail

# === EDIT ME ===
DOMAIN="cloudmigration.blog"
WWW_ROOT="/var/www/${DOMAIN}"
TZ="Europe/Budapest"
PHP_VER="8.2"          # keep 8.2 unless you have a reason to change
USE_ONDREJ_PPA=true    # set false if you already have PHP 8.2 packages
# =================

export DEBIAN_FRONTEND=noninteractive

echo "[+] Updating and installing base packages…"
apt-get update -y
apt-get install -y ca-certificates software-properties-common curl wget unzip rsync lftp openssl ufw \
                   apache2 mariadb-server

# QEMU Guest Agent (harmless if not on Proxmox)
# apt-get install -y qemu-guest-agent || true
# systemctl enable --now qemu-guest-agent || true

# PHP 8.2 + FPM + common WP extensions
if $USE_ONDREJ_PPA; then
  add-apt-repository -y ppa:ondrej/php || true
  apt-get update -y
fi

apt-get install -y \
  php${PHP_VER}-fpm php${PHP_VER}-cli php${PHP_VER}-opcache \
  php${PHP_VER}-bcmath php${PHP_VER}-curl php${PHP_VER}-gd php${PHP_VER}-gmp \
  php${PHP_VER}-imap php${PHP_VER}-intl php${PHP_VER}-mbstring php${PHP_VER}-mysql \
  php${PHP_VER}-pgsql php${PHP_VER}-readline php${PHP_VER}-soap php${PHP_VER}-tidy \
  php${PHP_VER}-xsl php${PHP_VER}-zip php${PHP_VER}-xml php${PHP_VER}-zip \
  imagemagick php${PHP_VER}-imagick

echo "[+] Setting timezone to ${TZ}…"
timedatectl set-timezone "${TZ}"

echo "[+] Tuning PHP limits…"
INI="/etc/php/${PHP_VER}/fpm/conf.d/99-local-overrides.ini"
install -d "$(dirname "$INI")"
cat > "$INI" <<'EOF'
expose_php = Off
short_open_tag = On
html_errors = On
memory_limit = 768M
upload_max_filesize = 256M
post_max_size = 256M
max_execution_time = 120
max_input_time = 120
max_input_vars = 3000
date.timezone = UTC
EOF
systemctl enable --now php${PHP_VER}-fpm
systemctl restart php${PHP_VER}-fpm

echo "[+] Creating document root ${WWW_ROOT}…"
mkdir -p "${WWW_ROOT}"
chown -R www-data:www-data "${WWW_ROOT}"
chmod -R 755 "${WWW_ROOT}"

echo "[+] Enabling Apache modules and FPM integration…"
a2enmod proxy_fcgi setenvif rewrite headers ssl http2
a2enconf php${PHP_VER}-fpm || true

echo "[+] Generating a self-signed SSL cert for ${DOMAIN}…"
SSL_KEY="/etc/ssl/private/${DOMAIN}.key"
SSL_CRT="/etc/ssl/certs/${DOMAIN}.crt"
if [ ! -f "$SSL_KEY" ] || [ ! -f "$SSL_CRT" ]; then
  openssl req -x509 -nodes -days 365 \
    -newkey rsa:2048 \
    -keyout "${SSL_KEY}" \
    -out "${SSL_CRT}" \
    -subj "/C=HU/ST=Budapest/L=Budapest/O=CloudMigration/OU=IT/CN=${DOMAIN}"
fi
chmod 600 "${SSL_KEY}"

echo "[+] Creating Apache vhost…"
VHOST="/etc/apache2/sites-available/${DOMAIN}.conf"
cat > "$VHOST" <<EOF
<VirtualHost *:80>
    ServerName ${DOMAIN}
    ServerAlias www.${DOMAIN}
    DocumentRoot ${WWW_ROOT}
    RewriteEngine On
    RewriteCond %{HTTPS} off
    RewriteRule ^/?(.*) https://%{SERVER_NAME}/\$1 [R=301,L]
</VirtualHost>

<VirtualHost *:443>
    ServerName ${DOMAIN}
    ServerAlias www.${DOMAIN}
    DocumentRoot ${WWW_ROOT}

    SSLEngine On
    SSLCertificateFile    ${SSL_CRT}
    SSLCertificateKeyFile ${SSL_KEY}

    <Directory ${WWW_ROOT}>
        Options Indexes FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>

    <FilesMatch \.php$>
        SetHandler "proxy:unix:/run/php/php${PHP_VER}-fpm.sock|fcgi://localhost/"
    </FilesMatch>

    ErrorLog \${APACHE_LOG_DIR}/${DOMAIN}-error.log
    CustomLog \${APACHE_LOG_DIR}/${DOMAIN}-access.log combined

    Header always set X-Frame-Options "SAMEORIGIN"
    Header always set X-Content-Type-Options "nosniff"
    Header always set Referrer-Policy "strict-origin-when-cross-origin"
</VirtualHost>
EOF

a2ensite "${DOMAIN}.conf"
systemctl reload apache2

echo "[+] Optional: open UFW ports 80/443…"
ufw allow OpenSSH || true
ufw allow 80/tcp || true
ufw allow 443/tcp || true
echo "y" | ufw enable || true

# Safety index to verify Apache works (will be overwritten by your site)
if [ ! -f "${WWW_ROOT}/index.html" ]; then
  cat > "${WWW_ROOT}/index.html" <<EOF
<h1>${DOMAIN} - placeholder</h1>
<p>Apache + PHP-FPM is ready. Self-signed HTTPS is enabled.</p>
EOF
fi

echo "[✓] Base server prepared. Visit: https://${DOMAIN} (you'll see a self-signed warning)."

