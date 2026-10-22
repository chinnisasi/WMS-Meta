---
title: '3-3a batch block and unpromisable stock — block/unblock a batch with a reason; ATP and the grant ceiling exclude blocked and expired batches'
type: 'feature'
created: '2026-10-22'
status: 'ready-for-dev'
route: 'dispatch'
review_loop_iteration: 0
context:
  - 'docs/initiatives/production-readiness.md'
  - 'docs/design/SYSTEM-DESIGN.md'
  - 'docs/design/IMPLEMENTATION-GUIDE.md'
  - 'docs/design/modules/inventory.md'
  - 'docs/design/modules/catalog.md'
  - 'docs/design/PENDING.md'
  - 'docs/design/frontend/SYSTEM-DESIGN.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** `batches.status` allows `blocked` (0010), and the draw side already honours it: waves, replan and pick skip blocked and expired batches (`replan.ts:92-99`, `pick.command.ts:1517-1555`). But nothing can **set** it (PENDING:425), and the promise side ignores both. `committedOnHand` (`reservation.service.ts:~1519-1547`) counts blocked- and expired-batch stock, so order create, channel publish and replenishment promise units that can never be picked. The wave then comes back short. A recall, or a batch that fails QC (2-8a A11), has no lever.

**Approach:**
- A batch **block / unblock** verb, with a reason, who and when, audit and outbox.
- One new term in the `committedOnHand` seam subtracts on-hand of blocked or expired batches in non-system bins, so `atp()` and `committedCeiling` (and through them order create, channel publish, replenishment and pick regrant) all stop promising it.
- The adjustment FEFO default draw also skips blocked batches.
- BE + web. One additive migration, so the code waits for the migration chain.

**Decisions (recommended, taken autonomously):**
1. **Split.** 3-3a covers batches. **3-3b** covers blocked locations: a reason or kind on `bins.blocked` (who/when; `damaged` as a reason), stock in blocked storage bins excluded from ATP, and the count/adjust/release-into-blocked policy. It is recorded in deferred-work, with a different owner (putaway), migration and backfill.
2. **Capability.** Reuse `qc.manage` (owner, ops_manager). Blocking a lot is a quality decision, the same people as QC holds, and it adds no capability churn while 3-2b is open.
3. **Routes:** `POST …/inventory/batches/:batchId/block` with `{ reason, note? }`, and `POST …/inventory/batches/:batchId/unblock` with `{ note? }`.
   - Both carry the idempotency key.
   - The command lives in **catalog**, which owns `batches`. The routes sit beside the existing batch reads in `inventory.controller.ts:812-882`.
4. **Reasons:** `recall`, `qc-failed`, `contamination`, `client-instruction`, `expiry-review`, `other`. `other` requires the note; the note is ≤ 500 characters.
5. **Data (migration, next free number at code time).** `batches` gains `blocked_reason`, `blocked_at` and `blocked_by`.
   - A pairing CHECK: `status='blocked'` ⇔ all three are non-null, with the reason in the vocabulary.
   - No existing row is blocked (there was no setter), so no backfill is needed; a probe proves it.
   - Unblocking clears all three.
   - `serials.status` is out of scope.
6. **Guard order:**
   1. `qc.manage`
   2. key
   3. DTO vocabulary
   4. replay
   5. batch `FOR UPDATE` in tenant (404)
   6. replay again under the lock
   7. state check: 409 `batch-already-blocked` / `batch-not-blocked`
   8. update
   9. outbox `batch.blocked` / `batch.unblocked`, carrying skuId, batchId and reason
   10. audit

   The fingerprint covers tenantId, batchId, the verb, the reason and the normalised note.
7. **The unpromisable term.** In the `committedOnHand` seam: Σ on-hand in **non-system** bins of batches where `status = 'blocked'` OR the batch is not drawable by expiry at `now`.
   - The expiry test uses the **same** predicate the draw side uses (extract one shared `isBatchExpiredAt(expiry, at)` from `replan.ts` `drawableBatch`), so promise and draw agree.
   - Each (bin, batch) is counted once.
   - System bins are skipped because they are already subtracted (QC-HOLD, DAMAGED, RETURNS, IN-TRANSIT).
   - Catalog's `batches` is read (status and expiry only) with an architecture-spec allowance, following the "locate only" precedent of tenancy's `bins` in `damagedUnits`.
