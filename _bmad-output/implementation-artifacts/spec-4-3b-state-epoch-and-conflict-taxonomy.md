---
title: 'Story 4.3b: state_epoch and the AD-14 conflict taxonomy'
type: 'feature'
created: '2026-09-14'
status: 'done'
route: 'dispatch'
review_loop_iteration: 0
baseline_commit: '2523f42' # wms-be main
context:
  - '_bmad-output/implementation-artifacts/epic-4-context.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** Every offline conflict looks the same. A replayed pick whose bin moved underneath it fails `422 insufficient-on-hand`, and the client deletes the op — so a pick the operator physically performed vanishes from every record, and a bin that is merely *short* is indistinguishable from one that is unresolvable.

**Approach:** Give each bin a `state_epoch` that the device captures at task start and carries on the op. At replay the server compares it and, on mismatch, **classifies** the conflict by AD-14's taxonomy instead of rejecting blindly — so a short bin becomes a re-plannable outcome story 4.4 consumes, and only genuinely unresolvable conflicts quarantine.

**Decided (2026-09-14, human):**
- **An inventory-owned `bin_state_epochs` table mints the epoch** — `(tenant, warehouse, bin_id, epoch)`, bumped inside the ledger fold where every bin mutation already funnels. Precise (a mismatch means *that* bin changed), cheap to read for the snapshot, and it keeps the table inside the module that owns stock. A column on `bins` would be simpler to read but would have the inventory ledger writing a tenancy-owned table, which the AD-6 architecture guard forbids.
- **Ship the epoch, the comparison and the four outcomes as distinct machine codes.** Cases 1 and 2 remain `201` as today; case 3 gets a re-plannable code that 4.4 consumes; case 4 is terminal. This also settles the deferred question of which replay outcomes are retryable — today a stale pick is silently deleted from the outbox.

**Decided (technical, from investigation):**
- **The epoch is excluded from the idempotency payload hash.** `hashCommandPayload` covers every command field; including the epoch would make a replay carrying a stale epoch fail `422 idempotency-key-reuse` *before* the taxonomy ever ran — defeating the entire story.
- **The taxonomy's binding names are the spine's** — apply / settle / re-plan / quarantine (`ARCHITECTURE-SPINE.md:124`). `epics.md:505` calls them settled / re-authorized / rejected / quarantined; UX-DR24 makes the spine win on conflict.
- **Replay stays strictly FIFO.** AD-4's "replays in task order" is unresolved against the client's sequence-ordered outbox; the epoch check settles it, because each op is now validated against live bin state independently of what preceded it. Task order was only ever a proxy for that.
- Pick tasks are stitched into the snapshot in the API shell on a **different transaction** from its `bins` array. Epochs ride the pick-task read so a task and its epoch always come from one consistent read.

## Boundaries & Constraints

**Always:**
- The epoch bumps inside the ledger fold (`addToOnHand` / `addToBatchOnHand`), in the same transaction and under the same per-warehouse advisory lock as the movement itself. A bin's contents and its epoch can never disagree.
- The epoch is **opaque and monotonic per bin** — never interpreted, compared only for equality. It is not a quantity, a timestamp, or a global sequence.
- An op arriving with **no epoch** (a device that has not refreshed since upgrading) is treated as a match and proceeds as today — never rejected for the absence of a field its cache predates.
- The comparison happens **after the bin row is locked `FOR UPDATE` and before anything is written**, so a classification cannot race the state it classified.
- **Cases 1 and 2 are successes** — they answer `201` exactly as today. Only a mismatch that cannot be satisfied changes the outcome.
- **Case 3 (`pick-bin-short`) is re-plannable, not terminal**: the client keeps the op and surfaces it for re-planning rather than deleting it — but **bounded**. After `MAX_REPLAN_ATTEMPTS` refusals the op quarantines with session attribution and leaves the queue, so a permanently short bin cannot produce a permanently queued op or a queue chip that never clears. **Case 4 (`pick-unresolvable`) is terminal** and quarantines immediately.
- Quarantine stays client-side with the sync summary (the 4.3 decision); Epic 5's story 5.5 adds the web review queue.
- Every classification outcome is deterministic and testable from a forced state — no sleeps, no timing windows.

