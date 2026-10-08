---
title: 'Dispute drill-down — expand a client invoice line to the records that produced its quantity'
type: 'feature'
created: '2026-10-07'
status: 'done'
route: 'dispatch'
baseline_commit: '6ae21b8fa5c03d3e9e75bc8acc3bcd1092acea46'
review_loop_iteration: 0
context:
  - '_bmad-output/implementation-artifacts/epic-21-context.md'
  - '_bmad-output/specs/spec-3pl/SPEC.md'
  - '_bmad-output/specs/spec-3pl/schema.md'
  - '_bmad-output/specs/spec-3pl/billing-model.md'
  - '_bmad-output/specs/spec-3pl/architecture.md'
  - '_bmad-output/implementation-artifacts/spec-21-4-metering-and-storage-snapshots.md'
  - '_bmad-output/implementation-artifacts/spec-21-5-client-invoices.md'
  - 'docs/design/SYSTEM-DESIGN.md'
  - 'docs/design/IMPLEMENTATION-GUIDE.md'
  - 'docs/design/API-SURFACE.md'
  - 'docs/design/modules/billing.md'
  - 'docs/design/modules/inventory.md'
  - 'docs/design/modules/inbound.md'
  - 'docs/design/modules/outbound.md'
  - 'docs/design/frontend/SYSTEM-DESIGN.md'
  - 'docs/design/frontend/IMPLEMENTATION-GUIDE.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** A client invoice line (21-5) states a quantity, such as 412 picks or 1,234.567 unit-days, but nothing shows where that number came from. CAP-7 requires that "both sides can see which events produced each line". The billing model calls defending the bill *the* requirement.

**Approach:** An operator can expand any invoice line, on an invoice of any status, to the records its count was built from:
- **inbound handling:** each GRN line;
- **pick:** each pick;
- **outbound handling:** each order, at its first dispatch;
- **storage:** each day per warehouse, with an on-demand per-SKU breakdown of one day.

Each record shows the actor, the time (IST), the warehouse, the SKU, and the order or PO reference. The drill states whether its records add up to the line's quantity. A line's records can be exported as CSV to send to the client.

**Decisions (human, 2026-10-07):**
1. **CSV export.** Each line's record panel has an "Export CSV" action. It fetches every page and downloads the records, capped at 50,000 rows with a notice when the cap is reached. Leading `#` comment lines name the invoice number, client, period, line, records total, line quantity and whether they reconcile.
2. **Staff are pseudonymised in the CSV.** Each actor appears as a stable code, `user-` followed by the first 8 hex digits of `sha256(tenantId:userId)`, and device ids are dropped. The on-screen drill shows emails to the tenant's staff.

## Boundaries & Constraints

