# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.0] - 2026-08-25

### Added

- `consensus` skill: round-based consensus loop for decisions (independent opinions → evidence gate → rebuttals → termination ruling) and a 2-track cross-review workflow for code writing (Standard / Critical).
- `multi-review` skill: runs every `*-reviewer` agent in parallel on the same diff and aggregates findings into one deduplicated, severity-sorted report.
- Reviewer agents: `claude-reviewer`, `codex-reviewer` (Codex CLI), `gemini-reviewer` (Antigravity CLI).
- `install.sh`: raw-path based installer with `CLAUDE_DIR` / `REF` overrides, timestamped backups, and external CLI dependency checks.
- Version management: `VERSION` file, this changelog, and semver git tags; the installer reports and records the installed version.

[1.0.0]: https://github.com/MinseokOh/ai-consensus-skill/releases/tag/v1.0.0
