---
name: consensus
description: A workflow where Claude and external CLI agents (Codex, Gemini) form independent opinions in parallel, then reach consensus through rounds of debate for decision-making; for code writing, each side's input is also aggregated into the final work product. Use for important technical decisions and non-trivial code writing.
---

# Consensus Decision-Making (Claude × External Agents)

For important decisions in terminal-based work, Claude does not decide alone. Instead, it gathers independent opinions from external CLI agents and reaches consensus before deciding.

## Participating Agents

| Agent | Non-interactive read-only invocation | Notes |
|---|---|---|
| Codex | `codex exec -s read-only --skip-git-repo-check "<prompt>" 2>&1` | If codebase context is needed, run in the project directory and drop `--skip-git-repo-check` |
| Gemini (agy) | `agy -p "<prompt>" --mode plan 2>&1` | Antigravity CLI (successor to gemini-cli, replaced 2026-06). No stdin pipe support — include review targets in the prompt via command substitution (see below) |

- **Input delivery differs**: Codex supports stdin pipes (`cat <file> \| codex ...`, `git diff \| codex ...`). agy does not read stdin, and in headless mode file-read/command-execution permissions are auto-denied, so include the review content directly in the prompt string via command substitution (`$(git diff HEAD)`, `$(cat <file>)`). Command substitution results are not re-interpreted by the shell, so this is safe, but very large diffs may exceed argument limits — split and pass file by file.
- To add a new agent, register its non-interactive read-only invocation command in this table. The workflow below applies identically regardless of participant count.
- **Failure fallback**: If an agent fails to run (unauthenticated, spend cap, network, timeout, empty/insubstantial output), report that fact to the master and exclude it from the decision. A participant that fails mid-round is also excluded from that point on, and the majority denominator is updated. If only one external agent remains, use the two-party rule (agreement = consensus; on disagreement the master decides). If all fail, proceed with Claude's sole judgment. However, for **hard-to-reverse work**, do not proceed on Claude's sole judgment when all external agents have failed — get the master's confirmation. Never silently hide failures.

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

**(1) Query** — Query all participants in parallel (Bash `run_in_background: true`).

- **Round 1 (independent opinions)**: Send the same question (with sufficient context + constraints + options) to all external agents, but do **not** include Claude's or any other agent's opinion. Claude also finalizes its own conclusion and reasoning **before** reading external answers (anti-anchoring — you can parallelize by kicking off the queries, then writing down your position before reading results).

```bash
# Use the invocation commands from the participating-agents table, e.g.:
codex exec -s read-only --skip-git-repo-check "<question + context + options. Answer with a concise conclusion and reasoning.>" 2>&1
agy -p "Do not run any tools; answer using only the text below. <question + context + options. Answer with a concise conclusion and reasoning.>" --mode plan 2>&1
```

- **From round 2 on (rebuttals)**: Give each external agent the other participants' positions and reasoning and ask it to reconsider; Claude also reviews the other opinions and re-evaluates its own position. The rebuttal-round query format is identical every round. **Verbatim relay**: Claude does not summarize or reinterpret other participants' opinions — quote each participant's conclusion/reasoning sentences **verbatim** in a fixed format (only when argument limits are exceeded, excerpt at sentence granularity without adding interpretation — prevents summary distortion and anchoring):

