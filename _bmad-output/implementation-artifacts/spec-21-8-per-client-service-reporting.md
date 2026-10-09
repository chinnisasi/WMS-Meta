---
title: 'Per-client service reporting — dock-to-stock, pick accuracy and dispatch timeliness for one client, from the ledger, for the operator and the client'
type: 'feature'
created: '2026-10-10'
status: 'done'
route: 'dispatch'
baseline_commit: '90033ce11c3bce4db73cad2fe081fc7459551e0b'
review_loop_iteration: 0
context:
  - '_bmad-output/implementation-artifacts/epic-21-context.md'
  - '_bmad-output/specs/spec-3pl/SPEC.md'
  - '_bmad-output/specs/spec-3pl/architecture.md'
  - '_bmad-output/implementation-artifacts/spec-9-1-operational-dashboard.md'
  - '_bmad-output/implementation-artifacts/spec-21-7-client-portal.md'
  - 'docs/design/SYSTEM-DESIGN.md'
  - 'docs/design/IMPLEMENTATION-GUIDE.md'
  - 'docs/design/API-SURFACE.md'
  - 'docs/design/modules/reporting.md'
  - 'docs/design/modules/clients.md'
  - 'docs/design/modules/billing.md'
  - 'docs/design/modules/outbound.md'
  - 'docs/design/frontend/SYSTEM-DESIGN.md'
  - 'docs/design/frontend/IMPLEMENTATION-GUIDE.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** CAP-10 says an operator and a client can both see how the operation performed for that client: dock-to-stock, pick accuracy and dispatch timeliness. Today:
- 9-1's Overview computes dock-to-stock and short picks for a whole warehouse, for today and 7 days only. Its `ReportingScope.clientId` is always `null` (PENDING `reporting` :273).
- Nothing measures dispatch timeliness, and orders carry no promised date.
- `/reports` is a placeholder, and the portal has no service page.

**Approach:**
- **One read** computes a client's figures over an IST date range: `ReportingFacade.serviceReport`.
- It is served on **two routes**:
  - an operator route with the client in the path;
  - a portal route with the client from the session (the 21-7 stamp plus predicate).
- **Two web pages:**
  - the operator `/reports`, which gets a "Client service" section;
  - the portal `/portal/service`.
- No migration, no new table, no metric store.

**Decisions (human, 2026-10-10):**
1. **Timeliness** is measured against a **fixed 24 h target**:
   - the median time from order received (`orders.created_at`) to its dispatch;
   - the % of orders dispatched within 24 h.
   - A per-client target goes to PENDING.
2. **Period:** a chosen IST date range `from`/`to` (inclusive, at most 366 days). The web defaults to the last 30 days ending today.
3. **Operator surface:** the existing `/reports` page.
4. **Pick accuracy (amended after design review)** = of the client's order lines **dispatched** in the period, the % that **never had a short pick**.
   - A short that was later recovered still counts against the line.
   - Pack-check failures are shown beside it as a count, not folded into the ratio.
5. **Backlog (design review):** the timeliness tile also counts **late, not yet dispatched**: orders received in the period, not cancelled, with no dispatch as of now, and received more than 24 h ago.

## Boundaries & Constraints

**Always:**
- **Routes.**
  - **Operator:** `GET /tenants/{t}/reporting/clients/{c}/service?from&to[&warehouseId]` in `reporting.controller.ts`.
    - It sits behind `TenantSessionGuard` and is member-open, with no capability, like the Overview. These are floor-performance figures, with no money in them.
    - An unknown client is 404 `not-found`. Suspended clients and the tenant's `self` client (D2C) are valid.
  - **Portal:** `GET /tenants/{t}/portal/service?from&to[&warehouseId]`.
    - It sits behind `PortalSessionGuard` and `assertOwnTenant`, with `session.clientId`.
    - A query `clientId` is 400 `validation-failed` (`forbidNonWhitelisted`).
  - **Shared behaviour:**
    - An unknown `warehouseId` is 404 `not-found`; absent means every warehouse of the tenant.
- **Period.**
  - Validated in the facade, so both routes give identical details. The detail strings are those of `assertMeteringPeriod` (`billing/metering.ts:131`); the title is "Invalid report period"; max 366 days. 400 `validation-failed`.
  - Built over `shared/primitives/time.ts` (`isIsoDate`, `istMidnightOf`, `addIsoDays`).
  - The window is `[istMidnightOf(from), min(istMidnightOf(to+1), asOf))`, on server-stamped columns only. A `from` after today gives an empty window: counts 0, nulls, `asOf` shown.
