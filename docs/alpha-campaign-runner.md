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
# Phase 5: digest + commit SHAs required for promotable graded Jobs
./docker/alpha-runner/build-push.sh                # prints ALPHA_RUNNER_IMAGE=...@sha256:...
ALPHA_RUNNER_IMAGE=registry.watchtower.local/alpha-runner@sha256:... \
ALPHA_GIT_SHA=<40hex> ALPHA_LAB_GIT_SHA=<40hex> HOMELAB_GIT_SHA=<40hex> \
  ./scripts/alpha_watchtower_kick.sh               # default ALPHA_CAMPAIGN_FROM=ruby
# Power off — Job continues on Watchtower (Lease + heartbeat + cleanup are in-cluster)

./scripts/alpha_watchtower_status.sh               # anytime
./scripts/alpha_watchtower_review.sh               # CAPABILITY_MAP_LIVE on disk
./scripts/alpha_watchtower_review.sh log           # latest campaign log

# Only when promoting into alpha-lab git (sanitized bundle; raw results/ stays ignored):
./scripts/alpha_watchtower_pull.sh
```

### Runner image digest hygiene

`ALPHA_RUNNER_IMAGE` **must** be pinned to the **registry content digest**
(`Docker-Content-Digest` / `registry.watchtower.local/alpha-runner@sha256:…`).

Do **not** use a local `podman`/`docker` `RepoDigests` value from
`image inspect` — that digest is often a local index/manifest id and can differ
from what the registry serves, which produces `ErrImagePull` on the Job while
the pin looks “correct” on the laptop.

Prefer, after push:

```bash
# Registry SoT (skopeo / crane / buildx imagetools — not local RepoDigests)
skopeo inspect --raw docker://registry.watchtower.local/alpha-runner:<tag> \
  | …   # or: docker buildx imagetools inspect … | awk '/Digest:/'
# Then:
export ALPHA_RUNNER_IMAGE=registry.watchtower.local/alpha-runner@sha256:<64hex>
```

Confirm the digest by pulling that `@sha256:…` reference on Watchtower (or via
registry API) before a graded kick. `build-push.sh` should print a registry
digest; if it falls back to local `RepoDigests`, re-resolve from the registry.

### Hollow-campaign guard

For `ALPHA_CAMPAIGN_FROM=ruby` (default Watchtower suite; also `all` /
`coding` / `frontend` / `hotwire`), the Job entrypoint **exits non-zero** after
pin sync if required scenario dirs are missing under the Alpha worktree
(`scenarios/ruby-coding`, `frontend-coding`, `hotwire-coding`, and shared
`web-rails`). Missing trees used to Complete OK / skip-all — fail closed
instead. Fix the Alpha pin (or clear `.skip-git-sync` so PVC matches) before
re-kicking.

Entrypoint writes `results/infra_provenance.json` (runner/JARVIS digests, lease
identity, resolved SHAs) for Alpha `run_manifest.json` / report provenance.

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

`./deploy.sh alpha` discovers `kubectl get endpoints kubernetes` and patches the
CronJob template with `KUBERNETES_SERVICE_HOST` / `PORT` / `PORT_HTTPS` so Jobs
talk to the node kube-apiserver when ClusterIP flakes. No home-LAN IP is
committed; NetworkPolicy allows Service CIDR plus TCP `6443` anywhere.

Optional kick overrides (bake into the Job without changing the CronJob):

```bash
ALPHA_JOB_KUBERNETES_SERVICE_HOST=<apiserver-ip> \
ALPHA_JOB_KUBERNETES_SERVICE_PORT=6443 \
  ./scripts/alpha_watchtower_kick.sh
```

`./deploy.sh jarvis` applies `lease/jarvis-gpu` **create-if-absent** only — an
existing Lease (empty or held) is left alone so redeploys do not strip
`resourceVersion` or reset holder state.

CronJob runs as uid/gid **1000** (matches appdata owner) with
`imagePullSecrets: registry-pull`.
If the registry htpasswd was rotated, also refresh
`/etc/rancher/k3s/registries.yaml` (sudo + `systemctl restart k3s`) so *other*
node pulls keep working; alpha Jobs use the pull secret.

Artifacts live at `/mnt/appdata/alpha/artifacts/{reports,results,qualifications,logs}`.

Until Alpha `main` on GitHub has the campaign scripts, seed worktrees and leave
`.skip-git-sync` markers under `/mnt/appdata/alpha/src/{alpha,alpha-lab,homelab-k3s}/`.
