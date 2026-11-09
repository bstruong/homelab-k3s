#!/usr/bin/env bash
# One Watchtower-owned JARVIS GPU session interface.
#
# Graded campaigns call this from the cluster Job — never from a laptop heartbeat.
#
#   jarvis-session.sh begin  <holder> [ttl-minutes] [run-id]
#   jarvis-session.sh heartbeat
#   jarvis-session.sh heartbeat-loop [interval-seconds]
#   jarvis-session.sh end [--keep-up]
#   jarvis-session.sh acquire|wake|release|scale-down   # primitives
#   jarvis-session.sh status
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/jarvis-common.sh"

STATE_DIR="${JARVIS_SESSION_STATE_DIR:-${TMPDIR:-/tmp}/jarvis-session}"

usage() {
  cat <<'EOF'
Usage:
  jarvis-session.sh begin <holder> [ttl-minutes] [run-id]
  jarvis-session.sh heartbeat
  jarvis-session.sh heartbeat-loop [interval-seconds]
  jarvis-session.sh end [--keep-up]
  jarvis-session.sh acquire <holder> [ttl-minutes] [run-id]
  jarvis-session.sh wake
  jarvis-session.sh release
  jarvis-session.sh scale-down [--force]
  jarvis-session.sh status

Environment:
  JARVIS_LEASE_HOLDER / JARVIS_LEASE_MINUTES / JARVIS_SESSION_RUN_ID
  ALPHA_JARVIS_DOWN_AFTER=0 skips scale-down in end (caller owns it)
  JARVIS_LEASE_DUAL_READ=1 (default) dual-reads legacy ConfigMap during cutover
EOF
}

write_state() {
  mkdir -p "${STATE_DIR}"
  printf '%s\n' "$1" >"${STATE_DIR}/holder"
  printf '%s\n' "$2" >"${STATE_DIR}/ttl"
  printf '%s\n' "${3:-}" >"${STATE_DIR}/run_id"
}

load_state() {
  if [[ -f "${STATE_DIR}/holder" ]]; then
    JARVIS_SESSION_HOLDER="$(cat "${STATE_DIR}/holder")"
    JARVIS_SESSION_TTL_MIN="$(cat "${STATE_DIR}/ttl")"
    JARVIS_SESSION_RUN_ID="$(cat "${STATE_DIR}/run_id")"
  else
    JARVIS_SESSION_HOLDER="${JARVIS_LEASE_HOLDER:-}"
    JARVIS_SESSION_TTL_MIN="${JARVIS_LEASE_MINUTES:-60}"
    JARVIS_SESSION_RUN_ID="${JARVIS_SESSION_RUN_ID:-}"
  fi
}

cmd_acquire() {
  local holder="${1:-}" ttl="${2:-60}" run_id="${3:-}"
  jarvis_lease_acquire "${holder}" "${ttl}" "${run_id}"
}

cmd_wake() {
  echo "==> waking ${JARVIS_NS}/${JARVIS_DEP}"
  jarvis_scale 1
  jarvis_touch_activity
  jarvis_wait_healthy "${JARVIS_WAKE_TIMEOUT:-180}"
}

cmd_release() {
  load_state
  jarvis_lease_release "${JARVIS_SESSION_HOLDER:-}"
}

cmd_scale_down() {
  local force=false
  for arg in "$@"; do
    [[ "${arg}" == "--force" ]] && force=true
  done
  if [[ "${force}" != true ]]; then
    jarvis_lease_load
    # shellcheck disable=SC2154 # _jl_* from jarvis_lease_load
    if [[ -n "${_jl_holder}" ]] && ! jarvis_lease_expired "${_jl_renew_epoch}" "${_jl_duration}"; then
      echo "fail active lease holder=${_jl_holder} (pass --force to override)" >&2
      return 1
    fi
  fi
  echo "==> sleeping ${JARVIS_NS}/${JARVIS_DEP}"
  jarvis_scale 0
  echo "ok  scaled to 0"
}

