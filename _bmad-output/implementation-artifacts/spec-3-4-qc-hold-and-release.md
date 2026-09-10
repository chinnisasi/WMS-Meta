---
title: 'Story 3.4: QC hold and release'
type: 'feature'
created: '2026-09-10'
status: 'done'
route: 'dispatch'
review_loop_iteration: 0
baseline_commit: '3344061ac4fae5acb0eff176053afb6b0a9c0128' # wms-be main
baseline_commit_fe: '900cce785905febea66e67ff7fbc01952f9cd809' # wms-fe main
baseline_commit_mob: 'd0db5dcab27ed6136df3d2c31826466649683ef7' # wms-mobile main
context:
  - '_bmad-output/implementation-artifacts/epic-3-context.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** Received stock goes straight into ATP the moment its GRN is recorded — there is no way to quarantine suspect goods, so unverified stock is reservable and would be pickable.

**Approach:** An Ops Manager quarantines a (sku, bin) scope of stock: the stock's quantity moves through the ledger into a per-warehouse system **QC-hold bin** (real `qc.held` movements — no zero-delta bookkeeping events, keeping the story-2.1 zero-delta principle intact), `qc_holds` records the decision (reason, who, when, status), the ATP hook `qcHeldUnits()` is populated from QC-bin on-hand so held stock drops out of ATP in both `atp()` and the grant ceiling, and release moves the stock back to its recorded origin bin with a `qc.released` event. QC-held stock is visible on the web Inbound surface with its hold reason; mobile is untouched (the hold is a web Ops-Manager action, no new inbox task).

**Decided (2026-09-10, human):** hold mechanics = movement-to-QC-bin (option A — stock physically relocates; in-place quarantine rejected because zero-delta decisions cannot be ledger events), and the full spec ships as one goal (split declined at ~2,900 tokens).

## Boundaries & Constraints

**Always:**
- All stock changes go through `appendMovement` (ledger + projection in one tx) — hold and release are movements, never direct `stock_on_hand` writes.
- Release returns stock to the hold row's recorded `from_bin_id` (captured at hold time, per batch arm) — never to a caller-chosen bin.
- Hold and release are idempotent commands (required `Idempotency-Key`, payload hash, replay re-serves the snapshot, mismatch 422) with the full invariant order: role re-read → `assertPermission('qc.manage')` → idempotency replay → validation → movement(s) → hold-row write → in-tx outbox → idempotency-key snapshot.
- The QC-hold bin is system-owned (`system_owned = true`, code `QC-HOLD`, type `staging`), ensured lazily per warehouse exactly like the Receiving bin; only the hold/release commands ever move stock through it.
- One open hold per (tenant, warehouse, sku, bin) scope — partial unique index on open rows (the `inventory_quarantines` pattern), RLS `*_tenant_isolation` in the migration SQL only.

**Never:**
- No scrap/reject/destroy disposition — a failed inspection keeps the hold open; quantity shrinkage is Epic 5's adjustment path.
- No partial release (v1 releases the full held scope) and no bin-level "hold the whole bin" semantics — the hold grain is (sku, bin).
- No mobile changes: no new `OpType`, inbox tab, or screen.
- No new grammar version: the two event types register since v1, reference arms append only.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Hold happy path | Ops Manager holds (sku, bin) with on-hand > 0 | `201` hold snapshot; per-batch `qc.held` movements scope→QC bin; open `qc_holds` row; outbox `qc_hold.placed`; audit row; ATP drops by the moved qty | N/A |
| Hold an empty scope | (sku, bin) with zero on-hand | nothing written | 400 `validation-failed` naming the empty scope |
| Double hold | open hold already on the scope | no second row | 409 `qc-hold-open` (unique open-scope index backstops) |
| Release happy path | open hold released | `qc.released` movements QC bin→origin bin (same batch arms); row `released` with released_by/at; outbox `qc_hold.released`; audit; ATP restored | N/A |
| Double release | hold already `released` | no second decision | 409 `qc-hold-released` |
| Origin bin retired mid-hold | release finds origin bin retired/missing | no movement, hold stays open | 409 naming the bin state |
| Reserve held stock | grant against a scope whose stock is QC-held | reservation refused | 409 `unavailable` with detail naming the QC-held units |
| Held stock is excluded at read | ATP snapshot with an open hold | `qcHeld` = QC-bin on-hand; `atp = committedOnHand − reserved − qcHeld` | N/A |
| Wrong authority | operator/accountant session, or foreign-tenant path | no write | 403 `role-denied` / 403 `permission-denied` |
| Replay + malformed cursor | same key+payload; crafted cursor on the holds list | original snapshot re-served / holds list | 200 replay / 400 `invalid-cursor` |

