#!/usr/bin/env bash
#
# Back up the two Retain-policy hostPath volumes behind Odysseus:
#
#   /mnt/appdata/odysseus   the app's own data — app.db, auth.json, uploads,
#                           and (once any credential is stored through the UI)
#                           .app_key, the Fernet key encrypting every stored
#                           credential. Losing that key is unrecoverable.
#   /mnt/appdata/chromadb   the vector store.
#
# Archived separately so either can be restored without touching the other.
#
# WHY THIS STOPS THE PODS FIRST
# Both apps keep their SQLite databases in rollback-journal mode, not WAL —
# verified, not assumed: `PRAGMA journal_mode` returns "delete" for
# data/app.db and data/scheduled_emails.db, and chroma.sqlite3's header
# read/write format bytes are 1/1 (2/2 would mean WAL). In rollback-journal
# mode a copy taken mid-transaction can capture the database after a partial
# write but without the -journal file needed to roll it back, which restores as
# a corrupt database. /mnt/appdata is ext4 on a single disk with no LVM, so
# there is no filesystem snapshot to take instead. Scaling to zero for the few
# seconds this takes is the only way to get a guaranteed-consistent copy with
# what is on this host. The data is ~88 MB, so the outage is brief.
#
# Runs unprivileged as brian: every path it touches is brian-owned and it uses
# the user kubeconfig. Nothing here needs root.
#
# Installed via user crontab on watchtower (crond is active there). See the
# "INSTALL" and "RESTORE" notes at the bottom of this file.

set -euo pipefail

# --- configuration ----------------------------------------------------------
BACKUP_ROOT="/mnt/appdata/backups"
NAMESPACE="odysseus"
KEEP=7

# Off-host copy. 192.168.1.245 is Metrotower — note it is a DHCP lease on WiFi,
# so if the lease moves this silently stops shipping off-host until the address
# is corrected. A static reservation would fix that properly.
REMOTE_HOST="${ODYSSEUS_BACKUP_REMOTE:-brian@192.168.1.245}"
REMOTE_DIR="${ODYSSEUS_BACKUP_REMOTE_DIR:-backups/watchtower/odysseus}"
REMOTE_PORT="${ODYSSEUS_BACKUP_REMOTE_PORT:-22}"

# Alerting. ntfy is only reachable from this host by ClusterIP: the topic
# hostname ntfy.watchtower.local resolves via AdGuard, which watchtower
# itself does not use, and the homelab CA is not in this host's trust
# store — so the pretty URL fails from here even though it works from
# every other machine. The IP is looked up through kubectl at run time
# rather than hardcoded, since it changes if the Service is recreated.
NTFY_NAMESPACE="${ODYSSEUS_NTFY_NAMESPACE:-monitoring}"
NTFY_SERVICE="${ODYSSEUS_NTFY_SERVICE:-ntfy}"
NTFY_TOPIC="${ODYSSEUS_NTFY_TOPIC:-watchtower-alerts}"
NTFY_TOKEN_FILE="${ODYSSEUS_NTFY_TOKEN_FILE:-$HOME/.config/ntfy/backup-token}"

# deployment:source-directory pairs
VOLUMES=(
  "odysseus:/mnt/appdata/odysseus"
  "chromadb:/mnt/appdata/chromadb"
)

export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"
export PATH="/usr/local/bin:/usr/bin:/bin"

STAMP="$(date +%Y%m%d-%H%M%S)"
LOG="${BACKUP_ROOT}/backup.log"

log() { printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$LOG" >&2; }

# Best-effort push notification. Never fails the run: an alert that cannot be
# delivered must not also destroy the backup that was taken successfully.
alert() {
  local title="$1" priority="$2" body="$3" addr token

  addr="$(kubectl -n "$NTFY_NAMESPACE" get svc "$NTFY_SERVICE" \
           -o jsonpath='{.spec.clusterIP}:{.spec.ports[0].port}' 2>/dev/null)" || addr=""
  case "$addr" in
    :*|"") log "WARNING: cannot resolve ${NTFY_SERVICE} service; alert NOT sent: ${title}"
           return 0 ;;
  esac

  if [[ ! -r "$NTFY_TOKEN_FILE" ]]; then
    log "WARNING: no ntfy token at ${NTFY_TOKEN_FILE}; alert NOT sent: ${title}"
    return 0
  fi
  token="$(tr -d '[:space:]' < "$NTFY_TOKEN_FILE")"

  if curl -fsS --max-time 15 \
       -H "Authorization: Bearer ${token}" \
       -H "Title: ${title}" \
       -H "Priority: ${priority}" \
       -H "Tags: floppy_disk" \
       -d "$body" \
       "http://${addr}/${NTFY_TOPIC}" >/dev/null 2>&1; then
    log "ntfy alert sent (${priority}): ${title}"
  else
    log "WARNING: ntfy alert FAILED to send: ${title}"
  fi
}

