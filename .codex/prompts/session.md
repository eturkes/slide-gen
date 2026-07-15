# slide-gen session workflow

`TASK` = the explicit task supplied with `$session-prompt`, if any.

- Non-empty `TASK` → execute exactly that task; edit `.agent/roadmap.md` only when the task or roadmap requires it.
- Empty `TASK` → run the mode selected from the first milestone not yet `REVIEWED`: `UNPLANNED` → PLANNING; `IN-PROGRESS` with an OPEN unit → WORK-UNIT; `IMPLEMENTED` → MILESTONE-REVIEW.

Load `.agent/roadmap.md` (ledger + active detail), then `.agent/memory.md` (durable facts/decisions). `AGENTS.md` is the canonical instruction source and is already loaded by Codex. Begin with `git status`; read only tracked files/history implicated by the task. Navigate with `rg`; use `moon check`/`mooninfo` for MoonBit semantics.

Every mode advances the roadmap and closes with one scoped commit. After the commit, stop; the owner may invoke Codex's native `/review`. A review follow-up fixes accepted findings in a separate scoped commit. MILESTONE-REVIEW is itself the exhaustive adversarial review.

## PLANNING

Plan only the next milestone; split the wider scope first only when it is still unsplit.

1. Read the prior milestone's commit range, or the named seed commits for the first milestone.
2. Check gates first through the project's real pipeline/tooling. An unmet gate → record the standing block and stop.
3. Research current/tooling-dependent choices as `AGENTS.md` requires. Reconcile all findings with `git status`.
4. Split into cohesive, independently verifiable units; sequence gate-independent preparation first and mark gated units BLOCKED.
5. Set the milestone IN-PROGRESS with units enumerated; commit `roadmap (M<m> plan): …`.

## WORK-UNIT

Take the lowest OPEN unit.

1. Read the last completed unit's commits, or the planning commits for the first unit. Restate this unit + acceptance in one line.
2. Size-check before implementation: include the modules every gate must read. If the concern/read surface cannot land implementation + verification + review cleanly as one cohesive unit, split at a confirmed seam first. Bank only confirmed decisions, facts, and reading pointers; remove session-only WIP; commit `roadmap (M<m>.<u> respec): …`. Implement the first replacement unit in the same session when it remains cohesive; otherwise close at the respec commit.
3. Implement with existing modules/style. Confirm any gate functionally before consuming gated inputs; an unmet gate stops the unit honestly.
4. Run the roadmap's relevant format, check, build, and test gates; touched scripts must exit cleanly.
5. Record only durable new lessons/decisions in `.agent/memory.md`.
6. Mark the unit DONE; once all units are DONE, mark the milestone IMPLEMENTED. Commit `<scope> (M<m>.<u>): …`. A respec-only session leaves replacement units OPEN.

## MILESTONE-REVIEW

Read every milestone commit, planning included. Adversarially review the whole body against scope, `AGENTS.md`, memory, cross-unit consistency, correctness, security, verification, token efficiency, and obsolescence; fix every accepted issue. Better designs may revise the scope source; requirements changes reach the owner first. Mark the milestone REVIEWED and commit `<scope> (M<m> review): …`.

## Commit convention

Use scoped subjects (`<scope>: …`) with trace keys: unit `(M<m>.<u>)`, plan `(M<m> plan)`, review `(M<m> review)`. Review follow-ups retain the trace key and add `Codex-Review: <accepted findings>`. Query milestone history with `git log --grep "(M<m>[. ]"`.
