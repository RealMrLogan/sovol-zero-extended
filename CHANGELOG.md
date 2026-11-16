# Changelog

Each `## vX.Y.Z` section becomes that release's notes.

## Unreleased

- Sovol's updaters are removed, so releases are installed from `/extended/` only. That's the OTA service
  (taken out of `/boot/scripts/btt_init.sh`, stopped, deleted, and its display menu entry dropped by patch
  0009) and the `_MCU_UP`/`_EXTRUDER_MCU_UP`/`_EXTRA_MCU_UP` board flashers, which bypassed version checks
  and rollback (`_EXTRUDER_MCU_UP` would put the stock toolhead image back). Their macros are removed from
  `get_ip.cfg` and from Sovol's copy that factory reset restores; nothing else in the file changes.
- install.sh's chelper C guard and host-code change log now work: they looked for rsync's remote-transfer
  marker (`<f`), which a local sync never prints.
- Built board firmware reports `zx-<hash of the image>` instead of the release version, so a release only
  reflashes a board whose firmware actually changed.

## v0.2.0

- Config page at `http://<printer>/extended/`: shows the installed release and board firmware, and has the
  first setting, **screen orientation** (landscape, portrait, and both flipped; rotates touch to match).
  Served by a small `zero-config` service behind nginx, allowed for whoever Moonraker allows.
- Update from the config page: choose a release zip, check what it is, Install, and watch the log. The
  install runs as its own systemd job (`zero-install`), so it survives the page's server being updated
- `tools/install-release.sh` installs through the config page instead of running install.sh in the SSH
  session, so a dropped connection can't kill an install halfway; `--follow` reattaches.
  `--force-flash <board>` and `--no-flash` pass through (the API accepts only those). Printers without the
  page still install over SSH.
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
