---
title: 'Story 10.4: measured stock reconciles — fractional balances proven, the oracle never wedged'
type: 'feature'
created: '2026-09-19'
status: 'in-progress'
route: 'dispatch'
review_loop_iteration: 0
baseline_commit: 'd6b3009f1017568e3a27232003b1790178961892' # wms-be main (post 10-3)
context:
  - '_bmad-output/implementation-artifacts/epic-10-context.md'
  - 'docs/design/SYSTEM-DESIGN.md'
  - 'docs/design/IMPLEMENTATION-GUIDE.md'
  - 'docs/design/modules/inventory.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** FR-34 says measured stock reconciles — replay-reconciliation reproduces every fractional balance exactly, and a rounding policy is declared once and applied everywhere. The arithmetic already satisfies this: the fold and compare are exact integer operations on milli-units, guarded by `assertExactQuantity`. But the guarantee is **asserted, not demonstrated**: `test/reconciliation.spec.ts` tampers only in whole base units, so no test proves a milli-level (sub-unit) divergence is detected, rebuilt and alerted; the batch arm has never seen a fractional divergence; and the bounded scan has never run across a mixed-precision warehouse. Around the arithmetic, three already-diagnosed engine defects stand between "reconciles" and a guarantee that means anything continuously (PENDING, inventory): a persistently failing **never-checkpointed** partition wedges the whole worker (`pickPartition` sorts `nulls first` and the failure stamp finds no row); the bounded scan's blind spot is reachable only manually because **nothing schedules a full pass**; and a **batch-arm divergence alerts without its batch identity**, so a (sku,bin,batch) imbalance is indistinguishable from a plain one. Finally, the rounding policy is stated **twice** — the command write-edge (`assertRecordableQuantity`) and a hand-rolled copy in the CSV import (`parseQuantityMilli`).

**Approach:** No arithmetic changes anywhere in the reconcile path. This story (a) proves fractional reproduction with **divergence** scenarios over real HTTP — milli-level tamper on measured and each-counted SKUs, a mixed-precision bounded scan, a fractional batch-arm divergence through `rebuildBatchArmInTx`; (b) carries `batchRef` into the divergence alert and the repeat memory; (c) un-wedges the failure path by inserting an empty checkpoint row (ON CONFLICT DO NOTHING) before the stamp; (d) schedules a periodic full pass with a per-partition incremental counter and an env knob; (e) collapses the duplicated rounding rule into one pure function both entry shapes call. Backend only.

</frozen-after-approval>

## Boundaries & Constraints

**Always:**
- Fold/compare/rebuild stay exact integer arithmetic on milli-units — `assertExactQuantity` guards (`ledger.service.ts:1170-1179`) and the `!==` compares are untouched; **no per-UoM tolerance is introduced at compare time** (precision is a write-edge concern, `assertRecordableQuantity` + `uomPrecision`, per 10-2).
- The rounding policy stays **refusal, never rounding**; this story reduces the number of places the rule is stated from two to one — it does not change the rule.
- The failure path may only write a **last_seq=0, empty checkpoint row** and `updated_at` — `last_seq`, `invalid_attempts` and `last_divergences` remain cycle-written state (the comment at `reconcile.ts:319-324` keeps its meaning).
- Partition discovery stays the one cross-tenant BYPASSRLS read, read-only; checkpoint writes stay inside tenant-scoped transactions; migration 0029 carries **no RLS policy change**.
- Divergence alerts speak base units via `fromMilli` (3 dp) — for a corrupted non-multiple on a 0-dp unit this renders the honest fractional value (e.g. `0.007`); that rendering is declared here and pinned by test, not changed.
- Outbox payloads keep their two contracts: reconciliation alerts carry base units (`fromMilli`), ledger payloads carry milli. `canonicalEventBytes` is untouched — no hashed field changes.

**Never:**
- No quarantine re-keying to (sku,bin,batch) — a batch imbalance still quarantines the whole bin's ATP (fail-safe, documented below); only the alert naming changes.
- No `verifyChain` scheduling (PENDING 10.1 item — pre-migration events report severity-1 **by design**; scheduling it today means permanent noise).
- No application of `uom_conversions.factor` anywhere.
- No surfaces: no read-back route for divergence data beyond what reconciliation already exposes; web/mobile surfaces are 10-5/10-6.
- No batching/keysetting of `foldLedgerInTx` — the full pass reuses `replayInTx` as-is; the cost question is answered by cadence, not by a second fold implementation.

