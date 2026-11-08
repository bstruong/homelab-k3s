#!/usr/bin/env bash
# SSH hardening drop-in for Watchtower. Key-only, no root login over SSH.
# Run: sudo bash harden-sshd.sh
# Ensure your ed25519 key works (ssh watchtower-lan) BEFORE running — password auth is disabled.
set -euo pipefail

if [[ $(id -u) -ne 0 ]]; then
  echo "Run as root: sudo $0" >&2
  exit 1
fi

dropin=/etc/ssh/sshd_config.d/90-watchtower-hardening.conf
cat >"$dropin" <<'EOF'
# Managed by homelab-k3s scripts/harden-sshd.sh
PasswordAuthentication no
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
PermitRootLogin no
PubkeyAuthentication yes
AuthenticationMethods publickey
EOF

if ss -tlnp | grep -q ':22 '; then
  if systemctl reload sshd 2>/dev/null || systemctl reload ssh 2>/dev/null; then
    echo "✓ sshd reloaded with $dropin"
  else
    echo "⚠ Wrote $dropin but could not reload sshd — reload manually" >&2
  fi
else
  echo "✓ Wrote $dropin (sshd not listening on :22 yet; will apply on next start)"
fi

echo "Verify from another session: ssh -o BatchMode=yes watchtower-lan true"
