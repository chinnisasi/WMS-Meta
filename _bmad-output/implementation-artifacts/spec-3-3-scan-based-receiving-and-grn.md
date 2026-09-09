---
title: 'Story 3.3: Scan-based receiving and GRN'
type: 'feature'
created: '2026-09-09'
status: 'in-progress'
route: 'dispatch'
review_loop_iteration: 0
baseline_commit: '97733ed92d3064c2ee08f6c72fb16f736ee75a74' # wms-be HEAD
baseline_commit_fe: 'a11802b8fc9ba1693aeb91814705bd9ba44e3973' # wms-fe HEAD
baseline_commit_mob: '9830a07fc96f934422a8b8bfedaae01b01e5a280' # wms-mobile HEAD
context:
  - '_bmad-output/implementation-artifacts/epic-3-context.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** A PO can be created and tracked, but nothing can turn a physical delivery into stock — there is no GRN, no receipt path, and the mobile substrate has no task type. Deliveries still land via spreadsheets.

**Approach:** The substrate's first real task type. An operator opens a PO (or blind receive) in the mobile inbox, accumulates a draft by scanning SKU barcodes + entering batch and quantity (stepper / scan increments / manual fallback), and confirms — one idempotent `grn.submit` op replays the whole GRN against the server exactly once, in order, offline-safe. The server records the GRN, writes `grn.received` ledger events through the Epic 2 inventory envelope, updates PO `received_qty` transactionally, holds any over-open-quantity excess as a pending over-receipt event for Ops Manager approval (the operator's task continues), and flags blind GRNs for PO-matching. Web gets the Inbound surface (POs with open quantities, GRN list with blind flags) and the Conflicts & Reviews queue (over-receipt approval cards) becomes real.

## Boundaries & Constraints

