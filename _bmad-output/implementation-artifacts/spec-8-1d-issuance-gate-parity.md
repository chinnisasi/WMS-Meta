---
title: 'Issuance-gate parity — validate GST data at entry, warn at issue, buyer legal name'
type: 'feature'
created: '2026-10-05'
status: 'done'
route: 'dispatch'
baseline_commit: 'f0423a325fca021a30b2989d9388647eb45cf42b'
review_loop_iteration: 0
context:
  - '_bmad-output/implementation-artifacts/epic-8-context.md'
  - '_bmad-output/implementation-artifacts/epic-8-retro-2026-10-05.md'
  - 'docs/design/SYSTEM-DESIGN.md'
  - 'docs/design/IMPLEMENTATION-GUIDE.md'
  - 'docs/design/modules/invoicing.md'
  - 'docs/design/modules/outbound.md'
  - 'docs/design/modules/tenancy.md'
  - 'docs/design/frontend/SYSTEM-DESIGN.md'
  - 'docs/design/frontend/IMPLEMENTATION-GUIDE.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** Invoices issue under looser rules than the HSN summary and e-way bills later apply (epic-8 retro S1–S5, S7–S9). The cases:
- a malformed HSN;
- address state text that is not on the official list;
- a GSTIN whose state prefix is not a registration state;
- a warehouse whose state differs from its GSTIN's;
- a rate the GST rate master doesn't accept.

All of them issue silently. Because issued invoices are frozen, they then stay flagged in the HSN summary or permanently blocked for e-way. B2B documents also name the delivery contact person as the buyer.

**Approach:** Catch bad data where it enters, and make the remaining risks visible when the invoice issues, before filing time.

**Decisions (human, 2026-10-05, epic-8 retro A1/A2):**
1. **Validate at the source.** A GSTIN whose two-digit prefix is not a registration state code is refused (400) at registration, warehouse create and order create, on the backend and the web. On the web, the address **State** input becomes a select over the official list.
2. **Warn at issue, never block.** Issuance gains non-blocking warnings:
   - a malformed HSN;
   - a state that isn't recognised, as two kinds: the address text is off the list, or the stored GSTIN prefix is off the list;
   - the existing `pos-discrepancy`, whose detail now names the e-way consequence.

   Existing data stays issuable.
3. **Buyer legal name.** An optional buyer legal / trade name on orders, offered when a buyer GSTIN is entered. It is printed as the invoice's buyer, and so becomes the e-way `toTrdName`; it falls back to the contact name.
4. **The HSN summary flags rates outside the GST rate master**, as e-way does for NIC's list. Flagged rows stay in the totals and are left out of the CSV.
5. **E-way web fixes:** stop the refetch storm on invoice changes, and make the `needs-irn` hint follow whether the viewer can change the flag.

## Boundaries & Constraints

**Always:**
- **Registration state codes** are `01–24, 26, 27, 29–38, 97`: the official GST state codes, excluding 25 (Daman & Diu, merged into 26 in 2020), 28 (pre-GST Andhra Pradesh) and 99 (Centre Jurisdiction / OIDAR, which never ships goods). This is one pure constant on each side, pinned by a test against `gst_state_codes` minus 99. The same predicate is used at entry and at issue.
- **One HSN normaliser and one rule:**
  - normalise: trim spaces only, and `''` → null;
  - valid: `^[0-9]{4}([0-9]{2}){0,2}$`;
  - shared by the generator, the HSN summary and e-way.
- **Blank, invalid and valid HSNs are exclusive.** A null HSN is `hsn-gap`, as today. A non-null value that is whitespace-only or malformed is `hsn-invalid`. `hsn_gap` keeps its meaning (null only).
- **The legal name joins the order's request hash and its channel source hash only when present.** It is normalised (trimmed, blank = absent) before hashing, so every request without it keeps today's hashes. This is a deliberate exception to the always-present-key convention, recorded in the guide.
- **Refusals run behind the replay lookup, never in DTO validators:** the prefix check, a legal name without a GSTIN, and a legal name over 100 code points.
- **New warnings never block** and never change the document shape.
- **Awaiting invoices are re-derived once.** An awaiting invoice whose re-derive now yields new or changed warnings bumps its revision once (`documentsEqual` includes gap details). Issued invoices never change.

