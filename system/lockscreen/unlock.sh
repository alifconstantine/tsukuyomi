#!/usr/bin/env sh
# Clear session proof token and unlock the logind session.
set -eu

session_id=${XDG_SESSION_ID:-}
case "$session_id" in
    *[!A-Za-z0-9_.-]*|'') exit 2 ;;
esac
if [ -n "${XDG_RUNTIME_DIR:-}" ] && [ -S "$XDG_RUNTIME_DIR/ryoku-shell.sock" ]; then
    ryoku-shell unlock-prepare session "$session_id"
fi
proof="$(dirname "$0")/proof.sh"
if [ -x "$proof" ] && [ -n "${QYLOCK_PROOF_TOKEN:-}" ]; then
    "$proof" clear "$QYLOCK_PROOF_TOKEN" "$session_id" >/dev/null 2>&1 || true
fi
exec loginctl unlock-session "$session_id"
