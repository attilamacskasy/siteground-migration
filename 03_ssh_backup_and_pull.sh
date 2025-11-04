#!/usr/bin/env bash
set -euo pipefail

# ---------------- REMOTE SETTINGS ----------------
SSH_ALIAS="sg-ssh"
SSH_HOST="ssh.cloudmigration.blog"
SSH_PORT="18765"
SSH_USER="u1087-bgbtdthofrcy"
SSH_KEY_DEFAULT="siteground_ed25519"

# Candidate WP paths to probe
REMOTE_CANDIDATES=(
  "~/www/cloudmigration.blog/public_html"
  "~/cloudmigration.blog/public_html"
  "~/public_html"
)

# Archive name on remote
REMOTE_TMP="~/cloudmigration_blog_backup.tgz"

# ---------------- LOCAL SETTINGS -----------------
LOCAL_DIR="/var/www/cloudmigration.blog.ssh"
TMP_DIR="/tmp/cloudmigration_sg"

# --------------- USER / PERMS --------------------
REAL_USER="${SUDO_USER:-$USER}"
REAL_HOME="$(getent passwd "$REAL_USER" | cut -d: -f6)"
REAL_SSH_DIR="${REAL_HOME}/.ssh"
REAL_KEY_PATH="${REAL_SSH_DIR}/${SSH_KEY_DEFAULT}"

blue()  { echo -e "\e[34m$*\e[0m"; }
green() { echo -e "\e[32m$*\e[0m"; }
yellow(){ echo -e "\e[33m$*\e[0m"; }
red()   { echo -e "\e[31m$*\e[0m"; }

alias_usable() { [[ -r "${REAL_SSH_DIR}/config" ]] && sudo -u "$REAL_USER" bash -lc "ssh -G ${SSH_ALIAS} >/dev/null 2>&1"; }
if alias_usable; then
  blue "Using SSH alias '${SSH_ALIAS}' from ${REAL_SSH_DIR}/config"
  SSH_RUN=(sudo -u "$REAL_USER" ssh "$SSH_ALIAS")
  SCP_RUN=(sudo -u "$REAL_USER" scp -P "$SSH_PORT" "$SSH_ALIAS:")
else
  blue "Alias '${SSH_ALIAS}' not usable under sudo — using explicit host/port/key fallback."
  EXTRA_IDOPT=()
  [[ -f "$REAL_KEY_PATH" ]] && EXTRA_IDOPT=(-i "$REAL_KEY_PATH")
  SSH_RUN=(sudo -u "$REAL_USER" ssh -p "$SSH_PORT" "${EXTRA_IDOPT[@]}" "${SSH_USER}@${SSH_HOST}")
  SCP_RUN=(sudo -u "$REAL_USER" scp -P "$SSH_PORT" "${EXTRA_IDOPT[@]}" "${SSH_USER}@${SSH_HOST}:")
fi