**Always:**
- **Line selection.** Each drill reuses 21-4's predicate for its charge, plus 21-5's warehouse filter (the invoice's supplying-GSTIN group via `supplierGroups`/`groupOf`), over the line's `[segment_from, segment_to)`:
  - `receiptLinesPredicate`;
  - `picksPredicate`;
  - `dispatchedOrderEventsPredicate`, one row per order with `DISTINCT ON (orderId)` ordered by `(recorded_at, id)`. By that predicate's global NOT EXISTS, this is the order's first dispatch anywhere, so an order is billed and drilled exactly once;
  - storage from `storage_snapshots`, using the line's `uom`, the group's warehouses, and only the segment's days up to the line's measured day. That is the invoice's `storageCompleteThrough` at its last compute, stored on the invoice.
  - If the group is empty (its GSTIN no longer maps to any warehouse), the drill answers 409 `invoice-group-changed`. It never silently shows zero.
- **Reconciliation.** The first page (no cursor) carries `summary {lineQuantity, recordsQuantity, reconciles}`, computed over the whole predicate in that transaction. Later pages omit it. Quantities travel as decimal strings in the same units as the line view (storage unit-days, three decimals; counts as integers) and are compared exactly.
  - **Issued, disputed, settled or void, and the figures differ:** the web shows "These records no longer add up to the invoiced quantity". The causes are the 21-2b SKU-correction race or a snapshot rebuild.
  - **Draft, and the figures differ:** it shows "Draft may be out of date — Refresh".
  - A 404 on a draft's line, while paging or exporting, means the draft was refreshed: "Invoice changed — reload". It never produces a partial file.
- **Records.** Every record carries `kind`. Quantities are decimal strings in base units. Instants are UTC ISO on the wire, and the web renders them in IST with `+05:30`.
  - **receipt-line:**
    - `grnCode`, `poCode` (null on a blind receipt), `recordedAt`;
    - `warehouseCode`, `skuCode`, `skuName`, `qty`, `appliedQty`;
    - `actorEmail`, `actorId`.
  - **pick:** `pickedAt` (its `created_at`), `warehouseCode`, `orderRef`, `skuCode`, `skuName`, `qty`, `binCode`, `actorEmail`, `actorId`.
  - **order:** `dispatchedAt`, `warehouseCode`, `orderRef`, `lines` (the order's dispatch events in this window and group), `carrierName`, `trackingNumber`, `actorEmail`, `actorId`.
  - **storage-day:** `date`, `warehouseId`, `warehouseCode`, `uom`, `onHand`.
  - `orderRef` is `{source, externalEventId | null, orderId}`. The web labels it "Channel ref", falling back to the order id.
- **Storage breakdown** (`?date&warehouseId`) is allowed only on a storage line, for a date inside its measured segment and a warehouse in its group. Otherwise it answers 404. A malformed value answers 400 `validation-failed`.
  - The breakdown folds per SKU, from genesis to `istMidnightOf(date + 1)`, with `ON_HAND_FOLD_TERM`. It filters on `le.client_id` and `s.uom` = the line's uom, and keeps negative SKUs.
  - It returns rows with on-hand ≠ 0, plus `{snapshotOnHand | null, reconciles}`. A day whose total was ≤ 0 has no snapshot and no row to drill.
- **Actor emails** come from a new batch tenancy read. An unknown user answers `null`.
- **Paging.**
  - Keyset only.
  - Limit 1–1,000, default 100. A bad limit answers 400 `validation-failed`; a bad cursor answers 400 `invalid-cursor`.
  - Ordering and cursor `createdAt`, per kind:
    - receipt lines: `(grn.recorded_at, grl.id)`;
    - picks: `(created_at, id)`;
    - orders: `(first recorded_at, first event id)`;
    - storage: `(istMidnightOf(date), warehouse_id)`.
  - Every instant comes from `::text` through `fullPrecisionInstant`.
- **CSV:**
  - **File:** named `<invoiceNo | "draft-" + id8>-<chargeCode>-<segmentFrom>.csv`; UTF-8 with a BOM.
  - **Rows:**
    - text cells go through `csvField`, whose guard is extended to a leading tab and CR;
    - number cells are written plain and never guarded;
    - instants are IST with `+05:30`, plus an IST date column.
  - **Export:** limit 1,000; it shows progress and can be cancelled.
  - **Footer:** reconciles from the first page's summary, re-checked by a second summary request at the end. If they differ, the footer says so.
- **Access.** Facades only (AD-6): inbound, outbound and inventory own their row reads beside their count reads, and billing owns the snapshot reads and composes. Reads are member-open, and portal sessions are refused (`portalRefused`). The line view gains an additive `id`.
- **The web.** The drill is a separate `print:hidden` "Line records" panel under the printable invoice, never inside `data-print-root`.
  - Each line has a native button with `aria-expanded`/`aria-controls`.
  - The panel heading names the line, and paging is a "Load more" button.
  - Storage day rows expand the breakdown through a button.

**Never:**
- changing any count's definition;
- drilling the usage preview;
- portal access;
- annotations;
- a server export job;
- per-SKU storage across a segment.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected | Error |
|---|---|---|---|
| Pick line | Issued September invoice; pick quantity 412 | 412 pick rows; first page `reconciles: true` | — |
| Split dispatch | Lines dispatched 09-30 and 10-01 | Listed once, on September only, with the first event's carrier | — |
| Two registrations | Group 29 | Only group-29 warehouses | — |
| Card change | Two segments | Each line drills its own segment | — |
| Storage line | `kg`, 30 measured days | Day × warehouse rows; Σ = the line | — |
| Day breakdown | 09-14, WH1 | Per-SKU on-hand; Σ = snapshot | — |
| Drift, issued | A snapshot is rebuilt with a different figure | `reconciles: false`, both figures | — |
| Draft mismatch | Draft prepared before storage finished | "Draft may be out of date — Refresh" | — |
| Void invoice | — | Drillable like any status | — |
| Unknown actor | — | Email `null`; the CSV still has the pseudonym | — |
| CSV | 412 rows | `#` header, 412 rows (pseudonyms, no device), reconcile footer | — |
| CSV over the cap | More than 50,000 rows | First 50,000 rows and a notice | — |
| Group changed | GSTIN no longer maps | — | 409 `invoice-group-changed` |
| Breakdown misuse | Non-storage line; date outside the segment; warehouse outside the group | — | 404 |
| Bad line or invoice; another tenant | — | — | 404 |
| Bad cursor; limit outside 1–1,000 | — | — | 400 |
| Portal session | — | — | 403 |

</frozen-after-approval>

## Code Map

- **Predicates:**
  - `inbound.facade.ts:352-358` (`grl`/`grn`/`s`), with the count at `:331-338`;
  - `outbound.facade.ts:1206-1212` (`p`/`s`), with the count at `:1187-1193`;
  - `client-metering.ts:175-198` (`le`, plus the global first-dispatch `NOT EXISTS` over `earlier`; it matches one row per order **line**), with the count at `:201-212`;
  - `shared/db/warehouse-filter.ts:15-25`.
- **Columns** (`schema.ts`):
  - GRN `:1667-1694` (`code`, `po_id`, `recorded_by`, `device_id`) and its line at `:1717-1734`;
  - `purchase_orders.code` `:1505+`;
  - picks `:2331-2378`;
  - `ledger_events` `:947-980`, where a dispatch's `reference_doc` holds `{orderId, orderLineId, dispatchedQty, carrierName?, trackingNumber?}` (`dispatch.command.ts:357-369`);
  - orders `:1933-1990` (`source`, `external_event_id`; there is no order number);
  - users `:90-109` (email only).

  `storage_snapshots.on_hand_milli` is `mode: 'number'` (`:4298`), so read it as `::text`.
- **Fold:** `client-metering.ts:57-61` and `:75-98`; the snapshot skips totals ≤ 0 (`storage-snapshot.ts:243`).
- **Invoices:** `client-invoices.ts`:
  - views `:603-622` and `:694-730`, where the line view needs its `id`;
  - `supplierGroups`/`groupOf` `:200-219`;
  - portal refusal `:1121`;
  - line rewrite on refresh/issue `:1056` and `:1264-1276`.

  **0062 stores no measured-through date** (verified). Migration **0063** adds `client_invoices.storage_measured_through date` (nullable). Every compute writes the group's watermark clipped to `period_end`. A row with null (issued before 0063) is read as `period_end`, because issue already required storage complete through `period_end`.
- **Paging:** `shared/primitives/pagination.ts`; `decodeCursorSafe` (`client-invoices.ts:1474`); `fullPrecisionInstant` (`time.ts:84-94`).
- **Tenancy:** add `userEmailsInTx`, following the precedent at `tenancy.service.ts:263`.
- **Web:**
  - `components/compliance/client-invoices.tsx`: `PrintableClientInvoice` `:552-662`, rows keyed at `:635`;
  - `lib/csv.ts`;
  - `lib/client-invoices.ts`;
  - the BOM precedent at `import-catalog.tsx:313`.

## Tasks & Acceptance

**Execution:**
- [x] `wms-be` facades -- add a paged row read beside each count, on the same predicate:
  - `receiptLineRecordsInTx`, `pickRecordsInTx`, `dispatchedOrderRecordsInTx`, `clientOnHandBySkuAtInTx` (all in the owning modules);
  - `storageSnapshotRecordsInTx` (in billing);
  - `userEmailsInTx` (in tenancy).
- [x] `wms-be/drizzle/0063_invoice_storage_measured_through.sql` (+ journal, snapshot, schema.ts) -- add the nullable column, guarded. Writing it on a draft is allowed by the 0062 guard (drafts are mutable); confirm the guard permits it, and include it in the content hash only if it changes the figures (it does not).
- [x] `wms-be/src/modules/billing/invoice-records.ts` -- composes the reads: line lookup, group resolution, summary, records and breakdown.
- [x] `wms-be/src/api/client-invoices.controller.ts` with its DTOs:
  - `GET client-invoices/{id}/lines/{lineId}/records?cursor&limit` returning `{summary?, records[], nextCursor}`;
  - `GET …/lines/{lineId}/storage-breakdown?date&warehouseId`;
  - the line view's `id`.

  Re-export `openapi.json`.
- [x] `wms-be/test/invoice-records.spec.ts` -- cover:
  - every matrix row;
  - each charge's records summing to its line, on issued and draft invoices;
  - keyset pages with no duplicates or gaps, including picks sharing one `created_at`;
  - the breakdown Σ equalling the snapshot, including a negative SKU.
- [x] `wms-fe` -- the Line records panel, the summary banners, the breakdown, and the CSV export per the decisions, with `csvField` hardened. Add mappers, hooks and tests.
- [x] Meta docs:
  - `billing.md`;
  - `inbound.md`, `outbound.md`, `inventory.md`;
  - `API-SURFACE.md` and both contracts;
  - `frontend/SYSTEM-DESIGN.md` (client invoices and the drill);
  - `billing-model.md:83-85` (the pick drill reads `picks` rows, not `pick.picked` events);
  - `PENDING.md`:
    - close `:111`;
    - add: GRN lines and picks have no DB append-only guard; receipt and pick drills read the SKU's *current* client (the 21-2b race); orders have no client-facing number; no index serves the receipt drill's sort on `grn.recorded_at`; portal drill (21-7).

**Acceptance Criteria:**
- Given ACME's issued September invoice, when each line is drilled, then every line's records reconcile to its quantity, and each record names its actor, IST time, warehouse and SKU, plus the order or PO where one exists.
- Given the full BE and FE suites, when run, then they pass.

## Implementation Notes

- **Baselines:** wms-be `6ae21b8fa5c03d3e9e75bc8acc3bcd1092acea46` (`baseline_commit`); wms-fe `fc6a0ee2223bad363c5efde0fcba446606dfa05a`.
- **Branches:** `feat/21-5b-dispute-drill-down` in both repos.
- **Leave everything uncommitted:** no commit, push or PR.
- **Tests (wms-be):** use `bun run test -- <file>`. Never run two jest invocations at once.
- **Meta docs:** edit in `/Users/sasidhar/Documents/WMS-Meta`.
- **`/tmp`:** don't touch anything there outside your own scratch files.

## Spec Change Log

- **2026-10-07, implementation — interpretations taken where the spec was silent (no intent changed; each is in `modules/billing.md` §Dispute drill-down).**
  - **The records response also carries `kind` and `invoiceStatus`** (additive): the web picks its table and its mismatch banner from the response, not from a second read. `records` is an OpenAPI `oneOf` discriminated on `kind`.
  - **An order record's `id` is its first dispatch event's id** (the keyset tiebreaker); `orderRef.source` is null only if the order row is missing (the order drill names its orders through `OutboundFacade.orderRefsInTx`).
  - **The breakdown's `reconciles` with no snapshot** is `total ≤ 0` (a day closing at ≤ 0 writes none — the projection's rule); with one, `total = snapshot`.
  - **`storage_measured_through` writes:** prepare's insert, refresh's rewrite, a stale issue's rewrite and the issue update. A refresh whose hash did not move re-stamps only that column when the group watermark moved (a watermark crossing zero-stock days changes no figure) — never `updated_at` or the lines, so 21-5's "a refresh with nothing changed rewrites nothing" still holds. Prepare does not touch a live draft it lists as `existing` (its stored figures and its stored day stay a pair).
  - **A malformed `invoiceId`/`lineId` is 400** (the route-param shape check every client-invoice route has); an unknown one is 404, as the matrix says.
  - **The CSV file name replaces `/` in the invoice number with `-`** (`29-S2627-000001-pick-2026-09-15.csv`) — a `/` cannot be in a file name. The header gains one more `#` line ("Times are IST (+05:30). Staff appear as stable pseudonyms."). The records carry no device id to drop.
  - **The storage record's cursor** carries `istMidnightOf(date)` and the warehouse id (the spec's ordering); a cursor is decoded by the same `decodeCursorSafe` as the invoice list.
