---
title: 'Story 4.5: Pack station verification'
type: 'feature'
created: '2026-09-15'
status: 'done'
route: 'dispatch'
review_loop_iteration: 1
baseline_commit: 'd226005' # wms-be main
context:
  - '_bmad-output/implementation-artifacts/epic-4-context.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** Picked units leave their bins and then vanish from the system's attention. Nothing verifies that what reaches the bench is what was picked, nothing records that an order was packed, and an order sits `accepted` forever — so 4.6 has no Ready-to-Dispatch to consume and a mis-pick is only discovered by the customer.

**Approach:** A pack command verifies scanned contents against what was actually picked, records the pack in the ledger, moves the order to Ready-to-Dispatch, and returns everything a packing slip needs. A discrepancy is refused and named before anything is written.

**Decided (2026-09-15, human):**
- **A Pack Station is not an entity.** No table, no station id, no reference on any row. Nothing in FR-16 or the ACs needs one — "an Operator at a Pack Station" names a place in the building, not a thing in the data. One can be added when something actually asks for it.
- **The packing slip is a structured payload on the response**, not a document. The repo has no PDF, template or download machinery and no export precedent, so rendering belongs to whichever surface prints it. The *data* is the durable part.
- **The packing ledger event is one zero-quantity event per order line** — `quantityDelta: 0`, both bin arms null, a new `pack` reference-doc kind. Picking already drew the units out of stock entirely (`toBinId: null`), so a pack event has no bin to move between. The ledger tolerates this — no CHECK on `quantity_delta`, and projections fold only non-null bin arms — but it is the first non-movement event type in the system.
- **Backend only.** The pack screen rides `4-2b-outbound-web-surface`, which already owns the Outbound page and all three FE capability mirrors. This is the 4.1/4.2/4.3 shape.

**Decided (technical, from investigation):**
- **"Fully picked" is line-status based, never `picks`-based.** A zero-unit short pick writes no `picks` row at all (4.4), and a multi-slice line writes several. The predicate is: the order has at least one `picklist_lines` row, none of its rows is still `planned`, and **at least one of its rows is not `cancelled`**. `short`, `unfulfillable` and `cancelled` all count as settled for a line that sits alongside others — but a plan whose every line was withdrawn is the same "never picked" state that zero rows already refuses. (Amended 2026-09-15 during review loop 1 — see the Spec Change Log.)
- **Pack verifies against what was PICKED, not what was ordered.** After 4.4 a short-picked order legitimately has less on the bench than its lines asked for. Verifying against ordered quantities would refuse every short-picked order.
- Weight and dimensions ride the ledger event's reference doc. There is nowhere else durable for them without a table, and the decision above rules one out.

## Boundaries & Constraints

**Always:**
- The verification, the ledger events, the status flip, the outbox event, the audit row and the idempotency key **commit in one transaction**. A pack that half-lands would leave an order claiming to be packed with no ledger record, or the reverse.
- **A discrepancy is refused before anything is written**, naming the SKU and both quantities — what was picked and what was scanned. Refusing is the point of the story; a silent accept is worse than a hard failure.
- `ORDER_STATUSES` gains `ready_to_dispatch` additively, with the DB CHECK dropped and re-added per the 0019/0022 precedent. **Every guard that currently reads `accepted` must be audited**: order cancel, wave generation (both the explicit-selection and auto-selection paths), and the pick command's order-status gate. A packed order must not be re-waved, must not accept a queued pick, and must not silently cancel.
- Pack is refused unless the order is **fully picked** by the predicate above, and refused if it is already packed — an order reaches Ready-to-Dispatch once.
- Weight and dimensions are **optional**; their absence is never an error. When present they are validated as positive and carried on the reference doc.
- A `pack.execute` capability gates the command (Owner + Ops Manager + Operator), mirroring `picks.execute`. The FE mirror rides 4.2b with the other three.
- The command carries an `Idempotency-Key` with payload-hash replay, re-reads the member role at entry, and emits `order.packed` to the outbox plus an audit row.

