#!/usr/bin/env bash
# Sleep JARVIS (scale →0). Refuses if an unexpired lease is held unless --force.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/jarvis-common.sh"

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

jarvis_lease_load
# _jl_* populated by jarvis_lease_load
# shellcheck disable=SC2154
if [[ "${FORCE}" != true && -n "${_jl_holder}" ]] \
  && ! jarvis_lease_expired "${_jl_renew_epoch}" "${_jl_duration}"; then
  echo "fail active lease holder=${_jl_holder} run-id=${_jl_run_id:-none} (pass --force to override)" >&2
  exit 1
fi

# Dual-read ConfigMap holders during cutover.
if [[ "${FORCE}" != true && "${JARVIS_LEASE_DUAL_READ}" == "1" ]]; then
  cm_holder="" cm_expires=""
  IFS='|' read -r cm_holder cm_expires _ <<<"$(jarvis_cm_lease_fields)"
  now="$(jarvis_now_rfc3339)"
  if [[ -n "${cm_holder}" && -n "${cm_expires}" && "${cm_expires}" > "${now}" ]]; then
    echo "fail active ConfigMap lease holder=${cm_holder} expires=${cm_expires} (pass --force to override)" >&2
    exit 1
  fi
fi

echo "==> sleeping ${JARVIS_NS}/${JARVIS_DEP}"
jarvis_scale 0
echo "ok  scaled to 0"