## I/O & Edge-Case Matrix

| # | Input / situation | Expected behavior |
| --- | --- | --- |
| 1 | A kg (3-dp) SKU's `stock_on_hand` tampered **+7 milli** | Detected within one cycle; alert carries exact `projected`/`replayed`; rebuild reproduces the true balance; no second quarantine on repeat-advance |
| 2 | An `each` (0-dp) SKU's balance tampered **+7 milli** | Detected; alert renders `…0.007` — the honest 3-dp rendering of a corrupted non-multiple, never silently normalized |
| 3 | A **batch-arm** balance tampered fractionally | Divergence detected through `reconcileScanInTx`/`replayInTx`'s batch compare; alert and repeat memory carry `batchRef`; quarantine remains (sku,bin)-keyed |
| 4 | A mixed-precision warehouse (each-counted bin + kg bin) with a divergence **outside the checkpoint window** on one scope | Bounded scan verifies its window; the blind-spot divergence is caught by the **scheduled full pass**, not by luck |
| 5 | A partition whose full replay fails **persistently** and has **no checkpoint row** | First failure inserts an empty checkpoint (`last_seq 0`, `ON CONFLICT DO NOTHING`) when the tenant-scoped write can itself succeed; the next tick serves a **different** partition; the failing one re-queues behind the others. For failure classes that kill the tenant-scoped seam itself (RLS role, connection loss) the stamp also fails — logged, retried next rotation; the wedge is bounded by the same outage |
| 6 | A partition's `incremental_count` reaches the full-pass threshold | The next cycle runs `replayInTx` (full) instead of the bounded scan; the full pass resets the counter; every bounded pass (clean or divergent) increments it. The switch **may land mid-incident** (a recovering partition crossing the threshold) — the alert's `fromSeq` can then be 1 and previously-uncompared legacy scopes surface; declared, not prevented |
| 7 | `last_divergences` jsonb holds a malformed entry | `parseLastDivergences` skips the malformed entry typed (logged), does not throw, does not lose the well-formed entries |
| 8 | A CSV import row whose quantity cell is **too fine** for its unit | Same refusal text as the HTTP write edge — one statement of the precision+scale+ceiling rule, two call shapes; the **sign** rule differs by call shape by design (deltas are signed, import cells are not) and is one parameter of the same core |
| 9 | A clean bounded pass on a partition | Checkpoint advances; `incremental_count` increments; nothing else changes |

*Test-driving convention (matching `test/reconciliation.spec.ts`):* every row is driven via the `reconcile`/`reconcileNext` facade seam with the worker's poll envs deleted (worker loop itself env-gated off, per suite convention); tamper via raw SQL; "next tick" means the next `reconcileNext()` call.

## Code Map

