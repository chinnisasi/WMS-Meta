---
title: '1.5a Client filter — one client switcher filters every staff list, stock and stock history'
type: 'feature'
created: '2026-10-19'
status: 'ready-for-dev'
baseline_commit: '2dacebc06a43fd33a0db1af7fe2c097da5c87232'  # wms-be; wms-fe: a4fd560fae3a1652d28c6dc1788af5e604d7d225; wms-mobile: 3a208c070c2bb7f9c74a274a2d36db6af028db0e (unchanged by this story)
route: 'dispatch'
review_loop_iteration: 0
context:
  - 'docs/initiatives/production-readiness.md'
  - 'docs/design/SYSTEM-DESIGN.md'
  - 'docs/design/IMPLEMENTATION-GUIDE.md'
  - 'docs/design/modules/clients.md'
  - 'docs/design/modules/inventory.md'
  - 'docs/design/modules/inbound.md'
  - 'docs/design/modules/outbound.md'
  - 'docs/design/frontend/SYSTEM-DESIGN.md'
  - 'docs/design/frontend/IMPLEMENTATION-GUIDE.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** A 3PL holds many clients' goods, but staff cannot narrow any screen to one client.
- Only three staff lists accept a `clientId` filter today: ASNs, client invoices and partners.
- Stock, stock history (the ledger), POs, GRNs, orders, waves, returns, the catalog and the review queues all show every client mixed together.
- A filter run in the browser over one loaded page would miss rows on later pages, so the server must filter.
- PENDING (clients) records "No client filters on lists" as open.

**Approach:**
- **Backend:** an optional `clientId` query parameter on every staff list and on the stock and ledger reads, filtered in SQL before the page limit.
- **Web:** one client switcher in the shell, beside the warehouse switcher, that every list screen reads.
- **Indexes** so the filtered lists stay fast.

**Decisions (user, 2026-10-19):**
1. **Split.** 1.5a is this filter; 1.5b (dedicated client bins enforced in putaway, moves and merge) is in deferred-work.
2. **One global switcher.** "All clients" by default; picking a client filters every list, stock and history screen at once. Remembered in the browser like the warehouse. Hidden for a single-client tenant (`showClients` false).
3. **No handheld change.** The floor works the warehouse queue whoever owns the goods; client rules on the floor arrive with 1.5b.
4. **Mixed rows show when any part is the client's.** A wave, manifest, transfer or legacy mixed GRN appears under client A when any of its orders or lines is A's.

**Decisions (agent):**
5. **Server-side, composable.** The filter composes with each list's existing filters and its own keyset. A switch always restarts from page 1 (no cursor carries across).
6. **Unknown or other-tenant `clientId` → empty page, never 404** (the ASN precedent). Malformed → 400 `validation-failed`.
7. **Departed clients stay selectable,** labelled, so their history can be read.
8. **The stored pick survives a slow or failed clients list.** While clients load, lists wait; if the clients list fails, lists show all clients and the switcher says the client list is unavailable. A stored client absent from a loaded list is ignored (lists unfiltered) but never erased.
9. **Rows with no client of their own match through their lines** (decision 4): a legacy GRN whose `client_id` is null matches any client of its lines' SKUs.
10. **Write-side screens are never filtered.** Wave generation, the manifest builder and the QC-hold form keep acting on all clients and say so ("All clients"); a carrier pickup is never split by client. Create forms default their client to the active one; a create for another client succeeds and says "Created for X — hidden by the client filter".
11. **Drills ignore the switcher.** An overview or document drill sends no `clientId` and shows "All clients", so the drill still equals its tile and a document's history is never hidden.
12. **Lookups and pickers are never filtered:** SKU maps, the vendor map, the kits map, bin ledger timelines, stock scopes. Mixed rows keep their names.
13. **Partners are not filtered.** They are shared across clients (roadmap D3), and transporters have no client link.
14. **The stored pick is per tenant and per user,** so a shared workstation never inherits another user's filter.
15. **Client-portal sessions are unchanged.** Staff lists keep refusing portal sessions first (403 before validation).

## Boundaries & Constraints

