#!/usr/bin/env bash
# Build board firmware from work/ on the printer (Sovol's gcc 8.3.1). Usage: build-mcu.sh toolhead|mainboard
set -euo pipefail
. "$(dirname "$0")/common.sh"
need_work
board=${1:?usage: build-mcu.sh toolhead|mainboard}
ver=$(git -C "$WORK" describe --always --tags --long --dirty)
rsh "mkdir -p $B"
rsync -rlpt --delete --exclude=/.git --exclude='*.pyc' --exclude=__pycache__ "$WORK/" "$PRINTER:$B/klipper/"
rsync -rt "$ROOT/tools" "$ROOT/configs" "$PRINTER:$B/"
rsh "$B/tools/build-firmware.sh $B/klipper $board $B/out '$ver'"
echo "built printer:~/$B/out/$board.bin"
