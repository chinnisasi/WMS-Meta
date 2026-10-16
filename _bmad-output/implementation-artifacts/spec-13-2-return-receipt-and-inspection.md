---
title: 'Return receipt and inspection — the floor receives returned units scan-first against an authorization, grades their condition, and holds them awaiting disposition outside ATP'
type: 'feature'
created: '2026-10-16'
status: 'ready-for-dev'
route: 'dispatch'
review_loop_iteration: 0
context:
  - '_bmad-output/implementation-artifacts/epic-13-context.md'
  - '_bmad-output/implementation-artifacts/spec-13-1-return-authorization.md'
  - 'docs/design/SYSTEM-DESIGN.md'
  - 'docs/design/IMPLEMENTATION-GUIDE.md'
  - 'docs/design/API-SURFACE.md'
  - 'docs/design/modules/returns.md'
  - 'docs/design/modules/inbound.md'
  - 'docs/design/modules/inventory.md'
  - 'docs/design/modules/tenancy.md'
  - 'docs/design/modules/catalog.md'
  - 'docs/design/mobile/SYSTEM-DESIGN.md'
  - 'docs/design/mobile/IMPLEMENTATION-GUIDE.md'
  - 'docs/design/frontend/SYSTEM-DESIGN.md'
  - 'docs/design/frontend/IMPLEMENTATION-GUIDE.md'
  - 'docs/repos/wms-mobile/README.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** FR-47 requires that returned units are received and inspected scan-first on the existing mobile substrate, against their authorization. 13-1 creates authorizations, but nothing can receive against them.

The epic names the interim state "received, awaiting disposition". It must be **excluded from ATP** until 13-3 restocks, quarantines or scraps the unit. Today's receiving bin is *not* excluded from ATP, so a returned unit landing there would be sellable at once.

**Approach:**
- **Handheld:** a new handheld screen receives against a cached open return authorization (RMA). It grades each unit's condition and captures the batch, serial or case weight, then queues an offline op.
- **Server:** it applies the units that match the authorization. Each one gets a registered ledger event `return.received` into a new system **RETURNS** bin, which ATP subtracts, as it already does for QC-HOLD and IN-TRANSIT. Entries that don't match land in the existing rejected-ops review queue.
- **Web:** the Returns page shows what was received and its condition.

**Decisions (human, 2026-10-16):**
1. **Inspection is a condition grade per unit:** `resaleable`, `opened`, `damaged` or `missing-parts`, plus an optional note. It is recorded on the receipt and shown to whoever disposes. It suggests a disposition; it decides nothing.
2. **RMA-only in 13-2.** Units are received only against an `open` or `partially_received` authorization. Blind returns are a later story.
3. **Receive what matches; review the rest.** Units within the authorization go to awaiting disposition. Everything else lands in the existing rejected-ops review queue, so nothing is silently dropped or silently accepted. That covers extra units, a SKU not on the authorization, an unauthorized serial and an undispatched batch.
4. **In review, the refused units can only be discarded.** The row offers Discard, with the guidance "create a return authorization for these units, then receive them again". An authorization can't be amended, so re-applying the stored request could never match. Discard records that the reviewer has dealt with the units; it books nothing.

## Boundaries & Constraints

**Always:**

- **Awaiting disposition is a place: the RETURNS system bin.**
  - **The bin.** `ensureReturnsBinInTx` (`tenancy/receiving-bin.ts`) is a fourth copy of the IN-TRANSIT shape: zone and bin code `RETURNS`, `system_owned`, the 1M sentinel.
  - **Code collision.** A user-created bin named `RETURNS` refuses with 409 `returns-bin-conflict` (the `transfer-in-transit-bin-conflict` precedent, `:262-285`), and a user zone named `RETURNS` is refused the same way, never adopted.
  - **Excluded everywhere other system bins are.** Count, transfer, merge, pick, replan and putaway already exclude system-owned bins, and replenishment and channel sync read ATP. Two places refuse by code and must name RETURNS: the adjustment refusal (`inventory.command.ts:954-956`) and the QC-hold origin refusal (`qc.command.ts:326`). Only 13-3 moves stock out of RETURNS.
  - **ATP.** `reservation.service.ts` gains `returnsAwaitingUnits`, shaped like `qcHeldUnits` (`:76`). It is subtracted in `atp` (`:886`) and `committedCeiling` (`:1390`), and added to `AtpSnapshot` (`:226-240`), `ChannelVisibleSnapshot`, the refusal messages (`:303,561,2024`), the API DTO and openapi. The race-window comment at `:1546` is extended.
  - **The epic's quarantine decision.** This is the epic's "quarantine representation" call for 13-2. 13-3 decides its own quarantine move.
