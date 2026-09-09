---
name: consensus
description: Reach a decision by gathering independent opinions from external CLI agents (Claude, Gemini) in parallel and debating to consensus; for code writing, aggregate each side's review into the final work product. Use for important technical decisions and non-trivial code writing.
metadata:
  short-description: Decide with independent external agents
---

# Consensus Decision-Making (Codex × External Agents)

For important decisions in terminal-based work, do not decide alone. Gather independent
opinions from external CLI agents and reach consensus before deciding.

## Participants

Every external query runs through `scripts/worker.sh`, which starts the engine as a fresh,
read-only OS process. The runner owns transport only (flags, effort mapping, timeouts,
retries, failure formatting); **this skill composes every prompt** — question, review,
rebuttal — so the engines never learn what kind of round they are in.

| Participant | How it is queried |
|---|---|
| Codex | this session, or `worker.sh codex` for a fresh independent seat |
| Claude | `worker.sh claude` (`claude -p`, plan mode, read-only allow-list) |
| Gemini | `worker.sh gemini` (`agy --mode plan`, no tools) |

Resolve the runner as `scripts/worker.sh` **next to this skill file** — that is the copy the
`consensus-review` skill uses too. A global install puts it at
`${CODEX_DIR:-${CODEX_HOME:-$HOME/.codex}}/skills/consensus/scripts/worker.sh`, but a
project-local `.codex/skills/` copy is discovered the same way, so prefer the path this skill
was actually loaded from over a hardcoded one. Pass the prompt as a **file**, and launch a
round's workers in the background followed by one `wait`. Read `references/workers.md` before the first round of a session, and whenever a
worker fails, an engine is added, or the runner is missing.

**Seats.** In **decision mode** this session holds the Codex seat: write down your own
conclusion and reasoning **before** reading any worker output, then moderate. In **code
mode's review rounds** this session is anchored to the draft it just wrote, so it holds no
reviewer seat at all — spawn a fresh `worker.sh codex` for the Codex seat and act purely as
moderator. Never count this session and a Codex worker as two seats in the same round.

**Independence.** A separate process is only an independent seat if it starts from a fresh
session and sees nothing but the frozen prompt. Give every first-round worker the identical
prompt file, with no peer answers and no host reasoning in it, and collect each result into
its own file that no other worker can read.

**Adding an engine.** Add a `run_<engine>` arm to `scripts/worker.sh`, a row to the table
above, and the engine's name to the launch list in `consensus-review`'s Execution step —
that list is explicit and does not pick up new engines on its own. Steps below that name the Claude and Gemini workers mean **every external
engine in this table** — a newly added one joins automatically, and the workflow is
participant-count agnostic.

**Effort.** Pass `--effort <low|medium|high|xhigh|max>` to every worker in a round, the same
level for all of them, or their answers are not comparable. Raise it where depth pays off —
Critical Track implementations, hard-to-reverse decisions, a rebuttal round that turns on a
subtle fact — and leave it alone for routine rounds. Gemini caps at `high`, so a `max` round
is not `max` there; workers report what they actually used as `[<Model> effort=<level>]`,
and that is what belongs in the report. `references/workers.md` holds the level-picking
rules and the timeout budgets.

**Failure.** A worker returning `[<Model> FAILED] …` is reported to the master and excluded
from the decision, with the majority denominator updated. If one external engine remains,
use the two-party rule (agreement = consensus; on disagreement the master decides). If all
fail, proceed on your sole judgment — **except for hard-to-reverse work**, where you stop
and ask the master to confirm. Never silently hide a failure, and never answer on a failed
engine's behalf.

## Scope (Important Decisions)

- Architecture / design direction choices
- Library, framework, or tool selection
- Cases where two or more implementation approaches diverge
- Hard-to-reverse work (file deletion, migrations, large refactors, deployments, etc.)
- When the master explicitly invokes `$consensus <question>`

Do not apply to trivial decisions (variable names, simple bug fixes, work with one obvious
approach) — invoking every time is slow and costly.

## Workflow — Consensus Loop

Consensus is a loop where one round is **query → aggregate & judge → print round record**;
repeat until a termination condition is met, then exit and derive the result.

```
┌─> Query (round 1: independent opinions / round 2+: rebuttals)
│        ↓
│   Aggregate & judge (compare everyone's latest positions)
│        ↓
│   Print round record (to the master, immediately)
│        ↓
└─ no ── Consensus? ── yes ─> Derive result
   (max 2 rebuttal rounds)
```

### Loop body: running a round

**(1) Query** — query all participants in parallel.

