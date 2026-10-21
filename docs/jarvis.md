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
| Host port | `:8080` on the Watchtower node |
| Ingress | `ai.watchtower.local`, `jarvis.watchtower.local` |
| Client env | `OPENAI_BASE_URL=http://127.0.0.1:8080/v1` (node) or `http://jarvis.jarvis.svc.cluster.local:8080/v1` (in-cluster) |

Former GPU owners `alpha-llama` and `gemma-llama` are retired. GGUF weights on
`/mnt/models` are **not** deleted; JARVIS mounts them read-only via
`jarvis-models`.

## Sleepy-warm demand policy

1. **One resident GGUF** — Deployment claims `nvidia.com/gpu: 1`. Router args
   `--models-preset` + `--models-max 1`. Clients name a preset id; JARVIS
   loads/swaps; the previous model unloads.
2. **Wake on demand** — Default `replicas: 0`. `./scripts/jarvis-up.sh` (or
   Alpha `Engine::Manager#up`) scales to 1 and waits on `/health`.
3. **Idle sleep** — CronJob `jarvis-idle-sleep` every 10 minutes: if no active
   lease and `last-activity-at` older than ~25 minutes, scale to 0.
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

Cutover notes: scale down any leftover `alpha-llama` / `gemma-llama` before
first wake so only JARVIS claims the GPU. Remove stale `alpha-models` /
`gemma-models` PV claimRefs from the cluster after JARVIS PVC is Bound (weights
on disk stay).

## Preset SoT

Edit `manifests/watchtower/jarvis/configmap.yaml` and re-apply. Do not treat
Alpha’s local `engine/models.ini` as production truth — it is a client-side
mirror / lab aid at most.