- **The ledger.**
  - **Reference arm.** A new `LedgerReferenceDoc` arm, added only: `{kind: 'return-receipt', returnReceiptId, rmaId, rmaLineId}`.
  - **Event type.** `return.received` is registered with `sinceVersion: 1` and both the batch and serial arms open. It is a positive move to RETURNS from no bin, with the event time = the op's `occurredAt`.
  - **Client.** It is taken from the SKU (21-2b).
  - **Unchanged machinery.** Reconcile and metering fold it by bin arms with no change. The serial guard admits an intake of a picked serial, because a pick draws with `toBinId` null.
- **Migration 0073** (§3 checklist; the probe covers every new CHECK).
  - **`return_receipts`:** `id`, `tenant_id`, `client_id`, `warehouse_id`, `rma_id`, `code`, `device_id`, `received_by`, `idempotency_key`, `occurred_at`, `created_at`.
    - The code is `RRN-0001`, allocated per tenant under `hashtextextended(tenant || ':rrn-seq', 0)`.
    - Unique `(tenant_id, code)`.
  - **`return_receipt_lines`:**
    - **Columns:** `id`, `tenant_id`, `return_receipt_id`, `rma_line_id`, `sku_id`, `line_no`, `qty` (milli, > 0), `condition` (CHECK: the four grades), `note` (nullable, 1–200 characters), `batch_id`, `serial_id`, `handling_unit_id`, `ledger_event_id`, `created_at`.
    - **Shape CHECKs:** at most one of `serial_id` and `handling_unit_id` is set, and `serial_id` set ⇒ `qty` = 1 unit.
    - **Index:** unique `(rma_line_id, serial_id) WHERE serial_id IS NOT NULL`.
  - **`return_authorization_lines`:** gains CHECK `received_qty <= authorized_qty`.
  - **The authorization's status CHECK** widens to `open|partially_received|received|cancelled` (the 0070 drop-and-re-add). The backend `RMA_STATUSES` tuple (`return-authorization.command.ts:40`) widens with it, and with it the DTO enum and the list filter.
  - **`handling_units`:**
    - `grn_line_id` becomes nullable;
    - a new `return_receipt_line_id` column, with CHECK that exactly one of the two is set;
    - the status CHECK gains `returned`, a non-packable status. `HANDLING_UNIT_STATUSES` and its pin widen too, and `CreateHandlingUnitInput` takes either provenance. 13-3 changes the status when it restocks.
  - **RLS** follows the 13-1 client-document shapes. **No FKs.**
