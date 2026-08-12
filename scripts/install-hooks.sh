#!/usr/bin/env bash
#
# Point git at the tracked hooks in scripts/git-hooks/.
#
# Run once per clone:  ./scripts/install-hooks.sh

set -euo pipefail

cd "$(git rev-parse --show-toplevel)"
chmod +x scripts/git-hooks/*
git config core.hooksPath scripts/git-hooks

echo "core.hooksPath -> scripts/git-hooks"
echo "The pre-commit hook now blocks plaintext Secrets, private keys and env files."

if ! command -v gitleaks >/dev/null 2>&1; then
  echo
  echo "Optional but recommended: install gitleaks for full scanning."
  echo "  macOS:  brew install gitleaks"
  echo "  Linux:  https://github.com/gitleaks/gitleaks/releases"
fi