**The engine — read, do not change its arithmetic:**
- `src/modules/inventory/ledger.service.ts` — `foldLedgerInTx:1088-1212` (signed-delta fold into `${sku}:${bin}` / `${sku}:${bin}:${batch}` maps, `assertExactQuantity` guards at `:1170-1179`), `replayInTx:1228-1334` (full replay, exact compares), `reconcileScanInTx:1344-1422` (bounded window; blind-spot comment `:1337-1342`), `rebuildProjectionsInTx:1494-1588` + `rebuildBatchArmInTx:1598-1676` (absolute rewrite, fabricated-row delete, epoch bumps), manual-rebuild alert `:834-844` (**drops `batchRef`**). `canonicalEventBytes:189-230` — untouchable.
- `src/modules/inventory/reconcile.ts` — `reconcileNext:311-345` (**the wedge**: failure stamp `:325-342` is an UPDATE that no-ops without a checkpoint row; the comment `:319-324` names the nulls-first bucket as if it were fairness), `pickPartition:357-374` (BYPASSRLS, `order by c.updated_at asc nulls first`, one partition per tick), `detect:381-562` (repeatable read; **full replay only when `lastSeq === 0`**, `:508-515`; clean advance `:520-538`; **third upsert** — the post-discard re-earn `:454-472`), repair `:181-290` (quarantine `:193-226`, **ONE** `reconciliation.divergence` alert `:240-260` mapping `skuId, binId, projected, replayed, fromSeq, toSeq` — **no `batchRef`**; checkpoint upsert `:271-287` writes `lastDivergences`, never `last_seq`), repeat memory `:68-70` + `:175-179` (**repeat classification keys on `skuId:binId` only**; quarantine fires on repeat only), `parseLastDivergences:72` (typed `{skuId,binId}[]`; `lastDivergences` type at `:61` drops batch identity).
- `src/jobs/jobs.module.ts:136-188` — `ReconciliationWorker`, env-gated on `OUTBOX_RECONCILE_POLL_MS` (parse `:37`). The full-pass knob is parsed beside it.
- `src/modules/inventory/inventory.facade.ts:468,477` — `reconcile`/`reconcileNext` seams; `ReconcileReport` shape at `reconcile.ts:32-54`.
- `src/shared/db/schema.ts:899-927` — `reconciliationCheckpoints` (`last_seq`, `invalid_attempts`, `last_divergences` jsonb, unique per (tenant,warehouse), `tenant_updated_at_idx`). RLS in migration 0008 only — **no policy change**.
- `src/shared/primitives/quantity.ts` — `toMilli/fromMilli/QUANTITY_SCALE/QUANTITY_DECIMALS` (`:42-60`, `:128-161`), `assertRecordableQuantity` (the ONE write-edge gate; its doc already says "nine call sites"), `assertExactQuantity:193-201` (fold guard), `precisionRefusalDetail` (shared refusal text — already one place).
- `src/modules/catalog/import.command.ts:688-708` — `parseQuantityMilli`: **the duplicate rule statement** (regex → ceiling → `isAtPrecision` → `toMilli`, hand-rolled because the row-error shape differs from the ProblemException path). Shares `precisionRefusalDetail`; the *rule* is stated twice.

**Tests to extend:**
- `test/reconciliation.spec.ts` — the 2.2 suite; every seeded tamper is a whole base unit (`tamperProjection(binA, 7)` style, `:473-775`); healthy/incremental/tamper/quarantine/checkpoint-discard/verify-before-anchor cases are the patterns to copy.
- `test/fractional-quantity.spec.ts:940-957` — the 10-1 clean-pass-only oracle; this story adds its divergence counterparts.

**Known-defect provenance folded in here (PENDING, inventory):** starvation wedge + no periodic full pass *(epic-2 retro a6)*; reconcile failure-stamp + `parseLastDivergences` malformed-entry verification gaps *(epic-2 retro a7 — reconcile-scoped half only)*. `.env.example` gains `RECONCILE_FULL_PASS_EVERY` and the missing `OUTBOX_RECONCILE_POLL_MS` *(epic-2 retro a5, partial)*.

## Tasks & Acceptance

