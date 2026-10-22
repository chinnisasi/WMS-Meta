---
title: '3-2b handheld stock adjustment — a stock.adjust device op on the existing adjust route; operators request (always pended for approval), holders adjust under the threshold; review-queue apply arm'
type: 'feature'
created: '2026-10-22'
status: 'ready-for-dev'
route: 'dispatch'
review_loop_iteration: 0
context:
  - 'docs/initiatives/production-readiness.md'
  - 'docs/design/SYSTEM-DESIGN.md'
  - 'docs/design/IMPLEMENTATION-GUIDE.md'
  - 'docs/design/modules/inventory.md'
  - 'docs/design/PENDING.md'
  - 'docs/design/mobile/SYSTEM-DESIGN.md'
  - 'docs/design/frontend/SYSTEM-DESIGN.md'
  - '_bmad-output/implementation-artifacts/spec-3-2a-web-stock-adjustment.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** Stock adjustments are web-only (`POST :tenantId/inventory/adjustments`, `TenantSessionGuard`; 3-2a gave it a web form). A floor operator who finds a damaged, missing or extra unit in a bin must walk to a desk. Operators also do not hold `stock.adjust`, so even a handheld route would refuse them (deferred from 3-2a).

**Approach:**
- The adjust route gains a device arm (`AnySessionGuard`, badge-in operator, `occurredAt`), the way 3-1 `stock.move` did.
- A new capability `stock.adjust.request` (operator) lets a holder submit an adjustment that is **always pended** for approval. Holders of `stock.adjust` keep today's threshold rule on either surface.
- The handheld gets an offline-queued Adjust screen. The review queue can apply a rejected `stock.adjust` op.
- No DB migration.

**Decisions (recommended, taken autonomously):**
1. **Role.** Operators get `stock.adjust.request`, not `stock.adjust`. Owners hold everything; ops_manager keeps `stock.adjust`.
   - Holding `stock.adjust` → the existing rule: |delta| > threshold pends, otherwise applies.
   - Holding only `stock.adjust.request` → always pends.
   - Holding neither → 403 as today.
   - Approval stays `adjustments.approve` (owner only, unchanged; widening it is not this story). Capabilities 48 → 49: the FE mirror and `check:capability-mirror`.
2. **Pend reason.** The 202 body gains an additive field `pendReason: 'threshold' | 'approval-required'`. Nothing is stored for it: on reads it is derived as `approval-required` when |delta| ≤ `thresholdQuantityAtRequest`. No column, so no migration. The pend list and detail expose it too, and the web approval view shows "Requested from handheld (approval required)".
3. **One route, two surfaces.** `POST :tenantId/inventory/adjustments` switches to `AnySessionGuard` with `@ApiBearerAuth()` and `@ApiBearerAuth('device')`.
   - On the device: `userId === null` → `badgeInRequired()`; actor = badge-in user; `deviceId` from the session; `assertDeviceOperatorInTx` before the capability check (move order, `move.command.ts:288-292`).
   - `occurredAt` is required on the device and stays optional on the web (an existing contract, kept).
   - The 3-2a web form is unchanged.
4. **Fingerprint.** `surface` and `deviceId` join the adjust fingerprint **only on the device** (the only-when-present rule). The web hash inputs and goldens stay byte-identical; a golden test pins both.
5. **Composition seam.** `composeBatchSerialArms` (`inventory.controller.ts:401-557`) moves out of the controller into an api-layer provider, `AdjustmentComposer` (`src/api/adjustment-composer.ts`), which the controller uses.
   - The review-queue apply arm in tenancy (`sync-report.command.ts` `applyArm`) cannot import the api layer or catalog. It reaches the composer through a port: a DI token `ADJUSTMENT_COMPOSER` in `src/shared/`, provided by the api module. This is the same inversion the licence seam uses.
   - FEFO, override and serial/batch rules are unchanged. Live and replayed adjustments share one implementation.
6. **Device op.** Op type `stock.adjust` is added to every sync-report list: `RejectedOpType`, `REJECTED_OP_TYPES`, `REJECTED_OP_DECISIONS_BY_TYPE` (`['apply','discard']`), `ApplicableOpType`, `PAYLOAD_FIELDS`, the `applyArm` switch, and `SKU_NAMING_OP_TYPES`.
   - An applied rejected op runs the same command as the original actor's surface. The deciding user's capabilities are checked as they are for `stock.move`.
   - `rejected_ops.op_type` is free text (0047), so no migration.
