#!/usr/bin/env bash
#
# Deploy the Watchtower stack to k3s.
#
#   ./deploy.sh                 apply everything, then validate
#   ./deploy.sh --dry-run       server-side validate without changing anything
#   ./deploy.sh --validate      skip apply, just report current state
#   ./deploy.sh adguard-home    apply (and validate) a single app
#
# Secrets are never created here — see docs/SECRETS.md and
# scripts/create-secrets.sh. This script refuses to apply an app whose secrets
# are missing, so a rollout never hangs on an unresolvable secretKeyRef.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST_DIR="${REPO_ROOT}/manifests/watchtower"
COMMON_DIR="${REPO_ROOT}/manifests/common"
NODE="${WATCHTOWER_NODE:-watchtower}"
APPDATA_ROOT="${APPDATA_ROOT:-/mnt/appdata}"
ROLLOUT_TIMEOUT="${ROLLOUT_TIMEOUT:-300s}"

DRY_RUN=false
VALIDATE_ONLY=false
ONLY_APP=""

NAMESPACES=(adguard identity monitoring media docs sync home)

# app -> "namespace:secret-name:key,key,..."  (empty list = no secrets needed)
REQUIRED_SECRETS=(
  "identity:vaultwarden:admin-token"
  "docs:paperless-ngx:secret-key,admin-user,admin-password"
  "docs:appflowy:postgres-password,database-url,jwt-secret,gotrue-admin-password,minio-access-key,minio-secret-key"
  "monitoring:beszel-agent:hub-public-key"
)

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[0;33m'; BLUE=$'\033[0;34m'; NC=$'\033[0m'
info()  { printf '%s==>%s %s\n' "${BLUE}"   "${NC}" "$*"; }
ok()    { printf '%s ok %s %s\n' "${GREEN}"  "${NC}" "$*"; }
warn()  { printf '%swarn%s %s\n' "${YELLOW}" "${NC}" "$*"; }
fail()  { printf '%sfail%s %s\n' "${RED}"    "${NC}" "$*" >&2; }
die()   { fail "$*"; exit 1; }

# Print the comment block at the top of this file as the help text.
usage() {
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "${BASH_SOURCE[0]}"
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)  DRY_RUN=true ;;
    --validate) VALIDATE_ONLY=true ;;
    -h|--help)  usage ;;
    -*)         die "unknown flag: $1" ;;
    *)          ONLY_APP="$1" ;;
  esac
  shift
done

# ---------------------------------------------------------------- preflight --

preflight() {
  info "Preflight"

  command -v kubectl >/dev/null 2>&1 || die "kubectl not found in PATH"

  kubectl cluster-info >/dev/null 2>&1 \
    || die "cannot reach the cluster — check KUBECONFIG (currently: ${KUBECONFIG:-~/.kube/config})"
  ok "cluster reachable: $(kubectl config current-context)"

  if kubectl get node "${NODE}" >/dev/null 2>&1; then
    ok "node ${NODE} found"
  else
    warn "no node named '${NODE}'. Every PersistentVolume and nodeSelector in"
    warn "this repo pins to that hostname — update them, or set WATCHTOWER_NODE."
    kubectl get nodes -o custom-columns=NAME:.metadata.name --no-headers | sed 's/^/       available: /'
    die "node ${NODE} not found"
  fi

  # Traefik ships with k3s, but it can be disabled at install time.
  if kubectl get crd ingressroutes.traefik.io >/dev/null 2>&1; then
    ok "Traefik IngressRoute CRD present"
  else
    die "Traefik IngressRoute CRD missing — is Traefik installed? (k3s installs it unless started with --disable=traefik)"
  fi

  if [[ -n "${ONLY_APP}" && ! -d "${MANIFEST_DIR}/${ONLY_APP}" ]]; then
    die "no such app: ${ONLY_APP} (looked in ${MANIFEST_DIR})"
  fi
}

# The host directories must exist and be writable by uid 1000 before any pod
# with a hostPath PV starts; DirectoryOrCreate creates them owned by root.
check_appdata() {
  info "Checking ${APPDATA_ROOT} on ${NODE}"
  warn "This script cannot inspect the node's filesystem from here."
  warn "If this is a fresh install, run on ${NODE}:"
  cat <<EOF

  sudo mkdir -p ${APPDATA_ROOT}/{adguard-home,vaultwarden,jellyfin,paperless-ngx,beszel}
  sudo mkdir -p ${APPDATA_ROOT}/appflowy/{postgres,minio}
  sudo chown -R 1000:1000 ${APPDATA_ROOT}
  sudo chown -R 999:999   ${APPDATA_ROOT}/appflowy/postgres   # postgres runs as uid 999

EOF
}

check_secrets() {
  info "Checking required secrets"
  local missing=0 entry ns name keys key

  for entry in "${REQUIRED_SECRETS[@]}"; do
    IFS=: read -r ns name keys <<<"${entry}"

    if [[ -n "${ONLY_APP}" ]]; then
      # Only enforce secrets belonging to the app being deployed.
      case "${ONLY_APP}" in
        vaultwarden|paperless-ngx|appflowy|beszel) [[ "${name}" == "${ONLY_APP}"* ]] || continue ;;
        *) continue ;;
      esac
    fi

    if ! kubectl -n "${ns}" get secret "${name}" >/dev/null 2>&1; then
      fail "missing secret ${ns}/${name}"
      missing=$((missing + 1))
      continue
    fi

    local bad_keys=0
    IFS=, read -r -a key_list <<<"${keys}"
    for key in "${key_list[@]}"; do
      if ! kubectl -n "${ns}" get secret "${name}" -o "jsonpath={.data.${key}}" 2>/dev/null | grep -q .; then
        fail "secret ${ns}/${name} has no key '${key}'"
        bad_keys=$((bad_keys + 1))
      fi
    done

    if [[ ${bad_keys} -eq 0 ]]; then
      ok "secret ${ns}/${name}"
    else
      missing=$((missing + bad_keys))
    fi
  done

  if [[ ${missing} -gt 0 ]]; then
    echo
    die "${missing} secret problem(s). See docs/SECRETS.md or run scripts/create-secrets.sh"
  fi
}

