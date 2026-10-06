---
title: 'Operational dashboard — per-warehouse KPIs as ledger projections'
type: 'feature'
created: '2026-10-06'
status: 'done'
route: 'dispatch'
baseline_commit: '049ace4506155fd31675bf65fbff7d2637a4311f'
review_loop_iteration: 0
context:
  - '_bmad-output/implementation-artifacts/epic-9-context.md'
  - 'docs/design/SYSTEM-DESIGN.md'
  - 'docs/design/IMPLEMENTATION-GUIDE.md'
  - 'docs/design/modules/inventory.md'
  - 'docs/design/modules/outbound.md'
  - 'docs/design/modules/inbound.md'
  - 'docs/design/modules/replenishment.md'
  - 'docs/design/modules/channels.md'
  - 'docs/design/modules/invoicing.md'
  - 'docs/design/frontend/SYSTEM-DESIGN.md'
  - 'docs/design/frontend/IMPLEMENTATION-GUIDE.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** The Overview is a placeholder. Three of its tiles read "—", and a health probe is the only live data. An ops manager has no trustworthy live view of a warehouse (FR-27, story 9.1). Two PRD success metrics (SM-3 order accuracy, SM-4 oversell) rest on facts nothing stores. Two items routed here are still open: channel sync health (epic-7 retro) and SM-8 (epic-8 retro).

**Approach:** A `reporting` read model computes each KPI for the active warehouse, served by one Overview endpoint. Two missing facts are recorded from now on. The Overview becomes live tiles, and each tile names the exact list behind its number.

**Decisions (human, 2026-10-06):**
1. **Record the missing facts from now on.** These are failed pack verifications and channel orders refused under the reject policy. Manual order entry never refuses for stock; it backorders. Tiles that use these facts say "counting since <date>".
2. **Window: today plus the last 7 days.** Each tile shows today's figure (the IST day so far) with the 7-day figure beneath it. "Live" figures (open now) have no window.
3. **Click-through, split.** This story ships every backend list filter, each tile's exact `drill`, and tiles that link to their screens. The Ledger page, and existing screens reading filters from the URL, are **9-1b** (frontend only).
4. **SM-8 gets a compliance tile.**
5. **The tiles follow the PRD's metric definitions:**
   - **SM-3 order accuracy:** (short-picked lines + failed pack verifications) per 1,000 dispatched lines.
   - **SM-4 oversell:** channel orders *accepted* with at least one backordered line. Orders refused under the reject policy are shown beside it as "prevented".
   - **SM-8:** the share of e-way-eligible dispatches with a *gateway*-generated bill. It reads 0% until a live adapter exists. The share of invoices issued with no manual pricing is shown as a secondary figure.
6. **Reporting reads other modules' tables directly, read-only.** This is a named architecture exception, guarded by a test: reporting writes nothing, and nothing but the API imports it.

## Boundaries & Constraints

**Always:**
- **Windows** use **server-stamped** columns (`created_at`/`recorded_at`, never device `occurred_at`), so "today" never revises when offline work replays. They are IST calendar days computed in TS and bound as timestamptz. `today` = [IST midnight, `asOf`) and `7d` = [IST midnight 6 days ago, `asOf`). Upper bounds are exclusive.
- **Reconciliation.** For every figure marked `reconciles: true`, paging its `drill` route to exhaustion with the drill query (bounded by `asOf`) yields exactly that count. Rates, medians and ratios are marked `reconciles: false` and still name their source list. There is no "estimated" state: a tile is a number or `unavailable`.
- **Scope:** per warehouse. The warehouse is checked to exist in the tenant **before** any tile runs (else 404). Member-open; reads are never capability-gated. KPI functions take `ReportingScope {tenantId, warehouseId, clientId: null}` so 21-8 can add a client slice.
- **Best-effort tiles** (AD-17):
  - at most **3 tiles run concurrently**;
  - each tile runs in its own read transaction with `set_config('statement_timeout','1500',true)`;
  - there is an **overall deadline of 1.8 s**: any tile not finished by then is `unavailable`;
  - only a timeout (SQLSTATE 57014) or the deadline yields `unavailable` silently; any other error is logged with the tile name and also yields `unavailable`;
  - `stale: true` whenever any tile is `unavailable`.
