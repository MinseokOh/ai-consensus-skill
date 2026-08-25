# ai-consensus-skill

Multi-agent consensus workflows for [Claude Code](https://claude.com/claude-code): before making important technical decisions or finalizing non-trivial code, Claude gathers **independent opinions from external CLI agents** (OpenAI Codex, Google Gemini), debates them in structured rounds, and only then commits to a result.

One model reviewing its own work tends to agree with itself. Three models that formed their opinions *independently* — and then have to defend them against each other — catch what any one of them would miss.

## What's included

| Type | Name | What it does |
|---|---|---|
| Skill | `consensus` | Round-based consensus loop for decisions (architecture, library choice, irreversible work) and a 2-track cross-review workflow for code writing |
| Skill | `consensus-review` | Runs every `*-worker` agent in parallel with the same review prompt and aggregates the findings into one deduplicated, severity-sorted report |
| Agent | `claude-worker` | Claude answers the given prompt in a context independent from the one that wrote the code |
| Agent | `codex-worker` | Relays the given prompt to `codex exec -s read-only` and returns Codex's answer |
| Agent | `gemini-worker` | Relays the given prompt to the Antigravity CLI (`agy --mode plan`) and returns Gemini's answer |

The agents follow a **worker pattern**: each is a thin, generic relay that executes an arbitrary prompt read-only and returns the answer as data. What to ask — a decision question, a code review, a rebuttal — is composed entirely by the skills. This keeps every external query visible as a named subagent task in Claude Code UIs, and adding a new model means adding one small worker file (plus a one-line registration in the `consensus` participants table).

## Installation

One line:

```bash
curl -fsSL https://raw.githubusercontent.com/MinseokOh/ai-consensus-skill/main/install.sh | bash
```

This downloads the skills and agents from this repo's raw paths into `~/.claude/`:

```
~/.claude/skills/consensus/SKILL.md
~/.claude/skills/consensus-review/SKILL.md
~/.claude/agents/claude-worker.md
~/.claude/agents/codex-worker.md
~/.claude/agents/gemini-worker.md
```

The installer is safe to re-run — existing files are backed up as `<file>.bak.<timestamp>` before being replaced, and agent files superseded by newer releases (e.g., the old `*-reviewer` agents) are retired the same way. Restart Claude Code (or start a new session) afterwards to pick up the new skills and agents.

Options via environment variables:

| Variable | Default | Meaning |
|---|---|---|
| `CLAUDE_DIR` | `~/.claude` | Install target directory |
| `REF` | `main` | Git ref (branch/tag) to install from |

```bash
# Example: install a specific tag into a custom location
# (fetch the installer from the same tag — its file list must match that ref)
curl -fsSL https://raw.githubusercontent.com/MinseokOh/ai-consensus-skill/v1.0.1/install.sh | CLAUDE_DIR=/path/to/.claude REF=v1.0.1 bash
```

### Versioning

Releases follow [Semantic Versioning](https://semver.org) and are published as git tags (`v1.0.0`, …), with changes documented in [CHANGELOG.md](CHANGELOG.md). The repo's current version lives in the [`VERSION`](VERSION) file.

- The default install tracks `main` (latest). For a **reproducible, pinned install**, fetch the installer from the tag *and* pass the same tag as `REF`:

  ```bash
  curl -fsSL https://raw.githubusercontent.com/MinseokOh/ai-consensus-skill/v1.0.1/install.sh | REF=v1.0.1 bash
  ```

  (Note: with the `curl | bash` form, `REF` must be set on the `bash` side of the pipe — `REF=v1.0.0 curl ... | bash` would only apply it to `curl`. The recorded version equals a release only when `REF` is a tag; on `main` it reflects the `VERSION` file at install time, which may be ahead of the last tag.)

- The installer prints the version it installed and records it to `$CLAUDE_DIR/.ai-consensus-skill.version` (version, ref, timestamp), so you can always check what you're running:

  ```bash
  cat ~/.claude/.ai-consensus-skill.version
  ```

### Requirements

- **Claude Code** — the skills/agents are loaded from `~/.claude`.
- **[Codex CLI](https://github.com/openai/codex)** (`codex`) — logged in. Used via `codex exec -s read-only`.
- **Antigravity CLI** (`agy`) — logged in with a Google account. Used via `agy --mode plan`. (Successor to the old `gemini-cli`, whose personal-account support was discontinued.)

The external CLIs are *optional but recommended*: the workflows degrade gracefully. Any agent that fails (not installed, not logged in, spend cap, timeout) is reported and excluded, and the round continues with the remaining participants — down to Claude alone if necessary. The installer checks for both CLIs and warns if they are missing.

## Usage

### `consensus` — decisions

Claude applies it automatically to important decisions (architecture/design direction, library or tool selection, diverging implementation approaches, hard-to-reverse work), or you can invoke it explicitly:

```
/consensus Should we use SQLite or Postgres for this service?
/consensus --explain <question>   # adds a narrative walkthrough of how the consensus formed
```

How a decision is reached:

1. **Independent opinions** — the same question (context + constraints + options) goes to every agent in parallel. Nobody sees anyone else's answer, and Claude locks in its own conclusion *before* reading the external ones (anti-anchoring).
2. **Aggregate & judge** — the latest positions are compared. Disagreements rooted in *verifiable claims* (API behavior, performance numbers, anything testable) are settled by an **evidence gate**: Claude verifies directly (tests, docs, reproduction) instead of letting the models debate facts.
3. **Rebuttal rounds** (max 2) — each agent receives the others' positions *quoted verbatim* (no summarizing, no reinterpretation) and must defend, concede, or revise.
4. **Termination** — unanimity is adopted; a majority is adopted only if its key reasoning passed the evidence gate; hard-to-reverse work requires unanimity or is escalated to you. Full splits are never resolved arbitrarily — they come back to you with each side's reasoning.

Every round's record is printed as it happens, so you can watch positions move.

### `consensus` — code writing (2-track)

For non-trivial code, Claude doesn't finalize alone:

- **Standard Track** (default): Claude drafts → all reviewers analyze independently in parallel (Claude's own review runs in a *separate* subagent context, since the context that wrote the code is anchored to it) → one rebuttal round with verbatim cross-quotes → moderator rules on each finding (evidence gate for disputed facts) → project linter/type checker/tests run as mandatory verification → a final approval pass only if the aggregated changes were large.
- **Critical Track** (algorithms, financial calculations, parsing, security, concurrency, data-loss risk): every agent writes an **independent implementation** of the same spec first; divergences are settled by tests where possible; the synthesized final version then goes through the Standard Track review.

### `consensus-review` — pre-commit/PR cross-review

```
/consensus-review                      # current branch vs main
/consensus-review main...feature-x     # explicit diff scope
```

All `*-worker` agents run concurrently with the same review prompt on the same diff. Results are merged (same file + same issue → one row, all discovering workers credited), sorted by severity, and suspicious findings are checked against the actual code before reporting so obvious false positives are dropped.

## Design principles

- **Independence first.** Round 1 opinions are formed blind. Cross-round quotes are verbatim, never paraphrased — summaries distort and anchor.
- **Evidence beats debate.** Anything verifiable is verified, not argued. Model headcount does not guarantee correctness; models can share biases.
- **External agents never touch your files.** All invocations are read-only (`codex -s read-only`, `agy --mode plan`). Claude alone writes files and runs code/tests.
- **Bounded cost.** Rebuttals are capped (2 for decisions, 1 for code review). Trivial changes (renames, typos, one-liners) skip the workflow entirely.
- **Failures are loud.** A failed agent is excluded and reported — never silently dropped, never guessed for.

## Extending

**Add a new model:** drop a `{model}-worker.md` into `~/.claude/agents/` — a thin relay that passes the given prompt to that model's CLI read-only and returns the answer prefixed with `[<Model>]` (or `[<Model> FAILED] <reason>` on error). Use an existing worker as a template.  `consensus-review` picks up any agent whose name ends in `-worker` (and matches the relay contract) automatically; for `consensus`, also register it in the participants table at the top of `skills/consensus/SKILL.md`. The workflows are participant-count agnostic.

## Repository layout

```
.claude/
  skills/
    consensus/SKILL.md      # decision consensus + 2-track code workflow
    consensus-review/SKILL.md  # parallel multi-model diff review
  agents/
    claude-worker.md
    codex-worker.md
    gemini-worker.md
install.sh                  # raw-path based installer
VERSION                     # current version (single line, semver)
CHANGELOG.md                # release history
```

The repo mirrors the `~/.claude` layout, so you can also install manually by copying `.claude/` over your own, or vendor it per-project.
