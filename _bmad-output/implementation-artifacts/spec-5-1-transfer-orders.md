---
title: 'Transfer Orders — two-sided ledger legs, in-transit ATP exclusion, mobile confirm'
type: 'feature'
created: '2026-09-28'
status: 'done'
route: 'dispatch'
baseline_commit: 'wms-be:9696531 wms-mobile:22e1790'
review_loop_iteration: 1
context:
  - '_bmad-output/implementation-artifacts/epic-5-context.md'
  - 'docs/design/SYSTEM-DESIGN.md'
  - 'docs/design/IMPLEMENTATION-GUIDE.md'
  - 'docs/design/modules/inventory.md'
  - 'docs/design/modules/README.md'
  - 'docs/design/mobile/LLD.md'
  - 'docs/design/PENDING.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** Stock can only be relocated by placement/merge (same warehouse, immediate). There is no way to move stock Bin→Bin or Warehouse→Warehouse as a tracked, two-sided operation, and nothing in ATP represents goods in transit — so a stock-in-motion story cannot exist (Epic 5 foundation; FR-18, FR-29).

**Approach:** Populate the empty `movements` spine module with Transfer Orders: a two-leg state machine (draft → in-transit → completed) where the outbound confirm writes ledger events on the source warehouse chain and the inbound confirm completes on the destination chain, both legs correlated by Transfer Order ID in the hashed `referenceDoc`. In-transit stock physically parks in a system-owned IN_TRANSIT bin (QC-hold precedent) and is excluded from warehouse ATP by a dedicated subtraction hook. Mobile gains the `Transfer` inbox task (already a reserved placeholder tab) with an epoch-carrying `transfer.confirm` op.

## Boundaries & Constraints

**Always:**
- Every stock write rides `appendLedgerEventInTx` / the inventory ledger path; movements never writes `stock_on_hand`/`batch_on_hand` directly (PROJECTION_OWNER).
- The full command skeleton order (shape checks → fingerprint → authority → replay → parent asserts → locks → guards → writes → outbox → audit → idempotency key last).
- Units: base on the wire, milli inside commands, base out; zero-scaling input refused.
- Locks are acquired in the codebase's canonical acyclic order: bin-row locks → serial advisory locks → warehouse advisory lock(s), sorted by warehouse uuid when there are two. No lock is acquired out of this order (amended from "advisory-first" on human approval, 2026-09-28 — see Spec Change Log).
- Inbound confirm runs the destination placement gates (bin-row lock, capacity, storage class, hazard, bulk-asset, secure authority) — a transfer may NOT bypass the gates `stock.adjust` bypasses.
- Idempotency-Key required on every mutating route; mobile op ULID is the key.
- New tables: migration SQL RLS + CHECK, `db:generate` → "No schema changes", no FKs.

**Never:**
- No FE surface in this story (deferred — Open Question 1 records the decision).
- No in-transit cancellation (draft-only cancel; deferred).
- No edit of a non-draft transfer order (lines/qty immutable after create; corrections are new compensating orders).
- No new event-vocabulary values replacing existing ones; ledger-registry changes are additive registration only.
- No ATP endpoint, no reservation-granting from movements, no Valkey calls inside a caller's transaction.

**Recorded decisions (2026-09-28, human-approved):**
1. **No FE surface in this story.** The `/moves` web surface (list + create + detail + confirm) is deferred to a follow-up story; transfer orders are created and confirmed via HTTP only here. The spec stays BE + mobile.
2. **Mobile covers the inbound leg only.** The `Transfer` inbox tab lists in-transit transfers awaiting inbound confirm; the operator confirms the inbound leg (destination bin + qty). Outbound confirm runs on the web/API by `transfers.manage` holders.
3. **Draft-only cancel.** Reversing an in-transit transfer is deferred; `cancel` refuses any non-draft order with 409 `transfer-wrong-state`.

