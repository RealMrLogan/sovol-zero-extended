# Changelog

Each `## vX.Y.Z` section becomes that release's notes.

## v0.4.1

- KlipperScreen: the screen no longer gets stuck on the boot console or flickers after a start or a rotation.
  Upstream's service file switches to VT 7 after starting, but X runs on VT 2 on the Zero; install.sh now
  comments that line out, and `kbd` (only shipped for it) is no longer installed.
- Config page: the heater calibrations are labelled as PID tuning.

## v0.4.0

- Config page: a setting change or an install is refused while a calibration or an install runs (each restarts
  Klipper, which used to cut the other short). The belt check deletes the previous run's result files first,
  so it can't report on them.
- install.sh, system packages: one already there is never touched (held, or half-installed: refused), and a
  rollback keeps the config files of one that only had those before. dpkg never stops to ask about config
  files. A failing `daemon-reload` no longer stops a rollback partway. A service shared by two apps restarts
  once.
- Tests: board flashing and its rollback (a failed board is flashed back, with every board before it, then
  the host), and flash-board.sh's check of an image's start address. CI checks the SHA-256 of the tools it
  downloads.
- KlipperScreen v0.4.5 → current master (`a12e8dd`, 414 commits): lockscreen, fine-tune panel, Spoolman
  editing, settings in categories, keyboard navigation, a rewritten network panel, and many fixes. Its
  new Python packages ship in the release and install offline.
- System packages: releases can now ship Debian's own `.deb`s (`release/debs.conf`, pinned by sha256),
  installed offline only when apt's simulation finds their dependencies already there, and removed again on
  rollback. The first two are KlipperScreen's: `gir1.2-nm-1.0`, so its network panel uses libnm rather than
  its fallback, and `kbd`, for the `chvt` its service runs.
- Services are set up as upstream's installers do now: KlipperScreen's service file comes from its own
  template (a login session for the screen), and Moonraker starts with `-m moonraker` instead of its legacy
  `moonraker.py` entry point. Both are restored on rollback. Installing an older release afterwards keeps
  them; for KlipperScreen that breaks the screen on its next restart (its old start script under the new
  service), so put Sovol's service file back first: copy
  `~/zero-extended/originals/etc/systemd/system/KlipperScreen.service` (every file a release replaces is kept
  there as it was before, for good) over `/etc/systemd/system/KlipperScreen.service`, then
  `sudo systemctl daemon-reload`.
- Moonraker v0.9.3 → v0.11.0 (`b559b9a`, 187 commits): security fixes in authorization (constant-time
  credential checks, trusted-client checks now include the proxy's address), newer slicer metadata, and
  the replacement of the unmaintained dbus-next. Its new Python packages ship in the release and install
  offline. The database is unchanged, so rolling back to an older release keeps print history.
- Config page: if power was lost just as an install started, the Update section failed to load until the
  next install. It now shows the whole install log instead.
- Code cleanup, no behaviour change: the config page's JavaScript posts through one helper, the resonance
  test's 133 Hz top is one constant, and a few names say what they hold. Docs brought up to date.
- install.sh: the one-way removals of Sovol's leftovers (its updaters, Obico) moved to `sovol-cleanup.sh`,
  called at the same points, so install.sh stays the install flow. Patch 0010 also drops the "Install Obico"
  name from the stock menu's code.
- Klipper: Sovol's pressure probe module (patch 0005, `probe_pressure.py`) is removed. Sovol stopped using it
  in 1.4.2 and no config loads it; the next install deletes it from `~/klipper/klippy/extras/`.
- Logging: the config page writes `~/printer_data/logs/zero-config.log` (listed in Mainsail with Klipper's
  logs): setting changes (old -> new), calibration start, result and failures with their traceback, and
  install starts. Before, these were only on the page, or in a journal Sovol caps at 20 MB (about 30 min).
  The install log timestamps every line and lists the Python packages an install changed (old -> new).
- Tests: the config page's server (cross-site refusal, input validation, its log) and the dependency rules
  make-release.sh applies to app pins, now shared with build-wheels.sh in `tools/app-deps.sh`.
- install.sh installs an app's Python requirements when its pin changes them (`apps.conf`'s new pip
  column), offline, from wheels shipped in the release (`apps/wheels`). It backs up the app's venv first and
  restores it on rollback. Before, any pin that touched a dependency file was refused.
- Releases: `tools/build-wheels.sh` builds those wheels for the printer (arm64, Python 3.9, Debian 11), in CI
  in an emulated Debian 11 container, only when a pin needs them. `make-release.sh` now refuses a pin that
  changes system packages (install.sh can't install them) unless it's listed in `release/sysdeps-checked`
  as checked by hand, and a pin that changes the Python requirements of an app without a pip column.

## v0.3.0

- moonraker-obico is removed (it was never linked): its service, `~/moonraker-obico` and its venv, its
  config files and `printer.cfg` include, its macros in `get_ip.cfg` (live and factory-reset copies) and the
  stock screen's Setup > Link Obico menu (patch 0010). It goes only after a successful install, since an
  older klippy's menu needs its macros. One-way: installing an older release doesn't bring it back, and that
  release's Link Obico menu entry won't work.
- Upstream apps: Mainsail 2.13.2 → 2.19.0; mainsail-config → `ff3869a` (jogging from Mainsail no longer leaves
  the printer in relative or absolute mode); crowsnest 4.1.9 → 4.2.0 (`cf936da`, fixes only). KlipperScreen's
  source now points at its new home, github.com/KlipperScreen/KlipperScreen (same code).
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
- install.sh: a rollback compares file contents when restoring klippy/, the apps and the config page. Before,
  a release file with the same size and timestamp as the one it replaced was left in place.
- Tests: `tools/test.sh` runs the config page's self-checks, an install.sh test against a fake printer
  (install, re-install, refusal during a print, rollback) and shellcheck; CI runs it before every build.
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
