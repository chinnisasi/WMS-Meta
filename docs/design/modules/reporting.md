# Reporting module

> The operational dashboard (FR-27, story 9-1): a per-warehouse read model that computes ten KPI tiles as projections over the owning modules' records, served by one Overview endpoint, with every figure naming the exact list behind it. The audit trail and exports (9-3) join this module next.

Source: `workspace/core/backend/wms-be/src/modules/reporting/`. Every `file:line` below is relative to `wms-be/`. Read `../IMPLEMENTATION-GUIDE.md` first — and its §7a, the read-only exception this module exists under.

---

## Owns

**No tables.** The module is a read model: `kpis.ts` (one function per tile), `window.ts` (the IST windows), `reporting.facade.ts` (the warehouse check and the best-effort runner). It exports `ReportingFacade` alone; the api shell's `ReportingController` (`src/api/reporting.controller.ts`, DTOs in `src/api/reporting.dto.ts`) is its only consumer.

The two facts the dashboard needed that nothing stored before are **outbound-owned**, not reporting's (see `outbound.md`):

| Table | Written by | Feeds |
|---|---|---|
| `pack_verification_failures` | `PackCommandService.packOrder` — after the pack transaction rolled back, fresh tenant tx, best-effort | SM-3 order accuracy |
| `ingest_backorder_refusals` | `OrderCommandService.createOrder`'s reject-policy arm — after `releaseAll`, outside any tx, `ON CONFLICT DO NOTHING`, best-effort | SM-4 "prevented" |

