#!/usr/bin/env bash
# Installs the consensus + consensus-review skills and the worker agents
# (claude-worker, codex-worker, gemini-worker) into ~/.claude by
# downloading them from the public GitHub repo (raw paths).
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/MinseokOh/ai-consensus-skill/main/install.sh | bash
#
# Options (env vars):
#   CLAUDE_DIR  install target (default: ~/.claude)
#   REF         git ref to install from (default: main)
#
# Safe to re-run: files being replaced are backed up as <file>.bak.<timestamp>;
# files superseded by newer releases (old skills/agents) are deleted.
# Also registers a SessionStart auto-update hook in $CLAUDE_DIR/settings.json
# (backed up before modification; see README "Auto-update").
# All files are downloaded to a staging dir first and installed only if
# every download succeeds, so a failed download never leaves a partial
# install.
# The installed version is recorded to $CLAUDE_DIR/.ai-consensus-skill.version
# (a state stamp, overwritten on every install).
set -euo pipefail

REPO="MinseokOh/ai-consensus-skill"
REF="${REF:-main}"
RAW_BASE="https://raw.githubusercontent.com/$REPO/$REF"
CLAUDE_DIR="${CLAUDE_DIR:-$HOME/.claude}"
STAMP="$(date +%Y%m%d%H%M%S)"

case "$CLAUDE_DIR" in
  ""|"/") echo "ERROR: refusing to install into CLAUDE_DIR='$CLAUDE_DIR'" >&2; exit 1;;
esac

FILES=(
  ".claude/skills/consensus/SKILL.md"
  ".claude/skills/consensus-review/SKILL.md"
  ".claude/agents/claude-worker.md"
  ".claude/agents/codex-worker.md"
  ".claude/agents/gemini-worker.md"
  ".claude/scripts/ai-consensus-check-update.sh"
)

# Paths from older releases that this version supersedes; DELETED on install
# (including any leftover backups inside a superseded skill directory).
# Note: paths here are relative to $CLAUDE_DIR, while FILES above are
# repo-relative (their leading ".claude/" is stripped on install).
OBSOLETE_PATHS=(
  "skills/multi-review"
  "agents/claude-reviewer.md"
  "agents/codex-reviewer.md"
  "agents/gemini-reviewer.md"
)

mkdir -p "$CLAUDE_DIR"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

VERSION="$(curl -fsSL "$RAW_BASE/VERSION" 2>/dev/null | head -n1 | tr -d '[:space:]' || true)"
VERSION="${VERSION#v}"
if [ -z "$VERSION" ]; then
  echo "warning: could not fetch VERSION for ref '$REF' (bad ref, or a ref predating the VERSION file?); recording version as 'unknown'" >&2
  VERSION="unknown"
fi

echo "Installing skills/agents from $RAW_BASE into $CLAUDE_DIR ..."
echo "  version: $VERSION (ref: $REF)"

# Phase 1: download everything; abort before installing anything on any failure.
for repo_path in "${FILES[@]}"; do
  tmp="$TMP_DIR/${repo_path#.claude/}"
  mkdir -p "$(dirname "$tmp")"
  if ! curl -fsSL "$RAW_BASE/$repo_path" -o "$tmp"; then
    echo "  ERROR: failed to download $RAW_BASE/$repo_path — nothing was installed" >&2
    exit 1
  fi
done

# Phase 2: back up and install. The final step is a same-directory rename so
# each file is replaced atomically (mv from the staging dir may cross
# filesystems and degrade to a copy — never let that write the live path).
for repo_path in "${FILES[@]}"; do
  rel="${repo_path#.claude/}"
  dest="$CLAUDE_DIR/$rel"
  mkdir -p "$(dirname "$dest")"
  if [ -f "$dest" ]; then
    cp "$dest" "$dest.bak.$STAMP"
    echo "  backup: $dest -> $dest.bak.$STAMP"
  fi
  mv "$TMP_DIR/$rel" "$dest.tmp.$$"
  mv -f "$dest.tmp.$$" "$dest"
  echo "  installed: $dest"
done

chmod +x "$CLAUDE_DIR/scripts/ai-consensus-check-update.sh" \
  || echo "  warning: could not chmod +x $CLAUDE_DIR/scripts/ai-consensus-check-update.sh" >&2

