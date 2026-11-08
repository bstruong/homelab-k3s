# Site-local values (not for the public tree)

This repository is **public**. Manifests and scripts use [RFC 5737](https://www.rfc-editor.org/rfc/rfc5737) documentation addresses as stand-ins:

| Placeholder | Meaning |
| --- | --- |
| `192.0.2.10` | Watchtower LAN IPv4 |
| `192.0.2.11` | Secondary LAN host (e.g. workstation) |
| `192.0.2.1` | LAN default gateway / DNS upstream example |
| `192.0.2.0` | LAN subnet example (`192.0.2.0/24`) |
| `<MAC_ADDRESS>` | Documentation NIC MAC placeholder |

Before applying to a real cluster, substitute your site values **locally** and do **not** commit them:

```bash
# example — keep the result uncommitted or in a private fork
find manifests scripts docs -type f \( -name '*.yaml' -o -name '*.md' -o -name '*.sh' \) \
  -exec sed -i \
    -e 's/192\.0\.2\.10/YOUR_WATCHTOWER_LAN_IP/g' \
    -e 's/192\.0\.2\.11/YOUR_SECONDARY_LAN_IP/g' \
    -e 's/192\.0\.2\.1/YOUR_GATEWAY_IP/g' \
    -e 's/192\.0\.2\.0/YOUR_LAN_PREFIX/g' {} +
```

Prefer MagicDNS / `.local` hostnames in clients (`http://watchtower`, `ai.watchtower.local`) over raw IPs.

Never commit Tailscale auth keys, tailnet FQDNs (`*.ts.net`), private keys, or real LAN inventory into this repository.
