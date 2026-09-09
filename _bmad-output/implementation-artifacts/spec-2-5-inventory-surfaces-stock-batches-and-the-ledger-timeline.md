---
title: 'Inventory surfaces — stock, batches, and the ledger timeline'
type: 'feature'
created: '2026-09-09'
status: 'done'
route: 'dispatch'
review_loop_iteration: 0
baseline_commit: '2dbbce74b80d8f4b2a19498cd6074cce6d5cf73e'
context: []
story_key: '2-5-inventory-surfaces-stock-batches-and-the-ledger-timeline'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** The inventory module's traceability and projection reads (stock on-hand, batch on-hand/history, serial location/history, ATP snapshot, the ledger timeline) are facade-only — story 2.4 deferred their HTTP surfaces here, and no frontend can render the Inventory surface ("why is this number what it is" click-through) until they exist as HTTP reads.

**Approach:** Additive HTTP read routes on the existing inventory controller exposing the 2.1/2.3/2.4 facade reads: a stock list (on-hand projection per warehouse, filterable by SKU/bin), a batch list (catalog identity × inventory on-hand join, FEFO order) and per-batch/per-serial detail (identity, location, one-query history), plus additive timeline fields (batchRef/serialRef/referenceDoc) so every event carries its reference document. Also close the 2-4 deferral by documenting the adjustments endpoint's failure surface in OpenAPI. Reads only — no migration, no new writes, no capability gating.

## Boundaries & Constraints

**Always:**
- All routes session-guarded (`TenantSessionGuard` + `@ApiBearerAuth`), path-tenant asserted (`assertOwnTenant` → 403 `permission-denied`), never capability-gated (reads are never gated — the repo convention).
- Keyset-cursor pagination exactly like `listEvents`: `Page<T>` shape (`items`, `nextCursor`), `decodeCursorSafe` reused (strict uuid+instant regexes → 400 `invalid-cursor`, never a 500).
- Foreign warehouse → 404 `not-found` via the facades' existing `assertWarehouseInTenant`; unknown identity semantics per the CHECKPOINT resolution.
- OpenAPI is the contract: every new route documented with `@ApiOkResponse` + the 400/401/403/404 `problemJsonResponse` pattern; the adjustments POST gains its missing error `@ApiResponse` rows (closes the 2-4 deferral — additive response documentation only, no request-schema change).
- The timeline's additive fields (`batchRef`, `serialRef`, `referenceDoc`) are nullable passthroughs — legacy items (arms null) serialize identically apart from the new null fields.

**Never:**
- No new HTTP exposure of reservation mutations (`grantReservation`/`commitReservation`/`releaseReservation` stay facade-only until Epic 4) and no ATP route (deferred to Epic 4 — CHECKPOINT 1).
- No ledger-core HTTP surface beyond what 2.1 exposes (replay/verify/anchor are never HTTP).
- No writes, no migrations, no drizzle changes — this story reads only.
- No capability gating on reads; no new machine codes except any the CHECKPOINT picks.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Stock list | GET warehouse stock, optional `skuId`/`binId` filters | `{items: [{skuId, binId, quantity, …}], nextCursor}` — keyset pages to exhaustion, no dup/miss | Malformed cursor → 400 `invalid-cursor`; foreign warehouse → 404 |
| Batch list (FEFO) | GET batches, `skuId` required (+ optional `binId`) | Batches of that SKU joined with on-hand, **expiry ASC nulls-last, expired still listed** (order is data, not policy) | Unknown/foreign warehouse → 404; missing `skuId` → 400 |
| Batch detail | GET batch by id | Identity (code, mfg/expiry, dates), per-bin on-hand rows, full history (one query) | Unknown batch → 404 `not-found` (catalog existence check) |
| Serial detail | GET serial by id | `{serial, skuId, location: {warehouseId, binId} | null, history}` | Unknown serial → 404 `not-found` (catalog existence check) |
| Timeline enrichment | GET existing events route | Items additionally carry `batchRef`, `serialRef`, `referenceDoc` (nullable) | Existing 2.1 behavior byte-identical otherwise |
| Untracked passthrough | Stock list on a warehouse with only untracked SKUs | Plain `stock_on_hand` rows — no batch fields | N/A |

