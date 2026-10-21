# Alpha (retired GPU owner)

Project Alpha no longer owns Watchtower inference. **JARVIS** is the shared
engine:

- Manifests: [`../jarvis/`](../jarvis/)
- Docs: [`../../../docs/jarvis.md`](../../../docs/jarvis.md)
- Client: Alpha repo `Alpha::Engine::Manager` → namespace/deployment `jarvis`/`jarvis`

The `alpha` namespace is kept only so older scripts and sealed objects do not
break during cutover. Do not re-add an `alpha-llama` Deployment here.
