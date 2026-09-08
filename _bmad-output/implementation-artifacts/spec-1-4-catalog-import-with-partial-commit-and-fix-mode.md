---
title: 'Story 1.4 — Catalog import with partial commit and fix mode'
type: 'feature'
created: '2026-09-08'
status: 'done'
baseline_commit: 'meta d16f1a4f14f9265843ea3d8b0fbd3905bf8fe8df · wms-be a3d743b70fe931ca3fede9a41aa78fa3f7280497 · wms-fe 657976927122409f242cd40432e3911c385598fc'
route: 'dispatch'
review_loop_iteration: 0
context: ['_bmad-output/implementation-artifacts/epic-1-context.md']
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** A seller has a warehouse floor (1.3) but no catalog — no SKUs exist, so Epic 2's ledger and Epic 3's GRN have nothing to reference, and the setup checklist's catalog step is honestly stuck pending. Importing a 5,000-row sheet today would be all-or-nothing: one bad row forces a full restart.

**Approach:** Build the catalog module: `skus` (+ UoM conversions, GST bps, HSN, batch/serial flags, reorder defaults, server-generated barcode), a synchronous multipart CSV/XLSX import that commits valid rows and reports row-level errors, a downloadable error report, fix-mode re-import of only previously failed rows, SKU list + individual edit, and flip the checklist's catalog step via a catalog facade.

## Boundaries & Constraints