**Execution:**
- [ ] `drizzle/0029_reconciliation_full_pass.sql` + `drizzle/meta/_journal.json` + **tracked** `0029_snapshot.json` — `reconciliation_checkpoints` gains `incremental_count integer NOT NULL DEFAULT 0`; RLS untouched; `bun run db:generate` emits nothing further
- [ ] `src/modules/inventory/reconcile.ts` — failure path **inserts** an empty checkpoint row (`lastSeq: 0`, `invalidAttempts: 0`, `lastDivergences: null`) with `ON CONFLICT (tenant_id, warehouse_id) DO NOTHING` — never an upsert: an upsert would wipe an existing checkpoint's `last_seq`/`last_divergences` (destroying repeat memory and silently curing a corrupt checkpoint, bypassing the ×2 discard and its `checkpoint_invalid` alert) — then stamps `updated_at`; the wedge comment rewritten to describe the insert
- [ ] `src/modules/inventory/reconcile.ts` + `src/jobs/jobs.module.ts` — `RECONCILE_FULL_PASS_EVERY` (default **20**; semantics: **N bounded passes between full passes**, so 1 alternates) parsed by a helper beside `parseReconcilePollMs` and read in `ReconciliationService`'s constructor (mirroring `pollMs` — never module scope, so e2e suites can set it); `detect()` runs `replayInTx` when `incremental_count ≥ N` (and `lastSeq > 0`); the counter rule is **per pass kind, regardless of which upsert arm the write lands in**: a bounded pass increments, a full pass resets to 0 — so the repair-arm `set` is conditional on the pass kind, the clean-advance arm writes it, and the **third** upsert (post-discard re-earn, `:454-472`) includes `incremental_count: 0` in its conflict set (a freshly re-earned checkpoint starts bounded)
- [ ] `src/modules/inventory/reconcile.ts` (`:248-258`, `:61`, `:72`) + `src/modules/inventory/ledger.service.ts` (`:834-844`) — `batchRef` carried through the divergence alert payload, the manual-rebuild alert, and the `lastDivergences` **payload** (optional key; `parseLastDivergences` reads and re-emits it). **Repeat classification is untouched**: `divergenceScopeKey` stays `skuId:binId` (`:68-70`) — `batchRef` never joins the key, so two batch divergences on one bin still classify as repeats and quarantine as today, and pre-upgrade `last_divergences` rows (no `batchRef`) classify exactly as they did
- [ ] `src/shared/primitives/quantity.ts` — one pure `validate + convert` core (ceiling → precision → scale, **sign as an explicit parameter** — command deltas are signed, import cells are not) with a result-object return; `assertRecordableQuantity` and `import.command.ts:parseQuantityMilli` (`:680-709`) both delegate to it; the **precision-arm refusal text byte-identical** (pinned) — over-ceiling and malformed arms keep their import-specific sentences
- [ ] `test/reconciliation-fractional.spec.ts` — matrix rows 1-4 and 6: milli tamper on a 3-dp SKU and a 0-dp SKU (alert payload contents asserted, including the honest `0.007` rendering), mixed-precision bounded scan, fractional batch-arm divergence (asserting `batchRef` in the alert and the repeat memory), blind-spot divergence caught by the scheduled full pass
- [ ] `test/reconciliation.spec.ts` — the starvation arms: persistently failing no-checkpoint partition does not wedge the worker (next tick serves another partition; empty row exists); `parseLastDivergences` malformed-entry arm; failure-stamp arm
- [ ] `.env.example` — `RECONCILE_FULL_PASS_EVERY` + `OUTBOX_RECONCILE_POLL_MS` documented

**Acceptance Criteria:**
- Given a kg SKU's balance tampered by +7 milli, when reconciliation runs, then the divergence is detected with exact milli values, the alert renders the honest base-unit pair, and the rebuild reproduces the true balance exactly.
- Given an each-counted SKU's balance tampered by +7 milli, when the alert is emitted, then it reads `0.007` — a corrupted non-multiple is never silently normalized to `0`.
- Given a mixed-precision warehouse, when the bounded scan runs, then both the each-counted and measured scopes verify in one window.
- Given a never-checkpointed partition whose cycle fails persistently, when ticks pass, then every other partition still reconciles (no wedge) and the failing partition re-queues behind them.
- Given a divergence on a scope untouched since the checkpoint, when `incremental_count` reaches the full-pass threshold, then the full `replayInTx` detects it, and a clean pass resets the counter.
- Given a batch-arm divergence, when the alert fires, then `batchRef` is present in the alert and the repeat memory — the imbalance is nameable without a jsonb scan.
- Given a CSV row that is too fine for its unit, when the file imports, then the refusal names unit, precision and value with byte-identical text to the HTTP path's precision arm.
- Given `bun run db:migrate && bun run db:generate` on a migrated database, then no new migration is emitted and `0029_snapshot.json` is tracked in git.

## Implementation Notes

