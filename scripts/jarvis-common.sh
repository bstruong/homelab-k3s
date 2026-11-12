# Shared helpers for jarvis-up / jarvis-down / jarvis-lease / jarvis-session.
# shellcheck shell=bash

JARVIS_NS="${JARVIS_NAMESPACE:-jarvis}"
JARVIS_DEP="${JARVIS_DEPLOYMENT:-jarvis}"
JARVIS_LEASE_NAME="${JARVIS_LEASE_NAME:-jarvis-gpu}"
JARVIS_LEASE_CM="${JARVIS_LEASE_CM:-jarvis-lease}"
# Dual-read ConfigMap during cutover. Set JARVIS_LEASE_DUAL_READ=0 after CM removal.
JARVIS_LEASE_DUAL_READ="${JARVIS_LEASE_DUAL_READ:-1}"

jarvis_in_cluster() {
  [[ -n "${KUBERNETES_SERVICE_HOST:-}" ]]
}

jarvis_on_watchtower_host() {
  [[ "$(hostname 2>/dev/null || true)" == "watchtower" ]]
}

jarvis_default_base_url() {
  if jarvis_in_cluster; then
    echo "${OPENAI_BASE_URL:-http://jarvis.jarvis.svc.cluster.local:8080/v1}"
  elif jarvis_on_watchtower_host; then
    echo "${OPENAI_BASE_URL:-http://127.0.0.1:8080/v1}"
  else
    local url="${OPENAI_BASE_URL:-http://ai.watchtower.local/v1}"
    # LAN 8080 is firewalled; rewrite legacy direct hostPort URL to Traefik ingress.
    echo "${url//192.0.2.10:8080/ai.watchtower.local}"
  fi
}

# kubectl via: explicit context, in-cluster SA, local host, or ssh to watchtower.
jarvis_kubectl() {
  local context="${KUBE_CONTEXT:-}"
  local ssh_host="${WATCHTOWER_SSH:-watchtower}"
  if [[ -n "${context}" ]]; then
    kubectl --context="${context}" "$@"
  elif jarvis_in_cluster || jarvis_on_watchtower_host; then
    kubectl "$@"
  else
    ssh "${ssh_host}" kubectl "$(printf '%q ' "$@")"
  fi
}

jarvis_now_rfc3339() { date -u +%Y-%m-%dT%H:%M:%SZ; }

jarvis_now_epoch() { date -u +%s; }

# Microsecond RFC3339 for Lease renewTime / acquireTime (API requires MicroTime).
jarvis_now_micro() {
  local ts
  ts="$(date -u +%Y-%m-%dT%H:%M:%S.%6NZ 2>/dev/null || true)"
  if [[ -z "${ts}" || "${ts}" == *%* || "${ts}" == *N* ]]; then
    date -u +%Y-%m-%dT%H:%M:%S.000000Z
  else
    echo "${ts}"
  fi
}

jarvis_epoch_of() {
  date -u -d "$1" +%s 2>/dev/null || date -u -d "${1%.*}Z" +%s
}

jarvis_json_escape() {
  if command -v python3 >/dev/null 2>&1; then
    python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$1"
  else
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    printf '"%s"' "$s"
  fi
}

# Mutate the Lease object via get→python→replace (resourceVersion CAS).
# Env: JARVIS_CAS_HOLDER JARVIS_CAS_DURATION JARVIS_CAS_RUN_ID JARVIS_CAS_MODE
# MODE=acquire|heartbeat|release|touch  optional JARVIS_CAS_SCORE / JARVIS_CAS_MODEL
jarvis_lease_cas_mutate() {
  local mode="$1"
  local raw mutated rc
  # Pipe JSON over stdin/stdout so ssh-wrapped kubectl never needs a remote tempfile.
  if ! raw="$(jarvis_kubectl -n "${JARVIS_NS}" get lease "${JARVIS_LEASE_NAME}" -o json)"; then
    echo "fail could not get lease ${JARVIS_LEASE_NAME}" >&2
    return 1
  fi

  local cas_py
  cas_py="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/jarvis-lease-cas.py"
  set +e
  mutated="$(
    printf '%s\n' "${raw}" | JARVIS_CAS_MODE="${mode}" python3 "${cas_py}"
  )"
  rc=$?
  set -e
  if [[ "${rc}" -ne 0 ]]; then
    return "${rc}"
  fi
  if printf '%s\n' "${mutated}" | jarvis_kubectl -n "${JARVIS_NS}" replace -f - >/dev/null; then
    return 0
  fi
  return 1
}