# Is the remote's SSH port actually open? This is what separates "the box is
# off/unplugged" from "the box is up and rejecting us". Without it we are left
# guessing from ssh's stderr, and ssh reports exit 255 for every one of these.
tcp_open() {
  timeout 10 bash -c ": >/dev/tcp/$1/$2" 2>/dev/null
}

# Map ssh stderr onto a cause. Only consulted when the port is known open, so
# the connectivity patterns here are a backstop rather than the primary signal.
classify_ssh_error() {
  case "$1" in
    *'REMOTE HOST IDENTIFICATION HAS CHANGED'*|*'Host key verification failed'*|\
    *'key for'*'has changed'*|*'No RSA host key is known'*)
      printf 'hostkey' ;;
    *'Permission denied'*|*'Too many authentication failures'*|\
    *'no matching host key type'*|*'no mutual signature algorithm'*|\
    *'Authentication failed'*|*'not accessible'*|*'UNPROTECTED PRIVATE KEY'*)
      printf 'auth' ;;
    *'Connection refused'*|*'No route to host'*|*'Connection timed out'*|\
    *'Operation timed out'*|*'Network is unreachable'*|\
    *'Name or service not known'*|*'Could not resolve hostname'*|\
    *'Temporary failure in name resolution'*)
      printf 'unreachable' ;;
    *)
      printf 'unknown' ;;
  esac
}

mkdir -p "$BACKUP_ROOT"

# --- don't let two runs overlap ---------------------------------------------
exec 9>"${BACKUP_ROOT}/.lock"
if ! flock -n 9; then
  log "another run holds the lock; exiting"
  exit 0
fi

# --- always bring the pods back, whatever happens ---------------------------
SCALED_DOWN=()
restore_scale() {
  local rc=$?
  for dep in "${SCALED_DOWN[@]:-}"; do
    [[ -z "$dep" ]] && continue
    log "scaling ${dep} back to 1"
    kubectl scale deploy/"$dep" -n "$NAMESPACE" --replicas=1 >/dev/null 2>&1 || \
      log "WARNING: failed to scale ${dep} back up — CHECK THIS"
  done
  for dep in "${SCALED_DOWN[@]:-}"; do
    [[ -z "$dep" ]] && continue
    kubectl rollout status deploy/"$dep" -n "$NAMESPACE" --timeout=180s >/dev/null 2>&1 || \
      log "WARNING: ${dep} did not become ready within 180s"
  done
  exit $rc
}
trap restore_scale EXIT INT TERM

# --- quiesce ----------------------------------------------------------------
for entry in "${VOLUMES[@]}"; do
  dep="${entry%%:*}"
  log "scaling ${dep} to 0"
  kubectl scale deploy/"$dep" -n "$NAMESPACE" --replicas=0 >/dev/null
  SCALED_DOWN+=("$dep")
done

# Wait for the pods to actually be gone, not merely for the scale call to
# return — the file handles are what matter.
for entry in "${VOLUMES[@]}"; do
  dep="${entry%%:*}"
  for _ in $(seq 1 60); do
    n="$(kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/name="$dep" \
           --no-headers 2>/dev/null | wc -l)"
    [[ "$n" -eq 0 ]] && break
    sleep 2
  done
  n="$(kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/name="$dep" --no-headers 2>/dev/null | wc -l)"
  if [[ "$n" -ne 0 ]]; then
    log "ERROR: ${dep} pods still present after 120s; aborting without archiving"
    exit 1
  fi
  log "${dep} quiesced"
done

# --- archive ----------------------------------------------------------------
created=()
for entry in "${VOLUMES[@]}"; do
  dep="${entry%%:*}"
  src="${entry#*:}"
  name="$(basename "$src")"
  out="${BACKUP_ROOT}/${name}-${STAMP}.tar.gz"

  log "archiving ${src} -> ${out}"
  tar -czf "$out" -C "$(dirname "$src")" "$name"

  # A tarball that cannot be listed is not a backup.
  if ! tar -tzf "$out" >/dev/null 2>&1; then
    log "ERROR: ${out} failed verification; removing it"
    rm -f "$out"
    exit 1
  fi
  [[ -s "$out" ]] || { log "ERROR: ${out} is empty"; rm -f "$out"; exit 1; }

  log "verified ${out} ($(du -h "$out" | cut -f1))"
  created+=("$out")
