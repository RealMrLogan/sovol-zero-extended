#!/usr/bin/env bash
# Runs release/install.sh against a fake printer: a temporary $HOME, a fake / for /etc and /boot (ZX_ROOT) and
# stubs for Moonraker (curl), sudo, systemctl, nginx, pkill and sleep. No boards are flashed (--no-flash).
# Checks a clean install, a re-install, a refusal during a print and the rollback when Klipper doesn't come back.
set -euo pipefail
REPO=$(cd "$(dirname "$0")/.." && pwd)
t=$(mktemp -d); trap '[ -n "${KEEP:-}" ] || rm -rf "$t"' EXIT
H=$t/home R=$t/root REL=$t/release BIN=$t/bin
CFG=$H/printer_data/config
AUTOSAVE='#*# <---------------------- SAVE_CONFIG ---------------------->'
fail() { echo "FAIL: $*"; exit 1; }

stub() { printf '#!/usr/bin/env bash\n%s\n' "$2" > "$BIN/$1"; chmod +x "$BIN/$1"; }

setup() {
    rm -rf "${t:?}"/*
    mkdir -p "$H/klipper/klippy" "$CFG" "$H/printer_data/logs" "$H/patch/config" "$H/mainsail" \
             "$R/etc/nginx/sites-available" "$R/etc/systemd/system" "$R/boot/scripts" "$BIN"
    echo old > "$H/klipper/klippy/klippy.py"
    echo old > "$H/mainsail/index.html"
    echo '{"user": "keep"}' > "$H/mainsail/config.json"
    touch "$H/printer_data/logs/klippy.log"
    printf '[include moonraker_obico_macros.cfg]\r\n[printer]\r\nmax_accel: 40000\r\n\r\n%s\r\n#*# [input_shaper]\r\n' "$AUTOSAVE" > "$CFG/printer.cfg"
    cp "$CFG/printer.cfg" "$H/patch/config/printer.cfg"
    printf '[gcode_macro KEEP]\ngcode:\n[gcode_macro _OTA]\ngcode:\n  RUN_SHELL_COMMAND CMD=ota\n[gcode_macro _OBICO_CODE_GET]\ngcode:\n[delayed_gcode code_display]\ngcode:\n    OBICO_LINK_STATUS\n' > "$CFG/get_ip.cfg"
    mkdir -p "$H/moonraker-obico" "$H/moonraker-obico-env"
    for d in "$CFG" "$H/patch/config"; do touch "$d"/{moonraker_obico_macros.cfg,moonraker-obico.cfg,moonraker-obico-update.cfg}; done
    touch "$R/etc/systemd/system/moonraker-obico.service"
    printf 'server {\n    server_name _;\n}\n' > "$R/etc/nginx/sites-available/mainsail"
    printf 'keep\n/boot/scripts/ota_service.sh &\n' > "$R/boot/scripts/btt_init.sh"
    touch "$R/etc/systemd/system/crowsnest.service"
    cp -a "$H" "$t/orig"

    mkdir -p "$REL/klipper/klippy" "$REL/apps/mainsail"
    cp -r "$REPO"/release/{install.sh,flash-board.sh,apps.conf,systemd,zero-config} "$REL/"
    find "$REL" -name __pycache__ -prune -exec rm -rf {} +
    echo new > "$REL/klipper/klippy/klippy.py"
    echo new > "$REL/apps/mainsail/index.html"
    echo '{"name": "sovol-zero-extended", "version": "v9.9.9", "boards": {"toolhead": {"version": "t"}, "mainboard": {"version": "m"}}}' \
        > "$REL/manifest.json"
    (cd "$REL" && find . -type f ! -name SHA256SUMS -printf '%P\n' | sort | xargs -d '\n' sha256sum > SHA256SUMS)

    # Moonraker: Klipper's state and the print state come from FAKE_KLIPPER and FAKE_PRINT
    stub curl 'for a; do url=$a; done
case $url in
    *printer/info) echo "{\"result\": {\"state\": \"$FAKE_KLIPPER\"}}" ;;
    *print_stats) echo "{\"result\": {\"status\": {\"print_stats\": {\"state\": \"$FAKE_PRINT\"}}}}" ;;
    *firmware_restart) ;;
    *) exit 22 ;;
esac'
    stub sudo '[ "$1" = -n ] && shift; exec "$@"'
    stub systemctl "echo \"\$*\" >> $t/systemctl.log"
    stub nginx ':'
    stub pkill 'exit 1'
    stub sleep ':'
}

install() {   # FAKE_KLIPPER FAKE_PRINT: install.sh's exit code
    local rc=0
    HOME=$H ZX_ROOT=$R PATH=$BIN:$PATH FAKE_KLIPPER=$1 FAKE_PRINT=$2 "$REL/install.sh" --no-flash > "$t/out" 2>&1 || rc=$?
    echo $rc
}
same() { cmp -s "$t/orig/$1" "$H/$1" || fail "$1 changed"; }
has() { grep -qF -- "$2" "$1" || fail "$1 lacks: $2"; }
lacks() { ! grep -qF -- "$2" "$1" || fail "$1 still has: $2"; }

echo "== install"
setup
[ "$(install ready standby)" = 0 ] || { cat "$t/out"; fail "install failed"; }
has "$H/klipper/klippy/klippy.py" new
has "$H/mainsail/index.html" new
has "$H/mainsail/config.json" keep
has "$H/zero-extended/version" v9.9.9
has "$H/zero-extended/zero-config/server.py" ThreadingHTTPServer
has "$CFG/zero-extended/zero-extended.cfg" "[resonance_tester]"
for f in "$CFG/printer.cfg" "$H/patch/config/printer.cfg"; do
    python3 - "$f" "$AUTOSAVE" <<'EOF' || fail "$f: include missing, after SAVE_CONFIG's block or not CRLF"
import sys
s = open(sys.argv[1], newline="").read()
assert s.index("[include zero-extended/*.cfg]") < s.index(sys.argv[2]) and "\n" not in s.replace("\r\n", "")
EOF
done
has "$CFG/get_ip.cfg" "[gcode_macro KEEP]"
lacks "$CFG/get_ip.cfg" "_OTA"
lacks "$CFG/get_ip.cfg" "OBICO"
for f in "$CFG/printer.cfg" "$H/patch/config/printer.cfg"; do lacks "$f" obico; done
for f in "$H/moonraker-obico" "$H/moonraker-obico-env" "$CFG/moonraker_obico_macros.cfg" "$H/patch/config/moonraker-obico.cfg" \
         "$R/etc/systemd/system/moonraker-obico.service"; do [ ! -e "$f" ] || fail "$f left behind"; done
has "$t/systemctl.log" "disable -q --now moonraker-obico"
lacks "$R/boot/scripts/btt_init.sh" ota_service
has "$R/boot/scripts/btt_init.sh" keep
has "$R/etc/nginx/sites-available/mainsail" "include $R/etc/nginx/snippets/zero-extended.conf;"
has "$R/etc/systemd/system/zero-config.service" "$H"
has "$R/etc/systemd/system/crowsnest.service.d/zero-extended.conf" "[Service]"
has "$t/systemctl.log" "restart klipper"

echo "== re-install changes nothing"
cp "$CFG/printer.cfg" "$t/installed.cfg"
[ "$(install ready standby)" = 0 ] || { cat "$t/out"; fail "re-install failed"; }
cmp -s "$t/installed.cfg" "$CFG/printer.cfg" || fail "re-install changed printer.cfg"
[ "$(grep -c 'zero-extended.conf;' "$R/etc/nginx/sites-available/mainsail")" = 1 ] || fail "nginx include added twice"

echo "== refused while printing"
setup
[ "$(install ready printing)" = 1 ] || fail "installed during a print"
has "$t/out" "refusing to install"
same klipper/klippy/klippy.py; same printer_data/config/printer.cfg; same mainsail/index.html

echo "== rollback when Klipper doesn't come back"
setup
[ "$(install error standby)" = 1 ] || { cat "$t/out"; fail "install succeeded with Klipper down"; }
has "$t/out" "restoring the previous klippy/"
same klipper/klippy/klippy.py; same mainsail/index.html
same printer_data/config/printer.cfg; same patch/config/printer.cfg
[ ! -e "$CFG/zero-extended" ] || fail "zero-extended.cfg left behind"
[ ! -e "$H/zero-extended/version" ] || fail "version recorded for a failed install"
[ -e "$H/moonraker-obico" ] && [ -e "$CFG/moonraker_obico_macros.cfg" ] || fail "obico removed by a failed install"
has "$t/out" "FIRMWARE_RESTART"

echo "install-test ok"
