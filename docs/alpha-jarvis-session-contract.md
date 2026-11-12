# Alpha cutover contract — JARVIS GPU session (Phase 4)

Homelab owns the Watchtower lifecycle. Alpha owns graded harness code. This
document is the interface the subsequent **Alpha** PR must call.

## Binding rules

1. Graded suites run only as Watchtower `alpha` campaign Jobs.
2. Laptops may submit/monitor (`alpha_watchtower_kick.sh`) then disconnect.
3. The Job owns run ID, Lease, wake, heartbeat, cleanup, and GPU release.
4. Claim-on-demand / release-on-completion — never leave JARVIS permanently on.
5. Do not merge Alpha’s new lifecycle caller before this homelab Lease interface
   is deployed.

## Canonical session interface

Path (inside the Job after homelab sync): `$HOMELAB_K3S/scripts/jarvis-session.sh`

| Command | Meaning |
| --- | --- |
| `begin <holder> [ttl-min] [run-id]` | CAS-acquire `lease/jarvis-gpu`, scale 0→1, wait `/health` |
| `heartbeat` | Renew `renewTime` + `last-activity-at` for the session holder |
| `heartbeat-loop [seconds]` | Background renew (Job-owned; never laptop) |
| `end [--keep-up]` | Release Lease; scale 1→0 unless `--keep-up` |
| `status` | Print Lease + dual-read ConfigMap + replica count |

Primitives (`acquire` / `wake` / `release` / `scale-down`) exist for debugging.
Campaigns should use `begin` → `heartbeat-loop` → `end` only.

Thin wrappers that remain for operators:

- `scripts/jarvis-up.sh` / `jarvis-down.sh` / `jarvis-lease.sh` / `jarvis-status.sh`

## Kubernetes object

```text
coordination.k8s.io/v1  Lease  jarvis/jarvis-gpu
```

| Field | Role |
| --- | --- |
| `spec.holderIdentity` | Exclusive holder (e.g. `alpha-campaign`) |
| `spec.leaseDurationSeconds` | TTL after last renew (`ttl-min * 60`) |
| `spec.acquireTime` / `spec.renewTime` | MicroTime; exclusivity ends at renew+duration |
| `metadata.annotations.jarvis.watchtower/run-id` | Unique run / Job identity |
| `metadata.annotations.jarvis.watchtower/last-activity-at` | Idle reconciler warmth |

Legacy ConfigMap `jarvis/jarvis-lease` is **dual-read/mirrored only during cutover**.
After Alpha validates, delete it and set `JARVIS_LEASE_DUAL_READ=0`.

## Homelab Job entrypoint (already wired)

`manifests/watchtower/alpha/configmap-entrypoint.yaml`:

1. Sync repos (including homelab scripts).
2. `jarvis-session.sh begin "$JARVIS_LEASE_HOLDER" "$JARVIS_LEASE_MINUTES" "$JARVIS_SESSION_RUN_ID"`.
3. Start `heartbeat-loop` in the background.
4. Run the campaign script with `ALPHA_JARVIS_DOWN_AFTER=0` (entrypoint owns scale-down).
5. On `EXIT`: stop heartbeat, `jarvis-session.sh end`, ntfy.

Job bounds: `activeDeadlineSeconds: 16200`, `terminationGracePeriodSeconds: 180`.
Pod seccomp/AppArmor are `Unconfined` so Phase 2 bubblewrap user namespaces work.

## Alpha PR checklist (follow-up)

1. **`scripts/alpha_watchtower_kick.sh`** — submission only:
   - Create Job from CronJob template (or equivalent).
   - Confirm acceptance + record run/Job name.
   - Exit. No ConfigMap precheck ownership, no lease acquire, no heartbeat, no SSH hold.
   - Optional read-only status via `jarvis-session.sh status` / Lease get.
2. **Campaign scripts** (`run_capability_map_v2.sh`, ops/web variants):
   - Remove local `jarvis-up` / `jarvis-lease` / `jarvis-down` lifecycle when
     `JARVIS_SESSION_RUN_ID` is set (Job already owns the session).
   - Keep scripts usable for **non-graded** local diagnostics only; never claim
     graded evidence from a laptop runner.
3. **Status helpers** — read `lease/jarvis-gpu`, not ConfigMap annotations.
4. After end-to-end validation on Watchtower, homelab deletes:
   - `manifests/watchtower/jarvis/lease-configmap.yaml`
   - ConfigMap dual-read/mirror code (`JARVIS_LEASE_DUAL_READ`)
   - `scripts/alpha-engine/`
   - Duplicate wake/lease callers outside `jarvis-session.sh`

## RBAC expectations (`system:serviceaccount:alpha:alpha-runner`)

| Check | Expected |
| --- | --- |
| `patch deployment/jarvis` (parent) | **no** |
| `patch deployment/jarvis --subresource=scale` | **yes** |
| `get deployment/jarvis` | **yes** |
| `patch lease/jarvis-gpu` | **yes** |

## Validation (homelab)

```bash
./deploy.sh --dry-run jarvis
./deploy.sh --dry-run alpha
shellcheck scripts/jarvis-*.sh
kubectl auth can-i patch deployment/jarvis -n jarvis \
  --as=system:serviceaccount:alpha:alpha-runner
kubectl auth can-i patch deployment/jarvis --subresource=scale -n jarvis \
  --as=system:serviceaccount:alpha:alpha-runner
kubectl auth can-i patch lease/jarvis-gpu -n jarvis \
  --as=system:serviceaccount:alpha:alpha-runner
```
