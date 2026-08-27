# Antigravity Server (agy-server) — container image for Watchtower.
#
# Upstream ships no image: .goreleaser.yaml and .github/workflows/release.yml
# publish binaries only, and deploy/ holds just a Caddyfile and a systemd unit.
# So this is written from scratch, but it still installs OFFICIAL artifacts
# rather than building anything from source:
#
#   agy-server       GitHub release tarball (Apache-2.0, this project's own)
#   language_server  Google's build bucket. NOT redistributed by the project,
#                    which is why scripts/install.sh downloads it at install
#                    time and why this Dockerfile does the same.
#
# The image therefore contains a Google binary. It is pushed only to
# registry.watchtower.local and never leaves the LAN, so this is a local
# install rather than redistribution. Keep it that way.

# ---------------------------------------------------------------- fetch stage
# Base images come from mirror.gcr.io, Google's pull-through mirror of Docker
# Hub, NOT from docker.io directly. This is not a preference, it is a
# workaround for a Watchtower host issue: the node holds an IPv6 ULA address
# (fdd0::/8) from router RAs but has no IPv6 default route, so Go's built-in
# resolver -- which podman uses -- prefers the AAAA records that docker.io and
# its CloudFront backends publish and then dead-ends on an unreachable network.
# glibc gets this right (curl works), containerd gets it right, only the Go
# resolver does not. mirror.gcr.io serves the identical official image
# (config digest e426a54f50cc...), so this changes the fetch path and nothing
# about the contents. Fixing the host's IPv6 situation would let this revert
# to docker.io.
FROM mirror.gcr.io/library/debian:13-slim AS fetch

ARG AGY_VERSION=v0.2.7
ARG TARGETARCH=amd64
# Leave blank to resolve the current build from antigravity.google/download,
# exactly as scripts/install.sh does. Pin it to make a build reproducible.
ARG LANGUAGE_SERVER_URL=

RUN apt-get update -qq \
 && apt-get install --no-install-recommends -y ca-certificates curl tar \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /out

# agy-server: the release tarball carries the bare binary at its root.
RUN set -eux; \
    curl -fsSL "https://github.com/AFSlayer/antigravity-server/releases/download/${AGY_VERSION}/agy-server_linux_${TARGETARCH}.tar.gz" -o /tmp/agy.tar.gz; \
    tar -xzf /tmp/agy.tar.gz -C /tmp; \
    install -m 0755 /tmp/agy-server /out/agy-server

# language_server: ~170 MB, buried three levels deep in Google's desktop
# archive. The scrape and the --strip-components=3 path both mirror
# install_language_server() in scripts/install.sh. If upstream moves the
# download page this is the line that breaks, hence the ARG escape hatch.
COPY fetch-language-server.sh /usr/local/bin/fetch-language-server.sh
RUN chmod +x /usr/local/bin/fetch-language-server.sh \
 && /usr/local/bin/fetch-language-server.sh "${LANGUAGE_SERVER_URL}" /out

# -------------------------------------------------------------- runtime stage
FROM mirror.gcr.io/library/debian:13-slim

# ca-certificates is not optional: agy-server talks to Google over TLS for
# sign-in, and language_server does the same for model calls.
RUN apt-get update -qq \
 && apt-get install --no-install-recommends -y ca-certificates \
 && rm -rf /var/lib/apt/lists/*

# uid/gid 1000, matching runAsUser/runAsGroup in deployment.yaml.
RUN groupadd -g 1000 agy \
 && useradd -u 1000 -g 1000 -M -d /data -s /usr/sbin/nologin agy \
 && install -d -o 1000 -g 1000 -m 0755 /data

COPY --from=fetch /out/agy-server /usr/local/bin/agy-server
COPY --from=fetch /out/language_server /opt/agy-server/language_server

# HOME=/data, deliberately, and NOT AGY_HOME.
#
# AGY_HOME relocates only the config/credentials/sessions directory. The Google
# OAuth token lives at GeminiDir(), which internal/config/config.go builds from
# HomeDir() and which AGY_HOME does not affect. Setting AGY_HOME alone would
# leave ~/.gemini outside the volume, so the token would be lost on every pod
# restart and the server would need re-authenticating every time. Setting HOME
# puts all three under the single PVC mount:
#
#   /data/.agy-remote   config.json, credentials.json, sessions.json
#   /data/.gemini       jetski-standalone-oauth-token
#   /data/workspace     projects
ENV HOME=/data \
    AGY_BIND=0.0.0.0 \
    AGY_PORT=8765 \
    AGY_LANGUAGE_SERVER=/opt/agy-server/language_server \
    AGY_WORKSPACE_ROOT=/data/workspace

# language_server stays in /opt rather than on the PVC: ~170 MB of immutable,
# version-pinned binary belongs to the image, not to the user's state.

USER 1000:1000
WORKDIR /data
EXPOSE 8765

ENTRYPOINT ["/usr/local/bin/agy-server"]
CMD ["serve"]
