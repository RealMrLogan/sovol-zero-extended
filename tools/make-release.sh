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

# stock images ride along so install.sh always has a known-good image to roll a board back to
for b in toolhead mainboard; do cp "$ROOT/stock-firmware/stock-$b.bin" "$stage/firmware/stock-$b.bin"; done

cp -r "$tree/klippy" "$stage/klipper/"
find "$stage/klipper" \( -name '*.pyc' -o -name __pycache__ -o -name '*.so' \) -prune -exec rm -rf {} +

# upstream apps (release/apps.conf). A git app only needs a bundle once its pin moves past Sovol's stock
# commit, which every Zero already has; the bundle carries just stock..pin, so installs work offline.
mkdir -p "$stage/apps"
while read -r app type url stock pin _; do
    case $type in
        git) [ "$pin" = "$stock" ] && continue
             echo "== $app: bundling ${stock:0:7}..${pin:0:7}"
             git clone -q --bare "$url" "$work/$app.git"
             git -C "$work/$app.git" branch -f zero-pin "$pin"
             git -C "$work/$app.git" bundle create -q "$stage/apps/$app.bundle" zero-pin "^$stock" ;;
        zip) echo "== $app: $url"
             curl -fsSL "$url" -o "$work/$app.zip"
             echo "$pin  $work/$app.zip" | sha256sum --quiet -c
             python3 -m zipfile -e "$work/$app.zip" "$stage/apps/$app/" ;;
        *) echo "apps.conf: bad type '$type' for $app"; exit 1 ;;
    esac
done < <(grep -v '^\s*#' "$ROOT/release/apps.conf" | grep .)
cp "$ROOT/release/apps.conf" "$stage/"
cp -r "$ROOT/release/systemd" "$ROOT/release/zero-config" "$stage/"
find "$stage/zero-config" -name __pycache__ -prune -exec rm -rf {} +

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
        b: {"file": "firmware/%s.bin" % b, "version": v, "app_start": s, "canbus_uuid": u,
            "stock_file": "firmware/stock-%s.bin" % b, "stock_version": sv}
        for b, v, s, u, sv in [
            ("toolhead", "${ver[toolhead]}", "${start[toolhead]}", "${uuid[toolhead]}", "$(stock_version toolhead)"),
            ("mainboard", "${ver[mainboard]}", "${start[mainboard]}", "${uuid[mainboard]}", "$(stock_version mainboard)"),
        ]
    },
    "apps": {l.split()[0]: {"type": l.split()[1], "source": l.split()[2], "pin": l.split()[4]}
             for l in open("$ROOT/release/apps.conf") if l.strip() and not l.lstrip().startswith("#")},
}, open(sys.argv[1], "w"), indent=2)
EOF
(cd "$stage" && find . -type f ! -name SHA256SUMS -printf '%P\n' | sort | xargs -d '\n' sha256sum > SHA256SUMS)
(cd "$dist" && python3 -m zipfile -c "$name.zip" "$name" && sha256sum "$name.zip" > "$name.zip.sha256")
rm -rf "$stage"
ls -l "$dist/$name.zip"; cat "$dist/$name.zip.sha256"
