# Catalog module

> What a tenant sells and how it is counted: SKUs, the spreadsheet import that creates them, batch and serial identity, and the closed unit-of-measure vocabulary every quantity in the system is denominated in.

Paths are relative to `workspace/core/backend/wms-be`. Read [`../IMPLEMENTATION-GUIDE.md`](../IMPLEMENTATION-GUIDE.md) first — the command skeleton, the quantity/milli-unit boundary and the controlled-vocabulary pattern are assumed.

The module is small in code and large in blast radius: `uom.ts` decides how precise every quantity in the warehouse may be, and `CatalogFacade` is on the hot path of receiving, putaway, waving and picking.

---

## Owns

| Table | Holds | Key invariants |
|---|---|---|
| `skus` (`src/shared/db/schema.ts:272`) | Sellable units: code, name, base `uom`, GST bps, HSN, tracking flags, reorder defaults, barcode | `skus_tenant_id_code_unique` **and** `skus_tenant_id_barcode_unique`. `uom` is CHECK-constrained to the closed vocabulary (`skus_uom_check`, `drizzle/0027_uom_vocabulary.sql:351`). `reorder_point`/`reorder_qty` are `bigint` **milli-units**. `barcode` is NOT NULL — generated server-side as a uuidv7 when the file omits one. **`code` is immutable**; no create endpoint exists — SKUs enter through import only |
| `uom_conversions` (`schema.ts:310`) | `factor` base units per alternate `uom`, per SKU | `uom_conversions_sku_id_uom_unique`; `factor` is a positive `integer`; target `uom` CHECK-constrained to the same vocabulary |
| `batches` (`schema.ts:344`) | Batch **identity** for batch-tracked SKUs: code, mfg/expiry dates, status | `batches_tenant_sku_code_unique`; `batches_status_check` ∈ {`active`,`blocked`} (`drizzle/0010_sharp_hardball.sql:71`). **No location or quantity column, by design** — those live in inventory's `batch_on_hand` |
| `serials` (`schema.ts:378`) | Serial **identity**: serial number, status | `serials_tenant_sku_serial_unique`; `serials_status_check`. **No location column** — a serial's location is derived from its latest `ledger_events` row |
| `catalog_imports` (`schema.ts:410`) | One row per run: `mode`, committed/failed/skipped counts | The run ledger. Fix mode targets the **latest** row (`created_at` desc, `id` desc) |
| `catalog_import_errors` (`schema.ts:442`) | One row per rejected data row: `row_number`, `sku_code`, `reason_code`, `reason_detail` | The latest run's non-null `sku_code`s **are** the fix set |

`gst_rate_bps` is an integer in basis points (18% = 1800). There are no price or cost fields — a deliberate 1.4 boundary.

---

---

## Schema (field level)

### `skus`

| Column | Type | Null | Default | Guard | Meaning |
|---|---|---|---|---|---|
| `code` | text | NO | — | `unique (tenant, code)` | **Immutable after import** — `PatchSkuDto` has no `code` |
| `uom` | text | NO | — | `skus_uom_check` | One of 35 canonical units (10.2). **Also immutable** — no `uom` on the PATCH DTO, which is what makes the serial rule's `current.uom` read sound |
| `gst_rate_bps` | integer | NO | — | — | **Basis points, not a quantity** (18% = 1800) |
| `hsn` | text | **YES** | — | — | Goods classification. A 3PL would need SAC instead |
| `batch_tracked` / `serial_tracked` | boolean | NO | `false` | — | **Both true is refused at pick** until story 14-1 |
| `reorder_point` / `reorder_qty` | bigint `mode:'number'` | NO | `0` | — | **Milli-units** — UoM-denominated, so 10.1 scaled them. Policy thresholds, not stock |
| `barcode` | text | NO | — | `unique (tenant, barcode)` | Collision → `409 duplicate-barcode` naming the conflicting SKU |

### `uom_conversions`
`sku_id` · `uom` text NOT NULL (`skus_uom_check` vocabulary) · `factor` **integer** NOT NULL. `unique (sku_id, uom)`.
**`factor` is an integer nothing multiplies by** — stored at import, echoed back, never applied. Fractional conversions wait for the story that first applies one.

