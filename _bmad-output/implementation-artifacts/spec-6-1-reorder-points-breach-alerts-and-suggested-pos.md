---
title: '6.1 Reorder points, breach alerts, and suggested POs'
type: 'feature'
created: '2026-10-01'
status: 'in-progress'
route: 'dispatch'
baseline_commit: '8604e03'
review_loop_iteration: 1
context:
  - '_bmad-output/implementation-artifacts/epic-6-context.md'
  - 'docs/design/SYSTEM-DESIGN.md'
  - 'docs/design/IMPLEMENTATION-GUIDE.md'
  - 'docs/design/modules/catalog.md'
  - 'docs/design/modules/inventory.md'
  - 'docs/design/modules/inbound.md'
  - 'docs/design/frontend/SYSTEM-DESIGN.md'
  - 'docs/design/frontend/IMPLEMENTATION-GUIDE.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** The columns exist (`skus.reorder_point`/`reorder_qty`, editable tenant-wide in the SKU table for epics) but nothing ever reads them — no breach detection, no alert, no suggested PO. Stockouts are discovered on the floor instead of prevented. FR-22 also promises the alert within 5 minutes of ATP breach and a draft PO "from default vendors and quantities", editable before submission, never auto-submitted.

**Approach:** Populate the `replenishment` spine module (story 1.1 placeholder): a per-warehouse reorder-policy table over the SKU columns (per-warehouse override wins, tenant-wide SKU columns stay the fallback), a scheduled worker that re-reads ATP through the inventory core and on breach opens an alert row + pre-drafts a suggested PO, and the `/replenishment` web surface: the breach list with its suggested PO drafts (editable vendor + quantity), submit and dismiss, plus the inline-editable policy table. The system never auto-submits — the ONLY writer of a real PO is the human-triggered submit command, re-executed through the inbound module's PO-creation path.

## Boundaries & Constraints

**Always:**
- ATP is read ONLY via `InventoryFacade.atp()` — replenishment never touches stock tables, projections, or the ledger (the architecture spine; tests pin a module block).
- Every command follows the skeleton (capability at command-service entry → fingerprint → replay lookup → guards → tx → audit/outbox → idempotency LAST); background work takes explicit tenant context (AD-3) and is sheddable (AD-17).
- Quantities are base-UoM milli-units (10.1 model); millisecond-inaccurate inputs are refused at the boundary with the house problem shape.
- Alerts emit outbox events carrying a `notifyRole` hint in the payload (the `count.variance.threshold_exceeded` precedent) — the entry contract Epic 9's panel will read.