- **13-1's double-authorization guard is fixed.** `returnableFactsInTx` sums authorized quantity and serials over `status IN ('open','partially_received','received')` instead of `= 'open'` (`:503-522`). Otherwise a received authorization's units become authorizable again. A test pins it: after a receipt, a second RMA for the same order line refuses `exceeds-returnable` or `serial-already-authorized`. The other `'open'` literals (`:873,893`) are correct and stay.
- **The receive op `return.receive`.** Device-authenticated, following `grn.submit`.
  - **Route.** `POST /tenants/{t}/returns/receipts`, guarded by `DeviceSessionGuard`. The `Idempotency-Key` is the op's ULID.
  - **Body.**
    - **Fields:** `{warehouseId, rmaId, occurredAt, entries: [{rmaLineId | null, skuId, qty, condition, note?, batchCode?, serialNumber?, weightGrams?}]}`.
    - **Entry caps:** 1–150 entries, so the worst-case payload stays under the sync report's 32 KB per row. The device splits a larger receipt into several ops.
    - **One entry per unit or case:** a serial entry is 1 unit; a catch-weight entry is 1 case with its weight.
    - **Shape errors** are 400, checked above the transaction.
  - **Hash.** Taken over the whole body, including `warehouseId` and `occurredAt`, with `rmaLineId` hashed as an explicit null.
  - **The device and role guard** is the GRN one (`:408-435`), exported from tenancy as `assertDeviceOperatorInTx`, so returns reads no `devices` or `users` table.
  - **In one transaction:**
    1. The device and role guard.
    2. Replay.
    3. Lock the RMA `FOR UPDATE`. This checks existence only: an unknown RMA is 404 `not-found`.
    4. Replay again under the lock.
    5. `warehouseId` must equal the RMA's warehouse; otherwise 409 `document-warehouse-mismatch` (21-6b order: before status).
    6. An RMA not `open` or `partially_received` is 409 `rma-not-receivable`.
    7. Pre-lock the serials named, sorted (`lockSerialsInTx`).
    8. **Classify each entry, in order.** The remaining quantity per line is `authorized − received`, decremented as entries apply. An entry applies only when all of these hold:
       - its `rmaLineId` is on this RMA, and its `skuId` is that line's SKU;
       - its quantity is ≤ the remaining quantity at the SKU's precision (whole units for catch-weight);
       - for a serial-tracked SKU, its serial resolves to one of the line's authorized `serial_ids`, not yet received and not currently on-hand in any bin;
       - for a batch-tracked SKU, its batch is among the line's picked batches. For a batch-and-serial SKU, it must be **that serial's own** pick `batchRef`. The resolved batch id is reused rather than created;
       - for a catch-weight SKU, `weightGrams` is present and within `MAX_HANDLING_UNIT_WEIGHT_GRAMS`.

       Everything else is refused with one of these reasons: `not-on-authorization`, `exceeds-authorized`, `serial-not-authorized`, `serial-in-stock`, `batch-not-dispatched`, `missing-capture`.
    9. **Write each applied entry:**
       - for catch-weight, a new handling unit, `returned`, with the case's weight and return provenance;
       - one `return.received` event into RETURNS, with its batch and serial arms;
       - one receipt line (`line_no` in request order);
       - the RMA line's `received_qty` increases by the entry's quantity.

       A receipt row is written only if at least one entry applied.
    10. **Status.** `received` when every line is fully received, `partially_received` otherwise, unchanged when nothing applied.
    11. **Refused entries.** If any exist, write **one** rejected-op row through a new tenancy write `SyncReportCommand.recordServerRejectedOpInTx`:
        - `opType: 'return.receive'`, `classification: 'rejected'`;
        - `problemCode: 'return-entries-refused'`, with `problemDetail` listing the reasons;
        - `attribution` built by tenancy from the device and user rows;
        - `opEnqueuedAt` and `opOccurredAt` = `occurredAt`;
        - payload `{warehouseId, rmaId, rmaCode, occurredAt, entries: <the refused entries>, refusals: [{entryIndex, reason}]}`;
        - `opId` is a valid ULID derived deterministically from the op's key (the key's timestamp plus a hash of `key + ':refused'`). It never equals the key, and it is recorded in the idempotency snapshot, so a replay inserts nothing new.

        It raises `device.rejected_op.raised`, so the 9-2 `rejected-op` panel entry fires.
    12. Outbox `return_receipt.recorded` (`{returnReceiptId | null, rmaId, warehouseId, appliedCount, refusedCount}`).
    13. Audit `return_receipt.recorded`, actor the operator, `reference` = the key. Target `return_receipt` → the receipt, or `return_authorization` → the RMA when nothing applied.
    14. The key is written last.
  - **Answer.** 201 `{returnReceiptId | null, code | null, rmaStatus, applied: [{entryIndex, rmaLineId, qty}], refused: [{entryIndex, reason}]}`.
- **Review rows are Discard only (decision 4).** There are two origins:
  - the server-raised refused-entries row;
  - the device-uploaded row of a whole-op refusal (`rma-not-receivable`, `document-warehouse-mismatch`), carrying the full payload under the device's op id.

  How the review code handles them:
  - `sync-report.command.ts` adds `return.receive` to `RejectedOpType`, `REJECTED_OP_TYPES` and `PAYLOAD_FIELDS`, with `refusals`, `rmaCode` and `warehouseId` optional.
  - A new per-type decision rule (`REJECTED_OP_DECISIONS_BY_TYPE`) admits only `discard` for `return.receive`. Apply and recount answer 409 `decision-not-available`, and `applyArm` gets no case for it, so tenancy never imports returns.
- **Snapshot `openReturns`.**
  - **Composition.** `ReturnsFacade.getOpenReturns(tenantId, warehouseId)` is injected into `ReceivingController` and composed beside the task lists. It is a plain facade call (`receiving.controller.ts:182-198`).
  - **Contents.** RMAs in `open` or `partially_received`: `{id, code, orderReference, lines: [{id, skuId, authorizedQty, receivedQty, openQty, batchCodes, serials: [{id, serialNumber, received, batchCode}]}]}`.
  - **Docs.** PENDING inbound's fan-out entry is updated.
