# sovol-zero-extended

Community firmware for the Sovol Zero, now that Sovol's own (1.4.7) is frozen.
This repo is the source of truth: **upstream Klipper, pinned and unmodified, plus Sovol's changes as a patch series.**
The other upstream apps (Moonraker, Mainsail, KlipperScreen, ...) are pinned the same way, unmodified, in `release/apps.conf`.

- `klipper/`: submodule, upstream [Klipper3d/klipper](https://github.com/Klipper3d/klipper) pinned at `faa89be8` (what Sovol based 1.4.7 on)
- `patches/`: Sovol's changes (0001-0008), split by feature, then ours (0009 on), applied in order on top of the pin. `sovol-commit-log.txt` keeps Sovol's original commit messages.
- `configs/`: build settings for each board (`toolhead.config`, `mainboard.config`)
- `tools/`: build, deploy and flash over SSH
- `FINDINGS.md`: what's on the printer and what Sovol changed
- `RECOVERY.md`: what the installer recovers from by itself, and what to do by hand
- `stock-config/config/`: stock 1.4.7 printer config (from the recovery image)
- `from-printer/config/`: this printer's config before the 2026-11-14 reset (user mods, to re-add later)
- `sovol-host/`: Sovol's scripts, services and system files outside Klipper (stock)
- `stock-firmware/`: stock board images (mainboard read back from the board) and their version strings
- `release/`: what goes in a release zip (`install.sh`, `flash-board.sh`), `boards.conf` and `apps.conf`
- `release/zero-config/`: the config page at `http://<printer>/extended/` (stdlib Python server, one page, nginx snippet).
  Settings live in `SETTINGS` in `server.py`: each has choices plus a get/set; add new options there.
- `sovol-official/`: Sovol's published update package, manuals and recovery-image checksums

## Workflow
```sh
git submodule update --init
tools/setup.sh                # work/ = klipper pin + patches/, one commit per patch (gitignored)
# edit in work/ ...
tools/deploy-host.sh          # host Python (work/klippy) -> printer, restart Klipper. No flashing
tools/build-mcu.sh toolhead   # build board firmware on the printer (Sovol's gcc 8.3.1)
tools/flash-mcu.sh toolhead   # flash over Katapult; refuses while printing or on a wrong start address
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

## Releases
Versions are `vMAJOR.MINOR.PATCH` (`-rc.N` for test builds). Each release is one zip with the host code,
both board images, the upstream apps, a manifest and `install.sh`.

1. Add a `## vX.Y.Z` section to `CHANGELOG.md`, commit, then `git tag vX.Y.Z && git push origin main vX.Y.Z`.
2. GitHub Actions builds the zip in Debian 11 (Sovol's exact compiler) and opens a **draft** release.
   The build fails unless the toolhead firmware still comes out byte-identical to Sovol's stock image.
3. Test the draft on a printer: `tools/install-release.sh vX.Y.Z`. Publish it on GitHub when it works.
   It installs through the printer's config page, so a dropped connection doesn't stop it
   (`tools/install-release.sh --follow` reattaches to the log).
   Without SSH: download the zip from the release and upload it on `http://<printer>/extended/` (Update).

`install.sh` refuses while printing, checks every file's SHA-256 and each image's start address, backs up
`klippy/`, restarts Klipper (rolling back if it doesn't come up), and flashes only boards whose running
firmware version differs from the release (`--force-flash <board>` / `--no-flash` override). A board that
doesn't come back on the expected version is flashed back to its previous image; see `RECOVERY.md`.
Upstream apps (`release/apps.conf`) are put on their pins the same way: git apps are checked out at the
pinned commit (local edits are stashed, not lost), Mainsail is replaced by the pinned official release zip
(keeping `config.json`), and any failure restores them with `klippy/`. To upgrade an app, change its pin;
the zip then carries a git bundle from Sovol's stock commit to the pin, so installs don't need the network.
A pin that changes an app's Python/system dependencies is refused for now.
`release/boards.conf` picks per board whether a release ships the stock image or one built from `patches/`.
Build locally on the printer: `TREE=<patched tree> tools/make-release.sh vX.Y.Z`.

## Official Sovol resources
- Wiki (firmware, recovery image, manuals, changelog): https://wiki.sovol3d.com/en/sovol-zero
- Open-source hardware files (pinouts, STEP models): https://github.com/Sovol3d/SOVOL-ZERO

## Recovery
To restore stock firmware, use the official image from the wiki above
(`H616_2.3.3_debian_sovol-zero-1.4.7.zip`, flashed with an eMMC adapter).
This repo's `sovol-1.4.7-backup` release keeps a copy of that same file, only as a backup in case
Sovol's link goes away. Checksum: `sovol-official/SHA256SUMS`.
Stock toolhead firmware is on the printer at `~/printer_data/build/extruder_mcu_klipper.bin`.
Stock mainboard firmware: `tools/flash-mcu.sh mainboard stock-firmware/stock-mainboard.bin` (see `stock-firmware/README.md`).