**Never:**
- refusing free-text address **states** on the backend (channel and API orders);
- refusing a warehouse whose GSTIN state differs from its address state (the web warns inline; issuance warns);
- full GSTIN anatomy or checksum validation;
- rewriting issued invoices or backfilling or rejecting stored GSTINs;
- changing e-way blockers or NIC's rate list;
- editing GSTINs after creation;
- exposing the legal name on the order view (only the invoice facts read it).

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected | Error |
|---|---|---|---|
| Bad prefix at register, warehouse or order create | `92…`, `25…`, `28…`, `99…` | Refused | 400 `validation-failed` naming the prefix |
| Valid prefix | `29…`, `97…` | Accepted | — |
| Malformed HSN | `HSN 0910` | Issues, with `hsn-invalid` on that line | — |
| Whitespace-only HSN | `'   '` | Issues, with `hsn-invalid` (not `hsn-gap`) | — |
| Padded valid HSN | `' 0910 '` | No warning | — |
| Null HSN | `null` | `hsn-gap` only | — |
| State text off the list, GSTIN resolves | Consignee `29…`, state `Tamilnadu` | Issues, with `state-text-unknown` (destination) | — |
| Stored GSTIN with a bad prefix (legacy) | Warehouse GSTIN `92…` or `99…`, valid origin state | Resolves from the address text, issues with `gstin-prefix-unknown` (origin) | — |
| Dispatch-from mismatch | Warehouse has no GSTIN, tenant `27…`, origin Karnataka | `pos-discrepancy` (origin) whose detail names the e-way `ship-to-differs` block, if an e-way bill is required | — |
| Awaiting invoice saved before 8-1d | Re-derived twice | First re-derive bumps the revision; the second is a no-op | — |
| Legal name with GSTIN | `consigneeLegalName: "Mysore Spices Pvt Ltd"` | Invoice buyer and e-way `toTrdName` = the legal name | — |
| Legal name without GSTIN, or over 100 code points | — | — | 400 `validation-failed` |
| No legal name | Any order | Buyer = contact name; both hashes unchanged (golden) | — |
| HSN row at 12.5 % | 1250 bps | `rateIssue`, in totals, left out of the CSV, counted once in the shortfall | — |
| HSN row at 0.1 / 1.5 / 7.5 % | 10 / 150 / 750 bps | Accepted | — |

</frozen-after-approval>

## Code Map

- `wms-be/src/shared/primitives/gstin.ts`: `GSTIN_RE` and the lenient `normalizeGstinInput`. Add `GSTIN_STATE_CODES` (pure, sorted) and `isGstinStateCode(code)`, and correct the false comment ("validated in full by the 8-2 regulatory pass"). The callers:
  - `tenancy.service.ts:240 normalizeGstin` is **synchronous**, takes no DB handle, and also serves seed and adapter paths. Put the prefix check inside it.
  - Registration calls it outside any transaction (`registration.command.ts:93-106`).
  - Warehouse create (`warehouse.command.ts:139`).
  - Order create, with its own check at `order.command.ts:377`, behind the replay lookup.
- `wms-be/src/modules/outbound/order.command.ts:325-380`: two hashes are built there, `payloadHash` (idempotency) and `sourcePayloadHash` (channel dedup, compared at `:494`, `:1196`). `consigneeGstin` is in both. `hashCommandPayload` is `JSON.stringify` (`idempotency-guard.ts:55`), so an `undefined` key drops out. Also `outbound.dto.ts:148` and `outbound.facade.ts:177-182` (`OrderInvoiceFacts`); `schema.ts:~1899` (the `orders` destination columns). The next migration is **0057**.
- `wms-be/src/modules/invoicing/generator.ts`:
  - `GAP_KINDS`, `BLOCKING_GAP_KINDS` and their doc comment (:53-66);
  - `codeByGstinPrefix` (:502-505) is built from **every** row, 99 included. Filter it with `isGstinStateCode`, so a legacy 99 GSTIN falls back to text and warns.
  - `resolveStateCode` (:283-306) is exported, used by `eway-json.ts:239`, and tested at `invoicing-arith.spec.ts:222`. Add `gstinKnown` and `textUnresolved` **additively**; the existing fields stay unchanged.
  - Party gaps (:709-751), whose `place-of-supply` detail (:723-733) must name the case.
  - `hsnGap` (:783); `buyer.name` in `buildDocument`; `documentsEqual` (:933).