- **The handheld (wms-mobile).** 13-5 still owns the inbox chip and the task cards.
  - **The screen.** A **new thin screen** `app/return-receive.tsx`, registered in `app/_layout.tsx` and reached by `/return-receive?raId=` or a "Receive a return" button on the inbox (not a chip and not a card). `app/receive.tsx` and `src/receiving/draft.ts` are **not edited**. The small scan-input and weight-entry pieces are written fresh for returns, and that duplication is recorded in PENDING.
  - **The rules: `src/returns/draft.ts`,** pure, every string pinned by tests.
    - **Choose step.** The open RMAs of the snapshot's warehouse, as cards showing "RMA-0007 · N lines open". There is no summed-unit text.
    - **Entry.** An entry is (line, SKU, condition, batch). The grade is chosen at the entry step, covers that entry's quantity, is required, starts unset and then stays selected for the next unit. A different grade commits the entry and starts a new one.
    - **Serials.** A serial-tracked SKU takes one entry per serial scan, using a serial scan input with camera and HID interchangeable.
    - **Line choice.** A SKU on several lines takes the serial's own line first, otherwise the first line with open quantity.
    - **Capture.** Batch is captured for batch-tracked SKUs, with an amber hint when it is not among the line's `batchCodes`. Catch-weight captures one weight per case.
    - **Refusal on the device.** An unknown barcode is refused on the device, as in receiving. A known SKU not on the RMA, an unauthorized serial or an excess unit reads amber "Not on this return — it will be reviewed" and is still queued, with `rmaLineId: null` where there is no line.
    - **Queued work.** The device subtracts its own queued `return.receive` entries from `openQty` and the serial `received` flags (the pick `refreshConsumed` pattern).
    - **Splitting.** It splits above 150 entries.
    - **Banner.** It states the divergence (UX EXPERIENCE.md:53): "Return receipt — anything not on the return is queued for review, never refused here."
  - **The op.** A new `OpType` `return.receive`, enqueued to the sealed outbox before any send. The touch points:
    - `src/offline/types.ts`;
    - `src/state/op-dispatch.ts`;
    - `src/api.ts` (the payload type, and `SyncReportRowPayload.opType`);
    - `src/state/replay-classification.ts`;
    - `src/state/sync-report-uploader.ts`;
    - the cross-type FIFO test in `engine.test.ts`.

    The recipe's inbox step is deferred to 13-5, except for the nav button.
  - **Replay fates.**
    - A 201 goes through `settledNote` with a new `returnReceiptNote(response)`, pinned. It is a settled op and, when entries were refused, it adds a retraction line to the sync summary: "RRN-0003 — 2 unit(s) not booked (exceeds-authorized, …) — sent to review". This is not "Held for review", which stays reserved for quarantined replays.
    - `rma-not-receivable` gets its own named terminal-drop branch, and `document-warehouse-mismatch` uses its existing one. Both upload the full payload to the review queue.
    - `returns-bin-conflict` is a whole-op refusal and drops the same way.
  - **Snapshot parse.** `openReturns ?? []`, plus the legacy-seal equality test.
- **The web.**
  - **Labels.** `RETURN_STATUS_LABEL` gains `partially_received` ("Partly received") and `received` ("Received"). A new `RETURN_CONDITION_LABEL` is a `Record` over the generated condition union.
  - **Receipts.** They ride **only** on `GET /returns/{id}`, fetched when a row is expanded. Each carries `{code, occurredAt, operatorEmail (resolved by the server), lines: [{rmaLineId, qty, condition, note, batchCode, serialNumber, weightGrams}]}`. The list keeps `receivedQty` per line. The `receipts` field on the stored RMA snapshot is optional, so pre-13-2 replays still serve (§9).
  - **Expanded row.** It shows each line's received quantity, and the "↩ Awaiting disposition" badge (amber, word-first) on lines with received units. 13-2 never clears it.
  - **Cancel** stays hidden once anything is received; `canCancelReturn` already does this.
  - **The rejected-ops queue.** `return.receive` rows show a summary from a new helper `rejectedOpSummary`: the RMA code and each refused entry with its reason. They offer **Discard only**, with the decision-4 guidance text. The decision buttons now follow the server's per-type rule.
