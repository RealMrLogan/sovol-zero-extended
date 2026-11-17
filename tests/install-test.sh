#!/usr/bin/env bash
# Runs release/install.sh against a fake printer: a temporary $HOME, a fake / for /etc and /boot (ZX_ROOT) and
# stubs for Moonraker (curl), sudo, systemctl, nginx, pkill, sleep and dpkg (packages are files in $t/dpkg).
# No boards are flashed (--no-flash). Checks a clean install, a re-install, refusals (a print, missing wheels,
# a package dpkg can't install or that's installed at another version) and the rollback when Klipper doesn't
# come back. Moonraker is a git repo whose pin changes its requirements, with a venv whose pip only records its
# calls. The release ships one .deb (fakepkg).
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
    # Sovol's Moonraker env (legacy entry point) and an older KlipperScreen unit; upstream's template to fill in
    mkdir -p "$H/printer_data/systemd" "$H/KlipperScreen/scripts" "$t/dpkg"
    printf 'MOONRAKER_ARGS="%s/moonraker/moonraker/moonraker.py -d %s/printer_data"\n' "$H" "$H" > "$H/printer_data/systemd/moonraker.env"
    printf '[Service]\nUser=sovol\n' > "$R/etc/systemd/system/KlipperScreen.service"
    printf '[Service]\nUser=KS_USER\nEnvironment="KS_XCLIENT=KS_ENV/bin/python KS_DIR/screen.py" BACKEND=KS_BACKEND\nPAMName=%%u\n' \
        > "$H/KlipperScreen/scripts/KlipperScreen.service"
    if [ -n "${HAVE_PKG:-}" ]; then echo "$HAVE_PKG" > "$t/dpkg/fakepkg"; fi
    cp -a "$H" "$t/orig"; cp -a "$R" "$t/origroot"

    mkdir -p "$REL/klipper/klippy" "$REL/apps/mainsail"
    cp -r "$REPO"/release/{install.sh,sovol-cleanup.sh,flash-board.sh,apps.conf,systemd,zero-config} "$REL/"
    find "$REL" -name __pycache__ -prune -exec rm -rf {} +
    echo new > "$REL/klipper/klippy/klippy.py"
    echo new > "$REL/apps/mainsail/index.html"
    echo '{"name": "sovol-zero-extended", "version": "v9.9.9", "boards": {"toolhead": {"version": "t"}, "mainboard": {"version": "m"}}}' \
        > "$REL/manifest.json"
    # moonraker at Sovol's stock commit; the pin changes its requirements, so install.sh pip-installs them
    A=$H/moonraker; mkdir -p "$A/scripts" "$H/moonraker-env/bin"
    g() { git -C "$A" -c user.name=t -c user.email=t@t "$@"; }
    g init -q; echo 'tornado==1' > "$A/scripts/moonraker-requirements.txt"; g add -A; g commit -qm stock
    echo 'tornado==2' > "$A/scripts/moonraker-requirements.txt"; g commit -qam pin
    PIN=$(g rev-parse HEAD); STOCK=$(g rev-parse HEAD~1); g checkout -q "$STOCK"
    cat > "$H/moonraker-env/bin/pip" <<EOF
#!/usr/bin/env bash
if [ "\$1" = freeze ]; then [ -e "\$(dirname "\$0")/../installed" ] && echo tornado==2 || echo tornado==1; exit; fi
echo "\$*" >> $t/pip.log; touch "\$(dirname "\$0")/../installed"
EOF
    chmod +x "$H/moonraker-env/bin/pip"
    { grep "^mainsail " "$REPO/release/apps.conf"; echo "moonraker git x $STOCK $PIN moonraker moonraker-env:scripts/moonraker-requirements.txt"; } > "$REL/apps.conf"
    if [ -z "${NOWHEELS:-}" ]; then mkdir -p "$REL/apps/wheels"; touch "$REL/apps/wheels/tornado-2-py3-none-any.whl"; fi
    mkdir -p "$REL/debs"; touch "$REL/debs/fakepkg_1.0_arm64.deb"
    echo "fakepkg 1.0 - https://example.invalid/fakepkg_1.0_arm64.deb" > "$REL/debs.conf"
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
    # dpkg: a package is installed when $t/dpkg/<name> holds its version. apt-get -s simulates installing the
    # .debs: FAKE_DPKG_FAIL = their dependencies are missing, FAKE_APT_EXTRA = it would also install another package
    stub apt-get "[ -z \"\${FAKE_DPKG_FAIL:-}\" ] || { echo 'E: Unable to correct problems'; exit 100; }
[ -z \"\${FAKE_APT_EXTRA:-}\" ] || echo 'Inst libextra (1 Debian)'
for a; do case \$a in *.deb) b=\$(basename \"\$a\"); echo \"Inst \${b%%_*} (1 local-deb)\" ;; esac; done"
    stub dpkg-query "f=$t/dpkg/\${!#}; [ -f \"\$f\" ] || exit 1; printf 'ii %s' \"\$(cat \"\$f\")\""
    stub dpkg "echo \"\$*\" >> $t/dpkg.log
case \$1 in
    -i) shift; for d; do b=\$(basename \"\$d\" _arm64.deb); echo \"\${b#*_}\" > $t/dpkg/\${b%%_*}; done ;;
    -P) rm $t/dpkg/\$2 ;;