- **The web:**
  - it always shows "as of HH:MM";
  - it shows the stale banner (warning tone, with a Refresh button) when `stale`, or when `asOf` is more than 5 minutes old (a render-time comparison);
  - it reloads only on a warehouse switch or on Refresh; there is no polling (UX-DR19).
- **Fact writes are best-effort and never change the response.**
  - The pack failure is written after the pack transaction has rolled back, in a fresh tenant transaction.
  - The ingest refusal is written after `releaseAll`, outside any transaction.
  - If either write fails, it is logged, and the caller gets exactly today's refusal.

**Never:**
- rollup or summary tables;
- client slicing (21-8);
- notifications (9-2);
- the Ledger page or URL-reading screens (9-1b);
- totals on list responses;
- backfilling facts;
- changing what any command accepts or refuses;
- auto-refresh.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected | Error |
|---|---|---|---|
| Overview read | Active warehouse | Every tile `ok`, `asOf`, `stale: false` | — |
| Empty warehouse | No activity | Counts are 0; medians, rates and ratios are `null` ("no data") | — |
| Slow tile | Forced timeout on one tile | That tile is `unavailable`, the others `ok`, `stale: true`, response < 2 s | — |
| IST boundary | A pick row `created_at` 18:29:59 vs 18:30:00 UTC | Counted in yesterday vs today | — |
| Pack mismatch | Scans differ from picks, on the tenant, device or sync-report path | 422 `pack-mismatch` unchanged, plus one failure row | — |
| Fact write fails | Forced error in the fact write | The caller still gets the original 422/409; the failure is logged | — |
| Channel reject | Ingest with `backorder_policy=reject` and short stock | Today's refusal, plus one refusal row | — |
| Redelivered rejected webhook | Same integration and external event | No second refusal row | — |
| Zero-unit short pick (empty bin) | A short with 0 units | Counted in short-picks (from the picklist line) | — |
| Serial pick | One pick line with 10 serials | Counted as one pick line | — |
| SM-8 with no gateway | Every bill numbered by hand | 0% gateway-generated; eligible count shown | — |
| Reconciliation | Every `reconciles: true` figure | Equals its drill route paged to exhaustion | — |
| Foreign warehouse | — | — | 404 before any tile runs |

</frozen-after-approval>

## Code Map

- **Ledger.** `ledger_events` (`schema.ts:921-994`) has `type`, `recorded_at`, `created_at`, `reference_doc` and `client_id`. It has no `type`/time index. The timeline route `GET …/warehouses/:w/inventory/events` (`inventory.controller.ts:606-637`) is keyset on `(created_at, id)` and filters only by `skuId`/`binId` (`inventory.dto.ts:216`, `inventory.facade.ts:128-139`).
  - `pick.picked` is written per (sku, batch) arm, and per serial unit (`ledger-registry.ts:362-373`).
  - `pack.packed` and `dispatch.dispatched` are written once per order line (:383-425).
  - A zero-unit short pick writes **no** event and **no** `picks` row (`pick.command.ts:463-480,1291-1296`).
- **Sources:**
  - `picks` (one per line, `picks_line_unique`, `created_at`);
  - `picklist_lines.status='short'` (terminal flip, so `updated_at` is the flip time; join `picklists` for the warehouse);
  - `goods_receipt_notes` (`po_id IS NULL` = blind) and `goods_receipt_lines.applied_qty`;
  - `putaway_placements` (`grn_line_id`, `created_at`), with the remaining quantity taken from `GET /putaway/tasks` (`putaway.controller.ts:112`);
  - `over_receipts` (`requested_at`, `warehouse_id`);
  - `batch_alerts` (`created_at`, `kind`, `status`);
  - `orders` (`status`, `source`, `created_at`) and `order_lines` (`status='backordered'` set only at create, with `parent_line_id` for kits);
  - `integrations` (`status`, `ingest_warehouse_id`, `last_synced_at`) and `integration_calls` (`kind`, `status`, `at`);
  - `invoices` (`warehouse_id`, `status`, `issued_at`) and `invoice_lines.rate_source`;
  - `eway_bills` (no `warehouse_id`; join through `invoice_id`; `status`, `source`, `created_at`).
