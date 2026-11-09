#!/usr/bin/env bash
# Print JARVIS deployment, native Lease, legacy ConfigMap (cutover), and HTTP health.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/jarvis-common.sh"

BASE_URL="$(jarvis_default_base_url)"
ROOT_URL="${BASE_URL%/v1}"

echo "=== deployment ==="
jarvis_kubectl -n "${JARVIS_NS}" get deployment "${JARVIS_DEP}" -o wide 2>/dev/null || echo "(missing)"

echo
echo "=== pods ==="
jarvis_kubectl -n "${JARVIS_NS}" get pods -l app.kubernetes.io/name=jarvis -o wide 2>/dev/null || true

echo
echo "=== lease (coordination.k8s.io/v1) ==="
"${SCRIPT_DIR}/jarvis-session.sh" status || true

echo
echo "=== health ==="
if curl -fsS --max-time 3 "${ROOT_URL}/health" >/dev/null 2>&1; then
  echo "healthy  ${ROOT_URL}/health"
  curl -fsS --max-time 3 "${BASE_URL}/models" 2>/dev/null | head -c 500 || true
  echo
else
  echo "down     ${ROOT_URL}/health"
fi