```bash
<agent invocation> "Previous question: <question>. Your answer (verbatim quote): <that agent's original conclusion/reasoning>. Other participants' opinions (including Claude, per-participant fixed format 'Conclusion: … / Reasoning: …', verbatim quotes): <quotes per remaining participant>. <If an evidence gate was performed: Verified facts: <method and result>>. Review this and answer whether you maintain or revise your position. If you disagree with any participant, state whose reasoning you reject and why; if you change your position, state which argument was decisive."
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

2. **Independent analysis round** (everyone in independent contexts, in parallel): Send the changes to all reviewers in parallel, without telling them of each other's existence or opinions.
   - **Claude's own review is also done in an independent context**: the main context that wrote the draft is anchored to its own code, so it does not review directly — pass only the diff scope to the `claude-reviewer` subagent (Agent tool) to review. The main-context Claude acts only as **moderator (aggregation & ruling)**, not as a reviewer.
   - Run the external agents (Codex, Gemini) in parallel with the invocations below (separate processes = independent contexts). If the `codex-reviewer`/`gemini-reviewer` subagents are available, they may act as proxies (they perform the same read-only invocations).
   - Combine the review perspectives — bugs/edge cases and qualitative quality (readability, complexity, duplication, naming, error handling) — **into one prompt**; do not add a separate quality-check round trip.

```bash
# Git project: pass the diff via stdin (codex) / command substitution (agy) (when piped, codex auto-attaches a <stdin> block. Appending a `-` argument errors)
# git diff HEAD includes both staged and unstaged. Pass new untracked files separately via cat.
cd <project> && git diff HEAD | codex exec -s read-only "Review these changes (see stdin). Point out, item by item: (1) bugs/logic errors, (2) missed edge cases, (3) better approaches/simplifications, (4) quality issues in readability/complexity/duplication/naming/error handling. If there are no issues, answer 'No issues'."
cd <project> && agy -p "Do not run any tools; answer using only the text below. Review the following diff of changes. Point out, item by item: (1) bugs/logic errors, (2) missed edge cases, (3) better approaches/simplifications, (4) quality issues in readability/complexity/duplication/naming/error handling. If there are no issues, answer 'No issues'.

$(git diff HEAD)" --mode plan

# Non-git or new files: pass file contents via stdin (codex) / command substitution (agy) with the same prompt structure
```

3. **Opinion round (aggregation)**: Organize everyone's findings item by item — content, source, whether commonly flagged, whether reviewers conflict. The moderator does **not** rule at this stage (organize only, so the moderator's preconceptions don't contaminate the rebuttal round).

4. **Rebuttal round** (once): Give each reviewer the **other reviewers' findings quoted verbatim (unprocessed)** and request answers — (a) whether it agrees with each of the others' findings, and on what grounds if not; (b) whether it maintains or withdraws its own findings that were rebutted/conflicted.
   - The Claude reviewer is queried **by continuing the same subagent via SendMessage** that performed the independent analysis (preserves review context).
   - External agents are stateless, so re-attach the diff when calling. For quotes containing special characters, write them to a temp file and substitute with `$(cat <file>)`:

   ```bash
   cd <project> && git diff HEAD | codex exec -s read-only "This is the cross-review rebuttal round for these changes (see stdin). Your previous findings (verbatim): $(cat <own-findings-file>). Other reviewers' findings (verbatim quotes): $(cat <other-findings-file>). State agree/disagree with each of the others' findings with reasoning, and answer whether you maintain or withdraw your findings if they were rebutted."
   cd <project> && agy -p "Do not run any tools; answer using only the text below. This is the cross-review rebuttal round for the following diff. Your previous findings (verbatim): $(cat <own-findings-file>). Other reviewers' findings (verbatim quotes): $(cat <other-findings-file>). State agree/disagree with each of the others' findings with reasoning, and answer whether you maintain or withdraw your findings if they were rebutted.

   $(git diff HEAD)" --mode plan
   ```

   - **Skip conditions**: Skip the rebuttal round and go straight to re-examination & ruling if there are 0 findings, or all remaining findings are trivial (typo-level), or all were identically flagged by every reviewer leaving no room for disagreement. Also skip when only one reviewer is available — there is no one to rebut.

5. **Re-examination & ruling**: The moderator takes each finding's **latest position** (with rebuttal results reflected) and rules item by item — apply if valid; if rejected, state the reason. **Findings jointly maintained by multiple reviewers after rebuttal get priority scrutiny.** Findings with disputed facts go through the **evidence gate** — Claude rules by direct verification (tests, docs, reproduction) instead of debate. Unverifiable judgment differences are ruled by the moderator, with remaining disagreements noted in the report. Rebuttal ends after one round — do not open a counter-rebuttal round.

6. **Tool verification** (required): Run the project's configured tools first — linter (ruff/eslint etc.), formatter check, type checker (mypy/pyright/tsc etc.), tests (pytest etc.). If the project has no tool configuration, fall back to language defaults (for Python, `uvx ruff check`, `python -m py_compile`, etc.). Fix failed checks and re-run to confirm passing; also re-run if aggregation changes modified the code. Report pre-existing unfixable issues separately.
7. **Conditional final review**: Only if applying the aggregated feedback amounts to a **large modification** (structural change, new logic added, substantial rewrite of the diff), have everyone review the final diff once more in parallel (pass new untracked files along via cat). Skip for small applications. The final review is a single approval pass with no rebuttal round. If a serious defect surfaces here, fix and verify once more; if it persists, stop and report to the master.

   ```bash
   cd <project> && git diff HEAD | codex exec -s read-only "This is the final set of changes after aggregation (see stdin). Final review: point out only remaining bugs or regression risks. If there are none, answer 'Approved'."
   cd <project> && agy -p "Do not run any tools; answer using only the text below. The following is the final diff of changes after aggregation. Final review: point out only remaining bugs or regression risks. If there are none, answer 'Approved'.

   $(git diff HEAD)" --mode plan
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