# Register the SessionStart update-check hook in settings.json (idempotent;
# backs the file up before modifying). Skipped with instructions if python3
# is unavailable or the file isn't valid JSON.
SETTINGS="$CLAUDE_DIR/settings.json"
HOOK_CMD="$CLAUDE_DIR/scripts/ai-consensus-check-update.sh"
if [ -f "$SETTINGS" ] && grep -q "ai-consensus-check-update.sh" "$SETTINGS"; then
  echo "  hook: SessionStart update check already registered"
elif command -v python3 >/dev/null 2>&1; then
  [ -f "$SETTINGS" ] && cp "$SETTINGS" "$SETTINGS.bak.$STAMP"
  if SETTINGS="$SETTINGS" HOOK_CMD="$HOOK_CMD" python3 - <<'PY'
import json, os, sys
path, cmd = os.environ["SETTINGS"], os.environ["HOOK_CMD"]
data = {}
if os.path.exists(path):
    with open(path) as f:
        data = json.load(f)
if not isinstance(data, dict):
    sys.exit(1)
hooks = data.setdefault("hooks", {})
if not isinstance(hooks, dict):
    sys.exit(1)
session_start = hooks.setdefault("SessionStart", [])
if not isinstance(session_start, list):
    sys.exit(1)
session_start.append({"hooks": [{"type": "command", "command": cmd}]})
tmp = path + ".tmp"
with open(tmp, "w") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
os.replace(tmp, path)  # atomic: never leaves a truncated settings.json
PY
  then
    echo "  hook: registered SessionStart update check in $SETTINGS"
  else
    echo "  warning: could not update $SETTINGS (invalid JSON, or hooks/SessionStart has an unexpected type)." >&2
    [ -f "$SETTINGS.bak.$STAMP" ] && echo "           (unmodified backup: $SETTINGS.bak.$STAMP)" >&2
    echo "           Register the hook manually: hooks.SessionStart += {\"hooks\":[{\"type\":\"command\",\"command\":\"$HOOK_CMD\"}]}" >&2
  fi
else
  echo "  warning: python3 not found — register the update-check hook manually in $SETTINGS:" >&2
  echo "           hooks.SessionStart += {\"hooks\":[{\"type\":\"command\",\"command\":\"$HOOK_CMD\"}]}" >&2
fi

for rel in "${OBSOLETE_PATHS[@]}"; do
  case "$rel" in ""|/*|*..*) echo "  warning: skipping unsafe obsolete path '$rel'" >&2; continue;; esac
  obsolete="$CLAUDE_DIR/$rel"
  if [ -e "$obsolete" ] || [ -L "$obsolete" ]; then
    if rm -rf "$obsolete"; then
      echo "  removed obsolete: $obsolete"
    else
      echo "  warning: could not remove obsolete path $obsolete" >&2
    fi
  fi
done

# Sweep backups of superseded files left behind by older installers.
for bak in "$CLAUDE_DIR"/agents/claude-reviewer.md.bak.* \
           "$CLAUDE_DIR"/agents/codex-reviewer.md.bak.* \
           "$CLAUDE_DIR"/agents/gemini-reviewer.md.bak.*; do
  [ -e "$bak" ] || continue
  rm -f "$bak" && echo "  removed obsolete: $bak"
done

printf 'version=%s\nref=%s\ninstalled=%s\n' "$VERSION" "$REF" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  > "$CLAUDE_DIR/.ai-consensus-skill.version"

echo ""
echo "Checking external CLI dependencies..."
for cli in codex agy; do
  if command -v "$cli" >/dev/null 2>&1; then
    echo "  ok: $cli ($(command -v "$cli"))"
  else
    echo "  MISSING: $cli — the ${cli}-based worker will be excluded until it is installed & logged in."
  fi
done

echo ""
echo "Done. Installed ai-consensus-skill $VERSION (ref: $REF):"
echo "  - skill: consensus         ($CLAUDE_DIR/skills/consensus/SKILL.md)"
echo "  - skill: consensus-review  ($CLAUDE_DIR/skills/consensus-review/SKILL.md)"
echo "  - agent: claude-worker, codex-worker, gemini-worker ($CLAUDE_DIR/agents/)"
echo "  - auto-update: daily check at session start ($CLAUDE_DIR/scripts/ai-consensus-check-update.sh; notice only — export AI_CONSENSUS_AUTO_UPDATE=1 to install updates automatically)"
echo "Restart Claude Code (or start a new session) to pick up the new skills/agents."
