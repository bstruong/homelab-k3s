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

# The app namespaces. Traefik also lives in kube-system, but it is k3s's own
# bundled install rather than something this repo deploys, so it is never waited
# on here. This repo now owns no kube-system workloads at all.
NAMESPACES=(adguard identity monitoring media docs sync home infra caster immich)

# app|namespace|secret|required keys (a trailing ? marks an optional key,
# which must exist but may be empty)
# app|namespace|secret|keys
#
# A key marked with a trailing `?` is OPTIONAL: it may be absent or empty, and
# its absence downgrades the app rather than aborting the deploy. A secret with
# at least one unmarked key is REQUIRED and blocks the run.
#
# Optional does not mean the app invents the credential for itself. Every
# reference in these manifests is a plain secretKeyRef, so a pod whose Secret is
# missing stays in CreateContainerConfigError until it exists — the deploy
# continues and the rest of the stack comes up, which is the point. See
# consequence_for_app() for what each one actually costs.
SECRET_SPECS=(
  "traefik|kube-system|traefik-dashboard-auth|users?"
  "vaultwarden|identity|vaultwarden|admin-token?"
  "beszel|monitoring|beszel-agent|hub-public-key?"
  "paperless-ngx|docs|paperless-ngx|secret-key?,admin-user?,admin-password?"
  "appflowy|docs|appflowy|postgres-password?,database-url?,jwt-secret?,gotrue-admin-password?,minio-access-key?,minio-secret-key?"
  "syncthing|sync|syncthing|gui-apikey?"
  "registry|infra|registry-htpasswd|htpasswd?"
  "caster|caster|caster|postgres-password,secret-key-base"
  "immich|immich|immich|postgres-password"
)

# What actually happens when an optional secret is missing.
consequence_for_app() {
  case "$1" in
    traefik)       echo "the dashboard route returns 500; Traefik itself is unaffected" ;;
    vaultwarden)   echo "vaultwarden pod stays in CreateContainerConfigError" ;;
    beszel)        echo "beszel-agent will not start; the hub generates this key on first run (docs/SECRETS.md)" ;;
    paperless-ngx) echo "paperless-ngx pod stays in CreateContainerConfigError" ;;
    appflowy)      echo "all five appflowy pods stay in CreateContainerConfigError" ;;
    syncthing)     echo "syncthing pod stays in CreateContainerConfigError" ;;
    registry)      echo "registry pod stays in CreateContainerConfigError; no image push or pull works" ;;
    immich)        echo "immich-postgres and immich-server both stay in CreateContainerConfigError" ;;
    *)             echo "the app may not start" ;;
  esac
}

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
  sudo mkdir -p ${APPDATA_ROOT}/{paperless-ngx,beszel,uptime-kuma}
  sudo mkdir -p ${APPDATA_ROOT}/{syncthing,home-assistant,media,registry}
  sudo mkdir -p ${APPDATA_ROOT}/appflowy/{postgres,minio}
  sudo mkdir -p ${APPDATA_ROOT}/caster/postgres
  sudo mkdir -p ${APPDATA_ROOT}/immich/{postgres,library}

  # Apps running as uid 1000. Each directory is named explicitly on purpose:
  # a recursive chown of ${APPDATA_ROOT} itself would also rewrite k3s's
  # relocated data directory, which lives under this root and must stay
  # root-owned.
  sudo chown -R 1000:1000 ${APPDATA_ROOT}/{vaultwarden,pocket-id,jellyfin,media}
  sudo chown -R 1000:1000 ${APPDATA_ROOT}/{paperless-ngx,beszel,uptime-kuma,syncthing}
  sudo chown -R 1000:1000 ${APPDATA_ROOT}/registry                  # registry runs as uid 1000
  sudo chown -R 1000:1000 ${APPDATA_ROOT}/appflowy/minio
  sudo chown -R 999:999   ${APPDATA_ROOT}/appflowy/postgres  # postgres runs as uid 999
  sudo chown -R 999:999   ${APPDATA_ROOT}/caster/postgres    # postgres runs as uid 999
  sudo chown -R 999:999   ${APPDATA_ROOT}/immich/postgres    # postgres runs as uid 999

  # Apps whose container runs as uid 0. These MUST be root-owned. Every
  # container here drops ALL capabilities, so none of them holds
  # CAP_DAC_OVERRIDE — and without it uid 0 gets no permission bypass at all.
  # Against a 1000-owned 0755 directory, "other" has only r-x, so a root
  # process cannot create anything inside it. Getting this wrong looks like
  # a bare "permission denied" from an app you believe is running as root.
  sudo chown -R 0:0       ${APPDATA_ROOT}/adguard-home       # its first-launch check is a bare uid==0 test
  sudo chown -R 0:0       ${APPDATA_ROOT}/home-assistant     # s6-overlay needs root
  sudo chown -R 0:0       ${APPDATA_ROOT}/immich/library     # immich-server runs as uid 0

