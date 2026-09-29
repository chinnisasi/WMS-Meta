---
title: '5-4 Variance review and resolution'
type: 'feature'
created: '2026-09-29'
status: 'in-progress'
route: 'dispatch'
review_loop_iteration: 0
baseline_commit: ea28fee  # wms-be HEAD before implementation
baseline_commit_fe: dbe5157  # wms-fe HEAD (capability-mirror task)
context:
  - '_bmad-output/implementation-artifacts/epic-5-context.md'
  - 'docs/design/SYSTEM-DESIGN.md'
  - 'docs/design/IMPLEMENTATION-GUIDE.md'
  - 'docs/design/modules/movements.md'
  - 'docs/design/modules/inventory.md'
  - 'docs/design/API-SURFACE.md'
  - 'docs/design/PENDING.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** 5-3 leaves every count variance permanently `open` — nothing resolves a variance, no approver is routed to, and no stock correction can ever be signed off from a count.

**Approach:** A variance-resolution spine mirroring 5-2's approval flow: a per-tenant variance-threshold policy routes variances to a resolve-capable role (with an Owner notification outbox event when the threshold is exceeded); a resolve command executes approve-adjust (an explicit stock correction via `assertAdjustableInTx`/`applyAdjustmentInTx`) or recount (the recount task's snapshot replaces the variance's expected basis); the resolution references the ledger events the approver considered and is audit-logged.

## Boundaries & Constraints

