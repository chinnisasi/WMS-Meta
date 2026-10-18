---
title: '1.2b Client receiving policy — over-receipt tolerance, QC on receipt, expiry required, minimum remaining shelf life'
type: 'feature'
created: '2026-10-19'
status: 'ready-for-dev'
baseline_commit: '5dc9a33a0e364a26151b683d48fdafe9929669c6'  # wms-be; wms-fe: 1eefa7a735accacfae7dd7081dcdb8600e6002e2; wms-mobile: d6cac227b4e4f9439c773efb3d7fa31b2ffeb515 (branches feat/1-2b-client-receiving-policy)
route: 'dispatch'
review_loop_iteration: 0
context:
  - 'docs/initiatives/production-readiness.md'
  - 'docs/design/SYSTEM-DESIGN.md'
  - 'docs/design/IMPLEMENTATION-GUIDE.md'
  - 'docs/design/modules/clients.md'
  - 'docs/design/modules/inbound.md'
  - 'docs/design/modules/putaway.md'
  - 'docs/design/modules/catalog.md'
  - 'docs/design/frontend/IMPLEMENTATION-GUIDE.md'
  - 'docs/design/mobile/IMPLEMENTATION-GUIDE.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** A 3PL's brands set different rules for goods arriving at the dock. Today every client is received the same way:
- any quantity over the PO or ASN waits for a manual decision;
- QC is a manual hold an Ops Manager places afterwards;
- a receipt line cannot carry an expiry date (`batches.expiry_date` exists but receiving never writes it);
- short-dated goods are accepted silently.

**Approach:** Each client gets a receiving policy on its row, edited on its panel in Settings → Clients. The one receipt command (`grn.submit`) enforces it for web, handheld and offline replay alike:
- **Tolerance:** excess within the tolerance books straight away.
- **QC on receipt:** what books is put on receipt-scoped QC holds, which can be released one by one or per receipt.
- **Expiry:** a batch-tracked line must carry an expiry date, and a line with less remaining life than the minimum is refused. An Ops Manager can accept the refused line from review with a note.

The handheld captures expiry and warns at the dock.

**Decisions (user, 2026-10-19):**
1. **Receiving side only.** FEFO/FIFO allocation and minimum life to the customer stay in roadmap **4.3**, which adds its own fields to the same row. Roadmap **2.4** loses its "minimum-remaining-life check per client policy" (shipped here). It keeps good/damaged/short reason codes, temperature, and expiry derived from SKU shelf life (after 1.4).
2. **A short-dated line is refused.** It is not booked; it goes to review naming its expiry and the minimum. *(Amended by decisions 5 and 6.)*
3. **The expiry rules cover batch-tracked SKUs only.** Expiry lives on the batch. Untracked SKUs receive as today. The policy panel says so and shows how many of the client's SKUs are untracked.
4. **Minimum remaining shelf life is in days:** IST calendar days from the receipt's business date to the expiry date.
5. **Accept from review** (design review). Short-dated lines get their own review row, which admits **Apply** as well as Discard. Apply re-runs those lines with the shelf-life rule waived for that receipt only. It needs `review.decide` (Ops Manager, owner) and a mandatory note, and it is audited. The policy itself never changes.
6. **The handheld warns, never blocks** (design review). A line the device believes is short-dated shows a warning naming the minimum and the remaining days. The operator may still record it, and the server decides.
7. **A failed inspection is deferred to 2.4** (design review). 1.2b ships hold, release and release-per-receipt. For a failure, the runbook is release, then write off or move by adjustment. Roadmap 2.4 gains a "QC fail" disposition. Recorded in PENDING.

## Boundaries & Constraints

**Always:**

*The policy (migration 0078, columns on `clients`)*
- `receiving_tolerance_bps` integer NOT NULL default 0, CHECK 0–10000.
- `qc_on_receipt` boolean NOT NULL default false.
- `expiry_required` boolean NOT NULL default false.
- `min_shelf_life_days` integer NULL, CHECK 1–3650 and CHECK (`min_shelf_life_days IS NULL OR expiry_required`).
- Defaults reproduce today exactly. Every client carries a policy, `self` included; a departed client's policy stays editable.
- **The API speaks basis points** (`receivingToleranceBps`, integer). The web converts a percent string to bps by decimal string arithmetic, never float multiplication, so `1.005` is a field error and not 100.