- **Vocabulary.**
  - **Audit.** `return_receipt` joins `AUDIT_TARGET_TYPES` and the web label, and `return_receipt.recorded` joins `AUDIT_NEW_ACTIONS` with `expectAuditRow`.
  - **Outbox.** The event constant goes in `returns/events.ts`.
  - **No new capability.** Receiving is a floor verb, and Discard keeps `review.decide`.
- **Architecture.**
  - The returns read guard (`architecture.spec.ts:1895`) and import guard (`:1909`) are amended to admit the new tables and the tenancy helpers, with returns importing from tenancy and not the reverse.
  - The ownership block gains `return_receipts` and its lines.
  - `handling_units` stays catalog's: returns writes it only through `CatalogFacade`.
- **"At next touch" claims** (retro action item 4).
  - **Closed:** PENDING returns' "catch-weight and batch bound at 13-2".
  - **Declined, recorded:**
    - the GRN refused-lines gap (unchanged);
    - the snapshot fan-out (grown);
    - the duplication item (action item 3);
    - the mobile mixed-unit sums (this story avoids them).

**Never:**
- No disposition: nothing leaves RETURNS (13-3).
- No blind return.
- No inbox chip or task card (13-5).
- No photos.
- No edits to `app/receive.tsx`, `receiving/draft.ts` or the GRN rules.
- No apply or recount for `return.receive` review rows.
- No RMA amend.
- No `rmaId` ledger filter (13-4).
- No new capability.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Happy path | RMA 2 × A; receives 2 `resaleable` | 201 `RRN-0001`; 2 receipt lines; 2 `return.received` into RETURNS; RMA `received`; ATP for A unchanged | — |
| Partial | Receives 1 of 2 | `partially_received`; the snapshot shows 1 open | — |
| No double authorization | After a receipt, a new RMA on the same line | — | 409 `exceeds-returnable` / `serial-already-authorized` |
| Serial | An authorized serial | Applies; the serial is in RETURNS | Unauthorized → refused `serial-not-authorized`; a serial already in stock → refused `serial-in-stock` |
| Batch | Batch-tracked line picked from B1; batch-and-serial with the serial's own batch | Applies | B9, or another serial's batch → refused `batch-not-dispatched` |
| Catch-weight | One case, 2,340 g | A new `returned` handling unit, which pack cannot scan | No weight → refused `missing-capture` |
| Mixed parcel | 2 authorized + 1 extra + 1 SKU not on the RMA (`rmaLineId: null`) | 2 apply; one rejected-op row holding 2 entries with reasons; panel `rejected-op` | — |
| All refused | Every entry refused | No receipt row; RMA unchanged; one rejected-op row; audit target = the RMA | — |
| Replay | Same op ULID | Same 201; no second rejected-op row or event | Different body → 422 |
| Wrong state / warehouse | RMA cancelled or received / body `warehouseId` ≠ the RMA's | — | 409 `rma-not-receivable` / `document-warehouse-mismatch`; the device drops it and uploads it to review |
| Review | A `return.receive` row | Discard resolves it | Apply or recount → 409 `decision-not-available` |
| RETURNS protected | An adjustment or QC hold on RETURNS stock; a pick or putaway | — | Refused (by bin code / system-owned) |
| Bin conflict | A user bin or zone named RETURNS | — | 409 `returns-bin-conflict` |
| ATP | Stock in RETURNS | Excluded from ATP, the ceiling and the channel-visible figure | — |
| Device / role | Revoked device; a non-floor role | — | 403 (the GRN arms) |
| Mobile | Choose cards (line counts), `?raId=`, the inbox button; the grade required and then sticky; a serial input per unit; amber "not on this return" queued with `rmaLineId: null`; queued work subtracted; split above 150; banner copy; the settled note with its retraction line; terminal drops; snapshot default `[]` | As specified | — |
| Web | Labels; condition labels; receipts loaded when a row expands, with the operator's email; the awaiting badge; Cancel hidden after receipt; the queue row summary with Discard only | As specified | — |

</frozen-after-approval>

## Code Map

Paths are under BE `workspace/core/backend/wms-be/src`, mobile `workspace/core/mobile/wms-mobile`, and FE `workspace/core/frontend/wms-fe/src`.