esac"
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
has "$t/systemctl.log" "restart moonraker"
[ "$(git -C "$H/moonraker" rev-parse HEAD)" = "$PIN" ] || fail "moonraker not at its pin"
has "$t/pip.log" "--no-index --find-links $REL/apps/wheels -r $H/moonraker/scripts/moonraker-requirements.txt"
has "$t/out" "    tornado 1 -> 2"
grep -qE '^==> [0-9]{2}:[0-9]{2}:[0-9]{2} installed sovol-zero-extended v9.9.9$' "$t/out" || fail "no timed success line"
has "$t/dpkg/fakepkg" 1.0
has "$H/printer_data/systemd/moonraker.env" 'MOONRAKER_ARGS="-m moonraker"'
has "$H/printer_data/systemd/moonraker.env" "PYTHONPATH=\"$H/moonraker\""
has "$H/printer_data/systemd/moonraker.env" "MOONRAKER_DATA_PATH=\"$H/printer_data\""
KSUNIT=$R/etc/systemd/system/KlipperScreen.service
has "$KSUNIT" "User=$(id -un)"
has "$KSUNIT" "KS_XCLIENT=$H/.KlipperScreen-env/bin/python $H/KlipperScreen/screen.py\" BACKEND=X"
has "$KSUNIT" "PAMName=%u"
has "$t/systemctl.log" "restart KlipperScreen"
cmp -s "$t/origroot/etc/systemd/system/KlipperScreen.service" "$H"/zero-extended/backup/*/files"$KSUNIT" ||
    fail "old KlipperScreen unit not backed up under its own path"

echo "== re-install changes nothing"
cp "$CFG/printer.cfg" "$t/installed.cfg"
[ "$(install ready standby)" = 0 ] || { cat "$t/out"; fail "re-install failed"; }
cmp -s "$t/installed.cfg" "$CFG/printer.cfg" || fail "re-install changed printer.cfg"
[ "$(wc -l < "$t/pip.log")" = 1 ] || fail "re-install ran pip again"
[ "$(grep -c 'zero-extended.conf;' "$R/etc/nginx/sites-available/mainsail")" = 1 ] || fail "nginx include added twice"
[ "$(grep -c '^-i ' "$t/dpkg.log")" = 1 ] || fail "re-install ran dpkg -i again"
lacks "$t/out" "service file updated"
lacks "$t/out" "started as upstream does now"

echo "== refused while printing"
setup
[ "$(install ready printing)" = 1 ] || fail "installed during a print"
has "$t/out" "refusing to install"
same klipper/klippy/klippy.py; same printer_data/config/printer.cfg; same mainsail/index.html

echo "== refused when the pin needs wheels the release lacks"
NOWHEELS=1 setup
[ "$(install ready standby)" = 1 ] || fail "installed without wheels"
has "$t/out" "the release has no wheels"
[ "$(git -C "$H/moonraker" rev-parse HEAD)" = "$STOCK" ] || fail "moonraker moved"

echo "== refused when a package's dependencies are missing, or it would need another package"
for v in FAKE_DPKG_FAIL FAKE_APT_EXTRA; do
    setup; export "$v=1"
    [ "$(install ready standby)" = 1 ] || fail "$v: installed anyway"
    unset "$v"
    has "$t/out" "can't install fakepkg from the release alone"
    same klipper/klippy/klippy.py; [ ! -e "$t/dpkg/fakepkg" ] || fail "$v: fakepkg installed"
done
has "$t/out" "Inst libextra"

echo "== refused when a package is installed at another version"
HAVE_PKG=0.9 setup
[ "$(install ready standby)" = 1 ] || fail "replaced an installed package"
has "$t/out" "fakepkg 0.9 is installed, the release ships 1.0"
same klipper/klippy/klippy.py; has "$t/dpkg/fakepkg" 0.9

echo "== rollback when Klipper doesn't come back"
setup
[ "$(install error standby)" = 1 ] || { cat "$t/out"; fail "install succeeded with Klipper down"; }
has "$t/out" "restoring the previous klippy/"
same klipper/klippy/klippy.py; same mainsail/index.html
same printer_data/config/printer.cfg; same patch/config/printer.cfg
[ ! -e "$CFG/zero-extended" ] || fail "zero-extended.cfg left behind"
[ ! -e "$H/zero-extended/version" ] || fail "version recorded for a failed install"
[ -e "$H/moonraker-obico" ] && [ -e "$CFG/moonraker_obico_macros.cfg" ] || fail "obico removed by a failed install"
[ -e "$t/pip.log" ] || fail "pip never ran"
[ ! -e "$H/moonraker-env/installed" ] || fail "moonraker-env not restored"
[ "$(git -C "$H/moonraker" rev-parse HEAD)" = "$STOCK" ] || fail "moonraker not back at its old commit"
has "$t/out" "FIRMWARE_RESTART"
[ ! -e "$t/dpkg/fakepkg" ] || fail "fakepkg not removed"
same printer_data/systemd/moonraker.env
cmp -s "$t/origroot/etc/systemd/system/KlipperScreen.service" "$R/etc/systemd/system/KlipperScreen.service" || fail "KlipperScreen unit not restored"

echo "install-test ok"
