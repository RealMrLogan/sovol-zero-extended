#!/usr/bin/env bash
# Everything CI checks before building: the config page's self-checks and server, install.sh, the app
# dependency rules make-release.sh applies, flash-board.sh's image check, and shellcheck.
set -euo pipefail
cd "$(dirname "$0")/.."
for f in tuning calibration updates; do (cd release/zero-config && python3 -B "$f.py"); done
python3 -B tests/server-test.py
tests/install-test.sh
tests/app-deps-test.sh
tests/flash-board-test.sh
if command -v shellcheck >/dev/null; then shellcheck -S warning release/*.sh tools/*.sh tests/*.sh && echo "shellcheck ok"
else echo "shellcheck not installed, skipped"; fi