done

# Pods come back here via the EXIT trap, but bring them up now so the outage
# ends before the (slower) network copy rather than after it.
for dep in "${SCALED_DOWN[@]}"; do
  kubectl scale deploy/"$dep" -n "$NAMESPACE" --replicas=1 >/dev/null
done
SCALED_DOWN=()
log "pods scaled back up"

# --- ship off-host ----------------------------------------------------------
# The whole point of this script. A copy that stays on the same disk as the
# original protects against app-level corruption and fat-fingering, but not
# against the disk dying, which is the failure this is really guarding against.
# A failure to reach the remote is NOT all one thing, and the difference decides
# whether anyone ever finds out. "Host is down" is transient and self-healing —
# tonight's run misses, tomorrow's catches up. A rejected key or a changed host
# key is a permanent misconfiguration: every subsequent run fails the same way,
# and if that is a warning with exit 0, cron reports success forever while
# nothing ships. That is exactly how this went unnoticed for a day.
PUSH_FATAL=0
remote_addr="${REMOTE_HOST##*@}"

ssh_err=""
if ssh_err="$(ssh -o BatchMode=yes -o ConnectTimeout=10 "$REMOTE_HOST" \
                  "mkdir -p '${REMOTE_DIR}'" 2>&1 >/dev/null)"; then
  push_ok=1
else
  push_ok=0
fi

if [[ "$push_ok" -eq 1 ]]; then
  for f in "${created[@]}"; do
    if scp -q -o BatchMode=yes -o ConnectTimeout=10 "$f" "${REMOTE_HOST}:${REMOTE_DIR}/"; then
      log "shipped $(basename "$f") to ${REMOTE_HOST}:${REMOTE_DIR}/"
    else
      log "ERROR: failed to ship $(basename "$f") — local copy retained"
      PUSH_FATAL=1
    fi
  done
  if [[ "$PUSH_FATAL" -eq 1 ]]; then
    alert "Odysseus backup: off-host copy FAILED" "urgent" \
      "Archives were created and verified on watchtower, but one or more could not be copied to ${REMOTE_HOST}. Local copies retained. Off-host protection is NOT in place for this run."
  fi
  # Prune the remote to the same depth, per archive prefix.
  for entry in "${VOLUMES[@]}"; do
    name="$(basename "${entry#*:}")"
    ssh -o BatchMode=yes "$REMOTE_HOST" \
      "ls -1t '${REMOTE_DIR}/${name}'-*.tar.gz 2>/dev/null | tail -n +$((KEEP+1)) | xargs -r rm -f" \
      >/dev/null 2>&1 || log "WARNING: remote prune failed for ${name}"
  done
else
  if tcp_open "$remote_addr" "$REMOTE_PORT"; then
    # The port answered, so the host is up and this is not a connectivity
    # problem however ssh chose to word it.
    cause="$(classify_ssh_error "$ssh_err")"
    [[ "$cause" == "unreachable" ]] && cause="unknown"
  else
    cause="unreachable"
  fi

  case "$cause" in
    unreachable)
      # Transient and self-correcting; a warning is the right level.
      log "WARNING: ${remote_addr}:${REMOTE_PORT} is not answering — host down or off the network."
      log "         Archives are LOCAL ONLY this run; the next run should catch up."
      alert "Odysseus backup: off-host copy skipped" "default" \
        "${remote_addr}:${REMOTE_PORT} was unreachable, so tonight's archives stayed on watchtower only. Transient if the host is simply off; investigate if it repeats."
      ;;
    hostkey|auth|unknown)
      case "$cause" in
        hostkey) detail="the remote host key is unknown or has CHANGED (known_hosts mismatch)" ;;
        auth)    detail="SSH authentication was REJECTED (key not authorized, or wrong user)" ;;
        *)       detail="SSH failed for an unrecognised reason" ;;
      esac
      log "ERROR: off-host copy FAILED — ${detail}."
      log "       ${remote_addr}:${REMOTE_PORT} is open, so this is configuration, not connectivity."
      log "       ssh said: ${ssh_err//$'\n'/ | }"
      log "       This will NOT fix itself. Archives are LOCAL ONLY until it is resolved."
      alert "Odysseus backup: off-host copy BROKEN" "urgent" \
        "${detail}. Host ${remote_addr}:${REMOTE_PORT} is reachable, so this is a misconfiguration that will repeat every night until fixed. Archives are local-only. ssh said: ${ssh_err}"
      PUSH_FATAL=1
      ;;
  esac
