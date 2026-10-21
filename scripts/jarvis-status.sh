#!/usr/bin/env bash
# Print JARVIS deployment, lease, and HTTP health.
set -euo pipefail

NS="${JARVIS_NAMESPACE:-jarvis}"
DEP="${JARVIS_DEPLOYMENT:-jarvis}"
BASE_URL="${OPENAI_BASE_URL:-http://127.0.0.1:8080/v1}"
ROOT_URL="${BASE_URL%/v1}"
CONTEXT="${KUBE_CONTEXT:-}"

k() {
  if [[ -n "${CONTEXT}" ]]; then
    kubectl --context="${CONTEXT}" "$@"
  else
    kubectl "$@"
  fi
}

echo "=== deployment ==="
k -n "${NS}" get deployment "${DEP}" -o wide 2>/dev/null || echo "(missing)"

echo
echo "=== pods ==="
k -n "${NS}" get pods -l app.kubernetes.io/name=jarvis -o wide 2>/dev/null || true

echo
echo "=== lease ==="
k -n "${NS}" get configmap jarvis-lease -o jsonpath='holder={.metadata.annotations.jarvis\.watchtower/holder} expires={.metadata.annotations.jarvis\.watchtower/expires-at} last-activity={.metadata.annotations.jarvis\.watchtower/last-activity-at}{"\n"}' 2>/dev/null || echo "(missing)"

echo
echo "=== health ==="
if curl -fsS --max-time 3 "${ROOT_URL}/health" >/dev/null 2>&1; then
  echo "healthy  ${ROOT_URL}/health"
  curl -fsS --max-time 3 "${BASE_URL}/models" 2>/dev/null | head -c 500 || true
  echo
else
  echo "down     ${ROOT_URL}/health"
fi
