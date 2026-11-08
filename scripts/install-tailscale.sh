#!/usr/bin/env bash
# Install and enable Tailscale on Watchtower (Fedora Server).
# Run on the server (console or LAN SSH): sudo bash scripts/install-tailscale.sh
set -euo pipefail

if [[ $(id -u) -ne 0 ]]; then
  echo "Run as root: sudo $0" >&2
  exit 1
fi

# Prefer the invoking login user for --operator; never hardcode a username in-repo.
if [[ -z "${SUDO_USER:-}" || "${SUDO_USER}" == root ]]; then
  echo "Run this script with sudo from your login user so Tailscale --operator can be set." >&2
  exit 1
fi
operator="$SUDO_USER"

if ! command -v tailscale >/dev/null 2>&1; then
  echo "→ Installing tailscale"
  dnf install -y tailscale
fi

systemctl enable --now tailscaled
echo "→ Starting Tailscale login (open the printed URL if prompted)"
tailscale up --accept-dns --operator="$operator"
tailscale status
echo "✓ Tailscale installed. Prefer MagicDNS short hostname (machine hostname) for clients."
