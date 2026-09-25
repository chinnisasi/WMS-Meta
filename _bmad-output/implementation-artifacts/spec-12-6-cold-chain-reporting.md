---
title: 'Story 12-6 — Cold-chain reporting: the FR-45 reconstruction read'
type: 'feature'
created: '2026-09-25'
status: 'done'
route: 'dispatch'
baseline_commit: 'wms-be@b913438 / wms-fe@f948e38'
review_loop_iteration: 0
context:
  - '_bmad-output/implementation-artifacts/epic-12-context.md'
  - 'docs/design/SYSTEM-DESIGN.md'
  - 'docs/design/IMPLEMENTATION-GUIDE.md'
  - 'docs/design/modules/inventory.md'
  - 'docs/design/modules/compliance.md'
  - 'docs/design/API-SURFACE.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** FR-45 — "for any dispatched unit, the storage classes and excursions it passed through are reconstructible from the ledger" — has no reader. The 12-5 work put the reconstruction source into the ledger (`pick`/`putaway`/`qc-hold`/`excursion` reference docs, batch/serial trace indexes), but nothing queries it; a cold-chain auditor has no report.

**Approach:** One **read-only** endpoint in the compliance module (FR-45 is its FR): `GET /tenants/{t}/warehouses/{w}/cold-chain/orders/{orderId}` reconstructs a dispatched order's cold-chain trace from `ledger_events` alone — per order line, the full batch/serial ledger chain of every picked scope, annotated with each bin's storage class, plus the excursions whose reading fell inside a scope's dwell window at a chain bin. No new capability (reads are never gated), no new table.

## Boundaries & Constraints

**Always:**
- The trace is derived from ledger rows only — never from projections, never from `temperature_excursions` rows. The join chain: `dispatch.dispatched` (ref carries `orderId`/`orderLineId`) → `pick.picked` events with the same `reference_doc->>'orderId'` (ref also carries `orderLineId`; built at `pick.command.ts:987`) → those picks' `batch_ref`/`serial_ref` scopes → each scope's full event history via the `(tenant,batch_ref,seq)`/`(tenant,serial_ref,seq)` indexes (`schema.ts:866-871`).
- Each event in a chain is annotated with the **current** `bins.storage_class` of its from/to bins. Honest-by-construction: the 12-1/12-3 class-edit guards (`bin.command.ts:1395-1467`) refuse a class change that would strand stock, so while a unit was in the bin the class was conforming to what it is now (temperature classes may only have moved colder).
- Excursion correlation is **dwell-window** based, from the ledger alone: an `excursion.recorded` event attaches to a scope×bin when its `skuId` matches the scope, its `reference_doc.binId` is a bin on that scope's chain, and its `occurred_at` (the reading's business time, verified `excursion.command.ts:383`) falls inside that bin's dwell window — [first arrival (`to_bin_id` = bin), last departure (`from_bin_id` = bin), open-ended if the scope was still there at pick time]. An excursion recorded before arrival or after departure does NOT attach.
- Migration `0039` is additive index-only: a b-tree expression index on `ledger_events ((reference_doc->>'orderId')) WHERE reference_doc ? 'orderId'` so the per-order join doesn't degrade into a whole-warehouse scan as the ledger grows. No column, no data change, no RLS hand-append needed (table already has it).
- Reads are never gated: `TenantSessionGuard` + `assertOwnTenantToken` + `assertUuidParam`, no capability check, no idempotency (no writes).
- OpenAPI additive-only; the response carries the raw `referenceDoc` per chain event (the "ledger context" UX-DR30 names).

