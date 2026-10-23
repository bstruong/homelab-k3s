#!/usr/bin/env bash
# Sleep JARVIS (scale →0). Refuses if an unexpired lease is held unless --force.
set -euo pipefail

NS="${JARVIS_NAMESPACE:-jarvis}"
DEP="${JARVIS_DEPLOYMENT:-jarvis}"
CONTEXT="${KUBE_CONTEXT:-}"
WATCHTOWER_SSH="${WATCHTOWER_SSH:-watchtower}"
FORCE=false

for arg in "$@"; do
  case "$arg" in
    --force) FORCE=true ;;
    -h|--help)
      echo "Usage: $0 [--force]"
      exit 0
      ;;
  esac
done

k() {
  if [[ -n "${CONTEXT}" ]]; then
    kubectl --context="${CONTEXT}" "$@"
  elif [[ "$(hostname 2>/dev/null || true)" == "watchtower" ]]; then
    kubectl "$@"
  else
    ssh "${WATCHTOWER_SSH}" kubectl "$(printf '%q ' "$@")"
  fi
}

holder="$(k -n "${NS}" get configmap jarvis-lease -o jsonpath='{.metadata.annotations.jarvis\.watchtower/holder}' 2>/dev/null || true)"
expires="$(k -n "${NS}" get configmap jarvis-lease -o jsonpath='{.metadata.annotations.jarvis\.watchtower/expires-at}' 2>/dev/null || true)"
now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

if [[ "${FORCE}" != true && -n "${holder}" && -n "${expires}" && "${expires}" > "${now}" ]]; then
  echo "fail active lease holder=${holder} expires=${expires} (pass --force to override)" >&2
  exit 1
fi

echo "==> sleeping ${NS}/${DEP}"
k -n "${NS}" scale deployment/"${DEP}" --replicas=0
echo "ok  scaled to 0"
