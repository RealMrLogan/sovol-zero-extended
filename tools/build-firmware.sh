#!/usr/bin/env bash
# Build one board's firmware from a patched Klipper tree, stamped with an exact version string.
# Usage: build-firmware.sh <klipper-tree> <toolhead|mainboard> <out-dir> <version>
# Writes <out-dir>/<board>.bin and <board>.dict, prints the stamped version.
set -euo pipefail
cfg=$(cd "$(dirname "$0")/../configs" && pwd)/$2.config
[ -f "$cfg" ] || { echo "no config for board '$2'" >&2; exit 1; }   # stdout is the version callers capture
tree=$(cd "$1" && pwd); board=$2; mkdir -p "$3"; out=$(cd "$3" && pwd); ver=$4

tmp=$(mktemp -d)
bc=$tree/scripts/buildcommands.py
cp "$bc" "$tmp/buildcommands.py.orig"
trap 'cp "$tmp/buildcommands.py.orig" "$bc"; rm -rf "$tmp"' EXIT
# Klipper stamps `git describe` (+ date/host when "dirty"); pin it to $ver for the duration of this build
python3 - "$bc" "$ver" <<'EOF'
import sys
path, ver = sys.argv[1:]
src = open(path).read()
hook = "def build_version(extra, cleanbuild):\n"
assert hook in src, "buildcommands.py changed upstream: update build-firmware.sh"
open(path, "w").write(src.replace(hook, hook + "    return %r\n" % ver, 1))
EOF

cp "$cfg" "$tmp/.config"
make -C "$tree" -s KCONFIG_CONFIG="$tmp/.config" OUT="$tmp/out/" olddefconfig >/dev/null
make -C "$tree" -j"$(nproc)" KCONFIG_CONFIG="$tmp/.config" OUT="$tmp/out/" > "$tmp/build.log" 2>&1 ||
    { tail -40 "$tmp/build.log" >&2; exit 1; }
cp "$tmp/out/klipper.bin" "$out/$board.bin"
cp "$tmp/out/klipper.dict" "$out/$board.dict"
python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["version"])' "$out/$board.dict"
