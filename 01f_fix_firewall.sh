#!/usr/bin/env bash
set -euo pipefail

info(){ echo -e "\e[34m[INFO]\e[0m  $*"; }
pass(){ echo -e "\e[32m[PASS]\e[0m $*"; }
warn(){ echo -e "\e[33m[WARN]\e[0m $*"; }
err(){  echo -e "\e[31m[ERR]\e[0m  $*"; }

command -v ufw >/dev/null 2>&1 || { err "UFW not installed"; exit 1; }

info "Ensuring SSH stays open…"
ufw allow OpenSSH >/dev/null 2>&1 || ufw allow 22/tcp >/dev/null 2>&1 || true

if ! ufw status | grep -q "Status: active"; then
  info "Enabling UFW…"
  yes | ufw enable >/dev/null
fi

cleanup_denies() {
  local port="$1"
  local changed=0
  while true; do
    # Re-grab numbered status each loop (numbers shift after deletes)
    mapfile -t LINES < <(ufw status numbered | sed -e 's/^\[ \([0-9]\+\) \]/\1: /')
    local del=""
    for line in "${LINES[@]}"; do
      # Example line: "3: 80/tcp                     DENY       Anywhere"
      if [[ "$line" =~ ^([0-9]+):\ .*${port}/tcp[[:space:]]+DENY[[:space:]] ]]; then
        del="${BASH_REMATCH[1]}"
        break
      fi
    done
    if [[ -n "$del" ]]; then
      info "Removing DENY rule #${del} for ${port}/tcp…"
      yes | ufw delete "${del}" >/dev/null
      changed=1
    else
      break
    fi
  done
  return $changed
}

# Remove any existing DENY for 80/443 (v4/v6 covered by same rule numbers)
cleanup_denies 80 || true
cleanup_denies 443 || true

# Add explicit ALLOW rules (even if Apache app profile exists)
info "Allowing 80/tcp and 443/tcp explicitly…"
ufw allow 80/tcp >/dev/null 2>&1 || true
ufw allow 443/tcp >/devnull 2>&1 || true

# Reload to be neat
ufw reload >/dev/null || true

# Show status
STATUS="$(ufw status)"
echo "$STATUS"

if echo "$STATUS" | grep -qE '(^| )80/tcp[[:space:]]+ALLOW'; then
  pass "UFW shows 80/tcp allowed"
else
  warn "80/tcp still not listed as ALLOW — check for interface-specific policies or your verify regex."
fi

if echo "$STATUS" | grep -qE '(^| )443/tcp[[:space:]]+ALLOW'; then
  pass "UFW shows 443/tcp allowed"
else
  warn "443/tcp still not listed as ALLOW — check for interface-specific policies or your verify regex."
fi

info "Done. Re-run: sudo bash 01_verify_ubuntu.sh"

