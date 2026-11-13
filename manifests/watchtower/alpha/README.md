# Alpha campaign runner (Watchtower)

Client-side **benchmark Job** for [Alpha](https://github.com/bstruong/alpha). JARVIS
owns GPU inference (`../jarvis/`). This namespace does **not** run llama-server.

## UX

1. From Metrotower or Tohsaka: `scripts/alpha_watchtower_kick.sh` (Alpha repo; submit-only).
2. Power down the laptop — the Job keeps running here (Lease + heartbeat + cleanup).
3. Phone **ntfy** on topic `alpha-campaigns` (no email).
4. Later: review reports under `/mnt/appdata/alpha/artifacts/` on Watchtower.
5. Optional: `alpha_watchtower_pull.sh` only when promoting into alpha-lab git.

## Layout

| Path on node | Purpose |
|---|---|
| `/mnt/appdata/alpha/artifacts/` | results, qualifications, reports, logs |
| `/mnt/appdata/alpha/src/` | git worktrees for alpha / alpha-lab / homelab-k3s |

Pod runs as **uid/gid 1000**. After creating appdata: `chcon -Rt container_file_t /mnt/appdata/alpha`.
Optional bootstrap: place `.skip-git-sync` in a worktree to keep a host-seeded tree (skip GitHub fetch).

## Manifests

- `pvc.yaml` — hostPath PV+PVC
- `rbac.yaml` — SA `alpha-runner` + Role in `jarvis` (get Deployment, scale, Lease)
- `networkpolicy.yaml` — egress to DNS, Service CIDR API, node `:6443` apiserver (no LAN IP in git), JARVIS, ntfy, registry, HTTPS
- `configmap-entrypoint.yaml` — Job entrypoint (`jarvis-session` around campaign)
- `cronjob-campaign.yaml` — suspended CronJob template (`activeDeadlineSeconds`, userns)

## Apiserver reachability

k3s ClusterIP `kubernetes` (`10.43.0.1:443`) can intermittently refuse from alpha
pods. `./deploy.sh alpha` discovers the current `endpoints kubernetes` address/port
and patches `KUBERNETES_SERVICE_HOST` / `KUBERNETES_SERVICE_PORT` /
`KUBERNETES_SERVICE_PORT_HTTPS` onto CronJob `alpha-campaign` (live object only —
never committed). NetworkPolicy allows Service CIDR **and** TCP `6443` to
`0.0.0.0/0` so the node apiserver works without a hardcoded home-LAN IP.

Per-Job overrides (Alpha kick script) still win when set:

```bash
ALPHA_JOB_KUBERNETES_SERVICE_HOST=<apiserver-ip> \
ALPHA_JOB_KUBERNETES_SERVICE_PORT=6443 \
  ./scripts/alpha_watchtower_kick.sh
```

## Image

Build/push from the Alpha repo:

```bash
cd ~/Projects/alpha
./docker/alpha-runner/build-push.sh
```

Phase 5 pins (promotable graded Jobs):

```bash
./docker/alpha-runner/build-push.sh   # prints ALPHA_RUNNER_IMAGE=...@sha256:...
ALPHA_RUNNER_IMAGE=registry.watchtower.local/alpha-runner@sha256:... \
ALPHA_GIT_SHA=<40> ALPHA_LAB_GIT_SHA=<40> HOMELAB_GIT_SHA=<40> \
  ./scripts/alpha_watchtower_kick.sh
```

The CronJob template ships `alpha-runner:pin-me` as a non-runnable placeholder —
kick must rewrite the Job image to a digest. Moving `main` / `:latest` defaults
are removed. `ALPHA_ALLOW_MOVING_REFS=1` is diagnostics-only (not promotable).

Lifecycle contract: [docs/alpha-jarvis-session-contract.md](../../../docs/alpha-jarvis-session-contract.md).
