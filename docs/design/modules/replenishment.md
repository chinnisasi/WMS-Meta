# Replenishment module

> The stock-intelligence spine (story 6.1, FR-22): a scheduled sweep that notices ATP falling below a reorder point, opens an alert, and drafts a suggested PO — a human decides; the system never auto-submits. Story 6.2 (FR-23) extends the SAME tick with the expiry/aging scan: batch-tracked stock inside a tenant-configured lead/threshold opens batch alerts — still evidence only; the system never moves, blocks, or disposes stock on their account.

Paths are relative to `workspace/core/backend/wms-be`. Read [`../IMPLEMENTATION-GUIDE.md`](../IMPLEMENTATION-GUIDE.md) first — the command skeleton is followed closely here and is not repeated.

**The module exists for one rule: the ONLY writer of a real purchase order is the human-triggered `submitSuggestedPo` command.** The worker drafts; it never mints a PO. Every PO mint re-runs `createPurchaseOrderInTx`, which re-asserts `po.manage` on the same transaction — replenishment can never create a PO its caller wasn't entitled to create.

## Owns

| Table | Holds | Key invariants |
|---|---|---|
| `reorder_policies` (`src/shared/db/schema.ts:3230`) | Per-warehouse reorder-point overrides: `warehouse_id`, `sku_id`, `reorder_point_milli`, `reorder_qty_milli` | One row per (tenant, warehouse, sku); positive milli CHECKs migration-only |
| `reorder_breaches` (`src/shared/db/schema.ts:3264`) | Breach alerts: frozen `point_milli` + `atp_milli` at detection, `status open\|recovered\|actioned\|dismissed`, `resolved_at`/`resolved_by` | At most ONE open breach per (tenant, warehouse, sku) — partial unique |
| `suggested_pos` (`src/shared/db/schema.ts:3308`) | The drafts: `breach_id`, nullable `vendor_id`, `quantity_milli`, `status draft\|submitted\|dismissed`, `submitted_po_id` | At most ONE `draft` per (tenant, warehouse, sku) — partial unique |
| `expiry_alert_policies` (`drizzle/0049`, story 6.2) | The tenant-wide expiry/aging config: `expiry_lead_days`, `aging_threshold_days`, whole-day ints ≥ 0 | UNIQUE per (tenant_id) — the ABSENT ROW IS THE DISABLE MECHANISM: no default lead/threshold days hide in code, a tenant with no row scans to no-op, and the GET answers `404` |
| `batch_alerts` (`drizzle/0049`, story 6.2) | Expiry/aging alerts on batch scopes: `kind expiry_upcoming\|aged`, `status open\|resolved\|dismissed`, `age_days` (frozen on `aged` rows, null on expiry rows), `resolved_at`/`resolved_by` | At most ONE OPEN alert per (tenant, warehouse, sku, batch, kind) — partial unique; the `batch_alerts_open_...` unique covers open rows ONLY, which is why a DISMISSED alert re-raises on the next breach-conditioned scan (see the scan section) |

CHECKs and RLS live only in the hand-appended migrations (`drizzle/0048_replenishment.sql`, `drizzle/0049_expiry_alerts.sql` — the drizzle-blindness rule; schema.ts declares the columns, the migration owns the policies):

