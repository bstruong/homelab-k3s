# Homelab K3s Infrastructure

Kubernetes manifests for a single-node k3s homelab, applied with plain
`kubectl` — no Helm charts of my own, no kustomize overlays. Each app is a
directory of small, readable YAML files.

**This repository is public and contains no credentials.** Secrets are
encrypted with [sealed-secrets](https://github.com/bitnami-labs/sealed-secrets)
before they are committed, and a pre-commit hook blocks plaintext ones. See
[docs/SECRETS.md](docs/SECRETS.md).

## Layout

```
manifests/
  common/                 namespaces, storage class
  watchtower/<app>/       one directory per app
  metrotower/             (empty — second node, not yet in use)
docs/SECRETS.md           every credential, how it is created, how to rotate it
scripts/secrets.sh        generate + seal (or apply) credentials
scripts/bootstrap-sealed-secrets.sh
scripts/install-hooks.sh  pre-commit guard against committing secrets
deploy.sh                 apply + validate
```

Each app directory follows the same shape:

| File | Contents |
| --- | --- |
| `deployment.yaml` / `statefulset.yaml` / `daemonset.yaml` | the workload |
| `service.yaml` | ClusterIP, or LoadBalancer where the LAN must reach it |
| `ingress.yaml` | Traefik `IngressRoute`, HTTP + HTTPS |
| `configmap.yaml` | non-secret configuration |
| `pvc.yaml` | the `PersistentVolume` **and** its `PersistentVolumeClaim` |
| `sealedsecret.yaml` | encrypted credentials (generated, then committed) |
| `rbac.yaml` | ServiceAccount and roles, where the app needs API access |

## First deploy

```sh
./scripts/install-hooks.sh                 # once per clone
./scripts/bootstrap-sealed-secrets.sh      # install the controller
./scripts/secrets.sh seal --show           # generate and seal credentials
./scripts/bootstrap-sealed-secrets.sh --backup-key
git add manifests/watchtower/*/sealedsecret.yaml && git commit

./deploy.sh --dry-run                      # server-side validation, no changes
./deploy.sh                                # apply, wait, validate
```

Then:

```sh
./deploy.sh jellyfin                       # one app
./deploy.sh --validate                     # report current state
./scripts/secrets.sh check                 # what exists, in repo and cluster
```

`deploy.sh` verifies the cluster is reachable, the node exists, the Traefik and
sealed-secrets CRDs are installed, and every required Secret has every required
key — *before* applying anything. Then it waits on each rollout and reports
pod, PVC, IngressRoute and warning-event state.

Read [docs/SECRETS.md](docs/SECRETS.md) first. Several apps (AdGuard Home,
Jellyfin, Home Assistant, Pocket ID, Uptime Kuma, Beszel) have first-run wizard
steps that no manifest can perform, and Beszel in particular has to be deployed
before its agent's credential can exist.

## Apps

| App | Namespace | Host | Notes |
| --- | --- | --- | --- |
| Traefik | `kube-system` | `traefik.watchtower.local` | k3s's bundled install, tuned via `HelmChartConfig`; dashboard behind BasicAuth |
| Tailscale | `kube-system` | — | Subnet router; the only workload that needs root for networking |
| AdGuard Home | `adguard` | `dns.watchtower.local` | DNS on :53 via a LoadBalancer Service |
| Pocket ID | `identity` | `id.watchtower.local` | Passkey-only OIDC provider; HTTPS-only |
| Vaultwarden | `identity` | `vault.watchtower.local` | Signups closed; HTTP redirects to HTTPS |
| CrowdSec | `monitoring` | — | Parses Traefik access logs; no web UI |
| Beszel | `monitoring` | `beszel.watchtower.local` | Hub Deployment + Agent DaemonSet |
| Uptime Kuma | `monitoring` | `status.watchtower.local` | `NET_RAW` for ICMP monitors |
| Jellyfin | `media` | `jellyfin.watchtower.local` | Direct Play only, transcoding off |
| Paperless-ngx | `docs` | `paperless.watchtower.local` | Worker concurrency pinned to 1; SQLite + Redis |
| AppFlowy | `docs` | `appflowy.watchtower.local` | appflowy-cloud + Postgres + GoTrue + Redis + MinIO |
| Syncthing | `sync` | `syncthing.watchtower.local` | Sync ports exposed to the LAN separately |
| PairDrop | `sync` | `drop.watchtower.local` | Stateless; HTTPS-only for WebRTC |
| Home Assistant | `home` | `home.watchtower.local` | Root required (s6-overlay) |
| Homepage | `home` | `watchtower.local` | The front door; read-only cluster RBAC |

Cockpit runs on the host, not in k3s, and is deliberately absent here.

## Conventions

**Storage.** Application state lives under `/mnt/appdata/<app>` on the
Watchtower node. Each app gets a statically defined `PersistentVolume`
(`hostPath`, `storageClassName: appdata`) bound one-to-one to its PVC through
`claimRef`, so a PVC can never bind to another app's data. Reclaim policy is
`Retain` — deleting a PVC never deletes data on disk. `deploy.sh` prints the
`mkdir`/`chown` commands the node needs, including the three apps whose
directories are not owned by uid 1000.

**Node pinning.** The volumes are host paths, so every workload carries
`nodeSelector: kubernetes.io/hostname: watchtower` and every PV a matching
`nodeAffinity`. If your node is named something else, change it in both places
and set `WATCHTOWER_NODE` for `deploy.sh`.

**Ingress.** One Traefik `IngressRoute` per app on `*.watchtower.local`, with
an HTTP route and an HTTPS route. HTTPS uses Traefik's default self-signed
certificate, which browsers warn about on a `.local` domain. Apps that require
a secure context — Pocket ID (passkeys), PairDrop (WebRTC), Vaultwarden — get a
redirect middleware instead of a plain HTTP route. Point the hostnames at the
Traefik LoadBalancer IP in AdGuard Home; `./deploy.sh --validate` prints the
exact entries.

Traefik is configured with `allowCrossNamespace: false`, so every route,
middleware and service reference in this repo is namespace-local.

**Security.** Everything runs unprivileged unless the app genuinely cannot:
`runAsNonRoot`, all capabilities dropped, `allowPrivilegeEscalation: false`,
`seccompProfile: RuntimeDefault`, a read-only root filesystem wherever the app
tolerates one, and `automountServiceAccountToken: false` on every pod that does
not call the API.

The exceptions, each documented at the top of its manifest:

| Workload | Deviation | Why |
| --- | --- | --- |
| AdGuard Home | adds `NET_BIND_SERVICE` | binding `:53` |
| Uptime Kuma | adds `NET_RAW` | ICMP ping monitors |
| Beszel agent | host `/proc`, `/sys`, `/etc` mounts | node metrics — still non-root and read-only, via gopsutil's `HOST_*` vars |
| Tailscale | root + `NET_ADMIN` + `/dev/net/tun` | creates a TUN device and programs host routes; userspace mode cannot route for other hosts |
| CrowdSec | root, read-only host log mounts | `/var/log/pods` is root-owned mode 0640, and reading it is the entire job |
| Home Assistant | root | s6-overlay has no supported non-root mode |
| Homepage | mounts a token | its widgets read workload status; the ClusterRole is read-only and lists no secrets |

**Resources.** Every container sets both requests and limits.

## Notes on specific apps

**Traefik** is k3s's bundled install. `helmchartconfig.yaml` layers values onto
it — do not apply a second Traefik deployment alongside it.

**Paperless-ngx** runs on SQLite with Redis as the Celery broker, the lightest
configuration that works at homelab document volumes.
`PAPERLESS_TASK_WORKERS`, `PAPERLESS_THREADS_PER_WORKER` and
`PAPERLESS_WEBSERVER_WORKERS` are all `1`, so OCR processes documents serially
and cannot saturate the node. Move to Postgres past a few thousand documents.

**Jellyfin** is Direct Play only. The `encoding.xml` ConfigMap is seeded by an
init container that never overwrites an existing file, so UI changes survive.
The per-user transcoding toggles live in Jellyfin's database and must be
cleared by hand — see docs/SECRETS.md. Its media library is mounted read-only
from `/mnt/media`, not `/mnt/appdata`; adjust that path in
`manifests/watchtower/jellyfin/pvc.yaml`.

**AppFlowy** needs more than a database: appflowy-cloud, GoTrue for auth, Redis
for pub/sub, and S3-compatible storage for attachments (MinIO here). Its images
are the one thing in this repo not version-pinned, because upstream ships
appflowy-cloud and GoTrue as a matched pair — pin both to the tags from the
`docker-compose.yml` of the release you intend to run.

**CrowdSec** detects but does not block on its own. To actually drop traffic,
register the Traefik bouncer plugin with the `bouncer-key` from its Secret.

**Home Assistant** does not use `hostNetwork`, so mDNS/DHCP/SSDP discovery will
not find devices. If you depend on those integrations, enable it — the manifest
says exactly what to change.

**Tailscale**'s advertised routes (`TS_ROUTES`) default to `192.168.1.0/24` plus
k3s's service CIDR. Set them to your actual LAN.
