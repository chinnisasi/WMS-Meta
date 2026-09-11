---
title: 'Story 4.2: Waves and picklists'
type: 'feature'
created: '2026-09-11'
status: 'done'
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
- [x] `wms-be drizzle/0018_*.sql` — `wave_policies`, `waves`, `picklists`, `picklist_lines` (status CHECKs, the one-open-wave-per-order partial unique index, unique policy name per warehouse, keyset indexes) + hand-appended RLS, and the `stock_on_hand (tenant, warehouse, bin)` index the bin walk needs
- [x] `wms-be src/shared/db/schema.ts` — the four tables per conventions
- [x] `wms-be src/modules/outbound/wave.command.ts` — `generateWave` (eligibility, grouping, bin/batch planning, walk ordering) + `releaseWave` + `cancelWave`
- [x] `wms-be src/modules/outbound/outbound.facade.ts` — wave/picklist reads (detail + keyset list), sharing one serializer
- [x] `wms-be src/api/outbound.controller.ts` — `POST .../waves`, `POST .../waves/{id}/release`, `POST .../waves/{id}/cancel`, `GET .../waves/{id}`, `GET .../warehouses/{wid}/waves`, plus `POST .../wave-policies` + `GET .../warehouses/{wid}/wave-policies` (a policy must be creatable to be referenced); OpenAPI annotations
- [x] `wms-be src/modules/tenancy/permissions.ts` — `waves.manage` capability (Owner + Ops Manager), covering policy writes too
- [x] `wms-be test/architecture.spec.ts` — extend `ORDER_TABLES` to the wave tables
- [x] `wms-be test/waves.spec.ts` — the matrix e2e, including the batch-vs-single stop-count inequality, the cutoff arms (fake-clock or injected instant, both sides of the boundary), and the concurrent-generate race
- [x] `wms-be bun run openapi:export` + `wms-fe bun run api:generate` — additive contract

**Acceptance Criteria:**
- Given accepted orders sharing bins, when a batch wave generates, then each bin appears exactly once in the picklist and total stops ≤ the sum of those orders' single-order stops
- Given a wave is released, when it is released again under a new key, then the second call is an idempotent no-op emitting no second `wave.released` event
- Given an order is cancelled after being planned onto an unreleased wave, when that wave releases, then the order's pick lines are gone from the picklist
- Given a policy whose cutoff has passed for the Kolkata-local day, when release is requested, then it is refused and the wave stays `planned`
- Given two generate calls race the same accepted orders, then exactly one wave claims them and the loser is refused

## Implementation Notes

**Where the one-open-wave-per-order claim actually lives.** The design note calls for a partial unique index on `(tenant, order_id) WHERE wave state is open`. No table in the four-table set can carry that shape: a **batch** picklist spans orders, so `picklists.order_id` is null exactly when the guard matters most, and an order line whose reserved quantity spans two bins needs two `picklist_lines` rows, so `(tenant, order_line_id)` alone would refuse legitimate plans. The index shipped is `picklist_lines (tenant_id, order_line_id, slice_seq) WHERE status <> 'cancelled'` — equivalent in effect, because a second wave planning the same order always re-emits `slice_seq` 0 for that order's lines and collides. Cancelling a wave flips its lines to `cancelled`, which drops them out of the predicate: that flip *is* what frees the orders.

**"Gone from the picklist" is a flip, not a delete.** At release, pick lines whose order is no longer `accepted` flip to `cancelled` — the same disposal `cancelWave` uses, so there is one semantic rather than two, and the row keeps the record that those units were once planned. `cancelled` lines leave the partial unique index (freeing their claims) and are excluded from `stopCount`, so they are gone from the *walk*, which is what the AC is about. A picklist left with no line that names a bin — every line dropped, or every line `unfulfillable` — flips `cancelled` rather than reaching the floor with zero stops.

**Slices.** One pick line is one slice of one order line: `(bin, batch, qty)`. The planner walks bins in `bins.code` order and, within a bin, batches in FEFO order. Each bin carries a running budget equal to its plain `stock_on_hand` row, so the batch slots for a bin can never sum above what the bin actually holds; units the batch projection does not account for at all draw as one batch-less slot rather than being stranded, while units held by a blocked or expired batch ARE accounted for and stay undrawable. The pool is consumed as it is planned — so two lines of the same SKU never both claim the same units, which is what makes the batch-vs-single stop inequality hold rather than merely look true. A line whose reserved units have nowhere pickable to come from gets one trailing `unfulfillable` slice (`bin_id` null, `qty` 0, `shortfall_qty` = the remainder). `stopCount` on the picklist read is the derived distinct-bin count — the AC's "steps".

