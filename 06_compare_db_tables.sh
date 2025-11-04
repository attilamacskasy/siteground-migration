#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# ---------- SETTINGS ----------
SSH_ALIAS="sg-ssh"                               # SSH alias you already set up
REMOTE_WP_CANDIDATES=(                           # probe order for WordPress root on SG
  "/home/u1087-bgbtdthofrcy/www/cloudmigration.blog/public_html"
  "/home/u1087-bgbtdthofrcy/cloudmigration.blog/public_html"
  "/home/u1087-bgbtdthofrcy/public_html"
)
LOCAL_WP_ROOT="/var/www/cloudmigration.blog"     # used only if you want to parse local wp-config.php as a fallback

# ---------- HELPERS ----------
info(){ echo -e "\e[36m[INFO]\e[0m  $*"; }
ok(){   echo -e "\e[32m[OK]\e[0m    $*"; }
warn(){ echo -e "\e[33m[WARN]\e[0m  $*"; }
err(){  echo -e "\e[31m[ERR]\e[0m   $*" >&2; exit 1; }

extract_define() {
  # usage: extract_define KEY file
  LC_ALL=C sed -n -E "s/^[[:space:]]*define\([[:space:]]*['\"]$1['\"][[:space:]]*,[[:space:]]*['\"]([^'\"]*)['\"][[:space:]]*\).*/\1/p" "$2" | head -n1
}

tmpdir="$(mktemp -d)"; trap 'rm -rf "$tmpdir"' EXIT

# ---------- 0) Find remote WP root + fetch wp-config.php ----------
info "Detecting remote WordPress root…"
REMOTE_WP_ROOT=""
for d in "${REMOTE_WP_CANDIDATES[@]}"; do
  if ssh -p 18765 "$SSH_ALIAS" "test -f '$d/wp-config.php'"; then
    REMOTE_WP_ROOT="$d"
    break
  fi
done
[[ -z "$REMOTE_WP_ROOT" ]] && err "Couldn't find remote wp-config.php. Adjust REMOTE_WP_CANDIDATES."

ok "Remote WP root: $REMOTE_WP_ROOT"
info "Fetching remote wp-config.php…"
scp -P 18765 "${SSH_ALIAS}:${REMOTE_WP_ROOT}/wp-config.php" "$tmpdir/wp-config.php" >/dev/null

DB_NAME="$(extract_define DB_NAME "$tmpdir/wp-config.php" || true)"
DB_USER_R="$(extract_define DB_USER "$tmpdir/wp-config.php" || true)"
DB_PASS_R="$(extract_define DB_PASSWORD "$tmpdir/wp-config.php" || true)"
DB_HOST_R="$(extract_define DB_HOST "$tmpdir/wp-config.php" || echo 'localhost')"

[[ -z "$DB_NAME" || -z "$DB_USER_R" || -z "$DB_PASS_R" ]] && err "Failed to parse DB creds from remote wp-config.php."

ok "Parsed remote creds:
  DB_NAME=$DB_NAME  DB_USER=$DB_USER_R  DB_HOST=$DB_HOST_R"

# Local DB is same name/user/pass per your previous step.
DB_USER_L="$DB_USER_R"
DB_PASS_L="$DB_PASS_R"
DB_HOST_L="localhost"

# ---------- 1) Build remote table->rowcount ----------
info "Querying REMOTE tables and exact row counts (this may take a moment)…"
REMOTE_TLIST="$tmpdir/remote_tables.txt"
REMOTE_COUNTS="$tmpdir/remote_counts.tsv"

ssh -p 18765 "$SSH_ALIAS" "mysql -N -h'$DB_HOST_R' -u'$DB_USER_R' -p'$DB_PASS_R' '$DB_NAME' -e 'SHOW TABLES;'" \
  | LC_ALL=C sort > "$REMOTE_TLIST"