- RESOLVED at CHECKPOINT 1 (2026-09-09, human approved): **Unknown batch/serial identity on a detail GET returns 404 `not-found`** — via tiny `findBatch`/`findSerial` existence reads on CatalogFacade, checked at the api layer before the detail query.
- RESOLVED at CHECKPOINT 1 (2026-09-09, human approved): **No ATP HTTP route in 2.5** — deferred to Epic 4, where its consumers (order flows) land.
- RESOLVED at CHECKPOINT 1 (2026-09-09, human approved): **The timeline exposes the full `referenceDoc` passthrough** — each item carries the reference document itself (nullable; `{kind, reasonCode, note, overrideReason?}` today), serving the ≤2-navigations contract with zero extra queries; future event kinds extend it additively.

</frozen-after-approval>

## Code Map

- `src/api/inventory.controller.ts` — the routes home (`@Controller('tenants')`, `assertOwnTenant` helper :404-413); the 2.1 events GET (:371-401) is the route/error-doc pattern to copy; the adjustments POST (:59) gains only `@ApiResponse` docs.
- `src/modules/inventory/inventory.facade.ts` — `listEvents` (:198, `LedgerTimelineQuery`, keyset via `buildPage`, select at :210-224 gains the new nullable columns); `batchOnHand` (:381, `BatchOnHandEntry` :57-63); `serialHistory` (:414, `SerialLedgerEntry` :66-78); `serialLocation` (:448); `batchHistory` (:474); `atp` (:351). Add: a paginated stock-on-hand read (keyset `(created_at, id)` — the table has both) and any passthrough the CHECKPOINT requires.
- `src/modules/catalog/catalog.facade.ts` — `getBatches(tenantId, skuId)` (batch identity for the FEFO join); gains tiny `findBatch`/`findSerial` existence reads if CHECKPOINT picks 404. Catalog owns identity — inventory routes may compose it at the api layer (2.4 precedent).
- `src/modules/inventory/inventory.dto.ts` — `LedgerEventsQuery` (:170-188, `@ApiProperty` style), `LedgerEventDto` (:239, gains nullable `batchRef`/`serialRef`/`referenceDoc`), `LedgerEventListResponse` (:278); new query/response DTOs follow the same shape (limit 1–200, `@Type(() => Number)`).
- `src/shared/primitives/pagination.ts` — `encodeCursor`/`decodeCursor`/`buildPage`; `decodeCursorSafe` in inventory.facade.ts:101-134 is the 400-`invalid-cursor` pattern to reuse (strict uuid/instant regexes — do not weaken).
- `src/shared/problem-details/problem-details.openapi.ts` — `problemJsonResponse(description)` for the error docs.
- `test/batch-serial.spec.ts` — fixture seed (tenant → owner/ops members → warehouse/zone/bins → catalog import CSV with tracking flags → `skuIds` map; `adjust(body, key)` helper; `cleanupRows` incl. `reconciliation_checkpoints`; env bootstrap + advisory lock 742105) — reuse verbatim for the new suite.
- `test/ledger.spec.ts:565-598` — the canonical keyset-cursor e2e pattern (walk pages to exhaustion, no dup/miss, crafted-but-invalid cursor → 400 `invalid-cursor`).
- `openapi/openapi.json` — regenerated by `bun run openapi:export`; CI drift-guards both repos; wms-fe regenerates its client from it after merge.

## Tasks & Acceptance