Token gate resolved: full spec kept (~2,700 tokens) — the span is two repos and a first-ever cross-warehouse ledger model.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Bin→Bin happy path | draft transfer (same warehouse), outbound-confirm, inbound-confirm | 2 leg events on one chain (source bin→IN_TRANSIT bin; IN_TRANSIT bin→dest bin); status in_transit then completed; epochs bumped both bins | N/A |
| Warehouse→Warehouse happy path | cross-warehouse draft, both confirms | outbound leg on source chain (→ source IN_TRANSIT bin); inbound leg = drain event (toBin null) on source chain + intake event on dest chain, one tx | rollback rolls back BOTH chains |
| In-transit ATP exclusion | transfer in_transit | source warehouse ATP excludes in-transit units (inTransit hook); destination ATP unchanged (units not yet arrived) | N/A |
| Outbound confirm with source drawn down | on-hand at source bin < line qty | no write | 409 `transfer-source-short`, order stays draft |
| Inbound confirm wrong state | order not in_transit | no write | 409 `transfer-wrong-state` |
| Inbound confirm epoch mismatch | dest bin epoch ≠ op payload | no write | 409 `transfer-bin-changed` (mobile classifies re-plannable) |
| Inbound placement gate refusal | dest bin over capacity / non-conforming class / hazard conflict / bulk-asset held / secure bin without `secure.move` | no write | 409 with the gate's own machine code; order stays in_transit |
| Replay | same Idempotency-Key + same payload | stored snapshot replayed | same key + different payload → 422 `idempotency-key-reuse` |
| Cancel | draft order | status cancelled, no stock effect | in_transit/completed cancel → 409 `transfer-wrong-state` |
| Kit line | kit SKU on a line | no write | 409 `kit-cannot-hold-stock` |
| Serial line | serial-tracked SKU | one serial per unit, `lockSerialsInTx` pre-lock, serial arms on both legs | duplicate/unknown serial → existing serial machine codes |
| Precision | base-unit input scaling to zero milli | no write | 400 precision refusal |
| Cross-tenant | foreign transfer/bin/sku ids | no write | 404 |

</frozen-after-approval>

## Code Map

**Backend — `wms-be` (all paths under `workspace/core/backend/wms-be`):**

- `src/modules/movements/movements.module.ts` -- empty placeholder; register `TransferService` (commands), `MovementsFacade`; import `InventoryModule` (+ `TenancyModule` for guards) and export only the facade.
- `src/modules/movements/transfer.command.ts` (NEW) -- the command skeleton: `createTransfer`, `confirmOutbound`, `confirmInbound`, `cancelTransfer`. Mirror the `stock.adjust` guard order (`src/modules/inventory/inventory.command.ts:342-500`).
- `src/modules/movements/transfer.facade.ts` (NEW) -- public seam: create/list/get/cancel/confirm + `getTransferTasksInTx(tx, tenantId, warehouseId, cap)` for the device snapshot (derived read, no task table — putaway precedent `putaway.facade.ts:216`).
- `src/modules/movements/movements.dto.ts` (NEW) -- class-validator + `@ApiProperty` DTOs; base units at the edge.
- `src/shared/db/schema.ts` -- add `transfer_orders` + `transfer_order_lines` (see Design Notes for columns).
- `drizzle/00NN_transfer_orders.sql` + `drizzle/meta/_journal.json` + `drizzle/meta/00NN_snapshot.json` (NEW) -- tables, status CHECK, RLS policies (NULLIF shape), plus the data migration seeding one system-owned IN_TRANSIT bin per existing warehouse (fail-fast guard, pre-flight listing).
- `src/modules/inventory/ledger-registry.ts` -- register event types `transfer.outbound` / `transfer.inbound`; extend the reference-doc union with the reserved `transfer` arm (`{kind:'transfer', transferId, lineId?}`) — additive only (:18-221 already reserves it).
- `src/modules/reservation/reservation.service.ts` -- add `inTransitUnits` beside `qcHeldUnits` (:53-81): sum of stock on system-owned IN_TRANSIT bins, subtracted in `atp` (:585-641). Fail-closed behavior identical to the other counters.
- `src/modules/tenancy/receiving-bin.ts` -- the QC-hold bin is seeded here at warehouse creation (:46 code, :150 seed, :163 lookup); seed the IN_TRANSIT bin beside it (new code constant, e.g. `IN-TRANSIT`) and reuse this seed path for new warehouses.
- `src/modules/tenancy/permissions.ts` -- add `transfers.manage` (owner, ops_manager) and `transfers.execute` (owner, ops_manager, operator).
- `src/api/movements.controller.ts` (NEW) + `src/api/api.module.ts` -- routes (below), `AnySessionGuard` for inbound-confirm (both session types — `compliance.controller.ts:51-53` precedent), `TenantSessionGuard` for the rest.
- `src/api/receiving.controller.ts:142-187` -- compose the transfer-task snapshot arm via the movements facade (the sanctioned cross-module join pattern).
- `src/modules/inventory/inventory.facade.ts` -- additive arm exposing the destination placement-gate predicate (`assertPlacementGatesInTx`) so movements reuses, not re-implements, the 12-1/12-2/12-3/12-4 + capacity gates.
- Tests: `test/movements/transfer.spec.ts` (NEW — command guards, both-warehouse chains, ATP exclusion, replay, gates, RLS probe, vocabulary pin), `test/architecture.spec.ts` (module-boundary rows for movements).