# For each remote table do COUNT(*)
: > "$REMOTE_COUNTS"
while read -r t; do
  # protect table name with backticks
  c=$(ssh -p 18765 "$SSH_ALIAS" \
    "mysql -N -h'$DB_HOST_R' -u'$DB_USER_R' -p'$DB_PASS_R' '$DB_NAME' -e \"SELECT COUNT(*) FROM \\\`$t\\\`;\"") || c="ERR"
  printf "%s\t%s\n" "$t" "$c" >> "$REMOTE_COUNTS"
done < "$REMOTE_TLIST"

# ---------- 2) Build local table->rowcount ----------
info "Querying LOCAL tables and exact row counts…"
LOCAL_TLIST="$tmpdir/local_tables.txt"
LOCAL_COUNTS="$tmpdir/local_counts.tsv"

mysql -N -h"$DB_HOST_L" -u"$DB_USER_L" -p"$DB_PASS_L" "$DB_NAME" -e 'SHOW TABLES;' \
  | LC_ALL=C sort > "$LOCAL_TLIST"

: > "$LOCAL_COUNTS"
while read -r t; do
  c=$(mysql -N -h"$DB_HOST_L" -u"$DB_USER_L" -p"$DB_PASS_L" "$DB_NAME" -e "SELECT COUNT(*) FROM \`$t\`;") || c="ERR"
  printf "%s\t%s\n" "$t" "$c" >> "$LOCAL_COUNTS"
done < "$LOCAL_TLIST"

# ---------- 3) Compare ----------
ONLY_REMOTE="$tmpdir/only_remote.txt"
ONLY_LOCAL="$tmpdir/only_local.txt"
MISMATCH="$tmpdir/mismatch.tsv"

LC_ALL=C comm -23 "$REMOTE_TLIST" "$LOCAL_TLIST" > "$ONLY_REMOTE" || true
LC_ALL=C comm -13 "$REMOTE_TLIST" "$LOCAL_TLIST" > "$ONLY_LOCAL" || true

# Join on table name to align counts: table \t remote \t local
LC_ALL=C join -t $'\t' -j 1 "$REMOTE_COUNTS" "$LOCAL_COUNTS" \
  | awk -F'\t' '($2 != $3) {print $1 "\t" $2 "\t" $3}' > "$MISMATCH" || true

# ---------- 4) Report ----------
R_TAB=$(wc -l < "$REMOTE_TLIST")
L_TAB=$(wc -l < "$LOCAL_TLIST")
R_ONLY=$(wc -l < "$ONLY_REMOTE")
L_ONLY=$(wc -l < "$ONLY_LOCAL")
MIS=$(wc -l < "$MISMATCH")

echo
echo "==================== DB TABLE COMPARISON ===================="
echo "Database: $DB_NAME"
printf "Remote tables: %d\tLocal tables: %d\n" "$R_TAB" "$L_TAB"
printf "Only on remote: %d\tOnly on local: %d\tRow-count mismatches: %d\n" "$R_ONLY" "$L_ONLY" "$MIS"
echo "============================================================="
echo

show_head () {
  local title="$1" file="$2" cols="$3" max=30
  local n; n=$(wc -l < "$file")
  [[ "$n" -eq 0 ]] && return 0
  echo "--- $title (showing up to $max of $n) ---"
  if [[ "$cols" == "1" ]]; then
    head -n $max "$file"
  else
    # table \t remote \t local
    head -n $max "$file" | awk -F'\t' '{printf "%-48s  remote:%-10s  local:%-10s\n",$1,$2,$3}'
  fi
  echo
}

show_head "Tables only on REMOTE" "$ONLY_REMOTE" 1
show_head "Tables only on LOCAL"  "$ONLY_LOCAL"  1
show_head "Row-count mismatches (per table)" "$MISMATCH" 3

# Exit code semantics:
# 0 = perfect match (no missing tables, no mismatched counts)
# 1 = differences present
if [[ "$R_ONLY" -eq 0 && "$L_ONLY" -eq 0 && "$MIS" -eq 0 ]]; then
  ok "Databases match by table set and row counts."
  exit 0
else
  warn "Differences detected. See sections above."
  exit 1
fi
