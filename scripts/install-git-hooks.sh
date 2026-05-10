#!/usr/bin/env bash
# May 10, 2026 - 10:15am - GitHub Copilot (GPT-5.3-Codex)
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

cd "$repo_root"
git config core.hooksPath .githooks
chmod +x .githooks/pre-commit

echo "Installed repository hooks path: .githooks"
echo "pre-commit launch-screen guard is now active for this repository clone."
