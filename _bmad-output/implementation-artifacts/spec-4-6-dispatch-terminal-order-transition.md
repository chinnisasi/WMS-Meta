---
title: 'Story 4.6: Dispatch — the terminal order transition'
type: 'feature'
created: '2026-09-15'
status: 'done'
route: 'dispatch'
review_loop_iteration: 1
baseline_commit: 'c09d5e9' # wms-be main
context:
  - '_bmad-output/implementation-artifacts/epic-4-context.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** A packed order has nowhere left to go. It sits `ready_to_dispatch` forever, nothing records that it shipped, and — verified against the live stack — **its reserved units are double-deducted from ATP permanently**: the units leave `stock_on_hand` at pick, but the hold commits and no transition ever retires it from the reserved counter, so ATP reads 80 where it should read 90. `reservation.service.ts:219` and `schema.ts:893` both promise this ends "at Epic 4's dispatch movement". This is that story, and the epic has none after it.

**Approach:** A dispatch command closes the order: the status flips to a new `dispatched` arm, one zero-quantity ledger event per order line records the shipment, and every `committed` hold the order owns is retired to `released` — restoring the reserved counter and correcting ATP. All in one transaction.

**Decided (2026-09-15, human):**
- **The ATP retirement happens at dispatch, not at pick.** ATP stays understated for the pick→dispatch window, accepted deliberately: the alternative edits the pick path 4.3/4.4 built and 4.5 depends on, and changes what `committed` means in the counter rebuild. Dispatch is where the architecture put it.
- **Dispatch records an optional free-text `carrierName` and `trackingNumber`** on the event's reference doc — the same place 4.5 put weight and dimensions. An operator shipping by a manual courier can record it today, so dispatch is usable before the carrier arc. Absent is never an error. The carrier stories replace free text with a real carrier id and an adapter-issued tracking number; these fields are their migration target.
- **Carrier rating, the `CarrierAdapter` port, labels, manifests and tracking writeback are OUT** — split to `4-6b`/`4-6c` at the scope gate, each recorded in `deferred-work.md`. OQ1 (the carrier set) stays open and is decided at the adapter story, not here.
- **Backend only.** The dispatch surface rides `4-2b` with the rest of Outbound — the 4.1/4.2/4.3/4.5 shape.

**Decided (technical, from investigation):**
- **A `committed` hold retires to `released`, and no new reservation state is added.** `schema.ts:889-894` already declares the lifecycle `held → committed → released/expired`, so this is the documented exit, not an invention. The counter rebuild (`state in ('held','committed')`) then excludes it with no change, and `restoreCounter` already handles the decrement. What distinguishes "shipped" from "cancelled" is the order's status and the ledger, never the hold's state.
- **The dispatch event can only carry quantity 0.** Units left `stock_on_hand` at pick — `pick.picked` is a pure draw with `toBinId: null` — so there is nothing to move. One event per order line with `quantityDelta: 0` and both bin arms null, mirroring `pack.packed`, because `LedgerMovement` requires a non-null `skuId`.
- **"Dispatch closes the reservation" cannot mean a `held` hold.** None survives pack: picking commits them and 4.5's pack releases the stragglers. `commitInTx`/`releaseInTx` are conditional on `state = 'held'` and throw 409 on a zero rowcount, so a naive close would roll the whole dispatch back.

## Boundaries & Constraints

**Always:**
- The status flip, the ledger events, the hold retirements, the outbox event, the audit row and the idempotency key **commit in one transaction**. The Valkey counter restore is applied **after** the commit, per 4.4's journal-first ordering — a decrement that outlived a rollback would read as ATP the journal still holds.
- Each hold retirement is a conditional update `WHERE state = 'committed'`, preserving AD-12's exactly-one-terminal-transition: exactly one dispatch wins and a second is a deterministic conflict. **Cancel-vs-dispatch double-release stays impossible.**
- `ORDER_STATUSES` gains `dispatched` additively, with the DB CHECK dropped and re-added per the 0023 precedent. **Every guard reading an order status must be audited** — the 4.5 review found a deny-list that would have corrupted data, and the same class of bug is the risk here.
- **`pick.command.ts:604` must learn the new arm.** Its terminal classification is an explicit two-arm list (`cancelled || ready_to_dispatch`); a `dispatched` order falls through to a *retryable* `conflict` instead of `pick-unresolvable`, so a queued device pick would retry forever instead of quarantining. This is an AD-14 taxonomy defect, not a cosmetic one.
- Dispatch is refused unless the order is `ready_to_dispatch`, and refused if already dispatched — an order dispatches once.
- A `dispatch.execute` capability gates the command (Owner + Ops Manager + Operator), mirroring `pack.execute`. The FE mirror rides `4-2b` with the other four.
- The command carries an `Idempotency-Key` with payload-hash replay, re-reads the member role at entry, and emits `order.dispatched` to the outbox plus an audit row.