- **Body `ServiceReportDto`.** It is the same on both routes and has **no `clientId`**:
  `{from, to, warehouseId|null, asOf, targetHours: 24, dockToStock: ServiceDockToStockDto{medianMinutes|null, placements}, pickAccuracy: ServicePickAccuracyDto{accuracy|null, linesDispatched, linesShortPicked, packFailures, packFailuresCountingSince|null}, dispatchTimeliness: ServiceDispatchTimelinessDto{ordersDispatched, onTime, onTimeRate|null, medianMinutes|null, lateNotDispatched}}`
  - The query is a `ServiceReportQuery` value class (the `ClientUsageQuery` pattern).
  - Ratios are 0–1 to 4 dp, and null when the denominator is 0. Medians are minutes to 1 dp.
- **Definitions.** *c* is the client and *wh* the optional warehouse filter. Every query **inner-joins** to a client-policied table (`skus`, `orders` or `ledger_events`) **and** carries `client_id = c`.
  - **Dock-to-stock.** The 9-1 tile SQL (`kpis.ts:389-401`): placements in the window, `join skus s on s.id = pp.sku_id and s.client_id = c`, negatives excluded.
    - `medianMinutes` (GRN recorded → placement recorded, median over placements) and `placements`.
  - **Dispatched orders**, which the next two metrics share as one CTE:
    - `dispatchedOrderEventsPredicate(scope, from, to)`, imported from `inventory.facade` (`:55`), grouped by `reference_doc->>'orderId'` with `min(recorded_at)` as `dispatchedAt`;
    - inner-joined `orders o on o.id = orderId::uuid and o.client_id = c`.
  - **Pick accuracy.**
    - `linesDispatched` = the CTE orders' `dispatch.dispatched` events in the window (one per order line).
    - `linesShortPicked` = those lines that have any `picklist_lines` row where `order_line_id` = the line and `reason_code is not null`. `reason_code` is written only on a short (`pick.command.ts:1070`) and survives the wave-cancel flip (`wave.command.ts:919`).
    - `accuracy = (linesDispatched − linesShortPicked) ÷ linesDispatched`.
    - `packFailures`: `pack_verification_failures` in the window, `join orders o … o.client_id = c`, plus wh. `packFailuresCountingSince` is 9-1's `countingSinceInTx`.
  - **Timeliness.**
    - `ordersDispatched` = `count(*)` of the CTE. It **must equal** `countDispatchedOrdersInTx` for the same client, period and warehouses.
    - The interval is `dispatchedAt − o.created_at`, clamped at 0. `onTime` means ≤ 24 h; `medianMinutes` is over orders.
    - `lateNotDispatched` = orders with `client_id = c` (plus wh), `created_at` in the window, `status <> 'cancelled'`, `created_at ≤ asOf − 24h`, and no `dispatch.dispatched` event for the order (the 0039 `orderId` index).
- **Isolation.**
  - `portalServiceReport` calls `withTenantTransaction(this.db, tenantId, fn, { clientId })` inline in `reporting.facade.ts`; the `PORTAL_READS` scan reads the method body.
  - Reporting stays read-only and imported only by the api shell.
- **Budget.** One transaction with `SET LOCAL statement_timeout = 5000`. A 57014 is 503 `report-unavailable`, with nothing partial returned.
- **Web.**
  - **Operator `/reports`.**
    - The nav label "Reports / Audit" is unchanged. The page gets a "Client service" section; 9-3's audit trail joins as a sibling section later.
    - Inputs:
      - client select from `useClients` (every status), with `clientLabel` for `self`;
      - from and to: `to = istDateOf(now)`, `from = to − 29` in UTC date arithmetic, validated by a generalised `parseCustomRange` (`lib/usage.ts:96`) before sending;
      - warehouse select from `use-tenant-warehouses`, default "All warehouses";
      - Refresh.
    - Three `KpiTile`s. Values use `formatFigure(v, 'minutes'|'percent')`. Counts go in `secondary`, with `lateNotDispatched` on the timeliness tile and "pack checks counted since …" when set. A caption names each tile's population.
  - **Portal `/portal/service`.** Nav label "Service". The same tiles and period. The warehouse select appears only when `portal/warehouses` (every tenant warehouse, reused deliberately) returns more than one.
    - `usePortalDetail` keyed `${from}|${to}|${warehouseId ?? ''}`.
    - Calls go through `portalError`, and `client-suspended` fires the portal event.
    - A 404 reads "That warehouse is no longer available"; a 503 reads "The report took too long — try a shorter period". Every request is `/portal/*`.

