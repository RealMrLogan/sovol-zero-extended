# Changelog

Each `## vX.Y.Z` section becomes that release's notes.

## Unreleased

- Config page: a Calibration section runs input shaping, a CoreXY belt check (both belts' resonance
  spectra, graphed, with a verdict) and bed/nozzle heater PID tuning, and saves results with Klipper's
  SAVE_CONFIG (after a restart, so Sovol's leftover per-print eddy calibration isn't saved with them). It
  also flags what Sovol's defaults leave behind: input shaping off, factory bed tuning.
- Config page settings: X/Y motor current (Stock 3.5 A / Quiet 2.5 A / Low 1.5 A) and an acceleration limit that caps
  what any print file asks for (Sovol's profiles use 40,000 mm/s²), including "From input shaping".
- `zero-extended.cfg`: Klipper settings this firmware owns, included at the end of `printer.cfg` and of
  Sovol's factory-reset copy, so they win over Sovol's values and survive a factory reset. It widens the
  resonance test from Sovol's 35-45 Hz (SHAPER_CALIBRATE can't recommend a frequency it didn't test, so the
  display's Input Shaping always landed near 40 Hz; one Zero measured 72.8 Hz on X and 53.2 Hz on Y) and
  sets Klipper's default damping (Sovol: 0.001). Rerun input shaping after installing.
- Config page: refuses cross-site POSTs. Moonraker trusts every LAN address, so before this any web page open
  on the LAN could upload and install a release. Malformed requests now get a 400 instead of a dropped
  connection, and an install that was killed (power loss, reboot) no longer shows as successful.
- install.sh: if a board fails, every board flashed so far goes back to its previous image before the host is
  restored, so old host code never runs against new board firmware. Previous images are copied into the
  backup first (the "last flashed" record is overwritten during the install).
- install.sh: the chelper and app-dependency guards no longer depend on `grep -q` in a pipeline (SIGPIPE
  under pipefail could skip them), and a failing rsync now triggers the rollback instead of reading as
  "no changes". Rollback only pops stashes this run made, and leaves `get_ip.cfg` alone (removing Sovol's
  updaters is one-way).
- flash-board.sh: a mainboard already waiting in Katapult (an interrupted flash) can be flashed again;
  the retry and rollback used to stop at the missing `can0`.
- tools: `flash-mcu.sh` stops if uploading the image fails (it used to flash the last build instead),
  `install-release.sh --follow` prints the log exactly and stops when there's nothing to follow, and
  `deploy-host.sh` warns that chelper C edits don't take effect.

## v0.2.1

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
