---
title: 'Client invoices — monthly services tax invoices to a client brand, frozen at issue'
type: 'feature'
created: '2026-10-07'
status: 'ready-for-dev'
route: 'dispatch'
baseline_commit: 'dba77cc6aa49eff7759311a86a244aec5441ce43'
review_loop_iteration: 0
context:
  - '_bmad-output/implementation-artifacts/epic-21-context.md'
  - '_bmad-output/specs/spec-3pl/SPEC.md'
  - '_bmad-output/specs/spec-3pl/schema.md'
  - '_bmad-output/specs/spec-3pl/billing-model.md'
  - '_bmad-output/specs/spec-3pl/architecture.md'
  - '_bmad-output/implementation-artifacts/spec-21-4-metering-and-storage-snapshots.md'
  - 'docs/design/SYSTEM-DESIGN.md'
  - 'docs/design/IMPLEMENTATION-GUIDE.md'
  - 'docs/design/API-SURFACE.md'
  - 'docs/design/modules/billing.md'
  - 'docs/design/modules/clients.md'
  - 'docs/design/modules/invoicing.md'
  - 'docs/design/frontend/SYSTEM-DESIGN.md'
  - 'docs/design/frontend/IMPLEMENTATION-GUIDE.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** 21-4 measures each client brand's billable usage, but the 3PL cannot yet bill for it. CAP-7 and FR-78 require a period invoice for each client. Once issued, that invoice must never change, even if rates or data change later.

**Approach:** Billing gains **client invoices**.
- An operator **prepares drafts** for a client and a past calendar month, using the 21-4 metering read.
- They review the gaps and **issue** the invoice.
- An issued invoice is a frozen **services (SAC) GST tax invoice**, numbered in its own series. It can later be marked disputed or settled, or voided and replaced.
- Clients gain the tax details an invoice needs.
- The web gets a **Client invoices** section and a printable invoice.

**Decisions (human, 2026-10-07):**
1. **Split.**
   - This story: client tax details; draft → issue → dispute / settle / void; the printable invoice.
   - **21-5b:** the drill-down from a line to its source records.
   - **Epic-8 retro A5:** its own refactor story (`deferred-work.md`).
2. **One invoice per client, per month, per supplying GSTIN.** The supplying GSTIN is the warehouse's GSTIN, or else the tenant's. Each registration invoices the work done in its warehouses.
3. **An own series per supplying GSTIN per FY** (`29/S2627/000001`). It never interleaves with goods invoices.
4. **Fixed SAC codes and GST rate, frozen onto each line.**
   - Storage: `996729`.
   - Inbound handling, pick and outbound handling: `996719`.
   - All lines at 18% (1,800 bps).
   - A per-tenant override goes to PENDING.
5. **Place of supply = IGST Act s.12(2), the B2B general rule**: the client GSTIN's state, or else its billing state. It is stored **per line** (`place_of_supply`, `supply_type`). If storage is later ruled s.12(3) (immovable property → the warehouse's state), that is a rule change, not a schema change. A CA check is in PENDING.
6. **Supplier address** = the `origin_*` address of the group's warehouse that owns the GSTIN. For the tenant-GSTIN group, it is the lowest-code warehouse in the group with a full address. The printed supplier name is the tenant's name.

## Boundaries & Constraints

**Always:**

- **Period:** one IST calendar month, from the 1st to the last day. Prepare is refused for a month that has not ended (409 `period-not-ended`). The `self` client is refused (409 `client-not-billable`). The client must be in the tenant (404).
- **Groups:**
  - Every tenant warehouse goes into exactly one group, keyed by `warehouses.gstin ?? tenants.gstin` (null allowed).
  - Each group is metered over **all** of its warehouses through 21-4's `meterPeriodInTx`, using a new warehouse filter. The filter is applied to the storage sum and to the three count predicates. The order count's "no earlier dispatch" subquery stays unfiltered.
  - Groups whose lines all have quantity 0 get no draft.
  - A test pins that the sum over groups equals the unfiltered meter, for every charge.
- **Prepare** (`POST …/clients/{c}/invoices {month}`):
  - Under `lockClientInTx`, it creates drafts **only for groups that have usage and no live invoice**.
  - It returns `{created[], existing[]}` and refuses with 409 `nothing-to-invoice` only when no group has usage.
  - A draft for a group with a voided invoice sets `replaces_invoice_id` to the latest void for that group that nothing has replaced yet.
