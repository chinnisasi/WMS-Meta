---
title: '5-6a credit and debit notes — GST s.34 notes against an issued client services invoice, own series, caps, the s.34(2) time bar, print, portal, and dispute settlement by credit note'
type: 'feature'
created: '2026-10-23'
status: 'ready-for-dev'
route: 'dispatch'
review_loop_iteration: 0
context:
  - '_bmad-output/implementation-artifacts/epic-21-context.md'
  - '_bmad-output/implementation-artifacts/epic-8-context.md'
  - 'docs/initiatives/production-readiness.md'
  - 'docs/design/SYSTEM-DESIGN.md'
  - 'docs/design/IMPLEMENTATION-GUIDE.md'
  - 'docs/design/modules/billing.md'
  - 'docs/design/modules/invoicing.md'
  - 'docs/design/API-SURFACE.md'
  - 'docs/design/PENDING.md'
  - 'docs/design/frontend/SYSTEM-DESIGN.md'
  - 'docs/design/frontend/IMPLEMENTATION-GUIDE.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** A client services invoice is frozen once issued (`drizzle/0062_client_invoices.sql:264-350`). Today the only correction is to void it and re-prepare (`client-invoices.ts:1095-1141`). Once the invoice is in GSTR-1, the right instrument is a credit or debit note (CGST Act s.34), and nothing can issue one (PENDING "Credit and debit notes for client invoices"). So a 3PL cannot:
- refund a client for a deficient service;
- grant a post-sale discount;
- correct an over- or under-billed rate or quantity;
- close a dispute (21-5b) with a credit.

**Approach:** Add a billing-owned **note** document: `credit` or `debit`, against exactly one issued, disputed or settled client invoice.
- Lifecycle: draft → issued (numbered from its own series, frozen) → void.
- Lines reference the invoice's lines and carry a taxable amount. Tax uses the **original line's** SAC, rate, place of supply and supply type.
- Hard limits: a credit can never exceed the invoice, and a credit note cannot issue after the s.34(2) date.
- Printable as a Rule 53 document. Shown in the client portal.
- On a disputed invoice, a credit note can settle the dispute in the same transaction.
- Backend + web. One additive migration. Every existing invoice hash, response and printout stays byte-identical. No handheld surface: billing is an office document.

**Decisions (recommended, taken autonomously):**
1. **Split.** 5-6a = notes on **client services invoices** (billing).
   - **5-6b**: IRN through the NIC IRP for e-invoicing GSTINs (invoices *and* notes, QR code, 24-hour cancellation). It lifts the `einvoice-required` gap.
   - **5-6c**: notes on goods tax invoices (invoicing module, 8-1).
   - **GSTR-1 filing marker + reporting**: CDNR/CDNUR, Table 13 C/D series, the annual-return bound of s.34(2), and refusing void after filing.
   - All three are recorded in deferred-work.
2. **One note → one invoice.** s.34(1) allows a note to cover several invoices; Rule 53(1A)(g) asks for the invoice number(s). One invoice per note keeps the caps, the portal and the print exact. Multi-invoice notes are out of scope.
3. **Which invoices.** Status `issued`, `disputed` or `settled`. Never `draft` or `void` (409 `invoice-not-noteable`).
   - An invoice with any **issued** note cannot be voided (409 `invoice-has-notes`). Void the notes first.
   - This is a command guard only; 0062's guard function stays untouched.
4. **Reasons** (a fixed vocabulary, paired with the kind by a CHECK), plus a required free-text `reasonNote` of 1–500 code points, printed on the note:
   - credit: `deficiency-in-service`, `post-supply-discount` (s.15(3)(b)), `excess-billed` (rate or quantity charged too high), `dispute-settlement`;
   - debit: `short-billed` (rate or quantity charged too low).
   - The system records the reason. It verifies no legal condition, such as the s.15(3)(b) agreement or the recipient's ITC reversal. That is the operator's and their CA's responsibility, and these are product decisions, not legal advice.
5. **Lines.** One per referenced invoice line (unique per note), with `amountPaise` > 0 as the taxable delta. Each line copies the invoice line's description, SAC, `gst_bps`, `place_of_supply` and `supply_type`, and a trigger checks they are equal. No quantity: Rule 53(1A)(h) asks for the taxable value, rate and tax.
   - Tax per line: `computeLineTax(1000, amount, gst_bps, supply_type)` (`gst.ts:75`), the invoice's own rule.
   - Totals are sums of the rounded lines, then `roundToRupee` (`gst.ts:188`). This is identical to `computeClientInvoiceDraft` (`client-invoices.ts:400-427`).
   - All stored amounts are positive magnitudes. The kind gives the sign.
6. **The credit cap.** For each invoice line, the taxable amounts and each of the three tax heads summed over **issued** credit notes are ≤ that invoice line's. Debit notes add no headroom, so voiding a debit note can never break a credit. Drafts do not count.
   - **Exhaust rule:** a credit line equal to the line's remaining taxable credits exactly the remaining tax of each head. Otherwise it takes the computed heads, each clamped to what remains.
   - Refusal: 409 `credit-exceeds-invoice`, with a `lines [{invoiceLineId, remainingPaise}]` extension.
   - A debit note has no cap. Its amount is bounded only by the arithmetic guards (`assertInvoiceTotals`).
7. **The time bar (s.34(2), as amended by the Finance Act 2022).** A **credit** note issues only before IST midnight starting 1 December following the end of the FY of the original invoice's `fy_label`. Example: invoice `FY-2627` → last instant 2027-11-30 23:59:59.999 IST.
   - Checked at create and again at issue, on `clientInvoiceClock` (reused), behind the replay lookup.
   - Refusal: 409 `credit-note-time-barred`, naming the date.
   - The invoice's FY is the supply's FY. Time of supply for services is the invoice date (s.13(2)(a)), so a March period issued in April falls in the April FY.
   - The "annual return, if earlier" arm needs a filing marker that does not exist (deferred). A debit note has no time bar.
