# Sovol Zero firmware: phase 1 findings (2026-11-14)

## Printer
- Host: Allwinner H616, 1 GB RAM, 7.8 GB eMMC (root 91% full), Debian 11 "SPI-XI 2.3.3", kernel 5.16.17-sun50iw9
- Sovol firmware 1.4.7 (latest OTA). Moonraker update_manager disabled by Sovol.
- MCUs (both on CAN, can0 via USB-CAN bridge):
  - mainboard `[mcu]` STM32H750, USB-to-CAN bridge mode, canbus_uuid 0d1445047cdd, Katapult over USB, app @ 0x08020000
    (confirmed 2026-11-14 via Katapult CONNECT: Katapult 32c53b2-dirty, proto 1.1.0, block 64)
  - toolhead `[mcu extruder_mcu]` STM32F103xE, 8 MHz, canbus_uuid 61755fe321ac, Katapult over CAN, app @ 0x08002000
  - (an "extra_mcu" uuid 58a72bb93aa4 appears in scripts: optional chamber/extra board)
- Sovol's flashing tools: sovol-official/... .deb -> printer_data/build/{flash_can.py (Katapult flashtool), *_update_fw.sh}
- The .config / .config103 / .config750 in Sovol's tree say flash start 0x8000000: stale; real builds use Katapult offsets.

## Klipper delta
- Sovol tree = upstream faa89be8 (2024-10-28) + "first commit for sv08mini" + 48 commits + 13 uncommitted files.
- ~4,100 changed lines in 105 files (98 "modified" files on the printer were only stale .pyc caches).
- Now kept as patches/ (8 feature patches on upstream faa89be8). Applied, they reproduce the printer's tree exactly,
  minus noise that was dropped: 47 lost exec bits, a compiled c_helper.so, stale .config files, .gitignore/README edits.
- Notable: chipid.c pins fixed CAN UUIDs (printer.cfg relies on them); sched.c disables the "Timer too close" shutdown;
  virtual_sdcard.py hardcodes /home/sovol paths.
- Board build configs: configs/*.config = Sovol's .config103/.config750 with only the flash start fixed
  (matches every constant the running firmware reports in klippy.log).
- Main areas:
  - eddy probing / contact homing: probe_eddy_current.py, ldc1612.py, src/sensor_ldc1612.c, z_offset_calibration.py (new), homing.py, probe.py
  - pressure probe: probe_pressure.py (new, 486 lines; Sovol dropped it in 1.4.2)
  - stock screen: src/UC1701.c, src/fonts.c, display/menu.cfg, menu.py, display.cfg
  - misc: fan.py/heater_fan.py (fan-fault prompt codes), gcode_move.py, toolhead.py, idle_timeout.py,
    resonance_tester.py/shaper_calibrate.py, gcode_shell_command.py, ws2811.c, stm32 i2c.c changes
- Upstream has moved ~2 years (merge base 2024-10-28 -> 2026-11-10).

## Layout
See README.md.

## Sovol open-source references (checked 2026-11-14)
- https://github.com/Sovol3d/SOVOL-ZERO (ref commit d745b00b, 2026-06-02)
  - `Motherboard/Mcu_Pin_definition.pdf`, `Extra_Pin_definition.pdf`: board pinouts (copied to sovol-official/)
  - `STEP/`: CAD of the whole printer: frame, screen component, back cover, toolhead, enclosure (for the screen mount)
  - `sovol/`: snapshot of the stock /home/sovol from ~2025-03 (firmware ~1.3.x): mainsail build, patch/,
    usbmount, pyhelper, printer_data/build (flash scripts + toolhead bin), kiauh-backups. Older than our 1.4.7 copy.
  - **No Klipper source.** The 2026-06 commits only re-upload a pinout PDF.
- https://github.com/Sovol3d/klipper (last commit bae68982, 2024-10-29): pre-Zero (SV06/SV08 era), older than the Zero tree.
- So the Klipper tree pulled from the printer (captured in sovol-klipper/*.patch) is the most complete Zero
  source available. Sovol never published it.

## Stock baseline (2026-11-14)
- Reference = official 1.4.7 recovery image. Its ~/klipper (commit 8a8b5e8 "1.4.5") equals upstream faa89be8 + patches/
  (only Sovol's README/.gitignore edits dropped). The toolhead build from patches/ is byte-identical to Sovol's image.
- The printer had user edits (PROBE_CONTACT_Z_OFFSET_CALIBRATE in probe_eddy_current.py; custom Macro.cfg/printer.cfg).
  Reset to stock on 2026-11-14, keeping the printer's SAVE_CONFIG calibration block; the user's versions are in
  from-printer/config and in git history (commit 996f615).
- Mainboard runs an older Sovol build (14d7b18-dirty, Feb 2025) that no available source rebuilds exactly
  (closest, cc8afd8: same size, different bytes). Exact copy kept in stock-firmware/. Flashing the mainboard
  from patches/ gives Sovol's newer 1.4.7 board code instead: move queue 2048 -> 4096, reworked I2C error
  handling (unused on the mainboard), and ws2811 timing whose delays round to zero at 400 MHz, which may break
  the stock screen's power-on white LEDs (Klipper's [neopixel] still sets them once connected).