</frozen-after-approval>

## Code Map

- `wms-be/src/modules/inventory/reservation.service.ts` -- `qcHeldUnits()` :49 (zero hook) — becomes scope-aware `(db, tenantId, warehouseId, skuId)` Σ of `stock_on_hand` at QC-bin scopes; populate at **both** call sites: `atp()` :454 and `committedCeiling()` :827; grant-failure detail (:134-138, :267-272) names QC-held units when > 0. `committedOnHand()` :830 (quarantine `notExists` precedent).
- `wms-be/src/modules/inventory/ledger-registry.ts` -- register `qc.held` + `qc.released` (sinceVersion 1) + append the `qc-hold` `LedgerReferenceDoc` arm (`{holdId, fromBinId?}`); additive only.
- `wms-be/src/modules/tenancy/receiving-bin.ts` -- `ensureQcHoldBinInTx` mirror (`QC_HOLD_BIN_CODE = 'QC-HOLD'`, type `staging`, system-owned, generous capacity).
- `wms-be/src/modules/inbound/qc.command.ts` (new) + `qc.facade.ts` (new) + `qc.dto.ts` (new) -- hold/release commands in the `receiving.command.ts` invariant order; list read mirrors `listOverReceipts` (:237) incl. `decodeCursorSafe`; outbox via `OutboxSink.append` (:581); audit rows (:758).
- `wms-be/src/modules/inbound/receiving.command.ts` -- `appendLedgerEventInTx` call shape (:495), idempotency helpers (`writeIdempotencyKey` :814, `hashCommandPayload`), conditional status UPDATE for decisions (:756) — the templates.
- `wms-be/src/api/receiving.controller.ts` -- add routes on the existing `ReceivingController` pattern: `POST :tenantId/receiving/qc-holds` + `POST :tenantId/receiving/qc-holds/:holdId/release` (`TenantSessionGuard` + `@IdempotencyKey`), `GET :tenantId/receiving/qc-holds`; `assertOwnTenantToken` helper (:284); register in `api.module.ts` :42-49.
- `wms-be/src/modules/tenancy/permissions.ts` -- add `'qc.manage'` (:9-35) to `ops_manager` (:59); FE mirror `wms-fe/src/lib/users.ts` :15-45 (drift-guarded).
- `wms-be/src/shared/db/schema.ts` + `drizzle/0014_*.sql` -- `qc_holds` table (:1183-1216 over-receipts pattern) + hand-appended RLS/CHECKs/index; `stock_on_hand`/`batch_on_hand` untouched (writes stay ledger-only, `test/architecture.spec.ts` :104-141).
- `wms-be/test/qc-holds.spec.ts` (new) -- e2e per the matrix, `receiving.spec.ts` bootstrap pattern (advisory lock 742106, replica-role cleanup).
- `wms-fe/src/components/inbound/inbound-cards.tsx` -- third `QcHoldsCard` sibling (:57-81 card list; DataTable pattern :230-247).
- `wms-fe/src/lib/use-inbound.ts` -- `useQcHolds` mirroring `useOverReceipts` (:251); `useSkuMap`/`useUserMap` for labels.
- `wms-fe/src/lib/api/client.ts` -- helpers mirroring :591-629 (Idempotency-Key on hold/release); regenerate via `bun run api:generate` after the backend contract lands.
- `wms-fe/src/lib/over-receipt.ts` -- analogous `qcReason(error)` code-to-words map; `FeedbackBanner` outcomes (`over-receipt-queue.tsx` :170).
- `wms-mobile` -- no changes (no QC task type; the inbox tabs and `OpType` union stay as-is).