- `wms-be/src/modules/invoicing/hsn-summary.ts:124-132` (`HSN_PATTERN`, `isValidHsn`, no trim) and `eway-json.ts:230` (`trimmedHsn`): move both into a new `invoicing/hsn.ts` as `normalizeHsn` + `isValidHsn`, re-exported. The route description `invoicing.controller.ts:140` (CSV exclusion) must be updated.
- Tests pin gap kinds as **ordered arrays** (`invoicing.spec.ts:1069,1090,1115,1688`). The new gaps go in this order:
  1. the party block: existing gaps, then `gstin-prefix-unknown`, then `state-text-unknown`, origin before destination;
  2. the line loop: `hsn-invalid` right where `hsn-gap` is pushed.
- `wms-fe`:
  - `lib/invoices.ts:131` `GST_STATE_NAMES` moves to a standalone `lib/gst-states.ts` (re-exported), so the pre-login `lib/gstin.ts` doesn't pull in the API client. Gap labels are at :169-176.
  - Forms: `components/settings/warehouse-create-form.tsx:209-214`, `lib/outbound-orders.ts:590-625` (`DestinationFields`), the order form `components/outbound/outbound-orders.tsx:121-196` (`edit…` wrappers mint a fresh key, :131-150), and `auth-forms.tsx` (registration). Their tests fill State with `querySelector('input')` (`warehouse-create-form.test.tsx:93-108`, `outbound-orders.test.tsx:457-476`) and must use `setSelect` (:443).
  - `eway-bills.tsx:106` already computes `canConfigure`; `blockerHint` has 2 call sites (:345, :376). `lib/use-eway.ts:29-41,122` (`useChangeRevision`, shared by `useTenantList`).
- **Rate master** (the source corrected by review): India Compliance `GST_TAX_RATES` is checked against the **e-invoice (IRP) masters** (`transaction_data.py:643`): 0, 0.1, 0.25, 1, 1.5, 3, 5, 6, 7.5, 12, 18, 28, 40 %. It is assumed equal to Table 12's rate dropdown, which is **not verified**.

## Tasks & Acceptance

**Execution:**
- [x] `wms-be/src/shared/primitives/gstin.ts` + test -- add `GSTIN_STATE_CODES`, `isGstinStateCode`, and the truthful comment (shape + state prefix; PAN and checksum not validated). The test pins the constant equal to `gst_state_codes` minus `99`, read from the DB in an e2e suite.
- [x] `wms-be` tenancy `normalizeGstin` + `order.command.ts:377` -- refuse a bad prefix with 400 `validation-failed` ("`92` is not a GST registration state code"), behind the replay lookup.
- [x] `wms-be/drizzle/0057_order_consignee_legal_name.sql` (+ journal, snapshot, schema.ts) -- `orders.consignee_legal_name text NULL` with a CHECK: NULL, or `char_length(...)` between 1 and 100 and `consignee_gstin IS NOT NULL`. Guarded like 0056; no backfill.
- [x] `wms-be/src/modules/outbound/*` -- `consigneeLegalName` on the order. Normalised (JS trim; blank = absent) before hashing. It joins **both** hashes as a conditional spread after `consigneeGstin`. Refused, behind the replay lookup, when there is no GSTIN or when it exceeds 100 code points (`[...s].length`). It is persisted and added to `OrderInvoiceFacts`. Record the conditional-key hash exception in `IMPLEMENTATION-GUIDE.md`.
- [x] `wms-be/src/modules/invoicing/hsn.ts` -- `normalizeHsn` + `isValidHsn`, re-exported from `hsn-summary.ts` and used by `eway-json.ts`.
- [x] `wms-be/src/modules/invoicing/generator.ts`:
  - Add the non-blocking kinds `hsn-invalid`, `state-text-unknown` and `gstin-prefix-unknown`, and update the doc comment.
  - Filter `codeByGstinPrefix` by `isGstinStateCode`.
  - Add the `resolveStateCode` fields; emit the gaps in the order above.
  - Write the `place-of-supply` detail per case.
  - Write the `pos-discrepancy` detail per side: origin "dispatch-from", destination "ship-to", plus "— if an e-way bill is required it will be blocked (`ship-to-differs`); generate it on the portal". `state-text-unknown` gets the matching e-way note (`state-unresolved`).
  - `buyer.name` = `consigneeLegalName ?? contactName`.
