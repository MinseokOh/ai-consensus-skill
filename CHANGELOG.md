# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.3.0] - 2026-09-09

### Added

- **Codex CLI target**: the `consensus` and `consensus-review` skills now ship for Codex under `.codex/`, installed into `$CODEX_HOME` (default `~/.codex`) with `install.sh --target codex` (or `--target both`). Codex also discovers a project-local `.codex/skills/`, so the payload can be vendored per-repo instead of installed globally.
- `.codex/skills/consensus/scripts/worker.sh` — the engine adapter that replaces the three worker subagents, since Codex has no user-definable subagent mechanism. It runs one prompt on one engine (`claude -p`, `codex exec -s read-only`, `agy --mode plan`) as a fresh read-only OS process and prints exactly one normalized block: `[<Model> effort=<level>]` with the answer, or `[<Model> FAILED] <reason>`. A separate process supplies the same context isolation a subagent did — each engine starts from a fresh session and sees only the frozen prompt file.
  - One deadline covers the whole call, so a retry draws from what is left of the budget rather than re-arming it; budgets stay 120s by default, 180s at `high`, 600s for Claude and 300s for Codex at `xhigh`/`max`, and 180s for Gemini, whose budget follows its capped level.
  - Engine stderr is kept in a separate file and never becomes the answer; `codex exec` answers come from `--output-last-message`, and an empty final message on a zero exit is a failure rather than a fallback to the event log.
  - `INT`/`TERM`/`HUP` traps kill each engine's process group (`set -m`) and remove the temp dir, so a cancelled round leaves no paid engine running; the shell's job-control notices are kept out of the answer block.
  - Deterministic retries only: one step down from `xhigh`/`max` when Codex rejects the reasoning effort, and one retry when agy dies on its own `permission check failed`.
- `.codex/skills/consensus/references/workers.md` — per-engine operating notes: transport limits, effort caps and timeout budgets, how to read a result, failure handling, adding an engine, and the direct-CLI commands to fall back on if the runner is missing.
- `agents/openai.yaml` for both Codex skills (display name, short description, default prompt, implicit-invocation policy).

### Changed

- `install.sh` takes `--target claude|codex|both` (default `claude`, so existing one-line installs are unchanged) and a `CODEX_DIR` override. Downloads are staged per target and installed only if every download succeeds; the Codex target installs no hook and never touches `config.toml` or `AGENTS.md`. `--help` is now printed literally, so it works over the documented `curl … | bash -s -- --help` form where `$0` is the bash binary. An option given without a value, and a `--target both` where both roots resolve to the same directory, are rejected with a message instead of aborting mid-run. The dependency check now covers every CLI the selected target actually invokes and names the seat that would be lost.

### Notes

- On Codex the host session holds the Codex seat in decision mode and holds **no** seat in code mode — it drafts and moderates, while a fresh `codex exec` process takes the Codex reviewer seat, so the host and the worker are never counted as two seats.
- `codex exec` has no equivalent of Claude's `--safe-mode` / `--disallowed-tools`: a delegated Codex seat still enumerates the installed skills and still runs the user's hooks (`--disable skill_search`, `--enable skip_host_skill_discovery` and `--disable multi_agent` were each tried and suppress none of it). The runner prepends a delegated-reviewer instruction to every Codex prompt; this is a behavioral mitigation, not enforcement.
- The `.claude/` payload is unchanged by this release. The `SessionStart` auto-update hook therefore still updates only the Claude target; after a `--target both` install, re-run the installer with `--target codex` to update `$CODEX_DIR`.

## [1.2.0] - 2026-08-26

### Added

- **Per-run reasoning effort**: the invoking model picks one effort level per run and passes it to every worker as a worker-directed `Effort: <low|medium|high|xhigh|max>` line, separate from the task prompt; each worker maps it onto its own engine (`claude -p --effort`, `codex exec -c model_reasoning_effort=`, `agy --effort`). With no directive every engine keeps its current default, so existing behavior is unchanged.
- `consensus-review`: accepts an explicit `--effort <level>` argument, and otherwise derives the level from the diff — `high` for security/auth/crypto, concurrency/transaction, money, or migration/deletion changes and large diffs (>15 files or >500 lines), `low` for docs- or generated-file-only churn, `medium` otherwise. `xhigh`/`max` are never chosen automatically. The chosen level is announced before the run and recorded in the report's summary line.
- Workers report the level they actually ran at in their source bracket (`[<Model> effort=<level>]`), so a capped or degraded run is visible instead of being read as the requested level.