**Never:**
- a migration, a stored or cached metric, or a per-client target (PENDING);
- figures that differ between the two routes;
- drill-down (portal drill is PENDING :153);
- changing the Overview tiles' figures or `ReportingScope`;
- a `clientId` in the portal query or body;
- a chart library;
- removing the "Audit" half of the nav label.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected | Error |
|---|---|---|---|
| Happy | BRAND-A with receipts, picks and dispatches | Figures equal hand-computed fixtures | — |
| Isolation | A and B both active, in a cross-client wave | A's report counts none of B's rows on either route | — |
| Reconcile | 3 periods × (all warehouses, one warehouse) | `ordersDispatched` = `countDispatchedOrdersInTx` | — |
| Recovered short | A short line, then the remainder picked and dispatched | Line counted short-picked, once | — |
| Wave cancel | A zero-unit short, then the wave is cancelled | Still counted, once the line dispatches | — |
| Multi-line | A 3-line order | 1 order, 3 lines; median over orders | — |
| Boundary | Dispatched at exactly 24 h, and at 24 h + 1 s | On time, then late | — |
| Backlog | Received 30 h ago and undispatched; received 2 h ago; cancelled | 1 late; the others not counted | — |
| Empty / future | No activity, or `from` after today | 0s and nulls | — |
| Period | `from > to`, a bad date, or 367 days | — | 400 `validation-failed` |
| Unknown | A client or warehouse not in the tenant | — | 404 `not-found` |
| Portal | `?clientId=B`; a suspended client; an operator token | — | 400; 403s as in 21-7 |
| Timeout | A forced 57014 | — | 503 `report-unavailable` |

</frozen-after-approval>

## Code Map

`wms-be` paths are relative to `workspace/core/backend/wms-be`; `wms-fe` paths to `workspace/core/frontend/wms-fe`.

- **Reporting module:**
  - `src/modules/reporting/kpis.ts`:
    - the dock SQL is at `:389-401`, and pack failures at `:633-643`;
    - the private helpers `rowsOf`/`n`/`nf`/`ratio`/`ts` (`:299-334`) and `countingSinceInTx` (`:345`) **move** to a new `reporting/sql.ts`. `kpis.ts` imports them, and its figures are unchanged.
  - New `reporting/service.ts` holds the period guard, the queries and `SERVICE_TARGET_HOURS = 24`.
  - `reporting.facade.ts` gains `serviceReport` and `portalServiceReport`. The checks are `assertWarehouseInTenant` and `assertClientInTenantInTx` (`clients/clients.facade.ts:112`).
- **Shared predicate:** `inventory/inventory.facade.ts:55` (`dispatchedOrderEventsPredicate`, type `ClientScope`) and `:1258` (`countDispatchedOrdersInTx`, the equality oracle). Orders dispatch atomically, one event per line (`outbound/dispatch.command.ts:343-385`, `recordedAt = nowIso()`).
- **503 pattern:** `api/channels.controller.ts:89` (`*-unavailable` with `problemJsonResponse`).
- **API:** `src/api/reporting.controller.ts:26`, `src/api/portal.controller.ts` (13 routes), `billing-usage.controller.ts:15-21` (the query class pattern), `openapi.json`.
- **Tests:**
  - new `test/service-report.spec.ts`;
  - `test/portal.spec.ts:700` (13 → 14);
  - `test/architecture.spec.ts:1743-1797` (`PORTAL_READS` and the sorted list gain `reporting.facade.ts: portalServiceReport`);
  - `test/client-isolation.spec.ts`: a `wms_rls_probe` arm runs each query under A's stamp with only the `client_id = c` literal removed (joins kept) and returns A's rows only;
  - `test/reporting.spec.ts` stays green, which proves the helper move.