8. **Existing promises.** Blocking does not cancel or re-plan reservations already granted: ATP clamps at 0 (`max(0, …)`), and those lines short at the wave as they would today. Re-planning and backordering on block is recorded in PENDING.
9. **Adjustment draw.** The FEFO default draw (`inventory.controller.ts:580-595`, or 3-2b's composer if that merges first) also skips `status='blocked'`. An explicit batch on a negative adjustment still works, so blocked stock can be written off.
10. **Web.**
    - The batch list and detail get **Block / Unblock** actions, gated on `qc.manage`. Block opens a dialog with the reason select and a note.
    - Status shows "Blocked — recall (by X, date)", and expired batches show "Expired".
    - The inventory screen's ATP reflects the term with no other change.
    - The client is regenerated.
11. **Mobile.** Unchanged: pick already refuses a blocked batch server-side, and the snapshot carries no batch status. Recorded.
12. **Docs.** Correct PENDING:36 and catalog.md:95, which are stale, to read "blocked and expired batches stay on hand but are unpromisable".

**Design-review amendments (A1–A12).** Where they differ from the decisions above, these override them. Recommended, taken autonomously.
- **A1 — Which bins the term skips (replaces "non-system bins").**
  - Exclude, by identity (code + `system_owned`, as `damagedUnits` does), only the four bins already subtracted: QC-HOLD, DAMAGED, RETURNS, IN-TRANSIT.
  - **RECEIVING is included**, so a blocked or expired batch received but not yet put away is unpromisable.
  - The term runs under the same open-quarantine `notExists` predicate as `committedOnHand`, so quarantined scopes are never subtracted twice.
  - Per bin, it is clamped to `min(Σ unpromisable batch qty, stock_on_hand)` (the `replan.ts:148-157` defence).
  - Matrix rows: blocked stock in RECEIVING; blocked stock in a quarantined bin.
- **A2 — A named hook (replaces "inside `committedOnHand`").**
  - A sixth hook, `unpromisableBatchUnits`, sits beside `damagedUnits`.
  - It is subtracted in both `atp()` and `committedCeiling`, and exposed as `unpromisableBatch` on `AtpSnapshot` and `ChannelVisibleSnapshot`.
  - It is named in the 409 refusal detail ("of which N in blocked/expired batches") and in `bufferOverCeiling`.
  - `onHand` keeps its meaning.
  - Update the formula docstrings and the stale `inventory.md:206`.
- **A3 — Shared expiry predicate.**
  - `isBatchExpiredAt(expiry, at)` lives in `src/shared/primitives/` and replaces all three copies (`replan.ts:93-99`, `pick.command.ts:1548-1552`, `inventory.controller.ts:594`).
  - The hook reads (bin, batch, qty, status, expiry) rows and applies the JS predicate with an injectable clock (the `reservationRepairClock` pattern). There is no SQL `now()` copy.
  - The boundary is `Date.parse(expiry) >= at` = drawable. So a batch is unpromisable from the instant stored as its expiry (IST midnight beginning the label date for received batches).
  - Fixtures at E−1 ms, E and E+1 ms.
- **A4 — Granted reservations (extends decision 8).** When the ceiling drops below reserved:
  - A short-pick regrant can refuse, and the remainder takes the partial path, as for any stock loss. This is stated and tested.
  - `decreaseStandingBuffer` must not refuse a decrease. A decrease to a target at or below the previous one never creates ATP, so it is allowed even when the ceiling sits under reserved. This is a BE change with a test.
- **A5 — Rollout.**
  - Every expired batch on hand becomes unpromisable at deploy. Channel quantities drop on the next tick, and the replenishment sweep may open breaches.
  - Accepted, because that stock could never be drawn.
  - DEPLOY/release notes carry a pre-deploy probe query (expired-batch units per tenant and warehouse).
- **A6 — Migration safety.**
  - A pre-flight `DO` block raises, listing any `status='blocked'` row lacking the fields (the test DBs set it by hand).
  - The CHECK is written `IS NOT NULL` before `IN` (§3). Probes cover one refused and one accepted shape.
  - The `BATCH_BLOCK_REASONS` tuple is pinned against the CHECK (§4).
  - The three raw-SQL tests (`waves.spec.ts:853`, `picking.spec.ts:1084`, `replenishment.spec.ts:1502`) move to the block verb.
  - `waves.spec.ts:842-891` is re-established as a draw-side test, blocking **after** the reservation. It is not retargeted (§4).
- **A7 — Audit target.**
  - `batch` is added to `AUDIT_TARGET_TYPES`, which publishes in the OpenAPI enum, with the FE label in `src/lib/audit.ts:23`.
  - `expectAuditRow` covers both actions. Their `changes` carry before/after (status, reason, note), so history survives the row being cleared on unblock.
- **A8 — Unblock requires a note** (1–500). Lifting a recall is the riskier direction. An unblocked batch that is expired stays unpromisable, and the response carries `expired: true`.
- **A9 — DTOs and web.**
  - List and detail return `expired` (server predicate) and `blockedByName`, as well as reason and time. There is no client-side expiry copy.
  - Drop the "inventory screen ATP" claim: there is no ATP display.
  - The actions appear on the inventory batch list and detail. `replenishment-view.tsx:853` `BatchDetailBlock` shows the status only.
- **A10 — Scope and routes.**
  - The routes are tenant-scoped: `POST :tenantId/inventory/batches/:batchId/block|unblock`.
  - A block is **lot-wide**, covering all warehouses: batches are unique per (tenant, SKU, code). That suits recall and QC-fail of a lot; a single-site hold is a QC hold or a 3-3b bin block.
  - The outbox payload carries no warehouse.
- **A11 — Explicit flows into or out of a blocked lot.**
  - Receiving into, positively adjusting into, moving, and transferring a blocked batch are **allowed**. The units are unpromisable wherever they land, because status is lot-level.
  - A write-off of a named blocked batch needs `overrideReason`, as today.
  - A 3-2b pend resolved to a batch that is blocked before approval: approval re-runs the draw checks. If 3-2b has merged, its approval path must refuse a blocked FEFO-default batch; otherwise this is recorded.
  - Guard order adds the idempotency-key insert at the end, and a same-key parked-waiter race test.
  - The grant-versus-block residual race (`revalidatedCeiling` locks only `stock_on_hand`) is documented, like the QC/quarantine one.
- **A12 — Recorded, not built (PENDING inventory):**
  - a recall forward-trace read (orders and shipments containing batch B);
  - stopping packed or staged units of a blocked lot at pack and dispatch;
  - a list of orders shorted by a block, and re-planning;
  - the client portal view of blocked lots, client notification, and a client-requested block;
  - a bulk block by lot code across SKUs;
  - replenishment and transfer warnings for blocked stock;
  - an offline pick of a just-blocked batch (it already replays as the existing `batch-blocked` refusal fate; pinned in the mobile fate table docs).

## Boundaries & Constraints

**Always:**
- One shared expiry predicate.
- No double subtraction with the system-bin terms.
- The term goes into both `atp()` and `committedCeiling`.
- A block or unblock never moves stock.

**Never:**
- No bin-reason work (3-3b).
- No change to wave or pick draw rules beyond the shared predicate.
- No 4.3 allocation (FEFO/FIFO/shelf-life).
- No automatic re-plan of granted reservations.
- No serial blocks.
- No new capability.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected | Error handling |
|---|---|---|---|
| Block | Active batch B with 10 on hand in A-01 | 201; status blocked with reason; ATP −10; order create cannot reserve those 10 | — |
| Already blocked | Block on a blocked batch | 409 `batch-already-blocked` | — |
| Unblock | Blocked B | 201; ATP +10 | 409 `batch-not-blocked` if active |
| Expired | B's expiry date reached (IST) | ATP excludes it with no event; status stays active | — |
| System bin | B units in DAMAGED or QC-HOLD | Not subtracted twice | — |
| Write-off | Negative adjust naming blocked B explicitly | Allowed | The default FEFO draw skips B |
| Reserved | B blocked after an order reserved against it | ATP clamps at 0; the reservation stands; the wave shorts | — |
| Replay | Same key + body | The original response | Different body → 422 `idempotency-key-reuse` |
| `other` | Reason `other` with no note | 400 | — |

</frozen-after-approval>

## Code Map

- `wms-be/src/modules/inventory/reservation.service.ts`: `committedOnHand` (~1519-1547), `atp` (:328, :1003), `committedCeiling` (:1486-1515); the `damagedUnits` read (:197-230) is the cross-module precedent.
- `wms-be/src/modules/outbound/replan.ts:92-99` `drawableBatch`: extract the shared expiry predicate. Also check `pick.command.ts:1517-1555` and `wave.command.ts:1221-1262` use it.
- `wms-be/src/modules/catalog/`: the new `batch-block.command.ts`, facade exports, and `catalog.md:449` `ensureBatches`.
- `wms-be/src/api/inventory.controller.ts:580-595` (the adjust FEFO draw) and `:812-882` (batch routes; add the two verbs, and expose reason/at/by in the reads).
- `wms-be/src/shared/db/schema.ts:1143-1162` `batches` and the migration (`drizzle/`), with probes.
- `wms-be/src/shared/primitives/audit.ts` `AUDIT_NEW_ACTIONS`: `batch.blocked` and `batch.unblocked`.
- `wms-be/test/`: a batch-block spec (every matrix row, the ATP effect via order create, the channel visible quantity), and the architecture allowance. Regenerate OpenAPI.
- `wms-fe`:
  - `src/lib/inventory.ts:196-199` `batchStatusLabel`;
  - `inventory-screen.tsx:738` (batch list);
  - the batch detail;
  - the new block dialog;
  - client regen and tests.
- Meta docs (after code): inventory.md (the ATP formula), catalog.md, API-SURFACE, the FE design, PENDING (close :425; fix :36), both contracts.

## Tasks & Acceptance

**Execution:**
- [ ] BE: migration + schema; shared expiry predicate; catalog block command + facade; routes and reads; the ATP term; adjust-draw filter; audit; tests; OpenAPI.
- [ ] FE: actions, dialog, labels; regen; tests.
- [ ] Meta docs as in the Code Map; deferred-work 3-3b.

**Acceptance Criteria:**
- Given B blocked with 10 on hand and 0 other stock, when an order for 1 is created, then it backorders (no grant), and `channelVisibleQuantity` is 0.
- Given B expires today (IST), when ATP is read before and after IST midnight, then it flips without any event, matching what a wave would draw.
- Given a blocked bin (3-3b not shipped), then this term is unaffected; only batch status and expiry count.

## Verification

**Commands:**
- `cd workspace/core/backend/wms-be && bun run lint && bun run typecheck && bun run test` — expected: all pass (one jest run at a time).
- `cd workspace/core/frontend/wms-fe && bun run test && bun run lint && bun run typecheck && bun run build` — expected: all pass.

## Implementation Notes

## Spec Change Log

## Review Triage Log

Design review, 2026-10-22 (D). Two layers: a claims check against the code (K) and a blind reviewer (B). Choices are recommended, taken autonomously.

| ID | Src | Verdict | Finding → resolution |
|---|---|---|---|
| D1 | K | high | RECEIVING is a system bin but is not subtracted, so blocked stock there stays promised. → A1 |
| D2 | K | high | Open quarantines subtracted twice. → A1 |
| D3 | K | high | The term inside `committedOnHand` changes `onHand` and vanishes from refusal detail. → A2 |
| D4 | K | high | Raw-SQL blocked tests break under the CHECK; the waves test's semantics. → A6 |
| D5 | K | medium | Ceiling < reserved: pick regrant and buffer decrease refuse. → A4 |
| D6 | K | medium | The shared predicate is not implementable across modules; the SQL `now()` copy. → A3 |
| D7 | K,B | medium | IST boundary and the AC mis-stated; inclusive/exclusive. → A3 |
| D8 | K | medium | Deploy-time step change for expired stock. → A5 |
| D9 | K | medium | Batch projection divergence; per-bin clamp. → A1 |
| D10 | K | medium | `batch` missing from AUDIT_TARGET_TYPES (FE compile break). → A7 |
| D11 | K,B | medium | Migration "no blocked rows" asserted, not guarded; CHECK form; tuple pin. → A6 |
| D12 | K,B | medium | Client-side Expired copy; no blocker name; no ATP display. → A9 |
| D13 | K,B | medium | Lot-wide vs warehouse scope implicit. → A10 |
| D14 | K,B | low | Receive, move or transfer into a blocked lot implicit. → A11 |
| D15 | K | low | Explicit write-off needs overrideReason. → A11 |
| D16 | K | low | Grant-vs-block residual race. → A11 |
| D17 | K | low | Guard order: key insert, same-key race. → A11 |
| D18 | K | low | 3-2b pend interplay; migration sequencing. → A11 |
| D19 | K | low | Line references. → fixed in the implementation notes when coding |
| D20 | B | medium | No recall forward trace. → A12 |
| D21 | B | medium | Packed or staged units keep moving. → A12 |
| D22 | B | medium | No list of orders shorted by a block. → A12 |
| D23 | B | medium | Client portal, notification, client-requested blocks, billing. → A12 |
| D24 | B | — | Channel feeds stale on expiry, with no event. → R: the channel publish polls a full snapshot every `CHANNELS_SYNC_POLL_MS` tick (`jobs.module.ts:672-700`, K verified); no event needed |
| D25 | B | low | Unblock too weak; history lost. → A7, A8 |
| D26 | B | low | Bulk recall block. → A12 |
| D27 | B | low | Query performance: the hook reads per-SKU rows (atp is per SKU) on the existing (tenant, sku) indexes; no new index. → A3 note |
| D28 | B | low | Offline pick replay after a block. → A12 (existing fate) |
| D29 | B | low | Replenishment and transfers of blocked stock. → A11 (allowed), A12 (warnings) |
| D30 | B | low | Thin ACs. → A1, A3, A4, A6 add matrix rows and fixtures |
