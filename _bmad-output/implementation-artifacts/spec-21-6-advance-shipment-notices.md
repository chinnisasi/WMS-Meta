---
title: 'Advance shipment notices — announce an inbound shipment; receiving books against a PO or an ASN in one flow'
type: 'feature'
created: '2026-10-08'
status: 'ready-for-dev'
route: 'dispatch'
baseline_commit: '3527a8ef462e0ef22f5198a19ad157d097fb5583'
review_loop_iteration: 0
context:
  - '_bmad-output/implementation-artifacts/epic-21-context.md'
  - '_bmad-output/specs/spec-3pl/SPEC.md'
  - '_bmad-output/specs/spec-3pl/schema.md'
  - '_bmad-output/specs/spec-3pl/billing-model.md'
  - '_bmad-output/specs/spec-3pl/architecture.md'
  - '_bmad-output/implementation-artifacts/spec-21-5b-dispute-drill-down.md'
  - 'docs/design/SYSTEM-DESIGN.md'
  - 'docs/design/IMPLEMENTATION-GUIDE.md'
  - 'docs/design/API-SURFACE.md'
  - 'docs/design/modules/inbound.md'
  - 'docs/design/modules/billing.md'
  - 'docs/design/modules/reporting.md'
  - 'docs/design/mobile/SYSTEM-DESIGN.md'
  - 'docs/design/mobile/IMPLEMENTATION-GUIDE.md'
  - 'docs/design/frontend/SYSTEM-DESIGN.md'
  - 'docs/design/frontend/IMPLEMENTATION-GUIDE.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** A 3PL learns what a client is sending only when the truck arrives. CAP-9 asks for two things:
- a client can announce an inbound shipment beforehand;
- receiving can book against that announcement exactly as it books against a purchase order, with the same partial, blind and over-receipt handling, and reconcile announced against received quantities.

**Approach:** Inbound gains the **advance shipment notice (ASN)**, a document that deliberately mirrors the PO. A goods receipt references exactly one of **a PO, an ASN, or neither (blind)**, through one receiving command.
- Operators create, amend, close and cancel ASNs on the web.
- The device catalog snapshot carries open ASNs.
- Billing, the dispute drill, the over-receipt queue, the GRN views and reporting treat ASN receipts the same way they treat PO receipts.

**Decisions (human, 2026-10-08):**
1. **Split.**
   - This story covers the server, the web and the snapshot arm.
   - **21-6b** covers the handheld receiving against an ASN (`deferred-work.md`).
   - Until 21-6b ships, an ASN can be received only through the device API. The web card says so ("Receiving against ASNs arrives with the next handheld update").
2. **A short ASN is closed by an operator.**
   - Status `closed` joins `announced | partially_received | received | cancelled`. It applies to a partially received ASN and needs a note.
   - A closed ASN leaves the open list and the snapshot. There is no carry-forward.
   - `received` means every line was received in full.
   - `cancelled` means nothing was received.
3. **Closing is blocked while excess is pending.** Closing a PO or an ASN is refused while any of its over-receipts await a decision (409 `over-receipt-pending`).
   - Approve never refuses on document status. That includes a `received` ASN and over-receipts left pending on POs that were already closed before 21-6, so stock that physically arrived is never stranded.
   - Approve locks the document and its line, so a concurrent close and approve serialise. This closes PENDING :48.

## Boundaries & Constraints

**Always:**

- **Tables** (mirroring the PO; no FKs; RLS with the AD-24 client clause):
  - `advance_shipment_notices`:
    - columns `id, tenant_id, client_id, warehouse_id, asn_code, status, expected_at timestamptz NULL, status_note, created_at, updated_at`;
    - `asn_code` is 1–64 characters and **unique on `(tenant_id, client_id, asn_code)`**, because clients supply their own codes.
  - `asn_lines`:
    - columns `id, tenant_id, asn_id, sku_id, announced_qty, received_qty` (milli-units);
    - `announced_qty > 0` and `received_qty ≥ 0`, with no upper ceiling CHECK (an approved over-receipt passes it, as on a PO);
    - no line status.