**Never:**
- No carrier adapter, rating, label, manifest or tracking writeback.
- No new reservation state and no `reservations` migration — `released` is the documented exit.
- No un-dispatch, no return, no re-open. `dispatched` is terminal.
- No backfill of orders already picked before this ships — their counters correct themselves when they dispatch, and a bulk rewrite of live reserved counters is a separate, riskier change.
- No web or mobile surface (`4-2b`); no change to the pick or pack paths beyond the terminal-classification fix above.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Dispatch a packed order | order `ready_to_dispatch` | `201`; one zero-quantity `dispatch.dispatched` event per order line, order `dispatched`, outbox + audit | N/A |
| ATP recovers | a fully-picked order's `committed` hold | reserved drops by the hold's quantity, ATP rises to `onHand`; hold reads `released` | N/A |
| With carrier and tracking | optional free-text strings | `201`; both carried on the reference doc | over-long or non-string → `400 validation-failed` |
| Order not packed | order `accepted` | nothing written | `409` naming the status |
| Already dispatched | order `dispatched` | replay under the same key re-serves the snapshot; a new key is refused | `409` |
| Cancelled order | order `cancelled` | nothing written | `409` |
| Dispatched order re-waved, re-picked, packed or cancelled | any of those against it | wave selection excludes it; pack and cancel refuse it | the queued pick is **terminal** (`pick-unresolvable`), never retryable |
| Partially short-picked order | some lines `short`, none `planned` | `201`; only the `committed` holds retire, already-`released` ones are untouched | N/A |
| Wrong authority | caller lacks `dispatch.execute`, or a foreign tenant | nothing written | `403 role-denied` / `permission-denied` |

</frozen-after-approval>

## Code Map

