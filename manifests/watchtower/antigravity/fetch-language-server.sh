#!/usr/bin/env bash
#
# Fetch Google's language_server binary out of the official Antigravity desktop
# archive. Mirrors install_language_server() in the upstream install.sh: the
# download URL is not published as a stable link, it is scraped off the
# download page, so both the regex and the tar path below match upstream's.
#
#   fetch-language-server.sh [URL] OUTDIR
#
# URL may be empty, in which case it is resolved from the download page.
set -euo pipefail

URL="${1:-}"
OUT="${2:?output directory required}"

DOWNLOAD_PAGE="https://antigravity.google/download"
HUB_SLUG="linux-x64"

if [ -z "$URL" ]; then
  echo "Resolving language_server URL from ${DOWNLOAD_PAGE}..."
  URL="$(curl -fsSL --compressed "$DOWNLOAD_PAGE" \
    | grep -oE "https://storage\.googleapis\.com/antigravity-public/antigravity-hub/[^\"'<> ]+/${HUB_SLUG}/Antigravity\.tar\.gz" \
    | head -1)"
fi

if [ -z "$URL" ]; then
  echo "Could not resolve the Antigravity download URL." >&2
  echo "Pass it explicitly with --build-arg LANGUAGE_SERVER_URL=..." >&2
  exit 1
fi

VERSION="$(printf '%s' "$URL" | sed -nE 's#.*/antigravity-hub/([0-9][0-9.]*)-[0-9]+/.*#\1#p')"
echo "Antigravity ${VERSION:-unknown} for ${HUB_SLUG}"
echo "  ${URL}"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

curl -fL --progress-bar "$URL" -o "$TMP/Antigravity.tar.gz"

# --strip-components=3 drops Antigravity-*/resources/bin/ and leaves the bare
# binary. Only language_server is extracted; the rest of the desktop app (the
# Electron shell, ~170 MB of it) is not wanted in a headless image.
tar -xzf "$TMP/Antigravity.tar.gz" -C "$TMP" --wildcards --strip-components=3 \
  'Antigravity-*/resources/bin/language_server'

install -d "$OUT"
install -m 0755 "$TMP/language_server" "$OUT/language_server"

# Record what was installed so AGY_IDE_VERSION can be set from it if needed,
# and so `podman inspect` on the image is not the only way to tell.
printf '%s\n' "${VERSION:-unknown}" > "$OUT/language_server.version"

echo "Installed ${OUT}/language_server ($(stat -c %s "$OUT/language_server") bytes)"

# A dynamically linked Google binary in a slim base is the most likely way this
# image fails at runtime rather than build time, so check it here where the
# failure is loud and attributable.
if command -v ldd >/dev/null 2>&1; then
  if ldd "$OUT/language_server" 2>&1 | grep -q "not found"; then
    echo "MISSING SHARED LIBRARIES:" >&2
    ldd "$OUT/language_server" 2>&1 | grep "not found" >&2
    exit 1
  fi
  echo "Shared library check passed."
fi