7. **Snapshot.** The device catalogue snapshot gains `adjustReasons` (`ADJUSTMENT_REASON_CODES` with labels), served next to `moveReasons` (`receiving.controller.ts:272`). The handheld shows Adjust only when the snapshot carries it.
8. **Handheld screen.** `app/adjust.tsx`, modelled on `app/move.tsx`:
   - scan bin → scan SKU/barcode → signed quantity (Add / Remove toggle, positive entry) → reason → note (required, 1–500);
   - batch SKUs: Add requires a batch code; Remove leaves the batch empty, so the server takes FEFO, or the operator scans a batch with an override reason;
   - serial SKUs: scan exactly |quantity| serials;
   - HU arms, kits and catch-weight are not offered; the server refuses them anyway.
   - The ULID is minted at confirm, then `enqueueOp`, then `replay()`.
9. **Device outcome.** A 202 settles as `settled`, with the `settledNote` "Sent for approval" (precedent: replay-classification.ts:753). There is no new `SendResult` kind and the banner stays four-state. Refusals are classified in a new `ADJUST_REPLANNABLE_CODES` / `ADJUST_REJECTED_CODES` / `classifyAdjustRefusal` set, mirroring move.
10. **FE.** The capability mirror goes to 49. The review queue gets a `stock.adjust` arm (payload summary + Apply/Discard). The pending-adjustment approval view shows `pendReason` and the device. The client is regenerated.

