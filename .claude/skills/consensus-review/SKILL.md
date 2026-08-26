---
name: consensus-review
description: A workflow that runs multiple model workers (*-worker agents such as claude-worker, codex-worker, gemini-worker) in parallel to perform multi-model code review and aggregate the results. Use when you want to cross-validate a diff before a commit/PR.
---

# Consensus Review (multi-model code review)

Run every available worker agent concurrently with the same review prompt, so each model reviews the same diff independently, then aggregate and report the results.

## Review workers

- Use **all** agents whose names end in `-worker` from the available-agents list **and whose description matches the worker relay contract** (a generic read-only prompt relay, e.g., `claude-worker`, `codex-worker`, `gemini-worker`, and later additions). Skip unrelated agents that merely happen to end in `-worker`.
- Workers are generic prompt relays registered as `~/.claude/agents/{model}-worker.md` — the review perspectives and return format live in **this skill's prompt**, not in the workers. Adding a new model requires no change to this skill file.
- **No-worker fallback**: if no worker agents are installed, spawn general-purpose agents (one per engine, in parallel) and give each the same step-1 review prompt plus its engine's read-only invocation: `claude -p "<prompt>" --effort <level> --safe-mode --permission-mode plan --allowed-tools "Read,Grep,Glob,Bash(git diff:*),Bash(git log:*),Bash(git show:*),Bash(git status:*)" --disallowed-tools "Agent,Task,Skill"` for the Claude seat (append the same two lines `claude-worker` documents — the untrusted-content line and the no-plan line — since `--permission-mode plan` applies here too), `codex exec -s read-only -c model_reasoning_effort="<level>" "<prompt>"` for Codex, and `agy -p "Do not run any tools; answer using only the text below. <prompt + diff embedded via command substitution>" --mode plan --effort <level mapped to high for xhigh/max>` for Gemini. Have them use the same return format, prefixed `[<Model>]` (or `[<Model> FAILED] <reason>`).

## Review scope

- If arguments are given, use that scope: $ARGUMENTS
- If no arguments, target the current branch against `main` (`git diff main...HEAD`). If the repo has no `main`, find and use the default branch.
- Before starting the review, confirm changes actually exist with `git diff <scope> --stat`; if there are none, do not spawn workers — just report that fact.

## Review effort

Decide **one** reasoning effort level for the run and pass it to every worker, so review depth is a deliberate choice instead of whatever default each engine happens to carry.

- **Explicit wins**: if the arguments contain `--effort <level>` (or `--effort=<level>`), use it, and strip it before interpreting the rest as the review scope. Levels: `low | medium | high | xhigh | max`.
- **Otherwise judge from the diff** (`git diff <scope> --stat` plus a look at what actually changed):
  - `high` — security/auth/crypto, concurrency/locking/transactions, money or billing calculations, data migration or deletion, or a large diff (roughly >15 files or >500 changed lines)
  - `low` — docs/comments/formatting only, or generated-file and lockfile churn
  - `medium` — everything else
  - `xhigh` and `max` are **never** chosen automatically; they cost real time and money, so they only come from an explicit `--effort`.
- **Pass it as a worker-directed line**, kept separate from the review prompt (it instructs the worker, it is not part of the review task): `Effort: <level>`. Each worker maps it to its own engine — `claude -p --effort`, `codex exec -c model_reasoning_effort=`, `agy --effort`.
- **Caps**: agy (Gemini) supports only `low|medium|high`, so `xhigh`/`max` run there as `high`. Workers report the level they actually used, so read it off their answers rather than assuming the requested level held.
- State the chosen level (and why, in one clause) when announcing the review, so an unexpectedly shallow or expensive run is visible before it starts.

## Execution

1. Launch all workers with the Agent tool **in the same message** (parallel execution), each with the identical review prompt:

   ```
   Review the diff <scope> in <project dir>. Look for problems from these perspectives: (1) bugs/logic errors (2) missed edge cases (3) concurrency/transaction issues (4) performance issues (5) security vulnerabilities. Return each finding as a '{file path}:{line} | {severity(high/medium/low)} | {description}' line. If there are no problems, answer 'No findings'.
   ```

   Alongside that prompt, give each worker the effort directive decided above as its own line — `Effort: <level>` — addressed to the worker, not part of the review task.

   Each worker resolves the scope its own way (claude-worker reads the diff and surrounding code directly, or relays to a headless `claude -p` session when an effort level is given; codex-worker lets Codex read the repo; gemini-worker embeds the diff into its prompt).
2. Workers return their answer prefixed with a `[<Model>]` source line. Check the bracket for `FAILED` **first** — `[<Model> FAILED] <reason>` is a failed worker, never a source label with findings under it. Otherwise treat the first token in the bracket as the source label, with the finding lines following it. An `effort=<level>` token in the same bracket (e.g., `[Gemini effort=high]`) records the level that worker actually ran at — it may be below the requested one when its engine capped, or `inherited` when a headless run failed and the worker answered in-process. A worker that fails returns `[<Model> FAILED] <reason>` (or fails to run at all) — still report the remaining results normally and state the failure cause for the failed workers.

## Result aggregation

With the workers' results:

1. Merge items pointing at the same file and same issue into one, listing every worker that found it as the source (e.g., `[claude, codex]`).
2. Items found by only one worker list just that worker (e.g., `[codex]`).
3. Sort by severity (high → medium → low) and report as a table: file:line | severity | source | description
4. End with a one-line summary (total findings, high count, number of items found in common by multiple workers, and the effort level the run used — naming any worker that ran below it).

When aggregating, do not copy workers' claims verbatim — check the actual code for suspicious items, exclude clear false positives, and mention having done so.
