# JARVIS — shared Watchtower inference

JARVIS is the single GPU-backed LLM inference engine on Watchtower. It lives
in this repo under `manifests/watchtower/jarvis/`. App repos (Alpha, Beta,
Assassin, Odysseus, Omega) are **clients** only.

| Layer | Value |
| --- | --- |
| Namespace | `jarvis` |
| Deployment | `jarvis` |
| ConfigMap (presets) | `jarvis-models` → `models.ini` (**source of truth**) |
| Service DNS | `jarvis.jarvis.svc.cluster.local:8080` |
| Host port | `127.0.0.1:8080` on the Watchtower node (loopback-only `hostPort`) |
| Ingress | `ai.watchtower.local`, `jarvis.watchtower.local` |
| Client env | `OPENAI_BASE_URL=http://127.0.0.1:8080/v1` (on Watchtower) · `http://ai.watchtower.local/v1` (LAN via Traefik) · `http://jarvis.jarvis.svc.cluster.local:8080/v1` (in-cluster) |

Former GPU owners `alpha-llama` and `gemma-llama` are retired. GGUF weights on
`/mnt/models` are **not** deleted; JARVIS mounts them read-only via
`jarvis-models`.

**Do not** point clients at `http://192.168.1.92:8080` — hostPort is
loopback-only and LAN 8080 is firewalled.

## Sleepy-warm demand policy

1. **One resident GGUF** — Deployment claims `nvidia.com/gpu: 1`. Router args
   `--models-preset` + `--models-max 1`. Clients name a preset id; JARVIS
   loads/swaps; the previous model unloads.
2. **Wake on demand** — Default `replicas: 0`. `./scripts/jarvis-up.sh` (or
   Alpha `Engine::Manager#up`) scales to 1 and waits on `/health`.
3. **Idle sleep** — CronJob `jarvis-idle-sleep` every 10 minutes: samples
   llama.cpp `/metrics` so real inference traffic refreshes
   `last-activity-at`; if no active lease and activity is older than ~25
   minutes, scale to 0.
4. **Leases** — Exclusive Alpha/Omega work:
   `./scripts/jarvis-lease.sh acquire <holder> [ttl-minutes]`. Blocks idle
   sleep. Release with `./scripts/jarvis-lease.sh release`.
5. **Same client path** — `health → (wake if down) → POST /v1/chat/completions`
   with `model: <preset>`.

### Assumptions for apps

| Assumption | Answer |
| --- | --- |
| JARVIS is always up | **No** — health-check / wake |
| My model id is always resident | **No** — router may swap unless you hold a lease |
| I need my own llama Deployment | **No** |
| I can run during Alpha’s leased eval | **No** — wait or fail loud |
| Overnight silence parks the GPU | **Yes** |

## Lease-aware clients

Exclusive GPU use is first-class. Prefer the shared script over inventing
per-app lease stores:

```sh
# From a machine with kubectl → Watchtower (or ssh watchtower)
./scripts/jarvis-lease.sh acquire omega-session 90
./scripts/jarvis-lease.sh touch          # refresh last-activity during long work
./scripts/jarvis-lease.sh release
./scripts/jarvis-lease.sh show
```

| Client | Wiring |
| --- | --- |
| **Alpha** | `Alpha::Engine::Manager#acquire_lease!` / `#release_lease!` / `#touch_activity!` (annotates `jarvis-lease`) |
| **Beta / Assassin** | HTTP to JARVIS (`OPENAI_BASE_URL` / `VAULT_INFERENCE_URL` / `BETA_INFERENCE_URL`). For exclusive jobs, shell out to `jarvis-lease.sh` on Watchtower or mirror Alpha’s annotate pattern |
| **Omega** | Long Pi sessions should `acquire` before heavy runs and `release` in an ensure/cleanup path |
| **Any** | Holding a non-expired lease blocks idle sleep entirely |

Activity warmth without a lease: chat traffic alone is enough — the idle
CronJob compares llama.cpp token/request metric counters and refreshes
`last-activity-at` when they grow.

## Security posture

Matches the Watchtower app baseline where possible (`seccomp` RuntimeDefault,
capabilities dropped except `IPC_LOCK`, `allowPrivilegeEscalation: false`,
`enableServiceLinks: false`, Traefik-scoped NetworkPolicy). Documented
deviations: root + `IPC_LOCK` for mlock, privileged PSA on the `jarvis`
namespace, writable rootfs for CUDA, and loopback `hostPort` 8080. See the
security exceptions table in [README.md](../README.md).

### Optional non-root CUDA

**Not enabled.** Upstream `ghcr.io/ggml-org/llama.cpp:server-cuda` (pinned
digest) defaults to uid 0; `load-mode=mlock` needs `IPC_LOCK`, and CUDA
scratch expects a writable root. Peer Watchtower apps drop to non-root after
a root initContainer, but that pattern is unvalidated for this digest’s GPU
device nodes. Leave `runAsUser: 0` until a verified non-root CUDA entrypoint
exists; do not flip the uid in a drive-by change.

## Scripts

```sh
./scripts/jarvis-up.sh
./scripts/jarvis-status.sh
./scripts/jarvis-lease.sh acquire alpha-eval 45
./scripts/jarvis-lease.sh release
./scripts/jarvis-down.sh          # refuses if lease held; --force overrides
```

## Deploy

```sh
./deploy.sh jarvis
./deploy.sh --dry-run jarvis   # server-side validate
```

Cutover leftovers (`alpha-llama` Deployment, stale `alpha-models` /
`gemma-models` PV claimRefs) should already be gone from the cluster.
`deploy.sh` skips the README-only `alpha/` tree and will not recreate them.
GGUF weights under `/mnt/models` stay.

## Preset SoT

Edit `manifests/watchtower/jarvis/configmap.yaml` and re-apply. Do not treat
Alpha’s local `engine/models.ini` as production truth — it is a client-side
mirror / lab aid at most.
