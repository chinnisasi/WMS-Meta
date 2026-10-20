---
title: '1-6d licence enforcement — opt-in blocking of uncovered drug and food receipts and orders'
type: 'feature'
created: '2026-10-20'
status: 'in-progress'
baseline_commit: 'd45de08847b9b80f0da69b5e0c9f72b3958732f0'  # wms-be; wms-fe: 028440719443f873c39b21a8417fb587a91d5bfc; wms-mobile: f81fd3adc208dc4f472c1738d5e7ff0f140e9f28
route: 'dispatch'
review_loop_iteration: 0
context:
  - 'docs/initiatives/production-readiness.md'
  - 'docs/design/SYSTEM-DESIGN.md'
  - 'docs/design/IMPLEMENTATION-GUIDE.md'
  - 'docs/design/modules/compliance.md'
  - 'docs/design/modules/inbound.md'
  - 'docs/design/modules/outbound.md'
  - 'docs/design/modules/channels.md'
  - 'docs/design/modules/tenancy.md'
  - 'docs/design/frontend/IMPLEMENTATION-GUIDE.md'
  - 'docs/design/mobile/IMPLEMENTATION-GUIDE.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** Story 1-6c records drug and FSSAI licences and shows the coverage gaps, but nothing stops the warehouse from receiving or shipping a client's scheduled drugs or food without a valid licence.

**Approach:**
- Add a per-tenant **Enforce licences** switch. It is off by default and owner-only.
- While it is on, a receipt line or an order of drug or food goods is refused unless 1-6c's coverage rule holds on the operation's IST date. The rule needs a valid client licence (for that site or for no site) **and** a valid site licence of a covering kind. The `self` client needs the site licence only.

**Decisions (user, 2026-10-20):**
1. **Opt-in per tenant.**
   - Warnings (1-6c) work regardless.
   - Turning enforcement on while coverage gaps exist requires a confirmation that names the gap count.
   - Turning it off is always allowed.
2. **Missing or expired licences both block.**
3. **Receipts: a refused line goes to a waivable review row.**
   - A `grn.submit` line (web, handheld or replay) whose SKU is not covered is refused per line as `licence-not-covered` and is not booked.
   - The receipt raises one review row, `grn.licence-refused`. An **owner** may **Apply** it with a required note, which waives the check, books the lines and is audited as `goods_receipt.licence_waived` (the 1-2b shelf-life precedent). **Discard** drops it.
4. **Orders are refused outright.** Order create answers 409 `licence-not-covered`, naming each SKU, its missing need and the holder. A kit is checked through its components.
5. **Not blocked:** dispatch of accepted orders, transfers, ASN, PO and returns.
6. **The handheld only rewords the outcome.** The settled `grn.submit` note says a refused line is held for licence review. The snapshot is unchanged and there is no warning at scan.

**Decisions (agent):**
7. **Policy row.** `licence_policies` (`tenant_id` unique, `enforce`, `updated_by`, `updated_at`) follows the `expiry_alert_policies` precedent. A missing row means off.
   - `GET …/licence-policy` returns `{enforce, gapCount}`. It is open to staff; a portal session gets 403.
   - `PUT …/licence-policy {enforce, acknowledgeGaps?}` requires `licences.manage`.
     - Turning on with gaps and without `acknowledgeGaps: true` → 409 `licence-gaps-unacknowledged`, with `gapCount` in the problem extensions.
     - Audit `licence.enforcement_changed`, target type `licence_policy`.
     - An unchanged PUT is a no-op that stores its key.
8. **One coverage check.** `licenceCoverageInTx(tx, {tenantId, warehouseId, date, parties: {clientId, systemOwned, skuCode, needs}[]})` is an exported free function in compliance, built on 1-6c's primitives. It returns the uncovered `{skuCode, clientId, need, holder}` items, in a stable order.
   - `licenceEnforcedInTx(tx, tenantId)` reads the switch.
   - Receiving and orders import these as free functions, never the Nest module, because a module import would cycle.
   - Licences are read without a lock (the 1-2b policy stance; PENDING).
