# sovol-zero-extended

Unofficial firmware for the Sovol Zero, built on Sovol's frozen 1.4.7.

> [!WARNING]
> **Pre-release. Use at your own risk; YMMV.** This is a personal project, not affiliated with or supported by
> Sovol, and tested on one printer. Installs check files, refuse during a print and roll back on failure, but a
> bad install can still leave the printer needing manual recovery (see [Recovery](#recovery)), up to
> reflashing the eMMC with an adapter. No warranty (GPLv3). Read `CHANGELOG.md` before installing.

## What it changes
- **Config page** at `http://<printer>/extended/`: screen orientation, X/Y motor current, an acceleration cap,
  input shaping, a belt check, PID tuning, and installing releases from a zip.
- **Upstream apps**, unmodified and pinned in `release/apps.conf`, newer than stock: Moonraker, KlipperScreen,
  Mainsail, crowsnest, mainsail-config. Their Python packages and the few system packages they need ship in
  the release and install offline.
- **Removed:** Sovol's OTA updater and board flashers, and moonraker-obico.
- **Unchanged so far:** Klipper is Sovol's 1.4.7 (upstream `faa89be8` plus Sovol's patches), and both boards
  run Sovol's stock firmware. Moving to current Klipper is the next step (`UPSTREAMS.md`).

## Install
From a computer that can `ssh sovol@<printer>`, with this repo checked out:
```sh
PRINTER=sovol@<printer> tools/install-release.sh <tag|file.zip>   # tag: needs gh
```
Once a release is installed, later ones can also be uploaded on the config page (Update).
`install.sh` refuses while printing, verifies every file, installs host code, apps and packages, flashes only
boards whose firmware changed, and rolls everything back if Klipper or a board doesn't come back.
What it can't undo by itself is in `RECOVERY.md`.

## Layout
- `klipper/`: upstream Klipper submodule; `patches/`: Sovol's changes on it, split by feature, then ours.
  `patches-stock/`: Sovol's series on their pin (`patches-stock/PIN`), for the byte-identical check.
- `release/`: the installer and what it installs: `apps.conf` (app pins), `debs.conf` (system packages),
  `boards.conf` (stock or built firmware per board), `zero-config/` (the config page).
- `tools/`: build, test, release, deploy and flash over SSH. `tests/`: run by `tools/test.sh`.
- `stock-firmware/`: Sovol's board images, for rollback and the CI byte-identical check.
- `FINDINGS.md`: what Sovol changed. `UPSTREAMS.md`: the update plan. `RECOVERY.md`: recovery.
- Stock 1.4.7 files (Sovol's scripts, services, config) are at the tag `sovol-stock-reference`
  (`git show sovol-stock-reference:<path>`).

## Development
```sh
git submodule update --init
tools/setup.sh                # work/ = Klipper pin + patches/, one commit per patch
tools/deploy-host.sh          # work/klippy -> printer, restart Klipper (no flashing)
tools/build-mcu.sh toolhead   # build board firmware on the printer (Sovol's gcc 8.3.1)
tools/flash-mcu.sh toolhead   # flash over Katapult; refuses while printing or on a wrong start address
tools/export-patches.sh       # commit in work/, then rewrite patches/
tools/test.sh                 # all tests and shellcheck (CI runs it too)
```
Flash the toolhead first: the mainboard is also the USB-to-CAN bridge, so a bad mainboard image cuts off
both boards (Katapult survives). `PRINTER` defaults to `sovol@192.168.1.130`.

| Board | Chip | Link | Katapult | App start |
|---|---|---|---|---|
| mainboard `[mcu]` | STM32H750, 25 MHz | USB (USB-CAN bridge) | 128 KiB | `0x08020000` |
| toolhead `[mcu extruder_mcu]` | STM32F103xE, 8 MHz | CAN 1 Mbit/s | 8 KiB | `0x08002000` |

## Releases
CI builds every push to `main` as the `nightly` prerelease (untested, test printers only). For a release:
add a `## vX.Y.Z` section to `CHANGELOG.md`, tag `vX.Y.Z` and push; CI builds a draft (in Debian 11, failing
unless the toolhead image is byte-identical to stock). Install the draft on a printer, then publish it.
App pins that change Python or system packages need wheels (`tools/build-wheels.sh`, built in CI) or an entry
in `release/debs.conf` and `release/sysdeps-checked`; `tools/make-release.sh` refuses otherwise.

## Recovery
- Stock firmware: Sovol's eMMC image from the [wiki](https://wiki.sovol3d.com/en/sovol-zero)
  (`H616_2.3.3_debian_sovol-zero-1.4.7.zip`, SHA-256 `933a3e596370dc6d64ac30517ca9ccfd9276b4247363f7b1178666c89e9fb97e`),
  flashed with an eMMC adapter. Keep a copy: this repo doesn't host it.
- Stock board firmware: `tools/flash-mcu.sh toolhead|mainboard stock-firmware/stock-<board>.bin`.
- Hardware files (pinouts, STEP): https://github.com/Sovol3d/SOVOL-ZERO