- **2026-10-07, implementation review — fixes:** a compute with no group watermark stores `period_start − 1` (nothing measured), so NULL means only "stored before 0063" and reads as `period_end` on a non-draft invoice, nothing measured on a draft; the CSV writes each `#` comment line as one guarded cell and adds the status, supplying GSTIN, segment dates and generation time; an export aborts when its panel unmounts; the breakdown shows the session-expired, "Invoice changed — reload" and Retry states and a mismatch banner, and its toggle names its day and warehouse; a first-page read supersedes an in-flight "Load more". Tests added for keyset ties across page boundaries in every kind, the measured-through day after issue and a stale issue, the guard refusing it on an issued row, and the Load-more / export failure states.

## Review Triage Log

*Design review, 2026-10-07: two code-verified reviewers (correctness and performance; API, FE and fit). 24 findings merged into 16. One went to the human (decision 2), one was rejected, and the rest are folded in.*

| # | Sev | Finding | Disposition |
|---|---|---|---|
| 1 | high | Draft lines are rewritten on refresh or issue (ids change), and a draft's storage stops at its compute-time watermark, so draft drills would falsely mismatch | Measured-through stored per invoice; draft mismatch reads "may be out of date — Refresh"; a 404 on a draft line means "reload" |
| 2 | high | Staff emails and device ids would go to the client in the CSV | Decision 2: pseudonym codes, no device |
| 3 | high | `external_event_id` is a dedup key, null on manual orders | `orderRef {source, externalEventId, orderId}` labelled "Channel ref"; PENDING: no order number |
| 4 | high | The drill table would sit inside the printable invoice | A separate `print:hidden` panel with accessible controls |
| 5 | high | No timezone rule for record instants (a 20:00Z pick is the next IST day) | IST `+05:30` in the UI and the CSV, plus an IST date column |
| 6 | med | Number units are implicit; `on_hand_milli` is read as number | Decimal strings in the line view's units; `::text` reads |
| 7 | med | The breakdown's error arms and bounds are unspecified | Storage line, date in the measured segment, warehouse in the group, else 404; 400 when malformed |
| 8 | med | The breakdown must fold on `le.client_id` and keep negatives; ≤ 0 days have no snapshot | Stated |
| 9 | med | Order representative event ties; "line count" undefined | `DISTINCT ON` ordered by `(recorded_at, id)`; lines = dispatch events in the window and group |
| 10 | med | The cursor format doesn't fit storage or orders; ms truncation | Per-kind cursor `createdAt`; `fullPrecisionInstant` |
| 11 | med | Summary recomputed on every page; export of 250 requests in separate transactions | Summary on the first page only; export limit 1,000; footer re-checked at the end |
| 12 | med | Receipt lines lack the client's own reference | `poCode` |
| 13 | low | CSV layout, filename, BOM, guard gaps (tab/CR), quoted numbers | Specified |
| 14 | low | Groups can change silently; a void invoice's drill is undefined | 409 `invoice-group-changed`; every status drillable |
| 15 | low | Docs: billing-model says `pick.picked` events; the frontend docs lack client invoices; the receipt sort is unindexed | Fixed sentence; frontend docs; PENDING |
| 16 | false | An order dispatched from two GSTIN groups is billed on both | `NOT EXISTS earlier` (`client-metering.ts:192-197`) spans all warehouses, so only the group holding the order's first event counts it — rejected |

