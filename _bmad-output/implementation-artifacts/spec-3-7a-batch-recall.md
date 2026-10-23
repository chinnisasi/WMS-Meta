---
title: '3-7a batch recall — open a recall over a client''s lots (blocks them in every warehouse at once), see where the lot sits and which open orders hold it, trace every shipment and receipt, download a client recall report (staff and portal), close it with disposition figures'
type: 'feature'
created: '2026-10-23'
status: 'ready-for-dev'
route: 'dispatch'
review_loop_iteration: 0
context:
  - '_bmad-output/implementation-artifacts/epic-3-context.md'
  - '_bmad-output/implementation-artifacts/spec-3-3a-batch-block-and-unpromisable-stock.md'
  - '_bmad-output/implementation-artifacts/spec-5-3a-operational-registers.md'
  - 'docs/initiatives/production-readiness.md'
  - 'docs/design/SYSTEM-DESIGN.md'
  - 'docs/design/IMPLEMENTATION-GUIDE.md'
  - 'docs/design/modules/catalog.md'
  - 'docs/design/modules/inventory.md'
  - 'docs/design/modules/outbound.md'
  - 'docs/design/modules/inbound.md'
  - 'docs/design/modules/reporting.md'
  - 'docs/design/modules/clients.md'
  - 'docs/design/API-SURFACE.md'
  - 'docs/design/PENDING.md'
  - 'docs/design/frontend/SYSTEM-DESIGN.md'
  - 'docs/design/frontend/IMPLEMENTATION-GUIDE.md'
  - 'docs/design/mobile/SYSTEM-DESIGN.md'
  - 'docs/design/mobile/IMPLEMENTATION-GUIDE.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** When a brand recalls a lot, the warehouse needs four things. It must stop the lot everywhere at once. It must know where the units sit and which orders hold them. It must know who received the units and where they came from. And it must give the brand a report. 3-3a gives a single-batch block (lot-wide, reason `recall`). Nothing groups a recall, finds a lot code across SKUs, traces shipments, or answers the brand. A picked or packed order holding a blocked lot still dispatches: `dispatch.command.ts` checks only status (`:244-267`), and the dispatch events carry `batchRef: null` (`:384`).

**Approach:** Add a **recall** document in catalog. Opening it names 1–50 batches of one client, with a reason note and the brand's reference. In the same transaction it blocks every active batch it names, through 3-3a's block logic (reason `recall`). Read-only traces in reporting are composed through the owning facades. Dispatch refuses an order whose picked units include a blocked batch. The client report is a CSV/XLSX file, served to staff and on the portal. Closing records server-derived disposition figures and optionally releases the blocks.

**Depends on 3-3a.** WMS-BE `feat/3-3a-batch-block` must merge first: its block/unblock verb, migration 0092 and `unpromisableBatchUnits`. Code against main after that merge.

**Decisions (recommended, taken autonomously):**
1. **Split.** These are deferred-work entries, placed after the 3-3b entry:
   - **3-7b** notifying consignees and the client, and the full-contact export;
   - **3-7c** recalling non-batch SKUs by date range;
   - **3-7d** a recall opened from the portal, or a block the client requests there, and charging for a recall.
2. **Identity.** A batch is unique per `(tenant, sku, code)` (`schema.ts:1163`). One lot code can therefore span several SKUs, and it has no client column. A recall names **batch ids**:
   - The web resolves them from "client + lot code" through a candidates read.
   - Every batch must belong to the same client, derived from its SKUs (`assertSingleClientInTx`; otherwise 409 `mixed-client`).
   - A suspended or departed client is **not** refused, because safety comes first.
3. **Capability.** `qc.manage` for open and close, the same as 3-3a. Reads are open to any staff role, like the batch reads and registers (5-3a decision 7).
4. **Blocking.**
   - An `active` batch is blocked by the recall. The line records `blocked_by_recall = true`.
   - A batch already blocked for another reason stays as it is (`false`).
   - A batch already on an **open** recall gives 409 `batch-already-recalled`, naming that recall's code.
   - 3-3a's standalone **unblock** gains 409 `batch-under-recall` while any open recall names the batch. It sits behind the replay and under the batch lock.