**Unpickable = putaway's filter set.** `blocked = false`, `system_owned = false`, `retired_at IS NULL`. QC-held stock needs no separate exclusion: a QC hold *moves* the stock into the system-owned QC bin (3.4), which this filter already skips. Blocked and expired batches are never suggested — the draw-side half of epic-2 retro a13, free here because the planner already joins catalog identity for FEFO.

**New cross-module seams (all in-tx, the `reservationsByIdsInTx` shape).** `InventoryFacade.stockByBinsInTx` and `.batchOnHandByBinsInTx`; `CatalogFacade.getBatchesForSkusInTx`. `OutboundModule` now imports `CatalogModule` (which imports only `SharedModule` + `forwardRef(TenancyModule)` — no cycle). Each wave command is exactly ONE tenant transaction: nothing here grants, commits or releases a reservation, so 4.1's multi-phase split is unnecessary and the plan a generate commits is the stock it saw.

**The clock is injected.** `WAVE_CLOCK` (`src/modules/outbound/wave.clock.ts`) is the seam the cutoff comparison reads; the e2e suite stubs it on both sides of 16:00 IST instead of sleeping. `localTimeOfDay` is the one place local time enters the system.

**A drizzle trap worth remembering.** Inside a raw `` sql`…` `` fragment, drizzle renders a column reference UNqualified (`"id"`) in a SELECT *projection* — a correlated subquery then resolves it against its own FROM list and silently counts nothing. (It qualifies correctly in `where` / `update` / `delete` contexts.) The wave list's `picklistCount` is therefore hand-qualified `waves.id`.

## Spec Change Log

- **2026-09-11 — claim index granularity.** `picklist_lines (tenant_id, order_line_id, slice_seq) WHERE status <> 'cancelled'` replaces the design note's `(tenant, order_id)`; see Implementation Notes for why no four-table shape supports the literal form.
- **2026-09-11 — one new problem code.** `wave-cap-exceeded` (422) refuses an explicit selection larger than the policy's `max_orders`, instead of silently truncating it. The matrix's other codes ship as specified.
- **2026-09-11 — `grouping` is a policy column.** The I/O matrix says "policy `single`", so the single-vs-batch choice lives on `wave_policies.grouping` alongside `priority` / `max_orders` / `cutoff_local_time` / `carrier_ref`.
- **2026-09-11 — release empties a picklist to `cancelled`.** Not specified either way; a ready picklist with no pickable stop would be noise on the floor.
- **2026-09-12 (review) — a hold-less order in an EXPLICIT selection is refused by name** (422 `no-eligible-orders`) rather than silently skipped; a no-selection sweep still skips, since it promised no particular order.
- **2026-09-12 (review) — `cutoff_local_time` `00:00` is rejected at the DTO.** It passes the `HH:MM` shape but would refuse release at every instant except that one minute.
- **2026-09-12 (review) — index set corrected.** The speculative `stock_on_hand (tenant, warehouse, bin)` index is dropped (no query in this story uses it; the bin join happens in JS) and `picklist_lines (tenant_id, wave_id)` is added, which the snapshot read and both wave-keyed updates actually key on. Migration re-generated as `0018_narrow_lake.sql`.
- **2026-09-12 (review) — `MAX_POLICY_MAX_ORDERS`** separates a policy's own cap from `MAX_SELECTED_ORDERS` (the explicit IN-list bound), and `max_orders IS NULL` is documented as "inherits `DEFAULT_WAVE_MAX_ORDERS`", never "uncapped".

## Review Triage Log

_Three layers (blind hunter, edge cases, verification gaps) — 2026-09-11. Verification-gap findings arrive pre-verified (that layer proved each by mutation); every other claim was re-checked against the source before grading._