# Print: holder|renew_epoch|duration|rv|run_id|last_activity|acquire_micro|renew_micro
jarvis_lease_fields() {
  jarvis_kubectl -n "${JARVIS_NS}" get lease "${JARVIS_LEASE_NAME}" \
    -o jsonpath='{.spec.holderIdentity}|{.spec.renewTime}|{.spec.leaseDurationSeconds}|{.metadata.resourceVersion}|{.metadata.annotations.jarvis\.watchtower/run-id}|{.metadata.annotations.jarvis\.watchtower/last-activity-at}|{.spec.acquireTime}{"\n"}' \
    2>/dev/null || true
}

# Returns 0 if the native Lease currently has a non-expired foreign holder.
# Sets globals: _jl_holder _jl_run_id _jl_rv _jl_duration _jl_renew_epoch
jarvis_lease_load() {
  local raw holder renew_raw duration rv run_id last_act renew_epoch=0
  raw="$(jarvis_lease_fields)"
  IFS='|' read -r holder renew_raw duration rv run_id last_act _ <<<"${raw}"
  holder="${holder:-}"
  duration="${duration:-60}"
  rv="${rv:-}"
  run_id="${run_id:-}"
  last_act="${last_act:-}"
  if [[ -n "${renew_raw}" ]]; then
    renew_epoch="$(jarvis_epoch_of "${renew_raw}")" || renew_epoch=0
  fi
  # shellcheck disable=SC2034 # exported for callers after jarvis_lease_load
  _jl_holder="${holder}"
  # shellcheck disable=SC2034
  _jl_run_id="${run_id}"
  # shellcheck disable=SC2034
  _jl_rv="${rv}"
  # shellcheck disable=SC2034
  _jl_duration="${duration}"
  # shellcheck disable=SC2034
  _jl_renew_epoch="${renew_epoch}"
  # shellcheck disable=SC2034
  _jl_last_activity="${last_act}"
  # shellcheck disable=SC2034
  _jl_renew_raw="${renew_raw:-}"
}

jarvis_lease_expired() {
  local now renew_epoch duration
  renew_epoch="${1:-0}"
  duration="${2:-60}"
  now="$(jarvis_now_epoch)"
  if [[ -z "${renew_epoch}" || "${renew_epoch}" -le 0 ]]; then
    return 0
  fi
  (( now > renew_epoch + duration ))
}

# ConfigMap dual-read: print holder|expires_rfc|last_activity (empty if missing).
jarvis_cm_lease_fields() {
  if [[ "${JARVIS_LEASE_DUAL_READ}" != "1" ]]; then
    echo "||"
    return 0
  fi
  jarvis_kubectl -n "${JARVIS_NS}" get configmap "${JARVIS_LEASE_CM}" \
    -o jsonpath='{.metadata.annotations.jarvis\.watchtower/holder}|{.metadata.annotations.jarvis\.watchtower/expires-at}|{.metadata.annotations.jarvis\.watchtower/last-activity-at}{"\n"}' \
    2>/dev/null || echo "||"
}

# Fail if ConfigMap names a different non-expired holder (cutover safety).
jarvis_cm_conflict() {
  local want_holder="$1"
  local cm_holder cm_expires now
  if [[ "${JARVIS_LEASE_DUAL_READ}" != "1" ]]; then
    return 0
  fi
  IFS='|' read -r cm_holder cm_expires _ <<<"$(jarvis_cm_lease_fields)"
  now="$(jarvis_now_rfc3339)"
  if [[ -n "${cm_holder}" && -n "${cm_expires}" && "${cm_expires}" > "${now}" && "${cm_holder}" != "${want_holder}" ]]; then
    echo "fail ConfigMap lease held by ${cm_holder} until ${cm_expires} (cutover dual-read)" >&2
    return 1
  fi
  return 0
}

