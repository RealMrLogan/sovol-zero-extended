#!/usr/bin/env bash
# Install this sovol-zero-extended release. Runs ON the printer, from the unpacked release folder.
# Usage: ./install.sh [--force-flash toolhead|mainboard]... [--no-flash]
#
# Flashes a board only if it reports a different firmware version than this release ships
# (or --force-flash). If Klipper does not come back after the host update, the previous
# klippy/ is restored automatically.
set -euo pipefail
cd "$(dirname "$0")"
KLIPPER=$HOME/klipper
STATE=$HOME/zero-extended          # installed version, manifest, backups, install.log
mkdir -p "$STATE/backup"
exec > >(tee -a "$STATE/install.log") 2>&1

force=" "; noflash=0
while [ $# -gt 0 ]; do
    case $1 in
        --force-flash) force+="${2:?board} "; shift 2 ;;
        --no-flash) noflash=1; shift ;;
        *) echo "unknown option: $1"; exit 2 ;;
    esac
done

log() { echo "==> $*"; }
mf() { python3 -c "import json; d=json.load(open('manifest.json')); print($1)"; }
moon() { curl -sf "http://localhost:7125/$1"; }
klipper_state() { moon printer/info | python3 -c 'import json,sys; print(json.load(sys.stdin)["result"]["state"])' 2>/dev/null || echo down; }
wait_ready() {
    local s
    for _ in $(seq 45); do s=$(klipper_state); [ "$s" = ready ] && return 0; sleep 2; done
    echo "Klipper state: $s"; tail -20 "$HOME/printer_data/logs/klippy.log"; return 1
}
running_version() {   # board -> mcu_version reported by the running firmware
    local obj; [ "$1" = mainboard ] && obj=mcu || obj="mcu extruder_mcu"
    moon "printer/objects/query?${obj// /%20}" |
        python3 -c "import json,sys; print(json.load(sys.stdin)['result']['status']['$obj']['mcu_version'])" 2>/dev/null || true
}

version=$(mf 'd["version"]')
log "$(date '+%F %T') installing sovol-zero-extended $version"

log "verifying files"
sha256sum --quiet -c SHA256SUMS

state=$(moon 'printer/objects/query?print_stats' |
    python3 -c 'import json,sys; print(json.load(sys.stdin)["result"]["status"]["print_stats"]["state"])' 2>/dev/null || echo unknown)
case $state in printing|paused) echo "printer is $state: refusing to install"; exit 1 ;; esac

# decide which boards need flashing while Klipper can still tell us what they run
flash=""
for b in toolhead mainboard; do
    want=$(mf "d['boards']['$b']['version']"); have=$(running_version $b)
    if [[ $force == *" $b "* ]]; then flash+=" $b"; log "$b: flash forced (running: ${have:-unknown})"
    elif [ "$noflash" = 1 ]; then log "$b: skipped (--no-flash)"
    elif [ -z "$have" ]; then log "$b: running version unknown (Klipper not ready), not flashing; use --force-flash $b"
    elif [ "$have" != "$want" ]; then flash+=" $b"; log "$b: $have -> $want"
    else log "$b: already $want"
    fi
done

prev=$(cat "$STATE/version" 2>/dev/null || echo unknown)
backup=$STATE/backup/$(date +%Y%m%d-%H%M%S)-from-$prev
log "backing up klippy/ to $backup"
mkdir -p "$backup" && cp -a "$KLIPPER/klippy" "$backup/"
ls -1d "$STATE"/backup/*/ | head -n -3 | xargs -r rm -rf          # keep the last 3

log "installing host code"
sync_klippy() { rsync -rlptci --delete --exclude='*.pyc' --exclude=__pycache__ --exclude='*.so' "$@" klipper/klippy/ "$KLIPPER/klippy/"; }
# shortcut: Sovol disabled klippy's automatic c_helper.so rebuild, so refuse releases that change chelper C
# until install.sh builds it; "<f" = content differs (".f" = timestamp only)
if sync_klippy -n | grep -qE '^<f.* chelper/.*\.[ch]$'; then
    echo "this release changes klippy/chelper C code, which install.sh cannot rebuild yet"; exit 1
fi
sync_klippy | grep -E '^(<f|\*deleting)' || echo "(no file changes)"

sudo -n systemctl restart klipper
if ! wait_ready; then
    log "Klipper did not come back: restoring the previous klippy/"
    rsync -a --delete "$backup/klippy/" "$KLIPPER/klippy/"
    sudo -n systemctl restart klipper
    wait_ready || true
    exit 1
fi

if [ -n "$flash" ]; then
    sudo -n systemctl stop klipper
    trap 'sudo -n systemctl start klipper' EXIT
    for b in toolhead mainboard; do      # toolhead first: if the mainboard flash fails, both boards are offline
        if [[ " $flash " == *" $b "* ]]; then ./flash-board.sh "$b" "firmware/$b.bin"; fi
    done
    sudo -n systemctl start klipper; trap - EXIT
    wait_ready
    for b in $flash; do
        want=$(mf "d['boards']['$b']['version']"); have=$(running_version $b)
        [ "$have" = "$want" ] && log "$b now runs $have" || { log "$b reports '$have', expected '$want'"; exit 1; }
    done
fi

echo "$version" > "$STATE/version"
cp manifest.json "$STATE/manifest.json"
log "installed sovol-zero-extended $version"
