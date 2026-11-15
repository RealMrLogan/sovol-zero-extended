# sovol-zero-extended

Community firmware for the Sovol Zero, now that Sovol's own (1.4.7) is frozen.
This repo is the source of truth: **upstream Klipper, pinned and unmodified, plus Sovol's changes as a patch series.**

- `klipper/`: submodule, upstream [Klipper3d/klipper](https://github.com/Klipper3d/klipper) pinned at `faa89be8` (what Sovol based 1.4.7 on)
- `patches/`: Sovol's changes, split by feature, applied in order on top of the pin. `sovol-commit-log.txt` keeps Sovol's original commit messages.
- `configs/`: build settings for each board (`toolhead.config`, `mainboard.config`)
- `tools/`: build, deploy and flash over SSH
- `FINDINGS.md`: what's on the printer and what Sovol changed
- `stock-config/config/`: stock 1.4.7 printer config (from the recovery image)
- `from-printer/config/`: this printer's config before the 2026-11-14 reset (user mods, to re-add later)
- `sovol-host/`: Sovol's scripts, services and system files outside Klipper (stock)
- `stock-firmware/`: exact backup of the stock mainboard firmware, read from the board
- `sovol-official/`: Sovol's published update package, manuals and recovery-image checksums

## Workflow
```sh
git submodule update --init
tools/setup.sh                # work/ = klipper pin + patches/, one commit per patch (gitignored)
# edit in work/ ...
tools/deploy-host.sh          # host Python (work/klippy) -> printer, restart Klipper. No flashing
tools/build-mcu.sh toolhead   # build board firmware on the printer (Sovol's gcc 8.3.1); checks the start address
tools/flash-mcu.sh toolhead   # flash over Katapult; refuses while printing; keeps every flashed image in ~/zero-build/flashed
# commit the fix inside work/, then:
tools/export-patches.sh       # rewrite patches/ from work/'s commits
```
`mainboard` works the same way but asks for confirmation: it is also the USB-to-CAN bridge, so a bad
image cuts off both boards (Katapult itself survives). Flash the toolhead first.
Set `PRINTER=user@host` if the printer isn't at `sovol@192.168.1.130`.

| Board | Chip | Link | Katapult | App start |
|---|---|---|---|---|
| mainboard `[mcu]` | STM32H750, 25 MHz | USB (USB-CAN bridge) | 128 KiB | `0x08020000` |
| toolhead `[mcu extruder_mcu]` | STM32F103xE, 8 MHz | CAN 1 Mbit/s | 8 KiB | `0x08002000` |

## Official Sovol resources
- Wiki (firmware, recovery image, manuals, changelog): https://wiki.sovol3d.com/en/sovol-zero
- Open-source hardware files (pinouts, STEP models): https://github.com/Sovol3d/SOVOL-ZERO

## Recovery
To restore stock firmware, use the official image from the wiki above
(`H616_2.3.3_debian_sovol-zero-1.4.7.zip`, flashed with an eMMC adapter).
This repo's `sovol-1.4.7-backup` release keeps a copy of that same file, only as a backup in case
Sovol's link goes away. Checksum: `sovol-official/SHA256SUMS`.
Stock toolhead firmware is on the printer at `~/printer_data/build/extruder_mcu_klipper.bin`.
Stock mainboard firmware: `tools/flash-mcu.sh mainboard stock-firmware/stock-mainboard-app.bin` (see `stock-firmware/README.md`).