9. **Receipt mechanics.**
   - **Placement.** The licence phase runs **after** the whole-op shape checks: kit 409 (`:799`), catch-weight (`:817`) and precision (`:845`). It runs before the batch ensure, and it removes its lines from the receivable set. A malformed line therefore still fails the whole op as today, and a licence-refused line has passed every shape check, so its Apply cannot fail on shape. A kit SKU is never received (the kit 409 answers first).
   - **Skip set.** The phase skips every line already refused, client or expiry (`new Set(clientRefused.map(e => e.index))` computed after the expiry push at `:774`). One line is never in two rows.
   - **Judgement.** Each line is judged by its SKU's client and the receipt's warehouse, on `istDateOf(occurredAt)`. This is the 1-2b shelf-life precedent: a receipt is judged when it happened.
     - A late replay of a scan made while the licence was valid is booked.
     - A scan made before a licence's `validFrom` is refused and waivable.
     - Device-clock trust goes to PENDING.
   - **Refused entries.** Each is the full `RejectedGrnLine`: `{poLineId, asnLineId?, skuId, qty, code: 'licence-not-covered', reason, index, missing: [{need, holder}]}`.
     - `reason` reads `SKU "X" needs <kind label> (client | site "W1")`.
     - `missing` is a new optional DTO field.
   - **The review row.** `raiseRefusalReviewsInTx` partitions three ways: `shelf-life-short` → shelf-life row; `licence-not-covered` → `grn.licence-refused`; the rest → `grn.lines-refused`.
     - **Op id and problem code:** the licence row's op id is salted from the key with `:grn-licence-refused`, and its `problemCode` is `licence-not-covered`.
     - **Payload:** the 1-2b shape. Its `lines` keep `poLineId` and `asnLineId`, and each `refusals[]` entry carries `missing` and `skuClientId`.
     - **Client:** the first refused line's.
     - **Response:** `licenceReviewOpId` on the GRN snapshot and on `refusedReceipt`, optional and present only when raised.
     - **Audit target:** `firstRejectedOpId` covers a licence-only receipt.
   - **The waiver.**
     - A re-execution carries `licenceWaiver {byUserId, note}`, hashed as `licenceWaived: true` only when present (`?? undefined`, the `:564` precedent). It skips the licence phase only.
     - **No loop:** a row raised **during a waived re-execution** stores the waivers already granted in its payload as `waivers: {shelfLife?: {byUserId, note}}`, and its Apply passes all of them. A short-dated, uncovered line therefore books after one shelf-life Apply and one licence Apply.
   - **Enforcement off.** The phase is skipped and the response is byte-identical to before.
10. **Order mechanics.**
    - **Placement:** an early check in phase 1 after the client gate (~:626), before any grant, then a re-check in phase 3 after the guard (~:779). A throw there releases grants.
    - **Inputs:** every SKU in `preflight.skuFacts` is checked: each line SKU, a kit parent and its components. Phase 1 reads `foodCategory` and `drugSchedules`. Phase 3 re-reads them with the locked statuses (`lockSkuStatusesInTx`), so an edit in between is caught. One IST today is captured at the start of the command and used in both phases.
    - **A mixed order is refused whole.** Lines with no grant (backorders) are checked too.
    - **The 409:** the detail lists sorted `SKU — needs <kind> (client | site "<code>")` lines; the extensions carry `skuCodes`.
    - **Channel ingest:** maps it to a typed 422 with code `licence-not-covered` and `skuCodes`, metered `validation-failed`, following the `ingestSkuInactive` precedent. This deliberately stops retries; the merchant resends once the licence is fixed. An operator-visible list of refused ingests goes to PENDING.
11. **The review queue.** `grn.licence-refused` joins `REJECTED_OP_TYPES`, `SERVER_RAISED_ONLY_OP_TYPES`, the decisions table (`apply`, `discard`), the payload-shape table, the apply switch and `SKU_NAMING_OP_TYPES`.
    - Apply requires a note (400).
    - Apply requires `licences.manage` on top of `review.decide`, so an ops manager gets 403 `role-denied`.
      - **Where:** after the row is locked and `decision-not-available` is checked, and before the note check, so an ops manager without a note gets 403, not 400.
      - **After replay:** a replayed Apply re-serves its stored answer. This is a deliberate exception to fail-closed.
    - Discard keeps `review.decide`.
    - Apply and Discard behave the same whether enforcement is on or off: the row records a refusal that already happened.
