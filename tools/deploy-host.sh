#!/usr/bin/env bash
# Copy work/klippy (host Python, including uncommitted edits) to the printer and restart Klipper. No flashing.
set -euo pipefail
. "$(dirname "$0")/common.sh"
need_work
require_idle
# excluded files are also protected from --delete (compiled caches and c_helper.so)
synced=$(rsync -rlptc --delete -i --exclude='*.pyc' --exclude=__pycache__ --exclude='*.so' --exclude=.version \
    "$WORK/klippy/" "$PRINTER:klipper/klippy/")   # captured, so a failed rsync stops here
grep -E '^<f|deleting' <<<"$synced" || echo "(no content changes)"
if grep -qE '^(<f|\*deleting).* chelper/.*\.[ch]$' <<<"$synced"; then   # Klipper rebuilds it on start
    rsh rm -f klipper/klippy/chelper/c_helper.so
fi
rsh sudo -n systemctl restart klipper
wait_ready
