#!/usr/bin/env bash
#
# Graceful Shutdown Script for Watchtower Homelab
#
# Can be run:
#   1. Directly on Watchtower:  ./scripts/homelab-shutdown.sh
#   2. Remotely from Metrotower: ./scripts/homelab-shutdown.sh
#
# Gracefully terminates Dojos, user systemd units, drains/stops k3s pods so
# databases (PostgreSQL, SQLite, Redis) flush WALs and commit cleanly to disk,
# flushes all storage buffers (sync), and powers off the server.

set -euo pipefail

WATCHTOWER_HOST="${WATCHTOWER_HOST:-192.168.1.92}"
WATCHTOWER_USER="${WATCHTOWER_USER:-btruong}"

FORCE=false
DRY_RUN=false

for arg in "$@"; do
  case "${arg}" in
    -f|--force) FORCE=true ;;
    -d|--dry-run) DRY_RUN=true ;;
    -h|--help)
      echo "Usage: $0 [--force] [--dry-run]"
      echo "  --force, -f    Bypass confirmation prompt"
      echo "  --dry-run, -d  Show actions without executing them"
      exit 0
      ;;
    *)
      echo "Unknown argument: ${arg}" >&2
      exit 1
      ;;
  esac
done

current_host="$(hostname -s 2>/dev/null || hostname)"

# If running remotely from Metrotower, delegate to Watchtower over SSH
if [[ "${current_host}" != "watchtower" ]]; then
  echo "===================================================================="
  echo " Watchtower Homelab — Graceful Remote Shutdown"
  echo " Target: ${WATCHTOWER_USER}@${WATCHTOWER_HOST}"
  echo "===================================================================="
  echo "This will safely stop:"
  echo "  - All K3s pods (AdGuard, Vaultwarden, Immich, Paperless, JARVIS)"
  echo "  - All database engines (PostgreSQL, SQLite, Redis WAL flush)"
  echo "  - User systemd units (Dojos, idle watchers)"
  echo "  - Host operating system (Fedora Server / Watchtower)"
  echo "===================================================================="

  if [[ "${FORCE}" != true && "${DRY_RUN}" != true ]]; then
    read -r -p "Are you sure you want to gracefully power off Watchtower? [y/N] " response
    case "${response}" in
      [yY][eE][sS]|[yY]) ;;
      *)
        echo "Shutdown cancelled."
        exit 0
        ;;
    esac
  fi

  if [[ "${DRY_RUN}" == true ]]; then
    echo "[dry-run] Would SSH into ${WATCHTOWER_USER}@${WATCHTOWER_HOST} and execute graceful shutdown sequence."
    exit 0
  fi

  echo "Connecting to Watchtower to initiate graceful shutdown..."
  # -t allocates a pseudo-terminal for sudo authentication
  ssh -t -o BatchMode=no "${WATCHTOWER_USER}@${WATCHTOWER_HOST}" \
    "~/homelab-k3s/scripts/homelab-shutdown.sh --force"
  exit 0
fi

# -----------------------------------------------------------------------------
# Watchtower Local Graceful Shutdown Execution
# -----------------------------------------------------------------------------
echo "===================================================================="
echo " Initiating Graceful Homelab Shutdown Sequence on $(hostname)"
echo "===================================================================="

if [[ "${DRY_RUN}" == true ]]; then
  echo "[dry-run] Step 1: Would stop user systemd units (dojos, idle watchers)"
  echo "[dry-run] Step 2: Would stop k3s service to let pods & databases exit cleanly"
  echo "[dry-run] Step 3: Would flush filesystem buffers (sync)"
  echo "[dry-run] Step 4: Would issue systemctl poweroff"
  exit 0
fi

# Step 1: Gracefully stop lingering user systemd services (Dojos)
echo "==> [1/4] Stopping user systemd units (Dojos)..."
systemctl --user stop dojos-static python-express-dojo ruby-express-dojo alpha-idle-watcher.timer 2>/dev/null || true

# Step 2: Gracefully stop K3s
# Stopping the k3s service sends SIGTERM to all running pods and honors their
# terminationGracePeriodSeconds, giving PostgreSQL, SQLite, and Redis time to
# flush transactions to /mnt/appdata before unmounting volumes.
echo "==> [2/4] Stopping K3s cluster service (graceful pod & database drain)..."
sudo systemctl stop k3s

# Step 3: Flush filesystem buffers to disk
echo "==> [3/4] Flushing all filesystem buffers (sync)..."
sync

# Step 4: Power off host
echo "==> [4/4] Powering off system..."
sudo systemctl poweroff
