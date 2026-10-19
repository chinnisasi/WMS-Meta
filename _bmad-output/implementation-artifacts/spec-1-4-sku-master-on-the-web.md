---
title: '1.4 SKU master on the web — single SKU create, full edit, shelf life, multiple barcodes, case/pallet pack levels'
type: 'feature'
created: '2026-10-19'
status: 'done'
baseline_commit: '1598ef8b7b994d76f8f0fb705571bc1eeecaa018'  # wms-be; wms-fe: ae641880ab292c7f1da560cf6582080240b3a26a; wms-mobile: 3a04b50152c0a1df543c2cc0a3b8f0a71bff0600 (branches feat/1-4-sku-master-on-the-web)
route: 'dispatch'
review_loop_iteration: 0
context:
  - 'docs/initiatives/production-readiness.md'
  - 'docs/design/SYSTEM-DESIGN.md'
  - 'docs/design/IMPLEMENTATION-GUIDE.md'
  - 'docs/design/modules/catalog.md'
  - 'docs/design/frontend/IMPLEMENTATION-GUIDE.md'
  - 'docs/design/mobile/IMPLEMENTATION-GUIDE.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** SKUs reach the system only through the catalog import, and there is no way to create a single SKU.
- A SKU has one barcode, and nothing records how many units a case or pallet holds.
- The handheld adds one unit per scan, so receiving a pallet of 40 cases of 12 means 480 scans or typing the quantity.
- There is no shelf life on the SKU, which roadmap 2.4 needs in order to derive expiry.
- `batchTracked`, `serialTracked` and `catchWeightTracked` can be flipped while stock is on hand.
- Product names are unique across the tenant, although SKU codes became per-client in 1.1.

**Approach:**
- **Create and edit.** A single-SKU create route and form. The SKU edit gains shelf life, the remaining PATCH fields and a pack-levels-and-barcodes editor.
- **Pack levels** are the existing `uom_conversions` rows (box, case, pallet, …: one unit = an integer number of base units). Today they are written by import only and read by nothing operational; they become editable.
- **Barcodes.** A new `sku_barcodes` table holds every barcode of a SKU, each naming its level (the base unit, or a pack level). It is the single uniqueness authority per (tenant, client). `skus.barcode` remains the primary base-level barcode and always has a matching row.
- **Handheld scans.** The handheld snapshot carries the extra barcodes with their factor:
  - Receiving, returns and packing add the whole pack per scan.
  - Picking and putaway accept any of the SKU's barcodes to confirm it.
- **Products** become per-client.
- **Import.** The catalog import takes shelf life and extra barcodes.

**Decisions (user, 2026-10-19):**
1. **A case or pallet scan counts the whole pack.** Receive, returns and pack add `factor` base units and say so. Pick and putaway accept the pack barcode as SKU confirmation; the quantity stays as today. A serial-tracked or catch-weight SKU refuses a pack scan with a message: each unit must be scanned or weighed.
2. **SKU deactivation is a separate story (1.4b),** filed in deferred-work.
3. **Product names are unique per client.** Products gain `client_id`, backfilled from their SKUs, or the tenant's self client when they have none. The import resolves a product within the run's client.
4. **The import accepts `shelf_life_days` and `barcodes`.** The `barcodes` cell looks like `case:8901234567890;pallet:8901234567891;each:8900000000001`.
9. **(Design review) A returns pack scan larger than the line's open quantity splits.** The open quantity goes on the line; the rest becomes a separate excess entry flagged for review, exactly as a stray single unit is flagged today.
10. **(Design review) A stale pack factor is shown, not detected.** Every pack-scan message names the factor ("+12 (1 case of 12)"). The web packaging panel tells the user to refresh handhelds after a change. Server-side detection is a recorded gap (PENDING), not built.
11. **(Design review) A mistaken pack scan is corrected by typing the quantity.** No undo button; the pack-scan message says the quantity can be typed.

**Decisions (agent):**
5. **Shelf life:** `skus.shelf_life_days` is a nullable integer from 1 to 3650, meaning total days from manufacture. 1.4 stores and edits it; 2.4 derives expiry from it. It is distinct from the client receiving policy's `minShelfLifeDays` (minimum *remaining* life, 1-2b).
6. **Create needs `sku.edit`** (owner, ops manager) and takes one import row's worth of fields, typed, including pack levels and barcodes, in one keyed transaction.
   - A blank barcode gets the import's generated value.
   - **Client:** the import's rule exactly. `clientId` may be omitted only when the tenant has one client (then self); otherwise 400 `client-required`. The same rule applies to product create.
   - Kit composition and product attach stay on their existing routes.
