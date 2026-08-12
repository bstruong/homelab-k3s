# Secrets

**This repository is public.** No credential is committed to it in a form
anyone can read, and the tooling is built so that committing one by accident
takes deliberate effort.

## How it works

Credentials reach the cluster one of two ways.

**Sealed Secrets (the supported path).** The
[sealed-secrets](https://github.com/bitnami-labs/sealed-secrets) controller
generates a keypair inside the cluster. `kubeseal` encrypts a Secret to the
public half, producing a `SealedSecret` that only that controller can decrypt.
Those encrypted manifests live in this repo at
`manifests/watchtower/<app>/sealedsecret.yaml` and are safe to publish — an
attacker with the whole repository gets ciphertext and nothing else.

**Direct Secrets (the fallback).** `scripts/secrets.sh apply` creates ordinary
Secrets in the cluster and writes nothing to disk. Use this if you would rather
not run the controller; the tradeoff is that your credentials then exist only
in the cluster, so their backup is on you.

Either way, plaintext never touches the filesystem: values are generated in
memory and piped straight into `kubeseal` or `kubectl`.

## Setup

```sh
./scripts/install-hooks.sh                  # pre-commit guard, once per clone
./scripts/bootstrap-sealed-secrets.sh       # install the controller
./scripts/secrets.sh seal --show            # generate, seal, print once
./scripts/bootstrap-sealed-secrets.sh --backup-key
git add manifests/watchtower/*/sealedsecret.yaml && git commit
./deploy.sh
```

`--show` is the only time the generated values are ever printed. Put them in a
password manager at that moment; they are stored as ciphertext and hashes and
cannot be recovered afterwards.

**Back up the controller's private key.** Without it, a rebuilt cluster cannot
decrypt anything in this repo and every credential has to be regenerated. The
backup file is gitignored, but move it offline rather than relying on that.

## What the guards actually block

`scripts/install-hooks.sh` points `core.hooksPath` at `scripts/git-hooks`. The
pre-commit hook rejects:

* any file containing `kind: Secret` — seal it instead
* `stringData:` blocks
* `.env` files, `*.pem`, `*.key`, and SSH private keys
* Tailscale auth keys (`tskey-…`) and Postgres URLs with inline passwords
* anything `gitleaks` flags, if it is installed (`brew install gitleaks`)

`.gitignore` covers the plaintext intermediates and key backups. `.gitleaks.toml`
drives full-history scanning: `gitleaks detect`.

The hook is a safety net, not a boundary — `--no-verify` bypasses it. The real
protection is that no workflow here ever writes a plaintext credential to disk.

## The secrets

`./scripts/secrets.sh list` prints this table; `check` reports what exists.

| App | Namespace | Secret | Keys |
| --- | --- | --- | --- |
| Traefik | `kube-system` | `traefik-dashboard-auth` | `users` |
| Tailscale | `kube-system` | `tailscale` | `authkey` |
| Vaultwarden | `identity` | `vaultwarden` | `admin-token` |
| CrowdSec | `monitoring` | `crowdsec` | `bouncer-key`, `enroll-key` |
| Beszel | `monitoring` | `beszel-agent` | `hub-public-key` |
| Paperless-ngx | `docs` | `paperless-ngx` | `secret-key`, `admin-user`, `admin-password` |
| AppFlowy | `docs` | `appflowy` | `postgres-password`, `database-url`, `jwt-secret`, `gotrue-admin-password`, `minio-access-key`, `minio-secret-key` |
| Syncthing | `sync` | `syncthing` | `gui-apikey` |

Notes on the ones with sharp edges:

* **`traefik-dashboard-auth/users`** is an htpasswd line, not a password. Only
  the bcrypt hash is stored; the password is shown once by `--show`.
* **`tailscale/authkey`** must be supplied by you — generate a reusable,
  pre-authorized key at
  <https://login.tailscale.com/admin/settings/keys>. Tag it so your ACLs can
  target the node. Rotate it after the node has registered; the node key on the
  PVC is what keeps it connected.
* **`crowdsec/enroll-key`** may be empty. It only links the instance to
  app.crowdsec.net. The key must exist, but an empty value simply disables
  enrollment.
* **`appflowy/postgres-password` and `database-url`** are two views of one
  credential. Rotate them in the same command or GoTrue and appflowy-cloud will
  disagree with Postgres.
* **`appflowy/jwt-secret`** is shared by GoTrue and appflowy-cloud. If they
  ever differ, every request 401s.
* **`beszel-agent/hub-public-key`** cannot be generated ahead of time — see
  below.

## Ordering: Beszel

The hub creates its SSH keypair on first start, so the agent's Secret cannot
exist until the hub has run once.

1. `./deploy.sh beszel` — the agent CrashLoops until step 4. That is expected.
2. Open <https://beszel.watchtower.local> and create the admin account.
3. **Add System** → copy the public key it displays.
4. `./scripts/secrets.sh seal beszel --force` (or `apply beszel --force`) and
   paste the key when prompted.
5. `kubectl -n monitoring rollout restart daemonset/beszel-agent`

Register the system in the hub with host `watchtower` and port `45876`.

## Credentials that are not Kubernetes Secrets

These apps own their own credential store and set it up through a first-run
wizard. Nothing in a manifest can provision them.

**AdGuard Home** — <https://dns.watchtower.local> runs a setup wizard. Set the
admin interface to port **3000** and DNS to **53**; the Service and probes
assume 3000. The password is bcrypt-hashed into
`/mnt/appdata/adguard-home/conf/AdGuardHome.yaml`. To reset it, edit the
`users:` block on the node and restart the deployment.

**Jellyfin** — first-run wizard creates the admin. While you are there, finish
the Direct Play setup, which the ConfigMap only half covers. Under
**Dashboard → Users → \<user\> → Playback**, clear for *every* user:

* Allow audio playback that requires transcoding
* Allow video playback that requires transcoding
* Allow video playback that requires re-muxing

These are per-user policies in Jellyfin's database. With them cleared, an
unsupported file fails to play instead of silently pulling the node into a
software transcode.

**Home Assistant** — <https://home.watchtower.local> onboarding creates the
owner account. Everything after that lives in `.storage/` on the PVC, which is
sensitive: it holds long-lived tokens and every integration's credentials.

**Pocket ID** — passkey-only, so there is no admin password. The first-run
setup link is printed in the pod log:
`kubectl -n identity logs deploy/pocket-id | grep -i setup`. Note that passkeys
are bound to `APP_URL` — changing the hostname later invalidates every
registered credential.

**Uptime Kuma** — the first page load creates the admin account. Do it promptly;
until then, anyone who can reach the host can claim it.

**Vaultwarden master passwords** — chosen per user in the web vault and never
sent to the server. They cannot be provisioned, and there is no recovery.
`SIGNUPS_ALLOWED` is `false`; invite users from the `/admin` panel.

## Rotation

```sh
./scripts/secrets.sh seal <app> --force --show
git add manifests/watchtower/<app>/sealedsecret.yaml && git commit
./deploy.sh <app>
kubectl -n <namespace> rollout restart deployment/<name>
```

The restart is required, not optional: Secrets consumed through `env` are read
once at container start.

## If something leaks

1. Rotate at the source first — revoke the Tailscale key in the admin console,
   change the Postgres password, regenerate the Vaultwarden admin token. A
   credential removed from git but still valid is still leaked.
2. Rotate with `--force` as above and redeploy.
3. Only then worry about the history. Rewriting it with `git filter-repo` is
   worth doing, but treat anything ever pushed to a public remote as
   permanently disclosed — clones, forks and caches keep it.
4. If the sealed-secrets private key itself is exposed, rotate the controller's
   keypair and re-seal everything; the committed ciphertext must be considered
   readable.