- **Lines:** one line per metered `(segment, charge, uom)` with quantity > 0.
  - `quantity` is a bigint. For storage it is milli-unit-days, and the CHECK pairs `uom` and storage `basis`. Otherwise it is a count.
  - Each line also stores: `rate_card_id`, `segment_from`, `segment_to`, `charge_code`, `basis`, `uom`, `unit_amount_paise`, `amount_paise` (the taxable value), `sac_code`, `gst_bps`, `place_of_supply`, `supply_type`, `cgst_paise`, `sgst_paise`, `igst_paise`.
  - `rate_card_id`, `unit_amount_paise` and `amount_paise` are nullable on a draft only. The trigger refuses issue while any of them is null.
- **Tax:**
  - Computed per line by `computeLineTax(1000, amount, 1800, supplyType)`, half-up, with the odd paisa going to SGST.
  - Supply is intra-state when the supplier GSTIN's state equals the place of supply.
  - Totals: `subtotal + tax = total`, `cgst + sgst + igst = tax`, `payable = total + round_off`, `payable % 100 = 0`, and `round_off ∈ [−49, 50]`. These are pinned by CHECKs (the 0054 precedent).
- **Gaps** each have the shape `{code, detail, warehouseId?, segmentFrom?}`. Any gap refuses issue (409 `invoice-has-gaps`, naming the gaps). The codes:
  - `supplier-gstin-missing`
  - `supplier-address-missing`
  - `client-legal-name-missing`
  - `client-billing-address-missing` (line 1, city, state code, pincode)
  - `storage-not-complete` — the client's `storageCompleteThrough` is short of `period_end`; this also proves the counts complete. When it fires, storage lines raise no `line-unpriced`.
  - `line-unpriced`
  - `einvoice-required` — the GSTIN's `eInvoiceApplies` is set and the client has a GSTIN. The read goes through `InvoicingFacade`; IRN is out of scope.
- **Warnings** do not block issue. Shape `{code, detail}`:
  - `supplier-state-differs` — a warehouse's origin state is not the GSTIN's state.
- **The content hash** is sha256 over canonical JSON of everything the issued row would store, excluding ids, timestamps, status and lifecycle fields. Bigints are encoded as decimal strings, keys are sorted, lines are ordered by `(segment_from, charge_code, uom)`, and the JSON carries `"v":1`.
- **Issue order:**
  1. lock the client;
  2. lock the draft and check that its status is `draft`;
  3. re-meter, and recompute gaps and the hash;
  4. if the hash differs, store the fresh draft, **commit**, and return **200 `{outcome:'stale', invoice}`**. The response is recorded under the Idempotency-Key; the FE uses a new key per click;
  5. if gaps remain, return 409;
  6. allocate the number: a `client_invoice_series (tenant, supplier_gstin, fy_label)` row is inserted `ON CONFLICT`, then taken `FOR UPDATE`. The series is gap-free and resets each FY. `fy_label = fyLabelFor(issued_at)`, so a March period issued in April takes the next FY;
  7. stamp `issued_at` and `issued_by`, snapshot the `party` (supplier name, GSTIN, address and state; client legal name, GSTIN, billing address and state), write the audit row, and write the key last.

  No number is ever allocated on a refused issue. The number format is `formatServiceInvoiceNo` → `<gstin[0..2]>/S<fy digits>/<seq6>`, asserted ≤ 16 characters.
