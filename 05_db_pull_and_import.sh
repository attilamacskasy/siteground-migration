#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# --- CONFIG ---
SSH_ALIAS="sg-ssh"
LOCAL_DUMP_DIR="$HOME/db_backups"

# --- FUNCTIONS ---
info()  { echo -e "\e[36m[INFO]\e[0m  $*"; }
ok()    { echo -e "\e[32m[OK]\e[0m    $*"; }
warn()  { echo -e "\e[33m[WARN]\e[0m  $*"; }
err()   { echo -e "\e[31m[ERR]\e[0m   $*" >&2; exit 1; }

mkdir -p "$LOCAL_DUMP_DIR"

# --- STEP 0: Detect remote WordPress path ---
info "[0/6] Detecting remote WordPress path…"
REMOTE_WP_ROOT=$(
  ssh -p 18765 "$SSH_ALIAS" "cd ~/www && find . -type d -name public_html | head -1 | sed 's|^./||'"
)
[[ -z "$REMOTE_WP_ROOT" ]] && err "Couldn't find remote WordPress root."
REMOTE_WP_ROOT="/home/u1087-bgbtdthofrcy/www/${REMOTE_WP_ROOT}"
ok "Remote WP root: $REMOTE_WP_ROOT"

# --- STEP 1: Fetch wp-config.php and parse credentials ---
info "[1/6] Fetching wp-config.php and parsing DB credentials…"
TMP_WP_CONF=$(mktemp)
scp -P 18765 "${SSH_ALIAS}:${REMOTE_WP_ROOT}/wp-config.php" "$TMP_WP_CONF"

DB_NAME=$(grep "DB_NAME" "$TMP_WP_CONF" | sed "s/.*'DB_NAME', *'\([^']*\)'.*/\1/")
DB_USER=$(grep "DB_USER" "$TMP_WP_CONF" | sed "s/.*'DB_USER', *'\([^']*\)'.*/\1/")
DB_PASS=$(grep "DB_PASSWORD" "$TMP_WP_CONF" | sed "s/.*'DB_PASSWORD', *'\([^']*\)'.*/\1/")
DB_HOST=$(grep "DB_HOST" "$TMP_WP_CONF" | sed "s/.*'DB_HOST', *'\([^']*\)'.*/\1/")
rm -f "$TMP_WP_CONF"

[[ -z "$DB_NAME" || -z "$DB_USER" || -z "$DB_PASS" || -z "$DB_HOST" ]] && err "Failed to parse DB credentials."
ok "Parsed:
  DB_NAME = $DB_NAME
  DB_USER = $DB_USER
  DB_HOST = $DB_HOST"

# --- STEP 2: Create remote MySQL dump ---
info "[2/6] Creating remote MySQL dump (gz)…"
DUMP_NAME="${DB_NAME}_$(date +%F_%H%M).sql.gz"
ssh -p 18765 "$SSH_ALIAS" "mysqldump -u'$DB_USER' -p'$DB_PASS' '$DB_NAME' | gzip -9 > ~/${DUMP_NAME}"
ssh -p 18765 "$SSH_ALIAS" "ls -lh ~/${DUMP_NAME}"

# --- STEP 3: Download dump to ~/db_backups ---
info "[3/6] Downloading dump locally to ${LOCAL_DUMP_DIR}…"
scp -P 18765 "${SSH_ALIAS}:~/${DUMP_NAME}" "${LOCAL_DUMP_DIR}/"
LOCAL_SQL="${LOCAL_DUMP_DIR}/${DUMP_NAME}"
ok "Downloaded: ${LOCAL_SQL}"

# --- STEP 4: Ensure local DB + user exist ---
info "[4/6] Ensuring local DB and user (same names)…"
sudo mysql -e "
CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'localhost';
FLUSH PRIVILEGES;"
ok "Local DB/user ready."

# --- STEP 5: Import SQL into local DB ---
info "[5/6] Importing into local DB '${DB_NAME}' …"
gunzip -c "${LOCAL_SQL}" | sudo mysql "${DB_NAME}"
ok "Import completed."

# --- STEP 6: Cleanup remote dump ---
info "[6/6] Cleaning up remote dump…"
ssh -p 18765 "$SSH_ALIAS" "rm -f ~/${DUMP_NAME}" || warn "Couldn't remove remote dump."

ok "✅ Database transferred and imported successfully."
echo "Local dump retained at: ${LOCAL_SQL}"
