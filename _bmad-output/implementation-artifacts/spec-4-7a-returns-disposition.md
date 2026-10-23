---
title: '4-7a Returns disposition: restock, quarantine or scrap every received return unit (web and handheld), visible to the client in the portal'
type: 'feature'
created: '2026-10-23'
status: 'ready-for-dev'
route: 'dispatch'
review_loop_iteration: 0
context:
  - '_bmad-output/implementation-artifacts/epic-4-context.md'
  - '_bmad-output/implementation-artifacts/epic-13-context.md'
  - 'docs/design/SYSTEM-DESIGN.md'
  - 'docs/design/IMPLEMENTATION-GUIDE.md'
  - 'docs/design/modules/returns.md'
  - 'docs/design/modules/inventory.md'
  - 'docs/design/modules/inbound.md'
  - 'docs/design/frontend/SYSTEM-DESIGN.md'
  - 'docs/design/frontend/IMPLEMENTATION-GUIDE.md'
  - 'docs/design/mobile/SYSTEM-DESIGN.md'
  - 'docs/design/mobile/IMPLEMENTATION-GUIDE.md'
  - '_bmad-output/implementation-artifacts/spec-13-2-return-receipt-and-inspection.md'
  - '_bmad-output/implementation-artifacts/spec-2-8a-qc-inspection-outcome.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** A returned unit received under 13-2 lands in the system RETURNS bin. It is on hand but outside ATP (`returnsAwaitingUnits`), and **nothing moves it out**. The adjustment refuses RETURNS, the move refuses system bins, and a QC hold refuses RETURNS as its origin. So every return is stranded unsellable, the web's "↩ Awaiting disposition" badge never clears, and the brand cannot see what happened to its goods (`returns.md` intro; PENDING returns).

**Approach:** Record a **disposition** on each received return-receipt line (or part of one). Each outcome is its own registered ledger event (FR48, AD-20):
- **Restock:** `return.restocked`, RETURNS → a storage bin, through every placement gate. ATP rises.
- **Quarantine:** a QC hold of a new kind `return`. It writes `qc.held` RETURNS → QC-HOLD, and the existing QC desk releases or (2-8a) inspects it.
- **Scrap:** `return.scrapped`, RETURNS → out, with a reason.

Where each surface comes in:
- **Web:** an awaiting-disposition queue on `/returns`, with all three outcomes, for `returns.manage`.
- **Handheld:** a restock op `return.restock`, scanning the unit and then the target bin.
- **Portal:** the client's returns with their disposition totals.

The story is full-stack and needs one additive migration.

**Decisions (recommended, taken autonomously):**
1. **Split.** 4-7a covers dispositioning received units only. Split out to deferred-work, inserted after the 2-8b entry:
   - **4-7b** blind returns: no RMA, client resolution by SKU/barcode, exception review.
   - **4-7c** return to client.
   - Returns charges.
   - RMA close / close-short.
   - QC holds over serial and catch-weight arms.

   Return-to-vendor stays 2-8b's: a returned unit reaches DAMAGED through a failed return-hold inspection, and 2-8b draws from DAMAGED. Blind returns compose later because a disposition is keyed on the receipt line, never on the RMA line.
2. **The unit of disposition is the return-receipt line**, which is one applied entry. A disposition takes `qty ≤ awaiting(line)`, so a line may be split across outcomes. A serial or catch-weight line is exactly 1 unit.
3. **Awaiting** is computed and never stored. Per line: `awaiting = qty − Σ restock − Σ scrap − Σ quarantine + Σ returned-from-hold`.
   - A return hold returns its whole quantity when it is `released`.
   - Under 2-8a, an `inspected` hold returns `qty − failed`.
   - While a hold is `open` it returns 0.
   - Conservation per line: `received = restocked + scrapped + onHold + failedInspection + awaiting`.
4. **Restock** goes directly to a named storage bin, with no returns-staging and no putaway task. It runs `InventoryFacade.assertPlacementGatesInTx`: system-owned, retired, blocked, class, **dedicated client** (closes the PENDING 1-5b item), secure, bulk, hazard, capacity. It also checks the reconcile quarantine on both scopes. A restocked returned case's handling unit goes `returned → active`.
5. **Quarantine** reuses the QC hold:
   - A new `qc_holds.kind = 'return'`, origin bin = RETURNS, so a release brings the units back to awaiting.
   - It emits `qc_hold.placed`, so the existing `qc-hold` notification raises and its release resolves it. A return hold's release payload and snapshot carry no `kind` key, the same as a manual hold.
   - It is not supported for serial-tracked or catch-weight lines, which QC holds cannot carry (the `qc.held` serial arm is closed; 2-8a decision 1). Those take restock or scrap: 409 `disposition-not-supported`.
   - **Composition with unmerged 2-8a:** if 2-8a is on main at code time, its `inspect` applies to `return` holds (pass → RETURNS, fail → DAMAGED via `qc.failed`), and `returnHoldOutcomesInTx` reads its failed sums. If it is not, the outcome read returns `failed = 0`, and 2-8a's rebase adds the read plus a test that inspects a return hold. Whichever lands second handles 2-8a's `qc_holds_status_check` (drop/re-add); it does not touch our `qc_holds_kind_check`.
6. **Scrap** is a direct write-off out of RETURNS. It is `returns.manage` only, with no approval-threshold pend (the capability is already manager-only), web only, audited, and carries a reason. It adds no charge in 4-7a (CHARGE_CODES are unchanged; fees are deferred). A scrapped returned case's handling unit goes `returned → rejected`.
7. **Reasons** use one vocabulary for quarantine and scrap: `damaged | defective | expired | missing-parts | contaminated | needs-inspection | client-instruction | other`. `other` needs a note; a note is 1–200 characters, trimmed, optional otherwise. Restock takes no reason.
8. **Authority.** Web: `returns.manage` (owner, ops_manager) for every outcome. Handheld: restock only, by a floor role behind `DeviceSessionGuard` (the `return.receive` precedent). No new capability.
9. **Handheld addressing.** The op names `{skuId, qty, batchCode, serialNumbers}`, not a receipt line. The server allocates to the warehouse's awaiting lines of that SKU/batch oldest-first by `(created_at, id)`. A serial maps to the one awaiting line holding it. The condition grade decides nothing (13-2 decision 1). Catch-weight SKUs are web only.
10. **No RMA status change.** "Dispositioned" is derived: every receipt line has awaiting 0 and no open hold. No status vocabulary widens (§7g).
11. **Portal:** read only, with the RMA list and detail. The response is an exact allowlist: totals per outcome, scrap and quarantine reasons, and times. It never includes bins, users, notes or hold ids.