- **Client.**
  - The request carries `clientId`. It must match the client derived from the line SKUs through `assertSingleClientInTx`, or the request answers 409 `mixed-client` or `sku-client-mismatch`.
  - Amend refuses SKUs from another client.
  - The warehouse is required and active, and is fixed at create.
- **Status.**
  - `announced`, `partially_received` and `received` are **derived** from Σ received against Σ announced per line, in the same transaction as every receipt, approval and amend.
  - Rejecting an over-receipt never changes `received_qty`.
  - `closed` (from `partially_received`) and `cancelled` (from `announced`) are explicit and terminal, and each requires a note of 1–500 code points. Any other transition answers 409 `asn-transition-invalid`.
  - Receiving is allowed only while the ASN is `announced` or `partially_received`; otherwise 409 `asn-not-open`.
  - PO close also answers 409 `over-receipt-pending` while any of the PO's over-receipts are pending.
- **Amend.**
  - Allowed while `announced` or `partially_received`. It may change `expectedAt` and the line set.
  - It is a full line-set replace like the PO: a line without an `id` is new, a line not sent is deleted, and an unknown `id` answers 404.
  - Once a line has received anything, deleting it, changing its SKU, or setting `announced_qty` below `received_qty` answers 409 `asn-line-received`.
  - **The same guard lands on PO amend** (PENDING :50), as 409 `po-line-received`.
  - Limits: at most 200 lines, the same as a PO.
- **Receiving payload and idempotency** — load-bearing, because devices hold queued ops:
  - The command gains `asnId?` and per-line `asnLineId?`.
  - **The hash input** (`receiving.command.ts:275-298`) adds `asnId: command.asnId ?? undefined` and `asnLineId: line.asnLineId ?? undefined`, following the 10.3 `weightsGrams` precedent. An absent key therefore leaves the hash of every existing PO or blind op unchanged. A test pins a pre-21-6 hash literal.
  - The controller maps `asnId` the same way.
  - **The replay rebuild** (`sync-report.command.ts:1122-1137`) adds `asnId: payload.asnId ?? null`, and `PAYLOAD_FIELDS` (`:205-210`) gains `['asnId','uuid-or-null']`.
  - The command **normalises each line to `asnLineId ?? null` before validation**, so an old stored payload re-applies cleanly. A test re-applies a stored pre-21-6 payload.
- **Receiving rules.**
  - Exactly one of `poId`, `asnId` or `blindReasonCode` is given; otherwise 400.
  - A `poLineId` is allowed only with `poId`, and an `asnLineId` only with `asnId`.
  - The ASN and all its lines are locked `FOR UPDATE` exactly where the PO is.
  - A GRN whose warehouse differs from its document's answers 409 `document-warehouse-mismatch`. This applies to POs too.
  - **A line whose SKU differs from its referenced document line, or that has no line reference, settles unmatched:** it is applied in full, with no line reference, no ceiling and no over-receipt. This is the existing no-`poLineId` arm, now used for SKU mismatches on POs as well, so goods that arrived always reach the ledger. Such lines are listed in the response as `unmatchedLines[{index, reason: 'no-line-reference' | 'line-sku-mismatch'}]`.
  - An unknown `asnLineId` is a rejected line, `asn-line-not-found`, mirroring `po-line-not-found`. There is no `asn-line-not-open`, because ASN lines carry no status.
  - `applied = min(qty, remaining open)`. Any excess creates an `over_receipts` row, and `received_qty` takes the same cumulative ceiling.
- **Ledger and approve.**
  - The `grn.received` `referenceDoc` carries `{grnId, poId?, poLineId?, asnId?, asnLineId?}`, with absent keys omitted, on submit **and** on approve (`receiving.command.ts:962-968`). Widen `ledger-registry.ts:51-57`.
  - Approve bumps `asn_lines.received_qty` for an ASN over-receipt, then re-derives the ASN's status.
  - **Lock order** everywhere: over-receipt row → SKUs (by id) → PO or ASN → lines. The reject arm stays lock-free beyond its own row. ASN create and amend read SKUs without locking them, as PO amend does.
