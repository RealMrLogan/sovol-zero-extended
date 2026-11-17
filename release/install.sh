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

log() { echo "==> $(date +%T) $*"; }
manifest() { python3 -c "import json; d=json.load(open('manifest.json')); print($1)"; }
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

version=$(manifest 'd["version"]')
log "installing sovol-zero-extended $version ($(date +%F))"

log "verifying files"
sha256sum --quiet -c SHA256SUMS
. ./sovol-cleanup.sh   # one-way removals of Sovol's leftovers, called below; sourced once verified

state=$(moon 'printer/objects/query?print_stats' |
    python3 -c 'import json,sys; print(json.load(sys.stdin)["result"]["status"]["print_stats"]["state"])' 2>/dev/null || echo unknown)
case $state in printing|paused) echo "printer is $state: refusing to install"; exit 1 ;; esac

# decide which boards need flashing while Klipper can still tell us what they run
flash=""; declare -A was
for b in toolhead mainboard; do
    want=$(manifest "d['boards']['$b']['version']"); have=$(running_version $b); was[$b]=$have
    if [[ $force == *" $b "* ]]; then flash+=" $b"; log "$b: flash forced (running: ${have:-unknown})"
    elif [ "$noflash" = 1 ]; then log "$b: skipped (--no-flash)"
    elif [ -z "$have" ]; then log "$b: running version unknown (Klipper not ready), not flashing; use --force-flash $b"
    elif [ "$have" != "$want" ]; then flash+=" $b"; log "$b: $have -> $want"
    else log "$b: already $want"
    fi
done

# upstream apps (apps.conf): work out what changes, and make sure every pin is at hand, before touching anything
log "checking upstream apps"
# Python requirements (apps.conf pip column) are installed from the release's wheels. System packages only
# from debs.conf: make-release refuses a pin that changes them, unless they were checked (release/sysdeps-checked).
apps=(); dirty=""; restart=""; pipapps=""; declare -A atype apin apip
restart_add() { [[ " $restart " == *" $1 "* ]] || restart+=" $1"; }   # services to restart, each once
while read -r name type _ _ pin services pip; do
    dir=$HOME/$name; atype[$name]=$type; apin[$name]=$pin; apip[$name]=$pip; changed=0
    [ -e "$dir" ] || { log "$name: not installed, skipping"; continue; }
    if [ "$type" = git ]; then
        have=$(git -C "$dir" rev-parse HEAD)
        if [ "$have" != "$pin" ]; then
            git -C "$dir" cat-file -e "$pin^{commit}" 2>/dev/null ||
                { [ -f "apps/$name.bundle" ] && git -C "$dir" fetch -q "$PWD/apps/$name.bundle" zero-pin; } ||
                git -C "$dir" fetch -q origin "$pin" || true
            git -C "$dir" cat-file -e "$pin^{commit}" || { echo "$name: cannot get commit $pin"; exit 1; }
            files=$(git -C "$dir" diff --name-only "$have" "$pin")   # not piped into grep -q: SIGPIPE + pipefail
            if [ "$pip" != - ] && grep -qxF "${pip#*:}" <<<"$files"; then
                [ -d apps/wheels ] || { echo "$name: ${pin:0:7} changes its Python requirements, and the release has no wheels"; exit 1; }
                pipapps+=" $name"; log "$name: Python requirements change"
            fi
            changed=1; log "$name: ${have:0:7} -> ${pin:0:7}"
        fi
        if ! git -C "$dir" diff --quiet HEAD; then dirty+=" $name"; log "$name: has local changes, will stash them"; fi
    else
        diffs=$(rsync -rcni --delete --exclude=config.json "apps/$name/" "$dir/")
        if [ -n "$diffs" ]; then changed=1; log "$name: differs from the release's build"; fi
    fi
    if [ $changed = 1 ]; then apps+=("$name"); [ "$services" = - ] || restart_add "$services"; fi
