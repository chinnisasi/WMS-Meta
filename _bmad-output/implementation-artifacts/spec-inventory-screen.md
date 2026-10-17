---
title: 'Inventory screen — stock by location, batches and the ledger on /inventory'
type: 'feature'
created: '2026-10-17'
status: 'in-progress'
baseline_commit: '90196e6519a315904201f25442d22ae7ae343db6'  # wms-fe; wms-be baseline: 154a06c992f6c7f0998616965aeb43ece0b00963
route: 'dispatch'
review_loop_iteration: 0
context:
  - 'docs/design/SYSTEM-DESIGN.md'
  - 'docs/design/IMPLEMENTATION-GUIDE.md'
  - 'docs/design/modules/inventory.md'
  - 'docs/design/frontend/SYSTEM-DESIGN.md'
  - 'docs/design/frontend/IMPLEMENTATION-GUIDE.md'
  - '_bmad-output/implementation-artifacts/spec-page-tabs.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** `/inventory` is still the first skeleton's placeholder ("IA skeleton surface — functionality lands in a later story"). The user followed goods from dock to bin to dispatch (2026-10-17) and found no screen that answers two questions: "what is in bin D-01-01" and "which bins hold GLOW-SERUM-30". The data exists. The backend serves on-hand per (SKU, bin), batches and batch detail, but only the ledger timeline reaches the web.

