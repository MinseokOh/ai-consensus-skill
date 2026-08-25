---
name: consensus-review
description: A workflow that runs multiple model workers (*-worker agents such as claude-worker, codex-worker, gemini-worker) in parallel to perform multi-model code review and aggregate the results. Use when you want to cross-validate a diff before a commit/PR.
---

# Consensus Review (multi-model code review)

Run every available worker agent concurrently with the same review prompt, so each model reviews the same diff independently, then aggregate and report the results.

## Review workers

- Use **all** agents whose names end in `-worker` from the available-agents list **and whose description matches the worker relay contract** (a generic read-only prompt relay, e.g., `claude-worker`, `codex-worker`, `gemini-worker`, and later additions). Skip unrelated agents that merely happen to end in `-worker`.
- Workers are generic prompt relays registered as `~/.claude/agents/{model}-worker.md` — the review perspectives and return format live in **this skill's prompt**, not in the workers. Adding a new model requires no change to this skill file.
- **No-worker fallback**: if no worker agents are installed, spawn general-purpose agents (one per engine, in parallel) and give each the same step-1 review prompt plus its engine's read-only invocation: direct review for the Claude seat, `codex exec -s read-only "<prompt>"` for Codex, and `agy -p "Do not run any tools; answer using only the text below. <prompt + diff embedded via command substitution>" --mode plan` for Gemini. Have them use the same return format, prefixed `[<Model>]` (or `[<Model> FAILED] <reason>`).

## Review scope

- If arguments are given, use that scope: $ARGUMENTS
- If no arguments, target the current branch against `main` (`git diff main...HEAD`). If the repo has no `main`, find and use the default branch.
- Before starting the review, confirm changes actually exist with `git diff <scope> --stat`; if there are none, do not spawn workers — just report that fact.

## Execution

1. Launch all workers with the Agent tool **in the same message** (parallel execution), each with the identical review prompt:

   ```
   Review the diff <scope> in <project dir>. Look for problems from these perspectives: (1) bugs/logic errors (2) missed edge cases (3) concurrency/transaction issues (4) performance issues (5) security vulnerabilities. Return each finding as a '{file path}:{line} | {severity(high/medium/low)} | {description}' line. If there are no problems, answer 'No findings'.
   ```

   Each worker resolves the scope its own way (claude-worker reads the diff and surrounding code directly; codex-worker lets Codex read the repo; gemini-worker embeds the diff into its prompt).
2. Workers return their answer prefixed with a `[<Model>]` source line; treat that prefix as the source label, with the finding lines following it. A worker that fails returns `[<Model> FAILED] <reason>` (or fails to run at all) — still report the remaining results normally and state the failure cause for the failed workers.

## Result aggregation

With the workers' results:

1. Merge items pointing at the same file and same issue into one, listing every worker that found it as the source (e.g., `[claude, codex]`).
2. Items found by only one worker list just that worker (e.g., `[codex]`).
3. Sort by severity (high → medium → low) and report as a table: file:line | severity | source | description
4. End with a one-line summary (total findings, high count, number of items found in common by multiple workers).

When aggregating, do not copy workers' claims verbatim — check the actual code for suspicious items, exclude clear false positives, and mention having done so.