- **Web:**
  - Operator:
    - `app/(app)/reports/page.tsx` (placeholder) and `lib/navigation.ts:67` (label kept; `navigation.test.ts:20`);
    - `components/kpi-tile.tsx` (`secondary`), `lib/overview.ts:16-47`, `lib/use-clients.ts:23`, `lib/clients.ts:38`, `lib/use-tenant-warehouses.ts`;
    - `lib/usage.ts:96` (`parseCustomRange`; generalise `MAX_USAGE_DAYS`), `lib/rate-cards` `istDateOf`.
  - Portal:
    - `lib/portal.ts:72-77` (union and `PORTAL_NAV`), `:96-115` (`portalReadReason`);
    - `lib/use-portal.ts:41-42,114` (update the "no warehouse" comment);
    - `lib/api/client.ts:3311` (`portalError`). The wrappers are `fetchApiClientServiceReport` and `fetchApiPortalService`.
  - Tests:
    - `components/portal/portal.test.tsx` (nav list and test title `:211-222`, `/portal/*`-only `:589`);
    - `lib/portal.test.ts:41-45`.

## Tasks & Acceptance

**Execution:**
- [x] `wms-be` reporting: `sql.ts` (the move), `service.ts`, and the two facade methods.
- [x] `wms-be` api: both routes, the four DTO classes, and an `@ApiResponse` per arm; `openapi.json`.
- [x] `wms-be/test/service-report.spec.ts`: every matrix row on both routes, plus a deep exact-key `toEqual` on the body.
- [x] `wms-be` tests that change: `portal.spec.ts`, `architecture.spec.ts`, `client-isolation.spec.ts`.
- [x] `wms-be`: run `scripts/loadtest-overview.ts`'s seed once against a 366-day report and record the p95 in `modules/reporting.md` "Load" (reported, not a gate).
- [x] `wms-fe`:
  - `bun run api:generate`;
  - the wrappers and hooks;
  - `components/reports/client-service.tsx` and the page;
  - `components/portal/portal-service.tsx` and the route;
  - the nav.
  - Tests:
    - the default period, including the 00:00–05:30 IST edge in a non-IST zone;
    - a period the server would refuse is never sent;
    - changing the client, period or warehouse refetches (operator and portal);
    - a suspended client is selectable;
    - null shows "No data";
    - the portal nav is `['Stock','Orders','Inbound','Invoices','Service']`;
    - portal requests are `/portal/*` only;
    - `client-suspended` fires the event;
    - the 404 and 503 copy.
- [x] Meta docs:
  - `modules/reporting.md` (the 21-8 hook → done; the service read and its definitions);
  - `API-SURFACE.md`;
  - `frontend/SYSTEM-DESIGN.md`: `/reports` partial (service only); the placeholder count; the portal routes and nav;
  - `docs/repos/wms-be/README.md`, and `docs/repos/wms-fe/README.md:153-154`;
  - `PENDING.md`:
    - close `reporting` :273;
    - add the per-client target hours;
    - add "orders received = server ingestion time, not buyer order time";
    - add the dock-to-stock exclusions (non-GRN inbound, and offline placements stamped at sync).

**Acceptance Criteria:**
- Given BRAND-A and BRAND-B with activity, when an operator opens `/reports` for A and A's portal user opens Service for the same period, then both show identical figures, and B's activity changes neither.
- Given the full BE and FE suites, lint and typecheck, when run, then they pass.

## Implementation Notes

