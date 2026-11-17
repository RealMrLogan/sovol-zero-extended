# shellcheck shell=bash
# What an app pin changes in its dependencies (sourced by make-release.sh and build-wheels.sh).
# app_deps <bare repo> <app> <stock> <pin> <pip column> <sysdeps-checked file>
# Prints "wheels" if the pin changes the app's pip requirements file. Fails, saying why, if it changes what
# install.sh can't install on its own: system packages (unless checked by hand and listed, with any the printer
# lacks shipped in debs.conf), or Python requirements of an app without a pip column.
app_deps() {
    local repo=$1 app=$2 stock=$3 pin=$4 pip=$5 checked=$6 changed
    changed=$(git -C "$repo" diff --name-only "$stock" "$pin") || return 1
    if grep -qE '^(scripts/system-dependencies\.json|tools/libs/pkglist-[^/]*\.sh)$' <<<"$changed" &&
       ! grep -qx "$app $pin" "$checked"; then
        echo "$app: ${pin:0:7} changes its system packages, which install.sh can't install." >&2
        echo "Check them; ship any the printer lacks in release/debs.conf, then add \"$app $pin\" to release/sysdeps-checked." >&2
        return 1
    fi
    if [ "$pip" = - ]; then
        if grep -qE '^(scripts/)?[^/]*requirements[^/]*\.txt$' <<<"$changed"; then
            echo "$app: ${pin:0:7} changes its Python requirements; give it a pip column in apps.conf" >&2
            return 1
        fi
    elif grep -qxF "${pip#*:}" <<<"$changed"; then
        echo wheels
    fi
}