- **The counter, not a wall clock, drives the full pass.** `incremental_count` is deterministic, testable and per-partition by construction; a wall clock would couple the pass to tick frequency and make the e2e test flaky. The env knob exists so ops can trade fold cost against blind-spot latency.
- **The empty-checkpoint upsert changes no cycle semantics.** `lastSeq: 0` is detect's "no checkpoint" state exactly (`lastSeq === 0 → full replay`); the row only gives the stamp something to touch and makes the partition participate in the fairness ordering as an ordinary member.
- **`batchRef` in the alert is additive, not a contract break.** Optional key on the existing `reconciliation.divergence` payload; no consumer branches on absence today.
- **The import dedup changes no refusal.** The extracted core is pure; the CSV row-error shape and the HTTP ProblemException shape both wrap it. This is the FR-34 "declared once" clause made literal — the rule may have one statement with two call shapes, not two statements.
- **The accepted steady-state for a deterministically failing partition** is a warn log per rotation and an eternal retry — the upsert fix restores fairness (other partitions are served) but adds no escalation, no failure counter and no alert for the partition itself. Declared here; an escalation alert is deferred until a real deployment shows the need.
- **A full pass that fails** aborts its transaction with no partial state (the counter reset rolls back with it) and the partition re-queues via the stamp; it re-attempts the full compare on its next pick. Mitigating: `reconcileScanInTx` also folds from seq 1 — only the *compare* is windowed — so bounded and full differ little in fold cost.
- **After a divergent full pass** the repair arm leaves `last_seq` unchanged, so the next bounded window spans the entire pre-full range until a clean advance, and `last_divergences` stores the whole-warehouse divergence list (jsonb growth on a legacy-divergent warehouse). Accepted: it is the same list the discard path already produces; a list cap is a separate change.
- **Deferred here, deliberately:** quarantine re-keying to (sku,bin,batch) — real but touches the ATP-gating subquery and every open-quarantine flow; needs its own spec. `verifyChain` scheduling — the pre-migration severity-1 noise makes this a decision first (PENDING 10.1). `uom_conversions.factor` application — no input surface needs it (PENDING catalog).

## Design Notes

**Why no per-UoM rule at compare time, even for measured units.** The compare is exact integer equality on aligned milli-units — every derived table stores the SKU's base-UoM milli-units, so there is no conversion for reconciliation to reproduce and no rounding to tolerate. A per-UoM tolerance at compare time would be the system's **second** rounding policy and would weaken the oracle precisely where the fractional model is riskiest. Precision lives at the write edge (`assertRecordableQuantity`, one rule) and at display (`fromMilli`, 3 dp) — that is the policy "declared once and applied everywhere"; this story's job is to reduce the remaining duplicate statement and pin the display edge, not to add a third place.

**Why the failure path inserts a row instead of learning to stamp nothing.** The existing comment treats "no checkpoint row → nulls-first re-pick" as fairness. It is the opposite: with one partition per tick, a persistently failing never-checkpointed partition is picked **every** tick, the stamp UPDATE matches nothing, and the worker serves nothing else — the bounded-scan escape hatch is unreachable behind it. Upserting the empty row converts the partition into an ordinary queue member (oldest-`updated_at` first) with the same detect semantics it had. The alternative — ordering failures separately — adds a second mechanism for a state the upsert already represents.

**Why the alert gains `batchRef` but the quarantine does not re-key.** The quarantine's job is ATP fail-closure, and (sku,bin) is the granularity at which ATP is granted and gated — a batch-imbalance quarantine over-restricts (the whole bin is held) but never under-protects. Re-keying would change open-quarantine semantics and the `committedOnHand notExists` gate for a naming benefit; the alert naming is the part consumers actually branch on. Deferred with the reason stated.

**Why the full pass reuses `replayInTx` unchanged.** The fold is already headroom-guarded (`assertExactQuantity`) and exact; the bounded scan exists to keep steady-state cost proportional to change, not because the full fold is broken. Scheduling a rare whole-ledger pass per partition is the smallest honest escape from the blind spot; a batched second fold implementation would be a new correctness surface in the one component whose correctness is the point.

## Verification

**Commands:**
- `cd workspace/core/backend/wms-be && bun run test && bun run lint && bun run typecheck && bun run build`
- `bun run db:migrate && bun run db:verify` on a database migrated through 0028, then `bun run db:generate` — expected: **no new migration emitted**; `git status --short` — expected: no untracked files, specifically `drizzle/meta/0029_snapshot.json`
- `git diff -- src/modules/inventory/ledger.service.ts` — expected: only the manual-rebuild alert's `batchRef` addition; `canonicalEventBytes`, `foldLedgerInTx`, `replayInTx`, `reconcileScanInTx`, `rebuildProjectionsInTx` bodies untouched
- `grep -rn "toFixed\|Math.round" src/modules/inventory/reconcile.ts src/modules/inventory/ledger.service.ts` — expected: only the pre-existing `fromMilli` call sites