**Never:**
- No notification panel/bell surface, no `/notifications` work (Epic 9); no mobile surface.
- No change to the PO lifecycle (`purchase_orders` stays `open|closed`; suggested POs are replenishment's own draft tables); no vendor schema change.
- No auto-submission path exists anywhere (the worker drafts; it never calls PO create).
- No seasonality/temporal reorder model (later tier per the epic's amendment note); the policy schema must not preclude one but nothing seasonal ships.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|---|---|---|---|
| Policy upsert | `{warehouseId, skuId, reorderPoint, reorderQty}` (milli, > 0), `Idempotency-Key` | 200 snapshot (upsert last-write-wins, variance-policy precedent) | Unknown/foreign warehouse or SKU → 404; non-milli/non-positive → 400 `validation-failed` naming the field |
| Effective point | No per-warehouse row for (w, sku) | The SKU's tenant-wide `reorder_point` is the effective point | SKU point 0 → no breach evaluation for that (w, sku) |
| Worker sweep, ATP below point | No active breach for (tenant, w, sku) | New breach row + suggested-PO draft + outbox `replenishment.breach_detected` (audit row too) | ATP read fails (e.g. 503 `reservation-store-unavailable`) → skip scope, log, retry next tick — NEVER read as ATP 0 |
| Worker sweep, already active breach | Active breach exists | No-op (partial unique absorbs; no duplicate event, no second draft) | N/A |
| Worker sweep, ATP ≥ point | An open breach exists | Breach → `recovered` (`resolved_by` null), draft kept as a draft | N/A |
| Multiple default vendors | ≥ 2 `vendors.is_default = true` rows | Draft stamps deterministically: min `(created_at, id)` | N/A |
| Draft, no default vendor | Zero `is_default` vendors | Draft created with vendor **null** (the breach is still drafted evidence) | Submit refuses 400 `suggested-po-vendor-required` until a vendor is chosen |
| Submit suggested PO | `{vendorId?, quantityMilli?, }` (edits optional), fresh ULID key | Real PO minted via the inbound create path (caller-minted `PO-` code), draft → `submitted` + `submitted_po_id`, breach → `actioned` | Unknown/foreign draft → 404; not `draft` → 409 `suggested-po-submitted`; vendor still null → 400 (above); inner `po.manage`/PO-guard refusal (vendor gone, SKU gone) → refusal verbatim, draft stays draft row open. Non-milli/non-positive qty → 400 |
| Dismiss breach | `discarded` decision on an open breach | Breach → `dismissed`; its draft stays a draft (dismissal is about the breach, not the draft) | Unknown/foreign → 404; not `open` → 409 `breach-not-open` |
| List reads (policies / breaches / drafts) | keyset + status filters | `limit` clamped server-side | `limit=abc` → 400 naming the query (the 5-6 `@IsNumber/@Min/@Max` boundary convention) |

### Resolved decisions (user-ratified 2026-10-01, "take all recommended")

- **Capability:** one new `replenishment.manage` (owner + ops_manager) covering policy upsert/delete, breach dismiss, and suggested-PO submit; the submit arm re-executes PO creation under `po.manage`, so the inbound gate stays live.
- **Breach lifecycle:** `open → recovered` (worker sees ATP ≥ point) / `actioned` (its PO submitted) / `dismissed` (human) — all terminal; a later re-breach opens a NEW row (partial unique on active state only).
- **Draft gating:** a suggested-PO draft is minted exactly when a breach OPENS — one artifact per breach event, no drafting on subsequent sweeps.

</frozen-after-approval>

## Code Map

**Backend (wms-be):**
- `src/modules/replenishment/replenishment.module.ts` — the empty spine placeholder; this story populates it (commands, facade, migration 0048).
- `src/modules/inventory/inventory.facade.ts:1210` — `InventoryFacade.atp(tenantId, warehouseId, skuId)` → `AtpSnapshot {onHand, reserved, qcHeld, inTransit, buffer, atp}` (milli-units; `reservation.service.ts:635`). Plain read, **fallible 503** when Valkey is down — the worker skips, never assumes 0.
- `src/modules/catalog/catalog.facade.ts:228` — `findSku` (SKU-in-tenant assert). `SkuSummary` does NOT carry reorder fields — add one narrow facade read (`getSkuReorderDefaults(tenantId)` → `{id, code, name, uom, reorderPoint, reorderQty}`; additive, no breaking change).
- `src/modules/inbound/inbound.facade.ts:118` — `createPurchaseOrder` → `po.command.ts:171` (`po.manage`, idempotent, in-tx asserts warehouse/vendor/sku, caller-minted `code`, lines `{skuId, orderedQty, unitCostPaise}`; statuses `open|closed` only). Code-mint convention for the submit arm: `PO-${ulid().slice(10, 18).toUpperCase()}` (the test fixture's house shape). The submit arm mints through an **in-tx variant** of this command (`createPurchaseOrderInTx(tx, …)` — the `findDefaultVendorInTx` house shape) — see Design Notes; NEVER a second transaction inside a held one (the `putaway.facade.ts:221-224` pool-deadlock shape).
- `src/shared/db/schema.ts:1378` — `vendors` (`is_default` boolean, NO single-default unique, NO demote-previous logic → several defaults possible; deterministic pick required). `schema.ts:464-465` — `skus.reorder_point`/`reorder_qty`, bigint mode:number, milli-units, tenant-wide defaults.
- `src/jobs/jobs.module.ts:310` — `CountSchedulerWorker` is the worker template: `parseXPollMs` (unset/0 = OFF, boot-loud on garbage), AUTH_DATABASE `distinct on (tenant_id, warehouse_id)` enumeration (`:351-357`), per-scope tenant tx with catch/log/skip per scope (a poison warehouse never starves the rest).
- `src/modules/tenancy/permissions.ts:182` — role sets; add the new capability to the tuple + `ops_manager` set + a "Mirrored into wms-fe" comment.
- `src/api/api.module.ts:62` controllers array + `src/app.module.ts` imports (ReplenishmentModule already registered) — routes land under `/api/v1/tenants/{t}/replenishment` (PUT variance-policies is the route-shape precedent).
- `test/client-isolation.spec.ts:644` — the hard policy-count pin `toHaveLength(56)` → **59** (three new RLS tables) with the extended migration-history comment.
- `test/architecture.spec.ts:116,165` — a new module needs its own "no writes outside the module" + "siblings reach it only through the facade" blocks (the standing rule).
- Migration numbering: next is `0048` (highest 0047); RLS + CHECKs live ONLY in migration SQL, never drizzle-declared.

**Frontend (wms-fe):**
- `src/app/(app)/replenishment/page.tsx` — the literal SurfacePlaceholder this story replaces; nav entry already sits in `src/lib/navigation.ts` `NAV_ITEMS` (add the capability gate).
- `src/components/data-table/data-table.tsx` — the dense table primitive (cursor Prev/Next only, sticky header, `renderExpanded`).
- `src/components/settings/sku-table.tsx:289-360` — the inline-edit cell precedent for reorderPoint/reorderQty (`parseQuantityInput`, `inputMode="numeric"`).
- `src/lib/use-catalog.ts` `useSkus()` — the canonical cursor-page hook shape (`ResourceState` + `Reloadable`).
- `src/lib/api/client.ts` — `fetchApiX` wrappers + `ApiProblem {code, status, detail, title}`; `src/lib/outbound-orders.ts:379` — the read-reason mapper pattern; `adjustment-pendings-queue.tsx:147-165` — the command error contract (409 → `queue.reload()`, guard-class refusals verbatim, row stays pending).
- `src/lib/users.ts` — `CAPABILITIES` 31 → 32; `bun run check:capability-mirror` keeps BE/FE honest.
- Data flow: `bun run api:generate` against this backend's exported `openapi/openapi.json` (the FE drift guard stays red until BE merges).

## Tasks & Acceptance

**Execution:**
- [x] `wms-be` migration `drizzle/0048_*.sql` + `src/shared/db/schema.ts` — three tables: `reorder_policies` (UNIQUE `(tenant_id, warehouse_id, sku_id)`; `reorder_point_milli`/`reorder_qty_milli` bigint > 0 CHECKs migration-only), `reorder_breaches` (UNIQUE active-only per `(tenant_id, warehouse_id, sku_id)` via partial index; `status` CHECK `open|recovered|actioned|dismissed`; `point_milli`/`atp_milli` frozen at detection; `breach_at`/`resolved_at`/`resolved_by`), `suggested_pos` (UNIQUE `draft`-only per `(tenant_id, warehouse_id, sku_id)` partial; `vendor_id` nullable; `quantity_milli`; `breach_id` bare uuid; `status` CHECK `draft|submitted|dismissed`; `submitted_po_id` nullable) — fail-closed RLS ×3, keyset indexes.
- [x] `wms-be` `src/modules/replenishment/replenishment.command.ts` + `replenishment.facade.ts` — `upsertReorderPolicy`, `deleteReorderPolicy` (404 when absent), `listReorderPolicies`, `listBreaches`, `dismissBreach`, `listSuggestedPos`, `submitSuggestedPo` (the frozen command order; the submit arm re-executes PO creation via the inbound facade's **in-tx variant inside its own held transaction** — one connection; the deterministic inner idempotency key `replenishment-submit-po-<draftId>` stays). The controller's submit response carrier is the **FLAT PO snapshot**: `body.purchaseOrder` IS the PO (`{id, code, status, vendorId, warehouseId, lines…}`), not the facade's wrapped `{purchaseOrder: {…}}` (that wrap made the FE read `undefined` and silently drop the minted code).
- [x] `wms-be` `src/jobs/jobs.module.ts` — `ReplenishmentSchedulerWorker` (env `REPLENISHMENT_SCHEDULER_POLL_MS`, the CountSchedulerWorker shell: scope enumeration from reorder policies ∪ tenant-wide defaults' warehouses, per-scope catch/log/skip, ATP via the facade, breach open/recover transitions, draft-on-open). The tick's scope loop carries a **per-tick scope cap** (the count scheduler's `MAX_SCHEDULED_TASKS_PER_TICK` precedent) with a truncation log line — the frozen ≤5-min visibility bound stays honest at scope counts larger than one tick can carry.
- [x] `wms-be` `src/modules/catalog/catalog.facade.ts` — the additive `getSkuReorderDefaults` read.
- [x] `wms-be` capabilities: `replenishment.manage` in the tuple + `ops_manager` set (+ FE-mirror comment); api-shell `ReplenishmentController` (thin DTO mapping, `assertOwnTenant` per method); `bun run openapi:export`.
- [x] `wms-be` `test/replenishment.spec.ts` — the I/O matrix cells as e2e (upsert/refusals, worker tick breach/recover/no-op with faked ATP, deterministic default-vendor pick, vendor-null draft + submit refusal, submit happy path asserting the real PO + `actioned` + events, dismiss, 409 arms, foreign-tenant 404, RLS probe); a **worker-tick plumbing test** exercising `ReplenishmentSchedulerWorker.tick()` against a faked facade (the count scheduler's block, `count.spec.ts:2112-2260` precedent — `sweepScope`-direct tests do not execute the tick); `test/client-isolation.spec.ts` pin 56 → 59; `test/architecture.spec.ts` module block.
- [x] `wms-fe` `src/lib/users.ts` — capability 31 → 32 + `users.test.ts` pin.
- [x] `wms-fe` — `bun run api:generate`, wrappers (`src/lib/api/client.ts`), `src/lib/use-replenishment.ts` hooks, `src/lib/replenishment.ts` reason mappers; replace `replenishment/page.tsx` with the surface — the breach list with draft cards (vendor picker + editable qty, submit/dismiss), the policy table with inline-edit cells (sku-table precedent) over both per-warehouse rows and SKU defaults, `NAV_ITEMS` capability gate; component tests pinning the error contract (409 → reload, verbatim refusals) and the submit-never-auto claim (no submit call except on click).

**Acceptance Criteria:**
- Given ATP for (w, sku) falls below its effective point, when the worker next ticks, then a breach row, a suggested-PO draft, a `replenishment.breach_detected` event and an audit row exist, and the surface shows the breach — the whole detection-to-visibility loop is bounded by the poll interval (FR-22's ≤ 5 min when `REPLENISHMENT_SCHEDULER_POLL_MS ≤ 300000`).
- Given a drafted suggested PO, when the Ops Manager edits vendor/quantity and submits, then a REAL PO exists on the inbound path with the edited values and the breach reads `actioned`; when instead ATP recovers by the next tick, the breach reads `recovered` — and in NEITHER case does any write path other than the human-triggered submit command create a PO.
- Given a Valkey outage mid-sweep, when ATP reads fail, then scopes are skipped with a logged warn and resumed next tick — no false breach is minted while the reservation store is down.
- Given a role without `replenishment.manage`, when it hits any command, then 403 `role-denied` names the capability; lists stay open to members.

## Design Notes

- **The per-warehouse override wins; the SKU columns are the fallback** — the two sources are deliberate: `skus.reorder_point/qty` (tenant-wide, existing UI in the SKU table) stays the default; `reorder_policies` rows are the per-warehouse exception. Effective point = policy row ?? SKU column; SKU column 0 disables breach evaluation for that (w, sku) unless a policy row overrides.
- **Worker scope enumeration** must cover warehouses that have ONLY tenant-wide SKU defaults (no policy rows): enumerate distinct `(tenant, warehouse)` from `reorder_policies` UNION warehouses of tenants carrying any SKU default > 0 — implement as two queries, not one guess; a scope whose SKUs all read effective point 0 short-circuits.
- **Draft quantity**: effective `reorder_qty` when > 0, else the recovery gap `ceil((point − atp))` in milli-units — the draft always names a fillable quantity.
- **Events are audit-adjacent, not delivery**: `replenishment.breach_detected` payload `{breachId, warehouseId, skuId, atpMilli, pointMilli, breachAt, notifyRole: 'ops_manager'}`, `replenishment.suggested_po_submitted` `{suggestedPoId, poId, poCode, warehouseId, vendorId, quantityMilli}`. Nothing consumes them today (the relay only logs — verified); Epic 9 owns the panel. NO event on recovery (surface-visible state change only).
- **The submit arm is the apply-arm pattern, executed in-tx**: replenishment's command orchestrates inside ONE held transaction, the inbound command remains the only PO writer and re-asserts `po.manage` on the re-execution — through the inbound facade's **in-tx variant** (`createPurchaseOrderInTx(tx, …)`, the `findDefaultVendorInTx` house shape), so the mint happens on the SAME pooled connection: a nested second transaction while one is held is the documented pool-deadlock shape (`putaway.facade.ts:221-224`, pool `max: 10`) and is prohibited on this path. (An earlier draft of this note claimed the sync-report apply arm as an inner-transaction precedent — withdrawn: sync-report calls no facade and writes in the caller's tx, `sync-report.command.ts:534-560`.) Single-transaction atomicity removes the inner-commits-outer-rolls-back window the deterministic key was absorbing; the deterministic inner idempotency key (`replenishment-submit-po-<draftId>`) stays — harmless, and it keeps the mint reproducible.
- **Re-breach repoint semantics** (stated explicitly after review): when a NEW breach opens for a (tenant, warehouse, sku) whose old draft is still `draft`, the standing draft is REPOINTED — the fresh breach's vendor/quantity REPLACE whatever a planner had left on it. A draft is always a system-fresh suggestion; nothing preserves stale edits. (Spec-impl alignment: `reorder_breaches` carries the breach instant in the shared `created_at` column, not a separate `breach_at` — the audit trail and event payload name it `breachAt`.)

## Verification

**Commands:**
- `cd workspace/core/backend/wms-be && bun run test -- test/replenishment.spec.ts && bun run lint && bunx tsc --noEmit && bun run db:verify && bun run openapi:export` -- expected: suite green, migration verified, three routes+ reads exported
- `cd workspace/core/backend/wms-be && bun run test` -- expected: FULL suite green (the client-isolation 59-pin is only proven here)
- `cd workspace/core/frontend/wms-fe && bun run api:generate && bun run lint && bun run test` -- expected: regen clean, mirror check passes, new surface tests green

## Implementation Notes

- Implemented on BE/FE `feat/6-1-reorder-points-breach-alerts-and-suggested-pos` branches (4 commits each); not pushed.
- Verification evidence (2026-10-01): BE lint, `tsc --noEmit`, `db:verify`, `openapi:export` green; BE e2e `test/replenishment.spec.ts` green; FULL BE jest suite green **on the re-run** (51/51 suites, 989/989 tests) — the first run's only failures were 29 load-timeout `beforeAll` hooks in the unrelated story-5-1 `transfer.spec.ts` (proven 29/29 green in isolation immediately after); FE lint + 590-test suite (14 new component tests) green; `api:generate` regen produced no diff; capability mirror check passes (32 across roles).
- Deviation (recorded): the sweep's recovery-gap draft quantity ceils to WHOLE base units (`Math.ceil(gap/1000)*1000`), stricter than the spec's raw-milli wording — the PO's precision guard could refuse a fractional-base mint; the draft "always names a fillable quantity" is preserved.
- Deviation (recorded): the submit arm's PO code derives from the draft's uuid (`PO-` + last 8 hex of the draft id, uppercase) instead of a fresh ULID — the inner apply-arm's idempotent replay requires a deterministic payload; same visible shape.
- The sweep's audit rows use the module-reserved actor constant `REPLENISHMENT_SCHEDULER_ACTOR_ID` (`01900000-…`) because `audit_events.actor_user_id` is NOT NULL and no system-actor user exists; documented in-code, never sign-in-able.

## Spec Change Log

- 2026-10-01 — bad_spec loop (step-04 pass 1, review_loop_iteration 1). **Triggering finding:** the submit arm (`replenishment.command.ts:645-668` in the reviewed diff) calls `InboundFacade.createPurchaseOrder` INSIDE its own held `withTenantTransaction`, while the inner command opens its own transaction on a second pooled connection (postgres.js reserved session, pool `max: 10` per `db.ts:12`) — the documented pool-deadlock shape (`putaway.facade.ts:221-224`). Enough concurrent submits hang the pool with no timeout. The design note claiming "the sync-report/5-2 precedent" is FALSE — sync-report's apply arm calls no facade and writes in the caller's tx (`sync-report.command.ts:534-560`). **Known-bad state avoided:** a nested-transaction PO mint on the replenishment path, plus a spec note asserting a precedent that does not exist.
  **Amendments:**
  1. Design Notes — the submit arm mints the PO through an **in-tx inbound variant** (`createPurchaseOrderInTx(tx, …)` in the inbound facade, mirroring the `findDefaultVendorInTx` house shape) INSIDE the submit command's own held transaction — one connection total; single-tx atomicity makes the separate-inner-tx absorb-net framing unnecessary (the deterministic inner idempotency key stays, harmless). The false sync-report sentence is withdrawn.
  2. Task (submit command) — the controller's submit response carrier is the **FLAT PO snapshot**: `body.purchaseOrder` IS the PO (`{id, code, status, vendorId, warehouseId, lines…}`), not the facade's wrapped `{purchaseOrder: {…}}`. The prior wrap made the FE read `undefined`. BE e2e assertion and FE stubs pin the flat shape.
  3. Task (worker) — the tick's scope loop carries a **per-tick scope cap** (the count scheduler's `MAX_SCHEDULED_TASKS_PER_TICK` precedent) plus a truncation log line, so the frozen ≤5-min visibility bound stays honest at scope counts larger than one tick can carry.
  4. Task (tests) — a **worker-tick plumbing test** (the count scheduler's block, `count.spec.ts:2112-2260` precedent) exercises `ReplenishmentSchedulerWorker.tick()` against a faked facade — the reviewed build exercised only `sweepScope`.
  **KEEP instructions (what worked and must survive re-derivation):** migration 0048's table shapes/partial uniques/CHECKs/fail-closed RLS as written; the three-phase sweep structure (candidates tx → ATP reads strictly OUTSIDE any tx → transitions tx with fresh point re-reads) and the recovery-gap ceiling to whole base units; the deterministic default-vendor pick (min `(created_at, id)`); the catalog `getSkuReorderDefaults[InTx]` and inbound `findDefaultVendorInTx` additive facade reads; the full command-skeleton ordering in the other five commands; the client-isolation pin 56→59 and the architecture module block; the FE capability mirror 32-count, cursor-stamped-with-scope hooks, ApiProblem reason mappers, in-flight Set guards, the 409→reload / verbatim-refusal contract tests, and the submit-never-auto pin; preserve the `listPurchaseOrders` facade docblock (it was wrongly consumed by the new facade read); reword the 0048 comment that claims drizzle-kit is blind to partial uniques (the snapshots at `drizzle/meta/0009-0011` record `where` clauses — the hand-append pattern's justification is CHECKs and RLS only); record the re-breach repoint semantics explicitly (a standing draft's vendor/quantity are REPLACED by the fresh breach's defaults — a draft is always a system-fresh suggestion).

## Review Triage Log

All three review layers reported 2026-10-01 against `/tmp/6-1-review.diff` (baseline `8604e03`). Every finding verified first-hand at its cited location before this verdict. Overlapping findings from different lenses are kept as separate rows and grouped.

**Group A — submit response wire shape (medium).**
- [blind] Submit response shape mismatch (`replenishment.controller.ts` submit route / `replenishment-view.tsx:268-273`) — **medium** — verified: the controller assigns the facade's WRAPPED snapshot (`po`), so the wire serves `purchaseOrder.purchaseOrder.{…}` (the BE e2e asserts `submitted.body.purchaseOrder.purchaseOrder.status`, `test/replenishment.spec.ts:668,687-696`), while the FE reads flat `res.purchaseOrder.code` → undefined; the success copy silently drops the minted PO code. FE test stub returns the flattened shape (`replenishment-view.test.tsx:162`), hiding the mismatch from the FE suite. → folded into the bad_spec amendment (2).
- [blind] `SubmitSuggestedPoResponse.purchaseOrder` typed `@ApiProperty({ type: Object })` — **medium** — verified: untyped carrier is what let the wrapped snapshot ship as the contract; generated FE type carries no shape the view could have been held to. → group A, same root.
- [edge] FE reads `res.purchaseOrder.code` one level high — **medium** — same defect as row 1 (verified identical). → group A.

**Group B — nested transaction on the submit arm (medium) — BAD_SPEC TRIGGER.**
- [blind] Submit arm calls `createPurchaseOrder` inside a held tx (`replenishment.command.ts:645-668`) — **medium** — verified: inner command opens its OWN `withTenantTransaction` (`po.command.ts:191`); postgres.js reserves a second pooled connection; pool `max: 10` (`db.ts:12`); the hazard shape is documented in-repo from a real incident (`putaway.facade.ts:221-224`). Enough concurrent submits hang the pool, no timeout. → bad_spec.
- [blind] The cited "sync-report precedent" does not exist — **medium** — verified: `sync-report.command.ts:534-560` opens ONE transaction and calls NO facade; the apply arm writes in the caller's tx. The spec's Design Notes asserted this precedent as load-bearing support for the nested shape. → bad_spec (same entry).
- [edge] Same nested-transaction claim (command entry, `tx.begin` inside held tx) — **medium** — verified identical. → bad_spec (same entry).

**Group C — the worker tick is unbounded (medium) — folded into the bad_spec amendment.**
- [blind] Worker scope enumeration unbounded, no per-tick cap, and the loop untested (`jobs.module.ts` ReplenishmentSchedulerWorker) — **medium** — verified: the tick loops ALL scopes serially, no cap; tests exercise only `sweepScope` directly (`test/replenishment.spec.ts:26,296,638`); `tick()` never executed. → group C (bound half) + the verification-gap row (testing half).
- [edge] Sweep loop carries no candidate or time cap — **medium** — verified identical. → group C.
- [edge, claim] Frozen acceptance promises detection-to-visibility bounded by the poll interval; an unbounded serial sweep does not guarantee it at scope counts > one tick can carry — **medium** — verified: structurally true; the cap in the amendment restores honesty. → group C.

**Verification-gap rows (pre-verified by that layer's evidence).**
- [v-gap] `ReplenishmentSchedulerWorker.tick()` never executed by any test — **medium** — the plumbing block that protects every other worker (count scheduler precedent, `count.spec.ts:2112-2260`) was not mirrored; a regression to `tick()` would silently stop production breach detection. Filed disposition: patch. → folded into the bad_spec amendment (4).
- [v-gap] FE nav gate unpinned in `navigation.test.ts` — **low** — the conflict/outbound capability gates each carry a four-role pin precedent; `replenishment.manage`'s gate has none, so a role-set edit could silently add or drop the surface. Filed disposition: patch. → folded into the FE re-derivation KEEP.
- [v-gap, other] Draft-derived PO code could collide with an existing tenant PO code; deterministic retry regenerates the SAME code, so the draft would 409 forever — **low** — real but ~2^32 code space per tenant; never met in everyday use; the fix (collision-remint loop) adds branching. → rejected.

**Blind-hunter rows (individual verdicts).**
- [blind] `suggested_pos`'s `dismissed` status is a dead arm — nothing produces it; the FE drafts queue renders an always-empty Dismissed tab — **low** — cosmetic; the smallest fix removes vocabulary the spec's task text names (spec edit) plus a CHECK churn. → rejected; noted as cleanup material for 6-2.
- [blind] Re-breach repoint overwrites planner edits on a standing draft (`replenishment.sweep.ts:279+`) — **low** — verified the repoint replaces vendor/quantity with fresh defaults; the semantics (not the code) are the gap — the spec never stated them. Recorded explicitly in the Design Notes via this pass's amendment. → handled inside the bad_spec amendment.
- [blind] `unitCostPaise: 0` hardcoded on the minted PO — **low** — verified; v1 has no price source and the draft deliberately carries none; the PO is amendable on the inbound path after mint. → rejected.
- [blind] `parseMilliInput('0')` returns 0, not null — **false** — verified against the wrapper contract (`replenishment.ts:21`): grammar-admitted values go to the server, whose positivity refusal is the documented authority; the surface renders the server's own words. The bad outcome ("client refuses 0 promised") is contradicted by the shipped contract wording.
- [blind] `recoveryGapMilli` docstring says "≤ the gap" while `Math.ceil` overshoots — **low** — verified (`replenishment.sweep.ts:259-261`); the comment's direction is wrong. Direct one-word correction. → folded into re-derivation KEEP (comment reword).
- [blind] Reserved audit actor constant documented only in a code comment — **false** — the spec's Implementation Notes already record it (this spec, "Implementation Notes", actor-constant deviation paragraph); the claim of comment-only documentation is disproved.
- [blind] Meta-repo docs duty absent from the diff — **false** — the docs duty (API-SURFACE, module doc, repo contracts, PENDING) lands at step-05 by the story workflow; the implementation diff is not the artifact that carries it.
- [blind] `REPLENISHMENT_SCHEDULER_POLL_MS` undocumented outside code — **false** — house-consistent: no sibling scheduler env var (`COUNT_SCHEDULER_POLL_MS`, `OUTBOX_RECONCILE_POLL_MS`) is documented outside code comments either (greps returned nothing in docs/README).
- [blind] Sweep re-reads the whole tenant SKU-default table per warehouse scope, serial — **low** — verified (`replenishment.sweep.ts:115`); negligible at v1 tenant scale; the fix (cross-scope batching) is restructuring, not a correction. → rejected.
- [blind] No index serves the status-less default list reads — **false** — every production read carries the dimension its index leads on: policies fetch with warehouseId (FE passes it always), breaches and drafts fetch with status (the tabs). Status-less reads occur only in tests and the transient FE moment before a warehouse is picked, over tenant-partitioned row counts.
- [blind] `DELETE /policies` carries a required JSON body; it is the ONLY `@Delete` route in the API and the carriers controller documents "every destructive verb is a POST" (`carriers.controller.ts:60`) — **low** — verified; the route works through the generated client; the fix is a public route reshuffle (POST marker route + client regen), more than a direct correction. → rejected; the API-SURFACE doc at step-05 records the shape honestly.
- [blind] Nav gate hides the surface from read-only members though list reads stay member-open — **low** — verified; the gate is spec-authored (Code Map names it) and the intended read-only entry point is Epic 9's panel. Removing it is a spec edit. → rejected.
- [blind] 0048's comment claims drizzle-kit is blind to partial uniques, but `drizzle/meta/0009-0011` snapshots record `where` clauses on partial uniques — **low** — verified; the pattern still verifies green (`db:verify`), the comment's justification is just overbroad (it is accurate for CHECKs and RLS). Direct comment correction. → folded into re-derivation KEEP.

**Edge-hunter rows (individual verdicts).**
- [edge] `sweep.ts:267-273` early return on `quantityMilli <= 0` skips the outbox event + audit for a counted breach — **false** — the branch is unreachable: a breach means `point > atp ≥ 0`, the recovery gap ceils to ≥ 1000 milli (whole base units), and `effectiveQtyMilli > 0` is guarded before it — `quantityMilli > 0` always on this path; the warn-and-skip arm can never fire. Unreachable code failing loudly is correct behavior, not a defect.
- [edge] `draftedPoCode` collision makes a draft permanently 409 on retry — **low** — verified mechanism (deterministic code, no remint) but ~2^32 per-tenant code space; same claim as the v-gap "other" row. → rejected.
- [edge] FE `policyBySku` maps only the first policy page against the full SKU map — over-limit overrides render as SKU defaults (`replenishment-view.tsx:700-705`, `useSkuMap` fetches ALL pages) — **low** — verified; needs >50 override rows to manifest; fix restructures the map's data source. → rejected; noted for Epic 9 polish.
- [edge] inner-`duplicatePoCode` 409 `conflict` is conflated with the concurrent-write 409 — same code, indistinguishable at the FE — **low** — verified, but it only manifests with the (rejected) code-collision; the reload + "Not submitted" copy is otherwise truthful. → rejected.
- [edge] Spec task names a `breach_at` column; the table keeps `created_at` as the breach instant — **low** — verified divergence; no consumer reads `breach_at`; the renames to fix either side are spec edits or shared-timestamp churn. → rejected (naming divergence recorded here).
- [edge] `inbound.facade.ts` `listPurchaseOrders` contract docblock deleted by the facade-read insertion — **low** — verified; direct restoration. → folded into re-derivation KEEP (restore the docblock).
**Second pass — re-derived diff (2026-10-01), all three layers.** The re-derivation carried every fold-in from pass 1; none of the four known-bad states reappear. Prior verification gaps VERIFIED CLOSED: `ReplenishmentSchedulerWorker.tick()` now has a nine-assertion plumbing block (`test/replenishment.spec.ts:906+`) and the FE nav gate has its four-role pin (`navigation.test.ts`).

**Carried rows (same claim as a logged pass-1 row, code unchanged):**
- [blind, carried] `suggested_pos.dismissed` dead vocabulary (+ the always-empty FE tab) — carried **low**/rejected.
- [blind, carried] Candidate composition O(warehouses × tenant SKUs) with sequential per-candidate ATP reads (+ the phase-1/phase-3 double read) — carried **low**/rejected.
- [edge, carried] Spec task names `breach_at`; the table keeps `created_at` — carried **low**/rejected. (The Design Notes now record the created_at alignment explicitly.)
- [edge] Two concurrent sweeps of one scope → 23505 on the breach/draft insert rolls back one transitions tx — **low** — transient and self-healing (the next tick finds the standing breach and no-ops — the absorb IS the matrix's designed mechanism; the per-scope catch merely logs it). Multi-pod sweeping is not a v1 shape. → rejected.

**New findings (verified first-hand):**
- [blind] + [edge] The per-tick scope cap slices the HEAD of a deterministically-ordered enumeration EVERY tick — scopes past `MAX_REPLENISHMENT_SCOPES_PER_TICK` are never swept, and the truncation warn's "will be swept on the next tick" is false — **medium** (silently breaks the frozen ≤5-min bound for the tail) — verified at `jobs.module.ts:496-499`. The count-scheduler precedent dodges this only by being per-warehouse. → patch (rotating window + truthful log + a plumbing assertion that tail scopes eventually sweep).
- [v-gap] The tick's two scope-enumeration SQL strings never execute against a real DB — the plumbing stub distinguishes them by call ORDER (would pass with the queries swapped), and the e2e deletes `REPLENISHMENT_SCHEDULER_POLL_MS` before boot — **medium** — the detection entry point itself is unobserved; a schema rename ships green and detection dies logged-not-failed. → patch (one e2e arm seeding one policy scope + one defaulted-SKU scope, calling `tick()` against the REAL facades, asserting both swept in the deterministic dedupe order).
- [v-gap] Keyset pagination never walked past page one on the three new list reads — only malformed-cursor 400s exist; the sibling convention (`adjustment-approval.spec.ts:693`) walks the cursor chain to exhaustion — **medium** (a `<`→`<=` or dropped tie-breaker regression would duplicate/skip rows across pages, and for the policies walker that is the silent wrong-effective-point display) — verified: no second-page request exists in the suite. → patch (cursor-chain walk arms for policies/breaches/drafts).
- [v-gap] The FE policy-walker's `truncated`-is-SAID contract has no test — no test file imports `use-replenishment`; every view-test stub ends at page one so `truncated` is never observed — **low** → patch (multi-page stub scenario asserting the truncation notice renders; the `excursion-queue.test.ts:385` precedent).
- [blind] No holder-set pin that `replenishment.manage`'s grantees ⊆ `po.manage`'s — the inner mint's `po.manage` 403 is a documented arm only because today's hand-listed role map happens to nest — **low** (a future grant would break every submit for that role) → patch (`users.spec.ts` holder-set pin, the `secureMoveHolders` precedent).
- [blind] Policy delete is never tested against the sweep — override-wins is tested, but nothing proves the delete's fallback direction (delete RP-B → the next sweep evaluates the 2000 SKU default) — **low** → patch (one e2e arm).
- [blind] The mint's precision-refusal arm has no test — comments assert "a fractional quantity fails the PO command's precision guard… draft stays a draft" but `recoveryGapMilli`'s ceil makes gap-derived quantities always whole, so only a planner edit at a whole-unit UoM can reach it — **low** → patch (e2e arm: the verbatim refusal, draft stays draft).
- [edge] An actioned breach renders "dismissed by {resolvedBy}" — the submit sets `resolvedBy: actorUserId` on the actioned breach (`replenishment.command.ts:738`) and the card's copy is unconditional (`replenishment-view.tsx:~422`) — audit trail and card disagree — **low** → patch (status-conditional wording).
- [blind] `schema.ts:3219-3221` header comment contradicts itself — says "the positive-point CHECK companions are drizzle-declared here" right after "the status CHECKs … live only in the migration SQL"; no CHECK is drizzle-declared — **low** → patch (reword: partial uniques drizzle-declared; positive-point CHECKs migration-only).
- [blind] `fetchApiUpsertReorderPolicy`'s docstring says "everything else is the 400 the server's own words carry" while the wrapper actually has 403 `role-denied`, 409 `conflict`, 404 and 422 arms (the sibling wrappers enumerate theirs) — **low** — verified `client.ts:1856-1857` → patch (enumerate the arms).
- [blind] `SubmitSuggestedPoDto.quantityMilli`'s description appends the shared `QUANTITY_FIELD_DESCRIPTION` ("in the SKU's base UoM, at the decimal precision that unit declares") to an integer-milli field — two different grammars in one sentence — **low** — verified `replenishment.dto.ts:274` → patch (drop the appended clause).

**Rejected (new, verified):**
- [blind] Sweep/submit lock-order inversion deadlock — **false** — the opening arm holds NO breach row (none exists — it inserts one, so the partial unique absorbs a concurrent opener); the no-op arm `continue`s without touching the draft; the recovery arm never touches the draft. Opposing-order double locking on one (breach, draft) pair is not constructible.
- [blind] A never-bootstrapped warehouse's ATP read fails closed forever (no ready marker → `reservationStoreUnavailable` every tick) — **low** — the fail-closed stance IS the designed A8 behavior (never invent an ATP figure), and self-heal paths exist (startup rebuild over res/stock tenants, `reservation.service.ts:296-308`; the not-ready grant rebuild, `:917`). The residual — no eager rebuild on new-warehouse creation, so a cold warehouse logs every tick until first grant or restart — is a pre-existing inventory-core gap, not this story's shape. → deferred.
- [blind] `breach_detected` payload carries skuId only (no code/name) — Epic 9's panel must resolve identities itself — **low**; the payload shape is spec-authored; Epic 9 owns refining it. → rejected.
- [blind] The FE always sends `quantityMilli` (leaving the omitted-keeps-value arms dead) and a mid-edit repoint could turn an unchanged resend into a 422 key-reuse — **low**; the refusal renders verbatim and the mapper covers the arm. → rejected.
- [blind] The card's spinner `step` contradicts its hint for an unresolvable SKU — **low**; rare cosmetic edge. → rejected.
- [blind] The two queue hooks and two cards are ~100-line clones — **low**; refactor guidance, not a defect. → rejected.
- [blind] The surface is per-warehouse only; breaches in other warehouses hidden until Epic 9's panel — **low**; the intended UX; the panel is the cross-warehouse lens. → rejected.
