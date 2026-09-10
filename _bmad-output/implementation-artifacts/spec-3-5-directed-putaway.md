---
title: 'Story 3.5: Directed putaway'
type: 'feature'
created: '2026-09-10'
status: 'in-progress'
route: 'dispatch'
review_loop_iteration: 0
baseline_commit: 'f86451b42c64d439c222e64aec426104f4076241' # wms-be main
baseline_commit_fe: 'a45074c804152cace0e396fb629d9d818c523cf3' # wms-fe main
baseline_commit_mob: 'd0db5dcab27ed6136df3d2c31826466649683ef7' # wms-mobile main
context:
  - '_bmad-output/implementation-artifacts/epic-3-context.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** Received stock sits in the warehouse's system Receiving bin with no way to move it to a storage bin — dock-to-stock stalls at the last step, and nothing tells the operator where stock should go.

**Approach:** The `putaway` module (empty spine exists) ships directed putaway: the backend derives putaway tasks from GRN lines whose applied stock still sits in the Receiving bin, suggests a target bin per task (capacity fit, not blocked, not system-owned), the operator works the task on mobile — scan SKU, qty, scan/enter the bin — and the placement is a real ledger movement (`putaway.placed`, Receiving bin → target bin) recorded with suggestion-vs-actual + reason for the SM-3 report. Offline-first like receiving: decisions on-device, one queued `putaway.place` op replayed exactly once, server re-gates at replay.

**Decided (2026-09-10, human):**
- **Split** — scope is backend + mobile operator flow as one goal; the web suggestion-vs-actual report surface (plus the velocity class, `zones.putaway_class`, and the nightly slotting job) is deferred to `deferred-work.md` and a follow-up story.
- **Authority** — a new `putaway.execute` capability (Owner + Ops Manager + Operator; Accountant none — the first non-empty operator capability, deliberate).
- **Suggestion algorithm** — capacity-only v1: capacity fit ∧ not blocked ∧ not system bin, ranked lowest occupancy then bin code; no velocity class, no zone affinity, no nightly job (a recorded FR-10 deviation — the deferred story ships those with the report).
- **Mismatch reason** — a fixed enum, required in the placement payload when actual ≠ suggested: `pallet-too-heavy`, `suggested-bin-occupied`, `consolidation-with-existing-stock`, `operator-preference`, `other` (the `blindReasonCode` pattern; report- and summary-labelable).

## Boundaries & Constraints

