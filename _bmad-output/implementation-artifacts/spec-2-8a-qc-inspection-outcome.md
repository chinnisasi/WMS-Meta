---
title: '2-8a QC inspection outcome — inspect a QC hold per batch: passed units release, failed units move to DAMAGED with a reason; the hold closes as inspected'
type: 'feature'
created: '2026-10-22'
baseline_commit: 'd700a52c0fe4e87da3eeaa679d3e5661660033f3'  # wms-be (feat/3-2b tip, stacked on 5-1a — 0089/0090; rebase onto main after WMS-BE #125 and the 3-2b BE PR merge); wms-fe: 2e145dbbfd433c377e3791471a9d9ac3cf4c84b4; wms-mobile: 9c9d6d6a5141d1a89b936e064d68ce003fe5b52d
status: 'in-review'
route: 'dispatch'
review_loop_iteration: 0
context:
  - 'docs/initiatives/production-readiness.md'
  - 'docs/design/SYSTEM-DESIGN.md'
  - 'docs/design/IMPLEMENTATION-GUIDE.md'
  - 'docs/design/modules/inbound.md'
  - 'docs/design/modules/inventory.md'
  - 'docs/design/PENDING.md'
  - 'docs/design/frontend/SYSTEM-DESIGN.md'
  - '_bmad-output/implementation-artifacts/spec-1-2b-client-receiving-policy.md'
  - '_bmad-output/implementation-artifacts/spec-2-4a-damaged-and-short-receipt-quantities.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** A QC hold (manual, or automatic on receipt under 1-2b) can only be released whole. A failed inspection is a two-step runbook: release, then write off or move by adjustment (1-2b decision 7, PENDING:121, `inbound.md:629`). This puts failed goods back into available stock for a moment, leaves no record of the inspection result, and records no fail reason for the vendor claim.

**Approach:**
- A new **inspect** verb on an open hold records, for every batch arm the hold moved, the passed and the failed quantity (summing to that arm's held quantity), with a fail reason.
- In one transaction, passed units go back exactly as a release does (origin bin; Receiving for a receipt hold), failed units move QC-HOLD → DAMAGED under a new ledger type `qc.failed`, and the hold closes with status `inspected`.
- DAMAGED's existing rules then apply (ATP-excluded, write-off only), and so will 2-8b's return to vendor.
- BE + web (the QC desk, as in 1-2b). One additive migration, so the code waits for the migration chain.

**Decisions (recommended, taken autonomously):**
1. **Split.** 2-8a = the inspection outcome. **2-8b** = the return-to-vendor document (a new outbound document type drawing from DAMAGED for both QC-fail and 2-4a receipt damage, with the vendor snapshot and the RTV fee decision). 2-8b is recorded in deferred-work. Serial-tracked and catch-weight lines are never QC-held (PENDING:122), so they are out.
2. **Surface.** Web only, on the existing `/inbound?tab=qc-holds` card; the handheld has no QC surface (1-2b precedent). This is not a layer split: the user goal (the QC desk inspects) is complete without the device.
3. **Whole-hold inspection.** Per arm, `passed + failed` must equal the arm's held quantity exactly (fractional per AD-9, compared at the SKU's precision). There is no partial inspection with a remainder still held, and plain release stays as it is. "All passed" is equivalent to a release but records the inspection.
4. **Capability.** `qc.manage` (owner, ops_manager), the same as release. No new capability.
5. **Fail reasons:** `damaged`, `expired`, `contaminated`, `wrong-item`, `spec-failure`, `other`. `other` requires the note. A note (≤ 500) is optional otherwise. Reasons apply only to arms with `failed > 0`.
6. **Ledger.** The new type `qc.failed` is a relocation QC-HOLD → DAMAGED on the same batch arm. It goes in the registry with `grnLineId` (receipt holds) and `holdId` in its reference. Its metering shape is `['both']`: a relocation, so storage continues, as with DAMAGED today. Passed units reuse `qc.released` with the passed quantity. No new fee: the QC fail is billed like any held stock (PENDING:101 precedent).
7. **Data (migration, next free number at code time):**
   - `qc_holds_status_check` becomes ('open','released','inspected'). The release pairing generalises: a non-open row has `released_by`/`released_at` (read as "closed by/at").
   - New `qc_inspections`: id, tenant, hold_id (UNIQUE), inspected_by, inspected_at, note.
   - New `qc_inspection_lines`: inspection_id, batch_id (nullable for untracked), held_quantity, passed_quantity, failed_quantity, fail_reason. CHECKs: quantities ≥ 0, passed + failed = held, reason present ⇔ failed > 0, reason in the vocabulary.
   - Both new tables get the tenant RLS policy (guide §3 checklist). There is no FK, by repo convention.
