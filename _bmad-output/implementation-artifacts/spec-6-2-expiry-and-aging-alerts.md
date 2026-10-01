---
title: '6.2 Expiry and aging alerts'
type: 'feature'
created: '2026-10-01'
status: 'in-progress'
baseline_commit: '0171dcc6a7b78fe6bbb21856bbc0540d29752158'
route: 'dispatch'
review_loop_iteration: 0
context:
  - '_bmad-output/implementation-artifacts/epic-6-context.md'
  - 'docs/design/SYSTEM-DESIGN.md'
  - 'docs/design/IMPLEMENTATION-GUIDE.md'
  - 'docs/design/modules/replenishment.md'
  - 'docs/design/modules/catalog.md'
  - 'docs/design/modules/inventory.md'
  - 'docs/design/frontend/SYSTEM-DESIGN.md'
  - 'docs/design/frontend/IMPLEMENTATION-GUIDE.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** Batch-tracked stock has no expiry or aging awareness in the operations loop. `batches.expiry_date` is read only by FEFO draws, so a batch nearing (or past) expiry surfaces nowhere: the first person to notice is the picker holding it. Nothing shows batch age either — old stock sits invisible until it becomes the picker's problem. FR-23 promises an expiry dashboard within configurable lead days and aging stock visible by batch.

**Approach:** Extend the replenishment module (6-1's sweep + worker shell) with a per-scope expiry/aging scan driven by the SAME scheduler tick: a per-tenant config row (`expiry_lead_days`, `aging_threshold_days` — config data, not code) drives the evaluation; when a batch within lead days (or past the aging threshold) carries on-hand, a batch alert row opens (amber, notification-panel-shaped, `notifyRole` hint); the surface shows the expiry/aging queue on the Replenishment surface with click-through to the batch records. The system still never moves, blocks, or auto-disposes stock — alerts are evidence; the FEFO draw's existing expired-batch skip stays the only stock-side behavior.

## Boundaries & Constraints

**Always:**
- Batch identity is catalog-owned: expiry dates are read via the catalog facade (or in-tx catalog reads on the scan arms), NEVER by joining `batches` from inventory-side tables or a raw cross-module reach (AD-6; re-verified: `batches` is written only by `CatalogFacade.ensureBatches`).
- On-hand quantities are read from the `batch_on_hand` projection (inventory-owned, already batch-scoped) — the scan maintains NO stock numbers of its own (the ledger-as-truth spine).
- The scan runs on the SAME scheduler worker's tick (the epic's one-scheduler decision) and takes explicit tenant context; it is sheddable, per-scope catch/log/skip.
- Alert rows freeze their detection facts (`age_days` for aging at detection; expiry itself never changes — catalog freezes dates at intake) so the surface can render after consumption; the queue read re-reads live on-hand for freshness.
- Alerts carry the `notifyRole` hint in their outbox payload and an audit row, the 6-1 precedent; recovery/resolution emits NO event (surface-visible state change only).

**Never:**
- No auto-blocking, auto-moving, auto-disposal, or auto-write-off of expired/near-expiry/aged stock anywhere (the alert is the act; any block verb is a separate decision — see Open Questions).
- No change to the FEFO draw, the pick suggestion path, or any ledger writer — expiry behavior already ships there (draws sort expiry ASC nulls-last and skip expired).
- No notification panel surface (Epic 9), no mobile push (the epic restricts pushes to task/approval/cutoff classes), no batch-expiry work on the mobile substrate.
- No per-bin or per-HU expiry alerting (batch scope only, per the epic's "visible by batch"); no quarantine of expired batches through the QC-hold core (that's an operator verb via `qc.manage`, not a story verb).

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|---|---|---|---|
| Config upsert | `PUT {expiryLeadDays, agingThresholdDays}` (both ≥ 0 integers, `Idempotency-Key`) | 200 snapshot, last-write-wins (the count-policy upsert precedent) | Negative/non-integer → 400 `validation-failed` naming the field; capability-gated |
| Config absent | No config row | Scan no-ops for the tenant (the "absent row = disabled" convention — no default lead days hidden in code) | N/A |
| Expiry scan hit | Batch, `status='active'`, non-null `expiryDate` ≤ now + lead_days, on-hand > 0 in the scope warehouse, no open `expiry_upcoming` alert for (w, sku, batch) | Alert row opens (expiry itself needs no freezing — catalog froze the dates at intake; outbox `replenishment.batch_alert_raised` + audit) | N/A |
| Expiry scan, already open | An open `expiry_upcoming` alert for the same (tenant, w, sku, batch) | No-op (partial unique absorbs; no duplicate event, no repeat draft-equivalent) | N/A |
| Expiry scan, batch now blocked | `batches.status='blocked'` | No NEW alert for a blocked batch; an existing open alert stands while on-hand > 0 (it resolves through the normal on-hand-0 rule — see Resolved decisions) | N/A |
| Aging scan hit | Batch age ≥ `aging_threshold_days`, on-hand > 0, no open `aged` alert for (w, sku, batch) | `aged` alert opens — `age_days` FROZEN at detection (age moves; the alert records what it saw) | N/A |
| Expiry + aging both hit | Same batch qualifies for both | TWO alert rows (same kind-vocabulary, distinct kinds) — the queue filters by kind | N/A |
| Batch consumed / on-hand → 0 | The (w, sku, batch) scope's on-hand reads 0 on a later scan | Open alerts for that (w, sku, batch) resolve (`resolved_by` null — nobody acted; NO event) | N/A |
| Alert dismissal | Human dismiss on an open alert (`Idempotency-Key`) | `status 'open' → 'dismissed'`, `resolved_by/at` stamped; NO stock-side effect | Unknown/foreign → 404; not open → 409 `batch-alert-not-open` |
| List reads | Keyset + `kind`/`warehouseId`/`status` filters | `limit` clamped server-side | `limit=abc`/malformed cursor → 400 naming the query |
| Worker ATP/scan failure | Any scan arm throws (DB hiccup mid-scan) | Whole scope skipped, logged, retried next tick — a partial scan never half-resolves alerts | N/A |