## Boundaries & Constraints

**Always:**
- Command skeleton (IMPLEMENTATION-GUIDE §1), in this order:
  1. Shape (400) above the transaction.
  2. Hash.
  3. Device operator check (device only), then authority.
  4. Replay.
  5. Warehouse.
  6. Lock receipt lines `FOR UPDATE` in id order (404 only).
  7. Replay again.
  8. Guards.
  9. Lock order continues with the target bin row (via the gate runner), then serial advisory locks (sorted), then the warehouse advisory.
  10. Writes.
  11. Outbox `return_disposition.recorded`.
  12. Audit `return_disposition.recorded` (target type `return_disposition`, the first disposition id).
  13. Key last.
- Ledger events: `return.restocked` and `return.scrapped` are new types with the new reference kind `return-disposition` `{dispositionId, returnReceiptLineId, rmaId, outcome, reasonCode?}`. Both batch and serial arms are open, one event per serial unit. Metering classification: `['both']` and `['from']`. The client is the SKU's. Quarantine writes `qc.held` through `QcFacade` (reference `qc-hold`, unchanged).
- Returns writes only its own tables. It reaches QC only through `QcFacade` (in-tx), stock only through `InventoryFacade`, and handling units only through `CatalogFacade`. Inbound never imports returns.
- Existing hashes and stored snapshots stay byte-identical, pinned by goldens: `rma-create`, `rma-cancel`, `return-receive`, QC `release` `{tenantId, holdId}`, `placeHold`, and `release-receipt`. The new arms are `arm: 'return-dispose'` (web) and `arm: 'return-restock'` (device).
- Every vocabulary consumer that 4-7a widens becomes an allowlist: `qcHoldKindLabel`, the `inbound-cards.tsx:1099` filter, `QC_HOLD_KINDS`, the DTO enums, the register `referenceSummary` switch, and the fe `drill.ts` ledger types.

**Never:**
- Blind returns or return to client/vendor documents.
- Fees.
- RMA close.
- An RMA status widening.
- A device snapshot arm.
- Quarantine of serial or catch-weight units.
- A threshold pend on scrap.
- Moving stock out of RETURNS by any path other than these three outcomes and QC release.
- Inbox task cards: 13-5 owns them, and the handheld gets a plain button.
- Editing 2-8a's migration or code.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected | Error |
|---|---|---|---|
| Web restock, part of a line | line qty 5, awaiting 5; restock 3 → bin A | 1 `return.restocked` 3; awaiting 2; ATP +3 | — |
| Gate refusal | target is another client's dedicated bin, retired, or a system bin | nothing written | 409 with the gate's own code |
| Over-dispose | qty > awaiting | — | 409 `exceeds-awaiting` (+`awaitingQty`) |
| Quarantine, then release | quarantine 2 → QC desk release | `qc.held` RETURNS→QC-HOLD; awaiting −2, then +2 after release | — |
| Quarantine a serial line | serial-tracked or catch-weight | — | 409 `disposition-not-supported` |
| Scrap without a reason | reason missing, or `other` with no note | — | 400 `validation-failed` |
| Scrap a returned case | catch-weight line | `return.scrapped` 1; handling unit → `rejected` | — |
| Device restock FIFO | 4 units, SKU X, lines L1(2, older), L2(3) | dispositions L1:2, L2:2 | — |
| Device short | awaiting < qty, or the serial is not awaiting | nothing written | 409 `exceeds-awaiting` / `serial-not-awaiting` → device: rejected by name |
| Wrong warehouse | line in W2, body W1 | — | 409 `document-warehouse-mismatch` |
| Reconcile quarantine | RETURNS or target scope quarantined | — | 409 `disposition-scope-quarantined` |
| Same key, same body | replay | the stored snapshot | — |
| Portal, another client's RMA | id of client B as client A | — | 404 |

</frozen-after-approval>

## Design Review Amendments

Design review (2026-10-23): claims check K1–K18 against origin/main (wms-be `9a246e7`) and 2-8a's local branch `feat/2-8a-qc-inspection-outcome` (`00831db`), plus blind review B1–B22. The frozen block above is unchanged. Where they disagree, these amendments win. Everything below this section is rewritten to match them.

**A1. Stored open quantity and a hold-settlement subscriber (K1, B13, B4) — supersedes decision 3.**

- **Column.** `return_receipt_lines` gains `open_qty` (milli). The returns commands decrement it in the same transaction as the disposition write: restock, scrap and quarantine all subtract the disposed quantity.
- **Settlement subscriber.** Units coming back from a closed return hold are added back by a returns-module outbox subscriber, `returns/hold-settlement.delivery.ts`.
  - Precedent: `invoicing/delivery.ts:53` (subscribed through `RoutedEventBus.subscribe`, `shared/events/event-bus.ts:59`).
  - It listens to `qc_hold.released` and to 2-8a's `qc_hold.inspected`.
  - It routes by hold id, never by payload `kind`: it looks up `return_dispositions.qc_hold_id`, and no row means not a return hold, so it acks.
  - It runs in its own tenant transaction, in this order:
    1. Lock the receipt line `FOR UPDATE`.
    2. Insert a `return_hold_settlements` row. The insert is idempotent per hold: `ON CONFLICT (tenant_id, qc_hold_id) DO NOTHING`.
    3. Only when that insert inserted, run `open_qty += returnedMilli`.
  - `returnedMilli` comes from QC's own record (A23), never from the payload.
  - Failure handling: data faults log and ack; transient errors rethrow. The bus runs the notifications handler after this one on the same event, so a rethrown data fault would starve it (the `invoicing/delivery.ts` posture).
- **Indexes.** Partial indexes `WHERE open_qty > 0` (`IF NOT EXISTS`) drive both the queue and the device candidate read.
- **Backfill.** Existing lines are backfilled with `open_qty = qty`; no disposition exists before this migration.
  - Proof: `SELECT count(*) FROM return_receipt_lines WHERE open_qty <> qty` = 0, else `RAISE`.
- **Lock discipline.** Awaiting is re-read after the line locks and before allocation.
- **Eventual consistency.** A released or inspected return hold's units are back in RETURNS at once. Until the subscriber runs (one relay poll, `OUTBOX_RELAY_POLL_MS`, 2000 in `.env.example`), they still count as on hold in the line's split. A relay that is off or backlogged undercounts what can be disposed, which is the safe direction. Deploy already requires the relay (DEPLOY.md §2).
- **Per-line split** (all milli):
  - `onHold = Σ quarantine − Σ settlement.held`
  - `failedInspection = Σ settlement.failed`
  - `open_qty = qty − Σ restock − Σ scrap − Σ quarantine + Σ settlement.returned`