# Mirror holder state onto the legacy ConfigMap so old Alpha kick/status keep working.
jarvis_cm_mirror_acquire() {
  local holder="$1" ttl_min="$2" run_id="${3:-}"
  local exp now
  if [[ "${JARVIS_LEASE_DUAL_READ}" != "1" ]]; then
    return 0
  fi
  now="$(jarvis_now_rfc3339)"
  exp="$(date -u -d "+${ttl_min} minutes" +%Y-%m-%dT%H:%M:%SZ)"
  jarvis_kubectl -n "${JARVIS_NS}" annotate configmap "${JARVIS_LEASE_CM}" \
    "jarvis.watchtower/holder=${holder}" \
    "jarvis.watchtower/expires-at=${exp}" \
    "jarvis.watchtower/last-activity-at=${now}" \
    "jarvis.watchtower/run-id=${run_id}" \
    --overwrite >/dev/null 2>&1 || true
  jarvis_kubectl -n "${JARVIS_NS}" patch configmap "${JARVIS_LEASE_CM}" --type merge \
    -p '{"data":{"status":"leased"}}' >/dev/null 2>&1 || true
}

jarvis_cm_mirror_release() {
  local now
  if [[ "${JARVIS_LEASE_DUAL_READ}" != "1" ]]; then
    return 0
  fi
  now="$(jarvis_now_rfc3339)"
  jarvis_kubectl -n "${JARVIS_NS}" annotate configmap "${JARVIS_LEASE_CM}" \
    "jarvis.watchtower/holder-" \
    "jarvis.watchtower/expires-at-" \
    "jarvis.watchtower/run-id-" \
    "jarvis.watchtower/last-activity-at=${now}" \
    --overwrite >/dev/null 2>&1 || true
  jarvis_kubectl -n "${JARVIS_NS}" patch configmap "${JARVIS_LEASE_CM}" --type merge \
    -p '{"data":{"status":"idle"}}' >/dev/null 2>&1 || true
}

jarvis_cm_mirror_touch() {
  local now score="${1:-}" model="${2:-}"
  if [[ "${JARVIS_LEASE_DUAL_READ}" != "1" ]]; then
    return 0
  fi
  now="$(jarvis_now_rfc3339)"
  local -a args=(
    "jarvis.watchtower/last-activity-at=${now}"
  )
  if [[ -n "${score}" ]]; then
    args+=("jarvis.watchtower/metrics-warmth-score=${score}")
  fi
  if [[ -n "${model}" ]]; then
    args+=("jarvis.watchtower/metrics-model=${model}")
  fi
  jarvis_kubectl -n "${JARVIS_NS}" annotate configmap "${JARVIS_LEASE_CM}" \
    "${args[@]}" --overwrite >/dev/null 2>&1 || true
}

# Atomic acquire of coordination.k8s.io/v1 Lease jarvis-gpu.
# Args: holder ttl_minutes [run_id]
jarvis_lease_acquire() {
  local holder="$1" ttl_min="${2:-60}" run_id="${3:-}"
  local duration attempt rc

  if [[ -z "${holder}" ]]; then
    echo "fail acquire requires holder identity" >&2
    return 1
  fi
  duration=$(( ttl_min * 60 ))
  if (( duration < 60 )); then
    duration=60
  fi

  jarvis_cm_conflict "${holder}" || return 1

  export JARVIS_CAS_HOLDER="${holder}"
  export JARVIS_CAS_DURATION="${duration}"
  export JARVIS_CAS_RUN_ID="${run_id}"

  for attempt in 1 2 3 4 5 6 7 8; do
    jarvis_lease_load
    if [[ -z "${_jl_rv}" ]]; then
      echo "fail Lease ${JARVIS_LEASE_NAME} missing in ${JARVIS_NS}" >&2
      return 1
    fi
    set +e
    jarvis_lease_cas_mutate acquire
    rc=$?
    set -e
    if [[ "${rc}" -eq 0 ]]; then
      jarvis_cm_mirror_acquire "${holder}" "${ttl_min}" "${run_id}"
      echo "ok  lease holder=${holder} duration=${duration}s run-id=${run_id:-none}"
      return 0
    fi
    if [[ "${rc}" -eq 2 ]]; then
      return 1
    fi
    sleep 0.4
  done

  echo "fail lease acquire lost the race (CAS retries exhausted)" >&2
  return 1
}

