---
title: 'Invoice regulatory pass — frozen issued invoices, rupee round-off, per-GSTIN numbering'
type: 'feature'
created: '2026-10-03'
status: 'done'
route: 'dispatch'
baseline_commit: 'edb1e999efc0a7c5d59e9bfb2ef955e65f286ddd'
review_loop_iteration: 0
context:
  - '_bmad-output/implementation-artifacts/epic-8-context.md'
  - 'docs/design/SYSTEM-DESIGN.md'
  - 'docs/design/IMPLEMENTATION-GUIDE.md'
  - 'docs/design/modules/invoicing.md'
  - 'docs/design/frontend/IMPLEMENTATION-GUIDE.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** 8-1's invoice core leaves three GST-regulatory questions open (PENDING §invoicing):
- an issued, numbered invoice is silently rewritten in place when a catalog edit changes its tax;
- numbering runs one series per tenant, although each GSTIN is a separate registrant;
- the payable is paise-exact, while practice prints a rupee-rounded total.

The document also pins an odd-cased `totals.payAble`. E-way bills and the HSN summary (deferred, next) read these numbers, so they settle first.

**Approach:** Amend the invoicing core and its printable view so that:
- an issued invoice is a frozen legal document;
- its number comes from its supplier GSTIN's own series;
- its totals carry an explicit, stored round-off and a rounded payable.

Existing rows are migrated to the new shapes.

**Decisions (human, 2026-10-03):**
1. **Freeze.** Once an invoice is `issued` (or `voided`), generation never recomputes or rewrites it. A later catalog edit never reaches it. Corrections need credit/debit notes, which stay deferred.
2. **Round to the nearest rupee, stored.** The rounding is half-up at 50 paise: `payable = ⌊(total + 50) / 100⌋ × 100` and `roundOff = payable − total`, so `roundOff` lies in −49…+50. Both are stored on the row and in the document, the print shows a "Round off" line, and e-way and HSN later read the stored figures. Taxable, GST and per-tax amounts stay paise-exact.
3. **Number format `29/2627/000001`.** The format is the supplier GSTIN's two-digit state code, a slash, the FY digits, a slash, and a 6-digit sequence (14 chars). There is one consecutive series per (tenant, supplier GSTIN, FY).

## Boundaries & Constraints

**Always:**
- Integer paise and basis points end to end. Rounding touches only `total → payable`, never a line or a per-tax amount.
- 8-1's invariants hold:
  - one invoice per order;
  - derive-from-facts until issuance;
  - frozen acceptance rates;
  - generation never blocks dispatch;
  - `invoice.issued` only on first issuance.
- Every shape change ships with a migration that rewrites existing rows, and a test proving it.

**Never:**
- Credit/debit notes or a void command.
- Renumbering or re-pricing an already-issued invoice. The migration may only *add* derived fields to one.
- E-way, HSN summary or FE input-form work (the deferred specs).
- Deleting legacy series rows.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Catalog edit after issue | SKU `gst_rate_bps` changed; event redelivery or a plain manual regenerate on an issued invoice | The stored invoice is returned byte-identical. No write, no revision bump, no event | Delivery ACKs |
| Rates sent to an issued invoice | `POST /invoices {orderId, rates}`, invoice issued | Refused | `409 invoice-frozen` |
| Awaiting invoice issues | All gaps close | Number taken from its supplier GSTIN's series (e.g. `29/2627/000003`) | Series row locked |
| Two GSTINs, same FY | Warehouses in 29 and 27 | Two independent series, each starting at `000001` | Unique (tenant, origin GSTIN, number) |
| Rounding | total 228060 / 435449 / 435450 paise | payable 228100 (+40) / 435400 (−49) / 435500 (+50) | N/A |
| Legacy rows | 8-1 documents with `payAble`; per-tenant series rows | Key renamed to `total`; `roundOff`/`payable` added (row + document); legacy series rows keep a NULL GSTIN as a frozen historical series; legacy numbers untouched | Migration proof test |

</frozen-after-approval>

## Code Map

