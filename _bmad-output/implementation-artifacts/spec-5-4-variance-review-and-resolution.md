---
title: '5-4 Variance review and resolution'
type: 'feature'
created: '2026-09-29'
status: 'done'
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
- [x] `drizzle/0046_variance_resolution.sql` -- migration + snapshot per checklist -- states, columns, policy table, RLS, deferred indexes
- [x] `src/shared/db/schema.ts` -- schema columns + new table + doc blocks
- [x] `src/modules/movements/count.command.ts` -- submit extension + resolveCountVariance (both arms) -- the spine
- [x] `src/modules/movements/variance-policy.command.ts` + `transfer.facade.ts` + controller -- policy, queue read, routes
- [x] `src/modules/tenancy/permissions.ts`, pins, FE mirror -- capability 31
- [x] `inventory.facade.ts`/`inventory.controller.ts` -- binId filter on ledger timeline
- [x] `test/count.spec.ts` etc. -- cover every matrix row

**Acceptance Criteria:**
- Given an open variance, when resolved approve-adjust, then the bin's on-hand moves by the counted−expected delta as `stock.adjusted` events and the variance carries consideredEventSeqs.
- Given an over-threshold variance, when a non-owner resolves, then 403 and stock is untouched.

## Implementation Notes

- Implemented on wms-be `feat/5-4-variance-review-and-resolution` (827939d + 3ef0fc8 + review-patch f342df4) and wms-fe (016a5f0 + review-patch dcabe20). Subagent round 2 added the matrix row-1 error-cell test (retired-bin 400 with full rollback); the step-04 patch round landed 4 new resolve-cell tests + the ledger binId-filter test + 4 command/code corrections + doc/convention fixes.
- `audit_events` has no payload column — the considered-seqs echo lives in the outbox payload; the audit row carries action/target/reference.
- approve-adjust for a batch/serial-tracked or kit SKU answers the guard-set refusal verbatim (400, rollback) — recount is the remedy; the correction always lands as exactly one `stock.adjusted` event (no serial arms possible).

## Spec Change Log

## Review Triage Log

Review pass 1 (step-04, 2026-09-29) — three layers over the 2-commit diff; 35 findings verified first-hand. Verdicts per row; routing groups below.

