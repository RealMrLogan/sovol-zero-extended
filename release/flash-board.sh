#!/usr/bin/env bash
# Flash one board over Katapult. Runs ON the printer, with Klipper stopped.
# Usage: flash-board.sh toolhead|mainboard <image.bin>
set -euo pipefail
board=${1:-}; bin=${2:-}
FLASH="$HOME/klippy-env/bin/python $HOME/printer_data/build/flash_can.py"   # Sovol's Katapult flashtool; klippy-env has pyserial

case $board in
    toolhead)  start=0x08002000; uuid=61755fe321ac ;;   # 8 KiB Katapult, CAN
    mainboard) start=0x08020000; uuid=0d1445047cdd ;;   # 128 KiB Katapult, USB-CAN bridge
    *) echo "usage: $0 toolhead|mainboard image.bin"; exit 2 ;;
esac
[ -f "$bin" ] || { echo "no such image: $bin"; exit 1; }

# a wrong start address makes the board unbootable: refuse images whose reset vector is outside the app area
rv=$(od -An -tx4 -j4 -N4 "$bin" | tr -d ' \n')
if (( 16#$rv < start || 16#$rv >= start + 0x100000 )); then
    echo "REFUSING $bin: reset vector 0x$rv is not in the $board app area at $start"; exit 1
fi

if systemctl is-active -q klipper; then echo "stop Klipper first"; exit 1; fi

echo "flashing $board ($(stat -c %s "$bin") bytes, reset vector 0x$rv)"
if [ "$board" = toolhead ]; then
    # Sovol's firmware pins Klipper's CAN uuid; Katapult answers on the chip's real one (unique per board), so find it
    $FLASH -i can0 -u $uuid -r
    sleep 1
    katapult=$($FLASH -i can0 -q 2>&1 | sed -n 's/.*UUID: \([0-9a-f]*\), Application: Katapult.*/\1/p')
    [ "$(echo "$katapult" | grep -c .)" = 1 ] || { echo "expected one Katapult node on can0, found: '${katapult//$'\n'/ }'"; exit 1; }
    echo "toolhead Katapult uuid: $katapult"
    $FLASH -i can0 -u "$katapult" -f "$bin"
else
    # a mainboard already in Katapult (e.g. an interrupted flash) has no can0 to send the request on
    katapult_dev() { ls /dev/serial/by-id/*katapult_stm32h750* 2>/dev/null; }
    katapult_dev >/dev/null || $FLASH -i can0 -u $uuid -r
    dev=
    for _ in $(seq 30); do
        dev=$(katapult_dev) && break
        sleep 0.5
    done
    [ -n "$dev" ] || { echo "mainboard did not enter Katapult"; exit 1; }
    $FLASH -d "$dev" -f "$bin"
    for _ in $(seq 20); do ip link show can0 >/dev/null 2>&1 && break; sleep 0.5; done   # bridge re-creates can0
fi