**Mobile — `wms-mobile`:**

- `src/api.ts` -- `CatalogSnapshot.transferTasks` + `CatalogTransferTask` (legacy-seal default in `src/state/catalog-snapshot.ts:49-55`), `TransferConfirmPayload` with `binStateEpoch`.
- `src/offline/types.ts` -- `OpType` += `'transfer.confirm'`.
- `src/state/op-dispatch.ts` -- sender for `transfer.confirm` (exhaustiveness guard forces it).
- `app/inbox.tsx:165-176` -- replace the Transfer placeholder with the task list + a confirm flow screen (glove-usable stepper, dest-bin scan/manual fallback per UX-DR13).
- `src/state/replay-classification.ts` -- branch on `transfer-bin-changed` → re-plannable.
- Tests for the sender + classification branch.

**FE — `wms-fe`:** none — the `/moves` surface is deferred to a follow-up story (Decision 1).

## Tasks & Acceptance

**Execution:**
- [x] `drizzle/00NN_transfer_orders.sql` (+journal+snapshot) -- tables, CHECKs, RLS, IN_TRANSIT bin seed -- schema foundation (0043)
- [x] `src/shared/db/schema.ts` -- drizzle tables -- typing
- [x] `src/modules/inventory/ledger-registry.ts` -- register both transfer event types + referenceDoc arm -- additive grammar
- [x] `src/modules/inventory/inventory.facade.ts` -- placement-gate arm -- gate reuse (`assertPlacementGatesInTx`)
- [x] `src/modules/reservation/reservation.service.ts` -- `inTransitUnits` ATP term -- the exclusion (actual path `src/modules/inventory/reservation.service.ts`)
- [x] `src/modules/movements/transfer.command.ts` (NEW) -- four commands, full skeleton -- the core
- [x] `src/modules/movements/transfer.facade.ts` (NEW) -- seam + snapshot task derivation -- module boundary
- [x] `src/modules/movements/movements.module.ts` + `movements.dto.ts` (NEW) -- wiring + DTOs -- registration
- [x] `src/api/movements.controller.ts` (NEW) + `api.module.ts` -- routes + arms -- surface
- [x] `src/api/receiving.controller.ts` -- snapshot arm -- mobile inbox feed
- [x] `src/modules/tenancy/permissions.ts` + warehouse seeding -- capabilities + IN_TRANSIT bin creation -- access + substrate
- [x] `test/movements/transfer.spec.ts` + architecture rows -- proves the matrix
- [x] Mobile: snapshot field + OpType + sender + inbox tab + confirm flow + classification branch -- FR-29
- [x] Meta: `docs/design/API-SURFACE.md`, `docs/design/modules/` movements doc, `PENDING.md`, repo contracts -- docs duty (step-05)

**Acceptance Criteria:**
- Given stock in a bin, when a transfer order is created and outbound-confirmed, then the source bin's on-hand drops, the units sit in the source warehouse's IN_TRANSIT bin, the order is `in_transit`, and the source warehouse's ATP excludes those units (an order acceptance against the same SKU cannot consume them).
- When the transfer is inbound-confirmed, then the destination bin's on-hand rises, the in-transit units drain (cross-warehouse: both chains moved atomically), the order is `completed`, and both bins' epochs bumped.
- Given the two legs, when the ledger is queried via the transfer detail read, then both legs' events appear in order, each carrying `referenceDoc {kind:'transfer', transferId}`.
- Given a device session in the destination warehouse, when the catalog snapshot loads, then in-transit transfers to that warehouse appear as `Transfer` inbox tasks, and confirming one (op ULID as Idempotency-Key) executes the inbound confirm exactly once, with an epoch mismatch answered 409 `transfer-bin-changed` and classified re-plannable.
- Given a destination bin that fails any placement gate, when inbound confirm runs, then it is refused with that gate's machine code and the order stays in_transit.
- Given `db:generate`, the answer is "No schema changes"; given the RLS probe, cross-tenant reads return nothing.