- **Refresh, discard and transitions** lock the row and re-check its status. Refresh and discard are draft-only (409 `invoice-not-draft`). Discard deletes the draft's lines and then its row.
- **Allowed transitions:** `issued → disputed | settled | void` and `disputed → settled | void`. Any other is 409 `invoice-transition-invalid`. Dispute and void require a note. `status_note` keeps the latest note; the audit trail keeps every one. A void stays numbered.
- **Database guard** (`client_invoices_guard`, after 0060's `rate_cards_guard`):
  - it refuses any change to a non-draft row except the allowed status transition with its note and stamps;
  - it refuses a return to `draft`, an issue without `invoice_no`, `supplier_gstin` and `issued_at`, and a DELETE of a non-draft row;
  - a lines trigger requires the parent to be a draft (taken `FOR SHARE`) with a matching tenant;
  - neither table can be truncated.
- **One live invoice per group:** a unique partial index on `(tenant, client, period_start, coalesce(supplier_gstin, ''))` where status ≠ `void`. A 23505 violation maps to 409 `invoice-exists`.
- **RLS:** a tenant policy, plus the AD-24 client read clause **with `status <> 'draft'`**, so a portal never sees drafts. The lines table inherits through the parent.
- **Capability `billing.invoice`** (owner and accountant; excluded from ops) gates prepare, refresh, discard, issue, the transitions **and the client tax-details write**. Reads are member-open; portal sessions are refused 403.
- **Client tax details** are nullable `clients` columns:
  - `legal_name`, `gstin`;
  - `billing_line1`, `billing_line2`, `billing_city`;
  - `billing_state_code` (a 2-digit code from `GSTIN_STATE_CODES`);
  - `billing_pincode` (6 digits).

  Each is shape-checked when present. A GSTIN whose prefix differs from `billing_state_code` is refused (400). They are never required at client create. The invoice prints its frozen `party`, never the live client.
- **Facades only** (AD-6). The pure helpers move to `shared/primitives/gst.ts`, re-exported by invoicing unchanged.

**Never:**
- the drill-down (21-5b);
- A5;
- per-tenant SAC or rate overrides;
- IRN or e-invoicing;
- credit or debit notes;
- payment collection;
- partial-month invoices;
- portal reads (21-7);
- PDF;
- invoicing `self`;
- any change to goods invoicing.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected | Error |
|---|---|---|---|
| Single GSTIN | ACME in WH1 and WH2 on the tenant GSTIN `29…` | One draft | — |
| Two registrations | WH3 has GSTIN `27…` | Two drafts, each metered over its own warehouses; the sum over groups equals the unfiltered meter | — |
| Partial prepare | Group 29 issued; group 27 has new usage | `created:[27]`, `existing:[29]` | — |
| Card change mid-month | — | Two lines per charge, each with its own `rate_card_id` | — |
| Intra / inter | Supplier `29`, client `29…` / unregistered client with billing state `27` | CGST + SGST at 9% each / IGST at 18% | — |
| Month not ended | October, prepared on the 20th | — | 409 `period-not-ended` |
| Storage incomplete | Snapshot for the 30th not yet written | Draft carries a gap | 409 `invoice-has-gaps` on issue |
| E-invoicing GSTIN | Flag set, client has a GSTIN | Gap `einvoice-required` | 409 on issue |
| Issue | No gaps, hash matches | `29/S2627/000001`; payable rounded to the rupee | — |
| Stale | A GRN line arrives late | 200 `{outcome:'stale'}`, fresh draft stored, no number used | — |
| Rate change after issue | — | Read-back identical | — |
| Void and replace | — | Void keeps its number; the next prepare sets `replaces_invoice_id` | — |
| Illegal transition | `settled → disputed`; editing an issued line; deleting an issued row | — | 409 `invoice-transition-invalid`; the trigger refuses |
| `self` / portal | — | — | 409 `client-not-billable` / 403 |
| Tax-details errors | Malformed GSTIN; state code `99`; GSTIN `29…` with state `27` | — | 400 `validation-failed` |

</frozen-after-approval>

## Code Map

- **Metering:** `billing/metering.ts:154` `meterPeriodInTx`. Add `warehouseIds?` and thread it through:
  - the storage scopes and sum (`:186-210`);
  - `countReceiptLinesInTx` (`inbound.facade.ts:325`, `grn.warehouse_id`, `schema.ts:1656`);
  - `countPicksInTx` (`outbound.facade.ts:1180`, `p.warehouse_id`, `:2320`);
  - `countDispatchedOrdersInTx` (`inventory.facade.ts:1229`; `client-metering.ts:166-183` — filter the outer events only).

  The predicates take an optional list. With no list, behaviour is byte-identical, and the 21-4 suite proves it.
- **Helpers moving to `shared/primitives/gst.ts`:**
  - `computeLineTax` (`invoicing/arith.ts:97`); `taxable = amount` at `qtyMilli` 1000 (`:133`);
  - `roundToRupee` (`:210`), `assertInvoiceTotals` (`:160`), `asGstBps`;
  - `fyLabelFor` (`generator.ts:201`).

  Add `formatServiceInvoiceNo` beside them, a sibling of `formatInvoiceNo` (`:227`).
- **Series precedent:** `generator.ts:260-282`. Totals CHECK precedent: `drizzle/0054_*`. Trigger precedent: `drizzle/0060_*:129-241`.
- **Parties:**
  - `tenancy.service.ts:165-182`: tenant name and GSTIN, and the warehouse GSTIN plus the `origin_*` columns (`schema.ts:202-228`). Expose a tenancy facade read listing the warehouses with GSTIN, code and origin address.
  - E-invoice flag: the `InvoicingFacade` GSTIN settings read (`facade.ts:~202`).
- **Clients:** table at `schema.ts:136-158`; `clients.command.ts` `rename` (`:112`) is the command and audit precedent; `clients.facade.ts` `lockClientInTx` (`:107`); `shared/primitives/gstin.ts`.
- **Command skeleton:** `invoicing/command.ts:82-216`.
- **Capabilities:** `tenancy/permissions.ts:197-243` (accountant at `:331`).
- **Architecture:** `test/architecture.spec.ts:1524` `BILLING_TABLES`, plus the isolation-probe count.
- **Next migration:** **0062**.
- **Web:**
  - `app/(app)/compliance/page.tsx`;
  - `components/compliance/invoices.tsx`: list, `expandedRowId`, `PrintableInvoice` (`:319`, `data-print-root`), the `documentHeading` DRAFT precedent;
  - `lib/invoices.ts`: `formatRupees`, `amountInWords`, `invoiceDateLabel`;
  - per-draft key: `rate-cards-card.tsx:314-370`;
  - client picker: `:98-145`;
  - `clients-card.tsx`;
  - `lib/users.ts` (`OPS_EXCLUDED_CAPABILITIES` `:199`);
  - `lib/usage.ts:23` `ESTIMATE_NOTICE`.

### API (all under `/tenants/{t}`; every POST and DELETE takes an `Idempotency-Key`)

| Route | Success | Errors |
|---|---|---|
| `PATCH clients/{c}/tax-details` | 200 client view | 400, 403, 404 |
| `POST clients/{c}/invoices {month:'YYYY-MM'}` | 201 `{created, existing}` | 400, 403, 404, 409 `period-not-ended` / `client-not-billable` / `nothing-to-invoice` |
| `GET client-invoices?clientId&status&cursor&limit` | 200 page, keyset `(createdAt, id)`, limit 1–100 | 400 `invalid-cursor`, 403 |
| `GET client-invoices/{id}` | 200 invoice | 403, 404 |
| `POST …/{id}/refresh` | 200 invoice | 409 `invoice-not-draft` |
| `DELETE …/{id}` | 204 | 409 `invoice-not-draft` |
| `POST …/{id}/issue` | 200 `{outcome: 'issued' \| 'stale', invoice}` | 409 `invoice-has-gaps` / `invoice-not-draft` |
| `POST …/{id}/dispute`, `/settle`, `/void` `{note}` | 200 invoice | 400 (note required), 409 `invoice-transition-invalid` |

The **invoice DTO** carries:
- identity and status: `id, clientId, periodStart, periodEnd, status`;
- numbering: `invoiceNo, fyLabel, supplierGstin`;
- tax: `placeOfSupply, supplyType`;
- `gaps[]`, `warnings[]`, `party`, `lines[]`, `totals{subtotal, cgst, sgst, igst, tax, roundOff, payable}` (paise as numbers);
- lifecycle: `issuedAt, statusNote, replacesInvoiceId, createdAt`.

Each **line** carries `quantity` (a decimal string, base-unit-days for storage, as in 21-4), the rate, amount and tax fields, `sac`, and `placeOfSupply`.

## Tasks & Acceptance

**Execution:**
- [ ] `wms-be/drizzle/0062_client_invoices.sql` (with journal, snapshot and `schema.ts`). Guarded, with no FKs:
  - the `clients` columns and their CHECKs;
  - `client_invoices`, `client_invoice_lines` and `client_invoice_series`, with the columns, CHECKs (status, totals, period starts on the 1st, basis/uom pairing, a non-draft row requires its number) and indexes from Boundaries;
  - the guard, lines and no-truncate triggers;
  - RLS with the draft-hidden client clause;
  - a post-migration assertion.
- [ ] `wms-be/src/shared/primitives/gst.ts` -- the moved helpers and `formatServiceInvoiceNo`.
- [ ] `wms-be` metering, inbound, outbound and inventory -- the warehouse filter.
- [ ] `wms-be` tenancy facade -- the party read.
- [ ] `wms-be/src/modules/clients` -- `updateTaxDetails` (audit `client.tax-details-updated`).
- [ ] `wms-be/src/modules/billing/client-invoices.ts` -- the commands, plus a pure `computeClientInvoiceDraft` (lines, tax, totals, gaps, warnings, hash).
- [ ] `wms-be/src/modules/tenancy/permissions.ts` -- `billing.invoice`.
- [ ] `wms-be/src/api/client-invoices.controller.ts` -- with its DTOs; then re-export `openapi.json`.
- [ ] `wms-be` architecture and isolation tests -- `BILLING_TABLES` and the probe count.
- [ ] `wms-be/test/client-invoices.spec.ts`. Cover:
  - every matrix row;
  - every legal and illegal transition at the trigger;
  - the group-sum equality;
  - a series race (consecutive numbers, no gap);
  - the FY boundary;
  - staleness with no number consumed;
  - the hash being stable across reads;
  - the 0062 migration;
  - the vocabulary pinned against the CHECK.
- [ ] `wms-fe`:
  - **Capability mirror:** add `billing.invoice` to the owner and accountant, and to the ops-excluded list; the count goes from 38 to 39; add a holder test.
  - **Tax details:** a form on the clients card (state select over the codes), editable under `billing.invoice`.
  - **`ClientInvoices` on `/compliance`:** client and month pickers; Prepare; a list of status, number, client, month, supplier GSTIN and payable; an expanded detail showing lines, gaps and warnings, with the actions Refresh, Issue (stale → banner "Figures changed — review and issue again"), Discard, Dispute, Settle, and Void (note, plus the warning "if already reported in GSTR-1, a credit note is the correct fix — not supported yet").
  - **`PrintableClientInvoice`** prints from `party`:
    - a "Tax Invoice" heading ("DRAFT — not a tax invoice" on a draft);
    - the supplier's name, address, GSTIN and state, and the recipient's legal name, address, GSTIN and state;
    - the invoice number and date, and the place of supply as name and code;
    - "Reverse charge: No";
    - per line: description (charge label and segment dates), SAC, quantity (base-unit-days, "per 1,000 units/day" for storage), rate, taxable value, rate %, and CGST, SGST/UTGST or IGST;
    - totals, round-off, the amount in words, and an "Authorised signatory" block.
  - **Usage preview:** an invoiced month shows "Invoiced as <no.>" with a note that live figures may differ.
  - **Code:** mappers and hooks, with tests.
- [ ] Meta docs:
  - `billing.md`, `clients.md`, `invoicing.md`;
  - `frontend/SYSTEM-DESIGN.md:53` (the `/compliance` row);
  - amend the 3PL `schema.md` (nullable draft columns, per-line place of supply, payable, series table) and `billing-model.md` (adds `disputed → void`; drafts are hidden from the portal);
  - `API-SURFACE.md` (the capability count goes to 39) and both contracts;
  - `PENDING.md`:
    - close `:95`, `:110` (billing ignores client status, recorded), `:112`, and `:114` (a no-events client is `nothing-to-invoice`);
    - retarget `:111` to 21-5b;
    - add: SAC/rate override; credit notes; void after GSTR-1 filing; the s.12(3) CA check; the GSTR-1 Table 13 S-series; IRN for client invoices; the 21-7 portal DTO; status-note history.

**Acceptance Criteria:**
- Given ACME's September usage, a card in force, complete snapshots and full tax details, when it is prepared and issued:
  - the invoice reconciles per line and in total;
  - it is numbered `…/S2627/000001`;
  - it prints every Rule 46 field;
  - it reads back identically after a rate change and after new events.
- Given the full BE and FE suites, when they are run, they pass.

## Implementation Notes

- **Baselines:**
  - wms-be `dba77cc6aa49eff7759311a86a244aec5441ce43` (`baseline_commit`);
  - wms-fe `fa6c61974ffa8645202313a51d37d3ecd3e79a7a`.
- **Branches:** `feat/21-5-client-invoices` in both repos. Leave the work uncommitted: no commit, push or PR.
- **wms-be tests:** run `bun run test -- <file>`. Never run two jest invocations at once.
- **Meta docs:** edit in `/Users/sasidhar/Documents/WMS-Meta`.
- **`/tmp`:** don't touch anything there outside your own scratch files.

## Spec Change Log

## Review Triage Log

*Design review, 2026-10-07: two code-verified reviewers (data/tax/concurrency; API/FE/fit). 29 findings were merged into 22. Two went to the human as decisions 5 and 6; the rest are folded in.*

| # | Sev | Finding | Disposition |
|---|---|---|---|
| 1 | high | Issue allocated the number before the hash check, and the stale 409 couldn't store anything | Fixed order; stale returns 200 and commits; no number used |
| 2 | high | Groups built only from warehouses with events could skip usage | All warehouses grouped; group-sum test |
| 3 | high | Prepare against an existing draft or issued invoice was undefined | Per group: `{created, existing}`; client lock; 23505 → 409 |
| 4 | high | A CHECK can't enforce transitions | Guard, lines and no-truncate triggers (0060 precedent) |
| 5 | high | No source for the supplier address (Rule 46) | Decision 6; `supplier-address-missing` |
| 6 | high | Storage place of supply under s.12(3) | Decision 5; per-line place of supply |
| 7 | high | The accountant couldn't fix tax-detail gaps | Tax details gated by `billing.invoice` |
| 8 | med | schema.md declared NOT NULL columns that drafts need empty | Nullable on drafts; the trigger refuses issue while null; schema.md amended |
| 9 | med | Totals contract ambiguous; no payable | Payable column plus the 0054-style CHECKs |
| 10 | med | E-invoicing flag ignored | `einvoice-required` gap |
| 11 | med | Printable invoice under-specified | Full Rule 46 field list; printed from the `party` snapshot |
| 12 | med | Hash inputs underspecified | Canonical v1 definition |
| 13 | med | Refresh, discard and transitions ran without row locks; ambiguous void replacement | Lock and re-check; latest unreplaced void |
| 14 | med | Drafts visible to the portal through the AD-24 clause | Client clause adds `status <> 'draft'` |
| 15 | med | Response DTOs, paging and error arms unspecified | API table and DTO in the Code Map |
| 16 | med | GSTIN and billing state could disagree | 400 at write |
| 17 | med | Usage preview still read "Estimate" after invoicing | "Invoiced as …" |
| 18 | med | Capability naming and mirror wiring | `billing.invoice`; ops-excluded; count 39 |
| 19 | med | PENDING closures partly wrong (`:111` drill-down) | Retargeted to 21-5b; `:114` closed explicitly |
| 20 | low | FY rule implicit; no S formatter | `fyLabelFor(issued_at)`; `formatServiceInvoiceNo` |
| 21 | low | One quantity column, two units; order-count subquery | basis/uom CHECK, print units; outer filter only |
| 22 | low | Loose ends: `period-not-ended` as a gap, double gaps, notes, deletes, docs row, cross-state warehouse, void after GSTR-1 | 409 only; storage-gap precedence; audit keeps notes; trigger refuses deletes; FE route row; `supplier-state-differs` warning; void warning plus PENDING |

## Design Notes

- **Why per supplying GSTIN.** Each registration must invoice its own supplies, and a single-GSTIN tenant still issues one invoice per client per month.
- **Why stale commits.** The operator approves the figures they saw. When those figures move, the fresh draft is stored and shown, nothing is issued, and no number is spent.
- **Why the place of supply is per line.** The storage s.12(3) question is unsettled. Keeping the place of supply per line means a later ruling changes the rule, not the schema.

## Verification

**Commands:**
- `bun run lint && bun run typecheck && bun run build && bun run db:generate && bun run test` (wms-be) -- expected: green, and "No schema changes".
- `bun run lint && bun run test && bun run typecheck && bun run check:capability-mirror && bun run build` (wms-fe) -- expected: green.
