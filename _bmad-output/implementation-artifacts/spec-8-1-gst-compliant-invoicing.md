---
title: 'GST-compliant invoicing'
type: 'feature'
created: '2026-10-03'
status: 'done'
route: 'dispatch'
baseline_commit: 'a73e437ff132e9568b7627fe136e30219e3212c4'
review_loop_iteration: 0
context:
  - '_bmad-output/implementation-artifacts/epic-8-context.md'
  - 'docs/design/SYSTEM-DESIGN.md'
  - 'docs/design/IMPLEMENTATION-GUIDE.md'
  - 'docs/design/modules/outbound.md'
  - 'docs/design/modules/catalog.md'
  - 'docs/design/frontend/IMPLEMENTATION-GUIDE.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** A dispatched order leaves no tax document: the system has no rate, no GSTIN, no place-of-supply logic, and no invoice records — an accountant closes nothing without hand-building the invoice from raw data.

**Approach:** A new `invoicing/` module derives one invoice per dispatched order from persisted facts (order + lines + picks) over the outbox `order.dispatched` event, priced from per-line rates frozen at order acceptance (with an explicit operator override path for unpriced lines), taxed with the catalog's `gst_rate_bps` in exact integer math (`Paise`/`GstBps` primitives), stored as a tenant-scoped record with a JSON document snapshot, and surfaced on the existing `/compliance` web surface with printable invoices. Generation is retryable and never blocks dispatch.

## Boundaries & Constraints

**Always:**
- All money integer paise (`Paise`), all GST rates basis points (`GstBps`), all quantities milli-units — exact integer arithmetic end to end, floats forbidden. Stored math is paise-exact; no rupee rounding.
- Invoice lines come from persisted dispatch facts (picks re-derived by the handler), never from the event payload alone — retries are idempotent by derivation, not by caching.
- Exactly one invoice per (`tenant_id`, `order_id`) — `UNIQUE`.
- Generation failure is retryable and never blocks or touches dispatch state.
- Invoice records are tenant-scoped, module-exclusive to `invoicing/`; the rate/GSTIN columns it consumes are written only by their owning modules (rate override for unpriced lines rides the invoicing command's OWN input and freezes only into the invoice document — `order_lines.rate_paise` is never written post-dispatch).

**Never:**
- No PDF bytes or blob storage in 8-1 — the document path is the structured snapshot + printable surface.
- No e-way bills, no EwayGateway port, no thresholds, no HSN summary (Story 8-2).
- No ledger writes — an invoice is a derived money artifact, not stock motion.
- No void/credit-note commands in 8-1 (the status vocabulary carries `voided` for vocabulary stability; the command is deferred to PENDING).
- No client-invoice/billing model for 3PL (Epic 21-5 extends the later invoice core).
- No backfill: dispatches that completed before this module shipped get invoices only through the manual generate command; no event replay, no bulk backfill (the surface shows their absence naturally — they join when someone regenerates).

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Priced dispatch → invoice | `order.dispatched` arrives; all lines have `rate_paise`, place of supply resolvable | Invoice row (`status: issued`), lines with full tax math, document snapshot, numbered from the FY series | N/A |
| Unpriced lines at dispatch | Any dispatch line has null `rate_paise` | Invoice created `status: awaiting-data`, priced lines + gaps listed in the snapshot | No retry loop; the gap is stable state |
| Operator prices after the fact | `POST /tenants/{t}/invoices {orderId, rates:[{orderLineId, ratePaise}]}` | Regenerate recomputes with the override rates — frozen into the invoice document (`source: 'manual'`, `order_lines` untouched) — and flips `issued` when all gaps close | Duplicate/conflict → replay posture; unknown line id → 409 |
| State text unmatched | States resolvable nowhere (no GSTIN prefix, no code row) | Place-of-supply gap → `awaiting-data`; resolvable parts still computed and stored | No retry loop |
| Regenerate, already issued | Same command with no rate changes | Recompute from persisted facts; content-identical → revision unchanged; changes → revision bumps | 404 unknown / not-dispatched order |
| Kit dispatch | Kit parent line (zero picks) + component lines | Parent line drops out (zero dispatched qty); components invoice at their own rates; channel-invoiced kits price via per-component override | N/A |
| HSN missing | `skus.hsn` null on a line | Line issues with blank HSN + `hsn-gap` warning in the invoice; never blocks issuance | Warning surfaced on the surface, not an error |
| Concurrent generation | Event delivery + manual command race on the same order | `UNIQUE (tenant_id, order_id)` — the loser sees the violation and adopts the replay posture (existing row, no second insert, no double tax) | Unique violation handled, never 500 |

</frozen-after-approval>

## Code Map

- `src/modules/compliance/` -- EXISTS — temperature-excursion module (12-5); the GST module is deliberately the sibling `src/modules/invoicing/` (name collision is why).
- `src/shared/db/schema.ts:418-419` -- `skus.gst_rate_bps` NOT NULL, `hsn` nullable — the GST data home, already in catalog; zero catalog changes in 8-1.
- `src/shared/primitives/quantity.ts:94-101` -- `GstBps` branded type + `gstBps()`; **zero consumers today** — this is the landing point. `src/shared/primitives/money.ts` holds `Paise` + `paise()/addPaise()`.
- `src/shared/db/schema.ts:1928` `order_lines`; `:1861` `orders` -- outbound-owned; gain `rate_paise` (lines) and `consignee_gstin` (orders), written ONLY by outbound's **create** command (NO edit command exists — `order.command.ts` exposes only `createOrder` `:255` and `cancelOrder` `:732`; post-dispatch pricing rides the invoicing command's per-line override instead). Unpriced lines: channel-ingested orders arrive without prices.
- `src/shared/db/schema.ts:42` `tenants` -- tenancy-owned; gains nullable `gstin` (the tenant default), stamped by the tenant registration command.
- `src/shared/db/schema.ts:193` `warehouses` -- tenancy-owned; gains nullable `gstin` (warehouse override), written by the tenancy warehouse command.
- `src/modules/outbound/dispatch.command.ts:310-331,340-465` -- `dispatchedQty` = picks sum (NOT persisted); `DispatchDto` (outbound.dto.ts:1190-1245) carries lines, no rate/destination. Generation re-derives from `orders`/`orderLines`/`picks`/`warehouses`/`skus` via facades — never trusts the payload.
- `src/modules/outbound/order.command.ts:208,297-316` -- `lineFingerprint` = `{skuId, quantity}` and both create hashes span lines+destination: adding `ratePaise` (line fingerprint) and `consigneeGstin` (create hash) is a deliberate 11-1-shaped hash-shape break — pinned explicitly in Design Notes, not silent.
- `src/modules/outbound/order.command.ts:663` -- in-tx `outbox.append(tx, {type:'order.dispatched'…})` precedent; invoicing writes `invoice.issued` the same way.
- `src/modules/channels/channel-availability.delivery.ts` -- THE outbox delivery-handler exemplar: `OnModuleInit` subscribe, malformed → ACK, failure → meter+rethrow (relay owns backoff); `src/modules/channels/channels.module.ts:49-50` registration.
- `src/modules/putaway/bin-state.command.ts:52-205` -- the canonical command skeleton (hash → permission → replay → lock → guards → write → outbox → audit → idempotency-key last) for the manual generate command.
- `src/modules/carriers/carrier-label-port.ts` -- port/registry shape reference only; 8-1 has NO external adapter (no metered calls), so no port is written.
- `drizzle/0052_*.sql` -- latest migration; invoicing migration is `0053` (hand-amended CHECK/index pattern, journal+snapshot+sql committed together).
- FE `src/app/(app)/compliance/page.tsx` + `src/components/compliance/cold-chain-trace.tsx` -- the EXISTING `/compliance` surface; 8-1 adds an Invoices Section alongside the trace viewer (same `Section`/`ReadFailure`/`DataTable` conventions, `useSyncExternalStore` loader skeleton, cursor pagination, `Idempotency-Key` mutations). No push infra exists — an `awaiting-data → issued` flip is visible on the next manual reload (accepted; noted in Design Notes).
- FE `src/lib/api/client.ts` -- single generated-client wrapper file; new `fetchApiInvoices*` wrappers follow the ~10-line pattern; capability mirror in `src/lib/users.ts` (CI guard parses BE `permissions.ts`).