**Always:**
- All stock changes go through `appendMovement` (ledger + projection in one tx) — a placement is one movement from the system Receiving bin to the target bin, never a direct `stock_on_hand` write; batch-tracked SKUs move one event per batch arm (batchRef carried), serial-tracked SKUs carry their serials (mirror `stock.adjustment`'s serials pattern).
- Placement is an idempotent command (required `Idempotency-Key`, payload hash, replay re-serves the snapshot, mismatch 422) in the established invariant order: device re-read fail-closed → role re-read → `assertPermission('putaway.execute')` → idempotency replay → validation → movement → placement row → in-tx outbox → audit → idempotency-key snapshot.
- Suggestion and placement guards are server-side truth; the device's on-device checks (bin exists, not blocked per cached snapshot) mirror but never replace them (AD-4/AD-10).
- Full or blocked bin rejection names the reason: `bin-full` (occupancy + qty vs capacity) / `bin-blocked` (FR-10).
- Mutating putaway endpoints are device-token-only (the `grn.submit` pattern — `DeviceSessionGuard`, badge-in session, real authority re-read in the command tx); web stays read-only.

**Never:**
- No bin claim/assignment machinery (FR-29's claim UX arrives with picking; receive tasks are derived and unclaimed today — putaway matches).
- No `state_epoch` capture (its consumer stories — count/short-pick — are feature-level deferred; the ledger's sufficiency guard plus replay re-authorization covers concurrent divergence: a losing replay fails `422 insufficient-on-hand` and quarantines, never corrupts).
- No nightly slotting job, no velocity class, no bin scoring/optimization (deferred with the report).
- No mobile claim/conflict UI beyond the sync-summary retraction the op path already gives.
- No new ledger grammar version: `putaway.placed` registers sinceVersion 1; the reference-doc arm appends only.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Tasks read | warehouse with GRN lines whose applied stock sits in the Receiving bin | task per line: GRN code, SKU, batch, remaining qty (min(applied, receiving-bin on-hand for sku/batch)), suggested bin + one-line rationale | N/A |
| Suggestion | line's SKU has no prior location | capacity-fit ∧ not blocked ∧ not system bin, lowest occupancy, then bin code order | N/A |
| Place happy path | operator scans target bin, qty within remaining | `200` placement snapshot; `putaway.placed` movement Receiving→target; placement row; outbox `putaway.recorded`; audit; device + server both re-gate | N/A |
| Replay | same key + payload | original snapshot re-served, nothing re-moved | 200 replay |
| Key reuse, different payload | same key, different qty/bin | nothing written | 422 `idempotency-key-reuse` |
| Full bin | target bin occupancy + qty > capacity | nothing written | 400 `bin-full` naming bin code, capacity, occupancy |
| Blocked bin | target bin blocked=true | nothing written | 400 `bin-blocked` naming the bin (device pre-checks from the cached snapshot too) |
| Non-target bin | system bin (Receiving/QC-HOLD) as target | nothing written | 400 `validation-failed` naming the bin |
| Over-place | qty > remaining for the (sku, batch) in the Receiving bin | nothing written | 400 `validation-failed` naming the remaining quantity |
| Concurrent drain | queued putaway replays after receiving-bin stock moved elsewhere | hold nothing; op rejected deterministically | 422 `insufficient-on-hand` → quarantine with session attribution |
| Wrong authority | accountant role, foreign tenant, expired device | nothing written | 403 `role-denied` / `permission-denied`, 401 `unauthenticated` |
| Mismatch record | actual ≠ suggested | placement row carries reason_code from the fixed enum (required in payload) | 400 `validation-failed` when reason missing/malformed |
| Serial-tracked SKU | placement without serials / wrong count / serial elsewhere | nothing written | 400 (mirror `stock.adjustment` serials arms) |

</frozen-after-approval>

## Code Map

- `wms-be/src/modules/putaway/putaway.module.ts` -- empty spine — becomes the module (command + facade providers).
- `wms-be/src/modules/inventory/ledger-registry.ts` -- register `putaway.placed` (sinceVersion 1) + reference arm `{kind:'putaway', grnId, grnLineId, reasonCode?, suggestedBinId?}`; additive only.
- `wms-be/src/modules/inventory/ledger.service.ts` -- `appendMovement` (:422-565) carries fromBin+toBin in one event (fold :515-562); sufficiency guard 422 (:268); serial-arm path reused.
- `wms-be/src/modules/tenancy/receiving-bin.ts` -- `ensureReceivingBinInTx` (:47-108) — the from-bin identity (`RECEIVING`, staging, system-owned).
- `wms-be/src/modules/tenancy/permissions.ts` -- add `putaway.execute` (:9-37, :47-68): owner + ops_manager + **operator**.
- `wms-be/src/shared/db/schema.ts` + `drizzle/0015_*.sql` -- `putaway_placements` (scope ids, qty, from/to/suggested bin, reason_code?, placed_by/at, device_id) + hand-appended fail-closed RLS + CHECKs + `(tenant_id, warehouse_id, created_at, id)` index (0014 pattern).
- `wms-be/src/modules/inbound/receiving.command.ts` -- command template: invariant order (:176-180), `hashCommandPayload` (:217), device re-read (:235-262), outbox (:581), audit (:757), `writeIdempotencyKey` (:814).
- `wms-be/src/modules/inbound/receiving.facade.ts` -- list-read template `listOverReceipts` (:237-286, `decodeCursorSafe` :93 + `buildPage`); `getCatalogSnapshot` (:291) — extend with `bins` + `putawayTasks` (additive).
- `wms-be/src/api/` -- NOT `receiving.controller.ts`; new `PutawayController` (its guard style: `DeviceSessionGuard` mutation, `TenantSessionGuard` reads) in `api.module.ts` (:42-49).
- `wms-be/src/modules/tenancy/bin.command.ts` -- `bins.blocked` toggle — consumed, not owned (re-home belongs to 3.6).
- `wms-be/test/putaway.spec.ts` (new) -- e2e per the matrix; bootstrap mirrors `receiving.spec.ts`/`qc-holds.spec.ts` (advisory lock 742106).
- `wms-mobile/src/offline/types.ts` -- `OpType` (:12) gains `'putaway.place'`.
- `wms-mobile/src/state/op-dispatch.ts` + `src/api.ts` -- `sendOp` exhaustive branch (:31-52) + sender; `fetchApiPlacePutaway` (badge token + idempotency key); `CatalogSnapshot` (:259-264) gains `bins` + `putawayTasks` (sealed-cache accessors: `device-store.ts:228-260`).
- `wms-mobile/app/inbox.tsx` -- Putaway tab branch (:89-104; replaces the "Task types arrive with putaway" empty state).
- `wms-mobile/app/putaway.tsx` (new) + `src/putaway/draft.ts` (new) -- linear flow mirroring `app/receive.tsx` + `src/receiving/draft.ts` (:84-141); banner from `src/components/scan-banner.tsx`.
- `wms-fe/src/lib/users.ts` + `users.test.ts` -- mirror `putaway.execute` (matrix 11→12, operator non-empty; per-story assertion).

## Tasks & Acceptance

**Execution:**
- [ ] `wms-be drizzle/0015_*.sql` -- `putaway_placements` + RLS/CHECKs/index -- the placement data model.
- [ ] `wms-be/src/modules/inventory/ledger-registry.ts` -- register `putaway.placed` + the `putaway` arm -- the ledger truth.
- [ ] `wms-be/src/modules/tenancy/permissions.ts` -- add `putaway.execute` (owner/ops_manager/operator) -- the authority.
- [ ] `wms-be/src/modules/putaway/` (command + facade + dto) + `PutawayController` -- tasks read (derive + suggest), placement command (idempotent, guarded, outbox, audit), placements read -- the module.
- [ ] `wms-be/src/modules/inbound/receiving.facade.ts` -- snapshot gains `bins` + `putawayTasks` (additive) -- the mobile decision surface.
- [ ] `wms-be bun run openapi:export` -- additive diff (three routes + snapshot fields) -- drift guard.
- [ ] `wms-be/test/putaway.spec.ts` -- e2e per the matrix incl. capacity/block/authority/replay/quarantine arms -- the matrix pinned.
- [ ] `wms-mobile` -- OpType + sender + api fn + snapshot fields + inbox Putaway tab + `app/putaway.tsx` flow (scan SKU → qty → scan/enter bin with wrong-bin/blocked pre-check → confirm enqueues `putaway.place`) + `src/putaway/draft.ts` -- the operator flow.
- [ ] `wms-mobile` typecheck + tests (op-dispatch exhaustiveness, draft decisions).
- [ ] `wms-fe bun run api:generate` + `src/lib/users.ts` mirror + `users.test.ts` pin -- typed consumers.

**Acceptance Criteria:**
- Given a GRN with applied stock in the Receiving bin, when the operator opens the Putaway tab, then each line shows a suggested bin and the placement scan-confirms it (FR-10)
- Given a full or blocked bin, when placed, then the command refuses naming the capacity/block reason — on-device before queueing when cached, always at replay
- Given placement differing from the suggestion, when recorded, then the reason is captured in the placement row (report-ready; SM-3)
- Given an offline placement, when replayed, then it lands exactly once as a `putaway.placed` ledger movement, re-authorized; a diverged replay quarantines without corrupting on-hand

## Implementation Notes

<!-- Append-only during implementation. -->

- **Ledger serial guard gained the relocation arm (2026-09-10, `ledger.service.ts` `assertSerialArmLegal`).** A placement's per-serial event is ONE two-arm event per unit (`quantityDelta = +1` with BOTH `fromBinId` (the Receiving bin) and `toBinId` (the target) — the qc.held two-arm convention, so the fold moves the unit in a single event). The pre-existing guard treated every positive movement as a pure intake and 409'd `duplicate-serial` on any located serial — correct for `stock.adjustment` (single-arm: intake `toBinId` only, draw `fromBinId` only), wrong for the two-arm placement event. The guard now branches on `fromBinId`: a positive movement WITHOUT a from-bin is a pure intake (duplicate check, unchanged); a positive movement WITH a from-bin is a relocation and takes the draw-side semantics (latest event must be an intake into the movement's `fromBinId`, else 409 `serial-elsewhere` naming the serial's actual bin; never-moved → 404 `serial-unknown`). Consequence for callers: `duplicate-serial` can only fire on a pure intake — a placement that re-scans a serial already living in the target bin surfaces as `serial-elsewhere` naming that bin (the serial is not in the from-bin), not `duplicate-serial`. No existing producer writes two-arm serial events, so `stock.adjustment` behavior is unchanged.
- **e2e note (2026-09-10):** the concurrent-drain arm parks the placement by holding the per-(tenant, warehouse) advisory lock in a manual `postgres` session and polling `pg_stat_activity` for an active lock-wait on the append's `pg_advisory_xact_lock` query. Matching `pg_locks.objid` directly does NOT work for bigint advisory keys — the key is split into `classid`/`objid` halves and `objid = hashtextextended(...)` overflows the oid type range ("OID out of range"). The supertest request must also be dispatched (its `.then` registered) BEFORE the poll — a supertest `Test` only sends when awaited.

## Spec Change Log

<!-- Append-only. Populated by step-04 during review loops. Do not modify or delete existing entries.
     Each entry records: what finding triggered the change, what was amended, what known-bad state
     the amendment avoids, and any KEEP instructions (what worked well and must survive re-derivation).
     Empty until the first bad_spec loopback. -->

## Review Triage Log

<!-- Append-only. Populated by step-04 on every review pass: one row per reviewer finding —
     verdict (high/medium/low/false/maybe-false) with its evidence: the refutation for
     false, what would settle it for maybe-false. Empty until the first review pass. -->

## Design Notes

**Derived tasks, not stored tasks.** Stock in the Receiving bin is not attributable to specific GRN lines (folds are per sku/batch/bin), so a task's "remaining" is `min(line.applied_qty, receiving-bin on-hand for that sku/batch)` and per-line completion is approximate when two GRNs bring the same (sku, batch). Placement moves the qty the operator enters (partial placements allowed, one op per placement); no task claim/state table in v1 — the inbox derives from the snapshot, the backend derives from GRN lines + on-hand.

**Why no velocity in v1 (recorded FR-10 deviation):** no velocity data exists anywhere (grep: zero hits), zones carry no type/class field, and a nightly job would need worker infra for a tenant whose ledger history starts today. Capacity-only suggestions are honest and testable; the velocity class + `zones.putaway_class` affinity + the report that makes accuracy *visible* ship together in the deferred follow-up (human decision at the token gate).

**Snapshot shape (additive):** `bins: [{id, code, zoneId, zoneCode, type, capacity, blocked, systemOwned}]` (blocked/system bins stay in the payload — the device needs them to *reject* a scan against them, so it verifies pre-queue) and `putawayTasks: [{grnId, grnCode, grnLineId, skuId, skuCode, batchId?, batchCode?, qty (remaining), suggestedBin: {binId, binCode} | null, rationale}]` — suggestions baked into the snapshot are advisory; the server re-derives and re-gates at placement.

**Placement command shape** (mirrors `placeHold`): authority (device re-read + role re-read → `assertPermission('putaway.execute')`) → idempotency replay → validation (bin in warehouse, not system-owned, not blocked, capacity fit, remaining check, serials for serial-tracked) → movements (Receiving bin → target) → `putaway_placements` row → outbox `putaway.recorded` → audit → idempotency-key snapshot.

## Verification

**Commands:**
- `cd workspace/core/backend/wms-be && bun run test` -- expected: all suites pass incl. `test/putaway.spec.ts`; the ledger stays reconciling
- `cd workspace/core/backend/wms-be && bun run lint && bun run typecheck && bun run build && bun run db:migrate && bun run db:verify` -- expected: clean; drift guard round-trips 0015
- `cd workspace/core/mobile/wms-mobile && bun run typecheck && bun run test` -- expected: clean; new op type + draft decisions pinned
- `cd workspace/core/frontend/wms-fe && bun run test && bun run lint && bun run typecheck && bun run build` -- expected: clean; `api:generate` output committed