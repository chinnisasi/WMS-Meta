---
title: 'HSN summary for GST filing'
type: 'feature'
created: '2026-10-03'
status: 'done'
route: 'dispatch'
baseline_commit: '51f459c358a0b1c666d99bf1268f66b967179829'
review_loop_iteration: 0
context:
  - '_bmad-output/implementation-artifacts/epic-8-context.md'
  - 'docs/design/SYSTEM-DESIGN.md'
  - 'docs/design/IMPLEMENTATION-GUIDE.md'
  - 'docs/design/modules/invoicing.md'
  - 'docs/design/modules/catalog.md'
  - 'docs/design/frontend/SYSTEM-DESIGN.md'
  - 'docs/design/frontend/IMPLEMENTATION-GUIDE.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** Filing GSTR-1 needs the HSN-wise summary of outward supplies (Table 12): per HSN, its unit (UQC), quantity, rate, taxable value and each tax. Today an accountant can only rebuild that by hand from individual invoices.

**Approach:** Add a read-only HSN summary over **issued** invoices. It is per supplier GSTIN (each GSTIN files its own return) and per accounting period (by IST issue date). It is split B2B / B2C, as Table 12 now requires, and grouped by (HSN, UQC, GST rate). It is shown on `/compliance`, reconciles exactly to the invoices it summarises, and exports as CSV.

**Decisions (human, 2026-10-03):**
1. **Periods are a month or a quarter.** A month is `2026-09`. A quarter is the FY quarter `FY-2627-Q2` (Q1 Apr–Jun, Q2 Jul–Sep, Q3 Oct–Dec, Q4 Jan–Mar; this matches the stored `FY-2627` label), which covers QRMP filers.
2. **Shown on screen, plus CSV download.** There is one file each for B2B and B2C, and no GSTR-1 JSON.
3. **The CSV is pinned to the GSTN offline-tool HSN layout.** The human chose to pin a real template and asked the agent to source it. The GSTN portal blocks automated downloads, so the layout is taken from the open-source **India Compliance** app (resilient-tech/india-compliance, `develop`), which generates GSTR-1 offline-tool workbooks used by real filers:
   - **Header row**, for both B2B and B2C: `HSN,Description,UQC,Total Quantity,Total Value,Rate,Taxable Value,Integrated Tax Amount,Central Tax Amount,State/UT Tax Amount,Cess Amount` (`gst_india/doctype/gstr_1/gstr_1_export.py` `get_hsn_headers`).
   - **UQC** is written as `CODE-DESCRIPTION` with GSTN's spellings, e.g. `KGS-KILOGRAMS`, `NOS-NUMBERS`, `MLT-MILILITRE` (`utils/gstr_1/sections/_shared.py` `uom_from_gov`; master in `constants/__init__.py` `UOM_MAP`).
   - **Total Quantity** is rounded once per row to **2 decimals** (`sections/hsn.py` via `sum_column` → `flt(…, 2)`).
   - **Total Value** is taxable value plus every tax.
   - **Description** is left blank, because Phase III auto-fills it from the HSN master.

   A test pins the header row byte-for-byte. If GSTN changes the template, that test is the one place to update.

## Boundaries & Constraints

