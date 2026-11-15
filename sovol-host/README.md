# Sovol host software (stock 1.4.7)

Sovol's own scripts, services and system files outside Klipper, extracted from the official
1.4.7 recovery image (`H616_2.3.3_debian_sovol-zero-1.4.7.img`). Paths mirror the printer's filesystem.

- `home/sovol/`: power-loss recovery (`plr.sh`, `clear_plr.sh`), OTA (`ota_client.sh`, `pyhelper/`),
  stock-screen menu patcher (`patch/`), USB automount (`usbmount/`), factory reset, Sovol's flash scripts
  and stock toolhead image (`printer_data/build/`)
- `boot/scripts/`: first-boot and system scripts (Wi-Fi setup server, brightness, RGB, sounds, OTA service)
- `etc/`: systemd units, `can0` interface, udev rules, rc.local, nginx site
- `upstream-versions.txt`: Moonraker, KlipperScreen, Mainsail etc. are unmodified upstream at these commits
- `upstream-diffs/`: the only two edits Sovol made to those upstream apps

The stock `printer_data/config` is in `../stock-config/config/`.
A printer updated by OTA differs slightly from the image (newer usbmount logging, Wi-Fi server run as a
systemd service instead of from `btt_init.sh`); those are Sovol revisions, left as they are.