12. **The policy PUT.**
    - **Hash and order:** it hashes `{tenantId, enforce}`; `acknowledgeGaps` is a precondition, not part of the hash. Steps: `licences.manage`, replay, lock the row, unchanged → no-op (no audit, in `AUDIT_NO_OP_ARMS`), then the gap check, then the write.
    - **`gapCount`:** an in-transaction variant of 1-6c's `coverageGaps`, counted in the same unit as the gaps list.
    - **Lower bound:** the count is a lower bound. A blind receipt or a backordered order of goods with no stock or open document anywhere is refused without having been a gap, so the copy says "known gaps".

## Boundaries & Constraints

**Always:**
- **Migration 0085:**
  - `licence_policies`, with RLS on the tenant arm;
  - fail-fast and a probe (unique tenant, `enforce` NOT NULL).

  Commit the snapshot and journal entry; `db:generate` must report no changes.
- **Vocabularies and pins:**
  - `REJECTED_GRN_LINE_CODES`, `LineRefusalCode` and the DTO enum (`receiving.dto.ts:283`) gain `licence-not-covered`;
  - the exact-list pins at `test/client-receiving-policy.spec.ts:926, 931` and `test/client-master.spec.ts:412` are updated;
  - `AUDIT_TARGET_TYPES` gains `licence_policy`;
  - the audit actions `licence.enforcement_changed` and `goods_receipt.licence_waived` are added, also in `AUDIT_NEW_ACTIONS` (`audit.ts:121`);
  - an architecture pin keeps `compliance/licence-enforcement.ts` importing only `drizzle-orm` and `shared/`;
  - `licenceFacts` moves to `shared/primitives/licence.ts`.
- **Tests:**
  - `test/licence-enforcement.spec.ts`: every matrix row;
  - the channel-ingest row in its own suite;
  - `openapi:export` committed.
- **Web:**
  - **Licences tab:** an **Enforce licences** section above the gaps.
    - Staff see its state read-only; the on/off action is owner-only, through `ConfirmRow`.
    - It reads the policy GET through a hook that `notifyLicencesChanged` refreshes, and N comes from its `gapCount`.
    - Turning it on with known gaps confirms with `Turn on with N known coverage gaps? Uncovered receipts, including goods on open POs and ASNs, will go to review, and orders will be refused.` and sends `acknowledgeGaps: true`.
    - On a 409 `licence-gaps-unacknowledged`, the `ConfirmRow` `detail` hook opens a fresh row keyed `enforce-on-${gapCount}` that asks the question and sends the acknowledgement.
  - **Review queue (`lib/review-queue.ts`, `rejected-ops-queue.tsx`):** one waiver-copy table keyed by the two waivable op types.
    - **Entries:** note label, blank-note message, button, outcome word, fallback and ending, heading, failure word.
    - **Shelf-life:** its values are copied out unchanged.
    - **Licence:** label `Why accept goods without a valid licence?`, heading `Lines in licence review`, outcome `Accepted anyway` with the ending `— licence waived`.
    - **Signature change:** `acceptAnywayNote(entry, text)`.
    - **Summary:** `rejectedOpSummary` covers the new type, and the summary helper is renamed with identical shelf-life output.
    - **Refusal label:** `GRN_REFUSAL_LABEL['licence-not-covered']` (`no valid licence`) lists each `missing` need and holder.
    - **Apply visibility:** `canApply = canDecide && (opType !== 'grn.licence-refused' || roleHasCapability(role, 'licences.manage'))`. A non-owner sees Discard and `An owner can accept these`, and this type's 403 shows the server detail.
    - **Pins:** `review-queue.test.ts:627` and `rejected-ops-queue.test.tsx:519–571` stay unchanged, proving the shelf-life bytes. The key-list pin `review-queue.test.ts:472–484` gains the code.
  - **Order form:** `createReason` maps `licence-not-covered` to the server detail, whose lines are separated by `; `, with a fallback naming `skuCodes`.
  - Run `api:generate`.
