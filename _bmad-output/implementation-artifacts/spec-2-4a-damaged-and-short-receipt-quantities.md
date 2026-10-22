---
title: '2-4a damaged and short receipt quantities — per-line good / damaged / short with reason codes, damaged units in a non-sellable DAMAGED bin'
type: 'feature'
created: '2026-10-21'
baseline_commit: 'e1771c7fc88b060ac998c0bf2c113058b9859c1d'  # wms-be; wms-fe: 3a5a14ff1150780d13bb002d05800a63b7e3dd3b; wms-mobile: d8df154903f908f31432e47aaaec4971a5efb3cc
status: 'done'
route: 'dispatch'
review_loop_iteration: 0
context:
  - 'docs/initiatives/production-readiness.md'
  - 'docs/design/SYSTEM-DESIGN.md'
  - 'docs/design/IMPLEMENTATION-GUIDE.md'
  - 'docs/design/modules/inbound.md'
  - 'docs/design/modules/inventory.md'
  - 'docs/design/modules/tenancy.md'
  - 'docs/design/frontend/SYSTEM-DESIGN.md'
  - 'docs/design/frontend/IMPLEMENTATION-GUIDE.md'
  - 'docs/design/mobile/SYSTEM-DESIGN.md'
  - 'docs/design/mobile/IMPLEMENTATION-GUIDE.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** A receipt line has one quantity. The dock cannot say that 10 of the 100 cartons arrived crushed, or that the invoice listed 5 that never arrived. Damaged units are booked as sellable stock, and a short delivery leaves no reason for the vendor claim.

**Approach:** Each `grn.submit` line splits into **good** (`qty`), **damaged** (`damagedQty` + `damageReasonCode`) and **short** (`shortQty` + `shortReasonCode`). Good units settle against the PO or ASN exactly as today. Damaged units go straight into a new per-warehouse system **DAMAGED** bin, outside ATP. Short is recorded on the line only. Damaged stock leaves DAMAGED by a write-off adjustment.

**Decisions (user, 2026-10-21):**
1. **Damaged units do NOT credit the PO or ASN.** Only good units move `received_qty` and run tolerance and over-receipt. Damaged units never pend, and the document line stays open for a replacement (or a short-close).
2. **Short is typed per line at the dock**, against the supplier's invoice or challan, with a reason. It is recorded only: no stock, no document effect.
3. **Disposal is a write-off by stock adjustment.** A negative adjustment out of DAMAGED is allowed; anything else touching DAMAGED is refused. Return-to-vendor and re-grade stay with 2.8.
4. **The web gets expandable GRN lines** (SKU, batch, good / damaged / short and reasons), and DAMAGED is labelled "Damaged (not sellable)" on stock.
5. **Split (user):** expiry derived from shelf life and arrival temperature are 2-4b (deferred-work).
6. **Refusals (design review):**
   - A line with `qty 0` (all damaged) skips `shelf-life-short` and `expiry-required`.
   - The licence rule and the expiry data-integrity rules (`expiry-on-untracked`, `expiry-before-mfg`, `batch-expiry-mismatch`) and the client rules still apply.
   - A refused line goes to review whole, damaged and short parts included. One line never splits between stock and review.
7. **Portal unchanged:** the damaged and short visibility gaps go to PENDING. Client confirmation is roadmap 2.9.
8. **DAMAGED stock is billed as storage**, like RETURNS.
9. **No damage on serial-tracked or catch-weight lines** (whole-op 400; the device hides the control). PENDING records the gap, which pairs with 2.6.

## Boundaries & Constraints

**Always:**
- **Additive hashing**, after `weightsGrams` in each line:
  - `damagedQty: d > 0 ? d : undefined`, then `damageReasonCode` hashed only beside it.
  - The same for `shortQty` and `shortReasonCode`.
  - A pre-2-4a queued op hashes byte for byte as before (a literal golden pins it).
