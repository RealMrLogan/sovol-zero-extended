#!/usr/bin/env bash
# tools/app-deps.sh against a small git repo: which app pins make-release.sh refuses, and which need wheels.
set -euo pipefail
REPO=$(cd "$(dirname "$0")/.." && pwd)
. "$REPO/tools/app-deps.sh"
t=$(mktemp -d); trap 'rm -rf "$t"' EXIT
fail() { echo "FAIL: $*"; exit 1; }
g() { git -C "$t/app" -c user.name=t -c user.email=t@t "$@"; }
commit() {   # a pin that changes only $1, straight from stock
    if [ -n "${stock:-}" ]; then g checkout -q "$stock"; fi
    mkdir -p "$t/app/$(dirname "$1")"; echo "$RANDOM" >> "$t/app/$1"; g add -A; g commit -qm "$1"; g rev-parse HEAD; }

git init -q "$t/app"
stock=$(commit README.md)
docs=$(commit docs/doc-requirements.txt)
sys=$(commit scripts/system-dependencies.json)
req=$(commit scripts/app-requirements.txt)
touch "$t/checked"
PIP="app-env:scripts/app-requirements.txt"
deps() { app_deps "$t/app" app "$stock" "$@" "$t/checked" 2>"$t/err"; }

echo "== a docs requirements file is not a dependency"
[ "$(deps "$docs" -)" = "" ] || fail "docs pin refused or needs wheels"
echo "== system packages: refused unless checked"
! deps "$sys" "$PIP" >/dev/null || fail "system-package change accepted"
grep -q "add \"app $sys\" to release/sysdeps-checked" "$t/err" || fail "no hint: $(cat "$t/err")"
echo "app $sys" > "$t/checked"
[ "$(deps "$sys" "$PIP")" = "" ] || fail "checked pin refused"
echo "== requirements: wheels with a pip column, refused without"
[ "$(deps "$req" "$PIP")" = wheels ] || fail "requirements change without wheels"
! deps "$req" - >/dev/null || fail "requirements change accepted without a pip column"
grep -q "give it a pip column" "$t/err" || fail "no hint: $(cat "$t/err")"
echo "app-deps-test ok"