### `batches`
`sku_id` · `code` (`unique (tenant, sku, code)`) · `mfg_date` / `expiry_date` timestamptz **nullable** · `status` text NOT NULL default `'active'` (`batches_status_check`).
**`expiry_date` drives FEFO** — which is why FEFO ordering lives outside inventory, in outbound and the api layer.
**Blocked status is unenforced on the draw side** (epic-2 retro a13).

### `serials`
`sku_id` · `serial_number` (`unique (tenant, sku, serial_number)`) · `status` (`serials_status_check`).
**No location column, by design** — a serial's location is derived from its latest `ledger_events` row via the `(tenant_id, serial_ref, seq)` index. The ledger is the only source of serial location and history.

### `catalog_imports`
`mode` text NOT NULL (`initial \| fix`) · `committed_rows` / `failed_rows` / `skipped_rows` integer NOT NULL — **counts, not quantities**, deliberately unscaled.

### `catalog_import_errors`
`import_id` · `row_number` integer NOT NULL · `sku_code` text **nullable** (null when the row failed before a code could be read) · `reason_code` NOT NULL · `reason_detail` NOT NULL.
**Durable error rows are what make fix mode possible** — it reprocesses the previous run's failed SKU codes. `reason_code` has **no DB CHECK**, so a new row-level arm needs no migration.

---

## Public seam

`CatalogModule` exports `CatalogFacade` only (`catalog.module.ts:32`). `ImportCommand` and `SkuCommand` are reachable only through this module's controller.

**`CatalogFacade`** (`catalog.facade.ts:98`):

| Method | Returns / does | Called by |
|---|---|---|
| `getImportSummary(tenantId)` `:101` | `{skuCount, lastImport}` | Tenancy's setup checklist |
| `findSku(tenantId, skuId)` `:138` | Identity + tracking flags, or `null` | Any module needing a 404 check before acting on a SKU |
| `getSkuSummaries(tenantId)` `:160` / `getSkuSummariesInTx(tx, …)` `:177` | The device catalog snapshot's scan identity: code, name, barcode, `uom`, **`uomPrecision`**, tracking flags | The api shell's device snapshot |
| `getBatches(tenantId, skuId)` `:198` | Batch identities, code-ordered | Inventory read surfaces |
| `getBatchesForSkusInTx(tx, tenantId, skuIds)` `:223` | Batch identities for a set, in the caller's tx | Outbound's wave planner (the FEFO half) |
| `findBatch` `:249` / `findSerial` `:275` | Identity + `skuId`, or `null` | Detail routes' 404 checks |
| `ensureBatches(tenantId, skuId, inputs)` `:307` / `ensureBatchesInTx` `:318` | Idempotent identity creation | Inbound's GRN command, stock adjustment |
| `ensureSerials(tenantId, skuId, serialNumbers)` `:371` | Idempotent identity creation | Same |

**`uom.ts` file-level functions** are imported directly by anything that needs the vocabulary: `resolveUom`, `uomPrecision`, `isFractionalUom`, `serialTrackedFractionalUomDetail`, `unknownUomDetail`, plus the `UOMS` tuple (consumed by `catalog.dto.ts` for the OpenAPI enum).

**The `…InTx` pairing is not a convenience.** `getSkuSummariesInTx` exists because the device catalog snapshot composes SKUs, bins, putaway tasks and pick tasks and must do so on **one** connection: a nested `withTenantTransaction` reserves a second pooled connection while the first is held, and postgres.js queues connection requests with no timeout — concurrent snapshots then wait on each other forever. `catalog.facade.ts:166-176` records that this endpoint deadlocked once already.

---

## Commands

### `ImportCommand.execute` (`import.command.ts:151`)

The one command in the repo with **partial commit**: a 201 can carry failures.

Guards, in the order they actually run:

1. **Size cap** `:152` — `> 5 MB` → 422 `import-too-large`. (Multer also caps at the same constant and its 413 is translated by `CatalogUploadFilter`, `catalog.controller.ts:72-84`.)
2. **Parse** `:155` — format sniffed by extension then mimetype; anything else → 415. Header contract, row cap and blank-row filtering all happen here (see Key algorithms). **This runs before the capability check** — see Gotchas.
3. Payload hash over `{sha256(file bytes), mode}` `:159` — never the parsed rows.
4. `assertPermission(…, 'catalog.import')` `:170`.
5. Replay lookup `:175`.
6. Fix-set resolution (fix mode only) `:199-218`.
7. Per-row validation, then duplicate detection.
8. Bulk insert of valid rows, chunked at 2,000.

Writes: `skus`, `uom_conversions`, `catalog_imports`, `catalog_import_errors`, `idempotency_keys`. Emits `catalog.imported` with the counts.

Response = idempotency snapshot = `{importId, mode, committedRows, failedRows, skippedRows, errors[]}`.

### `SkuCommand.edit` (`sku.command.ts:141`)

PATCH-only; `code` and `uom` are not editable.

Guards: empty-body check `:152` → hash over the **base-unit** field values `:170` → `sku.edit` capability `:182` → replay `:187` → SKU exists in tenant (404) `:207` → serial-tracking × fractional-UoM refusal `:227` → quantity precision conversion `:241-249` → barcode uniqueness pre-check (409 `duplicate-barcode` naming the conflicting SKU) `:254-263` → UPDATE.

Emits `catalog.sku_edited` `{skuId, code}`.

### `SkuCommand.list` (`sku.command.ts:86`)

A read, open to any tenant member. Page + conversions in **one** tenant transaction (`:95-124`); conversions are fetched for the page's SKUs only and stitched in memory.

### `CatalogFacade.ensureBatches` / `ensureSerials`

Not idempotency-keyed commands — identity creation. Both: fail-closed tracked-flag check (404 unknown SKU, 400 non-tracked SKU, `:409-438`) → dedupe the input → `insert … onConflictDoNothing` → **re-select as the source of truth** → return aligned to the caller's input order.

**Ensure is creation, never edit.** An existing batch keeps its original `mfgDate`/`expiryDate`; a retry with different dates rewrites nothing (`:296-298`, `:332-334`).

---

## Key algorithms

### Partial commit

The import's whole point: valid rows land, bad rows are reported, and there is no all-or-nothing rollback. Mechanically:

- Every row is validated into either `valid` or `errors` (`:230-233`). No exception escapes a row — `validateRow` returns a tagged result.
- Duplicate detection then filters `valid` into `insertable`, pushing one error per rejected row (`:242-259`).
- `committedRows = insertable.length`, `failedRows = errors.length`, and **both the SKU inserts and the error rows commit in the same transaction** as the `catalog_imports` run row and the idempotency record.

So a failure list is durable evidence, not a transient response body — which is what makes fix mode possible.

The only things that abort the whole run are file-level: too large, unparseable, unsupported type, no data rows, or a unique-violation race against a concurrent import (`:290-297`).

### Row validation order (`validateRow`, `import.command.ts:714`)

Shape first, one error per row, **first failure wins**: `sku_code` present/≤64 → `name` present/≤200 → `uom` present/≤32 → **`uom` resolves in the vocabulary** → `gst_rate` integer 0–10000 → `hsn` ≤32 → `batch_tracked` → `serial_tracked` → **serial × fractional-UoM refusal** → `reorder_point` → `reorder_qty` → `barcode` ≤64 → `uom_conversions` parsing.

Duplicate checks run afterwards because they need the whole file plus the tenant: file-internal code (naming the earlier row number), tenant code, then barcode (naming the conflicting SKU). Errors are sorted by `rowNumber` before persisting (`:264`) so the report is in document order regardless of which pass produced each one.

Machine codes clients branch on: `validation-failed`, `duplicate-sku-code`, `duplicate-barcode`.

### Fix mode (`import.command.ts:195-226`)

Set membership, not diffing, and deliberately has **no import picker**:

1. Find the tenant's latest `catalog_imports` row (`created_at` desc, `id` desc — uuidv7 makes the tiebreaker chronological).
2. Collect that run's `catalog_import_errors.sku_code` values, dropping nulls (a row that failed before a code could be read cannot be targeted).
3. Filter the uploaded file to rows whose trimmed `sku_code` is in that set. Everything else is `skippedRows` and is **left untouched** — not re-validated, not re-imported.

