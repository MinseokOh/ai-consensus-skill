#!/usr/bin/env bash
# Installs the consensus + consensus-review skills into Claude Code and/or Codex
# by downloading them from the public GitHub repo (raw paths).
#
# Claude Code target: the two skills plus the worker agents (claude-worker,
# codex-worker, gemini-worker) into ~/.claude.
# Codex target: the two skills plus the shared engine runner
# (skills/consensus/scripts/worker.sh) into $CODEX_HOME (~/.codex). Codex has no
# user-definable subagents, so the workers ship as that runner instead.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/MinseokOh/ai-consensus-skill/main/install.sh | bash
#   curl -fsSL .../install.sh | bash -s -- --target codex
#   ./install.sh --target both
#
# Options:
#   --target claude|codex|both   what to install (default: claude)
#   --claude | --codex | --both  shorthand for the above
#
# Options (env vars):
#   TARGET      same as --target
#   CLAUDE_DIR  Claude install target (default: ~/.claude)
#   CODEX_DIR   Codex install target  (default: $CODEX_HOME, else ~/.codex)
#   REF         git ref to install from (default: main)
#
# Safe to re-run: files being replaced are backed up as <file>.bak.<timestamp>;
# files superseded by newer releases (old skills/agents) are deleted.
# The Claude target also registers a SessionStart auto-update hook in
# $CLAUDE_DIR/settings.json (backed up before modification; see README
# "Auto-update"). The Codex target installs no hook and never touches
# config.toml or AGENTS.md.
# All files are downloaded to a staging dir first and installed only if
# every download succeeds, so a failed download never leaves a partial
# install.
# The installed version is recorded to <target dir>/.ai-consensus-skill.version
# (a state stamp, overwritten on every install).
set -euo pipefail

REPO="MinseokOh/ai-consensus-skill"
REF="${REF:-main}"
RAW_BASE="https://raw.githubusercontent.com/$REPO/$REF"
CLAUDE_DIR="${CLAUDE_DIR:-$HOME/.claude}"
CODEX_DIR="${CODEX_DIR:-${CODEX_HOME:-$HOME/.codex}}"
TARGET="${TARGET:-claude}"
STAMP="$(date +%Y%m%d%H%M%S)"

# Printed literally: `curl … | bash -s -- --help` makes $0 the bash binary, so
# anything that reads $0 for its own comments fails there.
usage() {
  cat <<'USAGE'
Installs the consensus + consensus-review skills into Claude Code and/or Codex.

Usage:
  curl -fsSL https://raw.githubusercontent.com/MinseokOh/ai-consensus-skill/main/install.sh | bash
  curl -fsSL .../install.sh | bash -s -- --target codex
  ./install.sh --target both

Options:
  --target claude|codex|both   what to install (default: claude)
  --claude | --codex | --both  shorthand for the above
  -h, --help                   this message

Environment:
  TARGET      same as --target
  CLAUDE_DIR  Claude install target (default: ~/.claude)
  CODEX_DIR   Codex install target  (default: $CODEX_HOME, else ~/.codex)
  REF         git ref to install from (default: main)

Claude Code gets the two skills plus the worker agents; Codex gets the two skills
plus the shared engine runner (skills/consensus/scripts/worker.sh), since Codex has
no user-definable subagents. Only the Claude target registers a hook; the Codex
target never touches config.toml or AGENTS.md.
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --target) [ $# -ge 2 ] || { echo "ERROR: --target requires a value (try --help)" >&2; exit 1; }
              TARGET="$2"; shift 2;;
    --target=*) TARGET="${1#--target=}"; shift;;
    --claude) TARGET="claude"; shift;;
    --codex)  TARGET="codex";  shift;;
    --both|--all) TARGET="both"; shift;;
    -h|--help) usage; exit 0;;
    *) echo "ERROR: unknown argument '$1' (try --help)" >&2; exit 1;;
  esac
done

case "$TARGET" in
  claude|codex|both) ;;
  *) echo "ERROR: --target must be claude, codex or both (got '$TARGET')" >&2; exit 1;;
esac

WANT_CLAUDE=0; WANT_CODEX=0
case "$TARGET" in claude|both) WANT_CLAUDE=1;; esac
case "$TARGET" in codex|both)  WANT_CODEX=1;;  esac

if [ "$WANT_CLAUDE" = "1" ]; then
  case "$CLAUDE_DIR" in
    ""|"/") echo "ERROR: refusing to install into CLAUDE_DIR='$CLAUDE_DIR'" >&2; exit 1;;
  esac
fi
if [ "$WANT_CODEX" = "1" ]; then
  case "$CODEX_DIR" in
    ""|"/") echo "ERROR: refusing to install into CODEX_DIR='$CODEX_DIR'" >&2; exit 1;;
  esac
