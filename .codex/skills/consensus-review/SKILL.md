---
name: consensus-review
description: Review a diff with several models at once — Claude, Codex and Gemini each review it independently in parallel — then merge the findings into one report. Use to cross-validate changes before a commit or PR.
metadata:
  short-description: Multi-model cross review of a diff
---

# Consensus Review (multi-model code review)

Run every available engine concurrently against the same review prompt, so each model
reviews the same diff independently, then aggregate and report the results.

## Concurrent hosts and frozen review input

- Keep **one writing host per worktree**. When another host is editing, use a separate
  branch and worktree before drafting or applying fixes. Do not move, stash, or overwrite
  another host's uncommitted work. Read-only reviews may run concurrently.
- Freeze a review round once in the parent: resolve revision names to commit IDs, capture
  the diff and explicitly scoped untracked text files, and embed any surrounding source
  needed by the reviewers. Every seat receives the same material; workers must not resolve
  the scope again. Do not sweep unrelated untracked files or credentials into the prompt.
- For an active working tree, use an **empty temporary context directory** as `--cwd` and
  tell reviewers to use only the embedded material, without reading the original project.
  Alternatively, supply a separate immutable checkout of the reviewed revision. Do not
  point reviewers at a worktree another host is changing. Empty-context review may need
  more surrounding source embedded; gather it before launching the round.
- Before applying findings, compare the reviewed commit IDs and scoped file contents with
  the current target. If they changed, rebuild the input and review the affected changes;
  do not apply stale findings. Worktree isolation is a workflow requirement, not a file
  lock enforced by this skill.
- Copy the runner into the round's unique temporary directory before launching any seats,
  and pass that copy to every worker. Keep it for follow-up rounds. Install/update between
  rounds and restart the session afterwards; per-file atomic replacement is not a whole
  release snapshot. The installer serializes writers but does not lock running hosts.

## Review seats

Engines are driven by the shared runner installed with the `consensus` skill:

```
<consensus skill dir>/scripts/worker.sh <claude|codex|gemini> --prompt-file <path> [--effort <level>] [--cwd <dir>]
```

Resolve `<consensus skill dir>` as the directory the `consensus` skill was loaded from — a
global install puts it at `${CODEX_DIR:-${CODEX_HOME:-$HOME/.codex}}/skills/consensus`, and a
project-local `.codex/skills/consensus` is discovered the same way.

It starts each engine as a fresh, read-only OS process and prints one normalized block:
`[<Model> effort=<level>]` with findings under it, or `[<Model> FAILED] <reason>`. The
review perspectives and return format live in **this skill's prompt**, not in the runner.
`../consensus/references/workers.md` covers per-engine behavior, effort caps, timeout
budgets, failure handling, and the direct-CLI commands to fall back on if the runner is
missing.

**This session holds no reviewer seat.** It builds the prompt, launches the seats, and
aggregates. The Codex seat is a separate `worker.sh codex` process — never count this
session and that worker as two seats, and never let this session's reading of the code
stand in for a seat that failed.

## Review scope

- If arguments are given, treat them as the review scope (a diff range, a path, a PR ref).
- With no arguments, target the current branch against `main` (`git diff main...HEAD`). If
  the repo has no `main`, find and use the default branch.
- Before starting, confirm changes actually exist. `git diff <scope> --stat` alone is not
  enough: a scope whose only changes are **untracked** files reports nothing there, so also
  check `git ls-files --others --exclude-standard <scope>`. Launch no seat only when both are
  empty; if the diff is empty but untracked files exist, review those files' contents.

## Review effort

Decide **one** effort level for the run and pass it to every seat, so review depth is a
deliberate choice instead of whatever default each engine happens to carry.

- **Explicit wins**: if the arguments contain `--effort <level>` (or `--effort=<level>`),
  use it and strip it before interpreting the rest as the scope. Levels:
  `low | medium | high | xhigh | max`.
- **Otherwise judge from the diff** (`git diff <scope> --stat` plus a look at what changed):
  - `high` — security/auth/crypto, concurrency/locking/transactions, money or billing
    calculations, data migration or deletion, or a large diff (roughly >15 files or >500
    changed lines)
  - `low` — docs/comments/formatting only, or generated-file and lockfile churn
  - `medium` — everything else
  - `xhigh` and `max` are **never** chosen automatically; they cost real time and money, so
    they only come from an explicit `--effort`.
