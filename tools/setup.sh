#!/usr/bin/env bash
# Create work/: upstream Klipper at the pinned submodule commit + patches/*.patch, one commit per patch.
set -euo pipefail
. "$(dirname "$0")/common.sh"
cd "$ROOT"
git submodule update --init klipper
[ ! -e "$WORK" ] || { echo "work/ already exists. To rebuild: git -C klipper worktree remove --force ../work"; exit 1; }
git -C klipper worktree add -q --detach ../work HEAD
git -C "$WORK" am -q --keep-cr --whitespace=nowarn "$ROOT"/patches/*.patch
git -C "$WORK" log --oneline "$(git -C klipper rev-parse HEAD)..HEAD"
