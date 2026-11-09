# Shared helpers for jarvis-up / jarvis-down / jarvis-lease.
# shellcheck shell=bash

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