**A2. 2-8a is a hard prerequisite (K4, B10) — supersedes decision 5's composition paragraph.**
- 4-7a code is rebased onto 2-8a after it merges. Note that 2-8a's branch is stacked on 0089 `email_messages` and 0090 `adjustment_pend_reason`.
- The "if 2-8a is not on main" path is dropped.
- The QC hold statuses `open | released | inspected` (Q:`qc.command.ts:92-93`) are mapped in a `Record<QcHoldStatus, …>`, so a further widening fails `typecheck`.
- Drop the earlier sentence about which story re-adds `qc_holds_status_check`. 2-8a's 0091 owns that constraint. 4-7a drops and re-adds only `qc_holds_kind_check`.

**A3. Scrap honours the tenant write-off threshold (K2, B6) — supersedes decision 6's "no threshold pend" rationale.**
- `returns.manage` decides who may scrap. It is not a value control. The tenant's adjustment policy is that control: `stock_adjustment_policies.quantity_threshold`, base units, one row per tenant; no row or null means no limit.
- A scrap whose `qty` in milli exceeds `threshold × QUANTITY_SCALE` is refused 409 `scrap-above-threshold` (`awaitingQty` and `threshold` as extensions). Strictly greater than the threshold, the same compare as `inventory.command.ts:505`.
- An approval flow for return scrap is deferred: a new deferred-work entry, inserted after "Returns charges".
- Each scrap also appends the client-facing outbox event `return_scrap.recorded` `{rmaId, rmaCode, clientId, warehouseId, skuId, qty (decimal string), reasonCode, dispositionId}`. Nothing consumes it yet; roadmap 5.2's client notifications will.

**A4. Device fates and the review row (K3, B3).**
- `classifyRestockRefusal` is modelled on `classifyMoveRefusal` (mobile `replay-classification.ts:85`) and wired at `:146` for `op.type === 'return.restock'`:
  - `conflict` → `unreachable`: the op stays queued.
  - `TRANSFER_PLACEMENT_GATE_CODES` (`:29-44`) minus `bin-retired` → `re-plannable`.
  - Rejected:
    - `bin-retired`, `exceeds-awaiting`, `serial-not-awaiting`, `batch-required`, `batch-expired`, `batch-blocked`
    - `disposition-not-supported`, `disposition-scope-quarantined`, `document-warehouse-mismatch`
    - `not-found`, `kit-cannot-hold-stock`, `role-denied`, `validation-failed`
    - any other code
- Before queuing, the device refuses a target whose `storageClass` is `secure` for a floor role. `secure.move` is owner and ops_manager only (`permissions.ts:516-524`), and `CatalogBin` has no separate secure flag (mobile `api.ts:1641-1664`).
- The Discard-only review row's payload carries `warehouseId, skuId, qty, batchCode, serialNumbers, toBinId, occurredAt`.
- The FE guidance in `review-queue.ts:480` reads: "Units were physically placed in <bin> — restock them on the web to that bin, or record a move or count to match the floor."
- `settledNote` (`replay-classification.ts:301`) gains a `return.restock` branch: "Restocked N to <bin> across K return lines".

**A5. Renumbering the migration on rebase (K5).**
- The deploy migrator applies a file only if its journal `when` (`folderMillis`) is later than the newest applied row (`migrate-deploy.ts:696-717`). So a migration renumbered behind 2-8a's must also be re-timed.
- On every rebase:
  1. Take the next free number.
  2. Set `when` later than every prior journal entry.
  3. Regenerate the snapshot from the new predecessor (`bun run db:generate` after deleting the stale one).
  4. Confirm `db:generate` reports "No schema changes" and `git status --short` shows nothing untracked.

**A6. Portal hold reads and probes (K6, B22).**
- The portal reads hold outcomes only through settlements and dispositions keyed by `qc_hold_id`, taken from client-scoped `return_dispositions` rows. It never reads hold ids from input or calls `QcFacade` with a caller-supplied id.
- `test/client-isolation.spec.ts` probes both new tables as `wms_rls_probe` under a client stamp: another client's rows are invisible, and its own are visible.
- **Not applied:** "client-restricted staff user" RLS probe. No such user kind exists on main; the only client scoping is the portal role via `users.client_id` (`schema.ts:62-72`). `GET returns/awaiting` is behind the portal fence (`TenantSessionGuard`), and that fence is tested.

**A7. The RMA-line badge (K7).**
- The badge is computed from the detail read's `receipts[].lines` (`openQty`, `onHoldQty`), grouped by `rmaLineId`. `lineAwaitsDisposition` (`lib/returns.ts:74`) currently returns `receivedQty > 0`.
- `RmaDetail` is a stored snapshot (`return-authorization.command.ts:153`), so no field is added to RMA lines.
- The detail's refetch deps (`returns-view.tsx:400-409`) gain a disposition epoch, bumped on every successful dispose.

**A8. Reference document (K8).** `return-disposition` is `{dispositionId, returnReceiptLineId, rmaId, outcome, reasonCode?, handlingUnitIds?}`. The optional keys are omitted when absent, never null. They are hashed into the chain as written.

**A9. System-bin target (K9).** The gate runner's system-bin arm answers **400 `validation-failed`**, its arm 2. The other gate arms answer 409.

