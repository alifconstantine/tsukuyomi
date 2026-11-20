#!/usr/bin/env bash
# Launch Tsukuyomi in-session Wayland lockscreen (Ryoku clockwork/orbital qylock).
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/theme-config.sh"

resolve_session_id() {
    local sid="" candidate="" st="" cls="" typ=""
    if [[ -n ${XDG_SESSION_ID:-} && ${XDG_SESSION_ID} =~ ^[A-Za-z0-9_.-]+$ ]]; then
        printf '%s\n' "$XDG_SESSION_ID"
        return 0
    fi
    if command -v loginctl >/dev/null 2>&1; then
        while read -r candidate _; do
            [[ -n $candidate ]] || continue
            typ=$(loginctl show-session "$candidate" -p Type --value 2>/dev/null || true)
            st=$(loginctl show-session "$candidate" -p State --value 2>/dev/null || true)
            cls=$(loginctl show-session "$candidate" -p Class --value 2>/dev/null || true)
            if [[ $cls == user && $typ == wayland && ( $st == active || $st == online ) ]]; then
                sid=$candidate
                break
            fi
        done < <(loginctl list-sessions --no-legend 2>/dev/null | awk -v u="$(id -un)" '$3 == u {print $1, $2}')
        if [[ -z $sid ]]; then
            sid=$(loginctl list-sessions --no-legend 2>/dev/null | awk -v u="$(id -un)" '$3 == u {print $1; exit}')
        fi
    fi
    printf '%s\n' "$sid"
}

runtime_dir="${XDG_RUNTIME_DIR:-/tmp}"
session_id="$(resolve_session_id)"
if [[ ! $session_id =~ ^[A-Za-z0-9_.-]+$ ]]; then
    echo "tsukuyomi-lock: could not resolve XDG_SESSION_ID" >&2
    exit 1
fi
export XDG_SESSION_ID="$session_id"

guard_file="$runtime_dir/tsukuyomi-lock-${UID:-$(id -u)}.$session_id.lock"
if ! exec 9>"$guard_file"; then
    echo "tsukuyomi-lock: cannot open launch guard $guard_file" >&2
    exit 1
fi
flock -n 9 || exit 0

proof_helper="$DIR/proof.sh"
proof_token=""
cleanup_proof() {
    if [[ -n $proof_token ]]; then
        "$proof_helper" retire "$proof_token" "$session_id" >/dev/null 2>&1 || true
    fi
}
trap cleanup_proof EXIT

session_alive() {
    local state
    state="$(loginctl show-session "$session_id" -p State --value 2>/dev/null)" || return 1
    [[ $state == active || $state == online ]]
}

sleep_while_session_alive() {
    local remaining=$1
    while (( remaining > 0 )); do
        sleep 1
        session_alive || return 1
        remaining=$((remaining - 1))
    done
}

export QML2_IMPORT_PATH="$DIR/imports:${QML2_IMPORT_PATH:-}"
export QML_XHR_ALLOW_FILE_READ=1
export XCURSOR_THEME="${XCURSOR_THEME:-Bibata-Modern-Classic}"
export XCURSOR_SIZE="${XCURSOR_SIZE:-24}"
export HYPRCURSOR_THEME="${HYPRCURSOR_THEME:-$XCURSOR_THEME}"
export HYPRCURSOR_SIZE="${HYPRCURSOR_SIZE:-$XCURSOR_SIZE}"

if [[ -z ${XDG_SESSION_TYPE:-} ]]; then
    XDG_SESSION_TYPE="$(loginctl show-session "$session_id" -p Type --value 2>/dev/null || true)"
    [[ -n $XDG_SESSION_TYPE ]] || XDG_SESSION_TYPE=wayland
fi
export XDG_SESSION_TYPE
if [[ $XDG_SESSION_TYPE != wayland ]]; then
    echo "tsukuyomi-lock: secure in-session locking requires a Wayland session" >&2
    exit 1
fi

if [[ -f "$DIR/theme/Main.qml" ]]; then
    export TSUKUYOMI_STOCK_LOCK_PATH="$DIR/theme"
elif [[ -f "/usr/share/sddm/themes/tsukuyomi/theme/Main.qml" ]]; then
    export TSUKUYOMI_STOCK_LOCK_PATH="/usr/share/sddm/themes/tsukuyomi/theme"
else
    echo "tsukuyomi-lock: clockwork/orbital theme not found" >&2
    exit 1
fi

selected_theme=${1:-}
if [[ -z $selected_theme && -r $lock_theme_pref ]]; then
    IFS= read -r selected_theme < "$lock_theme_pref" || true
fi
export QS_THEME="$stock_lock_theme" QS_THEME_PATH="$TSUKUYOMI_STOCK_LOCK_PATH"
if [[ -n ${1:-} && -f "$1/Main.qml" ]]; then
    export QS_THEME_PATH="$1"
elif [[ -n $selected_theme && $selected_theme != "$stock_lock_theme" ]] &&
        selected_path=$(installed_lock_theme_path "$selected_theme" 2>/dev/null); then
    export QS_THEME="$selected_theme" QS_THEME_PATH="$selected_path"
fi

killall -9 hyprlock swaylock wlogout 2>/dev/null || true

short_failures=0
backoff=1
session_alive || exit 0
while :; do
    proof_token="$(< /proc/sys/kernel/random/uuid)"
    export QYLOCK_PROOF_TOKEN="$proof_token"
    "$proof_helper" begin "$proof_token" "$session_id"
    attempt_started=$(date +%s%N)
    if (exec 9>&-; exec quickshell -p "$DIR/lock_shell.qml"); then
        rc=0
    else
        rc=$?
    fi
    lifetime_ns=$(( $(date +%s%N) - attempt_started ))
    "$proof_helper" retire "$proof_token" "$session_id" >/dev/null 2>&1 || true
    proof_token=""
    session_alive || exit 0
    (( rc == 0 )) && exit 0

    if [[ $QS_THEME_PATH != "$TSUKUYOMI_STOCK_LOCK_PATH" ]]; then
        echo "tsukuyomi-lock: falling back after a theme failure" >&2
        export QS_THEME="$stock_lock_theme" QS_THEME_PATH="$TSUKUYOMI_STOCK_LOCK_PATH"
        continue
    fi

    if (( lifetime_ns >= 2000000000 )); then
        short_failures=0
        backoff=1
        sleep 0.1
        continue
    fi
    short_failures=$((short_failures + 1))
    if (( short_failures < 3 )); then
        sleep 0.1
        continue
    fi
    echo "tsukuyomi-lock: lock client failed repeatedly; retrying in ${backoff}s" >&2
    sleep_while_session_alive "$backoff" || exit 0
    (( backoff < 30 )) && backoff=$((backoff * 2))
    (( backoff > 30 )) && backoff=30
done