1. Claude and the external agents **each independently** write an implementation of the same spec (external agents output code text only via read-only invocations and do not see each other's implementations):

```bash
codex exec -s read-only --skip-git-repo-check "<spec: purpose, inputs/outputs, edge-case requirements>. Output only implementation code satisfying this spec. Explanations only as code comments."
agy -p "Do not run any tools; answer using only the text below. <same spec>. Output only implementation code satisfying this spec. Explanations only as code comments." --mode plan
```

2. Claude compares the implementations and analyzes differences (especially edge-case handling differences). Where they diverge, **verify by test which side is correct** whenever possible (evidence gate — rule by execution results, not debate).
3. Write a final version synthesizing each implementation's strengths, then apply Standard Track steps 2–7 (independent analysis → opinion round → rebuttal → re-examination & ruling → tool verification → conditional final review) to the final version as-is.
4. Report in the same format as Standard Track, adding **the points of divergence and adoption rationale**.

### Common rules for code mode

- External agents provide only opinions/reviews/code text; **file writing and execution of the code/tests under review are always Claude's job** (invocations are always read-only variants).
- On agent execution failure, follow the failure-fallback rule in the participating-agents table (report failure, proceed with remaining participants; Claude alone if all fail).
- External review round trips are, on the Standard Track, 1 independent analysis + at most 1 rebuttal, plus the conditional final review for large modifications — at most 3. The Critical Track prepends 1 independent-implementation request. Only when the final review surfaces a serious defect is there 1 extra verification after the fix. Do not iterate beyond that (no counter-rebuttal rounds).

## Cautions

- Always invoke external agents in read-only variants (codex: `-s read-only`, agy: `--mode plan`) — take opinions only; Claude does the executing.
- Default timeout is 120 seconds per agent; exclude agents that exceed it from that decision (if all exceed, Claude decides alone). Apply timeouts and parallelism via the Bash tool's `timeout` / `run_in_background` parameters.
- Do not include sensitive information (API keys, passwords, etc.) in questions.
- Do not type long content containing quotes, `$()`, or backticks directly into prompt strings — pass via stdin pipe for Codex and command substitution (`$(...)`) for agy (substitution results are not re-interpreted by the shell). Likewise for special-character-laden text such as rebuttal-round verbatim quotes: write to a temp file and substitute with `$(cat <file>)` instead of typing directly.
- **Invoke Gemini via the Antigravity CLI (`agy`)**: the old `gemini` (gemini-cli) is not used — personal-account support was discontinued 2026-06. agy uses Google-account login; on not-logged-in or quota-exceeded, exclude and report per the failure-fallback rule.
- **agy invocation caution**: In headless mode, file-read/command-execution permissions are auto-denied, and if agy attempts tools on its own, **the entire invocation fails with empty output/errors**. Therefore always begin agy prompts with **"Do not run any tools; answer using only the text given below"** and include all needed content in the prompt. If it still fails from a tool attempt (`permission check failed`), retry once; on repeat failure, apply the failure fallback. Never use `--dangerously-skip-permissions`.