**Execution:**
- [x] `src/modules/inventory/inventory.facade.ts` — add a paginated stock-on-hand read (warehouse-scoped, optional skuId/binId filters, keyset like `listEvents`); extend `listEvents`'s select + `LedgerTimelineEntry` with nullable `batchRef`/`serialRef`/`referenceDoc`.
- [x] `src/modules/catalog/catalog.facade.ts` — per CHECKPOINT: tiny `findBatch`/`findSerial` existence reads (or skip).
- [x] `src/api/inventory.controller.ts` + `src/modules/inventory/inventory.dto.ts` — new GET routes (stock list under the warehouse; batch list + batch/serial detail; query/response DTOs with `@ApiProperty`); timeline DTO gains the additive nullable fields; adjustments POST gains the missing `@ApiResponse` failure docs (400 batch-arm 400s, 409 `duplicate-serial`, 422 arms).
- [x] `openapi/openapi.json` — regenerate via `bun run openapi:export`; diff must be additive only (new routes + response docs).
- [x] `test/inventory-surfaces.spec.ts` (new suite, batch-serial fixture style) — the I/O matrix: stock list pagination + filters, FEFO batch order, batch/serial detail incl. history, timeline enrichment, `invalid-cursor` 400, foreign-warehouse 404, unknown-identity semantics per CHECKPOINT.

