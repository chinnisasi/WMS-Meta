---
title: '2-6a serial/IMEI capture at receipt — one serial per unit on the handheld receive, booked per unit into Receiving, carried through over-receipt approval and handheld putaway'
type: 'feature'
created: '2026-10-23'
status: 'ready-for-dev'
route: 'dispatch'
review_loop_iteration: 0
context:
  - '_bmad-output/implementation-artifacts/epic-2-context.md'
  - 'docs/initiatives/production-readiness.md'
  - 'docs/design/SYSTEM-DESIGN.md'
  - 'docs/design/IMPLEMENTATION-GUIDE.md'
  - 'docs/design/modules/inbound.md'
  - 'docs/design/modules/inventory.md'
  - 'docs/design/modules/catalog.md'
  - 'docs/design/modules/putaway.md'
  - 'docs/design/frontend/SYSTEM-DESIGN.md'
  - 'docs/design/frontend/IMPLEMENTATION-GUIDE.md'
  - 'docs/design/mobile/SYSTEM-DESIGN.md'
  - 'docs/design/mobile/IMPLEMENTATION-GUIDE.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** A serial-tracked SKU (phones, laptops, appliances) is received today as anonymous units. `grn.submit` books it with `serialRef: null` (`receiving.command.ts:1706`; `grn.received` has `allowsSerialArm: false`, `ledger-registry.ts:336-350`) and the handheld never asks for a serial (`wms-mobile src/api.ts:650-651`). Putaway, pick and moves all require located serials. Handheld putaway also refuses serial-tracked SKUs (`src/putaway/draft.ts:125-128`). So every serial-tracked receipt is stranded in the Receiving bin, and no serial or IMEI is ever recorded against the goods that arrived.

**Approach:**
- The handheld receive flow captures one serial per good unit of a serial-tracked line, offline. The line's quantity is the number of serials.
- `grn.submit` carries them as `lines[].serials`, hashed only when non-empty.
- The server validates the serials, ensures their catalog identity, refuses per line any serial already in stock, and appends one `grn.received` per booked unit with `serialRef`.
- The serials are stored on the GRN line in capture order. An over-receipt's units book their serials at approval.
- The web GRN lines show the serials. The handheld putaway places serial-tracked tasks by scanning those serials.
- IMEI is a per-SKU serial format.

**Decisions (recommended, taken autonomously):**
1. **Scope.**
   - In scope: capture on the handheld receive flow for PO, ASN and blind receipts; booking per unit; over-receipt approval per unit; the web GRN lines; the web SKU forms; handheld putaway of serial-tracked tasks.
   - Why putaway is in: without it the captured units cannot leave Receiving. The server's placement already takes serials (`putaway.command.ts:471-502`).
   - Desk receiving does not exist yet: `grn.submit` is `DeviceSessionGuard`-only (`receiving.controller.ts:82-84`) and no web code calls it. Roadmap 2.7 must send the same `serials` field.
2. **IMEI is a serial format, not a second identifier.**
   - `skus.serial_format` is `free` (default) or `imei`.
   - `imei` means exactly 15 ASCII digits whose last digit is the Luhn check digit of the first 14. The server and the device run the same pure check.
   - One identifier per unit, IMEI 1. A dual-SIM phone's second IMEI is deferred.
   - The device strips spaces and hyphens from a typed or scanned value on an `imei` SKU only. The server never normalises beyond trimming.
   - The format is consulted only while the SKU is serial-tracked. Changing it affects new captures only.
3. **Duplicate scope is the serial identity `(tenant, SKU, number)`.**
   - The scope is tenant-wide and across warehouses. Because a SKU has one client, this is client-wide by construction.
   - A serial is "in stock" when its latest ledger event is an intake, in any bin of any warehouse. This is the ledger guard's own definition (`ledger.service.ts:502-537`).
   - A serial whose latest event is a draw (dispatched, written off) may be received again.
   - The same number on two different SKUs is two different units.
   - Where each duplicate is caught:
     - inside one request: a 400;
     - against stock on hand: a per-line refusal;
     - on the device: against the draft and the device's own queued `grn.submit` ops.
4. **Per-line refusals.** These four codes join `REJECTED_GRN_LINE_CODES`. Each refuses the line whole (2-4a decision 6) into the `grn.lines-refused` review row, which offers Discard only. Each is per-line rather than a whole-op 400 because a flag or format change while an op is queued must not drop the other lines (§7g, the 1-2b expiry precedent).
   - `serials-required`: a serial-tracked line with no serials. Old builds and queued pre-2-6a ops no longer book anonymous serial-tracked units.
   - `serials-on-untracked`: serials on a SKU that is not serial-tracked.
   - `serial-format-invalid`: an `imei` SKU with a serial that fails the check.
   - `serial-in-stock`: a serial currently on hand.
5. **The excess carries its serials.**
   - Serials are in capture order. The first `appliedQty / 1000` book at submit. The rest stay on the GRN line and book, in order, when the over-receipt is approved.
   - Approve pre-checks them under the serial locks. One already in stock is a 409 `serial-in-stock` naming the serial number and the bin code, and the reviewer rejects the excess.
   - A pre-2-6a line (`serial_ids` null) approves anonymously, exactly as today.
6. **Shape and caps.**
   - Each serial is trimmed, then must be 1–64 characters of printable ASCII with no whitespace (`^[\x21-\x7E]{1,64}$`). 64 is putaway's bound (`putaway.dto.ts:78-81`).
   - Serials are case-sensitive, and none may repeat inside the request for the same SKU.
   - At most 500 serials per line and 1,000 per receipt. 1,000 is the adjustment's bound.
   - `serials.length` must equal the line's good `qty`.
   - All of these are 400s above the transaction. The device never produces them.
7. **Unchanged.**
   - Damage on a serial-tracked line stays refused (2-4a decision 9; `grn.damaged` keeps its serial arm closed).
   - QC on receipt still books serial lines unheld (`qcSkippedLines`).
   - The portal is unchanged; roadmap 2.9 owns GRNs in the portal.
   - Serial `status` is not consulted, as on every other intake path.