| # | Finding | Verdict | Evidence | Route |
|---|---------|---------|----------|-------|
| 1 | FEFO/batch arm of `planSlices` never executed — all 10 fixture SKUs are untracked, so `drawableBatch`, the FEFO sort and the batch clamp run on an empty array every time | high | Inverting the comparator or deleting the drawable filter leaves the suite green | patch |
| 2 | Only the `blocked` arm of the pickable-bin filter is tested; `system_owned` and `retired_at` are not | high | Deleting `eq(bins.systemOwned, false)` leaves the suite green — production would plan picks against Receiving/QC-hold bins | patch |
| 3 | `waves.manage` unasserted on release and cancel (only generate and policy-create are covered) | high | Deleting both `assertPermission` calls leaves the suite green — an Operator could release or cancel a wave | patch |
| 4 | The four new tables' RLS policies are never probed; the suite provisions `wms_rls_probe` and never connects as it | high | Dropping the policies from 0018 leaves the suite green; compounds #13, where the snapshot reads rely on RLS alone | patch |
| 5 | None of 0018's eleven CHECK constraints is probed, unlike 0009 and 0017 | medium | Deleting `picklist_lines_slice_shape` leaves the suite green | patch |
| 6 | `wave.generated` and `wave.policy-created` outbox events and audit rows unasserted (release/cancel are asserted) | medium | Deleting the outbox append at generation leaves the suite green — a silently half-broken event contract | patch |
| 7 | The `idempotency-key-reuse` (422) arm is untested on all four wave commands; only the matching-payload replay is exercised | medium | Deleting the payload-hash comparison leaves the suite green; every other suite in the repo asserts this arm | patch |
| 8 | Batch slots over-plan a bin: each slot is capped at `Math.min(batch.quantity, row.quantity)` but the slots' **sum** is never capped at the bin's on-hand | medium | Confirmed at `wave.command.ts:1075-1082`. Two batches of 10 in a bin holding 10 yield 20 drawable units. The comment claims `min` "keeps a divergent projection from over-planning" — it bounds each batch alone, which is exactly the case it claims to guard | patch |
| 9 | Bins whose batch rows cover less than the plain projection strand the uncovered units | medium | Confirmed: the `batchRows.length === 0` branch handles only the all-untracked case; a partially-covered bin plans an unfulfillable shortfall for stock that exists | patch |
| 10 | `stock_on_hand_tenant_warehouse_bin_idx` is never used by any query in the change | medium | Confirmed independently by two layers: `stockByBinsInTx` filters (tenant, warehouse, sku) and the bin join happens in JS via `binRank`. Write amplification on the hottest projection in the system for no read | patch |
| 11 | `picklist_lines` has no `(tenant_id, wave_id)` index, yet `snapshotOf`, the release-time delete and the cancel update all key on `wave_id` | medium | Confirmed: the four indexes created are `(picklist_id, walk_seq, id)`, `(tenant_id, order_id)`, `(tenant_id)` and the partial unique — every wave-keyed path falls back to the bare tenant index | patch |
| 12 | Release hard-DELETEs a cancelled order's pick lines where `cancelWave` soft-flips them to `cancelled` | medium | Confirmed at `wave.command.ts:680`. Two disposal semantics for the same situation; the delete loses the record that those units were ever planned and leaves surviving `walk_seq` values non-contiguous | patch |
| 13 | `snapshotById` and `snapshotOf` carry no tenant predicate — they select by id/`wave_id` alone | medium | Confirmed at `wave.command.ts:1225,1235`. Every other query in the file pairs id with tenant; these rely on RLS as the sole barrier, and the repo never issues `FORCE ROW LEVEL SECURITY` | patch |
| 14 | An explicitly selected order whose lines lost their holds is dropped from the wave silently | medium | Confirmed at `wave.command.ts:477`. Reachable via 7-day TTL expiry on a still-`accepted` order. Every adjacent refusal names its order (404 unknown, 422 non-accepted, 409 already-waved); this one returns fewer picklists than orders named, with nothing saying which or why | patch |
| 15 | A picklist whose every line is `unfulfillable` reaches the floor as `ready` | medium | Confirmed: the empty-picklist cancel predicate is `not exists (… pl.picklist_id = …)`, which is false when unfulfillable rows exist — zero pickable stops, released as work | patch |
| 16 | A `cutoffLocalTime` of `'00:00'` makes a policy permanently unreleasable | low | Confirmed: the DB CHECK regex admits `00:00`, and `nowLocal > '00:00'` is true at every instant except that exact minute | patch |
| 17 | `ReleaseWaveDto` / `CancelWaveDto` are empty classes advertised via `@ApiBody` but never bound; the published contract marks the body `required` | low | Confirmed against `openapi/openapi.json` — both wave routes carry `requestBody.required: true` against an empty schema. Generated clients must send `{}` on a body-less endpoint | patch |
| 18 | `max_orders` is documented as "null = uncapped" in the schema but implemented as `?? DEFAULT_WAVE_MAX_ORDERS`; the validation message reuses a constant meaning "bound on an explicit IN list" | low | Confirmed: null is capped, not uncapped — the schema comment is simply wrong | patch |
| 19 | `localTimeOfDay` fails **open** if `Intl` yields no hour/minute part — it would return `'00:00'`, allowing release past every cutoff | low | Confirmed by inspection; a fail-closed throw is the correct direction for a gate whose whole purpose is refusal | patch |
| 20 | `warehouseId` (generate) and `waveId` (release/cancel) are not UUID-validated for non-HTTP callers, unlike `policyId` and `carrierRef` | low | Confirmed: a malformed id reaches Postgres and surfaces as an unmapped 22P02 → 500 instead of 400 | patch |
| 21 | `releaseWave` hashes `{tenantId, waveId}` while `cancelWave` hashes `{tenantId, waveId, action: 'cancel'}` | low | Confirmed: the two transition commands hash differently, relying on the absence of a field rather than a discriminator | patch |
| 22 | `outbound.facade.ts` imports from `'../../shared/db/schema'` twice in consecutive statements | low | Confirmed | patch |
| 23 | The comment explaining drizzle's raw-`sql` column rendering is inaccurate for the pinned version | low | drizzle-orm 0.45.2 renders a `Column` chunk qualified except when `invokeSource === 'indexes'`. The hand-qualification is harmless, but the comment would mislead the next author into distrusting the correlated subqueries that depend on qualified rendering | patch |
| 24 | Batch expiry is judged on a UTC day boundary (`Date.parse('YYYY-MM-DD') >= now`) inside a module that otherwise reasons in Asia/Kolkata | medium | **Real but pre-existing.** The shipped FEFO path (`api/inventory.controller.ts:368`) uses the identical comparison, so this is a repo-wide semantic, not something this change introduced. Fixing it here alone would make waves and adjustments disagree about what "expired" means | defer |
| 25 | A hold can expire between generate and release, so a released picklist may direct picks against reservations that no longer exist | medium | Real and reachable (7-day TTL + reaper). Bounded by design: a picklist's bin/batch is a **suggestion** re-derived at pick time, so 4.3 re-validates before any draw. Closing it properly belongs with 4.3's re-derivation, not as a release-time guard invented here | defer |
| 26 | Two open waves can suggest the same bin units for different orders | medium | Real, and the direct consequence of the frozen decision that a picklist line is a suggestion rather than an allocation. Closing it needs bin-level allocation, which the spec explicitly forbids | defer |
| 27 | The race loser's re-read transaction failing turns a deterministic 409 into a 500 | low | Real but requires a second failure (connection drop, timeout) during an already-losing race; the fix wraps a re-read in a catch that would mask genuine faults | rejected |
| 28 | The review diff omitted `openapi.json` and the drizzle snapshot | — | Not a code defect — an artifact of how I staged the diff. I verified the request-body claim (#17) directly against the generated contract instead | rejected |


## Design Notes

**Why bin assignment is a suggestion, not an allocation.** A reservation holds `(tenant, warehouse, sku)` quantity with no bin, and ATP is warehouse-wide. Binding a picklist line hard to a bin would invent a second, weaker reservation the inventory module knows nothing about — two sources of truth for the same units. Putaway already settled this shape: suggest at plan time, re-derive at execution, require a reason when the operator diverges. Picking inherits it, and 4.3 owns the re-derivation.

**Why one order belongs to at most one open wave.** Without it, two waves plan the same reserved units and the floor picks the same stock twice — the reservation cannot catch it, because both picks are draws against the same held quantity. A partial unique index on `(tenant, order_id) WHERE wave state is open` makes the database refuse it, which is also what makes the concurrent-generate race deterministic.

## Verification

**Commands:**
- `cd workspace/core/backend/wms-be && bun run test` — all suites pass including `test/waves.spec.ts`
- `cd workspace/core/backend/wms-be && bun run lint && bun run typecheck && bun run build && bun run db:migrate && bun run db:verify`
- `cd workspace/core/frontend/wms-fe && bun run test && bun run lint && bun run typecheck && bun run build` — stays green after `api:generate`