- [x] `wms-be/src/modules/invoicing/hsn-summary.ts` + DTO + route description -- add `GST_RATE_MASTER_BPS` {0, 10, 25, 100, 150, 300, 500, 600, 750, 1200, 1800, 2800, 4000} (comment: e-invoice master via India Compliance; Table 12 equality unverified) and a `rateIssue` flag per row. Re-export `openapi.json`.
- [x] `wms-be` tests -- every matrix row, plus golden hashes (`payloadHash` and `sourcePayloadHash`) for a body without the legal name, and an 0057 migration block.
- [x] `wms-fe`:
  - **Prefix check and state list:**
    - `lib/gst-states.ts`: `GST_STATE_NAMES` (moved) and `GSTIN_STATE_CODES`, mirrored and pinned by a test.
    - `lib/gstin.ts`: the prefix check ("not a GST state code") and the comment truth.
  - **`StateSelect`:**
    - options are a blank placeholder, then the official names for 01–38 and 97, without 99;
    - it replaces the free-text State inputs on the warehouse form and the order destination;
    - the warehouse form shows an inline, non-blocking warning when the GSTIN's prefix state ≠ the selected state;
    - tests switch to `setSelect`.
  - **Order form legal name:**
    - a "Buyer legal name" input (`maxLength` 100), shown when Buyer GSTIN is non-blank;
    - `editConsigneeLegalName` mints a fresh key;
    - the text is kept but not sent while the GSTIN is blank, and reset on success.
  - **Gap labels** (`lib/invoices.ts`): "HSN malformed", "State not recognised", "GSTIN state code unknown".
  - **HSN summary** (`lib/hsn-summary.ts`):
    - the CSV excludes rows with `hsnIssue || rateIssue`;
    - the screen flags rate rows;
    - the shortfall adds `totalValuePaise` of rows with `rateIssue && !hsnIssue`.
  - **`use-eway.ts`:**
    - a bills-only hook listens for `INVOICES_CHANGED_EVENT` with one trailing-debounce timer that re-reads at about 3 s and again at about 10 s;
    - the timer is cleared on unmount and on a tenant change;
    - `EWAY_CHANGED_EVENT` stays immediate;
    - the settings lists stop listening to invoice events;
    - tests use fake timers.
  - **E-way hint:** `blockerHint(blocker, canConfigure)`. When false, the hint says "ask an owner to turn the flag off". Update both call sites.
  - **Tests** for each.
- [x] Meta docs -- `invoicing.md`, `outbound.md`, `tenancy.md`, `IMPLEMENTATION-GUIDE.md` (the hash exception), `API-SURFACE.md`, and both contracts. `PENDING.md`:
  - close "Issuance is looser…", keeping residuals for unverified GSTIN anatomy/checksum and the 6-digit AATO and HSN-master rules;
  - update the dispatch-from row;
  - add "`gst_state_codes` labels 99 'Other Country' (99 is Centre Jurisdiction; Other Country is 96)", affecting POS and e-way.

**Acceptance Criteria:**
- Given a warehouse with GSTIN prefix `92`, when it is created through the API, then it is refused with 400 and nothing is written.
- Given a B2B order with a legal name and a SKU with HSN `HSN 0910`, when it dispatches and issues, then the invoice is `issued`, its gaps include `hsn-invalid`, and its e-way export's `toTrdName` is the legal name.
- Given the full BE and FE suites, when run, then they pass.

## Implementation Notes

- Baselines: wms-be `f0423a325fca021a30b2989d9388647eb45cf42b` (frontmatter `baseline_commit`); wms-fe `698a23798a80fe8721c29e8aa32ac95396377eb3`. Work happens on `feat/8-1d-issuance-gate-parity` in both repos. Leave changes uncommitted; do not commit, push, or open PRs. In wms-be run jest via `bun run test -- <file>` (bare `bun test` hangs) and never two jest invocations concurrently. The India Compliance source copies cited in the Code Map are in `/private/tmp/claude-502/-Users-sasidhar-Documents-WMS-Meta/cce72c77-089a-4cee-bfc4-8a5a14be09e3/scratchpad/` (`const_init.py`, `transaction_data.py`).
- Shipped: WMS-BE #74 (`049ace4`), WMS-FE #59 (`1344c16`); design PR WMS-Meta #89.

