# Alpha engine helper (ARCHIVED — pending deletion)

Ruby `Engine::Manager` formerly lived in the Alpha repo and mirrored ConfigMap
lease annotations. **Do not use for new work.**

Canonical interface:

```bash
./scripts/jarvis-session.sh begin <holder> [ttl-minutes] [run-id]
./scripts/jarvis-session.sh heartbeat
./scripts/jarvis-session.sh end
```

See [docs/jarvis.md](../../docs/jarvis.md) and
[docs/alpha-jarvis-session-contract.md](../../docs/alpha-jarvis-session-contract.md).

This directory is deleted after Phase 4 end-to-end validation (Alpha launcher
cutover + ConfigMap removal).
