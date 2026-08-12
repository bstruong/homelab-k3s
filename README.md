# Homelab K3s Infrastructure

Kubernetes manifests for the homelab, applied with plain `kubectl` — no Helm,
no kustomize overlays. Each app is a directory of small, readable YAML files.

## Layout

```
manifests/
  common/                 namespaces, storage class
  watchtower/<app>/       one directory per app
  metrotower/             (empty — second node, not yet in use)
docs/SECRETS.md           every credential and how to create it
scripts/create-secrets.sh generates the Secrets
deploy.sh                 apply + validate
```

Each app directory follows the same shape:

| File | Contents |
| --- | --- |
| `deployment.yaml` / `statefulset.yaml` / `daemonset.yaml` | the workload |
| `service.yaml` | ClusterIP (or LoadBalancer for DNS) |
| `ingress.yaml` | Traefik `IngressRoute`, HTTP + HTTPS |
| `configmap.yaml` | non-secret configuration |
| `pvc.yaml` | the `PersistentVolume` **and** its `PersistentVolumeClaim` |

## Conventions

**Storage.** Application state lives under `/mnt/appdata/<app>` on the
Watchtower node. Each app gets a statically defined `PersistentVolume`
(`hostPath`, `storageClassName: appdata`) bound one-to-one to its PVC through
`claimRef`, so a PVC can never bind to another app's data. Reclaim policy is
`Retain` — deleting a PVC never deletes data on disk.

**Node pinning.** The volumes are host paths, so every workload carries
`nodeSelector: kubernetes.io/hostname: watchtower` and every PV a matching
`nodeAffinity`. If your node is named something else, change it in both places
(and set `WATCHTOWER_NODE` for `deploy.sh`).

**Ingress.** Traefik `IngressRoute` per app, on `*.watchtower.local`. Each app
gets an HTTP route and an HTTPS route; HTTPS uses Traefik's default
self-signed certificate, which browsers will warn about on a `.local` domain.
Point the hostnames at the Traefik LoadBalancer IP in your DNS (AdGuard Home
can do this once it is up) — `./deploy.sh --validate` prints the exact entries.

**Security.** Everything runs unprivileged: `runAsNonRoot`, all capabilities
dropped, `allowPrivilegeEscalation: false`, `seccompProfile: RuntimeDefault`,
and a read-only root filesystem wherever the app tolerates one. Two documented
exceptions:

* AdGuard Home adds back `NET_BIND_SERVICE` — nothing else — so it can bind
  `:53`.
* Beszel's agent reads host metrics, but does so through read-only `/proc`,
  `/sys` and `/etc` mounts plus gopsutil's `HOST_*` variables, which avoids
  needing host namespaces or root.

**Resources.** Every container sets both requests and limits.

## Deploying

```sh
./scripts/create-secrets.sh --show   # once, before the first deploy
./deploy.sh --dry-run                # server-side validation, changes nothing
./deploy.sh                          # apply everything, wait, validate
./deploy.sh jellyfin                 # just one app
./deploy.sh --validate               # report current state
```

`deploy.sh` checks that the cluster is reachable, the node exists, the Traefik
CRDs are installed, and every required Secret is present *before* it applies
anything, then waits on each rollout and reports pod, PVC, IngressRoute and
warning-event state.

Read `docs/SECRETS.md` first — a few apps (AdGuard Home, Jellyfin, Beszel) have
first-run wizard steps that no manifest can perform.

## Apps

| App | Namespace | Host | Notes |
| --- | --- | --- | --- |
| AdGuard Home | `adguard` | `dns.watchtower.local` | DNS on :53 via a LoadBalancer Service |
| Vaultwarden | `identity` | `vault.watchtower.local` | HTTP redirects to HTTPS; signups closed |
| Beszel | `monitoring` | `beszel.watchtower.local` | Hub Deployment + Agent DaemonSet |
| Jellyfin | `media` | `jellyfin.watchtower.local` | Direct Play only, transcoding off |
| Paperless-ngx | `docs` | `paperless.watchtower.local` | Worker concurrency pinned to 1; SQLite + Redis |
| AppFlowy | `docs` | `appflowy.watchtower.local` | appflowy-cloud + Postgres + GoTrue + Redis + MinIO |

Namespaces `sync` and `home` are created but not yet populated.

### Notes on specific apps

**Paperless-ngx** runs on SQLite with Redis as the Celery broker — the
lightest configuration that works, appropriate at homelab document volumes.
`PAPERLESS_TASK_WORKERS`, `PAPERLESS_THREADS_PER_WORKER` and
`PAPERLESS_WEBSERVER_WORKERS` are all `1`, so OCR processes documents serially
and cannot saturate the node. Move to Postgres if the library grows past a few
thousand documents.

**Jellyfin** is Direct Play only. The `encoding.xml` ConfigMap is seeded on
first start by an init container (and never overwrites an existing file, so UI
changes survive). The per-user transcoding toggles are stored in Jellyfin's
database and must be cleared by hand — see `docs/SECRETS.md`.

**AppFlowy** needs more than a database: appflowy-cloud, GoTrue for auth, Redis
for pub/sub, and S3-compatible storage for attachments (MinIO here). The
AppFlowy images are not version-pinned in this repo because upstream ships
appflowy-cloud and GoTrue as a matched pair — pin both to the tags from the
`docker-compose.yml` of the release you intend to run.

**Jellyfin's media library** is mounted read-only from `/mnt/media`, not
`/mnt/appdata` — appdata is for application state. Adjust that path in
`manifests/watchtower/jellyfin/pvc.yaml` to wherever the library actually is.