- **Refusal sites:**
  - `outbound/pack.command.ts:261,473`. `assertScanMatchesPicked` throws **inside** the transaction while it holds `FOR UPDATE` on the order and device rows. Three entry paths (tenant route, device route, sync-report apply) all reach the command.
  - `order.command.ts:697-700,1590-1602`. The `BackorderRejectedError` arm is reached only from channel ingest, after `releaseAll`, outside any transaction.
  - The ingest mints a per-delivery ULID (`channels.ingest.command.ts:171-175`), so dedupe must use `(integration_id, external_event_id)`, which is `orders_source_event_unique`'s identity.
- **Infrastructure:**
  - pool `max: 10` (`shared/db/db.ts:12`);
  - the transaction-local `set_config` pattern (`tenant-scope.ts:28`);
  - `IST_OFFSET_MS` lives in `invoicing/generator.ts` (move it to `shared/primitives/time.ts` and re-export from the generator);
  - `app_metadata` (`schema.ts:10`) for the counting-since stamp;
  - drizzle's migrator runs all pending migrations in one transaction (no `CONCURRENTLY`).
- **Architecture:** `test/architecture.spec.ts` (import and ownership rules :165-1216; outbound ownership :200-231). `reporting/reporting.module.ts` is an empty placeholder. The next migration is **0058**.
- **Web:**
  - `app/(app)/page.tsx` is a server component with `—` tiles and a health tile;
  - `components/kpi-tile.tsx` has no `href`;
  - `components/feedback/banner.tsx` has two tones and no action slot; `--warning` is in `globals.css:40`;
  - the active warehouse comes from `lib/warehouses.ts:25-48` with `useOutboundWarehouses`, falling back to `items[0]` (`outbound.tsx:96`).

## Tasks & Acceptance

**Execution:**
- [x] `wms-be/drizzle/0058_reporting_facts.sql` (+ journal, snapshot, schema.ts) -- guarded; RLS hand-appended (0047 pattern); no FKs:
  - **Index** `ledger_events (tenant_id, warehouse_id, type, recorded_at)`. A plain build: no `CONCURRENTLY` inside drizzle's transaction. The lock window is acceptable before launch; the header states it, and PENDING records a `CONCURRENTLY` runbook for a live deploy.
  - **`pack_verification_failures`** (owned by outbound): `id`, `tenant_id`, `warehouse_id`, `order_id`, `entry` (`tenant|device|sync`), `actor_user_id`, `mismatch` jsonb, `created_at`. One row per failed attempt.
  - **`ingest_backorder_refusals`** (owned by outbound): `id`, `tenant_id`, `warehouse_id`, `integration_id`, `external_event_id`, `lines` jsonb (sku, requested and available milli-units), `created_at`, with `UNIQUE (tenant_id, integration_id, external_event_id)`.
  - An `app_metadata` row `reporting_facts_since = now()`.
  - Indexes `(tenant_id, warehouse_id, created_at)`.
- [x] `wms-be` outbound -- fact writes:
  - **Pack:** `assertScanMatchesPicked` throws a typed `PackMismatchError` that carries `{warehouseId, orderId, mismatch}` and maps to today's problem. `packOrder` catches it **after** the outer transaction, writes the row in a fresh tenant transaction (best-effort), and rethrows the unchanged problem. This covers all three entry paths.
  - **Ingest:** the `BackorderRejectedError` arm writes the refusal with `ON CONFLICT DO NOTHING` (best-effort).
  - The outbound facade gets list reads: pack failures, refusals, short picklist lines.