fi
# Resolve to a physical path so `/x`, `/x/.`, `/x/../x` and a symlink to /x all
# compare equal. An existing directory is resolved with `pwd -P`; otherwise its
# parent is, so a not-yet-created target still normalizes.
norm_dir() {
  local d="$1" parent base
  if [ -d "$d" ]; then
    (cd "$d" 2>/dev/null && pwd -P) || printf '%s' "$d"
    return
  fi
  parent="$(dirname "$d")"; base="$(basename "$d")"
  if [ -d "$parent" ]; then
    printf '%s/%s' "$(cd "$parent" 2>/dev/null && pwd -P)" "$base"
  else
    printf '%s' "$d"
  fi
}

# Both targets write skills/consensus/SKILL.md, so a shared root silently overwrites
# one payload with the other and leaves a single version stamp.
if [ "$WANT_CLAUDE" = "1" ] && [ "$WANT_CODEX" = "1" ]; then
  claude_real="$(norm_dir "$CLAUDE_DIR")"
  codex_real="$(norm_dir "$CODEX_DIR")"
  if [ "$claude_real" = "$codex_real" ]; then
    echo "ERROR: CLAUDE_DIR and CODEX_DIR resolve to the same directory ('$claude_real'); install one target at a time" >&2
    exit 1
  fi
fi

# Repo-relative paths; the leading ".claude/" or ".codex/" is stripped on install.
CLAUDE_FILES=(
  ".claude/skills/consensus/SKILL.md"
  ".claude/skills/consensus-review/SKILL.md"
  ".claude/agents/claude-worker.md"
  ".claude/agents/codex-worker.md"
  ".claude/agents/gemini-worker.md"
  ".claude/scripts/ai-consensus-check-update.sh"
)

CODEX_FILES=(
  ".codex/skills/consensus/SKILL.md"
  ".codex/skills/consensus/agents/openai.yaml"
  ".codex/skills/consensus/references/workers.md"
  ".codex/skills/consensus/scripts/worker.sh"
  ".codex/skills/consensus-review/SKILL.md"
  ".codex/skills/consensus-review/agents/openai.yaml"
)

# Paths from older releases that this version supersedes; DELETED on install
# (including any leftover backups inside a superseded skill directory).
# Note: paths here are relative to the target dir, while the FILES arrays above
# are repo-relative.
CLAUDE_OBSOLETE_PATHS=(
  "skills/multi-review"
  "agents/claude-reviewer.md"
  "agents/codex-reviewer.md"
  "agents/gemini-reviewer.md"
)

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

VERSION="$(curl -fsSL "$RAW_BASE/VERSION" 2>/dev/null | head -n1 | tr -d '[:space:]' || true)"
VERSION="${VERSION#v}"
if [ -z "$VERSION" ]; then
  echo "warning: could not fetch VERSION for ref '$REF' (bad ref, or a ref predating the VERSION file?); recording version as 'unknown'" >&2
  VERSION="unknown"
fi

echo "Installing from $RAW_BASE"
echo "  version: $VERSION (ref: $REF)"
echo "  target:  $TARGET"
if [ "$WANT_CLAUDE" = "1" ]; then echo "    claude -> $CLAUDE_DIR"; fi
if [ "$WANT_CODEX" = "1" ];  then echo "    codex  -> $CODEX_DIR";  fi

# Phase 1: download everything; abort before installing anything on any failure.
# Staged under $TMP_DIR/<prefix>/<rel> so the two targets never collide.
download_files() {
  local prefix="$1"; shift
  local repo_path rel tmp
  for repo_path in "$@"; do
    rel="${repo_path#".$prefix/"}"
    tmp="$TMP_DIR/$prefix/$rel"
    mkdir -p "$(dirname "$tmp")"
    if ! curl -fsSL "$RAW_BASE/$repo_path" -o "$tmp"; then
      echo "  ERROR: failed to download $RAW_BASE/$repo_path — nothing was installed" >&2
      exit 1
    fi
  done
}

# Phase 2: back up and install. The final step is a same-directory rename so
# each file is replaced atomically (mv from the staging dir may cross
# filesystems and degrade to a copy — never let that write the live path).
install_files() {
  local prefix="$1" dest_root="$2"; shift 2
  local repo_path rel dest
  for repo_path in "$@"; do
    rel="${repo_path#".$prefix/"}"
    dest="$dest_root/$rel"
    mkdir -p "$(dirname "$dest")"
    if [ -f "$dest" ]; then
      cp "$dest" "$dest.bak.$STAMP"
      echo "  backup: $dest -> $dest.bak.$STAMP"
    fi
    mv "$TMP_DIR/$prefix/$rel" "$dest.tmp.$$"
    mv -f "$dest.tmp.$$" "$dest"
    echo "  installed: $dest"
  done
}

