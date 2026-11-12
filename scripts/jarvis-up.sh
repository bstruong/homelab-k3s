#!/usr/bin/env bash
# Wake JARVIS (scale 0→1) and wait for /health.
# Prefer scripts/jarvis-session.sh begin for exclusive work.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/jarvis-common.sh"

echo "==> waking ${JARVIS_NS}/${JARVIS_DEP}"
jarvis_scale 1
jarvis_touch_activity
jarvis_wait_healthy "${JARVIS_WAKE_TIMEOUT:-180}"
