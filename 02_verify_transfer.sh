#!/usr/bin/env bash
set -euo pipefail

# --------- EDIT THESE ---------
REMOTE_PROTO="ftp"                        # ftp | ftps | sftp
REMOTE_HOST="ftp.cloudmigration.blog"
REMOTE_USER="attila@cloudmigration.blog"
REMOTE_PASS="***"
REMOTE_PATH="/cloudmigration.blog/public_html"
LOCAL_PATH="/var/www/cloudmigration.blog"
# --------------------------------

LOG="/root/02_verify_transfer.log"
exec > >(tee -a "$LOG") 2>&1

info(){ echo -e "\e[34m[INFO]\e[0m  $*"; }
ok(){   echo -e "\e[32m[OK]\e[0m    $*"; }
warn(){ echo -e "\e[33m[WARN]\e[0m  $*"; }
err(){  echo -e "\e[31m[ERR]\e[0m   $*"; }
dbg(){  echo -e "\e[36m[DEBUG]\e[0m $*"; }

need(){ command -v "$1" >/dev/null 2>&1 || { err "Missing command: $1"; exit 1; }; }
need lftp
need awk
need find

# ---------- LOCAL TOTALS ----------
local_totals() {
  dbg "Scanning local directory tree (${LOCAL_PATH}) …"
  local bytes files
  bytes=$(find "$LOCAL_PATH" -type f -printf '%s\n' | awk '{s+=$1} END{print s+0}')
  files=$(find "$LOCAL_PATH" -type f | wc -l | awk '{print $1}')
  echo "$files $bytes"
}

# ---------- REMOTE CONNECTION CONFIG ----------
lftp_open_header() {
  case "$REMOTE_PROTO" in
    ftp)
      cat <<'EOF'
set cmd:fail-exit true
set net:timeout 30
set net:max-retries 2
set ftp:ssl-allow no
set ftp:passive-mode true
set ftp:prefer-epsv false
EOF
      ;;
    ftps)
      cat <<'EOF'
set cmd:fail-exit true
set net:timeout 30
set net:max-retries 2
set ftp:ssl-allow yes
set ssl:verify-certificate no
set ftp:passive-mode true
set ftp:prefer-epsv false
EOF
      ;;
    sftp)
      cat <<'EOF'
set cmd:fail-exit true
set net:timeout 30
set net:max-retries 2
set sftp:auto-confirm yes
EOF
      ;;
    *)
      err "Unsupported REMOTE_PROTO: $REMOTE_PROTO"; exit 1;;
  esac
}

# ---------- REMOTE TOTALS ----------
remote_bytes() {
  dbg "Running remote du -b -s to calculate total bytes …"
  lftp -u "${REMOTE_USER},${REMOTE_PASS}" "${REMOTE_PROTO}://${REMOTE_HOST}" -e "
$(lftp_open_header)
du -b -s ${REMOTE_PATH}
bye
" 2>/dev/null | awk 'NF>=1{print $1; exit}'
}

remote_files() {
  dbg "Running remote recursive listing via find -d (this may take a while) …"
  # show incremental debug output every 500 files to visualize progress
  local count=0
  lftp -u "${REMOTE_USER},${REMOTE_PASS}" "${REMOTE_PROTO}://${REMOTE_HOST}" -e "
$(lftp_open_header)
find -d ${REMOTE_PATH}
bye
" 2>/dev/null | awk '
  NF==0 {next}
  /\/$/ {next}
  {c++}
  (c % 500 == 0) {printf("[DEBUG] Processed %d remote files…\n", c) > "/dev/stderr"}
  END{print c+0}
'
}

# ---------- MAIN ----------
info "Calculating REMOTE totals from ${REMOTE_PROTO}://${REMOTE_HOST}${REMOTE_PATH} …"

RB=""; RF=""
for i in 1 2 3; do
  RB="$(remote_bytes || true)"
  [[ -n "$RB" && "$RB" =~ ^[0-9]+$ ]] && break || sleep 1
done
for i in 1 2 3; do
  RF="$(remote_files || true)"
  [[ -n "$RF" && "$RF" =~ ^[0-9]+$ ]] && break || sleep 1
done

if [[ -z "$RB" || -z "$RF" ]]; then
  warn "Remote listing returned no usable data."
  echo "Try manual checks (use your real password, not ***):"
  echo "  lftp -u \"${REMOTE_USER},<PASS>\" ftp://${REMOTE_HOST} -e \"set ftp:ssl-allow no; set ftp:passive-mode true; du -b -s ${REMOTE_PATH}; bye\""
  echo "  lftp -u \"${REMOTE_USER},<PASS>\" ftp://${REMOTE_HOST} -e \"set ftp:ssl-allow no; set ftp:passive-mode true; find -d ${REMOTE_PATH} | head -50; bye\""
  exit 2
fi

ok  "Remote files: ${RF}"
ok  "Remote bytes: ${RB}"

info "Calculating LOCAL totals from ${LOCAL_PATH} …"
read -r LF LB < <(local_totals)
LF=${LF:-0}; LB=${LB:-0}
ok  "Local files:  ${LF}"
ok  "Local bytes:  ${LB}"

# ---------- SUMMARY ----------
echo
echo "================= TRANSFER SUMMARY ================="
printf "Files  : remote=%-12s local=%-12s delta=%s\n" "$RF" "$LF" "$((LF-RF))"
printf "Bytes  : remote=%-12s local=%-12s delta=%s\n" "$RB" "$LB" "$((LB-RB))"
echo "===================================================="
echo

EXIT=0
[[ "$LF" -ne "$RF" ]] && { warn "File count mismatch."; EXIT=3; }
[[ "$LB" -ne "$RB" ]] && { warn "Total bytes mismatch."; EXIT=$((EXIT==0?4:EXIT)); }

if [[ "$EXIT" -eq 0 ]]; then
  ok "Source and destination match in file count and total bytes."
else
  warn "Mismatch detected. Consider re-running your mirror or spot-checking differences."
fi

exit "$EXIT"

