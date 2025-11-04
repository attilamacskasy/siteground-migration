#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# ====== SETTINGS ======
# Root of your WordPress (contains wp-config.php). If your install uses public_html,
# the script will auto-switch to that subfolder.
WP_ROOT_DEFAULT="/var/www/cloudmigration.blog"
BACKUP_DIR="$HOME/backups"
RETENTION_DAYS="${RETENTION_DAYS:-0}"  # set >0 to prune old backups

# ====== HELPERS ======
info(){ echo -e "\e[36m[INFO]\e[0m  $*"; }
ok(){   echo -e "\e[32m[OK]\e[0m    $*"; }
warn(){ echo -e "\e[33m[WARN]\e[0m  $*"; }
err(){  echo -e "\e[31m[ERR]\e[0m   $*" >&2; exit 1; }

extract_define() {  # usage: extract_define KEY file
  LC_ALL=C sed -n -E "s/^[[:space:]]*define\([[:space:]]*['\"]$1['\"][[:space:]]*,[[:space:]]*['\"]([^'\"]*)['\"][[:space:]]*\).*/\1/p" "$2" | head -n1
}

ts() { date +%Y%m%d_%H%M; }

mkdir -p "$BACKUP_DIR"

# ====== 0) Locate WP root and wp-config.php ======
WP_PATH="${WP_PATH:-$WP_ROOT_DEFAULT}"
[[ -d "$WP_PATH/public_html" ]] && WP_PATH="$WP_PATH/public_html"
[[ -f "$WP_PATH/wp-config.php" ]] || err "wp-config.php not found under $WP_PATH (set WP_PATH=/your/path)."

ok "WordPress path: $WP_PATH"

STAMP="$(ts)"
SITE_NAME="$(basename "$WP_PATH")"
SITE_NAME="${SITE_NAME:-wordpress}"

# ====== 1) Parse DB creds from wp-config.php ======
CFG="$WP_PATH/wp-config.php"
DB_NAME="$(extract_define DB_NAME "$CFG" || true)"
DB_USER="$(extract_define DB_USER "$CFG" || true)"
DB_PASS="$(extract_define DB_PASSWORD "$CFG" || true)"
DB_HOST="$(extract_define DB_HOST "$CFG" || echo "localhost")"

[[ -z "$DB_NAME" || -z "$DB_USER" || -z "$DB_PASS" ]] && err "Could not parse DB credentials from $CFG"

ok "DB parsed: name=$DB_NAME user=$DB_USER host=$DB_HOST"

# ====== 2) Database dump (gz) ======
DB_OUT="${BACKUP_DIR}/${DB_NAME}_${STAMP}.sql.gz"
info "Dumping database → ${DB_OUT}"
mysqldump -h"$DB_HOST" -u"$DB_USER" -p"$DB_PASS" \
  --single-transaction --default-character-set=utf8mb4 \
  --routines --triggers --events "$DB_NAME" | gzip -9 > "$DB_OUT"
ok "DB dump done: $(du -h "$DB_OUT" | awk '{print $1}')"

# ====== 3) Files archive (tar.gz) ======
# Exclude noisy/temporary dirs to keep backups smaller
SITE_OUT="${BACKUP_DIR}/${SITE_NAME}_${STAMP}.tar.gz"
info "Archiving WordPress files → ${SITE_OUT}"
(
  cd "$(dirname "$WP_PATH")"
  BASE="$(basename "$WP_PATH")"
  tar --warning=no-file-changed -czf "$SITE_OUT" \
    --exclude="$BASE/wp-content/cache" \
    --exclude="$BASE/wp-content/cache/*" \
    --exclude="$BASE/wp-content/ai1wm-backups" \
    --exclude="$BASE/wp-content/updraft" \
    --exclude="$BASE/wp-content/wflogs" \
    --exclude="$BASE/wp-content/debug.log" \
    --exclude="$BASE/*.log" \
    "$BASE"
)
ok "Files archive done: $(du -h "$SITE_OUT" | awk '{print $1}')"

# ====== 4) Manifest + checksums ======
MANIFEST="${BACKUP_DIR}/manifest_${STAMP}.txt"
sha256sum "$DB_OUT" "$SITE_OUT" > "${MANIFEST}.sha256"
{
  echo "Backup timestamp : $STAMP"
  echo "Site path        : $WP_PATH"
  echo "DB name          : $DB_NAME"
  echo "Archives:"
  echo "  - $(basename "$DB_OUT")"
  echo "  - $(basename "$SITE_OUT")"
  echo
  echo "SHA256:"
  cat "${MANIFEST}.sha256"
} > "$MANIFEST"
ok "Wrote manifest: $(basename "$MANIFEST")"

# ====== 5) Optional retention ======
if [[ "$RETENTION_DAYS" -gt 0 ]]; then
  info "Pruning backups older than ${RETENTION_DAYS} days in $BACKUP_DIR"
  find "$BACKUP_DIR" -type f -mtime +"$RETENTION_DAYS" \
    \( -name '*.sql.gz' -o -name '*.tar.gz' -o -name 'manifest_*.txt' -o -name '*.sha256' \) -print -delete || true
fi

echo
ok "Backup complete."
echo "• DB:   $DB_OUT"
echo "• Files:$SITE_OUT"
echo "• Info: $MANIFEST"
echo
echo "Verify with:"
echo "  (cd \"$BACKUP_DIR\" && sha256sum -c $(basename "${MANIFEST}.sha256"))"