**Acceptance Criteria:**
- Given seeded stock (tracked + untracked SKUs), when each new route is called, then it returns the projection/facade truth with keyset pagination where paginated and no second source of truth is created (reads go through the facades only).
- Given the pre-2.5 timeline contract, when the events route is called, then every prior field is unchanged and the new fields are additive nullable.
- Given `bun run openapi:export`, then the diff is purely additive (new GET routes + the adjustments' error docs) and wms-fe can regenerate its client from it.

## Implementation Notes

## Spec Change Log

## Review Triage Log

| # | Layer | Finding | Verdict | Evidence / Route |
|---|-------|---------|---------|------------------|
| 1 | blind | `getBatch`/`getSerial` take raw path params with no uuid guard — a malformed id reaches `eq(uuid, 'garbage')` and surfaces as a 500, but only 401/403/404 are documented | **medium** | Verified: no `ParseUUIDPipe` in `src/`; `problem-details.filter.ts:53` maps unhandled faults to 500 `internal-error`; Postgres raises `invalid_text_representation` on the cast. Route: **patch** (G1) |
| 2 | blind | Batch-list `skuId` documented "required — 400 when omitted" but declared optional in DTO/OpenAPI — contract machinery contradicts prose | **false** | Refuted: `required: false` + a documented 400 for omission is the accurate representation — marking it required would make the documented 400 unreachable; the prose inside the description explains the behavior |
| 3 | blind | `listBatches` accepts an unknown well-formed skuId → 200 `{items: []}` while detail routes 404 on unknown identity | **false** | Refuted: query filters narrow, path resources 404 (repo convention — the events route 404s the warehouse path resource, filters return the true empty answer). The stock list's `binId` behaves identically, so the change is internally consistent |
| 4 | blind | Batch list has no pagination — a long-lived SKU accumulates batches without bound | **low** | Real long-tail growth, but a deliberate recorded tradeoff (Design Notes: finite per-SKU batch count); the fix adds a public pagination surface. **Rejected** — unlikely in everyday use and the fix is more than a direct correction |
| 5 | blind | Batch/serial detail return the FULL history unbounded — no limit or cursor | **low** | The frozen I/O matrix requires "full history (one query)" — the fix would edit this build's frozen spec. **Rejected** on that rule; growth is a long-tail concern (defer-if-ever territory, not this change) |
| 6 | blind | `BatchBinOnHandEntry.skuId` comment promises "the api layer's identity cross-check" but `getBatch` never cross-checks and drops the skuId | **low** | Verified: `inventory.facade.ts:79` comment vs `getBatch` mapping bins with no comparison. Developer harm: a maintainer trusts a check that does not exist. Route: **patch** (G4 — fix the comment; a drift guard would guard un-demonstrated state) |
| 7 | blind | `listStock` binId filter from another warehouse → empty 200, asymmetric with the warehouse's 404 | **false** | Refuted: the rows genuinely are empty (bin-scoped projection rows of this warehouse); path resources 404, filters narrow — the same convention as row 3 |
| 8 | blind | `canonicalDate` unguarded — an unparseable catalog date throws a raw 500 out of a read route | **false** | Refuted: `mfgDate`/`expiryDate` are `timestamp({mode:'string'})` columns rendered by Postgres itself (always parseable) and intake validates the ISO shape (`BatchInputDto` length 20–35, Z-suffixed); an unparseable string is unreachable without DB corruption |
| 9 | blind | Contract prose degraded: `LedgerEventListResponse.nextCursor` loses its "Opaque keyset cursor" description; new nextCursor fields carry none | **false** | Refuted by generated-JSON inspection: HEAD's `nextCursor` is `{"type":"string","nullable":true}` — no description — and the working tree is identical; the new fields match the existing convention; nothing was lost |
| 10 | blind | `StockEntryDto.quantity` documents "non-negative" but the OpenAPI schema has no `minimum: 0` | **low** | True — the constraint exists only as prose; the schema is the contract. Route: **patch** (G5 — `minimum: 0` on the DTO property + regen) |
| 11 | blind | Missing e2e for the batch detail's tenant-wide claim — every seeded batch sits in one warehouse, `bins` only ever asserted as a single row | **low** | Verified against the suite: all batch stock is seeded in one warehouse; "per-bin on-hand rows across every warehouse" is never observed. Route: **patch** (G6) |
| 12 | blind | Missing e2e for the stock list's `limit` bounds (0/201/non-integer) — only `invalid-cursor` is exercised | **low** | Same claim as row 20 (verified by the verification-gap layer). Route: **patch** (G3, grouped) |
| 13 | blind | BS-1 (both-arms SKU) imported but never used — `SerialLedgerEntryDto.batchRef` and `BatchLedgerEntryDto.serialRef` never observed on the wire | **low** | Verified: the suite's serial events are batch-less; the detail-history cross-refs always read null. Route: **patch** (G2, grouped with row 19) |
| 14 | blind | `location` documents "null when never moved" but the null branch is never exercised | **false** | Refuted: serials are minted by the same adjustment that appends their intake event (`ensureSerial` inside the compose step, one transaction) — a serial with zero events is unreachable via the API; the DTO description is defensive prose |
| 15 | blind | `dbCount` builds `and sku_id = '${…}'::uuid` by string interpolation into `sql.unsafe` while siblings use the parameter form | **low** | Verified (test-only, API-issued uuid constants; no reachable harm) — but the direct fix is one line. Route: **patch** (G7) |
| 16 | blind | Missing trailing newline in `inventory.dto.ts` and the new test file — format-drift guard fodder | **false** | Refuted: the repo convention is mixed (batch-serial.spec.ts itself ends without a newline; ledger.spec.ts with one); no eol/prettier rule exists; the dto's `-` side shows HEAD already had this shape, and lint passes |
| 17 | blind | `opsToken = ownerToken` — "never capability-gated" never checked against a non-owner session | **low** | The no-gating property is structural (no `assertPermission` call exists on any read route to toggle); a fixture expansion doesn't earn its keep. **Rejected** |
| 18 | blind | 422 description garbled: "would drive on-hand — or the resolved/overridden batch's — below zero" leaves the elided noun implicit | **low** | Verified string — parseable ellipsis but unclear at read speed. Route: **patch** (G5 — name the noun) |
| 19 | vgap | Timeline `serialRef` passthrough's non-null path has no test — the `listEvents` select can break silently (mutation demonstration filed) | **medium** | Pre-verified by the layer: the enrichment test asserts `serialRef` only as null; swapping the select column keeps 211/211 green. Route: **patch** (G2) |
| 20 | vgap | Stock-list `limit` bounds (1..200) untested — the facade's no-clamp contract depends on them | **medium** | Pre-verified by the layer: dropping `@Min/@Max` ships an unbounded value into `.limit()` with no failing test. Route: **patch** (G3) |
| 21 | edge | Non-UUID batchId path param reaches `findBatch`'s eq → 500 instead of the documented 404 | **medium** | Same location and claim as row 1 — verified there. Route: **patch** (G1) |
| 22 | edge | Non-UUID serialId path param reaches `findSerial`'s eq → 500 | **medium** | Same claim as row 1 — verified there. Route: **patch** (G1) |
| 23 | edge | Unknown valid-uuid skuId on the batch list → 200 `{items: []}`; detail routes 404, list does not | **false** | Same claim as row 3 — same refutation (filters narrow, path resources 404) |
| 24 | edge | Batch intake between the parallel `getBatches`/`batchOnHand` reads → the new batch's on-hand joins to nothing | **low** | Verified race window exists (two facade transactions) but the consequence is a one-request stale, self-healing list read; no snapshot-isolation promise exists in the contract, and sharing one transaction restructures two facades. **Rejected** — unlikely met, fix not a direct correction |
| 25 | edge | `canonicalDate` on an unparseable string throws RangeError → 500 | **false** | Same claim as row 8 — same refutation |
| 26 | edge | Claim: regenerated openapi drops `nextCursor` from `LedgerEventListResponse.required` | **false** | Refuted by deep-sorted inspection: HEAD and working tree both have `required: ['items']` and identical `nextCursor` — the apparent drop is the diff aligning the removal of `SkuListResponse` (which did have `[items, nextCursor]`) with the moved `LedgerEventListResponse` block |
| 27 | edge | Claim: spec requires the 400/401/403/404 pattern on every new route, but detail routes document no 400 while the malformed path 500s | **medium** | Same root cause as row 1; with the 404-guard fix no 400 row is needed (a malformed id is an unknown identity → the documented 404). Route: **patch** (G1) |
| 28 | edge | Batch list unbounded: `getBatches` has no limit and `ensureBatches` mints identity rows per unique code | **low** | Same root cause as row 4 — same rejection (deliberate tradeoff; fix adds pagination surface) |
| 29 | edge | `batchBinsOnHand` comment promises a cross-check `getBatch` never performs | **low** | Same claim as row 6 — verified there. Route: **patch** (G4, grouped) |


## Design Notes

- **FEFO order is data, not policy, on reads.** The batch list orders `expiryDate ASC NULLS LAST` (same comparator as the 2.4 draw resolution) but lists expired batches too — exclusion of expired stock is the *draw* policy (2.4), not a read filter. The FE shows the order; Epic 4's pick engine consumes the same composition.
- **Detail routes are tenant-level.** Serials cross warehouses (tenant-wide location) and batches are tenant-scoped identity — both detail routes live at `.../inventory/{serials,batches}/:id`, NOT under a warehouse; their payloads carry the warehouse/bins where the state lives.
- **The batch list joins at the api layer** (catalog `getBatches` × inventory `batchOnHand`) exactly like the FEFO resolution — module direction holds; neither facade imports the other.
- **The batch list is deliberately unpaginated** (implementation-verified): a SKU's batch count is finite and small (identity rows only, one row per batch code); the I/O matrix requires `nextCursor` only on the stock list, which reads the unbounded `stock_on_hand` projection. `Page<T>`/keyset applies to the paginated reads; the batch list returns a plain `{items}` with FEFO ordering.

## Verification

**Commands:**
- In `wms-be`: `bun run db:migrate && bun run test` — all green incl. the new `test/inventory-surfaces.spec.ts`.
- `bun run lint && bun run typecheck` — clean; no drizzle changes (verify `git status` shows no `drizzle/` edits).
- `bun run openapi:export && git diff openapi/openapi.json` — additive only: new GET routes + the adjustments' `@ApiResponse` docs; zero request-schema changes.

**Manual checks:**
- From the seeded fixture: walk the stock list and batch list to exhaustion via `nextCursor`; fetch a serial detail and confirm location + full history match the facade reads.