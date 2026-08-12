# Secrets and manual setup steps

No credential in this repo is committed. Every workload reads its credentials
from a Kubernetes Secret, and `deploy.sh` refuses to apply an app whose Secret
is missing a required key.

The fastest path is `./scripts/create-secrets.sh --show`, which generates the
random ones and prompts for the rest. Everything below documents what that
script does, so you can create them by hand instead if you prefer.

## Secrets

### `identity/vaultwarden`

| Key | What it is |
| --- | --- |
| `admin-token` | Guards the Vaultwarden `/admin` panel. Any long random string. |

```sh
kubectl -n identity create secret generic vaultwarden \
  --from-literal=admin-token="$(openssl rand -base64 48)"
```

Note: this is **not** a Vaultwarden master password. Master passwords are
chosen per user in the web vault and never leave the client — they cannot be
provisioned from Kubernetes, and there is no recovery if one is lost.

### `docs/paperless-ngx`

| Key | What it is |
| --- | --- |
| `secret-key` | Django `SECRET_KEY`. Changing it invalidates all sessions. |
| `admin-user` | Username for the superuser created on first start. |
| `admin-password` | Password for that superuser. |

```sh
kubectl -n docs create secret generic paperless-ngx \
  --from-literal=secret-key="$(openssl rand -base64 48)" \
  --from-literal=admin-user=admin \
  --from-literal=admin-password="$(openssl rand -base64 18)"
```

The superuser is only created if the database has no users yet. Changing
`admin-password` later does **not** change the existing account — use
`kubectl -n docs exec deploy/paperless-ngx -- python3 manage.py changepassword admin`.

### `docs/appflowy`

| Key | What it is |
| --- | --- |
| `postgres-password` | Password for the `postgres` superuser in the AppFlowy StatefulSet. |
| `database-url` | Full connection URL. Must embed the same password. |
| `jwt-secret` | Shared by GoTrue and appflowy-cloud to sign and verify JWTs — they must match exactly or every request 401s. |
| `gotrue-admin-password` | Password for the GoTrue admin account (`admin@watchtower.local`). |
| `minio-access-key` | MinIO root user. |
| `minio-secret-key` | MinIO root password. |

`postgres-password` and `database-url` are two views of one credential; if you
rotate the password, rotate the URL in the same `kubectl` call.

### `monitoring/beszel-agent`

| Key | What it is |
| --- | --- |
| `hub-public-key` | The Beszel Hub's SSH public key. The agent only accepts connections signed by it. |

This one cannot be generated ahead of time — the hub creates the keypair on
first start. Order of operations:

1. Deploy the hub: `./deploy.sh beszel` (the agent will CrashLoop until step 4 —
   that is expected).
2. Open `https://beszel.watchtower.local` and create the admin account. This is
   a first-run web form, not a Secret; Beszel stores it in its own database.
3. Click **Add System**. Copy the public key it shows.
4. `kubectl -n monitoring create secret generic beszel-agent --from-literal=hub-public-key='ssh-ed25519 AAAA...'`
5. `kubectl -n monitoring rollout restart daemonset/beszel-agent`

Register the system in the hub with host `watchtower` (the node's LAN address)
and port `45876`.

## Credentials that are *not* Kubernetes Secrets

Some apps own their own credential store and set it up through a first-run
wizard. There is no manifest-level way to inject these.

### AdGuard Home admin password

AdGuard hashes the admin password into `AdGuardHome.yaml` inside its own data
directory, during the setup wizard.

1. `https://dns.watchtower.local` → setup wizard.
2. Set the **admin interface** to port `3000` and **DNS** to port `53`. The
   manifests, Service, and probes all assume 3000; changing it in the wizard
   will break the readiness probe.
3. Choose the admin username and password. Store them in your password manager.

To reset it later, edit `users:` in
`/mnt/appdata/adguard-home/conf/AdGuardHome.yaml` on the node with a fresh
bcrypt hash and restart the deployment.

### Jellyfin admin account

Created through the first-run wizard at `https://jellyfin.watchtower.local`.

While you are there, finish the Direct Play configuration — the ConfigMap only
covers the server half:

* **Dashboard → Users → \<user\> → Playback**, clear:
  * Allow audio playback that requires transcoding
  * Allow video playback that requires transcoding
  * Allow video playback that requires re-muxing
* Do this for every user, including the admin. These are per-user policies
  stored in Jellyfin's database, so they cannot be set from a manifest.

With those cleared, an unsupported file fails to play rather than silently
pulling the node into a software transcode.

## Rotation

```sh
kubectl -n <namespace> create secret generic <name> \
  --from-literal=<key>=<new-value> --dry-run=client -o yaml | kubectl apply -f -
kubectl -n <namespace> rollout restart deployment/<name>
```

Pods do not pick up changes to Secrets consumed via `env` until they restart,
so the rollout restart is required, not optional.
