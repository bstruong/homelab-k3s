#!/usr/bin/env bash
# ==============================================================================
# audit-network-security.sh
# Repeatable network security audit script for the Watchtower homelab,
# based on Chris Titus Tech's network security guide.
#
# Audits:
# 1. Local listening ports & LLMNR state (ss -tuln).
# 2. Local firewall posture (ufw / firewalld / docker bypass).
# 3. Watchtower LAN exposure (cross-LAN probe from workstation).
# 4. Optional Watchtower Tailnet exposure (WATCHTOWER_TS_IP or auto-detect).
# 5. K3s cluster segmentation & NetworkPolicy enforcement.
#
# Tailnet probes: set WATCHTOWER_TS_IP to Watchtower's Tailscale IPv4, or leave
# unset to attempt `tailscale ip -4 watchtower`. If neither yields an address,
# the Tailnet section is skipped with a note (never false-PASS).
# ==============================================================================

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; BLUE='\033[0;34m'; NC='\033[0m'
info()  { printf '%b==>%b %s\n' "${BLUE}" "${NC}" "$*"; }
ok()    { printf '  %b[PASS]%b %s\n' "${GREEN}" "${NC}" "$*"; }
fail()  { printf '  %b[FAIL]%b %s\n' "${RED}"   "${NC}" "$*"; }
warn()  { printf '  %b[WARN]%b %s\n' "${YELLOW}" "${NC}" "$*"; }
skip()  { printf '  %b[SKIP]%b %s\n' "${YELLOW}" "${NC}" "$*"; }

WATCHTOWER_IP="${WATCHTOWER_IP:-192.0.2.10}"
WATCHTOWER_TS_IP="${WATCHTOWER_TS_IP:-}"
FAILURES=0

echo "=================================================================="
echo "          HOMELAB NETWORK SECURITY AUDIT REPORT                  "
echo "=================================================================="

# -------------------------------------------------------------------------
# 1. Local Host Audit
# -------------------------------------------------------------------------
HOSTNAME="$(hostname 2>/dev/null || cat /etc/hostname 2>/dev/null || echo "localhost")"
info "Auditing Local Host: ${HOSTNAME}"

# A. Firewall
if systemctl is-active --quiet ufw 2>/dev/null; then
  ok "UFW firewall is active"
elif systemctl is-active --quiet firewalld 2>/dev/null; then
  ok "firewalld is active"
else
  warn "No active UFW or firewalld detected on ${HOSTNAME}"
fi

# B. LLMNR (port 5355)
if ss -tuln 2>/dev/null | grep -q ':5355 '; then
  fail "LLMNR is listening on port 5355 (LAN spoofing vector). Disable with scripts/reconcile-host-security.sh"
  FAILURES=$((FAILURES + 1))
else
  ok "LLMNR (port 5355) is NOT listening on local host"
fi

# C. Docker 0.0.0.0 Exposure Check
if command -v docker >/dev/null 2>&1 && systemctl is-active --quiet docker 2>/dev/null; then
  DOCKER_WILDCARDS="$(docker ps --format '{{.Names}}: {{.Ports}}' 2>/dev/null | grep '0.0.0.0:' || true)"
  if [[ -n "${DOCKER_WILDCARDS}" ]]; then
    warn "Docker containers published on 0.0.0.0 (may bypass UFW):"
    while IFS= read -r line; do
      echo "        ${line}"
    done <<< "${DOCKER_WILDCARDS}"
  else
    ok "No Docker containers published on wildcard 0.0.0.0"
  fi
fi

# -------------------------------------------------------------------------
# 2. Watchtower LAN Exposure Audit (from LAN / Workstation)
# -------------------------------------------------------------------------
echo
info "Auditing Watchtower Gateway & Exposure (${WATCHTOWER_IP})"

probe_port() {
  local port="$1"
  timeout 1 bash -c "</dev/tcp/${WATCHTOWER_IP}/${port}" 2>/dev/null
}

# Ports that MUST be reachable on Watchtower from the LAN
EXPECTED_OPEN=(
  "22:SSH"
  "53:AdGuard DNS"
  "80:Traefik HTTP"
  "443:Traefik HTTPS"
  "9090:Cockpit"
)

# Ports that MUST NEVER be directly reachable from the LAN (filtered by firewalld)
EXPECTED_BLOCKED=(
  "5355:LLMNR"
  "6443:K3s API Server"
  "8080:llama-server (bypasses firewalld if hostPort lacks hostIP)"
  "8880:Dojo Static Server"
  "8882:Ruby Dojo"
  "8888:Python Dojo"
  "10250:Kubelet API"
  "45876:Beszel Agent"
)

for item in "${EXPECTED_OPEN[@]}"; do
  IFS=':' read -r port desc <<< "${item}"
  if probe_port "${port}"; then
    ok "Port ${port} (${desc}) is OPEN as expected"
  else
    fail "Port ${port} (${desc}) is CLOSED or unreachable"
    FAILURES=$((FAILURES + 1))
  fi
done

for item in "${EXPECTED_BLOCKED[@]}"; do
  IFS=':' read -r port desc <<< "${item}"
  if probe_port "${port}"; then
    fail "Port ${port} (${desc}) is OPEN to the LAN! Should be blocked by firewall or loopback-bound."
    FAILURES=$((FAILURES + 1))
  else
    ok "Port ${port} (${desc}) is protected / blocked from LAN"
  fi
done

# -------------------------------------------------------------------------
# 3. Watchtower Tailnet Exposure Audit (optional)
# -------------------------------------------------------------------------
echo
info "Auditing Watchtower Tailnet Exposure"

