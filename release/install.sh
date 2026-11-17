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
PRINTER_CFG=$HOME/printer_data/config/printer.cfg
PATCH_CFG=$HOME/patch/config/printer.cfg   # Sovol's copy, restored by the display's factory reset
OUR_CFG=$HOME/printer_data/config/zero-extended
ROOT=${ZX_ROOT:-}   # tests/install-test.sh only: a fake / for the /etc and /boot files
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
wait_ready() {   # a host restart can't clear an MCU shutdown (e.g. a startup race in klippy), so try one FIRMWARE_RESTART
    local s fw=0
    for _ in $(seq 45); do
        s=$(klipper_state); [ "$s" = ready ] && return 0
        if [[ $s == shutdown || $s == error ]] && [ $fw = 0 ]; then
            fw=1; echo "Klipper is in $s, trying FIRMWARE_RESTART"; curl -sf -X POST http://localhost:7125/printer/firmware_restart >/dev/null || true
        fi
        sleep 2
    done
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
            files=$(git -C "$dir" diff --name-only "$have" "$pin")   # not piped into grep -q: SIGPIPE + pipefail
            if grep -qE "$DEPS" <<<"$files"; then
                echo "$name: ${pin:0:7} changes its dependencies, which install.sh cannot install yet"; exit 1
            fi
            changed=1; log "$name: ${have:0:7} -> ${pin:0:7}"
        fi
        if ! git -C "$dir" diff --quiet HEAD; then dirty+=" $name"; log "$name: has local changes, will stash them"; fi
    else
        diffs=$(rsync -rcni --delete --exclude=config.json "apps/$name/" "$dir/")
        if [ -n "$diffs" ]; then changed=1; log "$name: differs from the release's build"; fi
    fi
    if [ $changed = 1 ]; then apps+=("$name"); [ "$services" = - ] || restart+=" $services"; fi
done < <(grep -v '^\s*#' apps.conf | grep .)

sync_klippy() { rsync -rlptci --delete --exclude='*.pyc' --exclude=__pycache__ --exclude='*.so' --exclude=.version "$@" klipper/klippy/ "$KLIPPER/klippy/"; }
# shortcut: Sovol disabled klippy's automatic c_helper.so rebuild, so refuse releases that change chelper C
# until install.sh builds it; ">f" = content differs (".f" = timestamp only)
pending=$(sync_klippy -n)
if grep -qE '^>f.* chelper/.*\.[ch]$' <<<"$pending"; then
    echo "this release changes klippy/chelper C code, which install.sh cannot rebuild yet"; exit 1
fi

prev=$(cat "$STATE/version" 2>/dev/null || echo unknown)
backup=$STATE/backup/$(date +%Y%m%d-%H%M%S)-from-$prev
log "backing up klippy/ to $backup"
mkdir -p "$backup"
cp -a "$KLIPPER/klippy" "$backup/"
ls -1d "$STATE"/backup/*/ | head -n -3 | xargs -r rm -rf          # keep the last 3

restart_services() {   # each on its own, so one bad unit can't stop the others restarting
    local s rc=0
    for s in klipper $restart; do sudo -n systemctl restart "$s" || rc=1; done
    return $rc
}
# Undoes klippy/, the apps, the config page and zero-extended.cfg. Left as installed on purpose: the crowsnest
# drop-in, the zero-config unit and nginx snippet (both compatible with older releases) and the Sovol updater
# removal (one-way).
restore_host() {   # rsync -c: a release file can match the backup's size and mtime
    trap - ERR
    log "restoring the previous klippy/ and apps"
    rsync -ac --delete "$backup/klippy/" "$KLIPPER/klippy/"
    if [ -f "$backup/apps.prev" ]; then
        while read -r name ref; do git -C "$HOME/$name" checkout -q "$ref" || log "$name: could not return to $ref"; done < "$backup/apps.prev"
    fi
    for d in "$backup"/apps/*/; do if [ -d "$d" ]; then rsync -ac --delete "$d" "$HOME/$(basename "$d")/"; fi; done
    for name in $stashed; do git -C "$HOME/$name" stash pop -q || log "$name: local changes kept in git stash"; done
    if [ -d "$backup/zero-config" ]; then rsync -ac --delete "$backup/zero-config/" "$STATE/zero-config/"; fi
    if [ -f "$backup/klipper-config/printer.cfg" ]; then   # a bad zero-extended.cfg would keep Klipper down
        cp -p "$backup/klipper-config/printer.cfg" "$PRINTER_CFG"
        if [ -f "$backup/klipper-config/patch-printer.cfg" ]; then cp -p "$backup/klipper-config/patch-printer.cfg" "$PATCH_CFG"; fi
        rm -rf "$OUR_CFG"
        if [ -d "$backup/klipper-config/zero-extended" ]; then cp -a "$backup/klipper-config/zero-extended" "$OUR_CFG"; fi
    fi
    restart_services || true
    wait_ready || true
}
stashed=""   # apps whose local changes this run stashed: the only stashes restore_host may pop
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
    stashed+=" $name"
    log "$name: local changes stashed (see them: git -C ~/$name stash show -p)"