## Tasks & Acceptance

**Execution:**
- [x] `drizzle/0053_invoicing_core.sql` -- migration adding: `invoices` (`tenant_id`, `order_id` with **UNIQUE (tenant_id, order_id)**, `warehouse_id`, `invoice_no` unique per tenant, `fy_label`, `series_seq`, `status` CHECK `('awaiting-data','issued','voided')`, origin/consignee GSTIN snapshots, `place_of_supply` code, `supply_type` CHECK `('intra','inter')`, subtotal/gst/total paise, `revision`, `document` jsonb, ts columns), `invoice_lines` (invoice_id, order_line_id, sku code/name + hsn snapshots, qty_milli, rate_paise, rate_source CHECK `('order_line','manual')`, taxable_paise, gst_bps, cgst/sgst/igst paise, hsn_gap bool), `gst_state_codes` (the **CBIC GST state-code list, 38 entries** incl. 26-Ladakh, 37-AP, 38-Other-Territory, 07-Delhi: normalized state name → code — hand-seeded, count pinned), and the owned columns `tenants.gstin`, `warehouses.gstin`, `orders.consignee_gstin`, `order_lines.rate_paise`. Seed proof rides the test task.
- [x] `src/modules/invoicing/arith.ts` -- exact helpers: half-up `divRound(milliQty, paiseRate)` and the bps division at the line boundary, CGST/SGST split with the remainder paise to SGST (rendered "SGST/UTGST"), IGST for inter-state, and the two-sum invariants (`subtotal + gst = total`, `cgst+sgst+igst = gst` when intra) as checked totals.
- [x] `src/modules/invoicing/generator.ts` -- derive-from-facts computation shared by the delivery handler and the command: re-derive dispatched qty from `picks` (kit parent lines drop at zero), resolve rates (`order_lines.rate_paise` else command override), resolve POS (consignee GSTIN prefix first two digits when present; else `gst_state_codes` lookup of destination state; origin likewise from warehouse GSTIN/`origin_state`; classify intra vs inter), resolve supplier GSTIN (warehouse `gstin` else tenant `gstin`), compute lines per `arith.ts`, build the document snapshot.
- [x] `src/modules/invoicing/command.ts` -- manual generate/regenerate command on the full skeleton, `{orderId, rates?}` payload: creates or recomputes the order's single invoice; `awaiting-data → issued` flip stamps the FY number (series row `FOR UPDATE`); unique-violation → replay posture. `delivery.ts` subscribes to `order.dispatched` and calls the same generator (channels-delivery posture: malformed ACK, failure meter+rethrow), emitting `invoice.issued` in-tx when issuance happens. `facade.ts`/`view.ts`/`events.ts`/`module.ts` complete the module file set; capability `invoice.generate` in `src/modules/tenancy/permissions.ts`.
- [x] `src/modules/outbound/order.command.ts` (+controller) -- create command accepts optional `ratePaise` per line and `consigneeGstin`; stamps the new columns; hash/fingerprint updates pinned per Design Notes. `src/modules/tenancy/` -- tenant registration accepts optional `gstin`; warehouse create accepts optional `gstin`.
- [x] `src/api/invoicing.controller.ts` + `docs/design/API-SURFACE.md` -- routes: `GET /tenants/{t}/invoices` (cursor page), `GET /tenants/{t}/invoices/{id}` (error arm: 404), `POST /tenants/{t}/invoices` `invoice.generate` (refusals: 404 unknown order, 409 not-dispatched, 409 line-not-of-order). Controller thin, no rules.
- [x] `test/invoicing-arith.spec.ts` -- the exact-math table: half-up divisions, remainder split, intra/inter, MAX_QUANTITY_MILLI × paise safe boundaries, zero-rate/zero-qty, two-sum invariants.
- [x] `test/invoicing.spec.ts` -- real-DB: event-driven issuance, awaiting-data → regenerate-with-rates → issued, kit parent exclusion, hsn-gap warning, state gap, GSTIN-prefix POS wins over state text, **concurrent generate race → no double row**, event double-delivery → same invoice content, refusals, FY numbering sequence, **seed proof: `gst_state_codes` row count = 38 and every fixture state resolves**.
- [x] FE `wms-fe` -- extend `/compliance`: invoices Section (per-order invoice list, detail in expanded row), printable-invoice render + print action, `fetchApiInvoices*` wrappers, regenerate dialog carrying per-line rate overrides gated by `invoice.generate` in the mirrored `src/lib/users.ts`, `use-invoices` external-store hook. Rides AFTER the BE PR merges (generated-client CI pins the order).
- [x] Meta `docs/` -- API-SURFACE rows; epic-8-context amendment: "compliance/" → `invoicing/` + collision note; channels.md/PENDING rows: `invoice.void`/credit notes deferred, tenant-settings GSTIN edit route deferred (8-1 stamps GSTINs at registration/warehouse-create only).

