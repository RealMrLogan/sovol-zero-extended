#!/usr/bin/env bash
# Build board firmware from work/ on the printer (Sovol's gcc 8.3.1). Usage: build-mcu.sh toolhead|mainboard
set -euo pipefail
. "$(dirname "$0")/common.sh"
need_work
board_info "${1:-}"; board=$1
ver=$(git -C "$WORK" describe --always --tags --long --dirty)
rsh "mkdir -p $B/klipper $B/bin"
rsync -rlpt --delete --exclude=/.git --exclude='/out-*/' --exclude='*.pyc' --exclude=__pycache__ "$WORK/" "$PRINTER:$B/klipper/"
rsync -t "$CFG" "$PRINTER:$B/$board.config"
# shortcut: a stub git so buildcommands.py stamps work/'s version; the real 256 MB history won't fit on the printer's eMMC
rsh "printf '#!/bin/sh\necho %s\n' '$ver' > $B/bin/git && chmod +x $B/bin/git && touch $B/klipper/.git && cd $B/klipper &&
     export PATH=\$HOME/$B/bin:\$PATH && m='make KCONFIG_CONFIG=../$board.config OUT=out-$board/' &&
     \$m -s olddefconfig && \$m clean && { \$m -j4 > ../build-$board.log 2>&1 || { tail -30 ../build-$board.log; exit 1; }; } &&
     grep -E '^Version|warning' ../build-$board.log || true"
check_bin "$B/klipper/out-$board/klipper.bin"
echo "built $board $ver -> printer:~/$B/klipper/out-$board/klipper.bin"