- [x] `wms-be/src/modules/reporting/` -- the files:
  - `window.ts`: IST windows from the shared `IST_OFFSET_MS`;
  - `kpis.ts`: one function per tile, each `(tx, scope, window)`, using direct read-only SQL per decision 6;
  - `reporting.facade.ts`: the warehouse check, then a runner with concurrency 3, the per-tile `statement_timeout`, the 1.8 s deadline, the 57014/deadline mapping and logging.

  Every figure carries `drill: {apiPath, query, reconciles}`. The tiles, with figures `{today, d7}` unless marked live:
  1. **dockToStock:**
     - median minutes from GRN `created_at` to placement `created_at` (negative intervals excluded), over placements in the window (`reconciles: false`);
     - `awaitingPutaway` (live): lines with remaining quantity > 0, as `GET /putaway/tasks` computes it. It drills there (`true`).
  2. **pickRate:** pick lines (`picks.created_at`) and `lastHour`. It drills to the ledger with `type=pick.picked` (`false`; the units differ).
  3. **shortPicks:** `picklist_lines` with `status='short'` flipped in the window, including zero-unit shorts. Drill: the new `…/outbound/picklist-lines?status=short&from&to` (`true`).
  4. **grnVariances:**
     - over-receipts requested in the window, plus `pending` (live);
     - blind GRNs (`po_id IS NULL`) in the window.

     Drills: over-receipts (`warehouseId`, `status`, `from`, `to`) and goods-receipts (`poless=true`, `from`, `to`), both `true`.
  5. **orderAccuracy (SM-3):** `defectsPer1000 = (short lines + pack failures) × 1000 ÷ dispatched lines` (distinct `orderLineId` of `dispatch.dispatched` recorded in the window), plus its parts, each with a reconciling drill (pack failures list; short lines; ledger `type=dispatch.dispatched`), plus `countingSince`.
  6. **oversell (SM-4):** ingested orders created in the window with at least one backordered line, counted per order (kit children never double-count). Drill: orders `?source=ingested&backordered=true&from&to` (`true`). Plus `prevented` (refusals; refusal list; `true`) and `countingSince`.
  7. **expiryAlerts:** open `batch_alerts` by kind (live), plus those raised in the window. Drill: batch-alerts (`kind`, `status`, `warehouseId`, `from`, `to`) (`true`).
  8. **syncHealth:** per connection with `status='connected'`:
     - ingest warehouse = this one or unset;
     - unset → health `error` with reason `ingest-warehouse-unset`;
     - the lag (`now − last_synced_at`) reported as-is;
     - ingest failures in the last 24 h (`integration_calls`, status not `ok`).

     Drill: channel connections (`false`).
  9. **dispatchPipeline:**
     - live orders `accepted` and `ready_to_dispatch`; drill: orders `?status=` (`true`);
     - shipments labelled but not manifested (live; `false`, no list);
     - orders dispatched (distinct `orderId` of `dispatch.dispatched` in the window; `false`).
  10. **sm8 (SM-8):**
      - eligible = e-way bills created in the window for this warehouse's invoices, excluding dismissed and excluding voided invoices;
      - `gatewayShare` = those `generated` with `source='gateway'` (`null` when there are none eligible). Drill: e-way bills (`warehouseId`, `from`, `to`, `source`) (`true`).
      - Secondary: the share of invoices issued in the window with no `manual` rate-source line. Drill: invoices (`warehouseId`, `from`, `to`) (`false`).
- [x] `wms-be/src/api/reporting.controller.ts` + DTO -- `GET /tenants/{t}/warehouses/{w}/reporting/overview` returns `{asOf, stale, window: {todayFrom, d7From, to}, tiles}`. There is one flat DTO class per tile: a `state` enum; figures nullable (`null` when `unavailable` or no data); nullable enums written `enum: [...X, null]`; `drill` always present. Re-export `openapi.json`.
- [x] `wms-be` list filters (additive, all optional):
  - **The ledger timeline:**
    - `type`, repeatable; a single value is transformed to an array and validated against the registry;
    - `from` and `to` on `recorded_at`;
    - `orderId`;
    - `shortPick`, transformed explicitly from the strings `'true'`/`'false'`.
    - `grnId` is dropped (no index).
  - **Orders:** `status`, `source`, `backordered`, `from`, `to` (`created_at`).
  - **Over-receipts:** `warehouseId`, `from`, `to`.
  - **Goods-receipts:** `poless`, `from`, `to`.
  - **Batch-alerts:** `from`, `to`.
  - **E-way bills:** `warehouseId`, `from`, `to`, `source`.
  - **Invoices:** `warehouseId`, `from`, `to`.
  - **New routes:** picklist-lines (`status`, `from`, `to`), pack failures, refusals.

  Refusals are 400 `validation-failed` with named details: an unknown type, a bad ISO instant, `from ≥ to`, a non-boolean flag.
