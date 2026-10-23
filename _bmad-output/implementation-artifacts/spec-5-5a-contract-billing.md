---
title: '5-5a contract billing — ad-hoc charges (recorded, approved, billed as their own invoice lines) and a per-invoice minimum monthly charge topped up by a minimum-charge adjustment line'
type: 'feature'
created: '2026-10-23'
status: 'ready-for-dev'
route: 'dispatch'
review_loop_iteration: 0
context:
  - '_bmad-output/implementation-artifacts/epic-21-context.md'
  - 'docs/initiatives/production-readiness.md'
  - 'docs/design/SYSTEM-DESIGN.md'
  - 'docs/design/IMPLEMENTATION-GUIDE.md'
  - 'docs/design/modules/billing.md'
  - 'docs/design/modules/clients.md'
  - 'docs/design/API-SURFACE.md'
  - 'docs/design/PENDING.md'
  - 'docs/design/frontend/SYSTEM-DESIGN.md'
  - 'docs/design/frontend/IMPLEMENTATION-GUIDE.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** A client invoice (21-5) can only bill what metering counts: storage, receipt lines, picks and dispatched orders. Each is priced flat by the rate card in force (`client-invoices.ts:369-404`, `rate-cards.ts:21-40`). A real 3PL contract also bills:
- one-off work: extra labour, relabelling, repacking, client-requested re-slots (PENDING `movements` :536), returns processing, overflow space;
- a **minimum monthly charge** — PENDING billing :283 calls it "the most likely first ask".

Neither can be represented today. The only workaround is to keep a second invoice outside the system.

**Approach:**
- **Ad-hoc charges.** A new billing-owned record `client_charges`: one billable event for one client in one warehouse on one IST day, with its figures fixed when it is recorded.
  - An approved charge becomes its own line on that month's invoice for the warehouse's supplying-GSTIN group. The line freezes a copy of everything it prints.
- **Minimum monthly charge.** A new rate-card term, `minimum_monthly` — one more frozen line on the card.
  - When a draft's priced charges fall short of the floor, the compute adds one `minimum_adjustment` line for the difference. The floor is prorated by days across card changes.
- Backend and web. One additive migration. No handheld surface — this is office work, as in 5-6a.
- **When no new term applies, the invoice is byte-identical to today's:** hashes, rows, responses, the portal DTO, the print and the drill-down predicates. Goldens prove it.

**Decisions (recommended, taken autonomously):**
1. **Split.**
   - **5-5a** = ad-hoc charges + the minimum monthly charge. Both are "the invoice bills the whole contract, not only metered usage". They share one mechanism: a priced invoice line that no card × meter produces. That means one widening of `client_invoice_lines`, one guard change and one hash extension. Splitting them would do that work twice.
   - **5-5b** = tiered/volume rates. This is a different goal ("price usage by volume"). It changes the card's line model (`UNIQUE (rate_card_id, charge_code)`, 0060:59) and metering's pricing (`metering.ts:255-320`), and needs its own slab-vs-step decision. Deferred.
   - **Value-added work orders (roadmap 3.8)** are their own story. They will raise `client_charges` rows through this story's service (deferred entry).
2. **Who records and who approves.**
   - New capability `billing.charge` (owner, ops_manager, accountant) records a charge. The floor knows about extra work; the office bills it.
   - A charge recorded by a `billing.invoice` holder (owner, accountant) is **approved at record** (`decided_by` = the recorder).
   - A charge recorded by anyone else is **pending**. Approve, reject (with a note) and cancel (with a note) need `billing.invoice`.
   - Only approved charges bill.
   - A pending charge in a draft's group and month is a **blocking gap**, `adhoc-charge-pending`. Money is never silently left off an invoice that is about to issue.