**Always:**
- **Scope:** only `issued` invoices count, and the period is by IST issue date.
- **Exact amounts:** every amount is the exact paise sum of frozen invoice lines. The invoice round-off is never spread across rows.
- **HSN issues are kept, never dropped.** These are lines whose HSN is blank (frozen since 8-1b) or malformed (not 4, 6 or 8 digits after trimming; HSN is free text in the catalog):
  - On screen, they appear as flagged rows, included in the totals.
  - The CSV **excludes** them, because the portal accepts only HSNs from its master list.
  - The screen lists the affected lines (invoice number, SKU, value, and the SKU's *current* catalog HSN as a hint) and says that excluding them leaves Table 12 short of the invoice total.
- **Units:** every catalog UoM maps to a UQC, and a test proves the mapping is complete.
- **Reconciliation:** the on-screen totals equal the sum of the included invoices' taxable value and GST.

**Never:**
- Writes beyond 0055's backfill.
- Any portal or GSP call.
- Including awaiting or voided invoices.
- Rounding per row.
- GSTR-1 JSON.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| One GSTIN, one month | Issued invoices in Sep 2026 under `29…` | Rows per (HSN, UQC, rate), B2B and B2C sections, totals | N/A |
| Quarter | `FY2627-Q2` | Covers 1 Jul–30 Sep 2026 IST | N/A |
| Same HSN, two rates | 0910 at 5% and at 12% | Two rows | N/A |
| Same HSN, two units | 1006 in `kg` and in `bag` | Two rows (`KGS`, `BAG`) | N/A |
| Blank or malformed HSN | `hsn` null, or `'HSN 0910'` | A flagged row, in the totals; left out of the CSV; the affected lines are listed | Warning on screen |
| B2C vs B2B | `consigneeGstin` null vs set | Separate sections and separate CSVs | N/A |
| IST boundary | Issued `2026-09-30T18:29:59.999Z` vs `…18:30:00.000Z` | September vs October (upper bound exclusive) | N/A |
| Q4 across the calendar year | `FY-2627-Q4` | 1 Jan–31 Mar 2027 IST | N/A |
| Mixed units under `OTH` | jar + keg, same HSN and rate | One `OTH` row, flagged as mixed units | Warning on screen |
| Awaiting / voided invoice in the period | — | Excluded | N/A |
| Another GSTIN's invoices | Issued under `27…` | Excluded from the `29…` summary | N/A |
| Bad period (month 13, `Q5`, non-consecutive FY) or a missing/malformed `gstin` | — | — | `400 validation-failed` |
| Well-formed GSTIN with no issued invoices | — | An empty summary | N/A |

</frozen-after-approval>

## Code Map

- `wms-be/src/shared/db/schema.ts`:
  - `invoices` (:3753): the issue time lives only in `document.header.issuedAt`. Add `issued_at timestamptz`, plus a partial index `(tenant_id, origin_gstin, issued_at) WHERE status = 'issued'` declared with `.where(sql\`…\`)` (the `invoices_tenant_gstin_invoice_no_unique` precedent at :3797), so `db:generate` reports no changes.
  - `invoiceLines` (:3815): no `uom`. Add `uom text` with **no vocabulary CHECK**, because a frozen snapshot must survive vocabulary changes.
- `wms-be/drizzle/0054_invoice_regulatory_pass.sql`: the guard, pre-flight, backfill, NOT NULL then CHECK precedent.
- `wms-be/test/invoicing-migration.spec.ts`: hard-wired to 0054 (`MIGRATION` :13, journal trimmed to ≤ 53 at :102-108). Add a **separate** `describe` that trims to ≤ 54 and applies 0055 whole.
- `wms-be/src/modules/invoicing/generator.ts`:
  - Issuance happens on two paths: insert (:599-619) and the awaiting→issued update (:663-685). Both write `issued_at` from the same `issuedAt` variable that goes into `buildDocument` (:553, :572), so there's one clock read.
  - The frozen early return (:461-485) and the `documentsEqual` no-op write nothing.
  - `writeLines` (:882) writes `uom` from the line draft.
- `wms-be/src/modules/invoicing/view.ts` (`toInvoiceView`/`toInvoiceLineView` :97-142), DTOs, `InvoiceSnapshot` and `documentsEqual` stay **unchanged**: the new columns are read-model only.
- `wms-be/src/modules/catalog/uom.ts`: `UOMS` (:60-104, 35 units). Add "update `invoicing/uqc.ts`" to its add-a-unit checklist.
- `wms-be/src/modules/outbound/outbound.facade.ts:484-502`: the `sum(x)::bigint` → `Number()` + `isSafeInteger` precedent. Postgres `sum(bigint)` returns `numeric`, which the driver returns as a string.
- `wms-be/src/api/invoicing.controller.ts`: `GET /invoices/:invoiceId` is at :121. `/invoices/hsn-summary` must be **declared before it**; `/hsn-summary/gstins` (two segments) can't collide. Pin the order with a test.
- `wms-fe/src/lib/invoices.ts`: `formatRupees` (:34-39) produces `₹1,234.56` with U+2212 and is **not** CSV-safe. `gstRateLabel` (percent from bps).
- `wms-fe/src/components/settings/import-catalog.tsx:250-260`: the Blob download precedent. It prepends a UTF-8 BOM; **this CSV deliberately omits it** (the offline tool matches headers exactly).

## Tasks & Acceptance

**Execution:**
- [x] `wms-be/drizzle/0055_hsn_summary_columns.sql` (+ journal/snapshot), in this order:
  1. **Guards.** RAISE if `invoices.issued_at` or `invoice_lines.uom` already exists (re-run). RAISE if `invoices.payable_paise` is missing (out of order).
  2. **Pre-flight**, listing every offender at once:
     - issued or voided rows whose `document.header.issuedAt` is null or not an ISO-Z instant;
     - lines with zero or several document matches on `(invoice_id, elem->>'orderLineId' = order_line_id::text)`;
     - a matched `uom` that is null or blank;
     - duplicate `(invoice_id, order_line_id)` rows.
  3. Add both columns as nullable, with no DEFAULT.
  4. **Backfill.** `issued_at` from the document only `WHERE status IN ('issued','voided')`. `uom` via a correlated subquery within the line's own invoice.
  5. `uom` → NOT NULL.
  6. **CHECKs:** `status = 'awaiting-data' ⇒ issued_at IS NULL`; `status <> 'awaiting-data' ⇒ issued_at IS NOT NULL`.
  7. `UNIQUE (invoice_id, order_line_id)` on `invoice_lines`.
  8. The partial index.

  The lock window is acceptable at current volumes (0054 already rewrote whole tables). State this in the header.
- [x] `wms-be/src/modules/invoicing/generator.ts`: write `issued_at` on both issuance paths (insert and update; `null` while awaiting) from the document's `issuedAt` variable, and `uom` in `writeLines`.
- [x] `wms-be/src/modules/invoicing/uqc.ts` + test:
  - `uqcFor(uom: string) → {uqc, exact: boolean}`;
  - the full 35-unit table below; a completeness test over `UOMS`;
  - an unknown unit → `OTH` with `exact: false`;
  - **never scale a quantity.**
- [x] `wms-be/src/modules/invoicing/hsn-summary.ts` + `facade.ts`:
  - **Periods.** `parsePeriod('YYYY-MM' | 'FY-yyyy-Qn')`: validates month 01-12, consecutive FY years and `Q1`-`Q4`. It computes `[from, to)` in TypeScript as UTC instants of IST midnights, reusing the generator's `IST_OFFSET_MS`, and binds them as timestamptz (never `date_trunc` or session time zones). `to` is exclusive and the response says so.
  - **Aggregation.** In SQL, over `invoices ⨝ invoice_lines`: `status = 'issued'`, tenant, `origin_gstin = $gstin` (exact, no case folding), and `issued_at` in range. B2B means `invoices.consignee_gstin IS NOT NULL`. Group by `trim(hsn)`, `uom` and `gst_bps`, using `sum(...)::bigint` → `Number()` with an `isSafeInteger` check.
  - **Rows.** HSN validity is `^\d{4}(\d{2}){0,2}$` on the trimmed value. Map UoM → UQC, then merge rows sharing (HSN, UQC, rate) in integers. An `OTH` row records its distinct source units. Ordering is deterministic: HSN ascending with issues last, then UQC, then rate.
  - **Totals.** `invoiceCount` is `count(*)` from `invoices`, because an invoice can have zero lines.
  - **Issue lines** are listed with the invoice number, SKU code, value and the SKU's current catalog HSN, read through the catalog facade.
  - **`hsnSummaryGstins`** returns each issued `origin_gstin` with its min/max `issued_at`.
- [x] `wms-be/src/api/invoicing.{controller,dto}.ts`:
  - `GET /tenants/{t}/invoices/hsn-summary?gstin=&period=` (declared before `:invoiceId`);
  - `GET /tenants/{t}/invoices/hsn-summary/gstins`;
  - any member; a missing or malformed `gstin` or `period` gives 400;
  - re-export `openapi.json`.
- [x] `wms-be/test/invoicing-hsn.spec.ts`:
  - every matrix row;
  - **reconciliation against the invoice columns**: B2B + B2C + issue-row totals equal `sum(subtotal_paise)` and `sum(gst_paise)` over the included invoices, with an issue line present;
  - `issued_at` equals `document.header.issuedAt` on both issuance paths;
  - the route-order pin on `/hsn-summary`.
- [x] `wms-be/test/invoicing-migration.spec.ts`: a new 0055 `describe` on a scratch DB trimmed to ≤ 54. Seed:
  - an 8-1-legacy issued row;
  - an 8-1b issued row;
  - an awaiting row with lines and a stale `issuedAt`;
  - two lines on one invoice;
  - a boundary-instant row.

  Apply 0055 and assert:
  - `issued_at` matches as an instant;
  - `uom` matches;
  - **everything else is unchanged** (`to_jsonb(row) - 'issued_at' - 'uom'` identical, `updated_at` included);
  - the pre-flight refuses;
  - the re-run guard and the CHECKs hold.
- [x] `wms-fe`:
  - client wrappers + `client.test.ts`;
  - a new `src/lib/hsn-summary.ts` + test:
    - period options derived from each GSTIN's min/max `issued_at` (months and FY quarters, the current period included and labelled "in progress");
    - `paiseToPlainRupees` (ASCII `1234.56`, no grouping, no symbol);
    - `qtyMilliToTwoDecimals`: one half-up rounding per summed row, done in integers (no floats). This rounds a quantity, not money; the "no rounding" rule is about amounts;
    - Rate as a plain number from bps (`1800` → `18`, `25` → `0.25`);
    - the UQC cell as `CODE-DESCRIPTION`, taken from a 25-entry description map for the codes in the UoM table (spellings as in the GSTN master, e.g. `MLT-MILILITRE`, `GMS-GRAMMES`);
    - `hsnSummaryCsv(rows, 'b2b'|'b2c')` with the pinned header row, Description blank, Cess `0.00`, quoted with the existing `csvField`, `\n`, **no BOM**, issue rows excluded, filename `hsn-<b2b|b2c>-<gstin>-<period>.csv`;
    - a test pins the header row byte-for-byte and one full sample row.
  - A new `src/components/compliance/hsn-summary.tsx` section on `/compliance` + test:
    - GSTIN and period pickers;
    - B2B and B2C tables with totals;
    - the issue-lines panel and the mixed-unit flags;
    - an AATO note (4 digits up to ₹5 Cr, 6 above; the app can't know turnover);
    - empty states (no issued GSTINs; an empty period);
    - two CSV buttons;
    - `ResourceState` / `ReadFailure`.
- [x] Meta docs:
  - `invoicing.md`: the HSN read model and 0055;
  - `API-SURFACE.md`;
  - `PENDING.md`: close the HSN deferral; add "catalog HSN is free text, not validated against the HSN master", "credit/debit notes must net into Table 12 in their own period", and "cess is unmodelled (0)";
  - both contracts;
  - `catalog.md` add-a-unit checklist (uqc.ts).

**UoM → UQC table** (no scaling; `OTH` where no UQC means the same thing):

| UoM | UQC | UoM | UQC | UoM | UQC | UoM | UQC |
|---|---|---|---|---|---|---|---|
| each | NOS | box | BOX | case | OTH | carton | CTN |
| pack | PAC | pallet | OTH | bag | BAG | drum | DRM |
| roll | ROL | crate | OTH | bundle | BDL | pair | PRS |
| dozen | DOZ | bottle | BTL | can | CAN | tin | OTH |
| jar | OTH | tube | TUB | tray | OTH | sheet | OTH |
| bar | OTH | cylinder | OTH | keg | OTH | set | SET |
| g | GMS | kg | KGS | tonne | TON | ml | MLT |
| litre | LTR | kl | KLR | mm | OTH | cm | CMS |
| m | MTR | sqm | SQM | sqft | SQF | | |

**Acceptance Criteria:**
- Given issued invoices for one GSTIN in a period, including an HSN-issue line, when the summary runs, then all row totals together equal `sum(invoices.subtotal_paise)` and `sum(invoices.gst_paise)` over those invoices, to the paisa.
- Given a database migrated to 0054, when 0055 applies, then every issued row's `issued_at` equals its document's `issuedAt`, every line's `uom` equals its document line's, and every other column of every row is unchanged.
- Given the template supplied for decision 3, when a CSV is generated, then its header row matches the template byte-for-byte (a test pins it).
- Given the full BE and FE suites, when run, then they pass.

## Implementation Notes

- Baselines: wms-be `51f459c358a0b1c666d99bf1268f66b967179829` (frontmatter `baseline_commit`); wms-fe `9c33b7e82eda39a4e4da7e5690df26a6646da16b`. Work happens on `feat/8-2a-hsn-summary` in both repos. Leave changes uncommitted; do not commit, push, or open PRs.
- Shipped: WMS-BE #72 (`e4a6606`), WMS-FE #57 (`667874b`); design PR WMS-Meta #84.

## Spec Change Log

## Review Triage Log

*Design review, 2026-10-03: two reviewers (code-verified; GST Table 12 + migration). 29 findings merged into 20, every one verified. The regulatory claims were checked against GSTN advisories (B2B/B2C bifurcation from May 2025; Phase III HSN master dropdown and auto description; AATO digit rule). The CSV header order and quantity decimals were **unverifiable** and moved to the template decision.*

| # | Severity | Finding | Disposition |
|---|----------|---------|-------------|
| 1 | high | Merging under one UQC sums incompatible units; ambiguous picks not decided | The 35-row table pinned; no scaling; `OTH` flagged as mixed |
| 2 | high | HSN is free text, so malformed codes would reach the CSV | Validity regex; issue rows flagged, excluded from the CSV, listed |
| 3 | high | Table 12 header order asserted without verification (the spec had Rate last, which would have failed the import) | Human decision 3: the layout was sourced from India Compliance's offline-tool export code (GSTN blocks automated downloads) and pinned byte-for-byte |
| 4 | high | Backfill join key unstated and unenforced | `(invoice_id, orderLineId)` key; pre-flight; new UNIQUE |
| 5 | high | Reconciliation compared lines to lines and could not fail | Compares against `invoices.subtotal_paise` / `gst_paise` |
| 6 | high | SQL `sum` returns a numeric string | `::bigint` → `Number()` + `isSafeInteger` |
| 7 | medium | Stale `issuedAt` on re-parked 8-1 rows | Backfill only issued/voided; two-way CHECK |
| 8 | medium | Two issuance write paths unnamed | Both named; one clock read; test |
| 9 | medium | Period label clashed with `FY-2627` | `FY-2627-Q2`; validation pinned |
| 10 | medium | IST bounds via the session time zone could drift | Computed in TS, bound as timestamptz; exclusive `to` |
| 11 | medium | The FE period list missed periods with data | Built from each GSTIN's min/max `issued_at` |
| 12 | medium | `formatRupees` is not CSV-safe; the precedent adds a BOM | `paiseToPlainRupees`; no BOM |
| 13 | medium | Migration harness hard-wired to 0054 | A separate 0055 `describe`; whole-row unchanged check |
| 14 | medium | "Credit-note correction" guidance misleading | Lines listed with the current catalog HSN hint; the Table 12 shortfall stated |
| 15 | low | New columns could leak into views and snapshots | Read-model only, stated |
| 16 | low | No `uom` vocabulary CHECK decided | None (snapshot); `uqcFor` falls back to `OTH` |
| 17 | low | Index absent from the Drizzle schema | Declared with `.where` |
| 18 | low | Wrong line refs | Corrected |
| 19 | low | Null-HSN rows and ordering underspecified | Deterministic order; issue rows grouped |
| 20 | low | Credit/debit netting, cess, QRMP/IFF unstated | Design Notes + PENDING |

*Code review, 2026-10-03: three layers (blind, edge-case, verification-gap); 26 findings, 21 after merging duplicates. Each was verified against the code.*

| # | Verdict | Finding | Evidence | Route |
|---|---------|---------|----------|-------|
| C1 | medium | The three summary reads run READ COMMITTED, so an invoice issued between them makes the rows, `invoiceCount` and `issueLines` disagree | `withTenantTransaction` with no isolation option; `repeatable read` exists (`tenant-scope.ts:52`, used at `reconcile.ts:731`); the default period is the open month, where issues are live | patch |
| C2 | medium | The `INVOICES_CHANGED_EVENT` refetch has no test | No test file dispatches the event; dropping the listener keeps every test green | patch |
| C3 | medium | The refactored catalog error-report download (BOM, filename, formula guard) has no test | `import-catalog.test.tsx` has no download assertion; the README now promises the BOM | patch |
| C4 | low | Switching GSTIN after picking a period: the reset to the default has no test | The only picker test changes GSTIN before choosing a period | patch |
| C5 | low | The picker opens on the current (in-progress) month, usually empty; a filer wants the newest period with data | `options.months[0]` default; the component test's own default is empty | patch: default to the IST month of the GSTIN's `lastIssuedAt` |
| C6 | low | TS `trim()` and SQL `btrim` disagree on non-space whitespace; a whitespace-only HSN becomes `''`, not null, which splits rows, ties `compareRows` and duplicates React keys | Unreachable through today's API (import and PATCH both JS-trim; `''` maps to null), but the module claims one classifier | patch: `nullif(btrim(hsn), '')` in SQL, classify the SQL value with no second trim |
| C7 | low | Nothing checks that the issue lines and the `hsnIssue` rows agree | Two classifiers (TS for rows, SQL for lines); only a hand-listed expectation | patch: per section, Σ issue-line value = Σ `hsnIssue` row value, and the counts match |
| C8 | low | `status = 'issued'` is bound as a parameter, so a generic plan cannot use the partial index | drizzle `eq()` binds a parameter; the index predicate is a literal | patch: literal predicate |
| C9 | low | Issue-line amounts use plain `+`, unlike every other sum in the module | `hsn-summary.ts` issue-line map | patch: `addExact` |
| C10 | low | `UQC_DESCRIPTIONS` is `Record<string, string>`, so a new backend code silently becomes `OTH-OTHERS` | The test's list is hand-copied | patch: type it over the generated `uqc` enum |
| C11 | low | The route-order gotcha is not in `IMPLEMENTATION-GUIDE.md`; the `SYSTEM-DESIGN.md` module map still says the HSN summary "lands in 8-2" and omits the invoicing → catalog read | `SYSTEM-DESIGN.md:74` | patch (docs) |
| C12 | low | `csvField`'s formula guard would turn a negative amount into `'-12.00` | No amount can be negative until credit notes exist | rejected: unreachable today. Recorded in PENDING's credit-note entry |
| C13 | low | A year 0000–0099 maps to the 1900s; year 9999 gives an extended ISO bound and a 500 | Nobody files for those years; the fix is new guards | rejected |
| C14 | low | The pre-flight passes an impossible date such as `2026-02-30` | `issuedAt` was always written by `toISOString()` | rejected |
| C15 | low | `issueLines` is unbounded | A catalog with no HSNs lists every line; that is a large table, not a failure, and a cap needs new response fields | rejected |
| C16 | low | No architecture test pins invoicing's single catalog read | Developer-only; the dependency is recorded in the module map (C11) | rejected |

## Design Notes

- **Per GSTIN, B2B/B2C split (agent decision, regulatory fact).** GSTR-1 is filed per registration, and Table 12 has separate B2B and B2C tabs. B2B means the invoice has a `consigneeGstin`.
- **The period is the IST issue date,** on the same clock as the FY label and the printed date. A quarter is an FY quarter, because QRMP quarters follow the FY.
- **No round-off apportioning.** Table 12's values are taxable plus tax; round-off is invoice-level presentation.
- **Gross, for now.** No credit/debit notes exist yet. When they ship, they net into Table 12 in their own issue period, under their own HSN, UQC and rate (PENDING). There is no cess model, so cess is 0; that is an assumption, and wrong for cess goods.
- **QRMP.** IFF months carry B2B invoices only, with no HSN table. Table 12 is filed once per quarter, so a month is a working view for QRMP filers, not a filing period.
- **B2B** is `invoices.consignee_gstin IS NOT NULL` (the issued snapshot). SEZ recipients with a GSTIN land in B2B; exports (place of supply 99, no GSTIN) land in B2C.
- **No unit scaling, ever.** `mm` → `OTH` rather than `CMS`/10. `OTH` is the only lossy bucket, and the screen flags mixed source units there.
- **Real columns, not jsonb reads.** Filtering by period and grouping by unit over `document` JSON would scan every invoice. The two backfilled columns give an indexed, set-based aggregate.

## Verification

**Commands:**
- `bun run test -- test/` (wms-be): green. `bun run typecheck`, `bun run lint`, `bun run db:verify`; `bun run db:generate` → "No schema changes".
- `bun run lint && bun run test && bun run typecheck && bun run build` (wms-fe): green.
