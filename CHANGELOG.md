# Changelog

Each `## vX.Y.Z` section becomes that release's notes.

## v0.1.2

- Config page at `http://<printer>/extended/`: shows the installed release and board firmware, and has the
  first setting, **screen orientation** (landscape, portrait, and both flipped; rotates touch to match).
  Served by a small `zero-config` service behind nginx, allowed for whoever Moonraker allows.
- install.sh retries once with `FIRMWARE_RESTART` when Klipper comes back in shutdown/error (a rare klippy
  startup race on the CAN toolhead left the MCU shut down, which a service restart can't clear)

## v0.1.1

Upstream apps are now pinned and installed by releases, like Klipper. Same versions as stock 1.4.7.

- Moonraker, moonraker-timelapse, moonraker-obico, KlipperScreen, crowsnest and mainsail-config are put on
  their upstream commits (`release/apps.conf`); local edits in them are stashed
- Mainsail v2.13.2 is replaced by the official release zip (Sovol's copy had converted line endings)
- crowsnest's 6 s start delay moves from an edit in `~/crowsnest` to a systemd drop-in

## v0.1.0

Stock Sovol Zero firmware 1.4.7, repackaged. Nothing changes on a stock printer: installing
copies identical host code and flashes no board. It exists to prove the release pipeline.

- Host: Sovol's 1.4.7 Klipper (upstream `faa89be8` + `patches/`), identical to the official recovery image
- Toolhead firmware: Sovol's stock image (`cc8afd8-dirty-20250310_015728-SPI-XI`)
- Mainboard firmware: the stock image read back from a 1.4.7 board (`14d7b18-dirty-20250210_015142-SPI-XI`)