- **Round 1 (independent opinions)**: write one prompt file and run every external worker
  against it in the background, then `wait`. The prompt carries sufficient context,
  constraints and options, and **no** opinion from you or any other agent. Finalize your own
  conclusion and reasoning **before** reading any result (anti-anchoring — launch the
  workers, then write down your position while they run).

  Prompt template (identical for every worker):

  ```
  <question + context + options>. Answer with a concise conclusion and reasoning.
  ```

- **From round 2 on (rebuttals)**: build a new prompt file per participant with the other
  participants' positions, and re-evaluate your own position against them. Every engine is
  stateless between runs, so each rebuttal prompt must rebuild the whole context: the
  original question, that seat's own previous answer, and the peers' answers.
  **Verbatim relay** — do not summarize or reinterpret; quote each participant's
  conclusion/reasoning sentences **verbatim** in a fixed format (only when size limits force
  it, excerpt at sentence granularity without adding interpretation).

  ```
  Rebuttal round. Previous question: <question>. Your answer (verbatim quote): <that agent's conclusion/reasoning>. Other participants' opinions (including Codex, per-participant fixed format 'Conclusion: … / Reasoning: …', verbatim quotes): <quotes per remaining participant>. <If an evidence gate was performed: Verified facts: <method and result>>. Review this and answer whether you maintain or revise your position. If you disagree with any participant, state whose reasoning you reject and why; if you change your position, state which argument was decisive.
  ```

**(2) Aggregate & judge** — compare the **latest positions** of everyone (you + external
agents); participants swapping positions with each other also counts as disagreement. Group
conditional or compromise positions as the same option only when their practical conclusion
is the same; if ambiguous, treat as disagreement.

**Evidence gate**: if a disagreement stems from a **verifiable claim** (facts, API/library
behavior, performance numbers, behavior checkable by tests), resolve it by direct
verification — run the tests, check the official docs, reproduce it — before opening a
rebuttal round, and include the verification result in the next prompt. Rebuttal debate is
reserved for unverifiable judgment differences.

**(3) Print round record** — immediately after judging, print that round's record to the
master (do not defer it to the final report):

```
### Round <N> — <Independent opinions / Rebuttal>
(If a rebuttal round was opened by a new argument) New argument that opened this round: <gist>
(If an evidence gate was performed) Verification: <method and result gist>
- <Participant>: <conclusion / position maintained·changed> — <reasoning gist. For rebuttal rounds: whose reasoning was rebutted (or conceded) and why; if position changed, the decisive argument>
```

The record contains only the gist of each item — do not paste raw worker output wholesale.
Participant lines grow or shrink with actual participants.

**(4) Termination check**

- **Unanimity** → exit the loop, go to result derivation.
- **Disagreement, fewer than 2 rebuttal rounds so far, and a new argument exists** → run the
  next round. A new argument means new evidence, test or experiment results, a previously
  unconsidered constraint, and so on; you judge whether one exists (in explain mode,
  disclose the rationale).
- **Otherwise** (2 rebuttals exhausted, or the same claims repeated without new arguments) →
  exit the loop, go to the termination ruling.

Rebuttal rounds are capped at **2** (round 1's independent opinions do not count). Never
iterate beyond that.

### Termination ruling (loop ended without unanimity)

- **Majority** (e.g., 2:1 among 3) → for ordinary decisions, adopt the majority option
  **only if it has passed the evidence gate** (its key reasoning was verified, or the
  question is inherently an unverifiable judgment call), noting the minority opinion in the
  report. If the majority's key reasoning is verifiable but unverified (verification was
  blocked by environment constraints, say) and the minority presented counter-evidence, do
  not auto-adopt — report to the master, since models share biases and headcount does not
  guarantee correctness. For **hard-to-reverse work**, adopt nothing short of unanimity —
  ask the master to decide.
- **No majority** (full split, tie) → summarize each side's position and reasoning, report
  to the master, and ask for a decision. Do not arbitrarily pick a side.
- Majority is counted over **available, non-excluded participants**.
- A compromise option that first appeared in the final round has not been evaluated by
  everyone, so do not adopt it as consensus; include it in the master report as a strong
  candidate.

### Result derivation (final report)

Round records were already printed during the loop, so do not repeat them. If the loop
terminated without consensus, title it
`## Consensus Result: No consensus — master decision required`.

```
## Consensus Result: <decision>

| | Final opinion | Key reasoning |
|---|---|---|
| Codex  | ... | ... |
| Claude | ... | ... |
| Gemini | ... | ... |

**Consensus process**: Unanimity at round <N> / majority adoption (minority: <participant — gist>) / no consensus (master decision required)
**Excluded agents**: none / <agent — failure reason>
```

