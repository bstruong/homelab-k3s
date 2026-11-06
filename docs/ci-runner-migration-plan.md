# Watchtower CI Migration Plan: Self-Hosted GitHub Runners on Ryzen 7 9700X

> [!IMPORTANT]
> **Objective:** Eliminate GitHub Actions minute limits permanently by migrating resource-intensive workflows (especially Sapphire's nightly mutation testing, which accounted for ~91% of monthly usage) to the **Watchtower** k3s cluster.
> 
> * **Cloud Quota Used:** 1,800 / 2,000 minutes (90%)
> * **Self-Hosted Cost:** **$0.00 / 0 minutes** consumed on GitHub's quota
> * **Hardware Target:** AMD Ryzen 7 9700X (8c/16t Zen 5 @ 5.58 GHz), Samsung 990 Pro NVMe, 24 GB available DDR5 RAM

---

## 1. Executive Summary & Root Cause Analysis

### The Bottleneck
A review of repository billing telemetry shows that **`sapphire`** consumed **$49.23 out of $54.12 (~91%)** of the entire account's compute allowance. 

The primary consumer was `.github/workflows/mutation-nightly.yml`, which executes `mutmut` mutation testing on a daily `0 8 * * *` schedule across a Postgres service container.

```mermaid
pie title Oct 2026 Actions Compute Breakdown
    "Sapphire (Mutation & CI)" : 91
    "Odysseus (Docker & Scans)" : 5
    "Omega (Rails CI)" : 1.6
    "Homelab-K3s (Lint)" : 1.2
    "Carnelian (Rails CI)" : 1.1
```

### The Performance Multiplier
GitHub's hosted `ubuntu-latest` runner provides only **2 shared vCPUs and 7 GB RAM** with throttled cloud disk I/O. 

Running these jobs on Watchtower's Ryzen 7 9700X unlocks:
* **4x–6x Parallel Throughput:** Up to 12–16 Zen 5 threads dedicated during compile and mutation passes.
* **NVMe Caching:** Persistent host-path caching for Python `uv`, Ruby `bundler`, and Docker layer caches.
* **Unlimited Minutes:** Zero impact on GitHub's 2,000-minute free tier.

---

## 2. Target Architecture Options

```mermaid
flowchart TD
    subgraph GitHub["GitHub Cloud (bstruong)"]
        Event["Push / PR / Schedule Event"] --> Orchestrator["GitHub Actions Queue"]
    end

    subgraph Watchtower["Watchtower Node (Ryzen 7 9700X / Fedora 44)"]
        Orchestrator -->|"Outbound Long-Poll (HTTPS 443)<br>Zero Inbound Ports Needed"| RunnerPod["k3s Runner Pod<br>(namespace: infra)"]
        
        subgraph Compute["Execution Environment"]
            RunnerPod -->|"CPU Burst (up to 12 cores)"| Job["Test / Mutation / Build"]
            Job -->|"Local NVMe Cache"| SSD[("/mnt/cache/ci/uv-bundler")]
            Job -->|"Local Test DB"| ServiceContainer["Postgres 15<br>(RAM tmpfs)"]
        end
        
        JARVIS["JARVIS (RTX 3060)"] -.->|"Sleepy-Warm (Unbothered)"| GPU[("RTX 3060 GPU")]
    end
```

### Comparison of Deployment Models

| Feature | Option 1: K3s Pod Runner (Recommended) | Option 2: Actions Runner Controller (ARC) | Option 3: Host Systemd Service |
| :--- | :--- | :--- | :--- |
| **Description** | Declarative Kubernetes Deployment in `manifests/watchtower/github-runner/` | Official GitHub Kubernetes operator scaling ephemeral runner pods | Direct background daemon on the Fedora host |
| **Simplicity** | High (plain deployment + sealed secret) | Moderate (Helm chart, CRDs, webhook) | High (single shell script) |
| **Isolation** | Containerized within k3s network policies | Fresh ephemeral pod per job | Shared host filesystem |
| **Resource Control** | Governed by Kubernetes requests/limits & CFS | Dynamic pod auto-scaling | Linux cgroups / nice |
| **Recommended For** | **Immediate deployment & steady-state CI** | Enterprise-scale fleet scaling | Bare-metal Docker-in-Docker needs |

---

## 3. Step-by-Step Implementation Blueprint

### Phase 1: Immediate Mitigation (Completed)
- [x] **Scheduled Cron Disabled:** Merged PR [#59 in `sapphire`](https://github.com/bstruong/sapphire/pull/59) to disable the `0 8 * * *` schedule and push triggers in `mutation-nightly.yml`.
- [ ] **Spending Limit Hard Stop:** Verify GitHub spending limit is set to **$0** in [GitHub Billing Settings](https://github.com/settings/billing).

---

### Phase 2: Deploy Self-Hosted Runner on Watchtower K3s

> **Status (Option 1 manifests):** Shipped under
> [`manifests/watchtower/github-runner/`](../manifests/watchtower/github-runner/).
> Owner must still seal a **real** registration token and apply on Watchtower.
> Agents must not invent tokens. Full seal/apply + DinD notes:
> [`manifests/watchtower/github-runner/README.md`](../manifests/watchtower/github-runner/README.md).

#### Step 1: Generate Registration Token
1. Go to **Repository Settings** (or Account Settings for all repos) -> **Actions** -> **Runners** -> **New self-hosted runner**.
2. Copy the token provided under the registration command (expires ~1h).

#### Step 2: Seal Runner Secrets
Using the homelab secret workflow (`seal-generic` writes SealedSecret YAML to stdout):
```bash
# In homelab-k3s workspace — paste the REAL token; do not invent one
./scripts/secrets.sh seal-generic github-runner-token infra \
  token="<GITHUB_RUNNER_REGISTRATION_TOKEN>" \
  > manifests/watchtower/github-runner/sealedsecret.yaml

git add manifests/watchtower/github-runner/sealedsecret.yaml
git commit -m "chore(github-runner): seal registration token"
```

#### Step 3: Manifests (`manifests/watchtower/github-runner/`)

Committed files (vs the sketch below):

| File | Role |
| --- | --- |
| `deployment.yaml` | Option-1 Deployment (`myoung34/github-runner:ubuntu-noble`) |
| `README.md` | Seal/apply runbook + Postgres/DinD spike |

Deviations from the early sketch (intentional):

* Env is **`LABELS`**, not `RUNNER_LABELS` (upstream image contract).
* Labels use `app.kubernetes.io/name`.
* **`START_DOCKER_SERVICE=true` + `privileged`** so Sapphire mutation Postgres
  *service containers* work (Watchtower has no host `docker.sock`).
* `infra` PSA `enforce: privileged` so the pod is admitted.
* hostPath work dir `/mnt/appdata/ci-runner-work` → `/_work` (DinD path safety).
* Cache env hints: `UV_CACHE_DIR`, `XDG_CACHE_HOME`, `NPM_CONFIG_CACHE` under `/cache`.
* No ServiceAccount/RBAC (outbound HTTPS only).

Sketch (authoritative YAML is in `deployment.yaml`):
```yaml
# see manifests/watchtower/github-runner/deployment.yaml
# LABELS=self-hosted,watchtower,x64,zen5
# resources: requests 500m/1Gi, limits 12000m/12Gi
# hostPath: /mnt/appdata/ci-cache -> /cache
```

#### Step 4: Apply on Watchtower (owner)

```bash
ssh watchtower 'sudo mkdir -p /mnt/appdata/ci-cache /mnt/appdata/ci-runner-work'
./deploy.sh --dry-run github-runner
./deploy.sh github-runner
# Confirm Idle at https://github.com/bstruong/sapphire/settings/actions/runners
```

#### Postgres service containers (DinD spike)

**Conclusion:** Job `services:` (Postgres) requires Docker on the runner.
`myoung34/github-runner` without a Docker engine fails Job Services. Watchtower
is k3s/containerd → no host socket → in-container dockerd via
`START_DOCKER_SERVICE` + privileged is the Option-1 path.

**Circuit breaker:** If DinD is unstable, drop workflow `services:` and point
mutation at host/in-cluster Postgres via `TEST_DATABASE_URL` instead.

**Not live-validated in the manifests PR** — no token sealed, no pod scheduled.

---

### Phase 3: Migrate Sapphire Workflows

Update `.github/workflows/mutation-nightly.yml`:

```yaml
jobs:
  mutation:
    name: Mutation Testing (Watchtower Zen 5)
    # Changed from ubuntu-latest:
    runs-on: [self-hosted, watchtower]
```

#### Re-enable the Cron Schedule
Once verified on the self-hosted runner, uncomment the cron trigger:
```yaml
on:
  schedule:
    - cron: "0 8 * * *"
  workflow_dispatch:
```
Because the job runs on `[self-hosted, watchtower]`, it will execute every night, complete 3x faster, and consume **0 minutes** of your GitHub cloud allowance.

---

### Phase 4: Account-Level Rollout Across Repos

Once `sapphire` is validated, register an **Account-Level Runner** under `https://github.com/settings/actions_runners`. 

This enables all your personal repositories to use the runner:

| Repository | Current Hosted Cost | Target Workflow | Migration Benefit |
| :--- | :---: | :--- | :--- |
| **`sapphire`** | $49.23 | `mutation-nightly.yml`, `ci.yml` | Eliminates 91% of account usage |
| **`odysseus`** | $2.73 | `docker-publish.yml`, `ci.yml` | Multi-core container builds with local layer caching |
| **`omega`** | $0.86 | `ci.yml` | Rails 8 + Minitest runs in seconds |
| **`carnelian`** | $0.62 | `ci.yml` | Rails 8 test suite |
| **`homelab-k3s`** | $0.67 | `ci.yaml` | Instant cluster validation & yamllint |

---

## 4. Invariants & Security Guardrails

1. **Private Repositories Only:**  
   > [!CAUTION]
   > Never attach a self-hosted runner to public open-source repositories without strict PR approval gates. For your private repos (`bstruong/*`), it is completely safe.
2. **Network Isolation:**  
   The runner pod requires only **outbound HTTPS (port 443)** to GitHub. No router port forwarding or incoming firewall exceptions are needed on Watchtower.
3. **No JARVIS Contention:**  
   The runner uses pure CPU/RAM. The RTX 3060 remains parked in sleepy-warm mode unless JARVIS is called for model inference.