**Never:**
- No short-pick re-planning, alternate-bin suggestion, or re-planned task cards (4.4) — case 3 emits its outcome and stops.
- No backend rejected-op table, no Conflicts & Reviews surface (Epic 5).
- No change to the reservation state machine, ATP, or the ledger grammar.
- No epoch on any flow but picking — putaway and receiving keep today's behaviour until a story needs otherwise.
- No web surface (`4-2b`).

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Epoch matches | bin untouched since task start | `201` — the pick proceeds exactly as today | N/A |
| Case 1 — apply | epoch moved, the draw still stands, and this pick does NOT settle the order line's hold (other slices remain) | `201`, drawn normally; `conflictClass: 'applied'` on the pick row | N/A |
| Case 2 — settle | epoch moved, the draw still stands, and this pick settles the order line's hold (`held → committed`, the hold being `held` and unexpired) | `201`, drawn and settled; `conflictClass: 'settled'` | N/A |
| Case 3 — re-plan | epoch moved, bin no longer covers the draw | `409 pick-bin-short` naming the bin and its live on-hand; **nothing written** | client KEEPS the op, surfaces it as needing re-plan |
| Case 4 — unresolvable | hold no longer `held`, or line/wave/order moved terminally | `409 pick-unresolvable` naming what moved; nothing written | client quarantines with session attribution |
| No epoch on the op | pre-upgrade device cache | treated as a match; today's behaviour | N/A |
| Epoch for an unknown bin | bin id with no epoch row | treated as a match (a bin never touched has no epoch) | N/A |
| Replay after a successful pick | same key, same payload | the stored snapshot re-serves | unchanged by this story |
| Concurrent movement mid-classification | adjustment commits between snapshot and replay | classification reads the locked row, so it sees one settled state | never a half-classified write |

</frozen-after-approval>

## Code Map

- `workspace/core/backend/wms-be/src/modules/inventory/ledger.service.ts` — `appendMovement` (`:438`) is the single chokepoint; the per-warehouse advisory lock is taken at `:461`; the folds that must bump the epoch are `addToOnHand` (`:621`, upsert `:646-668`) and `addToBatchOnHand` (`:681`, upsert `:708-730`). The second write path, `rebuildProjectionsInTx` (`:1372`, callers `:764` and `reconcile.ts:230`), rewrites projections absolutely — it must bump the epochs of every scope it touches, or a repaired bin would look unchanged to a device holding a pre-repair epoch.
- `workspace/core/backend/wms-be/src/modules/outbound/pick.command.ts:193` — `recordPick`. The insertion point is between the bin row `FOR UPDATE` (`:390-407`) and the FEFO derivation (`:448`) / sufficiency check (`:456-459`). The existing producers of `insufficient-on-hand` are `:1053` (whole-bin, thrown `:458`; FEFO shortfall, thrown `:774`) and the fold backstops in `ledger.service.ts:266,276`. The payload hash is built at `:194-208` — **the epoch must not enter it**. The comment at `:168-172` already reserves this slot.
- `workspace/core/backend/wms-be/src/modules/inventory/reservation.service.ts` — validity for case 2 is `state === 'held'` **and** `expires_at > now`; `expireDue` (`:716`) is a job, so a hold can be past expiry and still read `held` — the two checks are not the same test. Read seam: `reservationsByIdsInTx` (`:1188`), whose snapshot carries `expiresAt` (`:106`).
- `workspace/core/backend/wms-be/src/modules/outbound/pick.command.ts:835` — `getPickTasksInTx`, projection at `:892-915`, `PickTask` shape at `:106-124`. The epoch joins here so a task and its epoch come from one read. Bound is `MAX_SNAPSHOT_PICK_TASKS = 500` (`:143`) via `truncateToWholePicklists` (`:940`).
- `workspace/core/backend/wms-be/src/api/receiving.controller.ts:157-158` — pick tasks are stitched onto the snapshot **outside** the snapshot's transaction (`receiving.facade.ts:320-391`). Do not add the epoch to the `bins` array (`receiving.facade.ts:84-93`); it would come from a different read than the task it describes.
- `workspace/core/backend/wms-be/src/modules/outbound/outbound.dto.ts:554-603` — `RecordPickDto`, the seven fields a device sends; the epoch is the eighth, optional.
- `workspace/core/backend/wms-be/src/shared/db/schema.ts` — `stock_on_hand` (`:575`), `batch_on_hand` (`:620`), `reservations` (`:865-897`, scope is (tenant, warehouse, sku), never bin-level). Highest migration is `0020`.
- `workspace/core/backend/wms-be/test/picking.spec.ts:622` — the stale-replay test and its **deterministic driver**: `drainStock` (`:359-373`) posts a real `stock.adjusted` adjustment against the bin, so any epoch derived from the fold changes by construction. `bodyFor` (`:452`) stamps `occurredAt` once so the payload hash is stable across replays. Direct state forcing for the reservation arm is at `:1064` (`update reservations set state = 'expired'`).
- `workspace/core/mobile/wms-mobile/src/offline/engine.ts:39-55` — the `rejected` branch that currently deletes the op from the durable outbox. Case 3 must keep it; case 4 quarantines. `src/picking/draft.ts` `confirmPayload` and `src/api.ts` `PickRecordPayload` carry the new field.
- `workspace/core/mobile/wms-mobile/app/inbox.tsx:140-162` — the sync summary, where a re-plannable outcome must read differently from a quarantine.