| # | Lens | Finding | Verdict | Evidence / route |
|---|------|---------|---------|------------------|
| 1 | blind | API-SURFACE.md missing from diff | false | Docs land in step-05 (meta repo last, code before docs); deliberate workflow ordering, not an omission |
| 2 | blind | movements.md missing | false | Same — step-05 docs duty |
| 3 | blind | PENDING.md missing | false | Same — step-05 docs duty |
| 4 | blind | repo README contracts missing | false | Same — step-05 docs duty |
| 5 | blind | Command docstring claims per-seq validation that lives in the DTO | low | True: shape checks cover max-count + approve-arm non-empty only; per-seq IsInt/Min ride the wire DTO. Patch — fix the docstring |
| 6 | blind | count_variance_policies doc block implies only over-threshold rows stamped | low | Verified :3047 text; submit stamps every row the policy covers. Patch — comment |
| 7 | blind | task_id index justification wrong (resolve reads countTasks by PK) | low | Verified: the guard reads countTasks.id (PK). Index serves variances-by-task reads (PENDING's rationale). Patch — comment |
| 8 | blind | At-threshold boundary (\|delta\| == threshold) untested | medium | Strictly-greater documented, no test pins it; a >= drift would be silent. Patch — test |
| 9 | blind | Reordered-seqs replay never observed | medium | Same root as VG-2. Patch — test |
| 10 | blind | Kit/serial/batch refusal arms untested | low | Same guard-set mechanism as the tested bin-retired arm; no distinct code path. Reject — unlikely met, duplicate of proven path |
| 11 | blind | Cross-warehouse seq rejection untested | medium | Probe scopes variance.warehouseId; only a nonexistent seq is tested. Patch — test |
| 12 | blind | Recount arm with stated seqs untested | low | Recount-with-seqs branch stores/echoes but no test. Patch — assert in recount test |
| 13 | blind | Outbox echo carries [] vs row's null for no-statement | low | Verified: payload always carries statedSeqs ([] on recount-none). Patch — echo null |
| 14 | blind | Re-basis delta can exceed threshold post-recount | false | Recomputed delta gates nothing — the row is terminal, no resolution decision rides it; the recount's own submit writes fresh variances that re-route normally |
| 15 | blind | status typed bare string despite COUNT_VARIANCE_STATUSES | low | Entry + DTO field use string. Patch — type |
| 16 | blind | @IsInt missing on policy DTO threshold | low | 5-2's AdjustmentPolicyDto mandates @IsInt ("load-bearing"); 5-4 deviates. Patch — decorator |
| 17 | blind | Policy fingerprint: absent vs null differ | false | Controller normalizes `dto.quantityThreshold ?? null` before the command — both arrive null, same hash |
| 18 | blind | Resolve fingerprint omits tenantId vs policy's | false | No bad outcome: idempotency keys are unique per (tenant_id, key); lookup filters by tenant — hash-side tenantId is redundant; convention varies repo-wide |
| 19 | blind | List route OpenAPI response type wrong-shaped | medium | 5-2 declares a real list envelope (AdjustmentPendingListResponse); 5-4 annotates a single-row type. Patch — envelope class |
| 20 | blind | Dead `!== undefined` guard in submit event loop | low | thresholdMilli comes from `?? null`, never undefined. Patch — simplify |
| 21 | blind | varianceBasisMoved reports the frozen epoch param as "live" | low | Caller passes task.binStateEpoch; diagnostic misleads. Patch — rename param + message |
| 22 | blind | binId ledger filter has no supporting index | low | True (OR on from/to bin). New read arm with no consumers yet; fix = a migration + 2 indexes. Reject — unlikely met; weigh at 5-5's read pattern (note for step-05 PENDING update) |
| 23 | blind | count-task-open 409 text not scoped to the recount arm | low | Approve-adjust under an open sibling task is legal; contract text says otherwise. Patch — description |
| 24 | blind | Duplicate assertion in FE users.test | low | owner.length 31 asserted twice. Patch — remove |
| 25 | blind | Trailing newlines: 0046.sql, variance-policy.command.ts; movements.module.ts | low | 0045 ends with newline; the two NEW files must match; movements.module.ts pre-existing (false for that file). Patch — two files |
| 26 | edge | Multi-arm recount: limit(1) arbitrary line | false | onHandInBinInTx reads stock_on_hand, one row per (sku, bin) — recount lines are unique per SKU; limit(1) is deterministic |
| 27 | edge | Replay returns snapshot before the owner guard | low | Real order (capability → replay → guard), but replay serves already-stored data, all visible via the ungated queue read; no mutation re-executed. Reject — unlikely met; fix would add a guard re-run the 5-2 discipline does not carry |
| 28 | edge | Empty-string threshold coerces to 0 by @Type(() => Number) | low | House pattern: 5-2's @IsInt DTO has the same coercion hole. Defer — pre-existing validation-convention gap, shared fix across both policy DTOs |
| 29 | edge | Migration fail-fast guard misses partial-application state | low | Drizzle runs each migration file in one transaction — a mid-file failure rolls back the whole file; the guard's reviewed 0044/0045 shape covers rerun/missing-prior. Reject — the partial state requires manual surgery |
| 30 | edge | epochConflict variances still notify the owner | false | The frozen intent routes over-threshold variances to the Owner with no epoch carve-out; the recount arm IS the remedy the command documents |
| 31 | edge | Retired-bin test sends the full ledger walk (200-cap risk) | low | Fragile against ledger growth — wrong error cell on failure. Patch — slice(0, 200) |
| 32 | vg | binId filter has no verifying test | medium | Verified: no test sends binId anywhere; the OR filter could no-op invisibly. Patch — ledger.spec test |
| 33 | vg | Order-insensitivity of consideredEventSeqs never observed | medium | Only a byte-identical replay is tested. Patch — reorder/duplicate retry test |
| 34 | vg | Foreign-token fence untested on the two new GET routes | medium | Verified: otherTenantToken never hits them; the sole cross-tenant fence untested. Patch — fences test |
| 35 | vg | FE generated SDK stale for the binId param | defer | True but the consumer is 5-5's; the drift guard only compares capabilities. Regen with the consumer story |

Review patch round applied and verified (2026-09-29, BE `f342df4`, FE `dcabe20`): the 19 patch rows above are all fixed and re-verified first-hand — count.spec 58/58 (4 new resolve-cell tests + hardened retired-bin), ledger.spec +1 (binId filter), users + client-isolation 56 pass, FE users.test 19/19, `tsc --noEmit` + eslint clean. Rows 22/28/35 remain deferred (deferred-work.md).

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