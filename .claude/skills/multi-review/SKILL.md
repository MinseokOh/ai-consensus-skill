---
name: multi-review
description: A workflow that runs multiple model review workers (*-reviewer agents such as claude-reviewer, codex-reviewer) in parallel to perform multi-model code review and aggregate the results. Use when you want to cross-validate a diff before a commit/PR.
---

# Multi Review (multi-model code review)

Run every available review worker agent concurrently to review the same diff independently, then aggregate and report the results.

## Review workers

- Use **all** agents whose names end in `-reviewer` from the available-agents list (e.g., `claude-reviewer`, `codex-reviewer`, and later additions like `gemini-reviewer`).
- Workers are registered as `~/.claude/agents/{model}-reviewer.md`. Adding a new model requires no change to this skill file.
- If no `*-reviewer` agents exist in the environment, spawn two general-purpose agents: one runs a Codex review via `codex exec --sandbox read-only`, the other reviews the diff directly.

## Review scope

- If arguments are given, use that scope: $ARGUMENTS
- If no arguments, target the current branch against `main` (`git diff main...HEAD`). If the repo has no `main`, find and use the default branch.
- Before starting the review, confirm changes actually exist with `git diff <scope> --stat`; if there are none, do not spawn workers — just report that fact.

## Execution

1. Launch all review workers with the Agent tool **in the same message** (parallel execution). Pass the identical review scope to every worker as its prompt.
2. If some workers fail (e.g., expired login, spend cap), still report the remaining results normally and state the failure cause for the failed workers.

## Result aggregation

With the workers' results:

1. Merge items pointing at the same file and same issue into one, listing every worker that found it as the source (e.g., `[claude, codex]`).
2. Items found by only one worker list just that worker (e.g., `[codex]`).
3. Sort by severity (high → medium → low) and report as a table: file:line | severity | source | description
4. End with a one-line summary (total findings, high count, number of items found in common by multiple workers).

When aggregating, do not copy workers' claims verbatim — check the actual code for suspicious items, exclude clear false positives, and mention having done so.
