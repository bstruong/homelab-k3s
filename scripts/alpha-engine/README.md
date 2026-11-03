# Alpha engine helper (JARVIS wake / lease)

Ruby `Engine::Manager` formerly lived in the Alpha repo. Alpha is now an HTTP
eval client only (`OPENAI_BASE_URL`). Cluster lifecycle stays here next to JARVIS.

## Preferred shell interface

```bash
./scripts/jarvis-up.sh
./scripts/jarvis-status.sh
./scripts/jarvis-lease.sh acquire alpha-lab 90
# ... run Alpha / other clients ...
./scripts/jarvis-lease.sh release
./scripts/jarvis-down.sh
```

See [docs/jarvis.md](../../docs/jarvis.md).

## Ruby Manager (optional)

[`manager.rb`](manager.rb) is the historical Alpha client: scale Deployment
`jarvis/jarvis`, annotate lease ConfigMap `jarvis-lease`, health-check the
OpenAI-compatible endpoint. Use when you need the same API from Ruby scripts.
Tests snapshot: [`engine_manager_test.rb`](engine_manager_test.rb) (not wired
into Alpha's CI).
