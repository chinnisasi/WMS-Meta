---
title: 'Late receipts against a closed or cancelled ASN or PO pend for approval — no scanned carton is ever lost'
type: 'bugfix'
created: '2026-10-10'
status: 'ready-for-dev'
route: 'dispatch'
review_loop_iteration: 0
context:
  - '_bmad-output/implementation-artifacts/epic-21-context.md'
  - '_bmad-output/implementation-artifacts/spec-21-6-advance-shipment-notices.md'
  - '_bmad-output/implementation-artifacts/spec-21-6b-handheld-asn-receiving.md'
  - '_bmad-output/implementation-artifacts/epic-21-retro-2026-10-10.md'
  - 'docs/design/SYSTEM-DESIGN.md'
  - 'docs/design/IMPLEMENTATION-GUIDE.md'
  - 'docs/design/modules/inbound.md'
  - 'docs/design/modules/putaway.md'
  - 'docs/design/mobile/SYSTEM-DESIGN.md'
  - 'docs/design/frontend/IMPLEMENTATION-GUIDE.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** The epic-21 retro (X1, action A1) found that a handheld receipt replayed after its document went terminal is lost.
- **Server:** `submitGoodsReceipt` refuses a cancelled or closed ASN with 409 `asn-not-open` (`receiving.command.ts:603-605`), and a closed PO with 409 `po-not-open` (`:568-571`).
- **Device:** classifies both as `rejected`. The review queue's apply re-runs the same payload and gets the same 409, so only discard remains. The cartons are on the dock with no GRN.
- **Related defect:** approving *any* over-receipt puts its excess in the Receiving bin, but putaway only derives work from the GRN line's original `applied_qty`. That excess never gets a putaway task (`putaway.facade.ts:259-351`).

**Approach:**
- **Accept and hold.** A receipt against a terminal document is accepted: its lines become over-receipts pending approval against that document, which an operator approves (into stock) or rejects in the existing queue.
- **Closed PO with an open successor.** The receipt is re-targeted to that successor, where the goods are still expected.
- **Putaway.** It counts approved over-receipt excess as work, for every document.

**Decisions (human, 2026-10-10):**
1. A late receipt on a cancelled or closed document is booked as an **over-receipt pending approval against that document**, with the document link kept. It is never dropped, and never booked straight to stock.
2. **Unmatched lines pend too.** That covers a line with no document-line reference, a SKU that differs from its line, and (from review) a line id that no longer exists. This needs an additive migration so an over-receipt may carry no line id.
3. **POs get the same rule.** A closed PO's lines are `cancelled` or `carried`; there is no cancelled line on an open PO.
4. **(review) Putaway is fixed for all approvals.** Approved over-receipt excess becomes putaway work, on open and terminal documents alike. Units already stranded this way also surface as tasks.
5. **(review) A carried line re-targets to the successor.** A receipt against a closed PO that has an open successor (following `carried_from_po_id`) is booked against that successor:
   - lines whose SKU matches an open successor line receive normally, applied up to its remaining with any excess pending;
   - every other line pends with no line credited.

## Boundaries & Constraints

**Always:**
- **Terminal documents.** An ASN is terminal when it is `cancelled` or `closed`; a PO when it is `closed`. Receiving into one no longer throws `asn-not-open` / `po-not-open`.
  - The status check moves **after** the warehouse check. A terminal document in another warehouse is now 409 `document-warehouse-mismatch` (a deliberate change, with a test).
  - The remaining refusals and their order are unchanged: device, role, replay, shapes, warehouse, SKUs, kit (whole request).
- **Terminal arm (no re-target).**
  - Every line's applied quantity is 0, and its whole physical quantity is the excess. The open remainder counts as 0, even when `announced − received > 0`.
  - Each line gets an `over_receipts` row (`pending`):
    - matched (same SKU, known line) → its line id;
    - no reference, a SKU mismatch, or an **unknown line id** → line id **null**.
  - The GRN line's `po_line_id` / `asn_line_id` equals the over-receipt row's line id.
  - Nothing goes to `unmatchedLines` or `rejectedLines`; every line is reported only through `excessQty`.
  - No `grn.received`, no `received_qty` bump, and no status re-derivation.
  - The GRN, the outbox `grn.recorded` and one `over_receipt.requested` per row are written as today.