- `reorder_policies_tenant_warehouse_sku_unique` + `reorder_policies_{point,qty}_milli_positive_check` — an override is a valid milli quantity or nothing.
- `reorder_breaches_open_tenant_warehouse_sku_unique` **WHERE status = 'open'** — one active alert per scope; the open path reads-then-inerts inside the transition tx but this unique is the deterministic 23505 backstop against two concurrent sweeps of one scope both opening (the loser's 23505 is swallowed as another sweep's already-open verdict).
- `reorder_breaches_status_check` — the frozen four-vocabulary lifecycle: `open → recovered` (worker; ATP ≥ point) / `open → actioned` (its PO submitted) / `open → dismissed` (human). Recovery stamps `resolved_at` with `resolved_by` **null** (nobody acted); dismissal/action stamp both (the actor was the submitter/dismissor — 6-1's resolved-by convention).
- `suggested_pos_draft_tenant_warehouse_sku_unique` **WHERE status = 'draft'** — one standing draft per scope; the re-breach repoint updates it in place (never duplicates).
- `suggested_pos_status_check` — `draft|submitted|dismissed`; `submitted_po_id` nullable, set exactly once at submit.
- `*_tenant_isolation` ×5 — the standard fail-closed RLS guard; breach rows, batch alerts and the expiry config are tenant secrets like everything else (the `client-isolation` pin counts 61 policies).
- Keyset indexes on every table (tenant-first `(tenant_id, …, created_at, id)`); 0049 also adds `batches_tenant_expiry_idx` on `batches (tenant_id, expiry_date)` — the scan's join input (the index lives on the catalog-owned table; the scan reaches it through the catalog facade only, AD-6).

The module also writes `audit_events` and `idempotency_keys` (tenancy-owned, shared), and appends outbox events through the seam.

**The two data sources for an effective reorder point** (the module's central design):

1. `skus.reorder_point` / `reorder_qty` — tenant-wide defaults, existing columns (`schema.ts:464`), editable in the SKU table; the fallback.
2. `reorder_policies` rows — the per-warehouse exception; wins row-by-row.

Effective point = policy row ?? SKU column. **SKU column 0 disables breach evaluation for that (w, sku)** unless a policy row overrides. A SKU whose effective point is 0 is never a candidate, whatever its qty says.

---

## The sweep — three deliberate phases

`ReplenishmentSweep.sweepScope(tenantId, warehouseId)` (`replenishment.sweep.ts:84`) evaluates one scope; a throw from any phase skips the whole scope and retries next tick (the worker logs and moves on).

```mermaid
sequenceDiagram
    participant W as ReplenishmentSchedulerWorker
    participant S as ReplenishmentSweep
    participant DB as tenant tx
    participant INV as InventoryFacade.atp
    Note over S: Phase 1 — candidates (tenant tx #1)
    S->>DB: policy rows (w) + catalog.getSkuReorderDefaultsInTx (ALL tenant SKUs)
    S->>S: effective point = override ?? SKU default; point 0 → drop
    S->>S: sort by skuId (the phase-3 lock order)
    Note over S: Phase 2 — ATP reads on NO transaction
    loop each candidate
        S->>INV: atp(tenant, warehouse, sku)
        INV-->>S: snapshot.atp (or THROWS — fail-closed 503)
    end
    Note over S: Phase 3 — transitions (tenant tx #2, FRESH point re-reads)
    S->>DB: re-read candidates (a policy edited since phase 1 decides THIS sweep)
    loop each fresh candidate (in the skuId order)
        S->>DB: loadOpenBreach … FOR UPDATE
        alt ATP < point, no open breach → OPEN
            S->>DB: insert breach (freeze point + ATP) + mint/repoint draft + outbox + audit
        else ATP < point, breach open → no-op
        else ATP ≥ point, breach open → RECOVER
            S->>DB: status recovered (no event, by design)
        end
    end
```

**Why the phases are shaped this way:**

- **Phase 1 never reads stock** — candidates come from policy + catalog tables only. Composing with the catalog defaults on ONE transaction (`getSkuReorderDefaultsInTx`) keeps catalog exclusive to its module.
- **Phase 2 is strictly outside any transaction** — `InventoryFacade.atp` (`inventory.facade.ts:1210`, backed by `reservation.service.ts:635`) is the ONLY allowed ATP read (the module never touches stock tables — the architecture spine, pinned by the architecture test). It is fallible (throws `reservationStoreUnavailable` when the Valkey-side ready marker is absent): a failing read propagates, the scope is skipped and retried — **a store outage is never read as ATP 0**, which would mint false breaches wholesale. On an open path the ATP snapshot's freshness is accepted as of phase 2; phase 3 handles races below.
- **Phase 3 re-reads points FRESH inside the transition tx** — a policy edited between phase 1 and phase 3 decides THIS sweep, not a stale snapshot. A candidate that appeared only after phase 2 carries no ATP reading (`atpBySku.get(skuId) === undefined`) and is skipped to the next tick — never read as ATP 0.
- **The candidates' skuId sort is the phase-3 lock order** — two concurrent sweeps of one scope take row locks in the same order and never interleave into deadlock.

**Breach OPEN** (`replenishment.sweep.ts:231`): inserts the breach with frozen `point_milli`/`atp_milli`, mints the draft, appends `replenishment.breach_detected` (payload `{breachId, warehouseId, skuId, atpMilli, pointMilli, breachAt, notifyRole: 'ops_manager'}` — Epic 9's panel contract), and writes the audit row under `REPLENISHMENT_SCHEDULER_ACTOR_ID` (the module-reserved actor constant — `audit_events.actor_user_id` is NOT NULL and no system-actor user row exists; the constant is deliberately never sign-in-able). **The breach instant is the row's `created_at`** — there is no separate `breach_at` column; the audit trail and event payload name it `breachAt`.

**Draft quantity**: effective `reorder_qty_milli` when > 0, else `recoveryGapMilli(point, atp)` — the shortfall converted to whole base units rounded UP so every unit vocabulary passes the PO command's whole-unit precision guard on submit. A `qty_milli > 0` value that fails precision (fractional base units) surfaces at submit as the PO command's verbatim precision refusal — the draft stays a draft.

**Re-breach repoint semantics:** a draft is minted exactly when a breach OPENS (one artifact per breach event, no drafting on later sweeps). If a NEW breach opens while an old draft for the same scope is still `draft`, the standing draft is **REPOINTED in place** — the fresh breach's id, the vendor, and the quantity REPLACE whatever a planner had left on it. A draft is always a system-fresh suggestion; stale planner edits are never preserved.

**Breach RECOVER** (`replenishment.sweep.ts:336`): ATP ≥ point → status `recovered`, `resolved_by` stays null, its draft KEPT as a draft, and **deliberately NO outbox event** — a recovery is a surface-visible state change only (the audit-adjacent, not-delivery rule). The kept draft lets a planner decide the recovered breach still wants ordering; dismissal is their other arm.

---

## The expiry scan — the tick's SECOND evaluation (story 6.2)

`ExpiryScan.scanScope(tenantId, warehouseId)` (`replenishment.expiry.scan.ts`) runs BESIDE the breach sweep on the same one-scheduler tick — not a second worker. It reads no stock numbers of its own: on-hand comes from the `batch_on_hand` projection through the inventory facade, batch identity/expiry/intake-instant from the catalog facade — never a cross-module table reach.

```mermaid
sequenceDiagram
    participant W as ReplenishmentSchedulerWorker
    participant S as ExpiryScan
    participant DB as tenant tx
    participant INV as InventoryFacade
    participant CAT as CatalogFacade
    Note over S: Phase 1 — config + enumeration (tenant tx)
    S->>DB: expiry_alert_policies row (tenant)
    alt config ABSENT
        Note over S: no-op — the absent row IS the disable switch
    else configured
        S->>INV: batchScopeSumsInTx (positive scopes)
    end
    Note over S: Phase 3 — transitions (tenant tx, EVERYTHING re-read)
    S->>DB: re-read config (fresh decides THIS scan)
    S->>INV: batchScopeSumsInTx (fresh — a scope consumed since phase 1 resolves, never rides stale enumeration)
    S->>CAT: getBatchIntakesForSkusInTx (identity + expiry + created_at)
    S->>DB: open batch alerts FOR UPDATE, ordered (skuId, batchId, kind) — the lock order
    loop each fresh scope, sorted (skuId, batchId)
        alt batch blocked (catalog status)
            Note over S: NO NEW alert; an open alert stands
        else expiry ≤ now + lead_days (inclusive, already-expired qualifies) → open expiry_upcoming
        else age ≥ aging_threshold_days → open aged (age_days FROZEN)
        end
    end
    loop each open alert whose scope carries no positive on-hand
        S->>DB: status resolved (resolved_by null, NO event)
    end
```

**The arithmetic, frozen:**

- **Expiry boundary is inclusive:** `Date.parse(batches.expiryDate) <= nowMs + expiryLeadDays * 86_400_000` — the lead-day edge itself alerts, and an already-expired date still qualifies (expiry only matures; the alert can't be missed by arriving late).
- **Aging is intake-anchored:** `age_days = floor((now − batches.created_at) / 86_400_000)` — the receipt instant, no ledger join. `age_days` is FROZEN at detection on the `aged` row (age is a moving target; the alert records what it saw — the 6-1 frozen `point_milli`/`atp_milli` reasoning). The expiry row freezes nothing: the catalog froze the dates at intake.
- **A batch can hit BOTH kinds** — two rows, one (w, sku, batch, kind) partial-unique scope each; the queue's kind filter splits them.

**The lifecycle, lifted from the breach pattern with one sharper edge:**

- **OPEN** (raiseAlert): the row (`ON CONFLICT DO NOTHING` absorbs a racing double-open as the already-open verdict — no aborted tx, no duplicate event), the `replenishment.batch_alert_raised` outbox event + audit row under `REPLENISHMENT_SCHEDULER_ACTOR_ID`.
- **AUTO-RESOLVE**: every open alert whose scope reads no positive on-hand → `resolved`, `resolved_by` null (nobody acted), deliberately NO event (the breach-recovery rule). A batch that merely stopped TRIGGERING (expiry only matures, age only grows) keeps its alert — it stands until consumption or dismissal.
- **DISMISSAL** (the `dismissBatchAlert` command): `open → dismissed`, the dismisser stamped, no stock-side effect. **Dismissal is NOT suppression** — the partial unique covers open rows only, so while the batch still trips the tenant's thresholds with stock on hand the scan raises a FRESH alert on a later tick. Deliberate (it exactly matches 6-1's behaviour where a dismissed breach re-opens past a still-below-ATP sweep), tested in the real-facade tick arm, and SAID in the FE's dismissal sentence.
- **A blocked batch raises NO NEW alert**; an existing open alert stands while on-hand > 0 and resolves through the normal on-hand-0 rule.

**The phase discipline is kept** (enumerate in a tx; decide; transition alerts in one tx re-reading fresh facts) even though 6.2 has no Valkey/ATP-style fallible outside-tx phase — projection and catalog reads only. Any throw skips the whole scope (the worker logs and retries next tick): a partial scan never half-resolves alerts.

---

## The worker — scope enumeration and the cap

`ReplenishmentSchedulerWorker` (`jobs.module.ts:428`) is the `CountSchedulerWorker` shell: env `REPLENISHMENT_SCHEDULER_POLL_MS` (unset/0 = OFF; boot-loud on garbage), single-flight (`this.running`), auth-db enumeration with per-scope catch/log/skip (a poison scope never starves the tick).

**Scope enumeration is three queries, not one guess** (`jobs.module.ts`):

1. distinct `(tenant, warehouse)` from `reorder_policies` — warehouses with configured overrides;
2. every warehouse of every tenant carrying at least one SKU default > 0 (point OR qty — a point-0 SKU with a qty is not an alert source, and a scope whose SKUs all read effective point 0 short-circuits in the sweep anyway);
3. (story 6.2) distinct `(tenant, warehouse)` from `batch_on_hand.quantity > 0` joined batch-tracked SKUs **and predicated on the tenant holding an `expiry_alert_policies` row** (`and exists (…)` — a config-less tenant's scan no-ops anyway, so enumerating it is pure waste), UNIONed with scopes of OPEN batch alerts with NO config check (the policy table has no DELETE, so an open alert implies the config row existed) — so a warehouse whose alerts are standing but whose last scope was consumed still gets enumerated to resolve them.

The union is a deduped Map, deterministic: **policy scopes** (a configured override is the sharpest alert source), **then defaults**, **then batch scopes** — and the deduped Map is also the scan's source: each carried scope calls `sweepScope` AND `scanScope` (each in its own try/catch — a poisoned sweep does not skip the scan, and a poisoned scan does not skip the sweep; pinned by a plumbing test).

**The per-tick cap (200, `MAX_REPLENISHMENT_SCOPES_PER_TICK`) is a ROTATING window** — this is a review finding's fix, worth its paragraph. A head-only slice of a deterministically-ordered enumeration would carry the SAME head every tick and starve everything past the cap forever. Each truncating tick instead carries a wrap-around window starting at an in-memory `tickOffset` that advances one scope per truncated tick; every scope is swept within ⌈length / cap⌉ + ticks, and the truncation warn quantifies the carry ("the rotating window advances each tick until every scope is swept"). Scope counts larger than one tick can carry remain LOUDLY bounded — FR-22's ≤ 5-minute detection bound holds when `REPLENISHMENT_SCHEDULER_POLL_MS ≤ 300000` and the cycle fits the cap.

```mermaid
sequenceDiagram
    participant ENV as setInterval(poll)
    participant W as SchedulerWorker.tick
    participant DB as auth db
    participant S as ReplenishmentSweep
    participant X as ExpiryScan
    ENV->>W: tick() (single-flight shed)
    W->>DB: policy ∪ defaulted-SKU ∪ batch scopes (3 SQL, deterministic order)
    W->>W: dedupe; ≤200-carried (rotating window if truncated, warn)
    loop each carried scope — catch/log/skip per scope, per evaluation
        W->>S: sweepScope(tenant, warehouse)
        W->>X: scanScope(tenant, warehouse)
    end
```

---

## Commands

All follow the frozen skeleton (capability at command-service entry → fingerprint → replay lookup → guards → tx → audit/outbox → idempotency LAST). Writes gate `replenishment.manage` (Owner + Ops Manager — the planning set, the 32nd capability); the list reads are deliberately ungated (reads are never gated). The holder-set invariant — every `replenishment.manage` holder also holds `po.manage` — is pinned in `test/users.spec.ts`, because the submit's inner mint depends on it.

| Command (`replenishment.command.ts`) | Does | Guards, in order |
|---|---|---|
| `upsertReorderPolicy` :376 | Last-write-wins upsert of a per-warehouse override (variance-policy precedent) | `replenishment.manage`; warehouse+SKU in tenant (404); point/qty strictly positive integers (400 `validation-failed` naming the field) |
| `deleteReorderPolicy` :490 | Removes the override — the SKU-column default resumes on the next sweep | capability; id exists in tenant (404) |
| `dismissBreach` :556 | Open → `dismissed`, stamps `resolved_by/at`; its draft stays a draft (dismissal is about the breach, not the draft) | capability; breach exists (404); **status open** (`409 breach-not-open` naming the status) |
| `submitSuggestedPo` :630 | Draft → `submitted` + `submitted_po_id`, mints the REAL PO via `createPurchaseOrderInTx`, breach → `actioned` — one held transaction, all-or-nothing | capability; draft exists (404); **status draft** (`409 suggested-po-submitted`); vendor known or resolvable on edits (null vendor + no edit → `400 suggested-po-vendor-required`); quantityMilli whole-unit precision (the PO command's verbatim refusal — draft untouched); inner PO guards re-run verbatim (vendor gone, SKU gone → refusal verbatim, draft stays draft); code conflict → `409 conflict` |
| `upsertExpiryPolicy` (6.2) | Last-write-wins upsert of the tenant-wide expiry/aging config — the per-tenant UNIQUE swallows-violation upsert (the count-variance-policy precedent) | capability; `expiryLeadDays`/`agingThresholdDays` whole-day ints ≥ 0 (400 naming the field). There is NO per-field disable and no DELETE — the ABSENT ROW is the disable mechanism |
| `dismissBatchAlert` (6.2) | Open → `dismissed`, stamps `resolved_by/at`; no stock-side effect — the alert is evidence | capability; alert exists (404, malformed id 404 before any query); **status open** (`409 batch-alert-not-open` naming the current status) |

The **submit arm's transaction shape** is the module's load-bearing rule: ONE held tenant transaction (`withTenantTransaction`), inside which the inbound facade's in-tx PO mint runs on the SAME pooled connection. A nested second transaction while one is held is the documented pool-deadlock shape (`putaway.facade.ts:221-224`, pool `max: 10`) — **never** nest. The mint re-asserts `po.manage` inside (`createPurchaseOrderInTx`, the `findDefaultVendorInTx` house shape), so a hypothetical `replenishment.manage`-without-`po.manage` holder is refused where it would matter; the deterministic inner idempotency key `replenishment-submit-po-<draftId>` stays (harmless, keeps the mint reproducible). Submit stamps `resolvedBy: command.actorUserId` on the actioned breach — the FE's "actioned by" wording reads it.

The breach-open path carries no command — it is the sweep's (system actor, no idempotency key needed, the transition tx re-reads and the partial unique absorbs a racing double-open).

---

## Public seam

`ReplenishmentModule` exports `ReplenishmentFacade` (`replenishment.facade.ts:123`); the architecture test pins "siblings reach it only through the facade" and "no writes outside the module". Reads are plain facade methods; writes delegate to the command service.

| Method | Does |
|---|---|
| `upsertReorderPolicy` / `deleteReorderPolicy` / `dismissBreach` / `submitSuggestedPo` :135-163 | Delegate to `ReplenishmentCommand` (returns the entry snapshots) |
| `listReorderPolicies(tenantId, query)` :181 | Keyset page, `warehouseId`/`skuId` filters (foreign warehouse → 404 via `assertWarehouseFilter`) |
| `listBreaches(tenantId, query)` :217 | Keyset page, `status`/`warehouseId` filters |
| `listSuggestedPos(tenantId, query)` :252 | Keyset page, `status`/`warehouseId` filters |
| `getExpiryPolicy(tenantId)` (6.2) | The tenant's config snapshot — **`null` when absent** (the disable mechanism read back); the controller renders the null as `404 not-found` |
| `upsertExpiryPolicy` / `dismissBatchAlert` (6.2) | Delegate to `ReplenishmentCommand` (the config snapshot, the dismissal snapshot) |
| `listBatchAlerts(tenantId, query)` (6.2) | Keyset page on the batch-alert scope, `kind`/`status`/`warehouseId` filters; each row's `onHandMilli` stitched LIVE via `batchScopeSumsForScopesInTx` (a batch consumed an hour ago reads 0 here, not a stored figure) and its `batchCode` stitched via the catalog facade's in-tx intake read (AD-6 — identity read in catalog, never a direct table reach); both stitches are OPTIONAL on the wire (`required: false`) — the DISMISSAL snapshot omits them, and the FE card renders the human code, never a truncated id |
| `sweepScope(tenantId, warehouseId)` | The worker's per-scope breach entry (see the sweep section) |
| `scanScope(tenantId, warehouseId)` | The worker's per-scope expiry/aging entry (see the scan section) |

Keyset cursors are the house `(createdAt, id)` opaque envelope (`decodeCursorSafe` → `400 invalid-cursor`); page rows compose without repeats — proven by the cursor-chain exhaustion walks in `test/replenishment.spec.ts`.

**Cross-module reads the module takes** (all in-tx via facades, never direct table reaches):

| Facade | Read | Why |
|---|---|---|
| `InventoryFacade.atp` | The ONLY ATP read, outside any tx | The architecture spine; fallible 503 is the sweep's skip signal |
| `CatalogFacade.getSkuReorderDefaultsInTx` | ALL tenant SKUs `{id, code, name, uom, reorderPoint, reorderQty}` | The tenant-wide defaults + the identity source for candidates |
| `InventoryFacade.batchScopeSumsInTx` / `...ForScopesInTx` (6.2) | Positive `(w, sku, batch)` sums from the `batch_on_hand` projection (milli strings summed, `Number()` at the boundary) | On-hand is the projection's; the scan maintains no stock numbers of its own |
| `CatalogFacade.getBatchIntakesForSkusInTx` (6.2) | Batch identity `{id, code, expiryDate, status, createdAt}` on the caller's tx | Catalog owns `batches` (AD-6) — the scan never joins batches from an inventory-side table; `status` is what says a batch is blocked |
| `InboundFacade.createPurchaseOrderInTx` | The PO mint on the submit arm's held tx | The inbound module remains the only PO writer |
| `InboundFacade.findDefaultVendorInTx` | Deterministic min `(created_at, id)` default vendor | ≥ 2 defaults possible (no single-default unique by design); null when none — a vendor-less draft requires the submit edit |

`outbound`/`movements`/`putaway` never see this module; the ledger is untouched (replenishment invents NO quantities — it freezes an ATP snapshot and lets PO receipts do the rest).

HTTP lives in the api shell (`src/api/replenishment.controller.ts`) — 11 routes (6.2 adds `PUT`/`GET .../expiry-policies`, `GET .../batch-alerts`, `POST .../batch-alerts/{id}/dismiss`), thin DTO mapping, `assertOwnTenant` per method. Note: **the policy delete is the repo's FIRST `@Delete` route** (PUT/POST destructive verbs elsewhere) — idempotent and snapshot-returning (the deleted row), so it lives within the same `Idempotency-Key` contract the POST-destructives carry.

---

## Events

Deliberately exactly three (and two deliberate absences):

| Event | When | Payload | Consumers |
|---|---|---|---|
| `replenishment.breach_detected` | Breach OPEN | `{breachId, warehouseId, skuId, atpMilli, pointMilli, breachAt, notifyRole: 'ops_manager'}` | **None yet** — the relay only logs; Epic 9's panel reads `notifyRole` |
| `replenishment.suggested_po_submitted` | Submit arm | `{suggestedPoId, poId, poCode, warehouseId, vendorId, quantityMilli}` | None yet |
| `replenishment.batch_alert_raised` | Batch-alert OPEN (6.2) | `{alertId, kind, warehouseId, skuId, batchId, batchCode, notifyRole: 'ops_manager'}` PLUS exactly what THAT kind detected: `expiryDate` on the expiry arm, the frozen `ageDays` on the aged arm | None yet |
| — | BATCH-ALERT AUTO-RESOLVE (6.2) | **no event, by design** — nobody acted (resolved_by null), surface-visible state change only (the breach-recovery rule) | — |
| — | BATCH-ALERT DISMISSAL (6.2) | **no event** — the dismissal command writes audit only, the same as the breach dismissal | — |

Events are audit-adjacent, not delivery. The `notifyRole` hint is the `count.variance.threshold_exceeded` precedent.

---

## Gotchas (the ones that caused real findings)

- **Head-only scope slices starve.** The first shipped cap sliced the same deterministic head every tick — scopes past 200 were NEVER swept and the warn lied ("swept on the next tick"). The rotating window fixed it; any new enumerated-cap worker must rotate or order-shuffle, not slice-head.
- **A nested transaction while holding one is the pool deadlock.** The submit arm mints via `createPurchaseOrderInTx` on the SAME connection. The false precedent that almost shipped: the sync-report apply arm was cited as an inner-transaction precedent — withdrawn; sync-report calls no facade and writes in its caller's tx.
- **The response carrier must be FLAT.** The PO mint's natural return is the wrapped `{purchaseOrder: {…}}`; submit's HTTP response wraps the FLAT snapshot — `body.purchaseOrder` IS the PO. (An earlier wrapped reading made the FE read `undefined` and silently drop the minted code.)
- **A down reservation store is not ATP 0.** The fail-closed `atp()` throw propagates as the scope's skip. Any new read path that invents a default figure here mints false breaches wholesale during an outage.
- **A cold warehouse's first sweep pays its rebuild inline.** The sweep's first ATP read on a warehouse with no ready marker (created after start, stock-less, flushed) runs that warehouse's journal rebuild inline and then answers; a failed repair is a 503 that skips the scope (backed off 5 s) — never a read of ATP 0.
- **A dismissed batch alert RE-RAISES — deliberate, but say it.** The partial open-scope unique covers `status='open'` rows only, so a dismissed alert re-opens as a FRESH row on the next scan that still sees the breach conditions. This exactly matches 6-1's re-breach past dismissal, but it cost a test round when the real-facade tick arm first read one row short; the FE's dismissal sentence names the re-raise up front. Any future "suppress until conditions lift" idea needs a new suppression state, not a unique re-key.
- **The 6.2 boundaries are both INCLUSIVE, on purpose.** Expiry: `expiry ≤ now + lead_days` — the lead-day edge itself alerts and an already-expired date still qualifies (expiry only matures; a late scan must not miss). Aging: `age_days ≥ threshold`, with `age_days` FROZEN via `floor((now − created_at)/86400s)` — so a fixture backdated EXACTLY N days freezes N (the scan runs ε later). A `>`-style exclusive comparison silently drops day-N batches; the e2e arms pin ±1h margins so the assertion never rides a millisecond.
- **The absent config row is the OFF switch, and the GET answers 404.** No invented default lead/threshold days anywhere in code; a GET that returned a default would silently ARM alerting for a tenant that deliberately has none. The FE's `fetchApiGetExpiryPolicy` folds that 404 to `null` and renders "alerts are OFF" — it is not a failed read.
