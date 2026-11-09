# Alpha campaign runner (Watchtower)

Client-side **benchmark Job** for [Alpha](https://github.com/bstruong/alpha). JARVIS
owns GPU inference (`../jarvis/`). This namespace does **not** run llama-server.

## UX

1. From Metrotower or Tohsaka: `scripts/alpha_watchtower_kick.sh` (in the Alpha repo).
2. Power down the laptop — the Job keeps running here.
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
- `rbac.yaml` — SA `alpha-runner` + Role in `jarvis` (scale + lease)
- `networkpolicy.yaml` — egress to DNS, JARVIS, ntfy, registry, HTTPS
- `configmap-entrypoint.yaml` — Job entrypoint
- `cronjob-campaign.yaml` — suspended CronJob used as `kubectl create job --from=…` template

## Image

Build/push from the Alpha repo:

```bash
cd ~/Projects/alpha
./docker/alpha-runner/build-push.sh
```

Default image: `registry.watchtower.local/alpha-runner:latest`
