#!/usr/bin/env bash
#
# Install the sealed-secrets controller, which is what makes it safe for this
# repository to be public: it holds the private key, in the cluster, and is the
# only thing that can decrypt the SealedSecret manifests committed here.
#
#   ./scripts/bootstrap-sealed-secrets.sh              install
#   ./scripts/bootstrap-sealed-secrets.sh --backup-key back up the private key
#
# Back the key up somewhere offline. Without it, a rebuilt cluster cannot
# decrypt anything in this repo and every credential has to be regenerated.

set -euo pipefail

VERSION="${SEALED_SECRETS_VERSION:-v0.27.1}"
CONTROLLER_NS="${SEALED_SECRETS_NAMESPACE:-kube-system}"
BACKUP_ONLY=false

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[0;33m'; BLUE=$'\033[0;34m'; NC=$'\033[0m'
info() { printf '%s==>%s %s\n' "${BLUE}" "${NC}" "$*"; }
ok()   { printf '%s ok %s %s\n' "${GREEN}" "${NC}" "$*"; }
warn() { printf '%swarn%s %s\n' "${YELLOW}" "${NC}" "$*"; }
die()  { printf '%sfail%s %s\n' "${RED}" "${NC}" "$*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --backup-key) BACKUP_ONLY=true ;;
    -h|--help) awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) die "unknown flag: $1" ;;
  esac
  shift
done

command -v kubectl >/dev/null || die "kubectl not found in PATH"
kubectl cluster-info >/dev/null 2>&1 || die "cannot reach the cluster"

backup_key() {
  local out="sealed-secrets-key-$(date +%Y%m%d-%H%M%S).yaml"
  info "Exporting the controller's private key"
  kubectl -n "${CONTROLLER_NS}" get secret \
    -l sealedsecrets.bitnami.com/sealed-secrets-key -o yaml > "${out}"
  chmod 600 "${out}"
  ok "wrote ${out}"
  warn "This file decrypts every SealedSecret in this repo."
  warn "Move it to offline storage and delete the local copy. It is gitignored,"
  warn "but do not rely on that alone."
}

if [[ "${BACKUP_ONLY}" == true ]]; then
  backup_key
  exit 0
fi

if kubectl -n "${CONTROLLER_NS}" get deployment sealed-secrets-controller >/dev/null 2>&1; then
  ok "controller already installed"
else
  info "Installing sealed-secrets ${VERSION}"
  kubectl apply -f \
    "https://github.com/bitnami-labs/sealed-secrets/releases/download/${VERSION}/controller.yaml"
  kubectl -n "${CONTROLLER_NS}" rollout status deployment/sealed-secrets-controller --timeout=120s
  ok "controller ready"
fi

if ! command -v kubeseal >/dev/null 2>&1; then
  echo
  warn "kubeseal (the CLI) is not installed. Install it to seal secrets:"
  echo "  macOS:  brew install kubeseal"
  echo "  Linux:  https://github.com/bitnami-labs/sealed-secrets/releases/tag/${VERSION}"
fi

cat <<EOF

Next:
  ./scripts/secrets.sh seal --show          generate and seal every credential
  ./scripts/bootstrap-sealed-secrets.sh --backup-key
  ./deploy.sh

EOF
