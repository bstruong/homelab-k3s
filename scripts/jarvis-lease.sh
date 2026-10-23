#!/usr/bin/env bash
# Acquire / release / show an exclusive JARVIS lease.
#
#   ./scripts/jarvis-lease.sh acquire alpha-eval 45
#   ./scripts/jarvis-lease.sh release
#   ./scripts/jarvis-lease.sh show
set -euo pipefail

NS="${JARVIS_NAMESPACE:-jarvis}"
CONTEXT="${KUBE_CONTEXT:-}"
WATCHTOWER_SSH="${WATCHTOWER_SSH:-watchtower}"

k() {
  if [[ -n "${CONTEXT}" ]]; then
    kubectl --context="${CONTEXT}" "$@"
  elif [[ "$(hostname 2>/dev/null || true)" == "watchtower" ]]; then
    kubectl "$@"
  else
    ssh "${WATCHTOWER_SSH}" kubectl "$(printf '%q ' "$@")"
  fi
}

now_rfc3339() { date -u +%Y-%m-%dT%H:%M:%SZ; }

expires_in_minutes() {
  local mins="$1"
  date -u -d "+${mins} minutes" +%Y-%m-%dT%H:%M:%SZ
}

cmd="${1:-show}"
case "${cmd}" in
  show)
    k -n "${NS}" get configmap jarvis-lease -o yaml
    ;;
  acquire)
    holder="${2:-}"
    ttl_min="${3:-60}"
    if [[ -z "${holder}" ]]; then
      echo "Usage: $0 acquire <holder> [ttl-minutes]" >&2
      exit 1
    fi
    current="$(k -n "${NS}" get configmap jarvis-lease -o jsonpath='{.metadata.annotations.jarvis\.watchtower/holder}' || true)"
    expires="$(k -n "${NS}" get configmap jarvis-lease -o jsonpath='{.metadata.annotations.jarvis\.watchtower/expires-at}' || true)"
    now="$(now_rfc3339)"
    if [[ -n "${current}" && -n "${expires}" && "${expires}" > "${now}" && "${current}" != "${holder}" ]]; then
      echo "fail lease held by ${current} until ${expires}" >&2
      exit 1
    fi
    exp="$(expires_in_minutes "${ttl_min}")"
    k -n "${NS}" annotate configmap jarvis-lease \
      "jarvis.watchtower/holder=${holder}" \
      "jarvis.watchtower/expires-at=${exp}" \
      "jarvis.watchtower/last-activity-at=$(now_rfc3339)" \
      --overwrite
    k -n "${NS}" patch configmap jarvis-lease --type merge -p '{"data":{"status":"leased"}}'
    echo "ok  lease holder=${holder} expires=${exp}"
    ;;
  release)
    k -n "${NS}" annotate configmap jarvis-lease \
      "jarvis.watchtower/holder-" \
      "jarvis.watchtower/expires-at-" \
      "jarvis.watchtower/last-activity-at=$(now_rfc3339)" \
      --overwrite
    k -n "${NS}" patch configmap jarvis-lease --type merge -p '{"data":{"status":"idle"}}'
    echo "ok  lease released"
    ;;
  touch)
    # Refresh activity (and lease expiry if held by this holder).
    k -n "${NS}" annotate configmap jarvis-lease \
      "jarvis.watchtower/last-activity-at=$(now_rfc3339)" \
      --overwrite
    echo "ok  activity touched"
    ;;
  -h|--help|help)
    cat <<'EOF'
Usage:
  jarvis-lease.sh show
  jarvis-lease.sh acquire <holder> [ttl-minutes]
  jarvis-lease.sh release
  jarvis-lease.sh touch
EOF
    ;;
  *)
    echo "unknown command: ${cmd}" >&2
    exit 1
    ;;
esac