remove_obsolete() {
  local dest_root="$1"; shift
  local rel obsolete
  for rel in "$@"; do
    case "$rel" in ""|/*|*..*) echo "  warning: skipping unsafe obsolete path '$rel'" >&2; continue;; esac
    obsolete="$dest_root/$rel"
    if [ -e "$obsolete" ] || [ -L "$obsolete" ]; then
      if rm -rf "$obsolete"; then
        echo "  removed obsolete: $obsolete"
      else
        echo "  warning: could not remove obsolete path $obsolete" >&2
      fi
    fi
  done
}

stamp_version() {
  printf 'version=%s\nref=%s\ninstalled=%s\n' "$VERSION" "$REF" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    > "$1/.ai-consensus-skill.version"
}

if [ "$WANT_CLAUDE" = "1" ]; then download_files claude "${CLAUDE_FILES[@]}"; fi
if [ "$WANT_CODEX" = "1" ];  then download_files codex  "${CODEX_FILES[@]}";  fi

if [ "$WANT_CLAUDE" = "1" ]; then
  echo ""
  echo "Claude Code -> $CLAUDE_DIR"
  mkdir -p "$CLAUDE_DIR"
  install_files claude "$CLAUDE_DIR" "${CLAUDE_FILES[@]}"

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

  remove_obsolete "$CLAUDE_DIR" "${CLAUDE_OBSOLETE_PATHS[@]}"

  # Sweep backups of superseded files left behind by older installers.
  for bak in "$CLAUDE_DIR"/agents/claude-reviewer.md.bak.* \
             "$CLAUDE_DIR"/agents/codex-reviewer.md.bak.* \
             "$CLAUDE_DIR"/agents/gemini-reviewer.md.bak.*; do
    [ -e "$bak" ] || continue
    rm -f "$bak" && echo "  removed obsolete: $bak"
  done

  stamp_version "$CLAUDE_DIR"
fi

if [ "$WANT_CODEX" = "1" ]; then
  echo ""
  echo "Codex -> $CODEX_DIR"
  mkdir -p "$CODEX_DIR"
  install_files codex "$CODEX_DIR" "${CODEX_FILES[@]}"

  chmod +x "$CODEX_DIR/skills/consensus/scripts/worker.sh" \
    || echo "  warning: could not chmod +x $CODEX_DIR/skills/consensus/scripts/worker.sh" >&2

  stamp_version "$CODEX_DIR"
fi

echo ""
echo "Checking external CLI dependencies..."
DEPS=""
# Every seat is a separate process on both targets — the Claude target relays its
# own seat to a headless `claude -p` too — so check all three binaries either way.
if [ "$WANT_CLAUDE" = "1" ]; then DEPS="$DEPS claude codex agy"; fi
if [ "$WANT_CODEX" = "1" ];  then DEPS="$DEPS claude codex agy"; fi
# shellcheck disable=SC2086  # $DEPS is a deliberate space-separated list
for cli in $(printf '%s\n' $DEPS | tr ' ' '\n' | sed '/^$/d' | sort -u); do
  case "$cli" in
    claude) seat="Claude";;
    codex)  seat="Codex";;
    agy)    seat="Gemini";;
    *)      seat="$cli";;
  esac
  if command -v "$cli" >/dev/null 2>&1; then
    echo "  ok: $cli ($(command -v "$cli")) — $seat seat"
  else
    echo "  MISSING: $cli — the $seat seat will be excluded until it is installed & logged in."
  fi
done

echo ""
echo "Done. Installed ai-consensus-skill $VERSION (ref: $REF):"
if [ "$WANT_CLAUDE" = "1" ]; then
  echo "  Claude Code ($CLAUDE_DIR)"
  echo "    - skill: consensus, consensus-review  ($CLAUDE_DIR/skills/)"
  echo "    - agent: claude-worker, codex-worker, gemini-worker  ($CLAUDE_DIR/agents/)"
  echo "    - auto-update: daily check at session start ($CLAUDE_DIR/scripts/ai-consensus-check-update.sh; notice only — export AI_CONSENSUS_AUTO_UPDATE=1 to install updates automatically)"
fi
if [ "$WANT_CODEX" = "1" ]; then
  echo "  Codex ($CODEX_DIR)"
  echo "    - skill: consensus, consensus-review  ($CODEX_DIR/skills/)"
  echo "    - runner: worker.sh  ($CODEX_DIR/skills/consensus/scripts/worker.sh)"
  echo "    - no hook installed; config.toml and AGENTS.md are untouched"
fi
echo "Restart the CLI (or start a new session) to pick up the new skills."