## Tasks & Acceptance

**Execution:**
- [x] `wms-be drizzle/0014_*.sql` -- `qc_holds` table (scope, reason, status, held_by/at, released_by/at, from_bin_id) + RLS/CHECKs/partial-unique/index -- the hold data model.
- [x] `wms-be/src/modules/tenancy/receiving-bin.ts` -- `ensureQcHoldBinInTx` -- the system QC bin.
- [x] `wms-be/src/modules/inventory/ledger-registry.ts` + `reservation.service.ts` -- register the two event types + reference arm; populate `qcHeldUnits` at both call sites; grant detail names held units -- the ATP hook.
- [x] `wms-be/src/modules/inbound/qc.command.ts` + `qc.facade.ts` + `qc.dto.ts` + controller routes + `permissions.ts` -- hold/release commands (idempotent, outbox, audit) + holds list read + `qc.manage` gate.
- [x] `wms-be/test/qc-holds.spec.ts` -- e2e per the matrix incl. RLS, replay, and an ATP-snapshot pin (`qcHeld > 0`, reservation refused naming the hold).
- [x] `wms-be bun run openapi:export` -- additive diff (hold/release/list routes) -- drift guard.
- [x] `wms-fe bun run api:generate` + `src/lib/api/client.ts` -- regenerate client + fetch helpers -- typed consumers.
- [x] `wms-fe` QC Holds card + `useQcHolds` + place-hold/release actions gated by `qc.manage` + `users.ts` capability mirror -- the Inbound surface's holds view.
- [x] `wms-fe` tests + lint/typecheck/build.

**Acceptance Criteria:**
- Given received stock, when an Ops Manager places it in QC Hold, then it is excluded from ATP and a reservation grant against it is refused naming the held units (FR-9)
- Given a held scope, when released, then the ledger carries inspector, decision, and timestamp (hash-chained `qc.released` events) and ATP is restored
- Given QC-held stock, then it is visible on the Inbound surface with its hold reason, held-by, and held-at
- Given a non-Ops-Manager session, when hold/release is attempted, then 403 `role-denied` and nothing persists

## Implementation Notes

<!-- Append-only during implementation. -->