## Spec Change Log

## Review Triage Log

*Design review, 2026-10-06: two code- and source-verified reviewers (backend/migration; FE/GST rules). 28 findings merged into 20; every one was within the human decisions, so none needed escalating.*

| # | Severity | Finding | Disposition |
|---|---|---|---|
| 1 | high | The order has two hashes; only one was named | Both, as a conditional spread; normalised first; golden test |
| 2 | high | Registration has no transaction for a DB prefix lookup; `normalizeGstin` is synchronous | A pure constant pinned to the table by a test; `shared/reference` dropped |
| 3 | medium | 99 refused at entry but resolvable at issue | `codeByGstinPrefix` filtered by the same predicate; matrix row |
| 4 | medium | 99's reason was wrong (Centre Jurisdiction, not Other Country, which is 96) | Reason corrected; the seed mislabel goes to PENDING |
| 5 | medium | HSN trim undefined: padded or whitespace values disagree across readers | `normalizeHsn` shared; whitespace-only = `hsn-invalid`; matrix rows |
| 6 | medium | "Warnings change nothing" is false for awaiting invoices | One-time revision bump stated and tested |
| 7 | medium | Order-view exposure was an implicit decision | Dropped |
| 8 | medium | `resolveStateCode` lacks the needed signals; gap order is pinned | Additive fields; order specified |
| 9 | medium | The `pos-discrepancy` text was wrong per side and overstated | Per-side text, conditional, names `ship-to-differs` |
| 10 | medium | `state-unresolved` collided with the e-way blocker name and merged two causes | Split into `state-text-unknown` and `gstin-prefix-unknown` |
| 11 | medium | The rate list's source was misattributed | Relabelled as the e-invoice master; Table 12 equality marked unverified |
| 12 | medium | Warehouse GSTIN state vs address state mismatch was undecided | Web inline warning; backend never refuses (Never) |
| 13 | medium | StateSelect options undefined; the stored-value clause can't happen | Placeholder plus 01–38 and 97; clause dropped |
| 14 | medium | FE legal-name key and visibility semantics unspecified | `edit…` wrapper, keep-not-send, reset, `maxLength` |
| 15 | medium | The hint should follow a capability, not a role | `canConfigure` |
| 16 | medium | The delayed refetch was too loose (relay timing, multiple events, shared hook) | Debounced 3 s + 10 s, cleared on unmount and tenant change, split hook, fake timers |
| 17 | low | `place-of-supply` detail becomes false | Per-case detail |
| 18 | low | Legal-name length units ambiguous | 100 code points after JS trim, in the command |
| 19 | low | FE tests and import direction (`gstin.ts` → `invoices.ts`) | `setSelect`; `lib/gst-states.ts` |
| 20 | low | Shortfall could double-count; stale doc comments | `rateIssue && !hsnIssue`; comments in the Code Map; AATO 6-digit rule in PENDING |

*Code review, 2026-10-06: three layers (blind, edge-case, verification-gap); 24 findings merged into 18, each verified against the code.*

