#!/usr/bin/env bash
# Everything CI checks before building: the config page's self-checks, the install.sh test and shellcheck.
set -euo pipefail
cd "$(dirname "$0")/.."
for f in tuning calibration updates; do (cd release/zero-config && python3 -B "$f.py"); done
tests/install-test.sh
if command -v shellcheck >/dev/null; then shellcheck -S warning release/*.sh tools/*.sh tests/*.sh && echo "shellcheck ok"
else echo "shellcheck not installed, skipped"; fi
