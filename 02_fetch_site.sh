#!/usr/bin/env bash
set -euo pipefail

DOMAIN="cloudmigration.blog"
WWW_ROOT="/var/www/${DOMAIN}"

REMOTE_HOST="ftp.cloudmigration.blog"
REMOTE_USER="attila@cloudmigration.blog"
REMOTE_PASS="***"
REMOTE_PATH="/cloudmigration.blog/public_html"

AUTO_PARSE_WPCONFIG=true
REMOTE_DB_HOST=""
REMOTE_DB_NAME=""
REMOTE_DB_USER=""
REMOTE_DB_PASS=""
DUMPDIR="/root"
GZIP_DUMP=true

LOG="/root/02_fetch_site.log"
exec > >(tee -a "$LOG") 2>&1

info(){ echo -e "\e[34m[INFO]\e[0m  $*"; }
ok(){   echo -e "\e[32m[OK]\e[0m    $*"; }
warn(){ echo -e "\e[33m[WARN]\e[0m  $*"; }
err(){  echo -e "\e[31m[ERR]\e[0m   $*"; }

need(){ command -v "$1" >/dev/null 2>&1 || { err "Missing command: $1"; exit 1; }; }
need lftp
need curl
need php
command -v mysqldump >/dev/null 2>&1 || warn "mysqldump not installed (install mysql-client if you want remote dump)"

mkdir -p "${WWW_ROOT}"

PUBIP="$(curl -fsS https://api.ipify.org || true)"
[[ -n "$PUBIP" ]] && info "Public IP: ${PUBIP} (add in SG → MySQL → Remote)" || warn "Could not detect public IP"

COMMON="
set net:timeout 30
set net:max-retries 2
set cmd:fail-exit true
"

mirror_ftp_passive() {
  info "FTP (plain), passive mode → ${WWW_ROOT}"
  lftp -e "
${COMMON}
set ftp:ssl-allow no
set ftp:passive-mode true
set ftp:prefer-epsv false
open -u ${REMOTE_USER},${REMOTE_PASS} ftp://${REMOTE_HOST}
mirror --verbose --parallel=1 --delete --only-newer ${REMOTE_PATH}/ ${WWW_ROOT}/
bye
" || return 1
}

mirror_ftp_active() {
  info "FTP (plain), active mode → ${WWW_ROOT}"
  lftp -e "
${COMMON}
set ftp:ssl-allow no
set ftp:passive-mode false
set ftp:prefer-epsv false
open -u ${REMOTE_USER},${REMOTE_PASS} ftp://${REMOTE_HOST}
mirror --verbose --parallel=1 --delete --only-newer ${REMOTE_PATH}/ ${WWW_ROOT}/
bye
" || return 1
}

mirror_ftps() {
  info "FTPS (explicit TLS) → ${WWW_ROOT}"
  lftp -e "
${COMMON}
set ftp:ssl-allow yes
set ssl:verify-certificate no
set ftp:passive-mode true
set ftp:prefer-epsv false
open -u ${REMOTE_USER},${REMOTE_PASS} ftps://${REMOTE_HOST}
mirror --verbose --parallel=1 --delete --only-newer ${REMOTE_PATH}/ ${WWW_ROOT}/
bye
" || return 1
}

mirror_sftp() {
  info "SFTP → ${WWW_ROOT}"
  lftp -e "
${COMMON}
set sftp:auto-confirm yes
open -u ${REMOTE_USER},${REMOTE_PASS} sftp://${REMOTE_HOST}
mirror --verbose --parallel=1 --delete --only-newer ${REMOTE_PATH}/ ${WWW_ROOT}/
bye
" || return 1
}

set +e
mirror_ftp_passive || {
  warn "FTP passive failed. Trying active mode…"
  mirror_ftp_active || {
    warn "FTP active failed. Trying FTPS…"
    mirror_ftps || {
      warn "FTPS failed. Trying SFTP…"
      mirror_sftp || {
        err "All protocols failed. Check creds/firewall. Log: $LOG"
        exit 1
      }
    }
  }
}
set -e

chown -R www-data:www-data "${WWW_ROOT}"
ok "Files mirrored."

# --- DB section omitted for brevity (same as previous version) ---