- **Mobile (`src/state/replay-classification.ts`):**
  - **Naming:** `licenceRefusalWords(line, skuIdentityOf)` names each licence line, e.g. `RICE-5KG: no valid licence (FSSAI — site) — in licence review`. It reads `missing` defensively; when `missing` is absent it says just `no valid licence`.
  - **Placement:** it is used by both the partial and the all-refused composers, after the expiry phrases. These lines are excluded from the generic bucket.
  - **Types only:** `src/api.ts` gains `missing?` on `GrnRejectedLine` and `licenceReviewOpId?` on `GrnRefusedReceipt`. No runtime parsing changes.
  - **Pin:** one mixed receipt (client mismatch + shelf-life + licence + `po-line-not-found`). Every other arm is unchanged.

**Never:**
- No blocking of dispatch, transfers, ASN, PO or returns.
- No snapshot change and no scan-time warning on the handheld.
- No per-client or per-site switch.
- No grace period after expiry.
- No portal access.
- No change to 1-6c's coverage rule or warnings.

## I/O & Edge-Case Matrix

Enforcement is on unless stated. Client C, site W1. Receipt IST date is 2026-11-01.

| Scenario | Input / State | Expected | Error |
|---|---|---|---|
| Off | no licences; food receipt and order | booked and created, byte-identical to before | N/A |
| Partly covered SKU | an `H` + `NDPS` SKU; both hold `drug-20b`, neither `ndps` | refused, `missing [{ndps, client}, {ndps, site}]` | `licence-not-covered` |
| Blind into an empty site | gapCount 0; a blind food receipt into a site holding nothing | refused | `licence-not-covered` |
| Late replay | scanned 2026-10-30 while licensed; licence expired 2026-10-31; synced 11-01 | booked | N/A |
| Before validFrom | scanned 2026-10-30; licence from 2026-10-31 | refused, waivable | `licence-not-covered` |
| Catch-weight line | an uncovered catch-weight food line with bad weights | the whole op is refused on shape, as today | 400 |
| Covered | C and W1 hold a valid FSSAI; rice receipt | booked | N/A |
| Site missing | C covered, W1 not | line refused, `missing [{fssai, site}]`, `grn.licence-refused` raised, `licenceReviewOpId` set | `licence-not-covered` |
| Client premises | C's FSSAI is for W2 only | refused, `{fssai, client}` | same |
| Expired / future | C's licence until 2026-10-31, or from 2026-11-02 | refused | same |
| Self | self food; W1 holds FSSAI | booked | N/A |
| Mixed receipt | rice (uncovered) + t-shirt | rice refused, t-shirt booked | N/A |
| All refused | only rice | `goodsReceipt: null`, `refusedReceipt.licenceReviewOpId` | N/A |
| Shelf-life first | a short-dated uncovered line | shelf-life row only; its Apply raises a licence row whose payload stores the shelf-life waiver | N/A |
| No loop | then the licence row's Apply | booked once, one GRN, no new shelf-life row | N/A |
| Departed meanwhile | the client departs between the refusal and the Apply | Apply settles `client-departed` per line; no licence row | N/A |
| Waiver | owner Applies with a note | lines booked; audit `goods_receipt.licence_waived` | N/A |
| Waiver retry | the same Apply twice | one GRN | N/A |
| Waiver, no note | Apply without a note | refused | 400 |
| Waiver, ops | ops_manager Applies, with or without a note | refused | 403 `role-denied` |
| Apply while off | an open licence row after enforcement is turned off | Apply still needs the owner and a note | N/A |
| Discard | ops_manager Discards | dropped | N/A |
| Handheld | a device op refused at replay | settled note says held for licence review | N/A |
| Order | an `H` drug; W1 lacks `drug-20b` | nothing created, no grants left | 409 `licence-not-covered` |
| Order kit | a kit whose component is food; C uncovered | refused | 409 |
| Mixed order | one covered line, one uncovered | the whole order is refused, no grants left | 409 |
| Backordered line | an uncovered line with no stock | refused | 409 |
| Channel order | ingest of an uncovered order | typed 422, metered `validation-failed`, not retried | 422 |
| Turn on with gaps | PUT `{enforce: true}` | refused, `gapCount` | 409 `licence-gaps-unacknowledged` |
| Turn on, acknowledged | with `acknowledgeGaps: true` | 200, audited | N/A |
| Turn off | PUT `{enforce: false}` | 200, audited | N/A |
| Switch, not owner | ops_manager PUT | refused | 403 `role-denied` |

