---
title: 'Story 4.2: Waves and picklists'
type: 'feature'
created: '2026-09-11'
status: 'in-progress'
route: 'dispatch'
review_loop_iteration: 0
baseline_commit: '3fec363' # wms-be main
context:
  - '_bmad-output/implementation-artifacts/epic-4-context.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** Story 4.1's accepted orders have nowhere to go. Nothing groups them for the floor, nothing decides which bins an operator walks, and story 4.3's mobile picking has no task substrate to consume.

**Approach:** Add the wave aggregate to the outbound module: a wave gathers accepted orders by policy into picklists — one per order, or one batched across orders — and each picklist carries an ordered list of pick lines naming a bin and a batch. Release is the transition that makes a wave the floor's work.

**Decided (2026-09-11, human):**
- **Walk order is `bins.code` ascending.** Bins carry no spatial data — no aisle/rack/level/sequence/coordinate column exists. The grid generator's `A-01-01` (aisle-bay-level) convention sorts naturally, so code order *is* the walk for grid-generated warehouses and is stable-but-arbitrary for hand-created codes. "Steps" in the AC therefore means distinct bin stops. This matches putaway's capacity-only v1 honesty; a real `pick_sequence` needs a maintenance surface nobody has designed.
- **The outbound module owns `wave_policies` now** — `priority`, `max_orders`, `cutoff_local_time`, and a nullable **unvalidated** `carrier_ref` uuid, exactly the precedent 4.1 set with `orders.integration_id` (no integrations table until Epic 7). All three epic ACs ship; 4.6 and Epic 7 resolve the ref. Module ownership holds because outbound owns its own policy table rather than reaching into an empty `carriers`/`channels` shell.
- **Wave generation is an operator-triggered command**, not a scheduled job — `POST .../waves` with a policy and an order selection. Every AC here is about grouping correctness, not timing; a job can be layered on later without changing the aggregate.
- **Keep the full spec** (human accepted ~2,500 tokens vs the 1,600 ceiling — the 4.1 precedent).

**Decided (technical, from investigation):**
- Cutoff is compared in **`Asia/Kolkata`**, a named module constant. `warehouses` has no timezone column and the product is India-only (GST invoicing, e-way bills, Indian carriers), so a per-warehouse timezone would be speculative scope. When warehouses gain a timezone, this constant is the single place to change.
- A picklist line names a bin and batch as a **suggestion**, never an allocation — reservations bind to `(tenant, warehouse, sku, owner)` with no bin, and nothing in the system allocates stock to a bin today (FEFO only ranks batches *within* a caller-supplied bin).

## Boundaries & Constraints

**Always:**
- The wave/picklist aggregate lives only in the outbound module (AD-6). Stock is never written here — bin and batch reads compose through `InventoryFacade`, and no pick movement is journalled in this story.
- Picklist bin/batch assignment is a **suggestion re-derived at pick time**, exactly as putaway's target bin is (`suggestBinInTx`). It is never a bin-level allocation, because a reservation binds to `(tenant, warehouse, sku, owner)` and carries no bin.
- A wave draws only `accepted` orders whose lines hold live reservations; a cancelled order's lines are never picked. Orders already on an open wave are never re-waved — one order belongs to at most one open wave.
- Wave release is idempotency-keyed with payload-hash replay, re-reads the member role at entry, and commits its outbox event, audit row and idempotency key with the state flip (the 4.1 command shape, flip-first).
- A batch picklist visits each bin at most once: pick lines are grouped by bin, so total stops ≤ the sum of the same orders' single-order stops. That inequality is the AC and is asserted directly in tests.
- Every quantity a picklist names is the order line's `reserved_qty` — never `qty`. A backordered line contributes only what acceptance actually held.
- A policy's `cutoff_local_time` gates **release, not generation**: releasing after the cutoff has passed in the Kolkata-local day is refused `409 cutoff-passed` naming the cutoff. Generation is always allowed — planning ahead of a cutoff is the point.
- Reads: picklist detail (lines in walk order), a warehouse-scoped cursor-paginated wave list (keyset `(created_at, id)` from day one), and the policy list. OpenAPI export + FE `api:generate` ride the story.