**Never:**
- No pack station table, no station id, no bin representing a station.
- No PDF, HTML document, template, print endpoint or file download.
- No carrier rating, label, manifest or dispatch (4.6) — this story stops at Ready-to-Dispatch.
- No web or mobile surface (`4-2b`); no change to the reservation machinery or any projection. **One ATP exception (amended 2026-09-15, review loop 1):** the pack releases any still-`held` reservation on the order's own lines, because 4.5 is what makes those holds unreachable — see the Spec Change Log.
- No re-opening a packed order, no unpack, no partial pack.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Pack a fully-picked order | scanned contents match what was picked | `201`; one `pack.packed` ledger event per order line, order `ready_to_dispatch`, outbox + audit, slip payload returned | N/A |
| Pack with weight and dims | same, plus optional measurements | `201`; measurements carried on the reference doc and in the slip | non-positive values → `400 validation-failed` |
| Scanned contents mismatch | an extra SKU, a missing SKU, or a wrong quantity | nothing written | `422` naming the SKU, the picked quantity and the scanned quantity |
| Short-picked order | one line picked 3 of 5, scan carries 3 | `201` — verification is against what was picked, not ordered | N/A |
| Order not fully picked | any `picklist_lines` row still `planned` | nothing written | `409` naming the outstanding line |
| Order never waved | no `picklist_lines` rows at all | nothing written | `409` — an unwaved order has not been picked |
| Wave cancelled before any pick | every `picklist_lines` row is `cancelled` | nothing written; the order stays `accepted` and re-wavable | `409` — a wholly-withdrawn plan has not been picked *(amended, loop 1)* |
| Short pick left a live hold | a settled line still carries a `held` reservation | `201`; the dead hold is released in the pack transaction, ATP recovers | N/A *(amended, loop 1)* |
| Already packed | order already `ready_to_dispatch` | replay under the same key re-serves the snapshot; a new key is refused | `409` |
| Cancelled order | order `cancelled` | nothing written | `409` |
| Packed order re-waved or re-picked | wave generation or a queued pick targets it | excluded from wave selection; the pick is refused | the pick's existing order-status gate |
| Wrong authority | caller lacks `pack.execute`, or a foreign tenant | nothing written | `403 role-denied` / `permission-denied` |

</frozen-after-approval>

## Code Map

- `workspace/core/backend/wms-be/src/modules/outbound/order.command.ts:33` — `ORDER_STATUSES`; the comment at `:32` already anticipates this arm. Cancel's conditional flip is at `:550-557` and its guards at `:493-503` (committed reservations) and `:518-539` (`picklistLineDrewUnits()`). The snapshot cast is at `:845`.
- `workspace/core/backend/wms-be/drizzle/0017_ambiguous_santa_claus.sql:56` — `orders_status_check`. The additive precedent is `0019_flippant_komodo.sql:62-64` and `0022_steep_morbius.sql:12-13`: drop then re-add with the widened set.
- `workspace/core/backend/wms-be/src/modules/outbound/wave.command.ts:73-75` — `picklistLineDrewUnits()`, the existing "this line actually moved units" predicate. The order-status guards to audit are at `:962`, `:977` (explicit selection) and `:1008` (auto-selection filter `eq(orders.status, 'accepted')`).
- `workspace/core/backend/wms-be/src/modules/outbound/pick.command.ts:577-609` — the order-status gate. Its `else` branch is already commented as forward-looking for exactly this: "a dispatched order is terminal and belongs above; anything an order can still leave belongs below." A `ready_to_dispatch` order is terminal for picking.
- `workspace/core/backend/wms-be/src/modules/inventory/ledger-registry.ts:108-136` — `registerLedgerEventType({ type, sinceVersion, referenceKinds, allowsBatchArm, allowsSerialArm })` and the reference-doc union whose comment reserves `pack` by name. `:240` records why the pick draw leaves `toBinId` null.
- `workspace/core/backend/wms-be/src/modules/inventory/ledger.service.ts:438` — `appendMovement`. It folds projections only for non-null bin arms (`:530-560`), so a both-null event touches nothing; `signedQuantity` (`src/shared/primitives/quantity.ts:33`) accepts 0 and no CHECK constrains `quantity_delta`. `LedgerMovement` (`:26-48`) requires a non-null `skuId` — hence one event per order line rather than one per order.
- `workspace/core/backend/wms-be/src/shared/db/schema.ts:1806` — `picks_tenant_order_idx`, whose comment says it exists for "4.5's pack verification" reading the order's picked units.
- `workspace/core/backend/wms-be/src/modules/outbound/pick.command.ts:1183` — `pickId` is null on a zero-unit short pick, which is why `picks` cannot answer completeness.
- `workspace/core/backend/wms-be/src/modules/tenancy/permissions.ts:66` — `picks.execute`, the capability shape to copy. The FE mirror at `wms-fe/src/lib/users.ts:16-44` is **out of scope** and already missing three capabilities that 4.2b owns.
- `workspace/core/backend/wms-be/src/modules/outbound/outbound.dto.ts:150,211` — both `@ApiProperty` status enums need the new arm.
- `workspace/core/backend/wms-be/test/picking.spec.ts` — the e2e bootstrap, `releasedWave`/`pick` helpers and the fixture-SKU convention a pack suite reuses.

