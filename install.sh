#!/usr/bin/env bash
# Installs the consensus + multi-review skills and the reviewer agents
# (claude-reviewer, codex-reviewer, gemini-reviewer) into ~/.claude by
# downloading them from the public GitHub repo (raw paths).
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/MinseokOh/ai-consensus-skill/main/install.sh | bash
#
# Options (env vars):
#   CLAUDE_DIR  install target (default: ~/.claude)
#   REF         git ref to install from (default: main)
#
# Safe to re-run: existing files are backed up as <file>.bak.<timestamp>.
# All files are downloaded first and installed only if every download
# succeeds, so a failed run never leaves a partial install.
# The installed version is recorded to $CLAUDE_DIR/.ai-consensus-skill.version
# (a state stamp, overwritten on every install).
set -euo pipefail

REPO="MinseokOh/ai-consensus-skill"
REF="${REF:-main}"
RAW_BASE="https://raw.githubusercontent.com/$REPO/$REF"
CLAUDE_DIR="${CLAUDE_DIR:-$HOME/.claude}"
STAMP="$(date +%Y%m%d%H%M%S)"

FILES=(
  ".claude/skills/consensus/SKILL.md"
  ".claude/skills/multi-review/SKILL.md"
  ".claude/agents/claude-reviewer.md"
  ".claude/agents/codex-reviewer.md"
  ".claude/agents/gemini-reviewer.md"
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

# Phase 1: download everything; abort before touching $CLAUDE_DIR on any failure.
for repo_path in "${FILES[@]}"; do
  tmp="$TMP_DIR/${repo_path#.claude/}"
  mkdir -p "$(dirname "$tmp")"
  if ! curl -fsSL "$RAW_BASE/$repo_path" -o "$tmp"; then
    echo "  ERROR: failed to download $RAW_BASE/$repo_path — nothing was installed" >&2
    exit 1
  fi
done

# Phase 2: back up and install.
for repo_path in "${FILES[@]}"; do
  rel="${repo_path#.claude/}"
  dest="$CLAUDE_DIR/$rel"
  mkdir -p "$(dirname "$dest")"
  if [ -f "$dest" ]; then
    cp "$dest" "$dest.bak.$STAMP"
    echo "  backup: $dest -> $dest.bak.$STAMP"
  fi
  mv "$TMP_DIR/$rel" "$dest"
  echo "  installed: $dest"
done

printf 'version=%s\nref=%s\ninstalled=%s\n' "$VERSION" "$REF" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  > "$CLAUDE_DIR/.ai-consensus-skill.version"

echo ""
echo "Checking external CLI dependencies..."
for cli in codex agy; do
  if command -v "$cli" >/dev/null 2>&1; then
    echo "  ok: $cli ($(command -v "$cli"))"
  else
    echo "  MISSING: $cli — the ${cli}-based reviewer/agent will be excluded until it is installed & logged in."
  fi
done

echo ""
echo "Done. Installed ai-consensus-skill $VERSION (ref: $REF):"
echo "  - skill: consensus     ($CLAUDE_DIR/skills/consensus/SKILL.md)"
echo "  - skill: multi-review  ($CLAUDE_DIR/skills/multi-review/SKILL.md)"
echo "  - agent: claude-reviewer, codex-reviewer, gemini-reviewer ($CLAUDE_DIR/agents/)"
echo "Restart Claude Code (or start a new session) to pick up the new skills/agents."
