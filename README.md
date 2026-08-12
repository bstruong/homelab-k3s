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

`deploy.sh` verifies the cluster is reachable, the node exists, and the Traefik
and sealed-secrets CRDs are installed — *before* applying anything. Then it
waits on each rollout and reports pod, PVC, IngressRoute and warning-event
state.

No credential blocks a deploy any more: every remaining one is optional, so a
missing one warns and the rest of the stack still goes out. (Tailscale's auth
key used to be the sole exception, and it left with Tailscale.) That is a
convenience, not self-healing — those pods stay in
`CreateContainerConfigError` until the Secret exists, and the warning says so
per app. See [docs/SECRETS.md](docs/SECRETS.md#required-vs-optional).

Read [docs/SECRETS.md](docs/SECRETS.md) first. Several apps (AdGuard Home,
Jellyfin, Home Assistant, Pocket ID, Uptime Kuma, Beszel) have first-run wizard
steps that no manifest can perform, and Beszel in particular has to be deployed
before its agent's credential can exist.

## Apps

| App | Namespace | Host | Notes |
| --- | --- | --- | --- |
| Traefik | `kube-system` | `traefik.watchtower.local` | k3s's bundled install, tuned via `HelmChartConfig`; dashboard behind BasicAuth |
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
`mkdir`/`chown` commands the node needs, including the four directories not
owned by uid 1000: AdGuard Home, CrowdSec and Home Assistant are `0:0`, and
AppFlowy's Postgres is `999:999`.

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
| AdGuard Home | root + `NET_BIND_SERVICE` | its first-launch check is a bare `os.Getuid() == 0` test, which no capability can satisfy |
| Uptime Kuma | starts as root, adds `CHOWN`, `SETUID`, `SETGID`, `NET_RAW` | its entrypoint chowns the data volume and then drops to uid 1000 via `setpriv`; the app process itself is unprivileged |
| Beszel agent | host `/proc`, `/sys`, `/etc` mounts | node metrics — still non-root and read-only, via gopsutil's `HOST_*` vars |
| CrowdSec | root, read-only host log mounts | `/var/log/pods` is root-owned mode 0640, and reading it is the entire job |
| Home Assistant | root | s6-overlay has no supported non-root mode |
| Homepage | mounts a token | its widgets read workload status; the ClusterRole is read-only and lists no secrets |

**Host volume ownership.** `fsGroup` does not fix ownership on `hostPath`
volumes — kubelet's recursive ownership pass skips them, so a directory created
by `DirectoryOrCreate` stays `root:root` and every non-root app fails to write
to it. The fix is the `chown` step that `deploy.sh` prints for the node; run it
before the first deploy, and run *all* of it — the root-owned directories at the
end are not optional.

Note that "runs as root" does not mean "can write anywhere." Every container
here drops `ALL` capabilities, so none has `CAP_DAC_OVERRIDE`, and a uid 0
process without it gets no permission bypass: against a 1000-owned `0755`
directory it can read and traverse but not create. AdGuard Home, CrowdSec and
Home Assistant all run as uid 0 and therefore need their data directories owned
by `0:0`, not `1000:1000`.

Uptime Kuma is the inverse case: it starts as root and drops to uid 1000 in its
own entrypoint, so its directory stays `1000:1000` and it needs `CHOWN`,
`SETUID` and `SETGID` to make the transition.

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

**Tailscale is deliberately not in this stack.** It was removed, and re-adding
it as a workload will not work. Watchtower already runs `tailscaled` as a host
systemd service, joined to a self-hosted Headscale instance, and a Tailscale
pod wants the same thing the host process already holds: exclusive use of the
`tailscale0` TUN interface. The pod loses that race every time and crash-loops
indefinitely on

```
wgengine.NewUserspaceEngine(tun "tailscale0") error: tstun.New("tailscale0"): device or resource busy
```

This is not fixable from inside Kubernetes. `TS_USERSPACE=true` avoids the TUN
conflict but cannot route for other hosts, which is the entire point of a subnet
router, and two tailscaled instances on one machine cannot share the interface
whatever their configuration. If you want the cluster's service CIDR advertised
to the tailnet, advertise it from the **host** daemon instead:

```sh
sudo tailscale up --advertise-routes=192.168.1.0/24,10.43.0.0/16
```

That gets the same reachability with one daemon, one machine identity in
Headscale, and no interface contention.