</frozen-after-approval>

## Code Map

All backend paths are under `workspace/core/backend/wms-be/`.

- **Receipt** (`inbound/receiving.command.ts`):
  - hash `:537–586` (`shelfLifeWaived` precedent `:564`);
  - phases `:703–792`: departed `:736`, policies `:759`, expiry refusals `:766–775`, receivable lines `:789`;
  - all-refused `:866–912`;
  - expiry race `:1050–1085`;
  - `REJECTED_GRN_LINE_CODES` `:206`, `LineRefusalCode` `:229`, `LINES_REFUSED_CODE_PRECEDENCE` `:257`, `RejectedGrnLine` `:276`;
  - `clientRefusalLines` `:2483`, `raiseRefusalReviewsInTx` `:2533–2666`, `shelfLifeRefusedOpId` `:2718`;
  - snapshot fields `:1662`;
  - waiver audit `:1748–1761`.

  Also `receiving.dto.ts:283`.
- **Review queue** (`tenancy/sync-report.command.ts`):
  - type union `:97–106`;
  - `REJECTED_OP_TYPES` `:108`, `SERVER_RAISED_ONLY_OP_TYPES` `:126`;
  - decisions `:169`, `ApplicableOpType` `:179`, payload shapes `:352`;
  - `review.decide` `:1008`, note required `:1080`;
  - apply arm `:1388–1411`, exhaustive switch `:1516`.

  Also `client-wind-down.ts:21` (`SKU_NAMING_OP_TYPES`), `api/rejected-ops.dto.ts:37`, and `tenancy/permissions.ts:296, 332`.
- **Orders:**
  - `outbound/order.command.ts`: phase 1 `:401–639` (SKU facts `:1626`, kits `:522–572`, client gate `:626`), phase 3 `:767–806` (guard `:779`);
  - `catalog/sku-status.ts:24` (the multi-SKU 409 precedent);
  - `outbound.facade.ts:454`, `api/outbound.controller.ts:108`.
- **Channels:** `channels/channels.ingest.command.ts:228, 353–416` (`mapIngestRejection`; an unmapped code is rethrown and retried); `channels.errors.ts:242` (`ingestSkuInactive`).
- **Compliance (1-6c):**
  - `shared/primitives/licence.ts:143` (`needsOf`), `:166`, `:178`, `:194`;
  - `compliance/licence.facade.ts:166–277` (`coverageGaps` rules: self, departed), `:463` (`licenceFacts`, private, to export);
  - `compliance.module.ts:44` (forwardRef Inbound/Outbound; no module import back).
- **Policy precedent:** `drizzle/0049_expiry_alerts.sql:62–95`, `schema.ts:4422`, `replenishment.command.ts:~980–1055`, `replenishment.controller.ts:318, 349`.
- **Web** (`workspace/core/frontend/wms-fe/src/`):
  - `components/conflicts/rejected-ops-queue.tsx:128, 154–200, 301–480, 432–468`;
  - `lib/review-queue.ts:394, 427, 453, 502, 544, 595–603, 639–715`;
  - `components/compliance/licences.tsx:72, 107–127, 203–215`;
  - `lib/licences.ts:240`, `lib/use-licences.ts:11`;
  - `components/settings/confirm-row.tsx:36`;
  - `lib/outbound-orders.ts:336–376`;
  - the toggle precedent `compliance/eway-bills.tsx:721–742`.
