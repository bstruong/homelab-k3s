#!/usr/bin/env bash
#
# Manage the Watchtower stack's credentials.
#
#   ./scripts/secrets.sh seal [app...]     encrypt into committable SealedSecrets
#   ./scripts/secrets.sh apply [app...]    create Secrets directly in the cluster
#   ./scripts/secrets.sh check             report what exists, in repo and cluster
#   ./scripts/secrets.sh list              show the secret inventory
#
#   --show     print generated values once (nothing else ever prints them)
#   --force    overwrite a SealedSecret / Secret that already exists
#
# This repository is PUBLIC. `seal` is the supported workflow: values are
# generated in memory, piped straight into kubeseal, and only the encrypted
# result reaches the filesystem. Plaintext is never written to disk, and the
# pre-commit hook blocks `kind: Secret` from being committed at all.
#
# `apply` exists for anyone not running the sealed-secrets controller. It
# leaves nothing behind in the repo — the credentials then live only in the
# cluster, so back them up yourself.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MANIFEST_DIR="${REPO_ROOT}/manifests/watchtower"
CONTROLLER_NAME="${SEALED_SECRETS_CONTROLLER:-sealed-secrets-controller}"
CONTROLLER_NS="${SEALED_SECRETS_NAMESPACE:-kube-system}"

ALL_APPS="traefik tailscale vaultwarden crowdsec beszel paperless-ngx appflowy syncthing"

MODE=""
SHOW=false
FORCE=false
SELECTED=()

# Filled in by collect(), which deliberately runs in the current shell so that
# these survive — a pipeline or $( ) would discard them.
LITERALS=()
SUMMARY=()

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[0;33m'; BLUE=$'\033[0;34m'; NC=$'\033[0m'
info() { printf '%s==>%s %s\n' "${BLUE}" "${NC}" "$*"; }
ok()   { printf '%s ok %s %s\n' "${GREEN}" "${NC}" "$*"; }
warn() { printf '%swarn%s %s\n' "${YELLOW}" "${NC}" "$*"; }
die()  { printf '%sfail%s %s\n' "${RED}" "${NC}" "$*" >&2; exit 1; }

usage() {
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "${BASH_SOURCE[0]}"
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    seal|apply|check|list) MODE="$1" ;;
    --show)    SHOW=true ;;
    --force)   FORCE=true ;;
    -h|--help) usage ;;
    -*)        die "unknown flag: $1" ;;
    *)         SELECTED+=("$1") ;;
  esac
  shift
done

if [[ -z "${MODE}" ]]; then
  usage
fi

# ------------------------------------------------------------------ helpers --

# Random value from a URL-safe alphabet: no shell metacharacters, so these are
# safe to embed in connection strings and htpasswd lines.
#
# Reads /dev/urandom in finite blocks rather than streaming it. The obvious
# version of this function --
#
#   tr -dc 'A-Za-z0-9' </dev/urandom | head -c "$1"
#
# -- looks correct and prints a correct value, but exits 141: `head` closes the
# pipe as soon as it has enough bytes, `tr` is still writing an endless stream
# and dies of SIGPIPE, and `set -o pipefail` (set at the top of this script)
# then reports the pipeline as failed. Under `set -e` that aborted the caller
# mid-generation, which is a silent failure rather than a loud one. See
# collect().
gen() {
  local n="${1:-48}" out=""
  while (( ${#out} < n )); do
    # 8 bytes per character wanted, plus a floor: only ~24% of random bytes
    # land in [A-Za-z0-9], so this clears n on the first pass in practice.
    # `head` bounds the read, so `tr` reaches EOF on its own and exits 0.
    out+="$(LC_ALL=C head -c "$(( (n - ${#out}) * 8 + 64 ))" /dev/urandom \
            | LC_ALL=C tr -dc 'A-Za-z0-9')"
  done
  printf '%s' "${out:0:n}"
}

# Reads from the terminal so it still works with stdout redirected.
prompt() {
  local description="$1" value=""
  printf '\n  %s\n' "${description}" >&2
  printf '  (leave blank to skip this secret for now): ' >&2
  read -r value </dev/tty || true
  printf '%s' "${value}"
}

app_namespace() {
  case "$1" in
    traefik|tailscale) echo kube-system ;;
    vaultwarden)       echo identity ;;
    crowdsec|beszel)   echo monitoring ;;
    paperless-ngx|appflowy) echo docs ;;
    syncthing)         echo sync ;;
    *) die "unknown app: $1 (known: ${ALL_APPS})" ;;
  esac
}