**Implemented per this spec (story 3.4; wms-be PR: https://github.com/chinnisasi/WMS-BE/pull/18, wms-fe PR: https://github.com/chinnisasi/WMS-FE/pull/11 — merged by the human operator per the project's PR convention).**

- Backend: `qc.command.ts` (`placeHold`/`releaseHold` in the frozen invariant order — role re-read → `assertPermission('qc.manage')` → idempotency replay → validation → movements → hold row → in-tx outbox → audit → idempotency-key snapshot), `qc.facade.ts` (list with keyset `(createdAt, id)` pagination + status filter), `qc.dto.ts`, three routes on `ReceivingController`, `QcCommand`/`QcFacade` registered in `inbound.module.ts`.
- Movement truth: a hold appends one `qc.held` event per on-hand arm into the warehouse's lazily-ensured system `QC-HOLD` bin (reference arm `{kind:'qc-hold', holdId, fromBinId}`); a release replays the hold's own `qc.held` arms (`qcHeldArmsInTx` — same batch refs, same magnitudes) into `qc.released` events back to the recorded origin bin. No zero-delta events, no direct `stock_on_hand` writes, no held-qty column. `qc.held`/`qc.released` register sinceVersion 1 (no grammar bump); mobile untouched.
- ATP: `qcHeldUnits()` populated at both `atp()` and `committedCeiling()` call sites; a refused grant names the held units ("of which N are QC-held").
- Migration 0014: `qc_holds` with the partial unique index `qc_holds_open_scope_unique` (one open hold per scope), release-pairing CHECKs, fail-closed RLS — all in migration SQL only. Release guards origin-bin existence (`409 qc-hold-origin-bin-gone`, hold stays open; the 'retired' bin state arrives with story 3.6 and will extend this path).
- e2e `test/qc-holds.spec.ts`: 14 tests per the I/O matrix incl. ATP-snapshot pins (`qcHeld > 0`), replay (same snapshot, mismatch → 422), double hold/release 409s, empty-scope 400 naming the scope, operator role-denied + foreign-path permission-denied, reserve refusal naming held units + ATP restored on release, origin-bin-gone, holds-list status filters + crafted-cursor 400, RLS invisibility + fail-closed INSERT, and the migration backstops (release-pairing CHECK, partial unique index, released twin OK) — plus the review-loop-1 arms: whitespace-only and >200-char reason 400s, the QC-bin-as-origin 400, the serial-tracked-SKU 400 (zero rows moved), the multi-batch one-movement-per-batch arm, and the holds-list `warehouseId` filter + foreign-warehouse 404 + `nextCursor` walk (no repeats). All green: 270 tests / 18 suites; lint/typecheck/build/db:migrate/db:verify clean; `openapi:export` purely additive.
- Frontend: `QcHoldsCard` (open/released tabs, Release inside the Status column, place-hold form from `useStockScopes`) as the third Inbound sibling; `useQcHolds`/`useStockScopes`/`useBinCodeMap` external-store hooks; `qcReason()` problem map; `qc.manage` mirrored into `users.ts` (owner + ops_manager) with matrix test pins; generated client regenerated (additive). FE test/lint/typecheck/build all clean (71 tests).
- Pre-existing gap noted, unchanged by this story: the FE capability mirror covers only the capabilities its surfaces gate on (now incl. `qc.manage`); backend-only capabilities (`stock.adjust`, `vendor.manage`, `po.manage`) remain unmirrored.

## Spec Change Log

<!-- Append-only; populated by step-04. -->

## Review Triage Log

<!-- Append-only. Populated by step-04 on every review pass. -->

### Review loop 1 (2026-09-10) — layers: blind-hunter (16), edge-case-hunter (11), verification-gap (3 gaps + 2 other)

**Blind hunter:**

- B1 `src/lib/use-inbound.ts` — `useQcHolds` fetches without the `warehouseId` filter the backend and client helper both support; the warehouse-scoped card lists the whole tenant's holds — **medium** — verified in the diff: the card renders under the active-warehouse switcher, its doc comment and the README contract both claim the warehouse's holds, yet `fetchApiListQcHolds(tenantId, { status })` never passes `warehouseId`; origin bins of other warehouses' holds resolve to "—". Patch.
- B2 `inbound-cards.tsx` place-hold form offers scopes already under an open hold and the QC bin's own rows (guaranteed 400/409 submits) — **medium** — verified: `useStockScopes` filters only `quantity > 0` over the stock read, which excludes neither open-held scopes nor system bins; the QC-bin-as-origin 400 is the only guard for the latter. Patch.
- B3 `receiving-bin.ts` — the ensure's re-selects lack a `systemOwned` filter, so a user bin named `QC-HOLD` (created before the first hold) is returned as the QC bin while `qcHeldUnits` (which requires `system_owned = true`) counts zero — ATP never drops — **medium** — verified: `onConflictDoNothing({ target: [bins.warehouseId, bins.code] })` + re-select by `(tenant, warehouse, code)` returns the user's non-system bin; no code-reservation guard exists anywhere in the diff. Patch.
- B4 `qc.command.ts` — batch arms not checked against the plain quantity; zero arms skipped → a hold with no movements whose release 409s forever — **false** — `stock_on_hand` and `batch_on_hand` are folds of the same event stream (every movement folds both), so `sum(batch rows) = plain` by construction; zero batch rows are legitimately nothing-to-move, and `scope.quantity <= 0` is already a 400. No program path reaches the divergence.
- B5 release's empty-arms path reuses `qc-hold-origin-bin-gone`, a wrong-signal code — **false** — the only reachable empty-arms state is ledger tampering (the code comment says exactly that); the program cannot produce a hold with zero movements (B4 disproven), and renaming/reusing codes is a public-surface change for an unreachable case.
- B6 release doesn't verify QC-bin on-hand; a blind release could drive `stock_on_hand` negative — **false** — `appendMovement` refuses over-draws with 422 `insufficient-on-hand` (ledger.service.ts:268-276, applied at :627) and the projection carries a non-negative CHECK; a mid-hold QC-bin draw makes release fail safe (hold stays open), not corrupt.
- B7 no supporting index for `qcHeldArmsInTx`'s `referenceDoc->>'holdId'` query — **low** — real but release is a rare admin action on a small tenant ledger; the fix churns an already-applied migration for no everyday impact. Reject.
- B8 snapshot instant-format inconsistency (place returns raw `nowIso()`, release/list canonicalize) — **false** — `nowIso()` is `new Date().toISOString()` (time.ts:8) and `canonicalInstant(value)` is `new Date(value).toISOString()` (ledger.service.ts:232-234); the DB round-trip preserves the instant, so both paths emit byte-identical strings.
- B9 missing e2e arms: reason >200/whitespace, multi-batch one-movement-per-arm, `nextCursor` walk, warehouseId filter 404, limit clamp — **medium** — verified against the 11-test suite: none of these documented arms is exercised (the batch-arm test uses a single batch; the list test sends only status-filter and garbage-cursor requests). Patch (with the verification-gap gaps below).
  - **Correction (2026-09-10, patch round):** the limit-clamp sub-arm was mis-routed — no frozen contract documents a clamp (the matrix, the baseline wms-be README, and the wms-fe README all say nothing about `limit`; the DTO's `@Max(200)` and the controller's own "out-of-range limit (validation-failed)" 400 annotation ARE the documented behavior). The patch round's remedy (removing `@Max`/`maximum`, clamping in the facade) was a public-surface change, out of scope for a patch, and contradicted the controller annotation — reverted in the same review loop; the list test keeps filter/404/cursor-walk arms only.
- B10 Release is a one-click terminal decision with no confirm dialog (sibling revoke has one) — **low** — release is recoverable in effect (a new hold on the released scope is legal — the partial unique index only bars open duplicates), and the fix adds a dialog component rather than a direct correction. Reject.
- B11 `useQcHolds`/`useStockScopes`/`useBinCodeMap` swallow fetch errors → indistinguishable empty state — **low** — this is the repo's deliberate external-store convention ("quiet chrome on failure", identical in the sibling hooks); a fix means error-state plumbing across the hook family for a rare condition. Reject.
- B12 spec task line says the table carries `from_bin_id`; the shipped column is `bin_id` (origin) — **verified mismatch, but the fix edits this build's spec** — reject per rule (the frozen text's concept wording; the contract READMEs correctly say `bin_id`).
- B13 wms-be README Story 3.4 entry omits the "No FKs — app-validated" convention note its 0012/0013 siblings carry — **low** — direct doc-sentence fix; developers read this contract first. Patch.
- B14 OpenAPI: release/list `200` descriptions empty, `releasedAt` missing the ISO description its siblings carry, place `400` omits the QC-bin-as-origin rejection — **low** — direct annotation corrections + `openapi:export`. Patch.
- B15 files shipped without trailing newlines — **low** — lint passes (no rule enforces it), cosmetic. Reject.
- B16 migration comment glued onto the index line — **low** — valid SQL, purely cosmetic. Reject.