done < <(grep -v '^\s*#' apps.conf | grep .)

# system packages (debs.conf), from the release's .debs: only missing ones are added, and only if their
# dependencies are already installed. The rollback purges them again.
debs=""; debfiles=(); declare -A deb_had   # deb_had[package]: its dpkg state before ("c": config files left)
while read -r pkg ver _ url; do
    have=$(dpkg-query -W -f='${db:Status-Abbrev}${Version}' "$pkg" 2>/dev/null || true)   # e.g. "ii 1.0", "hi 1.0", "rc 1.0"
    state=${have:1:1}   # n: not installed, c: only its config files, i: installed (also when held); else half-installed
    if [ "$state" = i ] && [ "${have:3}" = "$ver" ]; then continue; fi
    # shortcut: no upgrades or repairs of a package that's there (the rollback would need its old .deb); add them when one is needed
    if [ -n "$state" ] && [ "$state" != n ] && [ "$state" != c ]; then
        echo "$pkg ${have:3} is installed, the release ships $ver: install.sh only adds missing packages (dpkg: ${have:0:2})"; exit 1
    fi
    deb_had[$pkg]=$state; debs+=" $pkg"; debfiles+=("debs/${url##*/}"); log "$pkg: will install $ver"
done < <(grep -v '^\s*#' debs.conf | grep .)
if [ -n "$debs" ]; then   # dpkg --dry-run doesn't check dependencies; apt's simulation does, and must add nothing else
    sim=$(apt-get -s -o Debug::NoLocking=1 install --no-install-recommends "${debfiles[@]/#/$PWD/}" 2>&1) || true
    planned=$(awk '$1 == "Inst" || $1 == "Remv" {print $1, $2}' <<<"$sim" | sort)
    if [ "$planned" != "$(printf 'Inst %s\n' $debs | sort)" ]; then
        echo "can't install$debs from the release alone:"; grep -E '^(Inst|Remv|E:)' <<<"$sim" || true; exit 1
    fi
fi

