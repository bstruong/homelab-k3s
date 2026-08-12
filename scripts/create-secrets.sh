#!/usr/bin/env bash
#
# Create the Kubernetes Secrets the Watchtower stack expects.
#
#   ./scripts/create-secrets.sh            create anything missing
#   ./scripts/create-secrets.sh --show     print generated values once, then exit
#   ./scripts/create-secrets.sh --force    recreate secrets that already exist
#
# Existing secrets are left alone unless --force is given, so this is safe to
# re-run. Generated values are random; the ones only you can supply are
# prompted for. Nothing is written to disk — put the values in your password
# manager when they are shown.

set -euo pipefail

FORCE=false
SHOW=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --force) FORCE=true ;;
    --show)  SHOW=true ;;
    *) echo "unknown flag: $1" >&2; exit 1 ;;
  esac
  shift
done

command -v kubectl >/dev/null || { echo "kubectl not found" >&2; exit 1; }

gen()  { LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c "${1:-48}"; }
have() { kubectl -n "$1" get secret "$2" >/dev/null 2>&1; }

ensure_ns() { kubectl get ns "$1" >/dev/null 2>&1 || kubectl create ns "$1"; }

create() {
  local ns="$1" name="$2"; shift 2
  ensure_ns "${ns}"
  if have "${ns}" "${name}"; then
    if [[ "${FORCE}" == true ]]; then
      kubectl -n "${ns}" delete secret "${name}"
    else
      echo "  skip  ${ns}/${name} (already exists)"
      return 0
    fi
  fi
  kubectl -n "${ns}" create secret generic "${name}" "$@" >/dev/null
  echo "  ok    ${ns}/${name}"
}

echo "Creating Watchtower secrets"

# --- Vaultwarden -------------------------------------------------------------
# ADMIN_TOKEN guards the /admin panel. Vaultwarden accepts a plain token; it is
# compared in constant time, so a long random string is what matters.
VW_ADMIN_TOKEN="$(gen 64)"
create identity vaultwarden --from-literal=admin-token="${VW_ADMIN_TOKEN}"

# --- Paperless-ngx -----------------------------------------------------------
PAPERLESS_SECRET_KEY="$(gen 64)"
PAPERLESS_ADMIN_PASSWORD="$(gen 24)"
create docs paperless-ngx \
  --from-literal=secret-key="${PAPERLESS_SECRET_KEY}" \
  --from-literal=admin-user="admin" \
  --from-literal=admin-password="${PAPERLESS_ADMIN_PASSWORD}"

# --- AppFlowy ----------------------------------------------------------------
# database-url is derived from postgres-password; both live in the same secret
# so they can never drift apart.
APPFLOWY_PG_PASSWORD="$(gen 32)"
APPFLOWY_JWT_SECRET="$(gen 64)"
APPFLOWY_GOTRUE_ADMIN_PASSWORD="$(gen 24)"
APPFLOWY_MINIO_ACCESS_KEY="$(gen 20)"
APPFLOWY_MINIO_SECRET_KEY="$(gen 40)"
create docs appflowy \
  --from-literal=postgres-password="${APPFLOWY_PG_PASSWORD}" \
  --from-literal=database-url="postgres://postgres:${APPFLOWY_PG_PASSWORD}@appflowy-postgres:5432/postgres" \
  --from-literal=jwt-secret="${APPFLOWY_JWT_SECRET}" \
  --from-literal=gotrue-admin-password="${APPFLOWY_GOTRUE_ADMIN_PASSWORD}" \
  --from-literal=minio-access-key="${APPFLOWY_MINIO_ACCESS_KEY}" \
  --from-literal=minio-secret-key="${APPFLOWY_MINIO_SECRET_KEY}"

# --- Beszel agent ------------------------------------------------------------
# This one is NOT generated: it is the hub's SSH public key, which the hub
# creates on first start. Deploy the hub, copy the key out of the UI
# (Add System -> the key is shown), then re-run with --force if it changes.
if have monitoring beszel-agent && [[ "${FORCE}" != true ]]; then
  echo "  skip  monitoring/beszel-agent (already exists)"
else
  echo
  echo "Beszel agent needs the hub's SSH public key."
  echo "Get it from the hub UI at https://beszel.watchtower.local -> Add System."
  echo "Leave blank to skip for now (the agent will not start until it is set)."
  read -r -p "  hub public key: " BESZEL_KEY
  if [[ -n "${BESZEL_KEY}" ]]; then
    create monitoring beszel-agent --from-literal=hub-public-key="${BESZEL_KEY}"
  else
    echo "  skip  monitoring/beszel-agent (no key given)"
  fi
fi

if [[ "${SHOW}" == true ]]; then
  cat <<EOF

------------------------------------------------------------------------
Save these now — they are not stored anywhere and are not recoverable.
(If a secret already existed, the value below was NOT applied.)
------------------------------------------------------------------------
Vaultwarden admin token   ${VW_ADMIN_TOKEN}
Paperless admin           admin / ${PAPERLESS_ADMIN_PASSWORD}
AppFlowy postgres         ${APPFLOWY_PG_PASSWORD}
AppFlowy gotrue admin     admin@watchtower.local / ${APPFLOWY_GOTRUE_ADMIN_PASSWORD}
AppFlowy minio            ${APPFLOWY_MINIO_ACCESS_KEY} / ${APPFLOWY_MINIO_SECRET_KEY}
------------------------------------------------------------------------
EOF
else
  echo
  echo "Re-run with --show to print the generated values."
fi
