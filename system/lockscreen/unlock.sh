#!/usr/bin/env sh
# Clear session proof token and unlock the logind session.
set -eu

session_id=${XDG_SESSION_ID:-}
case "$session_id" in
    *[!A-Za-z0-9_.-]*|'') exit 2 ;;
esac
proof="$(dirname "$0")/proof.sh"
if [ -x "$proof" ] && [ -n "${QYLOCK_PROOF_TOKEN:-}" ]; then
    "$proof" clear "$QYLOCK_PROOF_TOKEN" "$session_id" >/dev/null 2>&1 || true
fi
exec loginctl unlock-session "$session_id"