3. **What a charge carries.**
   - `category` from a closed list. Each category fixes its SAC (decision 4).
   - `description`: 1–200 code points, printed.
   - `unit` from a closed list.
   - `quantity`: a decimal string, > 0, at most 3 places, ≤ 10,000. Stored as `quantity_milli`.
   - `unitRatePaise`: 1..10,000,000 (the card's ₹1 lakh cap).
   - `amount_paise` = `round_half_up(quantity_milli × rate / 1000)` (`divideRoundHalfUp`, `money.ts:37`). A CHECK enforces it. An amount that rounds to 0 is a 400.
   - `chargeDate`: an IST date, ≤ today and ≥ today − 366 days. This rule sits behind the replay lookup, on `clientInvoiceClock`.
   - `warehouseId`: required. It decides the GSTIN group.
   - `reference`: optional free text, 1–100 — an order ref, GRN code or ASN code, printed. Free text, because a charge often has no document, and validating one would couple billing to three modules.
   - `evidenceNote`: optional, 1–500. Internal only: never printed, never shown in the portal.
   - No edit: a wrong charge is cancelled and recorded again.
4. **Categories and SAC, at 18 % (`CLIENT_INVOICE_GST_BPS`).**
   - `extra_labour` 996719
   - `special_handling` 996719
   - `returns_processing` 996719
   - `relabelling` 998540
   - `repacking` 998540
   - `re_slotting` 996729
   - `extra_storage` 996729
   - `other` — the SAC is chosen from {996729, 996719, 998540, 998599} and is required.
   - Goods (packaging material sold) are refused by vocabulary. They belong on a goods tax invoice (deferred).
   - This is a product decision, not tax advice. A CA check is added to PENDING beside the existing storage place-of-supply check.
5. **Units:** `each, hour, day, carton, pallet, order, shipment, container, kg, lot`.
6. **Billing a charge.** An approved charge bills on the invoice of `(client, IST month of chargeDate, the group of warehouses.gstin ?? tenants.gstin)` — the 21-5 group rule (`supplierGroups`, `client-invoices.ts:200`).
   - The line is `charge_code 'adhoc'`, `basis 'per_unit'`, `uom` = the unit, `quantity` = `quantity_milli`, `unit_amount_paise` = the rate, `amount_paise` = the charge's amount, `sac_code` = the charge's SAC, `rate_card_id` null, `adhoc_charge_id` = the charge.
   - The segment is `[istMidnightOf(chargeDate), +1 day)`.
   - The line's `description` is `"<category label> — <description>"`, plus `" · Ref <reference>"` when a reference exists.
   - Tax uses `computeLineTax(1000, amount, 1800, supplyType)` (`gst.ts:75`), the invoice's own rule.
   - A group whose only usage is an approved charge gets a draft: "usage" now includes charges.
7. **A charge is frozen once its month is invoiced.**
   - Record, approve and cancel refuse when its `(client, month, group)` has an `issued`, `disputed` or `settled` invoice: 409 `charge-period-invoiced`. The copy says: "record it in an open month, or raise a debit/credit note".
   - Every charge command takes `lockClientInTx` (`clients.facade.ts:375`, FOR NO KEY UPDATE) first — the same lock prepare, refresh and issue take. So a charge either lands before an issue's recompute (the hash moves, and issue answers `stale`) or sees the issued invoice and refuses.
   - A void invoice frees its month: the replacement bills the charge again.
8. **Minimum monthly charge — where it lives.** It is a rate-card line: `charge_code 'minimum_monthly'`, `basis 'per_month'`, `amount_paise` 1..1,000,000,000 (₹1 crore). There is at most one per card (the existing unique).
   - It is drafted, activated, superseded and cancelled with its card. It is frozen by the existing `rate_card_lines_frozen` trigger (parent must be a draft).
   - Not a `rate_cards` column: `rate_cards_guard` lists its columns one by one (0060:129-190), so a new column would not be frozen.
   - Metering ignores it. `rateOf` looks up only the four metered codes (`metering.ts:258-259`), so the usage read stays byte-identical.
9. **Minimum — scope: per invoice** (per client × month × supplying GSTIN).
   - Every invoice stays computed from its own group alone. Refresh, stale-issue and the drill depend on that independence.
   - 3PL minimums are per site in practice.
   - The UI says: "applies to each monthly invoice (one per GSTIN)".
   - A client-wide floor across GSTINs, and a floor for a month with no usage and no stock (no draft exists then), are deferred.
10. **Minimum — the computation.**
    - `floor = round_half_up(Σ over the month's card segments of minimum × segment days, days in month)`. A segment with no card, or a card with no minimum, contributes 0.
    - `charges` = Σ `amount_paise` of every other line: metered and ad-hoc.
    - If `floor > charges`, one line is added:
      - `charge_code 'minimum_adjustment'`, `basis 'per_invoice'`, `uom` null, `quantity 1`;
      - `unit_amount_paise = amount_paise = floor − charges`;
      - SAC 996729, `rate_card_id` null, segment = the whole month;
      - `description` = `"Minimum monthly charge ₹<floor> less charges ₹<charges>"`, with the per-segment proration when more than one card applied.
    - The line is computed **only when every other line is priced and storage is complete**. Until then, a non-blocking warning `minimum-charge-pending` takes its place.
    - The adjustment line is never unpriced and never carries a gap.
11. **Line order.** Metered lines first, in exactly today's order (`compareLines`, `client-invoices.ts:291`). Then ad-hoc lines, by `(segment_from, adhoc_charge_id)` — uuidv7, so recording order. Then the adjustment.
12. **Hash v1 unchanged.** The two new line keys, `description` and `adhocChargeId`, enter the hashed line object **only when non-null** — the conditional-key exception (IMPLEMENTATION-GUIDE §4). The new gap and warning appear only when their term applies. `"v": 1` stays.
13. **Views.**
    - `ClientInvoiceLineView` and `PortalInvoiceLine` gain an **optional** `description`, present only on `adhoc` / `minimum_adjustment` lines.
    - `chargeCode` and `basis` widen to the invoice-line vocabularies.
    - An existing invoice's JSON is byte-identical.
    - The `quantity` of an `adhoc` line is a 3-decimal string, as for storage.
14. **Drill-down (21-5b).**
    - An `adhoc` line drills to its one charge: `kind 'adhoc-charge'`, by `adhoc_charge_id`, no predicate. It returns `{chargeId, chargeDate, warehouse, category, description, unit, quantity, unitRatePaise, amountPaise, reference, status, recordedBy, decidedBy}`. The summary compares the line's quantity with the charge's quantity.
    - A `minimum_adjustment` line answers **409 `line-not-drillable`**; the web shows the line's description instead.
    - The four existing arms and their predicates are untouched.
15. **Wind-down.** A new blocker, `unbilled-charges`: pending charges, plus approved charges whose month and group has no issued, disputed or settled invoice. It sits beside `unsettled-invoices` (`client-wind-down.ts`). A departing client is billed for its extras.
16. **Audit.** Target type `client_charge`. Actions: `client_charge.recorded | approved | rejected | cancelled`. No no-op arms.

## Boundaries & Constraints

**Always:**
- The house skeleton (IMPLEMENTATION-GUIDE §1): shape checks above the transaction → capability → replay → `lockClientInTx` → replay under the lock → lock the charge row → guards → write → audit → key.
- Lock order: **client row → charge row**, and client row → invoice row as today. Nothing locks a charge or an invoice before its client.
- Hash arms: `charge-record`, `charge-approve`, `charge-reject {note}`, `charge-cancel {note}` — distinct from every invoice arm.
- Money is integer paise in BigInt, rounded half up once per line. Totals are sums of the rounded lines, then `roundToRupee` (`gst.ts:188`).
- An issued invoice reads only its own stored lines. A later change to a charge never reaches it.
- The database backstops every rule: CHECKs, freeze triggers and the widened 0062 guard.

**Never:**
- Change `metering.ts`, the usage route, the four drill predicates, `rate_cards_guard`, the 21-5 hash version, or any existing line's bytes.
- Tiers, a client-wide minimum, a minimum for a group with no usage, proration of anything except the minimum, goods charges, a handheld surface, charges in the portal (the portal shows them only as invoice lines), or editing a recorded charge.
- FKs, TRUNCATE in tests, a `CREATE INDEX` without `IF NOT EXISTS`, the word INDEX inside a DO block (`test/migrate-deploy.spec.ts:166`), or dropping and re-creating an index under the same name.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected | Error |
|---|---|---|---|
| Accountant records | `extra_labour`, 2.5 hour × ₹350, warehouse W (GSTIN G), 2026-10-05 | 201 `approved`, amount 87500 | — |
| Ops records | same, by ops_manager | 201 `pending`; the Oct/G draft gets the `adhoc-charge-pending` gap | issue → 409 `invoice-has-gaps` |
| Approve, then issue | the draft from before | the hash moved → 200 `stale`; the next issue issues with the `adhoc` line | — |
| Rounds to zero | 0.001 × 1 paise | — | 400 `validation-failed` |
| `other` without SAC / goods SAC | — | — | 400 `validation-failed` |
| Month invoiced | Oct/G issued; record dated 2026-10-20 in W | — | 409 `charge-period-invoiced` |
| Cancel after void | Oct/G void; cancel the approved charge | 200; the replacement draft omits it | — |
| Date window | tomorrow, or today − 367 | — | 400 `validation-failed` (behind replay) |
| Minimum met | floor ₹50,000; charges ₹62,000 | no adjustment line; hash = today's | — |
| Minimum short | floor ₹50,000; charges ₹31,250.40 | `minimum_adjustment` 1,874,960 paise; tax on it | — |
| Prorated | ₹40,000 card 1–14 Oct, ₹50,000 card from 15 Oct | floor = round_half_up((40,000×14 + 50,000×17) × 100 / 31) = 4,548,387 paise | — |
| Minimum pending | the storage-not-complete gap fires | no adjustment line; warning `minimum-charge-pending` | — |
| Only a charge | group has no metering usage, one approved charge | prepare creates a draft with one `adhoc` line | — |
| No new terms | any existing fixture | rows, hash, `GET` / portal JSON byte-identical (goldens) | — |
| Drill | `adhoc` line / `minimum_adjustment` line | 200 `adhoc-charge` record, `reconciles: true` | 409 `line-not-drillable` |
| Self client | record for `self` | — | 409 `client-not-billable` |
| Portal | a portal session on any charge route | — | 403 `role-denied` |
| Same-key race | two records, one key, parked on the client lock | identical 201 bodies, one row | — |

</frozen-after-approval>

## Design Review Amendments

The design review ran two passes: a claims check (K1–K22, against origin/main and 5-6a's branch) and a blind review (B1–B22). The triage is in the Review Triage Log. Each amendment below wins over the frozen Intent wherever they differ. Every new assertion has been re-checked against origin/main.

**Rate-card line model**
- **A1 (K1).** `drizzle/0060_rate_cards.sql` has **four** line CHECKs:
  - `rate_card_lines_charge_code_check` (:95)
  - `rate_card_lines_basis_check` (:98)
  - `rate_card_lines_charge_basis_pair` (:102)
  - `rate_card_lines_amount_range` (:109)

  All four are widened. `_basis_check` gains `per_month`. Each widened CHECK gets a probe.
- **A12 (K12).**
  - `RateCardLineDto`'s `@Max` / `maximum` (`rate-cards.dto.ts:60,66`) rises to 1,000,000,000.
  - The per-code bound lives in `lineProblems`: 0..10,000,000 for the four metered codes, 1..1,000,000,000 for `minimum_monthly`.
  - Pins: a ₹2 lakh `minimum_monthly` is accepted; a ₹2 lakh `storage` rate is refused 400.
- **A19 (K20/B9/B12) — supplements decisions 8–10.**
  - A card whose only line is `minimum_monthly` may activate (`rate-card-no-lines` counts lines).
  - New term `rate_card_lines.minimum_counts`, `all` (default) or `metered`.
    - CHECK `rate_card_lines_minimum_counts`: `(charge_code = 'minimum_monthly') = (minimum_counts IS NOT NULL) AND (minimum_counts IS NULL OR minimum_counts IN ('all','metered'))`.
    - It is frozen by the existing parent-draft trigger.
    - It joins the line DTO and the `createDraft` / `replaceDraftLines` hash **only on the minimum line** (conditional key), so G6 holds.
  - `charges` = Σ over metered lines, plus the ad-hoc lines when the rule is `all`.
  - When segments disagree, the rule of the **latest minimum-bearing segment** applies to the whole month, and the description names it.
  - 5-6a may credit the `minimum_adjustment` line like any other line.
  - **The floor is not protected against credits.** A credit note on a metered line can take the month's net below the minimum; that is a commercial decision for the operator.
  - The usage preview's copy says "metered charges only — ad-hoc charges and the minimum appear on the invoice".

**The charge record**
- **A20 (K21) — the exact `client_charges` columns:**
  - `id` uuid PK
  - `tenant_id`, `client_id`, `warehouse_id` — uuid NOT NULL
  - `supplier_gstin` — text NULL; the group key frozen at record (A8)
  - `charge_date` — date NOT NULL
  - `bill_month` — date NOT NULL (A4)
  - `category`, `description`, `sac_code`, `unit` — text NOT NULL
  - `quantity_milli`, `unit_rate_paise`, `amount_paise` — bigint NOT NULL (A29)
  - `reference`, `client_authorization_ref`, `evidence_note` — text NULL
  - `status` — text NOT NULL
  - `recorded_by` uuid NOT NULL, `recorded_at` timestamptz NOT NULL
  - `decided_by`, `decided_at`, `decision_note` — NULL
  - `cancelled_by`, `cancelled_at`, `cancel_note` — NULL
  - `created_at`, `updated_at` — timestamptz NOT NULL default `now()`

  Audit:
  - An approve-at-record writes **one** `client_charge.recorded` row, with `changes: {status: 'approved', autoApproved: true}`. A pending record writes `changes: {status: 'pending'}`.
  - `AUDIT_NEW_ACTIONS` (`audit.ts:142`) gains the four `client_charge.*` actions and `client_charge_policy.updated` (A22).
- **A2 (K2) — `client_charges_decided`:**
  - `(decided_at IS NULL) = (decided_by IS NULL)`
  - `status <> 'pending' OR decided_at IS NULL`
  - `status NOT IN ('approved','rejected') OR decided_at IS NOT NULL`
  - `status <> 'rejected' OR decision_note IS NOT NULL`
  - `decision_note IS NULL OR char_length(btrim(decision_note)) BETWEEN 1 AND 500`

  A cancelled charge may carry a decision stamp (it was approved first) or none (it was cancelled while pending). Probes cover both cancelled shapes, plus a pending row with a stamp (refused).
- **A29 (B19).**
  - `_figures`:
    - `quantity_milli BETWEEN 1 AND 10000000`
    - `unit_rate_paise BETWEEN 1 AND 10000000`
    - `amount_paise BETWEEN 1 AND 1000000000`
    - `amount_paise = (quantity_milli * unit_rate_paise + 500) / 1000`
  - Every operand is bigint, so the product (≤ 1e14) never overflows.
  - Probes: the maximum quantity and rate whose amount is ≤ the cap (accepted), and one paisa over the cap (refused).
  - The module doc gains a table giving the meaning of `client_invoice_lines.quantity` per `charge_code`:
    - storage: milli-unit-days
    - the three counts: a count
    - `adhoc`: milli-units of the charge's unit
    - `minimum_adjustment`: 1
- **A18 (K19).** `quantity` is parsed and normalised to `quantity_milli` (BigInt) **above the transaction**, and the hash carries `quantityMilli` as a decimal string. Golden: `"2.5"` and `"2.50"` hash identically and replay each other.
- **A24 (B7).** Optional `clientAuthorizationRef`: 1–100 trimmed code points. It is the client's PO, email or work-order reference approving the work. Hashed, printed on the line (A10), and shown in the drill.
- **A10 (K10/B18) — supersedes decision 3's date window and decision 10's description wording.**
  - **Frozen labels.** BE `CHARGE_CATEGORY_LABELS` (never read from the FE):

    | Category | Label |
    |---|---|
    | `extra_labour` | Extra labour |
    | `special_handling` | Special handling |
    | `returns_processing` | Returns processing |
    | `relabelling` | Relabelling |
    | `repacking` | Repacking |
    | `re_slotting` | Re-slotting |
    | `extra_storage` | Extra storage |
    | `other` | Other service |

  - **Ad-hoc line description, exactly:** `"<label> — <description>"` + (`" · Ref <reference>"` if present) + (`" · Client auth <clientAuthorizationRef>"` if present).
  - **Minimum line description, exactly:**
    ```
    Minimum monthly charge ₹<F>[ (<seg>; <seg>)] less <all|metered> charges ₹<C>
    ```
    - `<seg>` is `DD–DD Mon YYYY at ₹<M>/month`, and appears only when more than one card segment applied.
    - Every amount is in rupees with two decimal places, grouped en-IN **by hand** (`formatPaiseEnIn`: last three digits, then pairs). Never `Intl`, whose ICU data varies by runtime.
    - Month names come from a fixed English array.
    - Two-segment golden, for the prorated row:
      ```
      Minimum monthly charge ₹45,483.87 (01–14 Oct 2026 at ₹40,000.00/month; 15–31 Oct 2026 at ₹50,000.00/month) less all charges ₹31,250.40
      ```
  - **`CHARGE_UNIT_UQC`** maps each unit to a GST UQC that exists in `invoicing/uqc.ts:23-48`: each→NOS, carton→CTN, kg→KGS, everything else→OTH. Pinned against `UQCS` and exported for the future services HSN summary (PENDING). It is not stored.
  - **Date window:** `chargeDate` must be ≤ today (IST) and ≥ 1 April of the **previous** financial year (`fyLabelFor` of today). This is behind the replay lookup, on `clientInvoiceClock`; outside it → 400. A date more than 30 days back answers 201 with the warning `charge-late`.
  - The PENDING CA-check entry is extended to cover the ad-hoc SACs, the minimum's 996729, and the **place of supply and time of supply of ad-hoc lines**.

**Billing a charge**
- **A4 (K4/B3) — supersedes decisions 3, 6 and 7 where they tie a charge's date to its invoice month.**
  - New column `bill_month`: the first of a month.
  - CHECK `client_charges_bill_month`: `extract(day from bill_month) = 1 AND bill_month >= date_trunc('month', charge_date)::date`.
  - At record, the server sets `bill_month` to the **earliest month ≥ the IST month of `chargeDate`** whose `(client, month, supplier_gstin)` has no `issued`, `disputed` or `settled` invoice. It is not part of the hash.
  - The current month can never be invoiced (prepare refuses a month that has not ended), so a month always exists, and **record never answers `charge-period-invoiced`**. A late charge bills on the next open invoice.
  - The invoice line keeps the charge's **true service date** as its segment `[istMidnightOf(chargeDate), +1 day)`, which may fall before the invoice period. The segment CHECK requires only IST midnights.
  - The compute selects charges by `bill_month = period_start`.
  - When `bill_month` ≠ the service month, the response carries the warning `charge-billed-later`.
  - `charge-period-invoiced` (409) now refers to `bill_month`, on approve, reject and cancel. Its copy: "This charge's billing month (Oct 2026) is already invoiced under <GSTIN> — it can no longer change." No debit/credit-note wording.
- **A8 (K8/B4).**
  - `supplier_gstin` is frozen on the charge at record (`warehouses.gstin ?? tenants.gstin`, read through `clientInvoiceSupplierFactsInTx`). The compute groups by `coalesce(supplier_gstin, '') = coalesce(group gstin, '')`.
  - `client_charges_guard` refuses **approved → cancelled** when any `adhoc` line with this `adhoc_charge_id` sits on an invoice whose status is `issued`, `disputed` or `settled`.
  - The issue arm of `client_invoices_guard` additionally requires, for every `adhoc` line:
    - its charge exists with the line's tenant and the invoice's client;
    - it is `approved`;
    - `bill_month = period_start`;
    - its `supplier_gstin` matches the invoice's;
    - its `adhoc_charge_id` is on no line of **another non-void** invoice.

    Otherwise it raises. These arms are reachable only through `adhoc` lines, so every existing invoice issues exactly as before.
- **A5 (K5).** A client with **no snapshot scope** — no ledger events at all; `clientWarehousesWithEventsInTx` returns no pair — has nothing to store. Its storage counts as complete through `period_end` once the month has ended (prepare already refuses a month that has not), so a charge-only invoice issues.
  - Before this story such a client never had a draft (no lines), so no existing draft changes.
  - New row: "Only a charge, and the client has no events → prepare, issue 200."
- **A6 (K6).** A group whose month has **only pending** charges gets a **zero-line draft** carrying the `adhoc-charge-pending` gap, and prepare counts it as usage.
  - Approve, then refresh → the line appears.
  - Reject, then refresh → the draft is empty; issue answers 409 `nothing-to-invoice`; discard it.
  - New row: "Pending-only month → 201 draft, 0 lines, 1 gap."
- **A21 (B1) — supersedes decision 9 in part.** Rate cards are **client-scoped and tenant-wide** (`rate_cards (tenant_id, client_id)`, 0060; per-warehouse rates are PENDING). A per-invoice minimum would therefore bill a multi-GSTIN client once per GSTIN.
  - **The client's GSTIN footprint** = the groups of the warehouses where it has ledger events (`clientWarehousesWithEventsInTx`), plus the groups of its non-rejected, non-cancelled charges.
  - **Activation** of a card carrying `minimum_monthly` refuses 409 `minimum-needs-single-gstin` when the footprint has more than one group. This is the last activate guard; the activate hash is unchanged.
  - **At compute**, when the footprint has grown past one group, the minimum is **not applied**. The non-blocking warning `minimum-not-applied-multi-gstin` names the groups.
  - **Partly applied:** the review asked for a blocking gap here. A gap would leave a past month unissuable for good — cards are frozen, and a replacement card cannot start in the past. The warning never double-bills and never strands a month.
  - Client-wide allocation stays in the existing deferred entry.
- **A25 (B10).** Verified that `clients` (schema.ts:302-…) carries only `status` (`active | suspended | departed`, :296). It has no activation or departure date, so no billable window exists to intersect.
  - Proration follows the card segments only. A first card from the 15th prorates naturally.
  - New row: "First card from 15 Oct, minimum ₹31,000 → floor 1,700,000 paise (17/31)."
  - PENDING gains "minimum ignores client start and departure dates (none exist)".
- **A27 (B13) — supersedes decision 10's warning.** `minimum-charge-pending` is a **blocking gap**. It is listed after `adhoc-charge-pending` and before `einvoice-required`, and fires whenever some segment carries a minimum but the adjustment cannot be computed yet. A test proves issue cannot succeed while it is present.
- **A26 (B11).**
  - Record warns `charge-may-bring-minimum` when the card in force on the first day of `bill_month` carries `minimum_monthly` and the month has no draft yet for that group.
  - A draft whose adjustment line exists while its only other lines are ad-hoc carries the warning `minimum-from-charges-only`.
  - Dormant months stay deferred.

**Commands and authority**
- **A22 (B2) — supersedes decision 2's approve-at-record rule.**
  - New table `client_charge_policies`: `id`; `tenant_id` NOT NULL; `self_approve_limit_paise` bigint NOT NULL CHECK 0..1,000,000,000; `updated_by` NOT NULL; timestamps. `CREATE UNIQUE INDEX IF NOT EXISTS client_charge_policies_tenant_unique (tenant_id)`.
  - No row means a limit of 1,000,000 paise (₹10,000).
  - A charge is approved at record only when the recorder holds `billing.invoice` **and** its amount is ≤ the limit. Otherwise it is pending, whoever recorded it.
  - **pending → approved requires `decided_by <> recorded_by`**: command 409 `charge-needs-second-approver`, with the guard as backstop.
  - A single-person tenant raises its limit through the policy.
  - Routes:
    - `GET /tenants/{t}/client-charge-policy` — member-open → `{selfApproveLimitPaise, isDefault}`;
    - `PUT` — `billing.invoice`, hash `{arm:'charge-policy', tenantId, selfApproveLimitPaise}`; upserted ON CONFLICT, then FOR UPDATE; audited `client_charge_policy.updated` (target type `client_charge_policy`).
  - The hard per-charge cap is A29's ₹1 crore.
- **A14 (K14/B15/B16/B17) — the transition table** (every hash carries `tenantId`; the key is stored last):

  | Command | Capability | Hash | Guards, in order | Result |
  |---|---|---|---|---|
  | `record` | `billing.charge` | `{arm:'charge-record', clientId, warehouseId, chargeDate, category, description, sacCode, unit, quantityMilli, unitRatePaise, reference, clientAuthorizationRef, evidenceNote}` (nulls explicit) | shape 400 above the tx (vocabularies, lengths, quantity format, rate range, amount 1..cap, `other` ⇒ SAC in the set, SAC absent otherwise) → capability → replay → `lockClientInTx` (404) → replay → `self` 409 `client-not-billable` → status ≠ `active` 409 `client-not-active` → warehouse in tenant 404 `not-found` → date window 400 | 201 `{charge, warnings}`; outbox `client_charge.pending` when pending |
  | `approve` | `billing.invoice` | `{arm:'charge-approve', chargeId}` | capability → replay → read the charge (404 `charge-not-found`) → `lockClientInTx` → replay → lock the charge → `pending` (409 `charge-not-pending`) → `decided_by ≠ recorded_by` (409 `charge-needs-second-approver`) → `bill_month` open (409 `charge-period-invoiced`) | 200; outbox `client_charge.approved` |
  | `reject` | `billing.invoice` | `{arm:'charge-reject', chargeId, note}` | note 1–500 above the tx → as approve, without the second-approver rule | 200; outbox `client_charge.rejected` |
  | `cancel` | `billing.charge` | `{arm:'charge-cancel', chargeId, note}` | note 1–500 above the tx → as approve to the charge lock → status `pending` or `approved` (409 `charge-not-cancellable`) → a pending charge: the recorder or a `billing.invoice` holder; an approved charge: `billing.invoice` (else 403 `permission-denied`) → not on an issued/disputed/settled invoice line, and `bill_month` open (409 `charge-period-invoiced`) | 200; outbox `client_charge.cancelled` when it was pending |

  - Further rules:
    - There is no notion of "a warehouse serves a client" on main: no client–warehouse link table, only `partnerClientLinks` for partners. So a warehouse only has to exist in the tenant.
    - No client start or end date exists (A25), so `chargeDate` is bounded only by A10's window.
    - A suspended or departed client can still have pending charges approved, rejected or cancelled — it still owes.
    - A replay returns the stored first response, byte for byte.
    - The list filter gains `warehouseId`.
  - Amended matrix rows:
    - "Self client → 409 `client-not-billable`";
    - "Suspended client, record → 409 `client-not-active`";
    - "Approve own pending → 409 `charge-needs-second-approver`";
    - "Cancel a pending charge (by its recorder) → 200, no decision stamp";
    - "Reject a charge whose `bill_month` is invoiced → 409" (unreachable through commands, proved by the guard probe).
- **A28 (B14).**
  - A recorder may cancel their own pending charge (A14).
  - The `adhoc-charge-pending` gap carries `count`, and the web links it to `/compliance?tab=client-charges&clientId=…&month=…&status=pending`.
  - Outbox events `client_charge.pending | approved | rejected | cancelled` (payload `{chargeId, clientId, warehouseId, amountPaise}`). **No consumer yet** — the notification source is a deferred entry.
- **A7 (K7/B8) — supersedes the read-scoped RLS in Tasks.** Both `client_charges` and `client_charge_policies` are **operator-only**, with one `FOR ALL` policy each in the `client_invoice_series` shape (0062:466-474, T AND U). Policies 121 → **123**.
  - Probe: under a portal stamp (`app.client_id` set), SELECT returns zero rows and INSERT is refused.
  - The `adhoc-charge` drill is never reachable from the portal (the drill routes already refuse portal sessions with 403). The portal invoice line shows only the frozen description; a test pins this.
- **A15 (K15).** The `unbilled-charges` wind-down blocker counts:
  - pending charges, plus
  - approved charges with no `adhoc` line on an `issued`, `disputed` or `settled` invoice — by the line link, not by month.

  Codes: the charge's IST date + category. The asymmetry is deliberate: metered usage never blocks a wind-down (only unsettled invoices do), because a charge is an explicit record someone asserted and metering is not.
- **A31 (B22).**
  - The charge DTO (list and get) carries `billing: {invoiceId, invoiceNumber | null, status} | null`, derived from the latest **non-void** invoice with a line carrying this charge.
  - The issue audit row gains `changes: {adhocChargeIds: [...]}` **only when** the invoice has ad-hoc lines, so existing issue audit rows keep their exact shape.

**Invoice compute and views**
- **A9 (K9) — the full `client_invoice_lines_priced` text:**
  ```sql
  ("unit_amount_paise" IS NULL) = ("amount_paise" IS NULL)
  AND ("amount_paise" IS NULL OR "amount_paise" >= 0)
  AND (
    ("charge_code" IN ('storage','inbound_handling','pick','outbound_handling')
      AND ("rate_card_id" IS NOT NULL OR "unit_amount_paise" IS NULL)
      AND ("unit_amount_paise" IS NULL OR "unit_amount_paise" BETWEEN 0 AND 10000000))
    OR ("charge_code" = 'adhoc' AND "rate_card_id" IS NULL
      AND "unit_amount_paise" IS NOT NULL AND "unit_amount_paise" BETWEEN 1 AND 10000000
      AND "amount_paise" = ("quantity" * "unit_amount_paise" + 500) / 1000)
    OR ("charge_code" = 'minimum_adjustment' AND "rate_card_id" IS NULL
      AND "unit_amount_paise" IS NOT NULL AND "unit_amount_paise" BETWEEN 1 AND 1000000000
      AND "amount_paise" = "unit_amount_paise")
  )
  ```
  - Every conjunct of 0062's version survives in the metered arm.
  - Each new arm states `IS NOT NULL`, because a NULL arm would pass the CHECK (§3).
- **A11 (K11).** On `ClientInvoiceDraftLine`, `description?` and `adhocChargeId?` are **optional and absent** on metered lines (never `null`). G2 therefore deep-equals main's output, and the hash's conditional keys read `!== undefined`.
- **A16 (K16).**
  - `portal-invoices.ts` selects `adhoc_charge_id` **internally** for `compareLines` and never puts it in the DTO.
  - `invoice-records.ts` `targetInTx` dispatches `adhoc` and `minimum_adjustment` **before** the group re-resolution, so `invoice-group-changed` never fires for them.
  - The adhoc arm reads the charge by `(tenant_id, client_id = invoice.client_id, id = line.adhoc_charge_id)`.
  - The summary's `lineQuantity` and `recordsQuantity` are milli → decimal strings, compared exactly.
  - The drill's `recordedBy` and `decidedBy` use the CSV pseudonym rule.

**5-6a, migration and proof**
- **A3 (K3/B20) — supersedes the Code Map's conditional compose.**
  - No conditional DDL. **The story that merges second rebases** and widens the other's line CHECKs unconditionally.
  - 5-6a's spec does not name its note-line CHECKs. Verified: its A12 says only "the charge/basis pair and uom/basis pair (0062:199-216)". This spec fixes the names the second-lander must use:
    - `client_invoice_note_lines_charge_code_check`
    - `client_invoice_note_lines_basis_check`
    - `client_invoice_note_lines_charge_basis_pair`
    - `client_invoice_note_lines_uom_basis_pair`

    A DROP of a missing name fails loudly, and the probe asserts that both tables accept every widened pair.
  - If 5-5a lands second, it also edits 5-6a's:
    - note DTOs (the charge code enum, an optional description);
    - `PrintableClientInvoiceNote` (prints the invoice line's `description` for the new kinds);
    - the portal notes DTO.
  - If 5-6a lands second, its spec does all of this.
  - AC3 is replaced (below).
- **A17 (K17/B5).**
  - The migration's probes insert their parent rows (invoice, card, charge) inside the sentinel-rolled-back block.
  - A probe asserts that `client_invoices_guard`'s `prosrc` contains the new metered-codes predicate and the adhoc checks.
  - **The guard body is copied from the LIVE definition at code time** (`pg_get_functiondef` on a database migrated to origin/main), and the header names the migration it came from (0062, unless a later one replaced it). The test diffs the pre-migration live `prosrc` against the new one, and the only differences allowed are A8's and A9's arms.
  - The header records that the tables are small, but cites the deploy guard: `DEFAULT_LARGE_TABLE_ROWS = 100_000` (`migrate-deploy.ts:64`) and the `DEPLOY.md` §5 pre-build runbook for `client_invoice_lines_line_key_unique`.
- **A13 (K13).** The "Ops records" matrix row becomes two steps. An existing draft stays stored, and the next issue answers 200 `stale` (the fresh draft now carries the gap). The issue after that answers 409 `invoice-has-gaps`.
- **A23 (B6).** The Code Map lists every reader of `rate_card_lines` and `CHARGE_CODES` with what happens to it (below).
- **A30 (B21).**
  - Goldens:
    - **G1:** captured on the merge base. A rebase re-captures it and notes this in the Spec Change Log.
    - **G4:** `test/invoice-records.spec.ts`'s existing cases pass unedited, and `git diff <base> -- src/modules/inbound/inbound.facade.ts src/modules/outbound/outbound.facade.ts src/modules/inventory/client-metering.ts` is empty.
    - **G5:** `git diff <base> -- src/modules/billing/metering.ts` is empty, and the usage response for the 21-4 fixture deep-equals a stored golden.
  - **Race harness:** transaction A takes `lockClientInTx` and holds it. B starts `issue`, and the test waits until B is parked (`waitParked`). A records a charge and commits. Then assert B answers `stale` and the charge appears on the stored draft. The mirror case: B issues first, then A's approve answers 409 `charge-period-invoiced`.

## Code Map

Backend (`workspace/core/backend/wms-be`, origin/main):

- **Readers of `rate_card_lines` / `CHARGE_CODES`, and what happens to each (A23):**

  | File | Disposition |
  |---|---|
  | `billing/rate-cards.ts:21-128` | `CHARGE_CODES` / `CHARGE_BASIS` stay the metered four. Add `RATE_CARD_LINE_CODES`, `RATE_CARD_LINE_BASES`, `MINIMUM_COUNTS` and the per-code bounds; `lineProblems` and `sortLines` move to the card-line tuple (the existing four keep their rank) |
  | `billing/billing.facade.ts:38-40,84-99,122-128` | `RateCardLineSnapshot.chargeCode` widens to the card-line code, plus optional `minimumCounts` |
  | `billing/rate-card.command.ts:153,187,434` | inserts carry `minimumCounts`; `activate` gains A21's guard |
  | `billing/metering.ts:258-259` | `rateOf` — **no edit** (G5) |
  | `billing/client-invoices.ts:288` | rank over `INVOICE_LINE_CODES` |
  | `billing/portal-invoices.ts:14` | as above |
  | `billing/invoice-records.ts:64` | `RECORD_KIND_OF_CHARGE` widens |
  | `api/rate-cards.dto.ts:46-98` | widen; `@Max` 1e9 (A12) |
  | `api/client-invoices.dto.ts:145` | widen |
  | `api/portal.dto.ts:671` | widen |
  | `api/billing-usage.dto.ts:10` | **stays** `CHARGE_CODES` |
  | wms-fe `lib/rate-cards.ts:25-60,193,241-249`, `components/settings/rate-cards-card.tsx:192-195,382-391` | below |

- **`billing/client-invoices.ts`:**
  - `:107-115` gaps gain `adhoc-charge-pending` (with `count`) and `minimum-charge-pending`, after `line-unpriced`.
  - `:119` warnings gain `minimum-not-applied-multi-gstin` and `minimum-from-charges-only`.
  - `:222-240` the line's optional keys (A11).
  - `:267-277` the input gains `charges`, `pendingCount`, `minimumSegments`, `minimumCounts` and `footprintGroups`.
  - `:291-303` `compareLines` (decision 11).
  - `:313-521` the compute (decision 10, A19, A21, A26, A27).
  - `:545-580` the hash (conditional keys).
  - `:713-759` `linesOfInTx` (milli for `adhoc`; the optional `description`).
  - `:897-958` prepare (A6; the `:945-951` detail).
  - `:1197-1230` `computeInTx`:
    - charges by `bill_month` and group;
    - `rateCardSegmentsInTx` (`billing.facade.ts:345`) for the minimum terms;
    - the footprint;
    - A5's no-scope rule.
  - `:1320-1346` `insertLinesInTx` (the two columns).
  - `:1060` the issue audit `changes` (A31).
- **`drizzle/0062_client_invoices.sql`:**
  - `:199-216` the four line CHECKs to widen (`charge_code_check` :199, `basis_check` :202, `charge_basis_pair` :205, `uom_basis_pair` :214);
  - `:227-232` `priced` (A9);
  - `:120` the unique to replace;
  - `:264-350` the guard: `:304-308` is the predicate; A8 adds the ad-hoc arms (copied from the live body, A17);
  - `:466-474` the RLS shape (A7).
- **`drizzle/0060_rate_cards.sql`:** `:95-111` the four line CHECKs (A1); the new `rate_card_lines_minimum_counts`.
- **`billing/invoice-records.ts:325-455`:** dispatch before `targetInTx`'s group step (A16). The four existing arms are untouched.
- **Support modules:**
  - `billing/client-wind-down.ts`, `shared/primitives/wind-down.ts:14-28` — the blocker (A15).
  - `tenancy/permissions.ts:245,447` — `billing.charge` (ops_manager and accountant sets).
  - `shared/primitives/audit.ts:44-60,142` — `client_charge`, `client_charge_policy` and the new actions.
  - `invoicing/uqc.ts:23-48` — read-only, for `CHARGE_UNIT_UQC`.
- **Suites that pin today's sets, retargeted to the widened sets with a comment saying so:**
  - `test/rate-cards.spec.ts:391-410`
  - `test/client-invoices.spec.ts:407,489`
  - `test/client-isolation.spec.ts:1032` (121 → 123)
  - `test/architecture.spec.ts` (billing's tables 7 → 9)

Frontend (`workspace/core/frontend/wms-fe`):
- **`lib/rate-cards.ts`:**
  - split `MeteredChargeCode` (the four; `CHARGE_CODES` / `CHARGE_BASIS` / the editor columns) from the widened `ChargeCode` (labels for all seven codes, three new basis labels);
  - an optional minimum plus a counts selector in `RateDraftFields`;
  - `toLines` (:241-249) emits the minimum line with its own bound.
- **`components/settings/rate-cards-card.tsx`:** the minimum column and the input, with decision 9 / A21 copy.
- **`components/settings/client-usage.tsx`:** the "metered charges only" note.
- **`lib/client-invoices.ts:174`:** the description label.
- **`components/compliance/client-invoices.tsx:581`:** print the description; the gap and warning copy; the pending-gap deep link.
- **`components/compliance/line-records.tsx` and `lib/invoice-records.ts`:** the `adhoc-charge` record; no toggle on `minimum_adjustment`.
- **`components/portal/portal-invoices.tsx`:** the description.
- **`lib/page-tabs.ts:118-131`:** the `client-charges` tab.
- **`lib/users.ts:178,273,313`:** the capability mirror.
- **`lib/clients.ts:543`:** the blocker line.

## Tasks & Acceptance

**Execution:**
- [ ] `drizzle/NNNN_contract_billing.sql` (next free at code time; 0089 on main today) + journal + git-added snapshot -- one transaction:
  - (a) `client_charges`, columns per A20, with named CHECKs:
    - `_category` (IN), `_sac_pair` (category → SAC; `other` from the four), `_unit` and `_status` (`pending|approved|rejected|cancelled`);
    - `_figures` (A29), `_bill_month` (A4);
    - `_gstin` (NULL or `^[0-9]{2}[A-Z0-9]{13}$`);
    - `_text`: each text trimmed and within its length — description 1–200, reference / client auth 1–100, evidence 1–500;
    - `_decided` (A2), `_cancelled` (cancelled ⇔ stamp ⇔ by ⇔ note 1–500).

    Indexes, each `IF NOT EXISTS`: `(tenant_id, client_id, bill_month)`, `(tenant_id, created_at, id)`, `(tenant_id, client_id, created_at, id)`.

    `client_charges_guard` (BEFORE INSERT OR UPDATE OR DELETE):
    - an insert is `pending` with no stamp, or `approved` with `decided_by = recorded_by`;
    - updates make only the A14 transitions, with pending → approved requiring `decided_by <> recorded_by`;
    - approved → cancelled is refused per A8;
    - a set decision stamp never changes;
    - `to_jsonb(NEW) - [status, decided_*, decision_note, cancelled_*, cancel_note, updated_at]` equals the same of OLD;
    - no delete.

    Plus `_no_truncate`, and A7's single policy.
  - (b) `client_charge_policies` per A22: its CHECK, unique, policy and `_no_truncate`.
  - (c) `client_invoice_lines`:
    - add the `description` and `adhoc_charge_id` columns;
    - drop and re-add the four CHECKs at 0062:199-216, adding `adhoc/per_unit` and `minimum_adjustment/per_invoice`, with `uom_basis_pair` = `(basis IN ('per_thousand_units_per_day','per_unit')) = (uom IS NOT NULL)`;
    - `priced` per A9;
    - add `_extra_kind`: `(charge_code = 'adhoc') = (adhoc_charge_id IS NOT NULL) AND (charge_code IN ('adhoc','minimum_adjustment')) = (description IS NOT NULL) AND (charge_code <> 'minimum_adjustment' OR quantity = 1)`;
    - `CREATE UNIQUE INDEX IF NOT EXISTS client_invoice_lines_line_key_unique (invoice_id, segment_from, charge_code, coalesce(uom,''), coalesce(adhoc_charge_id::text,''))`, **then** `DROP INDEX IF EXISTS client_invoice_lines_invoice_segment_charge_uom_unique`.
  - (d) `rate_card_lines`: the four CHECKs (A1, A12 bounds) and `rate_card_lines_minimum_counts`.
  - (e) `CREATE OR REPLACE FUNCTION client_invoices_guard()` per A8, A9 and A17.
  - (f) If 5-6a's tables exist on the base: widen its four note-line CHECKs by name, unconditionally (A3).
  - (g) A post-migration DO block (0064 style; no word INDEX; `to_regclass` probes):
    - a refused and an accepted insert per new or widened CHECK, parents inserted inside the sentinel;
    - the guard's `prosrc` assertions.
- [ ] `src/shared/db/schema.ts` -- `clientCharges`, `clientChargePolicies`, the two line columns, the renamed unique, `minimumCounts` -- `db:generate` reports "No schema changes".
- [ ] `src/modules/billing/client-charges.ts` (new) --
  - vocabularies and labels: `CLIENT_CHARGE_CATEGORIES`, `SAC_BY_CATEGORY`, `OTHER_SACS`, `CHARGE_CATEGORY_LABELS`, `CLIENT_CHARGE_UNITS`, `CHARGE_UNIT_UQC`, `CLIENT_CHARGE_STATUSES`;
  - `formatPaiseEnIn` and the description builders (A10);
  - `ClientChargeService.record | approve | reject | cancel | list | get | getPolicy | putPolicy` per A14, A22 and A31;
  - the `bill_month` resolver (A4) and the footprint (A21).
- [ ] `rate-cards.ts`, `rate-card.command.ts`, `billing.facade.ts`, `client-invoices.ts`, `portal-invoices.ts`, `invoice-records.ts`, `client-wind-down.ts`, `billing.module.ts` -- per the Code Map.
- [ ] `src/api/client-charges.controller.ts` + `client-charges.dto.ts` (new) --
  - routes: decision routes, A14, A22;
  - list `?clientId&warehouseId&status&month&cursor&limit` (`month` filters `bill_month`);
  - every POST/PUT takes an `Idempotency-Key`;
  - portal sessions get 403 `role-denied`;
  - nullable enums list `null` (§4).
- [ ] `permissions.ts`, `audit.ts`, `wind-down.ts` -- the capability, the target types, the actions, the blocker.
- [ ] `test/client-charges.spec.ts` (new) --
  - every matrix row, original and amended;
  - every CHECK and guard arm by direct SQL;
  - A7's portal probe;
  - the same-key race and A30's race harness;
  - `expectAuditRow` per action, including the single auto-approve row;
  - the outbox rows;
  - the policy default and the update;
  - A18's golden;
  - the blocker.
- [ ] `test/client-invoices.spec.ts` --
  - minimum: met, short, prorated (the A10 golden description), first card mid-month, `metered` counts, pending (blocking), multi-GSTIN warning;
  - ad-hoc: line order, intra/inter tax, routing across two GSTINs, a late charge on the next open month (true date printed), void → replacement;
  - A5 and A6;
  - the guard's new arms;
  - G1–G3 and A31's audit shape.
- [ ] `test/invoice-records.spec.ts`, `test/rate-cards.spec.ts` (A1, A12, A19, A21, G6), `test/client-isolation.spec.ts` (123), `test/architecture.spec.ts`, the portal suite (the description present on new kinds only; no `adhocChargeId`; no charge route reachable).
- [ ] FE, per the Code Map, plus:
  - `components/compliance/client-charges.tsx` (new): list and filters; the record form (decimal quantity, A26 / A10 warnings shown after the 201); approve/reject/cancel by capability and recorder; the policy editor for `billing.invoice`; copy for every 409;
  - `lib/client-charges.ts` and `lib/use-client-charges.ts`, with tests;
  - `bun run gen:api`.

**Acceptance Criteria:**
- Given a client with no ad-hoc charge and no `minimum_monthly` on any card, when its month is prepared, refreshed, issued, drilled and read in the portal, then G1–G6 hold.
- Given an approved charge on an issued invoice, when it is cancelled (by command or by direct SQL), then it is refused (409 / the guard), and the invoice's lines are unchanged.
- Given a ₹50,000 minimum and ₹31,250.40 of charges, then the draft carries one `minimum_adjustment` line of 1,874,960 paise with the exact template description. Given ₹62,000 of charges, then it carries none and its hash equals the same fixture's hash without the minimum term. Given the two-card month, then the floor is 4,548,387 paise.
- Given an accountant with a ₹10,000 limit who records ₹25,000, then the charge is `pending`; their own approve is 409 `charge-needs-second-approver`, and another holder's approve is 200.
- Given an issued invoice with an `adhoc` line, when the portal reads it, then that line's keys are the 21-7 allowlist plus `description`, and no line carries `adhocChargeId`.
- Given whichever of 5-5a / 5-6a merged second, when its migration runs, then its probes assert that `client_invoice_lines` and `client_invoice_note_lines` both accept every widened pair.

## Implementation Notes

## Spec Change Log

## Review Triage Log

| ID | Verdict | Finding | Outcome |
|---|---|---|---|
| K1 | high | `rate_card_lines_basis_check` (0060:98) not widened | A1 |
| K2 | high | `_decided` CHECK undefined for cancelled shapes | A2 |
| K3 | high | conditional DDL against 5-6a; names unverified | A3 (verified: 5-6a names none) |
| K4 | high | a late charge has no billable month | A4 |
| K5 | medium | charge-only client with no events never storage-complete | A5 |
| K6 | medium | pending-only month leaves no draft to block | A6 |
| K7 | high | charges readable by the portal under the read-scoped shape | A7 |
| K8 | high | DB lets an invoiced charge be cancelled; guard ignores the charge state | A8 |
| K9 | high | `priced` CHECK not written; NULL arms | A9 |
| K10 | medium | description, labels and UQC unstated; window too wide | A10 |
| K11 | medium | `null` keys break G2 | A11 |
| K12 | medium | DTO `@Max` refuses minimums above ₹1 lakh | A12 |
| K13 | low | "Ops records" row skipped the stale step | A13 |
| K14 | high | transitions, codes and guard order unspecified | A14 |
| K15 | medium | blocker by month, not by link | A15 |
| K16 | medium | portal sort id, drill dispatch, quantity units | A16 |
| K17 | medium | probes without parents; guard copy source | A17 |
| K18 | — | not relayed in the review digest | no action (resend if it carries a finding) |
| K19 | medium | `"2.5"` vs `"2.50"` hash drift | A18 |
| K20 | medium | minimum-only card, credits, counting base | A19 |
| K21 | medium | columns implicit; auto-approve audit shape | A20 |
| K22 | — | not relayed in the review digest | no action (resend if it carries a finding) |
| B1 | high | per-invoice minimum double-bills a multi-GSTIN client | A21 — **partly**: activation refuses; at compute a warning, not the requested blocking gap (a frozen past month would be unissuable for good) |
| B2 | high | no maker-checker above a limit | A22 |
| B3 | high | = K4 | A4 |
| B4 | high | a charge regrouped or billed twice | A8 |
| B5 | medium | guard copied from a possibly superseded body | A17 |
| B6 | medium | readers of the widened vocabularies unlisted | A23 |
| B7 | low | no client authorisation reference; no portal view | A24; portal view and attachments deferred |
| B8 | high | = K7 | A7 |
| B9 | medium | = K20 | A19 |
| B10 | medium | proration ignores the client's start/end | A25 (no such dates on main; PENDING) |
| B11 | medium | a charge silently brings a minimum | A26 |
| B12 | medium | = K20 | A19 |
| B13 | medium | `minimum-charge-pending` non-blocking | A27 |
| B14 | low | recorder cannot withdraw; no pending signal | A28; notification consumer deferred |
| B15 | medium | = K14 (suspended client) | A14 |
| B16 | medium | = K14 (warehouse–client) | A14 (verified: no link on main) |
| B17 | low | = K14 (replay, filters) | A14 |
| B18 | medium | = K10 | A10 |
| B19 | medium | bigint overflow and casts | A29 |
| B20 | high | = K3 | A3 |
| B21 | medium | G4/G5 vague; no race harness; ACs thin | A30 + ACs |
| B22 | low | charge → invoice link not visible | A31 |

## Design Notes

**Why the guard must change.** 0062's issue arm refuses any line whose `rate_card_id` is null (`:304-308`).
- An ad-hoc charge has no card: a client with no card can still owe for extra labour.
- A minimum spans card segments, so it has no single card either.
- Pointing either kind of line at a card would claim that card priced it.

So the null-card refusal narrows to the four metered codes, and A8 adds the ad-hoc arms. The rest of the body is copied from the live definition (A17).

**Why lines, not a side table.** Several rules already key on `client_invoice_lines`:
- the guard's rule that the header equals Σ of the lines (`:315-324`);
- 5-6a's credit cap, which works per invoice line;
- the drill's line address;
- the portal.

A side table would mean rewriting every one of them.

**Golden recipe.** Before editing anything, run the existing `client-invoices.spec` fixture on the merge base. Print `contentHash`, the canonical JSON and the `GET` / portal bodies, then commit them as literals in the new test.

**Proration, worked.** A ₹40,000 minimum applies for 14 days and a ₹50,000 minimum for 17 days of a 31-day month:

```
(4,000,000 × 14 + 5,000,000 × 17) / 31 = 141,000,000 / 31 = 4,548,387.09 → 4,548,387
```

**PENDING at doc time.**
- Tiers stay open; they move to 5-5b.
- The "minimum charges" clause closes.
- New entries:
  - CA check (A10);
  - client-wide minimum and dormant-month minimum;
  - the minimum ignores client start and departure (A25);
  - the charge notification consumer;
  - the `bill_month` drill note: a line's date may precede its period.

## Verification

**Commands:**
- `bun run db:generate` -- expected: "No schema changes"; `git status --short` shows no untracked files.
- `bun run test -- test/client-charges.spec.ts`, then `client-invoices`, `invoice-records`, `rate-cards`, `client-isolation`, `architecture`, `migrate-deploy` -- one jest invocation at a time; expected: green, with G1–G6 and the race harness.
- `git diff <base> -- src/modules/billing/metering.ts src/modules/inbound/inbound.facade.ts src/modules/outbound/outbound.facade.ts src/modules/inventory/client-metering.ts` -- expected: empty.
- wms-fe: `bun run gen:api && bun run typecheck && bun run test && bun run lint` -- expected: green. The drift guard stays red until the backend merges; that is expected.
