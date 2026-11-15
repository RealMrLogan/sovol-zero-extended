#!/usr/bin/env bash
# Install this sovol-zero-extended release. Runs ON the printer, from the unpacked release folder.
# Usage: ./install.sh [--force-flash toolhead|mainboard]... [--no-flash]
#
# Flashes a board only if it reports a different firmware version than this release ships
# (or --force-flash). If Klipper does not come back after the host update, the previous
# klippy/ is restored automatically.
set -eEuo pipefail   # -E: the ERR trap below also fires inside functions
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
flash=""; declare -A was
for b in toolhead mainboard; do
    want=$(mf "d['boards']['$b']['version']"); have=$(running_version $b); was[$b]=$have
    if [[ $force == *" $b "* ]]; then flash+=" $b"; log "$b: flash forced (running: ${have:-unknown})"
    elif [ "$noflash" = 1 ]; then log "$b: skipped (--no-flash)"
    elif [ -z "$have" ]; then log "$b: running version unknown (Klipper not ready), not flashing; use --force-flash $b"
    elif [ "$have" != "$want" ]; then flash+=" $b"; log "$b: $have -> $want"
    else log "$b: already $want"
    fi
done

# upstream apps (apps.conf): work out what changes, and make sure every pin is at hand, before touching anything
log "checking upstream apps"
# shortcut: a pin that changes an app's Python or system dependencies is refused; install.sh would have to
# pip/apt install them (needs the network), so upgrade that app by hand or teach install.sh first
DEPS='(^|/)([^/]*requirements[^/]*\.txt|setup\.py|pyproject\.toml|system-dependencies\.json)$'
apps=(); dirty=""; restart=""; declare -A atype apin
while read -r name type _ _ pin services; do
    dir=$HOME/$name; atype[$name]=$type; apin[$name]=$pin; changed=0
    [ -e "$dir" ] || { log "$name: not installed, skipping"; continue; }
    if [ "$type" = git ]; then
        have=$(git -C "$dir" rev-parse HEAD)
        if [ "$have" != "$pin" ]; then
            git -C "$dir" cat-file -e "$pin^{commit}" 2>/dev/null ||
                { [ -f "apps/$name.bundle" ] && git -C "$dir" fetch -q "$PWD/apps/$name.bundle" zero-pin; } ||
                git -C "$dir" fetch -q origin "$pin" || true
            git -C "$dir" cat-file -e "$pin^{commit}" || { echo "$name: cannot get commit $pin"; exit 1; }
            if git -C "$dir" diff --name-only "$have" "$pin" | grep -qE "$DEPS"; then
                echo "$name: ${pin:0:7} changes its dependencies, which install.sh cannot install yet"; exit 1
            fi
            changed=1; log "$name: ${have:0:7} -> ${pin:0:7}"
        fi
        if ! git -C "$dir" diff --quiet HEAD; then dirty+=" $name"; log "$name: has local changes, will stash them"; fi
    elif rsync -rcni --delete --exclude=config.json "apps/$name/" "$dir/" | grep -q .; then
        changed=1; log "$name: differs from the release's build"
    fi
    if [ $changed = 1 ]; then apps+=("$name"); [ "$services" = - ] || restart+=" $services"; fi
done < <(grep -v '^\s*#' apps.conf | grep .)

sync_klippy() { rsync -rlptci --delete --exclude='*.pyc' --exclude=__pycache__ --exclude='*.so' "$@" klipper/klippy/ "$KLIPPER/klippy/"; }
# shortcut: Sovol disabled klippy's automatic c_helper.so rebuild, so refuse releases that change chelper C
# until install.sh builds it; "<f" = content differs (".f" = timestamp only)
if sync_klippy -n | grep -qE '^<f.* chelper/.*\.[ch]$'; then
    echo "this release changes klippy/chelper C code, which install.sh cannot rebuild yet"; exit 1
fi

prev=$(cat "$STATE/version" 2>/dev/null || echo unknown)
backup=$STATE/backup/$(date +%Y%m%d-%H%M%S)-from-$prev
log "backing up klippy/ to $backup"
mkdir -p "$backup" && cp -a "$KLIPPER/klippy" "$backup/"
ls -1d "$STATE"/backup/*/ | head -n -3 | xargs -r rm -rf          # keep the last 3

restart_services() {   # each on its own, so one bad unit can't stop the others restarting
    local s rc=0
    for s in klipper $restart; do sudo -n systemctl restart "$s" || rc=1; done
    return $rc
}
restore_host() {
    trap - ERR
    log "restoring the previous klippy/ and apps"
    rsync -a --delete "$backup/klippy/" "$KLIPPER/klippy/"
    if [ -f "$backup/apps.prev" ]; then
        while read -r name ref; do git -C "$HOME/$name" checkout -q "$ref" || log "$name: could not return to $ref"; done < "$backup/apps.prev"
    fi
    for d in "$backup"/apps/*/; do if [ -d "$d" ]; then rsync -a --delete "$d" "$HOME/$(basename "$d")/"; fi; done
    for name in $dirty; do git -C "$HOME/$name" stash pop -q || log "$name: local changes kept in git stash"; done
    restart_services || true
    wait_ready || true
}
# from here on, anything failing unexpectedly puts klippy/ and the apps back before install.sh exits
trap 'log "unexpected failure, rolling back"; restore_host' ERR

