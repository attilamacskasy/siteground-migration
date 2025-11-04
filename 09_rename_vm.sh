#!/usr/bin/env bash
set -euo pipefail

NEW_HOST="${1:-AT-P-BLG-LMP-U24-01}"
REGEN_MACHINE_ID="${REGEN_MACHINE_ID:-yes}"   # yes|no
REGEN_SSH_KEYS="${REGEN_SSH_KEYS:-no}"        # yes|no

red(){ echo -e "\e[31m$*\e[0m"; }
green(){ echo -e "\e[32m$*\e[0m"; }
blue(){ echo -e "\e[34m$*\e[0m"; }
yellow(){ echo -e "\e[33m$*\e[0m"; }

[[ $EUID -eq 0 ]] || { red "Run as root: sudo bash $0 [NEW_HOST]"; exit 1; }

OLD_HOST="$(hostnamectl --static || hostname)"
blue "Current hostname: $OLD_HOST"
blue "New hostname    : $NEW_HOST"

if [[ "$OLD_HOST" == "$NEW_HOST" ]]; then
  yellow "Hostname already set to $NEW_HOST — continuing with fixups."
fi

# 1) Set the hostname via systemd
hostnamectl set-hostname "$NEW_HOST"
green "Hostname set via hostnamectl."

# 2) Fix /etc/hosts mapping (127.0.1.1 is used by Debian/Ubuntu for local hostname)
if grep -qE '^127\.0\.1\.1\s' /etc/hosts; then
  sed -i "s/^127\.0\.1\.1\s\+.*/127.0.1.1\t$NEW_HOST/g" /etc/hosts
else
  echo -e "127.0.1.1\t$NEW_HOST" >> /etc/hosts
fi
# Ensure localhost lines exist (just in case)
grep -qE '^127\.0\.0\.1\s' /etc/hosts || echo "127.0.0.1\tlocalhost" >> /etc/hosts
green "/etc/hosts updated."

# 3) (Optional) Regenerate machine-id (recommended for cloned VMs)
if [[ "$REGEN_MACHINE_ID" == "yes" ]]; then
  blue "Regenerating machine-id (safe for clones)…"
  # Keep a backup just in case
  [[ -f /etc/machine-id ]] && cp -a /etc/machine-id /etc/machine-id.bak || true
  : > /etc/machine-id
  rm -f /var/lib/dbus/machine-id || true
  systemd-machine-id-setup >/dev/null
  ln -sf /etc/machine-id /var/lib/dbus/machine-id
  green "machine-id regenerated."
else
  yellow "Skipping machine-id regeneration (REGEN_MACHINE_ID=no)."
fi

# 4) (Optional) Regenerate SSH host keys so the clone has unique keys
if [[ "$REGEN_SSH_KEYS" == "yes" ]]; then
  blue "Regenerating OpenSSH host keys…"
  systemctl stop ssh || true
  rm -f /etc/ssh/ssh_host_* || true
  ssh-keygen -A
  systemctl start ssh
  green "SSH host keys regenerated."
else
  yellow "Skipping SSH host key regeneration (REGEN_SSH_KEYS=no)."
fi

# 5) Small nicety: show new prompt hostname and suggest reboot
blue "Verifying:"
echo -n "  Static hostname: "; hostnamectl --static
echo -n "  Pretty hostname: "; hostnamectl --pretty || true
echo -n "  /etc/hosts line: "; grep -E '^127\.0\.1\.1\s' /etc/hosts || true

green "Done. A reboot is recommended to ensure all services pick up the new hostname."
echo "Reboot now? (y/N)"
read -r ans
if [[ "${ans,,}" == "y" ]]; then
  reboot
else
  echo "You can reboot later with: sudo reboot"
fi