*Code review, 2026-10-07: three layers (blind, edge-case, verification-gap). 27 findings, each verified against the code. 16 merged into 9 patches, 1 deferred, the rest rejected.*

| # | Verdict | Finding | Evidence | Route |
|---|---|---|---|---|
| C1 | medium | CSV `#` comment lines are written raw. A client name, invoice text or line description containing `, =…` splits into a cell that begins with a formula, which bypasses `csvField` | `lib/invoice-records.ts` header lines | patch: each comment line is written as ONE `csvField` cell |
| C2 | medium | `storage_measured_through` NULL is ambiguous. A post-0063 draft whose group had no watermark writes NULL, and so does a pre-0063 draft. Both are read as `period_end`, so the drill lists days the line never counted. The migration and schema comments claim NULL means "issued before 0063" | `measuredThroughOf`; `storageDays`; 0063 header | patch: a compute with no watermark stores `period_start − 1` (nothing measured); NULL reads as `period_end` only on a non-draft; fix the comments |
| C3 | medium | Keyset ties are never crossed at a page boundary for receipt lines (one GRN, several lines), orders (same-instant first dispatch) or storage (two warehouses on one day) | `invoice-records.spec.ts` | patch: fixtures plus walks at limits 1–3 asserting no duplicates or gaps |
| C4 | low | An export keeps paging and downloads after the line panel unmounts | `line-records.tsx`, no abort on unmount | patch: abort on unmount |
| C5 | low | Breakdown: a null session spins forever; a 404 on a draft has no reload action; a mismatch is plain text; the toggle's accessible name lacks the day and warehouse | `line-records.tsx` breakdown | patch: session-expired state; `needsInvoiceReload` banner with Reload and Retry; the warning banner; aria-label naming day and warehouse |
| C6 | low | A status change while "Load more" is in flight lets a late page merge into the refetched first page; the stale "more" error survives | `use-invoice-records.ts` | patch: bump `seq` in the first-page effect and clear `more` |
| C7 | low | The CSV header omits the invoice status, supplying GSTIN, segment dates and generation time | `lib/invoice-records.ts` | patch: add the `#` lines |
| C8 | gap | Web "Load more" failure and export-failure states are untested | `line-records.test.tsx` | patch: 404 on page 2 of a draft shows reload with a working Reload button and keeps the shown rows; same for export |
| C9 | gap | The column after issue (including a stale issue) and the 0062 guard refusing a write to it on an issued row are unasserted | `invoice-records.spec.ts` | patch: assertions |
| D1 | gap | The refresh restamp (hash unchanged, watermark moved) is untested | `restampMeasuredThroughInTx` | defer: only causes breakdown 404s on zero-stock days, and the setup needs out-of-step groups |
| R1 | false | A storage line with NULL uom gives a silent zero drill | `client_invoice_lines_uom_basis_pair` CHECK (0062:214) makes it impossible | rejected |
| R2 | false | The group shrinks or grows after issue, so the drill shifts | No path edits a GSTIN or deletes a warehouse; a warehouse created later can hold no records stamped in a past period | rejected (PENDING already carries the GSTIN-edit guard) |
| R3 | false | The filename may carry illegal characters | An invoice number is digits, `S` and `/`, and `/` is already replaced | rejected |
| R4 | low | Measured-through is not shown on the drill | Only a draft can stop short, and its `storage-not-complete` gap explains why | rejected |
| R5 | low | The cursor is not bound to the line or kind (a replayed cursor gives a wrong page, not 400) | Only an API misuse reaches it | rejected |
| R6 | low | Each page re-scans the order window; the breakdown folds from genesis; there is no export rate limit | By design (summary on first page only, one-day breakdown); the index gap is already in PENDING | rejected |
| R7 | low | The pseudonym is reversible by anyone holding user ids, and linkable across files | Decision 2's exact formula (frozen) | rejected; billing.md states it hides emails, not identity |
| R8 | low | `#` lines become rows in Excel; no guard on `\|` or full-width `＝`; quantities carry no unit column | `#` is decision 1; the guard follows the OWASP set | rejected |
| R9 | low | Order and storage records lack a SKU or actor, despite the Intent's general sentence | The per-kind record shapes are in Boundaries | rejected |
| R10 | low | The export's protocol fault uses network wording | Unreachable from a conforming server | rejected |

## Design Notes

- **Why an issued line reproduces.** Every count's instant is a server stamp, and the 21-4 commit guarantee proves the period complete. The ledger is append-only by trigger, and GRN lines and picks are never updated by any code path. A SKU with history cannot change client. The reconcile flag is the alarm for the residual paths: the correction race and a snapshot rebuild.
- **Why the summary is computed only on the first page.** The order drill's first-dispatch walk is the costly part, so it is computed once and paged after.
- **Why the per-SKU breakdown covers one day.** It folds from genesis, which is cheap for one (day, warehouse).

## Verification

**Commands:**
- `bun run lint && bun run typecheck && bun run build && bun run db:generate && bun run test` (wms-be) -- expected: green, and `db:generate` reports "No schema changes".
- `bun run lint && bun run test && bun run typecheck && bun run check:capability-mirror && bun run build` (wms-fe) -- expected: green.
