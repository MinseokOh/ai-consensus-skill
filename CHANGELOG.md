# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.1] - 2026-08-25

### Changed

- Replaced the `*-reviewer` agents with generic `*-worker` agents (`claude-worker`, `codex-worker`, `gemini-worker`): thin relays that execute an arbitrary prompt (decision query, code review, rebuttal, …) read-only and return the answer as data. All prompt content (review perspectives, return formats) now lives in the skills.
- `consensus`: decision-mode queries and code-mode reviews now run through the worker subagents (Agent tool) instead of raw background Bash — every external query shows up as a named background task in UIs (e.g., Orca); rebuttal rounds continue the same worker via SendMessage. Direct CLI invocation remains documented as a no-worker fallback.
- Renamed the `multi-review` skill to **`consensus-review`**; it now discovers `*-worker` agents and passes them the review prompt (perspectives and return format moved from the agents into the skill).
- `install.sh`: installs the worker agents and the renamed skill, and retires the superseded files (`skills/multi-review/SKILL.md`, `agents/*-reviewer.md`) with `.bak.<timestamp>` backups.

### Removed

- `claude-reviewer`, `codex-reviewer`, `gemini-reviewer` agent files and the `multi-review` skill path (superseded by the workers and `consensus-review`).

## [1.0.0] - 2026-08-25

### Added

- `consensus` skill: round-based consensus loop for decisions (independent opinions → evidence gate → rebuttals → termination ruling) and a 2-track cross-review workflow for code writing (Standard / Critical).
- `multi-review` skill: runs every `*-reviewer` agent in parallel on the same diff and aggregates findings into one deduplicated, severity-sorted report.
- Reviewer agents: `claude-reviewer`, `codex-reviewer` (Codex CLI), `gemini-reviewer` (Antigravity CLI).
- `install.sh`: raw-path based installer with `CLAUDE_DIR` / `REF` overrides, timestamped backups, and external CLI dependency checks.
- Version management: `VERSION` file, this changelog, and semver git tags; the installer reports and records the installed version.

[1.0.1]: https://github.com/MinseokOh/ai-consensus-skill/releases/tag/v1.0.1
[1.0.0]: https://github.com/MinseokOh/ai-consensus-skill/releases/tag/v1.0.0
