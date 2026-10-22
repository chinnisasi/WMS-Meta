---
title: '5-3a operational registers — stock on hand, inbound, outbound, ledger and batch ageing/near-expiry as client-filtered CSV/Excel downloads'
type: 'feature'
created: '2026-10-22'
baseline_commit: 'e1771c7fc88b060ac998c0bf2c113058b9859c1d'  # wms-be; wms-fe: 3a5a14ff1150780d13bb002d05800a63b7e3dd3b; wms-mobile: unchanged
status: 'done'
route: 'dispatch'
review_loop_iteration: 0
context:
  - 'docs/initiatives/production-readiness.md'
  - 'docs/design/SYSTEM-DESIGN.md'
  - 'docs/design/IMPLEMENTATION-GUIDE.md'
  - 'docs/design/API-SURFACE.md'
  - 'docs/design/PENDING.md'
  - 'docs/design/modules/reporting.md'
  - 'docs/design/modules/inventory.md'
  - 'docs/design/modules/inbound.md'
  - 'docs/design/modules/outbound.md'
  - 'docs/design/modules/clients.md'
  - 'docs/design/frontend/SYSTEM-DESIGN.md'
  - 'docs/design/frontend/IMPLEMENTATION-GUIDE.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** Operations, accounts and clients ask for registers: what is in stock, what came in, what went out, every movement, and what is ageing or near expiry. Today they can only page through screens. No server route exports operational data.

**Approach:**
- One read-only download route, `GET /tenants/:t/warehouses/:w/reports/:report?format=csv|xlsx&clientId&from&to`.
- `:report` is one of `stock-on-hand`, `inbound-register`, `outbound-register`, `ledger` or `batch-ageing`.
- It answers a file through the IMPLEMENTATION-GUIDE §6 binary pattern. Each report's rows come from a new read on its owning module's facade.
- The web Reports page gains an **Operational reports** section.