**Always:**
- Partial commit is honest: valid rows commit in one transaction, bad rows are listed per row with a machine-readable reason (`error: {rowNumber, skuCode, code, detail}`); the response carries committed/failed counts and the error list.
- Duplicate SKU code (vs tenant's existing SKUs or within the file) is a row-level rejection naming the code — never a silent merge, never a whole-import 409. One barcode resolving to two SKUs is a row-level rejection naming the conflicting SKU.
- Fix mode processes only rows whose SKU code failed in the tenant's most recent import run; other rows are counted as skipped and left untouched. (Decision: targeting is automatic — latest run, no import picker.)
- Decisions from planning: manual SKU creation is out of scope — the story ships import + individual edit only; manual create defers to a later catalog story.
- Barcode values are generated server-side at entry (uuidv7-derived); a provided barcode column is honored. Barcodes are unique per tenant.
- AD-5 carried forward: Idempotency-Key on import and edit; the import is one transaction + one idempotency record, replay re-serves the same result snapshot.
- AD-3: every new table carries `tenant_id` + RLS policy verified by test, fail-closed; no FKs (uuid columns + app-layer integrity); problem-details errors with machine codes; deterministic primitives (uuidv7, UTC, cursor pagination).
- GST stored as basis points (integer); UoM conversion factors stored as positive integers relative to the SKU's base UoM.

**Never:** no manual SKU create (import + edit only, per planning decision), no async/queued import jobs (synchronous in-request), no server-side file storage (error report is generated client-side from the response), no price/cost fields, no channel mappings, no barcode scanning hardware, no catalog editing beyond the PATCH fields (SKU code immutable, barcode changeable), no image/attachment handling.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Import CSV | `POST .../catalog/imports` multipart CSV/XLSX + Idempotency-Key | 201: `{importId, mode, committedRows, failedRows, skippedRows, errors[]}`; valid rows live; replay re-serves same snapshot | 422 `import-too-large` (>10,000 rows or >5 MB); 415 `unsupported-file-type` (not .csv/.xlsx); parse failure → 400 `file-unreadable` |
| Bad rows | 5,000-row file, 30 invalid (bad gst, empty name, duplicate code…) | 4,970 committed; errors name rowNumber + skuCode + code | 409-style row codes: `duplicate-sku-code`, `duplicate-barcode` (naming conflicting SKU), `validation-failed` |
| Fix mode | Re-upload with `mode=fix` after a run with N failed rows | Only rows whose skuCode ∈ latest run's failed set are processed; others counted `skippedRows` | Rows that still fail list errors again (they form the next failed set) |
| SKU list | `GET .../catalog/skus?cursor&limit` | 200 keyset pages `{items, nextCursor}` | 400 `invalid-cursor` on crafted cursors; limit 1–200 |
| Edit SKU | `PATCH .../catalog/skus/{skuId}` `{name?, gstRate?, hsn?, batchTracked?, serialTracked?, reorderPoint?, reorderQty?, barcode?}` | 200 updated SKU | Unknown SKU → 404 `not-found`; barcode colliding with another SKU → 409 `duplicate-barcode` naming it |
| Checklist | `GET /tenants/{t}/setup-checklist` after a partial import | catalog step done when ≥1 SKU exists; detail honest ("N SKUs · last import X committed, Y failed") | — |
| Isolation | Foreign session reads/writes catalog | Empty / 403/404 (fail-closed RLS verified by test) | — |

</frozen-after-approval>

## Code Map

- `wms-be/package.json` — add `multer` + `@types/multer` (Nest 12 doesn't bundle it), `csv-parse`, `exceljs` (xlsx read). Nothing upload-related exists today.
- `wms-be/src/modules/catalog/` — all new: `catalog.module.ts` (placeholder exists), `catalog.controller.ts` (@Controller('tenants'), copy tenancy guard/header/problem-response patterns incl. `@ApiConsumes('multipart/form-data')`), `catalog.dto.ts`, `import.command.ts`, `sku.command.ts`, `catalog.facade.ts`.
- `wms-be/src/modules/tenancy/tenant-scope.ts` — move `withTenantTransaction`/`TenancyTx` to `src/shared/db/tenant-scope.ts` (catalog needs tenant-scoped tx; tenancy imports the shared path). Leave the event-bus token in tenancy (`catalog` imports `EVENT_BUS` from there — precedented seam).
- `wms-be/src/modules/tenancy/tenancy.service.ts:264` — `computeSetupChecklist`: replace the hardcoded catalog-pending block with a call into the catalog facade (TenancyModule imports CatalogModule; catalog exports the facade interface only).
- `wms-be/src/shared/db/schema.ts` + `drizzle/0004_*.sql` — tables `skus` (unique `(tenant_id, code)`, unique `(tenant_id, barcode)`, keyset index), `uom_conversions` (sku_id + uom), `catalog_imports` (mode, counts), `catalog_import_errors` (import_id, row_number, sku_code, reason code/detail); hand-written RLS DDL per 0003 pattern; next migration number 0004.
- `wms-be/test/catalog.spec.ts` (new) — copy bootstrap/cleanup/registerTenant helpers from `test/tenancy.spec.ts`; extend cleanup (import_errors → imports → conversions → skus before zones); supertest `.attach()` for multipart; RLS probes on the new tables.
- `wms-fe/src/components/settings/import-catalog.tsx` (new) — wizard card: file input → in-flight state → result (counts + error table + "Download error report (.csv)" via Blob) → fix-mode checkbox; FeedbackBanner + local `rejectionReason` copy branching on `import-too-large`/`unsupported-file-type`/`file-unreadable`/`validation-failed`/`duplicate-sku-code`/`duplicate-barcode`.
- `wms-fe/src/components/settings/sku-table.tsx` (new) — DataTable (code, name, UoM, GST %, HSN, batch/serial, barcode) + inline edit row form; Prev/Next cursor paging.
- `wms-fe/src/lib/use-catalog.ts` (new) + `src/lib/catalog.ts` (CATALOG_CHANGED_EVENT pattern of `zones.ts`); `src/lib/api/client.ts` — new fetchApi* wrappers incl. multipart FormData; `settings/page.tsx` — slot the card group between ZonesBinsSetup and WarehouseList. Checklist card needs no change (backend drives it).
- `docs/repos/wms-be/README.md`, `docs/repos/wms-fe/README.md` — contract updates (endpoints, partial-commit semantics, fix-mode rule).

## Tasks & Acceptance

**Execution:**
- [x] `wms-be` — deps (multer, csv-parse, exceljs); `src/shared/db/tenant-scope.ts` move; schema.ts `skus`/`uom_conversions`/`catalog_imports`/`catalog_import_errors` + `drizzle/0004_*.sql` with RLS.
- [x] `wms-be/src/modules/catalog/**` — import command (parse csv/xlsx → validate per row → insert valid + error rows in one tx, idempotent, ≤10,000 rows/5 MB), sku command (PATCH edit w/ barcode-conflict check), controller routes + DTOs, facade (`getImportSummary(tenantId)`).
- [x] `wms-be` — tenancy checklist reads the facade; `bun run openapi:export`.
- [x] `wms-be/test/catalog.spec.ts` — partial-commit, duplicate/barcode conflicts, fix-mode skipping, replay, limits, RLS probes, checklist flip; all matrix rows covered.
- [x] `wms-fe` — regenerated client, fetchApi* wrappers, use-catalog hooks, import wizard card + SKU DataTable/edit, settings wiring.
- [x] Meta — both interface-contract READMEs updated.

**Acceptance Criteria:**
- Given a 5,000-row import with 30 bad rows, then 4,970 commit, the response names each bad row and reason, and a downloadable error report is produced.
- Given fix mode re-import, then only previously failed rows are processed and the rest are skipped.
- Given a duplicate SKU code or a barcode resolving to two SKUs, then the row is rejected naming the conflict.
- Given a SKU edited afterward, then the fields persist and the checklist's catalog step reflects true state honestly.
- Given lint + tests + typecheck + build in both repos, then all pass and OpenAPI drift guards stay green.

## Design Notes

- **Fix mode is set-membership, not diffing:** latest run's failed SKU codes are the fix set; re-uploaded rows outside it are `skippedRows`. This makes repeated fix rounds compose without history selection.
- **Row validation order (per row):** shape → gst bps range → uom factor positive int → duplicate-sku-code (file-internal then tenant) → duplicate-barcode. First failure wins; one error per row.
- **Import response snapshot is the idempotency payload** — replaying the same file+key re-serves the exact counts and error list (hash over file sha256 + mode).
- **Excel parsing:** `exceljs` workbook → rows; CSV via `csv-parse`; header row required with fixed column names (`sku_code,name,uom,uom_conversions,gst_rate,hsn,batch_tracked,serial_tracked,reorder_point,reorder_qty,barcode?`) documented in the wizard card; `uom_conversions` format `box:12;case:144`.

## Verification

**Commands:**
- `bun test` (wms-be) — expected: all pass incl. new catalog suite; RLS probes fail-closed.
- `bun run lint && bun run typecheck` (both repos) — clean.
- `bun run openapi:export` (wms-be) then client regeneration (wms-fe) — drift guards green.
- `bun run build` (wms-fe) — succeeds.

**Manual checks:** Settings shows the import card; a small CSV with 2 bad rows commits the rest, shows counts + error table, downloads a CSV naming rows/reasons; fix-mode re-import reports skipped rows and commits fixed ones; checklist shows honest catalog detail.

## Review Triage Log

| # | Finding (source) | Verdict | Evidence |
|---|------------------|---------|----------|
| 1 | No endpoint exposes a past run's row-level errors (`catalog_import_errors` persisted but unexposed) (blind-hunter) | low | Verified: controller has only the three routes; fix mode reads the table internally but nothing GETs history. Fix is a new public surface (route + DTO + OpenAPI + client + UI) — an enhancement beyond the intent, and the downloadable client-side report covers the immediate need. Rejected. |
| 2 | No search/filter on the SKU list (blind-hunter) | low | Verified absent; finding is a feature addition (new query surface + index). Not in intent. Rejected. |
| 3 | `ImportResult` renders the error table unbounded — thousands of bad rows hit the DOM at once (blind-hunter) | low | Verified: `result.errors.map` with no cap. Direct correction: slice to the first N with a pointer to the downloadable full report. |
| 4 | Import concurrent-writer 409 names `insertable[0].code`, not the actually-colliding code (blind-hunter, edge-case-hunter) | low | Verified at import.command.ts:261. Race-only path; status and machine code are correct, and naming the true code needs an out-of-tx re-query — same trade-off accepted in 1.3 (#9). Fix adds error-path complexity for a rare race. Rejected. |
| 5 | PATCH barcode race throws `duplicateBarcode(fields.barcode, '')` — empty conflicting code, generic detail (blind-hunter) | low | Verified at sku.command.ts:241. Sequential paths name the conflicting SKU (test asserts it); only the true-concurrency race lands here, and naming it needs an out-of-tx re-query (same 1.3 #9 trade-off). Rejected. |
| 6 | README claims duplicates are "never a whole-import 409" while the import's concurrent-writer fallback throws a whole-import 409 (blind-hunter, edge-case-hunter claim, verification-gap) | low | Verified: import.command.ts:260-262 aborts the whole transaction with 409 `duplicate-sku-code` when the insert loses a race — the docs' absolute claim is false for that path (transient; a retry re-runs the row-level checks). Direct fix: honest doc wording. |
| 7 | The 409s (`conflict`, import-race `duplicate-sku-code`) are absent from the import route's OpenAPI response set (blind-hunter) | low | Verified in generated types: import errors are 400/401/403/415/422 only. Direct fix: document the existing 409 responses (text + re-export + client regen). |
| 8 | `skus` keyset query has no `(tenant_id, created_at, id)` composite index (`catalog_imports` got one) (blind-hunter) | low | Verified in schema: only bare `skus_tenant_id_idx` + `(created_at, id)`. Fix is a new migration — mirrors 1.3 #14's accepted deferral ("revisit when volumes grow"). Deferred. |
| 9 | No CHECK constraints back the documented invariants (mode text, gst 0–10000, factor positive) (blind-hunter) | low | Verified in 0004 SQL; repo convention is app-layer integrity (no FKs either) — adding DB CHECKs is a convention change plus a migration, not a direct correction. Rejected. |
| 10 | Fix mode gives no preview of the set being targeted (blind-hunter) | low | Verified absent; the locked planning decision settled auto-targeting of the latest run, and a preview is new API surface + UI. Rejected. |
| 11 | No frontend tests for the new components/hooks (blind-hunter) | low | Verified; matches the accepted repo convention — e2e coverage lives backend-side, FE unit tests only for pure logic (fetch-all-pages, proxy gate). `useZoneBins` (1.3) is likewise untested. Rejected. |
| 12 | Domain events `catalog.imported`/`catalog.sku_edited` unobserved by tests (blind-hunter) | low | Verified — no test reads the bus; the only consumer is the log-only bus. Mirrors 1.3 #23: pin when the first subscriber lands. Deferred. |
| 13 | `useSkus` swallows fetch errors — prior page keeps rendering on a failed refetch of the current scope; with no prior page the "No SKUs yet" empty state misleads (blind-hunter, edge-case-hunter, verification-gap) | low | Verified in use-catalog.ts: failure leaves `page` untouched and it passes the render-time key check. Quiet-chrome-on-failure is the accepted 1.2/1.3 read-only-surface convention (1.3 #19); a real error state adds hook machinery beyond a direct correction. Rejected. |
| 14 | 5 MB pre-check is display-only — submit stays enabled for a doomed 422 (blind-hunter) | low | Verified: button `disabled={pending \|\| file === null}` ignores file size. Direct fix: disable. |
| 15 | Re-submitting the same file after success predictably fails every row with `duplicate-sku-code` (blind-hunter) | false | That is the feature working as specified: re-imported existing codes ARE duplicates, rejected row-level naming the code — exactly the honest behavior the spec mandates. Rejected. |
| 16 | `downloadErrorReport`: no UTF-8 BOM (Excel mojibake), immediate `revokeObjectURL` race, anchor never appended (blind-hunter, edge-case-hunter) | low | Verified in import-catalog.tsx. Direct small fixes: BOM prefix, `appendChild` + deferred revoke. |
| 17 | CSV formula injection in the error report (`=+-@`-prefixed skuCode/detail executes in Excel) (edge-case-hunter) | low | Verified: `csvField` only quotes. One-line guard prefixing `'`. Same defect family as #16 (report hardening). |
| 18 | Error list is not globally sorted by rowNumber (validation failures first, then duplicate failures, each in row order) (blind-hunter) | low | Verified at import.command.ts:204-233 — two sequential loops; the 5,000-row test passes only because all failures are validation failures. Direct fix: sort by rowNumber before snapshot/persist. |
| 19 | README multi-tenancy bullet still says RLS "on all four tables (migration `0001_greedy_scarecrow.sql`)" — misleading now that 0004 carries four more (blind-hunter) | low | Verified in the meta docs diff. Text-only fix. |
| 20 | `CatalogUploadFilter` hardcodes "(5 MB)" beside the interpolated `MAX_IMPORT_BYTES` (blind-hunter) | low | Verified in catalog.controller.ts. One-line text fix deriving the wording from the constant. |
| 21 | No retention/cleanup story for `idempotency_keys` + three new append-only tables (blind-hunter) | low | Verified; `idempotency_keys` growth predates this story (1.2 bullet already flags it). Pre-existing concern → deferred. |
| 22 | Missing trailing newlines on new files (blind-hunter) | low | Verified; cosmetic, and several pre-existing repo files lack them too (1.3 #20 precedent). Rejected. |
| 23 | Bind-param ceiling: the three bulk inserts are single statements — >5,461 rows (12 cols) or >9,362 error rows (7 cols) exceed Postgres' 65,535 limit → whole import 500 despite passing the 10,000-row cap (edge-case-hunter) | medium | Verified: `tx.insert(skus).values(skuRows)` etc. at import.command.ts:256/275/288, no chunking anywhere in the file. The documented cap admits files the insert physically cannot write. Direct fix: chunk the inserts. |
| 24 | Multer errors other than LIMIT_FILE_SIZE (unexpected file/field/parts) bypass `CatalogUploadFilter` → 500 (edge-case-hunter) | low | Verified: `@Catch(PayloadTooLargeException)` only; platform-express transforms only LIMIT_FILE_SIZE into 413. Malformed multipart is rare (the shipped UI sends exactly one file field) and the fix is a small catch extension. |
| 25 | Duplicate header column name silently passes the header contract — last occurrence's values win, first column's data silently lost (edge-case-hunter) | medium | Verified in both parsers: CSV's `headerNames` Set absorbs duplicates and object assignment overwrites; XLSX's `columns.set` maps two colNumbers to one name, last wins. Silent data loss against the honest-parse contract. Direct fix: reject as file-unreadable. |
| 26 | XLSX data on a second worksheet is silently ignored (`worksheets[0]`, no guard) (edge-case-hunter) | medium | Verified at import.command.ts:499. Rows on other sheets silently dropped while counts read complete. Direct fix: file-unreadable when the workbook has multiple sheets. |
| 27 | XLSX `rowNumber = sheetRow − 1` preserves blank-row gaps while CSV's `skip_empty_lines` compresses them — neither matches the documented "1-based data-row index" (edge-case-hunter) | low | Verified both paths. Direct fix: renumber sequentially after blank filtering in both parsers. |
| 28 | `relax_column_count: true` silently discards fields beyond the header (no `__parsed_extra` check) (edge-case-hunter) | low | Verified at import.command.ts:457. Direct fix: reject rows with extra fields as file-unreadable. |
| 29 | Concurrent-write fallback branches in both catalog commands are unverified — no test asserts one-201-one-409-`conflict` or the writer-race mapping (verification-gap, pre-verified) | medium | Filed evidence: greps over test/ find no concurrency assertions; every idempotency test is sequential. A regression in the unique-violation mapping would 500 real double-submits undetected. Disposition filed: add Promise.allSettled e2e tests. Patch. |
| 30 | SKU edit always sends every field, so every save bumps `updated_at` even with no change (verification-gap) | low | Verified, but harmless (the finding itself notes it; full-field PATCH is normal form behavior). No named harm. Rejected. |

**Grouping → routing** (`review_loop_iteration` stays 0 — no loopback):

- **patch** G1 (#23, medium): bulk inserts exceed the Postgres bind-param ceiling above ~5,461 rows — chunk all three inserts.
- **patch** G2 (#25+#26+#28, medium): parse boundary silently accepts malformed structure (duplicate header column, extra worksheet, extra fields) — reject as `file-unreadable`.
- **patch** G3 (#29, medium): concurrency fallback branches untested — Promise.allSettled e2e tests for `409 conflict` and the PATCH barcode race.
- **patch** G4 (#6+#7, low): concurrent-race 409s mis/undocumented — honest README wording + OpenAPI 409 responses (re-export + client regen).
- **patch** G5 (#16+#17, low): error-report CSV hardening (BOM, anchor append + deferred revoke, formula-injection guard).
- **patch** G6 (#3, low): cap the rendered error table with a pointer to the downloadable report.
- **patch** G7 (#14, low): disable submit when the picked file exceeds 5 MB.
- **patch** G8 (#18, low): sort errors by rowNumber before snapshot/persist.
- **patch** G9 (#20, low): derive the filter's size wording from `MAX_IMPORT_BYTES`.
- **patch** G10 (#19, low): fix the stale 0001 parenthetical in the README RLS bullet.
- **defer** D1 (#8): `skus` composite keyset index — revisit at volume (mirrors 1.3 #14).
- **defer** D2 (#12): domain events unpinned until the first subscriber (mirrors 1.3 #23).
- **defer** D3 (#21): retention/cleanup for idempotency keys + append-only catalog ledger tables.

## Spec Change Log

- **2026-09-08 — Created** from Story 1.4 intent (epics.md) + epic-1 context; investigation by two subagents (upload/parse infrastructure gap, checklist seam); both Open Questions answered by the user (import + edit only, no manual create; fix mode auto-targets the latest run).
- **2026-09-08 — Implemented** across all three repos (wms-be `0cb176f`, wms-fe `faa1514`, meta `5eb9659`, branch `feat/1-4-catalog-import-with-partial-commit-and-fix-mode`, local commits only). Orchestrator verification re-run: backend 60/60 e2e (15 new catalog tests; matrix audit 7/7 rows covered), lint + typecheck clean; frontend lint/typecheck clean, 50 tests, build succeeds. Diff staged and judged against the spec, not the subagent report.