- [x] `wms-be/test` -- every matrix row, plus:
  - **reconciliation:** each `reconciles: true` figure equals its drill paged to exhaustion;
  - **the architecture guard:** reporting writes no table, only `src/api` imports it, and both fact tables are in outbound's ownership list;
  - **an 0058 migration block:** the guard, RLS, the unique constraint and the `app_metadata` row;
  - **a load check:** `scripts/loadtest-overview.ts` seeds about 25k ledger events in 7 days for one warehouse through the inventory facade in batches, plus matching `picks`, GRN and putaway rows, then reports the overview's p95. It is reported, not a CI gate.
- [x] `wms-fe`:
  - **Overview:** a client `OverviewDashboard` with `useReportingOverview(warehouseId)` (`ResourceState`, keyed on the warehouse; reloads only on switch or Refresh). The warehouse is the active one, else the first. When there is no warehouse, an empty state links to Settings.
  - **`KpiTile`:**
    - gains `href` (`next/link`), `secondary`, `unavailable` (shown as text, not only colour), and an accessible name of label plus value;
    - live figures show no 7-day line;
    - "counting since" appears on the SM-3/SM-4 tiles, and a partial-window note when `countingSince > d7From`.
  - **Banner:** `FeedbackBanner` gains a `warning` tone with an action slot (Refresh), `role="status"`. "As of HH:MM" is always shown, and stale also triggers when `asOf` is more than 5 minutes old.
  - **API health** moves to a small status line.
  - **Links:** tiles link to the screen for their drill. An `apiPath` → web route map lives in one file; the full drill query is carried in the `href` now, so 9-1b only adds URL-reading.
  - Tests for each.
- [x] Meta docs and status:
  - a new `modules/reporting.md`: tile definitions, drills, the runner, decision 6 as a named exception, and the 21-8 hook;
  - `IMPLEMENTATION-GUIDE.md`: the read-only exception;
  - `API-SURFACE.md`, the module notes, both contracts, and the FE system design (the Overview is no longer a placeholder);
  - `PENDING.md`:
    - close :138 (SM-8) and :191 (sync health);
    - record the index `CONCURRENTLY` runbook;
    - record that SM-8 reads 0% until a live gateway;
  - `sprint-status.yaml`: add `9-1b-dashboard-click-through: backlog`.

**Acceptance Criteria:**
- Given a warehouse with receipts (one blind), putaways, picks (one zero-unit short and one serial), a failed pack, a channel order refused under reject and one accepted backordered, an open expiry alert, and dispatches, when the overview is read, then every `reconciles: true` figure equals its drill paged to exhaustion, and SM-3/SM-4/SM-8 match the PRD formulas computed independently in the test.
- Given about 25k ledger events in 7 days in one warehouse, when the overview is read repeatedly, then the reported p95 is < 2 s.
- Given the full BE and FE suites, when run, then they pass.

## Implementation Notes

- Baselines: wms-be `049ace4506155fd31675bf65fbff7d2637a4311f` (frontmatter `baseline_commit`); wms-fe `1344c167fb77a560fe24a825d962245636c21582`. Work happens on `feat/9-1-operational-dashboard` in both repos. Leave changes uncommitted; do not commit, push, or open PRs. In wms-be run jest via `bun run test -- <file>` (bare `bun test` hangs) and never two jest invocations concurrently. Local dev needs `OUTBOX_RELAY_POLL_MS` set for dispatch-driven flows.
- Shipped: WMS-BE #75 (`0523148`), WMS-FE #60 (`1776c39`); design PR WMS-Meta #92.

## Spec Change Log

## Review Triage Log

*Design review, 2026-10-06: two code-verified reviewers (data/backend; API/FE/UX). 33 findings merged into 24. Two went to the human as decisions 5 and 6; the rest are folded in.*

