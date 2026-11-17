# Upstream update plan

Goal: every upstream on its current version, with everything the printer does today still working.
Status (2026-11-16): steps 1 and 2 are released (v0.3.0), step 0's pip half is on `main`; each step says
where it stands. Researched 2026-11-15 (read-only: scratch clones, PyPI metadata, the printer
over SSH, and Klipper master run in batch mode against the printer's config and the stock images' data
dictionaries). "Inferred" marks what was read in code but not run.

## Where everything stands

| Upstream | Pinned now | Target | Blocker |
|---|---|---|---|
| mainsail-config | `e57810d` (v1.2.1) | `ff3869a621db17ce3ef660adbbd3fa321995ac42` | none |
| Mainsail | v2.13.2 zip | v2.19.0 zip, sha256 `c4d9d96f89851c6ae0709c2f20725447f3fe8c57cf193869b0083441bd93378a` | none |
| crowsnest | `d75a3ae` (v4.1.9-1) | v5 (`436042452f564f3d737e3b980a213f849a8a0562` = v5.0.12); master `cf936dabdcf6a3d1eb0138d8eea9044745b40db6` (v4.2.0 + a changelog commit) as a stepping stone | apt + venv in install.sh |
| moonraker-obico | `4c0b7b6` | **removed** (not used) | removal steps below |
| moonraker-timelapse | `c7fff11` | `c7fff11` (upstream `main` hasn't moved) | none |
| Moonraker | `4e00a07` (v0.9.3-1) | `b559b9a81161f958a43c2f527b6ad96f73310d5d` (v0.11.0+4) | **pinned** (step 3) |
| KlipperScreen | `7127b5d6` (v0.4.5-3) | `a12e8dde55d79774f9dfc5c59a61854f3f5c0184` (master, 2026-11-15) | **pinned** (step 4) |
| Klipper | `faa89be` (2024-10-28) + patches | master (`29d4ec2d6` at research time) | patch rebase, probe rewrite, toolhead reflash |

Targets are the newest commits at research time; recheck before each step and take newer ones if they
don't add new requirements.

## Step 0: install.sh has to manage dependencies

Before this step, install.sh refused any app pin whose diff touched a dependency file (a `DEPS` regex) and
installed no packages itself. Moonraker, KlipperScreen and crowsnest v5 all change dependencies, so this
comes first.

pip done (2026-11-16), not yet released: `apps.conf` pip column, offline install from `apps/wheels` with venv
backup and rollback (`tests/install-test.sh`), `tools/build-wheels.sh` + a CI job (QEMU, untested in CI),
and build-time refusal of system-package changes (`release/sysdeps-checked` lists reviewed exceptions).
Tried on the printer with the step 3 and 4 targets: the wheels built on Debian 11 arm64 (pycairo and
streaming-form-data from source, ~10 min native); offline installs into copies of both venvs changed only
what the new requirements need, `pip check` clean, pip 20.3.4 took the `manylinux_2_28` sdbus wheel, and
pycairo 1.28.0 imports against the printer's cairo 1.16. Moonraker `b559b9a` changes
`system-dependencies.json`, so step 3 has to review it and add it to `release/sysdeps-checked`.
apt (crowsnest v5) is left for step 6. App removal was done for obico alone (step 2).

`.deb`s done (2026-11-17, step 4), not yet released: `release/debs.conf` lists Debian's own packages by
version, sha256 and archive.debian.org URL; make-release downloads and checks them into `debs/`. install.sh
adds only missing ones, before any change refuses them unless `apt-get -s` would install exactly those (it
checks dependencies; `dpkg --dry-run -i` doesn't: it passed a backports build whose libnm0 the printer
lacks), and purges them on rollback. Upgrading an already installed package is refused for now (the rollback
would need its old `.deb`); step 6 (crowsnest v5) needs that.

- **Fix the regex.** It refuses harmless files (Moonraker `docs/doc-requirements.txt`,
  `docs/pymdown-extras/setup.py`) and misses real ones (crowsnest `tools/libs/pkglist-*.sh`).
- **pip:** ship a cp39 / aarch64 wheelhouse in the release zip and install with
  `pip install --no-index --find-links`, so installs stay offline. Build it in CI with
  `pip download --platform manylinux2014_aarch64 --python-version 39 --only-binary=:all:`, or on an arm64
  runner. Packages without a wheel need a decision. pycairo 1.28.0 (KlipperScreen) is sdist only; the
  printer has gcc but its cairo headers are unverified. streaming-form-data (Moonraker) has no aarch64
  wheel, but the installed 1.15.0 satisfies the range.
- **Rollback:** back up each venv (`cp -a`) before changing it and restore it in `restore_host`. Today
  rollback only checks out the old commit.
- **apt (crowsnest v5 only):** packages come from apt.mainsail.xyz (`debian bullseye generic` arm64 exists,
  e.g. `mainsail-ustreamer 6.65.bullseye`). Needs network at install time, or `.deb`s shipped in the zip.
  apt would install libevent / libjpeg62-turbo / libgpiod2 over files Sovol copied in by hand (dpkg
  doesn't know them): check that this is clean first.
- **Removing an app:** obico needs install.sh (or a one-time step in it) to stop, disable and delete an
  app that apps.conf no longer lists.

The printer's pip is 20.3.4. Check it accepts `manylinux_2_28` wheels (sdbus for KlipperScreen) with glibc
2.31 before relying on them.

## Step 1: bumps with no new requirements (one release)

Done (2026-11-16, nightly `ccf6ae5`): pins set in `release/apps.conf`; rechecked, no newer targets. Tested on
the printer: Mainsail and `/extended/` load, a jog through `_CLIENT_LINEAR_MOVE` leaves G90 set, and the
webcam streams after a cold boot. The crowsnest
bump changes `tools/libs/pkglist-*.sh` (adds `pkg-config`, only for building ustreamer); its runtime
scripts need nothing the printer lacks.

- **mainsail-config → `ff3869a`.** Only adds `_CLIENT_LINEAR_MOVE`, which Mainsail ≥2.13 detects and
  uses for jog/extrude/move-to, so a jog no longer leaves G90/G91 changed. Works with old and new Klipper
  (`client.cfg` reads only `.x/.y/.z` and long-standing fields). Sovol's `Macro.cfg` still overrides
  PAUSE/RESUME/CANCEL_PRINT after it; unchanged.
- **Mainsail → v2.19.0.** `minMoonrakerVersion` (v0.8.0-306) and `minKlipperVersion` (v0.11.0-257) are
  unchanged since 2.13.2; no new Moonraker RPC methods; nothing marked breaking in 2.14 to 2.19;
  `config.json` is the upstream default (kept anyway).
- **crowsnest → master `cf936da`** (v4.2.0 plus a changelog-only commit, 2026-04-17). Fixes only (46 commits). `bin/build.sh` now targets ustreamer v6.36 but a pull
  doesn't rebuild; the printer keeps its v6.10 binary (inferred to work; it only logs "update available").
  master is frozen at v4.2.0; upstream's default branch is now `v5`.
- **KlipperScreen URL:** the repo moved to `https://github.com/KlipperScreen/KlipperScreen` (same history).
  Update `release/apps.conf`; no pin change needed.

Test: pages load, jog leaves the mode unchanged, webcam streams after a reboot.

## Step 2: remove moonraker-obico

Done (2026-11-16, v0.3.0, installed and checked on the printer): `release/sovol-cleanup.sh` (after a
successful install), `apps.conf` and patch 0010; covered by `tests/install-test.sh`. The commented
`#[include moonraker-obico-update.cfg]` in `moonraker.conf` stays (a comment; moonraker.conf is untouched).

Not used (never linked: no `auth_token`). Everything that refers to it:

- Printer: `moonraker-obico.service` (enabled), `~/moonraker-obico`, `~/moonraker-obico-env`,
  `~/printer_data/logs/moonraker-obico.log`.
- Config: `printer.cfg` `[include moonraker_obico_macros.cfg]`; `moonraker_obico_macros.cfg`,
  `moonraker-obico.cfg`, `moonraker-obico-update.cfg`; the commented
  `#[include moonraker-obico-update.cfg]` in `moonraker.conf`.
- `get_ip.cfg` (both `~/printer_data/config/` and `~/patch/config/`): `[gcode_shell_command obico_restart]`,
  `_OBICO_RESTART`, `_OBICO_CODE_GET`, `[delayed_gcode code_display]`. Strip these the same way install.sh
  already strips the OTA macros (keep CRLF).
- **Stock screen menu:** `[menu __main __setup __obico_link]` and its two children (patch 0003, also in
  `~/patch/menu.cfg`) read `printer["gcode_macro OBICO_LINK_STATUS"]`. Remove the menu entries in the
  same release as the macros (new patch like 0009), or the menu breaks.
- Repo: `release/apps.conf` line; `~/moonraker-obico/include_cfgs/KlipperScreen.conf` is the only
  KlipperScreen.conf on the printer. It goes with obico, and KlipperScreen runs on defaults (verify).

Removal is one-way, like the OTA removal: rollback doesn't reinstall it.

## Step 3: Moonraker → `b559b9a`

Pinned (2026-11-17), not yet released; rechecked, still upstream master. Tested on the printer before
pinning: the wheels installed offline into a copy of `moonraker-env` (`pip check` clean; only apprise,
dbus-fast, inotify-simple, Jinja2 and paho-mqtt changed), and `b559b9a` ran from it on port 7126 against
the live Klipper: no failed components, history, timelapse and file APIs answer, `/access/user` gives 200
for a LAN address forwarded by 127.0.0.1 and 401 for an outside one. System packages reviewed and listed in
`release/sysdeps-checked`.

- **Python:** pyproject says ≥3.10 (245f718), but the changelog says running from source (how the
  printer runs it) still works on 3.7+. Verified: every file parses with the 3.9 grammar, and it runs on
  the printer's 3.9.2 (above).
- **Deps:** `dbus-next` → `dbus-fast` (fccffa9). `dbus_manager` is core and imports it at load, so it must
  be installed or Moonraker won't start. Its startup "pip recovery" would try the network. Also apprise
  ≥1.9.3, paho-mqtt 2.1.0, inotify-simple 2.0.1, jinja2 3.1.6; pyserial-asyncio dropped. All have 3.9
  versions with aarch64/cp39 or pure wheels (tornado 6.5.8, pillow 11.3.0, zeroconf 0.148,
  dbus-fast 2.45.1, apprise 1.13, importlib_metadata 8.7.1).
- **System packages:** only Ubuntu/RPi conditionals added; nothing for Debian 11 (inferred).
- **Auth:** trusted-client auth now also checks the proxy IP (2ed3f34); nginx is 127.0.0.1, inside
  `trusted_clients`, so `/extended/`'s `auth_request` to `/access/user` keeps working (inferred). Keep
  `use_xheaders` at its default. v0.11.0 returns 401 for a bad API key; b559b9a includes the partial
  revert (fbfe348).
- **Config / database:** the printer's moonraker.conf is Sovol's stock and uses nothing renamed. No schema
  migrations, so rollback is safe. Optional: `[announcements] enable_moonlight: False`. Keep
  update_manager off.
- **Timelapse** still works against HEAD (its API calls all exist). It's wired in by an untracked symlink
  in `~/moonraker/moonraker/components/`, which survives the checkout.
- Works with old and new Klipper (inferred).

Test before pinning: install the wheels into a copy of `~/moonraker-env` on the printer and start
Moonraker from it on another port.

## Step 4: KlipperScreen → `a12e8dd`

Pinned (2026-11-17), not yet released: master, not the planned `26d2625`, with its setup brought up to
what its installer does now, so nothing runs on a fallback. Tested on the printer before pinning (each test
reverted):

- The wheels installed offline into a copy of `.KlipperScreen-env` (`pip check` clean; jinja2, pycairo
  1.28.0, requests, sdbus 0.14.3 and websocket-client changed), and `a12e8dd` ran on the screen through the
  service (its new `KlipperScreen-start.sh`, X): 600x1024, connected, Klipper ready, main menu built.
- **`gir1.2-nm-1.0`** (shipped, `release/debs.conf`): without it the network panel falls back to its sdbus
  code. With the package's typelib, KlipperScreen's libnm client listed `wlan0` and 10 networks against
  the printer's libnm 1.30.6.
- **Service file:** install.sh fills in upstream's `scripts/KlipperScreen.service` as its installer does.
  New against Sovol's: `PAMName=%u` (a logind session on tty7, seen as `c1 sovol seat0 tty7`),
  `CapabilityBoundingSet=~CAP_WAKE_ALARM` and `ExecStartPost=+chvt 7`. install.sh comments out the `chvt 7`
  (as upstream's installer does on systems without a VT): X here starts on the first free VT, 2, not the
  session's tty7, and switches to it itself. When `chvt 7` ran after that, the screen was left on the boot
  console, or flickered (seen); without it, ten restarts all ended on VT 2. So `kbd`, which upstream's
  installer adds for `chvt`, isn't shipped. Run as a release installs it (`a12e8dd`, its venv, both `.deb`s,
  the new unit): three restarts each left one xinit/Xorg/KlipperScreen and a stop left none, the network
  panel imports libnm. After a manual stop the unit reads `failed` (xinit exits non-zero; from upstream's
  `exec xinit`). **Under `PAMName`, X and KlipperScreen live in the login session's scope**, outside the
  service: systemd stops them only through the main PID, which works because `a12e8dd`'s start script
  `exec`s xinit. Sovol's older script doesn't, and with it a restart left the old X holding `:0` (seen in
  testing). install.sh's rollback restores the old unit with the old tree, but installing an older
  release later keeps the new unit with the old script; put the old unit back first (see CHANGELOG). PolicyKit: the printer's polkit is 0.105, for which upstream
  still writes the `.pkla` the printer has; the `network` group it adds is only used by newer polkit rules.
- **Moonraker:** install.sh rewrites `moonraker.env` as Moonraker's installer does now (`-m moonraker`,
  `PYTHONPATH`, `MOONRAKER_DATA_PATH`); Sovol's started `moonraker/moonraker.py`, upstream's "legacy entry
  point". Sovol's Moonraker (`4e00a07`) runs that way too (tested on port 7126), so a rollback works. Its
  unit is upstream's SV1 (Moonraker validates it as current); its PolicyKit script is unchanged since stock.

The Network panel wasn't opened on the screen; check it after installing.

- 414 commits: lockscreen, fine-tune panel, Spoolman edits, keyboard navigation, settings in categories,
  optional Unix-socket connection, Wayland support. KlippyRest is gone (all websocket RPC); Spoolman
  options reworked; the macro shortcut now defaults off.
- **Python:** still ≥3.8. **Deps:** jinja2 3.1.6, requests 2.32.5, pycairo 1.28.0 (sdist),
  psutil <7.2.0, websocket-client 1.9.0, sdbus ≥0.14.3, PyGObject <3.51 (3.50.0 installed already).
- `a451d9d` adds the apt package `gir1.2-nm-1.0` (libnm networking): shipped (above), and the pin is listed
  in `release/sysdeps-checked`. Later commits are fixes (Wi-Fi device re-resolve, popups, settings
  combobox, `Gtk.Label(label=...)`).
- `KlipperScreen-start.sh` still runs `xinit` for X.
- **Rotation stays ours.** Upstream: "Rotation is handled by the OS and not by KlipperScreen". The
  orientation setting in `release/zero-config/settings.py` stays. The `Screen resolution: WxH` log line
  it waits for is still at `screen.py:147`.
- Moonraker RPC methods it calls all exist in 0.9.x (inferred), so it doesn't strictly need step 3 first.

## Step 5: Klipper → master (its own branch and release series)

### Patches against master

Ported on branch `klipper-master`, against master `29d4ec2d6` (2026-11-10). `patches-stock/` keeps Sovol's
series on `faa89be8` (its `PIN`) for the byte-identical toolhead check; `patches/` is the master series. Each
commit message says what was kept and dropped.

| Stock | Master | What happened |
|---|---|---|
| 0001 H750 128 KiB offset | - | dropped: upstream |
| 0002 fixed chip ids | 0001 | clean |
| 0003 UC1701, fonts, ws2811 | 0002, 0009 | Sovol's per-error i2c recovery dropped (an i2c error now shuts down, as upstream). But the LDC1612 NACKs the first transfer after every toolhead reset, which Sovol's retries hid: 0009 recovers the bus at setup and sends the sensor one throwaway transfer (found on hardware, 2026-11-17) |
| 0009, 0010 menu removals | 0003, 0004 | clean on 0002 |
| 0006 shutdown / tip codes | 0005 | onto master's `idle_timeout` status and lis2dw/lis3dh id check |
| 0007 scheduling / move queue | 0006 | **"Timer too close" shutdown restored** (Sovol pushed late timers back 50 ticks, hiding late steps); kept the 50 ms trsync timeout, 4096-entry move queue and the shutdown code for the stock screen; dropped never-incremented debug counters |
| 0008 assorted host | 0007 | kept shell command, start-print events, tip codes, shaper result for the stock screen; dropped chelper no-rebuild, configfile hacks, toolhead constants, hidden files listing, `GET_GCODE_STATE`/`SOVOL_GET_STATE` (unused), and **power-loss recovery** (below, Later) |
| 0004 eddy contact homing | 0008 | rewritten: `[z_offset_calibration]` keeps Sovol's commands on upstream "tap" (below); only the homing tip codes kept |

**`Z_OFFSET_CALIBRATION` and `RUN_PROBE_VIR_CONTACT` on tap** (`klippy/extras/z_offset_calibration.py`):
Sovol's macros (`CLEAN_NOZZLE`, `START_PRINT`, `BED_MESH_CALIBRATE`) and the stock menu call them, so they
keep their names and Sovol's config options (`vir_contact_speed` is read but unused: `tap_threshold` scales with probe speed, so taps run at the speed it was calibrated at).
`RUN_PROBE_VIR_CONTACT` taps from Z 5 and leaves the nozzle at the contact height, as Sovol's macros
expect. `Z_OFFSET_CALIBRATION` heats (bed `BED_TEMP`, nozzle 130 °C), homes, taps at
`endstop_xy_position` until two touches agree within 0.0125 mm, and sets the g-code Z offset to the contact
height. Sovol instead recalibrated the eddy sensor from the contact point every print. A tap that fails to
detect contact is retried twice (a hot nozzle with filament on it blurs one; Sovol's touch retried too).
Before either works: `tap_threshold` in `printer.cfg`. The stock `stepper_z` already allows
`position_min: -5`.

**`tap_threshold`: 12000, set by hand, not the tool's value.** `PROBE_EDDY_CURRENT_TAP_CALIBRATE` (guess,
refine, verify) chose 7083 cold and 6858 with the bed at 65 °C, and its verify passed, but at those values
the nozzle pressed only 0.018-0.029 mm into the bed, so taps randomly failed tap's 0.03 mm minimum. At 12000
five taps in a row pressed 0.096 mm and agreed within 0.007 mm (the tool's upper bound was ~30900).
Contact measured 0.66-0.76 mm above the eddy's zero, varying with temperature: what the per-print
calibration corrects.

**Hardware test, 2026-11-17** (dev builds of this branch): toolhead flashed (with Katapult as fallback);
G28 with eddy homing; `PROBE_ACCURACY` range 0.005 mm, stddev 0.0014 mm; tap calibration; Sovol's whole
print start (two cleaning touches at 200 °C, `Z_OFFSET_CALIBRATION`, rapid-scan mesh). Found and fixed on
the way: the LDC1612 NACKing the first transfer after every toolhead reset (patch 0009), `max_sensor_hz`
(the sensor reads ~6.03 MHz, Klipper's default is 5 MHz; set in `zero-extended.cfg`), master's rename of
`gcode_move.absolute_extrude`, and power-loss recovery's per-move fsync stalling the reactor into "Timer too
close" (removed). Python changes need a Klipper *service* restart: `RESTART`/`FIRMWARE_RESTART` keep the
already-imported modules.

**Downgrade:** an older release's install.sh refuses this one's chelper C (Sovol's tree can't rebuild
`c_helper.so`). And once `tap_threshold` is saved, Sovol's Klipper rejects the option: remove it from
`printer.cfg`'s SAVE_CONFIG block before going back.

### What else changed upstream that matters here

- Eddy/probe: `probe_eddy_current.py`, `ldc1612.py`, `src/sensor_ldc1612.c` rewritten; MCU
  `ldc1612_setup_home` replaced by generic `trigger_analog` + `sos_filter`; 400 sps (d2aa4bd7e);
  `z_offset` → `descend_z` (20df766e2, old name accepted with a warning).
- MCU protocol: i2c → `i2c_transfer`/`i2c_response` (host falls back, `bus.py:228`); multi-value
  `analog_in_state` (host keeps the old handler); `config_lis2dw` format changed (018102395);
  `spi/i2c_set_sw_bus` renamed; new `canbus_status`.
- stm32/CAN/USB: usb_canbus stall detection and echo ordering (2c90c97cc, 941fb5a36), can.c error
  interrupts (8176ba22a), H7 clock/VOS fixes, larger canserial tx buffer (85c79bc44).
- Input shaper: Z-axis shaper (caf7accf2), new recommendations (c339bb0cd). Bed mesh: small fixes.
- Python: master still runs on 3.9. All 180 klippy files compile under the printer's 3.9.2. Requirements
  for Python <3.12 are unchanged and already installed; `msgspec` is optional.
- The printer's config runs on master in batch mode. The only rejected options are ones the Sovol
  patches add (`vir_contact_speed`, `[z_offset_calibration]`, `[gcode_shell_command]`). Everything else
  is accepted.

### Boards

- **Toolhead must be reflashed.** Verified in batch mode: master against the stock toolhead dictionary
  fails on `trigger_analog_query_state`, then `config_lis2dw`. Unpatched v0.13.0 fails too (Sovol added
  `homing_method` to `ldc1612_setup_home`). Carrying Sovol's protocol forward isn't practical.
- **Mainboard built from master too** (`boards.conf: build`). Master configures the stock mainboard
  dictionary, but the stock image has Sovol's older protocol. The master image runs the H750 at 480 MHz, not
  stock's 400 (upstream `43f9219cf`; `CLOCK_FREQ` has no prompt, so `configs/mainboard.config`'s value is
  ignored). Flashed and power-cycled on hardware 2026-11-17: both boards and the CAN bridge came back.
- **Reproducibility check:** the byte-identical toolhead check proves the extraction of Sovol's tree, not
  the new image. Keep it as a frozen CI job (old pin + current patches moved to e.g. `patches-stock/`).
  The new toolhead image becomes `boards.conf: build`.
- gcc 8.3.1 building master is **unverified**. So is the image size (stock toolhead is 31.8 KB of 56 KB).

### Hardware test (in order)

1. Flash the toolhead; CAN uuid still `61755fe321ac`; LDC1612 reads.
2. `PROBE_EDDY_CURRENT_CALIBRATE`, tap calibrate, `G28 Z`, rapid-scan bed mesh.
3. lis2dw resonance test, stock screen and menus, fan-fault and shutdown codes.
4. A long print, watching for timer errors.
5. Reflash the mainboard on master; recheck the ws2811 power-on LEDs (FINDINGS.md).

Katapult answers on the chip's real CAN uuid, so a bad toolhead flash is recoverable (RECOVERY.md).
The stock screen's z-offset/calibration flow changes behaviour with the move to tap.

## Step 6: crowsnest → v5

A rewrite: Python package in `~/crowsnest-env`, ustreamer/camera-streamer from apt.mainsail.xyz (builds
from source if the apt source fails), new service template (StartLimitBurst=3, RestartSec=30, no
`Before=nginx`). Supports Python 3.9. Migration is upstream's `make upgrade`: it rewrites crowsnest.conf
(drops `log_path`, `enable_rtsp`, `rtsp_port`; `delete_log` → `rollover_on_start`), reinstalls the unit
and switches branch. install.sh has to do the equivalent offline, or require network for this one
release. Needs step 0's apt and venv support.

**Startup delay:** upstream still exits on "No usable Devices Found" rather than waiting for the camera
(v4 `libs/logging.sh:97`, v5 `logging_helper.py:119`). Both versions have a boot-only delay (v4 `-s`,
v5 `--sleep_boot`, applied while uptime < 120 s). Our drop-in (`release/systemd/crowsnest-zero.conf`)
still works on v5 and stays. `-s 6` in `~/printer_data/systemd/crowsnest.env` would avoid delaying manual
restarts, but that file is user data.

## Later

Not upstream updates, but planned. Each needs its own look before work starts.

### Speed

- **Build (~9 min, ~7½ of it wheels):** every build compiles the wheels again, under QEMU, because the pins'
  requirements differ from Sovol's stock and always will. Cache the `wheels` job's output in CI, keyed on
  the two requirements files (a few workflow lines; skips the 7½ min when they haven't changed). Once the
  repo is public, build on GitHub's native arm64 runners (`ubuntu-24.04-arm`, free for public repos) instead of
  QEMU.
- **Install (~80 s, v0.4.0 nightly):** ~40 s is pip installing the new requirements (only when a pin changes
  them), ~15 s restarts and waiting for Klipper. Nothing big to win without dropping checks.
- **Boot (18.5 s to multi-user: 6.9 s kernel + 11.7 s userspace):** the slowest units don't hold up Klipper,
  which starts at 3.4 s: `rc-local` (8.0 s, Sovol's `btt_init.sh` and the scripts it starts) and crowsnest
  (6.0 s, our deliberate camera delay). First measure what matters, Klipper `ready` and the screen usable
  after a cold boot (from the journal), then decide whether any of Sovol's boot scripts can go.

### Operating system

The printer runs Debian 11 (Python 3.9.2), whose Python is past end of life (Oct 2025) and whose LTS
support has ended or is ending (check the date). Everything pinned so far runs on 3.9 (Moonraker on its
`< 3.10` code paths, KlipperScreen on its 3.9 compatibility pins: older requests, pycairo, psutil,
websocket-client). Held off for now (2026-11-17). Options when an upstream drops 3.9:

- **A standalone Python for the apps** (e.g. a prebuilt 3.12 beside the system one): the OS is untouched,
  all three venvs (klippy, Moonraker, KlipperScreen) are rebuilt on it, wheels built for it, ~100 MB more
  per release. install.sh's rollback has to keep the old interpreter. The safer option.
- **Debian 12** (Python 3.11): every system package changes under Sovol's 5.16 kernel and the libraries
  Sovol copied in by hand. A failed boot needs the eMMC adapter. Only with a tested image-level fallback.

### Feature: power-loss recovery

**Removed at step 5** (2026-11-17). Sovol's version recorded progress in `cmd_G1`: on every G1 with X, Y and
Z from a file (every z-hop travel), it reread `saved_variables.cfg` with configparser and rewrote and fsynced
`~/sovol_plr_height`. On Klipper master that blocked the reactor up to 1.4 s (38 stalls in 3 minutes of a
Benchy) and the toolhead shut down with "Timer too close" at layer 12; Sovol had disabled that check and
enlarged Klipper's buffers. The hook, the stock menu's `__resume`, `plr.cfg`, the `START_PRINT`/`END_PRINT`/
`CANCEL_PRINT` lines that used it, `plr.sh`, `clear_plr.sh` and `~/sovol_plr_height` are gone
(`sovol-cleanup.sh`'s `remove_plr`, after a successful install). `saved_variables.cfg` keeps its keys, with
`was_interrupted = False`: Sovol's menu code reads it at startup.

Its resume was also weak: positions set to 0,0,0 without homing Z, fixed preheats, Cura-only temperature
keys (OrcaSlicer files resumed without them), and the move under way at the cut lost or doubled.

A replacement, once everything is current, should:
- record off the reactor (a timer or thread, a few times a minute or per layer), never per move, and not
  fsync on the print's path;
- record what resuming needs: file, byte position of the last *finished* move, Z, temperatures, fan, E mode;
- resume with Z homed or probed (tap can find the print's top), and work with OrcaSlicer's files;
- be offered in KlipperScreen and Mainsail, not only the stock display.

## Customizations that go away

- Klipper patch 0001 (0005 is already gone); 0008's chelper, toolhead and `-backup` hunks; most of 0004.
- moonraker-obico entirely (step 2).
- The byte-identical check moves from the release build to a frozen job.

Everything else stays: KlipperScreen leaves rotation to the OS, crowsnest still doesn't wait for the
camera, and Sovol made no other changes to these apps (checked against `sovol-stock-reference`).
