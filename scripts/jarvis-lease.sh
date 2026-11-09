#!/usr/bin/env bash
# Acquire / release / show the exclusive JARVIS GPU lease (native Lease + CM dual-read).
#
# Prefer scripts/jarvis-session.sh begin|heartbeat|end for campaign Jobs.
#
#   ./scripts/jarvis-lease.sh acquire alpha-eval 45 [run-id]
#   ./scripts/jarvis-lease.sh release
#   ./scripts/jarvis-lease.sh show
#   ./scripts/jarvis-lease.sh touch
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/jarvis-common.sh"

cmd="${1:-show}"
case "${cmd}" in
  show|status)
    "${SCRIPT_DIR}/jarvis-session.sh" status
    ;;
  acquire)
    holder="${2:-}"
    ttl_min="${3:-60}"
    run_id="${4:-}"
    if [[ -z "${holder}" ]]; then
      echo "Usage: $0 acquire <holder> [ttl-minutes] [run-id]" >&2
      exit 1
    fi
    jarvis_lease_acquire "${holder}" "${ttl_min}" "${run_id}"
    ;;
  release)
    holder="${2:-${JARVIS_LEASE_HOLDER:-}}"
    jarvis_lease_release "${holder}"
    ;;
  touch|heartbeat)
    holder="${2:-${JARVIS_LEASE_HOLDER:-}}"
    ttl_min="${3:-${JARVIS_LEASE_MINUTES:-}}"
    if [[ -z "${holder}" ]]; then
      jarvis_touch_activity
      echo "ok  activity touched"
    else
      jarvis_lease_heartbeat "${holder}" "${ttl_min}"
    fi
    ;;
  -h|--help|help)
    cat <<'EOF'
Usage:
  jarvis-lease.sh show
  jarvis-lease.sh acquire <holder> [ttl-minutes] [run-id]
  jarvis-lease.sh release [holder]
  jarvis-lease.sh touch|heartbeat [holder] [ttl-minutes]
EOF
    ;;
  *)
    echo "unknown command: ${cmd}" >&2
    exit 1
    ;;
esac
