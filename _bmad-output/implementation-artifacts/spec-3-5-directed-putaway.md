---
title: 'Story 3.5: Directed putaway'
type: 'feature'
created: '2026-09-10'
status: 'done'
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
- [x] `wms-be drizzle/0015_*.sql` -- `putaway_placements` + RLS/CHECKs/index -- the placement data model.
- [x] `wms-be/src/modules/inventory/ledger-registry.ts` -- register `putaway.placed` + the `putaway` arm -- the ledger truth.
- [x] `wms-be/src/modules/tenancy/permissions.ts` -- add `putaway.execute` (owner/ops_manager/operator) -- the authority.
- [x] `wms-be/src/modules/putaway/` (command + facade + dto) + `PutawayController` -- tasks read (derive + suggest), placement command (idempotent, guarded, outbox, audit), placements read -- the module.
- [x] `wms-be/src/modules/inbound/receiving.facade.ts` -- snapshot gains `bins` + `putawayTasks` (additive) -- the mobile decision surface.
- [x] `wms-be bun run openapi:export` -- additive diff (three routes + snapshot fields) -- drift guard.
- [x] `wms-be/test/putaway.spec.ts` -- e2e per the matrix incl. capacity/block/authority/replay/quarantine arms -- the matrix pinned.
- [x] `wms-mobile` -- OpType + sender + api fn + snapshot fields + inbox Putaway tab + `app/putaway.tsx` flow (scan SKU → qty → scan/enter bin with wrong-bin/blocked pre-check → confirm enqueues `putaway.place`) + `src/putaway/draft.ts` -- the operator flow.
- [x] `wms-mobile` typecheck + tests (op-dispatch exhaustiveness, draft decisions).
- [x] `wms-fe bun run api:generate` + `src/lib/users.ts` mirror + `users.test.ts` pin -- typed consumers.

**Acceptance Criteria:**
- Given a GRN with applied stock in the Receiving bin, when the operator opens the Putaway tab, then each line shows a suggested bin and the placement scan-confirms it (FR-10)
- Given a full or blocked bin, when placed, then the command refuses naming the capacity/block reason — on-device before queueing when cached, always at replay
- Given placement differing from the suggestion, when recorded, then the reason is captured in the placement row (report-ready; SM-3)
- Given an offline placement, when replayed, then it lands exactly once as a `putaway.placed` ledger movement, re-authorized; a diverged replay quarantines without corrupting on-hand

## Implementation Notes

<!-- Append-only during implementation. -->

- **Ledger serial guard gained the relocation arm (2026-09-10, `ledger.service.ts` `assertSerialArmLegal`).** A placement's per-serial event is ONE two-arm event per unit (`quantityDelta = +1` with BOTH `fromBinId` (the Receiving bin) and `toBinId` (the target) — the qc.held two-arm convention, so the fold moves the unit in a single event). The pre-existing guard treated every positive movement as a pure intake and 409'd `duplicate-serial` on any located serial — correct for `stock.adjustment` (single-arm: intake `toBinId` only, draw `fromBinId` only), wrong for the two-arm placement event. The guard now branches on `fromBinId`: a positive movement WITHOUT a from-bin is a pure intake (duplicate check, unchanged); a positive movement WITH a from-bin is a relocation and takes the draw-side semantics (latest event must be an intake into the movement's `fromBinId`, else 409 `serial-elsewhere` naming the serial's actual bin; never-moved → 404 `serial-unknown`). Consequence for callers: `duplicate-serial` can only fire on a pure intake — a placement that re-scans a serial already living in the target bin surfaces as `serial-elsewhere` naming that bin (the serial is not in the from-bin), not `duplicate-serial`. No existing producer writes two-arm serial events, so `stock.adjustment` behavior is unchanged.
- **Verification re-run (2026-09-10, step-03):** all suites green on my side — BE 289/289 across 19 suites (incl. 16 putaway e2e), lint + typecheck + build + `db:migrate` + `db:verify` round-trip clean (0015 drift guard passes); mobile typecheck clean + 66/66; FE 76/76 + lint + typecheck + build clean. Full-diff read complete (34 files); matrix audit: all 13 matrix rows covered by the 16 e2e tests, each verified against its expected behavior in the diff.
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

<!-- ── Review pass 1 (2026-09-10, step-04): 33 findings — 13 edge-case, 15 blind-hunt, 2+3 verification-gap. ── -->

