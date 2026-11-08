#!/usr/bin/env bash
# Install and enable Tailscale on Watchtower (Fedora Server).
# Run on the server (console or ssh watchtower-lan): sudo bash install-tailscale.sh
set -euo pipefail

if [[ $(id -u) -ne 0 ]]; then
  echo "Run as root: sudo $0" >&2
  exit 1
fi

if ! command -v tailscale >/dev/null 2>&1; then
  echo "→ Installing tailscale"
  dnf install -y tailscale
fi

systemctl enable --now tailscaled
echo "→ Starting Tailscale login (open the printed URL if prompted)"
# --operator allows the invoking sudo user to run tailscale without root later.
operator="${SUDO_USER:-homelab}"
tailscale up --accept-dns --operator="$operator"
tailscale status
echo "✓ Tailscale installed. MagicDNS short name should be the machine hostname (watchtower)."
