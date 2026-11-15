# Recovery

What the installer does on its own, and what to do when it can't. Commands run from this repo on a PC
that can `ssh sovol@<printer>` (set `PRINTER=user@host` if it isn't `sovol@192.168.1.130`).

## Handled automatically by install.sh

| Failure | What install.sh does |
|---|---|
| Corrupt or wrong download | `SHA256SUMS` check fails before anything changes |
| Printer is printing or paused | Refuses to start |
| Board image with a wrong start address | Refuses to flash it (`flash-board.sh` checks the reset vector) |
| New host code stops Klipper starting | Restores the previous `klippy/`, restarts Klipper, exits with an error |
| An upstream app (Moonraker, Mainsail, ...) can't be fetched, or its pin changes its dependencies | Refuses before changing anything |
| An updated app's service doesn't come back | Puts every app back on its previous commit/files (and pops stashed local edits), restores `klippy/` |
| A board flash fails or is interrupted | Retries once. The board waits in Katapult, so the retry finds it there |
| A board doesn't come back on the expected version | Flashes that board's previous image back (the last image install.sh flashed, or stock), then restores the previous `klippy/` |

Boards are done toolhead first, and the toolhead is verified before the mainboard is touched.
Rollback was tested on 2026-11-14 with a release that claimed a wrong toolhead version.

Everything install.sh does is logged to `~/zero-extended/install.log` on the printer.
`~/zero-extended/version` only changes after a fully successful install.

## By hand

**Go back to an earlier release**
```sh
tools/install-release.sh v0.1.0          # any earlier tag; add --force-flash <board> to reflash a board
```

**Put a board back on stock firmware**
```sh
tools/flash-mcu.sh toolhead  stock-firmware/stock-toolhead.bin
tools/flash-mcu.sh mainboard stock-firmware/stock-mainboard.bin
```

**Klipper says "Lost communication with MCU" after a failed install**
The board is probably waiting in Katapult. Check the CAN bus, then flash any image to bring it back:
```sh
ssh sovol@<printer> '~/klippy-env/bin/python ~/printer_data/build/flash_can.py -i can0 -q'
#   "Application: Katapult" -> toolhead is in its bootloader: tools/flash-mcu.sh toolhead stock-firmware/stock-toolhead.bin
ssh sovol@<printer> 'ls /dev/serial/by-id/'
#   "usb-katapult_stm32h750xx..." -> mainboard is in its bootloader: tools/flash-mcu.sh mainboard stock-firmware/stock-mainboard.bin
```
If the mainboard is in Katapult, the toolhead is unreachable too (the mainboard is its CAN bridge): fix the mainboard first.

**Host code broken, Klipper won't start**
Backups of the last three `klippy/` folders are in `~/zero-extended/backup/` on the printer:
```sh
ssh sovol@<printer> 'rsync -a --delete ~/zero-extended/backup/<folder>/klippy/ ~/klipper/klippy/ && sudo systemctl restart klipper'
```

**No SSH, or the Linux system is broken**
Reflash the eMMC with Sovol's 1.4.7 recovery image (wiki, or this repo's `sovol-1.4.7-backup` release) using an
eMMC adapter. That restores stock everything; then reinstall a release.

## Not covered in software

**A board image that starts, then hangs.** Katapult only takes over by itself when the image looks invalid,
and the normal route into it (Klipper asking the board to reboot into the bootloader) needs working firmware.
Both bootloaders are built with Katapult's double-reset entry (two resets 10-500 ms apart), confirmed from
their code (FINDINGS.md), but that needs a reset line:
- mainboard: probably the `RESET` pin on the EXP2 header (Sovol's pinout). Untested.
- toolhead: no reset pin documented.

Releases that change board firmware should be tested on one printer, toolhead first, before publishing.