## Implementation Notes

<!-- Append-only during implementation. -->

**(2026-09-28, implementation):**

- The `context:` list names `docs/design/mobile/LLD.md`, which does not exist — the actual mobile design doc is `docs/design/mobile/IMPLEMENTATION-GUIDE.md` (the FE/BE entries were correct).
- The Code Map names `src/modules/reservation/reservation.service.ts`; the actual reservation service path is `src/modules/inventory/reservation.service.ts` (it has been under `inventory/` since the module merge).
- Inbound-confirm gate refusals answer **409** (not 400): every placement-gate refusal is a conflict-class problem (`bin-retired`, `bin-blocked`, `bin-storage-mismatch`, `bin-segregation-conflict`, `bin-occupancy-conflict`, the load gates, `transfer-bin-changed`, `transfer-wrong-state`). Catch-weight lines are refused **fail-closed at outbound confirm** (400, `validation-failed` — "a catch-weight SKU cannot be transferred", no dedicated code); the inbound confirm never sees one, and the confirm-time guard repeats the create-time check deliberately (the SKU can flip via sku.edit between the two).
- Inbound confirm is whole-quantity only: there is no partial-landing arm — the command lands every line in one tx and completes the order, so a partial receipt is a cancel + a new transfer.
- No expression index was added on `reference_doc->>'transferId'`: the ledger's transfer correlation reads ride the existing `reference_doc` GIN/index posture; the read volume (detail + list screens) does not justify a new index yet (PENDING candidate).
- System bins are refused as intake targets by the shared placement gate in `InventoryFacade` (400, `validation-failed` — "Bin is a system bin (Receiving/QC-hold/In-Transit)"); the transfer legs are the only writer that parks units in the IN-TRANSIT bin. The outbound draw refuses a system source bin the same way.
- Serial resolution on the inbound leg answers **404 `serial-unknown`** for a code the catalog does not resolve (the outbound leg's precedent), and 400 on a duplicate scan within one confirm.
- The mobile confirm flow resolves ONE landing bin per confirm and the op always carries `destBinId` (the server's scanned-bin-authoritative semantics apply it to every line); the epoch quote rides only when the chosen bin is one the task planned (redirect ⇒ null epoch, which the server treats as a match). `transferTasks` is required on `CatalogSnapshot` with the `?? []` legacy-seal default; `CatalogBin` carries no epoch on the device — the epoch comes from the task line, not a live bin read.
- `listTransfers` cursor fix (production, found by the e2e suite): list items now emit `createdAt` through `canonicalInstant()` so cursors round-trip `CURSOR_INSTANT_RE`.
- Story 5-1's two new capabilities (`transfers.manage`, `transfers.execute`) grew the vocabulary 25 → 27 and its two tables grew the RLS policy count 46 → 48 — the pinned counts in `test/users.spec.ts` and `test/client-isolation.spec.ts` were updated with the story reference.
- The `test/architecture.spec.ts` story-5-1 guard's allowlist regex was corrected to whitelist the `transfer.facade` import (the aggregate's seam) alongside the `movements.facade` legacy suffix.

## Spec Change Log

<!-- Append-only; populated by step-04. -->

**(2026-09-28, step-04 review — human-approved frozen-text amendment):** The Always bullet "Both warehouse advisory locks (cross-warehouse confirm) acquired in one deterministic order; no lock may be acquired before it" mandated advisory-first locking, which reverses the codebase's canonical acyclic order (bins-row → serial → warehouse, documented at `inventory.facade.ts:915-918` and `pick.command.ts:876`) and creates a verified deadlock window vs putaway/pick via `appendMovement`'s in-append warehouse-advisory re-acquire (`ledger.service.ts:452`). Human approved amending it to the canonical order (T1, intent_gap). The confirms re-derive under it: bin-row locks first, serial advisories, warehouse advisory last, and the inbound epoch compare moves below the locks (closing the verified TOCTOU at `transfer.command.ts:1263`).

## Review Triage Log

<!-- Append-only; populated by step-04. Sources: Blind Hunter (16), Edge-case Hunter (10), Verification-gap (5), plus one first-hand diff-audit finding; deduped to 17 root causes below. Verdicts: high / medium / low / false / maybe-false. Routes: intent_gap / bad_spec / patch / defer / reject (with reason). Cascading order: the intent_gap entry loops to the human before patching begins. Every load-bearing claim below was verified first-hand at the cited location, not trusted from the layer's report. -->

### T1 — Lock ordering: both confirms take the advisory locks FIRST, reversing the codebase's canonical order — intent_gap

- **Finding:** `confirmOutbound` and `confirmInbound` acquire the warehouse advisory lock(s) *before* the bin-row `.for('update')` locks, and `confirmInbound` additionally reads the dest-bin epochs *before* any lock (Blind #2 epoch-TOCTOU, Edge #6 deadlock, plus the step-03 audit pass).
- **Verdict: high. Route: intent_gap.** The root cause is inside the frozen block — the Always bullet "Both warehouse advisory locks (cross-warehouse confirm) acquired in one deterministic order; **no lock may be acquired before it**" mandates advisory-first, but the codebase's documented canonical order is **bins-row → serial advisory → warehouse advisory** ("putaway's documented acyclic bins-row → serial → warehouse", `inventory.facade.ts:915-918` and `pick.command.ts:876`; putaway takes the bin-row lock at `putaway.command.ts:260/:528` and only the warehouse advisory inside `appendMovement`).
- **Verified deadlock window:** `appendMovement` re-acquires the warehouse advisory inside the ledger append (`ledger.service.ts:452`, a no-op re-acquire for advisory-first callers). A putaway/pick holding the bin-row lock on a shared bin then blocking on the warehouse advisory inside `appendMovement`, while a transfer confirm holds the warehouse advisory and blocks on the bin-row, forms a cycle — one command aborts as 500. Also verified: putaway itself never takes an advisory before its append, so the Edge #6 "putaway takes advisory first" alternative is refuted — the reversal is on the transfer side.
- **Verified TOCTOU half:** the epoch read sits at `transfer.command.ts:1263`, before the warehouse locks at `:1287/:1293`, contradicting the adjacent "locks come FIRST" comment; a concurrent epoch-bumping write between read and lock slips past the staleness gate.
- **Human resolution required** (frozen text) — **Resolved 2026-09-28: human approved amending the bullet to the canonical order** (bins-row → serial → warehouse, sorted). Route after resolution: patch (T1 re-derivation).

### T2 — Inbound confirm derives serial arms per SKU, not per line

- **Verdict: high. Route: patch.** (Step-03 audit + Blind #1 + Edge #1 — three independent detections.) `transferOutboundSerialArmsInTx` groups the outbound events' serial refs `bySku`; `confirmInbound` looks arms up as `outboundSerialArms.get(line.skuId)`. Create permits two lines of the same serial-tracked SKU, so each line's inbound leg replays *both* lines' serials — the second line's drain hits serials already drained, the append guard refuses mid-tx, and the order is permanently stuck in_transit with a misleading 422. Fix: derive per-line refs from `referenceDoc->>'lineId' = line.id`.

### T3 — Inbound confirm never re-checks kit/catch-weight after `sku.edit`

- **Verdict: high. Route: patch.** (Edge #3.) Outbound confirm refuses kit/catch-weight SKUs fail-closed, and the implementation notes rely on that — but the SKU can flip between the two confirms. The landing write then parks unrepresentable catch-weight or kit stock, the exact thing the outbound guard exists to prevent. Fix: re-read the SKUs in `confirmInbound` and repeat the `kit-cannot-hold-stock` / catch-weight refusals (outbound's own rationale, stated in the notes).

### T4 — Hazard gate never checks the moving SKUs against each other

- **Verdict: high. Route: patch.** (Blind #3 + Edge #4.) `assertPlacementGatesInTx` compares each moving SKU only against the bin's *existing* occupants; the `skuIds.includes(occupant.skuId)` skip (`inventory.facade.ts:1540-1556`) lets two mutually segregated SKUs co-land in one bin within a single inbound confirm. No prior writer could create that pair in one tx — the transfer is the first. Fix: pairwise `hazardClassesCompatible` across the moving `skuIds` themselves after the occupants loop.

### T5 — Migration 0043 breaks on user-created `IN-TRANSIT` master data

- **Verdict: high. Route: patch.** (Blind #4.) Bin/zone codes are user-chosen (`CreateBinDto` code is `@Length(1,32)` with no pattern, `tenancy.dto.ts:367`). A pre-existing user bin coded `IN-TRANSIT` makes the bin insert a no-op and trips the fail-fast post-assertion, failing the migration for every tenant; afterwards `ensureInTransitBinInTx` throws an untyped `Error` (500) on every transfer for that warehouse. No remediation path named in either place. Fix: a migration pre-flight that fails fast naming the offending warehouses + the remediation (rename or retire the user bin), and a typed `ProblemException` from the ensure path.

### T6 — False "seeded at warehouse creation" comments (lazy-ensure is the actual pattern)

- **Verdict: low. Route: patch (comments only).** (Edge #10 claim, resolved differently than filed.) First-hand grep: `ensureQcHoldBinInTx` is called *only* from `qc.command.ts:388/:628` — warehouse creation seeds **neither** system bin; lazy-ensure at first use is the established QC-hold precedent, and the transfer implementation correctly follows it. The defect is documentation, not wiring: `receiving-bin.ts` and migration 0043's comment say the IN-TRANSIT bin is created "at warehouse creation … beside `ensureQcHoldBinInTx`", which describes wiring that does not exist. Fix: correct both comments (and the spec's Code Map line); no new call sites.

### T7 — `@ValidateNested` missing on the nested line DTOs

- **Verdict: high. Route: patch.** (Blind #7.) `movements.dto.ts` carries `@Type(() => …)` on `CreateTransferDto.lines` / `ConfirmOutboundDto.lines` but zero `@ValidateNested` — under the global ValidationPipe the per-field constraints on `TransferLineDto` / `ConfirmOutboundLineDto` (`@IsUUID`, `@Min`, serial `@Length(1,64)`) never run; malformed line payloads reach the command layer or DB casts. Fix: `@ValidateNested({ each: true })` on both arrays.

### T8 — Serial-tracked fractional quantity accepted at create, unconfirmable at outbound

- **Verdict: high. Route: patch.** (Blind #8.) Create validates only the SKU's UoM precision, so a serial-tracked line of 1.5 units drafts fine and then always fails the integer unit-count check at outbound confirm — the guard belongs at create where the draft can be corrected.

### T9 — Serial-tracked line > 200 units drafted, never scannable

- **Verdict: medium. Route: patch.** (Edge #7.) Serials are capped at 200 per confirm (`movements.dto.ts:123`, `@ArrayMaxSize(200)`), but create doesn't cap the line quantity — a 201-unit serial line drafts and can never supply enough scans. Fix: at create, refuse a serial-tracked line whose base units exceed 200.

### T10 — Mobile replay classifies every gate refusal terminal except `transfer-bin-changed`

- **Verdict: high. Route: patch.** (Blind #9 + Edge #8.) `replay-classification.ts:49-53` re-plans only `transfer-bin-changed`; gate refusals (`bin-blocked`, `bin-full`, `bin-overweight`, `bin-storage-mismatch`, `bin-segregation-conflict`, `bin-occupancy-conflict`, `bin-retired`, …) leave the order in_transit and are re-plannable by re-scanning a landing bin — the same shape as `pick-bin-short`, which *is* re-plannable. Unpatched, a queued offline confirm dies and the op is **dropped from the durable outbox** (verified: `engine.ts:114-125` removes 'rejected' ops). Fix: classify the gate-409 family re-plannable.

### T11 — Mobile task lines hardcode 0-decimal quantity rendering

- **Verdict: low. Route: patch.** (Blind #10.) `app/transfer.tsx` renders `formatQuantity(line.qty, 0)`; a fractional transfer quantity (legal under the milli-unit model) displays truncated. Sibling cards derive decimals from the value. Fix: derived precision like the siblings.

### T12 — Dead `replayPrior*Snapshot` methods

- **Verdict: low. Route: patch.** (Blind #12.) The four `replayPrior*Snapshot` methods on `TransferService` have no call site — each command does its own replay lookup inside its transaction. Fix: delete them.

### T13 — `committedCeiling` comment inverted vs the code

- **Verdict: low. Route: patch (comment).** (Blind #14.) `reservation.service.ts:1093-1100`: comment says parked units "must be unsubtracted here"; the code *adds* `inTransit` to the subtraction (`onHand - qcHeld - inTransit - bufferUnits()`). Code correct, wording inverts it.

### T14 — Detail-read event ordering contradicts its own comment

- **Verdict: low. Route: patch (comment).** (Blind #5.) `transferLegEventsInTx` orders by `warehouseId` uuid then seq; the facade comment claims "source chain first, then dest". For any transfer whose dest warehouse uuid sorts before its source, the intake leg presents before the drain leg. Ordering is deterministic — the claim is what's false.

### T15 — Verification gaps on exactly the new surfaces

- **V1 device-session arm of inbound-confirm never exercised — Verdict: high. Route: patch.** All 11 inbound-confirm calls in the suite use the web-family `operatorToken`; if `AnySessionGuard` were mis-wired or the badge-in null-operator check inverted, every device Transfer confirm fails in the field with the suite green (the suite's own header comment concedes the gap). Add: inbound-confirm via the device badge-in token (200, completed) + a bare-credential 401 arm, mirroring `putaway.spec.ts:892` / `picking.spec.ts:2221`.
- **V2 `committedCeiling` in-transit subtraction unpinned at its grant consumers — Verdict: high. Route: patch.** No grant in any suite coexists with in-transit stock; deleting the `inTransit` term would leave everything green while an acceptance grant reserves parked units (oversell). Add: a grant attempt after outbound confirm refusing with 409 naming the in-transit units (also pins the new `reservation.service.ts:397` message arm).
- **V3 stock-adjust IN-TRANSIT refusal untested — Verdict: medium. Route: patch.** Reverting the added guard condition leaves the suite green and lets an adjustment strand ATP-excluded stock in the IN-TRANSIT bin. Add: adjustment against the IN-TRANSIT (or QC-hold) bin answers the refusal.
- **V4 inbound-confirm replay untested — Verdict: medium. Route: patch.** Replay is pinned on create + outbound confirm only — never on the exact retry path the device op depends on. Add: same key + same payload replays the stored snapshot.
- **V5 `transfer_order_lines` RLS policy unpinned — Verdict: medium. Route: patch.** The other new table's policy rides the suite's RLS probe; the lines table is never probed cross-tenant. Add: a probe row.
- **V6 secure-bin 403 arm unpinned — Verdict: low. Route: patch.** The spec's matrix grants secure-authority refusal 403 but only `bin-blocked` (409) is exercised via a transfer. Add: one secure-dest-bin confirm without `secure.move` answering 403.

### Deferred (root cause outside this story's fix scope or accepted as known debt)

- **D1 — Snapshot truncation signal computed then dropped. Verdict: medium. Route: defer.** (Blind #11.) `getTransferTasksInTx` over-reads `MAX_SNAPSHOT_TRANSFER_TASKS + 1` precisely to learn truncation, then slices and drops the signal. Verified this matches the `pick` precedent (`pick.command.ts:1686-1688`, same over-read, same dropped signal) — fixing it here means a snapshot-shape change with no consumer; it belongs with the FE `/moves` surface follow-up. → PENDING.md.
- **D2 — Migration seed statements never exercised in CI. Verdict: low. Route: defer.** The 0043 data-migration inserts run only under a real `db:migrate`; the test suite's migrate step exercised them once on this machine, and the post-assertion verifies the result at run time — no test can pin a data migration beyond that. Accepted; the pre-flight from T5 tightens it.

### Rejected (false, precedent-matching, or out of scope)

- **R1 — Fingerprint gap `lines: []` ≠ `lines` absent. Verdict: false.** (Blind #6.) `outboundFingerprint` maps `(command.lines ?? []).map(...)` — an absent field and an empty array hash identically; the cited 422 cannot fire.
- **R2 — BigInt RangeError on large bin dims. Verdict: false.** (Edge #5.) Bin dimensions are integer columns (`schema.ts:311-313`/`458-460`); the integer product at `inventory.facade.ts:1614` cannot be a non-integer, and the column ranges keep the product within exact float range — `BigInt()` cannot throw there.
- **R3 — `cancelTransfer` ignores business time. Verdict: low / reject.** (Blind #13.) True as stated, but no cancel surface carries `occurredAt` and draft-only cancel has no business-time semantics; in-transit cancellation (where timing would matter) is frozen-deferred (Decision 3). Fold into that follow-up.
- **R4 — stock.adjust IN-TRANSIT refusal reuses `qc-bin-not-adjustable`. Verdict: reject.** (Edge #9.) True as stated but deliberate: the guard is one shared system-bin check; a new machine code is a new error surface for clients, and the detail read distinguishes bins by code. Revisit only if a consumer needs to branch on it.
- **R5 — No wms-fe surface. Verdict: out of scope.** (Blind #16.) Frozen Decision 1 records this exactly; the FE drift-guard failure until the FE story merges is the known cross-repo pattern, and the `/moves` follow-up is already in `deferred-work.md`.

## Design Notes

**In-transit representation — a system-owned IN_TRANSIT bin per warehouse** (QC-hold precedent, `reservation.service.ts:53-81`): the outbound leg physically moves units into it, so the serial-in-exactly-one-bin invariant survives, and ATP exclusion is one subtraction term (`inTransitUnits`) beside `qcHeldUnits` — exclusion is structural, not a new state flag. Source-side exclusion is automatic (units left the source bin); destination-side automatic (units arrive only at inbound confirm). Alternatives rejected: units-in-limbo (breaks the serial invariant), `inventory_quarantines` rows (pollutes the quarantine lifecycle/surface with transfer semantics).

**Event shape.** Every leg writes its own events (the epic AC), correlated by `referenceDoc {kind:'transfer', transferId}`:
- outbound confirm: per line-arm, one event on the SOURCE chain, `fromBinId` = source bin, `toBinId` = source IN_TRANSIT bin.
- inbound confirm, same warehouse: one event per arm, IN_TRANSIT bin → dest bin (one chain).
- inbound confirm, cross-warehouse: per arm, (a) a drain event on the SOURCE chain (`fromBinId` = source IN_TRANSIT bin, `toBinId` = null — the `pick.picked` pure-draw precedent) and (b) an intake event on the DESTINATION chain (`toBinId` = dest bin), in ONE transaction. Deterministic lock order: acquire the two warehouse advisory locks sorted by warehouse uuid (the `lockSerialsInTx` sorted-order rule generalized), then bin-row locks sorted by bin uuid.

**Tables.** `transfer_orders` (id, tenant_id, source_warehouse_id, dest_warehouse_id, status `draft|in_transit|completed|cancelled`, note, created_by, timestamps, keyset cursor) and `transfer_order_lines` (transfer_id, sku_id, quantity_milli, from_bin_id, to_bin_id, batch_ref, note). Statuses as a three-layer vocabulary (TS tuple + CHECK + `@IsIn`).

**Gates at inbound confirm** are the placement gate set via an additive `InventoryFacade` arm — a transfer is a new stock writer of the adjustment shape, and PENDING.md's five `stock.adjust` bypass entries are exactly what this story must not replicate. Secure-bin authority: the confirm actor must hold `secure.move` for secure dest bins.

**Mobile op.** `transfer.confirm` carries `{transferId, binStateEpoch (dest bin), occurredAt}`; the task read captures the epoch on the same tx as the task (pick precedent, `pick.command.ts:1708-1717`). New machine code `transfer-bin-changed` is re-plannable; the client's `classifyReplayFailure` gains the branch.

## Verification

**Commands (wms-be):**
- `bun run test -- test/movements/transfer.spec.ts` -- expected: green
- `bun run test && bun run lint && bun run typecheck && bun run build` -- expected: green
- `bun run db:migrate && bun run db:verify` -- expected: green
- `bun run db:generate` -- expected: "No schema changes"

**Commands (wms-mobile):** `bun run lint && bun run typecheck && bun run test` (or the repo's suite command) -- expected: green

**Manual:**
- Seed a warehouse→warehouse transfer through real HTTP: confirm ATP excludes in-transit units mid-transfer, and that the mobile snapshot lists the task.