resolve_watchtower_ts_ip() {
  if [[ -n "${WATCHTOWER_TS_IP}" ]]; then
    printf '%s\n' "${WATCHTOWER_TS_IP}"
    return 0
  fi
  # Auto-detect peer "watchtower" via Tailscale CLI (not this host's own IP).
  if command -v tailscale >/dev/null 2>&1; then
    local detected=""
    detected="$(tailscale ip -4 watchtower 2>/dev/null | head -n1 || true)"
    if [[ -n "${detected}" && "${detected}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      printf '%s\n' "${detected}"
      return 0
    fi
  fi
  return 1
}

probe_ts_port() {
  local host="$1"
  local port="$2"
  timeout 1 bash -c "</dev/tcp/${host}/${port}" 2>/dev/null
}

# Must stay closed on Tailnet (same high-risk set as LAN blocked, minus nothing
# intentional). Cockpit 9090 is LAN-only and must also stay closed on Tailnet.
TS_EXPECTED_BLOCKED=(
  "5355:LLMNR"
  "6443:K3s API Server"
  "8080:llama-server (loopback hostPort / not published on Tailnet)"
  "8880:Dojo Static Server"
  "8882:Ruby Dojo"
  "8888:Python Dojo"
  "10250:Kubelet API"
  "45876:Beszel Agent"
  "9090:Cockpit (LAN-only)"
)

# Must stay open on Tailnet after Phase 2 firewall-tailscale.sh (ssh + Traefik).
TS_EXPECTED_OPEN=(
  "22:SSH"
  "80:Traefik HTTP"
  "443:Traefik HTTPS"
)

if TS_TARGET="$(resolve_watchtower_ts_ip)"; then
  info "Probing Tailnet target ${TS_TARGET} (WATCHTOWER_TS_IP or auto-detect)"
  for item in "${TS_EXPECTED_OPEN[@]}"; do
    IFS=':' read -r port desc <<< "${item}"
    if probe_ts_port "${TS_TARGET}" "${port}"; then
      ok "Tailnet port ${port} (${desc}) is OPEN as expected"
    else
      fail "Tailnet port ${port} (${desc}) is CLOSED or unreachable"
      FAILURES=$((FAILURES + 1))
    fi
  done
  for item in "${TS_EXPECTED_BLOCKED[@]}"; do
    IFS=':' read -r port desc <<< "${item}"
    if probe_ts_port "${TS_TARGET}" "${port}"; then
      fail "Tailnet port ${port} (${desc}) is OPEN! Should be blocked by Tailscale zone/ACLs."
      FAILURES=$((FAILURES + 1))
    else
      ok "Tailnet port ${port} (${desc}) is protected / blocked"
    fi
  done
else
  skip "WATCHTOWER_TS_IP unset and Tailscale IPv4 not auto-detected — skipping Tailnet probes (not a PASS)"
fi

# -------------------------------------------------------------------------
# 4. Kubernetes NetworkPolicy & Workload Drift Audit
# -------------------------------------------------------------------------
echo
info "Auditing K3s Cluster Segmentation (NetworkPolicy & Namespaces)"

k_cmd() {
  if command -v kubectl >/dev/null 2>&1 && kubectl cluster-info >/dev/null 2>&1; then
    kubectl "$@"
  elif ssh -o BatchMode=yes -o ConnectTimeout=3 watchtower "true" 2>/dev/null; then
    ssh -o BatchMode=yes -o ConnectTimeout=3 watchtower "kubectl $*" 2>/dev/null
  else
    return 1
  fi
}

if k_cmd cluster-info >/dev/null 2>&1; then
  # Check NetworkPolicies
  for ns in caster immich docs identity jarvis; do
    POLICIES="$(k_cmd -n "${ns}" get networkpolicy -o name 2>/dev/null || true)"
    if [[ -n "${POLICIES}" ]]; then
      ok "Namespace '${ns}' has NetworkPolicy enforced (${POLICIES})"
    else
      warn "Namespace '${ns}' has NO NetworkPolicy (open east-west traffic)"
    fi
  done

  # Check for retired leftover workloads
  if k_cmd get ns gemma >/dev/null 2>&1; then
    warn "Retired namespace 'gemma' still exists on the cluster"
  else
    ok "Retired namespace 'gemma' is clean"
  fi

  if k_cmd -n alpha get deploy alpha-llama >/dev/null 2>&1; then
    fail "Retired deployment alpha/alpha-llama still exists — delete it (JARVIS owns the GPU)"
    FAILURES=$((FAILURES + 1))
  else
    ok "Retired deployment alpha/alpha-llama is gone"
  fi

  if k_cmd -n alpha get pvc alpha-models >/dev/null 2>&1; then
    warn "Stale PVC alpha/alpha-models still present (safe to delete after jarvis-models is Bound; never delete /mnt/models)"
  else
    ok "Stale PVC alpha/alpha-models is clean"
  fi

  if k_cmd get ns odysseus >/dev/null 2>&1; then
    ok "Self-hosted namespace 'odysseus' is present on the cluster"
  fi
else
  warn "kubectl cluster not reachable from current context or SSH — skipping in-cluster checks"
fi

echo "=================================================================="
if [[ ${FAILURES} -eq 0 ]]; then
  printf '%bAUDIT PASSED:%b All audited network security checks succeeded.\n' "${GREEN}" "${NC}"
  exit 0
else
  printf '%bAUDIT FAILED:%b %d security violation(s) detected. See above.\n' "${RED}" "${NC}" "${FAILURES}"
  exit 1
fi