- `wms-be/src/modules/invoicing/generator.ts` `generateCoreInTx`:
  - **Reorder:** the locked invoice read (today step 4, ~:384-396) moves FIRST.
  - **Freeze:** an `issued`/`voided` row short-circuits before the facts read (step 1), the override checks (:398-409) and `computeDraft` (:411). It returns from the stored row: `warehouseId: existing.warehouseId`, `contentChanged: false`, `firstIssuance: false`.
  - **Dead code:** the `issued`/`voided` arms of `nextStatus` (:427-434) become dead and are deleted.
  - **Series:** `allocateSeriesSeq` (~:161-170) locks by `(tenant, origin_gstin, fy)`; its `onConflictDoNothing` must be `target: [tenantId, originGstin, fyLabel], where: sql\`origin_gstin is not null\`` (Postgres only infers a partial unique with the matching predicate).
  - **Number:** stamped at ~:447 as `${draft.originGstin.slice(0,2)}/${fyLabel.slice(3)}/${seq padded to 6}`. The prefix is never from `resolveStateCode`. Assert the result is ≤16 chars.
  - **Document:** `buildDocument` emits totals `{subtotal, gst, total, roundOff, payable}`.
- `wms-be/src/modules/invoicing/arith.ts`: `roundToRupee(total: Paise) → {payable: Paise, roundOff: number}`. It is half-up at 50 paise, `roundOff` is a checked integer in [−49, 50] (not `Paise`; `asPaise` rejects negatives), and it guards `total + 50` within the safe-integer range.
- `wms-be/src/modules/invoicing/{command,delivery,events}.ts`: the `invoice.issued` payload is built in two places (command ~:155, delivery ~:75). Extract one builder. The payload gains `originGstin`, `payablePaise` and `roundOffPaise` (additive). Consumers key on `(originGstin, invoiceNo)`, never `invoiceNo` alone.
- `wms-be/src/modules/invoicing/view.ts`, `src/api/invoicing.{dto,controller}.ts`: `InvoiceView` and `InvoiceEntry` gain `payablePaise` and `roundOffPaise`; `InvoiceEntry` gains `originGstin`. The `409 invoice-frozen` arm is added.
- `wms-be/src/shared/db/schema.ts`:
  - `invoices` (:3753): new columns.
  - `invoices_tenant_invoice_no_unique` (:3786): becomes `(tenant_id, origin_gstin, invoice_no) WHERE invoice_no IS NOT NULL`.
  - `invoiceSeries` (:3842): gains `origin_gstin`; its unique becomes partial `WHERE origin_gstin IS NOT NULL`, and `invoice_series_tenant_fy_unique` is dropped.
- `wms-be/drizzle/0053_invoicing_core.sql`: the hand-amended precedent; its guard block (:14-24) is the shape to copy. `test/fractional-quantity.spec.ts:118-133` is the scratch-DB migration-proof harness to copy (copy `drizzle/`, trim the journal, migrate, seed, apply the next file whole).
- `wms-be/test/invoicing.spec.ts`:
  - 4 `payAble` references (plus 2 in `invoicing-arith.spec.ts`).
  - The numbering test (~:1280-1311, `max(last_seq) … where tenant_id`) assumes one series row per tenant and must be rewritten.
  - The race and AC2 tests stay green.
