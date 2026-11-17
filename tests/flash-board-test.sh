#!/usr/bin/env bash
# release/flash-board.sh's guard against an image built for the wrong address: its reset vector (the image's
# second word) must point into the board's app area, or the board can't boot. A fake systemctl reports Klipper
# as running, so an image that passes the guard stops at "stop Klipper first" and nothing is flashed.
set -euo pipefail
REPO=$(cd "$(dirname "$0")/.." && pwd)
t=$(mktemp -d); trap 'rm -rf "$t"' EXIT
mkdir "$t/bin"; printf '#!/bin/sh\nexit 0\n' > "$t/bin/systemctl"; chmod +x "$t/bin/systemctl"
fail() { echo "FAIL: $*"; exit 1; }

check() {   # board, reset vector (hex), expected: ok or refused
    python3 -c 'import struct, sys; sys.stdout.buffer.write(struct.pack("<II", 0x20010000, int(sys.argv[1], 16)))' "$2" > "$t/img.bin"
    local out; out=$(PATH=$t/bin:$PATH HOME=$t "$REPO/release/flash-board.sh" "$1" "$t/img.bin" 2>&1 || true)
    case $3 in
        ok) [ "$out" = "stop Klipper first" ] || fail "$1 0x$2 refused: $out" ;;
        refused) [[ $out == REFUSING* ]] || fail "$1 0x$2 accepted: $out" ;;
    esac
}
check toolhead  08002101 ok
check toolhead  08001fff refused   # inside Katapult
check toolhead  08102001 refused   # past the app area
check mainboard 08020201 ok
check mainboard 08002101 refused   # a toolhead image
echo "flash-board-test ok"