8. **Numbers.** Two series per (tenant, supplying GSTIN, FY of the note's issue instant): `29/C2627/000001` and `29/D2627/000001`. Both are 15 characters; Rule 53(1A)(b) allows ≤ 16, one or more series.
   - New formatter `formatServiceNoteNo(gstin, kind, fy, seq)` in `gst.ts`, reusing `assertNumberParts` and `assertNumberLength`.
   - New table `client_invoice_note_series`, allocated exactly like `allocateSeqInTx` (`client-invoices.ts:1380-1405`): insert ON CONFLICT, then FOR UPDATE.
   - The goods and services invoice series are untouched.
9. **Party.** The note copies the invoice's frozen `party` jsonb **verbatim** at create. Rule 53(1A)(a) and (d) require supplier and recipient details, so the note matches the document it amends. `supplier_gstin` is copied too. No live party compute, no content hash and no stale arm: a note is entered, not derived.
10. **Issue-time re-check, no stale.** Under the invoice lock, issue recomputes each line's heads with the exhaust rule against the then-issued credits.
    - Any difference from the stored figures → 409 `note-figures-changed` ("another credit note was issued against this invoice — discard and re-create").
    - Then the cap, the time bar, and `einvoice-required` (409, when `InvoicingFacade.eInvoiceAppliesInTx` is on and the stored recipient has a GSTIN — IRN is 5-6b).
11. **Dispute settlement.** `settlesDispute: true` is allowed only with `kind=credit` and `reason=dispute-settlement` (400 otherwise, plus a CHECK). At create and at issue, the invoice must be `disputed` (409 `invoice-not-disputed`).
    - Issuing such a note moves the invoice `disputed → settled` in the same transaction: status note `Settled by credit note <noteNo>`, the stamps, and audit `client_invoice.settled` with the existing composite reference `note: … (key …)`.
    - Voiding that note later does **not** reopen the invoice, because `settled` is terminal (`client-invoices.ts:72-78`).
12. **Void.** An issued note may be voided with a required note (1–500). It keeps its number and frees its cap. Audit references use key equality.
13. **Reads never change existing DTOs.** Notes come from new routes. `ClientInvoiceView`, the portal invoice DTOs and `PrintableClientInvoice` keep their exact bytes. The invoice's **net** after notes is a field of the new notes read.
    - Net: invoice − Σ issued credits + Σ issued debits, per subtotal and each head. Payable: `invoice.payable − Σ credit.payable + Σ debit.payable`.
14. **Print.** `PrintableClientInvoiceNote` prints one copy, titled "Credit Note" or "Debit Note". It carries every Rule 53(1A) item:
    - the supplier's name, address and GSTIN;
    - the nature of the document;
    - its number and date of issue (IST);
    - the recipient's name, address, GSTIN, and state name and code;
    - the original invoice's number and date;
    - per line: description, SAC, taxable value, rate, and CGST/SGST/IGST;
    - the reason and reason note;
    - an "Authorised signatory" line;
    - "Reverse charge: No".
    - A draft prints "DRAFT — not a credit/debit note". A void prints "VOID".
15. **Capability and roles.** Mutations need `billing.invoice` (owner + accountant, `permissions.ts:447`). Reads are member-open. A portal session is refused 403 on the operator routes (`portalRefused`). Billing ignores client status here too, as in 21-5.
16. **Audit.** New target type `client_invoice_note`. Actions: `client_invoice_note.drafted | discarded | issued | voided`. No no-op arms.

## Boundaries & Constraints

**Always:**
- The house skeleton (IMPLEMENTATION-GUIDE §1): shape checks above the tx → `billing.invoice` → replay → lock → replay under the lock → guards → write → audit → key last.
- Lock order is always **invoice row → note row**. Discard and void lock only the note's invoice, then the note. Nothing locks a note before its invoice, and the invoice transitions already lock only the invoice.
- Hash arms are distinct from the invoice arms: `{arm:'note-create', tenantId, invoiceId, kind, reason, reasonNote, settlesDispute, lines sorted by invoiceLineId}`, `note-issue`, `note-discard`, `note-void {note}`.
- Money is integer paise in BigInt-safe helpers. Every rounding is the invoice's own (half up, CGST the floor half, odd paisa to SGST).
- The database enforces the freeze, the caps and the line facts as a backstop. The command answers named problems first.
- Portal: two layers (client-stamped tx + explicit `client_id = $client`, `status <> 'draft'`), an exact key allowlist, and the methods in `PORTAL_READS`. An unknown id, another client's id and a draft id are the same 404.

**Never:**
- Change `clientInvoiceContentHash`, `computeClientInvoiceDraft`, `ClientInvoiceView` / `ClientInvoiceDto`, the portal invoice DTOs, `PrintableClientInvoice`, `client_invoices_guard()`, or the invoice or goods series.
- Notes on goods invoices; IRN or IRP calls; GSTR-1 exports; a filing marker; multi-invoice notes; a note with no invoice line (an omitted charge needs a new invoice); quantity on note lines; changing a note's place of supply or rate.
- Wind-down blockers for draft notes (`client-wind-down.ts:12` unchanged).
- FKs, `TRUNCATE` in tests, a `CREATE INDEX` without `IF NOT EXISTS`, or the word INDEX inside a DO block (`test/migrate-deploy.spec.ts:166`). Probe relations with `to_regclass('…') IS NOT NULL`.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected | Error |
|---|---|---|---|
| Credit draft | issued invoice; line L (₹1,000, intra, 18%); credit ₹200 `excess-billed` | 201 draft: CGST 1800, SGST 1800 paise; payable rounded | — |
| Issue | that draft | 200 `{note}` `29/C2627/000001`, frozen; net payable −₹236 | — |
| Over cap | issued credits on L total ₹900; new credit ₹200 | — | 409 `credit-exceeds-invoice`, `remainingPaise: 10000` |
| Exhaust | ₹1,000 line already credited ₹333.33 + ₹333.33; credit ₹333.34 | heads = exactly the remainders; Σ heads = the invoice line's | — |
| Concurrent credits | two drafts, each within cap alone, together over; issue both (different keys) | one 200 | other 409 `credit-exceeds-invoice` or `note-figures-changed` |
| Same-key race | two issues with one key, parked on the invoice lock | identical 200 bodies, one number used | — |
| Time bar edge | invoice FY-2627; clock 2027-11-30T23:59:59.999+05:30 / 2027-12-01T00:00+05:30 | issues / — | — / 409 `credit-note-time-barred` |
| Debit after the bar | same clock, `short-billed` | issues `29/D2728/…` | — |
| Draft or void invoice | create against it | — | 409 `invoice-not-noteable` |
| Foreign line | `invoiceLineId` of another invoice | — | 404 `not-found` |
| Bad shape | debit + `dispute-settlement`; `settlesDispute` on debit; duplicate line; amount 0; blank `reasonNote` | — | 400 `validation-failed` (above the tx) |
| Settle dispute | disputed invoice; credit `dispute-settlement`, `settlesDispute` | note issued; invoice `settled`, note "Settled by credit note …" | invoice no longer disputed → 409 `invoice-not-disputed` |
| E-invoicing | GSTIN flag on, recipient registered | — | 409 `einvoice-required` at issue |
| Void invoice with notes | invoice has an issued note; void it | — | 409 `invoice-has-notes` |
| Void note | issued note + note text | 200, number kept, cap freed | not issued → 409 `note-not-issued` |
| Discard | draft | 204; same-key replay 204; new key 404 | issued → 409 `note-not-draft` |
| Portal | own issued invoice | `GET portal/invoices/{id}/notes` lists issued and void notes + net; drafts never | foreign or draft → 404 |

</frozen-after-approval>

## Design Review Amendments

Design review 2026-10-23: claims check K1–K18 (against origin/main) and blind review B1–B20. Every amendment is recommended and taken autonomously. Where an amendment and the frozen Intent disagree, **the amendment wins**.

**Lifecycle and eligibility**
- **A1 (K8/B6) — supersedes decision 3 in part.**
  - A **credit** note may be raised against an `issued`, `disputed` or `settled` invoice.
  - A **debit** note may be raised only against an `issued` invoice. Otherwise 409 `invoice-not-debitable`.
  - Draft and void invoices stay `invoice-not-noteable` for both kinds.
- **A2 (K9) — supersedes decisions 4 and 11 in part.**
  - `settlesDispute` is independent of the reason: any credit reason can settle a disputed invoice.
  - `dispute-settlement` is dropped. The credit reasons are `deficiency-in-service`, `post-supply-discount` and `excess-billed`. The debit reason stays `short-billed`.
  - CHECK: `NOT settles_dispute OR kind = 'credit'`.
- **A3 (K11) — supplements decision 4.**
  - `reasonNote` is printed on the client's copy and shown in the portal.
  - The web form labels it "Printed on the note the client receives".
- **A4 (B12) — supersedes decision 3's "command guard only".**
  - A **separate** trigger `client_invoices_void_needs_no_notes` (BEFORE UPDATE OF status ON `client_invoices`, WHEN `NEW.status = 'void'`) refuses while any `issued` note of the invoice exists.
  - `client_invoices_guard()` keeps its bytes.
  - The command check `invoice-has-notes` sits **after** `invoice-transition-invalid` (K14), behind the replay under the lock.
  - A void that passes **discards the invoice's draft notes** (lines, then rows) in the same transaction, each with `client_invoice_note.discarded`.
- **A5 (B4) — supplements decision 12.**
  - A credit note with `settles_dispute` cannot be voided: 409 `note-settles-dispute`. The correction is a further note.
- **A6 (B3) — supplements decision 12; an interim rule.**
  - Until the filing marker ships, a note (credit or debit) cannot be voided once the GSTR-1 due date for its issue month has passed. Refused from IST midnight starting the **12th** of the following month: 409 `note-period-closed`.
  - This assumes monthly GSTR-1 filers (the 11th). QRMP filers (the 13th after the quarter) are recorded in PENDING as an interim rule that the filing-marker entry replaces.
  - Invoice void behaviour is unchanged.
- **A7 (B5) — new: maker/checker.**
  - For **credit** notes: `issued_by <> created_by`, and `voided_by <> issued_by`. Otherwise 409 `note-needs-second-approver`. The command checks first; the notes trigger is the backstop.
  - **Where the setting lives:** no tenant-settings table exists (`tenants` has only `name` and `gstin`, `schema.ts:42-57`). A new billing-owned one-row-per-tenant table `client_invoice_note_policies (tenant_id unique, require_second_approver bool NOT NULL default true, updated_by)` follows the `stock_adjustment_policies` precedent (`schema.ts:3880-3900`). A missing row means **required**.
  - **Routes:**
    - `GET /tenants/{t}/billing/note-policy` is member-open.
    - `PUT` with `{requireSecondApprover}` needs a new **owner-only** capability `billing.configure` (`permissions.ts`, mirrored in wms-fe `src/lib/users.ts` `CAPABILITIES` + `OWNER_ONLY_CAPABILITIES`).
    - The PUT is keyed and audited: `client_invoice_note_policy.updated`, target type `client_invoice_note_policy`, `changes {from, to}`.
  - The trigger reads the row; a missing row means required.

**Figures**
- **A8 (K5/B7/B8) — supersedes decision 5's totals rule and decision 6's exhaust rule.**
  - **Heads.** A credit line that exhausts its invoice line's remaining taxable takes exactly the remaining CGST, SGST and IGST.
    - Any other credit line takes `computeLineTax`. If a computed head exceeds what remains, the line is refused: 409 `credit-exceeds-invoice` with `lines[{invoiceLineId, remainingPaise, remainingCgstPaise, remainingSgstPaise, remainingIgstPaise}]`. No silent clamp.
  - **Payable.** Notes are **not** rounded to a rupee on their own. Independent rupee rounding of the parts breaks Σ ≤ invoice (see the ₹1.50 row).
    - `payable = min(total, invoice.payable − Σ prior issued credit payable)`.
    - The credit that **exhausts the whole invoice** (every line fully credited after it) takes exactly the remaining payable.
    - Debit notes: `payable = total`.
    - So `round_off = payable − total ∈ [−49, 50]` (Design Notes prove it), and Σ issued credit payable ≤ invoice payable always holds.
    - Both the command and the trigger check it.
  - **Notes CHECK:**
    - `payable = total + round_off`, round-off in [−49, 50], `payable ≥ 0`;
    - **no** `% 100`;
    - `round_off <> 0` only on a credit.
- **A9 (K8/B6) — new: the debit plausibility cap.**
  - A debit line's amount must be ≤ its invoice line's taxable, unless the line carries `overrideReason` (1–500 code points). Otherwise 409 `debit-needs-override`.
  - The reason is stored on the line (`override_reason`) and listed in the audit row's `changes`.
- **A10 (K3/B9/B10) — supersedes decision 7.**
  - **The supply's FY is the earlier of** `fyLabelFor(istMidnightOf(period_end))` and the invoice's `fy_label`.
    - s.13(2): time of supply for services is the invoice date when the invoice is issued within Rule 47's 30 days, otherwise the date of provision; the period's last day stands for the provision.
    - This is a product decision, not legal advice.
  - The credit-note deadline is IST midnight starting 1 December after that FY ends.
  - Refusal copy: "The GST adjustment for this supply is time-barred under s.34(2) (last day 30 Nov YYYY) — a credit note can no longer reduce tax."
  - PENDING gains "financial credit note (no GST)".
  - The note's own FY and series come from **its own issue instant in IST**: 2027-03-31T20:00Z is 01:30 IST on 1 April, so FY-2728.
  - The web shows the deadline on a credit draft.
- **A11 (K4/B14) — supersedes decision 5's "description" and corrects decision 14.**
  - The note header copies the invoice's `place_of_supply` and `supply_type`.
  - Each note line copies `charge_code`, `basis`, `uom`, `segment_from`, `segment_to`, `sac_code`, `gst_bps`, `place_of_supply` and `supply_type`. The lines trigger checks every one against the invoice line, and the header pair against the invoice.
  - The print shows "Place of supply: <state name> (<code>)" through `placeOfSupplyLabel` (wms-fe `lib/invoices.ts:134`), and "For <supplier name> — Authorised signatory". The supplier name is `party.supplier.name`, the only stored supplier name.
  - The portal allowlist adds `invoiceIssuedAt`.
  - **K12 — the clause letters of Rule 53(1A):**
    - (a) supplier name, address and GSTIN;
    - (b) nature of document;
    - (c) serial number ≤ 16 characters, in one or more series;
    - (d) date;
    - (e) a registered recipient's name, address and GSTIN;
    - (f) an unregistered recipient's name, address and delivery address, with state name and code;
    - (g) the invoice number(s) and date(s);
    - (h) taxable value, rate and tax;
    - (i) signature.
  - Decision 5's "(1A)(h)" and decision 2's "(1A)(g)" stand; decision 8's "(1A)(b)" reads (c), and decision 9's "(a) and (d)" reads (a), (e) and (f).

**Numbering**
- **A12 (K6/B17) — supplements decision 8.**
  - `formatServiceNoteNo` refuses `seq > 999999` with `ArithmeticOverflowError('note series exhausted …')`. The command maps it to 409 `note-series-exhausted`.
  - Goods notes (5-6c) will use the `GC` / `GD` pair, e.g. `29/GC2627/000001`, 16 characters (written into the 5-6c entry).
  - A `gst.ts` unit test formats every series for one GSTIN — goods invoice, S, C, D — and asserts that no two outputs share a prefix up to the FY digits.

**Settlement and reuse**
- **A13 (K7) — supplements decision 11.**
  - Extract `settleInTx(tx, row, note, actorUserId, auditReference)` from `ClientInvoiceService.transition` (`client-invoices.ts:1121-1137`). It does the update, sets the status note and the stamps, and writes the audit row.
  - `transition`'s settle path calls it with the user's note. The note issue calls it with `Settled by credit note <noteNo>`.
  - It is exported from `client-invoices.ts` beside `lockInvoiceInTx`; both become module-level functions taking `tx`. `ClientInvoiceNoteService` imports them, never the class.
  - `replay` and `writeIdempotencyKey` are copied as private methods: four lines each, and the house precedent is per-service.

**Reads, register, events**
- **A14 (B15/K15) — supersedes decision 13's net.**
  - The notes read returns `{notes, netDocument: {subtotal, cgst, sgst, igst, tax, roundOff, payable}}`, using the `ClientInvoiceTotalsView` key names, and `netDocumentPayable` (= `netDocument.payable`).
  - Notes do not touch receivables. This is the document value, not the outstanding balance.
  - PENDING gains "applying credits — refund vs carry-forward".
  - On the portal, an invisible or foreign invoice's notes GET is a **404**, never 200-empty. `netDocument` is in the allowlist. Segments map like `portal-invoices.ts:239-240` (`istDateOf`, end − 1 day).
- **A15 (B13) — new: the notes register.**
  - `GET /tenants/{t}/client-invoice-notes?gstin&from&to&kind&status&cursor&limit`.
    - `gstin` is required; `from` / `to` are inclusive IST dates, a half-open `issued_at` window, with `assertMeteringPeriod`-shaped rules (≤ 366 days).
    - Only issued and void notes are listed.
    - Keyset on `(supplier_gstin, issued_at, id)` over the new lookup `client_invoice_notes (tenant_id, supplier_gstin, issued_at, id) WHERE issued_at IS NOT NULL`.
  - Rows carry the CDNR fields, one row per (note, `gst_bps`) — today always one:
    - note number and IST date, kind, and status (`voided`);
    - recipient GSTIN (from `party`), place of supply, supply type;
    - the original invoice number and IST date;
    - taxable, IGST, CGST, SGST.
  - JSON only: billing has no server export, and reporting's CSV pattern is a reporting seam. The web exports CSV client-side through `csvField` (`wms-fe/src/lib/csv.ts:15`), the 21-5b precedent.
  - Member-open; portal 403.
- **A16 (B16) — new: outbox events.**
  - `client_invoice_note.issued` and `.voided`, carrying `{noteId, invoiceId, clientId, kind, noteNo}`, through `OUTBOX_SINK` (`shared/events/outbox.seam.ts`; model `carriers/carrier.command.ts:474`), at step 9.
  - **No consumer yet.** Roadmap 5.2 (client notifications) is the intended one.
  - Client acknowledgement goes to PENDING.
- **A17 (B20) — supersedes decision 12's field and decision 16 in part.**
  - The void request field is `voidNote`.
  - Audit `changes` per action:
    - `drafted {kind, reason, settlesDispute, lines:[{invoiceLineId, amountPaise, overrideReason?}]}`;
    - `issued {noteNo, fyLabel, payablePaise}`;
    - `voided {noteNo}`; the reference is the key and the note text lives on the row;
    - `discarded {}`;
    - the policy `updated {from, to}`.
  - Note reads follow the invoice read rule: member-open, operators see drafts, portal 403 on operator routes.
- **A18 (K16/K17) — supplements Boundaries.**
  - The hash arms:
    - `{arm:'note-create', tenantId, invoiceId, kind, reason, reasonNote, settlesDispute, lines:[{invoiceLineId, amountPaise, overrideReason}] sorted by invoiceLineId}`;
    - `{arm:'note-issue', tenantId, noteId}`;
    - `{arm:'note-discard', tenantId, noteId}`;
    - `{arm:'note-void', tenantId, noteId, voidNote}`;
    - `{arm:'note-policy', tenantId, requireSecondApprover}`.
  - Every length is counted in code points with `[...s].length`, after trimming.

**Database**
- **A19 (K2/B1/B2) — new: a notes INSERT arm.**
  - `client_invoice_notes_guard` fires BEFORE INSERT OR UPDATE OR DELETE.
  - On INSERT it requires:
    - `status = 'draft'`, with no number, issue or void stamps;
    - the parent invoice read FOR SHARE, and fail closed when it is missing or invisible;
    - `tenant_id`, `client_id`, `supplier_gstin`, `place_of_supply`, `supply_type` and `party` equal to the invoice's;
    - the invoice status eligible for the kind (A1).
  - Probes insert a draft and then update it. A `wms_rls_probe` arm checks an insert with a mismatched `client_id`.
- **A20 (K13/B19) — supplements the cap trigger.**
  - On draft → issued, the trigger takes the invoice row **FOR UPDATE**. It then sums the issued credits of the invoice **plus this note's own lines** (the note is still `draft` in BEFORE UPDATE).
  - The function is declared `VOLATILE`: each statement takes a fresh snapshot under READ COMMITTED, so the post-lock sum sees a competitor that just committed.
  - **Lock order:** invoice → note → series. A direct-SQL writer that updates a note without first locking its invoice takes note → invoice. Against the command, Postgres aborts one side as a deadlock; this is accepted and tested.
  - Probes refuse `void → issued` and `void → draft`.
- **A21 (B19/K18) — exact RLS and the pin.**
  - The policy text is in the Tasks. Operators read drafts; portal sessions do not.
  - `wms_rls_probe` arms: operator sees a draft; portal sees own issued and void; foreign invisible; draft invisible; writes `42501`; series and policy tables invisible.
  - **The pin** is `test/client-isolation.spec.ts` `expect(policies).toHaveLength(121)` (~:1032) with its comment chain. Bump it by **10** (9 note policies + 1 policy-table policy) at code time.
  - The 0062 block in `test/client-invoices.spec.ts:377/:394/:411` uses `like 'client_invoice%'`, but it runs on a journal trimmed to 0061 plus 0062 only (`:345-350`), so the new tables never exist there. Verified, no change.

**Print and web**
- **A22 (K1) — supersedes decision 14's placement.**
  - Opening a note switches the client-invoice detail to a **note view** that unmounts `PrintableClientInvoice` and holds the only `data-print-root` (`PrintableClientInvoiceNote`).
  - The notes panel holds none.
  - A test asserts exactly one `[data-print-root]` in the invoice view, the note view and the portal note view.
- **A23 (K10) — supplements the Code Map.**
  - wms-fe `src/lib/client-invoices.ts:384-401`'s refusal mapper adds `invoice-has-notes` ("This invoice has issued credit/debit notes — void its notes first").
  - The new note refusals live in `lib/client-invoice-notes.ts`.

**Smaller**
- **A24.** PENDING warns:
  - `einvoice-required` blocks notes until 5-6b, and a credit's time bar can run out meanwhile;
  - there is no draft expiry job (by decision);
  - debits add no credit headroom (B11). The operator workaround is to void the credit and re-issue it within the original, or raise a new invoice.
  - The module doc records the same limitation.

**Amended Boundaries**
- **Always:**
  - The lock order is invoice → note → series.
  - The notes trigger INSERT arm (A19).
  - Maker/checker (A7).
  - Outbox at step 9, before audit (A16).
- **Never:**
  - Change `client_invoices_guard()`'s bytes (A4 adds a separate trigger).
  - Round a note to a rupee on its own (A8).
  - A server CSV for the register (A15).
  - Reopen a settled invoice.

**Amended matrix rows** (literal paise)

| Scenario | Input / State | Expected | Error |
|---|---|---|---|
| Credit draft (replaces row 1) | line 100000, intra 1800 bps; credit 20000 `excess-billed` | cgst 1800, sgst 1800, total 23600, payable 23600, round_off 0 | — |
| Three-part line | line 100000 (cgst 9000, sgst 9000; invoice total = payable 118000); credits 33333, 33333, 33334 | heads 3000/3000, 3000/3000, then exhaust 3000/3000 (computed would be 3000.06); payables 39333, 39333, 39334 | — |
| ₹1.50 invoice, three ₹0.50 credits | line 150 (cgst 13, sgst 14), total 177, payable 200 (+23); credits 50 each | C1, C2: cgst 4, sgst 5, total 59, payable 59. C3 exhaust: cgst 5, sgst 4, total 59, payable 82, round_off +23. Σ payable 200 | — |
| Head overflow | line 6 (cgst 0, sgst 1); credit 3 issued (sgst 1); credit 2 (non-exhausting) | — | 409 `credit-exceeds-invoice` (remainingSgstPaise 0) |
| Figures changed | two drafts on one line; A issues; B's exhaust heads now differ | — | 409 `note-figures-changed` |
| Debit on disputed | invoice `disputed` | — | 409 `invoice-not-debitable` |
| Debit over the line | line 100000, debit 120000, no override / with `overrideReason` | issued, `changes` carries the reason | 409 `debit-needs-override` |
| Supply FY | period 2027-03, invoice issued 2027-04-05 (FY-2728) | deadline 2027-11-30 (FY-2627 is earlier) | at 2027-12-01T00:00+05:30 → 409 `credit-note-time-barred` |
| Note FY | issue at 2027-03-31T20:00:00Z | `29/C2728/000001` | — |
| Void after the GSTR-1 date | note issued 2027-05-20 IST; void 2027-06-11T23:59:59.999+05:30 / 2027-06-12T00:00+05:30 | voided / — | — / 409 `note-period-closed` |
| Void a settling note | `settles_dispute` credit | — | 409 `note-settles-dispute` |
| Maker = checker | creator issues a credit; policy row absent | — | 409 `note-needs-second-approver` |
| Single-person tenant | owner PUTs `requireSecondApprover:false`; creator issues | issued; policy audit row | non-owner PUT → 403 `role-denied` |
| Void invoice with drafts only | invoice with 2 draft notes; void | invoice void, drafts discarded, 2 `discarded` audit rows | — |
| Void invoice with an issued note (direct SQL) | `update client_invoices set status='void'…` | — | trigger refuses |
| Portal invisible invoice | `GET portal/invoices/{draftOrForeign}/notes` | — | 404 |
| Register | `?gstin=29…&from=2027-05-01&to=2027-05-31` | issued + void notes in the window, CDNR fields | missing `gstin` → 400 |

## Code Map

Backend (`workspace/core/backend/wms-be`, origin/main `9a246e7`):

- **`src/modules/billing/client-invoices.ts`**
  - Reuse: vocabularies `:68-120`; `clientInvoiceClock` `:147`; the party type `:153-185`; line tax `:376-381` and totals `:400-427` (for debit lines and computed heads); `einvoice-required` `:483-488` (mirror its condition); `allocateSeqInTx` `:1380-1405` (the series pattern).
  - Change `transition` `:1095-1141`:
    - void: `invoice-has-notes` after the `invoice-transition-invalid` check (`:1108-1117`), then discard the draft notes;
    - settle: through the extracted `settleInTx` (A13).
  - Export as module functions: `lockInvoiceInTx` `:1424-1435` and `settleInTx`.
  - Untouched: `computeClientInvoiceDraft`, `clientInvoiceContentHash` `:545-580`, the views `:620-772`.
- **`src/modules/billing/client-invoice-notes.ts`** -- **new**:
  - `ClientInvoiceNoteService` (create, issue, discard, void, notes-of-invoice, get, register, policy get/put);
  - pure `computeNoteFigures(invoice, invoiceLines, issuedCredits, request)` for the heads, exhaust and payable (A8), `supplyFyLabel(periodEnd, fyLabel)`, `creditNoteDeadline(fyLabel)`, `gstr1VoidCutoff(issuedAt)`;
  - the vocabularies `NOTE_KINDS`, `NOTE_STATUSES`, `NOTE_REASONS_BY_KIND`.
- **`src/modules/billing/portal-invoices.ts:174-254`** -- add `portalInvoiceNotesInTx` and `portalInvoiceNoteInTx`. Use a type-only import of client-invoices (`:7-9`), reuse `toParty` and `clientScope`, and map segments as at `:239-240`.
- **`src/modules/billing/billing.facade.ts:172-187`** -- add `portalInvoiceNotes` / `portalInvoiceNote`, stamped `{ clientId }`.
- **`src/modules/billing/billing.module.ts`** -- register the service and inject `OUTBOX_SINK`.
- **`src/shared/primitives/gst.ts:237-287`** -- add `formatServiceNoteNo` (A12).
- **`src/modules/tenancy/permissions.ts:205-230, :348`** -- add `billing.configure` (owner-only).
- **`src/shared/primitives/audit.ts:60, :142`** -- target types `client_invoice_note`, `client_invoice_note_policy`; five actions in `AUDIT_NEW_ACTIONS`. `test/support/audit-guard.ts:171` is unchanged: `client_invoice.settled` is already composite.
- **`src/api/client-invoices.controller.ts`** (+ `.dto.ts`) -- the routes below, modelled on the void route `:435-460`.
- **`src/api/portal.controller.ts:493-535`** -- the two portal routes.
- **`src/shared/db/schema.ts:5456-5600`** -- four tables.
- **`test/architecture.spec.ts`** -- `BILLING_TABLES` / `RAW_BILLING_TABLES` `:1886-1896` (+4); `PORTAL_READS` `:2269` (+2 methods).
- **`test/client-isolation.spec.ts`** -- the probe pattern `:800-830`; the pin `toHaveLength(121)` ~`:1032` (+10).
- **Models:**
  - `test/client-invoices.spec.ts:275-284` -- the hash fixture;
  - `drizzle/0064_*.sql:185-315` -- the CHECK probes;
  - `test/inbound.spec.ts` `raceTwice` / `waitParked` -- the parked race.

Routes (an `Idempotency-Key` on every mutation):

| Method | Path | Capability | Body / result |
|---|---|---|---|
| POST | `/tenants/{t}/client-invoices/{id}/notes` | `billing.invoice` | `{kind, reason, reasonNote, settlesDispute?, lines:[{invoiceLineId, amountPaise, overrideReason?}]}` (1–100) → 201 `{note}` |
| GET | `/tenants/{t}/client-invoices/{id}/notes` | — | `{notes, netDocument, netDocumentPayable}` |
| GET | `/tenants/{t}/client-invoice-notes?gstin&from&to&kind&status&cursor&limit` | — | the register (A15) |
| GET | `/tenants/{t}/client-invoice-notes/{noteId}` | — | `{note}` — lines, party, `invoiceNo`, `invoiceIssuedAt`, `creditDeadline` |
| POST | `…/client-invoice-notes/{noteId}/issue` | `billing.invoice` | 200 `{note, invoice?}` (`invoice` when it settled one) |
| DELETE | `…/client-invoice-notes/{noteId}` | `billing.invoice` | 204 |
| POST | `…/client-invoice-notes/{noteId}/void` | `billing.invoice` | `{voidNote}` → 200 `{note}` |
| GET / PUT | `/tenants/{t}/billing/note-policy` | — / `billing.configure` | `{requireSecondApprover}` |
| GET | `/tenants/{t}/portal/invoices/{id}/notes` | portal | `{notes, netDocument, netDocumentPayable}`; invisible → 404 |
| GET | `/tenants/{t}/portal/invoice-notes/{noteId}` | portal | the allowlist below |

**Portal allowlist:**
- id, kind, noteNo, fyLabel, issuedAt, status, reason, reasonNote;
- invoiceNo, invoiceIssuedAt, placeOfSupply, supplyType;
- `totals` with the `ClientInvoiceTotalsView` keys;
- lines `{chargeCode, basis, uom, segmentFrom, segmentTo, sac, gstBps, amountPaise, cgstPaise, sgstPaise, igstPaise}`;
- the portal party.
- Never `voidNote`, `settlesDispute`, `overrideReason`, actor ids, `clientId`, top-level `supplierGstin`, or line ids.

Frontend (`workspace/core/frontend/wms-fe`):

- **`src/components/compliance/client-invoices.tsx:300-445`** -- mount `<InvoiceNotesPanel>` after `LineRecordsPanel` (`:443`). It is `print:hidden` and has no print root. Opening a note switches to the note view (A22).
- **`src/components/compliance/client-invoice-notes.tsx`** -- **new**:
  - the panel: list, `netDocumentPayable` labelled "Document value after notes";
  - the form: per-line `parseRupees` (`lib/rupees.ts:14`), reason, the printed reason note, an override reason when a debit exceeds its line, settle-dispute on a disputed invoice, the credit deadline;
  - the note view: Issue / Discard / Void, with a new key per click;
  - `PrintableClientInvoiceNote` (Rule 53(1A)(a)–(i), A11);
  - the Notes register tab with CSV export through `csvField`.
- **`src/components/compliance/line-records.tsx:48`** -- "Credit this line" on a disputed invoice, with `billing.invoice`: opens the form preset to the line, with settle checked.
- **`src/lib/client-invoices.ts:384-401`** -- `invoice-has-notes` copy (A23).
- **`src/lib/client-invoice-notes.ts`**, **`use-client-invoice-notes.ts`** -- **new**: labels, parsing, the copy for every 409 arm, a `CLIENT_INVOICES_CHANGED_EVENT` notify.
- **`src/components/settings/…`** -- an owner toggle "Require a second person to issue credit notes", reading `useCan('billing.configure')`.
- **`src/components/portal/portal-invoices.tsx:69-130`** -- the Notes section and the note view, with portal hooks only.
- **`src/lib/audit.ts`** `AUDIT_TARGET_LABEL` -- two labels.
- **`src/lib/users.ts`** -- `billing.configure` in `CAPABILITIES` + `OWNER_ONLY_CAPABILITIES`.

## Tasks & Acceptance

**Execution:**
- [ ] `drizzle/NNNN_client_invoice_notes.sql` (+ journal, + git-added snapshot) -- next free number at code time (main 0088; 2-8a holds 0089–0091 in flight). Hand-amended, additive, no data, no FKs.
  - **0. Fail-fast guard:** `client_invoice_notes` exists → RAISE; `client_invoices` missing → RAISE.
  - **`client_invoice_notes`:**
    - `id` uuid PK; `tenant_id`, `client_id`, `invoice_id` uuid NOT NULL;
    - `kind`; `status` text NOT NULL default `'draft'`; `supplier_gstin` NOT NULL; `place_of_supply` NOT NULL; `supply_type` NOT NULL;
    - `reason`, `reason_note` NOT NULL; `settles_dispute` bool NOT NULL default false;
    - `note_no`, `fy_label`, `series_seq`;
    - `subtotal_paise`, `cgst_paise`, `sgst_paise`, `igst_paise`, `tax_paise`, `total_paise`, `round_off_paise`, `payable_paise` bigint NOT NULL;
    - `party` jsonb NOT NULL;
    - `issued_at` / `issued_by`; `void_note`, `voided_at`, `voided_by`; `created_by`, `created_at`, `updated_at`.
  - **CHECKs on notes**, each named and probed:
    - `_kind`: IN ('credit','debit');
    - `_status`: IN ('draft','issued','void');
    - `_reason`: `(kind='credit' AND reason IN ('deficiency-in-service','post-supply-discount','excess-billed')) OR (kind='debit' AND reason='short-billed')`;
    - `_settles`: `NOT settles_dispute OR kind='credit'`;
    - `_reason_note`: `char_length(btrim(reason_note)) BETWEEN 1 AND 500 AND reason_note = btrim(reason_note)`;
    - `_tax_shape`: GSTIN, POS and supply-type regexes as 0062:159-163;
    - `_totals`: amounts ≥ 0; `subtotal + tax = total`; `cgst + sgst + igst = tax`; `payable = total + round_off`; `round_off` BETWEEN −49 AND 50; `payable ≥ 0`; `kind='credit' OR round_off=0`;
    - `_numbered`: `(status='draft') = (note_no IS NULL)`; number ⇔ fy ⇔ seq ⇔ `issued_at` ⇔ `issued_by`; `fy_label ~ '^FY-[0-9]{4}$'`; `note_no ~ '^[0-9]{2}/[CD][0-9]{4}/[0-9]{6}$'`;
    - `_void`: `(status='void') = (voided_at IS NOT NULL)`; `voided_at` ⇔ `voided_by` ⇔ `void_note`; `void_note` 1–500;
    - `_party`: `party <> '{}'::jsonb`.
  - **`client_invoice_note_lines`:**
    - `id`; `tenant_id`, `note_id`, `invoice_line_id` NOT NULL;
    - `charge_code`, `basis`, `uom`; `segment_from`, `segment_to` timestamptz; `sac_code`, `gst_bps`;
    - `place_of_supply` NOT NULL, `supply_type` NOT NULL;
    - `amount_paise` bigint; `cgst_paise`, `sgst_paise`, `igst_paise`; `override_reason`.
    - CHECKs: the charge/basis pair and uom/basis pair (0062:199-216); `amount_paise > 0`; heads ≥ 0 with the supply split (0062:236-246, non-null arms only); `override_reason` NULL or 1–500.
  - **`client_invoice_note_series`:** `(id, tenant_id, supplier_gstin, kind, fy_label, last_seq ≥ 0, timestamps)`, with the shape CHECK including kind.
  - **`client_invoice_note_policies`:** `(id, tenant_id, require_second_approver bool NOT NULL default true, updated_by uuid NOT NULL, timestamps)`.
  - **Uniques and lookups**, every one `CREATE [UNIQUE] INDEX IF NOT EXISTS`:
    - notes `(tenant_id, supplier_gstin, note_no) WHERE note_no IS NOT NULL`;
    - lines `(note_id, invoice_line_id)`;
    - series `(tenant_id, supplier_gstin, kind, fy_label)`;
    - policies `(tenant_id)`;
    - lookups: notes `(tenant_id, invoice_id)`, `(tenant_id, created_at, id)`, `(tenant_id, client_id, created_at, id)`, `(tenant_id, supplier_gstin, issued_at, id) WHERE issued_at IS NOT NULL`; lines `(tenant_id, note_id)`, `(tenant_id, invoice_line_id)`.
  - **Trigger `client_invoice_notes_frozen`** → `client_invoice_notes_guard()`, plpgsql, VOLATILE, BEFORE INSERT OR UPDATE OR DELETE.
    - **INSERT arm (A19).**
    - **UPDATE:**
      - the identity never changes: id, tenant, client, invoice, kind, GSTIN, POS, supply type, reason, reason note, settles, party, creator, created_at;
      - draft → draft is allowed;
      - **draft → issued** requires:
        - the stamps;
        - ≥ 1 line;
        - the header equal to Σ lines;
        - the invoice FOR UPDATE, eligible for the kind;
        - `issued_by <> created_by` for a credit, unless the policy row says false;
        - for a credit: per invoice line, Σ amount and each head over the issued credits plus this note ≤ the invoice line's, and Σ issued credit payable plus this note's ≤ the invoice payable (A8, A20);
      - **issued → void** requires the stamps, and `voided_by <> issued_by` for a credit under the policy;
      - every other move is refused, including void → anything;
      - otherwise frozen (`to_jsonb(NEW) - status cols`).
    - **DELETE:** only a draft with no lines.
  - **Trigger `client_invoice_note_lines_frozen`:**
    - the old and new parent is a draft (FOR SHARE; missing = fail closed);
    - the tenant is equal;
    - the invoice line exists on the note's invoice, and all nine copied columns are equal (A11).
  - **`client_invoice_notes_no_truncate`, `client_invoice_note_lines_no_truncate`.**
  - **`client_invoices_void_needs_no_notes`** (A4): `BEFORE UPDATE OF status ON client_invoices FOR EACH ROW WHEN (NEW.status = 'void' AND OLD.status <> 'void')`. RAISE if `EXISTS (select 1 from client_invoice_notes where invoice_id = NEW.id and status = 'issued')`.
  - **RLS** (enable on all four). With `T := tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid` and `U := NULLIF(current_setting('app.client_id', true), '') IS NULL`:
    - `client_invoice_notes_tenant_isolation` FOR SELECT USING `(T AND (U OR (client_id = NULLIF(current_setting('app.client_id', true), '')::uuid AND status <> 'draft')))`;
    - `_operator_insert` WITH CHECK `(T AND U)`; `_operator_update` USING and WITH CHECK `(T AND U)`; `_operator_delete` USING `(T AND U)`;
    - `client_invoice_note_lines_tenant_isolation` FOR SELECT USING `(T AND (U OR EXISTS (SELECT 1 FROM client_invoice_notes n WHERE n.tenant_id = client_invoice_note_lines.tenant_id AND n.id = client_invoice_note_lines.note_id)))`, plus the three operator-only write policies;
    - `client_invoice_note_series_tenant_isolation` and `client_invoice_note_policies_tenant_isolation`: USING and WITH CHECK `(T AND U)`.
    - Total: **10**.
  - **Post-migration DO block** (no word INDEX anywhere in it):
    - RLS on for 4 tables; 10 policies; 5 triggers by name;
    - each unique by `to_regclass('public.<name>') IS NOT NULL`;
    - 0064-style probes: one accepted shape per table, rolled back by a sentinel; each named CHECK refused by `check_violation` on its own name;
    - note probes insert a draft, then update it;
    - a line probe first inserts a draft invoice, its line and a draft note in the same subtransaction;
    - trigger probes: an issue over cap, a mismatched-client insert, void → issued, void → draft, an invoice void with an issued note — each refused (`P0001`).
- [ ] `src/shared/db/schema.ts` -- four tables. `bun run db:generate` → "No schema changes".
- [ ] `src/shared/primitives/gst.ts` -- `formatServiceNoteNo` (A12) and the prefix-disjointness unit test.
- [ ] `src/modules/billing/client-invoice-notes.ts` -- the service.
  - **Create:**
    1. shape (400): kind and reason vocabulary; code-point lengths; 1–100 distinct lines; `amountPaise` a positive safe integer; settles only on a credit;
    2. `billing.invoice`;
    3. replay;
    4. lock the invoice (404);
    5. replay again;
    6. eligibility (A1);
    7. settling → `disputed`;
    8. lines on the invoice (404);
    9. credit deadline (A10);
    10. figures and cap (A8);
    11. debit plausibility (A9);
    12. insert;
    13. `drafted` audit;
    14. key.
  - **Issue:**
    1. lock the invoice (via the note, 404), then the note;
    2. replay;
    3. draft (`note-not-draft`);
    4. eligibility;
    5. settling → `disputed`;
    6. maker/checker;
    7. deadline;
    8. recompute figures, which must equal the stored ones (`note-figures-changed`);
    9. cap;
    10. `einvoice-required`;
    11. series (`note-series-exhausted`);
    12. update;
    13. `settleInTx` when flagged;
    14. outbox;
    15. audit;
    16. key.
  - **Void:** lock the invoice, then the note → replay → issued (`note-not-issued`) → `note-settles-dispute` → `note-period-closed` → maker/checker → update → outbox → audit → key.
  - **Discard:** lock the invoice, then the note → replay → draft (`note-not-draft`). 204; a replay 204; a new key 404.
- [ ] `src/modules/billing/client-invoices.ts` -- the A4 and A13 changes only.
- [ ] Controllers, DTOs, `billing.facade.ts`, `portal-invoices.ts`, `billing.module.ts`, `permissions.ts`, `audit.ts` -- the routes, reads and vocabularies; regenerate `openapi.json`.
- [ ] `test/architecture.spec.ts`, `test/client-isolation.spec.ts` -- the scans, the pin, the RLS probe arms (A21, A19).
- [ ] `test/client-invoice-notes.spec.ts` -- new suite:
  - the migration on a database built from the journal trimmed before it, in one transaction;
  - every frozen and amended matrix row, with literal paise;
  - `computeNoteFigures` unit cases;
  - the deadline, supply-FY, note-FY and GSTR-1 cutoff boundary pairs on `clientInvoiceClock`;
  - **the same-key parked race** on issue: identical bodies, one seq;
  - **the two-key race:** a raw holder locks the invoice FOR UPDATE; issue B is parked behind issue A; release; A 200, B exactly 409 `credit-exceeds-invoice`;
  - **gap-free series:** N issues with interleaved voids, plus one issue forced to roll back by a trigger refusal after allocation → seqs exactly 1..N;
  - **the deadlock case:** a direct-SQL note update against a command issue; one side aborts `40P01`, accepted;
  - every direct-SQL trigger arm;
  - `expectAuditRow` for each action and for `client_invoice.settled`;
  - the outbox rows.
- [ ] `test/client-invoices.spec.ts` -- **the goldens.** Captured on origin/main **before** any change and committed as literals. Then the notes are added, and the bytes are asserted equal:
  - **G1:** the `computeClientInvoiceDraft(draftInput()).contentHash` literal;
  - **G2:** the exact JSON of `GET /tenants/{t}/client-invoices/{id}` for a seeded issued invoice, re-read after a credit and a debit note are issued against it;
  - **G3:** the stored `idempotency_keys.response_snapshot` of an invoice issue and of a dispute;
  - **G4:** `GET /tenants/{t}/portal/invoices/{id}` JSON, also after notes;
  - **G5:** `GET /tenants/{t}/client-invoices` list page JSON.
  - Plus the `invoice-has-notes` and draft-discard-on-void cases.
- [ ] FE:
  - `client-invoice-notes.test.ts(x)`: parsing and labels; every refusal; each Rule 53(1A) item (a)–(i) asserted on `PrintableClientInvoiceNote` and in the portal note view; the settle checkbox only on a disputed invoice; the actions per status and capability; the deadline display; the register CSV through `csvField`;
  - the exactly-one-print-root test (A22);
  - **G6:** `renderToStaticMarkup(<PrintableClientInvoice invoice={fixture}/>)`, captured on main before the change and asserted equal;
  - the portal-boundary test; the `invoice-has-notes` copy test; the owner toggle.
- [ ] Meta docs, last:
  - **`docs/design/modules/billing.md`:** a "Credit and debit notes (5-6a)" section — tables, the lifecycle state diagram, the commands table, figures, the deadline, the triggers, the issue flow diagram, the lock order, the gotchas (no rupee rounding, debit headroom, interim GSTR-1 cutoff);
  - **`API-SURFACE.md`:** the rows;
  - **`PENDING.md`:**
    - close "Credit and debit notes for client invoices";
    - amend "Void after GSTR-1 filing" (the interim A6) and "IRN" (5-6b, blocks notes);
    - add: one invoice per note; draft notes neither expire nor block wind-down; debits add no credit headroom (workaround); financial credit note (no GST); applying credits (refund vs carry-forward); client acknowledgement of notes; QRMP cutoff;
  - **the `docs/repos/wms-be` and `wms-fe` READMEs;**
  - **`frontend/SYSTEM-DESIGN.md`:** the `/compliance` and `/portal/invoices` rows, and Settings.

**Acceptance Criteria:**
- Given goldens G1–G6 captured on origin/main, when notes are issued against the same invoice, then `GET client-invoices/{id}`, `GET client-invoices`, `GET portal/invoices/{id}`, the stored issue and dispute snapshots, the content hash and the printed invoice markup are byte-equal to them.
- Given any set of issued credit notes on an invoice, then for every line Σ taxable and each Σ head ≤ the line's, and Σ payable ≤ the invoice payable. The command enforces it, and under direct SQL the trigger does.
- Given an issued note, when any column changes outside the void transition, or it is deleted or truncated, or it is void and moved again, then the database refuses.
- Given a portal user of client A, then on `GET portal/invoices/{id}/notes` and `GET portal/invoice-notes/{noteId}`, and at the RLS layer, client B's notes and every draft are invisible (404 on the routes), and every write is `42501`.
- Given credit and debit notes in one FY under one GSTIN, then each series is gap-free from 000001, with rollbacks and voids included, independent of the invoice series.
- Given the policy default, then no single user both creates and issues, or issues and voids, a credit note.

## Implementation Notes

## Spec Change Log

## Review Triage Log

| ID | Verdict | Finding | Outcome |
|---|---|---|---|
| K1 | high | The note printable inside the invoice view gives two print roots | A22 |
| K2 | high | No INSERT arm: a note could be inserted issued, or with another client or party | A19 |
| K3 | high | The deadline keyed only to the invoice FY; the March-period, April-issue case | A10 |
| K4 | medium | "Description" undefined; the print lacked POS and the supplier name; portal lacked the invoice date | A11 |
| K5 | high | Payable rounding: rupee-rounded parts exceed the invoice | A8 |
| K6 | medium | Goods notes could collide with C/D; seq overflow unnamed | A12 |
| K7 | medium | Settle-in-tx duplicated `transition`'s private logic | A13 |
| K8 | medium | Debit on a disputed or settled invoice; no debit bound | A1, A9 |
| K9 | low | `dispute-settlement` reason redundant with the flag | A2 |
| K10 | low | FE copy for `invoice-has-notes` missing | A23 |
| K11 | low | `reasonNote` visibility unstated | A3 |
| K12 | low | Rule 53(1A) clause letters wrong | A11 |
| K13 | high | The trigger sum omitted the note's own draft lines; snapshot staleness | A20 |
| K14 | low | Guard order for `invoice-has-notes` | A4 |
| K15 | medium | Portal notes on an invisible invoice; totals key names; segment mapping | A14 |
| K16 | low | Hash arm fields unnamed | A18 |
| K17 | low | Code-point counting unstated | A18 |
| K18 | medium | Policy-count pin location wrong | A21 (verified: `client-isolation.spec.ts` `toHaveLength(121)`; the 0062 LIKE queries run on a trimmed journal) |
| B1 | high | A note could carry a client other than the invoice's | A19 |
| B2 | high | A note could be inserted with its party or GSTIN differing | A19 |
| B3 | high | Void after the GSTR-1 filing undoes a reported document | A6 (interim) |
| B4 | medium | Voiding a settling note leaves a settled invoice uncredited | A5 |
| B5 | high | No maker/checker on money-out documents | A7 |
| B6 | medium | An unbounded debit | A9 |
| B7 | high | The payable sum can exceed the invoice | A8 |
| B8 | medium | The silent clamp hides a refusal | A8 |
| B9 | medium | Wrong FY for the deadline | A10 |
| B10 | low | Refusal copy and UI deadline | A10 |
| B11 | low | Debits add no credit headroom | kept by decision; A24 records it as a limitation |
| B12 | high | Invoice void with notes was enforced in the command only; orphan drafts | A4 |
| B13 | medium | No register for GSTR-1 CDNR | A15 |
| B14 | medium | The print missed Rule 53 items | A11 |
| B15 | low | "Net" read as receivable | A14 |
| B16 | low | No events | A16 |
| B17 | low | Series prefix collision | A12 |
| B18 | medium | ACs and tests not literal or not deterministic | Tasks rewritten: G1–G6, literal paise rows, parked race, gap-free test |
| B19 | medium | RLS text, lock order, void re-transition | A20, A21 |
| B20 | low | Void field name, audit metadata, read rule | A17 |
| N1 | new | The 0062 test's `like 'client_invoice%'` could catch the new tables | false: it runs on a journal trimmed to 0061 plus 0062 (`client-invoices.spec.ts:345-350`); names kept |
| N2 | new | No tenant-settings table exists for the A7 toggle | A7: the new `client_invoice_note_policies` table and the `billing.configure` capability |
| N3 | new | `audit_events.changes` jsonb exists (`schema.ts:461`) | used for A17's metadata |

## Design Notes

**Why rupee rounding breaks for notes.** Take a ₹1.50 invoice: total 177 paise, payable 200. If each of three ₹0.50 credits rounded independently, each would pay ₹1, for ₹3 in all — more than the invoice's ₹2.

So notes do not round. A credit pays `min(total, remaining payable)`, and the credit that exhausts the invoice takes exactly the remainder. That keeps `round_off` within [−49, 50]:
- **Invoice round-off r ≥ 0:** Σ totals ≤ invoice total ≤ invoice payable, so nothing clamps. The exhaust round-off is `payable − total = r`.
- **r < 0:**
  - If a prior credit clamped, the remaining payable is 0. The exhaust's remaining total ≤ invoice total − invoice payable = −r ≤ 49, so its round-off ≥ −49.
  - If none clamped, the exhaust round-off is again r.

**Why refuse instead of clamping heads.** A non-exhausting credit whose computed head exceeds what remains is a figure the operator did not type. Refusing names the remainder. Only the exhausting credit is adjusted, because only it has a single right answer.

**Why the trigger locks the invoice and is VOLATILE.** The command already holds the lock, so the trigger's lock is free. A writer that bypasses the command is then still serialised. A VOLATILE function's statements each take a new snapshot under READ COMMITTED, so the sum after the lock sees the competitor that just committed.

**Deadline sketch:**
```ts
export function supplyFyLabel(periodEnd: string, invoiceFy: string): string {
  const byPeriod = fyLabelFor(istMidnightOf(periodEnd));
  return byPeriod < invoiceFy ? byPeriod : invoiceFy; // 'FY-2627' < 'FY-2728'
}
export function creditNoteDeadline(fy: string): string { // first refused instant
  return istMidnightOf(`${2000 + Number(fy.slice(5, 7))}-12-01`);
}
export function gstr1VoidCutoff(issuedAtIstDate: string): string { // the 12th of the next month, IST
  const [y, m] = issuedAtIstDate.split('-').map(Number);
  return istMidnightOf(`${m === 12 ? y + 1 : y}-${String(m === 12 ? 1 : m + 1).padStart(2, '0')}-12`);
}
```

**GST sources relied on** (product decisions, not legal advice):
- CGST Act s.34(1)/(3) — when notes are issued;
- s.34(2), as amended by the Finance Act 2022 — 30 November, or the annual return if earlier;
- s.15(3)(b) — post-supply discounts;
- s.13(2) with Rule 47 — time of supply of services;
- Rule 53(1A)(a)–(i) — the contents of a note;
- Rule 48(2) — duplicates for invoices only;
- the GSTR-1 due date (the 11th, monthly filers) — the interim A6.

## Verification

**Commands:**
- `cd workspace/core/backend/wms-be && bun run test -- test/client-invoice-notes.spec.ts` -- expected: green. Never bare `bun test`, and never two jest runs at once.
- `bun run test -- test/client-invoices.spec.ts test/client-isolation.spec.ts test/architecture.spec.ts test/migrate-deploy.spec.ts test/invoice-records.spec.ts test/portal.spec.ts` -- expected: green; goldens G1–G5 unchanged.
- `bun run db:generate` -- expected: "No schema changes"; `git status --short` shows no untracked files.
- `bun run lint && bun run typecheck && bun run build` in both repos.
- `cd workspace/core/frontend/wms-fe && bun run test` -- expected: green, G6 unchanged. The FE drift guard passes once the BE merges.

**Manual checks:**
- **Credit note:** with two users, A drafts a credit note and B issues it.
  - It prints as "Credit Note", one print root.
  - It shows the number, the original invoice number and date, the place of supply and "For <supplier> — Authorised signatory".
  - The invoice printout is unchanged.
- **Portal:** the client sees the note under its invoice, with "Document value after notes".
- **Register:** the month's notes export to CSV.