**Verification-gap (pre-verified gap findings — filed evidence trusted):**

- G1 the QC-bin-as-origin 400 guard (`qc.command.ts:176-180`) has no test; deleting the branch passes all 270 tests — **medium** — patch (add the e2e arm).
- G2 the holds-list `warehouseId` filter and its out-of-tenant 404 are documented contract surface with zero coverage — **medium** — patch (extend the list test).
- G3 `qcReason()` ships untested while its same-file sibling `decisionReason()` is branch-pinned in `over-receipt.test.ts` — **medium** — patch (add the matrix in the same style).

**Verification-gap, other findings** — VG-o1 (card tenant-wide vs warehouse claim) merges into B1; VG-o2 (form offers the QC-bin scope) merges into B2.

**Edge-case hunter:**

- E1 batch arms zero/divergent → unreleasable hold — **false** — same refutation as B4 (fold construction).
- E2 user-created `QC-HOLD` bin/zone hijacks the ensure; ATP never drops — **medium** — same verification as B3; the zone arm is benign (zones carry no systemOwned and the ensure's bin still lands system-owned), the bin arm is the defect. Patch.
- E3 `stock.adjustment` can move units into or out of the system QC-HOLD bin — ATP drops with no hold row and no release path — **medium** — verified: `inventory.command.ts` contains no `systemOwned` exclusion; a QC-bin intake is counted by `qcHeldUnits` yet no release path exists; a mid-hold out-adjustment makes release fail safe (422, hold stays open). This directly violates the frozen boundary "only the hold/release commands ever move stock through it". Patch (reject adjustments whose from/to bin is the system QC-hold bin).
- E4 a serial-tracked SKU's scope can be held bulk (`serialRef: null`), leaving serial location records at the origin bin — serial/stock divergence — **medium** — verified: `placeHold` never checks `serialTracked`, the serial fold ignores null-ref bulk movements (ledger.service.ts:364-367), and `qc.held` registers `allowsSerialArm: false`. One safe reading exists (v1 holds no serials) → reject serial-tracked holds with 400. Patch.
- E5 holds-list cursor encodes the ms-truncated canonical instant, so rows sharing the boundary millisecond with later sub-ms timestamps are skipped — **medium** — verified: `buildPage` encodes from the mapped item's `createdAt` (`canonicalInstant` = `toISOString()`, ms precision) while Postgres keeps microseconds; the exact pattern epic-2 retro A1 already logs for the shared cursor primitive. Defer (pre-existing, fix lands with A1).
- E6 card shows cross-warehouse holds — merges into B1. Patch.
- E7 form offers the QC-bin scope — merges into B2. Patch.
- E8 concurrent `placeHold` on one scope with different keys → the loser surfaces 422 `insufficient-on-hand` instead of the documented 409 — **low** — verified real (the movement-append precedes the hold insert), but it needs two different-key commands in flight on the same scope in the same instant, the refusal is still a deterministic 4xx with zero corruption (the movement guard holds), and the same-key path replays correctly. Reject.
- E9 (claim) the task list names a `from_bin_id` column that does not exist — merges into B12. Reject (spec edit).
- E10 (claim) the adjustment command has no systemOwned exclusion — merges into E3. Patch.
- E11 (claim) a pre-render double-click fires two distinct fresh ULIDs, so the second is a new command: a spurious 409 banner ("already covers this scope"/"already released") right after the action succeeded — **medium** — verified plausible: both handlers run before the disabling state renders, each generating its own key, so the fresh-key-per-click design does not deliver the "double click replays" contract for this window. Patch (re-entry guard so the second click is a no-op, not a new command).

## Design Notes

**Movement-based quarantine.** The ledger only records movements with non-zero deltas (`stock.adjusted` rejects zero at the command, :inventory.command.ts:323-330 — "zero deltas write no ledger event"), and the story AC requires the release decision *in the Ledger* — so hold and release are real movements of the scope's stock into/out of a system QC-hold bin, not zero-delta records. This makes the held quantity exactly the QC bin's on-hand, so `qcHeldUnits` reads only `stock_on_hand` at QC-bin scopes — no cross-module hold-table read, and `inventory_quarantines` (a data-integrity flag) stays semantically distinct. Hold grain is the whole (sku, bin) scope: the hold moves every on-hand row there (one movement per batch row, `batchRef` carried for traceability).

## Verification

**Commands:**
- `cd workspace/core/backend/wms-be && bun run test` -- expected: all suites pass incl. `test/qc-holds.spec.ts`; ATP snapshots with holds stay green
- `cd workspace/core/backend/wms-be && bun run lint && bun run typecheck && bun run build && bun run db:migrate && bun run db:verify` -- expected: clean; drift guard round-trips 0014
- `cd workspace/core/frontend/wms-fe && bun run test && bun run lint && bun run typecheck && bun run build` -- expected: clean; `api:generate` output committed
- `cd workspace/core/mobile/wms-mobile && bun run typecheck` -- expected: untouched tree still typechecks