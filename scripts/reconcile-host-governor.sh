#!/usr/bin/env bash
# ==============================================================================
# reconcile-host-governor.sh
# Authoritative host-level dynamic performance governor reconciliation script
# for Watchtower (Fedora Server / K3s / Zen 5 Ryzen 9700X + RTX 3060).
#
# Codifies:
# 1. /usr/local/bin/jarvis-governor.sh: Detects active llama-server inference.
#    - When active: CPU EPP -> performance, GPU Persistence -> 1, THP -> always.
#    - When idle: CPU EPP -> balance_performance, GPU Persistence -> 0, THP -> madvise.
# 2. Systemd service + timer (runs every 15s) to reconcile hardware states.
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
info "Reconciling JARVIS dynamic hardware governor on host: ${HOSTNAME_CURRENT}"

# 1. Deploy /usr/local/bin/jarvis-governor.sh
info "Installing /usr/local/bin/jarvis-governor.sh..."
cat <<'EOF' > /usr/local/bin/jarvis-governor.sh
#!/usr/bin/env bash
# Managed by homelab-k3s: scripts/reconcile-host-governor.sh
# Dynamically adjusts CPU EPP, GPU Persistence, and THP based on JARVIS activity.
set -euo pipefail

STATE_FILE="/run/jarvis-governor.state"
CURRENT_STATE="$(cat "${STATE_FILE}" 2>/dev/null || echo "unknown")"

# Check if llama-server container process is active on the host
if pgrep -f "llama-server" >/dev/null 2>&1; then
  TARGET_STATE="perf"
else
  TARGET_STATE="idle"
fi

if [[ "${CURRENT_STATE}" == "${TARGET_STATE}" ]]; then
  exit 0
fi

if [[ "${TARGET_STATE}" == "perf" ]]; then
  # 1. Boost CPU responsiveness on AMD Zen 5 cores
  for f in /sys/devices/system/cpu/cpu*/cpufreq/energy_performance_preference; do
    echo "performance" > "$f" 2>/dev/null || true
  done

  # 2. Lock GPU Persistence Mode to avoid driver reload / clock drop latencies
  nvidia-smi -pm 1 >/dev/null 2>&1 || true

  # 3. Transparent Huge Pages to 2MB to minimize MoE RAM TLB misses
  if [[ -f /sys/kernel/mm/transparent_hugepage/enabled ]]; then
    echo "always" > /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null || true
  fi

  echo "perf" > "${STATE_FILE}"
  logger -t jarvis-governor "JARVIS active: CPU EPP -> performance, GPU Persistence -> 1, THP -> always."
else
  # 1. Revert CPU to energy-saving balanced profile
  for f in /sys/devices/system/cpu/cpu*/cpufreq/energy_performance_preference; do
    echo "balance_performance" > "$f" 2>/dev/null || true
  done

  # 2. Allow GPU to enter deepest P8 low-power state (~8.9W)
  nvidia-smi -pm 0 >/dev/null 2>&1 || true

  # 3. Revert Transparent Huge Pages to madvise
  if [[ -f /sys/kernel/mm/transparent_hugepage/enabled ]]; then
    echo "madvise" > /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null || true
  fi

  echo "idle" > "${STATE_FILE}"
  logger -t jarvis-governor "JARVIS idle: CPU EPP -> balance_performance, GPU Persistence -> 0, THP -> madvise."
fi
EOF

chmod 0755 /usr/local/bin/jarvis-governor.sh
ok "Installed /usr/local/bin/jarvis-governor.sh"

# 2. Deploy systemd units
info "Deploying systemd service and timer units..."
cat <<'EOF' > /etc/systemd/system/jarvis-governor.service
[Unit]
Description=JARVIS Dynamic Hardware Performance Governor
After=network.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/jarvis-governor.sh
EOF

cat <<'EOF' > /etc/systemd/system/jarvis-governor.timer
[Unit]
Description=Run JARVIS Dynamic Hardware Performance Governor every 15s

[Timer]
OnBootSec=30s
OnUnitActiveSec=15s
AccuracySec=1s

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now jarvis-governor.timer
ok "Enabled and started jarvis-governor.timer (15s interval)"

# 3. Reconcile state immediately
/usr/local/bin/jarvis-governor.sh
ok "Current governor state reconciled: $(cat /run/jarvis-governor.state)"
