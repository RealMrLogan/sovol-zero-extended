# shellcheck shell=bash disable=SC2034   # sourced by the tools/ scripts, which use its variables
# Shared helpers for the tools/ scripts. Override the printer with PRINTER=user@host.
PRINTER=${PRINTER:-sovol@192.168.1.130}
ROOT=$(cd "$(dirname "$0")/.." && pwd)
WORK=$ROOT/work
B=zero-build                      # build/flash scratch dir in the printer's home

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

wait_ready() {   # like install.sh's: one FIRMWARE_RESTART clears an MCU shutdown left by a klippy startup race
    local s fw=0
    for _ in $(seq 45); do
        s=$(rsh 'curl -s localhost:7125/printer/info' | jq_py 'd["result"]["state"]') || true
        [ "$s" = ready ] && { echo "klipper: ready"; return 0; }
        if [[ $s == shutdown || $s == error ]] && [ $fw = 0 ]; then
            fw=1; echo "klipper: $s, trying FIRMWARE_RESTART"
            rsh 'curl -sf -X POST localhost:7125/printer/firmware_restart >/dev/null' || true
        fi
        sleep 2
    done
    echo "klipper: NOT ready (state: ${s:-unknown}). Last log lines:"
    rsh 'tail -25 ~/printer_data/logs/klippy.log'
    return 1
}
