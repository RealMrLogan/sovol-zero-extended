# Sovol Zero firmware: phase 1 findings (2026-11-14)

## Printer
- Host: Allwinner H616, 1 GB RAM, 7.8 GB eMMC (root 91% full), Debian 11 "SPI-XI 2.3.3", kernel 5.16.17-sun50iw9
- Sovol firmware 1.4.7 (latest OTA). Moonraker update_manager disabled by Sovol.
- MCUs (both on CAN, can0 via USB-CAN bridge):
  - mainboard `[mcu]` STM32H750, USB-to-CAN bridge mode, canbus_uuid 0d1445047cdd, Katapult over USB
  - toolhead `[mcu extruder_mcu]` STM32F103xE, 8 MHz, canbus_uuid 61755fe321ac, Katapult over CAN, app @ 0x08002000
  - (an "extra_mcu" uuid 58a72bb93aa4 appears in scripts: optional chamber/extra board)
- Sovol's flashing tools: sovol-official/... .deb -> printer_data/build/{flash_can.py (Katapult flashtool), *_update_fw.sh}
- The .config / .config103 / .config750 in Sovol's tree say flash start 0x8000000: stale; real builds use Katapult offsets.
  Mainboard H750 app offset still to confirm (likely 0x08020000) before any flash.

## Klipper delta
- Sovol tree = upstream faa89be8 (2024-10-28) + "first commit for sv08mini" + 48 commits + 13 uncommitted files.
- ~4,100 changed lines in 105 files (98 "modified" files on the printer were only stale .pyc caches).
- Full patch (applies cleanly to upstream faa89be8): sovol-klipper/sovol-1.4.7-vs-upstream-faa89be8.patch
- Per-file stats: sovol-klipper/sovol-vs-upstream.numstat; Sovol commit messages: sovol-klipper/sovol-commit-log.txt
- Main areas:
  - eddy probing / contact homing: probe_eddy_current.py, ldc1612.py, src/sensor_ldc1612.c, z_offset_calibration.py (new), homing.py, probe.py
  - pressure probe: probe_pressure.py (new, 486 lines; Sovol dropped it in 1.4.2)
  - stock screen: src/UC1701.c, src/fonts.c, display/menu.cfg, menu.py, display.cfg
  - misc: fan.py/heater_fan.py (fan-fault prompt codes), gcode_move.py, toolhead.py, idle_timeout.py,
    resonance_tester.py/shaper_calibrate.py, gcode_shell_command.py, ws2811.c, stm32 i2c.c changes
- Upstream has moved ~2 years (merge base 2024-10-28 -> 2026-11-10).

## Layout
- upstream-klipper/          clone of Klipper3d/klipper (local only, gitignored)
- from-printer/klipper/      Sovol's Klipper tree as running (local only, gitignored; captured by the patch)
- from-printer/config/       printer_data/config from the printer (includes calibration)
- sovol-official/            Sovol wiki downloads (recovery image, update .deb, manuals)

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