| # | Severity | Finding | Disposition |
|---|---|---|---|
| 1 | critical | Manual order create never refuses for stock (it backorders); the manual refusal site doesn't exist | Decision 1 reworded; the one write site is the ingest reject arm |
| 2 | critical | Webhook redeliveries mint new keys, so refusals would duplicate | Unique on `(integration_id, external_event_id)`; matrix row |
| 3 | critical | Writing the pack failure in a second transaction while the first holds locks risks pool deadlock | Typed error; written after rollback; best-effort |
| 4 | critical | Three KPIs diverged from the PRD (SM-3, SM-4, SM-8) | Decision 5: follow the PRD |
| 5 | high | No list returns a total | Reconciliation = paging the drill to exhaustion; no totals (Never) |
| 6 | high | Most drills couldn't express their tile's filter | Per-figure drills; all missing filters added; `reconciles` flag |
| 7 | high | Ledger event counts ≠ lines/orders (per arm, per serial, per line) | `picks` for pick lines; distinct `orderLineId`/`orderId` |
| 8 | high | Zero-unit short picks write no event | Short picks from `picklist_lines` |
| 9 | high | The index can't be `CONCURRENTLY` in drizzle; a plain build locks | Plain build accepted pre-launch, stated; runbook in PENDING |
| 10 | high | `occurred_at` is device time, so "today" revises on replay | Server-stamped columns; drills bounded by `asOf` |
| 11 | high | Module boundary contradictory | Decision 6: named read-only exception plus guard |
| 12 | high | 10 parallel transactions vs a pool of 10; no deadline | Concurrency 3; local `statement_timeout`; 1.8 s deadline; only 57014 is silent |
| 13 | medium | Stale too narrow; the banner has no warning tone or action | `asOf` always shown; age-based stale; warning tone with Refresh |
| 14 | medium | `countingSince` not computable | `app_metadata` stamp from 0058; partial-window note |
| 15 | medium | Fact-write failure semantics | Best-effort; the original refusal unchanged; matrix row |
| 16 | medium | Dock-to-stock definitions loose (device clocks, partial lines) | Server columns; negatives excluded; awaiting = remaining > 0 via putaway tasks |
| 17 | medium | Backorder timestamp and kit double-count unstated | Counted per order; `created_at` named |
| 18 | medium | SM-8 joins/statuses wrong (`queued`, no `warehouse_id`, `source`, voided) | Joined via invoice; gateway only; dismissed/voided excluded |
| 19 | medium | Sync health reads degraded on idle; unset ingest shown as ok | Connected only; lag as-is; unset = error with reason; 24 h failures |
| 20 | medium | DTO and drill shape undefined; nullable-enum rule | Flat per-tile DTOs; drill `{apiPath, query, reconciles}` |
| 21 | medium | Filter validation (booleans, repeatable `type`, error arms); `grnId` unindexed | Explicit transforms and 400 arms; `grnId` dropped |
| 22 | medium | Blind GRNs (FR-27) missing | Blind-GRN figure added |
| 23 | medium | Fact table ownership, RLS and the 404-before-tiles order implicit | Outbound owns; RLS hand-appended; warehouse check first |
| 24 | low | The load check's harness and seeding were unspecified; FE states (no warehouse, health tile, a11y); 9-1b not in sprint-status | `loadtest-overview.ts`, reported; FE states listed; 9-1b registered |

*Code review, 2026-10-06: three layers (blind, edge-case, verification-gap); 38 findings merged into 24, each verified against the code.*

