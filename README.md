# sovol-zero-extended

Community firmware work for the Sovol Zero: moving it off Sovol's frozen Klipper fork (1.4.7)
onto current upstream Klipper/Moonraker/Mainsail/KlipperScreen, plus new features.

- `FINDINGS.md`: what's on the printer and what Sovol changed
- `sovol-klipper/`: Sovol's Klipper changes as one patch against upstream `faa89be8`
- `from-printer/config/`: the stock 1.4.7 printer config
- `sovol-official/`: Sovol's published update package, manuals and recovery-image checksums

## Official Sovol resources
- Wiki (firmware, recovery image, manuals, changelog): https://wiki.sovol3d.com/en/sovol-zero
- Open-source hardware files (pinouts, STEP models): https://github.com/Sovol3d/SOVOL-ZERO

## Recovery
To restore stock firmware, use the official image from the wiki above
(`H616_2.3.3_debian_sovol-zero-1.4.7.zip`, flashed with an eMMC adapter).
This repo's `sovol-1.4.7-backup` release keeps a copy of that same file, only as a backup in case
Sovol's link goes away. Checksum: `sovol-official/SHA256SUMS`.