7. **Tracking flags lock once stock exists.** Changing (value differs from current) `batchTracked`, `serialTracked` or `catchWeightTracked` is a 409 `sku-has-stock` while the SKU has any of: a `stock_on_hand` row with qty ≠ 0 in any bin including system bins (receiving, QC-HOLD, IN-TRANSIT); a `pending` `over_receipts` row; a `pending` `stock_adjustment_pendings` row with positive qty. The existing catch-weight live-handling-unit guard stays and runs first.
8. **A pack level has an integer factor of 2 to 1,000,000.** Its `uom` comes from the existing vocabulary and must differ from the SKU's base `uom`. The same rule applies to the import's `uom_conversions` cell.
12. **Barcode rule (one rule everywhere):** trimmed, 1–64 characters, printable ASCII (`^[!-~]([ -~]*[!-~])?$`), and not containing `;`. The 64 keeps today's DTO and import limit; the character rule is a deliberate narrowing, guarded by the migration's pre-flight (the dev DB holds none that fail).
13. **A barcode may not equal any SKU code in the same client** (including the SKU's own), 409 `barcode-is-code` — so scan resolution never has to choose between a barcode and a code.

## Boundaries & Constraints

**Always:**
- **`sku_barcodes` table:** `(id, tenant_id, client_id, sku_id, barcode, uom, is_primary, created_at, updated_at)`.
  - Unique `sku_barcodes_tenant_client_barcode_unique (tenant_id, client_id, barcode)` → 409 `duplicate-barcode` naming the holder's SKU code and level.
  - Partial unique `sku_barcodes_primary_unique (sku_id) WHERE is_primary`; index `(tenant_id, sku_id)`.
  - CHECKs: the barcode rule (decision 12); `uom` in the uom vocabulary (TS↔DB pinned per guide §4).
  - The primary row has `is_primary`, `barcode = skus.barcode` and `uom = skus.uom`. Every other row's `uom` is either the base uom (extra base-level barcode) or a `uom_conversions` level of that SKU.
  - `client_id` always equals the SKU's; only client correction updates it (architecture pin, beside the `skus.client_id` pin).
  - RLS: the 0079 tenant + `app.client_id` clause on USING and WITH CHECK; added to `STAMPED_TABLES` and `CLIENT_POLICIES` in `client-isolation.spec.ts`.
- **`skus_tenant_client_barcode_unique` stays** as a backstop; every 23505 handler maps both it and the new index.
- **Products:** `client_id` NOT NULL after backfill; the name index becomes `products_tenant_client_name_unique (tenant_id, client_id, name)` (update `PRODUCTS_TENANT_NAME`); the products RLS policy gains the client clause and joins the isolation lists.
- **Migration 0080**, in this order: fail-fast guard against a second run → pre-flights that abort listing every offender (`skus.barcode` breaking decision 12; `uom_conversions.factor` outside 2–1,000,000; a product whose SKUs span clients) → create table and columns → backfill (`sku_barcodes` primary rows; `products.client_id` from its SKUs, else the self client `code='self' AND system_owned`) → assert (one primary per SKU, equal to `skus.barcode`; `sku_barcodes.client_id = skus.client_id`; no product with NULL client) → SET NOT NULL → swap the name index → CHECKs (`skus.shelf_life_days IS NULL OR 1..3650`, factor, barcode, uom) → RLS. `meta/0080_snapshot.json` and the journal entry are committed; `db:generate` reports no changes.
- **Every writer of `skus.barcode` keeps the primary row in the same transaction:** create, edit, import. Client correction moves every `sku_barcodes` row of the moving SKUs and the products' `client_id`. Every barcode-uniqueness check reads `sku_barcodes` only, and also refuses a barcode equal to a SKU code in the client (decision 13).
- **Lock order:** product → skus → sku_barcodes. Every `sku_barcodes` writer locks the SKU row first. The edit locks the product (when attaching) before the SKU.
- **Pack levels and barcodes:** `PUT /tenants/:t/catalog/skus/:skuId/packaging` takes `{ levels: [{uom, factor}], barcodes: [{barcode, uom}] }`, where `barcodes` is every non-primary barcode. Response `{ sku: SkuResponse }`.
  - Skeleton: SKU lock `FOR UPDATE` → second replay under the lock → guards → delete-and-insert the conversions and non-primary barcodes.
  - Refusals:
    - 400 `validation-failed` (detail names it): duplicate level uom; a level equal to the base uom; factor outside 2–1,000,000; a barcode breaking decision 12; an entry equal to the primary barcode.
    - 400 `barcode-level-unknown`: a barcode whose `uom` is neither the base uom nor in `levels`.
    - 409 `duplicate-barcode`: within the request, or held by another SKU of the client.
    - 409 `barcode-is-code`.
    - 409 `client-departed` via `assertClientTakesWorkInTx`.
  - Kit SKUs take packaging like any SKU.
  - Hash: levels sorted by uom, barcodes sorted by (uom, barcode). No-op when both sets are equal to the stored ones: arm `skus.packaging:unchanged`, stored as `{ sku }`, registered in `AUDIT_NO_OP_ARMS`.
  - Audit `sku.packaging_replaced`; outbox `catalog.sku_edited` (as the PATCH).
- **Create:**
  - Route: `POST /tenants/:t/catalog/skus`; body `CreateSkuDto` = code, name, uom, gstRate, hsnCode?, barcode?, batchTracked, serialTracked, catchWeightTracked, attributes?, storageClass?, hazardClass?, abcClass?, reorderPoint?, reorderQty?, shelfLifeDays?, clientId?, `levels?`, `barcodes?` (same shapes and rules as the PUT). Response 201 `{ sku: SkuResponse }`.
  - Shares the import's typed post-parse validators (uom resolution with aliases, GST, attributes, classes, levels, barcodes) — extract the seam, don't copy. The CSV cell parser stays import-only.
  - Refusals: 409 `duplicate-sku-code` / `duplicate-barcode` / `barcode-is-code`, 409 `client-departed`, 400 `client-required`.
  - Hash `clientId` only when present (21-2b precedent). Same-key concurrent creates: the loser answers 409 `duplicate-sku-code` rather than replaying — accepted, as the cross-cutting PENDING entry records.
  - Outbox `catalog.sku_created {skuId, code, clientId}`, audit `sku.created`.
- **Edit** (`PATCH`) gains `shelfLifeDays` (`null` clears; hashed only when present) and the decision-7 guard, which runs under the SKU `FOR UPDATE` only when a flag changes. A name-only edit on a stocked SKU with unchanged flags succeeds.
  - Setting the primary barcode to a value that is currently this SKU's extra barcode **promotes** it: the extra row is deleted and the primary row updated in one transaction.
  - The empty-patch message lists `shelfLifeDays`.
  - Replay of a pre-1.4 stored response defaults `shelfLifeDays ?? null`, `barcodes ?? []` (edit and correction replays).
- **Return receipts** take the SKU rows `FOR SHARE` when reading SKU facts, so a flag flip cannot interleave with a return posting.
- **Products:**
  - Create takes `clientId?` (decision-6 rule; departed client refused); `product.command.ts` joins `TAKES_WORK_CALLERS`.
  - Names are unique per client (409 `duplicate-product-name`, "for this client").
  - Edit takes `clientId` only while the product has no SKUs (otherwise 409 `product-has-skus`).
  - `ProductResponse` gains required `clientId`.
  - Attach refuses a SKU of another client (409 `product-client-mismatch`), replacing `mixed-client` for products; kits, POs and ASNs keep `mixed-client`.
- **Client correction:** pre-checks every moving SKU's barcodes (all rows) against the target and the moving products' names against the target (409 `duplicate-product-name`), and maps both 23505s.
- **Import:**
  - New optional columns `shelf_life_days` (blank → null, `^\d+$`, 1–3650) and `barcodes`.
  - `barcodes` cell: split on `;`, then on the first `:`. The level resolves through `resolveUom`; a level equal to the base uom is an extra base-level barcode (so `each:` on an each-based SKU), otherwise it must be a level in the row's `uom_conversions` cell. Several barcodes per level are allowed. A barcode equal to the row's primary, or repeated, is a row error.
  - The `uom_conversions` factor narrows to 2–1,000,000.
  - Product lookup is by name within the run's client; a name not in that client creates it there. The product `mixed-client` row error is removed.
  - Duplicates within the file or the client, and barcode-equals-code, are row errors. The import stays create-only.
- **Device snapshot:** each SKU gains `packBarcodes: [{barcode, uom, factor}]` — every non-primary row; `factor` is 1 when `uom` is the base uom, otherwise the level's factor. Built by one batched query on the caller's transaction inside `getSkuSummariesInTx` (no nested transaction). Declared in `SkuSummary`, the `CatalogSnapshot` mirror and `CatalogSnapshotSkuDto` with a named nested `CatalogSnapshotPackBarcodeDto`.
- **Handheld snapshot:** `parseCatalogSnapshot` defaults `packBarcodes` to `[]` and drops invalid entries (non-integer or < 1 factor, empty barcode); `CatalogSku.packBarcodes` is then required.
- **Handheld resolution:** `matchValue` treats the primary and pack barcodes as one barcode tier (more than one distinct SKU at a step → `ambiguous`), then the code. A match carries `factor` and `level` (uom). The work → client → other-clients order is unchanged.
- **Handheld quantities:**
  - Every resolution arm that carries a SKU also carries `factor`/`level`: `SkuResolution` work/client, `OtherClientMatch`, `ReceiveScanResolution`, `ReturnScanResolution`, `PackScanResolution`, returns `Pending`, `applyResolvedSku`, `applyScanToDraft(…, factor)`, `addUnit(…, factor)`, `scanSkuUnit(draft, sku, factor)`.
  - Serial-tracked or catch-weight SKU + factor > 1 is refused in the resolve layer, before any capture prompt or other-client question.
  - **Receive:** increment, switch and new-line branches all apply `factor` (new line `qty: factor`; switch sets `qty: factor`). Over `MAX_LINE_QTY` → new `{kind:'rejected', reason}` result, line unchanged (replaces the clamp). Over-receipt tolerance behaviour is unchanged.
  - **Returns:** decision 9 — open quantity on the line, remainder as a flagged excess entry.
  - **Pack:** refuse whole when `qty + factor > pickedQty`.
  - One pure helper `packScanDetail(factor, level, uom)` builds the message ("+12 (1 case of 12) — type a quantity to correct"), used by all three flows.
  - Pick and putaway: a pack barcode confirms the SKU; quantity unchanged.

**Never:**
- No SKU deactivation (1.4b).
- No `code` or `uom` edit.
- No GS1-128 / AI(17) parsing.
- No pack-level dimensions or weights.
- No case or pallet quantities on documents or the ledger: everything stays in base units.
- No server-side barcode lookup route, and no server-side stale-factor detection.
- No undo-scan button.
- No SKU or product admin on the handheld.
- No portal changes (portal reads only SKU id/code/name/uom).
- No FK.
- No price or cost.
- No bulk packaging update for existing SKUs (PENDING).

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected | Error |
|---|---|---|---|
| Create | `{code:'TEA-1', name, uom:'pcs', gstRate:5, shelfLifeDays:365, levels:[case×12], barcodes:[case 890…1]}`, single-client tenant | 201, primary row + case row, `catalog.sku_created` | N/A |
| Create, multi-client, no clientId | tenant with GLOWCO + self | none | 400 `client-required` |
| Create duplicate | code taken in the client | none | 409 `duplicate-sku-code` |
| Packaging | levels case×12, pallet×480; barcodes case `890…1`, pallet `890…2`, base `890…3` | rows replaced; snapshot lists factors 12 / 480 / 1 | N/A |
| Packaging no-op | same sets, reordered | 200, no audit row | N/A |
| Barcode clash | `890…1` is another SKU's barcode in the client | unchanged | 409 `duplicate-barcode` naming SKU and level |
| Barcode equals a code | `TEA-2` is a SKU code in the client | unchanged | 409 `barcode-is-code` |
| Same barcode, other client | `890…1` held in client B | allowed for client A | N/A |
| Level missing | barcode on `pallet`, no pallet level | unchanged | 400 `barcode-level-unknown` |
| Level equals base | level `pcs` on a pcs SKU | unchanged | 400 `validation-failed` |
| Promote extra | PATCH barcode = this SKU's extra `890…3` | primary becomes `890…3`, extra row gone | N/A |
| Flag flip with stock | `batchTracked:true`, 5 on hand (or only in QC-HOLD, or a pending over-receipt) | unchanged | 409 `sku-has-stock` |
| Flags unchanged | name edit, flags sent unchanged, 5 on hand | 200 | N/A |
| Handheld case scan, receive | case barcode (×12), line open for 30 | line +12, "+12 (1 case of 12)" | N/A |
| Handheld case scan, new line | no open line | new line qty 12 | N/A |
| Handheld case scan, serial / catch-weight SKU | case barcode | nothing added, no capture prompt | message: scan or weigh each unit |
| Handheld receive over max | line at `MAX_LINE_QTY - 5`, case ×12 | line unchanged | message names the limit |
| Handheld pack cap | 10 left to pack, case ×12 | nothing added | message names the cap |
| Handheld return split | line has 5 open, case ×12 | 5 on the line, 7 excess flagged | N/A |
| Handheld pick | pack barcode of the task's SKU | SKU confirmed, qty unchanged | N/A |
| Handheld clash | client 1 primary X, client 2 case X, tenant-wide step | ambiguous | existing ambiguous message |
| Old snapshot | no `packBarcodes` | resolves as before | N/A |
| Product names | client A and client B each create "T-Shirt" | both 201 | 409 within one client |
| Import barcodes | `uom_conversions: case:12`, `barcodes: case:890…1;each:890…3` | SKU + level + both barcodes | row error on missing level, taken barcode, factor 1 |
| Migration | existing SKUs and products | one primary row per SKU; each product carries its SKUs' client | aborts listing offenders on a pre-flight failure |

</frozen-after-approval>

## Code Map

**Backend (`wms-be`)**
- `src/shared/db/schema.ts`:
  - `skus` (:772-918): add `shelfLifeDays`; keep `skus_tenant_client_barcode_unique`;
  - `products` (:933-957): add `clientId`, the new unique index, the client RLS clause;
  - `uomConversions` (:969-985): factor CHECK;
  - new `skuBarcodes` with its indexes, CHECKs and RLS.
- `drizzle/0080_sku_master.sql` + `meta/0080_snapshot.json` + journal: hand-checked, ordered as in Boundaries; migration test on the `business-partners-migration.spec.ts` pattern, including refused-and-accepted probes for every CHECK and the pre-flight aborts.
- `src/modules/catalog/sku.command.ts`:
  - new `create` and `replacePackaging`;
  - `edit` (:305): `shelfLifeDays`, the decision-7 guard beside the catch-weight guard (:850-871), the barcode path (:893-927) via `sku_barcodes` with promote, replay defaults (:400-418), empty-patch message (:344);
  - attach (:660-806): `product-client-mismatch`; product lock before SKU lock.
  - The comment at :224-226 ("Manual creation is out of scope") goes.
- A shared typed validator module (uom, GST, attributes, classes, levels, barcodes) used by create, the PUT, the edit and the import.
- `src/modules/catalog/catalog.controller.ts`: `POST /catalog/skus`, `PUT /catalog/skus/:skuId/packaging`; DTOs in `catalog.dto.ts` (`CreateSkuDto`, `ReplacePackagingDto`, `SkuResponse.shelfLifeDays` + `barcodes: {barcode, uom, isPrimary}[]` sorted primary first then (uom, barcode); `uomConversions[]` is the levels array; `ProductResponse.clientId`; barcode `@Length(1,64)` + pattern on every DTO).
- `src/modules/catalog/sku-client.command.ts:159,257,300-304,353`: barcode and product-name pre-checks, both 23505 mappings, moving `sku_barcodes` and `products.client_id`, replay defaults.
- `src/modules/catalog/product.command.ts:28,126,287`: index name, `clientId` on create and empty-product edit, client-scoped names.
- `src/modules/catalog/import.command.ts`: columns (:125-177); client rule unchanged (:358-371); product lookup per run client (:415-490); factor range (:1315-1326); barcode rule (:1186-1192); primary row with the generated default (:594); uniqueness (:997) and 23505 mapping (:617) for both indexes; new cells.
- `src/modules/returns/return-receipt.command.ts:588,921`: `FOR SHARE` on the SKU rows (a `skuFactsInTx` variant or option in `catalog.facade.ts`).
- Snapshot: `catalog.facade.ts:503-536` (`getSkuSummariesInTx`), `SkuSummary` (:165); `inbound/receiving.facade.ts:87-125`; `receiving.dto.ts:716` + `CatalogSnapshotPackBarcodeDto`.
- `src/shared/primitives/audit.ts`: `sku.created`, `sku.packaging_replaced` (+ `AUDIT_NEW_ACTIONS`); `skus.packaging:unchanged` in `test/support/audit-guard.ts`.
- `test/architecture.spec.ts`: `TAKES_WORK_CALLERS` + `product.command.ts`; pin that only correction updates `sku_barcodes.client_id` / `products.client_id`.
- `test/client-isolation.spec.ts`: `sku_barcodes`, `products`.
- A test helper that inserts the primary row, used by the ~10 suites that insert `skus` directly.
- `openapi/openapi.json` regenerated.
- Tests: new `test/sku-master.spec.ts` covering the matrix, parked-waiter same-key races (`raceTwice` + `waitParked`) on the PUT and the flag-flip edit, `expectAuditRow` for both actions, and the snapshot's exact `packBarcodes` key set; update the catalog, import, per-client-sku (:335, :359, :1004), client-correction, product and return-receipt suites.

**Web (`wms-fe`)**
- `bun run api:generate` → `src/lib/api/generated`; capability mirror unchanged (all under `sku.edit`); update the `SkuResponse`/`ProductResponse` test fixtures.
- `src/components/settings/settings-tabs.tsx` (catalog tab): mount `sku-create-card.tsx` (client — required when the tenant has more than one; code, name, uom, GST, HSN, flags, attributes, classes, shelf life, barcode, and the packaging editor), gated on `sku.edit`.
- `src/components/settings/sku-table.tsx`:
  - `SkuEditForm` gains shelf life ("Shelf life — total days from manufacture"; a warning when below the client's `minShelfLifeDays`), `catchWeightTracked`, `abcClass`;
  - a `Packaging` panel (shared editor with the create card) sends the PUT, notes "refresh handhelds after changing pack sizes";
  - the table shows shelf life and pack levels;
  - attach refusal mapper (:768) uses `product-client-mismatch`;
  - the owner's client-correction dialog (:108-131, `correctClientReason` in `src/lib/clients.ts`) gains messages for the new correction refusals (`duplicate-barcode` on any of the SKU's barcodes, `duplicate-product-name`).
- `src/components/settings/products-card.tsx`: client field on create; client label in the list; attach picker filtered by `product.clientId`; a client field on product edit, shown only while the product has no SKUs (`product-has-skus` message otherwise).
- `src/lib/catalog-products.ts:75,114`: "for this client" copy; `product-client-mismatch`.
- `src/lib/api/client.ts`: wrappers; call `notifyCatalogChanged()` after create and packaging. `src/lib/sku-admin.ts`/`sku-attributes.ts`: validation mirroring the server (barcode rule, factor range, shelf life), and messages for `sku-has-stock`, `barcode-level-unknown`, `duplicate-barcode`, `barcode-is-code`, `client-required`.
- `import-catalog.tsx:138-139`: help lists all current columns including the new two.
- Tests: `sku-table.test.tsx` (PUT body, error messages), `products-card.test.tsx` (client field, filtered picker), `settings-tabs.test.tsx` (create hidden without `sku.edit`), `import-catalog.test.tsx`, `sku-admin.test.ts` (pinned sentences).

**Handheld (`wms-mobile`)**
- `src/api.ts` `CatalogSku` (~:1150): `packBarcodes` (required after parse).
- `src/state/catalog-snapshot.ts` `parseCatalogSnapshot`: default and validate; pinned by equality in `device-store.test.ts`.
- `src/lib/sku-resolution.ts`: `matchValue` single barcode tier, `factor`/`level` on every arm, `packScanDetail`.
- `src/receiving/draft.ts` (`resolveReceiveScan` :387, `applyScanToDraft` :422-497), `app/receive.tsx` (:231-296);
- `src/returns/draft.ts` (`resolveReturnScan` :259, `addUnit` :432-447, `unitDetail` :480), `app/return-receive.tsx` (:126-170);
- `src/packing/draft.ts` (`resolvePackScan` :179, `scanSkuUnit`), `app/pack.tsx` (:226-238);
- pick/putaway (`resolveTaskItemScan`) unchanged apart from accepting the match.
- Coverage (verified): the only handheld screens that resolve a SKU scan are receive (PO, ASN and blind), return-receive, pack, pick and putaway. Count is typed per line and transfer resolves bins only, so neither changes. SKU create, edit and packaging are web-only; the handheld has no catalog admin and gains none.
- Tests: `sku-resolution.test.ts` (pack match factor, single barcode tier ambiguity, pick/putaway ignore factor, handling-unit id still wins in pack), receiving `draft.test.ts` (:215-219 rewritten to the refusal; the three branches; AC2 `confirmPayload` `qty: 24`), returns and packing draft tests (split, cap, serial/catch-weight refusal before capture).

## Tasks & Acceptance

**Execution:**
- [x] `wms-be` schema + 0080 + migration test -- barcode table, product client, shelf life, CHECKs, RLS, pre-flights -- single uniqueness authority
- [x] `wms-be` shared validators, catalog commands, controller, DTOs, audit -- create, packaging, edit guard and promote, product client, client correction, return-receipt lock -- the SKU master API
- [x] `wms-be` import + snapshot -- new columns, narrowed factor, client-scoped products, `packBarcodes` -- bulk onboarding and handheld feed
- [x] `wms-be` tests -- matrix, races, audit rows, isolation, architecture pins, existing suites, openapi
- [x] `wms-fe` generated client, create card, edit form, packaging panel, products client, error copy, import help + tests -- the web SKU master
- [x] `wms-mobile` snapshot parse, resolver tier and factor, receive/returns/pack factor, refusals, split, message helper + tests -- case and pallet scans
- [x] Meta docs (land last): `docs/design/modules/catalog.md`, `API-SURFACE.md`, mobile guide (scan path), `docs/repos/*/README.md`, PENDING (close the product-name entry and the "`uom_conversions.factor` nothing applies" entry; add 1.4b, stale-factor detection, bulk packaging import)

**Acceptance Criteria:**
- Given an ops manager on Settings → Catalog, when they create a SKU with a case level of 12 and a case barcode, then the SKU lists with both and a fresh handheld snapshot carries the case barcode with factor 12.
- Given a handheld receiving against a PO line, when the operator scans that case barcode twice, then the line shows 24, the message reads "+12 (1 case of 12)", and the GRN sends `qty: 24` base units.
- Given a SKU with stock in any bin, when a user changes its batch, serial or catch-weight flag, then it is refused with `sku-has-stock`; an edit leaving the flags unchanged succeeds.
- Given a warehouse operator, when they open the catalog, then create, edit and packaging are not offered.
- Given a tenant with two clients, when a user creates a SKU or product without choosing a client, then it is refused with `client-required`.
- Given an existing database, when 0080 runs, then every SKU has exactly one primary `sku_barcodes` row equal to `skus.barcode`, every product has the client of its SKUs, and a pre-flight failure aborts listing every offender.

## Implementation Notes

Implemented 2026-10-19 (uncommitted, all three repos on `feat/1-4-sku-master-on-the-web`).

- **Readings taken where the spec was loose:**
  - Import "a name not in that client creates it there" read as: the row error names the client and tells the user to create the product there — the import still never creates products (it has no axes to declare). The product `mixed-client` row error is gone.
  - `CreateSkuDto` follows the spec literally: `hsnCode` and a nested `attributes` object (the PATCH keeps flat `hsn` and attribute fields).
  - `products.client_id` has two writers: the correction and the product edit while empty (the spec's own rule); the architecture pin names both. `sku_barcodes.client_id`: correction only.
  - `FOR SHARE` on SKU facts is taken in the return-receipt **posting** (`:921`) only; `openReturnsInTx` (`:588`) is the snapshot read and stays unlocked.
  - The edit now locks the SKU row `FOR UPDATE` on every PATCH (product first when attaching), then replays again under the lock.
  - On attach, `client-departed` is decided before `product-client-mismatch` (keeps the 1-2a pin meaningful).
  - Decision 13 is also enforced in reverse (a new code equal to a client barcode → `barcode-is-code`) in create, import and correction.
  - A pre-1.4 stored product snapshot replays with the product row's current `clientId` (so `ProductResponse.clientId` stays a required string).
- **Re-pinned tests (old behaviour gone, new expectation asserted):** `clients.spec.ts` product pass (`mixed-client` → row error + `product-client-mismatch`); `adjustment-approval.spec.ts` flag flips with a pending adjustment now assert `409 sku-has-stock` and flip below the API to keep the approval parity guard pinned; `client-isolation.spec.ts` policy count 116 → 117.
- **Verification:** wms-be full jest 99 suites / 2370 tests green, lint, typecheck, build; `db:generate` reports no changes; 0080 run against the dev DB inside a rolled-back transaction (192 primary rows, 0 products without a client). Both same-key race tests fail with the second replay removed (mutation-checked). wms-fe 1888 tests, lint, typecheck, build, capability mirror green. wms-mobile 705 tests and typecheck green.

## Spec Change Log

## Review Triage Log

**Design review, 2026-10-19.** Three reviewers: backend claims (B1–B24), edge cases (E1–E24) and clients/contract (F1–F22). 70 raw findings, 37 after merging duplicates. Load-bearing claims re-checked by hand (import client rule `import.command.ts:358-371`, factor `:1321`, barcode `:1189`, receive clamp `receiving/draft.ts:456`, returns flagging `returns/draft.ts:432-447`, `matchValue` `sku-resolution.ts:70-74`, catch-weight guard `sku.command.ts:850-871`, 0041 RLS); dev DB probed: 0 out-of-range factors, 0 barcodes breaking decision 12, 0 products spanning clients, 6 products without SKUs. Every confirmed finding is patched above.

- D1 high (B1, E4): no RLS on `sku_barcodes` or the new `products.client_id`. Both get the tenant + client clause and join the isolation lists.
- D2 high (B2, E2, F17): the barcode CHECK silently narrowed and widened today's rule. One rule (decision 12) everywhere, with a pre-flight listing offenders.
- D3 high (B3, E1): the factor CHECK would 500 the import and could abort 0080. The import narrows to 2–1,000,000; the pre-flight lists rows in both directions.
- D4 high (B4, E7, E8): the stock guard missed catch weight, system bins, pending over-receipts and adjustments, and return receipts' unlocked read. Decision 7 widened; return receipts take `FOR SHARE`.
- D5 high (B9, E10): defaulting to self contradicts the import's `client-required`. Decision 6 now uses the import's rule for SKUs and products.
- D6 high (E3, B10): the old barcode index's fate and the 23505 mappings were unstated. The index stays as a backstop; every handler maps both.
- D7 high (E6, F9): primary → pack → code precedence hid cross-client clashes and let a pack barcode shadow a code. One barcode tier with ambiguity, and decision 13 `barcode-is-code`.
- D8 high (F1): base-level extra barcodes were refused by `barcode-level-unknown`. The base uom is always a valid barcode level.
- D9 high (F2, E15): the factor was dropped by every screen wrapper. Every arm and signature is named.
- D10 high (F3, E14): "refused whole" contradicted the receive clamp. New rejected arm; per-flow caps named.
- D11 med (E5, B15): the `each:` token was ambiguous. The level resolves through `resolveUom` and "equals base uom" means base level; split on the first `:`; `;` refused in barcodes.
- D12 med (B8, E12): no primary marker, no lock order, own-extra collision. `is_primary` with a partial unique; lock order product → skus → sku_barcodes; promote on edit, 400 on the PUT.
- D13 med (B5, E18): replays of pre-1.4 stored responses lacked the new fields. Defaults named.
- D14 med (B6, E18): the new locks needed a second replay. Skeleton and parked-waiter races named.
- D15 med (B7, E18): no-op arm, hash canonicalisation, audit list and outbox for the PUT undefined. All defined; the PUT emits `catalog.sku_edited`.
- D16 med (B11, E9, E11): correction could hit the new product-name index as a 500, and empty products were stranded. Pre-check + mapping; product client editable while empty.
- D17 med (B12): migration ordering, re-run guard, CHECK probes and snapshot files. Order written out.
- D18 med (B13, E19, F13): the create body was ambiguous. `CreateSkuDto` listed, includes levels and barcodes in one transaction; shared validator seam named.
- D19 med (B14): same-key concurrent create. Accepted per the existing PENDING entry.
- D20 med (F4, E16): receive's switch and new-line branches. Both apply the factor.
- D21 med (F5, E14): returns had no cap. User decision 9: split.
- D22 med (F6, E15): serial/catch-weight refusal came after capture prompts. Refused in the resolve layer.
- D23 med (F7): the message was untestable in screens. Pure `packScanDetail`.
- D24 med (F8, E13): stale factor invisible. User decision 10: shown in every message, documented, PENDING.
- D25 med (F10, F11): old-snapshot test and contract check. Parse default pinned; backend asserts the exact key set; named nested DTO.
- D26 med (F12): response shapes undefined. `SkuResponse.barcodes` and `shelfLifeDays` defined; `uomConversions` is the levels array.
- D27 med (F14, B16): error-code changes across web mappers. Enumerated; `mixed-client` kept for kits/POs/ASNs; import product row error removed.
- D28 med (F15): the web sends flags on every save. The guard fires only on change; matrix row added.
- D29 med (F16): products lacked a client on the response and in the picker. `ProductResponse.clientId`, filtered picker, client label.
- D30 low (B17): no per-SKU index. Added.
- D31 low (B18, E21): snapshot query placement. Caller's transaction, one batched query.
- D32 low (B19): lock-order deadlock between edit and correction. Product before SKU in the edit.
- D33 low (B20): `sku_barcodes.client_id` unpinned. Architecture pin.
- D34 low (B21, B22, B23, B24): PENDING entry, empty-patch message, delete-and-insert, catch-weight guard kept. All written in.
- D35 low (F18, E22): two meanings of shelf life; cell grammar. Labelled; grammar pinned; web warning below the client minimum.
- D36 low (F19, F20, F22): generated client, import help, web tests. Named in the Code Map.
- D37 low (F21, E17, E23, E20, E24): undo (user decision 11: typed quantity), bulk packaging import (PENDING), `factor` wording, unnamed error arms. All written in.

- D38 med (user question, 2026-10-19): a coverage walk found two web surfaces the spec missed — the client-correction dialog's messages for the new refusals, and the product client edit while empty. Both added; handheld scan-site coverage listed in the Code Map.

Rejected: none.

**Code review, 2026-10-19.** Three reviewers: blind hunter (BH1–BH13), edge-case hunter (EC1–EC11), verification gap (G1–G6). 30 findings, 22 entries after grouping. Verified by hand at the cited lines.

- C1 high, patch (BH1, EC2): promoting a SKU's own case/pallet barcode to primary silently re-levels it to the base unit (`sku.command.ts` promote deletes the extra row whatever its uom), so a case scan then counts 1. Fix: refuse with 400 unless the extra row is base-level.
- C2 med, patch (BH2, EC1): client correction checks moving barcodes against target codes but not moving codes against target `sku_barcodes`; `barcodeIsCode(codes[0].code, codes[0].code)` names nothing useful. Fix: check both directions, name the moving SKU.
- C3 low, patch (BH3): `catalog.md` states barcode ≠ code as an invariant, but legacy rows were never surveyed (dev DB: 0). Fix: doc says "enforced on every write since 1.4".
- C4 low, reject (BH4): no lost-update check on the packaging PUT. Same as every catalog PATCH and the kit PUT; two admins on one SKU is rare and a version precondition adds public surface.
- C5 false (BH5): audit rows carry no before/after anywhere in the system (no details column); the after-state lives in the stored idempotency snapshot. Convention, not a defect.
- C6 med, patch (BH6): the import maps a concurrent `sku_barcodes`/`skus` barcode 23505 to `duplicate-sku-code` naming row 1 (`import.command.ts:689`). Fix: map barcode indexes to `duplicate-barcode`.
- C7 low, patch (BH7, EC4): `normalizeStoredProduct` returns `clientId: ''` when the product row is gone. Fix: 404.
- C8 false (BH8): create without product/variant is decision 6 ("product attach stays on its existing route").
- C9 low, patch (BH9): two `status: 400` decorators on product create — the later replaces the earlier in Swagger; the product PATCH 404 omits the unknown-client case. Fix: merge, document.
- C10 low, reject (BH10): `UOM_OPTIONS` drift check is one-way; a backend unit addition is rare and visible.
- C11 low, reject (BH11): the snapshot skip of a barcode with no level is unreachable — the PUT and import validate the level, and levels and barcodes are replaced together under the SKU lock.
- C12 med, defer (BH12, EC5): a handheld's offline-queued receipt captured under the old flags replays after a flag flip. Pre-existing class (any master change vs the WAL); recorded in deferred-work.
- C13 low, patch (BH13, EC9): the web create form rounds GST beyond two decimals silently. Fix: refuse.
- C14 med, patch (EC3): a variantValues-only PATCH locks the product read before the SKU lock; a concurrent attach/detach leaves it holding the wrong product. Fix: after the SKU lock, a changed `productId` is 409 `conflict`.
- C15 med, patch (EC6): while the clients list is loading or failed, the create cards hide the client field and every create in a multi-client tenant gets `client-required`. Fix: hold submit until clients are ready.
- C16 low, patch (EC7): changing the base unit on the create card keeps barcode rows on the old/new base level. Fix: clear those rows' level.
- C17 low, patch (EC8): duplicate level options in the packaging editor's barcode select. Fix: dedupe.
- C18 med, patch (EC10): on the handheld, a pack scan matching several other clients is refused whole if any one match is serial/catch-weight. Fix: drop refused matches; refuse only when all are.
- C19 low, reject (EC11): a tenant without a self client fails the assert rather than the pre-flight — still aborts whole, and every tenant has a self client since 21-2b.
- C20 med, patch (G1, G2, G3, G4): untested: the return-receipt `FOR SHARE`, `barcode-is-code` in import and correction, pre-1.4 replays (SKU fields, product hash and `clientId`), the catch-weight arm of decision 7. Fix: tests.
- C21 med, patch (G5): on the handheld `factor` is optional in `applyScanToDraft`/`addUnit`/`scanSkuUnit`; a screen dropping it type-checks and counts 1 (AC2). Fix: make it required.
- C22 med, patch (G6): the web create card and the packaging key reuse/reset have no component tests. Fix: tests.

## Design Notes

**Why `sku_barcodes` holds the primary too.** Uniqueness has to span the primary barcode and the pack barcodes, and a partial index cannot span two tables. One table with one unique index makes the database the authority. `skus.barcode` stays because the snapshot, the import and 1-1's resolution read it; `is_primary`, the migration assert and the shared writer keep the two in step.

**Why pack levels reuse `uom_conversions`.** The table already has the right shape: one integer factor per (SKU, unit), with `case` and `pallet` in the vocabulary. Nothing operational reads it today (verified), so editing it cannot move stock. A second table would hold two truths about what a case is.

**Why the factor lives only on the handheld.** Documents and the ledger stay in base units: the server receives `qty: 24`, never "2 cases". No server operation changes, which keeps the handheld flows and the server contract decoupled. The cost is decision 10: a handheld with an old snapshot counts the old factor and the server cannot tell. The message names the factor so the operator can see it, and detection is a PENDING item.

**Why a barcode may not equal a code.** The handheld matches barcodes before codes. Allowing a barcode equal to another SKU's code would let a pallet barcode silently win over a typed code and add 480 units of the wrong SKU. Refusing at write time removes the choice at scan time.

**Why the stock guard reads pending stock.** A pending over-receipt or adjustment becomes stock later without reading the flags again, so a flip in between books batchless stock against a batch-tracked SKU. On-hand alone is not enough.