- **Mobile** (`workspace/core/mobile/wms-mobile/`): `src/state/replay-classification.ts:328, 351, 458–466, 491, 528–541` and its test.

## Tasks & Acceptance

**Execution:**
- [x] `wms-be drizzle/0085_licence_policies.sql` + schema + meta -- the policy table, RLS, probe -- decision 7
- [x] `wms-be compliance/licence-enforcement.ts` (free functions) + the policy command and routes in `licences.controller.ts` -- the switch, the coverage check -- decisions 1, 7, 8
- [x] `wms-be inbound/receiving.command.ts`, `receiving.dto.ts` -- the licence phase, the review row, the waiver -- decisions 3, 9
- [x] `wms-be tenancy/sync-report.command.ts`, `client-wind-down.ts`, `rejected-ops.dto.ts` -- the review type, the owner-only Apply -- decisions 3, 11
- [x] `wms-be outbound/order.command.ts`, `channels/channels.ingest.command.ts`, `channels.errors.ts` -- the order gate, the ingest mapping -- decisions 4, 10
- [x] `wms-be test/licence-enforcement.spec.ts` + the pins + `openapi.json` -- every matrix row
- [x] `wms-fe` the switch section, the review-queue generalisation, the order reason, regenerated types, tests
- [x] `wms-mobile` the settled-note licence arm (+ test)
- [x] meta `docs/design/modules/{compliance,inbound,outbound,channels,tenancy}.md`, `docs/design/{frontend,mobile}/IMPLEMENTATION-GUIDE.md` (the review queue; the named licence phrase at mobile `:135`), `API-SURFACE.md`, `PENDING.md`, `docs/repos/wms-be/README.md`, `docs/repos/wms-fe/README.md:53`, `docs/repos/wms-mobile/README.md:89`
  - PENDING entries: licence reads unlocked; device-clock trust; the scan-time warning; dispatch, transfer and returns gaps; refused channel ingests not listed for operators

**Acceptance Criteria:**
- Given enforcement off, when any receipt or order runs, then its response is byte-identical to before.
- Given enforcement on and a site lacking FSSAI, when a handheld receipt of rice and t-shirts syncs, then the t-shirts are booked, the rice is held in `grn.licence-refused`, the device note says so, and an owner's Apply with a note books the rice.

## Implementation Notes

Implemented 2026-10-20 against this spec. Choices the spec left open, or where the code differs from its wording:

- **`coverageGapsInTx` lives in `compliance/licence-coverage.ts`.** The policy command counts gaps. If it imported `licence.facade.ts`, which injects the policy command, the two files would import each other. The facade re-exports the types and the function.
- **`licenceClock` / `licenceToday` moved to `licence-enforcement.ts`.** `licence.command.ts` re-exports the same object, so tests that assign `licenceClock.now` keep working. The order create captures its one IST date from this clock.
- **The licence row's payload has no `clientId` for the first refused line.** In that payload `clientId` means the blind receipt's named client, and Apply carries it through. Putting another client there would turn a PO receipt's Apply into a 400. Instead, the row's client is shown through `clientLabel` (the first refused line's), and each entry in `refusals[]` carries its own `skuClientId`.
- **A line with several missing needs** gets one `needs …` phrase per need, joined with `; `.
- **`LockedSkuStatus`** gains `foodCategory` and `drugSchedules`. These come from the same locked read that phase 3 re-checks.
- **Two first-ever PUTs that race** would both insert a row. The tenant unique index refuses the second, and it answers 409 `conflict`.
- **The licence note label** is the spec's exact text, `Why accept goods without a valid licence?`, without the shelf-life label's "(required)".
- **Departed meanwhile** is staged with a direct status update in the test. The open licence row blocks a departure through the API (the wind-down rule).

## Spec Change Log

## Review Triage Log

**Design review, 2026-10-20.** Three reviewers: backend (B1–B11), edge cases and operations (E1–E12), web, handheld and contracts (F1–F9). 32 raw findings, 24 after merging duplicates. None needed the user: every choice had a code precedent. All are patched above or sent to PENDING. Re-checked by hand: the shelf-life apply arm passes only its own waiver (`sync-report.command.ts:1388–1411`), so all three reviewers' loop finding is real.

- D1 high (B1, E1, F1): a short-dated, uncovered line loops between the two rows forever. Fix: a row raised during a waived re-run stores the waivers already granted, and its Apply passes all of them; matrix rows added.
- D2 high (B2): reusing `alreadyRefused` puts a shelf-life line in the licence row too. Fix: the skip set is computed after the expiry push.
- D3 high (E2, B10): licence-refused lines skipped the kit, catch-weight and precision checks, so their Apply could fail. Fix: the phase runs after the shape checks.
- D4 med (B3, E3): the review-row partition could crash or misfile. Fix: an explicit three-way split, `licenceReviewOpId`, the audit target.
- D5 med (B4, F2): the entry shape missed required fields, and `missing` never reached the row. Fix: the full shape, optional DTO fields, `missing` in `refusals[]`.
- D6 med (B5, F4): where the owner check sits; the web couldn't know who may Apply. Fix: placement stated; `canApply` and the copy.
- D7 med (B6, E5): device time decides. Fix: the 1-2b precedent made explicit, two matrix rows, PENDING.
- D8 med (B7): the policy PUT's hash and order. Fix: decision 12.
- D9 med (B8, E4): the gap count understates what will be refused. Fix: "known gaps" and the lower-bound note; matrix row.
- D10 med (E6): refused channel orders are invisible. Fix: the wire code kept; deliberate no-retry; PENDING.
- D11 med (E7): mixed, partly covered and backordered orders weren't shown. Fix: matrix rows.
- D12 med (F3): the shelf-life copy is hard-coded in more places than listed. Fix: one copy table; shelf-life pins kept.
- D13 med (F5): the switch's 409 path could not be passed. Fix: the `detail` hook opens a fresh, re-keyed row; `gapCount` from the policy GET.
- D14 med (F6): the handheld note broke the per-line naming rule and used the quarantine word. Fix: named per line, "in licence review", placement stated, a mixed pin.
- D15 low (E8): enforcement off with open rows. Fix: Apply unchanged (decision 11).
- D16 low (E9): a licence row can mix clients. Fix: the row's client is the first refused line's, and lines carry `skuClientId`.
- D17 low (E10, B9): kit parents and a stale phase-3 read. Fix: every SKU checked; phase 3 re-reads the goods attributes.
- D18 low (E11): two IST dates around midnight. Fix: one captured today.
- D19 low (E12): a client departs before the Apply. Fix: matrix row.
- D20 low (B11): the audit pins, the architecture pin, the `licenceFacts` home. Fix: named.
- D21 low (F7): a web key-list pin. Fix: named.
- D22 low (F8): docs missing from the task. Fix: added.
- D23 low (F9): the 409 detail format. Fix: the `; ` separator and a fallback.
- D24 info (B: idempotency, imports, grant release, ingest, `op_type` with no CHECK): verified correct, no change.

## Design Notes

- **Why the switch refuses unacknowledged gaps on the server.** The confirm lives in the web. A direct API call, or a second tab with stale gaps, would otherwise switch enforcement on blind, and the next receipt would surprise the floor.
- **Why free functions, not the facade.** Compliance already forward-references inbound and outbound, and tenancy imports compliance. A Nest import from receiving or orders back into compliance would close the cycle; the 1-6c precedent is direct reads.
- **Why the licence phase follows shelf life.** A line that is short-dated and uncovered needs two decisions, and an owner should see the expiry problem first. One line is never in two rows, and waiving shelf life cannot skip the licence check.

## Verification

**Commands:**
- `cd workspace/core/backend/wms-be && bun run db:migrate && bun run db:generate` -- expected: 0085's probe passes; no changes
- `bun run lint && bun run typecheck && bun run test` (one jest run at a time; rerun a known load flake alone) -- expected: green
- `cd workspace/core/frontend/wms-fe && bun run api:generate && bun run lint && bun run typecheck && bun run test` -- expected: green
- `cd workspace/core/mobile/wms-mobile && bun run typecheck && bun run test` -- expected: green
