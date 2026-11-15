#!/usr/bin/env bash
# Copy work/klippy (host Python, including uncommitted edits) to the printer and restart Klipper. No flashing.
set -euo pipefail
. "$(dirname "$0")/common.sh"
need_work
require_idle
# excluded files are also protected from --delete (compiled caches, chelper .so is rebuilt by klippy when sources change)
rsync -rlptc --delete -i --exclude='*.pyc' --exclude=__pycache__ --exclude='*.so' --exclude=.version \
    "$WORK/klippy/" "$PRINTER:klipper/klippy/" | grep -E '^<f|deleting' || echo "(no content changes)"
rsh sudo -n systemctl restart klipper
wait_ready