- **The GRN template** is `modules/inbound/receiving.command.ts`:
  - `:334` `submitGoodsReceipt`;
  - `:408-435` the device and role guards (to export);
  - `:438-448` the replay;
  - `:565-578,604,650,1758` the warehouse comparison against the body;
  - `:1150-1156`;
  - `:1665-1677` the code allocation;
  - `:893-952` the catch-weight units.
- **System bins** are in `modules/tenancy/receiving-bin.ts`:
  - `:22,46,67`, and `:136,211` (the ensure functions);
  - `:262-285`, the conflict 409 precedent.
- **ATP** is `modules/inventory/reservation.service.ts`:
  - `:76` `qcHeldUnits`;
  - `:119` `inTransitUnits`;
  - `:226-240` `AtpSnapshot`;
  - `:303,561,2024`;
  - `:886` the ATP formula;
  - `:1390` the committed ceiling;
  - `:1546`.
- **Code-named refusals:** `modules/inventory/inventory.command.ts:954-956` (adjustment); `modules/inbound/qc.command.ts:326` (QC origin).
- **Ledger:**
  - `ledger-registry.ts:18,70-85,118-131,310-316,424-455`;
  - `ledger.service.ts:507-534` (the serial guard), `:605-625` (client attribution), `:761` `lockSerialsInTx`;
  - `inventory.facade.ts:1223-1248` `ledgerEventsByOrderRefInTx`.
- **Catalog:**
  - `schema.ts:898-913` (`handling_units`, `grn_line_id` NOT NULL at `:908`);
  - `catalog/handling-unit.ts:40`;
  - `handling-unit.store.ts:107-125` `createHandlingUnitsInTx`;
  - `outbound/pack.command.ts:963-1010` and `outbound.facade.ts:~1188` (pack accepts an active unit);
  - `CatalogFacade.serialIdentitiesInTx`.
- **Sync report:**
  - `modules/tenancy/sync-report.command.ts`:
    - `:80-98`, `:103`, `:204-250`, `:257`;
    - `:378` (the 32 KB row limit);
    - `:832` (the decision check);
    - `:922` (recount needs a bin);
    - `:1116-1160` `applyArm`;
  - `schema.ts:3586-3602` (the `rejected_ops` NOT NULL columns);
  - `api/rejected-ops.dto.ts:203-212`.
- **Returns (13-1):**
  - `modules/returns/return-authorization.command.ts`:
    - `:40` `RMA_STATUSES`;
    - `:503-522` (the open-only sums to fix);
    - `:873,893`;
    - `:1037,1063` (the stored snapshots);
  - `returns.facade.ts`, `returns.module.ts`, `events.ts`;
  - `test/returns.spec.ts` (`:195-206` badge-in, `:819`);
  - `test/support/dispatched-order.ts` (extend it to seed a batch-tracked and a catch-weight dispatch).
- **Snapshot:** `api/receiving.controller.ts:182-198`; `modules/inbound/receiving.facade.ts:124,424,524`; `receiving.dto.ts:860`.
- **Architecture:** `test/architecture.spec.ts:1895,1909` (the returns guards).
- **Mobile:**
  - screens: `app/_layout.tsx`, `app/inbox.tsx:325`, `app/receive.tsx` (read only, as a reference);
  - `src/picking/draft.ts:453` `addSerial`, and `app/pick.tsx:68,234` (the serial-step reference);
  - `src/offline/types.ts:34-42`;
  - `src/state/op-dispatch.ts:108`;
  - `src/state/replay-classification.ts:71-85,187-231` (`settledNote`, `goodsReceiptNote`);
  - `src/state/sync-report-uploader.ts`;
  - `src/state/catalog-snapshot.ts:62-65`;
  - `src/api.ts:208,274,958,1153`;
  - `engine.test.ts`;
  - `docs/design/mobile/IMPLEMENTATION-GUIDE.md:11-52,147,269-300`.
- **Web:**
  - `lib/returns.ts:45-48`;
  - `components/returns/returns-view.tsx`;
  - `components/conflicts/rejected-ops-queue.tsx:290,398-411`;
  - `lib/review-queue.ts:220`;
  - `lib/notifications.ts:163`;
  - `lib/audit.ts:23`.
- **UX:** `EXPERIENCE.md:52-53,78,113`; `DESIGN.md:124`.

## Tasks & Acceptance

