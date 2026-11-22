#!/usr/bin/env bash
# Alert if diff vs default branch exceeds 150 LOC (insertions + deletions).
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || {
  echo "error: not inside a git repository" >&2
  exit 1
}
cd "$ROOT"

MAX_LOC=150

resolve_base() {
  local ref
  for ref in origin/main origin/master main master; do
    if git rev-parse --verify --quiet "$ref" >/dev/null; then
      echo "$ref"
      return 0
    fi
  done
  echo "error: could not find default branch (main or master)" >&2
  exit 1
}

BASE="$(resolve_base)"
shortstat="$(git diff "${BASE}" --shortstat || true)"

insertions=0
deletions=0
if [[ -n "${shortstat}" ]]; then
  insertions="$(echo "${shortstat}" | grep -oE '[0-9]+ insertion' | grep -oE '[0-9]+' || true)"
  deletions="$(echo "${shortstat}" | grep -oE '[0-9]+ deletion' | grep -oE '[0-9]+' || true)"
  insertions="${insertions:-0}"
  deletions="${deletions:-0}"
fi

total=$((insertions + deletions))

echo "Base: ${BASE}"
echo "Diff shortstat: ${shortstat:-"(no changes)"}"
echo "LOC churn (insertions + deletions): ${total} (limit ${MAX_LOC})"

if (( total > MAX_LOC )); then
  echo "❌ Diff exceeds ${MAX_LOC} LOC (${total}). Split the change or justify the size before review." >&2
  exit 1
fi

echo "✅ Diff size OK (≤ ${MAX_LOC} LOC)."
exit 0