5. **Open orders (flag and refuse; no automatic un-allocation).** Reservations are per SKU, never per batch (`reservations`, `schema.ts:1976`). A batch is fixed only at pick: `deriveBatchArms` already skips non-active batches (`pick.command.ts:1553-1555`). So:
   - **Unpicked orders** are untouched. They draw another lot or short, as 3-3a does.
   - **Picked or packed orders** (status in `ORDER_OPEN_STATUSES` with `pick.picked` events of the lot) are listed as "held in open orders".
   - **Dispatch** refuses them with 409 `order-holds-blocked-batch`, naming the batch codes. The rule keys on batch status, so it covers any block reason (it closes 3-3a A12's "packed units keep moving"). The way to free such an order is 4-2b's unpack (deferred); until then it waits.
   - Backordering automatically would release holds that another lot could still fill, so it is not done.
6. **Serials.** A batch-and-serial SKU cannot be picked (`pick.command.ts:796`). A lot's dispatched units therefore never carry serials, and the trace has **no serial column**. Recorded.
7. **PII.** The trace and the report carry the consignee legal name and GSTIN, the destination city, state and pincode, the client order number, the channel reference, the carrier and the AWB. This is exactly the 5-3a outbound register's set. **No** contact name, phone or address lines appear; a full-contact export belongs with 3-7b. The portal sees only its own client's recalls and orders.
8. **The report** is one table (CSV, or a one-sheet XLSX), one schema with a `section` column:
   - `on_hand`: per warehouse × location role, with **no bin codes**, so the operator copy is the client copy;
   - `held_in_open_order`;
   - `dispatched`: one row per `pick.picked` slice;
   - `received`: one row per `grn.received` event.

   It is capped at `REGISTER_MAX_ROWS`, has a 15 s whole-read deadline and uses the register slots.
9. **Close.** It takes `{note (1–500), releaseBatches}`.
   - It freezes `close_summary`, the figures of decision 10 per lot as of close.
   - `releaseBatches: true` unblocks only lines with `blocked_by_recall` whose batch is still `blocked` with reason `recall`.
   - Otherwise the lots stay blocked, and are then unblockable through 3-3a.
   - A recall that is not open gives 409 `recall-not-open` (stores no key).
10. **Figures per lot.** These are derived from the ledger and projections, in base units, live on the detail and frozen at close.
    - `received`: Σ `grn.received` δ.
    - `onHand`: Σ `batch_on_hand`.
    - `heldInOpenOrders`: Σ |δ| of `pick.picked` whose order is open.
    - `dispatched`: the same Σ, for dispatched orders.
    - `returned`: Σ `return.received` δ.
    - `adjustedOut`: Σ |δ| of negative `stock.adjusted`.

    They are figures, not a reconciliation: moves, QC and damage are not summed.
11. **Web.**
    - An **Inventory → Recalls** tab (`?tab=recalls`) with:
      - the list;
      - "Open a recall" (`qc.manage`): client, lot code, the candidates checklist, reason note "visible to the client", brand reference;
      - the detail: lots and figures, where it sits (by warehouse/role, plus a paged bin list), held open orders, paged shipments and receipts, Download CSV/XLSX, and Close (`qc.manage`).
    - The portal gets **Recalls** (`/portal/recalls`): list, detail (lots, figures, per-warehouse on hand, with no bins and no orders but its own) and Download.
12. **Mobile.** Unchanged. Dispatch is web-only (`outbound.controller.ts:252-254`, `TenantSessionGuard`), and pick already skips blocked lots.

## Boundaries & Constraints

**Always:**
- Opening, blocking, outbox events, audit rows and the key are all written in **one** transaction.
- Recall reads write nothing and read only through facades.
- Portal reads use two layers (IMPLEMENTATION-GUIDE §7e): the `{ clientId }` stamp, plus `batch_recalls.client_id = $client`, with child rows reached only by joining to it.
- An unknown id and another client's id give the same 404.
- Every refusal precedes the first header of a file response.

**Never:**
- No consignee notification and no email (3-7b).
- No recall of untracked SKUs (3-7c).
- No portal write (3-7d).
- No automatic cancel, backorder or re-plan.
- No serial blocks.
- No new capability.
- No stock movement on open or close. Disposition stays the existing write-off adjustment, 2-8b RTV, or 13-x returns.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected | Error |
|---|---|---|---|
| Open | 2 ACME lots, active, stock in WH1 and WH2 | 201 `RCL-000001`; both blocked (reason `recall`); ATP drops in both warehouses; two `batch.blocked` and one `batch_recall.opened` audit rows under the key | — |
| Mixed client | One ACME lot plus one BETA lot | — | 409 `mixed-client` |
| Already recalled | A lot on an open recall | — | 409 `batch-already-recalled` (code) |
| Pre-blocked | A lot blocked `qc-failed` | Line `blocked_by_recall=false`; status untouched | — |
| Held order | Order packed with 3 units of the lot, then the recall opens | Listed as held; dispatch gives 409 `order-holds-blocked-batch`; a different-lot order dispatches | — |
| Unblock during recall | 3-3a unblock on a recalled lot | — | 409 `batch-under-recall` |
| Close release | `releaseBatches:true`; lot A blocked by the recall, lot B pre-blocked | A active; B still blocked; summary frozen | Re-close gives 409 `recall-not-open` |
| Portal | BETA session asks for ACME's recall or report | — | 404 (same as unknown) |
| Report | 50,001 rows / 3 concurrent / > 15 s | — | 422 `report-too-large` / 503 / 503, with no partial file |
| Replay | Same key and body; same key with a different body | The original snapshot | 422 `idempotency-key-reuse` |

</frozen-after-approval>

## Design Review Amendments

These come from the design review of 2026-10-23: a claims check (K1–K22, against origin/main and `feat/3-3a-batch-block`) and a blind review (B1–B24). They are recommended and were taken autonomously. **Where an amendment differs from the frozen block above, the amendment governs.**

**Base.** `feat/3-3a-batch-block` is stacked on 5-1a (0089), 3-2b (0090) and 2-8a (0091, which adds `qc.failed`). All four must merge before this story is coded. Line references below are on that branch (`[3a]`) or on main (`[m]`) where the file is unchanged.

---

### Ownership and locks

**A1 — A `recalls` module (supersedes "a recall document in catalog").**

- New module `src/modules/recalls/` owns `batch_recalls` and `batch_recall_lines`.
  - `RecallCommand`: `open`, `addBatches`, `close`.
  - `RecallsFacade`.
  - `recalls/client-wind-down.ts`.
- It depends on the catalog, inventory, outbound and clients facades. Nothing imports it back, so there is no cycle.
- The block/unblock helpers stay in catalog:
  - `catalog/batch-block.ts` exports `applyBatchBlockInTx` and `applyBatchUnblockInTx`.
  - They are exposed as `CatalogFacade.blockBatchInTx` and `CatalogFacade.unblockBatchInTx`.
- **Cross-module reads of recall lines go through one free-function seam:** `recalls/open-recall-lines.ts` (the §7h 1-6d pattern).
  - It exports `openLiveRecallLinesForBatchesInTx(tx, tenantId, batchIds) → {batchId, recallId, recallCode}[]`.
  - It imports only `drizzle-orm` and `shared/`.
  - Outbound (pick, dispatch), catalog (unblock) and inbound (receive) import the file, never the module. An architecture scan pins this.
- `test/architecture.spec.ts` gains a recalls block:
  - only `recalls` writes the two tables;
  - the seam file's imports are limited as above;
  - recalls imports siblings only through their facades.

**A2 — The dispatch guard refuses only an OPEN LIVE recall (supersedes decision 5's "keys on batch status", K3/B4).**

- **When it refuses.** Dispatch refuses only when a picked batch of the order sits on an open recall whose `mode = 'live'`. A lot blocked for any other reason (`qc-failed`, `expiry-review`, …) still dispatches, exactly as 3-3a left it.
- **The refusal.** The code is renamed to **409 `order-holds-recalled-batch`**, with `extensions: {batchCodes, recallCodes}`. Its detail names the remedies:
  - release the lot from the recall (close with `releaseBatchIds`);
  - or wait for the packed-order cancel/unpack deferred from 4.2.
- **Callers verified.** `dispatchOrder` is called only from `outbound.controller.ts:276-286 [m]` through `outbound.facade.ts:1150 [m]`. No return-to-vendor or return-to-client flow exists on main (2-8b is deferred). **Any disposition flow built later that ships recalled stock out must be exempted from this guard explicitly** (a PENDING note).
- **A stuck order's effects** go to PENDING:
  - its committed reservation keeps the reserved counter depressed, as with the existing "packed-but-abandoned" entry;
  - it is an `open-orders` wind-down blocker.

**A3 — Locks: `FOR KEY SHARE` on every picked batch (K1/K19).**

- **Dispatch.**
  1. After the status guards (`dispatch.command.ts:244-267 [m]`) and before the shipment read, dispatch reads the order's picked batch ids.
  2. It calls the new `inventory.pickedBatchRefsOfOrderInTx` (with the `reference_doc ? 'orderId'` qual).
  3. It locks **every one** with `CatalogFacade.keyShareLockBatchesInTx` (renamed from `shareLockBlockedBatchesInTx`): `FOR KEY SHARE`, ordered by id, with **no status filter**.
  4. Only then does it ask the seam which are on an open live recall.
- **Why `FOR KEY SHARE`.**
  - It conflicts with the `FOR UPDATE` taken by the block command (`batch-block.command.ts:301 [3a]`) and by every recall command.
  - It does not conflict with receiving's `FOR NO KEY UPDATE` expiry write (`ensureBatchesInTx`, `catalog.facade.ts:1083 [3a]`).
- **Two race tests.**
  - Block or recall commits first: dispatch waits, then answers 409.
  - Dispatch holds first: the recall waits, the order ships, and it appears in the recall's `dispatched` trace.

**A15 — `lock_timeout` and the lock order (B12).**

- **The timeout.** `open`, `addBatches` and `close` run `select set_config('lock_timeout', '5000', true)` first. A `55P03` is **503 `recall-open-contended`**; no key is stored and nothing is written. No such app-level timeout exists today (`lock_timeout` appears only in `migrate-deploy.ts`); this is the first.
- **The lock order, recorded in the guide.** The batch-row family sits **outside** the canonical chain: bin row → serial advisory → warehouse advisory.
  - **Recall commands** lock batch rows `FOR UPDATE`, with the recall row first for `addBatches` and `close`, then the recall-sequence advisory. They wait on nothing else.
  - **3-3a block** takes the batch `FOR UPDATE` only.
  - **Pick** takes the bin row `FOR UPDATE` (`pick.command.ts:746 [3a]`), then the new batch `FOR KEY SHARE` (A13), then serials (`:859`), then the warehouse advisory (`:877`).
  - **Dispatch** takes the order row, then batch `FOR KEY SHARE`, then the warehouse advisory inside the append.
  - **Receive** takes `FOR NO KEY UPDATE` on a batch only for the expiry write. That never conflicts with key-share and never waits on a recall lock.
  - **Putaway and adjust** take no batch lock.
- **Why it is acyclic.** No holder of a batch `FOR UPDATE` ever waits on a bin row, an order row or an advisory other than the recall sequence.
- **A race test.** A pick holds the batch key share while open waits. The pick commits, then open commits. Holding past 5 s gives 503.

---

### Commands

**A4 — Unblock under recall, and the UI (K4/K5/K14).**

- **The check.** `batch-under-recall` lives **only** in `BatchBlockCommand.unblock`. It runs after the `batch-not-blocked` guard (`batch-block.command.ts:251 [3a]`), through the seam, and covers live recalls only. It is **never** in `applyBatchUnblockInTx`, so a recall close can still release.
- **What changes around it.**
  - OpenAPI text on unblock's 409.
  - An API-SURFACE row.
  - `batchLifecycleViewsInTx` (`batch-block.command.ts:75 [3a]`) gains `recallCode: string | null` (an open live recall). It is optional on the DTO, because it is part of the stored snapshot (§9).
  - The 3-3a FE dialog (`components/inventory/batch-block-dialog.tsx`, `lib/batch-block.ts` on wms-fe `feat/3-3a-batch-block`) disables Unblock with "Under recall RCL-x — release it from the recall", and words the 409 the same way.
  - Dispatch's 409 gets OpenAPI text and copy in `dispatchReason` (`lib/outbound-pack-dispatch.ts:434 [m]`).
- **The standalone `recall` reason.** 3-3a's reason is kept. When it is chosen, the dialog shows "Recalling a lot? Open a recall instead — it blocks, traces and reports" with a link.
- **A test.** A close with release does actually release.

**A5 — Close releases a chosen subset (supersedes decision 9's `releaseBatches`, B1).**

- **Body.** `{note, releaseBatchIds: uuid[] (0..50, distinct), overrideReason?, acknowledgeUnaccounted?, dispositionNotes?, evidenceRef?}`.
- **Eligibility.** Each listed id must be a line with `blocked_by_recall`, whose batch is still `blocked` with reason `recall`. Otherwise it is 409 `recall-release-not-eligible`, naming the codes.
- **Stock check.** A listed batch with live `onHand + inTransit > 0` or `heldInOpenOrders > 0` is 409 `recall-release-has-stock`, unless `overrideReason` (1–500 code points) is given.
- **Recorded.** The override is recorded per batch in that batch's `batch.unblocked` audit `changes`.
- **Hash.** `{command:'recall.close', tenantId, recallId, note: normalised, releaseBatchIds: sorted, overrideReason: normalised ?? null, acknowledgeUnaccounted: bool, dispositionNotes: sorted by batchId, evidenceRef: ?? null}`.

**A6 — The close summary, frozen (B22, B6).**

- **Unaccounted stock.** A close with any batch's `unaccounted ≠ 0` requires `acknowledgeUnaccounted: true`; otherwise it is 409 `recall-unaccounted`. The flag is audited.
- **Optional inputs.** `dispositionNotes` is up to 50 entries of `{batchId (a line), note 1–500}`. `evidenceRef` is 1–200 code points (a destruction certificate number or similar).
- **The summary.** `close_summary` jsonb, schema version 1, built by one function and pinned by a golden:

  ```json
  {"v":1,"asOf":"<instant>","lots":[{"batchId","batchCode","skuId",
    "figures":{"received","receivedDamaged","onHand","inTransit","heldInOpenOrders",
               "dispatched","returned","adjustedOut","unaccounted"},
    "adjustedOutByReason":{"<reasonCode>": <base units>},
    "released": bool, "overrideReason": string|null, "dispositionNote": string|null}],
   "acknowledgedUnaccounted": bool, "evidenceRef": string|null}
  ```

- **What "disposition" means.** It is `adjustedOutByReason`: negative `stock.adjusted` grouped by `reference_doc ->> 'reasonCode'`. Return-to-vendor and return-to-client arms join it when 2-8b and 13-x ship (PENDING).

**A14 — Add batches; receiving into a recalled lot (B9).**

- **The command.** `POST …/recalls/{id}/batches {batchIds[1..50]}`, under `qc.manage`.
  - Guard order: lock the recall, replay again, 409 `recall-not-open`, then the same batch guards as open (A1).
  - Audit `batch_recall.batches_added`.
- **Candidates.** The candidates read flags a matching batch that is not on the open recall: `onRecall: null` with `sameCodeOnOpenRecall: 'RCL-x'`.
- **Receiving into a recalled batch** is still allowed (3-3a A11), and the batch stays blocked.
  - The `grn.submit` response gains an optional `recalledLots?: {batchId, batchCode, recallCode}[]`. It is absent when there are none and optional because it is a stored snapshot (§9). It is computed through the seam behind the replay.
  - The handheld's settled note says "Lot X is under recall RCL-y — keep it apart".
  - The web GRN lines read (`GET …/goods-receipts/{grnId}/lines`) gains an optional `recallCode`, shown as a badge.
  - The recall's `received` rows carry `during_recall = yes` when `recorded_at ≥ opened_at`.

**A18 — Validation and text rules (K11/K22).**

- **Above the transaction**, with the shape checks: note and ref trimming, the length rules in **code points** (`[...s].length`), distinct uuids and the array bounds, all 400.
- **Truncation.** The block note `RCL-x: <reasonNote>` is truncated to 500 code points.
- **Normalisation.** Every hash normalises its text first (trim; blank means absent).
- **The close audit assertion.** It uses `expectAuditRow` for `batch_recall.closed`, with `batch.unblocked` rows asserted **alongside** under the same key (one per released batch).

---

### Figures and reads

**A7 — The figures, redefined (supersedes decision 10, K6/B5/B6/B7).**

All figures are per batch, in base units.

| Figure | Definition |
|---|---|
| `received` | Σ `grn.received` |
| `receivedDamaged` | Σ `grn.damaged` |
| `onHand` | Σ `batch_on_hand`, **excluding** the IN-TRANSIT bin |
| `inTransit` | `batch_on_hand` in IN-TRANSIT bins |
| `heldInOpenOrders` | **net** pick quantity per (order line, batch) for orders in `ORDER_OPEN_STATUSES` |
| `dispatched` | the same, for `dispatched` orders |
| `returned` | Σ `return.received` |
| `adjustedOut` | Σ \|δ\| of negative `stock.adjusted` |
| `unaccounted` | Σ over **every** event of the batch of `ON_HAND_FOLD_TERM` (`inventory/client-metering.ts`), − `onHand` − `inTransit` |

- **Netting.** "Net" is the signed sum over `PICK_NETTING_TYPES`. On the base that is exactly `['pick.picked']`: of the 16 registered types (`ledger-registry.ts [3a]`: stock.adjusted, grn.received, qc.held, qc.released, putaway.placed, bin.merged, pick.picked, pack.packed, dispatch.dispatched, excursion.recorded, transfer.outbound, transfer.inbound, return.received, grn.damaged, qc.failed, stock.moved), none reverses a pick.
  - An architecture test fails when a registered type whose reference kind carries `orderLineId` and which moves quantity is missing from the list. The packed-order cancel/unpack must then join it.
- **`unaccounted` should read 0.** A non-zero value means the projection has diverged, or the batch is in a quarantined scope.
- **A fixture drives all 16 types** on one batch (including a WH1 → WH2 transfer left in transit, B7) and asserts `unaccounted = 0`.

**A8 — Bounded reads (K12/K15/K16).**

- **Held orders** are derived from the client's open orders, never by walking every pick of the lot.
  - The client's open orders come from a new partial index `orders_tenant_client_open_idx` on `("tenant_id","client_id","warehouse_id") WHERE "status" IN ('accepted','ready_to_dispatch')`.
  - Their `pick.picked` events of the recalled batches come in **one** statement. It is a set-valued sibling of `ledgerEventsByOrderRefInTx` (`inventory.facade.ts:1487 [3a]`), `ledgerPickEventsByOrderRefsInTx(tx, t, orderIds, batchIds)`, with the same `reference_doc ? 'orderId'` qual, `->> 'orderId' = any($)`, `type = 'pick.picked'` and `batch_ref = any($)`.
  - Calling the per-order method once per open order would be O(orders) statements; that is why there is a sibling.
- **Planned pick tasks** in bins that hold a recalled lot (A13) come from those same open orders: `picklist_lines_tenant_order_idx`, `status='planned'`, `(bin_id, sku_id)` in the recall's on-hand bins.
- **On hand** is queried with `warehouse_id = any(<tenant's warehouses>) AND sku_id = any($) AND batch_id = any($)` on `batch_on_hand_tenant_warehouse_sku_idx` (`0010:36`). **`batch_on_hand_tenant_batch_idx` is dropped.**
- **EXPLAINs.** The candidates, open-orders, held-picks and on-hand statements are each pinned by an `EXPLAIN` of the **real** statement.
  - If the on-hand EXPLAIN shows a sequential scan at the seeded volume, re-add the index and record why.

**A9 — Normalised lot-code candidates (B16, K15).**

- **The match.** Candidates match `upper(regexp_replace("code", '[^A-Za-z0-9]', '', 'g'))` against the same expression of the input.
  - It is one SQL constant, `LOT_CODE_NORM_SQL`, used by both the index and the query.
  - It is served by the expression index `batches_tenant_code_norm_idx` on `("tenant_id", (upper(regexp_replace("code", '[^A-Za-z0-9]', '', 'g'))))`.
  - It replaces the plain `batches_tenant_code_idx`.
- **Each row** carries `match: 'exact' | 'normalised'`.
- **The web.** It pre-ticks exact matches only, and labels normalised ones "similar code — check the label".

**A12 — Column sources (K7/K17/K18/B10/B11).**

- **Vendor.** GRN → PO `vendor_snapshot` (legal name, else name). It is null for an ASN receipt (`advance_shipment_notices` has no vendor column on main) and for a blind receipt.
- **`channel_order_ref`.** `external_event_id` only when `source = 'ingested'` (5-3a's case).
- **`expiry_date`.** The registers' `date()` column (an IST date).
- **One dispatch per order** (verified, `dispatch.command.ts:244-260 [m]`, "an order dispatches once"; one labelled shipment per order). So a `dispatched` row's carrier and AWB are its order's, with no per-slice problem.
  - Rows carry `dispatched_at` (the first dispatch instant).
  - **No delivery status exists on main** (`shipments.status` is `labelled | manifested`), so none is shown (PENDING).

**A11 — Portal keys, exactly (K9, K10/B21).**

- **`GET portal/recalls`** gives `{items: [{id, code, mode, status, externalRef, openedAt, closedAt, lotCount}], nextCursor}`.
- **`GET portal/recalls/{id}`** gives:
  - `{id, code, mode, status, externalRef, reasonNote, openedAt, closedAt, closeNote}`;
  - `lots: [{batchId, batchCode, skuCode, skuName, uom, expiryDate, figures, closeFigures | null}]`;
  - `onHandByWarehouse: [{warehouseCode, role, batchCode, quantity}]`;
  - `heldOrders: [{orderLabel, clientOrderRef, batchCode, quantity}]`.
- **Never shown:** an opener or closer identity, a bin, or another client's row.
- **The report** carries the client's own `held_in_open_order` and `dispatched` rows, and vendor names (they supplied this client's goods).
- **Timing.** A recall is visible on the portal the moment it commits.
- **A suspended or departed client.** The portal guard answers 401, or 403 `client-suspended`, before any header. Its recalls and reports remain **staff-only** after that.
- **The FE.** The fetcher is `fetchApiPortalRecallReport(tenantId, recallId, format): Promise<Blob>` (`parseAs: 'blob'`, the `fetchApiBinLabels` pattern, `lib/api/client.ts:933 [m]`). `src/lib/portal-boundary.test.ts` covers the new page.

**A10 — The report (supersedes decision 8's caps and slots, K8/B2/B18/B20).**

- **Slots.** Recall reports have their own process-wide slot pools, both plain fields on `ReportingFacade` so tests can override them:
  - staff: `recallReportSlots = new RegisterSlots(1)`;
  - portal: `portalRecallReportSlots = new RegisterSlots(1)`.

  They are separate from the 5-3a register slots. A full pool is 503 `report-unavailable`, with `Retry-After: 5`.
- **CSV streams with no row cap.**
  - One `REPEATABLE READ, READ ONLY` transaction.
  - Internal keyset paging of 1,000 rows (per batch, `(batchOrdinal, seq, warehouseId)`).
  - A **60 s** whole-read deadline (`recallReportDeadlineMs`, overridable), with no `Content-Length`.
  - Every refusal that can be known first comes before the first byte: 400, 401/403, 404, 503.
  - A failure after the first byte destroys the socket. The file then lacks its final `section=end` row, which carries the row count, so a truncated file can be recognised. This is a **named exception to §6**, written into IMPLEMENTATION-GUIDE §6.
- **XLSX** is built whole, capped at **200,000** rows; beyond that it is 422 `report-too-large`: "download the CSV".
- **Meta.**
  - CSV: leading `section=meta` rows using `meta_field` and `meta_value`: recall code, mode, external ref, client, reason note, `opened_ist`, `closed_ist`, `generated_ist`, `as_of_ist`, and the consignee-contacts note (B20).
  - XLSX: a "Recall" sheet with the same fields, through a new `buildXlsxWorkbook(sheets[])`. `buildXlsx`'s bytes are unchanged, pinned by the registers suite.
- **Figure rows.** `figure_live` rows per batch × figure (`location` = the figure name), and for a closed recall also `figure_at_close`, both labelled.
- **Final columns:** section, client_code, sku_code, sku_name, uom, batch_code, expiry_date, warehouse_code, location, event_ist, during_recall, client_order_ref, channel_order_ref, consignee_legal_name, consignee_gstin, destination_city, destination_state, destination_pincode, carrier, awb, vendor_name, reason, quantity, meta_field, meta_value.
- **Sections:** meta, figure_live, figure_at_close, on_hand, in_transit, held_in_open_order, planned_pick_in_recalled_bin (staff only), dispatched, received, received_damaged, adjusted_out, end.
- **Every download is audited.**
  - The controller calls `RecallsFacade.recordReportDownload(t, recallId, actor, surface, format, rowCount)` in its **own** transaction, after the file is built (XLSX) or before the first byte (CSV, where `rowCount` is null and the `end` row carries the count), and before any header.
  - It writes `batch_recall.report_downloaded`.
  - The audit row carries `reference` = a fresh uuidv7 (an unkeyed read, outside the key rule); it is listed in the audit guard's read-audit allowance.
  - An audit write failure is a 500 before any byte.
- **Reporting still writes nothing.**

**A13 — Picks in a bin holding a recalled lot (B3/B23; partly applied, see the triage log).**

- **The refusal.** `recordPick` (`pick.command.ts:355 [m]`) refuses **409 `recalled-lot-in-bin`** when the SKU is batch-tracked and the scanned bin holds `batch_on_hand > 0` of a batch on an open live recall. The detail names the batch and recall codes.
- **Where it runs.** Behind the replay, after the bin-row lock: key-share the bin's batch rows for that SKU, ordered by id, then check through the seam.
- **Never re-derived.** The pick is not re-derived onto another lot in that bin. A recalled lot and a good lot mixed in one bin cannot be told apart by an unscanned draw.
- **The remedy.** Move the recalled units out (a move of a blocked batch is allowed, 3-3a A11), then pick.
- **Mobile.** `src/state/replay-classification.ts` gains `code 'recalled-lot-in-bin' → quarantined, BY NAME` (the review queue). It is added to the fate table in `docs/design/mobile/SYSTEM-DESIGN.md`. A live device pick is the same queued op.
- **The detail lists** planned pick tasks in recalled bins (A8).
- **Not applied:** "unless the request names an explicitly scanned, active batch". The pick payload has no batch field (`RecordPickCommand`, `pick.command.ts:81-130 [m]`). This is deferred as **3-7f**.

**A16 — Wind-down, mock recalls, retention (K13/B17).**

- **Wind-down.** An open live recall is a client wind-down blocker.
  - New kind `open-recalls` in `WIND_DOWN_BLOCKER_KINDS` (`shared/primitives/wind-down.ts:14 [m]`, between `open-rmas` and `pending-adjustments`).
  - `recalls/client-wind-down.ts` is added to `clients.command.ts:60-66 [m]`.
  - The FE label goes in `lib/clients.ts:538 [m]` (a `Record` over the kinds).
  - Every consumer of the kind list must be read before widening it (§7g).
- **Mock recalls.** `mode: 'live' | 'mock'` on open (default `live`).
  - A **mock** blocks nothing.
  - It affects no pick, dispatch, unblock or wind-down: the seam returns live lines only.
  - Two mocks may name the same batch.
  - Its trace and report are identical, labelled MOCK in the meta and the UI.
- **Time to report.** `first_report_at` is set by the first download (any mode), and `timeToReportSeconds` is shown on the detail.
- **Retention.** Wind-down deletes nothing but a removed client contact (`clients.command.ts:996 [m]`), and departure keeps every document. Recall rows are never purged; the documents say so.

**A17 — Where the trace stops (B8).**

- No kit assembly, repack or relabel exists that consumes one lot into another: kits hold no stock (catalog 11.4).
- Every `adjusted_out` row (and every `received_damaged` row) carries `reason`. That is the adjustment reason code, plus "trace stops here — the units left stock by adjustment".
- Genealogy is deferred as **3-7e**.

**A19 — Channel exposure (B13).** Main has no way to trigger an immediate channel publish. `channels.facade.ts` exposes only connection reads and manage. Channels therefore keep advertising a recalled lot until the next `CHANNELS_SYNC_POLL_MS` tick (`.env.example:82`, 60 s). Recorded in PENDING channels.

---

### Migration and the rest

**A20 — The migration, revised (K15/B15).** It replaces the migration task.

- **`batch_recalls`:**
  - `id` uuid PK; `tenant_id` and `client_id` uuid NOT NULL;
  - `code` text NOT NULL, CHECK `"code" ~ '^RCL-[0-9]{6,9}$'`, UNIQUE `("tenant_id","code")`;
  - `status` text NOT NULL default `'open'`, CHECK `IN ('open','closed')`;
  - `reason_note` text NOT NULL, CHECK `char_length(btrim("reason_note")) BETWEEN 1 AND 500`;
  - `external_ref` text NULL, CHECK `"external_ref" IS NULL OR char_length(btrim("external_ref")) BETWEEN 1 AND 100`;
  - `opened_at` timestamptz NOT NULL; `opened_by` uuid NOT NULL;
  - `closed_at`, `closed_by`, `close_note`, `close_summary` jsonb, `released_batch_ids` uuid[], all NULL;
  - CHECK `batch_recalls_closed_pairing`: `("status" = 'closed') = ("closed_at" IS NOT NULL AND "closed_by" IS NOT NULL AND "close_note" IS NOT NULL AND "close_summary" IS NOT NULL)` AND (`"released_batch_ids" IS NULL OR "status" = 'closed'`);
  - timestamps;
  - indexes `("tenant_id","created_at","id")`, `("tenant_id","client_id","created_at","id")` and `("tenant_id","external_ref")` (A21's filter);
  - RLS `batch_recalls_tenant_isolation`, the 0041 client shape on `client_id`;
  - and also:
  - `mode` text NOT NULL default `'live'`, CHECK `IN ('live','mock')`;
  - `first_report_at` timestamptz NULL;
  - `released_batch_ids` stays.
- **`batch_recall_lines`:**
  - `id`, `tenant_id`, `recall_id`, `batch_id` and `sku_id` (uuid NOT NULL); `batch_code` text NOT NULL; `blocked_by_recall` boolean NOT NULL; timestamps;
  - UNIQUE `("tenant_id","recall_id","batch_id")`; index `("tenant_id","batch_id")` (the seam's lookup);
  - tenant-only RLS (§3 shape), reached by the portal only by joining to `batch_recalls`.
- No backfill; no enum.
- **The new index**, with every identifier quoted, written as plain SQL:

  ```sql
  CREATE INDEX IF NOT EXISTS "orders_tenant_client_open_idx" ON "orders" ("tenant_id","client_id","warehouse_id") WHERE "status" IN ('accepted','ready_to_dispatch')
  ```

  and `CREATE INDEX IF NOT EXISTS "batches_tenant_code_norm_idx" …` (A9).
- **The deploy guard.** It refuses a pending index build only on a **large** table, unless that index was pre-built `CONCURRENTLY` and is valid (DEPLOY.md §5). The release note carries both `CREATE INDEX CONCURRENTLY IF NOT EXISTS` statements.
- **Rollback** (outside a transaction): `DROP INDEX CONCURRENTLY IF EXISTS` each.
- **Probes.**
  - CHECK probes, each one refused and one accepted insert rolled back by a sentinel, with no word INDEX inside a DO block: code shape, status, `mode`, the closed pairing both ways, a blank note, a 101-code-point ref; RLS enabled on both tables (`pg_class.relrowsecurity`).
  - Each new index is proved **outside any DO block** by a plain statement that raises when it is missing or invalid:

    ```sql
    SELECT 1 / count(*) FROM pg_index i JOIN pg_class c ON c.oid = i.indexrelid WHERE c.relname = '<name>' AND i.indisvalid
    ```

    It divides by zero when absent.

**A21 — Smaller decisions.**

- **Key storage.** No refusal stores a key. Every 4xx and the 503 roll back.
- **Expired or other-status lots.** An expired active lot is recallable and gets blocked. A lot already blocked keeps its reason (decision 4).
- **One vendor lot across several clients** is N recalls, one per client, linked by the same `external_ref`. The staff list filters on `externalRef`.
- **The FE gate.** `qc.manage` through `roleHasCapability`.

**A22 — Naming and PENDING wording (K20/K21).**

- "4-2b's unpack" throughout means **the packed-order cancel/unpack deferred from 4.2**. The key `4-2b` collides with the done `spec-4-2b-outbound-orders-surface.md`.
- A PENDING note records that 4-2a's deferred keys (4-2b, 4-2c) need renaming.
- 3-3a's A12 entries are closed **if present** in PENDING when the docs land, and otherwise are not added.

**A23 — Tests and acceptance (B19/B24)** are below.

---

**Amended Boundaries.**

- **Always:**
  - every recall read goes through facades or the seam file;
  - mock recalls have no stock-side or order-side effect;
  - the CSV stream's only post-header failure mode is a truncated file without its `end` row.
- **Never:**
  - a dispatch refusal for a non-recall block;
  - a pick re-derived away from a recalled lot in the same bin;
  - a recall row deleted;
  - a client seeing an actor's identity.

**Amended matrix rows.**

| Scenario | Input / State | Expected | Error |
|---|---|---|---|
| Other block | A lot blocked `expiry-review` (no recall), packed order | Dispatches | — |
| Held order (amends) | Order packed with the lot, recall opens | Listed; dispatch refused | 409 `order-holds-recalled-batch` (`recallCodes`) |
| Mixed bin | Bin A-01 holds recalled L and good M of the same SKU; pick at A-01 | — | 409 `recalled-lot-in-bin`; a device op is quarantined to review |
| Release with stock | `releaseBatchIds:[L]` where L has 4 on hand | — | 409 `recall-release-has-stock`; with `overrideReason` → released, reason audited |
| Unaccounted | Projection diverged for L | Close without the flag refused | 409 `recall-unaccounted` |
| In transit | L moved WH1 → WH2, not confirmed | `inTransit` = qty; `in_transit` row; confirm at WH2 keeps L blocked | — |
| Normalised code | Input `ab-12/3`; batches `AB123`, `ab-12/3` | Both returned; `normalised` and `exact` | — |
| Big CSV | 120,000 trace rows | A complete CSV ending in an `end` row with the count | XLSX: 422 `report-too-large` |
| Mock | Mock recall on L | L stays active; picks and dispatch unaffected; report labelled MOCK | — |
| Contended | Open waits on a held batch row longer than 5 s | — | 503 `recall-open-contended`, no key |
| Receive into recalled | GRN line of L | Booked; L stays blocked; `recalledLots` in the response | — |

## Code Map

**Base.** wms-be main plus the `feat/3-3a-batch-block` stack (0089–0092). `[3a]` = the branch, `[m]` = main, where the file is the same.

**Facts relied on**

- **Batches and ledger indexes**
  - `schema.ts:1169-1196 [3a]` `batches`: unique `(tenant, sku, code)`, no client column. `BATCH_BLOCK_REASONS` is at `:1145`.
  - `drizzle/0010:36` `batch_on_hand_tenant_warehouse_sku_idx`.
  - `0010:42` `ledger_events_tenant_batch_ref_seq_idx`, which serves every per-batch ledger read.
  - `0039` is the `orderId` partial index.
- **Pick**
  - `pick.command.ts [3a]`: the batch+serial refusal at `:797`; the referenceDoc at `:988`; `batchRef: arm.batchId` at `:1046`.
  - `picks.batch_id` is null on a multi-batch draw (`:1298`).
  - `deriveBatchArms` at `:1528`, which skips non-active or expired lots at `:1555-1557`.
  - The lock points: bin `:746`, serials `:859`, warehouse `:877`.
  - `RecordPickCommand` at `:81 [m]` has no batch field.
- **Dispatch**
  - `dispatch.command.ts [m]`: `dispatchOrder` at `:174`, status guards at `:244-267`, flip at `:301`, `batchRef: null` at `:384`.
  - The only caller is `outbound.controller.ts:276-286` → `outbound.facade.ts:1150`.
- **Inventory facade** (`inventory.facade.ts [3a]`): `ledgerEventsByOrderRefInTx` at `:1487`, `firstDispatchByOrderInTx` at `:1711`, `batchBinsOnHand` at `:2031`, `batchHistory` at `:2115`. The join precedent is `inventory/registers.ts:84-107`.
- **Catalog, 3-3a** (`batch-block.command.ts [3a]`): `batchLifecycleViewsInTx` at `:75`, `block` at `:148`, `unblock` at `:226`, the `batch-not-blocked` guard at `:251`, `lockBatch` at `:301`. `catalog.facade.ts:1083 [3a]` is `ensureBatchesInTx`.
- **Clients and wind-down**
  - `clients.facade.ts [3a]`: `assertSingleClientInTx` at `:651`, `getClientLabelsInTx` at `:598`.
  - `ORDER_OPEN_STATUSES` is at `outbound/client-wind-down.ts:15`.
  - `WIND_DOWN_BLOCKER_KINDS` is at `shared/primitives/wind-down.ts:14`.
  - The blocker imports are at `clients.command.ts:60-66`.
- **Reporting and export**
  - `reporting.facade.ts:156,260` (`RegisterSlots`).
  - `reporting/registers.ts:38-42`.
  - `shared/export/csv.ts` `csvTypedCell` / `buildCsv`, and `xlsx.ts:42` `buildXlsx`.
  - The binary route is at `reporting.controller.ts:241-249`.
- **Other**
  - RLS shape: `drizzle/0041:80-95`.
  - The code-sequence pattern: `receiving.command.ts:3151-3163`.
  - `PORTAL_READS`: `test/architecture.spec.ts:2295 [3a]`.
  - No ASN vendor column: `schema.ts:2680 [m]`.
  - `shipments.status` is `labelled | manifested` (`schema.ts:3634 [m]`).

**New (BE)**

- **The recalls module**
  - `src/modules/recalls/{recall.command.ts, recalls.facade.ts, recalls.module.ts, recall.dto.ts, open-recall-lines.ts, client-wind-down.ts, close-summary.ts}`.
  - `src/api/recalls.controller.ts`, with the literal `candidates` route before `:recallId`.
  - The portal routes in `api/portal.controller.ts`.
- **Catalog:** `catalog/batch-block.ts` (the helpers); facade `blockBatchInTx`, `unblockBatchInTx`, `keyShareLockBatchesInTx`, `batchesByNormalisedCodeInTx`.
- **Inventory:** `inventory/recall-trace.ts`, with every statement re-arming the deadline:
  - `batchOnHandForRecallInTx`, `batchLedgerFiguresInTx` (incl. the fold and `adjustedOutByReason`);
  - `batchTraceEventsPageInTx(kind)`;
  - `ledgerPickEventsByOrderRefsInTx`, `pickedBatchRefsOfOrderInTx`.
- **Outbound:** `openOrderIdsOfClientInTx` (the partial index), `orderTraceFactsByIdsInTx`, `plannedTasksInBinsInTx`; plus the dispatch and pick guards.
- **Inbound:** `grnTraceFactsByIdsInTx`; `recalledLots` on the GRN submit; `recallCode` on the GRN lines read.
- **Reporting:** `reporting/recall-trace.ts`, which composes everything and streams the CSV. `ReportingFacade.recallCandidates`, `recallDetail`, `recallTrace`, `recallReport`, `portalRecalls`, `portalRecall`, `portalRecallReport`.
- **Shared:** `shared/export/xlsx.ts` `buildXlsxWorkbook`; `shared/primitives/wind-down.ts`; `audit.ts` (target `batch_recall`; actions `opened`, `batches_added`, `closed`, `report_downloaded`).

**FE (`wms-fe`, on the 3-3a FE branch)**

- `lib/page-tabs.ts:140` (`recalls`); `components/inventory/recalls/*`.
- The 3-3a `batch-block-dialog.tsx` and `lib/batch-block.ts` (A4).
- `lib/outbound-pack-dispatch.ts:434`; `lib/clients.ts:538`; `lib/audit.ts`.
- `lib/portal.ts:125-130`; `app/(portal)/portal/recalls/page.tsx`; `components/portal/portal-recalls.tsx`.
- The blob fetchers in `lib/api/client.ts`; the GRN line badge.

**Mobile (`wms-mobile`)**

- `src/state/replay-classification.ts` (`recalled-lot-in-bin`).
- The GRN settled note for `recalledLots`.

## Tasks & Acceptance

**Execution:**

- [ ] **Migration** (A20, next free number at code time, at least 0094, after 0092):
  - the tables, CHECKs and RLS of A20;
  - `mode` and `first_report_at`;
  - the two indexes;
  - the CHECK probes and the `indisvalid` probes;
  - the journal entry and snapshot; `db:generate` reports "No schema changes".
- [ ] **Catalog**:
  - the extracted helpers (3-3a golden byte-identical);
  - `recallCode` on the lifecycle view;
  - `batch-under-recall` in `unblock` only;
  - the normalised candidates read;
  - `keyShareLockBatchesInTx`.
- [ ] **Recalls module**:
  - `open` `{batchIds[1..50], reasonNote, externalRef?, mode?}`:
    - hash `{command:'recall.open', tenantId, batchIds: sorted, reasonNote, externalRef ?? null, mode}`;
    - shape checks above the transaction (A18);
    - inside: `lock_timeout` → `qc.manage` → replay → batches `FOR UPDATE`, ordered by id (404 names the missing ids) → replay again → SKUs + `assertSingleClientInTx` (409 `mixed-client`) → live only: an open live line gives 409 `batch-already-recalled` → `pg_advisory_xact_lock(hashtextextended(tenant || ':recall-seq', 0))` + next `RCL-` → header and lines → live only: `CatalogFacade.blockBatchInTx` for each active batch (reason `recall`) → outbox `batch_recall.opened` → audit → key;
  - `addBatches` and `close` per A14 and A5/A6, with recall row → batches lock order (A15);
  - the close-summary builder plus golden;
  - the seam file;
  - the wind-down blocker;
  - `recordReportDownload`;
  - the architecture block.
- [ ] **Outbound**:
  - the dispatch guard (A2/A3);
  - the pick guard (A13);
  - the trace reads.
- [ ] **Inventory and inbound**: the reads; `recalledLots`; `recallCode` on GRN lines.
- [ ] **Reporting**:
  - composition;
  - the pools, deadlines and their test fields;
  - CSV streaming with the `end` row;
  - XLSX workbook plus cap;
  - the portal reads in `PORTAL_READS` and the declared list.
- [ ] **Tests** (`test/recalls.spec.ts` plus existing suites):
  - every matrix row (base and amended);
  - the two dispatch race orderings;
  - pick-holds-key-share vs open (and the 503);
  - same-key parked-waiter races for open, addBatches and close;
  - **B19**: in one REPEATABLE READ snapshot, for every batch, each figure equals its section sum. This includes a multi-batch pick with a null `picks.batch_id`.
  - the all-16-types `unaccounted = 0` fixture;
  - the `PICK_NETTING_TYPES` architecture pin;
  - EXPLAINs (A8, A9);
  - the RLS probes plus the stamped portal probe;
  - CSV and XLSX parse-back with meta; a 120k-row CSV;
  - the slot and deadline overrides (`recallReportSlots`, `portalRecallReportSlots`, `recallReportDeadlineMs`);
  - the download audit;
  - the OpenAPI paths;
  - the `buildXlsx` byte-golden.
- [ ] **FE**: A4, A9, A11, A14, A16 and decision 11; boundary test; regenerate.
- [ ] **Mobile**: the fate entry plus test; the settled note.
- [ ] **Meta (after code)**:
  - modules: `recalls.md` (new), catalog, outbound (both guards), inventory, inbound, reporting;
  - IMPLEMENTATION-GUIDE §1 lock order (A15) and the §6 streaming exception (A10);
  - API-SURFACE; mobile fate table; FE design; contracts;
  - PENDING: A2's stuck order and the exemption rule, A6's RTV and return-to-client arms, A12 delivery status, A19 channel poll exposure, A22 key renaming, and 3-3a A12 closures if present.

**Acceptance Criteria:**

- Given lot L (ACME) in WH1 and WH2, when a read in a new transaction runs before the open commits, then ATP includes L. After the commit it excludes L in both warehouses, and the detail lists L by warehouse and role.
- Given an order that dispatched 2 of L and a GRN-12 receipt of 5, when staff and ACME's portal user download the report, then:
  - their meta, figure, on_hand, in_transit, held_in_open_order, dispatched, received, received_damaged and adjusted_out rows are identical;
  - only staff has `planned_pick_in_recalled_bin`;
  - BETA gets 404.
- Given B1's eligible and ineligible ids, then only eligible, stock-free (or overridden) batches are released, each with its own `batch.unblocked` audit.
- Given a recall-held order (B3/B5), then its held quantity is net per (line, batch). A pick in a mixed bin refuses, and the device op lands in review.
- Given A7's fixture, then `unaccounted = 0` and every figure matches its rows (B6/B7).

## Design Notes

**Why the ledger, not `picks`.** `picks.batch_id` is null on a multi-batch draw, and dispatch events carry no batch. So `pick.picked` events are the per-batch record. Held quantities start from the client's open orders, which is a small partial index, not the lot's whole pick history.

**Why recall-only at dispatch.** 3-3a's other block reasons are lot-quality holds, and their dispatch behaviour stays as it was. A recall is the case where shipping is the harm. Key-share locks on every picked batch make "the block or the dispatch, whichever commits first" well defined.

**Why refuse a mixed bin.** FEFO re-derivation is a ledger fiction. The operator physically grabs units, and a recalled lot beside a good one cannot be told apart without a lot scan, which the payload does not carry (3-7f).

**Why stream the CSV.** A recall report is evidence. Capping it, or splitting it per warehouse, would push the brand into joining files. The `end` row makes truncation detectable, which is the price of streaming.

## Verification

**Commands:**

- `cd workspace/core/backend/wms-be && bun run lint && bun run typecheck && bun run test && bun run db:generate` — expected: green; "No schema changes"; `git status --short` clean. Run one jest at a time.
- `cd workspace/core/frontend/wms-fe && bun run api:generate && bun run test && bun run lint && bun run typecheck && bun run build` — expected: green.
- `cd workspace/core/mobile/wms-mobile && bun run test && bun run typecheck` — expected: green.

## Implementation Notes

## Spec Change Log

## Review Triage Log

Design review, 2026-10-23. **K** is the claims check against origin/main and `feat/3-3a-batch-block`; **B** is the blind review. All choices are recommended and taken autonomously. Accepted findings fold into A1–A23 above.

| ID | Src | Verdict | Finding → resolution |
|---|---|---|---|
| K1 | K | high | `FOR SHARE` on only the blocked batches misses a concurrent block. → A3 (all picked ids, `FOR KEY SHARE`) |
| K2 | K | high | A recall in catalog would need catalog to import outbound and inventory, creating a cycle. → A1 (recalls module plus seam) |
| K3 | K | high | Refusing dispatch on any block reason changes 3-3a's behaviour. → A2 (open live recall only) |
| K4 | K | medium | New 409s had no OpenAPI, API-SURFACE or FE handling. → A4, A2 |
| K5 | K | medium | An under-recall check in the shared helper would stop close from releasing. → A4 |
| K6 | K | medium | `grn.damaged` units were absent from the figures and rows. → A7, A10 |
| K7 | K | low | The vendor source was unstated; ASNs have no vendor. → A12 |
| K8 | K | medium | A 50k cap and shared register slots are wrong for a recall report. → A10 |
| K9 | K | medium | The portal blob fetcher, the guard's pre-header refusals and the suspended client were unspecified. → A11 |
| K10 | K | medium | Portal keys were not enumerated; AC2's "identical" claim was imprecise. → A11, AC2 |
| K11 | K | low | Note and ref rules sat behind the transaction; the close hash did not normalise. → A18 |
| K12 | K | high | Held orders came from walking every pick of the lot, which is unbounded. → A8 |
| K13 | K | medium | An open recall did not block client wind-down. → A16 |
| K14 | K | low | 3-3a's standalone `recall` reason overlaps the recall. → A4 (kept, with a nudge) |
| K15 | K | medium | The `batch_on_hand` index was unneeded; identifiers unquoted; the guard sentence imprecise. → A8, A20 |
| K16 | K | low | `ledgerEventsByOrderRefInTx` already exists. → A8 (its predicate reused as a set sibling; the per-order call is O(orders)) |
| K17 | K | low | The channel ref must use the `source='ingested'` case. → A12 |
| K18 | K | low | Expiry should use the registers' `date()` cell. → A12 |
| K19 | K | high | The lock helper name and the status filter were wrong. → A3 |
| K20 | K | low | Line numbers drifted on the 3-3a branch; the `4-2b` key collides. → A22, Code Map |
| K21 | K | low | PENDING closures must not add entries. → A22 |
| K22 | K | low | Truncation was in code units; close audit multiplicity. → A18 |
| B1 | B | high | The boolean release ignored remaining stock. → A5 |
| B2 | B | medium | Report caps and slots. → A10 |
| B3 | B | high | FEFO re-derivation in a mixed bin can ship recalled units. → A13 (explicit-batch override not applied: no payload field → 3-7f) |
| B4 | B | medium | A stuck order had no stated remedy or side effects. → A2 |
| B5 | B | medium | Held and dispatched quantities must be net. → A7 (no reversing type on the base; pinned list) |
| B6 | B | medium | No unaccounted figure. → A6, A7 |
| B7 | B | medium | In-transit stock was not separated. → A7, A10 |
| B8 | B | low | The trace stops at consumption without saying so. → A17; deferred 3-7e |
| B9 | B | medium | A later receipt into a recalled lot, and new matching batches. → A14 |
| B10 | B | low | Per-slice AWB? → A12 (verified: one dispatch per order) |
| B11 | B | low | Delivery status. → A12 (none on main; PENDING) |
| B12 | B | medium | Lock waits and lock order. → A15 |
| B13 | B | low | Channel lag after open. → A19 (no trigger on main; PENDING) |
| B14 | B | medium | The per-dispatch picked-batch lookup (`reference_doc ? 'orderId'`) had no proven index. → resolved by K16/A8: the dispatch guard reads the order's pick events through the existing `ledgerEventsByOrderRefInTx` predicate (the 0039 order-ref qual), pinned by an EXPLAIN in the test list; no new index (recommended, taken autonomously at triage). |
| B15 | B | low | Index validity proof and rollback. → A20 |
| B16 | B | medium | Lot-code formatting variants. → A9 |
| B17 | B | low | Mock recalls; retention. → A16 |
| B18 | B | low | The report lacked meta and the close figures. → A10 |
| B19 | B | medium | Figures vs rows consistency. → A23 test |
| B20 | B | medium | The contacts gap was not stated; downloads not audited. → A10; 3-7b marked go-live-blocking for pharma and food |
| B21 | B | medium | What the client sees. → A11 |
| B22 | B | medium | Disposition detail at close. → A6 |
| B23 | B | medium | A device replay of a refused pick. → A13 (quarantined by name) |
| B24 | B | low | AC1 precision; test hooks; missing ACs. → A3, A10, ACs |