## Tasks & Acceptance

**Execution:**
- [x] `wms-be drizzle/0021_lean_george_stacy.sql` — `bin_state_epochs` (unique on tenant+warehouse+bin) + RLS, the `epoch > 0` CHECK, and `picks.conflict_class` + its CHECK
- [x] `wms-be src/shared/db/schema.ts` — the table per conventions
- [x] `wms-be src/modules/inventory/ledger.service.ts` — bump in both folds and in `rebuildProjectionsInTx`
- [x] `wms-be src/modules/inventory/inventory.facade.ts` — an in-tx epoch read seam for the outbound module (`binStateEpochInTx` / `binStateEpochsInTx`)
- [x] `wms-be src/modules/outbound/pick.command.ts` — classification between the bin lock and the draw; epoch on the task projection; epoch excluded from the payload hash
- [x] `wms-be src/modules/outbound/outbound.dto.ts` + `src/api/outbound.controller.ts` — the optional epoch field and the two new codes in OpenAPI
- [x] `wms-be test/picking.spec.ts` — all four cases driven deterministically, plus the no-epoch and unknown-bin arms; `test/reconciliation.spec.ts` covers the repair-path bump; `test/architecture.spec.ts` pins the new table to the inventory module
- [x] `wms-mobile src/picking/draft.ts`, `src/api.ts` — capture and carry the epoch
- [x] `wms-mobile src/offline/engine.ts` — case 3 keeps the op, case 4 quarantines; sync summary distinguishes them
- [x] `wms-mobile src/offline/engine.test.ts`, `src/picking/draft.test.ts` — the retained-op and quarantine arms
- [x] `wms-be bun run openapi:export` + `wms-fe bun run api:generate`

**Acceptance Criteria:**
- Given a bin drained after a task started, when its queued pick replays, then it is refused as re-plannable, nothing is written, and the client still holds the op
- Given a bin whose epoch moved but which still covers the draw, when the pick replays, then it succeeds
- Given a hold that expired before replay, when the pick replays, then it is refused as unresolvable and quarantines with the session that created it
- Given a device that has not refreshed since upgrading, when its pick replays without an epoch, then it behaves exactly as before this story

## Implementation Notes

