#!/usr/bin/env bash
# Daily update check for ai-consensus-skill, run from a Claude Code
# SessionStart hook. Prints a notice (added to the session context) when the
# version on main differs from the installed one; set AI_CONSENSUS_AUTO_UPDATE=1
# to install the new release automatically instead (pinned to its release tag).
# AI_CONSENSUS_UPDATE_INTERVAL (seconds, default 86400) controls the check
# frequency; 0 disables checks entirely.
set -uo pipefail  # deliberately no -e: a failed check must never disturb session start

REPO="MinseokOh/ai-consensus-skill"
RAW="https://raw.githubusercontent.com/$REPO"

# Locate the install dir from this script's own path (…/scripts/ → CLAUDE_DIR),
# so custom-dir installs work even though the hook environment lacks CLAUDE_DIR.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)" || exit 0
CLAUDE_DIR="${CLAUDE_DIR:-${SCRIPT_DIR%/scripts}}"

STATE="$CLAUDE_DIR/.ai-consensus-skill.version"
CHECK_STAMP="$CLAUDE_DIR/.ai-consensus-skill.update-check"
LOG="$CLAUDE_DIR/.ai-consensus-skill.update.log"
INSTALL_URL="$RAW/main/install.sh"

INTERVAL="${AI_CONSENSUS_UPDATE_INTERVAL:-86400}"
case "$INTERVAL" in ""|*[!0-9]*) INTERVAL=86400;; esac
[ "$INTERVAL" -eq 0 ] && exit 0   # explicit opt-out

# Not installed via the installer — nothing to check.
[ -f "$STATE" ] || exit 0

# Serialize the timestamp check and optional install across simultaneous sessions.
# Fail quietly when another check owns the lock; never delete its lock.
CHECK_LOCK="$CLAUDE_DIR/.ai-consensus-skill.update-lock"
lock_signal=0
trap 'lock_signal=1' INT TERM HUP
mkdir "$CHECK_LOCK" 2>/dev/null || exit 0
trap 'rmdir "$CHECK_LOCK" 2>/dev/null || true' EXIT
trap 'exit 0' INT TERM HUP
[ "$lock_signal" -eq 0 ] || exit 0

# Use one snapshot for the version/ref decision. The installer checks this same
# state again under its publication lock to preserve concurrent manual installs.
installed_state="$(cat "$STATE" 2>/dev/null)" || exit 0

# Throttle: at most one remote check per INTERVAL. The stamp is written before
# the network call on purpose — offline machines pay the 3s timeout at most
# once per interval instead of on every session start.
now=$(date +%s)
last=$(cat "$CHECK_STAMP" 2>/dev/null || echo 0)
case "$last" in ""|*[!0-9]*) last=0;; esac
[ "$last" -gt "$now" ] && last=0
[ $((now - last)) -lt "$INTERVAL" ] && exit 0
echo "$now" > "$CHECK_STAMP"

# Only the release channel (main or a vX.Y.Z tag install) is checked; an
# install pinned to any other ref (branch, sha) is deliberate — never nag it.
ref=$(printf '%s\n' "$installed_state" | sed -n 's/^ref=//p' | head -n1)
case "$ref" in ""|main|v[0-9]*) ;; *) exit 0;; esac

local_ver=$(printf '%s\n' "$installed_state" | sed -n 's/^version=//p' | head -n1)
[ -z "$local_ver" ] && local_ver="unknown"

remote_ver=$(curl -fsSL --max-time 3 "$RAW/main/VERSION" 2>/dev/null | head -n1 | tr -d '[:space:]')
remote_ver="${remote_ver#v}"
case "$remote_ver" in
  "") exit 0;;                     # offline or fetch failed: retry next interval
  *[!0-9A-Za-z.+-]*) exit 0;;      # implausible content — don't inject it into the session
esac
[ "${#remote_ver}" -gt 32 ] && exit 0
[ "$remote_ver" = "$local_ver" ] && exit 0

if [ "${AI_CONSENSUS_AUTO_UPDATE:-0}" = "1" ]; then
  # Install from the release tag matching the version we just compared, so what
  # executes is pinned to that release rather than the moving tip of main.
  # pipefail makes a failed curl fail the whole pipeline (bash won't run on empty input).
  if curl -fsSL --max-time 30 "$RAW/v$remote_ver/install.sh" \
      | CLAUDE_DIR="$CLAUDE_DIR" REF="v$remote_ver" \
        AI_CONSENSUS_EXPECTED_CLAUDE_STATE="$installed_state" \
        bash -s -- --target claude >"$LOG" 2>&1; then
    echo "[ai-consensus-skill] auto-updated $local_ver -> $remote_ver (log: $LOG). Restart the session (or start a new one) to load the updated skills."
  else
    rc=$?
    if [ "$rc" -eq 75 ]; then
      echo "[ai-consensus-skill] auto-update skipped: installed state changed during the update check."
    else
      echo "[ai-consensus-skill] auto-update to $remote_ver failed (see $LOG); update manually: curl -fsSL $INSTALL_URL | bash"
    fi
  fi
else
  echo "[ai-consensus-skill] update available: $local_ver -> $remote_ver. Update with: curl -fsSL $INSTALL_URL | bash  (export AI_CONSENSUS_AUTO_UPDATE=1 for automatic updates, AI_CONSENSUS_UPDATE_INTERVAL=0 to disable checks)"
fi
exit 0
