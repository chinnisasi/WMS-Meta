---
title: 'GST-compliant invoicing'
type: 'feature'
created: '2026-10-03'
status: 'ready-for-dev'
route: 'dispatch'
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
- [ ] `drizzle/0053_invoicing_core.sql` -- migration adding: `invoices` (`tenant_id`, `order_id` with **UNIQUE (tenant_id, order_id)**, `warehouse_id`, `invoice_no` unique per tenant, `fy_label`, `series_seq`, `status` CHECK `('awaiting-data','issued','voided')`, origin/consignee GSTIN snapshots, `place_of_supply` code, `supply_type` CHECK `('intra','inter')`, subtotal/gst/total paise, `revision`, `document` jsonb, ts columns), `invoice_lines` (invoice_id, order_line_id, sku code/name + hsn snapshots, qty_milli, rate_paise, rate_source CHECK `('order_line','manual')`, taxable_paise, gst_bps, cgst/sgst/igst paise, hsn_gap bool), `gst_state_codes` (the **CBIC GST state-code list, 38 entries** incl. 26-Ladakh, 37-AP, 38-Other-Territory, 07-Delhi: normalized state name → code — hand-seeded, count pinned), and the owned columns `tenants.gstin`, `warehouses.gstin`, `orders.consignee_gstin`, `order_lines.rate_paise`. Seed proof rides the test task.
- [ ] `src/modules/invoicing/arith.ts` -- exact helpers: half-up `divRound(milliQty, paiseRate)` and the bps division at the line boundary, CGST/SGST split with the remainder paise to SGST (rendered "SGST/UTGST"), IGST for inter-state, and the two-sum invariants (`subtotal + gst = total`, `cgst+sgst+igst = gst` when intra) as checked totals.
- [ ] `src/modules/invoicing/generator.ts` -- derive-from-facts computation shared by the delivery handler and the command: re-derive dispatched qty from `picks` (kit parent lines drop at zero), resolve rates (`order_lines.rate_paise` else command override), resolve POS (consignee GSTIN prefix first two digits when present; else `gst_state_codes` lookup of destination state; origin likewise from warehouse GSTIN/`origin_state`; classify intra vs inter), resolve supplier GSTIN (warehouse `gstin` else tenant `gstin`), compute lines per `arith.ts`, build the document snapshot.
- [ ] `src/modules/invoicing/command.ts` -- manual generate/regenerate command on the full skeleton, `{orderId, rates?}` payload: creates or recomputes the order's single invoice; `awaiting-data → issued` flip stamps the FY number (series row `FOR UPDATE`); unique-violation → replay posture. `delivery.ts` subscribes to `order.dispatched` and calls the same generator (channels-delivery posture: malformed ACK, failure meter+rethrow), emitting `invoice.issued` in-tx when issuance happens. `facade.ts`/`view.ts`/`events.ts`/`module.ts` complete the module file set; capability `invoice.generate` in `src/modules/tenancy/permissions.ts`.
- [ ] `src/modules/outbound/order.command.ts` (+controller) -- create command accepts optional `ratePaise` per line and `consigneeGstin`; stamps the new columns; hash/fingerprint updates pinned per Design Notes. `src/modules/tenancy/` -- tenant registration accepts optional `gstin`; warehouse create accepts optional `gstin`.
- [ ] `src/api/invoicing.controller.ts` + `docs/design/API-SURFACE.md` -- routes: `GET /tenants/{t}/invoices` (cursor page), `GET /tenants/{t}/invoices/{id}` (error arm: 404), `POST /tenants/{t}/invoices` `invoice.generate` (refusals: 404 unknown order, 409 not-dispatched, 409 line-not-of-order). Controller thin, no rules.
- [ ] `test/invoicing-arith.spec.ts` -- the exact-math table: half-up divisions, remainder split, intra/inter, MAX_QUANTITY_MILLI × paise safe boundaries, zero-rate/zero-qty, two-sum invariants.
- [ ] `test/invoicing.spec.ts` -- real-DB: event-driven issuance, awaiting-data → regenerate-with-rates → issued, kit parent exclusion, hsn-gap warning, state gap, GSTIN-prefix POS wins over state text, **concurrent generate race → no double row**, event double-delivery → same invoice content, refusals, FY numbering sequence, **seed proof: `gst_state_codes` row count = 38 and every fixture state resolves**.
- [ ] FE `wms-fe` -- extend `/compliance`: invoices Section (per-order invoice list, detail in expanded row), printable-invoice render + print action, `fetchApiInvoices*` wrappers, regenerate dialog carrying per-line rate overrides gated by `invoice.generate` in the mirrored `src/lib/users.ts`, `use-invoices` external-store hook. Rides AFTER the BE PR merges (generated-client CI pins the order).
- [ ] Meta `docs/` -- API-SURFACE rows; epic-8-context amendment: "compliance/" → `invoicing/` + collision note; channels.md/PENDING rows: `invoice.void`/credit notes deferred, tenant-settings GSTIN edit route deferred (8-1 stamps GSTINs at registration/warehouse-create only).

**Acceptance Criteria:**
- Given a dispatched order with priced lines and resolvable POS, when the event delivers, then an `issued` invoice exists with `subtotal + gst = total` and `cgst + sgst = gst` exactly, in paise.
- Given generation throws, when the relay retries, then dispatch state is untouched and the invoice eventually issues with no duplicate row (UNIQUE key holds under the concurrent race).
- Given unpriced lines at dispatch, the invoice parks `awaiting-data`; after the operator regenerates with per-line rates, it flips `issued` with the same invoice number — and `order_lines.rate_paise` stayed unchanged.
- Given two concurrent generate invocations, one replays; no invoice double-taxes.

## Implementation Notes

<!-- Agent-owned. Append-only during implementation. -->

## Spec Change Log

<!-- Append-only. Empty until the first bad_spec loopback. -->

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