# Off-LAN Tailscale (Watchtower host)

Operator narrative lives in [fleet off-lan-tailscale.md](https://github.com/bstruong/fleet/blob/main/machines/watchtower/off-lan-tailscale.md).

Host scripts in this repo (run on Watchtower with sudo, from a LAN/console session):

```bash
sudo bash scripts/install-tailscale.sh
sudo bash scripts/firewall-tailscale.sh
# confirm key auth still works, then:
sudo bash scripts/harden-sshd.sh
```

JARVIS mesh URL is Traefik `http://watchtower/v1` (IngressRoute Host match) — not hostPort `:8080`.

Related: `scripts/reconcile-host-security.sh` already trusts `tailscale0` for the broader firewall posture.