**Always:**
- Backend commands follow the established invariant order (`withTenantTransaction`: assertPermission → idempotency replay → asserts → write → in-tx outbox → idempotency-key snapshot) — `grn.submit` and the approval commands included; ULID idempotency keys tenant-scoped (AD-5).
- Receiving is device-authenticated (`DeviceSessionGuard`, badge token — no bare device credential): the device row is re-read fail-closed (active + bound operator), the operator role re-read from DB per command (accountant → 403 `role-denied`), JWT/token is transport only (AD-10, selfTestEcho pattern).
- Received stock lands in a **system Receiving bin per warehouse** — auto-created at first receipt through tenancy's bin facade (bin master data is tenancy-owned), flagged as system, excluded from putaway suggestions and picking; 3.5's putaway moves bin→bin; dock-to-stock derives from GRN `arrival_at` → putaway event (human decision 2026-09-09).
- Receipts write ledger events through `InventoryFacade`/`LedgerService` in the same transaction as relational state; event type `grn.received` registered in `ledger-registry.ts` with a NEW `reference_doc` union arm (never reshape `manual-adjustment`); `occurredAt` = device time, `recordedAt` = server ingest (AD-1).
- Batch identity is created through catalog's interface (`CatalogFacade.ensureBatches`, idempotent by batch code); the ledger stays the only source of batch quantity/location (review-adversarial H-2).
- Over-receipt: the GRN records the full physically-received quantity; only the within-open-qty portion applies immediately (ledger + `received_qty`); the excess lands in a pending `over_receipts` row + outbox event + approval card — applied to inventory only on approval (the excess "requires Ops Manager approval", FR-8); rejection leaves it unapplied and audit-trailed. Ops Manager (or Owner) decides **every** over-receipt in v1; threshold-based Owner routing lands later with FR-19's adjustment thresholds (human decision 2026-09-09). The operator's task continues, never hard-blocks (UX-DR15).
- PO state re-check at server write time, not just scan time: a GRN submitted against a closed/cancelled-line PO is rejected naming the PO state (`409 po-not-open`); on replay this surfaces as a visible retraction in the sync summary (AD-10: server re-authorization; a demoted operator's or stale-PO queued receipt does not apply).
- Blind receive requires a reason code from a fixed enum (`unannounced-delivery` | `po-not-found` | `other`); the GRN carries the code and the web Inbound surface flags blind GRNs for PO-matching.
- GRN codes are server-assigned, human-readable, unique per tenant (`GRN-<n>`, zero-padded sequence).
- On-device decisions mirror server rules (AD-4): barcode→SKU resolution, open-qty progress, and over-receipt warning all run on-device against a sealed cached snapshot (SKU barcode map + open-PO lines) captured while online; the server gate, not the mirror, is authority.
- Each GRN is ONE queued op enqueued at confirm (draft persisted locally sealed so force-quit loses nothing); FIFO replay exactly-once via the op's ULID (AD-5); session-expiry 401s keep the op queued (3.2 semantics); `device-revoked` quarantines with attribution.
- Partial GRN leaves the PO line open; `open_qty` stays derived (`ordered − received`), never stored; approved over-receipt may drive it negative — the OpenAPI `openQty` `minimum: 0` is relaxed in this story's additive diff (the deferred 3-1 item settles here).
- Web capability `review.decide` (owner, ops_manager) gates over-receipt approve/reject and the Conflicts & Reviews surface ("hide surfaces, never blocked screens").
- Microcopy: numbers and verbs, no exclamation marks ("Scanned 180 of 200. 20 short — record a partial."); scan banner states per UX-DR (✓/↻/✕/⚠, never color-only); qty stepper ≥ 48dp glove-usable; manual entry a one-tap fallback at every scan step; HID keeps capture-field focus.

**Never:**
- No QC holds (3.4 owns quarantine of received stock — received stock lands in putaway-eligible state and 3.4 adds the hold), no putaway suggestions or bin moves (3.5), no bin administration (3.6).
- No serial-number capture in the receive flow (serials stay ledger-capable but no serial intake UI; batch-level only).
- No ASN; no dashboard KPI tiles beyond what the surfaces already stub; no vendor portal; no PO creation/amend/close UI on web (3.1 stayed backend — POs enter via API; the Inbound surface renders existing POs).
- No Conflicts & Reviews items beyond over-receipt approvals (quarantined replay conflicts and escalated variances arrive later).
- No refresh-token machinery, no push notifications, no LWW conflict auto-merge.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Receive, single-SKU single-lot | Online device, open PO, scan SKU → batch code + mfg date → qty → confirm | 201 GRN (`GRN-0001`-style code) + lines + `grn.received` ledger events + `received_qty` updated; ≤ 4 scans + 1 confirm | N/A |
| Partial GRN | Confirm with received < ordered | GRN records actual; PO line stays `open`, remaining derived correctly | N/A |
| Over-receipt | Confirm where a line's qty > PO open qty | GRN records full physical qty; within-open applies immediately; excess → pending `over_receipts` row + `over_receipt.requested` outbox + approval card; task continues | Excess unapplied until decided; ledger/`received_qty` untouched for the excess |
| Blind receive | `poId: null` + reason code | GRN created with blind flag + reason code; no PO refs on lines | Missing/unknown reason code → 400 |
| Submit against closed PO | `poId` of a `closed` PO | `409 po-not-open` naming the PO state; on replay: rejected retraction in sync summary | N/A |
| Duplicate submit | Same `Idempotency-Key` twice | Replay returns stored snapshot; no second GRN/ledger event | Payload-hash mismatch → 422 `idempotency-key-reuse` |
| Unknown/wrong barcode on device | Barcode not in cached SKU map | Device rejects ≤ 500 ms with reason; never queues; manual entry fallback | N/A |
| Offline receive ≥ 30 min | Queued `grn.submit` ops, network returns | Replay in task order exactly once; sync summary settles each | Expired session → unreachable (stays queued); `device-revoked` → quarantine with attribution |
| Over-receipt decision | ops_manager/owner approves or rejects | Approve: ledger event applies excess + `received_qty` bump + audit + `over_receipt.approved`; reject: stays unapplied + audit + `over_receipt.rejected` | Non-privileged caller → 403 `role-denied`; already-decided → 409 |
| Batch creation on receipt | New batch code + mfg date | `CatalogFacade.ensureBatches` idempotent per (sku, code); GRN line references batch id | Duplicate batch code under a different SKU → 400 (catalog uniqueness) |
| PO-line cancelled mid-receive | Line `cancelled` on an otherwise-open PO | Line rejected naming the line state; other lines settle | N/A |

</frozen-after-approval>

## Code Map

- `wms-be/src/modules/inbound/po.command.ts` -- the command template: invariant order (`create` at :168), `replay`/`writeIdempotencyKey` helpers (:521/:543), `loadOpenPo` (:602, 409 `po-not-open`), `lineSnapshot` open-qty derivation (:722). `received_qty` is column-updated transactionally; `open_qty` always derived — never break this.
- `wms-be/src/modules/inventory/ledger.service.ts:424` -- `appendMovement(tx, movement)` + `LedgerMovement` shape (:25); per-warehouse advisory lock + hash chain — receipts go through this, never around it.
- `wms-be/src/modules/inventory/ledger-registry.ts` -- register `grn.received` + extend the `LedgerReferenceDoc` union with a new `grn-receipt` arm (`{grnId, poId?, poLineId?}`); grammar version untouched.
- `wms-be/src/modules/catalog/catalog.facade.ts:205` -- `ensureBatches` (idempotent batch identity by code) — the ONLY way receipts create batches; never write `batches` rows directly.
- `wms-be/src/modules/tenancy/*` (zones/bins facade from 1.3) -- bin master data is tenancy-owned: the receive command ensures the system Receiving bin exists through this facade, never by writing `bins` rows directly; mark the bin system-owned so putaway suggestions (3.5) and picking exclude it.
- `wms-be/src/modules/tenancy/enrollment.command.ts:709` -- `selfTestEcho`: the device-authenticated command pattern (device `.for('update')`, active + pinHash check, role re-read non-accountant, then invariant order) — the receive command mirrors it.
- `wms-be/src/modules/tenancy/device-session.guard.ts:36` + `CurrentDeviceSession` -- device guard; badge token carries `{deviceId, tenantId, userId}`; bare credentials (userId null) rejected at the controller (devices.controller.ts:241 pattern).
- `wms-be/src/modules/tenancy/permissions.ts` -- add `review.decide` (owner, ops_manager); operators need no new capability (device badge-in authorizes task execution; accountant is rejected per-command).
- `wms-be/src/shared/db/schema.ts` + `drizzle/0013_*.sql` -- new tables (GRN header/lines, `over_receipts`); hand-append RLS `*_tenant_isolation`, status CHECKs, tenant-led indexes per the 0012 pattern. The `received_qty <= ordered_qty` CHECK noted in 0011 must NOT land — approved over-receipt legitimately drives received past ordered; relax the OpenAPI `openQty` `minimum: 0` instead (deferred 3-1 item).
- `wms-be/test/devices.spec.ts` / `test/inbound.spec.ts` -- e2e bootstrap pattern (probe roles, advisory lock 742106, children-first cleanup, HTTP-minted sessions, `enrollDevice`/`badgeInOperator` helpers); drift guard `test/api.spec.ts:96` demands `openapi:export` regeneration.
- `wms-mobile/src/offline/types.ts` -- `OpType` union: add `'grn.submit'` (comment says real types land here).
- `wms-mobile/src/state/device-store.ts:replay` -- sender dispatch: currently calls `selfTestEcho` for every op; dispatch on `op.type` (the outcome mapping — unreachable/revoked/rejected/unauthenticated — is already right).
- `wms-mobile/src/scanning/engine.ts:decideScan` -- the unknown-scan fallback (:101 defers receiving); receiving scans are SKU-barcode events decided against the draft context, not new engine states — the receive screen drives `decideScan` with its own accepted-shape rules (keep the engine pure).
- `wms-mobile/app/inbox.tsx` -- `TASK_TABS` gains 'Receive'; the empty-list block is replaced by open-PO receive tasks; sync summary already renders retractions/quarantines.
- `wms-mobile/src/api.ts` -- add `submitGoodsReceipt` mirroring `selfTestEcho` (Idempotency-Key = op.id, 10s abort ceiling).
- `wms-mobile/src/offline/sqlite.ts` -- the sealed secrets table hosts the cached catalog snapshot (SKU barcode map + open-PO lines) captured while online — same `getSecret`/`setSecret` machinery, new SECRET_KEYS.
- `wms-fe/src/app/(app)/inbound/page.tsx` -- SurfacePlaceholder today; becomes the real surface (POs card + GRNs card) using `DataTable` + `FeedbackBanner` (`src/components/settings/sku-table.tsx` is the end-to-end pattern).
- `wms-fe/src/app/(app)/conflicts/page.tsx` + `src/lib/navigation.ts:NAV_ITEMS` -- the nav entry exists; gate it with `capabilities: ['review.decide']` via `visibleNavItems` + `roleHasCapability`; the page becomes the over-receipt approval queue.
- `wms-fe/src/lib/api/generated/` -- regenerate via `bun run api:generate` from `wms-be/openapi/openapi.json` (never hand-edited); 3.1's `receivedQty`/`openQty` types update with the new routes.

## Tasks & Acceptance

**Execution:**
- [x] `wms-be migration 0013` -- `goods_receipt_notes`, `goods_receipt_lines`, `over_receipts` tables + hand-appended RLS/CHECKs/tenant-led indexes (0012 pattern; no received≤ordered CHECK) -- the receiving data model.
- [x] `wms-be/src/modules/inventory/ledger-registry.ts` -- register `grn.received` + new `grn-receipt` reference arm -- ledger grammar for receipts.
- [x] `wms-be/src/modules/inbound/receiving.command.ts` (new) + `receiving.facade.ts` + `ReceivingController` routes + DTOs -- device route `POST /:tenantId/receiving/goods-receipts` (badge token, Idempotency-Key); user routes: list GRNs, list over-receipts, approve/reject (`review.decide`); outbox `grn.recorded`, `over_receipt.requested/approved/rejected`; audit rows on decisions; register in module + api shell; capabilities in `permissions.ts`.
- [x] `wms-be/test/receiving.spec.ts` (new) -- e2e per the matrix: happy path, partial, over-receipt gate + decision arms, blind receive, closed-PO rejection, duplicate key, offline replay (queue → expiry-unreachable → replay), RLS.
- [x] `wms-be/openapi:export` -- additive diff incl. the `openQty` `minimum` relaxation -- drift guard.
- [x] `wms-mobile/src/offline/types.ts` + `src/api.ts` + `src/state/device-store.ts` -- `'grn.submit'` op type, `submitGoodsReceipt` call, sender dispatch -- the substrate's first real op.
- [x] `wms-mobile/app/receive.tsx` (new) + inbox 'Receive' tab -- draft flow: PO context header + progress, scan SKU (barcode map from the sealed catalog cache) → batch code + mfg date → stepper/manual qty → next line → Confirm GRN / Record partial; over-receipt notice (amber, task continues); blind-receive reason-code step; confirm enqueues one `grn.submit` op.
- [x] `wms-mobile` catalog cache -- fetch + seal SKU barcode map + open-PO lines at badge-in/refresh; on-device progress + over-receipt warning + barcode resolution from the cache -- offline decisions (AD-4).
- [x] `wms-mobile` tests -- engine/receive-draft/store tests mirroring the existing 18-test suite.
- [x] `wms-fe` `bun run api:generate` -- regenerate the client.
- [x] `wms-fe/src/app/(app)/inbound/page.tsx` + components -- Inbound surface: POs (code, vendor, ordered/received/open per line, status) + GRNs (code, PO ref or blind flag + reason, lines, units, recorded) -- the review half.
- [x] `wms-fe/src/app/(app)/conflicts/page.tsx` -- over-receipt approval cards (PO line, excess qty, GRN ref, requested by/at, threshold context) with Approve/Reject + nav capability gate -- Conflicts & Reviews becomes real.
- [x] `wms-fe` tests + lint/typecheck/build.

**Acceptance Criteria:**
- Given an open PO, when receiving a single-SKU single-lot pallet, then GRN creation takes ≤ 4 scans + 1 confirm; quantities enter via the glove-usable qty stepper or scan increments
- Given a partial GRN, when confirmed, then the PO line stays open with correct remaining quantity
- Given receiving exceeds a line's open quantity, then an over-receipt event is created and Ops Manager approval is requested mid-receive — the task continues, never hard-blocks; the excess applies to inventory and `received_qty` only after approval
- Given blind receive with a reason code, then the GRN is flagged on the Inbound surface for PO-matching
- Given receipts, then ledger events are written through Epic 2 and queued receipts replay in order and exactly once; a stale (closed-PO or demoted-operator) queued receipt is visibly retracted, never silently applied

## Implementation Notes

<!-- Append-only during implementation. -->

- Implemented on `wms-be` (baseline `97733ed`, branch `feat/3-3-scan-based-receiving-and-grn`, commit `4348fcd`): migration `drizzle/0013_steady_diamondback.sql` (three tables + hand-appended RLS `*_tenant_isolation` + status/qty CHECKs + tenant-led indexes per the 0012 pattern; no `received_qty <= ordered_qty` CHECK, per the deferred 3-1 item), `src/shared/db/schema.ts`, `src/modules/inventory/ledger-registry.ts` (the `grn.received` event + a new `grn-receipt` reference arm), `src/modules/tenancy/permissions.ts` (`review.decide`, owner/ops_manager), tenancy's receiving-bin facade arm (system Receiving bin auto-provisioned at first receipt), catalog's `ensureBatches` reuse, and the new receiving surface (`receiving.facade.ts`, `receiving.command.ts`, `receiving.dto.ts`, `src/api/receiving.controller.ts`) wired through `inbound.module.ts` + `api.module.ts`; `openapi/openapi.json` re-exported (additive diff, `openQty` `minimum` relaxed).
- Command invariant order holds throughout: device row re-read fail-closed (`.for('update')`) → per-command operator role re-read (accountant → 403 `role-denied`) → idempotency replay → validation → master-data asserts → PO `.for('update')` (`409 po-not-open` names the status) → batch identity → write → in-tx outbox → idempotency-key snapshot (hash mismatch → 422 `idempotency-key-reuse`).
- Over-receipt semantics as specced: GRN lines record physical truth; within-open applies immediately (ledger event + `received_qty`); excess lands in a pending `over_receipts` row + `over_receipt.requested` outbox + audit; approval applies the excess as a new `grn.received` ledger event (reference = the decision's idempotency key) + `received_qty` bump + audit + `over_receipt.approved` outbox; rejection leaves it unapplied. A decision replay re-serves the snapshot; a second decision is 409 `over-receipt-decided`. `openQty` stays derived and may go negative.
- Bug caught by the e2e suite and fixed in-session: the reject arm's audit/outbox type was built as `over_receipt.${decision}d` → the malformed `over_receipt.rejectd`; now built from the status (`over_receipt.approved | rejected`).
- Bun's OpenAPI export path has no swagger TS plugin, so every nullable `@ApiProperty` in `receiving.dto.ts` carries an explicit `type: String` — without it nullable props render `type: object` on disk and the api.spec drift guard fails against the served document (repo convention).
- `test/receiving.spec.ts` (14 e2e tests, real Postgres, supertest against the HTTP surface): happy path, partial, over-receipt gate + approve/reject arms (+ replay, + authorization matrix incl. a demoted operator's 403), blind receive (+ validation), closed-PO rejection incl. a carried-line retraction, line-level settlement (a rejected `po-line-not-found` line does not block the valid line's apply), idempotency (replay / hash-mismatch / missing key), device auth (bare device 401, demoted 403, revoked 403 `device-revoked`), catalog snapshot, GRN list (keyset walk + filter), RLS cross-tenant probe, 0013 CHECK round-trip. Ledger-cleanup deletes run under `set session_replication_role = replica` (append-only trigger).
- Implemented on `wms-mobile` (baseline `9830a07`, same-named branch, commit `1ca52cd`): `'grn.submit'` op type + sender dispatch, receive draft flow (`app/receive.tsx` + inbox Receive tab) — PO context header + progress, barcode resolution from the sealed catalog cache, batch/mfg-date step, stepper/manual qty, over-receipt amber notice (task continues), blind-receive reason-code step, confirm enqueues ONE `grn.submit` op; catalog snapshot sealed at badge-in; engine/draft/store tests extend the existing suite.
- Implemented on `wms-fe` (baseline `a11802b`, branch `feat/3-3-inbound-conflicts`, commit `419f5a9`): generated client re-exported from the final backend OpenAPI; fetch helpers (vendors, PO list/detail, GRN list, over-receipt list/approve/reject) with Idempotency-Key headers on decisions; `src/lib/use-inbound.ts` hooks (keyset cursor + revision + stale-page render filter, mirroring `use-catalog.ts`); Inbound surface (POs card: vendor name, per-line ordered/received/open with the negative-open callout, status — the list is headers-only so each PO's lines come from its detail read; GRNs card: PO ref or blind flag + reason, line/unit counts with the "+N pending" excess marker); Conflicts & Reviews surface (pending/approved/rejected tabs, approve/reject cards gated by `review.decide`, problem-code reason strings); nav gate `capabilities: ['review.decide']` on the conflicts entry; capability mirror + tests updated.
- Known gaps, deliberate: the FE PO card makes one detail request per PO on the page (the list endpoint is headers-only — acceptable at tenant scale, N+1 by design); over-receipt cards resolve SKU/user names from full-list walkers (bounded 20 hops); offline replay retraction UX on mobile shows the op's server rejection verbatim in the sync summary (no bespoke retraction screen — deferred polish, not a behavior gap); the 3-1 deferred `received_qty <= ordered_qty` CHECK stays dropped permanently (approval legitimately drives received past ordered).

## Spec Change Log

<!-- Append-only; populated by step-04. -->

## Review Triage Log

<!-- Append-only; populated by step-04. -->

## Design Notes

**Draft-on-device, one op per GRN.** The device accumulates the draft locally (sealed rows in SQLite, force-quit-safe) and enqueues a single `grn.submit` op at confirm — the whole GRN is one idempotent server command. This matches the mockup's confirm step ("Record partial GRN · GRN-0088") and keeps the server stateless between scans. Scan budget math: pick PO (tap, not scan) + 1 scan for the SKU + batch typed once + stepper qty (no scan) + confirm = 1 scan + 1 confirm for the single-SKU single-lot pallet, well inside ≤ 4 + 1.

**Over-receipt semantics.** GRN lines record physical truth (all units arrived); the within-open portion applies immediately; the excess pends. On approval a `grn.received` event applies the excess (a normal ledger append — corrections are new events, none needed here). Rejection leaves it unapplied; the physical disposition is the reviewer's call, audit-trailed. `receivedQty` on the PO line tracks the applied portion only, so `openQty` can go negative post-approval — hence the OpenAPI `minimum` relaxation.

**Device catalog cache.** Barcode→SKU resolution and open-qty progress are on-device (AD-4) — the device seals a snapshot (SKU id/name/barcode + open-PO line quantities) into the offline store at badge-in while online; stale caches mirror, never override, the server's re-check at replay.

## Verification

**Commands:**
- `cd workspace/core/backend/wms-be && bun run test` -- expected: all suites pass incl. `test/receiving.spec.ts` + drift guard
- `cd workspace/core/backend/wms-be && bun run lint && bun run typecheck && bun run build && bun run db:migrate && bun run db:verify` -- expected: clean; drift guard round-trips 0013
- `cd workspace/core/mobile/wms-mobile && bun run test && bun run typecheck` -- expected: tests + strict typecheck pass
- `cd workspace/core/frontend/wms-fe && bun run test && bun run lint && bun run typecheck && bun run build` -- expected: clean; `api:generate` output committed