- **DAMAGED is excluded from availability.** Its units are on-hand in DAMAGED and excluded from ATP, reservations, channel publish and replenishment, through one `damagedUnits` term beside `returnsAwaitingUnits` everywhere that term is used.
- **The device gates on the vocabularies.** It shows the damaged and short controls only when the catalog snapshot carries the vocabularies, and blocks confirm while a draft holds damage or short but the snapshot has none. Rolling back the server while new-key ops are queued is unsupported (stated).
- **Review rows round-trip the new fields.** Every review-row line builder carries the four fields when > 0, so a pre-2-4a row is byte-identical, and Apply re-sends them. `rejectedLines` entries carry them too.

**Never:**
- **Document effects:**
  - No crediting of a PO or ASN line by damaged units.
  - No `over_receipts` row for a `qty 0` line in any arm.
  - No damage on serial-tracked or catch-weight lines.
- **No adjustment into DAMAGED, and no positive adjustment there.** No putaway, pick, transfer, count, QC hold or excursion origin on DAMAGED.
- **Out of scope:**
  - No portal change, no GRN document, no photos (2.5), no desk receiving (2.7).
  - No short on a line without arrivals: a line needs `qty + damagedQty > 0`.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|---|---|---|---|
| Split line | PO line open 100; `qty 90, damagedQty 10 crushed` | 90 → Receiving (`grn.received`), credits 90; 10 → DAMAGED (`grn.damaged`); line stays open 10 | — |
| All damaged, open doc | `qty 0, damagedQty 5 wet` | GRN line applied 0, no `grn.received`, no credit, no over-receipt, no `unmatchedLines` entry; 5 → DAMAGED | — |
| All damaged, terminal or re-targeted | closed or cancelled document; `qty 0, damagedQty 5` | no `over_receipts` row (the R1 500); 5 → DAMAGED | — |
| All damaged, blind or unmatched | `qty 0, damagedQty 2` | applied 0; 2 → DAMAGED; no unmatched entry | — |
| Short only | `qty 95, shortQty 5 not-shipped` | 95 settles as today; `short_qty 5` stored | — |
| Over-receipt + damage | open 10; `qty 12, damagedQty 3` | good: 10 applied + 2 pend; 3 → DAMAGED | — |
| QC client | `qty 8, damagedQty 2` | the hold moves the 8 applied; the 2 go unheld into DAMAGED | — |
| Short-dated all damaged | client min life 90 d; `qty 0, damagedQty 4`, expiry 10 d | books to DAMAGED (decision 6) | — |
| Refused mixed line | `sku-client-mismatch`; `qty 3, damagedQty 1` | whole line to review, `rejectedLines` carries `damagedQty 1`; Apply re-books both parts | — |
| Bad shape | damage without a reason; a reason with 0; an unknown code; `qty 0` with no damage; a negative value or one over max; damage on serial or catch-weight | whole-op 400 `validation-failed` | — |
| Write-off | `−4 damaged` adjustment, batch named, on DAMAGED | `stock.adjusted` out of DAMAGED; ATP unchanged | over threshold → 202 pend |
| Wrong adjustment | `+4` on DAMAGED, or a pend approved after the guard | 400 `damaged-bin-write-off-only` | — |

</frozen-after-approval>

## Code Map

### Backend (`workspace/core/backend/wms-be`)

**Schema and migration**
- `src/shared/db/schema.ts:2547` `goodsReceiptLines`: add `damagedQty` (bigint milli, not null, default 0), `damageReasonCode` (text null), `shortQty` and `shortReasonCode`. Fix the comment that says "positive".
- `drizzle/0087_receipt_line_condition.sql` (new):
  - The four columns.
  - Drop `goods_receipt_lines_qty_positive`; add `_qty_nonnegative` (`qty >= 0`) and `_received_positive` (`qty + damaged_qty > 0`).
  - The pairing CHECKs, `IS NOT NULL` before `IN`, for damage and for short.
  - **Re-code collisions (code review CR1):** every user zone or bin (`system_owned = false`, retired or not) coded `DAMAGED` is re-coded to `'DAMAGED-' || left(id::text, 8)`, with a `RAISE NOTICE` naming each (warehouse, old, new code). Codes cannot be renamed and retire keeps the unique key, so nothing else frees the code. After 0087 the collision is unreachable (creates reserve it); `damaged-bin-conflict` stays only as a defensive arm, and its detail names the colliding location's id instead of advising a retire.
  - Refused-insert probes: `qty 0, damaged 0`; damaged without a reason; a reason with 0; an unknown code. An accepted `qty 0, applied 0, damaged > 0` row is rolled back.
  - Follow the 0086 header and the IMPLEMENTATION-GUIDE §3 checklist.
