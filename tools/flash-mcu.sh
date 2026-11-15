#!/usr/bin/env bash
# Flash the last build-mcu.sh image over Katapult. Usage: flash-mcu.sh toolhead|mainboard
set -euo pipefail
. "$(dirname "$0")/common.sh"
board_info "${1:-}"; board=$1
bin=$B/klipper/out-$board/klipper.bin
require_idle
check_bin "$bin"
if [ "$board" = mainboard ]; then
    echo "The mainboard is the USB-CAN bridge: a bad image cuts off BOTH boards (Katapult itself stays intact)."
    read -rp "Type 'mainboard' to flash it: " a; [ "$a" = mainboard ] || exit 1
fi
rsh "mkdir -p $B/flashed && cp $bin $B/flashed/$board-\$(date +%Y%m%d-%H%M%S).bin"   # history of every image flashed
rsh sudo -n systemctl stop klipper
trap 'rsh sudo -n systemctl start klipper' EXIT
case $board in
    toolhead)  rsh "$FLASH -i can0 -u 61755fe321ac -f $bin" ;;
    mainboard) rsh "$FLASH -i can0 -u 0d1445047cdd -r && for i in \$(seq 30); do
                    d=\$(ls /dev/serial/by-id/*katapult_stm32h750* 2>/dev/null) && break; sleep 0.5; done &&
                    [ -n \"\$d\" ] && $FLASH -d \$d -f $bin && sleep 3 && ip -br link show can0" ;;
esac
rsh sudo -n systemctl start klipper; trap - EXIT
wait_ready
rsh 'curl -s "localhost:7125/printer/objects/query?mcu&mcu%20extruder_mcu"' |
    jq_py '"\n".join("%s: %s" % (k, v["mcu_version"]) for k, v in d["result"]["status"].items())'