| # | Verdict | Finding | Evidence | Route |
|---|---|---|---|---|
| C1 | high | Sync health uses its own rules: it ignores `connectionHealth()` (half-open breaker, `lastError`, SLO lag, never synced), drops disconnected connections, and counts successful cancellations (`released`), `ignored` and policy refusals (`rejected`) as failures. A healthy channel reads Degraded, and a "prevented" oversell degrades its channel. | `kpis.ts:744-796`; `channels.view.ts:164`; `channels.ingest.command.ts` (`recordIngestOutcome`: refusals are decisions, not failures) | patch: reuse `connectionHealth`; disconnected = error; failures = only transport and processing failures; a test classifying every `INTEGRATION_CALL_STATUSES` member |
| C2 | high | The pool is unprotected: concurrency 3 is per request, the deadline doesn't stop stragglers, and multi-statement tiles can hold a connection about 6 s, so a few concurrent viewers take all 10 connections | `reporting.facade.ts:26-178`; `db.ts:12` | patch: a process-wide semaphore (3 tile transactions in total); each statement's timeout = min(1500 ms, remaining deadline) |
| C3 | high | The age-based stale banner never fires; nothing re-renders after load | `overview-dashboard.tsx:137` | patch: a timer re-renders at `asOf` + 5 min |
| C4 | medium | Retries of one failed pack (same key, or a repeated sync apply) add rows, inflating SM-3 | `pack.command.ts` `recordPackFailure` | patch: dedupe on the idempotency key or sync op id (0058 isn't deployed) |
| C5 | medium | A refused channel event later redelivered and accepted still counts as "prevented" | `recordBackorderRefusal` | patch: exclude refusals whose `(integration, external_event_id)` now has an order, in the tile and the drill |
| C6 | medium | Timeline `orderId` in uppercase silently matches nothing; a non-boolean `shortPick` in any reference doc fails the read with a 500 | `inventory.facade.ts` filters | patch: compare as uuid; text comparison, no cast |
| C7 | medium | The picklist-lines list pages on the mutable `updated_at`, so rows skip or repeat | `fact-lists.ts:234` | patch: keyset on `(created_at, id)`, window on `updated_at` |
| C8 | medium | Test gaps: windows never discriminated (every row seeded "today"); no full-precision-cursor tie group; `shortPick=true` never returns a row; e-way `warehouseId` scoping untested; the inverted window tested on 2 of 10 routes; invoices 404 untested; FE failed-read and warehouse-switch states untested | `reporting.spec.ts`; `overview-dashboard.test.tsx` | patch: tests |
| C9 | medium | The load check seeds only ledger, picks, GRN and putaway; the other tiles' tables are empty at volume | `scripts/loadtest-overview.ts` | patch: seed orders, picklist lines, alerts and invoices/e-way at volume; report per-tile timings |
| C10 | low | Tiles don't say the big number is "Today (IST)"; "as of" is in local time | FE tile | patch: label |
| C11 | low | The window DTO omits `lastHourFrom`/`last24hFrom`, which drills use | `ReportingWindowDto` | patch |
| C12 | low | The controller casts `as unknown as` and re-implements the tenant/uuid guards inline | `reporting.controller.ts` | patch: typed mapping; shared helpers |
| C13 | low | Links to screens that ignore the drill query (until 9-1b); three drills have no screen | `drill-routes.ts` | patch: drills with no screen get no link; the link text says "Open <screen>" |
| C14 | low | Duplicate `IsBoolean` imports, import order, `void DAY_MS`, unchecked statuses in the load script | as cited | patch |
| C15 | low | "Counting since" is the migration time, not the first write | 0058 | patch (doc): migrations and code ship in one release; noted in `reporting.md` |
| C16 | medium | Ledger drill paging isn't served by the new index (sort on `created_at`); `orderId` has no expression index under tenant | timeline query | defer: PENDING (drill-page performance; tile reads unaffected) |
| C17 | low | The SM-3 numerator mixes short lines and attempts with a dispatched-lines denominator | `kpis.ts` | rejected: it is the PRD formula (decision 5); documented in `reporting.md` |
| C18 | low | `gatewayGenerated` reconciles only while no invoice is voided | `kpis.ts` | rejected: void is not built (PENDING tracks it) |
| C19 | low | A sub-millisecond `from`/`to` compare | `instant-range.ts:88` | rejected: clients send ms instants; theoretical |
| C20 | low | 0058's `IF NOT EXISTS` would accept an INVALID index left by a failed `CONCURRENTLY` | 0058 | rejected: the runbook drops the invalid index first (noted in PENDING) |

## Design Notes

- **Live queries, not rollups.** Seven days of one warehouse's facts with the new index stays cheap. Rollups would add a second derived store that must reconcile and rebuild (AD-1); they wait until windows longer than 7 days are wanted.
- **Why the facts are tables, not ledger events.** A refused command moved no stock. The ledger is stock movements under a hash chain, so non-movements would distort replay and reconciliation.
- **Relational sources count as ledger projections** where the row is written in the same transaction as the ledger event (picks, GRN, putaway). Each definition names its source.
- **SM-8 reads 0% today.** This is deliberate (decision 5): it shows the real gap until a live NIC or GSP adapter exists. The invoice share beside it shows the manual-pricing gap.

## Verification

**Commands:**
- `bun run test` (wms-be) -- green, plus `typecheck`, `lint`, `build`; `db:generate` reports "No schema changes"; `bun scripts/loadtest-overview.ts` reports p95.
- `bun run lint && bun run test && bun run typecheck && bun run build && bun run check:capability-mirror` (wms-fe) -- green.