- `src/modules/inbound/receipt-condition.ts` (new):
  - `DAMAGE_REASON_CODES = ['crushed','wet','torn-packaging','broken','leaking','pest','other']`.
  - `SHORT_REASON_CODES = ['not-shipped','short-packed','lost-in-transit','other']`.
  - Both are pinned against the CHECKs by a test.

**DTOs**
- `src/modules/inbound/receiving.dto.ts`:
  - `GrnLineInputDto` (`:50`) gains the four optional fields (`@Min(0)`, `@Max`, `@IsIn`). `qty` becomes `@Min(0)`.
  - The response `GrnLineDto` (`:255`, `:306`) gains the fields and drops `minimum: 0.001`.
  - The `totalUnits` description (`:587`) changes to "good units".
  - `RejectedGrnLineDto` gains the fields.

**The receipt command** (`src/modules/inbound/receiving.command.ts`, `submitGoodsReceipt`)
- Hash at `:613` (rule in Boundaries).
- Normalise `inputLines` (`:722`) with `?? 0` / `?? null`, so an old review payload re-applies.
- Shape tier (`:729–790`):
  - The pairing, the codes, `>= 0` and the maximum for each quantity, and `qty + damaged > 0`.
  - Both quantities go through `assertRecordableQuantity` beside `qty` (`:961`).
- Right after `loadSkus` and before the refusal split, over ALL lines: damage on a serial-tracked or catch-weight SKU is a 400.
- The expiry phase (`:879`) skips `shelf-life-short` and `expiry-required` when `qty = 0`.
- `ensureDamagedBinInTx` runs only when some receivable line carries damage, beside `:1090`.
- Settlement:
  - The terminal and re-target arms (`:1362–1421`) write an over-receipt row only when `qty > 0`.
  - The unmatched and mismatch arms (`:1423–1449`) add no `unmatchedLines` entry when `qty = 0`.
  - Damaged units of a `po-line-not-found` or `asn-line-not-found` line are not booked; the rejected entry carries them.
- After the `grn.received` loop (`:1584`): one `grn.damaged` per settled line with `damaged > 0`, independent of applied, terminal or pending. Its reference names the header's `po?.id` / `asnId` plus the new optional `grnLineId`. QC holds, handling units and `qcSkippedLines` are unchanged (keyed `applied > 0`).
- The inactive-SKU flag (`:1716`/`:1758`) checks `applied > 0 || damaged > 0`, and its lines carry `damagedQty`.
- The three review-row line builders (`:2835`, `:2877`, `:2928`) and `clientRefusalLines` (`:2684`) carry the four fields when > 0.
- The snapshot, `grn.recorded` and the response lines carry the fields.

**Ledger and metering**
- `src/modules/inventory/ledger-registry.ts:324`: register `grn.damaged` (sinceVersion 1, `['grn-receipt']`, batch arm open, serial arm closed), with the `return.received` intake comment.
- The `grn-receipt` reference arm (`:67–84`) gains an optional `grnLineId`, omitted elsewhere, so existing canonical bytes are unchanged.
- `inventory.dto.ts:491` description updated.
- `client-metering.ts` / `test/metering.spec.ts:629`: `'grn.damaged': ['to']`. It bills storage (decision 8).

**System bin and guards**
- `src/modules/tenancy/receiving-bin.ts`:
  - `DAMAGED_ZONE_CODE` / `DAMAGED_BIN_CODE = 'DAMAGED'` and `ensureDamagedBinInTx` (the RETURNS pattern; 409 `damaged-bin-conflict` for a collision that already exists).
  - `assertNotReservedLocationCode` reserves DAMAGED too: `bin.command.ts:544`/`:1954`, `zone.command.ts:100`, and the 409 text at `tenancy.controller.ts:367/426/487`.