**Always:**
- **Query DTOs.** Each route below gains `@ApiProperty({required:false, format:'uuid'}) @IsOptional() @IsUUID() clientId?: string`, copied from `AsnListQuery` (`modules/inbound/inbound.dto.ts:422-425`).
  - `OrderListQuery` is shared by orders, manifests, waves **and wave-policies** (`api/outbound.controller.ts:470,660,731,1045`). Wave-policies gets its own DTO without `clientId`; the other three keep `OrderListQuery` with it.
  - Waves (`:1045-1049`) and manifests (`:660-664`) pass only cursor/limit to their facades today. Their controllers must pass `clientId` explicitly, and the facade query types gain it. E-way bills pass the DTO whole; its facade reads `clientId` explicitly.
  - Catalog list commands are positional (`skuCommand.list`, `productCommand.list`, `kitCommand.list(tenantId, cursor, limit)`); `clientId` is added as a named option object, not a fourth positional argument.
- **Predicate per list**, inside the existing tenant transaction, before the limit:
  - **Own column** (`eq(t.clientId, $c)`): purchase orders, orders, RMAs (`GET /returns`), ledger events, SKUs, products, kits (kit SKUs).
  - **GRNs:** `client_id = $c` OR (`client_id IS NULL` AND `EXISTS` a line whose SKU is `$c`'s) — decision 9.
  - **Through the SKU** (`sku_id IN (SELECT id FROM skus WHERE tenant_id = $t AND client_id = $c)`): stock on hand (both paths — `listStock` by `(createdAt,id)` and `listStockByLocation` with its own cursor, `inventory.facade.ts:784,812-880`), putaway tasks and placements, over-receipts, QC holds (all kinds, including manual holds with no GRN), adjustment pendings, count variances, replenishment breaches, batch alerts, suggested POs, replenishment policies.
  - **Backorder refusals** (no order; `lines` jsonb of `{skuId,…}`): `EXISTS (SELECT 1 FROM jsonb_array_elements(r.lines) l JOIN skus s ON s.tenant_id = r.tenant_id AND s.id::text = l->>'skuId' WHERE s.client_id = $c)`.
  - **Through orders, any-match:** waves (via `picklist_lines.wave_id` → `order_id`), picklist lines and pack failures (own `order_id`), manifests (via `shipments.manifest_id` → order). A wave with no lines matches no client.
  - **Through the order, single:** tax invoices (`invoices.order_id`), e-way bills (→ invoice → order).
  - **Transfers, any-match** over line SKUs.
  - **Putaway tasks** are derived and unpaginated (`getPutawayTasksInTx`, shared with the device snapshot and KPIs): the non-InTx wrapper takes an optional `clientId` and filters by the line's SKU; the InTx callers are unchanged.
  - ASNs, client invoices and partners already filter and are unchanged. Batches (per-SKU, `skuId` required) take no client filter.
- **Migration 0081 (indexes only):**
  - `(tenant_id, client_id, warehouse_id, created_at, id)` on `purchase_orders`, `orders`, `goods_receipt_notes`, `return_authorizations` and `ledger_events` — matching each list's `(created_at, id)` keyset. Copy the exact leading columns of each table's existing keyset index.
  - `(tenant_id, client_id, created_at, id)` on `goods_receipt_notes`, for the GRN list without `warehouseId`.
  - Built non-concurrently (the migrator wraps all migrations in one transaction), with the 0058 comment; a PENDING note records a manual `CONCURRENTLY` build for large tenants.
  - `EXPLAIN` of the filtered orders and ledger queries in the migration test shows the new index used.
- **Web, active client:**
  - `lib/active-client.ts`: `readActiveClientId(tenantId, userId)`, `writeActiveClientId(tenantId, userId, id | null)`, `subscribeActiveClient`, `ACTIVE_CLIENT_CHANGED_EVENT` — the `lib/warehouses.ts:20-55` shape, storage in try/catch; cleared on logout.
  - One clients read per screen: a `useActiveClient()` hook returns `{ state: 'pending' }` (stored id, clients loading), `{ state: 'client', client }`, or `{ state: 'all' }` (nothing stored, single-client tenant, stored id absent, or clients failed). It never writes storage.
  - **List hooks take `clientId: string | null` as an explicit argument;** screens call `useActiveClient()` once and pass it down. A hook given `pending` does not fetch. `clientId` joins every place the hook stamps its scope: the requested-cursor stamp, the result stamp, the render-time stale check, the effect deps, and the `<DataTable key>` (frontend guide §1.11). A switch therefore never reuses a cursor or renders the previous client's rows.
  - `components/shell/client-switcher.tsx` beside `warehouse-switcher.tsx`, in `sidebar.tsx:37` and the `app-shell.tsx` header mount; options "All clients" then clients in the API's order (self first), labelled with `clientLabel(client, tenantName)`, departed ones marked.
  - `ClientFilterChip` on every filtered screen: "Client: <label>" with a "Show all clients" action (so the filter can be cleared at widths where the sidebar is hidden). Unfiltered tabs and screens on a filtered page (excursions, rejected ops, HSN, cold chain, overview) show "All clients".
  - Wave detail lists each order's client when `showClients` is true.
  - The inbound tab counts (`useInboundTabCounts`) take the same `clientId`.
  - `reports/client-service.tsx`: the selected client is `chosenClient ?? activeClient ?? list[0]`; a local pick wins.

**Never:**
- No handheld change (decision 3).
- No dedicated client bins or any write-path rule (1.5b).
- No change to portal routes or RLS.
- No client filter on: the audit trail, rejected device ops, temperature excursions, HSN summary, cold-chain trace, ledger integrity, overview tiles, channels, notifications, partners, batches, drills, write-side screens (decision 10) or lookups (decision 12).
- No URL parameter for the client.
- No new `client_id` column on any table.
- No change to status filters.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected | Error |
|---|---|---|---|
| Own-column list | orders of GLOWCO and self; `?clientId=GLOWCO` | only GLOWCO orders, paged | N/A |
| Beyond page 1 | `limit=2`; 3 self orders, then 2 older GLOWCO | first filtered page holds the 2 GLOWCO orders | N/A |
| Stock through SKU | both clients' stock in one bin, both stock orders | only GLOWCO SKUs' rows | N/A |
| Ledger | events of both clients | only GLOWCO events | N/A |
| Mixed wave / manifest / transfer | one GLOWCO and one self order or line | appears under both | N/A |
| Legacy mixed GRN | `client_id` null, lines of both clients | appears under both | N/A |
| Manual QC hold | no GRN, GLOWCO SKU | appears under GLOWCO | N/A |
| Backorder refusal | lines jsonb with a GLOWCO SKU | appears under GLOWCO | N/A |
| Unknown client | random uuid | 200, empty page | N/A |
| Malformed client | `abc` | none | 400 `validation-failed` |
| Composes | `?status=open&clientId=GLOWCO` | open GLOWCO POs only | N/A |
| Wave-policies | `?clientId=…` | none | 400 (not accepted) |
| Portal session | client user calls a staff list | unchanged refusal | existing 403 |
| Web switch | on page 2 under All, pick GLOWCO | request has `clientId`, no cursor; previous rows not shown; chip "Client: GlowCo" | N/A |
| Web clients loading | stored GLOWCO, slow `/clients` | no list request until clients load | N/A |
| Web clients failed | stored GLOWCO, `/clients` fails | lists unfiltered; switcher says clients unavailable; stored pick kept | N/A |
| Web stale stored client | stored id not in loaded list | lists unfiltered, no `clientId`, storage untouched | N/A |
| Web single client | only self | no switcher, no chip, no `clientId` even with a stored id | N/A |
| Web drill | overview drill while GLOWCO stored | drill request has no `clientId`; "All clients" shown | N/A |
| Web create for another client | GLOWCO active, order created for self | 201; "Created for <self> — hidden by the client filter" | N/A |
| Web wave generate / manifest builder | GLOWCO active | unchanged, all clients, labelled "All clients" | N/A |

</frozen-after-approval>

## Code Map

**Backend (`wms-be/src`)** — `api/` = `src/api/`, `mod/` = `src/modules/`. Precedents: `mod/inbound/inbound.dto.ts:422-425`, `mod/inbound/inbound.facade.ts:252`, partners' `EXISTS` at `mod/partners/partners.facade.ts:371-379`. `forbidNonWhitelisted` is on: a route whose DTO lacks the field answers 400.
- Inbound: POs `api/inbound.controller.ts:121`.
- Receiving: GRNs `api/receiving.controller.ts:248` (warehouse optional, `receiving.facade.ts:282-284`); over-receipts `:294`; QC holds `:507` (already joins `skus`, `qc.facade.ts:183-188`).
- Putaway: tasks `api/putaway.controller.ts:112/135` (`getPutawayTasks` wrapper), placements `:144`.
- Outbound: orders `api/outbound.controller.ts:452/470`; manifests `:645/660`; wave-policies `:731` (own DTO); waves `:1030/1045`; picklist lines `:492`; pack failures `:525`; backorder refusals `:560` (`schema.ts` `ingest_backorder_refusals`, `lines` jsonb).
- Returns: `api/returns.controller.ts:222` (`return_authorizations`).
- Inventory: stock `api/inventory.controller.ts:774` (two facade paths); ledger events `:612` (`inventory.facade.ts:666` keyset); adjustment pendings `:277`.
- Movements: variances `api/movements.controller.ts:521`; transfers `:609`.
- Replenishment: `api/replenishment.controller.ts` policies `:146`, breaches `:172`, suggested POs `:237`, batch alerts `:384`.
- Invoicing: `api/invoicing.controller.ts:103`; e-way `api/eway.controller.ts:63/86`.
- Catalog: `mod/catalog/catalog.controller.ts` SKUs `:212`, products `:407`, kits `:671`; commands `kit.command.ts:276` and the SKU/product `list`.
- `drizzle/0081_client_filter_indexes.sql` + snapshot + journal; index declarations in `shared/db/schema.ts`.
- `openapi/openapi.json` regenerated.
- Tests: `test/client-filter.spec.ts`.
  - Fixture: reuse `test/support/dispatched-order.ts` (`dispatchedOrderFixtures`), `test/support/linked-vendor.ts` (`tenantClientIds`) and the client setup in `per-client-sku.spec.ts`. Derived fact rows (breach, alert, variance, refusal, pack failure, QC hold, over-receipt) may be raw-inserted — the subject is the read predicate.
  - One canonical route table drives the tests: for each route, a matching and a non-matching row, asserting exact ids (so an ignored parameter fails).
  - Plus every backend matrix row, the departed client, the portal 403, and wave-policies refusing the parameter.
  - The migration test runs `EXPLAIN` on the filtered orders and ledger queries.

**Web (`wms-fe/src`)**
- New `lib/active-client.ts`, `useActiveClient()`, `components/shell/client-switcher.tsx`, `components/shared/client-filter-chip.tsx`.
- `lib/api/client.ts`: list wrappers take an optional `clientId`, sent only when set; `bun run api:generate` after the backend lands (the FE PR merges after the BE PR).
- List hooks gain the `clientId` argument and the scope stamps:
  - Inbound `inbound-cards.tsx`: `usePurchaseOrders`, `useGoodsReceipts`, `usePutawayTasks`, `useQcHolds` (the list one only — the hold form's `openHolds` at `:867` and `useStockScopes` `:866` stay unfiltered); `asn-card.tsx` `useAsns`; `use-inbound-tab-counts.ts:63-71`.
  - Outbound `outbound-orders.tsx` `useOutboundOrders` (the list only; the wave-generate picker `outbound-waves.tsx:356` and `usePipelineOrders` in pack-dispatch stay unfiltered), `outbound-waves.tsx` `useOutboundWaves`, `useManifests` (`use-outbound-labels.ts:237`, the list only).
  - Inventory `inventory-screen.tsx` `useStockList` (`use-inventory.ts:178`); `ledger.tsx:141` `useLedgerEvents`. When a client is active, the stock SKU search narrows its suggestions with `skusOfClient` (`lib/clients.ts:237`).
  - Conflicts: `over-receipt-queue.tsx:88`, `variance-queue.tsx:83`, `adjustment-pendings-queue.tsx:87`.
  - Replenishment `replenishment-view.tsx`: breaches, batch alerts, suggested POs, `useReorderPolicies` (`use-replenishment.ts:301`).
  - Returns `returns-view.tsx` (`use-returns.ts:34`).
  - Compliance `invoices.tsx`, `eway-bills.tsx`, `client-invoices.tsx` (the list; `client-usage.tsx:76` keeps its own id).
  - Settings `sku-table.tsx`, `products-card.tsx`.
- Drill hooks (`lib/drill-fetch.ts`) never receive `clientId`.
- Create forms (order, ASN, PO, return, SKU, product) default their client picker to the active client and show the hidden-by-filter note.
- Never filtered (decision 12): `useSkuMap`, `useSkuCatalog`, `useCatalogSkus`, `useOutboundSkus`, `useVendorMap` (`use-inbound.ts:460`), `useKits` (`use-catalog.ts:251`), `useBinLedgerEvents`.
- Backend-only (no web consumer yet): transfers, picklist lines, pack failures, backorder refusals.
- Tests:
  - `client-switcher.test.tsx`, `active-client.test.ts`: per tenant + user, cleared on logout, departed label, single client hidden.
  - One test per list hook or screen above: under a stored client, the request carries `clientId` and the chip renders.
  - The switch test: page 2 under All → pick GlowCo → no cursor, Prev disabled, old rows gone; back to All → no `clientId`.
  - Pending, failed and stale states.
  - The drill test in `drill-screens.test.tsx`; the wave-generate and manifest-builder tests unchanged under a stored client; `client-service.test.tsx` precedence.
  - Switcher tests clear storage after each case.

**Handheld (`wms-mobile`)** — no change.

## Tasks & Acceptance

**Execution:**
- [ ] `wms-be` DTOs (wave-policies split), controllers passing `clientId`, predicates per list -- server-side client filter
- [ ] `wms-be` 0081 indexes + schema + EXPLAIN test + openapi -- filtered lists stay fast
- [ ] `wms-be` `test/client-filter.spec.ts` -- route table and matrix
- [ ] `wms-fe` active-client store and hook, switcher, chip, hook arguments and scope stamps, create defaults, exemptions, tests -- the web filter
- [ ] Meta docs (land last): `API-SURFACE.md` (`clientId` per route), `docs/design/frontend/SYSTEM-DESIGN.md` and `IMPLEMENTATION-GUIDE.md` (the switcher and the hook rule), `modules/clients.md`, `docs/repos/wms-be|wms-fe/README.md`, PENDING (close "No client filters on lists"; the CONCURRENTLY note; 1.5b)

**Acceptance Criteria:**
- Given a tenant with clients self and GlowCo, when an ops manager picks GlowCo, then the stock, stock history, PO, GRN, order, wave, return, invoice and catalog lists show only GlowCo's rows from page 1, each shows "Client: GlowCo", and "Show all clients" restores everything.
- Given a wave holding one GlowCo and one self order, when either client is chosen, then the wave appears, and its detail names each order's client.
- Given GlowCo's 2 orders are older than a full first page, when GlowCo is chosen, then the first page lists them.
- Given GlowCo is chosen, when the user opens an overview drill, generates a wave or builds a manifest, then those act on all clients and say "All clients".
- Given a tenant with only its own client, when any list opens, then no switcher and no chip appear.
- Given a staff list called with an unknown client id it returns an empty page; with a malformed one, 400.

## Implementation Notes

## Spec Change Log

## Review Triage Log

**Design review, 2026-10-19.** Three reviewers: backend (B1–B14), edge cases (E1–E18), web and contract (F1–F18). 50 raw findings, 29 after merging duplicates; load-bearing claims re-checked by hand (`OrderListQuery` at `outbound.controller.ts:470,660,731,1045`; ledger keyset `inventory.facade.ts:666`; `qc_holds.grn_line_id` nullable for manual holds; `ingest_backorder_refusals` has only a `lines` jsonb; drill hooks in `lib/drill-fetch.ts`). Every confirmed finding is patched above.

- D1 high (B1, E2, E3, F3): over-receipts and QC holds "through the GRN" hid manual holds and legacy-GRN rows. Both filter through the SKU.
- D2 high (B2, E1): backorder refusals have no order. jsonb any-match over line SKUs.
- D3 high (B3): waves and manifests drop query fields in the controller. Wiring named per route; tests use a non-matching row.
- D4 high (B4, E13): `OrderListQuery` also serves wave-policies. Wave-policies gets its own DTO.
- D5 high (E4, F2): drills would break tile parity and hide document history. Decision 11: drills ignore the switcher.
- D6 high (E5, F1): the "reload key" doesn't exist; cursors and stale rows would carry across a switch. `clientId` joins every scope stamp and the table key; switch test named.
- D7 high (E6, F5): slow or failed clients list. Decision 8 rewritten: pending waits, failed shows all with a notice, stale ignored and never erased.
- D8 high (E8, E9, F4): wave generation, the manifest builder and the QC-hold form share filtered hooks. Decision 10: write-side screens unfiltered and labelled; hooks take `clientId` explicitly.
- D9 med (B5, E14): the 21-4 ledger index can't serve the `(created_at, id)` keyset. New ledger index, proved by EXPLAIN.
- D10 med (B6, E15): indexes must end in `id`; GRNs need a tenant-wide shape; `return_receipts` has no list. Fixed.
- D11 med (B7): stock has two query paths. Both named.
- D12 med (B8): putaway tasks are derived and unpaginated. Wrapper-level filter.
- D13 med (B9): the single HTTP-seeded fixture was infeasible. Helpers named; derived rows raw-inserted; `limit=2` beyond-page test.
- D14 med (E7, F5): one `/clients` fetch per hook. One read per screen.
- D15 med (E10, F9): inbound tab counts unfiltered. They take `clientId`.
- D16 med (E11, F7): lookups share filtered wrappers. Decision 12 names them; stock SKU search narrows its suggestions.
- D17 med (E12): the partners filter hides transporters. Decision 13: partners unfiltered.
- D18 med (E16): the wave detail did not show clients. Added.
- D19 med (E17, F11): a create for another client vanishes. Create defaults and the hidden-by-filter note.
- D20 med (F6): Code Map web entries wrong (queue hooks, kits, pack-dispatch, policies, ledger line). Corrected; backend-only lists marked.
- D21 med (F10): no switcher at 768–1023px. The chip clears the filter.
- D22 med (F12, F13, F14): per-hook, switch, stale, single-client and backend matrix tests were unnamed. Named.
- D23 low (B10, F8): batches are per-SKU. Dropped.
- D24 low (B11): invoices and e-way bills are single-order. Wording fixed.
- D25 low (B12, E3): decision 9 conflicted with decision 4. Legacy GRNs any-match over lines.
- D26 low (B13): non-concurrent index builds. Commented; PENDING note.
- D27 low (B14): positional catalog list signatures. Option object.
- D28 low (E18, F15, F16): mixed tabs, report precedence, per-user storage, other tabs, ordering and labels. All written in; other open tabs refilter on a switch, as the warehouse switcher does.
- D29 low (F17, F18): FE PR after BE merge; test storage hygiene. Written in.

Rejected: none.

## Design Notes

**Why server-side.** Status filters run over the loaded page (`filterPage`), which is fine for a status on a recent page but wrong for a client: a client whose rows are all older than the first page would show an empty list. Every paged list keys on its own cursor, so one predicate before the limit is the change per route.

**Why one switcher, not a URL parameter.** The user chose one global switcher. It mirrors the warehouse: in the browser, outside the URL. Keeping it out of the URL leaves the drill parser alone, and drills deliberately ignore it (decision 11).

**Why any-match for mixed rows.** Hiding a mixed wave from both clients would hide real work for both. Any-match never hides a client's goods; the wave detail names each order's client.

**Why write-side screens stay unfiltered.** A carrier pickup is one batch whoever owns the parcels, and wave generation by policy sweeps every client server-side. Filtering their pickers would split a pickup or show a picker that disagrees with what the server does.