**Execution:**
- [ ] **BE migration 0073** (§3): the receipt tables; the RMA line CHECK; the status widening; the `handling_units` provenance and `returned` status; journal, snapshot, probe.
- [ ] **BE tenancy:**
  - `ensureReturnsBinInTx` and its conflict 409;
  - export `assertDeviceOperatorInTx`;
  - `recordServerRejectedOpInTx`;
  - `REJECTED_OP_DECISIONS_BY_TYPE`, plus `return.receive` in the type list and `PAYLOAD_FIELDS`.
- [ ] **BE inventory:**
  - the reference arm and the `return.received` registration;
  - `returnsAwaitingUnits` through ATP, the ceiling, the snapshots, the messages and the DTO;
  - RETURNS in the adjustment and QC-origin refusals.
- [ ] **BE catalog:** `CreateHandlingUnitInput` provenance, `returned` status, pins.
- [ ] **BE returns:**
  - the 13-1 sum fix and its pin;
  - the receive command;
  - `getOpenReturns`;
  - receipts on the detail read (optional on stored snapshots);
  - events;
  - guards amended.
- [ ] **BE api:** `POST returns/receipts` (device); snapshot composition; DTOs; openapi.
- [ ] **BE tests:** every backend matrix row; extend `test/support/dispatched-order.ts`; an ATP projection-and-replay reconcile with stock in RETURNS.
- [ ] **Mobile:**
  - `src/returns/draft.ts` and its strings;
  - `app/return-receive.tsx`, `_layout`, and the inbox button;
  - the op touch points;
  - `returnReceiptNote` and the drop branches;
  - snapshot parse;
  - tests (`bun test` and typecheck).
- [ ] **FE:**
  - `api:generate`;
  - the status and condition labels;
  - receipts loaded when a row expands;
  - the awaiting badge;
  - the per-type decisions and `rejectedOpSummary`;
  - the audit label;
  - tests.
- [ ] **Meta docs:**
  - `returns.md`, `inventory.md` (the ATP term, the event, the refusals), `tenancy.md` (the RETURNS bin, server-raised rejected ops, per-type decisions), `catalog.md` (provenance, `returned`), `inbound.md`;
  - the mobile docs;
  - API-SURFACE, SYSTEM-DESIGN, `frontend/SYSTEM-DESIGN.md`;
  - the three repo contracts;
  - PENDING:
    - close "catch-weight/batch bound at 13-2";
    - add: no link from a returned case to its original case; Discard books nothing; no `rmaId` filter; 13-3's quarantine choice; the fan-out grown; the duplicated mobile scan/weight pieces; blind returns.

**Acceptance Criteria:**
- Given an open RMA cached on a handheld, when an operator receives its units with grades, then the web shows the RMA received with each unit's condition, the units sit in RETURNS, and ATP is unchanged.
- Given a parcel with one unit too many, when it is received, then the authorized units apply, and one `return.receive` row appears in the review queue offering Discard only.
- Given the full BE, FE and mobile suites, lint and typecheck, build, and the capability-mirror check, when run, then they pass.

## Implementation Notes

## Spec Change Log

## Review Triage Log

Design review (2026-10-16), two lenses: backend (K), and mobile/web/API/tests (M). 33 findings, merged into 24 rows below.