Because each run's failures form the next run's fix set, repeated fix rounds compose: fix 30 rows, 5 still fail, the next fix targets those 5.

A fix upload is a full file, not a delta — the operator re-submits the corrected spreadsheet.

### Row error reporting

`rowNumber` is the **1-based data-row index with the header excluded**, and it is renumbered in `finalizeRows` (`:619-632`) after blank rows are dropped — so it is gap-free and identical between CSV and XLSX, even though CSV's `skip_empty_lines` already compresses blanks while XLSX rows carry sheet-row gaps.

`skuCode` is null when the row failed before a code could be read. Note the pattern at `:763-780`: helpers that validate a field return an error with `skuCode: null`, and the caller re-stamps it (`{...result.error, skuCode: code}`) once a code is known.

### Header contract and parsing

Shared by both formats: required `sku_code`, `name`, `uom`, `gst_rate`; optional `uom_conversions`, `hsn`, `batch_tracked`, `serial_tracked`, `reorder_point`, `reorder_qty`, `barcode` (`:86-96`). An unknown column, a duplicate column, a missing required column, or a file with no data rows is 400 `file-unreadable`.

Three parser traps handled explicitly:

- **CSV**: `relax_column_count` keeps parsing a row with extra fields but parks them in `__parsed_extra` — silent data loss, so it is rejected (`:546-548`). The header check runs inside csv-parse's `columns` callback but **captures** the problem rather than throwing, so the code never depends on how csv-parse propagates callback errors (`:500-541`).
- **XLSX**: a workbook with more than one worksheet is rejected — only the first would silently win (`:574-576`). `cellText` (`:635`) unwraps formulas (`{result}`), rich text, dates and booleans.
- **Duplicate header column**: rejected in both formats because the last occurrence would silently win.

Bulk inserts are chunked at 2,000 rows (`INSERT_CHUNK_ROWS`, `:405`): Postgres binds at most 65,535 parameters per statement, and 10,000 rows × 12 columns would exceed it and 500 a file that passed the row cap.

### The UoM vocabulary (`uom.ts`)

**Two lists, not one.**

- `UOMS` (`:60-104`) — 35 canonical units, grouped by family (count/packaging, counted containers, mass, volume, length, area). This tuple and the `skus_uom_check` / `uom_conversions_uom_check` CHECKs in `drizzle/0027_uom_vocabulary.sql` are **one list**; `test/uom-precision.spec.ts:520` fails on drift.
- `UOM_ALIASES` (`:167-308`) — what a spreadsheet may *say*. `kgs`, `kilogram`, `kilo`, `"Kg."` → `kg`; `pcs`, `pc`, `piece`, `nos`, `unit`, `item`, `qty` → `each`.

**Resolution** (`resolveUom`, `:342`): normalize (trim, lowercase, collapse internal whitespace, strip trailing `.,;:`) → canonical hit → alias hit → `null`. An unresolvable unit is a **row-level** refusal naming the spelling and sampling one unit per family (`unknownUomDetail`, `:418`), so the rest of the file still commits and fix mode can re-submit that row.

**Precision is a property of the unit, not the SKU.** `UOM_PRECISION` (`:118-154`): every count/packaging/container unit declares 0 decimal places; every measured unit (mass, volume, length, area) declares 3. There is no per-SKU precision anywhere and no precision column — which is what lets the device validate a scan offline from the `uomPrecision` its cached catalog snapshot carries (`catalog.facade.ts:80-94`).

`uomPrecision(uom)` (`:360`) **fails closed**: an unresolvable unit is treated as `QUANTITY_DECIMALS` (3, the finest the milli-unit representation holds), which refuses serial tracking rather than waving an unknown unit past the rule.

**Three load-time guards** run on import (`assertVocabularyIsRepresentable`, `:458`, invoked at `:495`) — so a violation is a process failure in the first test that imports the module, never a mystery at an edge:

1. No unit declares more decimals than `QUANTITY_DECIMALS`.
2. No alias is also a canonical unit; every alias resolves to a canonical unit; every alias is already in normalized form (an un-normalized alias could never match).
3. `STORY_10_1_DISCRETE_UOMS` (`:448-456`) — every spelling the pre-vocabulary allowlist blessed still resolves, and still to a 0-dp unit. Dropping one would leave stored rows failing `skus_uom_check` and take migration 0027 down.

`WHOLE_UNIT_UOMS` (`:320`) is **derived** from the precision table, never listed twice; migration 0027 declares the same set in a temp table and the e2e suite pins the two together, so adding a 0-dp unit cannot silently miss the migration's rounding statements.

**Why a CHECK and not a `pgEnum`** (`:39-48`): a vocabulary expected to grow is the wrong thing to put in a Postgres type — `ALTER TYPE … ADD VALUE` has its own transaction rules and values cannot be reordered or removed, while a CHECK is dropped and re-added with a widened set (the repo's ten other vocabularies do exactly this). Imperial units are **deliberately absent** — they are only useful alongside conversions, which do not exist yet.

### The serial / whole-unit rule

A serial-tracked SKU moves exactly one whole unit per serial; four call sites compare a unit count against `serials.length`. A SKU that is both serial-tracked and measured to three decimals is a contradiction, so it is refused **once, at catalog entry**, rather than converted four times downstream.

Two refusal sites, one message (`serialTrackedFractionalUomDetail`, `uom.ts:395`):

- Import, when a row sets `serial_tracked` on a fractional unit (`import.command.ts:771-776`) — a row error, so the rest of the file commits.
- `SkuCommand.edit`, when `serialTracked` is turned **on** for a SKU whose stored `uom` is fractional (`sku.command.ts:227-234`) — a 400.

The rule is a **precision lookup**, not a hand-maintained list of "discrete" spellings — which is the point: a legitimate whole-unit unit nobody remembered to enumerate no longer gets a false refusal (`test/uom-precision.spec.ts:863`).

### Quantities cross the edge inside the command, never at the controller

`reorder_point` / `reorder_qty` are stored in milli-units. Both write paths convert **behind the replay lookup**:

- Import: `parseQuantityMilli` (`:677`) — empty cell means zero; a non-numeric or over-ceiling value is a row error; **a value finer than the row's own unit is a row error, not a rounding** (`:699-704`).
- Edit: `assertRecordableQuantity` (`sku.command.ts:241-249`), called after the SKU row — and therefore its unit — is in hand.

`catalog.controller.ts:220-227` records why the controller must not scale: converting at the edge would put the precision refusal in front of the replay, answering 400 to an op that already committed. `toSnapshot` (`sku.command.ts:332`) is the module's only SKU read shape — base units leave there, milli-units stay in the column.

---

## Invariants

| Invariant | Enforced by |
|---|---|
| SKU codes and barcodes are unique per tenant | `skus_tenant_id_code_unique`, `skus_tenant_id_barcode_unique`, plus the import's file-internal + tenant pre-checks |
| A duplicate is rejected, never merged | Row-level `duplicate-sku-code` naming the code; the message says so verbatim |
| Every SKU has a barcode | NOT NULL + `barcode: row.barcode ?? uuidv7()` (`import.command.ts:284`) |
| SKU code and base UoM are immutable | No create endpoint; `PatchSkuDto` (`catalog.dto.ts:127`) carries neither |
| Every stored `uom` is canonical | `resolveUom` at the only creation path + `skus_uom_check` / `uom_conversions_uom_check` |
| A serial-tracked SKU is measured in whole units | The two refusal sites above |
| No quantity is finer than its unit declares | `parseQuantityMilli` / `assertRecordableQuantity` |
| Batch and serial rows carry no location or quantity | No such column exists; inventory owns `batch_on_hand`, the ledger owns serial location |
| Identity creation is idempotent and never rewrites | `onConflictDoNothing` + re-select in both ensures |
| Batch/serial arms open only for tracked SKUs | `assertSkuTracked` (`catalog.facade.ts:409`) |
| One conversion per (sku, uom), factor a positive integer | `uom_conversions_sku_id_uom_unique`; per-row repeat check (`:830-835`); `INT_MAX` bound |
| A conversion target is never the SKU's own base unit | `:824-829` |
| Catalog tables are catalog-exclusive | `test/architecture.spec.ts` bans writes outside the module; siblings use `CatalogFacade` |

---

## Events

| Type | Emitted by | Payload |
|---|---|---|
| `catalog.imported` | `ImportCommand.execute` | `{importId, mode, committedRows, failedRows, skippedRows}` — counts only, never rows or errors |
| `catalog.sku_edited` | `SkuCommand.edit` | `{skuId, code}` |

Both appended in-transaction through `OUTBOX_SINK`; a replay returns before the append, so it emits nothing.

`ensureBatches` / `ensureSerials` emit nothing — identity creation is not a domain event.

---

## Gotchas

**The file is parsed before the capability is checked.** `import.command.ts:152-155` runs the size cap and the full CSV/XLSX parse *before* the transaction opens at `:164` and therefore before `assertPermission` at `:170`. A caller without `catalog.import` can drive a 5 MB parse and learn `file-unreadable` / `unsupported-file-type` / `import-too-large` outcomes. This inverts the guide's "authority before validation" rule, which exists precisely so an unauthorized caller learns nothing from error messages. Moving the parse inside the transaction is the fix; it is not recorded in `../PENDING.md`.

**A concurrent-import unique violation names the wrong SKU.** `:294` throws `duplicateSkuCode(insertable[0]!.code)` — the *first* insertable row's code, not the one that actually collided. `sku.command.ts:321` has the same shape, throwing `duplicateBarcode(fields.barcode ?? '', '')` with an empty conflicting code. Both are rare races (pinned by `test/catalog.spec.ts:832,863`), but the message misleads whoever hits one.

**`conversionRows` is index-aligned, not id-joined.** `:298-306` maps `insertable.flatMap((row, i) => … skuRows[i]!.id)`. It is correct only because `skuRows` is built from `insertable` in order at `:271`. Any filtering, sorting or partial retry between those two points silently attaches conversions to the wrong SKU.

**`uom_conversions.factor` is stored and echoed but never applied.** Nothing in the system does arithmetic with it (`../PENDING.md` → catalog). Do not assume a quantity has been converted through it anywhere.

**`uomPrecision` ships unconsumed on the device.** The catalog snapshot carries it so a handheld can refuse a too-precise scan offline before queueing. Until the mobile story lands, a too-precise dead-zone scan queues and is refused on replay — the exact behaviour the field exists to prevent. `../PENDING.md` flags this as a **live gap**, not a deferred nicety.

**`UOM_ALIASES` is built on `Object.create(null)`, deliberately** (`uom.ts:167-175`). A `uom` cell is spreadsheet-controlled text; on an ordinary object literal `aliases['constructor']` answers a Function and `aliases['__proto__']` an object — both truthy, so `?? null` never fires, the unknown-unit refusal is skipped, and the importer writes a "unit" that is a function. Never replace it with `{}`.

**A nested `withTenantTransaction` in this facade deadlocks.** `catalog.facade.ts:166-176` documents it having happened: postgres.js queues connection requests with no timeout, so a facade method that opens its own transaction while the caller holds one can exhaust the pool under concurrency. That is why `getSkuSummariesInTx` and `getBatchesForSkusInTx` exist. Add the `…InTx` variant when a new caller composes.

**The import payload hash is over the file bytes, not the parsed rows.** The same spreadsheet re-uploaded under the same key replays; a whitespace-different but semantically identical file does not. Reusing a key with a different file is 422 `idempotency-key-reuse` (`test/catalog.spec.ts:417`).

**The `errors.sort` comment is stale.** `:261-263` says duplicates are collected "in the loop below"; that loop is above the sort. The behaviour is right — everything is pushed before `:264` sorts — but the comment misdirects.

**`getSkuSummariesInTx` derives `uomPrecision` in process, never from a table** (`catalog.facade.ts:191-194`). There is no per-SKU precision to select. Adding a lookup read there is the nested-pool shape described above.