*Policy write and read* — the `updateAddresses` skeleton (`clients.command.ts:612`):
- **Write:** `PUT /tenants/:tenantId/clients/:clientId/receiving-policy`, `clients.manage`. A full replace of the four fields, with a new DTO (not the addresses DTO's "omitted = unchanged").
- **Hash:** `arm: 'receiving-policy'` over the bps integer. A no-op stores its key and writes nothing else.
- **Audit:** `client.receiving_policy_updated`, target the client, pinned in `AUDIT_NEW_ACTIONS`.
- **400s:** `validation-failed` naming the field.
- **Read:** `GET …/receiving-policy`, any staff session, returns the policy plus `untrackedSkuCount`. The count is composed in the API shell through `CatalogFacade` (clients must not import catalog).
- **DTO:** `ClientDto.receivingPolicy` is **optional**, because `ClientMutationSnapshot` is stored in idempotency keys.
- **Read semantics:** a receipt reads the policy committed when it reads it; there is no serialisation against an edit.

*Whose policy, and when*
- **Expiry and QC** use each line's own SKU client.
- **Tolerance** uses the document's client, which is the same client, because a mismatch is refused.
- The policies are read **once**, in the `departedClientsInTx` phase (`receiving.command.ts:584-613`), before any document lock, which keeps the lock order "client first".
- The **over-receipt approve** arm uses the policy current at approval.
- Remaining life is judged against the op's `occurredAt` (business time, the pick precedent). Device clock skew is accepted and recorded in PENDING.

*Expiry on the wire and at rest*
- `GrnLineInput.expiryDate` is optional, an **IST calendar date** `YYYY-MM-DD`.
- It is hashed `?? undefined`, so queued older ops hash byte-for-byte as before. Pin it with a golden.
- A malformed date is a whole-op 400, as malformed instants are today.
- Stored as `istMidnightOf(date)`. Every comparison of two expiries, and every remaining-life count, goes through `istDateOf`.

*Per-line refusals* (§7g — zero-scan-loss: never a whole-op 400 for a rule a stale snapshot can trip). New codes in `REJECTED_GRN_LINE_CODES` and `modules/inbound/receiving.dto.ts` (`:263,375`):
- `expiry-on-untracked`: the line names an expiry on an untracked SKU.
- `expiry-before-mfg`: the line's expiry precedes its mfg date.
- `batch-expiry-mismatch`, any client:
  - the line's expiry differs (by IST date) from the existing batch's non-null expiry; or
  - two lines of one receipt name the same `(sku, batch code)` with different expiries (the later lines are refused).

  A line without an expiry and a line with one on the same batch **merge**, taking the non-null expiry.
- `expiry-required`: the client has `expiry_required`, the SKU is batch-tracked, and the **effective** expiry (the line's, else the existing batch's) is null.
- `shelf-life-short`: the client has `expiry_required`, and `istDateOf(effective expiry) − istDateOf(occurredAt) < (min_shelf_life_days ?? 0)`. So an **already expired** batch is refused whenever expiry is required, even with no minimum.

These are evaluated with the client refusals, before the all-refused check (`:679`), the batch ensure and settlement. A refused line creates no batch. The refusal entries gain optional `index`, `poLineId`, `asnLineId`, `batchCode`, `expiryDate` and `minShelfLifeDays`; the existing 1-1 snapshot entries replay without them.

*Two review rows* (op ids derived from the key, with different salts, recorded in the snapshot):
- **`grn.lines-refused`**: every refused line except `shelf-life-short`. Discard only, as today.
  - **`problemCode` precedence:** `client-departed` > `sku-client-mismatch` > `batch-expiry-mismatch` > `expiry-before-mfg` > `expiry-on-untracked` > `expiry-required`. The departed code keeps winning, as today.
  - `problemDetail` and the web/device guidance vary by code.
- **`grn.shelf-life-refused`** (new op type): `shelf-life-short` lines only. Decisions `['apply', 'discard']`; the payload is the original receipt's header plus only those lines.
- **Apply** requires `note` (a new optional field on the resolve command and DTO; 400 when missing for this type).
- `applyArm` re-runs `submitGoodsReceipt` with `shelfLifeWaiver: {byUserId, note}`, a field set **only** by `applyArm` (never on the HTTP DTO) and hashed when present.
- The waiver skips `shelf-life-short` and nothing else. Departed, tolerance, QC, the document state and late-receipt (21-9) handling all apply as on any receipt.
- The audit row is `goods_receipt.shelf_life_waived`.

*Batch expiry* — `ensureBatchesInTx` gains an opt-in `fillNullExpiry` used **only by receiving** (manual movements are unchanged).
- A new batch takes the expiry.
- An existing null expiry is filled by a conditional `UPDATE … WHERE expiry_date IS NULL`, then re-selected. This amends catalog's "ensure is creation, never edit" to *fill a null, never overwrite*.
- After the ensure, a resolved expiry that differs from the line's (a concurrent writer) refuses that line `batch-expiry-mismatch`. There is never a 409.

*Tolerance* — PO and ASN lines on an **open** document:
- `ceiling = ordered + floor_to_uom_step(ordered × bps / 10000)`, in milli-units.
- `applied = clamp(qty, 0, ceiling − received)`, and the rest pends as today.
- Across a 21-9 carry-forward the tolerance applies to the line actually booked (the successor's carried quantity). This is stated and recorded in PENDING.
- `received_qty` may pass `ordered` (already true of an approved excess). The PO and ASN reads clamp `openQty` at 0 for display.
- The within-tolerance part is recorded on the GRN line as `goods_receipt_lines.tolerance_qty` (bigint, default 0, CHECK ≥ 0 and ≤ `applied_qty`). It raises no `over_receipts` row, and the over-receipt tile does not count it.
- Late receipts on terminal documents, and blind or unmatched lines, are unchanged.

*QC on receipt* — `qc_holds` gains `grn_line_id` and `over_receipt_id` (both nullable), and `kind` (`manual` | `receipt`, NOT NULL, default `manual`):
- **CHECK:** `kind = 'receipt'` ⇔ `grn_line_id IS NOT NULL`.
- **Index and 409:** the open-scope unique index becomes `WHERE status = 'open' AND kind = 'manual'`. The `openRows` 409 query in `holdScopeInTx` (`qc.command.ts:366`) gets the same predicate, so manual and excursion holds keep their rule untouched.
- **Placement:** `holdReceiptLineInTx` holds each booked line of a `qc_on_receipt` client in the same transaction.
  - One hold per GRN line, origin Receiving.
  - One `qc.held` per batch arm, moving exactly that line's applied quantity. It never reads or sweeps the scope.
  - No bin lock and no role gate (it is a consequence of the receipt).
  - The actor is the device operator. `occurredAt` is the receipt's.
  - Reason: `QC on receipt — <GRN code>`.
- **Approved excess:** for a QC client, approval holds the excess the same way (`grn_line_id` + `over_receipt_id`; the actor is the approver).
- **Not held:** serial-tracked and catch-weight lines book unheld. They are counted in the snapshot's `qcSkippedLines`, named on the device's note and on the policy panel, and recorded in PENDING.
- **Side effects, one per receipt and not per hold:**
  - outbox `qc_hold.receipt_placed {grnId, holdIds, count}`, which raises **one** notification (`notification-sources.ts`);
  - one audit row `qc_hold.receipt_placed`, target the GRN.
- **Release:** `releaseHold` is unchanged for one hold. The new `POST …/qc-holds/release-receipt {grnId}` (`qc.manage`, idempotent) releases every open receipt hold of a GRN in one transaction. The receipt notification resolves when none remain open.
- **Snapshot:** `GoodsReceiptSnapshot` gains optional `qcHeldLines` / `qcSkippedLines`.

*Putaway and reporting* (§7f amended):
- Putaway work for a line is `applied + approved excess − open receipt-hold quantity of that line`, still capped by Receiving on-hand. The hold quantity is the sum of its open hold's `qc.held` events by `grn_line_id`.
- The same subtraction applies in `putaway.facade.ts:255-372`, in the placement bound at `putaway.command.ts:355-361`, and in the `kpis.ts:343-360` awaiting-putaway SQL.
- Dock-to-stock **includes** QC dwell (it is real time to stock; recorded in `reporting.md`).

*Web*
- `ClientReceivingPolicyPanel` sits in the client panel beside addresses. It shows:
  - percent, QC, expiry required and minimum days;
  - the tracked-only note with `untrackedSkuCount`;
  - the note that serial and catch-weight SKUs are not QC-held.
  
  It is read-only without `clients.manage`. Field errors map from `validation-failed`. It also shows for `self`.
- The QC holds list (`inbound-cards.tsx`) shows, for receipt holds, the kind ("Auto · QC on receipt"), the GRN code, the client, the batch and the held quantity. It adds a GRN filter and a **Release receipt** action.
- The review queue (`lib/review-queue.ts`):
  - labels for the new codes in `GRN_REFUSAL_LABEL`;
  - guidance per code;
  - the expiry and minimum in `grnLinesRefusedSummary`;
  - the `grn.shelf-life-refused` row with **Accept anyway** (Apply) and a required note.

*Handheld*
- **Snapshot:** each client entry gains optional `receivingPolicy`. Absent means no policy: the device warns about nothing, and the server decides.
- **Expiry field:** `receive.tsx` gets an expiry field on batch-tracked lines, required when the client requires it.
  - A new `normalizeExpiryDate` accepts `YYYY-MM-DD` or `YYYY-MM` (→ the month's last day).
  - A non-empty but unparseable entry blocks confirm, as does an expiry before mfg.
- **Shelf-life check:** `shelfLifeCheck(expiry, occurredAtOfConfirm, min)` is pure and in IST. It **warns** (decision 6) at add and again at confirm.
- **Over-receipt notice:** it uses the same ceiling rule as the server and says "within tolerance — books now" or "held for approval".
- **Replay notes:** words for the five new codes per line, using the new `batchCode`. "N line(s) held for QC" and "N line(s) not QC-held (serial / catch-weight)". A legacy snapshot still shows the server's codes.
- **Golden cases:** shared tolerance and shelf-life cases (100 at 5 % → 105; 10 each at 5 % → 10; a kg line at precision 3; expiry on the IST-midnight edge) run in both wms-be and wms-mobile tests.

**Never:**
- No allocation, wave, pick or ATP change (4.3).
- No QC fail disposition (2.4).
- No change to manual or excursion holds' one-per-scope rule, or to the adjustment draw.
- No overwrite of a non-null batch expiry.
- No portal surface; no policy history beyond the audit row.
- No whole-op 400 for any of the new expiry rules.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected |
|---|---|---|
| Within tolerance | PO line 100, 5 %, receive 104 | applied 104, tolerance_qty 4, no over-receipt |
| Past tolerance | same, receive 108 | applied 105, 3 pend |
| Cumulative | 103 then 3 | second: applied 2, 1 pends |
| UoM floor | each UoM, ordered 10, 5 % | ceiling 10 |
| Expiry missing | expiry_required, tracked, new batch, none | `expiry-required`, rest books |
| Batch satisfies | existing batch has expiry, line omits | books |
| Fill | existing batch expiry null, line gives one | filled, books |
| Same date, other instant | batch stored 18:30Z prior day; line same IST date | books (no mismatch) |
| Mismatch | batch expiry ≠ line's | `batch-expiry-mismatch` |
| Intra-receipt | lines A (no expiry), B (expiry X), C (expiry Y) same batch | A, B book with X; C `batch-expiry-mismatch` |
| Short | min 90, 60 IST days left | `shelf-life-short` → its own row |
| Edge | exactly 90 days | books |
| Expired, no min | expiry_required, expiry before occurredAt's IST date | `shelf-life-short` |
| Untracked + expiry | expiryDate on untracked SKU | `expiry-on-untracked`, rest books |
| Mixed refusals | one departed, one short | two rows: lines-refused (`client-departed`), shelf-life-refused |
| Accept anyway | Apply with note on a shelf-life row | lines book (QC/tolerance apply), audit `goods_receipt.shelf_life_waived` |
| Accept, no note | Apply without note | 400, row stays open |
| QC client | 2 lines booked | 2 receipt holds, 1 notification, 1 audit row; ATP excludes; no putaway work for either |
| Pooled batch | earlier unheld receipt of same (sku, batch) in Receiving, new held line | held line shows no task; the earlier line keeps its own |
| QC + manual | open manual hold on (sku, Receiving) | receipt hold placed; a 2nd manual hold still 409s |
| Release receipt | release-receipt on a GRN with 3 open holds | all released, putaway work appears, notification resolved |
| Serial line, QC client | serial-tracked line | booked unheld, qcSkippedLines 1 |
| Old op | queued op without `expiryDate` | same hash, replays |

</frozen-after-approval>

## Code Map

wms-be (`src/`):
- `shared/db/schema.ts:302-372` `clients` (policy columns); `:2193` `goodsReceiptLines` (`toleranceQty`); `:2379` `qcHolds` (`kind`, `grnLineId`, `overReceiptId`, index). New `drizzle/0078_client_receiving_policy.sql`: CHECKs in SQL as in `0077`; the index is dropped and re-created with the new predicate.
- `modules/clients/clients.command.ts:612` → `updateReceivingPolicy`. `clients.facade.ts:100` `toClientSnapshot` gains the policy; `:346` `departedClientsInTx` is joined by `receivingPoliciesInTx`; `:168` `snapshotClients` gains the policy.
- `api/clients.controller.ts` (beside addresses `:257`, the contacts read `:299`), `api/clients.dto.ts` (a new DTO, **not** `UpdateClientAddressesDto:208`); `untrackedSkuCount` via `CatalogFacade` in the controller.
- `modules/inbound/receiving.command.ts`:
  - `:68-101` (`expiryDate`, `shelfLifeWaiver`)
  - `:408` (hash)
  - `:174-183` (codes)
  - `:584-613` (the policy read + new refusals, with existing batches read by `(sku, code)`)
  - `:679` (all-refused)
  - `:1831-1862` `ensureBatchIdentity` (merge per `(sku, code)`, `fillNullExpiry`, re-check)
  - `:1031-1054` (tolerance)
  - `:1870-1890` `clientRefusalLines` (new optional fields)
  - `:1901-1964` (two rows, precedence, text per code)
  - `:2012` `refusedGrnLinesOpId` (+ shelf-life salt)
  - the approve arm `:1464-1566` (hold the excess)
- `modules/inbound/receiving.dto.ts:263,375` — code enums and descriptions; `expiryDate` on the line DTO.
- `modules/catalog/catalog.facade.ts:770-826` `ensureBatchesInTx` — `fillNullExpiry`, returning the resolved expiry.
- `modules/inbound/qc.command.ts` — `holdReceiptLineInTx` (the movement write of `:404-449` without the scope read, bin lock or role gate); `:366` the 409 query predicate; `releaseReceiptHolds`. `releaseHold:513` reverses its own `qc.held` events by `holdId` (verified) and is unchanged. `qc.facade.ts:165-176` list mapping: kind, GRN code, client, batch, held qty, `grnId` filter.
- `modules/notifications/notification-sources.ts:448-463` — a `qc-receipt` source on `qc_hold.receipt_placed`, resolved when the GRN has no open receipt holds.
- `modules/tenancy/sync-report.command.ts`:
  - `:137` (`grn.shelf-life-refused`: apply + discard)
  - `:153` `ApplicableOpType`
  - `:241` resolve `note`
  - `:264` `PAYLOAD_FIELDS`
  - `:1240-1300` `applyArm` case (re-uses the `grn.submit` call, passing the waiver)
  - `:321-329, :1005-1007` (decision texts)
- `modules/putaway/putaway.facade.ts:255-372`, `putaway.command.ts:355-361`, `modules/reporting/kpis.ts:343-360` — subtract open receipt-hold quantity per line.
- `modules/inbound/po.command.ts:607,947` and the ASN read — clamp `openQty` at 0.
- `openapi/openapi.json` via `bun run openapi:export`.

wms-fe (`src/`):
- `components/settings/clients-card.tsx:282-292` mounts the new `client-receiving-policy.tsx` (modelled on `client-addresses.tsx:48`).
- `lib/api/client.ts:1092` (wrappers), `lib/clients.ts:1122` (`receivingPolicyReason`, `percentToBps` / `bpsToPercent` by string).
- `components/inbound/inbound-cards.tsx:610-640` (QC list columns, filter, Release receipt).
- `lib/review-queue.ts:393-470` (labels, guidance, summary, the shelf-life row, Accept anyway + note) and its review-queue component.
- `bun run api:generate`.

wms-mobile:
- `src/api.ts:1139` `CatalogClient.receivingPolicy?`.
- `src/receiving/draft.ts`: `:64-96` (`expiryDate`), `:545` beside `normalizeMfgDate` (`normalizeExpiryDate`), `:905` (`overReceiptNotice` with the ceiling), `:960` (confirm-time check), `:994,1025` (payload).
- `app/receive.tsx:805-818` (expiry field, warning).
- `src/state/replay-classification.ts:276-351` (codes, QC counts).

## Tasks & Acceptance

**Execution:**
- [ ] wms-be migration 0078 + schema -- policy, `tolerance_qty`, `qc_holds` kind/columns/CHECK/index -- `db:verify` and `db:generate` clean.
- [ ] wms-be clients surface (command, facade, controller, DTO, audit pin) -- the policy.
- [ ] wms-be catalog `fillNullExpiry` -- expiry on batches.
- [ ] wms-be receiving + qc + sync-report + notifications -- refusals, two rows, waiver apply, tolerance, receipt holds, release-receipt.
- [ ] wms-be putaway + kpis + PO/ASN openQty clamp -- held stock is not work.
- [ ] wms-be `test/client-receiving-policy.spec.ts` -- every I/O row; the old-op hash golden; the 0078 index (manual + receipt hold on one scope; second manual still 409; excursion path); audit pins; the shared golden cases.
- [ ] wms-fe panel, wrappers, reasons, QC list, review queue + tests (`clients-card.test.tsx`: owner edit, read-only non-owner, `self`, field errors, percent↔bps; `review-queue` tests for each code and Accept anyway) -- web.
- [ ] wms-mobile expiry capture, warnings, notice, replay words + tests (every code; QC counts; legacy snapshot; IST edge; shared goldens) -- handheld.
- [ ] meta docs -- `clients.md`, `inbound.md` (receipt holds, tolerance, two rows), `putaway.md`, `catalog.md` (fill rule), `reporting.md` (dock-to-stock), `API-SURFACE.md`, `PENDING.md` (close 1.2b; add the deferrals below), `IMPLEMENTATION-GUIDE.md` §7f (receipt holds subtract), `docs/repos/*/README.md`, `mobile/IMPLEMENTATION-GUIDE.md` (replay codes), `production-readiness.md` (2.4, 4.3).

**PENDING entries to add:** QC fail disposition (2.4); serial / catch-weight not QC-held; device clock skew on remaining life; tolerance across carry-forward applies to the remainder; a client portal view of its policy.

**Acceptance Criteria:**
- Given a client with the default policy, when any receipt is submitted, then outcome, hash, snapshot and review rows are byte-identical to today.
- Given a QC client's receipt holds, when an Ops Manager releases the receipt, then the units are putaway work and the notification resolves.
- Given a handheld with a snapshot lacking `receivingPolicy`, when it receives, then it warns about nothing and shows the server's refusals on replay.
- Given an accountant opens a client, then the policy is read-only.

## Design Notes

**Receipt holds, not `holdScopeInTx`.** A manual hold quarantines a whole `(sku, bin)` on-hand. On the shared Receiving bin that sweeps other receipts' units, and the one-open-hold index would 409 the second receipt of a SKU. A hold's quantity is already the sum of its own `qc.held` events, so a line-sized hold needs no quantity column.

**Per-line, never 409.** The first draft had a "retryable" 409 after the batch ensure. Same-batch lines with different expiries made it permanent: every retry replays the same input, and the device's replay drops a 409 as `rejected` (`replay-classification.ts:159`), which loses scans. Every expiry rule is therefore a per-line refusal.

**Shelf-life lines get their own row** because Apply must re-run only lines a waiver can book. A departed client's line in the same row could never apply.

## Verification

**Commands:**
- wms-be: `bun run test` (full suite, alone), `bun run lint && bun run typecheck && bun run build`, `bun run db:migrate && bun run db:verify` on a fresh DB, `bun run db:generate` → "No schema changes", `bun run openapi:export` with no diff left.
- wms-fe: `bun run api:generate`, `bun run test`, `bun run lint`, `bun run typecheck`, `bun run build`. The drift guard fails until wms-be merges, which is expected.
- wms-mobile: `bun run test`, `bun run typecheck`, `bun run lint`.

## Implementation Notes

## Spec Change Log

## Review Triage Log

### Design review — 2026-10-19 (2 reviewers: backend/data 17, web/handheld/product 16; 33 raw → 22 after dedup)

| # | Finding (reviewers) | Verdict | Disposition |
|---|---|---|---|
| D1 | Post-ensure "retryable" 409 is permanent for same-batch lines with different expiries; the device drops a 409 as `rejected` (both) | high — verified `receiving.command.ts:1844-1852`, `replay-classification.ts:159` | Merge per (sku, code); per-line `batch-expiry-mismatch`; no 409 |
| D2 | Whole-op 400s (expiry on untracked, expiry < mfg) quarantine the whole receipt on replay (product) | high | Per-line `expiry-on-untracked`, `expiry-before-mfg` |
| D3 | Short-dated refusal is a dead end: Discard only, policy owner-only (product) | high | **User decision 5**: own row, Apply with note |
| D4 | "No putaway work until release" false — putaway is pooled per (sku, batch) (both) | high — verified `putaway.facade.ts:255-381`, `putaway.command.ts:355` | `grn_line_id`; subtract open hold qty in tasks, placement bound, kpis |
| D5 | Narrowed index leaves the 409 query unfiltered; approve holds would count as manual (backend) | high — verified `qc.command.ts:355-375` | `kind` column + CHECK; same predicate on index and query |
| D6 | Expiries compared as instants (both) | high | Date-only wire format; `istMidnightOf` store; `istDateOf` compare |
| D7 | Review-row `problemCode` rule changed as a side effect; guidance/text client-only; web labels a `Record` (both) | high — verified `review-queue.ts:393-416` | Explicit precedence, departed still wins; text per code; FE files mapped |
| D8 | Refusal entries can't identify the line (no batch, poLineId null) (backend) | medium | Optional `index`, `poLineId`, `asnLineId`, `batchCode`, `expiryDate`, `minShelfLifeDays` |
| D9 | Whose policy (doc vs receipt vs line client) implicit; blind mixed receipt would skip QC (both) | medium | Per line's SKU client for expiry/QC; read once in the departed phase |
| D10 | Null-fill scope and race unstated; effective expiry unstated (backend) | medium | Receiving-only `fillNullExpiry`, conditional UPDATE; effective = line ?? batch |
| D11 | One notification + audit per hold; 200-line receipt = 200 releases (both) | medium — verified `notification-sources.ts:448` | One event/notification/audit per receipt; `release-receipt` command |
| D12 | Ops Manager can't work receipt holds: no qty/client/batch/filter (product) | medium | List columns, GRN filter, Release receipt |
| D13 | Hold lock/authority/actor/time implicit; bin lock would serialise receipts (backend) | medium | No bin lock, no role gate; actor per path; receipt's occurredAt |
| D14 | Dock-to-stock includes QC dwell; within-tolerance excess recorded nowhere (backend) | medium | Include dwell (decision); `tolerance_qty` column |
| D15 | Tolerance across carry-forward applies to the remainder; openQty negative (backend) | medium | Stated + PENDING; openQty clamp |
| D16 | Serial/catch-weight silently unheld (product) | medium | Panel note, device note, PENDING |
| D17 | No QC fail path (product) | medium | **User decision 7**: deferred to 2.4 |
| D18 | Device refusal on stale snapshot; check time ≠ occurredAt (product) | medium | **User decision 6**: warn; check at confirm |
| D19 | Expiry labels often MM/YYYY; typo silently dropped (product) | medium | `normalizeExpiryDate` (YYYY-MM → month end); unparseable blocks confirm |
| D20 | `untrackedSkuCount` home would create a module cycle (backend) | low | Composed in the API shell via CatalogFacade |
| D21 | Percent float rounding; "same lock" claims serialisation (backend) | low | API in bps, string conversion; read-committed stated |
| D22 | Code Map wrong refs (`toClientSnapshot`, addresses DTO semantics) and missing consumers (both) | low | Corrected; consumers added |
| — | `expiry_required` without a minimum books expired goods (backend) | low | Expired refused whenever expiry required |
| — | Device tolerance math has no shared proof (product) | low | Shared golden cases |
| — | Client-surface ACs/tests missing (product) | low | Added to Tasks |