### Resolved decisions (user-ratified 2026-10-01, "take all recommended")

- **Aging definition:** days since batch intake — `batches.created_at` (the receipt instant). `age_days = floor((now − created_at) / 86400s)`, frozen at detection.
- **Alert lifecycle:** `open → dismissed` (human, `resolved_by/at` stamped) ⨯ plus AUTO-resolve `open → resolved` when the (tenant, warehouse, sku, batch) on-hand reaches 0 on a later scan — `resolved_by` null, nobody stamped, NO event.
- **No batch `block` verb in this story:** `batches.status='blocked'` stays unreachable vocabulary; recorded in PENDING as a future catalog batch-verb story. A blocked batch raises no NEW alert, and an existing open alert stands while on-hand > 0 (resolving through the normal on-hand-0 rule).
- **Spec size:** keep full spec (~3,400 tokens — the 6-1 precedent).

</frozen-after-approval>

## Code Map

**Backend (wms-be):**
- `src/shared/db/schema.ts:669` — `batches` (identity in catalog): `expiryDate` nullable timestamptz (the ONLY expiry field), `status 'active'|'blocked'` CHECK, `code`, `mfgDate`. Dates frozen at intake (`test/batch-serial.spec.ts:272`). NO expiry index — 0049 adds `batches_tenant_expiry_idx` (the scan's join input).
- `src/shared/db/schema.ts:1032` — `batch_on_hand` (inventory-owned projection): unique (tenant, warehouse, sku, bin, batchId), `quantity` bigint milli, index `(tenant, warehouse, sku)`. THE on-hand source for scanning and queue freshness.
- `src/shared/db/schema.ts:3264` — `reorder_breaches` (6-1): the alert-row PATTERN (frozen-at-detection facts, partial unique on open, keyset indexes, `resolved_by/at`) — do NOT extend it; its scope is SKU-only and its unique re-keying would break every 6-1 arm. New sibling tables instead.
- `src/modules/replenishment/replenishment.sweep.ts` — 6-1's `sweepScope` three-phase shape: candidates tx → reads on NO transaction (ATP, the spine) → transitions tx with fresh re-reads. 6-2's scan is SIMPLER (no Valkey, no reservation store): batch reads + on-hand reads are plain projection/catalog reads, but keep the phase discipline (enumerate in a tx; decide; transition alerts inside one tx re-reading fresh facts).
- `src/jobs/jobs.module.ts:428` — `ReplenishmentSchedulerWorker`: the scope enumeration is two deduped SQL queries with a 200-cap rotating window (`rotatingWindow` + `tickOffset` — review fix). 6-2 adds a THIRD enumeration query (warehouses carrying batch on-hand — `batch_on_hand.quantity > 0` joined batch-tracked SKUs) and per-scope calls the facade's expiry scan alongside `sweepScope`. DO NOT touch the rotating-window semantics; the cap applies to the union.
- `src/modules/movements/count.command.ts:1542` — the config-row upsert precedent (unique-violation-swallowing upsert) — but the variance-policy family's PUT route + "absent = disabled" is the shape to reuse (`count.command.ts:1590` read shape).
- `src/modules/tenancy/permissions.ts:177` — `replenishment.manage` (the 32nd, Owner + Ops Manager): 6-2's config PUT + alert dismissal gate SAME capability (the planning set reasoning holds — an aging threshold is inventory planning). Reads ungated. No new capability ⇒ mirror untouched in FE except users.
- `src/api/replenishment.controller.ts` — 6-1's 7 routes as the shape (keyset lists, `Idempotency-Key` on mutations, `assertOwnTenant` per method). 6-2 adds: `PUT`/`GET :t/replenishment/expiry-policies`, `GET :t/replenishment/batch-alerts`, `POST .../batch-alerts/{id}/dismiss`.
- `drizzle/0048_replenishment.sql` — the migration pattern (RLS + CHECKs + partial uniques in hand-appended SQL; drizzle-blindness rule). Next migration is `0049`.
- `test/batch-serial.spec.ts` — the batch e2e conventions (dates malformed arm, FEFO seed shapes). `test/replenishment.spec.ts:1094` — the real-facade tick arm; `:1152` — the plumbing block to extend. `test/count.spec.ts:2112` — worker plumbing precedent.
- `test/client-isolation.spec.ts:644` — the hard RLS-policy pin 59 → `61` (batch alerts + expiry policy). `test/architecture.spec.ts` — replenishment's module blocks already exist; extend for the new reads.

**Frontend (wms-fe):**
- `src/components/replenishment/replenishment-view.tsx` — 6-1's three-panel surface: gain the fourth panel, the expiry & aging queue (kind tabs or one amber list, `kind` filter, click-through to batch records — `GET .../inventory/batches/{id}` is the detail read; `GET .../inventory/batches` the tenant list read).
- `src/lib/use-replenishment.ts` — the hooks pattern (cursor-page + chain-walker + `truncated`-is-SAID flag) for the new queue hook; `src/lib/api/client.ts` wrapper docstrings enumerate arms (the 1856 finding's convention); `src/lib/replenishment.ts` reason mappers gain the batch-alert codes.
- `src/lib/users.ts` — NO capability change (reuses `replenishment.manage`; mirror stays 32 — mirror check must still pass).
- Nav unchanged (Replenishment surface hosts the fourth panel — the bell-panel click-through in Flow 5 lands here too).

## Tasks & Acceptance

**Execution:**
- [ ] `wms-be` `drizzle/0049_expiry_alerts.sql` + `schema.ts` — `expiry_alert_policies` (unique `(tenant_id)`, `expiry_lead_days`/`aging_threshold_days` int ≥ 0) and `batch_alerts` (scope tenant/warehouse/sku/batch, `kind 'expiry_upcoming'|'aged'` CHECK, `status 'open'|'resolved'|'dismissed'` CHECK, `age_days` int nullable frozen-at-detection, `resolved_by/at`; partial unique open-rows per `(tenant_id, warehouse_id, sku_id, batch_id, kind)`; keyset indexes; fail-closed RLS ×2) + `batches_tenant_expiry_idx` index on `batches (tenant_id, expiry_date)`.
- [ ] `wms-be` the scan — `replenishment.sweep.ts` (or a sibling `expiry.scan.ts` in the module): per-scope `scanScope(tenantId, warehouseId)` — enumerate batch-tracked on-hand scopes (tx), evaluate against the tenant config (absent → no-op), open/transition alerts in ONE transitions tx with fresh re-reads (on-hand 0 → resolve; partial unique absorbs double-open). Alerts carry audit + outbox `replenishment.batch_alert_raised` `{alertId, kind, warehouseId, skuId, batchId, batchCode, expiryDate?, ageDays?, notifyRole: 'ops_manager'}`.
- [ ] `wms-be` `jobs.module.ts` — third scope-enumeration query (warehouses with batch on-hand on batch-tracked SKUs), union + dedupe + cap with the SAME rotating window; per-scope `scanScope` after `sweepScope`, per-scope catch/log/skip preserved.
- [ ] `wms-be` commands + facade — `upsertExpiryPolicy` (the absent-row family: GET → `404 not-found` when absent, the disable mechanism), `dismissBatchAlert`, `listBatchAlerts`; controller routes; capability checks (`replenishment.manage`); openapi export.
- [ ] `wms-be` tests — I/O-matrix arms as e2e (config upsert/validation/absent-row no-op; expiry hit on lead-day boundary; already-open no-op; aging hit with frozen `age_days`; both-kinds-both-rows; consumed-batch auto-resolve; dismissal + 409; foreign 404; RLS probe; the real-facade tick arm drives BOTH scan kinds; plumbing block extended — third enumeration query + truncation). `client-isolation` pin 59 → 61; architecture blocks extended.
- [ ] `wms-fe` — batch-alerts panel on the replenishment surface (kind filter, amber treatment, click-through to the batch detail read, dismissal button), hook + wrappers + mappers, `users.ts` mirror unchanged but re-verified, component tests pinning the error contract and truncation flag.

**Acceptance Criteria:**
- Given a batch-tracked SKU with a batch whose expiry falls inside the tenant's lead days and on-hand in a warehouse, when the worker ticks, then an `expiry_upcoming` alert row, a `replenishment.batch_alert_raised` event, and an audit row exist and the surface shows the batch in the expiry queue; when the batch's on-hand reaches 0 by a later tick, the alert reads `resolved` with `resolved_by` null.
- Given a batch older than the tenant's aging threshold on-hand, when the worker ticks, then an `aged` alert opens with `age_days` frozen at detection, and a consumed batch's `aged` alert resolves the same way — the expiry and aging alerts coexist for the same batch as two rows.
- Given NO config row, when the worker ticks, then no expiry/aging alert is evaluated for the tenant; when a config row is upserted with fresh values, the next tick evaluates under them.
- Given a Valkey/ATP-style mid-scan failure (any arm throwing), when the scan runs, then the scope is skipped whole and logged — no alert is opened, none resolved, and the previous state stands.
- Given a role without `replenishment.manage`, when it hits the config PUT or a dismissal, then 403 `role-denied`; the queue and config GET are open to members (config GET as an ungated read of its existence, 404 when absent).

## Design Notes

- **Why a sibling table, not reuse of `reorder_breaches`:** a batch alert's natural scope is (tenant, warehouse, sku, batch) with a kind vocabulary; re-keying reorder_breaches' partial unique would break every 6-1 guard and muddle two lifecycles. The PATTERN (frozen facts, partial unique on open, resolved_by/at, keyset indexes) is lifted verbatim.
- **Expiry reads never cache:** identity (batches) and state (batch_on_hand) are read fresh every scan; nothing else is computed from a snapshot. The ONLY frozen fact is `age_days`, because age is a moving target and the alert records what it saw — the same reasoning as 6-1's frozen `point_milli`/`atp_milli`.
- **Absent-row = disabled** is load-bearing for the config: a newly onboarded tenant must wake up with NO expiry alerts (no invented default to tune later) — the same "config-not-code" decision as variance policies. `PUT` establishes; `GET` reading `404` is the disable mechanism (the adjustment-policy precedent). NOTE: unlike the variance family, there is no "null field disables one arm" — the two integers are independent switches. (0 for `expiry_lead_days` still alerts day-of-expiry batches; 0 for `aging_threshold_days` alerts every on-hand batch — values a tenant simply won't set; both ≥ 0, validated at the DTO.)
- **The worker gains a scope, a query, and one call** — not a second worker. The epic's "one scheduler" decision, plus the enumeration union keeps the rotating window's starvation fix intact across everything the tick could carry.
- **The lifecycle's auto-resolve direction follows the breach precedent:** nobody-stamped resolutions carry `resolved_by` null and NO event; only human dismissal stamps. The scan evaluates ALL open alerts for the scope each tick: on-hand 0 → resolve; a batch that never triggers anymore keeps its open alert until consumption or dismissal — expiry only matures, so expiry alerts never self-resolve any other way.
- **Aging is intake-anchored** (ratified): `age_days = floor((now − batches.created_at)/86400s)` — the receipt instant, computable from the identity row with no ledger join; the aging threshold is an independent switch from the expiry lead days (a batch can hold both alerts).

## Verification

**Commands:**
- `cd workspace/core/backend/wms-be && bun run test -- test/replenishment.spec.ts test/batch-serial.spec.ts test/users.spec.ts` — expected: all green (jest; never bare `bun test`)
- `cd workspace/core/backend/wms-be && bun run test` — expected: full suite green (51+ suites)
- `cd workspace/core/backend/wms-be && bun run lint && bun run typecheck && bun run db:verify` — expected: clean; round-trip OK
- `cd workspace/core/frontend/wms-fe && bun run test` — expected: all green (+ mirror check, `bun run check:capability-mirror` — 32 capabilities, unchanged)
- `cd workspace/core/frontend/wms-fe && bun run api:generate && git diff --exit-code src/lib/api/generated` — expected: no drift after openapi:export

**Manual checks (if no CLI):**
- The 0049 migration's RLS policies + partial uniques exist (psql `\d` or db:verify round-trip).
- The openapi.json re-export carries the three new route paths + schemas.

## Implementation Notes

## Spec Change Log

## Review Triage Log