**Acceptance Criteria:**
- Given a dispatched order with priced lines and resolvable POS, when the event delivers, then an `issued` invoice exists with `subtotal + gst = total` and `cgst + sgst = gst` exactly, in paise.
- Given generation throws, when the relay retries, then dispatch state is untouched and the invoice eventually issues with no duplicate row (UNIQUE key holds under the concurrent race).
- Given unpriced lines at dispatch, the invoice parks `awaiting-data`; after the operator regenerates with per-line rates, it flips `issued` with the same invoice number — and `order_lines.rate_paise` stayed unchanged.
- Given two concurrent generate invocations, one replays; no invoice double-taxes.

### Review Findings

*Code review of the BE slice, 2026-10-03. Four layers: blind, edge-case, verification-gap, acceptance. All reported. 4 decision-needed (all resolved: 3 became patches, 1 deferred), so 26 patch, 1 defer, 10 rejected.*

- [x] [Review][Patch] *(decided: refuse with 409 `line-already-priced`; the frozen rate always wins, and overrides fill only unpriced lines)* **A rate override re-prices a line frozen at acceptance; a later plain regenerate silently reverts it** (medium). `computeDraft` resolves `override ?? fact.ratePaise ?? carriedManual`. An override on an already-priced line wins, contradicting Intent ("override path for unpriced lines") and Tasks ("`order_lines.rate_paise` else command override"). The next override-less regenerate (an event redelivery counts) then puts the order-line rate back above the carried manual rate. That silently changes totals on an issued, numbered invoice. [generator.ts:607]
- [x] [Review][Patch] *(decided: park with a new blocking gap kind `supplier-gstin`)* **An invoice issues with no supplier GSTIN** (medium). `originGstin = warehouseGstin ?? tenantGstin` can be null. The origin still resolves from address text, so no gap is raised and a numbered `issued` invoice carries `seller.gstin: null`. That contradicts the `tenants.gstin` schema comment ("parks awaiting-data … never issues"). [generator.ts:565]
- [x] [Review][Patch] *(decided: invoicing logs and ACKs deterministic data faults (4xx problems, arithmetic overflow) and rethrows only transient errors)* **`order.dispatched` now has two subscribers, and invoicing runs first** (medium). `RoutedEventBus.publish` awaits handlers in order and stops at the first throw; the runtime handler order is invoicing, then channel writeback. A persistent invoicing failure (rethrown by design) blocks the 7-2 marketplace writeback until the row dead-letters. Every writeback failure re-runs invoicing (harmless), and every invoicing failure re-runs a metered marketplace call. [delivery.ts:99, event-bus.ts:54]
- [x] [Review][Defer] **Every kit order parks `awaiting-data`, even when priced at create** (medium). Deferred: per-component manual pricing works for 8-1, and splitting a kit's price across components needs a rounding rule designed on purpose, not improvised (decided 2026-10-03; PENDING row). The parent's frozen `ratePaise` is dropped (zero picks) and components are exploded with `rate_paise = null`, so "components invoice at their own rates" can never happen for a manual order. Each kit needs per-component manual pricing. [order.command.ts component explode; generator.ts:600]
- [x] [Review][Patch] **A command that loses the insert race drops the operator's rates and writes no key or audit row** (medium). The `InvoiceRaceLostError` catch returns the winner's snapshot with 200. If the delivery won, that is the unpriced `awaiting-data` row, and a same-key retry re-generates instead of replaying. Fix: retry the generate once in a fresh transaction, where it now takes the update path. [command.ts:203]
- [x] [Review][Patch] **The document's seller name is the warehouse label, not the tenant's legal name**: use `party.tenantName`, which is read but unused (medium). [generator.ts:704]
- [x] [Review][Patch] **A mismatch between origin GSTIN and origin state goes unwarned** (medium). The tenant-GSTIN fallback from another state decides intra/inter with no warning. Fix: push a `pos-discrepancy` for the origin arm as well. [generator.ts:566]
- [x] [Review][Patch] **The destination `pos-discrepancy` warning is dropped whenever the origin is unresolved** (an `else if` chain) (low). [generator.ts:589]
- [x] [Review][Patch] **`normalizeRates` throws before the permission check and the replay lookup** (low). A role-denied caller gets 400 instead of 403, against the skeleton order. Make the hash step lenient and move the throwing checks into the transaction after replay. [command.ts:85]
- [x] [Review][Patch] **Registration calls the throwing `normalizeGstin` before the replay lookup**, while its own comment says otherwise. Use `normalizeGstinInput` for the hash, as `warehouse.command.ts` does (low). [registration.command.ts:82]
- [x] [Review][Patch] **Issuance reads the clock twice** (`fyLabelFor(nowIso())`, `issuedAt = nowIso()`), so an invoice can be numbered in one FY and dated in the next; take one instant (low). [generator.ts:442]
- [x] [Review][Patch] **A blank `consigneeGstin`/`gstin` over HTTP gets 400**, while the commands treat blank as absent (the DTO transform trims to `''` and `@Matches` fails); map blank to undefined (low). [outbound.dto.ts:140, tenancy.dto.ts]
- [x] [Review][Patch] **Migration 0053 formatting**: `invoices_money_non_negative_check` has no `--> statement-breakpoint`, and there is a stray `;;` after `invoices_tenant_created_at_id_idx` (low). [0053_invoicing_core.sql:91,99]
- [x] [Review][Patch] **`OrderInvoiceLineFact.dispatchedQtyMilli` is documented as "null when the line has none"**, but it is typed `number` and returns 0 (low). [outbound.facade.ts:171]
- [x] [Review][Patch] **A stale comment in `order.command.ts` names the throwing `normalizeGstin`** for the lenient hash step (low). [order.command.ts:160,329]
- [x] [Review][Patch] **0053's seed comment claims the state-code transposition is "recorded in the spec's Spec Change Log"**, which is empty. Correct the comment and record the deviation (the official CBIC list, with 26 = DNH&DD, 38 = Ladakh, 97 = Other Territory) in Implementation Notes (low). [0053_invoicing_core.sql:11]
- [x] [Review][Patch] **No architecture write-guard for `invoices`/`invoice_lines`/`invoice_series`**, though the module and schema comments cite one. Mirror the channels block (low). [test/architecture.spec.ts:1102]
- [x] [Review][Patch] **The race test doesn't force an overlap**, so the adopt arm is unexercised (deleting the catch still passes). Add a deterministic two-transaction race. [test/invoicing.spec.ts:1143]
- [x] [Review][Patch] **No assertion that `invoice.issued` is emitted on the command's awaiting-data → issued flip.** [test/invoicing.spec.ts:824]
- [x] [Review][Patch] **No assertion of the revision bump on a content change** (`revision`/`document.revision` = 2 after pricing). [test/invoicing.spec.ts:840]
- [x] [Review][Patch] **8-1's hash inputs are not pinned**: the same key with a changed `ratePaise`, `consigneeGstin`, warehouse `gstin` or registration `gstin` should answer 422. [test/shipment-addresses.spec.ts precedent]
- [x] [Review][Patch] **The positive GSTIN arm is untested**: registration with a lowercase GSTIN should show uppercased in the 201, in sign-in `tenant.gstin` and in the DB; the warehouse-list `gstin` is untested too. [test/invoicing.spec.ts:183]
- [x] [Review][Patch] **The state alias map and the `&` → `and` normalization are not exercised** (the arith test adds `orissa` to its fixture by hand). [test/invoicing-arith.spec.ts:232]
- [x] [Review][Patch] **The delivery handler's ack/rethrow split is untested**: a malformed payload should ack, and an unknown order should reject. [delivery.ts:55,99]
- [x] [Review][Patch] **The duplicate `orderLineId` in `rates` → 400 arm is untested.** [command.ts normalizeRates]
- [x] [Review][Patch] **The seed proof doesn't assert that "every fixture state resolves"** (a Tasks/test requirement). [test/invoicing.spec.ts:683]
- [x] [Review][Patch] **AC2 is unverified**: no test injects a generation failure, retries through the relay, and asserts dispatch state untouched plus an eventual single issue. [test/invoicing.spec.ts]

