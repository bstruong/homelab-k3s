# JARVIS — shared Watchtower inference

JARVIS is the single GPU-backed LLM inference engine on Watchtower. It lives
in this repo under `manifests/watchtower/jarvis/`. App repos (Alpha, Beta,
Assassin, Odysseus, Omega) are **clients** only.

| Layer | Value |
| --- | --- |
| Namespace | `jarvis` |
| Deployment | `jarvis` |
| ConfigMap (presets) | `jarvis-models` → `models.ini` (**source of truth**) |
| Lease (exclusive GPU) | `coordination.k8s.io/v1` `jarvis-gpu` (deploy create-if-absent) |
| Service DNS | `jarvis.jarvis.svc.cluster.local:8080` |
| Host port | `127.0.0.1:8080` on the Watchtower node (loopback-only `hostPort`) |
| Ingress | `ai.watchtower.local`, `jarvis.watchtower.local` |
| Client env | `OPENAI_BASE_URL=http://127.0.0.1:8080/v1` (on Watchtower) · `http://ai.watchtower.local/v1` (LAN via Traefik) · `http://jarvis.jarvis.svc.cluster.local:8080/v1` (in-cluster) |

Former GPU owners `alpha-llama` and `gemma-llama` are retired. GGUF weights on
`/mnt/models` are **not** deleted; JARVIS mounts them read-only via
`jarvis-models`.

**Do not** point clients at `http://192.0.2.10:8080` — hostPort is
loopback-only and LAN 8080 is firewalled.

## Sleepy-warm demand policy

1. **One resident GGUF** — Deployment claims `nvidia.com/gpu: 1`. Router args
   `--models-preset` + `--models-max 1`. Clients name a preset id; JARVIS
   loads/swaps; the previous model unloads.
2. **Wake on demand** — Default `replicas: 0`. Prefer
   `./scripts/jarvis-session.sh begin …` (acquire + scale 1 + `/health`).
   `./scripts/jarvis-up.sh` remains a thin wake helper.
3. **Safety reconciler** — CronJob `jarvis-idle-sleep` every 10 minutes runs
   `jarvis-reconcile-idle.sh`: refresh activity from llama.cpp `/metrics`,
   expire stale Lease holders, and scale to 0 only when idle past ~60 minutes
   with no live holder. Unreachable metrics **never** force scale-down.
4. **Leases** — Exclusive long eval / agent work uses native Lease
   `jarvis-gpu` (holder, run ID, renew time, duration). CAS acquire prevents
   two live holders.
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
| Graded Alpha suites keep JARVIS up from a laptop | **No** — Watchtower Job owns the session |

## Session interface (preferred)

```sh
./scripts/jarvis-session.sh begin alpha-eval 45 my-run-id
./scripts/jarvis-session.sh heartbeat
./scripts/jarvis-session.sh end
./scripts/jarvis-session.sh status
```

Alpha campaign Jobs call this once around the suite (see
[alpha-jarvis-session-contract.md](alpha-jarvis-session-contract.md)).
Operators may still use the thin wrappers:

```sh
./scripts/jarvis-lease.sh acquire omega-session 90
./scripts/jarvis-lease.sh touch
./scripts/jarvis-lease.sh release
./scripts/jarvis-up.sh
./scripts/jarvis-down.sh          # refuses if lease held; --force overrides
./scripts/jarvis-status.sh
```

| Client | Wiring |
| --- | --- |
| **Alpha (graded)** | Watchtower Job entrypoint → `jarvis-session.sh`; laptop kick is submit-only |
| **Beta / Assassin** | HTTP to JARVIS. For exclusive jobs, shell out to `jarvis-session.sh` |
| **Omega / Pi** | Long sessions should `begin` before heavy runs and `end` in cleanup |
| **Any** | A live Lease holder blocks idle reclaim |

Activity warmth without a lease: chat traffic alone is enough — the reconciler
compares llama.cpp token/request metric counters and refreshes
`last-activity-at` when they grow.

### Cutover note

ConfigMap `jarvis-lease` is dual-read/mirrored only until Alpha cutover
validates. Do not add new ConfigMap lease writers.

## Security posture

Matches the Watchtower app baseline where possible (`seccomp` RuntimeDefault,
capabilities dropped except `IPC_LOCK`, `allowPrivilegeEscalation: false`,
`enableServiceLinks: false`, Traefik-scoped NetworkPolicy). Documented
deviations: root + `IPC_LOCK` for mlock, privileged PSA on the `jarvis`
namespace, writable rootfs for CUDA, and loopback `hostPort` 8080. See the
security exceptions table in [README.md](../README.md).

Alpha campaign pods intentionally use `seccompProfile: Unconfined` and
`appArmorProfile: Unconfined` so Phase 2 bubblewrap can create unprivileged
user namespaces. JARVIS itself stays on RuntimeDefault.

### Optional non-root CUDA

**Not enabled.** Upstream `ghcr.io/ggml-org/llama.cpp:server-cuda` (pinned
digest) defaults to uid 0; `load-mode=mlock` needs `IPC_LOCK`, and CUDA
scratch expects a writable root. Peer Watchtower apps drop to non-root after
a root initContainer, but that pattern is unvalidated for this digest’s GPU
device nodes. Leave `runAsUser: 0` until a verified non-root CUDA entrypoint
exists; do not flip the uid in a drive-by change.

## Deploy

```sh
./deploy.sh jarvis
./deploy.sh --dry-run jarvis   # server-side validate
```

Cutover leftovers (`alpha-llama` Deployment, stale `alpha-models` /
`gemma-models` PV claimRefs) should already be gone from the cluster.
GGUF weights under `/mnt/models` stay.

## Preset SoT

Edit `manifests/watchtower/jarvis/configmap.yaml` and re-apply. Do not treat
Alpha’s local `engine/models.ini` as production truth — it is a client-side
mirror / lab aid at most.
