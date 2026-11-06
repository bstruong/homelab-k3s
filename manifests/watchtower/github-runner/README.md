# GitHub Actions runner (Watchtower / Option 1)

k3s `Deployment` of [`myoung34/github-runner:ubuntu-noble`](https://github.com/myoung34/docker-github-actions-runner)
registered to **private** repo `bstruong/sapphire`, labels
`self-hosted,watchtower,x64,zen5`.

No `ServiceAccount` / RBAC: outbound HTTPS to GitHub only; `automountServiceAccountToken: false`.

## Blockers (owner action required)

This PR ships manifests + runbook only. Live apply needs secrets and cluster
access the agent does not have:

1. **Real registration token or PAT** — never invent or commit plaintext.
2. **SealedSecret** — `manifests/watchtower/github-runner/sealedsecret.yaml` is
   intentionally absent until the owner seals.
3. **Cluster apply** — `./deploy.sh github-runner` on Watchtower after seal.
4. **GitHub spending limit $0** — verify in Billing settings (plan Phase 1).

Until the Secret exists, the pod stays in `CreateContainerConfigError`.

## Seal the registration token (owner)

Registration tokens from **Settings → Actions → Runners → New self-hosted runner**
expire in about an hour. Paste the real value; do not invent one.

```bash
# From the homelab-k3s repo root, with kubectl context = Watchtower and
# sealed-secrets controller running (or SEALED_SECRETS_CERT pointing at the
# public cert).

# Preferred for smoke: one-shot registration token → key `token`
./scripts/secrets.sh seal-generic github-runner-token infra \
  token="<GITHUB_RUNNER_REGISTRATION_TOKEN>" \
  > manifests/watchtower/github-runner/sealedsecret.yaml

git add manifests/watchtower/github-runner/sealedsecret.yaml
git commit -m "chore(github-runner): seal registration token"
```

`EPHEMERAL=1` deregisters after each job and the Deployment recreates the pod.
A short-lived registration token will not survive that loop. For steady-state:

```bash
# Durable: classic PAT with repo scope (private repos). Key must still be
# named `token` for the current Deployment's secretKeyRef, OR switch the
# Deployment env from RUNNER_TOKEN to ACCESS_TOKEN (upstream preferred).
#
# Recommended durable shape (edit deployment.yaml env to ACCESS_TOKEN /
# key access-token, then):
./scripts/secrets.sh seal-generic github-runner-token infra \
  access-token="<GITHUB_PAT_WITH_REPO_SCOPE>" \
  > manifests/watchtower/github-runner/sealedsecret.yaml
```

Until you change the Deployment to `ACCESS_TOKEN` / `access-token`, seal the
registration token as `token=` as shown in the first command.

Rotate with the same command (overwrite the SealedSecret) and re-apply.

## Apply

```bash
# Host dirs (deploy.sh usually prints these if missing)
ssh watchtower 'sudo mkdir -p /mnt/appdata/ci-cache /mnt/appdata/ci-runner-work'

# Dry-run first
./deploy.sh --dry-run github-runner

# Apply just this app (after sealedsecret.yaml is committed or applied)
./deploy.sh github-runner

# Confirm the runner appears Idle under
# https://github.com/bstruong/sapphire/settings/actions/runners
kubectl -n infra get pods -l app.kubernetes.io/name=github-runner-sapphire -o wide
kubectl -n infra logs -l app.kubernetes.io/name=github-runner-sapphire --tail=100
```

## Postgres Actions service containers (DinD spike)

### Conclusion

**Sapphire `mutation-nightly.yml` uses a Postgres *service container*.** That
requires a Docker engine on the runner. Upstream
[`myoung34/github-runner`](https://github.com/myoung34/docker-github-actions-runner)
documents that Job Services fail without Docker.

Watchtower runs **k3s + containerd**, not a host Docker daemon, so mounting
`/var/run/docker.sock` is not available. This Deployment therefore sets:

| Setting | Value | Why |
| --- | --- | --- |
| `START_DOCKER_SERVICE` | `true` | Start dockerd inside the runner container |
| `securityContext.privileged` | `true` | Required for in-container dockerd |
| `infra` PSA | `enforce: privileged` | baseline PSA rejects privileged pods |

With that, Actions can start `services: postgres:` and the job reaches it on
`localhost:5432` (job on host network path) or via the service label when the
job itself runs in a container — matching GitHub's service-container docs.

### Circuit breaker (if DinD misbehaves on Watchtower)

If privileged dockerd is blocked or unstable:

1. Keep this runner for CPU-bound steps that do **not** need service containers.
2. Point mutation at a **host Postgres** (or an in-cluster Postgres Service) via
   workflow env (`TEST_DATABASE_URL=…`) instead of `jobs.*.services`.
3. Leave ARC / scale-to-zero / “all CI on Watchtower” on the raw backlog.

### What was *not* live-validated in this PR

No registration token was sealed and no pod was scheduled on Watchtower.
Treat the DinD path as **designed + documented**; confirm with a
`workflow_dispatch` mutation after the owner seals and applies.

## Security

- Private repository only (`bstruong/sapphire`).
- Outbound HTTPS (443) only; no inbound ports.
- Privileged + root is a documented exception for DinD — do not reuse this
  pattern for ordinary apps.
- JARVIS keeps the GPU; this runner is CPU/RAM only (limits leave headroom).