**Always:**
- Submit still records variances only ('open'); the ONLY stock write is approve-adjust's explicit correction, written as `stock.adjusted` ledger events through `applyAdjustmentInTx` (ledger-as-truth).
- A resolution states whom it consulted: `considered_event_seqs` (ledger seqs) stored on the row, echoed in the audit + outbox events.
- Over-threshold variance (frozen `threshold_quantity` stamped at submit) resolves only by owner.
- `variances.resolve` is held by owner + ops_manager (the counts.execute reviewer floor); over-threshold stays owner-only via the frozen-threshold guard.
- approve-adjust requires the task's frozen `binStateEpoch` to still EQUAL the bin's live epoch (null matches null) — a moved basis means recount, not adjust.
- Recount arm reuses `createRecountTaskInTx` — a recounted variance's expected basis becomes the recount snapshot's line expectation (0 when the bin's on-hand is empty and the line is absent), delta recomputed in the same UPDATE.

**Never:**
- No web UI beyond the capability mirror (30→31) — the Conflicts & Reviews queue surface is 5-5's.
- No mobile change (the count inbox and submit are untouched).
- No new ledger event types for counts; no notification delivery (outbox functional entry only — Epic 9 owns the consumer).
- No policy delete verb (PUT is upsert); no change to 5-3's auto-recount-on-epoch-mismatch submit path.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| resolve approve-adjust | open variance, epoch equal, role holds variances.resolve | 200; variance `adjusted` with resolvedBy/At; stock corrected by signed delta into ledger events | 400 bin not adjustable (assertAdjustableInTx arms) |
| resolve over-threshold as non-owner | \|delta\| > frozen threshold, role ops_manager | refused; state unchanged | 403 variance-owner-required |
| resolve recount | open variance | 200; recount task created (origin 'recount'); expected ← recount snapshot line (0 if absent), delta recomputed; `recounted` | N/A |
| basis moved | approve-adjust, task epoch ≠ live bin epoch | refused; recount is the remedy | 409 variance-basis-moved |
| already resolved | status ≠ 'open' | refused | 409 variance-resolved |
| stale considered seqs | seqs not in tenant's ledger | refused before any write | 400 validation-failed |
| threshold exceeds at submit | tenant policy row exists, \|delta\| > threshold | variance stamped threshold_quantity + outbox `count.variance.threshold_exceeded` (notifyRole owner) | no policy row → disabled, no event |
| queue + policy reads | GET variances (keyset); GET policy unset | 200 list; 404 (mirror GET adjustment-policies) | N/A |
| idempotency | same resolve key, different body | replay or 422 idempotency-key-reuse | 422 |

</frozen-after-approval>

## Code Map

- `src/shared/db/schema.ts` -- add columns `threshold_quantity_milli integer`, `resolved_by uuid`, `resolved_at timestamptz`, `recount_task_id uuid`, `considered_event_seqs jsonb` to countVariances; add `count_variance_policies` (per-tenant single row: `quantity_threshold_milli integer nullable` = disabled; unique(tenant_id)) mirroring stock_adjustment_policies
- `drizzle/0046_variance_resolution.sql` -- drop/re-add `count_variances_status_check` (`'open','adjusted','recounted'`); columns above; CREATE TABLE + `count_variance_policies_tenant_isolation` RLS; deferred indexes `count_variances(task_id)`, `skus(tenant_id, abc_class)` from PENDING; fail-fast guard; snapshot + journal
- `src/modules/movements/count.command.ts` -- submit: read policy once, stamp threshold, append outbox; `resolveCountVariance`: capability → idempotency → variance lock `.for('update')` → 404 → 409 variance-resolved → owner check → epoch-equality guard (`binStateEpochsInTx`) → arm (approve-adjust rebuilds AdjustStockCommand like decideAdjustment's approve arm: `assertAdjustableInTx` then `applyAdjustmentInTx`, ledger seq captured → recount arm `createRecountTaskInTx`) → terminal UPDATE `.where(status='open')` → audit row + outbox `count.variance.resolved` → idempotency LAST
- `src/modules/movements/variance-policy.command.ts` -- new `setVariancePolicy`/`getVariancePolicy` mirroring inventory's setAdjustmentPolicy (capability gate, lock, upsert, audit `count.variance_policy_updated`); queue read `listCountVariances` beside `getCountTasksInTx` in `transfer.facade.ts` (status/warehouse filters, keyset via fullPrecisionInstant)
- `src/api/movements.controller.ts` -- `PUT/GET :tenantId/movements/variance-policies`, `GET :tenantId/movements/variances`, `POST :tenantId/movements/variances/:varianceId/resolve`
- `src/modules/inventory/inventory.facade.ts` + `src/api/inventory.controller.ts` -- optional `binId` filter on the warehouse ledger timeline (fromBin = bin OR toBin = bin) so the approver can pull the bin's history
- `src/modules/tenancy/permissions.ts` -- `variances.resolve`, 31st capability
- `test/` -- pins `client-isolation.spec.ts:660` 54→55, `users.spec.ts:849` 30→31; new count.spec cases for the matrix
- `workspace/core/frontend/wms-fe/src/lib/users.ts` + `users.test.ts` -- capability mirror 30→31

## Tasks & Acceptance

**Execution:**
- [ ] `drizzle/0046_variance_resolution.sql` -- migration + snapshot per checklist -- states, columns, policy table, RLS, deferred indexes
- [ ] `src/shared/db/schema.ts` -- schema columns + new table + doc blocks
- [ ] `src/modules/movements/count.command.ts` -- submit extension + resolveCountVariance (both arms) -- the spine
- [ ] `src/modules/movements/variance-policy.command.ts` + `transfer.facade.ts` + controller -- policy, queue read, routes
- [ ] `src/modules/tenancy/permissions.ts`, pins, FE mirror -- capability 31
- [ ] `inventory.facade.ts`/`inventory.controller.ts` -- binId filter on ledger timeline
- [ ] `test/count.spec.ts` etc. -- cover every matrix row

**Acceptance Criteria:**
- Given an open variance, when resolved approve-adjust, then the bin's on-hand moves by the counted−expected delta as `stock.adjusted` events and the variance carries consideredEventSeqs.
- Given an over-threshold variance, when a non-owner resolves, then 403 and stock is untouched.

## Implementation Notes

## Spec Change Log

## Review Triage Log

## Design Notes

- Resolver set ratified at CHECKPOINT 1 (2026-09-29): owner + ops_manager for `variances.resolve`.
- Direct-write approve-adjust, not a `stock_adjustment_pendings` round-trip: the variance row IS the stored pending (5-2's pend exists because requester ≠ approver; here the approver decides in one step).
- Threshold is frozen on the variance at submit (`threshold_quantity_at_request` precedent) so later policy edits cannot re-write history.
- Epoch guard reuses 5-3's EQUALITY-compare discipline; `epochConflict` variances resolve approve-adjust only after epochs re-equalize.

## Verification

**Commands:**
- `cd workspace/core/backend/wms-be && bun run test -- test/count.spec.ts` -- all pass incl. matrix rows
- `bun run test -- test/client-isolation.spec.ts test/users.spec.ts` -- pins 55 / 31
- `cd workspace/core/frontend/wms-fe && bun run test -- src/lib/users.test.ts` -- mirror 31
- lint + typecheck -- clean

**Manual checks:**
- `drizzle/0046` contains only statement-breakpoint-separated statements incl. fail-fast guard; RLS hand-appended and named `count_variance_policies_tenant_isolation`