- **Database backstops** (migration **0064**):
  - `goods_receipt_notes.asn_id`, with the pairing CHECK written in full:
    - `po_id` set, `asn_id` null, reason null; or
    - `asn_id` set, `po_id` null, reason null; or
    - both null, with reason `IN ('unannounced-delivery','po-not-found','other')`.
  - `goods_receipt_lines.asn_line_id`, with a CHECK that it and `po_line_id` are not both set.
  - `over_receipts.asn_id` and `asn_line_id`, with a CHECK that exactly one of the pairs `(po_id, po_line_id)` and `(asn_id, asn_line_id)` is set, and each pair is set together.
  - Before applying, the migration counts pending over-receipts on closed POs and reports the number in its log.
  - The post-migration assertion probes each CHECK with a refused insert.
- **Readers.**
  - The GRN list's `poless` filter is replaced by `blind` (`true | false`) on `blind_reason_code is [not] null`. `poless` stays accepted as an alias, now meaning "blind", and the tile drill (`kpis.ts:536`) moves to `blind`.
  - The blind-GRN KPI (`kpis.ts:567`) moves to `blind_reason_code`.
  - `asnId`, and `asnLineId` where a line exists, are added (omitted when absent) to the GRN snapshot (`:767-793`), the GRN list rows, the `grn.recorded` and `over_receipt.*` outbox payloads (where `OverReceiptRequest.poId` becomes nullable), and the over-receipt view.
  - `asnLines` joins HISTORY_SOURCES.
- **Snapshot.** `getCatalogSnapshot` gains `openAsns[]`, a direct query on the snapshot transaction. Each entry is `{id, code, clientId, warehouseId, expectedAt, lines{id, skuId, announcedQty, receivedQty, openQty}}`, for the warehouse's ASNs that are `announced` or `partially_received`.
- **Billing and drill.** `receiptLinesPredicate` is unchanged, and a test pins that ASN receipts are counted. The drill's `receipt-line` record gains `asnCode`.
- **Capability and access.**
  - Capability `asn.manage` is held by owner and ops_manager, the same as `po.manage`.
  - Reads are member-open. A portal session is refused 403 **on reads and writes**; 21-7 opens them.
- **Commands** follow the skeleton: hash → permission → replay → validate → lock → write → outbox (`asn.created | amended | closed | cancelled`) → audit → key. Every mutation takes an Idempotency-Key.

**Never:**
- handheld changes (21-6b);
- linking an ASN to a PO;
- auto-close;
- portal entry (21-7);
- a web PO create or amend UI;
- a second receiving path;
- an over-receipt tolerance;
- scanning an ASN code.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected | Error |
|---|---|---|---|
| Create | ACME, WH1, 2 lines | `announced`; on the snapshot | — |
| Client mismatch | `clientId` ACME, a BETA SKU | — | 409 `sku-client-mismatch` |
| Same code, two clients | ACME and BETA both `ASN-001` | Both created | — |
| Partial | 60 of 100 | `partially_received` | — |
| Over | 60 then 50 of 100 | `received`; 10 pending; approve → 110, still `received` | — |
| Close with pending | Partially received, 1 pending over-receipt | — | 409 `over-receipt-pending` (also on PO close) |
| Legacy pending on closed PO | Pre-21-6 row | Approve and reject both still work | — |
| Short close | 80 of 100, no pending | `closed` with note; off the snapshot | — |
| Cancel | 0 received / some received | `cancelled` / — | — / 409 `asn-transition-invalid` |
| Receive closed ASN | — | — | 409 `asn-not-open` |
| Two references | `poId` + `asnId` | — | 400 |
| SKU mismatch (PO or ASN) | Line SKU ≠ referenced line SKU | Applied unmatched; `unmatchedLines` names it; the document line is not bumped | — |
| Wrong warehouse | GRN WH2, document WH1 | — | 409 `document-warehouse-mismatch` |
| Amend received line | Delete or drop below received (PO and ASN) | — | 409 `asn-line-received` / `po-line-received` |
| Amend to complete | `announced_qty` lowered to `received_qty` | Status derives `received` | — |
| Old ops | Queued pre-21-6 PO or blind op, replayed and re-applied | Same hash; applies | — |
| Views | ASN GRN | List, snapshot, over-receipt queue and drill show the ASN code; not blind | — |
| Blind KPI | 1 ASN receipt + 1 blind receipt | 1 | — |
| Duplicate code for same client; portal session | — | — | 409; 403 |

</frozen-after-approval>