# -------------------------------------------------------------------- apply --

kapply() {
  if [[ "${DRY_RUN}" == true ]]; then
    kubectl apply --dry-run=server -f "$1"
  else
    kubectl apply -f "$1"
  fi
}

apply_common() {
  info "Applying namespaces and storage class"
  kapply "${COMMON_DIR}/namespaces.yaml"
  kapply "${COMMON_DIR}/storageclass.yaml"
}

apply_apps() {
  local dir app
  for dir in "${MANIFEST_DIR}"/*/; do
    app="$(basename "${dir}")"
    if [[ -n "${ONLY_APP}" && "${app}" != "${ONLY_APP}" ]]; then
      continue
    fi

    info "Applying ${app}"
    # PVs, PVCs and config first, so that WaitForFirstConsumer binding has
    # something to bind to the moment a pod is scheduled. Re-applying them as
    # part of the directory below is a no-op.
    if [[ -f "${dir}/pvc.yaml" ]]; then
      kapply "${dir}/pvc.yaml"
    fi
    if [[ -f "${dir}/configmap.yaml" ]]; then
      kapply "${dir}/configmap.yaml"
    fi
    kapply "${dir}"
  done
}

wait_for_rollouts() {
  if [[ "${DRY_RUN}" == true ]]; then
    return 0
  fi
  info "Waiting for rollouts (timeout ${ROLLOUT_TIMEOUT} each)"

  local ns kind obj rc=0
  for ns in "${NAMESPACES[@]}"; do
    kubectl get ns "${ns}" >/dev/null 2>&1 || continue
    for kind in deployment statefulset daemonset; do
      while read -r obj; do
        if [[ -z "${obj}" ]]; then
          continue
        fi
        if kubectl -n "${ns}" rollout status "${kind}/${obj}" --timeout="${ROLLOUT_TIMEOUT}" >/dev/null 2>&1; then
          ok "${ns}/${kind}/${obj}"
        else
          fail "${ns}/${kind}/${obj} did not become ready"
          rc=1
        fi
      done < <(kubectl -n "${ns}" get "${kind}" -o name 2>/dev/null | cut -d/ -f2)
    done
  done
  return ${rc}
}

# ----------------------------------------------------------------- validate --

validate() {
  local rc=0

  info "Pods"
  kubectl get pods -A -l 'app.kubernetes.io/name' -o wide 2>/dev/null || true

  info "Pods not Running/Succeeded"
  local bad
  bad="$(kubectl get pods -A --field-selector=status.phase!=Running,status.phase!=Succeeded \
          --no-headers 2>/dev/null | grep -Ev '^(kube-system|default)[[:space:]]' || true)"
  if [[ -n "${bad}" ]]; then
    echo "${bad}"
    fail "some pods are not running"
    rc=1
  else
    ok "all pods Running or Succeeded"
  fi

  info "PersistentVolumeClaims"
  kubectl get pvc -A 2>/dev/null || true
  local unbound
  unbound="$(kubectl get pvc -A --no-headers 2>/dev/null | awk '$3 != "Bound" {print}' || true)"
  if [[ -n "${unbound}" ]]; then
    echo "${unbound}"
    fail "some PVCs are not Bound"
    rc=1
  else
    ok "all PVCs Bound"
  fi

  info "Traefik IngressRoutes"
  kubectl get ingressroute -A 2>/dev/null || true

  info "Host entries needed for *.watchtower.local"
  local lb
  lb="$(kubectl -n kube-system get svc traefik -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
  if [[ -n "${lb}" ]]; then
    ok "Traefik is reachable at ${lb}"
    kubectl get ingressroute -A -o jsonpath='{range .items[*]}{.spec.routes[*].match}{"\n"}{end}' 2>/dev/null \
      | grep -o '[a-z0-9.-]*\.watchtower\.local' | sort -u | sed "s|^|       ${lb}  |"
  else
    warn "Traefik has no LoadBalancer IP yet"
  fi

  info "Recent warning events"
  kubectl get events -A --field-selector type=Warning \
    --sort-by=.lastTimestamp 2>/dev/null | tail -15 || true

  return ${rc}
}

# --------------------------------------------------------------------- main --

main() {
  preflight

  if [[ "${VALIDATE_ONLY}" == true ]]; then
    validate
    exit $?
  fi

  check_appdata
  apply_common
  check_secrets
  apply_apps

  if [[ "${DRY_RUN}" == true ]]; then
    ok "dry run complete — nothing was applied"
    exit 0
  fi

  local rc=0
  wait_for_rollouts || rc=1
  echo
  validate || rc=1

  echo
  if [[ ${rc} -eq 0 ]]; then
    ok "Watchtower stack deployed"
  else
    fail "deployed with problems — see above"
  fi
  exit ${rc}
}

main
