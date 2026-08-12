#!/usr/bin/env bash
#
# Deploy the Watchtower stack to k3s.
#
#   ./deploy.sh                 apply everything, then validate
#   ./deploy.sh --dry-run       server-side validate without changing anything
#   ./deploy.sh --validate      skip apply, just report current state
#   ./deploy.sh jellyfin        apply (and validate) a single app
#
# Credentials are never created here. Run scripts/secrets.sh first; this script
# applies any committed SealedSecrets, waits for the controller to unseal them,
# and refuses to deploy an app whose Secret is missing a key — so a rollout
# never hangs on an unresolvable secretKeyRef.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST_DIR="${REPO_ROOT}/manifests/watchtower"
COMMON_DIR="${REPO_ROOT}/manifests/common"
NODE="${WATCHTOWER_NODE:-watchtower}"
APPDATA_ROOT="${APPDATA_ROOT:-/mnt/appdata}"
ROLLOUT_TIMEOUT="${ROLLOUT_TIMEOUT:-300s}"
UNSEAL_TIMEOUT="${UNSEAL_TIMEOUT:-60}"

DRY_RUN=false
VALIDATE_ONLY=false
ONLY_APP=""

# The app namespaces. kube-system also hosts Traefik and Tailscale, but it is
# handled separately so this script never waits on k3s's own components.
NAMESPACES=(adguard identity monitoring media docs sync home)
KUBE_SYSTEM_WORKLOADS=(deployment/tailscale)

# app|namespace|secret|required keys (a trailing ? marks an optional key,
# which must exist but may be empty)
SECRET_SPECS=(
  "traefik|kube-system|traefik-dashboard-auth|users"
  "tailscale|kube-system|tailscale|authkey"
  "vaultwarden|identity|vaultwarden|admin-token"
  "crowdsec|monitoring|crowdsec|bouncer-key,enroll-key?"
  "beszel|monitoring|beszel-agent|hub-public-key"
  "paperless-ngx|docs|paperless-ngx|secret-key,admin-user,admin-password"
  "appflowy|docs|appflowy|postgres-password,database-url,jwt-secret,gotrue-admin-password,minio-access-key,minio-secret-key"
  "syncthing|sync|syncthing|gui-apikey"
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

  if kubectl get crd sealedsecrets.bitnami.com >/dev/null 2>&1; then
    ok "sealed-secrets CRD present"
  else
    warn "sealed-secrets is not installed. Committed SealedSecrets cannot be"
    warn "unsealed; either run scripts/bootstrap-sealed-secrets.sh, or create"
    warn "the Secrets directly with: scripts/secrets.sh apply"
  fi

  if [[ -n "${ONLY_APP}" && ! -d "${MANIFEST_DIR}/${ONLY_APP}" ]]; then
    die "no such app: ${ONLY_APP} (looked in ${MANIFEST_DIR})"
  fi
}

# The host directories must exist and be writable by the uid each app runs as;
# hostPath's DirectoryOrCreate makes them owned by root, which is not enough.
check_appdata() {
  info "Checking ${APPDATA_ROOT} on ${NODE}"
  warn "This script cannot inspect the node's filesystem from here."
  warn "On a fresh install, run this on ${NODE} first:"
  cat <<EOF

  sudo mkdir -p ${APPDATA_ROOT}/{adguard-home,vaultwarden,pocket-id,jellyfin}
  sudo mkdir -p ${APPDATA_ROOT}/{paperless-ngx,beszel,crowdsec,uptime-kuma}
  sudo mkdir -p ${APPDATA_ROOT}/{syncthing,home-assistant,tailscale}
  sudo mkdir -p ${APPDATA_ROOT}/appflowy/{postgres,minio}
  sudo chown -R 1000:1000 ${APPDATA_ROOT}
  sudo chown -R 999:999   ${APPDATA_ROOT}/appflowy/postgres  # postgres runs as uid 999
  sudo chown -R 0:0       ${APPDATA_ROOT}/crowdsec           # crowdsec runs as root
  sudo chown -R 0:0       ${APPDATA_ROOT}/home-assistant     # s6-overlay needs root
  sudo chown -R 0:0       ${APPDATA_ROOT}/tailscale          # tailscaled runs as root

EOF
}

# ------------------------------------------------------------------ secrets --

spec_for_app() {
  local app="$1" spec
  for spec in "${SECRET_SPECS[@]}"; do
    if [[ "${spec%%|*}" == "${app}" ]]; then
      printf '%s' "${spec}"
      return 0
    fi
  done
  return 1
}

# Lists the key names present in a Secret. Checking names rather than values
# lets a key legitimately hold an empty string (CrowdSec's enroll-key).
secret_keys() {
  kubectl -n "$1" get secret "$2" -o go-template='{{range $k, $v := .data}}{{$k}}{{"\n"}}{{end}}' 2>/dev/null
}