**Decisions (recommended, taken autonomously under the user's standing instruction, 2026-10-22; revised by the design review):**
1. **Split.** Space utilisation, operator productivity and count accuracy are 5-3b (deferred-work).
2. **Bounded and synchronous.**
   - At most **50,000 rows**; the 50,001st row means 422 `report-too-large` (narrow the filters).
   - A **whole-read deadline** of 15 s, re-armed before every statement (`armServiceDeadline`, `reporting/service.ts:31,123-129`), maps to 503 `report-unavailable` (`isStatementTimeout`).
   - A **process-wide slot limit of 2** concurrent register reads (the `TileSlots` model, `reporting.facade.ts:70-118`). When full, 503 before reading.
   - Larger or async exports, and per-tenant quotas, are PENDING.
3. **Formats.**
   - **Typed cells** (`string | number | Date | null`). Numbers are written raw (a negative quantity stays a number); only strings pass the formula guard.
   - **CSV:** UTF-8 BOM + `csvCell` for strings (moved to `src/shared/export/csv.ts`, re-exported for the audit export).
   - **XLSX:** the `exceljs` **streaming** `WorkbookWriter` (`useSharedStrings: false`) into a buffer, so every refusal still precedes the headers. Strings are plain strings and dates are cells with a `numFmt`.
   - **IST everywhere** through a new `istWallClock()` in `shared/primitives/time.ts` (`YYYY-MM-DD HH:mm:ss`). Calendar dates (expiry, mfg) go through `istDateOf`. XLSX date cells are shifted by `IST_OFFSET_MS`, since exceljs writes UTC fields as wall clock. Columns carry an `_ist` suffix.
4. **Periods.**
   - `from`/`to` are inclusive IST dates (`assertServicePeriod`, at most 366 days). The window is the half-open `[istMidnightOf(from), min(istMidnightOf(to+1), now))` (`serviceWindow`), computed in reporting and passed to the facades as instants.
   - The window is **required** for the inbound, outbound and ledger registers, filtering each source's indexed `created_at`.
   - `stock-on-hand` and `batch-ageing` are as of now and take none. Month-end stock as of a date (ledger replay) is PENDING.
5. **Read shapes.**
   - `stock-on-hand` and `batch-ageing` are **one statement each** (`limit 50001`), so the snapshot is consistent.
   - The dated registers run in one `REPEATABLE READ, READ ONLY` transaction walking their existing keyset.
6. **Client attribution and filter.**
   - **Filter rule:** `clientId` uses the 1-5a predicates (`client-filter.ts`): unknown gives an empty file; malformed is 400.
   - **Stock and ageing:** the SKU's client.
   - **Inbound:** the line SKU's client (`skuOfClient`; a GRN with a null client is still attributed).
   - **Ledger:** `ledger_events.client_id`.
   - **Outbound:** `orders.client_id`.
7. **Privacy.** No member emails. Actors appear as **display names** through a new `TenancyFacade.memberDisplayNamesInTx` (the names staff screens already show). Access is any staff role, the same as the source lists, and portal sessions get 403. There is no new capability and no audit row: download auditing is roadmap 6.4, a stated product decision.
8. **Columns** (one row per; quantities are base units in the SKU's precision):
   - **stock-on-hand** (bin × batch; non-zero):
     - warehouse, zone, bin, `system_bin` (`bins.system_owned`), SKU code and name, HSN, client code, UoM, batch code, `expiry_date`, quantity.
     - The batch arm is `batch_on_hand`. The untracked arm is `stock_on_hand` joined to `skus` where `batch_tracked = false`, which never double-counts.
     - IN-TRANSIT and the other system bins are included and flagged. Serial-tracked SKUs give one row per bin; catch-weight gives units only; kits never appear.
   - **inbound-register** (GRN line):
     - GRN code, `recorded_ist`, document (PO code / ASN code / `blind:<reason>`), vendor name (PO `vendor_snapshot`), client code;
     - gate-in code, the supplier invoice/challan numbers and dates and the e-way bill numbers from the gate-in's documents (`; `-joined);
     - SKU code and name, batch code, qty, applied qty, recorded by (name).
   - **outbound-register** (order line):
     - order id, `created_ist`, status, source, `channel_order_ref` (`external_event_id`, ingested orders only), client code;
     - consignee legal name and GSTIN, destination city, state and pincode;
     - SKU code and name, quantity;
     - `first_dispatched_ist`, carrier and AWB from that first `dispatch.dispatched` event's reference (falling back to the latest shipment by `(labelled_at, id)`).
   - **ledger** (event):
     - `recorded_ist`, `occurred_ist`, type, SKU code, from-bin and to-bin codes, batch code, signed quantity;
     - a reference summary from an **exhaustive switch over the `reference_doc` union** (`never` check; unknown or legacy kinds give `<kind>`), with GRN codes looked up;
     - actor (name).
   - **batch-ageing** (bin × batch with stock):
     - SKU code and name, client code, batch code, mfg date, expiry date, `days_to_expiry` (IST dates);
     - `batch_created_ist` and `days_since_batch_created` (the batch's first appearance in the **tenant**, labelled as such), quantity;
     - sorted by expiry ascending, nulls last.
   - The untracked-age column is dropped: `stock_on_hand.created_at` is the bin's first-ever stock, not current stock (PENDING: age per receipt).
9. **Web.**
   - A new `OperationalReports` section at the **top** of `/reports` (no tabs; the existing anchors are untouched).
   - **Defaults:**
     - Client: a local pick, else the active switcher client, else **All**. Shows `AllClientsNote` when on All with a switcher client active.
     - Warehouse: the first or only one. A failed read shows `WarehousesFailure` and disables Download.
     - Dates: hidden with "As of now" for the two snapshot reports.
   - The filename is built on the web with `istDateOf(Date.now())` and slugged codes: `<report>-<WH>[-<client>]-<from>_<to>.<ext>` or `…-asof-<date>`.

## Boundaries & Constraints

**Always:**
- **§6:** every refusal is thrown before the first header: 400, 404 `unknown-warehouse`, 422 `report-too-large`, 503 `report-unavailable`.
- **Facades only** (AD-6). The reporting module owns the route, the registry, the writers, the slots and the deadline.
- **Batch reads** go through `CatalogFacade` where catalog owns them.
- **The dispatch lookup** states `reference_doc ? 'orderId'`, so `ledger_events_order_ref_idx` applies, proven by an `EXPLAIN` in the test.

**Never:**
- No migration or index (PENDING).
- No async job; no portal download (5.4).
- No new capability; no audit row; no emails.
- No 5-3b reports; no value or MRP columns (no prices exist; PENDING).

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|---|---|---|---|
| Stock CSV | 3 bins, a batch SKU, an untracked SKU | BOM; header golden; one row per bin × batch and per untracked bin; the batch SKU total equals `batch_on_hand` (no double count) | — |
| Negative quantity | a pick in the ledger | the quantity cell is the number −5 in both formats, never `'-5` | — |
| Client filter | `clientId=ACME`; a blind GRN with a null client but ACME SKUs | only ACME rows; the blind GRN line included | malformed id → 400 |
| XLSX | `inbound-register` | a valid workbook (parsed back), typed cells, IST date cells | — |
| IST boundary | an event at 23:59 IST and at 00:00 IST on the `to` day + 1 | the first inside, the second outside | — |
| Expiry date | expiry stored at IST midnight | printed as that IST date, not the day before | — |
| Too large, busy, slow | over 50,000 rows / 2 reads in flight / past 15 s | — | 422 / 503 / 503, no partial file |
| Outbound | a dispatched order; a second (manifested) shipment row | one row per line; dispatch time, carrier and AWB from the first dispatch | — |
| Portal | client session | — | 403 |

</frozen-after-approval>

## Code Map

### Backend (`workspace/core/backend/wms-be`)

**Reporting module**
- `src/modules/reporting/registers.ts` (new): the registry (name → columns, facade read, read shape, period rule), the slots, the deadline and the `serviceWindow` reuse.
- `src/shared/export/csv.ts` and `src/shared/export/xlsx.ts` (new): typed-cell writers. `tenancy/audit-export.csv.ts` re-exports, so the audit export is byte-identical (its suite stays green).
- `src/shared/primitives/time.ts`: `istWallClock()`.

**Facade reads (new, additive)**
- `InventoryFacade`: `stockOnHandRegisterInTx`, `ledgerRegisterInTx`, `batchAgeingRegisterInTx`, and `firstDispatchByOrderInTx(orderIds)` (with `reference_doc ? 'orderId'`).
- `CatalogFacade`: batch fields if needed.
- `InboundFacade.inboundRegisterInTx` (GRN lines + header + PO `vendor_snapshot` + ASN + gate-in documents).
- `OutboundFacade.outboundRegisterInTx` (order lines + consignee + a lateral latest shipment).
- `TenancyFacade.memberDisplayNamesInTx`.

**Route:** `src/api/reporting.controller.ts` `GET :t/warehouses/:w/reports/:report` (the §6 pattern at `:346-359`; `@ApiProduces('text/csv', 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet')`; the arms; the slot seam for tests).

**Tests:** `test/registers.spec.ts` covers:
- every matrix row and each report's header golden;
- isolation per report;
- XLSX parsed back;
- the stock no-double-count check;
- the IST boundaries;
- the EXPLAIN of the dispatch lookup;
- the slot and deadline seams;
- the audit export unchanged.

A Bun smoke run of the XLSX writer, plus a 50k-row heap measurement, is recorded in Implementation Notes.

### Web (`workspace/core/frontend/wms-fe`)

**`src/components/reports/operational-reports.tsx` (new)**
- Report select, warehouse, client and period controls with the decision-9 defaults; `ServicePeriodInputs` gains an optional `labelPrefix` (default unchanged) so names are "Register from" and "Register to".
- Format and Download (a `parseAs: 'blob'` + `as unknown as Blob` wrapper; `aria-busy`; a ref guard); errors in `role="alert"`.
- `parseServicePeriod` (`lib/service-report.ts:42`).

**`src/app/(app)/reports/page.tsx`:** render it first; update the header copy and the comment (`:7-20`).

**`src/lib/reports.ts`:** labels, the filename builder (an IST boundary test at 18:30Z), and the error map (`report-too-large`, `report-unavailable`, `validation-failed`, `unknown-warehouse`, `role-denied`), with tests.

**Other:** `fetchApiReportFile`; regenerate the client.

### Mobile

None.

## Tasks & Acceptance

**Execution:**
- [x] BE: writers, the time helper, the facade reads, the registry, the slots and deadline, the route; OpenAPI; tests; Bun smoke and heap measurement.
- [x] Web: the section, `ServicePeriodInputs` `labelPrefix`, `lib/reports.ts`, the wrapper, the page copy, plus tests; regenerated client.
- [x] Meta docs:
  - `API-SURFACE.md`;
  - `reporting.md` (registers);
  - the facade reads in `inventory.md`, `inbound.md`, `outbound.md` and `tenancy.md`;
  - frontend SYSTEM-DESIGN `/reports` (`:55`);
  - `docs/repos/wms-be|wms-fe` READMEs;
  - PENDING: an async export above 50k plus quotas; a download audit (6.4); the register indexes; age per receipt; month-end stock as of a date; value and MRP; 5-3b.

**Acceptance Criteria:**
- Given ACME and BETA stock, when an ops manager downloads `stock-on-hand` as Excel for ACME, then the workbook opens in Excel and lists only ACME's bin × batch rows, with HSN and IST expiry dates, totals matching on-hand.
- Given a 30-day ledger window, when downloaded as CSV, then each event in range appears once with IST times, signed numeric quantities and actor names (no emails).

## Design Notes

- **Why synchronous with slots.** The registers are bounded by warehouse, client and period. A 50k cap, a whole-read deadline and two process slots keep one request simple and the pool safe; the async machinery can take over when volumes demand it.
- **Ageing basis.** Without a per-receipt date (a migration), age is the batch's first appearance in the tenant, and the column name says so.

## Verification

**Commands:**
- `bun run test -- test/registers.spec.ts test/audit-export.spec.ts` (wms-be, run alone): pass.
- `bun run lint && bun run typecheck` (wms-be, wms-fe); `bun test` (wms-fe): pass.

## Implementation Notes

Implemented 2026-10-22 (wms-be and wms-fe on `feat/5-3a-operational-registers`, uncommitted; mobile untouched).

**Backend.**
- `src/modules/reporting/registers.ts` — the registry (`REGISTERS`: columns, period rule `dated | as-of-now`, read), `referenceSummary` (the exhaustive `LedgerReferenceDoc` switch with a `never` default), `assertWithinCap`, `RegisterSlots` (non-waiting `tryAcquire`). `ReportingFacade.register` — period rule → slot → one `REPEATABLE READ, READ ONLY` transaction (`withTenantTransaction` gained `accessMode: 'read only'`) with `setTxDeadline` → warehouse (`unknown-warehouse`) → the register read → the cap → the file. Seams as plain fields: `registerSlots`, `registerDeadlineMs`, `registerMaxRows`, `registerRead`. `ReportingModule` imports Inventory/Inbound/Outbound/Catalog modules (DI verified by `openapi:export` and the e2e suites).
- Facade reads (additive): `inventory/registers.ts` (`stockOnHandRegisterInTx`, `batchAgeingRegisterInTx`, `ledgerRegisterInTx`, `firstDispatchByOrderInTx` + the exported `firstDispatchQuery` the EXPLAIN test plans), `inbound/inbound-register.ts` (`inboundRegisterInTx`, `grnCodesByIdsInTx`), `outbound/outbound-register.ts` (`outboundRegisterInTx`), `CatalogFacade.batchFactsByIdsInTx`, `tenancy.service.ts` `memberDisplayNamesInTx`.
- `src/shared/db/tx-deadline.ts` — `setTxDeadline` / `rearmTxDeadline`: the whole-read deadline crosses module boundaries without a callback; every facade register read re-arms before every statement (a no-op for a caller without a deadline).
- `src/shared/export/{cells,csv,xlsx}.ts`; `csvCell` / `UTF8_BOM` moved there, `tenancy/audit-export.csv.ts` re-exports them (its suite: 32/32). `istWallClock` in `shared/primitives/time.ts`.
- Route `GET :t/warehouses/:w/reports/:report` (§6 pattern; `@ApiProduces('text/csv', <xlsx>)`; 200/400/401/403/404/422/503). `openapi/openapi.json` re-exported.
- `scripts/smoke-register-xlsx.ts` — the Bun smoke + measurement.

**Bun smoke and heap measurement** (`bun scripts/smoke-register-xlsx.ts --rows 50000`, Bun 1.4.0, macOS arm64, 2026-10-22): the smoke writes every cell kind with the streaming `WorkbookWriter`, parses it back with exceljs and checks the typed cells — passes under Bun. A 14-column ledger-shaped sheet: **50,000 rows → 4,417,200 bytes XLSX in 885 ms, RSS 96 → 257 MB, heapUsed 26 → 63 MB**; CSV 10,021,764 bytes in 57 ms (RSS +58 MB). The database side of a 50k register at production volume is unmeasured (PENDING: register indexes).

**Deviations and decisions taken while implementing (each recorded in PENDING or the design docs):**
1. **Display names (decision 7).** The spec's "the names staff screens already show" does not hold: `users` has no name column and every staff screen shows the email (`ledger.tsx` renders `users[id].email`). With no migration allowed, `memberDisplayNamesInTx` prints the email's **local part** (`System` for the system actor, `user-<last 8 hex>` for an unknown id). There is no `TenancyFacade` class either — tenancy's seam is free functions in `tenancy.service.ts` (the `getMemberRoleIn` / `userEmailsInTx` precedent), so the function lives there.
2. **Gate-in documents (decision 8).** Only the documents that NAME the receipt's PO or ASN are printed (`gate_in_documents.po_id` / `asn_id`): a truck carries several clients' goods, and an unlinked document beside a client-filtered line could leak another client's invoice. A blind receipt prints its gate-in code and no documents. All document kinds print as `<kind> <number>`.
3. **Columns added beyond the decision-8 list** (the header golden pins them): `uom` on every register (quantities are base units of it), `client_code` on the ledger, `bin` on batch ageing (a row is bin × batch), `kit_of` on the outbound register (a kit's exploded component names its kit line so the two are never summed). The outbound quantity column is `ordered_qty`; `system_bin` is `yes`/`no`; the document column is `po:<code>` / `asn:<code>` / `blind:<reason>`.
4. **A snapshot register given `from`/`to` is a 400** (not silently ignored), so nobody mistakes "as of now" for month-end stock. A missing period on a dated register is a 400 with its own detail before `assertServicePeriod`.
5. **404 code.** `assertWarehouseInTenant`'s `not-found` is re-coded `unknown-warehouse` for this route only (the spec's arm).
6. **Busy before 404.** The slot is taken before the transaction, so a full server answers 503 even for an unknown warehouse.
7. **The ledger window is `created_at`; the column prints `recorded_at`** (decision 4 said "indexed `created_at`"; recorded in PENDING).
8. **Web warehouse default** is the first warehouse (decision 9 as written), not the switcher's active warehouse.

**Verification.**
- wms-be: `bun run test -- test/registers.spec.ts` 20/20 (run alone); `test/audit-export.spec.ts` 32/32; `test/architecture.spec.ts` 124/124; **full suite 110 suites / 2,794 tests green**; `bun run lint`, `bun run typecheck`, `bun run build` clean; `bun run db:generate` → "No schema changes".
- Mutation checks (each made a registers test fail, then reverted): dropping `k.batch_tracked = false` (4 fail — the double count), dropping `reference_doc ? 'orderId'` (the EXPLAIN fails), routing numbers through `csvCell` (2 fail), dropping the XLSX IST shift (2 fail), disabling `rearmTxDeadline` (the slow test fails).
- wms-fe: `bun test` 2,298/2,298 (13 new in `lib/reports.test.ts` + `components/reports/operational-reports.test.tsx`, 1 new in `lib/api/client.test.ts`); `bun run lint`, `bun run typecheck`, `bun run build`, `bun run check:capability-mirror` clean; the client regenerated with `bun run api:generate`. Mutation checks: the ref guard, the snapshot "no dates", the local All, the `labelPrefix` — each failed its test.

## Spec Change Log

## Review Triage Log

Design review, 2026-10-22 (backend B, web W). Every accepted finding is folded into the spec above; all choices are recommended, taken autonomously.

| ID | Verdict | Finding → resolution |
|---|---|---|
| B1 | high | `csvCell` turns `-5` into `'-5`. Typed cells; numbers raw. |
| B2 | high | `statement_timeout` is per statement. Deadline re-armed per statement. |
| B3 | high | The union double-counts batch stock. The untracked arm is non-batch SKUs only; test. |
| B4 | high | Member emails exposed to all staff. Display names via a tenancy facade; no emails. |
| B5 | high | No IST wall-clock helper; expiry shows the day before; XLSX shows UTC. `istWallClock`, `istDateOf`, an XLSX offset; boundary fixtures. |
| B6 | medium | Period window unspecified. Half-open `serviceWindow`, inclusive `to`. |
| B7 | medium | The metering dispatch read doesn't fit. A new first-dispatch-by-order read with an index predicate; carrier and AWB from the event. |
| B8 + W7 | medium | Shipment join duplicates lines; "channel ref" had no source. Lateral latest shipment; `channel_order_ref` = `external_event_id`. |
| B9 | medium | Client attribution unstated. Per report, decision 6. |
| B10 + W8 | medium | `stocked_since` is wrong; batch age is tenant-wide. Column dropped; renamed `batch_created_ist`. |
| B11 | medium | Keyset walks are inconsistent snapshots. Single statements, and repeatable read for the dated registers. |
| B12 | medium | XLSX unproven under Bun; memory. Streaming writer; Bun smoke and heap check. |
| B13 | medium | Unbounded concurrent reads. 2 slots → 503; quotas PENDING. |
| B14 | low | Stock scope and reference vocabulary. System bins flagged; serial, catch-weight and kits stated; exhaustive switch. |
| W1 | high | Client pick rule has no All. Decision 9. |
| W2 | high | Warehouse default and failure undefined. Decision 9. |
| W3 | medium | Duplicate accessible names; a11y. `labelPrefix`, hidden dates, `role="alert"`, `aria-busy`, ref guard. |
| W4 | low | Period and blob claims verified. Cites `parseServicePeriod`; codes named. |
| W5 | medium | Filename clock and slugging. `istDateOf(Date.now())`, boundary test, slugged codes. |
| W6 | medium | Cheap high-value columns missing. Vendor, gate-in, invoice/e-way, consignee, HSN added; value and MRP PENDING. |
| W9 | low | Month-end stock. PENDING. |
| W10 | low | Access decision and stale docs. Decision 7; page copy; docs task. |

Code review, 2026-10-22 (Blind Hunter BH, Edge Case Hunter EC, Verification Gap VG). Routes taken autonomously (recommended). Pre-review fix: `test/registers.spec.ts`'s binary parser failed `tsc` (the implementer had reported typecheck clean); the parser was retyped through `request.Response`.

| ID | Verdict | Finding → resolution |
|---|---|---|
| BH1 | high | Patch: the inbound and outbound line queries are unbounded per header page (hundreds of thousands of lines before the cap). Bounded to `remaining + 1`. |
| BH2 + EC3 + EC11 + VG-o1 | medium | Patch: client-code and member-name lookups run without `rearmTxDeadline`. Re-armed before each. |
| BH15 + VG1 | high | Patch: no test reaches a second keyset page. Page size is a parameter; a page-size-1 test over same-instant rows per walk. |
| VG2 | medium | Patch: `referenceSummary` and the GRN-code lookup are untested beyond two kinds. A unit test over every kind, plus an e2e GRN row. |
| VG3 | medium | Patch: `kit_of` has no fixture. A kit order fixture. |
| VG4 | low | Patch: the latest-shipment order is unobserved. A second, older shipment fixture. |
| VG5 | medium | Patch: the XLSX formula-text guard is pinned only in a manual script. A jest test of typed XLSX cells (formula text, negative, IST instant, date). |
| VG-o2 | low | Patch: system-bin, no-expiry and ASN arms lack fixtures. Fixtures added; plus a cross-tenant 403. |
| BH5 | medium | Patch: a failed clients read leaves Download enabled with All. Disabled until the clients read settles OK. |
| BH6 + EC6 | medium | Patch: supplier document, date and e-way lists misalign when some are empty. Slots kept (`-`). |
| BH8 + EC7 | low | Patch: carrier and AWB fall back field by field, and empty strings are not treated as absent. They fall back as a pair; `''` is absent. |
| BH9 + EC4 + EC5 | low | Patch: email local parts collide or are empty. A collision gets a `user-<tail>` suffix; empty becomes `user-<tail>`. (Registers are staff-only, so a local part is shown only to staff, who already see emails.) |
| EC1 + EC2 + BH4 | low | Patch: an uppercase or unknown `clientId` drops the client from the server filename. Lower-cased; unknown gives `-client-unknown`. |
| BH10 | low | Patch: the dated registers filter on an unprinted column. A `created_ist` column is added to all three. |
| BH11 | low | Patch: the `to` description is off by one. "At most 366 days in all (inclusive)". |
| BH12 | low | Patch: too-large advice names a period for snapshot reports. Advice per report; the web reads the cap from the problem. |
| BH13 + VG-o3 | low | Patch: orphaned doc comments. Restored. |
| BH14 | low | Patch: the controller ignores `file.contentType`. Uses it. |
| BH3 | low | Patch: 503s carry no `Retry-After`. `Retry-After: 5`. |
| EC8 | low | Patch: XLSX text over 32,767 characters corrupts the workbook. Truncated with `…`. |
| EC12 | low | Patch: four registers use inline client predicates. The shared `client-filter.ts` predicates where they match. |
| BH16 | low, rejected | No capability gate on bulk exports. Decision 7 (member-open, like the source lists; portal 403). The risk is recorded in API-SURFACE and PENDING with 6.4. |
| BH7 | low, deferred | ASN receipts print no vendor. ASNs carry no vendor field today; PENDING. |
| EC9 | low, rejected | Batch-tracked stock without batch rows would be missing. Unreachable: tracking flags are locked while stock exists (`sku-has-stock`), and the ledger writes both projections in one fold; reconcile flags any drift. |
| EC10 | low, accepted | `memberDisplayNamesInTx` is a tenancy service function, not a `TenancyFacade` method (no such class exists). It follows the module's exported-function convention; the spec wording is noted in Implementation Notes. |
