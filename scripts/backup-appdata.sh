#!/usr/bin/env bash
# ==============================================================================
# backup-appdata.sh
# Production off-host backup script for Watchtower.
#
# Addresses the "Single-Disk Storage SPOF" by performing:
#   1. Clean database dumps (PostgreSQL logical dumps & SQLite live backups).
#   2. Cluster secret & master key extraction.
#   3. Atomic rsync mirror to Metrotower (/mnt/Archive) with preserved UIDs.
# ==============================================================================

set -euo pipefail

DEST_HOST="${DEST_HOST:-192.168.1.245}"
DEST_PATH="${DEST_PATH:-/mnt/Archive/watchtower-backup}"
BACKUP_TEMP="/mnt/appdata/backups/dumps"
KUBECONFIG="${KUBECONFIG:-/home/brian/.kube/config}"
export KUBECONFIG

mkdir -p "$BACKUP_TEMP"

echo "=== Starting Watchtower Off-Host Backup ==="
echo "Timestamp: $(date -Iseconds)"

# --- 1. Database Logical Dumps ---
echo "[1/4] Performing database backups..."

# Caster PostgreSQL
if kubectl -n caster get pod caster-postgres-0 &>/dev/null; then
  echo "  Dumping Caster PostgreSQL..."
  kubectl -n caster exec caster-postgres-0 -- pg_dumpall -U postgres | gzip > "$BACKUP_TEMP/caster-postgres.sql.gz" || true
fi

# Immich PostgreSQL
if kubectl -n immich get pod immich-postgres-0 &>/dev/null; then
  echo "  Dumping Immich PostgreSQL..."
  kubectl -n immich exec immich-postgres-0 -- pg_dumpall -U postgres | gzip > "$BACKUP_TEMP/immich-postgres.sql.gz" || true
fi

# Vaultwarden SQLite backup (hot-safe)
if [[ -f "/mnt/appdata/vaultwarden/db.sqlite3" ]]; then
  echo "  Backing up Vaultwarden SQLite..."
  sqlite3 /mnt/appdata/vaultwarden/db.sqlite3 ".backup '$BACKUP_TEMP/vaultwarden-backup.sqlite3'" || true
fi

# Uptime Kuma SQLite backup
if [[ -f "/mnt/appdata/uptime-kuma/kuma.db" ]]; then
  echo "  Backing up Uptime Kuma SQLite..."
  sqlite3 /mnt/appdata/uptime-kuma/kuma.db ".backup '$BACKUP_TEMP/uptime-kuma-backup.sqlite3'" || true
fi

# --- 2. Master Decryption Keys & Kubeconfig ---
echo "[2/4] Backing up cluster decryption keys..."
kubectl -n kube-system get secret -l sealedsecrets.bitnami.com/sealed-secrets-key -o yaml > "$BACKUP_TEMP/sealed-secrets-master-keys.yaml" || true
cp "$KUBECONFIG" "$BACKUP_TEMP/kubeconfig.yaml" || true

# --- 3. Rsync to Metrotower Archive ---
echo "[3/4] Mirroring /mnt/appdata to $DEST_HOST:$DEST_PATH..."
rsync -aHAX --numeric-ids --delete \
  --exclude="k3s-data" \
  --exclude="lost+found" \
  --exclude="staging" \
  /mnt/appdata/ \
  "brian@${DEST_HOST}:${DEST_PATH}/appdata/"

# Mirror cluster recovery secrets
rsync -av "$BACKUP_TEMP/" "brian@${DEST_HOST}:${DEST_PATH}/"

# --- 4. Host Code & Dotfiles ---
echo "[4/4] Mirroring host code and dotfiles..."
rsync -aHAX --numeric-ids --delete \
  /home/brian/dojos \
  /home/brian/python-express-dojo \
  /home/brian/ruby-express-dojo \
  /home/brian/rider \
  /home/brian/.config \
  /home/brian/.ssh \
  "brian@${DEST_HOST}:${DEST_PATH}/host-home/"

echo "=== Backup completed successfully ==="