8. **Command guard order.** This is `releaseHold`'s order plus validation:
   1. `qc.manage`
   2. idempotency replay
   3. body shape (one line per held arm, no extras, no duplicates)
   4. hold `FOR UPDATE`: 404, or 409 `qc-hold-released` when it is not open
   5. held arms read (`qcHeldArmsInTx`); 422 `qc-inspection-mismatch` when the lines do not cover exactly those arms and quantities
   6. when passed > 0: origin bin locked, 409 `qc-hold-origin-bin-gone`, then the secure gate
   7. DAMAGED ensured (`ensureDamagedBinInTx`)
   8. ledger arms (`qc.released` for passed, `qc.failed` for failed)
   9. a conditional UPDATE to `inspected`
   10. inspection rows
   11. outbox `qc_hold.inspected` with totals; for a receipt hold, also the existing `qc_hold.receipt_cleared`
   12. audit `qc_hold.inspected`

   The fingerprint covers holdId, lines sorted by batch id (null first) and the note.
9. **Reads.**
   - `GET …/qc-holds/:holdId` (new) returns the hold, its held arms (batch code, expiry, quantity) and, when inspected, the inspection with its lines.
   - The list gains an `inspected` status filter value and a `failedQuantity` total for inspected rows.
   - Batch codes are read through the facade, not by a cross-module join.
10. **Web.**
    - An **Inspect** action on open holds opens a dialog listing each arm with its held quantity, Passed defaulting to the full amount, Failed computed, and a reason select when Failed > 0. The summary line reads "N pass, M fail → DAMAGED".
    - Inspected holds show their result.
    - It is gated on `qc.manage`, and the client is regenerated.

**Design-review amendments (A1–A13).** Where they differ from the decisions above, these override them. Recommended, taken autonomously.
- **A1 — Putaway and KPI terms.**
  - A receipt line's putaway quantity subtracts open receipt-hold quantities (`putaway.command.ts:372-374,1954,1982`; `reporting/kpis.ts:368-374`).
  - Add a third term: minus Σ failed units of the line's **inspected** receipt holds (from `qc_inspection_lines` through `qc_holds.grn_line_id`).
  - Apply it in all three places and amend guide §7f.
  - The test covers a second, unheld line of the same SKU and batch in Receiving.
  - "As with release" holds for passed units only.
- **A2 — Notifications.**
  - `qc_hold.inspected` resolves the `qc-hold` source for manual holds (`notification-sources.ts:540-548`), carrying `kind` so receipt holds stay on `qc-receipt`.
  - `SOURCE_RESOLUTIONS['qc-hold']` and `['qc-receipt']` gain `'inspected'`. A receipt cleared by inspection resolves as `inspected`.
  - Update the FE resolved labels and tests.
- **A3 — Every status consumer.**
  - BE: `QC_HOLD_STATUSES` tuple, `QcHoldSnapshot.status` (`qc.command.ts:132`), `qc.facade.ts:38,63`, `qc.dto.ts:58,126-129`.
  - FE:
    - hand-written types: `lib/api/client.ts:2919`, `lib/use-inbound.ts:620,644,664`;
    - `inbound-cards.tsx`: tabs at `:775` become Open / Closed, with Closed covering released and inspected; the status column at `:960` branches on all three states, and actions appear on open holds only;
    - `lib/excursion.ts:75` `holdLabel`.
  - Excursion holds are manual holds, so inspection applies to them (the outcome after an excursion). The excursion row itself is untouched.