Table rows grow or shrink with actual participants.

## Explain Mode

Round records print every round even by default, but when the master invokes
`$consensus --explain <question>` or asks to "explain / show the process", expand beyond the
summary records into a **narrative walkthrough**:

1. **Narrate the flow**: unfold each item of the per-round records into sentences, showing
   how the rebuttals interlocked and positions moved.
2. **Disclose your meta-judgments**: why a new argument was or was not recognized, the
   criteria for grouping differently-worded positions as the same option, why a round ended
   early.
3. **Final judgment**: for unanimity, the decisive reasoning; for majority, the minority
   opinion and why it was not adopted; for no consensus, the remaining points of contention
   — then close with the standard report format.

Explain mode permits longer narration, but still summarizes rather than pasting raw worker
output. The workflow itself (independence, max 2 rebuttals) is unchanged.

## Code-Writing Mode (2-Track)

For non-trivial code writing (new modules or functions, logic with edge cases, refactors,
bug fixes with an unclear root cause), do not finalize the result alone — aggregate the
external agents' input. Do not apply to one-line fixes, typos, or obvious changes.

Pick the track by risk: **correctness-critical code** (algorithms, financial calculations,
parsing, security, concurrency, logic with data-loss risk) or an explicit request from the
master → Critical Track. Everything else → Standard Track.

### Standard Track (default): draft → round-based cross-review → tool verification

Cross-review runs on the same round structure as the decision loop: **independent analysis →
opinion round → rebuttal → re-examination & ruling**.

1. **Write the draft**: actually create or modify the files.

2. **Independent analysis round** (parallel, independent seats): run `worker.sh claude`,
   `worker.sh codex` and `worker.sh gemini` against one shared review prompt file, without
   telling them of each other's existence or opinions.
   - You wrote the draft, so you are anchored to it: you do **not** review, and you hold no
     seat. The Codex seat is the fresh `worker.sh codex` process; you act only as
     **moderator (aggregation & ruling)**.
   - Combine the review perspectives — bugs/edge cases and qualitative quality — **into one
     prompt**; do not add a separate quality-check round trip.

   Review prompt template (identical for every worker):

   ```
   Review the changes in <project dir>, scope: git diff HEAD (staged + unstaged; the new untracked files <list, if any> are embedded below in full). Point out, item by item: (1) bugs/logic errors, (2) missed edge cases, (3) better approaches/simplifications, (4) quality issues in readability/complexity/duplication/naming/error handling. Return findings as '{file}:{line} | {severity(high/medium/low)} | {description}' lines; if there are no issues, answer 'No issues'.
   ```

   Embed the material itself into the prompt file: the Gemini seat cannot read the repo, and
   an identical prompt for every seat is what makes the answers comparable. `git diff HEAD`
   omits untracked files, so append the **contents** of every new file in scope — naming them
   leaves the Gemini seat with nothing to read while the Claude and Codex seats reach them
   through `--cwd`, and the seats are then not reviewing the same material. The same holds for
   non-git or new-file-only work: embed each file's contents, not just its path. Pass `--cwd
   <project dir>` so the Claude and Codex seats can also check surrounding code.

3. **Opinion round (aggregation)**: organize everyone's findings item by item — content,
   source, whether commonly flagged, whether reviewers conflict. Do **not** rule at this
   stage, so your preconceptions do not contaminate the rebuttal round.

4. **Rebuttal round** (once): build one prompt file per reviewer containing the **other
   reviewers' findings quoted verbatim** and ask for (a) whether it agrees with each of the
   others' findings, and on what grounds if not; (b) whether it maintains or withdraws its
   own findings that were rebutted or conflicted. Re-embed the same material — the diff plus
   any untracked-file contents — because every engine is stateless and saw nothing before.

   ```
   Cross-review rebuttal round for the same changes in <project dir>, scope: git diff HEAD. Your previous findings (verbatim): <own findings>. Other reviewers' findings (verbatim quotes): <other findings>. State agree/disagree with each of the others' findings with reasoning, and answer whether you maintain or withdraw your findings if they were rebutted.
   ```

   - **Skip conditions**: skip the rebuttal and go straight to re-examination & ruling if
     there are 0 findings, or all remaining findings are trivial (typo-level), or all were
     identically flagged by every reviewer leaving no room for disagreement. Also skip when
     only one reviewer is available — there is no one to rebut.

5. **Re-examination & ruling**: take each finding's **latest position** (rebuttal results
   reflected) and rule item by item — apply if valid; if rejected, state the reason.
   **Findings jointly maintained by multiple reviewers after rebuttal get priority
   scrutiny.** Findings with disputed facts go through the **evidence gate** — rule by direct
   verification (tests, docs, reproduction) instead of debate. Unverifiable judgment
   differences are ruled by you, with remaining disagreements noted in the report. Rebuttal
   ends after one round — do not open a counter-rebuttal.

6. **Tool verification** (required): run the project's configured tools first — linter
   (ruff/eslint etc.), formatter check, type checker (mypy/pyright/tsc etc.), tests (pytest
   etc.). If the project has no tool configuration, fall back to language defaults (for
   Python, `uvx ruff check`, `python -m py_compile`; for shell, `bash -n`/`shellcheck`). Fix
   failed checks and re-run to confirm; also re-run if aggregation changed the code. Report
   pre-existing unfixable issues separately.

7. **Conditional final review**: only if applying the aggregated feedback amounts to a
   **large modification** (structural change, new logic added, substantial rewrite of the
   diff), have every worker review the final diff once more in parallel. Skip for small
   applications. The final review is a single approval pass with no rebuttal round. If a
   serious defect surfaces here, fix and verify once more; if it persists, stop and report to
   the master.

   ```
   Final review of the aggregated changes in <project dir>, scope: git diff HEAD. Point out only remaining bugs or regression risks. If there are none, answer 'Approved'.
   ```

8. **Report** in the format below.

```
## Code Consensus Result: <work description> (Standard / Critical)