| # | Lens | Finding | Verdict | Disposition |
|---|---|---|---|---|
| 1 | K | Widening the status breaks 13-1's double-authorization guard: the sums read `status = 'open'` only | high (verified: `:503-522`) | Fixed: the sums read `IN ('open','partially_received','received')`; a pin |
| 2 | K, M | An entry could not name a SKU that isn't on the RMA | high | Fixed: `{rmaLineId \| null, skuId}`; `not-on-authorization` |
| 3 | K, M | There is no "device's warehouse"; the GRN compares the body's `warehouseId` | high (verified: `schema.ts:1817-1838`, `receiving.command.ts:604`) | Fixed: `warehouseId` in the body and the hash; checked before status |
| 4 | M | There was no `occurredAt`, so a replayed receipt took server time | high (verified: the GRN hashes it) | Fixed: in the body and the hash; used as the event time |
| 5 | K | A returned case cannot be created: `handling_units.grn_line_id` is NOT NULL | high (verified: `schema.ts:908`) | Fixed: provenance columns with an exactly-one CHECK |
| 6 | K | An `active` returned case could be packed for another order | high (verified: `pack.command.ts:963-1010`) | Fixed: the non-packable status `returned`; 13-3 changes it |
| 7 | K, M | The apply arm could never match, and the actor rule was misstated | high (verified: `:1116-1160`) | **Human decision 4: Discard only**; per-type decisions; no `applyArm` case; actor claim removed |
| 8 | M | 500 entries break the 32 KB sync-report row | high (verified: `:378`) | Fixed: 150 entries; device splits; 200-character notes |
| 9 | M | Adding `raId` to `/receive` means forking the screen; every handler is typed to the PO/ASN draft | high (verified: `receive.tsx:88,182,409`) | Fixed: a thin new `return-receive.tsx`; receive untouched; a nav button, not a chip |
| 10 | K, M | The server-raised rejected-op row left NOT NULL columns unset, and there was nowhere to put the reasons | medium (verified: `schema.ts:3586-3602`) | Fixed: `problemCode` and detail, attribution, enqueued and occurred times; `refusals` a sibling key; derived id ≠ key |
| 11 | M | The "Accepted + N sent to review" state was mapped to the wrong code path | medium (verified: `settledNote`) | Fixed: `returnReceiptNote`, a retraction line; named drop branches |
| 12 | K | RETURNS stock could be adjusted or QC-held | medium (verified: `:954-956`, `qc:326`) | Fixed: both refusals name RETURNS |
| 13 | K | Returns guards would refuse the device and user reads; import cycle risk | medium (verified: `architecture.spec.ts:1895,1909`) | Fixed: an exported tenancy helper; discard-only removes tenancy → returns |
| 14 | K | A batch-and-serial SKU could book the wrong batch | medium | Fixed: the serial's own pick `batchRef` |
| 15 | K | A user bin or zone named RETURNS blocks receipt | medium (verified: `receiving-bin.ts:262-285`) | Fixed: 409 `returns-bin-conflict`; zone not adopted; device drops |
| 16 | K | The all-refused case has no audit target | medium (verified: `target_id` NOT NULL) | Fixed: target the RMA |
| 17 | M | Grade per scan clashed with how quantities accumulate; line choice for a SKU on several lines | medium | Fixed: entry = (line, SKU, condition, batch); sticky grade; line rule |
| 18 | M | The device didn't subtract its own queued receipts | medium | Fixed: the `refreshConsumed` pattern |
| 19 | M | The snapshot lacked batch codes; cards used mixed-unit sums | medium | Fixed: `batchCodes`; line counts |
| 20 | M | Receipts in the list DTO bloat the list; the operator name needs a join | medium | Fixed: detail only, loaded on expand; email resolved by the server |
| 21 | K, M | The snapshot method was misnamed as in-transaction | low (verified: `:182-198`) | Fixed: `getOpenReturns` |
| 22 | K | ATP read shapes (snapshots, messages, DTO) need the new term; Code Map line refs were wrong | low | Fixed |
| 23 | K | Old RMA snapshots replay without the new field; locking and backstops | low | Fixed: optional `receipts`; sorted serial pre-lock; `serial-in-stock`; unique serial index; `received ≤ authorized` CHECK |
| 24 | M | Touch points missing; per-type rejected-op rendering; fixture gaps; `context:` | low | Fixed: listed; `rejectedOpSummary`; fixture task; context amended |

## Design Notes

**Why a RETURNS bin, not a held flag.** Every existing ATP exclusion is a place the projections already sum. A flag would be a second mechanism that replay-reconciliation would have to learn. A place also gives 13-3 a clean source for its outgoing moves.

**Why a new screen.** PO receiving refuses on the device; a return never refuses a known SKU (UX EXPERIENCE.md:53). `receive.tsx` is typed end to end against the PO/ASN draft, and no screen test convention exists to catch a regression there. A thin new screen keeps the existing receive flow byte-identical. The cost is a small, recorded duplication of the scan and weight inputs.

**Why Discard only.** An authorization can't be amended, and the stored request names its original RMA lines, so re-applying it could never match. "Create an authorization, then receive again" is the honest remedy (human decision 4). It also keeps tenancy from importing returns.

## Verification

**Commands** (BE runs one jest invocation at a time):
- `cd workspace/core/backend/wms-be && bun run test -- test/return-receipts.spec.ts` -- expected: all pass.
- `cd workspace/core/backend/wms-be && bun run test && bun run lint && bun run typecheck` -- expected: green.
- `cd workspace/core/frontend/wms-fe && bun test && bun run lint && bun run typecheck && bun run check:capability-mirror && bun run build` -- expected: green.
- `cd workspace/core/mobile/wms-mobile && bun test && bun run typecheck` -- expected: green.
