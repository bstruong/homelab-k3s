#!/usr/bin/env bash
# Wake JARVIS (scale 0→1) and wait for /health.
set -euo pipefail

NS="${JARVIS_NAMESPACE:-jarvis}"
DEP="${JARVIS_DEPLOYMENT:-jarvis}"
BASE_URL="${OPENAI_BASE_URL:-http://127.0.0.1:8080/v1}"
ROOT_URL="${BASE_URL%/v1}"
TIMEOUT="${JARVIS_WAKE_TIMEOUT:-180}"
CONTEXT="${KUBE_CONTEXT:-}"

k() {
  if [[ -n "${CONTEXT}" ]]; then
    kubectl --context="${CONTEXT}" "$@"
  else
    kubectl "$@"
  fi
}

now_rfc3339() { date -u +%Y-%m-%dT%H:%M:%SZ; }

echo "==> waking ${NS}/${DEP}"
k -n "${NS}" scale deployment/"${DEP}" --replicas=1

# Touch activity so idle CronJob does not immediately sleep.
k -n "${NS}" annotate configmap jarvis-lease \
  "jarvis.watchtower/last-activity-at=$(now_rfc3339)" --overwrite

deadline=$((SECONDS + TIMEOUT))
while (( SECONDS < deadline )); do
  if curl -fsS --max-time 3 "${ROOT_URL}/health" >/dev/null 2>&1; then
    echo "ok  JARVIS healthy at ${ROOT_URL}"
    exit 0
  fi
  sleep 2
done

echo "fail JARVIS did not become healthy within ${TIMEOUT}s" >&2
exit 1