**Rejected**
- `false`: *an issued invoice is rewritten with zero GST when `supplyType` turns null*. Every place-of-supply input (order destination and consignee GSTIN, warehouse origin and GSTIN, tenant GSTIN, the seeded codes) has no edit route after create, so this can't be reached.
- `false`: *an explicit `ratePaise: null` from a non-HTTP caller is refused*. The only non-HTTP caller (channel ingest) never passes `ratePaise`.
- spec: *issued invoices are mutable in place under the same number, and a revision emits no event*. The I/O matrix sanctions it ("changes → revision bumps"). It is a legal question for 8-2's regulatory pass.
- spec: *the number series is per tenant, not per GSTIN*. Design Notes pin "one series row per tenant per FY". Multi-GSTIN tenants get gapped per-GSTIN sequences, which 8-2's regulatory pass should rule on.
- spec: *`totals.payAble` casing*. It is pinned verbatim in Design Notes; renaming is a spec change, and should happen before 21-5 or the FE freezes it.
- `low`: *a GSTIN prefix that is not on the state list falls back to address text*. It needs lookup-time validation, and typo'd prefixes are rare.
- `low`: *the SQL CHECK admits lowercase GSTINs*. Every write path uppercases first, so the CHECK is only a backstop.
- `low`: *no CHECK ties `status = 'issued'` to non-null number columns*. That guards state no path was shown to produce.
- `low`: *no unique `(invoice_id, order_line_id)`*. The rewrite path always deletes first.
- `low`: *no `status` filter on the invoice list*. That is a feature request outside the spec; the FE task can ask for it.


