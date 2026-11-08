#!/usr/bin/env bash
# Sole Tailscale firewalld owner for Watchtower.
# Creates/uses zone "tailscale", binds tailscale0 (or CGNAT fallback), allows
# only ssh + 80/tcp + 443/tcp, and removes tailscale0 from trusted if present.
# Does not touch FedoraServer / internal / home (LAN ssh must keep working).
#
# Apply order (Phase 2 / after reconcile): patched reconcile-host-security.sh
# first (LAN + CNI trust, no tailscale0), then this script.
# Run on Watchtower: sudo bash scripts/firewall-tailscale.sh
set -euo pipefail

if [[ $(id -u) -ne 0 ]]; then
  echo "Run as root: sudo $0" >&2
  exit 1
fi

if ! command -v firewall-cmd >/dev/null 2>&1; then
  echo "firewall-cmd not found — install firewalld or adapt for nftables" >&2
  exit 1
fi

firewall-cmd --state >/dev/null

if firewall-cmd --get-zones | tr ' ' '\n' | grep -qx tailscale; then
  echo "→ Using existing firewalld zone: tailscale"
else
  echo "→ Creating firewalld zone: tailscale"
  firewall-cmd --permanent --new-zone=tailscale || true
  firewall-cmd --permanent --zone=tailscale --set-description="Tailscale mesh (off-LAN access)"
fi

# Explicitly untrust Tailscale before binding the dedicated zone (idempotent).
# An interface belongs to one zone; leaving it in trusted would keep full bypass.
if firewall-cmd --permanent --zone=trusted --query-interface=tailscale0 >/dev/null 2>&1; then
  echo "→ Removing tailscale0 from trusted zone"
  firewall-cmd --permanent --zone=trusted --remove-interface=tailscale0 || true
fi

# Prefer binding the zone to the Tailscale interface; fall back to CGNAT source range.
firewall-cmd --permanent --zone=tailscale --add-interface=tailscale0 2>/dev/null || \
  firewall-cmd --permanent --zone=tailscale --add-source=100.64.0.0/10

firewall-cmd --permanent --zone=tailscale --add-service=ssh || true
firewall-cmd --permanent --zone=tailscale --add-port=80/tcp || true
firewall-cmd --permanent --zone=tailscale --add-port=443/tcp || true

# Drop former allowlist entries (Cockpit / raw JARVIS hostPort stay off Tailnet).
for port in 8080/tcp 9090/tcp; do
  firewall-cmd --permanent --zone=tailscale --remove-port="$port" 2>/dev/null || true
done

# Strip inference/admin from zones that typically face the WAN — do NOT touch
# FedoraServer / internal / home (LAN ssh must keep working for watchtower-lan).
for zone in public external; do
  if firewall-cmd --get-zones | tr ' ' '\n' | grep -qx "$zone"; then
    firewall-cmd --permanent --zone="$zone" --remove-port=8080/tcp 2>/dev/null || true
    firewall-cmd --permanent --zone="$zone" --remove-port=9090/tcp 2>/dev/null || true
  fi
done

firewall-cmd --reload
echo "→ Active zones:"
firewall-cmd --get-active-zones
echo "✓ Firewall updated for Tailscale (zone allows ssh + 80/tcp + 443/tcp only)."
echo "  Confirm the router has no inbound port-forwards to this host for 22/80/443/8080/9090."
echo "  LAN SSH (FedoraServer / internal) was left unchanged for watchtower-lan."