detect_remote_dir() {
  local probe="
set -e
for d in ${REMOTE_CANDIDATES[*]}; do
  dd=\${d/#\~/$HOME}
  if [ -d \"\$dd\" ]; then echo \"\$dd\"; exit 0; fi
done
echo NO_MATCH; exit 1
"
  "${SSH_RUN[@]}" "$probe"
}

blue "=== SSH site snapshot → ${LOCAL_DIR} ==="
sudo mkdir -p "$LOCAL_DIR"
mkdir -p "$TMP_DIR"
sudo chown -R "$REAL_USER":"$REAL_USER" "$TMP_DIR"

# 0) Find the actual WP root
blue "[0/5] Detecting remote WordPress path…"
REMOTE_DIR="$(detect_remote_dir || true)"
if [[ "$REMOTE_DIR" == "NO_MATCH" || -z "$REMOTE_DIR" ]]; then
  red "[ERR] Could not find WordPress directory. Adjust REMOTE_CANDIDATES."
  exit 1
fi
green "✓ Remote path: $REMOTE_DIR"
REMOTE_PARENT="$(dirname "$REMOTE_DIR")"
REMOTE_BASENAME="$(basename "$REMOTE_DIR")"
ARCHIVE_NAME="$(basename "$REMOTE_TMP")"

# 1) Freeze site (maintenance mode) if possible
blue "[1/5] Enabling maintenance mode during snapshot…"
"${SSH_RUN[@]}" "set -e
if command -v wp >/dev/null 2>&1; then
  wp maintenance-mode activate --path=\"$REMOTE_DIR\" || true
else
  echo \"<?php \$upgrading = time();\" > \"$REMOTE_DIR/.maintenance\" || true
fi
"

# 2) Create archive (exclude volatile stuff, suppress 'file changed' warning)
blue "[2/5] Compressing remote directory (excluding caches/logs)…"
EXCLUDES=(
  "--exclude=$REMOTE_BASENAME/wp-content/cache"
  "--exclude=$REMOTE_BASENAME/wp-content/cache/*"
  "--exclude=$REMOTE_BASENAME/wp-content/debug.log"
  "--exclude=$REMOTE_BASENAME/wp-content/*.log"
  "--exclude=$REMOTE_BASENAME/wp-content/updraft"
  "--exclude=$REMOTE_BASENAME/wp-content/ai1wm-backups"
  "--exclude=$REMOTE_BASENAME/wp-content/wflogs"
  "--exclude=$REMOTE_BASENAME/error_log"
  "--exclude=$REMOTE_BASENAME/*.tmp"
  "--exclude=$REMOTE_BASENAME/.well-known/acme-challenge"
)
EX_STR="${EXCLUDES[*]}"

# run tar with warnings suppressed; still non-zero on real failures
"${SSH_RUN[@]}" "set -e
cd \"$REMOTE_PARENT\"
tar --warning=no-file-changed -czf ${REMOTE_TMP} ${EX_STR} \"$REMOTE_BASENAME\"
ls -lh ${REMOTE_TMP}
" || { red "[ERR] Remote compression failed."; 
       "${SSH_RUN[@]}" "rm -f \"$REMOTE_DIR/.maintenance\" 2>/dev/null || true; wp maintenance-mode deactivate --path=\"$REMOTE_DIR\" >/dev/null 2>&1 || true"; 
       exit 1; }

# 3) Unfreeze site
blue "[3/5] Disabling maintenance mode…"
"${SSH_RUN[@]}" "set -e
if command -v wp >/dev/null 2>&1; then
  wp maintenance-mode deactivate --path=\"$REMOTE_DIR\" || true
else
  rm -f \"$REMOTE_DIR/.maintenance\" || true
fi
"

# 4) Download + extract locally
blue "[4/5] Downloading archive → ${TMP_DIR}/"
"${SCP_RUN[@]}${REMOTE_TMP}" "${TMP_DIR}/" || { red "[ERR] SCP download failed."; exit 1; }

blue "[5/5] Extracting into ${LOCAL_DIR} …"
sudo tar -xzf "${TMP_DIR}/${ARCHIVE_NAME}" -C "${LOCAL_DIR}/"
sudo chown -R www-data:www-data "${LOCAL_DIR}"
green "✓ Extraction complete."

# Quick size sanity
REMOTE_INFO="$("${SSH_RUN[@]}" "du -sh \"$REMOTE_DIR\" 2>/dev/null || true")"
LOCAL_INFO="$(sudo du -sh "${LOCAL_DIR}/${REMOTE_BASENAME}" 2>/dev/null || true)"
echo "────────────────────────────────────────────"
echo "Remote total: ${REMOTE_INFO:-unavailable}"
echo "Local  total: ${LOCAL_INFO:-unavailable}"
echo "────────────────────────────────────────────"
green "✓ SSH site transfer completed."
echo "Archive: ${TMP_DIR}/${ARCHIVE_NAME}"
echo "Extracted: ${LOCAL_DIR}/${REMOTE_BASENAME}"

# Optional cleanup on remote
read -r -p "Delete remote archive ${REMOTE_TMP}? [y/N]: " yn
if [[ "${yn,,}" == "y" ]]; then
  "${SSH_RUN[@]}" "rm -f ${REMOTE_TMP}" && green "✓ Remote archive removed."
else
  yellow "Remote archive kept at ${REMOTE_TMP}"
fi

