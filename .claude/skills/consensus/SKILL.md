---
name: consensus
description: A workflow where Claude and external CLI agents (Codex, Gemini) form independent opinions in parallel, then reach consensus through rounds of debate for decision-making; for code writing, each side's input is also aggregated into the final work product. Use for important technical decisions and non-trivial code writing.
---

# Consensus Decision-Making (Claude × External Agents)

For important decisions in terminal-based work, Claude does not decide alone. Instead, it gathers independent opinions from external CLI agents and reaches consensus before deciding.

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

## Participants (Worker Pattern)

All external queries run through **worker subagents** (Agent tool) — thin relays that take an arbitrary prompt, execute it read-only, and return the answer as data. The workers don't know what kind of question they carry; **this skill composes every prompt** (question, review, rebuttal). Running everything as subagents keeps each query visible as a named background task in UIs and centralizes CLI handling in the shared `skills/consensus/scripts/worker.sh` adapter.

| Participant | Worker agent | Underlying engine |
|---|---|---|
| Claude | `claude-worker` | `worker.sh claude` (fresh headless Claude session) |
| Codex | `codex-worker` | `codex exec -s read-only` |
| Gemini | `gemini-worker` | `agy --mode plan` (Antigravity CLI; the worker internalizes agy's no-stdin/no-tools handling) |

- Launch workers for the same round **in a single message** (parallel execution). From round 2 on, continue the **same worker** via SendMessage — the worker subagent keeps its conversation context (the stateless external CLI behind it is re-invoked internally, so remind the worker to re-attach any referenced diff/material).
- In **decision mode**, the main-context Claude is itself the Claude participant (it locks in its position before reading worker results). In **code mode's review rounds**, the main context is anchored to its own draft, so `claude-worker` takes the Claude seat instead (in Critical Track's implementation step, where no draft exists yet to anchor on, the main context writes Claude's implementation itself).
- Steps below that name `codex-worker` and `gemini-worker` mean **every external worker registered in this table** — a newly added worker joins all of them automatically.
- To add a new agent, add an engine to the shared runner and a `{model}-worker` agent file (a thin relay to that engine, same return contract) and register it in this table. The workflow applies identically regardless of participant count.
- **Effort**: every worker also accepts a worker-directed `Effort: <low|medium|high|xhigh|max>` line alongside the prompt and maps it to its own engine (`claude -p --effort`, `codex exec -c model_reasoning_effort=`, `agy --effort`); with no directive each engine keeps its own default. Raise it where depth pays off — Critical Track implementations, hard-to-reverse decisions, a rebuttal round that turns on a subtle fact — and leave it alone for routine rounds. Use the same level for every participant in a round, or their answers are not comparable. agy caps at `high`, so `xhigh`/`max` run there as `high`; workers report what they actually used as `[<Model> effort=<level>]`, which is what belongs in the report. The `consensus-review` skill's "Review effort" section holds the level-picking rules.
- **Failure fallback**: A worker that fails to run or returns `[<Agent> FAILED] …` is reported to the master and excluded from the decision. A participant that fails mid-round is excluded from that point on, and the majority denominator is updated. If only one external agent remains, use the two-party rule (agreement = consensus; on disagreement the master decides). If all fail, proceed with Claude's sole judgment. However, for **hard-to-reverse work**, do not proceed on Claude's sole judgment when all external agents have failed — get the master's confirmation. Never silently hide failures.
- **No-worker fallback**: invoke the same payload's `skills/consensus/scripts/worker.sh`
  directly, once per engine in parallel, using one frozen prompt file and context directory.
  Do not bypass the runner with raw CLI commands: its delegated-reviewer guard prevents
  child Codex sessions from starting another consensus round. If the runner is missing,
  report the missing dependency and reinstall the payload before retrying.

## Scope (Important Decisions)

- Architecture / design direction choices
- Library, framework, or tool selection
- Cases where two or more implementation approaches diverge
- Hard-to-reverse work (file deletion, migrations, large refactors, deployments, etc.)
- When the master explicitly invokes `/consensus <question>`

Do not apply to trivial decisions (variable names, simple bug fixes, work with one obvious approach) — invoking every time is slow and costly.

## Workflow — Consensus Loop

Consensus is a loop where one round consists of **query → aggregate & judge → print round record**; repeat until a termination condition is met, then exit the loop and derive the result.

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

**(1) Query** — Query all participants in parallel.

- **Round 1 (independent opinions)**: Launch `codex-worker` and `gemini-worker` in a single message, each with the same prompt — sufficient context + constraints + options, but **no** opinion from Claude or any other agent. Claude finalizes its own conclusion and reasoning **before** reading the worker results (anti-anchoring — kick off the workers, then write down your position before reading).

  Prompt template (identical for every worker):

  ```
  <question + context + options>. Answer with a concise conclusion and reasoning.
  ```

- **From round 2 on (rebuttals)**: SendMessage to each external worker with the other participants' positions, and Claude also re-evaluates its own position against them. **Verbatim relay**: do not summarize or reinterpret — quote each participant's conclusion/reasoning sentences **verbatim** in a fixed format (only when size limits force it, excerpt at sentence granularity without adding interpretation — prevents summary distortion and anchoring). Remind the worker that its CLI is stateless and must re-include the previous question.

  ```
  Rebuttal round. Previous question: <question>. Your answer (verbatim quote): <that agent's conclusion/reasoning>. Other participants' opinions (including Claude, per-participant fixed format 'Conclusion: … / Reasoning: …', verbatim quotes): <quotes per remaining participant>. <If an evidence gate was performed: Verified facts: <method and result>>. Review this and answer whether you maintain or revise your position. If you disagree with any participant, state whose reasoning you reject and why; if you change your position, state which argument was decisive.
  ```

**(2) Aggregate & judge** — Compare the **latest positions** of everyone (Claude + external agents) (participants swapping positions with each other also counts as disagreement). Group conditional/compromise positions as the same option only when their practical conclusion is the same; if ambiguous, treat as disagreement.

**Evidence gate**: If a disagreement stems from a **verifiable claim** (facts, API/library behavior, performance numbers, behavior checkable by tests), Claude resolves it by direct verification (running tests, checking official docs, reproduction experiments) before going to a rebuttal round, and includes the verification result as evidence in the next query. Rebuttal debate is reserved for unverifiable judgment differences.

**(3) Print round record** — Immediately after judging, print that round's record to the master (do not defer it to the final report):

```
### Round <N> — <Independent opinions / Rebuttal>
(If a rebuttal round was opened by a new argument) New argument that opened this round: <gist>
(If an evidence gate was performed) Verification: <method and result gist>
- <Participant>: <conclusion / position maintained·changed> — <reasoning gist. For rebuttal rounds: whose reasoning was rebutted (or conceded) and why; if position changed, the decisive argument>
```

The record contains only the gist of each item — do not paste agents' raw output wholesale. Participant lines grow or shrink with actual participants.

**(4) Termination check** — Branch on one of the following:

- **Unanimity** → exit the loop, go to result derivation.
- **Disagreement, fewer than 2 rebuttal rounds so far, and a new argument exists** → repeat with the next round. A new argument means new evidence, test/experiment results, a previously unconsidered constraint, etc.; Claude judges whether one exists (in explain mode, disclose the judgment rationale).
- **Otherwise** (2 rebuttals exhausted, or the same claims repeated without new arguments) → exit the loop, go to the termination ruling below.

Rebuttal rounds are capped at **2** (round 1's independent opinions do not count). Never iterate beyond that.

### Termination ruling (loop ended without unanimity)

- **Majority** (e.g., 2:1 among 3) → For ordinary decisions, adopt the majority option **only if it has passed the evidence gate** (its key reasoning was verified, or the question is inherently an unverifiable judgment call), noting the minority opinion in the report. If the majority's key reasoning is verifiable but unverified (verification couldn't be performed due to environment constraints, etc.) and the minority presented counter-evidence, do not auto-adopt — report to the master (models may share biases; headcount does not guarantee correctness). For **hard-to-reverse work**, adopt nothing short of unanimity — ask the master to decide.
- **No majority** (full split, tie) → Summarize each side's position and reasoning, report to the master, and ask for a decision. Do not arbitrarily pick a side.
- Majority is counted over **available, non-excluded participants**.
- A compromise option that first appeared in the final round has not been evaluated by everyone, so do not adopt it as consensus; include it in the master report as a strong candidate.

### Result derivation (final report)

Round records were already printed during the loop, so do not repeat them in the final report. If terminated without consensus, title it `## Consensus Result: No consensus — master decision required`.

```
## Consensus Result: <decision>

| | Final opinion | Key reasoning |
|---|---|---|
| Claude | ... | ... |
| Codex  | ... | ... |
| Gemini | ... | ... |

**Consensus process**: Unanimity at round <N> / majority adoption (minority: <participant — gist>) / no consensus (master decision required)
**Excluded agents**: none / <agent — failure reason>
```

Table rows grow or shrink with actual participants.

## Explain Mode (detailed walkthrough of the consensus process)

Round records are printed every round even by default, but when the master invokes `/consensus --explain <question>` or asks to "explain / show the process", expand beyond the summary records into a **narrative walkthrough**:

1. **Narrate the flow**: Unfold each item of the per-round records into sentences, showing how the rebuttals interlocked and positions moved as a flow.
2. **Disclose Claude's meta-judgments**: Reveal the rationale for judgments Claude made along the way — why a new argument was or wasn't recognized, the criteria for grouping differently-worded positions as the same option, why a round was terminated early, etc.
3. **Final judgment**: For unanimity, state the decisive reasoning; for majority, the minority opinion and why it wasn't adopted; for no consensus, the remaining key points of contention — then close with the standard report format from result derivation.

Explain mode permits longer narration, but the principle of summarizing key points rather than pasting raw agent output wholesale still holds. The workflow itself (independence, max 2 rebuttals, etc.) is the same as the default mode. Code-writing mode always includes a **Consensus process** summary in its default report (see the code-writing-mode report format); in explain mode, expand it into a step-by-step narrative down to per-finding rulings.

## Code-Writing Mode (aggregating each side's input, 2-Track)

For non-trivial code writing (new modules/functions, logic with edge cases, refactors, bug fixes with unclear root cause), Claude does not finalize the result alone — it aggregates external agents' input. Do not apply to one-line fixes, typos, or obvious changes.

Pick the track by risk: **correctness-critical code** (algorithms, financial calculations, parsing, security, concurrency, logic with data-loss risk) or when the master explicitly requests it → Critical Track. Everything else → Standard Track.

### Standard Track (default): draft → round-based cross-review → tool verification

Cross-review runs on the same round structure as the decision consensus loop: **independent analysis → opinion round → rebuttal → re-examination & ruling**.

1. **Claude writes the draft**: actually create/modify the files.

2. **Independent analysis round** (everyone in independent contexts, in parallel): Launch `claude-worker`, `codex-worker`, and `gemini-worker` **in a single message**, each with the same review prompt, without telling them of each other's existence or opinions.
   - `claude-worker` takes the Claude seat: the main context that wrote the draft is anchored to its own code, so it does not review directly — it acts only as **moderator (aggregation & ruling)**.
   - Combine the review perspectives — bugs/edge cases and qualitative quality — **into one prompt**; do not add a separate quality-check round trip.

   Review prompt template (identical for every worker):

   ```
   Review the changes in <project dir>, scope: git diff HEAD (staged + unstaged; also read the new untracked files: <list, if any>). Point out, item by item: (1) bugs/logic errors, (2) missed edge cases, (3) better approaches/simplifications, (4) quality issues in readability/complexity/duplication/naming/error handling. Return findings as '{file}:{line} | {severity(high/medium/low)} | {description}' lines; if there are no issues, answer 'No issues'.
   ```

   Freeze and embed the diff, scoped untracked text files and required surrounding source
   once in the parent. Pass the identical prompt file, frozen runner and empty context
   directory to every worker. Non-git or new-file-only work also needs embedded contents.
   Instruct reviewers to use only this material, without reading the original worktree.

3. **Opinion round (aggregation)**: Organize everyone's findings item by item — content, source, whether commonly flagged, whether reviewers conflict. The moderator does **not** rule at this stage (organize only, so the moderator's preconceptions don't contaminate the rebuttal round).

4. **Rebuttal round** (once): SendMessage to each worker with the **other reviewers' findings quoted verbatim (unprocessed)** and request answers — (a) whether it agrees with each of the others' findings, and on what grounds if not; (b) whether it maintains or withdraws its own findings that were rebutted/conflicted. Alongside the template, tell external workers (an instruction to the worker, not part of the relayed prompt) to re-attach the diff for their engine — their CLIs are stateless.

   ```
   Cross-review rebuttal round for the same changes in <project dir>, scope: git diff HEAD. Your previous findings (verbatim): <own findings>. Other reviewers' findings (verbatim quotes): <other findings>. State agree/disagree with each of the others' findings with reasoning, and answer whether you maintain or withdraw your findings if they were rebutted.
   ```

   - **Skip conditions**: Skip the rebuttal round and go straight to re-examination & ruling if there are 0 findings, or all remaining findings are trivial (typo-level), or all were identically flagged by every reviewer leaving no room for disagreement. Also skip when only one reviewer is available — there is no one to rebut.

5. **Re-examination & ruling**: The moderator takes each finding's **latest position** (with rebuttal results reflected) and rules item by item — apply if valid; if rejected, state the reason. **Findings jointly maintained by multiple reviewers after rebuttal get priority scrutiny.** Findings with disputed facts go through the **evidence gate** — Claude rules by direct verification (tests, docs, reproduction) instead of debate. Unverifiable judgment differences are ruled by the moderator, with remaining disagreements noted in the report. Rebuttal ends after one round — do not open a counter-rebuttal round.

6. **Tool verification** (required): Run the project's configured tools first — linter (ruff/eslint etc.), formatter check, type checker (mypy/pyright/tsc etc.), tests (pytest etc.). If the project has no tool configuration, fall back to language defaults (for Python, `uvx ruff check`, `python -m py_compile`, etc.). Fix failed checks and re-run to confirm passing; also re-run if aggregation changes modified the code. Report pre-existing unfixable issues separately.

7. **Conditional final review**: Only if applying the aggregated feedback amounts to a **large modification** (structural change, new logic added, substantial rewrite of the diff), have every worker review the final diff once more in parallel. Skip for small applications. The final review is a single approval pass with no rebuttal round. If a serious defect surfaces here, fix and verify once more; if it persists, stop and report to the master.

   ```
   Final review of the aggregated changes in <project dir>, scope: git diff HEAD. Point out only remaining bugs or regression risks. If there are none, answer 'Approved'.
   ```

8. **Report**: Report to the master in the format below.

```
## Code Consensus Result: <work description> (Standard / Critical)

**Consensus process**:
- Independent analysis: <per-reviewer finding counts and gist, whether commonly flagged — e.g., Claude 2, Codex 3, Gemini 2; 1 in common>
- Rebuttal: <gist of position changes — e.g., Codex rebutted 1 Gemini finding, Gemini withdrew> / skipped (<reason: no findings / all unanimous>)
- Re-examination & ruling: applied <M> / rejected <K> — <one line on the key contested point, omit if none>
- Final review: <per-agent approval status and finding handling> / skipped (condition not met: small application)

| Finding (source) | Ruling | Handling |
|---|---|---|
| ... (codex, gemini) | Valid | Applied: ... |
| ... (gemini) | Rejected | Reason: ... |

**Tool verification**: <tools run and results — e.g., ruff passed, mypy passed, pytest 24/24 passed>
**Excluded agents**: none / <agent — failure reason>

If everyone ruled "no issues" in independent analysis, report "Cross-review passed" instead of the table, but still include the **Consensus process** summary — write the rebuttal line as "skipped (no findings)" and deliberately omit the re-examination & ruling line since there is nothing to aggregate (tool verification still runs).
```

The **Consensus process** summary is always included in the default report. For detailed per-round rebuttal narration, follow explain mode.

### Critical Track (default for high-risk code): parallel implementations → compare & synthesize

1. Claude and the external workers **each independently** write an implementation of the same spec (workers return code text only and do not see each other's implementations). Launch `codex-worker` and `gemini-worker` in a single message with the same prompt; Claude writes its own implementation before reading theirs:

   ```
   <spec: purpose, inputs/outputs, edge-case requirements>. Output only implementation code satisfying this spec. Explanations only as code comments.
   ```

2. Claude compares the implementations and analyzes differences (especially edge-case handling differences). Where they diverge, **verify by test which side is correct** whenever possible (evidence gate — rule by execution results, not debate).
3. Write a final version synthesizing each implementation's strengths, then apply Standard Track steps 2–7 (independent analysis → opinion round → rebuttal → re-examination & ruling → tool verification → conditional final review) to the final version as-is.
4. Report in the same format as Standard Track, adding **the points of divergence and adoption rationale**.

### Common rules for code mode

- Workers provide only opinions/reviews/code text; **file writing and execution of the code/tests under review are always the main context's job** (all worker execution paths are read-only).
- On worker failure, follow the failure-fallback rule in the participants table (report failure, proceed with remaining participants; Claude alone if all fail).
- External review round trips are, on the Standard Track, 1 independent analysis + at most 1 rebuttal, plus the conditional final review for large modifications — at most 3. The Critical Track prepends 1 independent-implementation request. Only when the final review surfaces a serious defect is there 1 extra verification after the fix. Do not iterate beyond that (no counter-rebuttal rounds).

## Cautions

- All external execution is read-only (codex: `-s read-only`, agy: `--mode plan`, headless Claude: `--permission-mode plan` with a read-only allow-list) — workers relay opinions only; the main context does the executing.
- Effort multiplies cost and latency: `xhigh`/`max` on a large diff can run several minutes per participant, and a round labeled `max` is not `max` for Gemini (agy stops at `high`). Say which level a round ran at rather than letting the reader assume.
- Use a 600-second timeout per external CLI call for every model and effort level. Retries share that budget. A worker that exceeds it is excluded and reported according to the failure rules.
- Do not include sensitive information (API keys, passwords, etc.) in prompts.
- The no-worker fallback uses the same runner and prompt-file transport. Do not reconstruct raw CLI invocations; effort mapping, safe prompt transport and bounded retries belong to the adapter.
- **Gemini is invoked via the Antigravity CLI (`agy`)**: the old `gemini` (gemini-cli) is not used — personal-account support was discontinued 2026-06. agy uses Google-account login; on not-logged-in or quota-exceeded, exclude and report per the failure-fallback rule.
