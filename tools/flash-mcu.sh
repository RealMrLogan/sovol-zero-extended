#!/usr/bin/env bash
# Flash over Katapult. Usage: flash-mcu.sh toolhead|mainboard [local.bin]
# Without a file it flashes the last build-mcu.sh image; with one (e.g. stock-firmware/*.bin) it uploads and flashes that.
set -euo pipefail
. "$(dirname "$0")/common.sh"
board=${1:?usage: flash-mcu.sh toolhead|mainboard [local.bin]}
bin=$B/out/$board.bin
rsh "mkdir -p $B"
rsync -t "$ROOT/release/flash-board.sh" "$PRINTER:$B/"
if [ -n "${2:-}" ]; then
    rsync -t "$2" "$PRINTER:$B/upload-$board.bin"   # own line: a failure here must stop, not flash the last build
    bin=$B/upload-$board.bin
fi
require_idle
if [ "$board" = mainboard ]; then
    echo "The mainboard is the USB-CAN bridge: a bad image cuts off BOTH boards (Katapult itself stays intact)."
    read -rp "Type 'mainboard' to flash it: " a; [ "$a" = mainboard ] || exit 1
fi
rsh "mkdir -p $B/flashed && cp $bin $B/flashed/$board-\$(date +%Y%m%d-%H%M%S).bin"   # history of every image flashed
rsh sudo -n systemctl stop klipper
trap 'rsh sudo -n systemctl start klipper' EXIT
rsh "$B/flash-board.sh $board $bin"
rsh sudo -n systemctl start klipper; trap - EXIT
wait_ready
rsh 'curl -s "localhost:7125/printer/objects/query?mcu&mcu%20extruder_mcu"' |
    jq_py '"\n".join("%s: %s" % (k, v["mcu_version"]) for k, v in d["result"]["status"].items())'
