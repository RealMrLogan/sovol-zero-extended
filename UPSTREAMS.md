# Upstream update plan

Goal: every upstream on its current version, with everything the printer does today still working.
Nothing here is done yet. Researched 2026-11-15 (read-only: scratch clones, PyPI metadata, the printer
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
| Moonraker | `4e00a07` (v0.9.3-1) | `b559b9a81161f958a43c2f527b6ad96f73310d5d` (v0.11.0+4) | pip deps in install.sh |
| KlipperScreen | `7127b5d6` (v0.4.5-3) | `26d262522b9bd9fe7d67f67d3c6f90aa156d1b07` (≈v0.4.8) | pip deps in install.sh |
| Klipper | `faa89be` (2024-10-28) + patches | master (`29d4ec2d6` at research time) | patch rebase, probe rewrite, toolhead reflash |

Targets are the newest commits at research time; recheck before each step and take newer ones if they
don't add new requirements.

## Step 0: install.sh has to manage dependencies

Today install.sh refuses any app pin whose diff touches a dependency file (`DEPS` regex) and installs no
packages itself. Moonraker, KlipperScreen and crowsnest v5 all change dependencies, so this comes first.

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

In progress (2026-11-16): pins set in `release/apps.conf`; rechecked, no newer targets. The crowsnest
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

- **Python:** pyproject says ≥3.10 (245f718), but the changelog says running from source (how the
  printer runs it) still works on 3.7+. Verified: every file parses with the 3.9 grammar and the code
  keeps its `sys.version_info < (3,10)` fallbacks. Not run on 3.9.
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

## Step 4: KlipperScreen → `26d2625`

- 414 commits: lockscreen, fine-tune panel, Spoolman edits, keyboard navigation, settings in categories,
  optional Unix-socket connection, Wayland support. KlippyRest is gone (all websocket RPC); Spoolman
  options reworked; the macro shortcut now defaults off.
- **Python:** still ≥3.8. **Deps:** jinja2 3.1.6, requests 2.32.5, pycairo 1.28.0 (sdist),
  psutil <7.2.0, websocket-client 1.9.0, sdbus ≥0.14.3, PyGObject <3.51 (3.50.0 installed already).
- Master after `26d2625` (a451d9d9, 2026-11-15) adds the apt package `gir1.2-nm-1.0` (libnm networking,
  with an sdbus fallback). That's why the target stops before it.
- The installed systemd unit isn't regenerated by a pin change, so the new unit template doesn't apply.
  `KlipperScreen-start.sh` still runs `xinit` for X.
- **Rotation stays ours.** Upstream: "Rotation is handled by the OS and not by KlipperScreen". The
  orientation setting in `release/zero-config/settings.py` stays. The `Screen resolution: WxH` log line
  it waits for is still at `screen.py:147`.
- Moonraker RPC methods it calls all exist in 0.9.x (inferred), so it doesn't strictly need step 3 first.

## Step 5: Klipper → master (its own branch and release series)

### Patches against master

`git apply --3way` of each patch alone on master; conflicts are regions/lines.

| Patch | Upstream status | Conflicts | Plan |
|---|---|---|---|
| 0001 H750 128 KiB offset | fully upstream (`src/stm32/Kconfig:318`) | none (no-op) | **drop** |
| 0002 fixed chip ids | not upstream | clean | keep (CAN uuids in printer.cfg depend on it) |
| 0003 UC1701 fonts, menus, ws2811 | not upstream | i2ccmds.c 2/37, stm32/i2c.c 8/123 | keep screen parts; re-port the F1 i2c errata onto upstream's new i2c status codes |
| 0004 eddy contact homing | superseded by upstream "tap" (5c23f9296, 0795fb014, `tap_z_offset` 6c8c8d24d, `PROBE_EDDY_CURRENT_TAP_CALIBRATE` ef7b13b1f) and `trigger_analog` | probe_eddy_current.py 10/669, sensor_ldc1612.c 5/204, ldc1612.py 5/87, probe.py 4/62, homing.py 2/17, bed_mesh.py 1/5 | **rewrite on upstream tap**; keep a thin `z_offset_calibration` wrapper only if the stock screen's calibration flow needs it |
| 0005 pressure probe | unused by the printer | clean | **drop** |
| 0006 shutdown / tip codes | not upstream | idle_timeout 1/16, lis2dw 1/60 | keep, small rework |
| 0007 scheduling / move queue | not upstream (`TRSYNC_TIMEOUT` still 0.025) | mcu.py 1/86 | keep move queue and `debug_shut`; re-decide the disabled "Timer too close" shutdown |
| 0008 assorted host | toolhead timing hunk obsolete (constants moved to `extras/motion_queuing.py`) | configfile 2/233, toolhead 1/22, gcode_move 1/26, chelper 1/17, extruder 1/6, resonance_tester 1/7 | split: keep shell command, power-loss resume, paths; **drop** the chelper "don't rebuild" hunk (chelper changed 1,163 lines, so Sovol's prebuilt `c_helper.so` won't match), the toolhead hunk and the `-backup` hacks |
| 0009 drop OTA menu entry | ours | clean after 0003 | keep |

Rebase order: 0002 → 0003 + 0009 (screen first, then the i2c re-port) → 0006 → 0007 → what's left of
0008 → the 0004 rewrite. The obico menu removal (step 2) folds into 0003/0009.

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
- **Mainboard can stay on stock at first.** Master configured the stock mainboard dictionary (with the
  toolhead-only sections removed). Config phase only; runtime untested. Expect "deprecated MCU code"
  warnings until it's reflashed.
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

## Customizations that go away

- Klipper patches 0001 and 0005; 0008's chelper, toolhead and `-backup` hunks; most of 0004.
- moonraker-obico entirely (step 2).
- The byte-identical check moves from the release build to a frozen job.

Everything else stays: KlipperScreen leaves rotation to the OS, crowsnest still doesn't wait for the
camera, and Sovol made no other changes to these apps (checked against `sovol-stock-reference`).