- `src/modules/inventory/reservation.service.ts:156`: `damagedUnits` beside `returnsAwaitingUnits` at `:590`, `:873`, `:1443` and `:2031`, the ATP formula (`:942`), the probe types and the messages.
- `src/modules/inventory/inventory.command.ts:963` `assertAdjustableInTx`: DAMAGED allows only a negative delta (`damaged-bin-write-off-only`). This method runs before the pend branch and again at approval, so the guard needs no controller check.
- `src/modules/inbound/qc.command.ts:394`: DAMAGED cannot be a hold origin.

**Reads**
- `src/modules/inbound/receiving.facade.ts`:
  - The snapshot gains `receiptDamageReasons` / `receiptShortReasons`.
  - New `GET /tenants/:t/receiving/goods-receipts/:grnId/lines` (any staff role): SKU code and name, batch code, `qty`, `appliedQty`, and the damaged and short fields.
  - The GRN list gains `damagedUnits` / `shortUnits` (in the second query).
- `inbound.facade.ts:503` `ReceiptLineRecordRow` gains `damagedQtyMilli`.

**Stale system-bin lists to update:** `inventory.dto.ts:694`, `client-wind-down.ts:14`, `sku.command.ts:1953`, `inventory.facade.ts:2336`, `bin.command.ts:748/752/1270/1499`.

### Mobile (`workspace/core/mobile/wms-mobile`)