fi

# --- prune local ------------------------------------------------------------
for entry in "${VOLUMES[@]}"; do
  name="$(basename "${entry#*:}")"
  # shellcheck disable=SC2012
  ls -1t "${BACKUP_ROOT}/${name}"-*.tar.gz 2>/dev/null | tail -n +$((KEEP+1)) | \
    while read -r old; do log "pruning $(basename "$old")"; rm -f "$old"; done
done

if [[ "$PUSH_FATAL" -eq 1 ]]; then
  log "backup FAILED: archives exist locally (${created[*]}) but are NOT off-host"
  exit 1
fi

log "backup complete: ${created[*]}"

# --- ALERTING ---------------------------------------------------------------
# Alerts publish to the same ntfy topic Uptime Kuma uses (watchtower-alerts).
# The topic is deny-all, so a token is required. Create a dedicated identity
# for backups rather than reusing kuma's, then store the token where this
# script looks for it:
#
#   kubectl -n monitoring exec deploy/ntfy -- ntfy user add --role=user backup
#   kubectl -n monitoring exec deploy/ntfy -- ntfy access backup watchtower-alerts rw
#   kubectl -n monitoring exec deploy/ntfy -- ntfy token add backup
#
#   mkdir -p ~/.config/ntfy
#   printf '%s' 'tk_...' > ~/.config/ntfy/backup-token
#   chmod 600 ~/.config/ntfy/backup-token
#
# Without the token the script still works and still fails loudly via its exit
# status — it just logs that the alert could not be sent. Alerting is additive,
# never a dependency.
#
# --- EXIT STATUS ------------------------------------------------------------
#   0  archives created, verified, and shipped off-host
#   0  archives created and verified, remote genuinely unreachable (transient)
#   1  archives created but the off-host copy is broken by misconfiguration
#      (rejected key, changed host key, failed scp) — needs a human
#   1  archiving itself failed
#
# Cron mails any output from a failing job, so a non-zero exit here is what
# actually reaches you if ntfy is not configured.
#
# --- INSTALL ----------------------------------------------------------------
# On watchtower, as brian (crond is active; no root needed):
#
#   crontab -l 2>/dev/null | grep -v backup-odysseus-volumes > /tmp/ct || true
#   echo '15 3 * * * /home/brian/homelab-k3s/scripts/backup-odysseus-volumes.sh' >> /tmp/ct
#   crontab /tmp/ct && rm /tmp/ct
#
# --- RESTORE ----------------------------------------------------------------
# Restoring either volume, from watchtower:
#
#   1. Get the archive. If it only exists off-host:
#        scp brian@192.168.1.245:backups/watchtower/odysseus/odysseus-<stamp>.tar.gz /tmp/
#
#   2. Stop the consumer so nothing writes underneath you:
#        kubectl scale deploy/odysseus -n odysseus --replicas=0     # or chromadb
#
#   3. Move the current directory aside rather than deleting it — if the
#      archive turns out to be bad you still have the original:
#        mv /mnt/appdata/odysseus /mnt/appdata/odysseus.broken-$(date +%s)
#
#   4. Unpack. The archive contains the directory itself, so extract into the
#      parent:
#        tar -xzf /tmp/odysseus-<stamp>.tar.gz -C /mnt/appdata
#
#   5. Ownership must end up 1000:1000 — the pods run as uid 1000 and fsGroup
#      does not chown hostPath volumes:
#        chown -R 1000:1000 /mnt/appdata/odysseus
#
#   6. Bring it back:
#        kubectl scale deploy/odysseus -n odysseus --replicas=1
#        kubectl rollout status deploy/odysseus -n odysseus
#
#   7. Only once the app is confirmed healthy, remove the .broken- directory.
#
# NOTE ON .app_key: it lives in /mnt/appdata/odysseus and encrypts every stored
# credential. Restoring app.db from one backup and .app_key from another leaves
# every credential undecryptable — always restore the whole odysseus directory
# from a single archive, never mix.