### Review Findings — frontend

*Code review of the wms-fe slice, 2026-10-03. Four layers: blind, edge-case, verification-gap, acceptance. All reported. 1 decision-needed (resolved as a patch), so 17 patch, 0 defer, 9 rejected.*

- [x] [Review][Patch] *(decided: add them in 8-1; the state name comes from a code→name map mirroring the 38-row CBIC seed, never from the address text, which a GSTIN can outrank)* **The printed invoice omits several GST Rule 46 particulars**: separate CGST/SGST/IGST rates (only the combined rate prints), the place-of-supply state name (only the code), the total in words, and a signatory line. The spec's Intent says "GST-compliant", but its regulatory pass is 8-2's. [invoices.tsx PrintableInvoice]
- [x] [Review][Patch] **Two refusals claim "the invoice has refreshed", but nothing re-reads it.** `line-already-priced` and `line-not-of-order` need to call `notifyInvoicesChanged()` in the panel's catch (the excursion-resolved precedent) (medium). [invoices.tsx PricingPanel.submit; invoices.ts generateReason]
- [x] [Review][Patch] **Printed quantities take their unit from the LIVE catalog**, so a SKU map that hasn't loaded or was re-coded prints "N units". The snapshot's own `line.uom` should name the unit, with the catalog supplying precision only (medium). [invoices.tsx PrintableInvoice]
- [x] [Review][Patch] **The print stylesheet leaves gaps.** `visibility:hidden` keeps hidden content's height (blank trailing pages), the line table's `overflow-x-auto` clips on paper, and dark-theme text can print pale. Collapse non-print content, unclip, and force light colours on the print root (medium). [globals.css]
- [x] [Review][Patch] **The invoice date is formatted in the viewer's timezone**, so it can disagree with the IST-derived FY label. Pin it with `timeZone: 'Asia/Kolkata'` (low). [invoices.tsx PrintableInvoice]
- [x] [Review][Patch] **The section success banner isn't tied to its invoice**: it stays up after the operator opens another invoice. Key it by invoice id and show it only while that invoice is open (low). [invoices.tsx InvoicesSessioned]
- [x] [Review][Patch] **`readInvoiceDocument` doesn't check fields it renders**: an absent (`undefined`) address crashes `addressLines`, and an absent `issuedAt` prints "Invalid Date" (low). [invoices.ts]
- [x] [Review][Patch] **Copy and derivations sit in JSX**: the blocking-first gap sort, the Blocking/Warning prefix and the draft notice. Move them into `src/lib/` with tests (frontend guide §2.2/§10) (low). [invoices.tsx]
- [x] [Review][Patch] **The draft notice would be false for a `voided` invoice**, which has a number. It's unreachable in 8-1 but frozen into the branch; fold it into the moved notice (low). [invoices.tsx PrintableInvoice]
- [x] [Review][Patch] **The read mappers miss house-set codes** (`role-denied`, `not-found`, `validation-failed`) (low). [invoices.ts]
- [x] [Review][Patch] **The `invalid-cursor` copy says the list "restarted"**, but only Retry restarts it. Reword (low). [invoices.ts]
- [x] [Review][Patch] **`maxLength={36}` truncates a whitespace-padded UUID paste** before the trim (low). [invoices.tsx GenerateForOrder]
- [x] [Review][Patch] **A stale "Not generated" banner stays beside a new local validation problem.** Clear it on the early return (low). [invoices.tsx PricingPanel]
- [x] [Review][Patch] **Regenerating an issued invoice gives no word on the consequence** (it keeps its number, and a changed result bumps the revision). Add the copy (low). [invoices.tsx PricingPanel]
- [x] [Review][Patch] **Test gap: the per-draft Idempotency-Key** (reused across a retry of an unchanged draft, reset on edit) is untested for both forms. [invoices.test.tsx]
- [x] [Review][Patch] **Test gap: no component test reaches a generate refusal** (banner, draft kept, list not re-read; the refresh arm after the P1 fix). [invoices.test.tsx]
- [x] [Review][Patch] **Test gap: untested paths**: a read failure followed by Retry, the unreadable-document branch, the return to page one after a generate, and the banner surviving the remount. [invoices.test.tsx]

