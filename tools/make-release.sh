#!/usr/bin/env bash
# Build a release zip: dist/sovol-zero-extended-<version>.zip (+ .sha256).
# Usage: make-release.sh <version>      e.g. v0.1.0 (needs arm-none-eabi-gcc 8.3.1: Debian 11 or the printer)
# TREE=<dir> uses an already-patched Klipper tree instead of building one from klipper/ + patches/.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
version=${1:?usage: make-release.sh <version>}
[[ $version =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$ ]] || { echo "version must look like v1.2.3 or v1.2.3-rc.1"; exit 1; }
name=sovol-zero-extended-$version
dist=$ROOT/dist; stage=$dist/$name
rm -rf "$stage" "$dist/$name.zip"; mkdir -p "$stage/firmware" "$stage/klipper"
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT

tree=${TREE:-}
if [ -z "$tree" ]; then
    echo "== patched tree: klipper@$(git -C "$ROOT/klipper" rev-parse --short HEAD) + patches/"
    tree=$work/klipper
    git -C "$ROOT/klipper" archive --prefix=klipper/ HEAD | tar -x -C "$work"
    git -C "$tree" init -q   # apply inside a repo, as tools/setup.sh does (verified to reproduce the printer's tree)
    git -C "$tree" -c core.autocrlf=false apply --whitespace=nowarn "$ROOT"/patches/*.patch
fi

stock_version() { awk -v b="$1" '$1==b {print $2}' "$ROOT/stock-firmware/VERSIONS"; }

# the patches must still reproduce Sovol's shipped toolhead image byte for byte
echo "== reproducibility check: toolhead vs stock"
"$ROOT/tools/build-firmware.sh" "$tree" toolhead "$work/repro" "$(stock_version toolhead)" >/dev/null
cmp "$work/repro/toolhead.bin" "$ROOT/stock-firmware/stock-toolhead.bin"
echo "identical"

declare -A ver start uuid
start=([toolhead]=0x08002000 [mainboard]=0x08020000)
uuid=([toolhead]=61755fe321ac [mainboard]=0d1445047cdd)
while read -r board source; do
    case $source in
        stock) cp "$ROOT/stock-firmware/stock-$board.bin" "$stage/firmware/$board.bin"; ver[$board]=$(stock_version "$board") ;;
        build) ver[$board]=$("$ROOT/tools/build-firmware.sh" "$tree" "$board" "$work/fw" "$version")
               cp "$work/fw/$board.bin" "$stage/firmware/" ;;
        *) echo "boards.conf: bad source '$source' for $board"; exit 1 ;;
    esac
    echo "== $board: $source (${ver[$board]})"
done < <(grep -v '^\s*#' "$ROOT/release/boards.conf" | grep .)

cp -r "$tree/klippy" "$stage/klipper/"
find "$stage/klipper" \( -name '*.pyc' -o -name __pycache__ -o -name '*.so' \) -prune -exec rm -rf {} +
cp "$ROOT/release/install.sh" "$ROOT/release/flash-board.sh" "$stage/"
chmod +x "$stage"/*.sh

commit=$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || echo unknown)
pin=$(git -C "$ROOT/klipper" rev-parse HEAD 2>/dev/null || echo unknown)
python3 - "$stage/manifest.json" <<EOF
import json, sys
json.dump({
    "name": "sovol-zero-extended",
    "version": "$version",
    "commit": "$commit",
    "klipper_upstream": "$pin",
    "boards": {
        b: {"file": "firmware/%s.bin" % b, "version": v, "app_start": s, "canbus_uuid": u}
        for b, v, s, u in [
            ("toolhead", "${ver[toolhead]}", "${start[toolhead]}", "${uuid[toolhead]}"),
            ("mainboard", "${ver[mainboard]}", "${start[mainboard]}", "${uuid[mainboard]}"),
        ]
    },
}, open(sys.argv[1], "w"), indent=2)
EOF
(cd "$stage" && find . -type f ! -name SHA256SUMS -printf '%P\n' | sort | xargs -d '\n' sha256sum > SHA256SUMS)
(cd "$dist" && python3 -m zipfile -c "$name.zip" "$name" && sha256sum "$name.zip" > "$name.zip.sha256")
rm -rf "$stage"
ls -l "$dist/$name.zip"; cat "$dist/$name.zip.sha256"