**The epoch.** `bin_state_epochs` is `(tenant, warehouse, bin_id, epoch)` with `epoch bigint > 0`, unique on the scope, RLS as the sibling projections. It is minted by `bumpBinEpochInTx` in `ledger.service.ts` — the same file the stock projections are written from, so `test/architecture.spec.ts` now pins it there too (it is listed in `STOCK_TABLES` and in the single-quantity-path assertion). Both folds bump it, so a batch movement bumps its bin's epoch twice in one transaction; that is harmless (the value is opaque and compared only for equality) and keeps each fold's invariant local rather than dependent on call order. `rebuildProjectionsInTx` bumps the epoch of every bin it actually rewrote — and of none it did not, which the reconciliation suite asserts in both directions. Value starts at 1, never 0: a 0 on the wire would be indistinguishable from "no epoch".

**Where the classification runs.** In `recordPick`, between the bin's `for('update')` and the FEFO derivation — after the lock, before any write. The two shortfall producers (the FEFO shortfall inside `deriveBatchArms`, and the whole-bin sufficiency check) were unified behind one `binCannotCover(epochMoved, …)` router, so `deriveBatchArms` now REPORTS a shortfall (`{ drawable }`) instead of throwing one; the caller owns the 409-vs-422 choice. With a moved epoch a shortfall is `409 pick-bin-short`; without one it is the unchanged `422 insufficient-on-hand`, which is exactly the pre-upgrade behaviour AC 4 asks for.

**apply vs settle — what the server can actually prove.** The matrix distinguishes case 1 by "this SKU's on-hand in the bin unchanged". That is not derivable: the device sends no observed quantity, and the epoch is opaque and per-BIN by decision, so nothing stored says which SKU inside the bin moved. Rather than invent a client field or reinterpret the epoch as a sequence, the spine's two names were bound to the distinction the server can prove and that matches the matrix's *outcome* column exactly — `applied` is "drawn normally" (the epoch moved, the draw stood on its own) and `settled` is "drawn and settled" (the epoch moved and this pick flipped the hold `held → committed`). It is recorded on `picks.conflict_class` (`none` | `applied` | `settled`, CHECK-constrained) and returned on the pick snapshot. If a later story wants the literal "this SKU was untouched" test, the honest way is a per-(bin, sku) epoch, not a reinterpretation of this one.

**Case 4's reach.** The spec's case 4 is "hold no longer `held`, or line/wave/order moved terminally". The hold arm is new and lives at the classification point: `state === 'held'` AND `expires_at > now`, which are deliberately two tests — `expireDue` is a job, so a hold can be past TTL and still read `held`, and settling one would commit units nobody holds. The line/wave/picklist/order arms were already deterministic 409s upstream; they now answer `pick-unresolvable` **when the premise is terminal** (cancelled, or a line already picked — including the two concurrency backstops) and keep the plain retryable `conflict` when it is not (a wave still `planned`, a picklist not yet `ready`). Quarantining a not-yet-released wave would be wrong: releasing it later makes the queued op replayable.

**Client behaviour.** `SendResult` gained `re-plannable` and `quarantined` arms beside `rejected`; `SyncSummary` gained `rePlannable`. `pick-bin-short` keeps the op in the durable outbox (it is re-sent on the next sync and survives a restart — the engine test asserts both) and reports it; `pick-unresolvable` drops it and reports it as held-for-review with the creating session's attribution, stranding only itself (unlike a revocation, which still strands the tail).

**The re-plan bound (`MAX_REPLAN_ATTEMPTS = 3`, `REPLAN_ATTEMPT_COOLDOWN_MS = 5 min`).** Three, because the two failure shapes it has to separate sit either side of that number: a bin short because another wave got there first is usually replenished within a sync or two, and three attempts ride that out with no operator action; a bin short because the stock is simply gone never clears, and retrying forever means a doomed request every sync and a queue chip that never reaches zero — which reads as a broken device rather than as work waiting. On the third refusal the op quarantines with the creating session's attribution and leaves the queue, so giving up is still never a silent drop.