# Renew lease for the current holder. Args: holder [ttl_minutes]
jarvis_lease_heartbeat() {
  local holder="$1" ttl_min="${2:-}"
  local attempt duration rc

  if [[ -z "${holder}" ]]; then
    echo "fail heartbeat requires holder" >&2
    return 1
  fi

  for attempt in 1 2 3 4 5; do
    jarvis_lease_load
    duration="${_jl_duration}"
    if [[ -n "${ttl_min}" ]]; then
      duration=$(( ttl_min * 60 ))
      (( duration < 60 )) && duration=60
    fi
    export JARVIS_CAS_HOLDER="${holder}"
    export JARVIS_CAS_DURATION="${duration}"
    export JARVIS_CAS_RUN_ID="${_jl_run_id:-}"
    set +e
    jarvis_lease_cas_mutate heartbeat
    rc=$?
    set -e
    if [[ "${rc}" -eq 0 ]]; then
      if [[ -n "${ttl_min}" ]]; then
        jarvis_cm_mirror_acquire "${holder}" "${ttl_min}" "${_jl_run_id}"
      else
        jarvis_cm_mirror_touch
      fi
      echo "ok  heartbeat holder=${holder}"
      return 0
    fi
    if [[ "${rc}" -eq 2 ]]; then
      return 1
    fi
    sleep 0.3
  done
  echo "fail heartbeat CAS retries exhausted" >&2
  return 1
}

# Release only if we still hold (or holder unset / force).
# Args: [holder]  — when set, refuse to clear a different live holder.
jarvis_lease_release() {
  local holder="${1:-}"
  local attempt rc

  export JARVIS_CAS_HOLDER="${holder}"
  export JARVIS_CAS_DURATION=60
  export JARVIS_CAS_RUN_ID=""

  for attempt in 1 2 3 4 5; do
    set +e
    jarvis_lease_cas_mutate release
    rc=$?
    set -e
    if [[ "${rc}" -eq 0 ]]; then
      jarvis_cm_mirror_release
      echo "ok  lease released"
      return 0
    fi
    if [[ "${rc}" -eq 2 ]]; then
      return 1
    fi
    sleep 0.3
  done
  echo "fail lease release CAS retries exhausted" >&2
  return 1
}

jarvis_scale() {
  local replicas="$1"
  local attempt
  for attempt in 1 2 3 4 5; do
    if jarvis_kubectl -n "${JARVIS_NS}" scale deployment/"${JARVIS_DEP}" --replicas="${replicas}"; then
      return 0
    fi
    echo "warn: scale attempt ${attempt} failed; retrying in 3s" >&2
    sleep 3
  done
  echo "fail: could not scale ${JARVIS_NS}/${JARVIS_DEP} to ${replicas}" >&2
  return 1
}

jarvis_wait_healthy() {
  local timeout="${1:-${JARVIS_WAKE_TIMEOUT:-180}}"
  local base_url root_url deadline
  base_url="$(jarvis_default_base_url)"
  root_url="${base_url%/v1}"
  deadline=$((SECONDS + timeout))
  while (( SECONDS < deadline )); do
    if curl -fsS --max-time 3 "${root_url}/health" >/dev/null 2>&1; then
      echo "ok  JARVIS healthy at ${root_url}"
      return 0
    fi
    sleep 2
  done
  echo "fail JARVIS did not become healthy within ${timeout}s" >&2
  return 1
}

jarvis_touch_activity() {
  local score="${1:-}" model="${2:-}"
  export JARVIS_CAS_HOLDER=""
  export JARVIS_CAS_DURATION=60
  export JARVIS_CAS_RUN_ID=""
  export JARVIS_CAS_SCORE="${score}"
  export JARVIS_CAS_MODEL="${model}"
  jarvis_lease_cas_mutate touch >/dev/null 2>&1 || true
  jarvis_cm_mirror_touch "${score}" "${model}"
  unset JARVIS_CAS_SCORE JARVIS_CAS_MODEL
}