## Tasks & Acceptance

**Execution:**
- [ ] `wms-be drizzle/0023_*.sql` — drop and re-add `orders_status_check` with `ready_to_dispatch`
- [ ] `wms-be src/modules/outbound/order.command.ts` — the new status arm
- [ ] `wms-be src/modules/inventory/ledger-registry.ts` — the `pack` reference-doc arm and `pack.packed` registration
- [ ] `wms-be src/modules/outbound/pack.command.ts` — verification, the ledger events, the status flip, the slip payload
- [ ] `wms-be src/modules/tenancy/permissions.ts` — `pack.execute`
- [ ] `wms-be src/api/outbound.controller.ts` + `outbound.dto.ts` — `POST .../orders/{orderId}/pack`, both status enums, OpenAPI
- [ ] `wms-be src/modules/outbound/wave.command.ts` + `pick.command.ts` — audit every `accepted` guard for the new arm
- [ ] `wms-be test/packing.spec.ts` — the matrix e2e, including the short-picked order, the completeness predicate and the re-wave/re-pick exclusions
- [ ] `wms-be bun run openapi:export` + `wms-fe bun run api:generate`

**Acceptance Criteria:**
- Given a fully-picked order, when its scanned contents match what was picked, then a `pack.packed` event is written per order line and the order reads `ready_to_dispatch`
- Given a scanned set that differs from what was picked, then the pack is refused naming the SKU, the picked quantity and the scanned quantity, and nothing is written
- Given an order with any line still `planned`, when a pack is attempted, then it is refused naming that line
- Given an order that reached `ready_to_dispatch`, then wave generation excludes it and a queued pick against it is refused

## Implementation Notes

## Spec Change Log

**2026-09-15 — review loop 1, two frozen-block amendments (renegotiated with Sasidhar).**

1. **The completeness predicate gains a floor clause.** All three review layers converged on, and the
   verification-gap layer reproduced against the live stack, an order whose wave was cancelled before any
   pick: `cancelWave` flips every non-drawing line to `cancelled` and *deliberately* leaves the order
   `accepted` and re-wavable (pinned by `test/waves.spec.ts:1107`). The frozen predicate counted those lines
   as settled, so such an order passed completeness with zero `picks` rows, matched an empty `scanned: []`,
   and flipped to `ready_to_dispatch` with `totalUnits: 0` — then became unrecoverable, because cancel now
   refuses a non-`accepted` order and both wave-selection paths exclude it. The predicate now also requires
   at least one non-`cancelled` row. A *mixed* order — some lines picked, one withdrawn by a wave cancel —
   stays packable exactly as before; only a wholly-withdrawn plan is refused. Chosen over dropping
   `cancelled` from the settled set entirely, which would have stranded that mixed case forever (no path
   un-cancels a line).

2. **The "no change to ATP" boundary gains one carve-out.** After 4.4 a short pick releases the whole hold
   and re-grants the remainder as a fresh `held` reservation. When that remainder line settles as
   `unfulfillable`, the hold is still live at pack time — and 4.5's own cancel gate is what makes it
   unreleasable, since a `ready_to_dispatch` order can no longer be cancelled. ATP would stay understated
   for units that will never ship until the 7-day TTL reaper fired. The pack now releases still-`held`
   reservations on the order's lines inside its transaction, through the inventory facade (AD-6). The leak
   is one 4.5 created, so closing it is in scope; deferring to the TTL or to 4.6 was rejected because
   hiding sellable stock is the exact failure mode ATP exists to prevent.

## Review Triage Log

**Loop 1 — three layers (blind hunter, edge-case hunter, verification-gap). 12 + 4 + 5 raised, 15 distinct after
dedup: 11 patched, 2 rejected on verification, 2 escalated to frozen-block amendments (both approved — see the
Spec Change Log).**

*Verification-gap found no verification gaps in the strict sense: every behaviour this change alters is pinned by
an assertion that would fail if it regressed. Its findings below are defects it noticed while tracing.*

