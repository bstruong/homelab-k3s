#!/usr/bin/env bash
# ==============================================================================
# reconcile-appdata-permissions.sh
# Authoritative permissions ledger and reconciliation script for /mnt/appdata.
#
# Solves the "HostPath Permissions Spaghetti" hazard by strictly defining
# and enforcing the exact UID, GID, and permissions required by container
# workloads. Prevents database startup failures caused by accidental chown -R.
# ==============================================================================

set -euo pipefail

APPDATA_DIR="${1:-/mnt/appdata}"

if [[ ! -d "$APPDATA_DIR" ]]; then
  echo "Error: Directory $APPDATA_DIR does not exist." >&2
  exit 1
fi

if [[ $EUID -ne 0 ]]; then
  echo "Error: This script must be run as root (sudo)." >&2
  exit 1
fi

echo "=== Reconciling permissions in $APPDATA_DIR ==="

# Helper function: set owner and permissions safely
reconcile() {
  local path="$1"
  local owner="$2"
  local mode="$3"
  
  if [[ -e "$path" ]]; then
    echo "  Applying $owner ($mode) -> $path"
    chown "$owner" "$path"
    chmod "$mode" "$path"
  fi
}

reconcile_recursive() {
  local path="$1"
  local owner="$2"
  local dir_mode="$3"
  local file_mode="$4"

  if [[ -d "$path" ]]; then
    echo "  Recursively applying $owner (dirs: $dir_mode, files: $file_mode) -> $path"
    chown -R "$owner" "$path"
    find "$path" -type d -exec chmod "$dir_mode" {} +
    find "$path" -type f -exec chmod "$file_mode" {} +
  fi
}

# --- Base Appdata Directory ---
reconcile "$APPDATA_DIR" "1000:1000" "755"

# --- AdGuard Home (Runs as root inside container) ---
reconcile_recursive "$APPDATA_DIR/adguard-home" "0:0" "755" "644"

# --- Beszel Hub & Agent (UID 1000) ---
reconcile "$APPDATA_DIR/beszel" "1000:1000" "700"
if [[ -d "$APPDATA_DIR/beszel" ]]; then
  find "$APPDATA_DIR/beszel" -type d -exec chmod 700 {} +
  find "$APPDATA_DIR/beszel" -type f -exec chmod 600 {} +
  [[ -d "$APPDATA_DIR/beszel/storage" ]] && chmod 755 "$APPDATA_DIR/beszel/storage"
  chown -R 1000:1000 "$APPDATA_DIR/beszel"
fi

# --- Caster (PostgreSQL runs as UID 999) ---
reconcile "$APPDATA_DIR/caster" "0:0" "755"
reconcile_recursive "$APPDATA_DIR/caster/postgres" "999:999" "700" "600"

# --- Immich (Server runs as root/1000, Postgres runs as UID 999) ---
reconcile "$APPDATA_DIR/immich" "0:0" "755"
reconcile "$APPDATA_DIR/immich/library" "0:0" "755"
reconcile_recursive "$APPDATA_DIR/immich/postgres" "999:999" "700" "600"

# --- Paperless-ngx (UID 1000) ---
reconcile_recursive "$APPDATA_DIR/paperless-ngx" "1000:1000" "775" "664"

# --- Pocket ID (UID 1000) ---
reconcile_recursive "$APPDATA_DIR/pocket-id" "1000:1000" "700" "600"
[[ -d "$APPDATA_DIR/pocket-id/uploads" ]] && chmod 755 "$APPDATA_DIR/pocket-id/uploads"

# --- Docker Registry (UID 1000) ---
reconcile_recursive "$APPDATA_DIR/registry" "1000:1000" "755" "644"

# --- ntfy (UID 1000) ---
reconcile_recursive "$APPDATA_DIR/ntfy" "1000:1000" "700" "600"
[[ -d "$APPDATA_DIR/ntfy/attachments" ]] && chmod 755 "$APPDATA_DIR/ntfy/attachments"

# --- Uptime Kuma (UID 1000) ---
reconcile_recursive "$APPDATA_DIR/uptime-kuma" "1000:1000" "755" "644"
[[ -f "$APPDATA_DIR/uptime-kuma/kuma.db" ]] && chmod 755 "$APPDATA_DIR/uptime-kuma/kuma.db"

# --- Vaultwarden (UID 1000) ---
reconcile_recursive "$APPDATA_DIR/vaultwarden" "1000:1000" "700" "600"
[[ -d "$APPDATA_DIR/vaultwarden/attachments" ]] && chmod 755 "$APPDATA_DIR/vaultwarden/attachments"
[[ -d "$APPDATA_DIR/vaultwarden/icon_cache" ]] && chmod 755 "$APPDATA_DIR/vaultwarden/icon_cache"
[[ -d "$APPDATA_DIR/vaultwarden/sends" ]] && chmod 755 "$APPDATA_DIR/vaultwarden/sends"

# --- Nextcloud (www-data runs as UID 33, Postgres runs as UID 999) ---
reconcile "$APPDATA_DIR/nextcloud" "0:0" "755"
reconcile_recursive "$APPDATA_DIR/nextcloud/html" "33:33" "755" "644"
reconcile_recursive "$APPDATA_DIR/nextcloud/postgres" "999:999" "700" "600"

# --- Homelab CA (Root CA offline storage, UID 1000) ---
if [[ -d "$APPDATA_DIR/homelab-ca" ]]; then
  chown -R 1000:1000 "$APPDATA_DIR/homelab-ca"
  chmod 700 "$APPDATA_DIR/homelab-ca"
  find "$APPDATA_DIR/homelab-ca" -type f -exec chmod 644 {} +
  [[ -f "$APPDATA_DIR/homelab-ca/ca.key" ]] && chmod 600 "$APPDATA_DIR/homelab-ca/ca.key"
  [[ -d "$APPDATA_DIR/homelab-ca/intermediate" ]] && chmod 700 "$APPDATA_DIR/homelab-ca/intermediate"
  [[ -f "$APPDATA_DIR/homelab-ca/intermediate/intermediate.key" ]] && chmod 600 "$APPDATA_DIR/homelab-ca/intermediate/intermediate.key"
fi

echo "=== Permission reconciliation complete ==="