**`src/receiving/draft.ts`**
- `ReceiveDraftLine` (`:85`) gains `damagedQty`, `damageReason`, `shortQty` and `shortReason`.
- "Move to damaged" moves N units from good to damaged (default: the last scan's pack factor). Short is set by a stepper.
- An abandoned-line switch (`:600–622`) happens only when all three quantities are 0, and it resets the new fields.
- `canConfirm` / `totalDraftQty` (`:351`/`:362`) count `qty + damagedQty`. The payload filter (`:1655`) keeps lines with `qty + damagedQty > 0`. A reason is required when its quantity is > 0.
- Damage is not allowed on serial-tracked or catch-weight lines; the note there reads "receive as good, then write off".
- Expiry warnings (`:365`, `:1003`, `:1267`) follow decision 6.
- `confirmPayload` (`:1653`) adds the keys only when > 0.

**`app/receive.tsx:877`**
- The Damaged and Short controls with reason chips (the `return-receive.tsx:321` pattern), shown only when the vocabularies are present.

**Supporting files**
- `src/api.ts:321`: the input and response line types, including the rejected line.
- `src/state/catalog-snapshot.ts`: absent vocabularies → `null`, with a legacy-seal test.
- `src/state/replay-classification.ts`:
  - `goodsReceiptNote` (`:555`) adds "N damaged → DAMAGED, M short".
  - A named arm for `damaged-bin-conflict` (beside `:118`).

### Web (`workspace/core/frontend/wms-fe`)

**`src/components/inbound/inbound-cards.tsx`**
- `GoodsReceiptsCard` (`:456`) gets an expandable row that loads the lines route (the `gate-ins-card.tsx:487` pattern).
- The Units column adds "+N damaged".
- The QC picker (`:1019`) excludes DAMAGED.

**Stock and the write-off** (`src/lib/inventory.ts:20`, `inventory-screen.tsx`)
- Label: `DAMAGED: 'Damaged (not sellable)'`.
- A "Write off" action on DAMAGED rows, shown only with `stock.adjust` (the capability mirror). It lists the bin's batches (`GET …/inventory/batches?binId=`, `skuId`), and the write-off is per batch.
- The dialog:
  - Fields: quantity, reason `damaged`, required note (1–500 characters), and `batch {code, overrideReason: 'damaged write-off'}` on batch-tracked SKUs.
  - One Idempotency-Key per submission, reused on retry and renewed after success.
  - Error arms: `damaged-bin-write-off-only`, `bin-retired`, insufficient stock.
  - A 202 shows "Pending approval" with a link to `/conflicts?queue=adjustment-pendings`.
- `SYSTEM-DESIGN.md:45` ("read-only") changes.

**Other**
- `src/lib/drill.ts:65`: `grn.damaged` goes in both `LEDGER_EVENT_TYPES` and `LEDGER_TYPE_LABEL` ('Received damaged').
- `zone-bin-setup.tsx:1222` reserves DAMAGED.
- `src/lib/review-queue.ts:551/671/877` renders "good N · damaged M (reason) · short K (reason)", plus guidance for `damaged-bin-conflict`.
- `src/components/compliance/line-records.tsx` shows damaged.
- Regenerate the API client: `bun run openapi:export`, then `bun run api:generate`.

## Tasks & Acceptance

**Execution:**
- [x] BE schema, `0087` and `receipt-condition.ts`: columns, CHECK swap, notice, probes; `db:generate` reports no changes.
- [x] BE bin, reserved codes, registry, metering, ATP, adjustment and QC-origin guards, stale lists.
- [x] BE DTOs and the command: as mapped, including the arms, the builders and normalisation.
- [x] BE facade and controller: snapshot vocabularies, the lines route, list sums, drill; OpenAPI export.
- [x] BE tests `test/receipt-condition.spec.ts`:
  - every matrix row;
  - the old-op hash golden, and a new golden with all four fields;
  - ATP, reservation and channel quantity exclude DAMAGED;
  - a write-off is ATP-neutral, including an expired batch;
  - a `+` adjustment and an approved pend are refused;
  - an old review row re-applies;
  - a reserved-code refusal, and the ensure conflict.
- [x] Mobile: draft, payload, screen, snapshot and note, plus tests (an all-damaged line and receipt, the switch, a pack move, key absence, a legacy snapshot, the rollback blocker).
- [x] Web: card lines, labels, write-off dialog, ledger lists, review copy, drill, plus tests; regenerated client.
- [x] Meta docs (with the docs PR):
  - `API-SURFACE.md` (the route and the error arms);
  - `modules/inbound.md`, `inventory.md`, `tenancy.md`;
  - mobile IMPLEMENTATION-GUIDE §2 keys;
  - frontend SYSTEM-DESIGN;
  - `docs/repos/*/README.md`;
  - PENDING (below).

**Acceptance Criteria:**
- Given a pre-2-4a queued `grn.submit` or review row, when it replays or re-applies, then it hashes and settles exactly as before.
- Given 10 damaged units booked, when ATP, order allocation and channel publish read the SKU, then the 10 are not available.
- Given DAMAGED stock, when an operator with `stock.adjust` writes off 4 of a batch on the web, then that batch's on-hand in DAMAGED drops by 4, or the write-off pends over the threshold.
- Given a GRN with damage and short, when its row is expanded on the web, then each line shows good / damaged (reason) / short (reason).

## Design Notes

- **Why a separate `grn.damaged` type, not `grn.received` into DAMAGED.** `grn.received` means "a credited receipt into Receiving", and putaway, billing notes and over-receipt approval all reason about it. A distinct intake type (the `return.received` precedent) keeps each of those unchanged. `grnLineId` on its reference ties DAMAGED stock to the GRN line that the vendor claim and 2.8 will need.
- **Why `qty` stays "good".** The GRN list derives pending as `sum(qty) − applied` (`receiving.facade.ts:390`). Settlement and putaway read `qty` / `applied_qty`, and the billing drill reads `qty`. Keeping `qty` as good units leaves every one of them correct. The cost is the CHECK swap and the `qty 0` arms in the matrix.
- **Billing.** A receipt line is still one line. An all-damaged line is billed as a receipt line (the 21-9 precedent), and the drill shows its damaged quantity so the charge reads true.
- **The bin code.** RETURNS set the precedent: reserved at create, `*-conflict` at ensure for a collision that existed before the rule. Codes cannot be renamed, so ensuring the bin only on damage keeps good-only receipts unblocked in a collided warehouse. 0087's notice surfaces any collision before deploy.
- **Known overlap.** A reconcile-quarantined DAMAGED scope is dropped from the ATP on-hand read and also subtracted by `damagedUnits`. That understates ATP, the safe direction, and QC-HOLD and RETURNS behave the same way.
- **Write-off UI is in scope** although the adjustment screen is roadmap 3.2. Without it, decision 3 is API-only.
- **PENDING entries (docs PR):**
  - Portal damaged and short visibility: widen the "sellable / held split" entry (`PENDING.md:254`) and add ASN/PO damaged and short.
  - Serial and catch-weight damage intake: the workaround is to receive as good, then write off from Receiving or by handling unit.
  - DAMAGED mixes hazard and cold-chain classes, because system bins are exempt from segregation.
  - Server rollback with new-key ops queued is unsupported.
  - A short line with no arrivals cannot be recorded.

## Verification

**Commands:**
- `bun run test -- test/receipt-condition.spec.ts test/receiving.spec.ts test/client-receiving-policy.spec.ts test/licence-enforcement.spec.ts test/asn.spec.ts test/per-client-sku.spec.ts test/metering.spec.ts` (wms-be, run alone): pass.
- `bun run lint && bun run typecheck` in each repo; `bun test` in wms-fe and wms-mobile: pass.
- `bun run db:generate` (wms-be): "No schema changes".

## Implementation Notes

Implemented 2026-10-21 on `feat/2-4a-damaged-and-short-receipt-quantities` in each child repo (committed locally, not pushed): wms-be `ba38163`, wms-mobile `31347a0`, wms-fe `fb408e8` (amended after code review). The meta docs are edited in the working tree, uncommitted (the docs PR lands after the code merges).

- **Hash:** `conditionHashFields` puts `damagedQty`, `damageReasonCode`, `shortQty`, `shortReasonCode` after `weightsGrams`. Each pair is hashed only when its quantity is > 0. Goldens in `test/receipt-condition.spec.ts`: a pre-2-4a op hashes byte for byte (and to the same digest with explicit `0`/`null`), and a new op carries all four.
- **Normalisation:** `NormalisedGrnLineInput` applies `?? 0` / `?? null`. The shape tier (`assertLineConditionShape`) sits beside `qty`'s checks, behind the replay lookup, which is where `qty`'s checks already were. The controller passes the four keys only when they are present.
- **Bin ensure:** `ensureDamagedBinInTx` and `ensureReturnsBinInTx` now share `ensureReservedSystemBinInTx`, which is the 13-2 body unchanged. `RESERVED_LOCATION_CODES` reserves both codes.
- **Write-off guard:** lives in `assertAdjustableInTx`, right after the bin read (`assertBinInWarehouse` now returns `systemOwned`). It refuses `!(quantityDelta < 0)`.
- **`receiving.spec.ts`:** its 0013 CHECK test pinned `goods_receipt_lines_qty_positive`. The same insert (qty 0, nothing damaged) is now refused by `_received_positive`. The assertion names the new constraint, with a comment: the behaviour is unchanged and only the constraint's name moved.
- **Migration probe:** a negative `qty` cannot be probed against `_qty_nonnegative` alone. Postgres tests CHECKs in name order, so the `applied_*` pair always fires first. This is noted in 0087.
- **Mutation check:** dropping the `qty > 0` guard on the terminal arm's over-receipt (R1) fails the new suite, and so does dropping the `− damaged` ATP term.
- **Web:** the Stock tab's Action column appears only when a listed row can be written off, so every other table is unchanged. The billing CSV export of receipt lines is also unchanged; the on-screen drill shows a Damaged column.
- **Verified:**
  - wms-be: the full `bun run test` (110 suites, 2798 tests), lint, typecheck, build, `db:migrate` + `db:verify`, and `db:generate` reporting "No schema changes".
  - wms-fe: `bun test` (2306), lint, typecheck, build, `check:capability-mirror`.
  - wms-mobile: `bun test` (799) and typecheck (the repo has no lint script).

## Spec Change Log

- **2026-10-22, code review CR1 (Blind Hunter, Edge Case Hunter ×4):** the RETURNS-precedent `damaged-bin-conflict` had no remedy. Retire keeps `bins_warehouse_id_code_unique`, codes cannot be renamed, and zones cannot be retired, so a pre-rule `DAMAGED` location blocked damaged receipts in its warehouse forever, while four texts (the 0087 notice, the problem detail, the mobile comment, the web guidance) advised a retire that does nothing. **Amended:** Code Map, migration bullet: 0087 re-codes collisions; the conflict text no longer advises a retire. **Known-bad state avoided:** an unresolvable 409 and a review row whose Apply always fails. **KEEP:** everything else in the implementation (commits wms-be `d12c77b`, wms-mobile `5aa3c25`, wms-fe `4660501`). Applied as a targeted patch, not a revert and re-derive: the amendment touches one migration block and three strings, and the rest of the code was verified (tests pass and the I/O matrix is covered). This was the recommended approach, taken autonomously.

## Review Triage Log

Design review, 2026-10-21 (three reviewers: receiving R, inventory I, clients C). Verdicts: **high**/**medium**/**low** = accepted and folded in above; **dup** = merged into another.

| ID | Verdict | Finding → resolution |
|---|---|---|
| R1 | high | A `qty 0` line on the terminal or re-target arms writes `excess_qty 0` → the CHECK fails with a 500. Over-receipt only when `qty > 0`; matrix row. |
| R2 | high | No `qty 0` outcome per settlement arm. Stated per arm; no unmatched entry. |
| R3 | high | Refused or rejected lines lose their damaged units. `rejectedLines` and the DTO carry the fields. |
| R4 | high | Review rows are built by three whitelisting builders, not `PAYLOAD_FIELDS`. Code Map retargeted. |
| R5 | medium | Old payloads reach validation without the keys. Normalised with `?? 0` / `?? null`; test. |
| R6 | medium | `?? undefined` keeps 0 → two hashes for one act. Hash only when > 0; a reason with 0 is a 400. |
| R7 | medium | Precision does not range-check. Explicit `>= 0`, max and `@IsIn`. |
| R8 | medium | Should damaged-only lines be refused? User decision 6. |
| R9 | medium | Response DTO minimums and descriptions go stale. Updated. |
| R10 | medium | The catch-weight check runs only on receivable lines. Moved over all lines after `loadSkus`. |
| R11 | medium | The billing drill shows 0/0, and storage billing is undecided. Drill gains damaged; decision 8. |
| R12 | low | The inactive-SKU flag misses damaged-only lines. `applied > 0 || damaged > 0`. |
| R13 | low | The `grn.damaged` loop key was unstated. Keyed `damaged > 0`, independent. |
| R14 | low | Re-targeted reference. The header's `po?.id` / `asnId`. |
| R15 | low | CHECK swap probes and schema comment. Added. |
| I1 | high | A pre-existing `DAMAGED` user code blocks receipts forever. Reserve on create, ensure only on damage, 0087 notice, named arms. |
| I2 | high | Serial damage can never be written off. Decision 9. |
| I3 | medium | FEFO write-off skips expired batches. Per-batch write-off with `overrideReason`. |
| I4 | medium | The metering table test breaks, and billing is undecided. `['to']`; decision 8. |
| I5 | medium | No line link on `grn.damaged`. Optional `grnLineId`. |
| I6 | dup | → R11. |
| I7 | low | The guard belongs in `assertAdjustableInTx`. Stated; approval test. |
| I8 | dup | → C13. |
| I9 | low | Stale system-bin lists. Listed. |
| I10 | dup | → C11. |
| I11 | low | Hazard mixing in DAMAGED. PENDING. |
| I12 | low | Quarantine overlap understates ATP. Design Notes. |
| I13 | low | Catch-weight workaround. PENDING. |
| C1 | high | The device drops or cannot confirm all-damaged lines. Filters use `qty + damaged`. |
| C2 | high | A scan switch overwrites an all-damaged line. Switch only when all are 0. |
| C3 | medium | A pack scan cannot be marked damaged. "Move to damaged" action. |
| C4 | dup | → I2. |
| C5 | medium | Write-off dialog details. Batch, note, key lifetime, error arms. |
| C6 | medium | The first web adjustment write. Capability-gated; 202 link; design doc. |
| C7 | dup | → R4, R12. |
| C8 | medium | The review queue shows "× 0". Three-part render. |
| C9 | medium | Rollback and a stale snapshot. Confirm blocker; rollback unsupported (PENDING). |
| C10 | medium | Damaged catch-weight has no device path. Decision 9, note copy, PENDING. |
| C11 | medium | Portal gaps. Decision 7, PENDING. |
| C12 | medium | Device warnings vs refusals. Decision 6; warnings match. |
| C13 | low | The timeline filter list. Both lists. |
| C14 | low | The Units column shows 0. "+N damaged". |
| C15 | low | No docs task. Added. |

Code review, 2026-10-22 (three layers: Blind Hunter BH, Edge Case Hunter EC, Verification Gap VG). Verdicts as above; the route follows each.

| ID | Verdict | Finding → resolution |
|---|---|---|
| CR1 = BH1, BH2, EC1, EC2, EC7, EC8 | high | Bad spec: a pre-rule `DAMAGED` zone or bin can never be cleared (retire keeps the unique key, codes cannot be renamed, zones cannot be retired), yet four texts advise a retire. Spec amended (Change Log): 0087 re-codes collisions; texts fixed; migration test. |
| BH3 | low, rejected | A wholly-missing invoice line cannot be shorted. Decided at design (Never list; PENDING "A short line with no arrivals cannot be recorded"). |
| BH4 + EC5 | medium | Patch: "Move to damaged" moves only the last scan's pack factor, from any SKU's scan, and Short steps ±1, so one crushed unit in a case of 12 cannot be recorded. Typed quantity entry for damaged and short (honouring precision), with the default factor keyed to the open line. |
| BH5 + VG3 + VG-other | low | Patch: the web QC-hold form filter misses system RETURNS and keys on code alone. Key on `binSystemOwned` + code {QC-HOLD, RETURNS, DAMAGED}; test. |
| BH6 | low | Patch: 0087 probes miss a negative `short_qty` and an accepted short-only line; the jest pin misses the short side. Added. |
| BH7 | low | Deferred: the CHECKs scan under ACCESS EXCLUSIVE. `NOT VALID` then `VALIDATE` is the 6.2 live-deploy work (the 0081 precedent). |
| BH8 | low, rejected | A fifth ATP query. A real but small cost; merging the system-bin terms into one grouped query is a refactor beyond this story. |
| BH9 | medium | Deferred: a write-off loses its GRN-line and vendor provenance. This is the vendor-claim / RTV path of 2.8. |
| BH10a | dup | → CR1 (conflict → Apply e2e is moot once the collision is unreachable). |
| BH10b | low | Patch: the lines route's 403 and foreign-tenant arm is untested. Test added. |
| BH10c + EC4 | medium | Patch: the rollback blocker lives only in `canConfirm`/`confirmBlocker`, with `snapshot` optional, and a refreshed seal that makes a SKU serial or catch-weight after damage was drafted queues a guaranteed 400. `confirmPayload` refuses both, and `canConfirm` blocks damage on serial or catch-weight per the snapshot; tests. |
| BH11 | low, rejected | Several pending write-offs can exceed DAMAGED on-hand. A later approval fails with `insufficient-on-hand` and nothing is lost; the adjustment pend flow behaves this way everywhere. |
| EC3 | low | Patch: DAMAGED was ensured from `lines` before settlement, so a rejected-only damaged line created the bin. Ensured after settlement from `settled`. |
| EC6 | low | Patch: the write-off banner and panel survive a warehouse switch. Reset on `warehouseId`. |
| VG1 | medium | Patch: the billing drill's `damagedQty` is untested on BE and web. Tests added. |
| VG2 | medium | Patch: licence-refused damage through Apply, and the `po-line-not-found` rejected entry carrying damage, are untested. Tests added. |
