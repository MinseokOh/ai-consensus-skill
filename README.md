# ai-consensus-skill

Multi-agent consensus workflows for [Claude Code](https://claude.com/claude-code): before making important technical decisions or finalizing non-trivial code, Claude gathers **independent opinions from external CLI agents** (OpenAI Codex, Google Gemini), debates them in structured rounds, and only then commits to a result.

One model reviewing its own work tends to agree with itself. Three models that formed their opinions *independently* — and then have to defend them against each other — catch what any one of them would miss.

## What's included

| Type | Name | What it does |
|---|---|---|
| Skill | `consensus` | Round-based consensus loop for decisions (architecture, library choice, irreversible work) and a 2-track cross-review workflow for code writing |
| Skill | `multi-review` | Runs every `*-reviewer` agent in parallel on the same diff and aggregates the findings into one deduplicated, severity-sorted report |
| Agent | `claude-reviewer` | Claude reviews the diff directly, in a context independent from the one that wrote the code |
| Agent | `codex-reviewer` | Drives `codex exec --sandbox read-only` and returns Codex's findings |
| Agent | `gemini-reviewer` | Drives the Antigravity CLI (`agy --mode plan`) and returns Gemini's findings |

## Installation

One line:

```bash
curl -fsSL https://raw.githubusercontent.com/MinseokOh/ai-consensus-skill/main/install.sh | bash
```

This downloads the skills and agents from this repo's raw paths into `~/.claude/`:

```
~/.claude/skills/consensus/SKILL.md
~/.claude/skills/multi-review/SKILL.md
~/.claude/agents/claude-reviewer.md
~/.claude/agents/codex-reviewer.md
~/.claude/agents/gemini-reviewer.md
```

The installer is safe to re-run — existing files are backed up as `<file>.bak.<timestamp>` before being replaced. Restart Claude Code (or start a new session) afterwards to pick up the new skills and agents.

Options via environment variables:

| Variable | Default | Meaning |
|---|---|---|
| `CLAUDE_DIR` | `~/.claude` | Install target directory |
| `REF` | `main` | Git ref (branch/tag) to install from |

```bash
# Example: install a specific tag into a custom location
CLAUDE_DIR=/path/to/.claude REF=v1.0.0 bash -c "$(curl -fsSL https://raw.githubusercontent.com/MinseokOh/ai-consensus-skill/main/install.sh)"
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

### `multi-review` — pre-commit/PR cross-review

```
/multi-review                      # current branch vs main
/multi-review main...feature-x     # explicit diff scope
```

All `*-reviewer` agents run concurrently on the same diff. Results are merged (same file + same issue → one row, all discovering workers credited), sorted by severity, and suspicious findings are checked against the actual code before reporting so obvious false positives are dropped.

## Design principles

- **Independence first.** Round 1 opinions are formed blind. Cross-round quotes are verbatim, never paraphrased — summaries distort and anchor.
- **Evidence beats debate.** Anything verifiable is verified, not argued. Model headcount does not guarantee correctness; models can share biases.
- **External agents never touch your files.** All invocations are read-only (`codex -s read-only`, `agy --mode plan`). Claude alone writes files and runs code/tests.
- **Bounded cost.** Rebuttals are capped (2 for decisions, 1 for code review). Trivial changes (renames, typos, one-liners) skip the workflow entirely.
- **Failures are loud.** A failed agent is excluded and reported — never silently dropped, never guessed for.

## Extending

**Add a new external agent to `consensus`:** register its non-interactive, read-only invocation in the participating-agents table at the top of `skills/consensus/SKILL.md`. The workflow itself is participant-count agnostic.

**Add a new review worker to `multi-review`:** drop a `{model}-reviewer.md` into `~/.claude/agents/`. Any agent whose name ends in `-reviewer` is picked up automatically — the skill file needs no changes. Use an existing reviewer as a template; the contract is simply to return findings as:

```
[<Model> review results]
- {file}:{line} | {severity} | {description}
```

## Repository layout

```
.claude/
  skills/
    consensus/SKILL.md      # decision consensus + 2-track code workflow
    multi-review/SKILL.md   # parallel multi-model diff review
  agents/
    claude-reviewer.md
    codex-reviewer.md
    gemini-reviewer.md
install.sh                  # raw-path based installer
```

The repo mirrors the `~/.claude` layout, so you can also install manually by copying `.claude/` over your own, or vendor it per-project.