# The Secret's name is not always the app's name.
app_secret_name() {
  case "$1" in
    traefik) echo traefik-dashboard-auth ;;
    beszel)  echo beszel-agent ;;
    *)       echo "$1" ;;
  esac
}

app_dir() { echo "${MANIFEST_DIR}/$1"; }

# Emits two kinds of line, consumed by collect():
#   literal:key=value   material that goes into the Secret
#   summary:text        a human-readable credential to show with --show
# Runs in a subshell, so it must not try to set variables itself.
app_literals() {
  case "$1" in
    traefik)
      # Traefik's BasicAuth middleware takes an htpasswd line. Only the hash is
      # stored; the password is shown once by --show and then unrecoverable.
      local pw hash
      pw="$(gen 24)"
      if command -v htpasswd >/dev/null 2>&1; then
        hash="$(htpasswd -nbB admin "${pw}")"
      else
        hash="admin:$(openssl passwd -apr1 "${pw}")"
      fi
      printf 'summary:Traefik dashboard      admin / %s\n' "${pw}"
      printf 'literal:users=%s\n' "${hash}"
      ;;

    tailscale)
      local key
      key="$(prompt 'Tailscale auth key, from https://login.tailscale.com/admin/settings/keys
  Use a reusable, pre-authorized key. Tag it so the ACLs can target this node.')"
      if [[ -n "${key}" ]]; then
        printf 'literal:authkey=%s\n' "${key}"
      fi
      ;;

    vaultwarden)
      local token
      token="$(gen 64)"
      printf 'summary:Vaultwarden admin token %s\n' "${token}"
      printf 'literal:admin-token=%s\n' "${token}"
      ;;

    crowdsec)
      local bouncer enroll
      bouncer="$(gen 40)"
      printf 'summary:CrowdSec bouncer key   %s\n' "${bouncer}"
      printf 'literal:bouncer-key=%s\n' "${bouncer}"
      enroll="$(prompt 'CrowdSec console enroll key from https://app.crowdsec.net (optional).')"
      # The key must exist even when unused; an empty value disables enrollment.
      printf 'literal:enroll-key=%s\n' "${enroll}"
      ;;

    beszel)
      local key
      key="$(prompt 'Beszel hub SSH public key.
  Deploy the hub first, open https://beszel.watchtower.local -> Add System,
  then copy the key it displays (ssh-ed25519 AAAA...).')"
      if [[ -n "${key}" ]]; then
        printf 'literal:hub-public-key=%s\n' "${key}"
      fi
      ;;

    paperless-ngx)
      local secret_key admin_pw
      secret_key="$(gen 64)"
      admin_pw="$(gen 24)"
      printf 'summary:Paperless admin        admin / %s\n' "${admin_pw}"
      printf 'literal:secret-key=%s\n' "${secret_key}"
      printf 'literal:admin-user=admin\n'
      printf 'literal:admin-password=%s\n' "${admin_pw}"
      ;;

    appflowy)
      local pg jwt gotrue_pw minio_ak minio_sk
      pg="$(gen 32)"; jwt="$(gen 64)"; gotrue_pw="$(gen 24)"
      minio_ak="$(gen 20)"; minio_sk="$(gen 40)"
      printf 'summary:AppFlowy postgres      postgres / %s\n' "${pg}"
      printf 'summary:AppFlowy admin         admin@watchtower.local / %s\n' "${gotrue_pw}"
      printf 'summary:AppFlowy minio         %s / %s\n' "${minio_ak}" "${minio_sk}"
      printf 'literal:postgres-password=%s\n' "${pg}"
      # Derived from postgres-password and stored alongside it, so the two can
      # never drift apart during a rotation.
      printf 'literal:database-url=postgres://postgres:%s@appflowy-postgres:5432/postgres\n' "${pg}"
      printf 'literal:jwt-secret=%s\n' "${jwt}"
      printf 'literal:gotrue-admin-password=%s\n' "${gotrue_pw}"
      printf 'literal:minio-access-key=%s\n' "${minio_ak}"
      printf 'literal:minio-secret-key=%s\n' "${minio_sk}"
      ;;

    syncthing)
      local apikey
      apikey="$(gen 32)"
      printf 'summary:Syncthing API key      %s\n' "${apikey}"
      printf 'literal:gui-apikey=%s\n' "${apikey}"
      ;;
  esac
}