| # | Verdict | Finding | Evidence | Route |
|---|---|---|---|---|
| C1 | high | A legal name with no Latin letters or digits (e.g. Devanagari) is stripped to `""` by `nicText`, so the frozen invoice gets a permanent e-way `address-incomplete` block. This is the class of defect the story exists to close. | `eway-json.ts:208-211`; order command accepts any Unicode | patch: refuse at order create when `nicText(name, 100)` is empty; warn at issue when the printed buyer name is NIC-empty |
| C2 | medium | Control characters (U+0000 and the rest) in the legal name pass `trim()`; NUL fails the insert with a 500 | `normalizeConsigneeLegalName` | patch: refuse control characters (400) |
| C3 | medium | A side that resolves from its GSTIN but has a null address or a blank state issues silently, then e-way blocks (`state-unresolved`/`address-incomplete`) | `resolveStateCode` blank arm; `actualStateOf` | patch: `state-text-unknown` also fires for a null address or blank state on a GSTIN-resolved side |
| C4 | medium | Gap details print on the customer's tax invoice, and 8-1d adds internal advice to them | `invoices.tsx:332` (`data-print-root`), `:438` | patch: gaps hidden in print |
| C5 | medium | The web warehouse warning misses the main case: no warehouse GSTIN, tenant GSTIN in another state | `gstinStateMismatch(gstin, origin.state)` only | patch: compare against the session tenant GSTIN when the warehouse GSTIN is blank |
| C6 | low | The order form has no GSTIN-vs-destination state warning | form | patch: same inline helper |
| C7 | low | FE error text says `"99" (Other Country)`, the mislabel the story documents | `lib/gstin.ts` + test | patch: name the code only |
| C8 | low | `maxLength` counts UTF-16 units before trim, so the client cap is not the backend's | `outbound-orders.tsx` | patch: drop `maxLength`, check code points after trim in the parser |
| C9 | low | The 0057 CHECK lets a whitespace-only or padded name through at the storage layer | 0057 | patch: `char_length(btrim(...)) BETWEEN 1 AND 100` (not yet deployed) |
| C10 | low | The destination `gstin-prefix-unknown` detail omits that NIC may refuse that `toGstin` | generator detail | patch: one clause |
| C11 | medium | Test gaps: no registration replay arm for "prefix behind the replay lookup"; the per-case `place-of-supply` detail branches are never run (GSTIN with an unknown prefix and off-list text) | `issuance-gate-parity.spec.ts`; `invoicing.spec.ts` | patch: tests |
| C12 | low | No way to read back the create-only legal name before issue | design (#7 dropped view exposure) | patch (docs): PENDING row |
| C13 | low | Issue time is still silent on other terminal e-way blockers (`rate-not-standard`, `unsupported-supply`, `too-many-lines`) and the generator has no rate-master warning | `eway-json.ts` blockers | patch (docs): PENDING row; out of the human-decided scope |
| C14 | low | A legacy 99/25 GSTIN with off-list state text now parks `awaiting-data` on re-derive (previously resolved to 99) | prefix-map filter | accepted: by design (review #3). Place of supply is genuinely unknown, and the detail names the GSTIN cause |
| C15 | low | The AC's "e-way export `toTrdName`" is unreachable for that order (the HSN blocker refuses export); the test uses the builder | `eway.spec.ts:916-934` | accepted: the builder is the one source of the export file; the AC wording is noted |
| C16 | low | Allowed characters (`'`, `()`) are silently stripped in the e-way file | `nicText` | rejected: NIC's charset; cosmetic |
| C17 | low | The bills debounce stops at about 10 s; a slow relay stays stale | `use-eway.ts` | rejected: the Refresh button exists |
| C18 | low | PENDING cites S1–S5, S7 without S6 | docs | rejected: S6 is its own PENDING row (odd paisa) |

## Design Notes

- **Why the backend doesn't refuse free-text states.** Channel ingestion (7-2) and API clients send marketplace address text; refusing it would drop orders. The web narrows input, and issuance warns about whatever still gets through.
- **Prefix codes, verified:**
  - 25 (Daman & Diu) GSTINs were re-issued under 26 from 1 Aug 2020;
  - 28 is pre-GST Andhra Pradesh (37 under GST);
  - 97 (Other Territory) GSTINs are real;
  - 99 is Centre Jurisdiction (OIDAR / UIN), never a goods-shipping party.

  Sources: Tally and KDK on the 25→26 merger; Razorpay's and tax2win's state-code lists.
- **Why a constant, not a DB read.** The check must run in synchronous helpers and outside transactions (registration). A test pins the constant to the table, the same way the FE mirrors are pinned.
- **Hash stability.** A key added for every request changes every fingerprint, which is the side-effect convention change the design review guards against. So the name joins only when present.
- **Two rate lists, deliberately.** NIC's e-way table and the e-invoice rate master differ (e.g. 1.5 % and 7.5 % are only in the latter).

## Verification

**Commands:**
- `bun run test` (wms-be) -- green, plus `typecheck`, `lint`, `build`; `db:generate` reports "No schema changes".
- `bun run lint && bun run test && bun run typecheck && bun run build && bun run check:capability-mirror` (wms-fe) -- green.
