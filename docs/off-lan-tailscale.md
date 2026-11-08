# Off-LAN Tailscale (Watchtower host)

Operator narrative (private): fleet `machines/watchtower/off-lan-tailscale.md`.

Host scripts in this repo (run on Watchtower with sudo, from a LAN/console session while key auth still works):

```bash
sudo bash scripts/install-tailscale.sh
sudo bash scripts/firewall-tailscale.sh
sudo bash scripts/harden-sshd.sh
```

JARVIS over the mesh uses Traefik with `Host(watchtower)` (MagicDNS short name) — not the localhost-only hostPort on `:8080`.

`scripts/reconcile-host-security.sh` already trusts the Tailscale interface for the broader firewall posture.

Do **not** commit Tailscale auth keys, operator usernames, tailnet FQDNs (`*.ts.net`), or LAN addresses into this public repository.
