#!/usr/bin/env bash
# Install a release on the printer. Usage: install-release.sh <tag|file.zip> [install.sh options]
#   tag: downloaded from GitHub with gh (works for drafts and the private repo), e.g. v0.1.0
#   options: --force-flash toolhead|mainboard, --no-flash
# Goes through the printer's /extended/ page, like a browser upload: the install runs as a systemd
# unit on the printer, so a dropped connection here doesn't stop it (rerun with --follow to reattach).
# A printer without the page yet (stock, or a release before v0.2.0) is installed over SSH instead.
set -euo pipefail
. "$(dirname "$0")/common.sh"
URL=http://${PRINTER#*@}/extended/api/update
src=${1:?usage: install-release.sh <tag|file.zip|--follow> [--force-flash board] [--no-flash]}; shift

api() { curl -sS --fail-with-body "$@"; }

follow() {   # print the install log as it grows; the page's server restarts mid-install, so ride out errors
    local seen=0 d log
    while :; do
        if d=$(curl -sf "$URL" 2>/dev/null); then
            log=$(jq_py 'd["log"]' <<<"$d") || log=""
            [ ${#log} -gt $seen ] && { printf '%s\n' "${log:$seen}"; seen=$((${#log} + 1)); }
            case $(jq_py 'd["result"] if not d["running"] else ""' <<<"$d") in
                success) echo "== installed"; return 0 ;;
                failed) echo "== install FAILED (rolled back; see above)"; return 1 ;;
            esac
        fi
        sleep 2
    done
}
[ "$src" = --follow ] && { follow; exit; }

tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
if [ -f "$src" ]; then
    zip=$src
else
    gh release download "$src" -R RealMrLogan/sovol-zero-extended -p '*.zip' -p '*.zip.sha256' -D "$tmp"
    (cd "$tmp" && sha256sum -c ./*.sha256)
    zip=$(ls "$tmp"/*.zip)
fi

if ! curl -sf -o /dev/null "$URL"; then
    echo "no /extended/ page on the printer: installing over SSH"
    name=$(basename "$zip" .zip)
    rsh 'mkdir -p ~/zero-extended/incoming'
    rsync -t "$zip" "$PRINTER:zero-extended/incoming/"
    rsh "cd ~/zero-extended/incoming && rm -rf '$name' && unzip -q '$name.zip' && './$name/install.sh' $*"
    exit
fi

echo "== uploading $(basename "$zip")"
api -H 'Content-Type: application/zip' --data-binary @"$zip" "$URL/upload"; echo
args=$(python3 -c 'import json,sys; print(json.dumps({"args": sys.argv[1:]}))' "$@")
out=$(api -H 'Content-Type: application/json' -d "$args" "$URL/install") || { echo "$out"; exit 1; }
follow
