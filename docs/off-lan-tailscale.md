# Off-LAN Tailscale (Watchtower host)

Operator narrative (private): fleet `machines/watchtower/off-lan-tailscale.md`.

Host scripts in this repo (run on Watchtower with sudo, from a LAN/console session while key auth still works):

```bash
sudo bash scripts/install-tailscale.sh
# After LAN/CNI baseline (or after patched reconcile), apply the Tailscale zone:
sudo bash scripts/firewall-tailscale.sh
sudo bash scripts/harden-sshd.sh
```

## Firewall ownership and apply order

- `scripts/reconcile-host-security.sh` owns **LAN** allowlist + trusts **CNI only** (`cni0` and source `10.42.0.0/16`). It does **not** put `tailscale0` in the `trusted` zone.
- `scripts/firewall-tailscale.sh` is the **sole Tailscale firewalld owner**: dedicated `tailscale` zone, bind `tailscale0` (or CGNAT fallback), allow only `ssh` + `80/tcp` + `443/tcp`, and remove `tailscale0` from `trusted` if present. Cockpit (`9090`) and raw JARVIS (`8080`) stay off the Tailnet.

**Order when hardening a host:** patched `reconcile-host-security.sh` first, then `firewall-tailscale.sh`. Re-running reconcile must not re-trust Tailscale.

JARVIS over the mesh uses Traefik with `Host(watchtower)` (MagicDNS short name) — not the localhost-only hostPort on `:8080`.

Audit Tailnet exposure with `WATCHTOWER_TS_IP=<watchtower-tailscale-ipv4> ./scripts/audit-network-security.sh` (or auto-detect via `tailscale ip -4 watchtower`). If no Tailscale IP is available, that section is skipped — it does not false-PASS.

Do **not** commit Tailscale auth keys, operator usernames, tailnet FQDNs (`*.ts.net`), or LAN addresses into this public repository.