**Never:**
- No mobile surface, no scanning, no pick execution, no ledger event, no stock movement (4.3); no short-pick re-planning (4.4); no pack or dispatch (4.5/4.6).
- No web Outbound surface — split out at the build scope gate into `4-2b-outbound-web-surface`, which also carries 4.1's deferred orders card and the `orders.manage` FE mirror.
- No carrier adapters, rating, labels or manifests — the `carriers` module stays empty until 4.6.
- No bin-level reservation, no re-reservation at release, no change to Epic 2's reservation machinery.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Generate a single-order wave | one accepted order, policy `single` | `201` wave `planned` with one picklist, lines in walk order | no eligible order → `422 no-eligible-orders` |
| Generate a batch wave | three accepted orders sharing bins | one picklist; each bin appears once; stops ≤ sum of single-order stops | N/A |
| Release a wave | wave `planned` | `200` wave `released`, picklists `ready`; outbox `wave.released` + audit | already released → idempotent `200` snapshot; `cancelled` → `409 conflict` |
| Cancel a wave | wave `planned` or `released`, nothing picked | `200` wave `cancelled`, orders eligible for waving again | N/A (picking arrives in 4.3) |
| Order cancelled after waving | order cancelled while on a planned wave | the wave's pick lines for that order drop at release | released wave keeps its lines; 4.3 rejects them at scan |
| Line with no on-hand anywhere | reserved qty > sum of bin on-hand | the line is planned `unfulfillable` with the shortfall named, wave still generates | N/A |
| Release after cutoff | policy cutoff 16:00, now 16:30 IST | nothing written; the wave stays `planned` | `409 cutoff-passed` naming the cutoff |
| Policy with no cutoff | `cutoff_local_time` null | release always allowed | N/A |
| Wrong authority | operator/accountant, foreign tenant, missing key | nothing written | `403 role-denied` / `permission-denied`, `401`, `400 validation-failed` |
| Concurrent generate | two generate calls racing the same orders | exactly one wave claims each order | loser → `409 conflict` naming the wave |

</frozen-after-approval>

## Code Map

- `workspace/core/backend/wms-be/src/modules/outbound/order.command.ts` — the command shape to copy verbatim: invariant order (`:142-160`), the multi-phase pattern (`:215-401`), flip-first terminal transition (`:504-607`), module-owned state tuples (`:31-46`), `replay` (`:725`), `writeIdempotencyKey` (`:748`), `snapshotOf` (`:784`), problem factories (`:883-897`). `ORDER_STATUSES` gains no arm in this story.
- `workspace/core/backend/wms-be/src/modules/outbound/outbound.facade.ts` — reads live in the facade, commands pass through (`:88-93`); `listOrders` (`:127`) is the keyset-list pattern to mirror; `snapshotOf` (`:176`) delegates to the command service — one serializer, no drift.
- `workspace/core/backend/wms-be/src/modules/inventory/inventory.facade.ts` — the only inventory seam. `reservationsByIds` (`:501`) / `reservationsByIdsInTx` (`:511`) — **there is no read-by-owner**, so a wave carries `order_lines.reservation_id` forward. Bin-level stock: `listStock` (`:352`), `batchOnHand` (`:550`), `batchBinsOnHand` (`:586`).
- `workspace/core/backend/wms-be/src/modules/putaway/putaway.command.ts:717-761` — `binCandidatesInTx`: the reusable bin-ranking query. Its filter set (`blocked = false`, `systemOwned = false`, `retiredAt IS NULL`) is exactly what an unpickable bin means; `binOccupancyInTx` (`:764`).
- `workspace/core/backend/wms-be/src/api/inventory.controller.ts:354` — `resolveFefoBatch`: FEFO ranks batches **within a caller-supplied bin** and never selects one. Picking needs bin-then-batch, so the bin choice is new code.
- `workspace/core/backend/wms-be/src/shared/db/schema.ts` — `reservations` (`:865-897`, no `bin_id`/`batch_id`), `orders`/`order_lines` (`:1340-1440`), `bins` (`:201-224`), `stockOnHand` (`:575-601`, **no index on `bin_id`**), `batchOnHand` (`:620-640`). Highest migration is `0017`.
- `workspace/core/backend/wms-be/test/architecture.spec.ts` — `:185` the order-table write guard is path-prefixed, so new wave files under `src/modules/outbound/` pass, but **`ORDER_TABLES` (`:181`) must gain the new tables**; `:249` pins `.insert(orders`/`.insert(orderLines` to `order.command.ts` — do not relocate them; `:201-239` the outbound facade guard, whose "no sibling consumer yet" caveat this story does not yet retire.
- `workspace/core/backend/wms-be/test/orders.spec.ts` — the e2e bootstrap to copy (advisory lock, fixtures, `expectProblem`); `test/putaway.spec.ts` for bin fixtures.

