# Shared helpers for the tools/ scripts. Override the printer with PRINTER=user@host.
PRINTER=${PRINTER:-sovol@192.168.1.130}
ROOT=$(cd "$(dirname "$0")/.." && pwd)
WORK=$ROOT/work
B=zero-build                      # build/flash scratch dir in the printer's home
FLASH='~/klippy-env/bin/python ~/printer_data/build/flash_can.py'   # Sovol's Katapult flashtool (needs pyserial, which klippy-env has)

export RSYNC_RSH="ssh -o LogLevel=ERROR"
rsh() { ssh -o LogLevel=ERROR "$PRINTER" "$@"; }
jq_py() { python3 -c "import json,sys; d=json.load(sys.stdin); print($1)" 2>/dev/null; }

need_work() { [ -d "$WORK" ] || { echo "no work/ tree: run tools/setup.sh first"; exit 1; }; }

require_idle() {
    local s
    s=$(rsh 'curl -s localhost:7125/printer/objects/query?print_stats' | jq_py 'd["result"]["status"]["print_stats"]["state"]') || true
    case $s in
        printing|paused) echo "printer is $s: refusing"; exit 1 ;;
        "") echo "warning: could not read print state (Klipper not ready?), continuing" ;;
    esac
}

wait_ready() {
    local s i
    for i in $(seq 45); do
        s=$(rsh 'curl -s localhost:7125/printer/info' | jq_py 'd["result"]["state"]') || true
        [ "$s" = ready ] && { echo "klipper: ready"; return 0; }
        sleep 2
    done
    echo "klipper: NOT ready (state: ${s:-unknown}). Last log lines:"
    rsh 'tail -25 ~/printer_data/logs/klippy.log'
    return 1
}

board_info() {   # sets CFG, APP_START for $1
    case $1 in
        toolhead)  APP_START=0x08002000 ;;   # 8 KiB Katapult, CAN
        mainboard) APP_START=0x08020000 ;;   # 128 KiB Katapult, USB (confirmed 2026-11-14)
        *) echo "board must be toolhead or mainboard"; exit 1 ;;
    esac
    CFG=$ROOT/configs/$1.config
}

check_bin() {    # refuse an image whose reset vector is outside the app area (wrong offset = unbootable board)
    local rv
    rv=$(rsh "od -An -tx4 -j4 -N4 $1" | tr -d ' \n')
    [ -n "$rv" ] || { echo "cannot read $1"; exit 1; }
    if (( 16#$rv < APP_START || 16#$rv >= APP_START + 0x100000 )); then
        echo "REFUSING: reset vector 0x$rv is not after $APP_START"; exit 1
    fi
    echo "image ok: reset vector 0x$rv (app start $APP_START)"
}
