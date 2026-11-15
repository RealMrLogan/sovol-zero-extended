#!/usr/bin/env bash
# Write work/'s commits on top of the pinned upstream back to patches/ (the source of truth).
set -euo pipefail
. "$(dirname "$0")/common.sh"
need_work
[ -z "$(git -C "$WORK" status --porcelain)" ] || { echo "work/ has uncommitted changes: commit them in work/ first"; exit 1; }
rm -f "$ROOT"/patches/*.patch
git -C "$WORK" format-patch -q --zero-commit --no-signature --no-numbered -o "$ROOT/patches" "$(git -C "$ROOT/klipper" rev-parse HEAD)..HEAD"
ls "$ROOT/patches"