Attempts count only when separated by `REPLAN_ATTEMPT_COOLDOWN_MS`: `replay()` is a button that also fires after every confirm, so three taps in ten seconds would otherwise spend the whole allowance on a bin a replenishment two minutes later would have cleared. The bound is therefore a duration — at least ten minutes of a bin staying short — not a tap count. The counter and its cooldown stamp ride the op (`QueuedOp.replanAttempts` / `replanAttemptAt`, both optional — absent reads as zero so an op sealed by an earlier build replays and gets its full allowance) and had to be made genuinely durable: the SQLite store persisted neither it nor the `session` that `QueuedOp` already declared, so both are now real columns (`replan_attempts`, and `session_sealed` — sealed, since it holds an operator email) written through one shared `rowValuesFor` helper so `appendOp` and `replaceOps` cannot drift apart again. Pre-existing databases are migrated by two guarded `ALTER TABLE ... ADD COLUMN` statements; the column's absence is the version signal. Persisting `session` also fixes a quiet pre-existing bug: attribution fell back to the *replaying* operator after every restart, which is precisely the case a bounded re-plan reaches.

The summary distinguishes the two states — a retrying op reads "Attempt 1 of 3 — it stays queued", an exhausted one reads "Refused 3 times without clearing" under the held-for-review heading. When the exhausted op leaves the outbox its pick line stops being "consumed" and the stop returns to the device's walk, which is the same behaviour every `rejected` op has always had: the line really is unrecorded, and a fresh scan against a refreshed snapshot may well succeed. Every other refusal behaves exactly as before. `ApiProblem` now also carries the problem `detail`, so the summary can name the bin and what it now holds instead of only the title. The device captures the epoch of the bin it ACTUALLY scanned: on-plan from the task, off-plan from the walk stop at that bin (the only other draw `evaluateBin` permits) — and `null` when the walk names no stop there, because a guessed epoch would misclassify a healthy pick.

**Excluded from the payload hash.** `hashCommandPayload` does not see `binStateEpoch`; the e2e suite asserts that a replay with a *different* epoch re-serves the stored snapshot while a replay with a different `qty` still fails `422 idempotency-key-reuse`.

**Review fixes (2026-09-14).** The classification originally read the epoch under the `bins` row lock alone, which mutexes other picks and nothing else — adjustments, putaway, receiving and the reconciliation rebuild all bump a bin's epoch under the per-warehouse advisory lock without touching that row, so one committing mid-classification showed an unmoved epoch against a drained bin and produced the `422` a device deletes instead of the `409` it keeps. The classification now takes the warehouse lock first (`InventoryFacade.lockWarehouseInTx`), and the serial set is pre-locked just above it to keep putaway's documented acyclic bins-row → serial → warehouse order.

The hold's two premises were also collapsed. `state === 'held'` is a premise of every pick and stays at the classification point; `expires_at` is a premise only of the pick that SETTLES, so judging it earlier refused the first slice of a multi-bin order line that previously drew fine. It moved into the settlement branch and is compared in SQL against `now()` — `expires_at` is written and reaped Postgres-side, and node-clock skew would either refuse a live hold or settle a dead one. `unfulfillable` joined `cancelled` as a terminal line status (it never returns to `planned`, so the plain `conflict` had the device delete a real pick), and the migration now seeds `epoch = 1` for every bin already in `stock_on_hand` — without it every existing bin read null, `epochMoved` was permanently false, and the taxonomy was inert on deploy until each bin's next movement.