## Code Map

- **PO:**
  - tables in `schema.ts:1505-1585`; CHECKs in `drizzle/0011_tiresome_wraith.sql:74-88`;
  - `po.command.ts`: create `:192/:224`, amend `:314` (delete `:394-398`, rewrite `:404-413`, unlocked SKU read `:703-708`), close `:445`, `loadOpenPo` `:650-668`, `lineSnapshot` `:854-867`;
  - `inbound.controller.ts`: tenant-level create, detail and mutations `:115,200,233,286`; warehouse-level list `:165`;
  - `inbound.dto.ts:108-294`: PO limits of 200 lines and a 1–64 character code; per-line `expectedDate` `:142-150`.
- **Receiving:**
  - `receiving.command.ts`:
    - hash input `:275-298`;
    - guard order `:261`;
    - blind validation `:362-379` (the `null` checks at `:376`);
    - locks: SKUs `:1123-1124`, PO `:458-481`;
    - matching `:535-572`;
    - `referenceDoc` `:690-695`;
    - ceiling `:716-738`;
    - over-receipt `:742-824`;
    - snapshot type `:767-793`;
    - `decideOverReceipt` `:843`: locks `:927-932`, approve `:962-992`;
    - GRN code `:1206-1212`.
  - `receiving.controller.ts:112-116` (absent → null); `receiving.dto.ts` (`GrnLineDto.poLineId` `:178`, `RejectedGrnLineDto` `:213`, `GoodsReceiptEntryDto`/`GoodsReceiptDto` `:229,278`, `poless` `:339`).
  - Replay: `sync-report.command.ts:205-210,1122-1137`.
  - `ledger-registry.ts:51-57`.
- **Readers:**
  - `receiving.facade.ts`: list `:230-252`, over-receipt list `:357`, snapshot `:380-466`;
  - `reporting/kpis.ts:536,550,567`;
  - drill `inbound.facade.ts:363-378`;
  - `sku-client.command.ts:65`;
  - `test/architecture.spec.ts:1024-1026,1119,1195,1555`.
- **Blind CHECK:** `drizzle/0013_*:101-110`. **Next migration: 0064.**
- **Web:**
  - `components/inbound/inbound-cards.tsx`: sessioned `:93-95`, PO card `:101`, GRN card `:216` (blind arm `:231-235`), `clientCell`;
  - `lib/use-inbound.ts` (PO code resolution `:197-208`, over-receipt context `:298-306`);
  - `lib/clients.ts` (`showClients` `:33`, `clientLabel` `:38`, `skusForOrderClient` `:165-173`);
  - over-receipt queue `components/conflicts/over-receipt-queue.tsx` (copy `:95,111`) and `lib/over-receipt.ts`;
  - capability mirror `lib/users.ts`.
- **Mobile contract:** `docs/repos/wms-mobile/README.md:33-37`, and the API-SURFACE snapshot row `:99`.

### API (tenant-level like the PO; the list is per warehouse)

| Route | Body / query | Success | Errors |
|---|---|---|---|
| `POST /tenants/{t}/inbound/asns` | `{clientId, warehouseId, asnCode, expectedAt?, lines[{skuId, announcedQty}]}` (quantities in base units, converted like a PO) | 201 ASN | 400, 403, 404, 409 `mixed-client` / `sku-client-mismatch` / duplicate code |
| `GET /tenants/{t}/warehouses/{w}/inbound/asns?status&clientId&cursor&limit` | keyset `(createdAt, id)`, limit 1–100 | 200 page of rows `{id, code, clientId, status, expectedAt, lineCount, announcedTotal, receivedTotal, createdAt}` | 400 `invalid-cursor`, 403 |
| `GET /tenants/{t}/inbound/asns/{id}` | — | 200 ASN `{…row, warehouseId, statusNote, lines[{id, skuId, announcedQty, receivedQty, openQty}]}` | 403, 404 |
| `PATCH /tenants/{t}/inbound/asns/{id}` | `{expectedAt?, lines[{id?, skuId, announcedQty}]}` | 200 | 400, 404, 409 `asn-not-open` / `asn-line-received` / `sku-client-mismatch` |
| `POST …/asns/{id}/close` and `/cancel` | `{note}` | 200 | 400, 409 `asn-transition-invalid` / `over-receipt-pending` |