# Populates LITERALS and SUMMARY for one app. The loop body runs in this shell,
# which is what lets it assign to them at all.
#
# The generator's output is captured first rather than streamed from a process
# substitution. A process substitution discards the writer's exit status, so a
# generator that died partway through was indistinguishable from one that had
# nothing to say -- and every caller reported the second thing ("nothing to
# seal") while the first was what had actually happened. Capturing makes the
# status observable.
#
# prompt() is unaffected: it reads /dev/tty and writes its question to stderr,
# and neither is captured here.
collect() {
  local line output status=0
  LITERALS=()

  output="$(app_literals "$1")" || status=$?
  if (( status != 0 )); then
    die "generating credentials for $1 failed (exit ${status})"
  fi

  while IFS= read -r line; do
    case "${line}" in
      literal:*) LITERALS+=("--from-literal=${line#literal:}") ;;
      summary:*) SUMMARY+=("${line#summary:}") ;;
    esac
  done <<<"${output}"
}

# Writes the Secret YAML to stdout from the already-collected LITERALS.
render_secret() {
  local app="$1"
  kubectl create secret generic "$(app_secret_name "${app}")" \
    --namespace "$(app_namespace "${app}")" \
    "${LITERALS[@]}" \
    --dry-run=client -o yaml
}

# --------------------------------------------------------------- operations --