**Never:**
- No FE surface — FE is client regen only. The trace UI rides 12-7/12-8.
- No trace keyed by batch/serial directly, and no non-dispatched-order trace (FR-45 names dispatched units; the chain already covers the batch's full history regardless of which order picked it).
- No threshold/alert model, no carrier-API calls, no PDF/export, no reporting-module activation (epic 9 owns dashboards/exports; this is a domain read, not a dashboard).
- No new ledger events, no grammar bump, no writes anywhere.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Happy path | dispatched order, batch-tracked line, received→putaway→picked→dispatched | `200` per line: chronological chain (each event with seq/type/occurredAt/from-to bins/quantity/batch or serial ref/referenceDoc), a bins dictionary (id → code + storageClass), and excursions window-correlated per scope | N/A |
| Multi-scope line | one line picked from 2 batches (or serial-tracked units) | one chain per batch/serial scope | N/A |
| Excursion outside dwell | excursion at a chain bin recorded after the scope departed | excluded from that line's `excursions` | N/A |
| No excursions | clean chain | `excursions: []`, everything else normal | N/A |
| Undispatched order | accepted/packed order, no dispatch events | — | `409 order-not-dispatched` |
| Foreign or missing order | orderId not in tenant/warehouse | — | `404 not-found` |
| Foreign warehouse | warehouseId outside tenant | — | `404 not-found` |

</frozen-after-approval>

## Code Map

- `src/modules/inventory/ledger-registry.ts` -- the typed reference-doc union; `pick` (:99) carries `orderId/orderLineId` (the join key), `dispatch` (:191) carries `orderId/orderLineId/dispatchedQty/carrierName?/trackingNumber?`
- `src/shared/db/schema.ts:812-877` -- `ledgerEvents`: batch/serial trace indexes :866-871, keyset timeline :857; `reference_doc` jsonb has NO order index today
- `src/modules/inventory/inventory.facade.ts` -- `listEvents` :292 (the timeline read to imitate, NOT to reuse — it pages the whole warehouse); add the two by-ref reads here
- `src/modules/outbound/outbound.facade.ts:237` -- `getOrder` exists (order identity, carrier, tracking)
- `src/modules/compliance/excursion.command.ts` -- the module's read/write precedent; bins are read directly from schema (`bins` import :7) — the shared-substrate precedent 12-5 set
- `src/api/compliance.controller.ts` + `compliance.dto.ts` -- the route/DTO/`problemJsonResponse` pattern to copy; new GET route joins it
- `src/shared/primitives/pagination.ts` -- not needed (bounded single-order response, no pagination)
- `drizzle/0039_*.sql` -- NEW hand-authored migration: expression index only
- `test/excursions.spec.ts` -- the suite skeleton to copy (`useSuiteDatabase`, real HTTP, `codeOf`)

## Tasks & Acceptance

**Execution:**
- [x] `drizzle/0039_cold_chain_order_index.sql` + `meta/_journal.json` -- hand-authored additive migration: `CREATE INDEX ledger_events_order_ref_idx ON ledger_events ((reference_doc->>'orderId')) WHERE reference_doc ? 'orderId'` -- keeps the per-order join off a whole-warehouse scan (the ledger is append-only; every other lookup key already has an index)
- [x] `src/modules/inventory/inventory.facade.ts` -- additive read(s): ledger rows by order ref (type filter `pick.picked` + `dispatch.dispatched`, `reference_doc->>'orderId'` match) and by batch/serial ref lists, through `withTenantTransaction` -- the module's facade is the only ledger door
- [x] `src/modules/compliance/` (facade + the read logic; `outbound.module` import added to `compliance.module.ts` for `OutboundFacade.getOrder`) -- the reconstruction: scopes from picks, per-scope chains from the trace indexes, bins dictionary (direct `bins` read, 12-5 precedent), dwell windows, excursion correlation; response shape `{order, bins[], lines[]}` per the Design Notes example
- [x] `src/api/compliance.controller.ts` + `compliance.dto.ts` -- `GET tenants/:tenantId/warehouses/:warehouseId/cold-chain/orders/:orderId` (guard + asserts + `@ApiResponse` arms per the exhaustive-prose convention) -- the read surface
- [x] `openapi/openapi.json` via `bun run openapi:export` -- contract artifact
- [x] `test/cold-chain.spec.ts` -- full-suite e2e driving real HTTP: receive→putaway→pick→pack→dispatch a batch-tracked order, then every matrix row
- [x] wms-fe `bun run api:generate` -- client stays in sync (drift guard)

**Acceptance Criteria:**
- Given a dispatched batch-tracked order whose picked batch dwelt in 2 bins and survived an excursion at one of them, when the report is read, then the chain shows every ledger hop with the bin's storage class and the excursion appears exactly once, correlated to the dwell window.
- Given an excursion at a chain bin recorded after the batch departed that bin, when the report is read, then that excursion does not appear.
- Given an undispatched or foreign order, when the report is read, then `409 order-not-dispatched` / `404 not-found` and nothing is written.

## Implementation Notes

## Spec Change Log

## Review Triage Log

**Round 1** (blind-hunter 18 / edge-case-hunter 7 / verification-gap 6; each verified first-hand unless noted):

| # | Finding (source) | Verdict | Evidence / route |
|---|---|---|---|
| 1 | `openapi.json` hunk absent from review diff (BH) | false | Staging artifact of the review diff (diffstat only), not the change: the contract is generated by `openapi:export` (verified idempotent) and pinned by the route-published test; the reviewable source (controller annotations + DTOs) is fully in the diff. |
| 2 | Dispatch-dedupe comment mismatch: comment claims "first event wins", code pushes every dispatch event (BH/E/VG-o1) | low → patch | Comment/code mismatch confirmed, but the behavior is unreachable: `dispatch.command.ts:257` refuses anything not `ready_to_dispatch` and the command is the dispatched arm's only writer. Fix: reword the comment to state the single-writer reality. |
| 3 | Serial-scope path untested (BH, VG-3 pre-verified) | medium → patch | No serial-tracked SKU in the suite; the entire `s:` arm (scope keys, serial picks, serial chains) never runs. Fix: add a serial-tracked order trace test. |
| 4 | Multi-line orders untested — per-line excursion filter never exercised (BH) | medium → patch | Every traced order has one line; a bug attaching every excursion to every line would pass the suite. Fix: add a two-line order test where the excursion attaches to only one line's SKU. |
| 5 | Partial index likely unusable by the query — predicate `? 'orderId'` not implied by `->>'orderId' =` (BH) | **medium → patch (CONFIRMED)** | EXPLAIN first-hand: predicate-only query → `Index Scan using ledger_events_order_ref_idx`; the production shape (`->>'orderId' =` alone) with seqscan off → forced Seq Scan (`Disabled: true`). The index never serves the query as written. Fix: add the `reference_doc ? 'orderId'` qual to `ledgerEventsByOrderRefInTx`. |
| 6 | `CREATE INDEX` without `CONCURRENTLY` (BH) | low → reject | Pre-existing convention (every migration here is transactional); `CONCURRENTLY` cannot run inside the migration runner's transaction; unlikely met at current scale; fix fights the framework. |
| 7 | Snapshot omits the index; drift/introspection unverified; next hand-emitted index procedure undocumented (BH) | defer (with #26) | Same root cause as VG-4: the hand-emitted index is invisible to the snapshot and asserted nowhere. |
| 8 | Dwell windows merge visits — excursion during a QC-HOLD gap attaches (BH) | false | The frozen matrix defines the window as `[first arrival, last departure]`; the route's OpenAPI description states exactly that semantic. Code implements the specified window. |
| 9 | Chain unbounded into the future — post-dispatch returns extend dwell windows (BH) | false | The frozen Design Notes formula is `max occurredAt where from_bin_id = bin` over the COMPLETE chain; a post-dispatch return genuinely re-opens the dwell, and "the batch's history is the batch's history" is the frozen intent. |
| 10 | Unbounded response size, no cap (BH) | low → reject | The spec explicitly decided no pagination for a bounded single-order read; everyday batch histories are short; a cap/limit param adds surface beyond a direct fix. |
| 11 | Two-transaction composition ("one consistent snapshot" overclaim) + getOrder heavier than needed (BH/E-2/E-4) | low → patch (comment only) | Verified: `getOrder` runs its own transaction. Moving it inside the trace tx would put a direct `orders`-table query in compliance, violating AD-6; the ledger (not the row) supplies the response's dispatch facts; transient status staleness is tolerable. Fix: reword the "one consistent snapshot" claim. getOrder-heaviness: performance nit, not acted on. |
| 12 | Partially dispatched order loses undispatched lines silently (BH) | false | `dispatch.command.ts` is the dispatched arm's only writer and journals one event per line in a single command (status guard :257); short-picked lines still emit events with `dispatchedQty < orderedQty`. A partially-eventless line is unreachable. |
| 13 | `dwellWindows` fabricates arrival for departure-only bins (BH) | false | `grn.received` carries `toBinId = receivingBin` (`receiving.command.ts:684`), so every scope's first appearance at any bin is an arrival event inside its own complete chain — a departure-first bin is unreachable. |
| 14 | Empty-refs short-circuit + both-arms-null pick branches untested (BH) | low → reject | The empty-refs guard is behavior-preserving (verified: drizzle-orm renders empty `inArray` as `false`); the both-arms-null guard protects a scenario with correct present behavior (`scopes: []`). No wrong behavior claimed. |
| 15 | 401/403 arms untested for the new route (BH) | medium → patch (with #25) | The route's security surface (assertOwnTenantToken + assertWarehouseInTenant) is pinned nowhere at route level, unlike every sibling suite. |
| 16 | Docs/contract updates absent from diff (BH) | false | Meta-repo docs (API-SURFACE, module doc, interface contracts, PENDING) land in step-05 by design. |
| 17 | Journal `when` hand-faked (0038 + 60s) (BH) | false | Monotonic `when`, `idx`/`prevId` chain verified; hand-entry is the required procedure for hand-authored expression-index migrations (drizzle-kit is blind to them). |
| 18 | Missing trailing newlines in new files (BH) | false | Lint passes clean on the tree (re-verified at re-verification). |
| 19 | Inverted dwell window from backdated business times — excursions silently uncorrelated (E) | low → patch | Reachable: pick `occurredAt` is client-supplied; a backdated pick inverts the window and the correlation predicate can never match. Fix: clamp `departure = max(departure, arrival)`. |
| 20 | "Registry refuses a SKU tracked both ways" — refusal actually lives in the pick command (E) | false (behavior) / comment folded into patch | A dual-armed event's batch can never be a traced scope's batch: dual-tracked SKUs cannot be picked (`pick.command.ts:796`), so the cited consequence is unreachable. The comment's citation is imprecise — wording folded into the comment patch. |
| 21 | "Only the two types whose reference doc carries orderId" — `pack.packed` also carries orderId (E) | low → patch | Verified `ledger-registry.ts` pack arm carries `orderId/orderLineId` — three types carry it. The type filter is deliberate; the comment's invariant claim is wrong. Fix: reword. |
| 22 | RLS citation `0023` wrong — ledger_events RLS was enabled in `0006` (E) | low → patch | Verified: `0023` references ledger_events zero times; `0006:61` enables its RLS. Fix: correct the citation. |
| 23 | Cross-tenant 403 arm unpinned — dropping `assertOwnTenantToken` would leak silently (VG-1, pre-verified) | medium → patch | Filed evidence verified: the only suite hitting the route registers one tenant; sibling suites pin this arm route-by-route. Fix: add the cross-tenant 403 test (catalog.spec.ts pattern). |
| 24 | Open-ended dwell window (departure null) untested (VG-2, pre-verified) | medium → patch | In every traced scope every bin has a departure event; the branch the report exists to exercise is never taken. Fix: add a partially-picked-order test with leftover stock and a post-dispatch excursion. |
| 25 | (merged into #3) | — | — |
| 26 | Index existence/use asserted nowhere (VG-4, pre-verified) | defer | Correctness unaffected at suite volumes; the check belongs as a cheap introspection line in `db:verify`, not a gate for this story. Deferred with #7. |
| 27 | Stale rationale: "`IN ()` is invalid SQL" — drizzle-orm 0.45.2 renders empty `inArray` as `false` (VG-o2) | low → patch | Verified in `conditions.cjs:113`. Guard is behavior-preserving; the stated reason no longer holds. Fix: reword the doc comment. |

**Dispositions:** patch = #2 #3 #4 #5 #11 #15 #19 #21 #22 #23 #24 #27 (grouped: comment corrections #2/#11/#20/#21/#22/#27; index qual #5; dwell clamp #19; tests #3/#4/#15/#23/#24). defer = #7+#26. All others rejected (false/low) on the evidence above. No intent_gap, no bad_spec — no loopback; `review_loop_iteration` stays 0.

## Design Notes

**Why the order→pick join rides `reference_doc` and gets an index.** The `pick` reference doc was built (story 4.3) carrying the full order chain precisely so the ledger could answer "which picks served this order" without an outbound-table join; the hash-chained doc is the durable join key. The expression index in 0039 is the only schema change — everything else reads existing structures.

**Response example (the shape, abbreviated):**

```jsonc
{
  "order": {"id": "…", "code": "SO-12", "carrierName": "blue_dart", "trackingNumber": "…", "dispatchedAt": "…"},
  "bins": [{"id": "…", "code": "CH-01", "storageClass": "chilled"}],
  "lines": [{
    "orderLineId": "…", "skuId": "…", "dispatchedQty": 25000,
    "scopes": [{"batchRef": "B-77", "chain": [
      {"seq": 402, "type": "grn.received", "occurredAt": "…", "toBinId": "RCV", "referenceDoc": {"kind": "grn-receipt", "grnId": "…"}},
      {"seq": 409, "type": "putaway.placed", "occurredAt": "…", "fromBinId": "RCV", "toBinId": "CH-01", "referenceDoc": {"kind": "putaway", "grnId": "…"}}]}],
    "excursions": [{"excursionId": "…", "binId": "CH-01", "readingC": 8.5, "occurredAt": "…"}]
  }]
}
```

**Chain semantics.** A scope's chain is its COMPLETE batch/serial history (all events, chronological by `seq`) — including other orders' picks — because the batch's history is the batch's history; the requested order's picks are still visible in the trace. Dwell window per bin = `[min occurredAt where to_bin_id = bin, max occurredAt where from_bin_id = bin]`; open-ended at the pick side (the scope's last event may be the draw itself). `quantityDelta` on the raw rows is already signed milli-units.

**Storage-class honesty.** The report annotates with the CURRENT class; the 12-1 guard makes that sound (no class change strands stock; temperature classes can only have moved colder for bins that held stock). State the caveat in the endpoint's OpenAPI description — the report never fabricates historical classes it cannot prove.

## Verification

**Commands:**
- `bun run test -- cold-chain.spec.ts` (in wms-be) -- expected: all matrix rows pass
- `bun run test` -- expected: full suite green (748+ new tests), one jest process at a time
- `bun run lint && bun run typecheck` -- expected: clean
- `bun run openapi:export` twice -- expected: byte-identical second run
- `bun run db:migrate` -- expected: 0039 applies clean
- wms-fe `bun run api:generate` -- expected: idempotent regen, drift guard green

**Manual checks (if no CLI):**
- `drizzle/0039` journal entry present; `db:generate` after migrate reports no drift (expression index doesn't perturb the snapshot)