- **Receiving DTOs.** The command gains `asnId?` and `lines[].asnLineId?`. `GrnLineDto` gains `asnLineId`. `RejectedGrnLineDto.poLineId` becomes nullable, it gains `asnLineId`, and its code list gains `asn-line-not-found`. The response gains `unmatchedLines`. The GRN entry and detail gain `asnId` and `asnCode`, and the over-receipt view gains `asnId`, `asnLineId` and `asnCode`.

## Tasks & Acceptance

**Execution:**
- [ ] `wms-be/drizzle/0064_advance_shipment_notices.sql` (with journal, snapshot and `schema.ts`) -- tables, CHECKs, indexes `(tenant, warehouse, status)` and `(asn_id)`, RLS, the GRN/line/over-receipt columns and CHECKs, the pending-count log, and the probing post-assertion.
- [ ] `wms-be/src/modules/inbound/asn.command.ts` -- create, amend, close and cancel, plus a shared `deriveAsnStatusInTx`.
- [ ] `wms-be` receiving -- the hash and normalisation rules, validation, the ASN lock, the unmatched arm, the warehouse guard, the approve changes (refDoc, ASN bump, derive, locks), the close guards (`over-receipt-pending` on PO and ASN), and the PO amend guard.
- [ ] `wms-be` replay, readers, outbox payloads, snapshot arm, drill `asnCode`, HISTORY_SOURCES, the `blind` filter and KPI, and `ledger-registry`.
- [ ] `wms-be` controller and DTOs per the API table -- then re-export `openapi.json`.
- [ ] `wms-be` permissions, architecture and isolation -- `asn.manage`, ownership, probe count.
- [ ] `wms-be/test/asn.spec.ts` -- cover:
  - every matrix row through the device receiving route **and** the replay path;
  - the pre-21-6 hash literal;
  - a stored old payload re-applied;
  - each new CHECK;
  - the lock order under a close-versus-approve race;
  - vocabularies pinned against the CHECKs.
- [ ] `wms-fe`:
  - **Capability:** mirror `asn.manage`.
  - **ASN card** on `/inbound`: a list (code, client when `showClients`, status, expected date, announced/received totals) and a detail view with lines.
  - **ASN actions:** Create with a client picker that filters the SKU picker (`skusForOrderClient`), then Amend, Close and Cancel, each needing a note and a per-draft key, all gated on `asn.manage`. Include the 21-6b notice.
  - **GRN card:** the column becomes "Document" with PO, ASN and blind arms.
  - **Over-receipt queue:** document-neutral copy, ASN line context, and a mapping for `over-receipt-pending`.
  - **Code:** mappers, hooks and tests.
- [ ] Meta docs:
  - `inbound.md`: the ASN, "PO or ASN or blind", the guards, lock order and hash rule;
  - `billing.md`;
  - `reporting.md`;
  - `mobile/SYSTEM-DESIGN.md` and `mobile/IMPLEMENTATION-GUIDE.md`: `openAsns`, and the `document-warehouse-mismatch` fate (a queued op is dropped as rejected);
  - `API-SURFACE.md`, including the snapshot row `:99`;
  - the three contracts, `wms-mobile` included;
  - 3PL `schema.md`: `closed`, `status_note`, the per-client code uniqueness, and the GRN and over-receipt columns;
  - `PENDING.md`: close :48 and :50; add 21-6b, linking an ASN to a PO, auto-close, and that PENDING :51 (snapshot fan-out) grows with `openAsns`.

**Acceptance Criteria:**
- Given an ACME ASN of 100 units in WH1, when a device receives 60 and then 50, then:
  - the ASN ends `received` with `received_qty` 100 and an over-receipt of 10 pending;
  - approval raises it to 110, still `received`;
  - each GRN line counts once for ACME's `inbound_handling`.
- Given the full BE and FE suites, when run, then they pass.

## Implementation Notes