- `wms-fe/src/lib/invoices.ts` (`InvoiceDocument.totals`, `readInvoiceDocument` ~:310, `generateOutcome`, `generateReason`, `refusalNeedsReread`) and `src/components/compliance/invoices.tsx` (`PrintableInvoice` totals and amount in words; the `PricingPanel` gate ~:286; the list's Invoice column ~:105), plus tests: 6 `payAble` references.
- `docs/design/modules/invoicing.md`, `API-SURFACE.md`, `PENDING.md` §invoicing.

## Tasks & Acceptance

**Execution:**
- [x] `wms-be/drizzle/0054_invoice_regulatory_pass.sql` (+ journal/snapshot, git-added together). Statement order is load-bearing:
  1. Guards: RAISE if `invoices.payable_paise` exists (already applied) or `invoice_series` is missing (out of order).
  2. Pre-check: RAISE if any row has `(document->'totals'->>'payAble')::bigint <> total_paise`.
  3. `ADD COLUMN payable_paise`, `round_off_paise` (nullable, no DEFAULT).
  4. Backfill from the `total_paise` column: `payable = div(total_paise + 50, 100) * 100`, `round_off = payable - total_paise`. This is safe because `invoices_money_non_negative_check` keeps totals ≥ 0.
  5. Rewrite every `document.totals` to `{subtotal, gst, total, roundOff, payable}` from the columns. `revision` and `updated_at` stay untouched.
  6. Rewrite every `idempotency_keys.response_snapshot` whose `invoice.document.totals` has `payAble` the same way, adding `invoice.payablePaise` and `invoice.roundOffPaise`, so pre-change replays return the new shape.
  7. `SET NOT NULL` on both columns.
  8. CHECKs:
     - `payable = total + round_off`;
     - `round_off BETWEEN -49 AND 50`;
     - `payable % 100 = 0`;
     - `payable >= 0`;
     - `status <> 'issued' OR (invoice_no IS NOT NULL AND origin_gstin IS NOT NULL)`.
  9. `invoice_series`: add `origin_gstin` (nullable; legacy rows stay NULL), drop `invoice_series_tenant_fy_unique`, create the partial unique.
  10. Swap the invoice-number unique.
- [x] `wms-be/src/modules/invoicing/arith.ts`: `roundToRupee`.
- [x] `wms-be/src/modules/invoicing/generator.ts`: the freeze, per-GSTIN series and format, rounding, and the totals shape (per the Code Map).
- [x] `wms-be/src/modules/invoicing/{command,delivery,events,view}.ts`, `src/api/invoicing.{dto,controller}.ts`:
  - non-empty `rates` on an issued or voided invoice → `409 invoice-frozen` (it outranks the line checks; a plain regenerate returns the stored invoice with 200);
  - the shared payload builder;
  - the new view and DTO fields;
  - re-export `openapi.json`.
- [x] `wms-be/test/invoicing-arith.spec.ts`: the rounding table (remainders 00/40/49/50, zero total, the safe-integer bound) and the 16-char number assertion.
- [x] `wms-be/test/invoicing.spec.ts`:
  - freeze after a SKU `gstRate` PATCH, via both manual regenerate and redelivery;
  - `409 invoice-frozen`;
  - concurrent awaiting→issued vs regenerate (a single issuance);
  - numbering: two GSTINs in different states, and two in the same state, each consecutive from 000001 (rewrite the numbering test);
  - a migrated awaiting row regenerated with unchanged facts keeps its revision (SQL/TS rounding parity).
- [x] `wms-be/test/invoicing-migration.spec.ts` (new, scratch DB, trimmed journal `idx <= 53`):
  - seed issued rows with remainders 00/49/50, an awaiting zero-total row, a legacy series row and a legacy idempotency snapshot;
  - apply 0054 whole and assert the ACs;
  - a second apply RAISEs.
- [x] `wms-fe/src/lib/invoices.ts` + `components/compliance/invoices.tsx` + tests:
  - read `total`/`roundOff`/`payable`;
  - print Invoice total, Round off and Payable, with words from `payable`;
  - `invoice-frozen` arm in `generateReason` and `refusalNeedsReread`;
  - the pricing panel only for `awaiting-data` (issued is a guaranteed no-op);
  - the list shows each invoice's supplier GSTIN beside its number.
- [x] Meta docs:
  - `invoicing.md`: freeze, numbering, rounding, the series NULL invariant, consumers key on (GSTIN, number);
  - `API-SURFACE.md`;
  - `PENDING.md`: close three rows; add "corrections need credit/debit notes; frozen blank-HSN lines reach the HSN summary".

**Acceptance Criteria:**
- Given an issued invoice, when its SKU's GST rate changes and `order.dispatched` redelivers or a plain regenerate runs, then the row, lines, document and revision are unchanged and no outbox row is appended.
- Given a database migrated to 0053 with legacy rows, when 0054 applies, then:
  - no invoice document or idempotency snapshot contains `payAble`;
  - every row satisfies the CHECKs;
  - no issued invoice's number, subtotal, GST, total or revision changed;
  - legacy series rows have a NULL `origin_gstin`.
- Given two GSTINs that share a state code, when both issue in one FY, then each has its own consecutive series and the list distinguishes them by GSTIN.
- Given the full BE and FE suites, when run, then all pass.

## Implementation Notes

- Baselines: wms-be `edb1e999efc0a7c5d59e9bfb2ef955e65f286ddd` (frontmatter `baseline_commit`); wms-fe `7842db6f165882804bbf171df06881991208f15a`. Work happens on `feat/8-1b-invoice-regulatory-pass` in both repos.

## Spec Change Log

1. **2026-10-03 — matrix error code `invoice-issued` → `invoice-frozen` (human-authorised frozen-block edit).** Design-review finding #16 renamed the rates-on-issued refusal to `invoice-frozen`, because it fires on voided invoices too. The amendment reached the Code Map and Tasks but not the frozen I/O matrix. The implementation's matrix audit caught the contradiction, and the human chose to amend the matrix rather than rename the code. KEEP: `invoice-frozen` in the BE refusal, the FE mapper and the tests.

## Review Triage Log

*Design review, 2026-10-03: two reviewers (adversarial code-verified; GST + migration). 29 findings, all verified against the code; duplicates merged; every amendment is in the sections above.*

| # | Severity | Finding | Disposition |
|---|----------|---------|-------------|
| 1 | high | `ON CONFLICT` can't infer the partial series unique without its predicate → every first issuance errors | Code Map: target + `where` pinned; old unique dropped |
| 2 | high | NOT NULL columns and CHECKs before the backfill fail on a non-empty table (invisible in CI) | Tasks: 10-step statement order |
| 3 | high | The migration proof is unrunnable on the post-0054 schema, and the re-run guard blocks it | New `invoicing-migration.spec.ts` on a scratch DB (fractional-quantity harness) |
| 4 | high | Idempotency snapshots embed the `payAble` shape forever → replays break the FE | 0054 step 6 rewrites them |
| 5 | high | BE-first deploy leaves the old FE unable to read invoices | Accepted window, recorded in Design Notes |
| 6 | medium | Freeze position contradicted the code (override checks run at :398-411) | Locked read moves first; freeze before facts |
| 7 | medium | Same-state GSTINs print identical numbers; the list and events can't tell them apart | `originGstin` on the entry, list and event; consumers key on (GSTIN, number) |
| 8 | medium | CHECKs don't pin the rounding or the issued⇒GSTIN invariant | Three CHECKs added |
| 9 | medium | Migrated awaiting rows could bump revision on SQL/TS rounding drift | Parity test plus an AC |
| 10 | medium | `total` source and integer division unstated | Columns as the source; `div`; the non-negative CHECK cited; payAble≠total pre-check |
| 11 | medium | Payload built in two places; `delivery.ts` missing | Shared builder |
| 12 | medium | Rates-on-issued trigger undefined; FE affordances unchanged | Non-empty rates → 409; panel only for awaiting; FE arms |
| 13 | medium | The freeze silently freezes warning gaps | Design Note + PENDING row |
| 14 | medium | `db:verify` doesn't check schema drift | `db:generate` "No schema changes" added |
| 15 | low | `roundOff` can't be `Paise` | Signed checked integer |
| 16 | low | Error code `invoice-issued` also fires on voided | Renamed `invoice-frozen` |
| 17 | low | Prefix, FY digits and length bound not pinned | GSTIN slice, `fyLabel.slice(3)`, ≤16 assert |
| 18 | low | Wrong ref counts; numbering test needs a rewrite | Corrected; test named |
| 19 | low | Re-run / out-of-order guards unspecified | 0053-shaped guards |
| 20 | low | "No production invoices" claim unverified | Dropped; the migration is correct regardless |
| 21 | low | Downstream readers' figures unnamed | Design Note: e-way/GSTR-1 use payable, HSN exact |

*Code review, 2026-10-03: three layers (blind, edge-case, verification-gap), all reported. Each finding was verified against the code.*

| # | Verdict | Finding | Route |
|---|---------|---------|-------|
| C1 | medium | The controller description, a `command.ts` comment and API-SURFACE claim a race-loser's "rates still apply". If the insert winner issued, the loser's retry hits the freeze and gets `409 invoice-frozen`. No test covers that arm (blind, edge, VG) | patch: correct the copy; add a forced race where the winner issues |
| C2 | medium | FE: on `invoice-frozen` the re-read shows `issued`, which unmounts `PricingPanel` with its local refusal banner (confirmed: the panel is gated by `canRegenerate(status)`). The test mock never flips to issued (edge) | patch: route the refusal outcome to the section level; the test flips the status |
| C3 | medium | The list's Total renders `totalPaise` (₹210.49), but the spec's FE task says the list uses `payablePaise` (blind) | patch: render `payablePaise`; update the test |
| C4 | low | Step 6: a snapshot lacking `invoice.totalPaise` makes `jsonb_set(…, to_jsonb(NULL))` return NULL (blind, edge) | patch: `coalesce(s.invoice_total, s.total)` |
| C5 | low | Pre-flight check (b) (issued without number or GSTIN) is never triggered by a test (VG, blind) | patch: add the row and assertion to the pre-flight test |
| C6 | low | The `formatInvoiceNo` comment says 7 digits is the last legal width; 8 digits (16 chars) passes (blind, edge) | patch: correct the comment |
| C7 | low | A `documentsEqual` fixture `{total 0, roundOff 50, payable 50}` breaks the rounding invariants (blind) | patch: use an invariant-respecting pair |
| C8 | low | A GSTIN with legacy `FY-…` numbers gets a second series in the same FY (GSTR-1 Table 13), and legacy issued invoices are now frozen as they are; PENDING says neither (blind) | patch: PENDING note |
| C9 | medium | Voided rows sit outside `invoices_issued_stamped_check`, so a voided number with a NULL GSTIN escapes the unique; the voided half of the freeze is untested (blind, edge, VG) | defer: no path creates a voided row until the void/credit-note story |
| C10 | low | The `::bigint` casts in the pre-flight and Step 6 abort without naming a row on a non-integer `payAble` (blind, edge) | reject: code-written documents are always integers; the guard adds complexity for an unseen state |
| C11 | false | `invoiceIssuedPayload` throws a plain Error on an unstamped outcome, so delivery retries forever (edge) | reject: `firstIssuance` is set only on the stamped path, so it is unreachable |
| C12 | low | `ArithmeticOverflowError` is reused for a bad FY, GSTIN prefix, exhausted series and an unstamped issuance, which delivery would ACK silently (blind) | reject: each throw is unreachable (GSTIN shape CHECK, fixed FY format, 10^8 sequence, blocking supplier-gstin gap) |
| C13 | false | The BE list test's `originGstin: expect.any(String)` depends on test order (edge) | reject: the test creates its own invoices; the newest is its issued one |
| C14 | false | Generated artifacts (snapshot, OpenAPI, FE client) are unreviewed (blind) | reject: excluded by design; `db:generate` "No schema changes" and the client regeneration were verified separately |
| C15 | low | Migration test: the out-of-order guard and a non-negative violation are untested; a fixed scratch-DB name (blind) | reject: the guard mirrors 0053's; the scratch-DB naming follows the `fractional-quantity` harness |

## Design Notes

- **`payAble` → `total` (agent decision):** the exact sum becomes `totals.total`. The migration rewrites both documents and idempotency snapshots in place, so readers learn one spelling.
- **Legacy issued invoices gain round-off.** Adding derived `roundOff`/`payable` to an issued invoice is presentation, not re-pricing: its number, subtotal, GST, total and revision are untouched. The migration is written to be correct whether or not real invoices exist.
- **The series continues by format, not renumbering.** Legacy series rows keep a NULL GSTIN and stop allocating. That is safe because issuance requires a supplier GSTIN, which the new CHECK makes structural. Each GSTIN's new series starts at `000001`, which can't collide with a legacy `FY-…` number.
- **The freeze is total, including warnings.** A blank-HSN line on an issued invoice stays blank. This deliberately overrides PENDING's "rename with a revision bump on re-derive" note. The HSN summary (next) must handle blank-HSN lines.
- **Downstream figures:**
  - The e-way total invoice value and the GSTR-1 invoice value use `payable`; e-way's "other value" carries `roundOff`.
  - The HSN summary and per-tax figures stay exact.
  - A tenant-GSTIN fallback for an out-of-state warehouse numbers in the tenant's state series (the existing `pos-discrepancy` case).
- **Deploy window (agent decision, accepted):** backend first per the house rule. Until the FE PR ships, the deployed 8-1 FE can't read the new totals, so an invoice renders "Document unreadable". The window is accepted rather than adding a temporary `payAble` alias.

## Verification

**Commands:**
- `bun run test -- test/` (wms-be): full suite green. `bun run typecheck`, `bun run lint` and `bun run db:verify` clean.
- `bun run db:generate` (wms-be) after 0054 → "No schema changes" (the real snapshot-drift check; `db:verify` only round-trips app metadata).
- `bun run lint && bun run test && bun run typecheck && bun run build` (wms-fe): green.
