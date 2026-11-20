#!/usr/bin/env bash

readonly stock_lock_theme=clockwork/orbital
lock_theme_pref="${XDG_CONFIG_HOME:-$HOME/.config}/qylock/theme"

installed_lock_theme_path() {
    local slug=$1 root candidate
    [[ $slug =~ ^[A-Za-z0-9_-]+(/[A-Za-z0-9_-]+)*$ ]] || return 1
    root=$(realpath -e -- "${XDG_DATA_HOME:-$HOME/.local/share}/qylock/themes") || return 1
    candidate=$(realpath -e -- "$root/$slug/Main.qml") || return 1
    [[ $candidate == "$root/"* && -f $candidate && -r $candidate ]] || return 1
    printf '%s\n' "${candidate%/*}"
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    set -euo pipefail
    if [[ $# != 2 || $1 != set ]]; then
        echo "Usage: tsukuyomi-lock-theme set THEME_ID" >&2
        exit 2
    fi
    if [[ $2 != "$stock_lock_theme" ]] && ! installed_lock_theme_path "$2" >/dev/null 2>&1; then
        echo "This lockscreen theme is not installed: $2" >&2
        exit 1
    fi
    mkdir -p -- "${lock_theme_pref%/*}"
    pending=$(mktemp -- "$lock_theme_pref.XXXXXXXX")
    trap '[[ ! -e $pending ]] || unlink -- "$pending"' EXIT
    printf '%s\n' "$2" > "$pending"
    mv -fT -- "$pending" "$lock_theme_pref"
fi