cmd_begin() {
  local holder="${1:-}" ttl="${2:-${JARVIS_LEASE_MINUTES:-60}}" run_id="${3:-${JARVIS_SESSION_RUN_ID:-}}"
  if [[ -z "${holder}" ]]; then
    echo "Usage: $0 begin <holder> [ttl-minutes] [run-id]" >&2
    return 1
  fi
  if [[ -z "${run_id}" ]]; then
    run_id="${holder}-$(date -u +%Y%m%dT%H%M%SZ)"
  fi
  echo "==> session begin holder=${holder} ttl=${ttl}m run-id=${run_id}"
  jarvis_lease_acquire "${holder}" "${ttl}" "${run_id}"
  write_state "${holder}" "${ttl}" "${run_id}"
  export JARVIS_LEASE_HOLDER="${holder}"
  export JARVIS_LEASE_MINUTES="${ttl}"
  export JARVIS_SESSION_RUN_ID="${run_id}"
  cmd_wake
  echo "ok  session ready run-id=${run_id}"
}

cmd_heartbeat() {
  load_state
  local holder="${JARVIS_SESSION_HOLDER:-${JARVIS_LEASE_HOLDER:-}}"
  local ttl="${JARVIS_SESSION_TTL_MIN:-${JARVIS_LEASE_MINUTES:-}}"
  if [[ -z "${holder}" ]]; then
    echo "fail heartbeat: no session holder (run begin first or set JARVIS_LEASE_HOLDER)" >&2
    return 1
  fi
  jarvis_lease_heartbeat "${holder}" "${ttl}"
}

cmd_heartbeat_loop() {
  local interval="${1:-60}"
  load_state
  echo "==> heartbeat loop every ${interval}s holder=${JARVIS_SESSION_HOLDER:-${JARVIS_LEASE_HOLDER:-}}"
  while true; do
    cmd_heartbeat || echo "warn: heartbeat failed at $(jarvis_now_rfc3339)" >&2
    sleep "${interval}"
  done
}

cmd_end() {
  local keep_up=false
  for arg in "$@"; do
    [[ "${arg}" == "--keep-up" ]] && keep_up=true
  done
  load_state
  echo "==> session end holder=${JARVIS_SESSION_HOLDER:-unknown} run-id=${JARVIS_SESSION_RUN_ID:-none}"
  jarvis_lease_release "${JARVIS_SESSION_HOLDER:-}" || true
  rm -rf "${STATE_DIR}"

  if [[ "${keep_up}" == true ]]; then
    echo "ok  lease released; JARVIS left up (--keep-up)"
    return 0
  fi
  # Always release GPU claim on end unless --keep-up. Alpha campaign scripts may
  # set ALPHA_JARVIS_DOWN_AFTER=0 so *their* cleanup skips scale-down; the
  # Watchtower entrypoint still owns final scale-to-zero here.
  cmd_scale_down --force || true
}

cmd_status() {
  jarvis_lease_load
  local cm_holder cm_expires cm_last
  IFS='|' read -r cm_holder cm_expires cm_last <<<"$(jarvis_cm_lease_fields)"
  echo "lease.name=${JARVIS_LEASE_NAME}"
  echo "lease.holder=${_jl_holder:-}"
  echo "lease.run_id=${_jl_run_id:-}"
  echo "lease.renewTime=${_jl_renew_raw:-}"
  echo "lease.durationSeconds=${_jl_duration:-}"
  echo "lease.last_activity=${_jl_last_activity:-}"
  if [[ -z "${_jl_holder}" ]] || jarvis_lease_expired "${_jl_renew_epoch}" "${_jl_duration}"; then
    echo "lease.expired=true"
  else
    echo "lease.expired=false"
  fi
  if [[ "${JARVIS_LEASE_DUAL_READ}" == "1" ]]; then
    echo "configmap.holder=${cm_holder:-}"
    echo "configmap.expires=${cm_expires:-}"
    echo "configmap.last_activity=${cm_last:-}"
  fi
  local replicas
  replicas="$(jarvis_kubectl -n "${JARVIS_NS}" get deployment "${JARVIS_DEP}" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "?")"
  echo "deployment.replicas=${replicas}"
}

cmd="${1:-}"
case "${cmd}" in
  begin) shift; cmd_begin "$@" ;;
  heartbeat) shift; cmd_heartbeat "$@" ;;
  heartbeat-loop) shift; cmd_heartbeat_loop "$@" ;;
  end) shift; cmd_end "$@" ;;
  acquire) shift; cmd_acquire "$@" ;;
  wake) shift; cmd_wake "$@" ;;
  release) shift; cmd_release "$@" ;;
  scale-down) shift; cmd_scale_down "$@" ;;
  status) shift; cmd_status "$@" ;;
  -h|--help|help|"") usage ;;
  *)
    echo "unknown command: ${cmd}" >&2
    usage >&2
    exit 1
    ;;
esac
