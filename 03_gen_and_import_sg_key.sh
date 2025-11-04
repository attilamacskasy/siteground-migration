#!/usr/bin/env bash
set -euo pipefail

# --------- EDIT IF YOU WANT DIFFERENT NAMES ---------
SG_HOST="ssh.cloudmigration.blog"
SG_PORT="18765"
SG_USER="u1087-bgbtdthofrcy"
KEY_NAME="siteground_ed25519"                 # filename stem under ~/.ssh/
SSH_ALIAS="sg-ssh"                            # 'ssh sg-ssh' to connect
# ----------------------------------------------------

KEY_DIR="${HOME}/.ssh"
PRIV="${KEY_DIR}/${KEY_NAME}"
PUB="${PRIV}.pub"
CONFIG="${KEY_DIR}/config"

blue(){ echo -e "\e[34m$*\e[0m"; }
green(){ echo -e "\e[32m$*\e[0m"; }
yellow(){ echo -e "\e[33m$*\e[0m"; }
red(){ echo -e "\e[31m$*\e[0m"; }

mkdir -p "${KEY_DIR}" && chmod 700 "${KEY_DIR}"

# 1) Generate key if missing (prefer ed25519; fall back to RSA if old OpenSSH)
if [[ -f "${PRIV}" ]]; then
  green "✓ SSH private key already exists: ${PRIV}"
else
  blue "Generating SSH keypair (${PRIV})…"
  if ssh-keygen -t ed25519 -C "${SG_USER}@${SG_HOST}" -f "${PRIV}"; then
    :
  else
    yellow "ed25519 not supported here, falling back to RSA 4096…"
    ssh-keygen -t rsa -b 4096 -C "${SG_USER}@${SG_HOST}" -f "${PRIV}"
  fi
fi

chmod 600 "${PRIV}"
chmod 644 "${PUB}"

# 2) Print the public key (this is what you paste in SG → SSH Keys → IMPORT → Public key)
blue "\n────────── COPY THE TEXT BELOW INTO SiteGround → SSH Keys Manager → IMPORT → Public key ──────────"
cat "${PUB}"
blue "──────────────────────────────────────────────────────────────────────────────────────────────────\n"

# (Optional) Copy to clipboard if xclip/wl-copy/pbcopy exists
if command -v xclip >/dev/null 2>&1; then
  cat "${PUB}" | xclip -selection clipboard && green "✓ Public key copied to clipboard (xclip)."
elif command -v wl-copy >/dev/null 2>&1; then
  cat "${PUB}" | wl-copy && green "✓ Public key copied to clipboard (wl-copy)."
elif command -v pbcopy >/dev/null 2>&1; then
  cat "${PUB}" | pbcopy && green "✓ Public key copied to clipboard (pbcopy)."
else
  yellow "Clipboard tool not found (xclip/wl-copy/pbcopy). Manual copy is fine."
fi

# 3) Write/update ~/.ssh/config with a friendly alias
blue "Configuring SSH alias '${SSH_ALIAS}' in ${CONFIG}…"
touch "${CONFIG}" && chmod 600 "${CONFIG}"

# remove existing block for the same alias (idempotent)
tmpcfg="$(mktemp)"
awk -v alias="${SSH_ALIAS}" '
  BEGIN{skip=0}
  /^Host[[:space:]]+/ {
    if ($2==alias) {skip=1; next}
    else {skip=0}
  }
  skip==0 {print}
' "${CONFIG}" > "${tmpcfg}" || true
mv "${tmpcfg}" "${CONFIG}"

cat >> "${CONFIG}" <<EOF

Host ${SSH_ALIAS}
    HostName ${SG_HOST}
    Port ${SG_PORT}
    User ${SG_USER}
    IdentityFile ${PRIV}
    IdentitiesOnly yes
    # The next two lines avoid interactivity on first connect. Remove later if you prefer strict checking.
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null
EOF

green "✓ SSH alias '${SSH_ALIAS}' created."

# 4) Guide the user to SG portal, then optional test
cat <<MSG

Next steps:
1) Open Site Tools → Security → SSH Keys Manager → IMPORT tab.
2) Paste the public key you saw above into "Public key". Give it a Key Name.
3) (If SiteGround requires it) Allow your IP in "Manage IP Access".
4) Then press ENTER here to test the connection (or Ctrl+C to skip).
MSG
read -r -p ""

blue "Testing SSH connection (this may prompt for your *key passphrase* if you set one)…"
set +e
ssh "${SSH_ALIAS}" -- 'echo "[remote] Connected as: $(whoami) @ $(hostname)"; pwd'
rc=$?
set -e

if [[ $rc -eq 0 ]]; then
  green "✓ SSH connection works. Use:  ssh ${SSH_ALIAS}"
else
  red "SSH test failed."
  echo "Troubleshooting:"
  echo "  • Make sure you imported the PUBLIC key above into SiteGround (IMPORT tab)."
  echo "  • Confirm your IP is allowed in the portal (Manage IP Access)."
  echo "  • If you set a key passphrase, enter it when prompted."
  echo "  • Manual command to try:"
  echo "      ssh -i ${PRIV} -p ${SG_PORT} ${SG_USER}@${SG_HOST}"
fi