**Mutation checks** — each must make the suite FAIL:
- Delete the empty-checkpoint insert from the failure path — the starvation arm must fail (partition wedges again).
- Make the full-pass condition always false — the blind-spot arm must fail.
- Drop `batchRef` from the alert mapping — the batch-divergence arm must fail.
- Replace the shared validate+convert core's precision arm with `Math.round` — both the import arm and the command write-edge arm must fail (this proves the rule really is stated once).
- Make the failure-path insert an unconditional upsert — a mutation check asserting an **existing** checkpoint's `last_seq` and `last_divergences` survive a failing cycle must fail (this pins the DO NOTHING arm).

## Review Triage Log

**Design review, 2026-09-19 — two layers over the SPEC (no code exists yet). Claim-verification: every load-bearing
behavioral claim verified; one medium + four low citation drifts. Edge-case: 12 findings, 3 high, 5 medium, 4 low.
All triaged into the spec; no renegotiation of the frozen block was needed — every fix is local.**

| # | Finding | Layer | Verdict | Resolution |
|---|---------|-------|---------|------------|
| 1 | **`batchRef` joining the repeat key would silently re-key repeat classification** — two batch divergences on one bin stop being repeats, the (sku,bin) quarantine stops firing, and pre-upgrade rows classify as first offense | edge | **high — patched** | Spec now states explicitly: `divergenceScopeKey` stays `skuId:binId`; `batchRef` is alert/memory **payload** only |
| 2 | **The failure-path upsert's conflict arm was unspecified** — implemented as `onConflictDoUpdate` (the file's pattern), it would wipe an existing checkpoint: repeat memory destroyed, corrupt checkpoint cured without the ×2 discard + alert | edge | **high — patched** | Task now pins `ON CONFLICT … DO NOTHING`; a mutation check asserts an existing checkpoint's `last_seq`/`last_divergences` survive a failing cycle |
| 3 | **Full pass through the repair arm contradicted the counter text** — "both arms increment" + "full pass resets" cannot both hold when a scheduled full pass finds divergence and exits via the repair arm | edge | **high — patched** | One rule: per **pass kind**, regardless of arm — bounded increments, full resets; repair-arm `set` conditional on pass kind |
| 4 | The post-discard re-earn is a **third** upsert the counter edit must cover (its conflict set omits the counter; only the DEFAULT rescues fresh inserts) | claims | **medium — patched** | Task enumerates all three arms; re-earn's conflict set includes `incremental_count: 0` |
| 5 | Wedge fix holds only where the tenant-scoped stamp itself can succeed (RLS role, connection loss kill the stamp too) | edge | **medium — patched** | Matrix row 5 qualified |
| 6 | Deterministic per-partition failure becomes silent eternal retry — no escalation | edge | **medium — declared** | Accepted steady-state written into Implementation Notes; escalation deferred |
| 7 | "Byte-identical refusal" unachievable for over-ceiling/malformed (import has its own sentences) and the core lacked a **sign arm** (`assertRecordableQuantity` passes negatives through; the import regex is the only negative rule) | edge | **medium — patched** | Pin scoped to the precision arm; sign is one parameter of the shared core |
| 8 | `RECONCILE_FULL_PASS_EVERY = 1` yields alternating, not every-cycle, passes | edge | **medium — patched** | Knob documented as "N bounded passes between full passes" |
| 9 | Knob parsed in `jobs.module.ts` but consumed in the inventory module — module-scope read would be untestable per-suite | edge | **medium — patched** | Parse helper beside `parseReconcilePollMs`, read in `ReconciliationService`'s constructor |
| 10 | Full-pass failure retries on next pick; bounded fold is also whole-ledger (only the compare is windowed) | edge | **low — noted** | Implementation Notes |
| 11 | After a divergent full pass the bounded window spans the pre-full range until a clean advance; jsonb grows | edge | **low — noted** | Implementation Notes |
| 12 | Matrix phrasing implied worker-loop coverage; the suite drives the facade seam with worker env-gated off | edge | **low — patched** | Convention note added under the matrix |
| 13 | Citation drifts: `replayInTx` at `:1228` (not 1179); `canonicalEventBytes` at `:189-230`; `parseQuantityMilli` at `:680-709` | claims | **low — fixed** | Corrected in place |