- **Caps**: Gemini (agy) supports only `low|medium|high`, so `xhigh`/`max` run there as
  `high`. Read the level each seat actually used off its `[<Model> effort=<level>]` bracket
  rather than assuming the requested level held.
- State the chosen level (and why, in one clause) when announcing the review, so an
  unexpectedly shallow or expensive run is visible before it starts.

## Execution

1. Write **one** prompt file and embed the diff in it, so every seat reviews byte-identical
   material (the Gemini seat cannot read the repo itself):

   ```bash
   PROJECT="$PWD"; SCOPE="main...HEAD"; EFFORT="medium"   # from the scope/effort decided above
   D="$(mktemp -d)"
   mkdir "$D/context"
   {
     cat <<PROMPT
   Review the embedded diff $SCOPE from $PROJECT. Use only the embedded material; do not read the original worktree. Look for problems from these perspectives: (1) bugs/logic errors (2) missed edge cases (3) concurrency/transaction issues (4) performance issues (5) security vulnerabilities. Return each finding as a '{file path}:{line} | {severity(high/medium/low)} | {description}' line. If there are no problems, answer 'No findings'.
   PROMPT
     printf '\n'
     git -C "$PROJECT" diff "$SCOPE"
   } > "$D/prompt.txt"
   ```

   When the scope covers the working tree, append the contents of the untracked files **in
   that scope** as well — the Gemini seat cannot read them off disk, and a scope of only
   untracked files would otherwise carry no material at all:

   ```bash
   PATHS=(path/one path/two)   # the scope's paths — never run this with no pathspec
   git -C "$PROJECT" ls-files --others --exclude-standard -- "${PATHS[@]}" | while IFS= read -r f; do
     [ "$(file -b --mime-encoding "$PROJECT/$f")" = binary ] && continue
     printf '\n--- new file: %s ---\n' "$f"; cat "$PROJECT/$f"
   done >> "$D/prompt.txt"
   ```

   The pathspec is not optional: without it this sweeps every untracked file in the repo —
   build output, local credential files that `.gitignore` does not cover, binaries that would
   corrupt the prompt — into a payload sent to three external services, and can blow past the
   runner's 200 KB Gemini limit. A revision-range scope has no untracked files in it at all;
   skip this step there.

   The prompt text is in the snippet above and is identical for every seat.

2. Launch every seat **in parallel**, each into its own output file, then wait for the round:

   ```bash
   cp "<consensus skill dir>/scripts/worker.sh" "$D/worker.sh"
   W="$D/worker.sh"
   ENGINES=(claude codex gemini)   # every engine in the consensus skill's participants table
   for e in "${ENGINES[@]}"; do
     "$W" "$e" --prompt-file "$D/prompt.txt" --effort "$EFFORT" --cwd "$D/context" > "$D/$e.out" 2>&1 &
   done
   wait
   ```

   Use the array form: an unquoted `$ENGINES` string does not word-split under zsh, and the
   loop would then run once with `claude codex gemini` as a single engine name.

   `ENGINES` is the one place this skill names its seats: when an engine is added to the
   `consensus` skill's participants table and to `worker.sh`, add it here as well.

   `--cwd` points at the empty context; embed required surrounding code before launching.
   Collect results separately and read them only after `wait` — a seat that could see
   another seat's answer is not an independent seat.

3. Read each result. Check the bracket for `FAILED` **first** — `[<Model> FAILED] <reason>`
   is a failed seat, never a source label with findings under it. Otherwise the first token
   in the bracket is the source label and the finding lines follow. An `effort=<level>` token
   records the level that seat actually ran at, which may sit below the requested one. A
   failed seat is reported with its cause; the remaining results are still aggregated
   normally.

## Result aggregation

1. Merge items pointing at the same file and same issue into one, listing every seat that
   found it as the source (e.g., `[claude, codex]`).
2. Items found by only one seat list just that seat (e.g., `[codex]`).
3. Sort by severity (high → medium → low) and report as a table:
   file:line | severity | source | description
4. End with a one-line summary: total findings, high count, how many were found in common by
   multiple seats, and the effort level the run used — naming any seat that ran below it.

When aggregating, do not copy a seat's claims verbatim — check the actual code for
suspicious items, exclude clear false positives, and mention having done so.
