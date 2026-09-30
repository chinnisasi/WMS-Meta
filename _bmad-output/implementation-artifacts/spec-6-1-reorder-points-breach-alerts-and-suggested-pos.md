---
title: '6.1 Reorder points, breach alerts, and suggested POs'
type: 'feature'
created: '2026-10-01'
status: 'ready-for-dev'
route: 'dispatch'
review_loop_iteration: 0
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
- `src/modules/inbound/inbound.facade.ts:118` — `createPurchaseOrder` → `po.command.ts:171` (`po.manage`, idempotent, in-tx asserts warehouse/vendor/sku, caller-minted `code`, lines `{skuId, orderedQty, unitCostPaise}`; statuses `open|closed` only). Code-mint convention for the submit arm: `PO-${ulid().slice(10, 18).toUpperCase()}` (the test fixture's house shape).
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
- [ ] `wms-be` migration `drizzle/0048_*.sql` + `src/shared/db/schema.ts` — three tables: `reorder_policies` (UNIQUE `(tenant_id, warehouse_id, sku_id)`; `reorder_point_milli`/`reorder_qty_milli` bigint > 0 CHECKs migration-only), `reorder_breaches` (UNIQUE active-only per `(tenant_id, warehouse_id, sku_id)` via partial index; `status` CHECK `open|recovered|actioned|dismissed`; `point_milli`/`atp_milli` frozen at detection; `breach_at`/`resolved_at`/`resolved_by`), `suggested_pos` (UNIQUE `draft`-only per `(tenant_id, warehouse_id, sku_id)` partial; `vendor_id` nullable; `quantity_milli`; `breach_id` bare uuid; `status` CHECK `draft|submitted|dismissed`; `submitted_po_id` nullable) — fail-closed RLS ×3, keyset indexes.
- [ ] `wms-be` `src/modules/replenishment/replenishment.command.ts` + `replenishment.facade.ts` — `upsertReorderPolicy`, `deleteReorderPolicy` (404 when absent), `listReorderPolicies`, `listBreaches`, `dismissBreach`, `listSuggestedPos`, `submitSuggestedPo` (the frozen command order; the submit arm re-executes `InboundFacade.createPurchaseOrder` — idempotency key = the inner command's own key so an apply-retry replays exactly-once).
- [ ] `wms-be` `src/jobs/jobs.module.ts` — `ReplenishmentSchedulerWorker` (env `REPLENISHMENT_SCHEDULER_POLL_MS`, the CountSchedulerWorker shell: scope enumeration from reorder policies ∪ tenant-wide defaults' warehouses, per-scope catch/log/skip, ATP via the facade, breach open/recover transitions, draft-on-open).
- [ ] `wms-be` `src/modules/catalog/catalog.facade.ts` — the additive `getSkuReorderDefaults` read.
- [ ] `wms-be` capabilities: `replenishment.manage` in the tuple + `ops_manager` set (+ FE-mirror comment); api-shell `ReplenishmentController` (thin DTO mapping, `assertOwnTenant` per method); `bun run openapi:export`.
- [ ] `wms-be` `test/replenishment.spec.ts` — the I/O matrix cells as e2e (upsert/refusals, worker tick breach/recover/no-op with faked ATP, deterministic default-vendor pick, vendor-null draft + submit refusal, submit happy path asserting the real PO + `actioned` + events, dismiss, 409 arms, foreign-tenant 404, RLS probe); `test/client-isolation.spec.ts` pin 56 → 59; `test/architecture.spec.ts` module block.
- [ ] `wms-fe` `src/lib/users.ts` — capability 31 → 32 + `users.test.ts` pin.
- [ ] `wms-fe` — `bun run api:generate`, wrappers (`src/lib/api/client.ts`), `src/lib/use-replenishment.ts` hooks, `src/lib/replenishment.ts` reason mappers; replace `replenishment/page.tsx` with the surface — the breach list with draft cards (vendor picker + editable qty, submit/dismiss), the policy table with inline-edit cells (sku-table precedent) over both per-warehouse rows and SKU defaults, `NAV_ITEMS` capability gate; component tests pinning the error contract (409 → reload, verbatim refusals) and the submit-never-auto claim (no submit call except on click).

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
- **The submit arm is the apply-arm pattern** (the sync-report/5-2 precedent): replenishment's command orchestrates, the inbound command remains the only PO writer and re-asserts `po.manage` on the re-execution — the refusals propagate verbatim and the draft survives.

## Verification

**Commands:**
- `cd workspace/core/backend/wms-be && bun run test -- test/replenishment.spec.ts && bun run lint && bunx tsc --noEmit && bun run db:verify && bun run openapi:export` -- expected: suite green, migration verified, three routes+ reads exported
- `cd workspace/core/backend/wms-be && bun run test` -- expected: FULL suite green (the client-isolation 59-pin is only proven here)
- `cd workspace/core/frontend/wms-fe && bun run api:generate && bun run lint && bun run test` -- expected: regen clean, mirror check passes, new surface tests green

## Implementation Notes

## Spec Change Log

## Review Triage Log