Baselines: wms-be `3527a8ef462e0ef22f5198a19ad157d097fb5583` (`baseline_commit`), wms-fe `b0123bbe4b2bf9ee0bb22ef83768ef782d06d6a8`.
- Work on `feat/21-6-advance-shipment-notices` in both repos and leave everything uncommitted: no commit, push or PR.
- In wms-be, run `bun run test -- <file>`, and never run two jest invocations at once.
- Edit meta docs in `/Users/sasidhar/Documents/WMS-Meta`.
- Do not touch `wms-mobile` code; its README is a doc.
- Do not touch `/tmp` outside your own scratch files.

## Spec Change Log

## Review Triage Log

*Design review, 2026-10-08: two code-verified reviewers (receiving correctness; API, FE and fit). 28 findings, merged into 20. One went to the human (decision 3); three were settled by the agent (unmatched lines, per-client codes, explicit `clientId`); the rest are folded in.*

| # | Sev | Finding | Disposition |
|---|---|---|---|
| 1 | high | The hash is built from a hand-assembled command with absent fields set to `null`, not from the payload as sent. A naive `asnId` key re-hashes every queued op | `?? undefined` rule; pre-21-6 hash literal pinned; Design Notes corrected |
| 2 | high | The replay rebuild drops `asnId`; `PAYLOAD_FIELDS` lacks it | Rebuild and field list specified |
| 3 | high | Old replayed lines carry `asnLineId: undefined`, so a strict null guard returns 400 on every old op | Normalise to `?? null` before validation; stored-payload replay test |
| 4 | high | The acceptance criteria contradict the approve guard | Decision 3: approve never refuses on status; close blocked while pending |
| 5 | high | The replacement blind CHECK could drop the reason list | CHECK written out in full, with probes |
| 6 | high | The approve arm's own `referenceDoc` and bump were missed | Approve emits the ASN refs, bumps `asn_lines`, re-derives status |
| 7 | high | The web GRN card shows ASN receipts as "Blind · undefined" | "Document" column with three arms |
| 8 | high | The read and rejection DTOs were unspecified (`poLineId` required) | API table and DTO list |
| 9 | med | `over_receipts` has no reference CHECK | Pair CHECK |
| 10 | med | `asn-line-not-open` had no meaning | Dropped |
| 11 | med | Status was not re-derived on amend | Derived on amend too; reject never lowers `received_qty` |
| 12 | med | Lock order was unstated (deadlock risk) | Stated |
| 13 | med | Read models and outbox payloads couldn't tell an ASN receipt from a blind one | `asnId` and `asnLineId` added everywhere |
| 14 | med | `poless` has two arms plus the KPI drill | `blind` filter, `poless` kept as an alias, drill moved |
| 15 | med | Lines with no reference on an ASN receipt, and SKU mismatches losing goods (zero-scan-loss) | Settled unmatched, applied in full, listed in `unmatchedLines` |
| 16 | med | Route paths, limits, `expectedAt`, notes and list totals were implicit | API table |
| 17 | med | The over-receipt queue is PO-worded and fetches PO context | Document-neutral copy, ASN context, new code mapped |
| 18 | med | Client-supplied codes collide across clients | Unique per `(tenant, client, code)` |
| 19 | low | Explicit client versus derived client, for the web and 21-7 | `clientId` sent and checked against the SKUs |
| 20 | low | Docs: mobile contract, snapshot row, fate of the new 409, "passthrough" wording, portal read refusal, pending count before migration | Added |

## Design Notes

- **Why separate tables rather than a PO "kind".** schema.md ratified a mirror. The ASN's lifecycle (derived status, close with no carry, cancel) differs from the PO's (open, then close with per-line dispositions).
- **Why `?? undefined`.** The receiving hash is computed over a hand-built command object (`receiving.command.ts:275-298`), where `JSON` drops `undefined` but keeps `null`. A new key set to `null` would change the hash of every queued PO or blind op, and their replays would answer 422 `idempotency-key-reuse`.
- **Why unmatched lines are not rejected.** A rejected line never reaches the ledger. Goods that arrived must always be booked, under the zero-scan-loss rule. The document line simply isn't credited.

## Verification

**Commands:**
- `bun run lint && bun run typecheck && bun run build && bun run db:generate && bun run test` (wms-be) -- expected: green, and `db:generate` reports "No schema changes".
- `bun run lint && bun run test && bun run typecheck && bun run check:capability-mirror && bun run build` (wms-fe) -- expected: green.