Both were added by `drizzle/0058_reporting_facts.sql`, which also stamped `app_metadata.reporting_facts_since` (the tiles' `countingSince`) and built `ledger_events (tenant_id, warehouse_id, type, recorded_at)`. **No backfill**: the facts are counted from that instant on. **The migration and the code that writes the facts ship in ONE release** — `countingSince` is the migration's own `now()`, so it is exact only because no writer can run before the tables exist and no release runs the migration without the writers. Splitting them would make `countingSince` claim coverage the writers did not give.

Retries never inflate the facts: a failed pack records its attempt's idempotency key (the route's `Idempotency-Key`, or the sync-report op's ULID), and a partial unique `(tenant_id, idempotency_key) WHERE idempotency_key IS NOT NULL` with `ON CONFLICT DO NOTHING` makes a same-key retry — or a repeated sync-report apply — one row. Refusals dedupe on `(tenant, integration, external event)`.

## Decision 6 — the named read-only exception

Everywhere else a module reads a sibling's state only through its facade (AD-6). Reporting's tiles read the owning modules' tables **directly, read-only**, by human decision (9-1, decision 6): ten aggregate counts through ten facades would be ten bespoke "count my rows in this window" methods with one consumer each — a second definition of every KPI, free to drift from the one here.

The exception is bounded by guards in `test/architecture.spec.ts` ("reporting is a read-only exception…"):

1. nothing under `src/modules/reporting` writes any table — no Drizzle `.insert/.update/.delete`, no raw `INSERT INTO` / `UPDATE … SET` / `DELETE FROM` / `TRUNCATE` (detectors pinned against counterexamples);
2. nothing imports the reporting module except the api shell (`src/api/**`) and the root composition (`app.module.ts`);
3. the module exports only `ReportingFacade`, and both fact tables are in the **outbound** ownership list.

**Do not copy this into another module.** A new read model that wants the same freedom needs its own human decision and its own guard.

## Public seam

| Method | Shape | Does | Called by |
|---|---|---|---|
| `overview` | `(tenantId, warehouseId, now = new Date()) → Overview` | Warehouse check, then the ten tiles under the runner | `GET /tenants/{t}/warehouses/{w}/reporting/overview` |

`Overview` = `{asOf, stale, window: {todayFrom, d7From, to}, tiles: {dockToStock, pickRate, shortPicks, grnVariances, orderAccuracy, oversell, expiryAlerts, syncHealth, dispatchPipeline, sm8}}`. Each tile carries `state: 'ok' | 'unavailable'`. Every figure is `{value: number | null, drill: {apiPath, query, reconciles}}`; a windowed figure is `{today, d7}` of those. `value` is null when the tile is unavailable **or** the figure has no data (an empty median or ratio) — never a fake 0. `drill` is always present, unavailable tiles included.

Member-open: reads are never capability-gated.

## The flow

```mermaid
sequenceDiagram
  participant W as web (OverviewDashboard)
  participant C as ReportingController
  participant F as ReportingFacade
  participant PG as Postgres

  W->>C: GET …/warehouses/{w}/reporting/overview
  C->>F: overview(t, w)
  F->>PG: tx: assertWarehouseInTenant → 404 BEFORE any tile
  Note over F: asOf = now; IST windows fixed once (window.ts)
  par at most 3 tiles at a time
    F->>PG: tile tx: set_config('statement_timeout','1500',true); tile SQL
  end
  Note over F: at 1.8 s: assemble from what finished.<br/>still running / never started → unavailable<br/>57014 or deadline → silent; any other error → logged with the tile name
  F-->>C: {asOf, stale, window, tiles}
  C-->>W: 200
```

## The runner (AD-17 — tiles are sheddable)

- **Concurrency 3, process-wide** (`TILE_CONCURRENCY`) — one semaphore shared by every concurrent Overview read, so N viewers still hold at most 3 tile transactions between them; the pool is `max: 10` (`shared/db/db.ts`) and the scan path must never queue behind dashboards. A tile waiting for a slot gives up at the deadline (`unavailable`, no connection taken).
- **Each tile in its own tenant read transaction**, and **every statement** re-arms `set_config('statement_timeout', min(1500 ms, time left), true)` first — transaction-local, so it dies with the transaction, and no straggler outlives the deadline by more than a round trip.
- **Overall deadline 1.8 s** (`OVERVIEW_DEADLINE_MS`): workers start a tile only while the budget lasts; at the deadline the response is assembled from a snapshot of finished results. A straggler's late result is ignored.
- **Silent vs logged:** a statement timeout (SQLSTATE `57014`, found by walking drizzle's `cause` chain) or the deadline yields `unavailable` silently; **any other error is logged** (`Reporting tile "<name>" failed …`) and also yields `unavailable` — one broken tile never 500s the page.
- **`stale: true`** whenever any tile is unavailable.
- `facade.tiles` is a plain field — a suite substitutes one definition to force a deadline or a fault without a second production code path.

## Windows (`window.ts`)

IST calendar days computed in TS (`IST_OFFSET_MS`, now in `shared/primitives/time.ts`) and bound as `timestamptz` — never `now()` or a session-zone `date_trunc` in SQL. One `asOf` fixes every bound of a read.

| Window | Bounds |
|---|---|
| today | `[IST midnight of asOf, asOf)` |
| 7d | `[IST midnight 6 days before, asOf)` — today plus the six days before it |
| last hour | `[asOf − 1 h, asOf)` (pick rate) |
| last 24 h | `[asOf − 24 h, asOf)` (sync failures) |

**Server-stamped columns only** (`created_at`, `recorded_at`, `updated_at`, `requested_at`, `issued_at`, integration `at`) — never a device `occurred_at`, so an offline op replayed tomorrow never revises "today". A row stamped 18:29:59.999 UTC is yesterday (IST); 18:30:00 is today.

## The tiles

| # | Tile | Figure | Source & definition | Drill | Reconciles |
|---|---|---|---|---|---|
| 1 | dockToStock | `medianMinutes` {today, d7} | median of `putaway_placements.created_at − goods_receipt_notes.created_at` (minutes) over placements in the window; negative intervals excluded | ledger `type=putaway.placed` | no (a median) |
| | | `awaitingPutaway` (live) | GRN lines with applied units whose (sku, batch) still has on-hand in the system Receiving bin — `PutawayFacade.getPutawayTasksInTx`'s derivation in one statement | `GET /putaway/tasks?warehouseId` | **yes** |
| 2 | pickRate | `pickLines` {today, d7}, `lastHour` | `picks` rows by `created_at` — one per pick line (a 10-serial line is ONE line; the ledger has ten draws) | ledger `type=pick.picked` | no (units differ) |
| 3 | shortPicks | `shortLines` {today, d7} | `picklist_lines.status = 'short'` by `updated_at` (the terminal flip), via `picklists` for the warehouse — **zero-unit shorts included** (they write no `picks` row and no event) | `…/outbound/picklist-lines?status=short` (window on `updated_at`, keyset on the immutable `(created_at, id)`) | **yes** |
| 4 | grnVariances | `overReceipts` {today, d7} | `over_receipts.requested_at` in the window | `/receiving/over-receipts?warehouseId` | **yes** |
| | | `pendingOverReceipts` (live) | `status = 'pending'`, requested before `asOf` | `?warehouseId&status=pending&to` | **yes** |
| | | `blindGrns` {today, d7} | `goods_receipt_notes.blind_reason_code IS NOT NULL` by `created_at` — **21-6: blind is the reason, not the absent PO** (an ASN receipt has `po_id IS NULL` and is not blind) | `/receiving/goods-receipts?warehouseId&blind=true` (21-6 — `poless` stays accepted as its alias) | **yes** |
| 5 | orderAccuracy (SM-3) | `defectsPer1000` {today, d7} | **The PRD's SM-3 formula** (decision 5): `(short-picked lines + failed pack verifications) × 1000 ÷ dispatched lines`, one decimal; null with no dispatched line. Not a redefinition — "mis-picks" is measured as short-picked lines because a wrong-item scan is refused at pick and never stored (PENDING) | ledger `type=dispatch.dispatched` | no (a rate) |
| | | `shortLines`, `packFailures`, `dispatchedLines` | as tile 3; `pack_verification_failures.created_at`; distinct `referenceDoc.orderLineId` of `dispatch.dispatched` by `recorded_at` (one event per line, so the event count is the line count) | picklist-lines; `…/outbound/pack-failures`; ledger | **yes** |
| | | `countingSince` | `app_metadata.reporting_facts_since` | — | — |
| 6 | oversell (SM-4) | `backorderedOrders` {today, d7} | `orders.source = 'ingested'` by `created_at` with **any** line `status = 'backordered'` (set only at acceptance) — counted per ORDER, so a kit's parent and children never double-count | `…/outbound/orders?source=ingested&backordered=true` | **yes** |
| | | `prevented` {today, d7} | `ingest_backorder_refusals.created_at`, **excluding** a refusal whose `(integration_id, external_event_id)` now has an order — a redelivery accepted once stock arrived was not prevented. The drill list applies the same exclusion | `…/outbound/backorder-refusals` | **yes** |
| 7 | expiryAlerts | `openExpiryUpcoming`, `openAged` (live) | open `batch_alerts` by kind, raised before `asOf` | `/replenishment/batch-alerts?warehouseId&kind&status=open&to` | **yes** |
| | | `raised` {today, d7} | alerts of either kind by `created_at` | `?warehouseId&from&to` | **yes** |
| 8 | syncHealth | `connections[]` | every connection (connected **or disconnected**) whose `ingest_warehouse_id` is this warehouse **or unset**. Health, most severe first: disconnected → `error`/`disconnected`; unset ingest warehouse → `error`/`ingest-warehouse-unset`; then **`/channels`' own rule, reused — `connectionHealth()` via the channels facade, never re-derived**: breaker open → `error`/`breaker-open`; half-open, last delivery failed, never synced, or lag over the 60 s SLO → `degraded` (`breaker-half-open`/`last-delivery-failed`/`never-synced`/`sync-lag`); finally a genuine `order-ingest` failure in 24 h → `degraded`/`ingest-failures`. Failure = `INGEST_CALL_OUTCOMES`, a `Record` over every `INTEGRATION_CALL_STATUSES` member (a new status fails the build until classified); a policy refusal (`rejected` — a prevented oversell), settled cancellations (`released`, `ignored`) and successes are NOT failures | `/channels/connections` | no |
| 9 | dispatchPipeline | `accepted`, `readyToDispatch` (live) | `orders.status`, created before `asOf` | `…/outbound/orders?status=…&to` | **yes** |
| | | `labelledNotManifested` (live) | `shipments.status = 'labelled'` — no list of its own | orders `?status=ready_to_dispatch` | no |
| | | `ordersDispatched` {today, d7} | distinct `referenceDoc.orderId` of `dispatch.dispatched` | ledger | no (events per line) |
| 10 | sm8 (SM-8) | `eligible` {today, d7} | `eway_bills.created_at` in the window for this warehouse's invoices (a bill has no warehouse — joined through `invoice_id`), excluding `dismissed` bills and `voided` invoices | `/eway/bills?warehouseId` | no (the list cannot exclude dismissed) |
| | | `gatewayGenerated` {today, d7} | of those, `status = 'generated' AND source = 'gateway'` | `?warehouseId&source=gateway` | **yes** (a gateway source exists only on a generated bill; no code path writes `voided` today) |
| | | `gatewayShare` {today, d7} | `gatewayGenerated ÷ eligible`, 0–1; null with none eligible. **Reads 0 until a live gateway adapter exists** — deliberately (decision 5): it shows the real gap | as above | no |
| | | `invoicesIssued`, `noManualPricingShare` {today, d7} | invoices of the warehouse by `issued_at`; the share with **no** `invoice_lines.rate_source = 'manual'` | `/invoices?warehouseId` | issued: **yes**; share: no |

Every windowed drill carries `from` (today's or the 7-day start) and `to = asOf`; live drills carry `to = asOf` where the list has the filter (the putaway task list has none — it is live by construction).

## Invariants

| Invariant | Enforced by |
|---|---|
| A `reconciles: true` figure equals its drill paged to exhaustion | `test/reporting.spec.ts` pages every one at `limit=2` (so the cursor walks). The drills' lists carry full-precision cursors (`fullPrecisionInstant`) — a millisecond-truncated cursor skips the rest of a same-transaction tie group (a wave writes all its picklist lines at one `now()`, a GRN all its over-receipts) |
| The warehouse is checked before any tile runs | `overview()` asserts first, in its own short transaction; a spec spies `runTiles` and asserts it was never called on a 404 |
| A tile never 500s the page | the runner maps every error to `unavailable` |
| Reporting writes nothing; only the api shell imports it | `test/architecture.spec.ts` |
| Fact writes never change a refusal | both writers run after the refused work rolled back / released, inside `try/catch` that logs; a spec renames both tables away and asserts the 422 / 409 stand |

## Events

None produced, none consumed. The dashboard is pull-only and the web reloads it only on a warehouse switch or Refresh — no polling (UX-DR19).

## The 21-8 hook

Every tile takes `ReportingScope {tenantId, warehouseId, clientId: null}`. Story 21-8 slices by client by giving `clientId` a value; the tiles over `orders` / `ledger_events` (both carry `client_id`) then add the predicate, and the relational-only tiles need a join through `skus.client_id`. No tile may assume the field is always null.

## Gotchas

1. **The ledger is not the pick count.** `pick.picked` is one event per (sku, batch) arm and per serial unit, and a zero-unit short pick writes none. Pick lines come from `picks`, short picks from `picklist_lines`; the ledger drill for pick rate says `reconciles: false` for this reason.
2. **`count(*)::bigint` is a string** through postgres.js (IMPLEMENTATION-GUIDE §2) — every tile coerces at `n()`.
3. **A refused command moved no stock** — that is why the two facts are tables, not ledger events. The ledger is stock movements under a hash chain; non-movements would distort replay and reconciliation.
4. **The 0058 index is a plain build.** drizzle's migrator runs every pending migration in one transaction, where `CREATE INDEX CONCURRENTLY` is illegal. For a live deploy follow the runbook in `PENDING.md` (reporting).
5. **`countingSince` is when 0058 ran, not when the tenant began.** A figure over a window that starts before it is a partial count; the web says so.

## Load

`bun scripts/loadtest-overview.ts` seeds ~25k ledger events over 7 days for one warehouse (through `InventoryFacade.appendLedgerEventInTx` in batches) plus, at volume, every relational source a tile reads (picks, GRNs/putaways/over-receipts, orders/lines with ingested and backordered slices, waves/picklists/lines with short slices, batch alerts, invoices/lines/e-way bills, both fact tables), then reads the Overview 40 times and reports p95 overall and per tile. Reported, not a CI gate. Measured 2026-10-06 (local compose Postgres 18): **p95 ≈ 25 ms** overall, slowest tile `orderAccuracy` (p95 ≈ 10 ms), 0 stale reads — against the 2 s NFR-6 budget.
