---
title: '6.2 Expiry and aging alerts'
type: 'feature'
created: '2026-10-01'
status: 'done'
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
- `src/shared/db/schema.ts:669` — `batches` (identity in catalog): `expiryDate` nullable timestamptz (the ONLY expiry field), `status 'active'|'blocked'` CHECK, `code`, `mfgDate`. Dates frozen at intake (`test/batch-serial.spec.ts:272`). 0049 adds `batches_tenant_expiry_idx` on `(tenant_id, expiry_date)` — provisioned for expiry-range reads; NO query consumes it today (the scan's intake read is `(tenant_id, sku_id IN)` via the pre-existing `batches_tenant_sku_idx`) — keep/drop decision recorded in deferred-work.
- `src/shared/db/schema.ts:1032` — `batch_on_hand` (inventory-owned projection): unique (tenant, warehouse, sku, bin, batchId), `quantity` bigint milli, index `(tenant, warehouse, sku)`. THE on-hand source for scanning and queue freshness.
- `src/shared/db/schema.ts:3264` — `reorder_breaches` (6-1): the alert-row PATTERN (frozen-at-detection facts, partial unique on open, keyset indexes, `resolved_by/at`) — do NOT extend it; its scope is SKU-only and its unique re-keying would break every 6-1 arm. New sibling tables instead.
- `src/modules/replenishment/replenishment.sweep.ts` — 6-1's `sweepScope` three-phase shape: candidates tx → reads on NO transaction (ATP, the spine) → transitions tx with fresh re-reads. 6-2's scan is SIMPLER (no Valkey, no reservation store): batch reads + on-hand reads are plain projection/catalog reads, but keep the phase discipline (enumerate in a tx; decide; transition alerts inside one tx re-reading fresh facts).
- `src/jobs/jobs.module.ts:428` — `ReplenishmentSchedulerWorker`: the scope enumeration is two deduped SQL queries with a 200-cap rotating window (`rotatingWindow` + `tickOffset` — review fix). 6-2 adds a THIRD enumeration query (warehouses carrying batch on-hand — `batch_on_hand.quantity > 0` joined batch-tracked SKUs, arm 1 predicated on the tenant holding an `expiry_alert_policies` row so unconfigured tenants enumerate nothing; arm 2 keeps open-alert scopes so auto-resolve stays reachable) and per-scope calls the facade's expiry scan alongside `sweepScope`. DO NOT touch the rotating-window semantics; the cap applies to the union.
- `src/modules/movements/count.command.ts:1542` — the config-row upsert precedent (unique-violation-swallowing upsert) — but the variance-policy family's PUT route + "absent = disabled" is the shape to reuse (`count.command.ts:1590` read shape).
- `src/modules/tenancy/permissions.ts:177` — `replenishment.manage` (the 32nd, Owner + Ops Manager): 6-2's config PUT + alert dismissal gate SAME capability (the planning set reasoning holds — an aging threshold is inventory planning). Reads ungated. No new capability ⇒ mirror untouched in FE except users.
- `src/api/replenishment.controller.ts` — 6-1's 7 routes as the shape (keyset lists, `Idempotency-Key` on mutations, `assertOwnTenant` per method). 6-2 adds: `PUT`/`GET :t/replenishment/expiry-policies`, `GET :t/replenishment/batch-alerts`, `POST .../batch-alerts/{id}/dismiss`.
- `drizzle/0048_replenishment.sql` — the migration pattern (RLS + CHECKs + partial uniques in hand-appended SQL; drizzle-blindness rule). Next migration is `0049`.
- `test/batch-serial.spec.ts` — the batch e2e conventions (dates malformed arm, FEFO seed shapes). `test/replenishment.spec.ts:1094` — the real-facade tick arm; `:1152` — the plumbing block to extend. `test/count.spec.ts:2112` — worker plumbing precedent.
- `test/client-isolation.spec.ts:644` — the hard RLS-policy pin 59 → `61` (batch alerts + expiry policy). `test/architecture.spec.ts` — replenishment's module blocks already exist; extend for the new reads.

**Frontend (wms-fe):**
- `src/components/replenishment/replenishment-view.tsx` — 6-1's three-panel surface: gain the fourth panel, the expiry & aging queue (kind tabs or one amber list, `kind` filter, queue cards identify the batch by its code (the list rows carry `batchCode` — R4), click-through to batch records — `GET .../inventory/batches/{id}` is the detail read; `GET .../inventory/batches` the tenant list read).
- `src/lib/use-replenishment.ts` — the hooks pattern (cursor-page + chain-walker + `truncated`-is-SAID flag) for the new queue hook; `src/lib/api/client.ts` wrapper docstrings enumerate arms (the 1856 finding's convention); `src/lib/replenishment.ts` reason mappers gain the batch-alert codes.
- `src/lib/users.ts` — NO capability change (reuses `replenishment.manage`; mirror stays 32 — mirror check must still pass).
- Nav unchanged (Replenishment surface hosts the fourth panel — the bell-panel click-through in Flow 5 lands here too).

## Tasks & Acceptance

**Execution:**
- [x] `wms-be` `drizzle/0049_expiry_alerts.sql` + `schema.ts` — `expiry_alert_policies` (unique `(tenant_id)`, `expiry_lead_days`/`aging_threshold_days` int ≥ 0) and `batch_alerts` (scope tenant/warehouse/sku/batch, `kind 'expiry_upcoming'|'aged'` CHECK, `status 'open'|'resolved'|'dismissed'` CHECK, `age_days` int nullable frozen-at-detection, `resolved_by/at`; partial unique open-rows per `(tenant_id, warehouse_id, sku_id, batch_id, kind)`; keyset indexes; fail-closed RLS ×2) + `batches_tenant_expiry_idx` index on `batches (tenant_id, expiry_date)`.
- [x] `wms-be` the scan — `replenishment.sweep.ts` (or a sibling `expiry.scan.ts` in the module): per-scope `scanScope(tenantId, warehouseId)` — enumerate batch-tracked on-hand scopes (tx), evaluate against the tenant config (absent → no-op), open/transition alerts in ONE transitions tx with fresh re-reads (on-hand 0 → resolve; partial unique absorbs double-open). Alerts carry audit + outbox `replenishment.batch_alert_raised` `{alertId, kind, warehouseId, skuId, batchId, batchCode, expiryDate?, ageDays?, notifyRole: 'ops_manager'}`.
- [x] `wms-be` `jobs.module.ts` — third scope-enumeration query (warehouses with batch on-hand on batch-tracked SKUs), union + dedupe + cap with the SAME rotating window; per-scope `scanScope` after `sweepScope`, per-scope catch/log/skip preserved.
- [x] `wms-be` commands + facade — `upsertExpiryPolicy` (the absent-row family: GET → `404 not-found` when absent, the disable mechanism), `dismissBatchAlert`, `listBatchAlerts` (rows stitch `batchCode` via the in-tx catalog intake read — R4; `onHandMilli` optional on the wire — absent on the dismissal snapshot — R1); controller routes; capability checks (`replenishment.manage`); openapi export.
- [x] `wms-be` tests — I/O-matrix arms as e2e (config upsert/validation/absent-row no-op; expiry hit on lead-day boundary; already-open no-op; aging hit with frozen `age_days`; both-kinds-both-rows; consumed-batch auto-resolve; dismissal + 409; foreign 404; RLS probe; the real-facade tick arm drives BOTH scan kinds; plumbing block extended — third enumeration query + truncation). `client-isolation` pin 59 → 61; architecture blocks extended.
- [x] `wms-fe` — batch-alerts panel on the replenishment surface (kind filter, amber treatment, click-through to the batch detail read, dismissal button), hook + wrappers + mappers, `users.ts` mirror unchanged but re-verified, component tests pinning the error contract and truncation flag.

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

## Matrix Test Audit (step-03, judged against the staged diff)

Diff audited: `/tmp/6-2-be-code.diff` (3,430 lines excl. drizzle snapshot), `/tmp/6-2-fe-code.diff` (1,639 lines excl. generated). Verification re-run first-hand 2026-10-01: BE jest 1018/1018 (51 suites, 155s, exit 0), lint/typecheck/db:verify all 0 ("round-trip OK"), FE bun test 624/0, mirror 32 ✓, api:generate drift none.

| Matrix row | Test that RAN AND PASSED | Verdict |
|---|---|---|
| Config upsert (+validation/capability/tenant-403/replay/422/audit) | `config upsert: 200 with the snapshot…` (400s ×4 naming the field, 403 ×2, replay ==, 422, one audit row) | covered |
| Config absent → no-op + GET 404 | `absent config row = disabled…` (scanScope idle ×2 tenants; GET 404 `not-found`) | covered |
| Expiry scan hit (lead boundary +1h miss / −1h hit, E1 in-lead) | `the scan raises…` (E4 hit, E3 miss, report raised:4) | covered |
| Already open → no duplicate/event | `already-open: a re-scan is a no-op…` (raised:0, event+audit counts unchanged) | covered |
| Blocked batch → no NEW alert, open stands | `the scan raises…` (BLK evaluated, no row; 7 evaluated/4 raised) + openOnHand standing semantics | covered |
| Aging hit at threshold boundary, frozen age_days | `the scan raises…` (A1 exactly 30d → age_days 30; A2 29d no hit) | covered |
| Both kinds → two rows, two events, kind-shaped payloads | `the scan raises…` (E1 ×2 rows; expiry payload has expiryDate no ageDays; aged payload ageDays no expiryDate) | covered |
| Consumed → auto-resolve, resolved_by null, NO event | `AUTO-resolve: consuming the batch to zero…` (resolved:2, both rows resolved_by null, event count unchanged) | covered |
| Dismissal (+409/404/400/403/replay/audit) | `dismiss an open batch alert…` (snapshot no onHandMilli, replay ==, 409 names status, 404 unknown, 400 malformed, operator 403, audit stamps) | covered |
| List reads (filters, live on-hand, keyset, refusals) | `batch-alert list…` + `batch-alert keyset pagination` (walk composes) | covered |
| Scan-arm throw → whole scope skipped, logged | `the expiry scan gets its OWN failure domain…` (scan throw logged, sweep still ran; per-evaluation catch) | covered |
| Worker tick drives both evaluations (real facades) | `worker tick() against the REAL facades…` + `the consumed-warehouse arm…` (third enumeration's union arm proven: alert-only warehouse still swept to resolve) | covered |

FE matrix proxies (component tests, 6-2 describe): reads-only on mount, kind/status filter rides the query, amber + kind-named (never colour alone), dismissal POST + ULID + reload, 409 verbatim + reload, absent-config OFF read-back, batch-detail click-through (base units, no milli conversion) + 404 arm, operator read-only. All passing.

## Implementation Notes

## Spec Change Log

- **R4 — `batchCode` on list rows:** review (adversarial) found the batch-alerts list rows carry only `batchId` — the FE queue rendered `batch <uuid-prefix>`, untriageable without one heavy detail fetch per card. `listBatchAlerts` now stitches `batchCode` (keyed on batch id) via the existing in-tx catalog seam `getBatchIntakesForSkusInTx`; `BatchAlertDto`/openapi gains the field (a mirror of the already-public `batch_alert_raised` payload field, additive — no new API design), and the FE card renders `batch <code>`. Code Map DTO/FEM lines amended to match.
- **R6a — third enumeration query predicated on config:** review (adversarial) found tenants with NO `expiry_alert_policies` row pay a per-scope scan tx per tick (config read → null → no-op) at full cross-tenant scale. Arm 1 of the third query now carries `and exists (select 1 from expiry_alert_policies p where p.tenant_id = bo.tenant_id)`; arm 2 (open alerts) is unchanged — the policy table has no DELETE (absence-at-raise ⇒ never configured ⇒ no alerts to carry), so auto-resolve stays reachable and a later upsert is picked up next tick. Code Map jobs line amended to match.
- **R3-honesty — `batches_tenant_expiry_idx` wording:** review (all three lenses) found the "the scan's join input" claim false — no query consumes the index (the scan's intake read is `(tenant_id, sku_id IN)` via the pre-existing `batches_tenant_sku_idx`). The schema/drizzle comments now state the index is provisioned for expiry-range reads with no consuming query today. Code Map line amended to match.

## Review Triage Log

Step-04 (three lenses — adversarial / edge-case-hunter / verification-gap-hunter) over `/tmp/6-2-review.diff`. 16 unique findings after dedup; overlaps noted per row. Every row verified first-hand against the diff and surrounding code; verification-gap rows land pre-verified by the lens's own evidence rules; `review_loop_iteration` stays 0 (no loopback).

| # | Finding (location) | Lens | Verdict | Routing |
|---|---|---|---|---|
| 1 | `batches_tenant_expiry_idx` claimed "the scan's join input" — no query consumes it (schema.ts:686-690, drizzle/0049:76) | edge + vg + adversarial | **medium** — `git grep expiry_date -- src/` finds no predicate/order outside schema+comments; the scan's intake read filters `(tenant_id, sku_id IN)` (served by pre-existing `batches_tenant_sku_idx`); FEFO expiry ordering is JS in `inventory.controller.ts` | **patch** — reword both comments (provisioned for expiry-range reads, no consuming query today); defer row 1a for the keep/drop decision |
| 2 | `assertNonNegativeDays` comment says "behind the replay lookup" but the asserts run BEFORE `withTenantTransaction` (replenishment.command.ts upsertExpiryPolicy) | edge + adversarial | **medium** — comment teaches an order the code fails to implement; real consequence: a same-key replay with a different invalid payload 400s (`validation-failed`) before it can reach the 422 replay arm | **patch** — fix the comment to the actual order + one e2e assertion pinning 400-not-422 on that replay |
| 3 | `nowMs + lead*86_400_000` overflows Number.MAX_SAFE_INTEGER at leads > ~104k days (scan.ts:334) | edge + adversarial | **false** — the ~32 ms float drift band sits near a cutoff at year ≈5.87 M; no representable batch expiry (timestamptz max 294276 AD, JS Date max 275760) can fall inside the band, so the comparison outcome is exact for every storable value; "every realistic expiry qualifies at an extreme lead" is the documented design | rejected on refutation — the claimed misclassification is unreachable for any storable input |
| 4 | `onHandMilli` required on the wire but absent on the dismissal snapshot: dto's `@ApiProperty` defaults it required (openapi.json `required` incl. `onHandMilli`; types.gen.ts:3983 `onHandMilli: number`) while the snapshot omits it; FE dismissal mock carries it (mask) | edge + adversarial | **medium** — the FE compiles against a lying type; the first consumer reading the snapshot's on-hand passes `undefined` into `milliToBase` (NaN) with no compile error, and the FE mock hides it | **patch** — `required: false` on the property → openapi export regen → FE types regen; FE dismissal mock omits the field (BE test already asserts `undefined`) |
| 5 | FE batch-alert cursor paging never executes under test — every stub returns `nextCursor: null`; the 6-1 `policyPageQueue` walker precedent (test.tsx:766-787) is not applied to 6-2 | verification-gap | **medium** — a broken `onCursor`, dropped cursor stamping, or a replayed query losing its `warehouseId`/`status` filter ships silently (mixes the ops tabs) | **patch** — first-page-only non-null cursor fixture, click Next, assert the replay carries `cursor=` AND the filters |
| 6 | The facade's `?? 0` absent-scope stitch arm never observed — list tests read only positive on-hand; the auto-resolve e2e never re-lists (facade.ts:408) | verification-gap | **medium** — an open alert on a consumed batch is an ordinary inter-tick state whose live on-hand renders via that arm; a stitch-key drift would render NaN with no failing test | **patch** — in the auto-resolve e2e, between consumption and the resolving scanScope, GET the open queue and assert those rows report `onHandMilli` 0 |
| 7 | `MAX_ALERT_CONFIG_DAYS` (2147483647) never runs positive: only 2147483648 → 400 is tested; the documented "write wide values to disable" arm has never executed | verification-gap | **medium** — an off-by-one at either the command edge or the DTO `@Max` bricks the advertised disable with a 400 and no test fails | **patch** — PUT exact max → 200 + GET echo + one `scanScope` under that config stays well-formed |
| 8 | The scan's concurrency invariant (ordered `FOR UPDATE`, `onConflictDoNothing` backstop) has zero verification — the suite is deliberately sequential | verification-gap | **medium** — the central cross-pod claim of the transitions tx is never executed concurrently; a future edit introducing a lock-order violation surfaces only as a production log | **patch** — one concurrency e2e: `Promise.all([scanScope, scanScope])` over one seeded scope — both settle, exactly one open row per (scope, kind), exactly one `batch_alert_raised` event |
| 9 | List rows carry only `batchId` — FE renders `batch 0198f7a2…`; the outbox payload already carries `batchCode` and the catalog in-tx intake read already exists in the facade | adversarial | **medium** — the queue's headline surface is untriageable: N open alerts need N heavy detail fetches to identify their batches | **patch** — stitch `batchCode` into list rows via `getBatchIntakesForSkusInTx` keyed on batch id; `BatchAlertDto`/openapi gains the field (additive mirror of the already-public payload field); FE cards render `batch <code>`; change-log R4 |
| 10 | No per-scope scan budget — every positive (sku,batch) scope of a warehouse in one tx | adversarial | **low** — mechanism real but the harm needs a wide batch-tracked catalog not demonstrated at the epic's scale; each scope's reads are sku-scoped, and the worker's 200-cap already bounds scopes per tick; the fix (window-rotation-style per-scan cap) adds a mechanism, not a correction | rejected per the low rule (everyday unmeet + fix > direct correction) — recorded as a scale follow-up for the epic retro / PENDING |
| 11 | Arm 1 of the third enumeration query names every batch-on-hand scope regardless of config — tenants that never configure the feature pay a per-scope tx per tick forever | adversarial | **low** — pure efficiency, no user-visible defect; but the fix IS a direct one-line predicate (`and exists (… expiry_alert_policies …)`) and is safe on the story's own terms (no DELETE on the policy; arm 2 keeps open-alert scopes, so auto-resolve stays reachable) | **patch** — add the exists clause to arm 1; change-log R6a |
| 12 | Dismissal is un-silenceable: the next conditioned scan re-raises a fresh alert + fresh `batch_alert_raised` event; an operator cannot silence a slow-moving aged alert; rows accumulate per cycle | adversarial | **medium** — the outcome is real, but it is a FROZEN design decision (lifecycle ratified at checkpoint; FE success sentence discloses re-raise; PENDING already records it BY DESIGN with the suppression-state candidate) | **defer** — the suppression state is a new lifecycle design for a future story; PENDING row holds it |
| 13 | The stated lock-order discipline is half-honored: the open-alert read locks kind ASC ('aged' first) but `evaluationHits` pushes `expiry_upcoming` first, so the raise iteration's kind order is the reverse of the read's | adversarial | **medium** — benign today (whole-shipping FOR UPDATE serializes racers), but the docblock advertises exactly the order a future transition writer will obey — a deadlock class the comment exists to prevent | **patch** — iterate the raise loop's kinds in lock order (sort / reorder pushes) and state the kind tie-order in the phase comment |
| 14 | FE ships the OFF state with no path to ON — the config PUT has no client wrapper | adversarial | **medium** — real gap, but a ratified scope cut: PENDING already records the missing FE editor with the route live and capability-gated | **defer** — the FE editor consumer is future work; PENDING row 116 holds it |
| 15 | The queue's actual read shape (warehouseId + status, often + kind) has no composite supporting index — three single-filter indexes instead | adversarial | **maybe-false** — the index set is as described, but the harm's magnitude (residual-scan degradation over retained history) would need an EXPLAIN on a seeded large table; medium if true | **defer** — settle with an EXPLAIN at the scale-review point; ties to finding 12's row growth |
| 16 | "Phase 3: transitions" in a two-phase file — sweep's three-phase numbering copied onto the scan | adversarial | **low** — reader confusion only; the fix is a direct relabel + one line noting the sweep's phase 2 (fallible outside-tx reads) has no counterpart here | **patch** — relabel Phase 2 + the clarifying line |

Patch round routed to the step-03 implementation agent (same agent): findings 1, 2, 4, 5, 6, 7, 8, 9, 11, 13, 16 (grouped: comment/label honesty — 1, 2, 13, 16; DTO contract — 4; enumeration predication — 11; queue identity — 9; verification gaps — 5, 6, 7, 8). Defer rows appended to `deferred-work.md` (1a, 12, 14, 15). Rejected: 3 (refutation), 10 (low rule; scale follow-up noted for the retro).