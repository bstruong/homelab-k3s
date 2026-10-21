#!/usr/bin/env bash
# ==============================================================================
# reconcile-host-security.sh
# Authoritative host-level network security reconciliation script for
# Watchtower (Fedora Server / K3s) and Metrotower (workstation).
#
# Codifies:
# 1. LLMNR disablement on systemd-resolved (closes 5355/tcp+udp wildcard sockets).
# 2. Watchtower firewalld rules (restricts LAN to 22, 53, 80, 443, 9090 while
#    trusting cni0 10.42.0.0/16 and tailscale0).
# 3. Metrotower Docker daemon default IP binding (127.0.0.1) to eliminate UFW bypass.
# ==============================================================================

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; BLUE='\033[0;34m'; NC='\033[0m'
info() { printf '%b==>%b %s\n' "${BLUE}" "${NC}" "$*"; }
ok()   { printf '%b ok %b %s\n' "${GREEN}" "${NC}" "$*"; }
warn() { printf '%bwarn%b %s\n' "${YELLOW}" "${NC}" "$*"; }

if [[ $EUID -ne 0 ]]; then
  echo "Error: This script must be run as root (sudo)." >&2
  exit 1
fi

HOSTNAME_CURRENT="$(hostname 2>/dev/null || cat /etc/hostname 2>/dev/null || echo "unknown")"
info "Reconciling host network security on host: ${HOSTNAME_CURRENT}"

# 1. Disable LLMNR (Link-Local Multicast Name Resolution)
info "Checking systemd-resolved LLMNR configuration..."
mkdir -p /etc/systemd/resolved.conf.d
cat <<'EOF' > /etc/systemd/resolved.conf.d/no-llmnr.conf
# Managed by homelab-k3s: scripts/reconcile-host-security.sh
# Disables LLMNR (port 5355 tcp/udp) to prevent LAN spoofing/Responder vectors.
[Resolve]
LLMNR=no
EOF
if systemctl is-active --quiet systemd-resolved; then
  systemctl restart systemd-resolved
  ok "Disabled LLMNR and restarted systemd-resolved"
else
  warn "systemd-resolved is not active; configuration file written"
fi

# 2. Watchtower firewalld configuration
if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld; then
  info "Configuring firewalld on Watchtower..."
  
  # Ensure core services are allowed on default zone
  for svc in ssh cockpit dns http https; do
    firewall-cmd --permanent --add-service="${svc}" >/dev/null 2>&1 || true
  done
  
  # Ensure specific needed ports are allowed
  # DNS (TCP/UDP 53)
  firewall-cmd --permanent --add-port=53/tcp >/dev/null 2>&1 || true
  firewall-cmd --permanent --add-port=53/udp >/dev/null 2>&1 || true
  
  # Ensure internal cluster CNI (10.42.0.0/16) and tailscale0 are trusted
  firewall-cmd --permanent --zone=trusted --add-source=10.42.0.0/16 >/dev/null 2>&1 || true
  firewall-cmd --permanent --zone=trusted --add-interface=cni0 >/dev/null 2>&1 || true
  firewall-cmd --permanent --zone=trusted --add-interface=tailscale0 >/dev/null 2>&1 || true
  
  # Remove direct LAN exposure of high k3s nodeports or internal ports if present
  for p in 8080/tcp 8880/tcp 8882/tcp 8888/tcp 6443/tcp 10250/tcp 45876/tcp; do
    firewall-cmd --permanent --remove-port="${p}" >/dev/null 2>&1 || true
  done
  
  firewall-cmd --reload >/dev/null
  ok "firewalld rules reconciled and reloaded"
fi

# 3. Metrotower Docker default binding
if [[ -d /etc/docker ]] || command -v dockerd >/dev/null 2>&1; then
  info "Checking Docker daemon default binding IP..."
  mkdir -p /etc/docker
  if [[ ! -f /etc/docker/daemon.json ]]; then
    echo '{"ip": "127.0.0.1"}' > /etc/docker/daemon.json
    ok "Created /etc/docker/daemon.json with ip: 127.0.0.1"
  else
    if grep -q '"ip"' /etc/docker/daemon.json; then
      ok "/etc/docker/daemon.json already contains custom ip binding"
    else
      # Safely inject "ip": "127.0.0.1" into existing JSON
      python3 -c '
import json, sys
p = "/etc/docker/daemon.json"
with open(p, "r") as f:
    data = json.load(f)
data["ip"] = "127.0.0.1"
with open(p, "w") as f:
    json.dump(data, f, indent=2)
'
      ok "Injected ip: 127.0.0.1 into /etc/docker/daemon.json"
    fi
  fi
  if systemctl is-active --quiet docker; then
    warn "Docker is running. Restart docker service when convenient to apply default 127.0.0.1 binding."
  fi
fi

ok "Host security reconciliation complete on ${HOSTNAME_CURRENT}."
