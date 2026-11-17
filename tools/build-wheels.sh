#!/usr/bin/env bash
# Build the wheels install.sh installs offline: for each app with a pip column in apps.conf whose pin changes
# that requirements file from Sovol's stock commit, every package the file needs, built for the printer
# (arm64, Python 3.9, glibc 2.31). Run on Debian 11 arm64 with git, python3-venv, python3-dev, gcc, pkg-config
# and libcairo2-dev (pycairo has no wheel); CI uses an emulated debian:bullseye container.
# Usage: build-wheels.sh <out dir>     build-wheels.sh -n: only list the apps that need wheels (any machine)
# APPS_CONF=<file> reads another apps.conf (to try a pin before setting it).
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
out=${1:?usage: build-wheels.sh <out dir> | -n}
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
. "$ROOT/tools/app-deps.sh"

need=()
while read -r app type url stock pin _ pip; do
    [ "$type" = git ] && [ "$pip" != - ] && [ "$pin" != "$stock" ] || continue
    git clone -q --bare --filter=blob:none "$url" "$work/$app.git"
    deps=$(app_deps "$work/$app.git" "$app" "$stock" "$pin" "$pip" "$ROOT/release/sysdeps-checked")
    [ "$deps" = wheels ] || continue
    git -C "$work/$app.git" show "$pin:${pip#*:}" > "$work/$app.txt"
    need+=("$app")
done < <(grep -v '^\s*#' "${APPS_CONF:-$ROOT/release/apps.conf}" | grep .)
if [ "$out" = -n ]; then echo "${need[*]}"; exit 0; fi

mkdir -p "$out"
python3 -m venv "$work/venv"
"$work/venv/bin/pip" install -q --disable-pip-version-check -U pip wheel
for app in "${need[@]}"; do
    echo "== $app"
    "$work/venv/bin/pip" wheel -q --disable-pip-version-check -w "$out" -r "$work/$app.txt"
    # complete: the requirements resolve from these wheels alone, as install.sh installs them
    "$work/venv/bin/pip" install -q --disable-pip-version-check --dry-run --ignore-installed --no-index \
        --find-links "$out" -r "$work/$app.txt"
done
ls "$out"