sync_klippy() { rsync -rlptci --delete --exclude='*.pyc' --exclude=__pycache__ --exclude='*.so' --exclude=.version klipper/klippy/ "$KLIPPER/klippy/"; }

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
replaced=()   # files replace() changed; the previous copy of each is in $backup/files<its path>
ORIGINALS=$STATE/originals   # and the copy from before any release first changed it, kept for good (backups rotate)
replace() {   # file content: write content to file as root, keeping the old file for restore_host
    mkdir -p "$backup/files$(dirname "$1")"; sudo -n cp -p "$1" "$backup/files$1"
    if [ ! -e "$ORIGINALS$1" ]; then mkdir -p "$ORIGINALS$(dirname "$1")"; sudo -n cp -p "$1" "$ORIGINALS$1"; fi
    replaced+=("$1")
    printf '%s\n' "$2" | sudo -n tee "$1" >/dev/null
}
# Undoes klippy/, the apps and their system packages, service files, the config page and zero-extended.cfg.
# Left as installed on purpose: the crowsnest drop-in, the zero-config unit and nginx snippet (both compatible
# with older releases) and the Sovol updater removal (one-way).
restore_host() {   # rsync -c: a release file can match the backup's size and mtime
    trap - ERR
    log "restoring the previous klippy/ and apps"
    rsync -ac --delete "$backup/klippy/" "$KLIPPER/klippy/"
    local f
    for f in "${replaced[@]}"; do sudo -n cp -p "$backup/files$f" "$f" || log "$f: could not restore it"; done
    if [ ${#replaced[@]} -gt 0 ]; then sudo -n systemctl daemon-reload || log "systemd: daemon-reload failed"; fi
    for p in $debs_added; do   # purged, unless its config files were there before: those stay, as they were
        if [ "${deb_had[$p]}" = c ]; then mode=-r; else mode=-P; fi
        sudo -n dpkg "$mode" "$p" >/dev/null || log "$p: could not remove it"
    done
    if [ -f "$backup/apps.prev" ]; then
        while read -r name ref; do git -C "$HOME/$name" checkout -q "$ref" || log "$name: could not return to $ref"; done < "$backup/apps.prev"
    fi
    for d in "$backup"/apps/*/; do if [ -d "$d" ]; then rsync -ac --delete "$d" "$HOME/$(basename "$d")/"; fi; done
    for name in $pipapps; do   # venvs/<app>: the app's venv before pip changed it
        if [ -d "$backup/venvs/$name" ]; then rsync -ac --delete "$backup/venvs/$name/" "$HOME/${apip[$name]%%:*}/"; fi
    done
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
debs_added=""   # packages this run installed: the only ones restore_host purges
# from here on, anything failing unexpectedly puts klippy/ and the apps back before install.sh exits
trap 'log "unexpected failure, rolling back"; restore_host' ERR

if [ -n "$debs" ]; then
    debs_added=$debs   # before dpkg: a failure can leave some of them installed
    sudo -n dpkg --force-confdef --force-confold -i "${debfiles[@]}" >/dev/null   # never asks: no terminal here
    log "system packages installed:$debs"
fi

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
for name in $pipapps; do   # offline: only the wheels in the release; packages already satisfied stay as they are
    venv=$HOME/${apip[$name]%%:*}
    mkdir -p "$backup/venvs"
    cp -a "$venv" "$backup/venvs/$name"
    before=$("$venv/bin/pip" freeze --disable-pip-version-check)
    "$venv/bin/pip" install -q --disable-pip-version-check --no-index --find-links "$PWD/apps/wheels" \
        -r "$HOME/$name/${apip[$name]#*:}"
    log "$name: Python requirements installed"
    python3 - <(echo "$before") <("$venv/bin/pip" freeze --disable-pip-version-check) <<'EOF'
import sys
a, b = ({l.split("==")[0].lower(): l.strip().split("==")[1] for l in open(p) if "==" in l} for p in sys.argv[1:])
for name in sorted(a.keys() | b.keys()):
    if a.get(name) != b.get(name):
        print("    %s %s -> %s" % (name, a.get(name, "(new)"), b.get(name, "(removed)")))
EOF
done

# services, set up the way upstream's installers set them up now (a pin change alone doesn't touch them)
menv=$HOME/printer_data/systemd/moonraker.env   # Sovol's runs moonraker/moonraker.py, the legacy entry point
menv_text=$(printf 'MOONRAKER_DATA_PATH="%s"\nMOONRAKER_ARGS="-m moonraker"\nPYTHONPATH="%s"' "$HOME/printer_data" "$HOME/moonraker")
if [ -d "$HOME/moonraker" ] && [ -f "$menv" ] && [ "$menv_text" != "$(cat "$menv")" ]; then
    replace "$menv" "$menv_text"; restart_add moonraker; log "moonraker: started as upstream does now (-m moonraker)"
fi
ksunit=$ROOT/etc/systemd/system/KlipperScreen.service; kstpl=$HOME/KlipperScreen/scripts/KlipperScreen.service
if [ -f "$ksunit" ] && [ -f "$kstpl" ]; then   # upstream's template, filled in as its installer does (X: Sovol's backend)
    ksunit_text=$(<"$kstpl"); ksunit_text=${ksunit_text//KS_USER/"$(id -un)"}
    ksunit_text=${ksunit_text//KS_ENV/"$HOME/.KlipperScreen-env"}; ksunit_text=${ksunit_text//KS_DIR/"$HOME/KlipperScreen"}
    ksunit_text=${ksunit_text//KS_BACKEND/X}
    # X starts on the first free VT (2 here), not the session's tty7, and switches to it itself; a later
    # "chvt 7" left the screen on the boot console. Upstream's installer comments it out the same way without a VT.
    ksunit_text=${ksunit_text//$'\n'ExecStartPost=/$'\n'#ExecStartPost=}
    if [ "$ksunit_text" != "$(cat "$ksunit")" ]; then
        replace "$ksunit" "$ksunit_text"; sudo -n systemctl daemon-reload; restart_add KlipperScreen
        log "KlipperScreen: service file updated from upstream's template"
    fi
fi

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
    restart_add zero-config; log "config page: updated"
fi
unit=$(sed "s|@USER@|$(id -un)|; s|@HOME@|$HOME|" zero-config/zero-config.service)
if [ "$unit" != "$(cat "$ROOT"/etc/systemd/system/zero-config.service 2>/dev/null)" ]; then
    echo "$unit" | sudo -n tee "$ROOT"/etc/systemd/system/zero-config.service >/dev/null
    sudo -n systemctl daemon-reload
    sudo -n systemctl enable -q zero-config
    restart_add zero-config; log "config page: service installed"
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

remove_sovol_updaters   # sovol-cleanup.sh

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
if grep -qE '^(>f|\*deleting).* chelper/.*\.[ch]$' <<<"$synced"; then   # Klipper rebuilds it on start
    rm -f "$KLIPPER/klippy/chelper/c_helper.so"; log "klippy: chelper C changed, c_helper.so rebuilds on start"
fi

services_up() {
    local s
    for s in $restart; do
        for _ in $(seq 20); do systemctl is-active -q "$s" && continue 2; sleep 1.5; done
        echo "$s is not running"; return 1
    done
}
# with boards to flash, the new host may not work with their old firmware (Klipper master and Sovol's
# toolhead), so Klipper is checked once they're flashed
if ! restart_services || { [ -z "$flash" ] && ! wait_ready; } || ! services_up; then
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
# (newest first), then the host. Klipper checks them only once all are back, as host and boards may only
# work as a set.
declare -A old_img old_ver; flashed=""
rollback_all() {
    trap - ERR
    local b
    sudo -n systemctl stop klipper
    for b in $flashed; do
        log "$b: flashing back ${old_ver[$b]}"
        if ./flash-board.sh "$b" "${old_img[$b]}" || ./flash-board.sh "$b" "${old_img[$b]}"; then
            cp "${old_img[$b]}" "$STATE/firmware/$b.bin"; echo "${old_ver[$b]}" > "$STATE/firmware/$b.version"
        else
            log "$b: flashing back failed"
        fi
    done
    restore_host   # restarts Klipper and waits for it
    for b in $flashed; do
        if [ "$(running_version "$b")" = "${old_ver[$b]}" ]; then log "$b restored to ${old_ver[$b]}"
        else log "$b: ROLLBACK FAILED, see RECOVERY.md"; fi
    done
}

if [ -n "$flash" ]; then
    mkdir -p "$STATE/firmware" "$backup/firmware"   # $STATE/firmware: last image flashed to each board
    trap 'sudo -n systemctl start klipper' EXIT
    trap 'log "unexpected failure, rolling back"; rollback_all' ERR
    # toolhead first and verified before the mainboard, which is also the toolhead's only link to the host
    for b in toolhead mainboard; do
        [[ " $flash " == *" $b "* ]] || continue
        want=$(manifest "d['boards']['$b']['version']")
        # the previous image, copied: $STATE/firmware/$b.bin is overwritten once this board succeeds
        if [ -f "$STATE/firmware/$b.bin" ] && [ "$(cat "$STATE/firmware/$b.version")" = "${was[$b]}" ]; then
            cp "$STATE/firmware/$b.bin" "$backup/firmware/$b.bin"; old_ver[$b]=${was[$b]}
        else
            cp "$(manifest "d['boards']['$b']['stock_file']")" "$backup/firmware/$b.bin"; old_ver[$b]=$(manifest "d['boards']['$b']['stock_version']")
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

remove_obico   # sovol-cleanup.sh: only now, see there
remove_plr     # sovol-cleanup.sh: likewise
log "installed sovol-zero-extended $version"
