#!/usr/bin/env bash
# Install a release on the printer. Usage: install-release.sh <tag|file.zip> [install.sh options]
#   tag: downloaded from GitHub with gh (works for drafts and the private repo), e.g. v0.1.0
#   options: --force-flash toolhead|mainboard, --no-flash
set -euo pipefail
. "$(dirname "$0")/common.sh"
src=${1:?usage: install-release.sh <tag|file.zip> [--force-flash board] [--no-flash]}; shift
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
if [ -f "$src" ]; then
    zip=$src
else
    gh release download "$src" -R RealMrLogan/sovol-zero-extended -p '*.zip' -p '*.zip.sha256' -D "$tmp"
    (cd "$tmp" && sha256sum -c ./*.sha256)
    zip=$(ls "$tmp"/*.zip)
fi
name=$(basename "$zip" .zip)
rsh 'rm -rf ~/zero-extended/incoming && mkdir -p ~/zero-extended/incoming'
rsync -t "$zip" "$PRINTER:zero-extended/incoming/"
rsh "cd ~/zero-extended/incoming && unzip -q '$name.zip' && './$name/install.sh' $*"