**Edge-case-hunter findings:**
1. **high** — `serials: null` crashes the placement command. VERIFIED: mobile `confirmPayload` (draft.ts:205) always sends `serials: null`; `@IsOptional()` skips validation for null; controller (:98) forwards it; `putaway.command.ts:208` spreads null inside `hashCommandPayload` → TypeError → 500 before the tx opens. **Every mobile placement fails.** → patch.
2. **medium** — batch never checked against the GRN line. VERIFIED: the batch arm (:320-352) validates the batch exists for (tenant, sku) but never `line.batchId !== command.batchId`; a batch from another line of the same SKU is accepted and recorded against the wrong line. → patch.
3. **medium** — concurrent capacity race. VERIFIED: remaining/occupancy reads (:476-509) run before `appendLedgerEventInTx` takes the per-(tenant, warehouse) advisory lock; two concurrent placements into the same bin both pass capacity, then append serially → over capacity (the ledger's insufficiency guard covers draining, not filling). → patch.
4. **medium** — serial arm drops the batch. VERIFIED: per-unit events (:408-428) carry `batchRef: null` even when `batchId` is resolved; batch/serial tracking are independent booleans (no exclusivity), so a both-tracked SKU's batch arm in Receiving never drains — tasks keep promising moved stock. Receiving (:714) and adjustment (:454) carry the batch on per-serial events. → patch.
5. **low** — `reasonCode` on a match silently accepted. VERIFIED: only the mismatch direction is enforced (:526-530); a stale reason on a match is recorded. Fix is a strip (not a reject — the server's re-derived suggestion can legitimately differ from the device's task suggestion, so a supplied reason on a server-derived match is stale, not illegal). → patch.
6. **low** — snapshot composition failure blocks the whole device snapshot. REJECTED: fail-closed is the design — a device that cannot read its task surface should not operate; speculative robustness. → reject.
7. **low** — unbounded tasks read (no limit on `lineRows`). VERIFIED but bounded: the read covers pending-receipt lines only, which drain as stock is placed; no pagination in the frozen matrix. → reject.
8. **high** — legacy sealed-cache crash (inbox). PRE-VERIFIED by verification-gap layer (Gap A): `device-store.getCatalogSnapshot()` JSON.parses with no shape check; `inbox.tsx:302` `.map` on undefined for a pre-3.5 cache. → patch.
9. **high** — legacy sealed-cache crash (putaway.tsx:71/93/252). Same root cause as 8. → patch (grouped).
10. **low** — `tenantId ?? ''` at confirm queues an unsendable op. REJECTED: a snapshot can only be cached by an enrolled device whose tenantId secret is set; not met in everyday use. → reject.
11. **medium** — POST documents 200, returns 201. VERIFIED: `@HttpCode(CREATED)` (:50) vs `@ApiResponse(status: OK)` (:60); `openapi/openapi.json` documents 200. → patch.
12. **low** — task-cap docstring overclaims. VERIFIED: facade comment (:191) claims a cross-line cap the per-line `min(applied, onHand)` does not provide; the (non-frozen) Design Notes say per-line completion is approximate. Comment fix. → patch.
13. **medium** — serial arm `batchRef: null`. Duplicate of 4. → patch (same fix).

**Blind-hunter findings:**
1. **medium** — 200-vs-201. Duplicate of edge-11. → patch.
2. **low** — task-cap docstring. Duplicate of edge-12. → patch.
3. **medium** — All tab renders only the receive list. VERIFIED: `inbox.tsx:94-97` renders `ReceiveTaskList` for `Receive || All` and `PutawayTaskList` only for `Putaway` — its own comment promises both. → patch.
4. **medium** — placedAt is server time documented as device time. VERIFIED: the row gets `nowIso()` (:536) while `PutawayPlacementDto` documents "Device time of the placement (AD-1)"; the GRN-note pattern (schema.ts:1089) keeps device `occurred_at` + server `recorded_at`. → patch (placedAt = occurredAt).
5. **low** — chooseBin docstring backwards. VERIFIED: draft.ts:161 says "a mismatch clears any stale reason"; the code clears on a match (behavior right, comment wrong). → patch.
6. **high** — no pre-3.5 cache compatibility. Duplicate of Gap A (edge-8/9). → patch.
7. **low** — "oldest receipt first" is GRN-code order. REJECTED: codes are allocated sequentially (`allocateGrnCode`), so code order is receipt order; the comment is accurate in effect. → reject.
8. **low** — suggestions ignore cumulative fit across tasks. BY DESIGN: the frozen intent is per-task capacity-only suggestions and frozen Never excludes claim/reservation machinery; suggestions are advisory and the server re-gates. → reject (out of scope per frozen intent).
9. **low** — documented 409 `duplicate-serial` unreachable for putaway. VERIFIED: a relocation event always carries fromBinId, so the guard surfaces `serial-elsewhere`; the controller's 409 doc still names `duplicate-serial`. Docstring fix. → patch.
10. **medium** — relocation 404 `serial-unknown` / drawn-out arm untested. VERIFIED: no e2e arm draws a serial out (−1) then places it; the guard's relocation semantics are pinned only on the intake arm (overlaps Gap B). → patch (test arms).
11. **false** — `serialElsewhere(latest.toBinId ?? latest.fromBinId!)` can name a null bin. REFUTED: every ledger event carries at least one bin arm (intake: toBinId; draw: fromBinId; two-arm: both), so the coalesce never resolves null; the draw case names the bin drawn out of — the intended last-known-bin semantics. → reject.
12. **low** — concurrent-drain test witnesses brittle. Magic-number heuristics in one test; deterministic in practice. → reject.
13. **false** — inbox-routed preselected task resets on re-tap. REFUTED: putaway.tsx loads the draft once on mount (:64-76, "Load once"); `chooseTask`'s reset is its documented contract. → reject.
14. **low** — mismatch rule duplicated inline in putaway.tsx. VERIFIED: :190 inlines the `isMismatch` expression; the exported function exists. → patch.
15. **low** — web read surface has no FE consumer; mismatch enum hand-copied without a drift test. The web report surface is the human-deferred Split; the enum drift rides with that story. → defer.

**Verification-gap layer findings:**
- **high** (primary, pre-verified) — Gap A: legacy cached snapshot crashes putaway readers. → patch (with edge-8/9).
- **medium** (primary, pre-verified) — Gap B: relocation guard's "already drawn out" arm unverified (no test draws a serial out then places it). → patch (test arms, with blind-10).
- **low** — task-cap comment. Duplicate of edge-12. → patch.
- **medium** — status-code contract mismatch. Duplicate of edge-11. → patch.
- **low** — no per-surface OpenAPI companion test for putaway. VERIFIED: the drift-guard companion pattern exists in five other specs (catalog/api/devices/tenancy/users); putaway.spec.ts lacks it. → patch (one test).

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