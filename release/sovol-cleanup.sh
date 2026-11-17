# shellcheck shell=bash disable=SC2154   # $backup and the other variables come from install.sh, which sources this
# One-way removals of what Sovol left on the printer, sourced by install.sh (which provides $HOME, $ROOT,
# $backup, $PRINTER_CFG, $PATCH_CFG and log). Each step checks before it changes anything, so it does nothing on
# a printer that's already clean, and none of it is rolled back: putting these back would re-add code that
# bypasses or breaks this installer.

# Before the restart: Sovol's updaters and their macros, and the Obico macros in get_ip.cfg.
remove_sovol_updaters() {
    local boot build f cfg
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
    # (backed up for reference only: putting them back would re-add macros calling the scripts deleted above),
    # and the Obico ones (moonraker-obico goes in remove_obico; nothing but these sections calls them)
    for cfg in "$HOME/printer_data/config/get_ip.cfg" "$HOME/patch/config/get_ip.cfg"; do
        [ -f "$cfg" ] || continue
        cp -p "$cfg" "$backup/$(echo "${cfg#"$HOME"/}" | tr / _)"
        if python3 - "$cfg" <<'EOF'
import sys
drop = {"[gcode_shell_command %s]" % c for c in ("ota", "mcu_up", "extruder_mcu_up", "extra_mcu_up")}
drop |= {"[gcode_macro %s]" % m for m in ("_OTA", "_MCU_UP", "_EXTRUDER_MCU_UP", "_EXTRA_MCU_UP")}
drop |= {"[gcode_shell_command obico_restart]", "[gcode_macro _OBICO_RESTART]", "[gcode_macro _OBICO_CODE_GET]",
         "[delayed_gcode code_display]"}
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
        then log "Sovol updaters and Obico: macros removed from ${cfg#"$HOME"/}"; fi
    done
}

# moonraker-obico: not used (never linked). After a successful install only: a rolled-back klippy has Sovol's
# menu, which reads Obico's OBICO_LINK_STATUS macro.
remove_obico() {
    local cfg
    if [ -e "$HOME/moonraker-obico" ] || [ -e "$ROOT"/etc/systemd/system/moonraker-obico.service ]; then
        sudo -n systemctl disable -q --now moonraker-obico || true
        sudo -n rm -f "$ROOT"/etc/systemd/system/moonraker-obico.service
        sudo -n systemctl daemon-reload
        rm -rf "$HOME/moonraker-obico" "$HOME/moonraker-obico-env" "$HOME"/printer_data/logs/moonraker-obico.log*
        for cfg in "$PRINTER_CFG" "$PATCH_CFG"; do
            if [ -f "$cfg" ]; then sed -i '/^\[include moonraker_obico_macros\.cfg\]/d' "$cfg"; fi
            rm -f "$(dirname "$cfg")"/{moonraker_obico_macros.cfg,moonraker-obico.cfg,moonraker-obico-update.cfg}
        done
        log "moonraker-obico removed (takes effect at Klipper's next restart)"
    fi
}

# Sovol's power-loss recovery: its G1 hook isn't carried to Klipper master (it stalled printing, see patches/),
# so its macros, scripts and saved file are dead. After a successful install only, like remove_obico. Its
# saved_variables stay, was_interrupted set to False: Sovol's menu code reads it at startup and fails without it.
remove_plr() {
    local d vars=$HOME/printer_data/config/saved_variables.cfg
    for d in "$(dirname "$PRINTER_CFG")" "$(dirname "$PATCH_CFG")"; do
        [ -f "$d/plr.cfg" ] || continue
        sed -i '/^\[include plr\.cfg\]/d' "$d/printer.cfg"
        rm -f "$d/plr.cfg"
        # START_PRINT's interrupted-print block and its saving of the file name, and PRINT_END (plr.cfg's)
        if [ -f "$d/Macro.cfg" ]; then python3 - "$d/Macro.cfg" <<'PY'
import sys
lines = open(sys.argv[1], newline="").read().splitlines(True)   # newline="": keep its CRLFs
out, skip = [], False
for line in lines:
    s = line.strip()
    if s.startswith("{% if printer.save_variables.variables.was_interrupted"):
        skip = True
    if not skip and s not in ("save_last_file", "M117 {last_file}", "PRINT_END"):
        out.append(line)
    if skip and s == "{% endif %}":
        skip = False
open(sys.argv[1], "w", newline="").write("".join(out))
PY
        fi
        log "power-loss recovery: macros removed from ${d#"$HOME"/}"
    done
    rm -rf "$HOME/plr.sh" "$HOME/clear_plr.sh" "$HOME/sovol_plr_height" "$HOME/printer_data/gcodes/plr"
    if [ -f "$vars" ]; then sed -i 's/^was_interrupted = .*/was_interrupted = False/' "$vars"; fi
}
