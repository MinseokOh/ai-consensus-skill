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

echo "Installing skills/agents from $RAW_BASE into $CLAUDE_DIR ..."

for repo_path in "${FILES[@]}"; do
  dest="$CLAUDE_DIR/${repo_path#.claude/}"
  url="$RAW_BASE/$repo_path"

  tmp="$(mktemp)"
  if ! curl -fsSL "$url" -o "$tmp"; then
    rm -f "$tmp"
    echo "  ERROR: failed to download $url" >&2
    exit 1
  fi

  mkdir -p "$(dirname "$dest")"
  if [ -f "$dest" ]; then
    cp "$dest" "$dest.bak.$STAMP"
    echo "  backup: $dest -> $dest.bak.$STAMP"
  fi
  mv "$tmp" "$dest"
  echo "  installed: $dest"
done

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
echo "Done. Installed:"
echo "  - skill: consensus     ($CLAUDE_DIR/skills/consensus/SKILL.md)"
echo "  - skill: multi-review  ($CLAUDE_DIR/skills/multi-review/SKILL.md)"
echo "  - agent: claude-reviewer, codex-reviewer, gemini-reviewer ($CLAUDE_DIR/agents/)"
echo "Restart Claude Code (or start a new session) to pick up the new skills/agents."