done
for name in "${apps[@]}"; do
    if [ "${atype[$name]}" = git ]; then
        git -C "$HOME/$name" checkout -q --detach "${apin[$name]}"
    else
        mkdir -p "$backup/apps"
        cp -a "$HOME/$name" "$backup/apps/"
        rsync -rc --delete --exclude=config.json "apps/$name/" "$HOME/$name/"   # keep the user's config.json
    fi
    log "$name: installed ${apin[$name]:0:12}"
done
if [ ${#apps[@]} = 0 ] && [ -z "$dirty" ]; then echo "(all apps already at their pins)"; fi

dropin=$ROOT/etc/systemd/system/crowsnest.service.d/zero-extended.conf
if [ -f "$ROOT"/etc/systemd/system/crowsnest.service ] && ! cmp -s systemd/crowsnest-zero.conf "$dropin"; then
    sudo -n install -D -m644 systemd/crowsnest-zero.conf "$dropin"
    sudo -n systemctl daemon-reload
    log "crowsnest: start delay installed as a systemd drop-in"
fi

# config page (zero-config/): served by its own service on localhost, reached through nginx at /extended/
if [ -d "$STATE/zero-config" ]; then cp -a "$STATE/zero-config" "$backup/"; fi
page_changes=$(rsync -rci --delete --exclude=__pycache__ zero-config/ "$STATE/zero-config/")
if [ -n "$page_changes" ]; then
    restart+=" zero-config"; log "config page: updated"
fi
unit=$(sed "s|@USER@|$(id -un)|; s|@HOME@|$HOME|" zero-config/zero-config.service)
if [ "$unit" != "$(cat "$ROOT"/etc/systemd/system/zero-config.service 2>/dev/null)" ]; then
    echo "$unit" | sudo -n tee "$ROOT"/etc/systemd/system/zero-config.service >/dev/null
    sudo -n systemctl daemon-reload
    sudo -n systemctl enable -q zero-config
    restart+=" zero-config"; log "config page: service installed"
fi
site=$ROOT/etc/nginx/sites-available/mainsail; snippet=$ROOT/etc/nginx/snippets/zero-extended.conf
if ! cmp -s zero-config/nginx.conf "$snippet" || ! grep -q "include $snippet;" "$site"; then
    cp "$site" "$backup/nginx-mainsail"
    sudo -n install -D -m644 zero-config/nginx.conf "$snippet"
    grep -q "include $snippet;" "$site" || sudo -n sed -i "/server_name _;/a\    include $snippet;" "$site"
    if ! sudo -n nginx -t -q; then
        sudo -n cp "$backup/nginx-mainsail" "$site"; echo "nginx rejected the config page snippet"; false
    fi
    sudo -n systemctl reload nginx; log "config page: nginx set up at /extended/"
fi

# Sovol's updaters work around this installer (no version check, no rollback); releases come from /extended/
# only. OTA: ota_service.sh, started at boot by btt_init.sh, installs Sovol's package when _OTA signals it.
# _MCU_UP / _EXTRUDER_MCU_UP / _EXTRA_MCU_UP: flash a board with whatever image the OTA package left behind.
boot=$ROOT/boot/scripts/btt_init.sh
if grep -qs 'ota_service\.sh' "$boot"; then
    sudo -n sed -i '/ota_service\.sh/d' "$boot"; log "Sovol updaters: OTA removed from boot"
fi
# the pattern can't match this pkill's own command line (its "\." isn't ".")
if sudo -n pkill -f '\./ota_service\.sh$'; then log "Sovol updaters: OTA stopped"; fi
build=$HOME/printer_data/build   # keep flash_can.py: flash-board.sh uses it
for f in "$ROOT"/boot/scripts/ota_service.sh "$HOME/ota_client.sh" "$HOME/pyhelper/ota_process.py" "$build/mcu_update_fw.sh" \
         "$build/extruder_mcu_update_fw.sh" "$build/extra_mcu_update_fw.sh" "$build/extruder_mcu_klipper.bin"; do
    if [ -e "$f" ]; then sudo -n rm -f "$f"; log "Sovol updaters: removed $f"; fi
done
# their macros, from the live config and from Sovol's copy that the display's factory reset restores
# (backed up for reference only: putting them back would re-add macros calling the scripts deleted above)
for cfg in "$HOME/printer_data/config/get_ip.cfg" "$HOME/patch/config/get_ip.cfg"; do
    [ -f "$cfg" ] || continue
    cp -p "$cfg" "$backup/$(echo "${cfg#"$HOME"/}" | tr / _)"
    if python3 - "$cfg" <<'EOF'
import sys
drop = {"[gcode_shell_command %s]" % c for c in ("ota", "mcu_up", "extruder_mcu_up", "extra_mcu_up")}
drop |= {"[gcode_macro %s]" % m for m in ("_OTA", "_MCU_UP", "_EXTRUDER_MCU_UP", "_EXTRA_MCU_UP")}
lines = open(sys.argv[1], newline="").read().splitlines(True)   # newline="": keep its CRLFs
out, skip = [], False
for line in lines:
    if line.startswith("["):        # a section runs from its header to the next one
        skip = line.strip() in drop
    if not skip:
        out.append(line)
if len(out) == len(lines):
    sys.exit(1)                     # nothing to remove: no log line
open(sys.argv[1], "w", newline="").write("".join(out))
EOF
    then log "Sovol updaters: macros removed from ${cfg#"$HOME"/}"; fi
done

# zero-extended.cfg: our Klipper settings (full resonance test range, damping, the page's motor current and
# acceleration settings), included at the end of printer.cfg and of Sovol's factory-reset copy, so it wins
# over Sovol's values and survives a factory reset. See zero-config/tuning.py. Rolled back with the host.
mkdir -p "$backup/klipper-config"
cp -p "$PRINTER_CFG" "$backup/klipper-config/printer.cfg"
if [ -f "$PATCH_CFG" ]; then cp -p "$PATCH_CFG" "$backup/klipper-config/patch-printer.cfg"; fi
if [ -d "$OUR_CFG" ]; then cp -a "$OUR_CFG" "$backup/klipper-config/"; fi
tuned=$(cd "$STATE/zero-config" && python3 tuning.py install "$PRINTER_CFG" "$PATCH_CFG")
if [ -n "$tuned" ]; then log "Klipper settings: $tuned"; fi

log "installing host code"
synced=$(sync_klippy)   # captured, so a failing rsync triggers the rollback instead of reading as "no changes"
grep -E '^(>f|\*deleting)' <<<"$synced" || echo "(no file changes)"

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

# Boards belong to the install: if one fails, every board flashed so far goes back to its previous image
# (newest first) and then the host, so old host code never runs against new board firmware.
declare -A old_img old_ver; flashed=""
rollback_all() {
    trap - ERR
    local b
    for b in $flashed; do
        log "$b: flashing back ${old_ver[$b]}"
        if flash_and_check "$b" "${old_img[$b]}" "${old_ver[$b]}"; then
            cp "${old_img[$b]}" "$STATE/firmware/$b.bin"; echo "${old_ver[$b]}" > "$STATE/firmware/$b.version"
            log "$b restored to ${old_ver[$b]}"
        else
            log "$b: ROLLBACK FAILED, see RECOVERY.md"
        fi
    done
    restore_host
}

if [ -n "$flash" ]; then
    mkdir -p "$STATE/firmware" "$backup/firmware"   # $STATE/firmware: last image flashed to each board
    trap 'sudo -n systemctl start klipper' EXIT
    trap 'log "unexpected failure, rolling back"; rollback_all' ERR
    # toolhead first and verified before the mainboard, which is also the toolhead's only link to the host
    for b in toolhead mainboard; do
        [[ " $flash " == *" $b "* ]] || continue
        want=$(mf "d['boards']['$b']['version']")
        # the previous image, copied: $STATE/firmware/$b.bin is overwritten once this board succeeds
        if [ -f "$STATE/firmware/$b.bin" ] && [ "$(cat "$STATE/firmware/$b.version")" = "${was[$b]}" ]; then
            cp "$STATE/firmware/$b.bin" "$backup/firmware/$b.bin"; old_ver[$b]=${was[$b]}
        else
            cp "$(mf "d['boards']['$b']['stock_file']")" "$backup/firmware/$b.bin"; old_ver[$b]=$(mf "d['boards']['$b']['stock_version']")
        fi
        old_img[$b]=$backup/firmware/$b.bin
        flashed="$b $flashed"   # before flashing: a failed flash can leave the board anywhere
        sudo -n systemctl stop klipper
        if ! flash_and_check "$b" "firmware/$b.bin" "$want"; then
            log "$b: new firmware did not come up"; rollback_all; exit 1
        fi
        cp "firmware/$b.bin" "$STATE/firmware/$b.bin"; echo "$want" > "$STATE/firmware/$b.version"
        log "$b now runs $want"
    done
    sudo -n systemctl start klipper; trap - EXIT
    if ! wait_ready; then log "Klipper did not come back after flashing"; rollback_all; exit 1; fi
fi

trap - ERR
echo "$version" > "$STATE/version"
cp manifest.json "$STATE/manifest.json"
log "installed sovol-zero-extended $version"