**Design-review amendments (A1–A14).** Where they differ from the decisions above, these override them. Recommended, taken autonomously.
- **A1 — Migration (replaces "No DB migration").**
  - A forced pend cannot be stored today: `threshold_quantity_at_request` is NOT NULL (0044:53), but a tenant may have no policy. Nothing records the device either.
  - The migration is additive, numbered next after main at code time (after BE #123's 0088 and 5-1a's 0089). It changes `stock_adjustment_pendings`:
    - `pend_reason text NOT NULL DEFAULT 'threshold'`, with a CHECK in ('threshold','approval-required');
    - `source_device_id uuid NULL` (no FK, guide §3);
    - `threshold_quantity_at_request` drops NOT NULL (null = no policy at request). The existing `>= 0` CHECK still holds for non-null values.
  - Existing rows backfill to `threshold` through the default. That is correct: every existing pend has |delta| > its stored threshold.
  - The table is small, and the migration builds no index.
  - **The code waits** for the predecessor migrations to merge. `pendReason` is stored, never derived (this supersedes decision 2's derivation). The pend list returns `pendReason` and `sourceDeviceId`.
- **A2 — One submission service (replaces decision 5).**
  - The whole controller body after the session check moves into `AdjustmentSubmission` in tenancy, exported. Tenancy already imports `CatalogFacade` and `InventoryFacade` (`tenancy.module.ts`, `tenancy.service.ts:691`, `sync-report.command.ts:44`).
  - What moves: `normalizeArms`, `untrackedSku`, the SKU read, the capability + replay pre-check, `composeBatchSerialArms`, `resolveFefoBatch`, `assertBatchCoversDraw`, `assertBatchInstant`, and the `adjustStock` call.
  - There is no DI token and no `src/shared` port; the "licence seam" claim was wrong. The controller and the sync-report apply arm both call it, and the architecture spec must stay green.
  - On the device, the device/operator check (`device-operator.ts`) runs **before** composition, so a revoked device never mints batch/serial identity.
  - The controller's tracked-arm check accepts `stock.adjust` OR `stock.adjust.request`.
- **A3 — Review apply re-runs as the original operator** (the `stock.move` precedent, `sync-report.command.ts:1644-1666`).
  - An operator-originated op therefore always re-pends. The rejected op is marked applied, with its outcome snapshot holding the `pendingAdjustment`.
  - The FE review queue renders that outcome as "Sent for approval".
  - The resolver needs `review.decide`; approving the resulting pend still needs `adjustments.approve`.
- **A4 — Replay versus a changed role.**
  - Replaying a stored 201 (applied) requires `stock.adjust`, so a demoted actor gets 403, as today (`ledger.spec.ts:443-461`).
  - Replaying a stored 202 requires either capability.
  - A fresh request is judged by the actor's role when the server receives it.
- **A5 — The fate table, replacing the matrix's error arms.**
  - Device `unauthenticated` (401, `badgeInRequired`) → `unreachable` (the op stays queued, badge-in needed).
  - `operator-mismatch` → `quarantined`.
  - **No replannable codes**: the device cannot re-plan without on-hand data. Every other refusal → `rejected` (review): `insufficient-on-hand`, `serial-elsewhere`, `duplicate-serial`, `bin-retired`, `qc-bin-not-adjustable`, `returns-bin-not-adjustable`, `damaged-bin-write-off-only`, `kit-cannot-hold-stock`, `client-departed`, `not-found`, `role-denied`, `validation-failed`, `conflict`, `idempotency-key-reuse` (422).
  - Settled notes: 201 → "Adjusted"; 202 (the body has `pendingAdjustment`) → "Sent for approval". `request()` hides the status, so the sender branches on the body. There is no 202 precedent on mobile; :753 is wording only.
- **A6 — Capability grants.**
  - Operator gets `stock.adjust.request`. ops_manager gets it too, in the BE's explicit list, because the FE derives ops_manager as "all minus excluded". Owner holds everything.
  - In the cage and floor lists it follows `stock.move`.
  - Secure, cage and dedicated bins: the owner's approval is the containment for request-only holders. PENDING:171 is updated to say so.
- **A7 — `pendReason` on stored replays.** The DTO field is optional. A replayed 202 snapshot from before 3-2b is served with `pendReason: 'threshold'`, filled in at the controller edge (guide §9 idempotency checklist). There is no pend detail route; only the list carries it.
- **A8 — Golden first.** Task 1 captures today's web adjust fingerprint for each 3-2a fixture from origin/main and pins it, before `fingerprint()` changes. Device hashes add `surface` and `deviceId` (and `occurredAt`, which is required there). They are only-when-present, so web hashes are byte-identical.
- **A9 — Snapshot vocabulary.**
  - Labels go in `adjustment-reason.ts` (`ADJUSTMENT_REASON_LABELS`), served by an inventory facade method into `CatalogSnapshotResponse.adjustReasons`. Update the consumption-map comment.
  - Mobile `parseCatalogSnapshot` defaults to `[]` for older seals (the `moveReasonsOf` precedent), and the Adjust entry is hidden when the list is empty.
- **A10 — Device eligibility mirrors 3-2a's `adjustOffered`.**
  - Offline, system bins (RECEIVING, DAMAGED, QC-HOLD, IN-TRANSIT, RETURNS), retired bins, kits and catch-weight are not offered.
  - Quantities follow `uomPrecision`.
  - A new batch code on Add captures the optional expiry and manufacture dates, as on the web.
  - FEFO runs against the server clock when the request is received, and approval applies the composed arms with today's re-checks.
  - A confirm step shows the signed delta, bin, SKU and batch before enqueue.
- **A11 — The web surface.**
  - The 3-2a form still gates on `stock.adjust`, so operators don't see it. An operator calling the API from the web is force-pended, which is accepted.
  - The FE pend queue copy changes from "exceeded the threshold" to the two reasons, and the queue shows the source device.
  - The FE code branches from main after FE #108 merges.
- **A12 — Every list and test that changes:**
  - **Mobile:** the rejected-op `opType` union `api.ts:270-286`, `settledNote`, classifier dispatch `:146`, `OpType`, the sender switch.
  - **BE:** `REJECTED_OP_TYPES` feeds the OpenAPI enum (`rejected-ops.dto.ts:36,127`). The guard swap adds `device` security and changes the 401 detail.
  - **BE tests:** `ledger.spec.ts:433-441` (operator → 202, not 403) and `:443-461` (A4), `users.spec.ts:914` (49), `portal.spec.ts:747` (anyRoutes 5), `return-receipts.spec.ts:910-919`, `batch-serial.spec.ts:934` (use a role without either capability), and the cage invariant `users.spec.ts:828-840`.
  - **FE:** `users.test.ts` lists.
- **A13 — Device bookkeeping.** `touchDeviceInTx` runs on the device arm. `deviceId` is persisted on the pend (`source_device_id`), not in audit; `audit_events` has no metadata column.
- **A14 — Recorded, not built (PENDING, inventory):**
  - a cumulative or velocity limit against splitting under the threshold;
  - segregation of duties (approver ≠ requester);
  - stale-delta detection (on-hand at `occurredAt` against now);
  - requester notification and an on-device "my pending requests" list (PENDING:463 widened);
  - withdraw and TTL for pends (PENDING:31);
  - photo evidence for Remove (the file-storage story);
  - a badge-in idle timeout.

## Boundaries & Constraints

**Always:**
- The guard order matches move on the device:
  1. own tenant
  2. idempotency key
  3. badge-in
  4. operator match
  5. capability (`stock.adjust` or `stock.adjust.request`)
  6. replay
  7. `assertAdjustableInTx`
  8. the threshold / forced-pend branch.
- Audit and outbox events are unchanged (`stock_adjustment.pending_approval`, `stock.adjusted`); the actor is the badge-in user, and `deviceId` is in the audit metadata.
- The 3-2a vocabulary and rules are honoured unchanged: reasons, strict-greater threshold, FEFO/override, batch/serial, excluded bin classes.

**Never:**
- No DB migration beyond A1.
- No change to who approves.
- Operators are never granted `stock.adjust`.
- No new `SendResult` kind.
- No device-side FEFO preview (the snapshot has no on-hand).
- The requester is not notified of the decision (PENDING:463 stays).

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected | Error handling |
|---|---|---|---|
| Operator, small | Device, operator, \|delta\| ≤ threshold | 202 `pendReason: approval-required`; device settles "Sent for approval" | — |
| Operator, large | \|delta\| > threshold | 202 `pendReason: threshold` | — |
| Manager on device | ops_manager badge-in, \|delta\| ≤ threshold | 201 applied; ledger `stock.adjusted` | — |
| No badge-in | Device session, `userId` null | 401/409 `badge-in-required` (move's arm) | Replan |
| Operator mismatch | `X-Op-Operator` ≠ badge-in | 409 `operator-mismatch` | Rejected → review |
| No occurredAt | Device without `occurredAt` | 400 | Rejected |
| Replay | Same key + same body | The original 201/202 snapshot | — |
| Key reuse | Same key, different body | 409 idempotency conflict | Rejected |
| FEFO remove | Batch SKU, Remove, no batch | The server draws FEFO (oldest non-expired) | Not enough non-expired stock → the existing arm |
| Serial count | Serial SKU, serials ≠ \|delta\| | 400, the existing arm | Rejected |
| Review apply | Owner applies a rejected `stock.adjust` | Runs through the composer port; the same outcome rules | Refusal stays in review |
| Web unchanged | 3-2a form post | Identical response and fingerprint | — |

</frozen-after-approval>

## Code Map

- `wms-be/src/api/inventory.controller.ts:87-200` — the adjust route: guard swap, device arm, composer use. `:401-557` `composeBatchSerialArms` and `:581` `resolveFefoBatch` move to `src/api/adjustment-composer.ts`.
- `wms-be/src/api/movements.controller.ts:254-319` — the template for the AnySessionGuard device arm (badge-in, deviceId).
- `wms-be/src/modules/inventory/inventory.command.ts` — `:261` fingerprint (add surface/deviceId only-when-present), `:344` `adjust`, `:433` the permission check (accept `stock.adjust.request` → forced pend), `:504-597` the threshold branch (forced pend + `pendReason`). Reuse `applyAdjustmentInTx` (`:862`) and `assertAdjustableInTx` (`:697`).
- `wms-be/src/modules/movements/move.command.ts:219-292` — the occurredAt/fingerprint/device-operator pattern to mirror.
- `wms-be/src/modules/inventory/adjustment-approval.command.ts` and the pend reads — expose the derived `pendReason`.
- `wms-be/src/modules/tenancy/permissions.ts:14-327,347-440` — add `stock.adjust.request` and grant it to operator.
- `wms-be/src/modules/tenancy/sync-report.command.ts:124-1677` — the op-type lists and the `applyArm` case through the `ADJUSTMENT_COMPOSER` port; `tenancy/client-wind-down.ts:22`.
- `wms-be/src/api/receiving.controller.ts:272` — `adjustReasons` in the snapshot.
- `wms-be/test/` — extend the adjust spec (device arm, forced pend, fingerprint golden for web + device), `adjustment-approval.spec` (pendReason), and the sync-report apply spec. Regenerate OpenAPI.
- `wms-mobile`:
  - `app/move.tsx` is the template for `app/adjust.tsx`;
  - `src/moves/draft.ts` is the template for `src/adjust/draft.ts`;
  - `src/offline/types.ts:48` `OpType`;
  - `src/state/op-dispatch.ts:123-275` (sender);
  - `src/api.ts:1360-1407` (fetch + payload), `:1891` (snapshot type);
  - `src/state/replay-classification.ts:54-310` (codes, classifier, settledNote);
  - the inbox entry (`app/inbox.tsx:381`).
  - Tests: `bun test`, modelled on `draft.test.ts` and `replay-classification-moves.test.ts`.
- `wms-fe`:
  - `src/lib/users.ts` (capability mirror 49);
  - `review-queue.ts:484,713` (the `stock.adjust` arm);
  - the pending-adjustment approval view (pendReason + device);
  - regenerated `src/lib/api/generated`.

## Tasks & Acceptance

**Execution:**
- [ ] BE: the composer extraction and port; the route device arm; command capability/forced-pend/fingerprint; pendReason on 202 and on reads; the permission; sync-report op type and apply arm; snapshot `adjustReasons`; tests; OpenAPI regen.
- [ ] Mobile: the adjust draft (payload with explicit nulls), sender, classifier, screen, inbox entry; tests.
- [ ] FE: capability mirror, review-queue arm, approval-view pendReason; regenerated client; tests.
- [ ] Meta docs (after code): inventory module (device arm, forced pend, composer seam), the mobile fate table, API-SURFACE, the FE design, PENDING, both interface contracts; IMPLEMENTATION-GUIDE if a new pattern emerges.

**Acceptance Criteria:**
- Given the web adjust request fixtures from 3-2a, when they are hashed, then the fingerprints equal today's goldens.
- Given an operator badge-in on a device, when a small adjustment is sent, then no ledger row is written and a pending row exists with `requested_by` = operator.
- Given the composer, when the live route and the review-queue apply arm compose the same input, then the arms are identical (one test drives both).
- Given `check:capability-mirror` in FE, then it passes at 49.

## Verification

**Commands:**
- `cd workspace/core/backend/wms-be && bun run lint && bun run typecheck && bun run test` — expected: all pass (one jest run at a time).
- `cd workspace/core/mobile/wms-mobile && bun test && bun run typecheck` — expected: all pass.
- `cd workspace/core/frontend/wms-fe && bun run test && bun run lint && bun run typecheck && bun run build` — expected: all pass. The drift guard goes green after the BE merges.

## Implementation Notes

## Spec Change Log

## Review Triage Log

Design review, 2026-10-22 (D). Two layers: a claims check against the code (K) and a blind reviewer (B). Every accepted finding is folded into amendments A1–A14. Choices are recommended, taken autonomously.

| ID | Src | Verdict | Finding → resolution |
|---|---|---|---|
| D1 | K,B | high | A forced pend can't be stored (threshold NOT NULL, no policy); derivation lossy at 0. → A1 migration; the code waits |
| D2 | K | high | The controller's tracked-arm `stock.adjust` check locks operators out; composition runs before the device check. → A2 |
| D3 | K | high | The licence-seam DI precedent does not exist, and a token in ApiModule is invisible to tenancy. → A2 (a tenancy service) |
| D4 | K | high | Extraction too narrow (normalizeArms etc.); apply-arm fingerprint drift. → A2 |
| D5 | K,B | high | Review apply runs as the original operator, not the resolver; the outcome would be a pend. → A3 |
| D6 | K,B | high | Matrix codes wrong (badge-in 401 unauthenticated, 422 key reuse, mismatch quarantined); fate lists empty. → A5 |
| D7 | K,B | high | Existing tests change and demoted-replay semantics. → A4, A12 |
| D8 | K,B | high | No storage for deviceId (audit has no metadata). → A1, A13 |
| D9 | K | high | ops_manager grant vs the FE-derived mirror. → A6 |
| D10 | K | high | Secure-bin bypass reachable by floor staff. → A6 |
| D11 | K | medium | pendReason on stored replays; no detail route. → A7 |
| D12 | K | medium | No fingerprint golden exists. → A8 |
| D13 | K | medium | adjustReasons has no labels; snapshot parse default. → A9 |
| D14 | K | medium | Mobile 202 handling; :753 is not a 202 precedent. → A5 |
| D15 | K | medium | Mobile lists missed. → A12 |
| D16 | K,B | medium | Device eligibility / DAMAGED / precision / new-batch dates / FEFO clock / confirm step. → A10 |
| D17 | K,B | medium | Web surface scope; FE queue copy; FE #108 dependency. → A11 |
| D18 | K | low | 401 detail and OpenAPI security change. → A12 |
| D19 | K | low | REJECTED_OP_TYPES feeds the OpenAPI enum. → A12 |
| D20 | K,B | low | Approval volume, no notification, no withdraw/TTL. → A14 |
| D21 | B | medium | Splitting under the threshold by managers. → A14 (PENDING; the same rule as the web today) |
| D22 | B | medium | Self-approval / segregation of duties. → A14 (PENDING; no change to who approves, per Never) |
| D23 | B | low | Badge-in left open. → A14 (PENDING) |
| D24 | B | medium | Stale queued deltas, duplicate requests. → A14 (PENDING) |
| D25 | B | low | Approval timing of FEFO and checks. → A10 (composed at request; re-checked at approval) |
| D26 | B | low | Evidence photo for Remove. → A14 (file-storage story) |