- **A4 — Data model (replaces decision 7's tables).**
  - `qc_inspections`: id, tenant_id, hold_id UNIQUE, note.
    - Who inspected and when is the hold's `released_by`/`released_at`, which is the single authority; the inspection row carries no copy.
  - `qc_inspection_lines`: id, tenant_id, inspection_id, batch_id NULL, outcome ('passed'|'failed'), fail_reason NULL, quantity `bigint` milli-units > 0.
    - One row per (batch, outcome, reason), so mixed reasons per batch are allowed. This answers B "one reason per arm".
    - UNIQUE NULLS NOT DISTINCT (inspection_id, batch_id, outcome, fail_reason).
    - CHECK `(outcome='passed' AND fail_reason IS NULL) OR (outcome='failed' AND fail_reason IS NOT NULL AND fail_reason IN (…))`.
    - The sum per batch equals the held arm; the command enforces it and a test pins it.
  - Both tables get the 0014-shape tenant RLS policy, a `wms_rls_probe` test each, and entries in the suite cleanup lists.
  - Quantities go through `assertRecordableQuantity` after the SKU read.
  - `QC_FAIL_REASONS` and `QC_HOLD_STATUSES` tuples are pinned against their CHECKs (the `QC_HOLD_KINDS` precedent).
- **A5 — Request body and tiers.**
  - Body: `{ lines: [{ batchId|null, passed, failed: [{ reason, quantity }] }], note? }`. Held quantities are never sent.
  - DTO tier, above the transaction:
    - no duplicate batchId;
    - no duplicate reason within a batch;
    - reason in the vocabulary;
    - `other` needs the note;
    - note ≤ 500, trimmed, blank = absent.
  - Behind the replay lookup: the precision refusal, and 422 `qc-inspection-mismatch` against the held arms.
  - The fingerprint covers tenantId, holdId, the lines sorted by batch id (null first) with failures sorted by reason, quantities as sent, and the normalised note.
  - The response and snapshot are `{ qcHold, inspection }`. Outbox totals are in base units (`fromMilli`).
- **A6 — Guard order (replaces decision 8, steps 4–7):**
  1. lock the hold `FOR UPDATE` (404)
  2. **replay again**
  3. status check: 409 `qc-hold-released`, its wording changed to "already closed (released|inspected)"; the code is kept, which is the only change to release
  4. arms match
  5. when passed > 0: origin `FOR UPDATE`, gone check, secure gate
  6. `ensureQcHoldBinInTx`
  7. when failed > 0: `ensureDamagedBinInTx`, 409 `damaged-bin-conflict`

  Lock order: hold → origin → QC-HOLD → DAMAGED. A same-key race test uses `raceTwice` + `waitParked`.
- **A7 — Ledger reference.**
  - `qc.failed` uses `referenceKinds: ['qc-hold']`.
  - The `qc-hold` arm gains optional `grnLineId` and `inspectionId`, omitted when absent, never null (guide §4), so existing hashes are unchanged.
  - Update the timeline DTO's `grnLineId` description, the FE `lib/drill.ts:64-104` type list and labels ("QC failed"), and the metering `SHAPES` row.
- **A8 — Audit.** `{ action: 'qc_hold.inspected', targetType: 'qc_hold' }` is added to `AUDIT_NEW_ACTIONS` and pinned by `expectAuditRow`, including after a replay.
- **A9 — Document credit.**
  - Failed units stay credited on the GRN/PO/ASN line: they were received. This differs from 2-4a damage, which credits nothing.
  - 2-8b reads `qc.failed` (with `grnLineId`) to tell credited DAMAGED units apart.
  - The `damaged-bin-write-off-only` detail wording becomes "units received damaged or failed at QC".
- **A10 — Floor and UX.**
  - The dialog shows each batch's expiry and warns (never blocks) when passing an expired batch.
  - The physical move to DAMAGED or the origin is not tasked, which is the same gap as release; recorded in PENDING.
  - `wrong-item` lands in DAMAGED for now, and a SKU correction is a later story (PENDING).
- **A11 — Recorded, not built (PENDING inbound/QC):**
  - an inspection correction verb (today's runbook: write off in DAMAGED + a positive adjustment at the origin, both audited);
  - sampling/AQL fields (sample size, defects found, standard);
  - evidence attachments (the file-storage story);
  - partial inspection and remainder holds;
  - other outcomes (rework, concession, extend);
  - a batch-wide block on a failed batch (roadmap 3.3, the batch block verb);
  - a performed-by or inspection date distinct from the closer;
  - the client portal view of outcomes (2.9);
  - a vendor link for manual holds (2-8b).
- **A12 — Fixed references.** The release core is at `qc.command.ts:823-980`. Drop the PENDING:101 billing citation; there is no QC fee and no precedent is claimed.
- **A13 — Acceptance criteria added:**
  - putaway after a mixed inspection with a second same-batch line;
  - notification resolution (manual and receipt);
  - the closed-tab display;
  - RLS probes;
  - the same-key race;
  - audit after a replay;
  - mixed reasons in one batch;
  - an expired-batch warning in the dialog.

## Boundaries & Constraints

**Always:**
- One transaction for the whole command.
- Held arms are the source of truth: never trust client-sent held quantities beyond matching them.
- A receipt hold's passed units return to Receiving, so they become putaway work again, as with release.
- DAMAGED stock from QC fail is indistinguishable in rules from 2-4a damage. Only the ledger type and the reason tell them apart.

**Never:**
- No return-to-vendor document (2-8b).
- No partial inspection or remainder holds.
- No handheld change.
- No change to release or release-receipt.
- No client notification (5.1/2.9).
- No serial or catch-weight QC.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected | Error handling |
|---|---|---|---|
| All pass | Every arm passed = held | Units back to origin/Receiving; hold `inspected`; inspection rows | — |
| Mixed | Arm A 8 pass / 2 fail `damaged` | 8 `qc.released`, 2 `qc.failed` → DAMAGED; ATP excludes the 2 | — |
| All fail | passed 0 everywhere | Nothing to origin (no origin-bin check); all to DAMAGED | — |
| Mismatch | Sum ≠ held, a missing arm, or an extra batch | 422 `qc-inspection-mismatch` | Nothing written |
| Reason missing | failed > 0 with no reason, or `other` with no note | 400 validation | — |
| Already closed | Hold released or inspected | 409 `qc-hold-released` | — |
| Origin gone | Passed > 0 and the origin bin is retired | 409 `qc-hold-origin-bin-gone` | All-fail still succeeds |
| Replay | Same key + body | The original response | Same key, different body → 422 `idempotency-key-reuse` |
| Write-off after | A DAMAGED arm from QC fail | The 2-4a write-off works unchanged | — |

</frozen-after-approval>

## Code Map

- `wms-be/src/modules/inbound/qc.command.ts`:
  - `releaseHold` (`:646`) and its release core (`:864-963`) are the template; reuse `qcHeldArmsInTx` and the secure gate.
  - `holdScopeInTx` (`:319`) for the arm semantics.
  - Comment `:223` and `inbound.md:629` update.
- `wms-be/src/api/receiving.controller.ts:447-562`: add `POST …/qc-holds/:holdId/inspect` and `GET …/qc-holds/:holdId`; widen the list filter.
- `wms-be/src/modules/tenancy/receiving-bin.ts:418` `ensureDamagedBinInTx`.
- `wms-be/src/modules/inventory/ledger-registry.ts` (`:87` grn.damaged precedent): register `qc.failed`. Add `test/metering.spec.ts:629-647` shapes.
- `wms-be/src/shared/db/schema.ts:2762` and `drizzle/`: the migration (the CHECK drop/re-add per the 0078 precedent, with probes; the two new tables with RLS).
- `wms-be/test/`: the qc spec (every matrix row, ATP after a mixed inspection, write-off after) and the metering spec. Regenerate OpenAPI.
- `wms-fe/src/components/inbound/inbound-cards.tsx:780-1061` `QcHoldsCard`: the Inspect action and dialog, and the inspected display. Regenerate the client and add tests.
- Meta docs (after code): `inbound.md` (the inspect flow sequence diagram, invariants), API-SURFACE, the FE design, PENDING (close :121 and the decision-7 deferral; repoint RTV to 2-8b), both contracts.

## Tasks & Acceptance

**Execution:**
- [x] BE: the migration + schema; the `qc.failed` registry entry; the inspect command; the detail and list reads; routes and DTOs; tests; OpenAPI.
- [x] FE: the Inspect dialog and the inspected result; client regen; tests.
- [x] Meta docs, as in the Code Map.

**Acceptance Criteria:**
- Given a receipt hold of 10 units on batch B, when inspected as 7 pass / 3 fail `damaged`, then Receiving +7, DAMAGED +3, QC-HOLD 0, ATP excludes the 3, and the hold reads `inspected` with one inspection line.
- Given the migration, when it runs over existing `open`/`released` rows, then every probe passes and the existing rows are untouched.
- Given the metering fold, then `qc.failed` contributes 0 to storage relocation, as `qc.held` does.

## Verification

**Commands:**
- `cd workspace/core/backend/wms-be && bun run lint && bun run typecheck && bun run test` — expected: all pass (one jest run at a time).
- `cd workspace/core/frontend/wms-fe && bun run test && bun run lint && bun run typecheck && bun run build` — expected: all pass (the drift guard after the BE merges).

## Implementation Notes

Implemented 2026-10-23 (uncommitted, on `feat/2-8a-qc-inspection-outcome` in wms-be and wms-fe, `docs/2-8a-qc-inspection-outcome` here).

- **Branches.** wms-be stays on the baseline (`d700a52`, the 3-2b tip — 0089/0090 unmerged); the migration is **0091**. wms-fe was reset (it had no commits) onto `feat/3-2b-handheld-stock-adjustment` (`cf01884`), because the regenerated client from this BE carries 3-2b's nullable threshold and main's FE would not compile against it. Both rebase onto `main` once WMS-BE #125 / the 3-2b PRs merge.
- **BE.** `drizzle/0091_qc_inspection.sql` (+ snapshot, journal): fail-fast guard, the two tables, `qc_holds_status_check` / `qc_holds_release_pairing` dropped and re-added, the line CHECKs, RLS on both tables, the probe block. `qc.command.ts`: `QC_HOLD_STATUSES`, `QC_FAIL_REASONS`, `QC_INSPECTION_OUTCOMES`, `normaliseInspection` (the shape tier), `inspectHold` (A6's order), `lockOriginBinInTx` (extracted unchanged from the release core), `emitReceiptClearedInTx(…, 'inspected')`, the release's 409 wording. `qc.facade.ts`: `inspectHold`, `getQcHold`, the list's `inspected`/`closed` filter and `failedQuantity` (shared `entriesInTx`). `ledger-registry.ts`: `qc.failed`; the `qc-hold` arm's optional `grnLineId` / `inspectionId`. Putaway (`failedReceiptQtyByLine`, `failedReceiptQtyOfLineInTx`) and `kpis.ts`: §7f's third term. Notifications: `qc_hold.inspected` resolves `qc-hold`; `receipt_cleared` reads `resolution`; both sources gain `inspected`. Audit: `qc_hold.inspected`. `damaged-bin-write-off-only` wording. DTOs, controller routes, OpenAPI.
- **BE tests.** `test/qc-inspection.spec.ts` (13: the AC with a second unheld same-batch line, putaway/tile/placement bound, ledger reference bytes, notifications, audit + replay, list/detail; all-pass manual; mixed reasons across two batches; all-fail past a retired origin vs the 409 when passing; four mismatch shapes with nothing written; the 400 shapes, precision and 403; fractional kg; receipt placement cleared by a release after an inspection; the same-key race — mutation-checked by deleting the second replay, which fails with `409 qc-hold-released`; tuples vs CHECKs; RLS probes for both tables; decoders; OpenAPI paths). `test/qc-inspection-migration.spec.ts` (0091 over an open manual, a released and an open receipt hold — rows byte-identical, an inspected close admitted, the guard refuses a re-run). `test/metering.spec.ts` SHAPES `qc.failed: ['both']`. The two new tables joined the cleanup lists of the eight suites that delete `qc_holds`.
- **FE.** `lib/qc-inspection.ts` (+ test), `components/inbound/qc-inspect-dialog.tsx`, `inbound-cards.tsx` (Open/Closed tabs, the three-state status cell, Inspect), `lib/api/client.ts` (`fetchApiGetQcHold`, `fetchApiInspectQcHold`, the widened filter), `lib/use-inbound.ts` (`QcHoldStatusFilter`), `lib/excursion.ts` (`holdLabel`), `lib/drill.ts` (`qc.failed` → "QC failed"), `lib/over-receipt.ts` (`qcReason`), the regenerated client; tests in `inbound-cards.test.tsx`, `over-receipt.test.ts`, `notifications.test.ts`, `excursion.test.ts`.

## Spec Change Log

- **The list's `closed` filter value (added at implementation).** A3 makes the web's tabs Open / Closed with Closed covering released AND inspected; decision 9 only named `inspected`. A single-status filter cannot page a two-status tab, so `status` also takes `closed` (= `status <> 'open'`, on the existing `(tenant_id, status, created_at, id)` index). Additive.
- **AC 1's "one inspection line" reads as A4's rows.** Under A4 an arm with 7 passed and 3 failed is two rows (`passed 7`, `failed damaged 3`); the test asserts exactly those.
- **The 0091 pairing names no status list** (code review): `("status" = 'open') = (released_by IS NULL AND released_at IS NULL) AND (released_by IS NULL) = (released_at IS NULL)` — the second conjunct keeps 0014's "a closed row carries BOTH" (the first alone would admit half a closer; probed). The unknown-status probe is now refused by `qc_holds_status_check`.
- **Code review fixes:** a placement's `receipt_cleared` resolves `inspected` when ANY of its holds was inspected (not the last closer); `qc_hold.inspected` carries `lines [{batchId, outcome, reason, quantity (string)}]`; an inspected hold with no inspection row, no lines or no closer is `500 data-fault` (logged) on the detail and the list; the web dialog keeps one key per draft, treats `409 qc-hold-released` as closed elsewhere (close + reload), disables the hold's Release while open, is `aria-modal` with initial focus, Escape and focus return, says when the session expired or the hold has no held stock, and warns on an expired batch by the server's instant rule (expired from the IST midnight that begins its expiry day).
- **`inspectionId` rides the inspection's `qc.released` events too** (A7 added the key to the arm without saying which types carry it); `grnLineId` rides `qc.failed` only, as A9 needs. Both omitted when absent.
- **Fingerprint:** no `arm:` discriminator — A5's field list is followed exactly; the body (lines + note) cannot collide with release's `{tenantId, holdId}`.

## Review Triage Log

Design review, 2026-10-22 (D). Two layers: a claims check against the code (K) and a blind reviewer (B). Choices are recommended, taken autonomously.

| ID | Src | Verdict | Finding → resolution |
|---|---|---|---|
| D1 | K | high | Putaway and the KPI subtract only open-hold quantities, so failed units become putaway work. → A1 |
| D2 | K | high | The manual-hold notification never resolves on inspect. → A2 |
| D3 | K,B | high | Code treats non-open as released (FE tabs and actions, the excursion label, DTO enums). → A3 |
| D4 | K,B | high | The lines table lacks tenant_id/id; milli bigint; NULL uniqueness; the CHECK trap; duplicate inspected_by. → A4 |
| D5 | K | high | Lock and status combined; a same-key waiter gets 409. → A6 |
| D6 | K | medium | Unconditional DAMAGED ensure; a missing 409 arm. → A6 |
| D7 | K | medium | `qc.failed` reference shape unspecified. → A7 |
| D8 | K | medium | FE drill.ts ledger labels, metering SHAPES. → A7 |
| D9 | K | medium | Audit action not registered. → A8 |
| D10 | K | medium | No status or reason tuples. → A4 |
| D11 | K,B | medium | Body shape in the wrong tier; fingerprint canonical form; response shape. → A5 |
| D12 | K | medium | PO/ASN credit of failed units; excursion holds; wrong-item in DAMAGED. → A9, A3, A10 |
| D13 | K,B | low | The 409 wording says "released". → A6 (wording only) |
| D14 | K | low | Stale references. → A12 |
| D15 | B | medium | Mixed defects in one batch. → A4 (rows per batch, outcome and reason) |
| D16 | B | medium | No correction for a wrong inspection. → A11 (runbook + PENDING) |
| D17 | B | low | Sampling/AQL, evidence, re-inspection, other outcomes, partial inspection. → A11 |
| D18 | B | medium | A failed batch stays pickable elsewhere. → A11 (3.3 batch block) |
| D19 | B | — | Held arms can drift under concurrency. → R: adjustments, counts, moves and transfers all refuse system bins (K verified); lock order stated in A6 |
| D20 | B | low | Portal visibility; vendor link on manual holds. → A11 |
| D21 | B | low | Inspector vs closer, inspection date. → A11 |
| D22 | B | low | Expired batch passed silently. → A10 (warn) |
| D23 | B | low | Physical move not tasked. → A10 |
| D24 | B | medium | Thin ACs. → A13 |
| D25 | K | — | Side finding: origin/main fails tsc (registers bin-move). → Already fixed by WMS-BE #122 (open); not this story |

Code review, 2026-10-23 (Blind Hunter BH, Edge Case Hunter EC, Verification Gap VG). Routing per step-04; all choices recommended, taken autonomously. Migration 0091 proven on a copy of the dev database (21 holds: 18 open, 3 released): rolled back, applied by `db:migrate:deploy`, re-run a no-op, holds intact, both new tables under tenant RLS (a foreign tenant sees no rows). Re-proven after C6.

| ID | Source | Verdict | Finding → route |
|---|---|---|---|
| C1 | BH2, EC1 | medium | The dialog mints a new idempotency key per click; a retry after a lost response gets 409 "already closed", shown as an error, and the list is never reloaded. → patch: one key per dialog draft (useRef, re-minted when the draft changes); a 409 `qc-hold-released` closes the dialog and reloads the list. |
| C2 | BH5, EC5, EC6 | medium | An `inspected` hold with no inspection row (or null closer columns) reads as `inspection: null` / "0 fail" — a broken invariant reported as clean data. → patch: the read throws an integrity error (500, logged) instead. |
| C3 | BH4 | medium | A receipt placement's cleared notification takes the LAST closer's resolution, so mixed placements mislabel. → patch: resolution is `inspected` when any hold of the placement was inspected, else `released`; tests for both orders. |
| C4 | BH7, VG2 | medium | The §7f failed-units subquery is copied three times (`failedReceiptQtyByLine`, `failedReceiptQtyOfLineInTx`, `kpis.ts`) and the tile's term is untested (an all-fail line is not exercised). → patch: one mixed fixture (all-fail line beside an unheld line of the same SKU/batch, two inspected holds on one line, an over-receipt hold, a released hold) pinning the task list, the placement limit and the tile to the same answer. |
| C5 | VG1 | medium | `status=closed` is tested only with an inspected hold. → patch: released + inspected appear, open does not. |
| C6 | BH6 | low | The widened `qc_holds_release_pairing` repeats the status list, so the status CHECK is never reached by the probe and each new status must be added twice. → patch: pairing = `(status = 'open') = (released_by IS NULL AND released_at IS NULL)`; the unknown-status probe then hits `qc_holds_status_check`. |
| C7 | BH9 | medium | No e2e for `409 damaged-bin-conflict`, the 12-3 secure-origin gate on passed units, `GET …/qc-holds/{id}` 404 (unknown / other tenant), malformed `holdId` 400 on both routes, an `other` failure with a note, or an over-receipt receipt hold through the failed-units and cleared paths. → patch. |
| C8 | BH10, VG-other | low | The test titled "release one, inspect the other → resolved inspected" runs the opposite order. → patch: both orders as two tests (with C3). |
| C9 | BH11 | low | The `qc_hold.inspected` outbox payload carries only totals; 2-8b needs per-batch outcome and reason. → patch: add `lines[{batchId, outcome, reason, quantity}]`. |
| C10 | BH3 | low | Release stays clickable while that hold's Inspect dialog is open. → patch: disable it. |
| C11 | EC2, EC3 | low | A null session leaves the dialog loading forever; an empty-arms detail submits `lines: []` for an unexplained 400. → patch: explicit messages. |
| C12 | EC7 | low | The pass-expired warning compares `expiryDate < today`; on the expiry day it does not warn. → patch: match the server's `isBatchExpiredAt` boundary exactly (verify which). |
| C13 | BH12 | low | The dialog lacks `aria-modal`, initial focus, focus return and Escape. → patch. |
| C14 | VG3 | low | The two new `qcReason` codes are untested. → patch (two assertions). |
| C15 | BH1 | low | The web offers one fail reason per batch; mixed reasons are API-only. → defer (deferred-work; documented in the wms-fe contract). |
| C16 | BH8 | low | The change log's claim that `status=closed` uses the existing index is unproven. The fix edits this build's spec. → reject (fine at QC-hold volume). |
| C17 | EC4 | low | A hold with > 500 arms could never be inspected (DTO `ArrayMaxSize(500)`). Arms are batches in one hold; > 500 is not a real case. → reject. |
| C18 | EC8, EC9, VG-other | low | Spec text (A6 lock chain, AC's "one inspection line", release 409 wording vs the Never list) differs from the code. Fixes edit this build's spec. → reject (Implementation Notes record the actual behaviour). |