| # | Finding | Layers | Disposition |
|---|---------|--------|-------------|
| 1 | Wave-cancelled order packs on an empty scan and is then unrecoverable | all 3 (reproduced live) | **Amended frozen predicate** — floor clause + e2e case |
| 2 | Short pick's re-granted `held` hold is never released at pack → ATP leak to TTL | edge | **Amended frozen "Never"** — release via facade in the pack tx |
| 3 | Cancel's new status guard sits outside the write tx; lost flip serves 200 carrying `ready_to_dispatch` | blind | **Patched** — re-check under the lock, 409 |
| 4 | Order-line SKU missing from the read → `skuCode: ''` baked into a durable slip snapshot | blind | **Patched** — fall back to the id, as `assertScanMatchesPicked` already does |
| 5 | Concurrent same-key loser told to "replay the original Idempotency-Key" — which is what it sent | blind | **Patched** — re-check the idempotency row under the order lock, serve the stored snapshot |
| 6 | Packed-order pick refusal detail reads "its units are not picked" — backwards | blind | **Patched** — wording |
| 7 | DTO bounds are hardcoded copies of the command constants, nothing pins them | blind | **Patched** — import the constants; the file already imports `ORDER_STATUSES` |
| 8 | Two problem-detail strings enumerate unboundedly (outstanding lines, discrepancies) | blind + edge | **Patched** — cap the enumeration, report the count |
| 9 | Aggregated scan total is unbounded (per-line cap only), defeating `MAX_SCAN_QUANTITY` | blind | **Patched** — cap the aggregate |
| 10 | `cancelWave` can flip lines already journalled by `pack.packed` | edge | **Patched defensively** — consequence is unreachable today (only non-drawing lines flip; a `ready_to_dispatch` order cannot be re-waved), but the allow-list mirrors `releaseWave` and removes a trap for 4.6's `dispatched` arm |
| 11 | Test name "the order read and the order list report the new arm" never queries the list | v-gap | **Patched** — renamed |
| 12 | Replay with reordered `dimensionsMm` keys is unpinned | blind | **Patched** — regression test added (see rejection 1: the behaviour is correct, but it rests on an implicit transform guarantee nobody asserted) |
| 13 | `dimensionsMm` not normalized before hashing → reordered retry 422s instead of replaying | blind (edge disputed) | **Rejected on verification** — settled empirically, not by argument: `plainToInstance` yields declaration order regardless of input key order, so `{heightMm, widthMm, lengthMm}` and `{lengthMm, widthMm, heightMm}` hash identically. Edge-case was right. Pinned by #12 |
| 14 | `sum(picks.qty)::int` can raise a raw 22003 | blind (edge disputed) | **Rejected** — bounded by `MAX_LINE_QUANTITY`. The *scan* side of the same finding is caller-controlled and is #9 |
| 15 | `aggregateScan` runs before `assertPermission` (400 before 403); command-layer weight/dimension checks unreachable via HTTP and duplicate the DTO's | blind + v-gap | **Acknowledged, not patched** — the global pipe (`transform`/`whitelist`/`forbidNonWhitelisted`) fires before any command code, so the residual ordering window is unreachable over HTTP. The guards stay as defence for non-HTTP callers; #7 closes the drift half |

**Also deferred:** the conditional-flip backstop at `pack.command.ts:328-336` stays untested — it is genuinely
unreachable beneath the row lock, the same class as #10's consequence, and its own comment says so.

**Cross-repo:** the interface contracts (`docs/repos/wms-be/README.md`, `docs/repos/wms-fe/README.md`) do not yet
carry the pack surface — the new endpoint, the `ready_to_dispatch` arm, `pack.execute` and `order.packed`. Landing
with the meta docs PR, per CLAUDE.md ordering.

## Design Notes

**Why verification compares against picked, not ordered.** Story 4.4 made a short pick a first-class outcome: an order can legitimately reach the bench with fewer units than its lines asked for. Comparing the scan to ordered quantities would refuse every short-picked order, which would make short-picking unusable and push operators back to leaving lines `planned` forever — the exact behaviour 4.4 exists to end.

**Why one event per order line rather than one per order.** `LedgerMovement` requires a non-null `skuId`, and the ledger's per-SKU chain is what makes an item's history reconstructible. A single order-level event would either need a fabricated SKU or a nullable arm that every existing reader would have to learn. One event per line keeps every chain intact and costs only rows.

**What this leaves for later.** Weight and dimensions live on the reference doc, which is durable and auditable but not efficiently queryable — `ledger_events` has no index that reaches a reference doc's contents. Re-composing a packing slip long after the fact would need a query path that does not exist. That is acceptable while the slip is generated once at pack time, and should be revisited if a re-print surface is ever asked for.

## Verification

**Commands:**
- `cd workspace/core/backend/wms-be && bun run test && bun run lint && bun run typecheck && bun run build && bun run db:migrate && bun run db:verify` — run the full suite against a **freshly reset** database (drop the `public` and `drizzle` schemas, `FLUSHALL` Valkey, migrate). Run the whole suite, not a scoped subset: the last story's scoped run missed an architecture-guard failure.
- `cd workspace/core/frontend/wms-fe && bun run test && bun run lint && bun run typecheck && bun run build` — stays green after `api:generate`
