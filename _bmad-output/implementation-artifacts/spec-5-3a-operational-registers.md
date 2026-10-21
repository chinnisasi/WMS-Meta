---
title: '5-3a operational registers — stock on hand, inbound, outbound, ledger and batch ageing/near-expiry as client-filtered CSV/Excel downloads'
type: 'feature'
created: '2026-10-22'
status: 'ready-for-dev'
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
- [ ] BE: writers, the time helper, the facade reads, the registry, the slots and deadline, the route; OpenAPI; tests; Bun smoke and heap measurement.
- [ ] Web: the section, `ServicePeriodInputs` `labelPrefix`, `lib/reports.ts`, the wrapper, the page copy, plus tests; regenerated client.
- [ ] Meta docs:
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