- `workspace/core/backend/wms-be/src/modules/outbound/pack.command.ts` — **the template to copy.** Its shape in order: `hashCommandPayload` (normalize collections first), `withTenantTransaction` whose callback *returns* post-commit work, `assertPermission(await getMemberRoleIn(...))`, `replay()`, the order row lock `.for('update')`, **`replay()` re-run under the lock** (the same-key race fix), the guards, the conditional flip `.where(eq(orders.status, ...)).returning()`, `appendLedgerEventInTx` per line with an annotated `const referenceDoc: LedgerReferenceDoc`, the hold reads/releases at `:480-491`, `outbox.append`, the `auditEvents` insert, `writeIdempotencyKey`, then the post-commit `restoreReservedUnits`. Error helpers `packConflict`/`packValidation`/`namedSample` at `:734-750`.
- `workspace/core/backend/wms-be/src/modules/outbound/order.command.ts:44` — `ORDER_STATUSES`. Cancel's guards at `:482`/`:499`/`:584`/`:616` already refuse a non-`accepted` order, so `dispatched` is refused for free — verify, do not rewrite.
- `workspace/core/backend/wms-be/src/modules/outbound/pick.command.ts:604` — **the one real defect.** `const terminal = status === 'cancelled' || status === 'ready_to_dispatch'` needs `dispatched`. The `else` at `:615-620` is the retryable arm; its comment calls itself "forward-looking for 4.6", which is backwards.
- `workspace/core/backend/wms-be/src/modules/outbound/wave.command.ts:763, :927, :1011, :1044` — all four are already allow-lists after 4.5. **No change needed**; confirm and leave alone.
- `workspace/core/backend/wms-be/drizzle/0023_packed_order_arm.sql:19-20` — the exact drop-then-re-add pattern for `orders_status_check`. Note the **hand-named** file and the manual `drizzle/meta/_journal.json` entry (idx 24 next). CHECKs and RLS live only in migration SQL, never `schema.ts`.
- `workspace/core/backend/wms-be/src/modules/inventory/reservation.service.ts:487-528` (`commitInTx`), `:1247-1288` (`releaseInTx`), `:943` (`restoreCounter`), `:775-790` (the rebuild's `state in ('held','committed')` sum). A new in-tx retirement conditional on `state = 'committed'` belongs beside these.
- `workspace/core/backend/wms-be/src/modules/inventory/inventory.facade.ts` — the AD-6 seam. Existing passthroughs: `appendLedgerEventInTx` `:241`, `commitReservationInTx` `:508`, `releaseReservationInTx` `:530`, `restoreReservedUnits` `:565`, `heldReservationsByOwnerInTx` `:610`. The new retirement needs one more, in the same shape.
- `workspace/core/backend/wms-be/src/modules/inventory/ledger-registry.ts:159` (`registerLedgerEventType`), `:301-307` (how `pack.packed` registered), `:123-136` (the reference-doc union — its trailing comment **reserves `dispatch` by name**).
- `workspace/core/backend/wms-be/src/modules/tenancy/permissions.ts:70, :85, :104, :106` — `pack.execute` and its role grants; `dispatch.execute` mirrors it exactly.
- `workspace/core/backend/wms-be/test/architecture.spec.ts:98, :116, :147, :291` — forbids writes to inventory-owned tables outside `src/modules/inventory` and imports past the facade. It asserts per-command that `pick.command.ts` writes none of `['stockOnHand','batchOnHand','ledgerEvents','reservations']`; **a dispatch command needs the same new assertion**. A scoped test run missed this boundary last story — run the full suite.
- `workspace/core/backend/wms-be/test/packing.spec.ts:412` (`pickedOrder`), `:398` (`packOrder`), `:433` (`atp`), `:438` (`holdsOfOrder`), `:496` (the drift guard) — `pickedOrder` + `packOrder` is the two-call route to `ready_to_dispatch`. **`:497` hardcodes the three-arm tuple and will fail on a fourth.** The parity guards at `:502-506` and `orders.spec.ts:906-920` already use `/'([a-z_]+)'/g` and need no widening.

## Tasks & Acceptance

**Execution:**
- [x] `wms-be drizzle/0024_*.sql` + `drizzle/meta/_journal.json` — drop and re-add `orders_status_check` with `dispatched`; hand-written journal entry
- [x] `wms-be src/modules/outbound/order.command.ts` — the new status arm
- [x] `wms-be src/modules/inventory/reservation.service.ts` + `inventory.facade.ts` — the in-tx `committed → released` retirement and its facade passthrough
- [x] `wms-be src/modules/inventory/ledger-registry.ts` — the `dispatch` reference-doc arm and `dispatch.dispatched` registration
- [x] `wms-be src/modules/outbound/dispatch.command.ts` — the command: guards, ledger events, hold retirements, status flip, post-commit counter restore
- [x] `wms-be src/modules/tenancy/permissions.ts` — `dispatch.execute`
- [x] `wms-be src/api/outbound.controller.ts` + `outbound.dto.ts` — `POST .../orders/{orderId}/dispatch`, the status enums, OpenAPI
- [x] `wms-be src/modules/outbound/pick.command.ts:604` — add `dispatched` to the terminal classification
- [x] `wms-be test/dispatch.spec.ts` — the matrix e2e, including the ATP recovery assertion
- [x] `wms-be test/packing.spec.ts:497` + `test/architecture.spec.ts` — the four-arm tuple; the dispatch-command boundary assertion
- [x] `wms-be bun run openapi:export` + `wms-fe bun run api:generate`

**Acceptance Criteria:**
- Given a `ready_to_dispatch` order, when it is dispatched, then one `dispatch.dispatched` event is written per order line and the order reads `dispatched`
- Given a fully-picked order whose hold is `committed`, when it is dispatched, then the hold reads `released`, the reserved counter drops by its quantity, and ATP equals on-hand
- Given a dispatched order, when a queued pick targets it, then the refusal is **terminal** (`pick-unresolvable`), not retryable
- Given a dispatched order, when wave generation runs or a cancel or pack is attempted, then it is excluded or refused and nothing is written

## Implementation Notes

**Landed (wms-be, backend only — no FE/mobile surface beyond `api:generate`).**

- `drizzle/0024_dispatched_order_arm.sql` + a hand-written `_journal.json` entry (idx 24): drop-then-re-add `orders_status_check` with `dispatched`, per the 0023 precedent. `ORDER_STATUSES` becomes the four-arm lifecycle tuple `accepted → ready_to_dispatch → dispatched`, plus `cancelled`.
- `reservation.service.ts` gains `retireCommittedInTx` (`committed → released`, conditional on `state = 'committed'`) and `committedReservationsByOwnerInTx`. Both share a body with their `held` siblings via two new private helpers (`releaseFromStateInTx`, `ownedReservationsInTx`) rather than being copied — the `held` paths are unchanged in behaviour, and the only visible difference is the 409 title, which now names the source state. Facade passthroughs: `retireCommittedReservationInTx`, `committedReservationsByOwnerInTx`.
- `ledger-registry.ts`: the `dispatch` reference-doc arm (`orderId`, `orderLineId`, `dispatchedQty`, optional `carrierName` / `trackingNumber`) and `dispatch.dispatched`, `sinceVersion: 1`, both identity arms CLOSED (the `pack.packed` precedent — a dispatch re-counts nothing; `pick.picked` already carries the batch/serial identity).
- `dispatch.command.ts` is the `pack.command.ts` shape in order: normalize-then-hash, `withTenantTransaction` returning post-commit work, `assertPermission(await getMemberRoleIn(...))`, `replay()`, the order row lock, `replay()` re-run under the lock (the same-key race fix), the status guards, the conditional flip, one annotated `LedgerReferenceDoc` + `appendLedgerEventInTx` per order line, the owner-keyed committed-hold read and retirement, `outbox.append`, the audit row, `writeIdempotencyKey`, then the post-commit `restoreReservedUnits`.
- `permissions.ts`: `dispatch.execute` for Owner + Ops Manager + Operator, mirroring `pack.execute`. `POST .../orders/{orderId}/dispatch` on the outbound controller with `DispatchOrderDto` / `DispatchResponse`; `openapi.json` re-exported and `wms-fe`'s client regenerated.
- `pick.command.ts:604` — the one real defect — now classifies `dispatched` as terminal with its own true reason ("it has shipped"), so a queued device pick quarantines (`pick-unresolvable`) instead of retrying a dead op forever.

**Decisions taken inside the spec's boundaries.**

- `dispatchedQty` rides the reference doc beside the carrier arms, mirroring `pack`'s `packedQty` — it is the per-line record of what actually shipped, on an event whose `quantityDelta` is necessarily 0.
- The snapshot carries `retiredReservationIds`, which is what makes the ATP correction assertable from the response rather than only from the journal.
- Carrier and tracking are trimmed and normalized BEFORE the payload hash (the `aggregateScan` precedent), so absent / `null` / blank / whitespace-padded are one intent and replay rather than colliding as `idempotency-key-reuse`. Bound: 200 characters each (the `MAX_EXTERNAL_EVENT_ID_LENGTH` precedent) — the ledger is append-only, so an unbounded caller-controlled string is permanent.
- No `reservations` migration and therefore no index for the `committed` owner read: `reservations_open_owner_scope_unique` is partial on `held`, so the read narrows on `reservations_tenant_state_expires_at_idx` and filters one order's line set on top.

**Audit of every order-status guard (the frozen "Always" clause).** `order.command.ts:482/499/584`, `pack.command.ts:234/255/378` and `wave.command.ts:763/927/990/1044` are all allow-lists on `accepted` (or on `cancelled` for wave-line withdrawal), so `dispatched` is refused or excluded with no edit — each confirmed by an e2e assertion rather than by reading. `pick.command.ts:604` was the sole deny-list-shaped classification and is the only guard changed.

**Not done, deliberately.** No carrier adapter, rating, label, manifest or tracking writeback (`4-6b` / `4-6c`). No new reservation state, no un-dispatch, no backfill of orders picked before this shipped. No web or mobile surface — the dispatch command rides `4-2b` with the other four.

## Spec Change Log

## Review Triage Log

**Loop 1 — three layers (blind hunter 13, edge-case 3, verification-gap 4). 20 findings, all verified at their cited
locations: 10 patched, 6 rejected on refutation, 4 deferred. No `intent_gap` and no `bad_spec` — no loopback.**

| # | Finding | Layer | Verdict | Evidence |
|---|---------|-------|---------|----------|
| 1 | Cancel and dispatch produce IDENTICAL payload hashes for one order, so a key reused across them replays the wrong command's snapshot | edge | **high — patch** | Confirmed by execution: `JSON.stringify` drops `undefined`, so dispatch's `{tenantId, orderId, carrierName: undefined, trackingNumber: undefined}` serializes byte-identically to cancel's `{tenantId, orderId}` — both hash to `c148aa36…`. `replay()` runs before the order-status guard, so the hash check that exists to catch this passes and the caller gets the other command's snapshot |
| 2 | The post-commit counter mirror is unguarded — a throw returns 500 for a dispatch that COMMITTED and skips every later SKU | edge | **high — patch** | Confirmed at `dispatch.command.ts:434-443`: a bare `await` loop. A replay then serves the stored snapshot without re-attempting the mirror, so ATP stays understated — the exact defect this story exists to fix. `order.command.ts` phase 4 states the precedent outright: "Nothing here may throw" |
| 3 | The retirement loop is only ever exercised with ONE committed hold | v-gap | **high — patch** | Pre-verified by mutation: retiring only `committedHolds[0]` passes the whole suite. The two-line fixture short-picks one line deliberately, so only one hold is `committed` at dispatch. A multi-line order would leave holds unretired forever — `expireDue` sweeps `held` only |
| 4 | `dispatchedQty`'s `sum(picks.qty)` never sees a multi-slice line | v-gap | **medium — patch** | Pre-verified: every fixture seeds one bin per line, so the `GROUP BY` is indistinguishable from reading one row. `packing.spec.ts:972` has the twin test for pack and never dispatches that order. A two-bin line would write an understated quantity into the append-only ledger |
| 5 | Migration 0024 ships with no `drizzle/meta/0024_snapshot.json` | v-gap | **medium — patch** | Confirmed independently: journal carries `idx: 24`, snapshots stop at 0023. Mechanism verified — 0022 and 0023 snapshot bodies are byte-identical apart from `id`/`prevId` (the CHECK lives only in migration SQL), so 4.5 did ship one. Nothing catches it: `db:migrate` reads journal + SQL only, `db:verify` round-trips one row, so CI stays green and the next `db:generate` breaks |
| 6 | The terminal classification stays a hand-maintained list, so the NEXT status arm silently becomes retryable again | blind | **medium — patch** | Real named harm: this is the precise defect 4.6 just fixed, and nothing makes its recurrence a compile error. (The claim that the `else` comment over-promises is **false** — it says "today that is none".) |
| 7 | No ledger chain or projection-replay verification after a dispatch | blind | **medium — patch** | `packing.spec.ts:672-678` does exactly this after its zero-quantity events, on the stated reasoning that a zero-magnitude event with no bin arm must not make the ledger's invariants disagree with it. `dispatch.dispatched` is the second such type and gets no equivalent |
| 8 | A blank `carrierName`/`trackingNumber` is documented as "absent" but never tested | v-gap | **medium — patch** | Pre-verified: the DTO's `@Length(0, MAX)` admits `''`; deleting the blank-to-null branch breaks replay with a 422 and persists `""` into the append-only reference doc, with no test failing |
| 9 | `retiredReservationIds` declares `items: {type: string}` while every sibling id carries `format: uuid` | blind | **low — patch** | Confirmed in the emitted OpenAPI; fix is a direct correction to a shipped contract |
| 10 | The documented `400` arms and the `409 Concurrent idempotent request` path are untested; `expect(skuId).toBeDefined()` is filler | blind | **low — patch** | Confirmed against `dispatch.spec.ts`; all are direct additions/deletions |
| 11 | Input validation runs before authorization, so a caller lacking `dispatch.execute` gets 400 rather than 403 | blind | **false** | `outbound.dto.ts:30` imports the SAME `MAX_*` constants and `@Length(0, MAX)` fires in the global pipe *before* the controller runs — an over-long value is 400 regardless of where `assertText` sits. The ordering window is unreachable over HTTP |
| 12 | `shortfallQty` is unclamped and can be persisted negative | blind | **false** | Over-pick is refused per picklist line, and a line's slices sum to at most its planned quantity, so `line.qty - dispatchedQty` cannot go negative. Edge-case traced this independently and reached the same conclusion |
| 13 | The advisory-lock comment is false when the append loop does not run | blind | **false** | Requires a line-less order. `CreateOrderDto` enforces `ArrayMinSize(1)` and `assertLines` re-checks, so `lines.length >= 1` always and the lock is always taken. The `skuIds.length === 0` branch guards an unreachable state |
| 14 | Reservation-layer `404`/`409` outcomes are undocumented on an order-shaped endpoint | blind | **low — rejected** | Unreachable: `committed → released` has no competing writer — `expireDue` is `held`-only, cancel refuses non-`accepted`, and both commit paths are `held → committed`. The holds are read and retired inside one transaction under the order row lock |
| 15 | Third hardcoded copy of the `ORDER_STATUSES` drift guard | blind | **low — rejected** | The hardcoded tuples are deliberate tripwires that force a conscious edit per new arm; `orders.spec.ts` already carries the generic comparison. Deleting them removes the safety net rather than the duplication's cause |
| 16 | The spec's Intent says "all in one transaction" while the Valkey mirror is post-commit | edge (claim) | **low — rejected** | The fix would edit this build's spec, which triage rejects. The Boundaries section already states the post-commit ordering precisely and the code follows it; the Intent sentence is a summary, not the contract |
| 17 | No read-back path for the dispatch record — tracking lives only in `ledger_events.reference_doc` | blind | **defer** | Real gap, but the surface belongs to `4-2b`/the carrier arc |
| 18 | A short shipment leaves no queryable trace and schedules no backorder follow-on | blind | **defer** | `order_lines.status` keeps its acceptance-time reservation arm; pre-existing shape, not caused by this change |
| 19 | A packed-but-abandoned order understates ATP indefinitely — dispatch is the only `committed → released` writer | blind | **defer** | Real. The frozen block accepted the pick→dispatch window; an order never dispatched makes that window unbounded, which the decision did not contemplate |
| 20 | Ninth verbatim copy of the idempotency scaffolding across command files | blind | **defer** | Pre-existing across 9 files; a shared helper is its own change |

## Design Notes

**Why `released` and not a new reservation state.** `schema.ts:889-894` declares the lifecycle `held → committed → released/expired` and says in as many words that `committed` units "stay deducted until the consuming ledger movement (Epic 4's dispatch)". Retiring to `released` is therefore the documented exit, costs no migration, and needs no change to the counter rebuild — which already sums only `held` and `committed`. A new `dispatched` hold state would have to be taught to the CHECK, the rebuild, the DTOs and every exhaustive reader, to record a distinction the order's own status already carries.

**Why the ATP bug survived this long.** The rebuild sums `state in ('held','committed')`, which faithfully reproduces the same wrong number the live counter holds. The bug is self-consistent rather than a divergence, so every parity assertion in the suite passes while ATP is wrong. Verified directly: seed 100, accept 10 → ATP 90 (correct), full pick → on-hand 90, reserved 10, **ATP 80**. The dispatch e2e must assert the recovered value, not parity.

## Verification

**Commands:**
- `cd workspace/core/backend/wms-be && bun run test && bun run lint && bun run typecheck && bun run build && bun run db:migrate && bun run db:verify` — run the full suite against a **freshly reset** database (drop the `public` and `drizzle` schemas, `FLUSHALL` Valkey, migrate). The whole suite, not a scoped subset: this story adds an inventory-module seam, and `architecture.spec.ts` is what guards it.
- `cd workspace/core/frontend/wms-fe && bun run test && bun run lint && bun run typecheck && bun run build` — stays green after `api:generate`