EOF
}

# ------------------------------------------------------------------ secrets --

# Lists the key names present in a Secret. Checking names rather than values
# lets a key legitimately hold an empty string.
secret_keys() {
  kubectl -n "$1" get secret "$2" -o go-template='{{range $k, $v := .data}}{{$k}}{{"\n"}}{{end}}' 2>/dev/null
}

# True when a spec has at least one key without a `?` marker.
spec_is_required() {
  local keys="$1" key key_list
  IFS=, read -r -a key_list <<<"${keys}"
  for key in "${key_list[@]}"; do
    if [[ "${key}" != *\? ]]; then
      return 0
    fi
  done
  return 1
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
    # The controller decrypts asynchronously. Wait only on the secrets we just
    # applied — waiting on ones nobody sealed would always time out.
    local waited=0
    while [[ ${waited} -lt ${UNSEAL_TIMEOUT} ]]; do
      if sealed_secrets_unsealed; then
        break
      fi
      sleep 2
      waited=$((waited + 2))
    done
  fi
}

# Returns 0 once every app with a committed sealedsecret.yaml has its Secret.
sealed_secrets_unsealed() {
  local spec app ns name keys
  for spec in "${SECRET_SPECS[@]}"; do
    IFS='|' read -r app ns name keys <<<"${spec}"
    if [[ -n "${ONLY_APP}" && "${app}" != "${ONLY_APP}" ]]; then
      continue
    fi
    if [[ ! -f "${MANIFEST_DIR}/${app}/sealedsecret.yaml" ]]; then
      continue
    fi
    if [[ -z "$(secret_keys "${ns}" "${name}")" ]]; then
      return 1
    fi
  done
  return 0
}

# Required secrets abort the run. Optional ones only warn: the rest of the
# stack still deploys, and the warning says what that costs.
check_secrets() {
  info "Checking secrets"
  local spec app ns name keys key key_list present required
  local blocking=0 degraded=0

  for spec in "${SECRET_SPECS[@]}"; do
    IFS='|' read -r app ns name keys <<<"${spec}"
    if [[ -n "${ONLY_APP}" && "${app}" != "${ONLY_APP}" ]]; then
      continue
    fi

    if spec_is_required "${keys}"; then
      required=true
    else
      required=false
    fi

    # `|| true`: kubectl exits non-zero when the Secret does not exist, and a
    # missing Secret is a case to report, not a reason to abort under `set -e`.
    present="$(secret_keys "${ns}" "${name}" || true)"

    if [[ -z "${present}" ]]; then
      if [[ "${required}" == true ]]; then
        fail "missing secret ${ns}/${name} (required by ${app})"
        blocking=$((blocking + 1))
      else
        warn "missing secret ${ns}/${name} — $(consequence_for_app "${app}")"
        degraded=$((degraded + 1))
      fi
      continue
    fi

    local missing_required=0 missing_optional=0
    IFS=, read -r -a key_list <<<"${keys}"
    for key in "${key_list[@]}"; do
      if grep -Fxq "${key%\?}" <<<"${present}"; then
        continue
      fi
      if [[ "${key}" == *\? ]]; then
        missing_optional=$((missing_optional + 1))
      else
        fail "secret ${ns}/${name} has no key '${key}'"
        missing_required=$((missing_required + 1))
      fi
    done

    if [[ ${missing_required} -gt 0 ]]; then
      blocking=$((blocking + missing_required))
    elif [[ ${missing_optional} -gt 0 ]]; then
      warn "secret ${ns}/${name} is incomplete (${missing_optional} optional key(s)) — $(consequence_for_app "${app}")"
      degraded=$((degraded + 1))
    else
      ok "secret ${ns}/${name}"
    fi
  done

  if [[ ${degraded} -gt 0 ]]; then
    echo
    warn "${degraded} optional secret(s) missing. Deploying anyway; those pods"
    warn "will not start until the secrets exist. Create them with:"
    echo "    ./scripts/secrets.sh seal --show     # encrypt into the repo" >&2
    echo "    ./scripts/secrets.sh apply --show    # create in-cluster only" >&2
  fi

  if [[ ${blocking} -gt 0 ]]; then
    echo
    fail "${blocking} required secret problem(s) — nothing was deployed."
    echo "  Create them:  ./scripts/secrets.sh seal --show" >&2
    echo "  Or:           ./scripts/secrets.sh apply --show" >&2
    echo "  Details:      docs/SECRETS.md" >&2
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

  # Nothing in kube-system is waited on: Traefik there is k3s's own bundled
  # install, not this repo's. Tailscale used to be the one exception.

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