do_seal() {
  local app="$1" out
  out="$(app_dir "${app}")/sealedsecret.yaml"

  if [[ -f "${out}" && "${FORCE}" != true ]]; then
    ok "skip ${app} (already sealed; --force to rotate)"
    return 0
  fi

  collect "${app}"
  if [[ ${#LITERALS[@]} -eq 0 ]]; then
    warn "skip ${app} (nothing to seal)"
    return 0
  fi

  mkdir -p "$(dirname "${out}")"

  # Plaintext exists only inside this pipeline. On failure the temp file is
  # removed rather than left behind holding a partial result.
  if ! render_secret "${app}" \
      | kubeseal --format yaml \
          --controller-name "${CONTROLLER_NAME}" \
          --controller-namespace "${CONTROLLER_NS}" \
      > "${out}.tmp"; then
    rm -f "${out}.tmp"
    die "kubeseal failed for ${app}"
  fi

  if [[ ! -s "${out}.tmp" ]]; then
    rm -f "${out}.tmp"
    die "kubeseal produced no output for ${app}"
  fi

  mv "${out}.tmp" "${out}"
  ok "sealed ${app} -> ${out#"${REPO_ROOT}"/}"
}

do_apply() {
  local app="$1" ns name
  ns="$(app_namespace "${app}")"
  name="$(app_secret_name "${app}")"

  kubectl get namespace "${ns}" >/dev/null 2>&1 || kubectl create namespace "${ns}" >/dev/null

  if kubectl -n "${ns}" get secret "${name}" >/dev/null 2>&1; then
    if [[ "${FORCE}" != true ]]; then
      ok "skip ${ns}/${name} (exists; --force to rotate)"
      return 0
    fi
    kubectl -n "${ns}" delete secret "${name}" >/dev/null
  fi

  collect "${app}"
  if [[ ${#LITERALS[@]} -eq 0 ]]; then
    warn "skip ${app} (nothing to create)"
    return 0
  fi

  render_secret "${app}" | kubectl apply -f - >/dev/null
  ok "applied ${ns}/${name}"
}

do_check() {
  local app ns name sealed cluster live=false
  if command -v kubectl >/dev/null 2>&1 && kubectl cluster-info >/dev/null 2>&1; then
    live=true
  fi

  printf '%-16s %-12s %-24s %-8s %s\n' APP NAMESPACE SECRET SEALED CLUSTER
  for app in ${ALL_APPS}; do
    ns="$(app_namespace "${app}")"
    name="$(app_secret_name "${app}")"

    if [[ -f "$(app_dir "${app}")/sealedsecret.yaml" ]]; then sealed="yes"; else sealed="no"; fi

    if [[ "${live}" == true ]]; then
      if kubectl -n "${ns}" get secret "${name}" >/dev/null 2>&1; then
        cluster="present"
      else
        cluster="MISSING"
      fi
    else
      cluster="(no cluster)"
    fi

    printf '%-16s %-12s %-24s %-8s %s\n' "${app}" "${ns}" "${name}" "${sealed}" "${cluster}"
  done
}

do_list() {
  cat <<'EOF'
App             Namespace    Secret                   Keys
--------------- ------------ ------------------------ ------------------------------
traefik         kube-system  traefik-dashboard-auth   users
tailscale       kube-system  tailscale                authkey
vaultwarden     identity     vaultwarden              admin-token
crowdsec        monitoring   crowdsec                 bouncer-key, enroll-key
beszel          monitoring   beszel-agent             hub-public-key
paperless-ngx   docs         paperless-ngx            secret-key, admin-user,
                                                      admin-password
appflowy        docs         appflowy                 postgres-password, database-url,
                                                      jwt-secret, gotrue-admin-password,
                                                      minio-access-key, minio-secret-key
syncthing       sync         syncthing                gui-apikey

Credentials that are NOT Kubernetes Secrets, because the app owns its own
credential store and sets it up through a first-run wizard:

  AdGuard Home admin, Jellyfin admin, Home Assistant owner, Pocket ID admin,
  Uptime Kuma admin, and every Vaultwarden user's master password.

See docs/SECRETS.md for the order those need to happen in.
EOF
}

# --------------------------------------------------------------------- main --

main() {
  if [[ "${MODE}" == "list" ]]; then
    do_list
    exit 0
  fi

  command -v kubectl >/dev/null || die "kubectl not found in PATH"

  if [[ "${MODE}" == "check" ]]; then
    do_check
    exit 0
  fi

  local apps
  if [[ ${#SELECTED[@]} -gt 0 ]]; then
    apps=("${SELECTED[@]}")
  else
    # shellcheck disable=SC2206  # deliberate word splitting of the app list
    apps=(${ALL_APPS})
  fi

  # Validate names before doing any work, so a typo cannot half-complete a run.
  local app
  for app in "${apps[@]}"; do
    app_namespace "${app}" >/dev/null
  done

  if [[ "${MODE}" == "seal" ]]; then
    command -v kubeseal >/dev/null \
      || die "kubeseal not found. Install it, or use 'apply' mode. See docs/SECRETS.md"
    kubectl -n "${CONTROLLER_NS}" get deployment "${CONTROLLER_NAME}" >/dev/null 2>&1 \
      || die "no sealed-secrets controller in ${CONTROLLER_NS}. Run scripts/bootstrap-sealed-secrets.sh"
    info "Sealing secrets — the encrypted output is safe to commit"
  else
    kubectl cluster-info >/dev/null 2>&1 || die "cannot reach the cluster"
    warn "apply mode: credentials will exist only in the cluster, not in this repo"
    info "Creating secrets"
  fi

  for app in "${apps[@]}"; do
    if [[ "${MODE}" == "seal" ]]; then
      do_seal "${app}"
    else
      do_apply "${app}"
    fi
  done

  if [[ ${#SUMMARY[@]} -gt 0 ]]; then
    if [[ "${SHOW}" == true ]]; then
      echo
      echo "------------------------------------------------------------------"
      echo "Generated credentials. Save them now — they are stored only as"
      echo "hashes or ciphertext and cannot be recovered."
      echo "------------------------------------------------------------------"
      printf '%s\n' "${SUMMARY[@]}"
      echo "------------------------------------------------------------------"
    else
      echo
      echo "Re-run with --show to print the generated values."
    fi
  fi

  if [[ "${MODE}" == "seal" ]]; then
    echo
    echo "Commit the sealed manifests:"
    echo "  git add manifests/watchtower/*/sealedsecret.yaml && git commit"
  fi
}

main
