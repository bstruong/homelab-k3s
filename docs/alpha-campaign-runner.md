# Alpha campaign runner on Watchtower

Long Alpha benchmarks run as a **k8s Job** in namespace `alpha`, talking to
**JARVIS** over ClusterIP. Laptops (Metrotower / Tohsaka) only kick, notify,
and review — they must not host the graded runner, Lease, or heartbeat.

## Phone notify (no email)

ntfy is **deny-all**; topic `alpha-campaigns` uses user `alpha` + a Bearer token
(secret `alpha/alpha-ntfy`, minted on the ntfy pod).

1. Install **ntfy** by **Philipp Heckel** from the App Store.
2. Default server: `http://ntfy.watchtower.local` (LAN or Tailscale).
   Use **http**, not https — the iOS app often rejects the private Homelab CA
   even when the root is installed/trusted. Jobs still notify over ClusterIP HTTP.
3. Subscribe to topic **`alpha-campaigns`**. On iOS, authenticate with Vaultwarden
   username/password (`alpha` / user password) — the app has no Bearer-token field.
   Campaign Jobs still publish with the token in secret `alpha/alpha-ntfy`.

## Operator flow

```bash
# From Metrotower or Tohsaka (Alpha checkout) — submission only after Alpha cutover
./scripts/alpha_watchtower_kick.sh                 # default ALPHA_CAMPAIGN_FROM=ruby
# Power off — Job continues on Watchtower (Lease + heartbeat + cleanup are in-cluster)

./scripts/alpha_watchtower_status.sh               # anytime
./scripts/alpha_watchtower_review.sh               # CAPABILITY_MAP_LIVE on disk
./scripts/alpha_watchtower_review.sh log           # latest campaign log

# Only when promoting into alpha-lab git:
./scripts/alpha_watchtower_pull.sh
```

Lifecycle contract for the Alpha PR:
[alpha-jarvis-session-contract.md](alpha-jarvis-session-contract.md).

## Cluster ownership

| Concern | Owner |
| --- | --- |
| Job accept + run ID | Watchtower Job / kick submit |
| Lease `jarvis-gpu` acquire/renew/release | Job via `jarvis-session.sh` |
| Scale JARVIS 0↔1 | Job session begin/end |
| `activeDeadlineSeconds` / termination grace | `cronjob-campaign.yaml` |
| Stale Lease / idle reclaim | `jarvis-idle-sleep` safety reconciler |
| Bubblewrap userns (Phase 2) | Campaign pod seccomp/AppArmor Unconfined |

## Deploy (homelab-k3s)

```bash
# After any in-flight local bench finishes:
cd ~/Projects/homelab-k3s
mkdir -p /mnt/appdata/alpha/{artifacts,src}   # on watchtower node (btruong-owned appdata)
./deploy.sh alpha

# SELinux: hostPath starts as mnt_t; containers need container_file_t
ssh watchtower 'chcon -Rt container_file_t /mnt/appdata/alpha'

cd ~/Projects/alpha
./docker/alpha-runner/build-push.sh
```

CronJob runs as uid/gid **1000** (matches appdata owner) with
`imagePullSecrets: registry-pull`.
If the registry htpasswd was rotated, also refresh
`/etc/rancher/k3s/registries.yaml` (sudo + `systemctl restart k3s`) so *other*
node pulls keep working; alpha Jobs use the pull secret.

Artifacts live at `/mnt/appdata/alpha/artifacts/{reports,results,qualifications,logs}`.

Until Alpha `main` on GitHub has the campaign scripts, seed worktrees and leave
`.skip-git-sync` markers under `/mnt/appdata/alpha/src/{alpha,alpha-lab,homelab-k3s}/`.