- **Re-target arm (closed PO with a successor).**
  - Walk `carried_from_po_id` forward (successor = the PO whose `carried_from_po_id` is this one) to the first `open` PO in the **same warehouse**, at most 10 hops.
  - **None found** → the terminal arm on the original PO.
  - **Found** → the GRN header's `po_id` is the successor, and lines are resolved by **SKU** against the successor's open lines:
    - exactly one open successor line for the SKU → the normal open-document path (applied up to remaining, excess pends against that successor line);
    - zero or several → pend against the successor with a null line.
  - The device's original `poLineId`s are only used to look up each line's SKU on the closed PO. A line naming an unknown id pends with a null line.
  - The response reports what was booked (the successor's code in the GRN snapshot).
- **Open documents.** Submit is unchanged; existing tests pin it.
- **Migration `drizzle/0066_over_receipt_optional_line.sql`.** Follow IMPLEMENTATION-GUIDE §113-126:
  - **The constraint:** `DROP` then re-`ADD` `over_receipts_document_pair` as `(po_id NOT NULL AND asn_id NULL AND asn_line_id NULL) OR (asn_id NOT NULL AND po_id NULL AND po_line_id NULL)`.
  - **A probe DO-block,** modelled on `0064:186-320`:
    - it accepts a PO row with a null line, an ASN row with a null line, and fully lined rows;
    - it refuses no document, both documents, a PO with an ASN line, an ASN with a PO line, and a line with no document — each asserted by `CONSTRAINT_NAME`;
    - a sentinel rolls the accepted rows back.
  - **Journal and snapshot:** a journal entry and `0066_snapshot.json`, which is 0065's content with a new id and prevId, since CHECKs are not snapshotted. `db:generate` must then report no changes.
  - **Policy:** forward-only, with no pre-flight (relaxing a CHECK strands nothing). Rollback-safe: older code already tolerates a null `poLineId` (`receiving.dto.ts:471-473`, the FE `lineContext`).
- **Approve and reject.** Their null-line branches (`receiving.command.ts:1131-1182`) have never been reached since 0064, so they are new behaviour and get tests for both a PO row and an ASN row.
  - Approving a null-line row appends `grn.received` with `{grnId, poId|asnId}` (a valid shape, `ledger-registry.ts:56`) and credits no line.
  - Approving a lined row on a terminal document credits that line. **Neither re-derives** a terminal document; PO status is never derived at all.
- **Putaway counts approved excess** in all three derivations: the task list (`putaway.facade.ts:259-351`), the putaway command (`putaway.command.ts:317-352,488`), and the Overview "awaiting putaway" tile (`kpis.ts:362-364`).
  - **The line's putaway quantity** = `applied_qty + Σ over_receipts.excess_qty WHERE status = 'approved' AND grn_line_id = line.id`. A line qualifies when that sum is > 0. The remaining quantity stays `min(that, Receiving-bin on-hand)`.
  - **GRN lines stay immutable.** Read the over-receipt sum the way putaway reads GRN lines today. If `architecture.spec.ts` forbids the direct read, use an `InboundFacade` read.
- **Web (no BE DTO change).** The over-receipt queue:
  - reads document status from the PO and ASN details it already fetches (`use-inbound.ts:310-330`) and shows "· cancelled" / "· closed";
  - labels a null-line row "Unmatched line" (unmatched = `asnId ? asnLineId === undefined : poLineId === null`);
  - drops "+N over open" for late rows ("+N late receipt");
  - gives `approvedReason` null-line copy ("applied to stock; no line credited");
  - corrects the blurb (`over-receipt-queue.tsx:111-113`) and the `use-inbound.ts:255-258` comment.
- **Docs and comments:**
  - `receiving.controller.ts:91` (409 text);
  - `receiving.command.ts:291`;
  - `schema.ts:1780-1783`;
  - `receiving.dto.ts:478`;
  - the `po-line-not-open` enum stays (`receiving.dto.ts:250`) for older clients, and its arm (`:714-727`) becomes defensive.
- **Tests (BE):**
  - **One per matrix row,** each asserting the pending rows, no ledger event, document status and `received_qty` unchanged, and `unmatchedLines`/`rejectedLines` absent.
  - **Approve and reject** on null-line PO and ASN rows, and on a lined terminal row.
  - **Putaway:**
    - an approved over-receipt on an open PO produces a task for its excess;
    - a late receipt approved → a task;
    - the awaiting tile counts it.
  - **One catch-weight terminal receipt** (handling units settle by `grnLineId`).
  - **Re-target:**
    - a matched carried SKU applies to the successor;
    - an unmatched one pends against the successor;
    - no open successor → the closed PO pends.
  - **Replaced assertions:**
    - `asn.spec.ts:398-401` (the CHECK shapes: two become accepted, the four others stay refused);
    - the closed-ASN arm split out of `asn.spec.ts:569`;
    - `receiving.spec.ts:746`, `:767-770` and `:805-810`.
  - **Stuck queue op.** Port the vendor and ASN helpers into `review-reports.spec.ts`, cancel, then `reportRow('grn.submit', …, {problemCode:'asn-not-open'})`, apply → 201 and pending rows.
  - **Migration.** The probe runs under the suite's migrate.
- **Tests (FE).** Queue labels and status suffix; null-line approve copy; "+N late receipt".
- **Tests (mobile, fixtures only, no code change).** `goodsReceiptNote` on an all-excess 201 prints only "held for approval".

**Never:**
- booking a terminal-document line straight to stock (re-targeted matched lines are on an open document);
- reopening or re-deriving a terminal document;
- changing open-document submit, the payload hash, or mobile code;
- mutating GRN lines on approve;
- a new error code;
- changing billing (see Design Notes).

## I/O & Edge-Case Matrix

| Scenario | State | Expected | Error |
|---|---|---|---|
| Cancelled ASN | A replayed receipt, matched line | 201; pends on that ASN line; ASN stays cancelled | — |
| Closed short ASN | Remainder 5; 3 arrive late | 201; all 3 pend | — |
| Unmatched or unknown line | Terminal ASN or PO; no reference, SKU mismatch, or a removed line id | 201; pends with a null line | — |
| Closed PO, no successor | Replayed receipt | 201; pends on the closed PO's lines | — |
| Closed PO with a successor | Carried SKU, 4 arrive, successor remaining 3 | 201 on the successor: 3 applied, 1 pends | — |
| Successor, SKU not carried | A cancelled-line SKU | Pends on the successor with a null line | — |
| Approve, null line | A pending unmatched row | `grn.received`; no line credited; a putaway task appears | — |
| Approve on an open PO | Any approved over-receipt | Its excess becomes a putaway task | — |
| Reject | Any late row | `rejected`; no stock | — |
| Open document | Any receipt | Submit identical to today | — |
| Stuck queue op | Applying an op refused earlier | 201 with pending rows | — |
| Wrong warehouse | A terminal document in another warehouse | — | 409 `document-warehouse-mismatch` (changed from `*-not-open`) |
| Migration CHECK | Both documents / none / a split pair / a line without its document | — | refused by the CHECK |

</frozen-after-approval>

## Code Map

`wms-be` paths are relative to `workspace/core/backend/wms-be`; `wms-fe` to `workspace/core/frontend/wms-fe`; `wms-mobile` to `workspace/core/mobile/wms-mobile`.

- **Receiving, `src/modules/inbound/receiving.command.ts`:**
  - hash `:328-360`; replay `:419-431`; kit `:487-500`;
  - PO arm `:557-575`; ASN arm `:592-614`;
  - `openRemaining` `:648-654`;
  - fold: unmatched `:687-693`, unknown `:697-706`, SKU mismatch `:708-713`, `po-line-not-open` `:714-727`, applied/excess `:729-752`;
  - GRN line `:758-770`; catch-weight `:810-816`; ledger `:837-865`; `received_qty` `:894-905`; over-receipts `:917-936`;
  - response `:960-980`; outbox `:981-1007`;
  - `decideOverReceipt` `:1026` (null-line `:1131-1182`, credit `:1183-1240`, handling units `:1250-1261`).
- **PO:** `src/modules/inbound/po.command.ts:117` (statuses); close and carry `:556-601` (successor lines matched by SKU only; `carried_from_po_id` on the successor, `schema.ts:1529`).
- **ASN:** `src/modules/inbound/asn.command.ts:72-75`, `:195-205`, `:289-333`, `:772-818`.
- **Schema:** `schema.ts:1771-1783` (`over_receipts`); `drizzle/0064_*.sql:128-138` (the CHECKs) and `:186-320` (the probe model); `0065_snapshot.json`.
- **Putaway:** `src/modules/putaway/putaway.facade.ts:204,259-351`; `putaway.command.ts:317-352,488`; `src/modules/reporting/kpis.ts:362-364`.
- **API:** `src/api/receiving.controller.ts:91,255-319`; `receiving.dto.ts:250,471-478`; `receiving.facade.ts:361-402`.
- **Web:** `src/components/conflicts/over-receipt-queue.tsx:111-113,193,234`; `src/lib/over-receipt.ts:29-42`; `src/lib/use-inbound.ts:255-258,310-330`.
- **Mobile (fixtures only):** `src/state/replay-classification.ts:196-231`; `replay-classification.test.ts:510-607`.
- **Tests:**
  - `test/asn.spec.ts:398-401,516,569,651,693,709`;
  - `test/receiving.spec.ts:525,739-810,1112`;
  - `test/review-reports.spec.ts:153-339,977`;
  - putaway: `test/putaway.spec.ts`.

## Tasks & Acceptance

**Execution:**
- [ ] `wms-be` migration 0066 + journal + snapshot + `schema.ts` comment -- decision 2.
- [ ] `wms-be` `receiving.command.ts` -- terminal arm, re-target arm, status-check order, comments -- decisions 1, 3, 5.
- [ ] `wms-be` putaway (facade, command) and `kpis.ts` awaiting tile -- count approved excess -- decision 4.
- [ ] `wms-be` controller/DTO descriptions; `openapi.json`.
- [ ] `wms-be` tests -- every matrix row, the replaced assertions, approve/reject, putaway, catch-weight, re-target, stuck op, migration probe.
- [ ] `wms-fe` -- `api:generate`; queue labels, status suffix, copy; tests.
- [ ] `wms-mobile` -- one `goodsReceiptNote` fixture test (no code change).
- [ ] Meta docs:
  - `modules/inbound.md`: terminal-document rule, re-target, invariants that now hold only for on-time receipts, the event payload without a line id;
  - `modules/putaway.md`: approved excess is work;
  - `API-SURFACE.md`: submit no longer returns `asn-not-open` / `po-not-open`; the warehouse-mismatch order;
  - both repo contracts;
  - `PENDING.md`:
    - close the epic-21-retro A1 entries;
    - add: a pending late line is billed as a receipt line at submit even if rejected;
    - add: the `grnVariances` tile counts late lines as over-receipts;
    - add: an approved late receipt's dock-to-stock is measured from GRN creation;
    - add: the portal shows a cancelled ASN with received > 0 after a lined approval, and null-line approvals are invisible to the client.

**Acceptance Criteria:**
- Given an ASN cancelled after a device received against it offline, when the device syncs, then the receipt settles as "held for approval" and the operator sees it in the queue as "ASN … · cancelled". Approving it puts the units in stock **with a putaway task**.
- Given a PO closed with a carried successor, when a stale device receives a carried SKU against the closed PO, then it books against the successor.
- Given the full BE, FE and mobile suites, lint and typecheck, when run, then they pass.

## Implementation Notes

## Spec Change Log

## Review Triage Log

Design review (2026-10-11), three lenses: receiving and approve (R), migration consumers (M), contracts and tests (C).

| # | Lens | Finding | Verdict | Disposition |
|---|---|---|---|---|
| 1 | R, M | An unknown line id on a terminal document is still rejected and dropped | high | Fixed: it pends with a null line (decision 2 extended) |
| 2 | R, C | "Cancelled PO line on an open PO" cannot happen: line status changes only at close; the replaced-test list was wrong | high — verified, `po.command.ts:594-601` | Fixed: decision 3 recast; tests `:746, :767-770, :805-810` |
| 3 | R | Approved over-receipt excess never gets a putaway task, for any document (pre-existing) | high — verified, `putaway.facade.ts:259-270,351`; approve never touches `applied_qty` | **Human decision 4**: putaway counts approved excess everywhere |
| 4 | R, C | Approving a closed PO's carried line double-counts against the successor; there is no data for a successor note | medium | **Human decision 5**: re-target to the successor |
| 5 | M | `asn.spec.ts:398-401` pins the opposite of the new CHECK | high — verified | Fixed: listed as a replaced assertion |
| 6 | M, R | The migration checklist was named but not specified (drop/re-add, probe, journal/snapshot, policy) | high | Fixed: Boundaries |
| 7 | M, R, C | `unmatchedLines` on a terminal document would make the device print a false "booked" | medium | Fixed: never emitted; a mobile fixture test |
| 8 | M | The GRN line's own line reference was unspecified | medium | Fixed |
| 9 | M, C | FE copy is wrong for null-line and late rows ("+N over open", approvedReason, blurb, comment) | medium | Fixed |
| 10 | C | `documentStatus` duplicates the PO/ASN detail the FE already fetches | medium | Fixed: no BE DTO change |
| 11 | C | The wrong-warehouse row is not unchanged (the status check runs first today) | low | Fixed: reordered, deliberate, tested |
| 12 | C | The stuck-op test needs ASN helpers ported into `review-reports.spec.ts` | medium | Fixed: named |
| 13 | R, M | "Approve already handles a null line" is untested since 0064 | medium | Fixed: treated as new behaviour, tested |
| 14 | R | No PO status derivation exists | low | Fixed: stated as fact |
| 15 | M | Null-line `over_receipt.*` payloads carry `asnId` without `asnLineId` | low | Fixed: documented in `inbound.md` |
| 16 | M | The `grnVariances` tile, dock-to-stock and the portal are affected by late receipts | low | Fixed: PENDING entries |
| 17 | R, C | Stale controller and command 409 text and schema/DTO comments | low | Fixed: listed |
| 18 | R | Close/cancel vs a late submit: no new race (same lock order); pending rows on a cancelled ASN are fine since it has no transitions left | — | Recorded |
| 19 | C | Mobile claims: no named `po-not-open` arm; no cached document status | low | Fixed: Design Notes |

## Design Notes

- **Why pend, not apply.** A terminal document usually means "don't take these goods". Pending keeps the physical fact (the GRN) and the document link, and leaves the decision with an operator.
- **Why re-target a carried line.** Close moved the open quantity to the successor, so that is where the goods are expected. Booking there avoids double-counting and needs no operator action for the matched part.
- **Why putaway reads approved excess, not a GRN-line update.** GRN lines are treated as immutable records (21-5b drills reproduce them). The approval is its own row, so summing it keeps both facts honest. Previously stranded excess becomes visible work, which is correct.
- **Mobile.** The device already settles a 201 and prints "held for approval" for excess lines. A cancelled ASN stays on its snapshot only until the next refresh; it keeps no document status. Its `asn-not-open` branch (`replay-classification.ts:70-77`) becomes unreachable against this server. There was never a `po-not-open` branch (generic `rejected`).
- **Billing (accepted, pre-existing).** `receiptLinesPredicate` counts a GRN line at submit whatever its applied quantity, so a late line later rejected is still billed. Recorded in PENDING.

## Verification

**Commands:**
- `cd workspace/core/backend/wms-be && bun run test -- test/receiving.spec.ts test/asn.spec.ts test/review-reports.spec.ts test/putaway.spec.ts` -- expected: pass (never two jest runs at once)
- `cd workspace/core/backend/wms-be && bun run db:generate && git status --porcelain drizzle` -- expected: no changes after 0066
- `cd workspace/core/backend/wms-be && bun run test && bun run lint && bun run typecheck` -- expected: pass
- `cd workspace/core/frontend/wms-fe && bun run api:generate && bun test && bun run typecheck && bun run lint` -- expected: pass (the drift guard fails until the BE merges)
- `cd workspace/core/mobile/wms-mobile && bun test` -- expected: pass