Baselines: wms-be `90033ce11c3bce4db73cad2fe081fc7459551e0b` (`baseline_commit`), wms-fe `05dc4afb75366eff0e24edbff69b74f76718c6ca`.
- Work on `feat/21-8-per-client-service-reporting` in both repos (already checked out). Leave everything uncommitted: no commit, push or PR.
- In wms-be, run `bun run test -- <file>`; never bare `bun test`, and never two jest invocations at once (globalSetup sweeps kill the other run's DBs). The ledger idempotency-race test can flake under full-suite load only; rerun it alone before blaming the story.
- Edit meta docs in `/Users/sasidhar/Documents/WMS-Meta` (uncommitted, on the current branch).
- Do not touch `wms-mobile`.

## Spec Change Log

- **Design review (2026-10-10):** pick accuracy was redefined (decision 4 amended by the human) and the backlog figure added (decision 5). Before, it was per pick slice windowed on `picklist_lines.updated_at`. That double-counted a recovered short as a miss plus a hit, and a wave cancel rewrote past figures. KEEP: one facade read behind two routes; billing's dispatched-order predicate as the shared truth.

## Review Triage Log

Three design-review lenses ran over the draft: backend claims, metric semantics, and web/contract. "Fixed" means folded into this spec.

| # | Lens | Finding | Verdict | Disposition |
|---|---|---|---|---|
| 1 | metrics, backend | Recovered short counted miss + hit; slice not line | high | Fixed: decision 4 amended, Recovered-short row |
| 2 | backend | Wave cancel flips a zero-unit short to cancelled and moves `updated_at`, so past figures change | high | Fixed: windowed on dispatch; short = `reason_code is not null` (verified `pick.command.ts:1070`, `wave.command.ts:919`) |
| 3 | metrics | Shorts are mostly stock failures; a second "accuracy" beside SM-3 | high | Fixed: the population is named on the tile caption; the reason split goes to PENDING if asked |
| 4 | metrics | Timeliness survivorship: a backlog is invisible | high | Fixed: decision 5, `lateNotDispatched` |
| 5 | web | Replacing `/reports` drops 9-3's Audit home | high | Fixed: label kept, sectioned page, Never row |
| 6 | backend | Duplicate-predicate rationale wrong; it is exported at `inventory.facade.ts:55` | medium | Fixed: import it (verified) |
| 7 | backend | Stamp protects only client-policied tables | medium | Fixed: inner-join rule; probe keeps joins |
| 8 | backend, metrics | "First" dispatch undefined; median must be per order | medium | Fixed: one CTE grouped by orderId; atomic dispatch verified |
| 9 | backend | `PORTAL_READS` regex needs the inline stamp | medium | Fixed: Isolation |
| 10 | backend, metrics | No budget; no `picklist_lines.updated_at` index | medium | Fixed: 5 s timeout → 503; accuracy no longer scans `picklist_lines` by time; loadtest task |
| 11 | metrics | Reconciliation overstated | medium | Fixed: Design Notes say which figures reconcile |
| 12 | metrics | Pack failures before 0058 read 0 | medium | Fixed: `packFailuresCountingSince` |
| 13 | metrics | Dock label and exclusions | medium | Fixed: label, plus PENDING |
| 14 | metrics | Metrics window on different events | medium | Fixed: tile captions and Design Notes |
| 15 | web | Missed FE tests (`portal.test.ts`, test title, union) | medium | Fixed: Code Map |
| 16 | web | IST default-period drift; no client validation | medium | Fixed: named helpers and an edge test |
| 17 | web | `usePortalDetail` keying | medium | Fixed |
| 18 | backend | kpis helpers are private | low | Fixed: move to `sql.ts` |
| 19 | backend | "metering" in the error title; future `from` | low | Fixed |
| 20 | backend | Member-open operator route | low | Decided: member-open, no money (Boundaries) |
| 21 | backend | `orders.created_at` = ingestion time | low | Fixed: PENDING note, DTO description |
| 22 | metrics | Negative intervals handled two ways | low | Decided: dock excludes (9-1 rule); timeliness clamps, so the count stays equal to billing |
| 23 | metrics | Exact 24 h boundary | low | Fixed: matrix |
| 24 | metrics | Denominators hidden | low | Fixed: counts in `secondary` |
| 25 | web | Warehouse select source and default | low | Fixed |
| 26 | web | Client picker statuses; `self` label | low | Fixed |
| 27 | web | No `percent` function exists | low | Fixed: `formatFigure` |
| 28 | web | Portal `clientId` query row | low | Fixed: matrix |
| 29 | web | Portal 404 copy | low | Fixed |
| 30 | web | DTOs and wrappers unnamed | low | Fixed |
| 31 | web | Meta-doc list incomplete | low | Fixed |
| 32 | web | `portal/warehouses` reuse | low | Fixed: stated as deliberate |
| 33 | backend | Offline placements inflate dock | low | Fixed: PENDING note (9-1 accepts the same) |
| 34 | metrics | Same-transaction placement ties | low | False: medians and counts are order-independent; there is no cursor |
| 35 | backend | Equality holds only with the same `[from, to)` | low | Confirmed: the test passes the facade's clipped window to the oracle |

**Code review (2026-10-10)** — Blind Hunter (B), Edge Case Hunter (E), Verification Gap (V) over the combined diff; 19 findings.

| # | Layer | Finding | Verdict | Route |
|---|---|---|---|---|
| C1 | B, E | `statement_timeout` set once bounds each statement, not the read — ~7 statements can hold a connection ~30 s while every surface promises a 5 s report budget | medium — verified `reporting.facade.ts` serviceInTx sets it once; `rowsOf` re-arms only for `TILE_TX_DEADLINES` (capped 1.5 s) | patch: whole-read deadline re-armed per query |
| C2 | B | No concurrency cap — portal users can start concurrent 366-day reads | medium — real; root is the pre-existing absence of any portal read rate limit (PENDING already carries the write cap) | defer |
| C3 | B | `ordersDispatched` joins `orders`, billing's count does not — orphaned / mismatched events would diverge | low — orders are never deleted and an order's client is its SKUs' (21-2b `sku-client-mismatch`; correction refused once history exists); not met in use | reject |
| C4 | B | `linesDispatched` counts events, not distinct lines | low — one event per line today (atomic dispatch, `dispatch.command.ts:343-385`); `count(distinct)` is a direct correction | patch |
| C5 | B | The RLS probe re-types the query shapes; can drift from `service.ts` | low — real developer drift risk; a shared builder is new structure for an unlikely edit | reject |
| C6 | B | Load note implies year-scale cost; the seed is ~7 days | low — true | patch: doc wording |
| C7 | B | Backlog includes backordered orders (client's own stock missing) | false — exactly decision 5 (received, not cancelled, undispatched > 24 h) | reject |
| C8 | B | Exception title never reaches the wire; tests pin title === detail; no PENDING item | low — `ProblemDetailsFilter` behaviour, pre-existing (billing same) | patch: PENDING entry |
| C9 | B | FE copies the 366-day bound by hand | low — drift only if the BE bound changes; fix is new schema surface | reject |
| C10 | B, E | A failed warehouse read silently leaves only "All warehouses" (operator and portal) | low — real but only on a failed read, and the report still works over all warehouses; fix adds a failure branch | reject |
| C11 | B | Portal may name any tenant warehouse (200 vs 404 discloses existence) | false — `portal/warehouses` already lists every tenant warehouse to the client (21-7b decision 1) | reject |
| C12 | B | Isolation test's genesis-hash probe events break the chain | false — the file already seeds probe events this way (`client-isolation.spec.ts:17,167,605`) and nothing in it verifies a chain | reject |
| C13 | E | A line with an `unfulfillable` slice counts as accurate | false — decision 4 counts short *picks*; an unfulfillable slice is a plan-time stockout, never picked (excluded deliberately, design review #3) | reject |
| C14 | E | `to = 9999-12-31` passes the guards and 500s in `addIsoDays`/`istMidnightOf` | low — real but needs a year-9999 period; fix adds a guard (billing shares it) | reject |
| C15 | E | A ratio ≥ 0.9995 and < 1 renders "100%" | medium — `formatFigure` rounds to 1 dp; 1 short in 5,000 lines reads perfect to a client | patch |
| C16 | V | Dock-to-stock's upper bound `pp.created_at < window.to` is never exercised | medium — pre-verified gap; dropping it passes every test | patch: fixture after P + boundary assertion |
| C17 | V | `portalReadReason` `report-unavailable` arm unreachable and duplicates the copy | low — `portalServiceReason` answers it first | patch: delete |

## Design Notes

- **Why one facade read behind two routes.** CAP-10's success is that the operator and the client see the same truth. Two queries would drift.
- **What reconciles to the ledger.** Every timeliness figure and the accuracy denominator come from `dispatch.dispatched`. `ordersDispatched` equals the count the client is invoiced for, and the test pins it.
  - Dock-to-stock and short picks are projections over rows written in the same transaction as their ledger events (9-1's argument).
  - Pack failures come from a fact table that is not backfilled before 0058.
- **Why accuracy windows on dispatch.** The dispatch event is immutable and client-stamped, so last month's figure cannot change. `picklist_lines.updated_at` is rewritten by a wave cancel. Each tile's population is named on it:
  - placements made in the period;
  - lines dispatched in the period;
  - orders dispatched in the period;
  - orders received in the period, for the backlog.
- **Why the SKU join is safe for dock-to-stock.** `sku-client.command.ts:64` refuses a client correction once a SKU has ledger events. Only the race at PENDING :150 remains.

## Verification

**Commands:**
- `cd workspace/core/backend/wms-be && bun run test -- test/service-report.spec.ts` -- expected: pass (never two jest runs at once)
- `cd workspace/core/backend/wms-be && bun run test && bun run lint && bun run typecheck` -- expected: pass
- `cd workspace/core/frontend/wms-fe && bun run api:generate && bun test && bun run typecheck && bun run lint` -- expected: pass (the generated-client drift guard fails in CI until the BE merges)

**Manual checks:**
- Real-HTTP smoke: the operator `/reports` for BRAND-A versus the BRAND-A portal Service page over the same period show the same numbers.