**Approach:** Make `/inventory` a real page on the shared page-tabs module, with three tabs: **Stock** (on-hand per bin and SKU, searchable by SKU or bin), **Batches** (a SKU's batches by expiry, each opening to its bins and history) and **Ledger** (the existing timeline). It reads the active warehouse, like every other page.

**Stock list decision (user, 2026-10-17): backend change first, sorted by bin.** `GET …/inventory/stock` gains optional, additive `order=location` (bin code, then SKU id), `nonZero=true` and the per-item fields `binCode` and `binSystemOwned`. The web pages the whole warehouse bin by bin. The existing callers send neither parameter and see no change. The backend PR merges before the web PR.

- **Order:** storage bins first, then the system bins (`binSystemOwned`). Each group is sorted by `bins.code COLLATE "C"` (lexical, not natural: `D-01-10` sorts before `D-01-2`), then `sku_id`, then the row `id`. The keyset comparison uses the same collation. The database default is `en_US.utf8`, which treats `-` differently.
- **Cursor:** a separate payload `{o: 'location', sys, binCode, skuId, id}` with its own validator. A cursor minted under one `order` and sent with the other is 400 `invalid-cursor`, in both directions.
- **Zero rows:** `nonZero=true` filters `quantity > 0`. The CHECK `quantity >= 0` (0026) makes that the same as non-zero.
- **The default arm's cursor** (`createdAt DESC`) moves to the full-precision instant (`createdAt::text` + `fullPrecisionInstant`), and PENDING's cursor-truncation entry records `listStock` as repaired.
- **No migration or index.** The join is tenant- and warehouse-scoped (`bins.warehouse_id = $w`, plus RLS). A whole-warehouse sort per page is accepted for now and recorded in PENDING.

## Boundaries & Constraints

**Always:**
- **Tabs and links** follow the page-tabs rules (IMPLEMENTATION-GUIDE §1.8a):
  - Tabs, in order: Stock (`stock`, default), Batches (`batches`), Ledger (`ledger`).
  - Tablist label: "Inventory lists".
  - The page key is `drillKey|tab`.
- **The page key** is `` `none|${tab ?? 'default'}` ``. The page parses no drill: a stray `list=` on `/inventory` is ignored. Drills belong to `/inventory/ledger`.
- **The `/inventory/ledger` route keeps working** unchanged. It is the drill target of the Overview tile, five "View ledger" document links and `drill-routes.ts`. The Ledger tab renders the same `Ledger` component undrilled for the active warehouse.
- **Quantities and display:**
  - Quantities show at the SKU's own precision and unit (`quantityLabel`).
  - Bins and SKUs show by code, never by id.
  - The client column appears only when the tenant has more than its own client (the `showClients` precedent).
- **System bins are shown, labelled in words:**

  | Bin | Label |
  |---|---|
  | RECEIVING | Receiving (awaiting putaway) |
  | QC-HOLD | QC hold (not sellable) |
  | RETURNS | Returns |
  | IN-TRANSIT | In transit |

  Stock in them is real stock in the building, and hiding it would make totals disagree with the ledger. A row is labelled only when `binSystemOwned` is true, using the label for its code. A system bin with an unknown code reads "System bin (CODE)", and a user bin that happens to be coded like a system one gets no label. The four codes were verified at `wms-be src/modules/tenancy/receiving-bin.ts:23,47,68,303`.
- **Gating:** member-open, like the reads. The portal never reaches it: the operator fence refuses portal sessions, and the portal boundary test keeps operator components out of the portal.
- **Paging:** explicit cursor pages, limit 200, with **Load more**. Retry and a warehouse switch reset the cursor and the rows together (FE guide §1.11 reload epoch). Never `fetchAllPages`.
- **SKU search total:** a SKU search walks every page of `skuId` before showing **Total across bins**. A SKU is never in more than a few hundred bins.
- **The search box** needs the SKU and bin maps:
  - While either map is loading, search is disabled ("Loading codes…").
  - If a map failed, the box says which, and offers bin-only or SKU-only search.
  - A miss reads "No bin or SKU with code X found", never "is not in this warehouse", because the maps can be truncated.
- **The Ledger tab** renders bare `<Ledger />`. It owns its own warehouse resolution and failure and empty arms, and the screen's warehouse gate wraps only Stock and Batches, so a failure never shows twice.
- **Empty and failed states:** no warehouses → "Create a warehouse first". A failed read → the shared `ReadFailure` with Retry. A failed warehouses read → `WarehousesFailure`.

**Never:**
- No stock writes from this page: no adjust, move or hold. Those are separate surfaces.
- No ATP, allocated or QC-held per-SKU figure. No operator read serves one, and inventing it on the web would diverge from `atp()`.
- No serial lookup. The serial read takes an internal id, not a serial number, so it isn't usable from a search box (recorded in PENDING).
- No change to the Ledger component's drills or columns.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|---|---|---|---|
| Default | `/inventory` | Stock tab; the active warehouse's stock, non-zero rows only, bin by bin (bin code, then SKU) | Read failure → `ReadFailure` + Retry |
| What is in a bin | Search "D-01-01" (a bin code) | Only that bin's rows: SKU, name, quantity | Unknown code → "No bin or SKU matches D-01-01 in this warehouse" |
| Where is a SKU | Search "GLOW-SERUM-30" | Only that SKU's rows, one per bin, plus a total across bins | N/A |
| System bin | Stock in RECEIVING / QC-HOLD | Row shown with the bin's word label | N/A |
| Zero row | A (SKU, bin) drained to 0 | Not shown | N/A |
| Batches | Batches tab, search a SKU code (the picker offers batch-tracked SKUs only) | Its batches by expiry (FEFO): code, mfg, expiry, status, quantity in this warehouse. A batch with 0 here is shown greyed, "0 in this warehouse" | A non-batch SKU → "This SKU isn't batch-tracked", decided from `SkuResponse.batchTracked` before any read |
| Batch detail | Open a batch | This warehouse's bins with quantities (by code), plus "N more in other warehouses" naming each warehouse. Then the history, oldest first, filtered to this warehouse | 404 → "Batch not found" |
| Maps not ready | Search while SKU/bin codes load or failed | Disabled with "Loading codes…", or a note naming the failed map | N/A |
| Many rows | Warehouse with > 200 rows | Load more fetches the next page in bin order | Failure keeps the loaded rows, with Retry |
| Ledger tab | `/inventory?tab=ledger` | The active warehouse's ledger, as `/inventory/ledger` shows it undrilled | As today |
| Drill links | Any "View ledger" link | Still lands on `/inventory/ledger` with its banner | As today |
| Warehouse switch | Switch on any tab | That tab re-reads for the new warehouse; the search clears | N/A |

</frozen-after-approval>

## Code Map

**Repos and branches.** Backend paths are under `workspace/core/backend/wms-be`, on branch `feat/inventory-screen` (from `main`). Frontend paths are under `workspace/core/frontend/wms-fe`, on branch `feat/inventory-screen`, which is stacked on the unpushed `feat/inbound-tabs` because it needs the page-tabs module.
- Do the backend first and commit it there. Then export the OpenAPI spec (`bun run openapi:export`, committed), then run `bun run api:generate` in wms-fe.
- Commit locally in each repo. Do not push, open PRs or switch branches.
- **Backend tests** use jest: `bun run test -- <file>`. Never bare `bun test`, and never two jest runs at once.
- **Frontend tests** use `bun test`.


- `wms-fe src/app/(app)/inventory/page.tsx`: today a `SurfacePlaceholder` plus a Ledger link. It becomes a server page that parses `tab` with a new `INVENTORY_PAGE_TABS` and keys `<InventoryScreen>` on `` `none|${tab ?? 'default'}` ``. There is no drill on this page; drills stay on `/inventory/ledger`.
- `wms-fe src/lib/page-tabs.ts`: add `INVENTORY_PAGE_TABS` (route `/inventory`, label "Inventory lists"). `src/components/shared/page-tabs.tsx`: reuse `usePageTab`, `PageTabStrip` and `PageTabPanel` as-is. Pattern: `outbound.tsx:76,155-185`.
- **Active warehouse:** `useTenantWarehouses` plus `readActiveWarehouseId`, with a first-warehouse fallback (`outbound.tsx:80-110`). Failure arms: `WarehousesFailure` and `WarehousesRefreshNote`.
- **Lookup maps:**
  - `useSkuMap` (`src/lib/use-inbound.ts:471`) and `useBinCodeMap(warehouseId)` (`:702`).
  - `useClients` (`src/lib/use-clients.ts:23`), with `showClients` and `clientCell` as on the PO card (`inbound-cards.tsx:221-232`).
  - The maps page through `fetchAllPages`, which stops silently at 20 pages (`src/lib/fetch-all-pages.ts:17-28`; about 1,000 SKUs at the default 50). That limit is accepted and recorded in PENDING, not fixed here.
- **API wrappers:**
  - `fetchApiListStock` (`src/lib/api/client.ts:2028`) gains `limit`, `order` and `nonZero`.
  - Add a `fetchApiListBatches` wrapper; the generated `inventoryControllerListBatches` exists in `sdk.gen.ts:801-846`.
  - `fetchApiGetBatch` (`:3412`) and `useBatchDetail` (`src/lib/use-replenishment.ts:619`) are reused for batch detail.
- **Backend read shapes (verified):**
  - `StockListQuery` (`wms-be src/modules/inventory/inventory.dto.ts:605-628`) takes `skuId?`, `binId?`, `cursor?` and `limit` 1-200.
  - `StockEntryDto` returns `id`, `warehouseId`, `skuId`, `binId`, `quantity` (base UoM) and `createdAt`.
  - The facade (`inventory.facade.ts:680-708`) orders by `createdAt DESC, id DESC`, applies no zero filter and builds the cursor through `canonicalInstant`.
  - The batch list (`controller:807-875`) requires `skuId`, is unpaged and comes back FEFO.
- **Backend (decided: additive change first):**
  - `inventory.dto.ts` (query and entry), `inventory.facade.ts` `listStock` (join `bins`; order `(bins.system_owned, bins.code COLLATE "C", sku_id, id)` with the location cursor payload above; `quantity > 0`).
  - `test/` for the new arms, plus the existing stock-list tests unchanged.
  - Then regenerate the web client.
- **Ledger:** `src/components/inventory/ledger.tsx` is reused undrilled in the Ledger tab. `src/app/(app)/inventory/ledger/page.tsx` and every link into it are untouched. The one exception is the `/inventory` page's own "Open the Ledger" link, which goes away because the tab replaces it.
- **System bin codes:** `wms-be src/modules/tenancy/receiving-bin.ts:23,46-47`. The web labels them by code in a new `lib/inventory.ts`, with a pure-tested `SYSTEM_BIN_LABEL`.
- **Tests:** new `components/inventory/inventory-screen.test.tsx` for the matrix rows. `drill-screens.test.tsx` already covers `/inventory/ledger` (`:68,74,532`) and must stay green unchanged.

## Tasks & Acceptance

**Test plan (named):**
- **BE** `test/inventory-surfaces.spec.ts`:
  - `order=location` across a page boundary with a tied bin code over two SKUs.
  - Storage bins come before system bins.
  - Collation: a `-` code sorts lexically.
  - A cursor sent with the wrong `order` → 400, in both directions.
  - `nonZero` combined with a cursor.
  - An unknown `order` → 400.
  - A same-code bin in another warehouse is never joined.
  - A default-arm page boundary within one microsecond.
  - The existing `test/inventory-surfaces.spec.ts:226-278` and `test/fractional-quantity.spec.ts:767` pass unedited.
- **Process:** the BE PR commits the regenerated `openapi/openapi.json` (CI runs `openapi:export` + `git diff --exit-code`). The FE runs `bun run api:generate` after the BE merge. The FE drift guard fails until then, which is expected.
- **FE:**
  - `client.test.ts` pins `fetchApiListStock` (limit, order, nonZero) and `fetchApiListBatches`.
  - `inventory.test.ts` covers the resolver (bin wins, case-insensitive, maps loading or failed) and `SYSTEM_BIN_LABEL` with its fallback.
  - `inventory-screen.test.tsx` covers every matrix row, including: a warehouse switch clears the search; Load more; the Ledger tab shows one failure arm; zero-quantity batch greyed; other-warehouse batch bins.
- `useStockScopes` (the QC-hold form) is left as it is, and its 1,000-row cap is recorded in PENDING.

**Execution:**
- [x] wms-be `inventory.dto.ts` + `inventory.facade.ts` + tests: additive `order=location`, `nonZero`, `binCode`, `binSystemOwned`, and the full-precision cursor. Backend PR first; regenerate the client.
- [x] `src/lib/page-tabs.ts`: `INVENTORY_PAGE_TABS`, plus its line in `page-tabs.test.ts`.
- [x] `src/lib/inventory.ts` + test: `SYSTEM_BIN_LABEL` and the search resolver (code → `{kind: 'bin' | 'sku', id}` from the maps, exact code match, case-insensitive).
- [x] `src/lib/api/client.ts`: `fetchApiListStock` params; `fetchApiListBatches`.
- [x] `src/components/inventory/inventory-screen.tsx`: the tabbed screen (Stock, Batches, Ledger).
- [x] `src/app/(app)/inventory/page.tsx`: parse `tab`, key and render.
- [x] `src/components/inventory/inventory-screen.test.tsx`: the matrix.
- [x] Meta docs: the `/inventory` row in frontend SYSTEM-DESIGN (and the "two placeholders left" line), API-SURFACE for the new parameters, and PENDING (the serial lookup by number; the map truncation).

**Acceptance Criteria:**
- Given stock in RECEIVING, D-01-01 and D-01-02, when Stock opens, then each non-zero (SKU, bin) shows once with its bin code, SKU code and name, and quantity at SKU precision, and system bins carry their word label.
- Given the search "GLOW-SERUM-30", when submitted, then only that SKU's rows are listed with a total, and the read sends `skuId` (no client-side filtering of a full list).
- Given any existing "View ledger" link, when followed, then `/inventory/ledger` renders exactly as before.

## Design Notes

**Why search resolves codes on the web.** The stock read filters by id. The SKU and bin maps are already loaded for display, so a code-to-id lookup costs no extra read. A code that matches both a bin and a SKU picks the bin, and the screen says so.

**Why the Ledger tab duplicates, not replaces, `/inventory/ledger`.** Drill links carry `list=ledger`, and `parseDrill('ledger')` owns that route. Moving the drills under `/inventory?tab=` would touch five link builders and the drill parser. Rendering the same component undrilled on the tab costs nothing and breaks nothing.

## Verification

**Commands:**
- `bun run typecheck` / `bun run lint` / `bun test` / `bun run build` (wms-fe) -- expected: clean, 0 fail
- `bun run test -- inventory` (wms-be, jest; never two runs at once) -- expected: green

**Manual checks:**
- On localhost:3001, on Bengaluru DC:
  - Stock shows D-01-01 with 297 × GLOW-SERUM-30 and D-01-02 with 148 × GLOW-SPF50-50.
  - Searching "D-01-01" narrows to that bin.
  - The Ledger tab matches `/inventory/ledger`.

## Implementation Notes

wms-be `feat/inventory-screen`, commit `8ab7c2b`; wms-fe `feat/inventory-screen`, commit `95d0d39`. Both local, not pushed.

- **BE.** `StockListQuery` gains `order?: 'location'` (`STOCK_LIST_ORDERS`, `@IsIn`) and `nonZero?` (`@BooleanFlag` + `@IsBoolean`); `StockEntryDto` gains optional `binCode`/`binSystemOwned`, **present only under `order=location`**, so the default arm's rows stay byte-identical (the existing exact-keys assertion at `inventory-surfaces.spec.ts` passes unedited). `nonZero` applies to both orders. The location arm is a private `listStockByLocation`: an inner join to `bins` on id + tenant + **warehouse**, order `(system_owned, code COLLATE "C", sku_id, id)`, keyset `> (…::boolean, …::text COLLATE "C", …::uuid, …::uuid)`, its own cursor codec (`{o:'location', sys, binCode, skuId, id}`, bin code ≤ 200 chars). `decodeCursorSafe` additionally refuses a payload carrying `o`. The default arm now encodes its cursor from `createdAt::text` via `fullPrecisionInstant`.
- **BE tests** (`test/inventory-surfaces.spec.ts`, a nested describe on a second warehouse): location order across a tied bin code at `limit=1`, storage before system, lexical codes (`D-01-10` < `D-01-2`, `D-02` < `D01`), the location item shape, `nonZero` with a cursor (and on the default order, and `nonZero=yes` → 400), a same-code bin in another warehouse never joined, wrong-order cursor 400 both ways plus a crafted location cursor, unknown `order` → 400, and the default arm paged at `limit=1` over rows stamped with one microsecond instant. Mutation-checked: reverting the default cursor to `canonicalInstant` fails the microsecond test; flipping the system-bin order fails the order test. Full BE suite: 86 suites, 2041 tests, green. `openapi/openapi.json` re-exported and committed.
- **Collation caveat.** The dev/CI Postgres is Alpine (musl), where `en_US.utf8` collates byte-wise — the spec's "`en_US.utf8` treats `-` differently" does not hold there, so the collation test passes with or without `COLLATE "C"`. Recorded in PENDING.
- **FE deviations from the Code Map, each for a stated rule:** the search maps are new `ResourceState` hooks (`useSkuCatalog`, `useWarehouseBins` in `lib/use-inventory.ts`) rather than `useSkuMap`/`useBinCodeMap`, because those swallow a failure into `null` and the box must name a failed map; `useWarehouseBins` fails the read when any zone fails (a partial map would make a bin search miss). `useBatchDetail` gained an optional reason-mapper argument so the Inventory detail reads "Batch not found" while the replenishment queue keeps its copy. The Load-more lists render a plain table (DataTable's Prev/Next would sit disabled beside Load more, and it has no per-row class for the greyed zero batch).
- **The matrix's miss wording** follows the Always rule ("No bin or SKU with code X found"), not the matrix row's "…in this warehouse"; with one map failed it names the other ("No SKU with code X found (bin codes are not loaded)"). A miss sends no read. A bin search drops the Bin column; a SKU search shows Bin and On hand plus the total footer, and no Load more (it walks every page; a failed page leaves "Loading every bin…" in the total and the failure with Retry).
- **FE verification:** typecheck and lint clean; `bun test` 1638 pass / 0 fail (`drill-screens.test.tsx` unchanged and green); `bun run build` succeeds (`/inventory` is `ƒ`); `check:capability-mirror` matches. `inventory-screen.test.tsx` (18) mutation-checked: dropping the warehouse key fails the switch test; wrapping the Ledger in the gate fails the single-failure test.
- **Manual check:** a temporary wms-be from this branch on :3010 answered `order=location&nonZero=true` for a Bengaluru DC tenant with `… D-01-01:297 D-01-02:148 IN-TRANSIT* QC-HOLD* RECEIVING* RETURNS*` (storage bins lexically, system bins last). The UI on :3001 was not exercised: the running wms-be on :3000 (`bun src/main.ts`, no watch) predates this branch and refuses `order=` (`forbidNonWhitelisted`) until restarted.

## Spec Change Log

## Review Triage Log

Design review: one pass, 13 findings. The load-bearing ones were checked against the code: `CursorPayload` holds `{createdAt, id}` only (`pagination.ts:8-11`); batch detail spans every warehouse (`inventory.controller.ts:886`); `Ledger` renders its own `WarehousesFailure` and empty arm (`ledger.tsx:110,120`); the database collation is `en_US.utf8`.

| # | Finding | Verdict | Disposition |
|---|---|---|---|
| 1 | The location cursor needs its own codec; a wrong-order cursor is undefined | high | Decision block: `{o:'location', sys, binCode, skuId, id}`, a validator, 400 both ways; tests |
| 2 | "Full-precision cursor" unscoped | medium | Decision block: the default arm moves to `fullPrecisionInstant`; PENDING entry amended; a microsecond test |
| 3 | Collation, natural order, where the system bins land | medium | Decision block: `COLLATE "C"` in the order and the comparison; lexical; system bins last |
| 4 | No index or migration decision | low | Decision block: no migration; the warehouse-scoped join; whole-warehouse sort → PENDING |
| 5 | Web paging undecided (`fetchAllPages` truncates silently) | high | Always: explicit pages, limit 200, Load more, reload epoch; a matrix row |
| 6 | The SKU total is wrong past one page | medium | Always: a SKU search walks every page before the total |
| 7 | The resolver when the maps are loading, failed or truncated | medium | Always + matrix row: disabled, a named failure, wording that never asserts absence |
| 8 | The batch list is tenant-wide; "not batch-tracked" is no API arm; the picker unspecified | medium | Matrix: decided from `batchTracked`; the picker offers batch SKUs; zero-quantity greyed |
| 9 | Batch detail is tenant-wide: other warehouses' bins have no code | medium | Matrix: this warehouse's bins by code + "N more in other warehouses"; history filtered |
| 10 | The page key vs the page-tabs rule; the Ledger tab double-owns the warehouse | medium | Always: key `none|tab`; bare `<Ledger />`; the gate wraps Stock and Batches only |
| 11 | System-bin labelling decided twice | low | Always: label only when `binSystemOwned`; an unknown-code fallback; codes verified |
| 12 | `nonZero` semantics; the `useStockScopes` cap | low | `quantity > 0` citing the CHECK; `useStockScopes` unchanged, its cap → PENDING; the existing tests named |
| 13 | Test plan gaps: openapi export, the FE generate order, the BE file, matrix rows, wrapper pins | medium | A named test plan in Tasks & Acceptance |
