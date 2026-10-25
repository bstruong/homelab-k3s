# Homelab K3s — Agent & Infrastructure Conventions

Declarative Kubernetes manifests for the single-node **Watchtower** k3s homelab (`manifests/watchtower/<app>/`). Plain `kubectl` + `deploy.sh` — no custom Helm charts or kustomize overlays.

## Verification Commands
- **YAML Lint:** `yamllint .`
- **Secret Scan (Required before commit):** `gitleaks detect --source . -v` and `./scripts/secrets.sh check`
- **Cluster Dry-Run Validation:** `./deploy.sh --dry-run` (or `./deploy.sh --validate` to inspect live state without mutating)

## Core Invariants
1. **Zero Plaintext Secrets in Git:**
   - This repository is public. All credentials must be sealed via `sealed-secrets` (`sealedsecret.yaml`).
   - Never commit plaintext `Secret` manifests, `.env` files, tokens, or private IPs/MagicDNS hostnames where prohibited.
2. **Self-Contained App Layout (`manifests/watchtower/<app>/`):**
   - Keep each app to small, readable files (`deployment.yaml` / `statefulset.yaml`, `service.yaml`, `ingress.yaml`, `configmap.yaml`, `pvc.yaml`, `sealedsecret.yaml`, `rbac.yaml`).
   - Traefik has `allowCrossNamespace: false` — all routes, middlewares, and service references must be namespace-local.
   - Every container must declare explicit `resources.requests` and `resources.limits`.
   - Prefer unprivileged pods (`runAsNonRoot: true`, dropped capabilities, `allowPrivilegeEscalation: false`, `seccompProfile: RuntimeDefault`) unless documented in the README exception table.
3. **JARVIS Self-Preservation Guardrail (CRITICAL for Local Agents):**
   - If you are running via Pi connected to `http://ai.watchtower.local/v1` (`jarvis` namespace), **NEVER** execute `./deploy.sh jarvis`, `kubectl rollout restart -n jarvis`, or `./scripts/jarvis-sleep.sh` during your turn — restarting or sleeping JARVIS will terminate your own active LLM inference connection mid-execution. Only edit manifests and validate with `./deploy.sh --dry-run`.
4. **No Tailscale Pod:** Watchtower runs `tailscaled` on the host systemd service. Never add a Tailscale container/pod to k3s (it will crash-loop fighting the host for `tailscale0`).