log "installing apps"
for name in "${apps[@]}"; do   # record every git app's branch/commit before changing any
    if [ "${atype[$name]}" = git ]; then
        echo "$name $(git -C "$HOME/$name" symbolic-ref -q --short HEAD || git -C "$HOME/$name" rev-parse HEAD)" >> "$backup/apps.prev"
    fi
done
for name in $dirty; do
    git -C "$HOME/$name" stash push -q -m "sovol-zero-extended $version: local changes"
    log "$name: local changes stashed (see them: git -C ~/$name stash show -p)"
done
for name in "${apps[@]}"; do
    if [ "${atype[$name]}" = git ]; then
        git -C "$HOME/$name" checkout -q --detach "${apin[$name]}"
    else
        mkdir -p "$backup/apps" && cp -a "$HOME/$name" "$backup/apps/"
        rsync -rc --delete --exclude=config.json "apps/$name/" "$HOME/$name/"   # keep the user's config.json
    fi
    log "$name: installed ${apin[$name]:0:12}"
done
if [ ${#apps[@]} = 0 ] && [ -z "$dirty" ]; then echo "(all apps already at their pins)"; fi

dropin=/etc/systemd/system/crowsnest.service.d/zero-extended.conf
if [ -f /etc/systemd/system/crowsnest.service ] && ! cmp -s systemd/crowsnest-zero.conf "$dropin"; then
    sudo -n install -D -m644 systemd/crowsnest-zero.conf "$dropin" && sudo -n systemctl daemon-reload
    log "crowsnest: start delay installed as a systemd drop-in"
fi

log "installing host code"
sync_klippy | grep -E '^(<f|\*deleting)' || echo "(no file changes)"

services_up() {
    local s
    for s in $restart; do
        for _ in $(seq 20); do systemctl is-active -q "$s" && continue 2; sleep 1.5; done
        echo "$s is not running"; return 1
    done
}
if ! restart_services || ! wait_ready || ! services_up; then
    log "Klipper or an app did not come back"; restore_host; exit 1
fi

# Flash one board (one retry, which also recovers a board left waiting in Katapult), then start
# Klipper and check the board reports the expected version. Klipper is stopped again on return.
flash_and_check() {   # board image expected-version
    ./flash-board.sh "$1" "$2" || { log "$1: flash failed, retrying"; ./flash-board.sh "$1" "$2"; } || return 1
    sudo -n systemctl start klipper
    local rc=1
    if wait_ready && [ "$(running_version "$1")" = "$3" ]; then rc=0; fi
    sudo -n systemctl stop klipper
    return $rc
}

if [ -n "$flash" ]; then
    mkdir -p "$STATE/firmware"           # last image flashed to each board, kept for rollback
    trap 'sudo -n systemctl start klipper' EXIT
    # toolhead first and verified before the mainboard, which is also the toolhead's only link to the host
    for b in toolhead mainboard; do
        [[ " $flash " == *" $b "* ]] || continue
        want=$(mf "d['boards']['$b']['version']")
        if [ -f "$STATE/firmware/$b.bin" ] && [ "$(cat "$STATE/firmware/$b.version")" = "${was[$b]}" ]; then
            old_img=$STATE/firmware/$b.bin; old_ver=${was[$b]}
        else
            old_img=$(mf "d['boards']['$b']['stock_file']"); old_ver=$(mf "d['boards']['$b']['stock_version']")
        fi
        sudo -n systemctl stop klipper
        if flash_and_check "$b" "firmware/$b.bin" "$want"; then
            cp "firmware/$b.bin" "$STATE/firmware/$b.bin"; echo "$want" > "$STATE/firmware/$b.version"
            log "$b now runs $want"
        else
            log "$b: new firmware did not come up; flashing back $old_ver"
            if flash_and_check "$b" "$old_img" "$old_ver"; then
                log "$b restored to $old_ver"
            else
                log "$b: ROLLBACK FAILED, see RECOVERY.md"
            fi
            restore_host
            exit 1
        fi
    done
    sudo -n systemctl start klipper; trap - EXIT
    wait_ready
fi

trap - ERR
echo "$version" > "$STATE/version"
cp manifest.json "$STATE/manifest.json"
log "installed sovol-zero-extended $version"