**A10. `qc_holds` lock cost (K10, B17).**
- The kind-CHECK re-add scans `qc_holds` once under ACCESS EXCLUSIVE. The table holds one row per quarantine decision, small by construction, so the CHECK is added VALID (0091's own note).
- `NOT VALID` would buy nothing here: the migrator runs the pending set in one transaction, so a same-file `VALIDATE` scans under the lock anyway.
- `return_receipt_lines` (A1) grows with return volume, far below the ledger:
  - `ADD COLUMN … NOT NULL DEFAULT 0` is metadata-only.
  - The backfill `UPDATE` rewrites each row once under row locks.
  - The `open_qty` CHECK is added VALID for the same single-transaction reason. State that cost in the file header.

**A11. Constraints on `return_dispositions` (K11, B17).**
- The table is append-only, so `updated_at` is dropped. Settlements live in their own append-only table.
- `idempotency_key` is dropped: `audit_events.reference` and `idempotency_keys` carry the key.
- Partial uniques (`IF NOT EXISTS`):
  - `(tenant_id, qc_hold_id) WHERE qc_hold_id IS NOT NULL`
  - `(tenant_id, serial_id) WHERE serial_id IS NOT NULL AND outcome <> 'quarantine'`
  - `(tenant_id, handling_unit_id) WHERE handling_unit_id IS NOT NULL`
- CHECKs:
  - `outcome <> 'quarantine' OR (serial_id IS NULL AND handling_unit_id IS NULL)`.
  - `ledger_event_id` is NOT NULL ⇔ outcome is restock or scrap. A quarantine's `qc.held` belongs to QC, linked by `qc_hold_id`.
  - `outcome <> 'restock' OR note IS NULL`: restock takes no note.

**A12. Serial index on receipt lines (K12).** Add `return_receipt_lines (tenant_id, serial_id) WHERE serial_id IS NOT NULL` (`IF NOT EXISTS`); none exists today (0073:61-63). A serial resolves to the line holding it whose `open_qty > 0`. At most one exists, because RETURNS can hold the serial once.

**A13. Batch identity (K13, B1).**
- A batch-tracked, non-serial SKU requires `batchCode`, else 400 `batch-required`. An untracked SKU refuses one with 400 `validation-failed`.
- A batch-and-serial SKU's batch is derived per serial from its receipt line. The device sends `batchCode: null`, the moves draft precedent (`draft.ts:373-375`).
- Candidate lines match on `batch_id = $batch`. `batch_id IS NULL` is used only for unbatched SKUs.
- SKUs are read `FOR SHARE` through `skuFactsInTx(…, {lock: 'share'})`.
- New matrix rows: two-batch FIFO, and a missing batch.

**A14. Hold reason and the QC desk (K14, B11).**
- The hold `reason` is `return <RMA code> · <reasonCode>`. The note stays on the disposition row.
- `QcHoldEntryDto` gains an optional `rmaCode`. The qc-holds list controller composes it with `ReturnsFacade.rmaCodesByHoldIdsInTx`, so QC never reads returns tables (the ReceivingController composition precedent). The QC desk shows it.
- The queue card shows the line's prior quarantine count and last reason (from its dispositions), and its age from `receivedAt`.

**A15. The restock draft (K15).**
- The draft is a `MoveDraft` whose origin is the snapshot's `systemOwned` bin coded `RETURNS`.
- It is constructed directly (`{...createMoveDraft(w), origin}`), because `originRefusal` (`draft.ts:89`) refuses system bins.
- It reuses `resolveMoveSku`, `setBatch`, `addMoveSerial`, `targetRefusal`, `confirmBlocker`. RETURNS has no dedicated client, so the SKU lookup is unscoped.
- If no RETURNS bin is in the snapshot, the screen says "No returns received in this warehouse yet". The implementer verifies that the snapshot builder includes system bins (mobile `api.ts:1640` says it does).
- Wording is parameterised where a helper says "move".

**A16. Code Map corrected (K16).** It is rewritten below. Notably:
- Release is all-or-nothing, and the notification source needs no change because routing is by hold id.
- The device candidate read uses the partial index, not a computed formula.

**A17. Quantity units (K17, B18).**
- **Bodies** (device and web): base units as JSON numbers (`qty: 4`).
- **Hashes:** carry the number as sent, after A28's normalisation (the `return-receive` precedent).
- **Response and snapshot:** base units.
- **DB and ledger:** milli (`4000`), converted behind the replay at the SKU's precision.
- Goldens pin `4 ↔ 4000` on both arms.

**A18. Audit-adjacent payload (K18).** `return_disposition.recorded` is flat ids and counts, the `ReturnReceiptRecordedPayload` precedent (`returns/events.ts:36`): `{warehouseId, clientId, skuId, outcome, qty (decimal string), dispositionCount, firstDispositionId}`. Nothing consumes it yet.

**A19. Sellable condition for the device (B2).** A device restock consumes only lines whose received `condition` is in `RESTOCKABLE_ON_DEVICE = ['resaleable']`, from `RETURN_CONDITIONS` (`return-receipt.command.ts:53`). Lines graded `opened`, `damaged` or `missing-parts` are web-only decisions. Cross-RMA attribution is deliberate (Design Notes). New matrix row.

**A20. Conservation assertion (B5).**
- The "ledger fold backstop" claim is dropped.
- After the writes, inside the transaction, every touched line is re-read and must satisfy A1's equation. If it does not, the command throws a typed 500 `data-fault` and rolls back.
- A DB-level race test runs two concurrent disposes on one line, whose sum exceeds `open_qty`: exactly one commits, and the other answers 409 `exceeds-awaiting`.

**A21. Batch state at restock (B7).**
- Restock refuses an expired batch with 409 `batch-expired`, and a batch whose `status` is not `active` with 409 `batch-blocked`. `batches.status` `active|blocked` is already on main (`schema.ts:1143,1160`).
- The expiry predicate is the draw side's: `expiryDate === null || Date.parse(expiryDate) >= Date.parse(occurredAt)` (`pick.command.ts:1548-1552`). No shared primitive exists on main. If 3-3a's `isBatchExpiredAt` is on main at code time, use it instead.
- 4-3a's minimum remaining shelf life is an allocation rule, not a placement rule. It applies at outbound allocation, never at restock.

**A22. Serial state per outcome (B8).**
- `serials.status` has no stock vocabulary; its only write is `active → packed`. "In stock" is ledger-derived: the latest event has a `to_bin_id` (`ledger.service.ts:502`).
- Restock: a serial `return.restocked` into a bin puts the serial in stock.
- Scrap: `return.scrapped` with `toBinId` null takes it out of stock. Pick then refuses it (`serial-elsewhere`), and a later RMA cannot authorize it (`serial-already-authorized` — its line sits on a committed RMA).
- Tests pin all three facts. **No serial status write is added** (partly not applied: there is nothing to write).

**A23. QC release is all-or-nothing (B9).**
- Verified: release moves the whole hold back to its origin (`qc.command.ts:646`, `:823`). 2-8a's inspect closes the whole hold. Nothing else moves stock in QC-HOLD: adjust refuses it (`qc-bin-not-adjustable`), and move, transfer, pick and merge refuse system bins.
- `QcFacade.returnHoldOutcomeInTx(holdId)` returns `{status, heldMilli, returnedMilli, failedMilli}` from QC's own record:
  - held = Σ the hold's `qc.held` (`qcHeldArmsInTx`).
  - returned: held when `released`; 2-8a's passed sum when `inspected`.
  - failed: 2-8a's failed sum.
- A test pins it.

**A24. How DAMAGED-from-return units leave (B12).** Today the only exit is 2-4a's write-off: `POST …/inventory/adjustments` with a negative delta, `stock.adjust` (`inventory.command.ts:721`). Return to client or vendor out of DAMAGED is 4-7c / 2-8b; the PENDING returns item links them.

**A25. One audit row per command (B14).**
- One row per command, the receipt and move precedent (`return-receipt.command.ts:1205`, `move.command.ts:523`). Target: `return_disposition`, the first id.
- `changes` jsonb carries `{dispositionIds, outcome, deviceId, operatorUserId}`; the device fields are null on the web. `audit_events` has no device column (`schema.ts:445-463`).

**A26. Acceptance criterion 2 reworded (B15).**
- New wording: "Given a pickable, unblocked target bin, ATP rises by exactly the restocked quantity."
- **Not applied as written:** no stock-changed signal exists, and no automatic backorder re-allocation exists on main. Channel sync republishes full availability every `CHANNELS_SYNC_POLL_MS` tick (`channels.publish.ts:193`), and backorder status is set only at order create (`order.command.ts:1399`). The restock is therefore published on the next tick. A test asserts the channel snapshot's quantity after a restock.

**A27. Acceptance criterion 1 rescoped (B16).**
- New wording: "RETURNS on-hand for those SKUs falls by exactly the RMA's received quantity minus failed inspection."
- Reconcile is the reconcile worker (`OUTBOX_RECONCILE_POLL_MS`, `inventory/reconcile.ts:41-44`), driven once in the test.

**A28. Normalise before hashing (B19).**
- Trim `note` and `batchCode`; an empty string becomes null.
- Trim and dedupe-check serial numbers, then sort them.
- The golden includes padded whitespace.

**A29. `occurredAt` (B20).**
- Follows the move precedent (`move.command.ts:219-232`): required on the device, refused on the web (which uses `nowIso()`), format only (Z-suffixed UTC). There is no closed-period or future bound on any device op on main.
- It is stored on the ledger event and the disposition row. The audit row uses server time.
- New matrix row.

**A30. Portal field names and the disposition filter (B21).**
- The detail line field is `returnReasonCode`.
- The list takes `?dispositionState=awaiting|dispositioned`. `awaiting` means any line with `open_qty > 0` or with an unsettled quarantine; `dispositioned` is every other `received` / `partially_received` RMA.
- The key allowlist is pinned recursively, including `dispositions[]`.

**A31. Matrix rows (B22).** The new rows are listed below. On licence, segregation and temperature:
- The gate runner covers storage class, which includes temperature, and segregation/hazard (`inventory.facade.ts:2342`, arms 6 and 10). It does not cover licences.
- Licences are per site and the unit is already on site, so restock does not change licence coverage.
- Mobile `targetRefusal` (`draft.ts:257` → `lib/target-bin.ts:22-37`) mirrors system, blocked, class and client. The server decides the rest at replay, where those refusals are re-plannable.

**Amended Boundaries.**
- Always:
  - Maintain `open_qty` in the same transaction as every disposition, and assert conservation (A20).
  - The subscriber is the only writer of settlements.
  - Optional reference keys are omitted, never null.
  - 2-8a is merged first.
- Never:
  - Trust payload quantities in the subscriber.
  - Write `qc_holds` from returns.
  - Read QC data by a caller-supplied id on the portal.

**Amended matrix rows.**

| Scenario | Input / State | Expected | Error |
|---|---|---|---|
| System-bin target | toBinId = DAMAGED / RECEIVING | — | 400 `validation-failed` |
| Scrap over threshold | threshold 10, scrap 11 | — | 409 `scrap-above-threshold` |
| Batch missing | batch-tracked SKU, no batchCode | — | 400 `batch-required` |
| Two-batch FIFO | device restock 3 of B1; L1(B2, older), L2(B1) | L2 only | — |
| Expired / blocked batch | batch expired at occurredAt, or `blocked` | — | 409 `batch-expired` / `batch-blocked` |
| Device skips non-sellable | L1 `damaged` (older), L2 `resaleable` | L2 consumed | `exceeds-awaiting` if L2 short |
| Device serial restock | serial S on line L, open 1 | 1 disposition on L | already dispositioned → 409 `serial-not-awaiting` |
| Device op vs web dispose | web scraps L first, then the queued device op replays | device draws the remaining lines, or refuses | 409 `exceeds-awaiting` → rejected |
| Quarantine → inspect fail | batch line, quarantine 3; 2-8a inspect pass 1 / fail 2 | after the subscriber: open +1, failedInspection 2 (DAMAGED) | — |
| Restock into a segregated or class-mismatch bin | hazard pair, or chilled SKU into an ambient bin | — | 409 `bin-segregation-conflict` / `bin-storage-mismatch` → device re-plannable |
| Device `occurredAt` malformed | not Z-suffixed | — | 400 `validation-failed` |
| Same key in flight (device) | two `return.restock` with one key, parked | one commits, the other replays its snapshot | — |
| Subscriber redelivery | `qc_hold.released` delivered twice | one settlement, open +qty once | — |

## Code Map

Backend (`workspace/core/backend/wms-be`). Base: origin/main `9a246e7` (newest migration `drizzle/0088`), rebased onto 2-8a (A2), whose branch adds 0089–0091.

- `src/modules/returns/return-receipt.command.ts`:
  - `:1072-1108` writes receipt lines and the `return.received` doc. It sets `open_qty = qty` on insert.
  - `:1027` is `ensureReturnsBinInTx`.
  - `:1205` is the one-row-per-command audit.
  - `:53` is `RETURN_CONDITIONS`.
- `src/modules/returns/events.ts:36` holds the payload precedent. Add `return_disposition.recorded` and `return_scrap.recorded`.
- `src/modules/returns/returns.facade.ts:125-210`:
  - `get` adds per receipt line `{id, openQty, restockedQty, scrappedQty, onHoldQty, failedInspectionQty}`. This is a read; `RmaDetail` stays a stored snapshot with optional `receipts` (`return-authorization.command.ts:153,175`).
  - New: `dispose`, `restock`, `listAwaiting`, `portalReturns`, `portalReturn`, `rmaCodesByHoldIdsInTx`.
- `src/modules/returns/returns.module.ts:33` adds `forwardRef(() => InboundModule)`; `QcFacade` is exported at `inbound.module.ts:70`, with compliance `excursion.command.ts:124` as the precedent.
- `src/modules/invoicing/delivery.ts:30-80` is the subscriber model. `src/shared/events/event-bus.ts:28-62` gives ordered handlers, at-least-once delivery, and idempotency as the consumer's job.
- `src/api/returns.controller.ts`: `:127` is the device route precedent. Declare `GET returns/awaiting` before `:rmaId` (`:251`).
- `src/modules/inbound/qc.command.ts` (2-8a's version):
  - `QC_HOLD_KINDS` += `'return'`.
  - New `holdReturnLineInTx`, on the model of `holdReceiptLineInTx` (main `:598`). It adds the `qc_hold.placed` outbox (main `:550-565` payload, unchanged shape) and the `qc.held` RETURNS→QC-HOLD write.
  - New `returnHoldOutcomeInTx` (A23).
  - The status union is `:92-93` on 2-8a.
  - Release (main `:646`, `:823`) and 2-8a's inspect are unchanged; release returns to `row.binId` = RETURNS.
- `src/modules/inbound/qc.facade.ts` gets the passthroughs. Widen `QcHoldEntry.kind` and the `qc.dto.ts` enums. `QcHoldEntryDto.rmaCode?` is composed in `src/api/receiving.controller.ts`, the qc-holds list.
- `src/modules/notifications/notification-sources.ts:547` is unchanged: a return hold's release carries no `kind`, so it resolves its `qc-hold` entry.
- `src/modules/inventory/`:
  - `inventory.facade.ts:2342` is `assertPlacementGatesInTx` (14 arms; `subject` += `'restock'`). Also `:522` `appendLedgerEventInTx`, `:532` `lockSerialsInTx`, `:1345` `openQuarantinedBinsInTx`.
  - `inventory.command.ts:505` is the threshold compare to mirror.
  - `reservation.service.ts:157` is unchanged.
- `src/modules/inventory/ledger-registry.ts:271,580-640`: append the reference kind `return-disposition` and the two types. `src/modules/reporting/registers.ts:390` gets a new case.
- `src/modules/catalog/catalog.facade.ts`:
  - `:127` `SkuFacts` adds `code` and `name`.
  - `:943` takes `{lock: 'share'}`.
  - New `settleReturnedHandlingUnitsInTx(ids, 'active'|'rejected')`, conditional on `status='returned'`.
  - The batch reads: `getBatchesForSkusInTx` (`:740`) for status and expiry; `batchesByCodesInTx` (`:360`).
- `src/modules/tenancy/sync-report.command.ts:92,126,174,387`: add `'return.restock'` with Discard only and A4's payload fields. `client-wind-down.ts:35`: add it to `SKU_NAMING_OP_TYPES`.
- `src/api/portal.controller.ts`: new routes on the `:493` precedent. `test/architecture.spec.ts:2269`: `PORTAL_READS` += returns. Update the returns-module guard: 6 own tables, the `QcFacade` allowlist, and the subscriber file.
- `src/shared/db/migrate-deploy.ts:696-717` is the reason for A5.

Frontend (`workspace/core/frontend/wms-fe`):
- `src/components/returns/returns-view.tsx`:
  - `:387-446` is the detail panel. Its refetch deps (`:400-409`) gain the epoch.
  - The badge at `:429` reads A7.
- `src/lib/returns.ts`: `:59` labels, `:71-74` the badge and `lineAwaitsDisposition`.
- `src/lib/use-returns.ts:27` and `src/lib/api/client.ts:5065-5134`.
- `src/lib/over-receipt.ts:159`: `qcHoldKindLabel` becomes an allowlist that includes `'return'`. `src/components/inbound/inbound-cards.tsx:1099`: change the filter to `=== 'manual'`.
- `src/lib/drill.ts:79,100`: ledger types and their labels.
- `src/lib/use-inventory.ts:87`.
- `src/lib/review-queue.ts:480,1002`: guidance, using `STOCK_MOVE_GUIDANCE` as the model.
- Portal: `src/lib/portal.ts:124`, `src/lib/portal-boundary.test.ts`, and `src/components/portal/portal-inbound.tsx` (precedent).

Mobile (`workspace/core/mobile/wms-mobile`):
- `src/offline/types.ts:48-59` and `src/api.ts:270-286,1641-1664`.
- `src/state/op-dispatch.ts:232-240,265`.
- `src/state/replay-classification.ts`: `:29-44`, `:85` (the model), `:146` (wiring), `:301` (`settledNote`).
- `src/moves/draft.ts:42,57,89,112,193,213,257,334,373` and `src/lib/target-bin.ts:22-37`.
- `app/inbox.tsx:394-400` and `app/_layout.tsx:43`.

## Tasks & Acceptance

**Execution:**
- [ ] **Migration** `drizzle/NNNN_return_dispositions.sql`: the number and `when` per A5, plus the journal and snapshot.
  - **Header** states the lock cost (A10).
  - **Fail-fast:** RAISE if `return_dispositions` exists.
  - **Pre-check:** RAISE if any `qc_holds.kind` is outside `manual|receipt`.
  - **`return_receipt_lines`:**
    - `ADD COLUMN open_qty bigint NOT NULL DEFAULT 0`, then `UPDATE … SET open_qty = qty`, then the A1 proof (RAISE on any mismatch).
    - CHECK `open_qty >= 0 AND open_qty <= qty`.
    - `CREATE INDEX IF NOT EXISTS` on:
      - `(tenant_id, created_at, id) WHERE open_qty > 0`
      - `(tenant_id, sku_id, batch_id, created_at, id) WHERE open_qty > 0`
      - `(tenant_id, serial_id) WHERE serial_id IS NOT NULL`
  - **`return_dispositions`** (append-only):
    - Columns: `id`, `tenant_id`, `client_id`, `warehouse_id`, `return_receipt_id`, `return_receipt_line_id`, `rma_id`, `sku_id`, `outcome`, `qty` (bigint milli), `batch_id`, `serial_id`, `handling_unit_id`, `to_bin_id`, `qc_hold_id`, `reason_code`, `note`, `device_id`, `decided_by`, `ledger_event_id`, `occurred_at`, `created_at`.
    - CHECKs: the frozen list, minus the restock note (A11's CHECK forbids it), plus A11's.
    - Indexes: `(tenant_id, return_receipt_line_id)`, `(tenant_id, rma_id)`, `(tenant_id, client_id, created_at, id)`, plus A11's partial uniques.
  - **`return_hold_settlements`** (append-only):
    - Columns: `id`, `tenant_id`, `client_id`, `disposition_id`, `qc_hold_id`, `status`, `held_qty`, `returned_qty`, `failed_qty`, `settled_at`, `created_at`.
    - CHECKs: `status IN ('released','inspected')`; `held_qty > 0`; `returned_qty + failed_qty = held_qty`; both ≥ 0.
    - UNIQUE `(tenant_id, qc_hold_id)` and `(tenant_id, disposition_id)`.
  - **RLS:** both new tables use the `return_receipts_tenant_isolation` shape. No FKs.
  - **`qc_holds_kind_check`:** DROP, then re-ADD as `manual|receipt|return`.
  - **Probes:**
    - A refused insert per CHECK and per partial unique.
    - Accepted rows (one per outcome, a settlement, a `return` hold), rolled back by a sentinel `RAISE`.
    - No word INDEX inside a DO block.
- [ ] `src/modules/returns/return-disposition.command.ts` (new): `dispose` (web) and `restock` (device), sharing `applyDispositionsInTx`. The order:
  1. Shape and normalise (A28), then hash:
     - `{arm:'return-dispose', tenantId, warehouseId, receiptLineId, outcome, qty, toBinId, reasonCode, note}`
     - `{arm:'return-restock', tenantId, deviceId, operatorUserId, warehouseId, skuId, qty, batchCode, serialNumbers, toBinId, occurredAt}`
  2. Device operator check, then authority (`returns.manage`, or floor role).
  3. Replay.
  4. Warehouse.
  5. SKU `FOR SHARE`.
  6. Lines `FOR UPDATE` in id order. The device locks candidates oldest-first: A19's condition, A13's batch match, `open_qty > 0` via the partial index, capped at 1,000.
  7. Replay again.
  8. Re-read `open_qty`.
  9. Guards: 404s; warehouse 409; precision 400; `batch-required`; `disposition-not-supported`; `batch-expired` / `batch-blocked`; `exceeds-awaiting` / `serial-not-awaiting`; `scrap-above-threshold`; `disposition-scope-quarantined`.
  10. Gates (restock).
  11. Serial locks.
  12. Writes: ledger event or hold; the disposition row; `open_qty -=`; handling unit settle.
  13. Conservation assertion (A20).
  14. Outbox (A18, A3).
  15. Audit (A25).
  16. Key.

  The snapshot is `{dispositions:[{id, receiptLineId, rmaId, outcome, qty, toBinId, qcHoldId, ledgerEventId}]}` in base units.
- [ ] `src/modules/returns/hold-settlement.delivery.ts` (new) implements A1 and A23, and is registered in `returns.module.ts`.
- [ ] Routes:
  - `src/api/returns.controller.ts`: `POST returns/dispositions`, `POST returns/restocks` (device), `GET returns/awaiting?warehouseId&clientId&cursor&limit`.
  - Queue rows, oldest first, keyset ASC, no short pages: `{receiptLineId, receiptCode, receivedAt, rmaId, rmaCode, orderReference, clientId, skuId, condition, note, batchCode, serialNumber, weightGrams, receivedQty, openQty, onHoldQty, priorQuarantines, lastReasonCode}`.
  - `src/api/portal.controller.ts`: per A30 and Design Notes.
  - `src/api/receiving.controller.ts`: qc-holds `rmaCode`.
- [ ] The Code Map seams (qc, ledger registry, registers, catalog, inventory, sync-report, wind-down). Add `return_disposition` to `AUDIT_TARGET_TYPES` and `return_disposition.recorded` to `AUDIT_NEW_ACTIONS`.
- [ ] Tests:
  - `test/return-dispositions.spec.ts`:
    - Both matrices.
    - Goldens: the two new hashes, including padded-whitespace and `4 ↔ 4000` cases, plus the six existing hashes byte-identical.
    - Conservation after restock + quarantine + release + inspect + scrap.
    - ATP per outcome.
    - Channel snapshot after a restock (A26).
    - `expectAuditRow`, including `changes.deviceId`.
    - Replay.
    - Parked-waiter races on `dispose` and `restock`.
    - The DB race (A20).
    - Subscriber redelivery and data-fault ack.
    - Serial facts (A22).
    - Hold outcome (A23).
    - Reconcile clean after the worker runs.
    - Portal two-layer test: another client's RMA → 404; the recursive allowlist.
  - `test/client-isolation.spec.ts`: +2 policies, and the probes.
  - `test/metering.spec.ts`: `return.restocked ['both']`, `return.scrapped ['from']`.
  - `architecture.spec.ts`.
  - A migration spec executing it against seeded 0073-era lines.
- [ ] FE:
  - Labels, `parseDisposition`, and A7's badge in `lib/returns.ts`.
  - `useAwaitingReturns`.
  - Client and types regenerated.
  - `returns-view.tsx` tabs (Authorizations · Awaiting disposition `?tab=awaiting`), plus the epoch.
  - `awaiting-dispositions.tsx`: per-line cards with Restock (storage bins from `useWarehouseBins`), Quarantine and Scrap (reason + note, inline confirm, `scrap-above-threshold` worded); `returns.manage`; a per-draft key; the client filter; A14's card info.
  - Allowlist fixes; `drill.ts`; `review-queue.ts` guidance; QC desk `rmaCode`.
  - Portal: `/portal/returns`, `PORTAL_NAV`, hooks, and the `dispositionState` filter.
  - Tests and the boundary test.
- [ ] Mobile:
  - `src/returns/restock-draft.ts` (A15, + test).
  - `app/return-restock.tsx`, including the secure-target refusal (A4).
  - Op type, api, sender.
  - `classifyRestockRefusal`, `settledNote` (A4), and one test per branch.
  - The inbox button.
  - `engine.test.ts` FIFO.
- [ ] Meta docs last:
  - `returns.md`: the flow, subscriber and settlement diagram.
  - `inventory.md`, `inbound.md`, `API-SURFACE.md`.
  - `PENDING.md`: close the three returns items; link DAMAGED to 4-7c (A24); note the subscriber window.
  - `IMPLEMENTATION-GUIDE.md` §3: add A5's renumber rule.
  - `docs/repos/*/README.md`.

**Acceptance Criteria:**
- Given a fully received RMA whose lines are restocked, quarantined (then released or inspected) and scrapped, after the subscriber and the reconcile worker run: every line's `open_qty` and `onHoldQty` are 0, RETURNS on-hand for those SKUs falls by exactly the RMA's received quantity minus failed inspection, the badge reads "Dispositioned", and reconcile reports no divergence.
- Given a pickable, unblocked target bin, a restock raises ATP by exactly the restocked quantity, and the next channel-sync tick publishes it. A scrap or quarantine leaves ATP unchanged.
- Given a portal client, its RMA shows per line received / restocked / on hold / failed inspection / scrapped / open, with `returnReasonCode` and scrap reasons, and no bin, user, note or hold id.
- Given a device restock refused `exceeds-awaiting`, the op is dropped with a `✕` retraction and a Discard-only review row carrying the target bin and A4's wording. A gate refusal (other than `bin-retired`) stays queued as re-plannable, and `conflict` stays queued.

## Spec Change Log

## Review Triage Log

| ID | Verdict | Finding | Outcome |
|---|---|---|---|
| K1 | high | The computed awaiting is unindexable, so the queue pages short and the device scan is unbounded | A1 |
| K2 | high | Scrap bypasses the tenant write-off threshold | A3 |
| K3 | high | No restock-specific fates: `conflict` would drop and `bin-retired` would loop | A4 |
| K4 | high | 2-8a was treated as optional, and the claim about `qc_holds_status_check` was wrong | A2 |
| K5 | medium | The renumber steps are missing; the migrator skips older `folderMillis` | A5 |
| K6 | medium | Portal hold reads could take ids from input; no client-restricted probe | A6 (the restricted-staff probe was rejected: no such user kind on main) |
| K7 | medium | The badge reads `receivedQty > 0`; `RmaDetail` is a snapshot; no refetch on dispose | A7 |
| K8 | low | Reference doc: `handlingUnitIds` absent, and `reasonCode` null versus omitted | A8 |
| K9 | medium | The system-bin target status was wrong (400, not 409) | A9 |
| K10 | low | `qc_holds` lock cost not stated | A10 |
| K11 | medium | Missing uniques and outcome CHECKs; `updated_at` and `idempotency_key` columns | A11 |
| K12 | medium | No serial index on receipt lines | A12 |
| K13 | high | Batch identity on the device unspecified; null-batch match | A13 |
| K14 | low | Hold reason format; the QC desk cannot name the RMA | A14 |
| K15 | low | The restock draft is underspecified, and `originRefusal` refuses RETURNS | A15 |
| K16 | low | Code Map wording | A16 |
| K17 | medium | Quantity unit unstated at each boundary | A17 |
| K18 | low | Outbox payload shape and consumer | A18 |
| B1 | high | Batch-and-serial device path | A13 |
| B2 | high | The device could restock damaged-graded lines | A19 |
| B3 | medium | The review row lacks what the reviewer needs | A4 |
| B4 | high | Hold outcomes read across a facade on every queue read | A1 |
| B5 | medium | The "ledger fold backstop" is not a conservation proof | A20 |
| B6 | high | Scrap rationale wrong; no client signal | A3 |
| B7 | high | Restock of an expired or blocked batch | A21 (no shared expiry primitive on main; the pick predicate is used) |
| B8 | medium | Serial status per outcome | A22 (no serial status write: in-stock is ledger-derived) |
| B9 | medium | Is release partial? Where does the returned quantity come from? | A23 |
| B10 | medium | 2-8a merge-order ambiguity | A2 |
| B11 | low | The queue card lacks hold history and age | A14 |
| B12 | low | No exit stated for DAMAGED-from-return | A24 |
| B13 | high | The awaiting formula is not maintainable at scale | A1 |
| B14 | low | Audit granularity and device attribution | A25 |
| B15 | medium | Acceptance criterion 2 is unconditional; the stock signal is unnamed | A26 (no stock-changed signal and no backorder re-allocation exist; asserted through the channel-sync tick) |
| B16 | low | Acceptance criterion 1 over-claims; reconcile job unnamed | A27 |
| B17 | low | Constraint and lock-cost gaps | A10, A11 |
| B18 | low | Quantity unit goldens | A17 |
| B19 | low | Whitespace normalisation before hashing | A28 |
| B20 | low | `occurredAt` and closed periods | A29 (no closed-period check exists on any device op) |
| B21 | low | Portal field naming and filter | A30 |
| B22 | medium | Missing matrix rows | A31, A6 |

## Design Notes

**Why QC holds for quarantine, with RETURNS as the origin.** The QC hold is the one place that already has a desk, a release, a notification and 2-8a's inspect. With RETURNS as the origin, a release puts units back where a second disposition picks them up, and QC never learns that returns exist. The cost is cross-module state: the returns module learns that a hold closed through its own subscriber (A1), so the queue, the device candidates and the portal all read returns-owned indexed columns.

**Device allocation across RMAs.** Restocked units are fungible within (SKU, batch, `resaleable`). The device allocates oldest-first across every RMA of the warehouse, so the line credited may belong to a different RMA than the parcel the operator holds. The per-RMA split stays exact in total; the attribution is FIFO.

**Portal shape** (exact keys, pinned recursively):
- List rows: `{id, code, status, orderId, orderReference, externalReference, createdAt, lineCount, receivedTotal, restockedTotal, onHoldTotal, failedInspectionTotal, scrappedTotal, openTotal}`.
- Detail: the row + `lines[{skuCode, skuName, authorizedQty, receivedQty, returnReasonCode, restockedQty, onHoldQty, failedInspectionQty, scrappedQty, openQty}]` + `dispositions[{skuCode, outcome, qty, reasonCode, occurredAt}]`, oldest first.
- Layering: `return_authorizations.client_id = $client` under `{clientId}`. Lines, receipts, dispositions and settlements are reached by joining to it.

**Golden (device):**

```
{arm:'return-restock', tenantId, deviceId, operatorUserId, warehouseId, skuId,
 qty: 4, batchCode: null, serialNumbers: null, toBinId, occurredAt: '…Z'}
→ L1 resaleable open 2000, L2 resaleable open 3000
→ dispositions [{receiptLineId: L1, qty: 2}, {receiptLineId: L2, qty: 2}]  (DB: 2000, 2000)
```

## Verification

**Commands:**
- In wms-be, wms-fe and wms-mobile: `bun run test && bun run lint && bun run typecheck && bun run build`. Expect all green; in BE, use jest via `bun run test`, never bare `bun test`, and never two concurrent runs.
- `bun run db:migrate && bun run db:verify` on a fresh DB, then `bun run db:generate`. Expect "No schema changes", and `git status --short` with nothing untracked.
- After rebasing onto main with 2-8a merged: renumber and re-time per A5, then re-run `typecheck` and the full suite. Expect green.