apply_sealed_secrets() {
  local dir app found=0
  for dir in "${MANIFEST_DIR}"/*/; do
    app="$(basename "${dir}")"
    if [[ -n "${ONLY_APP}" && "${app}" != "${ONLY_APP}" ]]; then
      continue
    fi
    if [[ -f "${dir}/sealedsecret.yaml" ]]; then
      if [[ ${found} -eq 0 ]]; then
        info "Applying SealedSecrets"
        found=1
      fi
      kapply "${dir}/sealedsecret.yaml"
      ok "${app}"
    fi
  done

  if [[ ${found} -eq 0 ]]; then
    info "No SealedSecrets committed — expecting Secrets to already exist"
  elif [[ "${DRY_RUN}" != true ]]; then
    # The controller decrypts asynchronously; give it a moment before the
    # check below declares the Secrets missing.
    local waited=0
    while [[ ${waited} -lt ${UNSEAL_TIMEOUT} ]]; do
      if secrets_satisfied >/dev/null 2>&1; then
        break
      fi
      sleep 2
      waited=$((waited + 2))
    done
  fi
}

# Returns 0 when every required Secret and key is present. Prints nothing.
secrets_satisfied() {
  local spec app ns name keys key key_list present
  for spec in "${SECRET_SPECS[@]}"; do
    IFS='|' read -r app ns name keys <<<"${spec}"
    if [[ -n "${ONLY_APP}" && "${app}" != "${ONLY_APP}" ]]; then
      continue
    fi
    present="$(secret_keys "${ns}" "${name}")" || return 1
    if [[ -z "${present}" ]]; then
      return 1
    fi
    IFS=, read -r -a key_list <<<"${keys}"
    for key in "${key_list[@]}"; do
      grep -Fxq "${key%\?}" <<<"${present}" || return 1
    done
  done
  return 0
}

check_secrets() {
  info "Checking required secrets"
  local spec app ns name keys key key_list present missing=0 bad

  for spec in "${SECRET_SPECS[@]}"; do
    IFS='|' read -r app ns name keys <<<"${spec}"
    if [[ -n "${ONLY_APP}" && "${app}" != "${ONLY_APP}" ]]; then
      continue
    fi

    present="$(secret_keys "${ns}" "${name}")"
    if [[ -z "${present}" ]]; then
      fail "missing secret ${ns}/${name} (for ${app})"
      missing=$((missing + 1))
      continue
    fi

    bad=0
    IFS=, read -r -a key_list <<<"${keys}"
    for key in "${key_list[@]}"; do
      if ! grep -Fxq "${key%\?}" <<<"${present}"; then
        fail "secret ${ns}/${name} has no key '${key%\?}'"
        bad=$((bad + 1))
      fi
    done

    if [[ ${bad} -eq 0 ]]; then
      ok "secret ${ns}/${name}"
    else
      missing=$((missing + bad))
    fi
  done

  if [[ ${missing} -gt 0 ]]; then
    echo
    fail "${missing} secret problem(s)."
    echo "  Seal them into the repo:   ./scripts/secrets.sh seal --show" >&2
    echo "  Or create them in-cluster: ./scripts/secrets.sh apply --show" >&2
    echo "  Details:                   docs/SECRETS.md" >&2
    exit 1
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
    # PVs, PVCs and config first, so WaitForFirstConsumer binding has something
    # to bind the moment a pod is scheduled. Re-applying them as part of the
    # directory below is a no-op.
    if [[ -f "${dir}/pvc.yaml" ]]; then
      kapply "${dir}/pvc.yaml"
    fi
    if [[ -f "${dir}/configmap.yaml" ]]; then
      kapply "${dir}/configmap.yaml"
    fi
    if [[ -f "${dir}/rbac.yaml" ]]; then
      kapply "${dir}/rbac.yaml"
    fi
    kapply "${dir}"
  done
}

wait_for_rollouts() {
  if [[ "${DRY_RUN}" == true ]]; then
    return 0
  fi
  info "Waiting for rollouts (timeout ${ROLLOUT_TIMEOUT} each)"

  local ns kind obj target rc=0
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

  # Only this repo's kube-system workloads, never k3s's own.
  for target in "${KUBE_SYSTEM_WORKLOADS[@]}"; do
    kubectl -n kube-system get "${target}" >/dev/null 2>&1 || continue
    if kubectl -n kube-system rollout status "${target}" --timeout="${ROLLOUT_TIMEOUT}" >/dev/null 2>&1; then
      ok "kube-system/${target}"
    else
      fail "kube-system/${target} did not become ready"
      rc=1
    fi
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

  info "SealedSecrets"
  if kubectl get crd sealedsecrets.bitnami.com >/dev/null 2>&1; then
    kubectl get sealedsecret -A 2>/dev/null || true
  else
    warn "sealed-secrets not installed"
  fi

  info "Host entries needed for *.watchtower.local"
  local lb
  lb="$(kubectl -n kube-system get svc traefik -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
  if [[ -n "${lb}" ]]; then
    ok "Traefik is reachable at ${lb}"
    kubectl get ingressroute -A -o jsonpath='{range .items[*]}{.spec.routes[*].match}{"\n"}{end}' 2>/dev/null \
      | grep -o '[a-z0-9.-]*watchtower\.local' | sort -u | sed "s|^|       ${lb}  |"
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
  apply_sealed_secrets
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