**Consensus process**:
- Independent analysis: <per-reviewer finding counts and gist, whether commonly flagged — e.g., Claude 2, Codex 3, Gemini 2; 1 in common>
- Rebuttal: <gist of position changes> / skipped (<reason: no findings / all unanimous>)
- Re-examination & ruling: applied <M> / rejected <K> — <one line on the key contested point, omit if none>
- Final review: <per-agent approval status and finding handling> / skipped (condition not met: small application)

| Finding (source) | Ruling | Handling |
|---|---|---|
| ... (codex, gemini) | Valid | Applied: ... |
| ... (gemini) | Rejected | Reason: ... |

**Tool verification**: <tools run and results — e.g., ruff passed, mypy passed, pytest 24/24 passed>
**Excluded agents**: none / <agent — failure reason>
```

If every reviewer ruled "no issues" in independent analysis, report "Cross-review passed"
instead of the table, but still include the **Consensus process** summary — write the
rebuttal line as "skipped (no findings)" and omit the re-examination & ruling line, since
there is nothing to aggregate (tool verification still runs).

### Critical Track (default for high-risk code): parallel implementations → compare & synthesize

1. You and the external workers **each independently** write an implementation of the same
   spec (workers return code text only and never see each other's implementations). Run the
   external workers in parallel against one prompt file, and write your own implementation
   before reading theirs. Here the host session does implement — there is no draft yet to be
   anchored on:

   ```
   <spec: purpose, inputs/outputs, edge-case requirements>. Output only implementation code satisfying this spec. Explanations only as code comments.
   ```

2. Compare the implementations and analyze the differences, especially in edge-case
   handling. Where they diverge, **verify by test which side is correct** whenever possible
   (evidence gate — rule by execution results, not debate).
3. Write a final version synthesizing each implementation's strengths, then apply Standard
   Track steps 2–7 to it as-is.
4. Report in the same format as Standard Track, adding **the points of divergence and the
   adoption rationale**.

### Common rules for code mode

- Workers provide only opinions, reviews, or code text; **writing files and running the
  code or tests under review is always this session's job** — every worker path is
  read-only.
- On worker failure, follow the failure rule in Participants (report, proceed with the
  remaining participants, your sole judgment if all fail). A failed independent Codex review
  cannot fall back to this anchored session.
- External round trips are, on the Standard Track, 1 independent analysis + at most 1
  rebuttal, plus the conditional final review for large modifications — at most 3. The
  Critical Track prepends 1 independent-implementation request. Only a serious defect found
  in the final review adds 1 extra verification after the fix. Do not iterate beyond that.

## Cautions

- All external execution is read-only. Never use `--dangerously-skip-permissions`.
- Effort multiplies cost and latency: `xhigh`/`max` on a large diff can run several minutes
  per participant. State the level a round ran at rather than letting the reader assume.
- Do not include sensitive information (API keys, passwords) in prompts.
- Prompts always go through files, never through shell arguments — diffs and rebuttal quotes
  are full of quotes, `$()` and backticks.
- `references/workers.md` holds the per-engine detail: transport limits, effort caps,
  timeout budgets, failure causes, and the direct-CLI fallback when the runner is missing.