**A knowing deviation from AC 4.** Four terminal-premise codes (cancelled wave / picklist / line, already-picked line, cancelled order) changed from `conflict` to `pick-unresolvable` for every caller, including a device that sends no epoch. Gating them on the epoch's presence was considered and rejected: terminality is a fact about the wave, the line and the order and has nothing to do with what a device observed of a bin, so gating would hand two devices different answers to the same question and would misroute a 4.3b device that legitimately carries no epoch (an off-walk bin, or one no movement has touched) into deleting an op it should hold. A pre-4.3b client's observable behaviour is unchanged regardless — it has no branch for the new code, so it falls through to the same `rejected` default `conflict` reached. What the AC protects (an epoch-less replay is never refused for the field's absence, and its shortfall stays `422`) is preserved exactly.

**A self-inflicted epoch bump counts as movement, deliberately.** Two queued stops on the same bin mean the first pick's own draw moves the epoch the second quotes. That is not a false positive — the bin really did change and the sealed snapshot no longer describes it — and if the second stop is now short, `pick-bin-short` keeps an op the undifferentiated `422` would have deleted. Subtracting the transaction's own bumps would need the epoch to carry provenance, which is the interpretation AD-14 forbids.

**One thing found and left alone.** The shared `ProblemDetailsFilter` renders the wire `title` from the exception message, which `ProblemException` sets to the DETAIL — so `pickUnresolvable`'s new title parameter names the cause in-process (logs, the switch a reader has to follow) but does not yet reach the wire as a separate low-cardinality field. Fixing that filter changes every problem response in the repo and is not this story's; the four causes stay distinguishable on the wire through `detail`.

**Not done (out of scope, per the spec's Never list).** No short-pick re-planning or alternate-bin suggestion (4.4) — case 3 emits its outcome and stops, and until 4.4 consumes it a re-plannable op is re-sent at most `MAX_REPLAN_ATTEMPTS` times before quarantining. No backend rejected-op table and no Conflicts & Reviews surface (Epic 5 / 5.5). No epoch on putaway or receiving. No web surface.

## Spec Change Log

- **2026-09-14 (frozen matrix amended, human-authorized):** matrix cases 1 and 2 originally distinguished `apply` from `settle` by "this SKU's on-hand in the bin unchanged". **That test is not derivable** from the design this spec chose: the epoch is per-BIN and opaque (AD-14's own wording), and the device sends no observed quantity, so the server cannot know whether *this SKU's* share of the bin moved. The spec asked for something it had already made impossible — an error in the spec, not the implementation. The rows now distinguish the two arms by what the server can prove: whether this pick settled the order line's hold. The outcome column is unchanged, and the alternatives (a per-(bin, sku) epoch, or trusting a client-reported quantity) were rejected as contradicting AD-14 and widening the trusted input surface respectively.
- **2026-09-14 (bounded case 3, human-authorized):** the Always block said a re-plannable op is kept and surfaced, with no bound. As written that means a permanently short bin produces a permanently queued op, a doomed request every sync, and a queue-depth chip that never clears — which reads as broken to an operator. Case 3 is now bounded by `MAX_REPLAN_ATTEMPTS`, after which the op quarantines with attribution. The operator's physical pick is still never silently lost, which is the property the case exists to protect.

## Review Triage Log

_Three layers (blind hunter, edge cases, verification gaps) — 2026-09-14. Verification-gap findings arrive pre-verified; every other claim was re-checked against the source before grading._

| # | Finding | Verdict | Evidence | Route |
|---|---------|---------|----------|-------|
| 1 | The epoch read is not serialized against the writers that bump it — the comment claiming otherwise is false | high | Confirmed: `warehouseAdvisoryLock` appears NOWHERE in `pick.command.ts`. The only lock at the read (`:527`) is `for('update')` on the **bins row** (`:479`), which mutexes other picks and nothing else; adjustments, putaway, receiving and the repair path bump under the per-warehouse **advisory** lock without touching that row. An adjustment committing between `:527` and the on-hand read (`:588`) yields `epochMoved === false` against a drained bin → `422`, which the device DROPS instead of the `409` it keeps. All three layers found it independently | patch |
| 2 | `unfulfillable` lines fall through to plain `conflict`, which the device drops | high | `picklist_lines.status` includes `unfulfillable` (`0019:64`); the new gate enumerates `picked` and `cancelled` and routes the rest to `conflict` → `rejected` → deleted. An `unfulfillable` slice never returns to `planned`, so this is the silent loss the story exists to prevent, via the one status the branch forgot | patch |
| 3 | The expired-hold gate runs on every pick, not only one that would settle | high | Confirmed at `:546-565`: the `line.reservationId !== null` block is unconditional. The first slice of a multi-bin order line whose hold is past TTL is now refused where it previously drew successfully — a regression with nothing to do with the epoch | patch |
| 4 | AC violated: an epoch-less replay does NOT behave exactly as before | high | Cancelled wave/picklist/line/order and already-picked lines now answer `pick-unresolvable` where they answered `conflict`; the new TTL gate refuses holds `commitInTx` previously committed. Pre-upgrade devices see both changes | patch |
| 5 | The client's code→outcome mapping — the only place `pick-bin-short` means "keep the op" — has no test | high | Pre-verified: deleting the branch drops the op and the mobile suite still passes 110/110, because `engine.test.ts` supplies its own senders and never runs the `ApiProblem` translation. The repo already solved this shape once — `op-dispatch.ts` was extracted precisely so the mapping could be pinned without the Expo runtime | patch |
| 6 | "Survives a restart" is proven only against the in-memory store | high | Pre-verified: both restart tests build an `InMemoryOutboxStore` and re-append `structuredClone`d objects, so they cannot observe whether SQLite persists the counter or the session. This is the exact bug class the implementation just fixed — `session` was carried on `QueuedOp` since 4.3 and written by neither `appendOp` nor `replaceOps`, undetected | patch |
| 7 | `bin_state_epochs` RLS and both new CHECKs are unprobed | high | Pre-verified: dropping the policy from `0021` leaves the whole backend suite green. Every sibling story probes its new tables through `wms_rls_probe`; `architecture.spec.ts`'s entries are source-text regexes that never run SQL | patch |
| 8 | The batch-tracked shortfall arm of the `deriveBatchArms` refactor is never executed | high | Pre-verified: both batch-tracked tests assert `201`; every refusal test uses an untracked SKU and reaches `binCannotCover` at the later on-hand pre-check. Routing the batch shortfall to `422` unconditionally — dropping the op — fails no test | patch |
| 9 | No backfill: the taxonomy is inert on deploy for all existing inventory | high | `bin_state_epochs` starts empty, so every bin already holding stock reads `liveBinEpoch === null` and `epochMoved` is permanently false until that bin's next movement. Ships a feature that does nothing for the existing warehouse and converges silently over an unstated period | patch |
| 10 | A pick's own draw bumps the bin epoch, so a second queued stop on the same bin sees a self-inflicted mismatch | medium | Confirmed by construction: the fold bumps on every movement including this pick's. Two stops on one bin means the second is classified `applied`/`settled` and its refusals route to 409 for a conflict nothing external caused | patch |
| 11 | The re-plan bound is attempt-based, but replay is a button with no cooldown | medium | `MAX_REPLAN_ATTEMPTS = 3` is justified as "three refusals across a shift's syncs", but `replay()` is called from an `onPress` and after every confirm. Three taps in ten seconds quarantines a pick a replenishment minutes later would have cleared | patch |
| 12 | `Date.parse(hold.expiresAt) <= Date.now()` compares the app node's clock to a Postgres-owned TTL | medium | Confirmed at `:560`. The reaper expires holds by the database clock; skew either refuses a live hold or settles a dead one | patch |
| 13 | Decrypting the session widens the corrupt-row blast radius | medium | The session open shares the payload decrypt's `try`, whose `catch` drops the row. A torn attribution blob now discards a queued pick whose payload is intact — previously it always replayed | patch |
| 14 | The `ADD COLUMN` loop swallows every error, not just duplicate-column | medium | A genuinely failed migration (lock, disk, syntax) is indistinguishable from the steady state, and the subsequent SELECT then throws on the missing column — the outbox becomes unreadable | patch |
| 15 | An idempotency key written before 4.3b replays without `conflictClass` | medium | The stored snapshot predates the field, but `PickDto` declares it required — the replay answers a shape the contract says is impossible | patch |
| 16 | `conflictClass` is emitted, stored and never read by any consumer | medium | Declared optional in `src/api.ts` while the server always sends it; nothing in `src/` or `app/` reads it. Cases 1 and 2 are invisible on the device — a pick whose bin moved under the operator looks identical to a clean one | patch |
| 17 | Three of four `pick-unresolvable` arms and the deleted `commitInTx` backstop are untested | medium | Only order-cancelled, already-picked and expired-hold are covered; wave-cancelled, picklist-cancelled and line-cancelled are new ternaries that could be inverted unnoticed. The 4.3 test that reached `commitInTx`'s terminal-hold 409 was replaced rather than kept | patch |
| 18 | `applied` vs `settled` encodes slice position, fully derivable from `reservation_committed` | low | Confirmed: `epochMoved && reservationCommitted ? 'settled' : 'applied'`. A single-slice line is always `settled`. The column carries no information its row does not already have — but the human amended the matrix to exactly this binding, so it is the agreed semantics, not a defect | rejected |
| 19 | The re-plannable inbox row is not amber and shares a glyph with the queue-depth row | low | `theme.warning` exists and is unused here; both rows open with `↻`, and a re-plannable op is also counted in `remainingCount`, so it appears twice | patch |
| 20 | Comment and doc drift: a `draft` picklist status that does not exist, a stale "(the 422's figure)", an unreachable order-status branch | low | Confirmed by inspection | patch |
| 21 | `capturedBinEpoch` and `evaluateBin` call `walkOf` with different arguments | low | `evaluateBin` passes `consumed`, `capturedBinEpoch` does not. Masked today because a consumed stop is rejected before confirm, but the shared invariant is asserted in prose rather than in code | patch |
| 22 | `CatalogPickTask.binStateEpoch` is typed required while every consumer treats it as absent-able | low | Forces a cast in the test to launder a legacy fixture, hiding the legacy case from the compiler | patch |
| 23 | `InventoryFacade.binStateEpochsInTx` is a zero-logic passthrough shadowing its own import | low | Harmless but makes the file harder to read; the singular sibling does flatten a map | patch |
| 24 | `bin_state_epochs` missing from `cleanupRows`'s table lists | low | Real inconsistency with the file's convention, but harmless: each suite clones a template database and drops it in `afterAll` | rejected |
| 25 | Four distinct 409 titles collapsed into one "Pick cannot be resolved" | low | Log and metric aggregation on problem title loses the four causes; the cause survives only in prose detail | patch |
| 26 | The task read and the epoch read are two statements in one READ COMMITTED transaction, not one snapshot | low | Real but immaterial: an epoch newer than its task rows is safe in the conservative direction — it can only over-report movement, never under-report it | rejected |


## Design Notes

**Why the epoch is excluded from the payload hash.** The hash exists to detect a client reusing one idempotency key for two different intents. The epoch is not intent — it is an observation of the world the client made at task start. Two replays of the same physical pick carry the same intent and may legitimately carry different epochs. Including it would turn every stale replay into `422 idempotency-key-reuse`, which is precisely the undifferentiated rejection this story exists to replace.

**Why the repair path must bump too.** `rebuildProjectionsInTx` rewrites a scope's quantities absolutely, without appending events. A bin repaired by reconciliation has genuinely changed, and a device holding a pre-repair epoch must be told so. Bumping only in the fold would make the one path that exists *because* state diverged the one path that cannot report divergence.

**Why case 3 keeps the op and case 4 does not.** A short bin is a fact about the world that a re-plan can act on — 4.4 turns it into an alternate bin or a partial order, and the operator's physical pick is still real. An unresolvable conflict means the task's own premises are gone (its hold, its line, its wave), and no amount of retrying recovers it; it needs a human. Deleting both, which is today's behaviour, loses the first kind entirely.

## Verification

**Commands:**
- `cd workspace/core/backend/wms-be && bun run test && bun run lint && bun run typecheck && bun run build && bun run db:migrate && bun run db:verify`
- `cd workspace/core/mobile/wms-mobile && bun run test && bun run typecheck`
- `cd workspace/core/frontend/wms-fe && bun run test && bun run lint && bun run typecheck && bun run build`