**Rejected**
- `false`: *an issued invoice can print "Blocking" gaps under "Tax invoice"*. Every input that could raise a blocking gap is frozen once the invoice issues (rates frozen or carried, place-of-supply inputs immutable, GSTINs create-only).
- `false`: *the print root anchors to a positioned ancestor*. No ancestor of the expanded cell is positioned. (The sticky `thead` is a sibling branch.)
- `low`: *`session.tenant.gstin` reads `undefined` on pre-deploy sessions*. Nothing reads it.
- `low`: *₹0 is accepted*. The backend permits a zero rate (samples, free supply), and the spec sets no floor.
- `low`: *the supplier-gstin gap gives no way to set a GSTIN*. No route exists; PENDING already records it.
- `low`: *recovery asks for a raw UUID*. It's a UX feature request outside the spec.
- `low`: *an all-blank draft can't plain-regenerate while lines are unpriced*. The result would stay awaiting-data anyway.
- `low`: *an unknown `status` would label as undefined*. The status is a closed enum in the generated type.
- `low`: *`formatRupees` given NaN or a fraction*. The document check guarantees numbers, and the backend emits integers.

## Implementation Notes

<!-- Agent-owned. Append-only during implementation. -->

- **2026-10-03 — BE slice resumed and completed.** The first implementation pass stopped before `src/api/invoicing.controller.ts`, recording the controller as "deferred to the FE story" in the module and test headers. That contradicted the Tasks list (the controller is a BE task, and the FE task's generated client needs the routes), so it was built here: `invoicing.controller.ts` + `invoicing.dto.ts`, `InvoicingCommand` exported, registered in `ApiModule`, and the stale comments corrected. `POST /invoices` answers **200** (it creates or re-derives; it is not a pure create).
- **Defects the new HTTP tests and the full suite caught in the first pass:**
  - `view.ts` passed raw Postgres timestamp text through, so `createdAt`/`updatedAt` were non-ISO on the wire and the list's own `nextCursor` failed its `decodeCursorSafe` regex (page 2 → `400`). Fixed with `canonicalInstant` in the views, and the cursor now carries a `fullPrecisionInstant` of `created_at::text` (the replenishment precedent; millisecond truncation skips same-millisecond rows).
  - 0053's RLS policies were all named `"tenant_isolation"`, breaking IMPLEMENTATION-GUIDE's `"<table>_tenant_isolation"` shape. Renamed in place (unmerged; the dev DB had never applied 0053).
  - `TenantResponse.gstin` / `WarehouseResponse.gstin` lacked an explicit `type: String` (the `string | null` reflection gotcha), so the OpenAPI drift guard failed.
  - Count pins not moved: `users.spec.ts` capabilities 33 → 34 (plus `invoice.generate` holder-set pins); `client-isolation.spec.ts` policies 64 → 67.
  - Verification's `GstBps` grep found zero consumers: `arith.ts` used bare `number`. `computeLineTax` now takes `Paise`/`GstBps` and returns `Paise`; the generator converts via the checked `asPaise`/`asGstBps`.
- **HTTP coverage added to `test/invoicing.spec.ts`:** generate → issue over HTTP, same-key replay, `422` key reuse, accountant reads detail and paginates the list, and the refusal arms (`403` role/tenant, `400` key/body/path/cursor, `404`, `409 order-not-dispatched`, `409 line-not-of-order`, `401`).
- **State-code seed deviation (recorded here; the 0053 comment used to point at the empty Spec Change Log).** The Tasks list's parenthetical "26-Ladakh, 37-AP, 38-Other-Territory" transposes the official CBIC/e-way-bill codes. The seed follows the official list: 26 = Dadra & Nagar Haveli and Daman & Diu, 37 = Andhra Pradesh, 38 = Ladakh, 97 = Other Territory, 99 = Other Country; 25 and 28 are absent (pre-merger and pre-bifurcation codes). The count is still 38, as pinned.
- **2026-10-03 — code-review patch round applied (26 patches; D1–D3 decided, D4 deferred).** In behaviour terms:
  - an override on an acceptance-priced line → `409 line-already-priced`, and the frozen rate always wins;
  - no supplier GSTIN → blocking `supplier-gstin` gap;
  - the delivery ACKs data faults and rethrows only transient errors (so the 7-2 writeback on the same event is never starved);
  - a command that loses the insert race retries once, so its rates apply and its key and audit row land;
  - the seller of record is the tenant;
  - the origin GSTIN/state mismatch now warns, and the destination warning no longer depends on the origin resolving;
  - validation runs behind permission and replay in both the invoicing and registration commands;
  - FY and `issuedAt` share one clock read;
  - a blank GSTIN reads as absent at every DTO edge.

  Tests added: a forced (barrier) race, AC2's relay retry, the delivery postures, issuance-event and revision assertions, hash pins, the GSTIN round-trip, alias and ampersand cases, and the duplicate-line and already-priced refusals. Mutation-checked: removing the race retry, the flip's `firstIssuance`, or the revision bump each fails a test. Full suite 1165/1165.
- **Meta docs written (to commit last):** API-SURFACE invoicing section and capability #34. The "100 routes across 12 controllers" header was already stale before 8-1 (133 operations at baseline), so it was restated from the exported document. Also a PENDING `## invoicing` section and the epic-8-context module-name amendment. A `docs/design/modules/invoicing.md` module doc is not written yet; it belongs to story close, as 7.2's channels doc did.

- **2026-10-03 — FE code-review patch round applied (17 patches, Rule 46 decided "add now").**
  - The printout now carries the GST Rule 46 particulars: per-tax rates, the place-of-supply state name, the total in words (Indian system), and a signatory block. The state name comes from a 38-entry map mirroring the seed, never from the address.
  - The date is the IST calendar date.
  - The quantity is in the snapshot's unit, with the catalog lending precision only.
  - The print stylesheet collapses non-print content instead of hiding it, and prints light.
  - The two stale-line refusals now actually re-read the invoice.
  - The success banner is keyed to its invoice.
  - The document reader checks every field it renders.
  - Copy and derivations moved to `src/lib`.
  - The mappers carry the house set.

  Two defects were found by the new tests themselves:
  - the success banner vanished on the post-save remount (fixed earlier);
  - the list swapped the table for a loading line on every page change, which remounted `DataTable` onto page one, so Prev never enabled. Fixed with the outbound-orders keep-mounted pattern.

  Mutation-checked: removing key reuse, the key reset on edit, or the refusal re-read each fails a test. wms-fe 723/723.

## Spec Change Log

<!-- Append-only. Empty until the first bad_spec loopback. -->

1. **2026-10-03 — gap entries gain a structured `orderLineId` (FE loopback, WMS-BE #70).** The pinned document shape `gaps: [{ kind, detail }]` gave the FE pricing dialog no structured way to find the unpriced lines. The document lists priced lines only, the order read carries no rate, and the line id lived only in `detail` prose. Amended to `gaps: [{ kind, detail, orderLineId? }]`, with `orderLineId` set on the line-scoped kinds (`unpriced-line`, `hsn-gap`). The change is additive and was decided by the story owner. The gap it fixes was visible at design time, because the Design Notes pinned the document without asking who consumes the gaps.

## Review Triage Log

| # | Severity | Finding | Verdict | Disposition |
|---|----------|---------|---------|-------------|
| 1 | high | "operator sets rates" has no command; awaiting-data flow unimplementable as written; channel kit case never un-parks | high — confirmed (order.command.ts has no edit route/command) | Amended: rate override rides the regenerate command payload, frozen into the invoice document; `order_lines` untouched post-dispatch (Never-rules updated) |
| 2 | high | order_id indexed but uniqueness claimed — concurrent race is the double-tax scenario | high — confirmed | Amended: `UNIQUE (tenant_id, order_id)`; loser adopts replay posture (matrix + Never-rules + AC updated) |
| 3 | high | tenant-level GSTIN default has no storage home (no `tenants.gstin`, no tenancy task) | high — confirmed | Amended: `tenants.gstin` in migration, stamped by the tenant registration command; settings-edit route deferred to PENDING |
| 4 | medium | POS derivation ignores the GSTIN's own state code; mismatch can print a wrong `supply_type` | medium — confirmed | Amended: GSTIN first-two-digits resolve POS for registered consignees, address text only when GSTIN null |
| 5 | medium | rounding policy implicit; "totals = sums of lines" asserted but rupee-rounding question never stated | medium — confirmed | Amended: paise-exact everywhere, no rupee rounding in stored math (display-only rounding flagged to 8-2's regulatory pass) |
| 6 | medium | pre-8-1 dispatched orders silently uninvoiced with no stated decision | medium — confirmed | Amended: explicit no-backfill decision (Never-rules) |
| 7 | medium | hash-input change (lineFingerprint/payloadHash) silent — an 11-1-shaped break | medium — confirmed | Amended: pin named in Code Map + Design Notes (rate in line fingerprint, GSTIN in create hash; pre-deploy idempotence keys replayed by old clients break as they did for 11-1) |
| 8 | medium | migration 0053's seed data has no verification hook — the repo's known burn class | medium — confirmed | Amended: seed-proof assertions in `test/invoicing.spec.ts` (row count = 38, fixtures resolve) |
| 9 | med-low | UTGST arm unnamed before the CHECK freezes | med-low — confirmed | Amended: UTGST convention (stored in `sgst_paise`, rendered "SGST/UTGST") |
| 10 | med-low | "37 India rows" asserted with no source; real CBIC list is 38 entries | med-low — confirmed | Amended: seed named (CBIC state-code list, 38 entries), count pinned in the seed-proof test |
| 11 | low | `invoice.issued` has no consumer; awaiting→issued flip invisible on an open surface | low — accepted as 8-1 scope | Noted in Design Notes; consumers are future epics/8-2 |
| 12 | low | document snapshot shape left to implementation while 21-5/13/14 are named as future consumers | low — confirmed | Amended: snapshot field set pinned (header/seller+buyer/POS/lines-with-source/totals/gaps/revision) in Tasks (generator) — see Design Notes |

## Design Notes

- **Module name**: `src/modules/compliance/` is taken (temperature excursions, 12-5) — the new module is `invoicing/`. This amends epic-8-context's "new `compliance/` module" wording.
- **Rate freeze**: `order_lines.rate_paise` is the point-in-time truth set at order create; the override path prices unpriced lines WITHOUT touching the outbound-owned table — the invoice document becomes the freeze point for anything overridden.
- **Document snapshot shape (pinned)**: `{ header: { invoiceNo, fyLabel, orderRef, issuedAt, supplyType, placeOfSupply, originGstin, consigneeGstin, originAddress, consigneeAddress }, seller: {name, gstin}, buyer: {name, gstin?}, lines: [{ orderLineId, skuCode, skuName, hsn, qtyMilli, uom, ratePaise, rateSource, taxablePaise, gstBps, cgstPaise, sgstPaise, igstPaise, hsnGap }], totals: { subtotal, gst, payAble } , gaps: [{ kind, detail }], revision }` — client-agnostic for 21-5 (no warehouse-channel specifics inside).
- **Arithmetic**: half-up at the line boundary; all stored math paise-exact; totals are sums of lines with the two-sum invariants checked in `arith.ts`. No rupee rounding in stored values (GST practice rounds payable to a rupee; that belongs to the print layer at most and flags to the 8-2 regulatory pass — an explicit PENDING-class note, not silence).
- **Place of supply**: GSTIN's first two digits ARE the state code and outrank address text for registered consignees; text-based `gst_state_codes` resolution exists for GSTIN-lacking (B2C) consignees. A GSTIN/text mismatch logs a `pos-discrepancy` warning; the GSTIN wins.
- **Numbering**: one series row per tenant per FY (`FY-2627`): `series_seq` allocated under the row lock inside the generate tx; stamped only on first `issued`.
- **Hash pinning (the 11-1 shape)**: `lineFingerprint` becomes `{skuId, quantity, ratePaise}` and the create `payloadHash` spans `consigneeGstin` — deliberate, commented, same break profile as 11-1's destination add: pre-deploy idempotency keys replayed by old clients hash mismatch and are treated as new commands (existing behavior family; tests pin the new shapes).
- **No adapter port**: 8-1 makes zero external calls (portal/GSP transports and `EwayGateway` are 8-2); the metered-port pattern applies then.

## Verification

**Commands:**
- `bun run test -- test/invoicing-arith.spec.ts test/invoicing.spec.ts` -- expected: all green (NEW suites; never two jest runs concurrently).
- `bun run test -- test/` -- expected: full suite green; `bun run lint check`; `bun run typecheck` -- clean.
- `grep -rn "GstBps" src/` -- expected: the primitive now has consumers (was zero before this story).