8. **The receive draft stays in memory**, as every receive draft is today. Persisting a long capture against an app kill is deferred.
9. **Putaway.**
   - The snapshot's `putawayTasks[]` gains `serialNumbers`, present only on a serial-tracked task: that GRN line's serials that are in the Receiving bin now, in capture order.
   - The device verifies each scan against that list offline, and places at most 200 serials per placement (the placement DTO's cap).
   - A task without the field (a legacy line, or an older server) keeps today's refusal.
10. **Rollout.** The backend merges first (cross-repo rule). From then on, an older handheld build's serial-tracked lines are refused per line `serials-required`. They go to review, and the goods are received again with the new build. This is stated, not mitigated.

## Boundaries & Constraints

**Always:**
- **Additive hashing.**
  - Each line's last keys are `...conditionHashFields(line)`, then 2-5a's `photoRefs` when it lands, then `...(serials non-empty ? { serials: [...as sent] } : {})`.
  - Every existing golden stays as it is: `test/asn.spec.ts:1155-1160`, `test/per-client-sku.spec.ts:546-588`, `test/receipt-condition.spec.ts:708-740` and `test/client-receiving-policy.spec.ts:933-947`.
  - A request with no serials, `serials: []` or `serials: null` stores the same `payload_hash` and the same `response_snapshot` as before 2-6a.
- **One ledger event per booked serial unit** (+1 unit, `serialRef` = the `serials.id`, `batchRef` = the line's batch). The serial set is locked once with `lockSerialsInTx`, sorted, before the in-stock read and before the first append.
- **Lock order** is the canonical chain:
  - the receipt: SKU, document and line row locks → the serial advisory locks → the warehouse advisory inside the append;
  - approval: the over-receipt row → SKU → document → line → serial → warehouse.
- **Catalog owns identity** (AD-6). Identities are created by a new `CatalogFacade.ensureSerialsInTx`, the in-transaction twin of `ensureSerials`. The ledger owns location.
- **Review rows round-trip the serials.** `grn.lines-refused`, `grn.shelf-life-refused` and `grn.licence-refused` carry a line's `serials` when present, so an Apply re-sends them. A row stored before 2-6a stays byte-identical.

**Never:**
- No anonymous booking of a serial-tracked line once serials exist on the wire.
- No whole-op refusal for a stale flag, format or in-stock serial.
- No serial arm on `grn.damaged`, `qc.held` or `qc.released`.
- No serial uniqueness by a catalog index on location.
- No pack-level serial verification, serial lookup by number, serial history report, ASN serial pre-announcement or desk receiving. These are deferred.
- No change to billing counts. One GRN line is one receipt line, whatever its serials.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected | Error handling |
|---|---|---|---|
| Serial line, open PO | Serial SKU, open 3; `qty 3, serials [A,B,C]` | 3 `grn.received` +1, each with its serialRef; `serial_ids` = [A,B,C] ids; snapshot line `serials [A,B,C]`; credits 3 | — |
| Excess | Open 2; `qty 3, serials [A,B,C]` | A, B book now; C stays on the line, pending; the approval books C | C in stock at approval → 409 `serial-in-stock` (number + bin code) |
| Terminal or late document | Closed PO with no successor; `qty 2, [A,B]` | Applied 0; both pend; the approval books both in order | — |
| Duplicate in stock | B's latest event is an intake into bin X (any warehouse) | The line is refused `serial-in-stock` (the entry names B and X's code); the other lines book | The line goes to `grn.lines-refused` |
| Every line refused | Each line hits a serial refusal | `{goodsReceipt: null, refusedReceipt}`; no GRN code is used | — |
| Re-receipt after dispatch | A's latest event is a pick or dispatch draw | Books normally | — |
| Missing serials | Serial SKU, no `serials` (an old build or queued op) | Refused `serials-required` | Review, Discard |
| Untracked carries serials | The flag was cleared while the op was queued | Refused `serials-on-untracked` | Review |
| IMEI | `imei` SKU, `490154203237518` / `490154203237517` | Books / refused `serial-format-invalid` | — |
| Shape | Count ≠ qty, a blank, 65 characters, whitespace, a repeat within the SKU, > 500 per line or > 1,000 per receipt | — | Whole-op 400 above the transaction (replay never reached) |
| Damage on a serial line | `damagedQty > 0` | — | 400, as today (`receiving.command.ts:872-886`) |
| Legacy approval | An excess on a line with null `serial_ids` | Anonymous `grn.received`, as today | — |
| Putaway | Serial task with `serialNumbers [A,B]`; the operator scans A, then Z | A accepted; Z refused offline: "not waiting on this receipt line" | Server `serial-elsewhere` / 400 unknown → rejected fate |
| No serials | Any receipt without serials | Hash, snapshot, ledger and lines identical to before; `serial_ids` NULL | — |

</frozen-after-approval>

## Design Review Amendments

These come from the design review of 2026-10-23: the claims check K1–K17 against origin/main and the blind review B1–B18. Each was triaged in the Review Triage Log. Where an amendment and the frozen block disagree, **the amendment wins**. Every new code claim here was re-read on origin/main (wms-be `9a246e7`).

**A1 — The controller maps `serials` (K1).**
- `receiving.controller.ts:133-160` builds each command line key by key, so a DTO field it does not name is silently dropped.
- Map `serials` and A9's `unreadableSerialQty` there, each only when non-empty or > 0. This is the `expiryDate` spread at `:141`.
- `GrnLineInput` and `NormalisedGrnLineInput` gain `serials?: readonly string[] | null` and `unreadableSerialQty?: number | null`.

**A2 — A serial's latest event is ordered by `id`, not `seq` (K4).** This is a pre-existing defect, fixed here.
- `seq` is per `(tenant, warehouse)` (`ledger.service.ts:625-639`). Four tenant-wide "latest event of a serial" reads order by it anyway:
  - `ledger.service.ts:466` (`serialLatestEventInTx`, behind `assertSerialArmLegal`);
  - `inventory.facade.ts:1510` (`serialsInStockInTx`);
  - `inventory.facade.ts:2068` (the serial-location read);
  - `inventory.facade.ts:2298` (`serialsLocatedInBinInTx`).
- After a 5-1 transfer, the destination warehouse's seq can be lower than the source's, so the source's IN-TRANSIT intake is read as the latest event.
- Fix: order by `ledger_events.id DESC`.
  - The id is minted by `uuidv7()` inside `appendMovement` (`:641`), **after** the warehouse and serial advisory locks (`:594-597`). Every append of one serial is serialised by its lock, so a later append's id carries a later or equal millisecond.
  - `ids.ts:13-21` adds a 12-bit sequence within one millisecond in one process.
  - **Not `recorded_at`:** callers stamp it before taking the lock (for example `receiving.command.ts:1344`), so a waiter's stamp can precede the holder's.
  - The residual case is two API instances appending one serial within the same millisecond as the previous commit. It goes to PENDING.
- `(tenant_id, serial_ref, seq)` still narrows the read to one serial's few rows. No index change.
- Test: transfer serial S from warehouse A to B (A's seq high, B's low), confirm the inbound, then receive S on a GRN in A. S must be refused as in stock (A6 `serial-in-stock`), never booked.
- The serial history read (`serialHistory`, `inventory.facade.ts:2022`) orders a serial's events across warehouses too, so it moves to `id` ascending.

**A3 — A child table replaces `goods_receipt_lines.serial_ids` (B13, B14, K15).** This supersedes decision 5's storage, the Boundaries' `serial_ids` wording, and the frozen migration.
- `goods_receipt_line_serials`, inbound-owned. One row per captured unit, and the capture order is `ordinal`.
- State is `applied` (booked at submit, or approved), `pending` (on an open over-receipt), `rejected` (the excess was rejected) or `unreadable` (A9).
- Columns, CHECKs, RLS and indexes are in Design Notes.
- No FKs, by repo convention (IMPLEMENTATION-GUIDE §3: "No FK constraints anywhere").
- `goods_receipt_lines` is not altered.
- `skus.serial_format`'s CHECK is added and **validated in the same migration**. That is one sequential scan of `skus` under the `ADD COLUMN`'s lock: about 0.1 s per 100k rows, and the catalog import bounds a tenant's SKUs to that order. The other probes satisfy every other constraint on the table.
- If the 5 s `MIGRATE_LOCK_TIMEOUT_MS` (`DEPLOY.md:124`) expires, the remedy is to re-run the deploy. The pending set rolls back whole.
- `test/architecture.spec.ts` pins that only `src/modules/inbound` writes the table.
- A test pins `MAX_GRN_SERIALS_PER_LINE` against the CHECK's literal `500`.

**A4 — Refusals are per serial (B2, K5, K6).** This supersedes decision 4 for the serial codes and matrix row "Duplicate in stock".
- **Line-level codes** (the whole line is refused, as frozen): `serials-required` and `serials-on-untracked`.
- **Serial-level codes**, eight in all with `serial-in-stock`:
  - `serial-format-invalid`;
  - `serial-in-stock`;
  - `serial-in-transit`;
  - `serial-pending-approval` (A5);
  - `serial-dispatched-use-returns` (A6);
  - `serial-blocked` (A6).
- A serial-level refusal removes only the offending serials. The line books the rest: its stored `qty` is the remaining count, and the PO or ASN credit and the excess split are judged on that count.
- The refused serials form one `RejectedGrnLine` entry: `{index, code, skuId, qty (refused count), serials (numbers), serialsOnly: true, reason}`. It goes to the `grn.lines-refused` row (Discard only, `sync-report.command.ts:187`). Discarding is the acknowledgement.
- A line whose every serial is refused is refused whole. If no line is left, the receipt takes the all-refused arm.
- `LineRefusalCode` (`receiving.command.ts:304`), `ClientRefusedLine` (`:313`, gaining `serials` and per-serial `binCode` / `warehouseCode` / `otherSkuCode`) and the DTO enum description (`receiving.dto.ts:389-391`) widen.
- `linesRefusedDetail` / `mixedTail` (`:3283-3306`) gain a serial branch, and its text is tested.
- **One late-refused set** holds the 1-2b raced line indexes and the in-stock serial refusals. The fold, the line write and the all-refused test all read it. Raced lines are excluded before `ensureSerialsInTx` (K6).

**A5 — Pending serials are checked and shown (B8, K17).**
- Every captured serial, whether it will apply or pend, is checked at submit.
- A serial with a `pending` row (any GRN line, tenant-wide) is refused `serial-pending-approval`. The partial unique index `goods_receipt_line_serials_pending_unique` is the backstop.
- The pending numbers are shown in three places:
  - the web over-receipt review: `listOverReceipts` (`receiving.facade.ts:548`) gains `serials?: string[]`;
  - the response line, as `pendingSerials?`;
  - the device's settled note: "Set aside N unit(s) for approval: …".
- Reject sets their rows to `rejected`. Approve sets them to `applied`.
- Approving a subset of an excess is deferred (deferred-work).

**A6 — Re-receipt is judged by the serial's latest event (B9).** It is read by the new `InventoryFacade.serialLatestEventsInTx(tx, tenantId, serialIds)` → `Map<id, {type, warehouseId, fromBinId, toBinId}>`, ordered as in A2. `serialsInStockInTx` is re-expressed over it.

| Latest event | Outcome |
|---|---|
| Any intake (`toBinId` set) | `serial-in-stock`, naming the bin and warehouse codes — except `transfer.outbound`, which is `serial-in-transit` |
| `pick.picked` (a draw; the unit left on an order — `ledger-registry.ts:420-438`) | `serial-dispatched-use-returns` ("receive it as a return") |
| `stock.adjusted` with a negative delta (written off) | Allowed. The row gets `after_write_off = true`, and one `goods_receipt.serial_re_received` audit row per receipt (target `goods_receipt`, actor the operator) is pinned by `expectAuditRow`. The web marks the serial |
| None | Allowed |

- `serials.status = 'blocked'` is refused `serial-blocked`. The status exists (`0010_sharp_hardball.sql:73`), but nothing on main sets it, so this is defensive.

**A7 — An IMEI is unique across `imei` SKUs (B7).** This amends decision 3.
- For an `imei` SKU, the in-stock and pending checks also cover the same number under **every** `imei` SKU of the tenant. One found there is refused `serial-in-stock`, naming that SKU's code.
- The read is `CatalogFacade.serialIdentitiesAcrossSkusInTx(tx, tenantId, skuIds, numbers)`. It runs over `serials_tenant_sku_serial_unique` with `sku_id = ANY(imei sku ids)`, so no new index is needed. Those identities join the sorted lock set.
- `free` serials stay exact and case-sensitive, per (tenant, SKU). The same `free` number on two clients' SKUs is two units, stated in decision 3.
- Identities stay per SKU. A cross-SKU identity rule stays deferred.

**A8 — Identities are resolved before they are ensured (B16).** The late phase, after the 1-2b race arm:
1. `serialIdentitiesInTx({numbers})` per SKU (plus A7's cross-SKU read).
2. `lockSerialsInTx(existing ids, sorted)`.
3. `serialLatestEventsInTx`, the status, and the `pending` rows → A4/A5/A6 refusals.
4. `ensureSerialsInTx`, for the settling serials only.
5. `lockSerialsInTx(newly created ids, sorted)`.
6. Re-read their latest events (a concurrent writer may have committed one). A hit refuses that serial.
- A refused line or serial creates no identity. Pinned by a test.

**A9 — An unreadable serial is recorded, not booked (B5).**
- The device's serials step has "Serial unreadable (+1)". It sends `lines[].unreadableSerialQty`: an integer from 1 to 500, hashed after `serials` only when > 0, mapped by A1.
- The server writes that many `unreadable` rows: no serial, not booked, not credited. Shape rules:
  - it requires at least one serial on the line, so the line keeps `qty > 0` for `goods_receipt_lines_received_positive`; a line of only unreadable units is a 400, and the device blocks it ("set aside and report");
  - it counts toward the 500 cap.
- The web line shows "N unit(s) — serial unreadable". It is recorded like short. Damaged serial units into DAMAGED stay deferred (the PENDING entry stays open).

**A10 — IMEI parsing and shared vectors (B6, K3, B1).** This amends decision 2's device normalisation.
- The device's `src/lib/serial.ts` carries the backend's rules: `SERIAL_NUMBER_RE`, the 64-character bound and both caps. It refuses at the scan with a banner, and blocks confirm over a cap.
- On an `imei` SKU the prompt reads "Scan IMEI 1". The device parses in this order:
  1. a case-insensitive `IMEI1:` or `IMEI:` prefix;
  2. otherwise the payload's 15-digit groups — exactly one Luhn-valid group is taken; several distinct valid groups are refused ("Several IMEIs in this code — scan the IMEI 1 barcode");
  3. a 16-digit value gets its own banner ("This is an IMEISV — scan the 15-digit IMEI").
- Serials are text end to end, so leading zeros are kept. Any later export quotes them.
- **One vector file** (no repo precedent exists): `wms-be test/fixtures/serial-vectors.json` and `wms-mobile src/lib/serial-vectors.json`, byte-identical. Each repo's test asserts the file's sha256 equals the same literal, then runs every vector. The vectors cover the Luhn cases, prefixes, 2D payloads, ambiguous payloads, IMEISV, a leading zero, whitespace, and 64 vs 65 characters.

**A11 — The serials step (B4).**
- Progress reads `N / expected`, where expected is the open quantity of the line's PO or ASN line; blind shows just `N`.
- Undo-last, and search-to-remove.
- Three distinct feedback tones: accepted, refused, duplicate.
- A value that resolves (`resolveSku`) to a tenant SKU or pack barcode is refused, with "It's a serial" as an override.
- A repeat of the same value within 1 s is ignored as a scanner echo: no banner, no unit.

**A12 — The receive draft persists (B3).** This supersedes decision 8.
- A new `drafts` table sits beside the outbox (`outbox-store.ts:36-90`, `CREATE TABLE IF NOT EXISTS`, sealed with the store key).
- `OfflineStore` gains `putDraft` / `getDraft` / `clearDraft`, and `appendOpAndClearDraft` does both in **one SQLite transaction**. A crash between the enqueue and the clear can then never restore an already-queued receipt.
- The receive screen saves its draft after every accepted change, each serial included.
- On relaunch it offers "Resume the receipt in progress (N lines, M serials)" when the snapshot still lists its context. Otherwise it discards the draft with a note.
- A test covers a simulated kill. Other screens' drafts remain deferred.

**A13 — Values are frozen at capture (B15).**
- The queued payload holds the normalised serials as captured. Retries and the sync-report re-apply send those exact bytes.
- Test: the payload hash of a re-applied rejected `grn.submit` (stored payload passed raw, `sync-report.command.ts:1472-1497`) equals the original op's.

**A14 — Putaway amendments (K2, K8, K12, B11).** These amend decision 9.
- **Server.** `PutawayFacade` injects `InventoryFacade`.
  - A serial-tracked task's `qty` is `min(remaining putaway qty, its applied serials still in Receiving)`, and `serialNumbers` is those serials. The task is dropped at 0.
  - The id → number read is a new `serialNumbersByIdsInTx` beside `resolveSerialRefsInTx` (`putaway.command.ts:1720`).
  - Test: two lines of one SKU; place line 1 in full; re-read line 2's task, which is unchanged.
  - Size budget: ≤ 500 numbers per task at about 25 B each. The snapshot total is bounded by the serial units sitting in Receiving, about 0.5 MB at 20k units, recorded in PENDING.
- **Device.**
  - `PutawayPlacementPayload.serials`.
  - `verifyTaskSku` passes a serial SKU when the task carries `serialNumbers`.
  - The local list subtracts serials in the device's own queued `putaway.place` ops (the `queuedReturnWork` precedent) and shrinks after each queued placement.
  - A scanned serial of the same SKU that sits on **another** task's list (co-mingled Receiving stock) is placeable after a "This unit is from GRN-x — place it there?" confirmation. The device queues it as a separate placement on **its own** line. The server checks only the location, so no line's accounting is stranded.

**A15 — `serial_format` resets with tracking (K9).** An edit that ends serial tracking without sending `serialFormat` resets it to `free`. It is tested, and `serialFormat` joins the empty-edit field list (`sku.command.ts:995`).

**A16 — The device does not default `serialFormat` (K11).** `parseCatalogSnapshot` (`src/state/catalog-snapshot.ts:80`) leaves `serialFormat` absent when it is absent (the 1-1 `clients` precedent: absence means a pre-2-6a server). It passes `serialNumbers` through. Both are pinned.

**A17 — Rollout (B10).** This supersedes decision 10's "stated, not mitigated" and the device gate in Tasks.
- The new build **refuses** to receive a serial-tracked SKU when its snapshot lacks `serialFormat` ("Update the server snapshot — serial capture needs it"). It never captures anonymously.
- `DEPLOY.md` gains a runbook step: before the backend deploy, drain every handheld's queue of serial-tracked receipts (sync, then check that the review queue is empty), or accept their `serials-required` refusals.
- Two items are deferred: serialising in place the legacy anonymous serial units already in Receiving, and a server-side minimum-build check.

**A18 — Device wording (K10).** `serialRefusalWords` serves both `refusedReceiptNote` (`replay-classification.ts:590-614`) and the partly-booked `goodsReceiptNote`, e.g. "2 serial(s) not booked — already in stock at A-01-03 (WH1)". `serialsOnly` entries say "of line i", never "line refused".

**A19 — The web serial list shows each unit's state (K13).** Each serial is labelled booked, awaiting approval, approval rejected, or re-received after write-off. Unreadable units are shown as a count.

**A20 — The hash order, cross-referenced (K14).**
- Each line ends with `...conditionHashFields`, then `photoRefs` (2-5a), then `serials`, then `unreadableSerialQty`.
- Today a line never carries both photos and serials, because damage on a serial line is a 400. A both-keys golden is still added, by whichever of 2-5a and 2-6a lands second (the first cannot reference the other's key).

**A21 — Applied quantity must be whole units (K16).** For a serial line, `applied % QUANTITY_SCALE !== 0` (or excess) throws a data fault (500). It is unreachable, because serial SKUs have whole-unit UoMs (`sku.command.ts:619-620`).

**A22 — QC skipped is visible (B17).**
- A serial line of a QC-on-receipt client's receipt carries `qcSkipped: 'serial-tracked'` on its response line. Only lines with serials carry it, so requests without serials stay byte-identical.
- The lines read shows the same label, derived as "has serial rows, no receipt hold, and the receipt's client has QC on receipt now".
- PENDING records the risk: serial-tracked receipts are never quarantined, and the label reads the current policy.

**A23 — Load and locks (B12).**
- `test/serial-receipt-load.spec.ts` runs a 1,000-serial `grn.submit` concurrently with a `return.receive` naming one of its serials (dispatched earlier).
  - Pass: no deadlock, exactly one books the serial, and the other refuses it per entry.
  - The duration is logged, with an assertion under 30 s locally.
- Lock headroom: the shared lock table holds `max_locks_per_transaction` (default 64) × `max_connections` entries, and one 1,000-serial transaction takes about 1,000. `DEPLOY.md` gains `max_locks_per_transaction = 256` for the RDS parameter group (6-2b).
- The lock order of every serial-locking path is listed in Design Notes, each read on main.

**A24 — Existing tests updated (K7).** Every test that receives a serial-tracked SKU anonymously now sends serials. Known:
- `test/client-receiving-policy.spec.ts:1155` (QC-SER);
- the mobile `src/receiving/draft.test.ts` and `draft-condition.test.ts` serial fixtures.
- Find the rest with `grep -n "serialTracked: true\|serial_tracked" test/` against the 16 BE suites that post `goods-receipts`, and `src/**/*.test.ts` in mobile.
- The damage-on-serial 400 (`receipt-condition.spec.ts`) and both-flags 400 (`catch-weight.spec.ts`) tests stay as they are.

**A25 — The ACs are rewritten with observables (B18).** See Tasks & Acceptance.

**Amended Boundaries.**
- "One ledger event per booked serial unit" now reads "per **applied** serial row".
- "Review rows round-trip the serials" now includes `unreadableSerialQty`.
- The Never-list "No anonymous booking" is enforced on the device too (A17).
- The lock order adds A8's two-batch lock (existing ids, then new ones) and A7's cross-SKU identities.

**Amended matrix rows.**

| Scenario | Input / State | Expected | Error handling |
|---|---|---|---|
| Duplicate in stock | 3 serials [A,B,C]; B in stock at X | A, C book (qty 2, credit 2); B goes to review | `serialsOnly` entry `serial-in-stock` naming X |
| Two devices offline | Devices 1 and 2 each receive S on separate GRNs; device 1 syncs first | Device 1 books S; device 2's S is refused (`serial-in-stock`, or `serial-pending-approval` if S pended); its other serials book | Review row |
| Pending elsewhere | S on an open over-receipt | `serial-pending-approval` | — |
| After a pick | S's latest event is `pick.picked` | `serial-dispatched-use-returns` | — |
| After a write-off | S's latest event is a negative `stock.adjusted` | Books; `after_write_off`; audit row | — |
| In transit | S's latest event is `transfer.outbound` | `serial-in-transit` | — |
| Same IMEI, two SKUs | `imei` SKU P1 holds I in stock; receive I on `imei` SKU P2 | `serial-in-stock` naming P1 | — |
| Unreadable | `serials [A], unreadableSerialQty 1` | A books; one `unreadable` row; qty 1 | Only unreadable units → 400 |
| Putaway co-mingled | Task T1 (line 1) open; scan S from line 2 | After confirmation, queued as line 2's placement | — |

## Code Map

All wms-be paths are relative to `workspace/core/backend/wms-be/` and were read on origin/main `9a246e7`.

**Backend — receiving**
- `src/api/receiving.controller.ts:133-160` — the line mapping. Add `serials` / `unreadableSerialQty` (A1).
- `src/modules/inbound/receiving.command.ts`:
  - hash `:659-728` (line keys `:700-727`; `conditionHashFields` `:3338`); normalise `:740-763`; `assertWeightShape` `:764` (the shape precedent);
  - damage-on-serial 400 `:872-886` (keep); `clientRefused` `:897`; expiry phase `:945`; catch-weight flag rules `:990-1021`; conversion `:1023-1033`; licence `:1035`;
  - `settleAllRefused` `:1119`; document and line locks `:1200-1290`;
  - `ensureBatchIdentity` `:1303` and **the race arm `:1309-1340`** (the template for A4/A8's late phase); `recordedAt` `:1344`;
  - `grn.received` `:1693-1721`; QC skip `:1771`; approve `:2172-2371` (append `:2322`);
  - `REJECTED_GRN_LINE_CODES` `:277`; `LineRefusalCode` `:304`; `ClientRefusedLine` `:313`; `LINES_REFUSED_CODE_PRECEDENCE` `:345`;
  - `clientRefusalLines` `:2837`; `raiseRefusalReviewsInTx` `:2907`; `linesRefusedDetail` / `mixedTail` `:3283-3306`;
  - `loadSkus` `.for('update')` `:2589-2600` (receipts of one SKU serialise).
- `src/modules/inbound/receipt-condition.ts:37` — `lineConditionFields`, the pattern for `lineSerialFields`.
- `src/modules/inbound/receiving.dto.ts` — `GrnLineInputDto` `:51`; `lines` cap `:277`; `GrnLineDto` `:286`; the refusal enum description `:389-391`.
- `src/modules/inbound/receiving.facade.ts` — lines entry `:79-92`; `listGoodsReceiptLines` `:486`; `listOverReceipts` `:548`; snapshot `:725-750`.

**Backend — ledger and inventory**
- `src/modules/inventory/ledger-registry.ts:336-350` — open the `grn.received` serial arm. `pick.picked` is at `:420-438`.
- `src/modules/inventory/ledger.service.ts`:
  - `duplicateSerial` `:420`;
  - `serialLatestEventInTx` `:452-470` (A2);
  - `assertSerialArmLegal` `:502`;
  - append locks `:594-603`; seq `:625-639`; `uuidv7` id `:641`;
  - `lockSerialsInTx` `:761`.
- `src/modules/inventory/inventory.facade.ts`:
  - `lockSerialsInTx` `:532`;
  - `serialsInStockInTx` `:1494` (order at `:1510`, A2);
  - the serial-location read `:2060-2068`; history `serialHistory` `:2022`;
  - `serialsLocatedInBinInTx` `:2284-2300`;
  - new `serialLatestEventsInTx` (A6).
- `src/shared/primitives/ids.ts:13-21` — the `uuidv7` ordering (A2).

**Backend — catalog, putaway, returns, tenancy, schema**
- `src/modules/catalog/catalog.facade.ts`:
  - `serialIdentitiesInTx` `:990`; `ensureSerials` `:1122`, from which `ensureSerialsInTx` is extracted;
  - new `serialIdentitiesAcrossSkusInTx` (A7);
  - `getSkuSummariesInTx` `:600`.
- `src/modules/catalog/catalog.dto.ts` `:231` / `:681` / `:863`.
- `src/modules/catalog/sku.command.ts` — create hash `:559`; flags `:619-624`; edit `:946-1016`; empty-edit list `:995`; resulting flags `:1503-1523` (A15).
- `src/modules/putaway/putaway.facade.ts` `:77-89`, `:128-130` (constructor), `:267`.
- `src/modules/putaway/putaway.command.ts:1720` (`resolveSerialRefsInTx`); the placement serial arm `:471-502` / `:858-885` (unchanged).
- `src/modules/putaway/putaway.dto.ts:78-81` (≤ 200, 1–64).
- `src/modules/returns/return-receipt.command.ts:919-956` — the lock order and refusal precedent.
- `src/modules/tenancy/sync-report.command.ts` — `:187` (Discard only); `:1472-1497` (raw re-apply).
- New `binCodesByIdsInTx` beside `src/modules/tenancy/receiving-bin.ts` (refusal wording).
- `src/shared/db/schema.ts` — `skus` `:779`; `goodsReceiptLines` `:2554`; `overReceipts` `:2615` (`grn_line_id` `:2624`); `ledgerEvents` (`serial_ref` index).
- `drizzle/0087_receipt_line_condition.sql` — the probe model (fail-fast guard `:34`, sentinel `:124`, refused probes `:191`).
- `src/shared/db/migrate-deploy.ts:48,766` and `DEPLOY.md:124` — the lock timeout.

**Mobile** (`workspace/core/mobile/wms-mobile/`)
- `src/receiving/draft.ts` — `ReceiveDraftLine` `:86-150`; the catch-weight arm (`recordWeight` `:1556`, `removeWeight` `:1607`, `catchWeightBlocker` `:1621`); `confirmBlocker` `:1629`; `confirmPayload` `:2044` / `:2076`; `damageRefusal` `:841`.
- `app/receive.tsx` — `:159`, `:608-610`.
- `src/picking/draft.ts:453-497`; `app/pick.tsx:224-251`.
- `src/returns/draft.ts:101` (`queuedReturnWork`).
- `src/lib/sku-resolution.ts:124-137`.
- `src/api.ts` — `:324`, `:650-651`, `:1435-1450`, `:1667`.
- `src/state/catalog-snapshot.ts:80`.
- `src/putaway/draft.ts:112-130`, `:278-295`; `app/putaway.tsx:49`.
- `src/state/replay-classification.ts:590-614`.
- `src/offline/outbox-store.ts:36-121`, `src/offline/types.ts:262` (A12).

**Web** (`workspace/core/frontend/wms-fe/`)
- `src/components/inbound/inbound-cards.tsx:639-667`; `src/lib/grn-lines.ts:46`.
- The over-receipt queue (`components/conflicts/`).
- `src/components/settings/sku-create-card.tsx`, `sku-table.tsx`.
- The refusal and review label maps (the compile names each one).

## Tasks & Acceptance

**Execution:**

*Backend: schema, migration, primitives*
- [ ] `src/shared/db/schema.ts` + `drizzle/NNNN_serial_capture_at_receipt.sql` (+ journal, snapshot):
  - `skus.serial_format` with a validated CHECK;
  - the `goods_receipt_line_serials` table, its CHECKs, RLS and indexes;
  - probes (Design Notes).
- [ ] `src/shared/primitives/serial.ts`:
  - `SERIAL_FORMATS`, `SERIAL_NUMBER_RE`, `isValidImei`;
  - the caps (500 per line incl. unreadable; 1,000 per receipt);
  - `test/fixtures/serial-vectors.json` + a hash-pinned test (A10).

*Backend: ledger, inventory, catalog*
- [ ] `ledger-registry.ts` — the `grn.received` serial arm.
- [ ] `ledger.service.ts` + `inventory.facade.ts`:
  - the A2 ordering at all four sites and in history;
  - `serialLatestEventsInTx`;
  - `serialsInStockInTx` re-expressed over it;
  - the transfer test.
- [ ] `catalog.facade.ts` — `ensureSerialsInTx` (`ensureSerials` delegates), `serialIdentitiesAcrossSkusInTx`, `serialFormat` in the summaries.
- [ ] `catalog.dto.ts` + `sku.command.ts`:
  - `serialFormat`, hashed `?? undefined` last;
  - `imei` without serial tracking → 400;
  - the A15 reset;
  - an optional response field.

*Backend: receiving*
- [ ] `receiving.controller.ts` + `receiving.dto.ts`:
  - the A1 mapping;
  - `serials`, `unreadableSerialQty`;
  - response line `serials?` / `pendingSerials?` / `qcSkipped?`;
  - lines-read `serials?` with state, `unreadableSerialQty?`;
  - over-receipt list `serials?`;
  - snapshot `serialFormat` / `serialNumbers?`;
  - the widened refusal enum.
- [ ] `receiving.command.ts` — the Design Notes phases: hash, normalise, shape, early, late (A4–A8), fold, rows, appends, snapshot, audit (A6), approve and reject (A5, A21), wording (A4).
- [ ] `receipt-condition.ts` + the three review builders + `clientRefusalLines` — `lineSerialFields` (`serials`, `unreadableSerialQty`) and the `serialsOnly` entries.
- [ ] `receiving.facade.ts` — lines read (A19, A22) and over-receipt list (A5).
- [ ] `tenancy` — `binCodesByIdsInTx`.

*Backend: putaway*
- [ ] `putaway.facade.ts` — the A14 server side.

*Backend: tests*
- [ ] `test/serial-receipt.spec.ts` covers:
  - every frozen and amended I/O row;
  - the goldens (Design Notes);
  - approve and reject (incl. the 409);
  - the sync-report re-apply hash equality (A13);
  - shelf-life Apply re-sending serials;
  - identity creation only for settling serials (A8);
  - the audit row (A6);
  - `verifyChainInTx` / `rebuildProjectionsInTx` parity;
  - the putaway task cases (A14).
- [ ] `test/serial-receipt-load.spec.ts` (A23).
- [ ] The A24 updates, plus the `architecture.spec.ts` pins (writer, codes, precedence, the new audit action) and the cap-vs-CHECK pin.
- [ ] `openapi/openapi.json`.

*Web*
- [ ] `bun run api:generate`.
- [ ] SKU forms — serial format (A15 behaviour on untick).
- [ ] GRN lines — serials with states and unreadable count, plus "QC on receipt skipped — serial-tracked" (A19, A22).
- [ ] Over-receipt review — pending serials (A5).
- [ ] Labels for the 8 codes.
- [ ] Tests.

*Mobile*
- [ ] `src/lib/serial.ts` + `serial-vectors.json` (A10).
- [ ] `src/api.ts` types; `catalog-snapshot.ts` (A16).
- [ ] `src/receiving/draft.ts`:
  - serial capture, unreadable;
  - the caps and shape;
  - duplicates in the draft and against queued `grn.submit` ops;
  - the A17 refusal;
  - `confirmPayload` (A13).
- [ ] `app/receive.tsx` — the serials step (A11); draft persistence and resume (A12).
- [ ] `src/offline/*` — the `drafts` table and the atomic `appendOpAndClearDraft` (A12).
- [ ] `src/putaway/draft.ts` + `app/putaway.tsx` — A14.
- [ ] `replay-classification.ts` — A18.
- [ ] Tests for each.

*Docs (meta, last)*
- [ ] `inbound.md` — serials section; the child table; the hash order; events.
- [ ] `inventory.md` — A2 and its invariant row; events.
- [ ] `catalog.md`.
- [ ] `putaway.md`.
- [ ] Mobile SYSTEM-DESIGN — receive, putaway, the drafts table, rejections.
- [ ] `API-SURFACE.md`.
- [ ] `DEPLOY.md` — the drain step; `max_locks_per_transaction`.
- [ ] `PENDING.md`:
  - A2's residual;
  - A14's budget;
  - A22's risk;
  - legacy units;
  - the 1.4 entry narrowed;
  - "no serial intake path" removed;
  - the damage-on-serial entry kept open.
- [ ] `IMPLEMENTATION-GUIDE.md` §2 — the lesson: "never order across warehouses by `seq`".
- [ ] `docs/repos/*/README.md`.

**Acceptance Criteria:**
- **Dock to bin, offline.** Given an open PO line of 3 for a serial SKU and the device in airplane mode, when the operator scans the SKU and serials A, B, C, confirms, reconnects, and then puts away A, B, C from the snapshot task, then:
  - `select type from ledger_events where tenant_id=$t and serial_ref=$A order by id` returns `grn.received`, `putaway.placed`;
  - the web GRN line lists A, B, C as booked;
  - the PO line's `received_qty` is 3000.
- **Shape refused at the scan.** Given the serials step, when the operator scans a 65-character value, an invalid IMEI on an `imei` SKU, or a repeat, then the banner shows that rule's key, and the draft and the queue are unchanged.
- **Two devices.** Given devices 1 and 2 each offline-receive S (plus T on device 2), when 1 syncs and then 2 syncs, then:
  - device 2's GRN books T only;
  - its response carries a `serialsOnly` entry `serial-in-stock` for S naming 1's bin;
  - one `grn.lines-refused` row exists;
  - device 2's note says "1 serial(s) not booked".
- **Excess.** Given open 2 and serials [A,B,C], then:
  - A, B book and C is `pending`;
  - the over-receipt review lists C;
  - approving books C (`grn.received` for C, row `applied`);
  - had C been booked elsewhere first, approve answers 409 `serial-in-stock` and C's row stays `pending`.
- **Same IMEI on two SKUs.** Given IMEI I in stock under `imei` SKU P1, when I is received on `imei` SKU P2, then I is refused `serial-in-stock` naming P1, and P2's other serials book.
- **Putaway mismatch.** Given task [A,B], when Z is scanned, then the banner says "not waiting on this receipt line" and nothing queues. Rescanning A is refused as already scanned.
- **Old build or old op.** Given a pre-2-6a queued op for a serial SKU, when it replays, then:
  - that line is refused `serials-required`;
  - other lines book;
  - a request without serials stores a hash and snapshot equal to the goldens.
- **New build, old snapshot.** Given the new build with a snapshot that lacks `serialFormat`, when a serial SKU is scanned, then it is refused, and nothing is captured.
- **App kill.** Given 40 serials captured and the app killed, when it relaunches, then "Resume" restores 40 serials. Confirming then queues one op and leaves no draft.
- **Scale.** Given a 1,000-serial blind receipt, when it is submitted locally, then it settles in under 30 s, with the duration logged. With a concurrent return of one of its serials there is no deadlock and exactly one books that serial.
- **Migration.** Given the previous head, when the migration runs, then:
  - each refused probe fails on its named constraint;
  - accepted shapes insert and roll back;
  - `db:generate` reports "No schema changes".

## Implementation Notes

## Spec Change Log

## Review Triage Log

Design review, 2026-10-23. Two layers: the claims check against origin/main (K) and the blind review (B). Every finding was accepted on the coordinator's triage, except where noted.

| ID | Verdict | Finding → resolution |
|---|---|---|
| K1 | high | The controller maps line keys explicitly, so `serials` would be silently dropped → A1 |
| K2 | high | A serial task's qty ignored serials already placed (pooled Receiving) → A14 |
| K3 | medium | The device lacked the server's shape rules and caps → A10 |
| K4 | high | Pre-existing: serial "latest event" ordered by per-warehouse `seq` → A2. **Deviation:** ordered by `id` (uuidv7 minted after the serial lock, `ledger.service.ts:641`), not `recorded_at`, which callers stamp before the lock (`receiving.command.ts:1344`) |
| K5 | medium | Refusal wording and types not widened (`:304`, `:313`, `:3283-3306`, dto `:389-391`) → A4 |
| K6 | medium | The raced and in-stock sets were separate; raced lines were still ensured → A4, A8 |
| K7 | medium | Existing anonymous serial receipts in tests (`client-receiving-policy.spec.ts:1155`) → A24 |
| K8 | high | Device putaway ignored its own queued placements; payload lacked `serials`; `verifyTaskSku` refused → A14 |
| K9 | low | `serial_format` was left `imei` after tracking ended → A15 |
| K10 | low | The device's partly-booked note had no serial words → A18 |
| K11 | low | The snapshot parse could default `serialFormat` and hide a legacy server → A16 |
| K12 | low | `PutawayFacade` has no `InventoryFacade` (`:128-130`); the id → number read was unnamed → A14 |
| K13 | low | The web list did not distinguish pending units → A19 |
| K14 | low | The hash order was not cross-referenced with 2-5a → A20. **Partly applied:** the both-keys golden lands with whichever story lands second, because 2-5a is not on main |
| K15 | low | Probes must satisfy the other constraints; pin the cap → A3 |
| K16 | low | A non-integral applied quantity on a serial line was unhandled → A21 (data fault; unreachable) |
| K17 | low | Pending excess serials were not reserved → superseded by A5 |
| B1 | medium | No shared IMEI vectors across repos → A10 |
| B2 | high | One duplicate refused a whole line of hundreds → A4 |
| B3 | high | An app kill lost a long capture → A12 |
| B4 | medium | Serials-step ergonomics → A11 |
| B5 | medium | No path for a unit whose serial is unreadable → A9 (damaged serials stay deferred) |
| B6 | medium | IMEI label prefixes, 2D payloads, IMEISV, leading zeros → A10 |
| B7 | medium | The same IMEI under two SKUs was accepted → A7 |
| B8 | high | A pending serial could be received again before approval → A5; a subset approval is deferred |
| B9 | medium | Re-receipt after pick, transit or write-off was undifferentiated → A6 (`serials.status 'blocked'` exists, `0010:73`, and is never set → defensive) |
| B10 | high | The rollout stranded queued receipts; old snapshots captured anonymously → A17 (two items deferred) |
| B11 | medium | Co-mingled Receiving units and the snapshot size → A14 |
| B12 | medium | Load, lock headroom, lock order unverified → A23 |
| B13 | medium | jsonb ids on an immutable line → the child table (A3) |
| B14 | low | Migration lock and validation cost → A3 |
| B15 | medium | Normalised values must be frozen → A13 |
| B16 | medium | Identities were created for refused serials → A8 |
| B17 | medium | QC skip was invisible → A22 |
| B18 | medium | ACs lacked observables → A25 |

## Design Notes

**Phases in `submitGoodsReceipt`:**
1. **Hash** (A20 order).
2. **Normalise.** `serials ?? null` (`[]` → null); `unreadableSerialQty ?? 0`.
3. **Shape, above the transaction.** These are 400s:
   - trim, then `SERIAL_NUMBER_RE`;
   - no repeat within a `skuId` across the receipt;
   - `serials.length === qty`;
   - unreadable requires a serial;
   - the caps.
4. **Early, beside the expiry phase:**
   - `serials-required` / `serials-on-untracked` (whole line);
   - `serial-format-invalid` per serial on `imei` SKUs, which shrinks the line;
   - a line left with no serials is refused whole.
5. Catch-weight rules, conversion and licence, unchanged.
6. **The all-refused arm.**
7. Locks, `ensureBatchIdentity`, the race arm.
8. **Late (A8).** The resolve → lock → judge → ensure → lock → re-judge sequence. Raced lines are excluded. Hits join the one late-refused set (A4).
9. The all-refused re-test, the header, then the fold over the remaining counts.
10. **Per serial line.**
    - Rows `ordinal` 0..n−1: the first `applied/1000` are `applied` and the rest `pending` with the over-receipt id. Then the `unreadable` rows.
    - One `grn.received` per `applied` row (`QUANTITY_SCALE`, `serialRef`, `batchRef`).
    - The snapshot gets `serials` / `pendingSerials` / `qcSkipped`.
11. Audit (A6) beside `goods_receipt.submitted`.
12. **Approve:** the line's `pending` rows by ordinal, lock, judge (A6 table), append, rows → `applied`. **Reject:** rows → `rejected`.

**Lock order of every serial-locking path** (read on main). Each takes row locks first, then `lockSerialsInTx` sorted, then the warehouse advisory inside `appendMovement` (`ledger.service.ts:594-597`):

| Path | Row locks, then serial |
|---|---|
| Putaway | bin rows (`putaway.command.ts:558`) → `:864` |
| Pick | bin rows (`pick.command.ts:745`) → `:858` |
| Move | bins (`move.command.ts:361`) → `:427` |
| Transfer | source bins sorted (`transfer.command.ts:937`) → `:955` / `:1290` |
| Bin merge | bins (`bin.command.ts:733`) → `:1127` |
| Return receipt | RMA row (`return-receipt.command.ts:919`) → `:955` |
| Adjustment | SKU row (`inventory.command.ts:1048`) → `:1177` |
| Receipt (new) | SKUs (`receiving.command.ts:2600`) → document / lines (`:1200-1290`) → existing ids → new ids |
| Approve (new) | over-receipt row → SKU → document → line → serials |

No path takes a row lock after a serial lock. The append's SKU read (`:614`) is unlocked. Two receipts or approvals of one SKU serialise on the SKU row.

Residual risk: A8's second batch is acquired after the first. Postgres detects the theoretical cycle with a writer holding a new id and wanting an older one; it needs a concurrent adjustment of the same new number. That surfaces as a 40P01 → 500, and the device retries.

**Goldens (`test/serial-receipt.spec.ts`).**
- (a) **The literal** blind receipt with `serials ["SN-1","SN-2"]`, using the header key order at `:659-699` → its sha256 equals `idempotency_keys.payload_hash`.
- (b) **`serials: []` and `unreadableSerialQty: 0`** store the hash of the literal without either key.
- (c) **The snapshot.** For a no-serial line, `Object.keys` of the stored snapshot line equals the literal pre-2-6a list; the serialised snapshot has no `serials`, `pendingSerials` or `qcSkipped`; no `goods_receipt_line_serials` row exists.
- (d) Every existing golden file is untouched.

**IMEI vectors** live in the shared JSON (A10). They include `490154203237518` (valid), `490154203237517`, 14 and 16 digits, `IMEI1:490154203237518`, a 2D payload with one valid group, one with two, and `049015420323751…`-style leading-zero text.

**Migration** (NNNN = next free at code time). It runs in one transaction, uses no enum, and creates indexes only on its own new, empty table.

```sql
-- fail-fast: RAISE if skus.serial_format already exists (0087:34 shape)
ALTER TABLE "skus" ADD COLUMN "serial_format" text DEFAULT 'free' NOT NULL;
ALTER TABLE "skus" ADD CONSTRAINT "skus_serial_format_check" CHECK ("serial_format" IN ('free','imei')) NOT VALID;
ALTER TABLE "skus" VALIDATE CONSTRAINT "skus_serial_format_check";
CREATE TABLE IF NOT EXISTS "goods_receipt_line_serials" (
  "id" uuid PRIMARY KEY, "tenant_id" uuid NOT NULL, "grn_id" uuid NOT NULL, "grn_line_id" uuid NOT NULL,
  "ordinal" integer NOT NULL, "serial_id" uuid, "state" text NOT NULL, "over_receipt_id" uuid,
  "after_write_off" boolean DEFAULT false NOT NULL,
  "created_at" timestamptz DEFAULT now() NOT NULL, "updated_at" timestamptz DEFAULT now() NOT NULL,
  CONSTRAINT "grls_state_check" CHECK ("state" IN ('applied','pending','rejected','unreadable')),
  CONSTRAINT "grls_ordinal_range" CHECK ("ordinal" BETWEEN 0 AND 499),
  CONSTRAINT "grls_serial_pairing" CHECK (("state" = 'unreadable') = ("serial_id" IS NULL)),
  CONSTRAINT "grls_over_receipt_pairing" CHECK (
    ("state" IN ('pending','rejected') AND "over_receipt_id" IS NOT NULL)
    OR ("state" = 'applied')
    OR ("state" = 'unreadable' AND "over_receipt_id" IS NULL)),
  CONSTRAINT "grls_write_off_pairing" CHECK (NOT "after_write_off" OR "serial_id" IS NOT NULL)
);
CREATE UNIQUE INDEX IF NOT EXISTS "goods_receipt_line_serials_line_ordinal_unique" ON "goods_receipt_line_serials" ("tenant_id","grn_line_id","ordinal");
CREATE INDEX IF NOT EXISTS "goods_receipt_line_serials_tenant_serial_idx" ON "goods_receipt_line_serials" ("tenant_id","serial_id") WHERE "serial_id" IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS "goods_receipt_line_serials_pending_unique" ON "goods_receipt_line_serials" ("tenant_id","serial_id") WHERE "state" = 'pending';
ALTER TABLE "goods_receipt_line_serials" ENABLE ROW LEVEL SECURITY;  -- the 0086_gate_ins.sql:164-167 shape
CREATE POLICY "goods_receipt_line_serials_tenant_isolation" ON "goods_receipt_line_serials"
  USING ("tenant_id" = NULLIF(current_setting('app.tenant_id', true), '')::uuid)
  WITH CHECK ("tenant_id" = NULLIF(current_setting('app.tenant_id', true), '')::uuid);
```

- `state` is NOT NULL, so no CHECK arm needs `IS NOT NULL` before `IN`. `serial_id` and `over_receipt_id` are paired explicitly.
- `schema.ts` declares the table and its indexes, with no CHECK and no RLS.
- **The post-migration `DO` block** (0087's shape; the word INDEX never appears inside it).
  - Refused, each naming its constraint:
    - `serial_format 'IMEI'`;
    - state `'booked'`;
    - ordinal 500;
    - `unreadable` with a serial;
    - `applied` without a serial;
    - `pending` without an over-receipt;
    - `unreadable` with an over-receipt;
    - `after_write_off` on `unreadable`;
    - a second `pending` row for one serial (the unique index — listed as a refused probe, named by its constraint).
  - Accepted (sentinel `P<NNNN>`): `applied`, `pending` + over-receipt, `rejected` + over-receipt, `unreadable`, `applied` + `after_write_off`, and `serial_format 'imei'`.
  - Each probe satisfies every other constraint. Write probes in constraint-name order, so the first failure names the intended one.

## Verification

**Commands:**
- wms-be, one jest at a time: `bun run test -- test/serial-receipt.spec.ts test/serial-receipt-load.spec.ts test/receiving.spec.ts test/receipt-condition.spec.ts test/asn.spec.ts test/per-client-sku.spec.ts test/client-receiving-policy.spec.ts test/licence-enforcement.spec.ts test/putaway.spec.ts test/ledger.spec.ts test/batch-serial.spec.ts test/return-receipts.spec.ts test/movements/transfer.spec.ts test/architecture.spec.ts` — pass. Pre-existing goldens are untouched; the load test logs its duration.
- wms-be: `bun run db:generate` — "No schema changes". `git status --short` — nothing untracked.
- In each repo: `bun run lint && bun run typecheck`. `bun test` in wms-fe and wms-mobile. All pass. The shared vector files' sha256 match in both repos.