### Changed

- `claude-worker`: gained an effort mode. A subagent cannot change its own reasoning effort, so when an effort level is requested the worker relays the task to a headless `claude -p "<prompt>" --effort <level> --safe-mode --permission-mode plan` session with a read-only allow-list and `--disallowed-tools "Agent,Task,Skill"`, and returns its answer; if that run fails it falls back to answering in-process and labels the result `effort=inherited`. Without a directive it answers directly, as before.
  - `--safe-mode` is load-bearing: it keeps the headless session from running the user's hooks (a `SessionStart` auto-update hook could rewrite the worker files mid-review), from starting MCP servers, and from loading the project's own skills/agents — which the relayed review prompt could otherwise re-trigger into a recursive fan-out of workers. `--bare` is not a substitute: it never reads OAuth or the keychain. The file also records that the git allow-list is prefix-matched (`git diff --output=<file>` writes, `--ext-diff` executes), that the reviewed diff is untrusted input, and that CLI banner/stderr text must be stripped rather than returned as an answer.
- `codex-worker` / `gemini-worker`: document the effort flag for their engine. Codex accepts all five levels (an unsupported value comes back as an API 400); agy supports only `low|medium|high`, so `xhigh`/`max` run there as `high` and are reported as `high`.
- Timeouts are now budgeted per level instead of a flat ~120s (measured on a ~50-line diff: ~35-70s at `low`, ~8 minutes for the headless Claude seat at `xhigh`), and the no-worker fallbacks map `xhigh`/`max` down to `high` for agy the same way the worker does.
- `consensus`: the participants table, the no-worker fallback commands, and Cautions now cover the effort directive — including the rule that every participant in a round runs at the same level, and that a round labeled `max` is not `max` for Gemini.

## [1.1.0] - 2026-08-25

### Added

- **Auto-update**: `scripts/ai-consensus-check-update.sh`, run from a Claude Code `SessionStart` hook, checks the remote `VERSION` on `main` at most once a day (3s network cap, silent on failure) and prints an update notice into the session context when it differs from the installed version. `export AI_CONSENSUS_AUTO_UPDATE=1` makes it install the new release automatically instead, pinned to that release's tag; `AI_CONSENSUS_UPDATE_INTERVAL` (seconds) tunes the check frequency, `0` disables it. Installs pinned to a non-release ref are never checked.
- `install.sh` installs the check script and registers the `SessionStart` hook in `$CLAUDE_DIR/settings.json` (idempotent, JSON-merged via python3 with a backup and an atomic write; prints manual instructions if python3 is missing or the file is invalid). File replacement in phase 2 is now an atomic same-directory rename.

## [1.0.2] - 2026-08-25

### Changed

- `install.sh`: paths superseded by newer releases (the old `multi-review` skill directory and `*-reviewer` agents, plus `.bak.*` leftovers earlier installers made of them) are now **deleted** on update instead of being renamed to `.bak.<timestamp>`. Backups are still made for current files being replaced. The deletion is guarded (refuses `CLAUDE_DIR=/` or empty, unsafe relative paths, and continues with a warning if a removal fails).

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

[1.2.0]: https://github.com/MinseokOh/ai-consensus-skill/releases/tag/v1.2.0
[1.1.0]: https://github.com/MinseokOh/ai-consensus-skill/releases/tag/v1.1.0
[1.0.2]: https://github.com/MinseokOh/ai-consensus-skill/releases/tag/v1.0.2
[1.0.1]: https://github.com/MinseokOh/ai-consensus-skill/releases/tag/v1.0.1
[1.0.0]: https://github.com/MinseokOh/ai-consensus-skill/releases/tag/v1.0.0
