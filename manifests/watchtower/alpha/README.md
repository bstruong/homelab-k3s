# Alpha (retired GPU owner)

Project Alpha no longer owns Watchtower inference. **JARVIS** is the shared
engine:

- Manifests: [`../jarvis/`](../jarvis/)
- Docs: [`../../../docs/jarvis.md`](../../../docs/jarvis.md)
- Client: Alpha repo `Alpha::Engine::Manager` → namespace/deployment `jarvis`/`jarvis`

The `alpha` namespace is kept only so older scripts and sealed objects do not
break during cutover. There are **no** YAML manifests here — `deploy.sh`
skips this directory. Do not re-add an `alpha-llama` Deployment.

Cluster cleanup (one-time): delete any leftover `alpha-llama` Deployment and
the `alpha-models` PVC/PV claimRef after `jarvis-models` is Bound. Never
delete GGUF files under `/mnt/models`.