## Tasks & Acceptance

**Execution:**
- [ ] `wms-be drizzle/0018_*.sql` — `wave_policies`, `waves`, `picklists`, `picklist_lines` (status CHECKs, the one-open-wave-per-order partial unique index, unique policy name per warehouse, keyset indexes) + hand-appended RLS, and the `stock_on_hand (tenant, warehouse, bin)` index the bin walk needs
- [ ] `wms-be src/shared/db/schema.ts` — the four tables per conventions
- [ ] `wms-be src/modules/outbound/wave.command.ts` — `generateWave` (eligibility, grouping, bin/batch planning, walk ordering) + `releaseWave` + `cancelWave`
- [ ] `wms-be src/modules/outbound/outbound.facade.ts` — wave/picklist reads (detail + keyset list), sharing one serializer
- [ ] `wms-be src/api/outbound.controller.ts` — `POST .../waves`, `POST .../waves/{id}/release`, `POST .../waves/{id}/cancel`, `GET .../waves/{id}`, `GET .../warehouses/{wid}/waves`, plus `POST .../wave-policies` + `GET .../warehouses/{wid}/wave-policies` (a policy must be creatable to be referenced); OpenAPI annotations
- [ ] `wms-be src/modules/tenancy/permissions.ts` — `waves.manage` capability (Owner + Ops Manager), covering policy writes too
- [ ] `wms-be test/architecture.spec.ts` — extend `ORDER_TABLES` to the wave tables
- [ ] `wms-be test/waves.spec.ts` — the matrix e2e, including the batch-vs-single stop-count inequality, the cutoff arms (fake-clock or injected instant, both sides of the boundary), and the concurrent-generate race
- [ ] `wms-be bun run openapi:export` + `wms-fe bun run api:generate` — additive contract

**Acceptance Criteria:**
- Given accepted orders sharing bins, when a batch wave generates, then each bin appears exactly once in the picklist and total stops ≤ the sum of those orders' single-order stops
- Given a wave is released, when it is released again under a new key, then the second call is an idempotent no-op emitting no second `wave.released` event
- Given an order is cancelled after being planned onto an unreleased wave, when that wave releases, then the order's pick lines are gone from the picklist
- Given a policy whose cutoff has passed for the Kolkata-local day, when release is requested, then it is refused and the wave stays `planned`
- Given two generate calls race the same accepted orders, then exactly one wave claims them and the loser is refused

## Implementation Notes

## Spec Change Log

## Review Triage Log

## Design Notes

**Why bin assignment is a suggestion, not an allocation.** A reservation holds `(tenant, warehouse, sku)` quantity with no bin, and ATP is warehouse-wide. Binding a picklist line hard to a bin would invent a second, weaker reservation the inventory module knows nothing about — two sources of truth for the same units. Putaway already settled this shape: suggest at plan time, re-derive at execution, require a reason when the operator diverges. Picking inherits it, and 4.3 owns the re-derivation.

**Why one order belongs to at most one open wave.** Without it, two waves plan the same reserved units and the floor picks the same stock twice — the reservation cannot catch it, because both picks are draws against the same held quantity. A partial unique index on `(tenant, order_id) WHERE wave state is open` makes the database refuse it, which is also what makes the concurrent-generate race deterministic.

## Verification

**Commands:**
- `cd workspace/core/backend/wms-be && bun run test` — all suites pass including `test/waves.spec.ts`
- `cd workspace/core/backend/wms-be && bun run lint && bun run typecheck && bun run build && bun run db:migrate && bun run db:verify`
- `cd workspace/core/frontend/wms-fe && bun run test && bun run lint && bun run typecheck && bun run build` — stays green after `api:generate`
