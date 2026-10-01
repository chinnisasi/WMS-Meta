# Replenishment module

> The stock-intelligence spine (story 6.1, FR-22): a scheduled sweep that notices ATP falling below a reorder point, opens an alert, and drafts a suggested PO — a human decides; the system never auto-submits.

Paths are relative to `workspace/core/backend/wms-be`. Read [`../IMPLEMENTATION-GUIDE.md`](../IMPLEMENTATION-GUIDE.md) first — the command skeleton is followed closely here and is not repeated.

**The module exists for one rule: the ONLY writer of a real purchase order is the human-triggered `submitSuggestedPo` command.** The worker drafts; it never mints a PO. Every PO mint re-runs `createPurchaseOrderInTx`, which re-asserts `po.manage` on the same transaction — replenishment can never create a PO its caller wasn't entitled to create.

## Owns

| Table | Holds | Key invariants |
|---|---|---|
| `reorder_policies` (`src/shared/db/schema.ts:3230`) | Per-warehouse reorder-point overrides: `warehouse_id`, `sku_id`, `reorder_point_milli`, `reorder_qty_milli` | One row per (tenant, warehouse, sku); positive milli CHECKs migration-only |
| `reorder_breaches` (`src/shared/db/schema.ts:3264`) | Breach alerts: frozen `point_milli` + `atp_milli` at detection, `status open\|recovered\|actioned\|dismissed`, `resolved_at`/`resolved_by` | At most ONE open breach per (tenant, warehouse, sku) — partial unique |
| `suggested_pos` (`src/shared/db/schema.ts:3308`) | The drafts: `breach_id`, nullable `vendor_id`, `quantity_milli`, `status draft\|submitted\|dismissed`, `submitted_po_id` | At most ONE `draft` per (tenant, warehouse, sku) — partial unique |

CHECKs and RLS live only in `drizzle/0048_replenishment.sql` (the drizzle-blindness rule; schema.ts declares the columns, the migration owns the policies):

- `reorder_policies_tenant_warehouse_sku_unique` + `reorder_policies_{point,qty}_milli_positive_check` — an override is a valid milli quantity or nothing.
- `reorder_breaches_open_tenant_warehouse_sku_unique` **WHERE status = 'open'** — one active alert per scope; the open path reads-then-inerts inside the transition tx but this unique is the deterministic 23505 backstop against two concurrent sweeps of one scope both opening (the loser's 23505 is swallowed as another sweep's already-open verdict).
- `reorder_breaches_status_check` — the frozen four-vocabulary lifecycle: `open → recovered` (worker; ATP ≥ point) / `open → actioned` (its PO submitted) / `open → dismissed` (human). Recovery stamps `resolved_at` with `resolved_by` **null** (nobody acted); dismissal/action stamp both (the actor was the submitter/dismissor — 6-1's resolved-by convention).
- `suggested_pos_draft_tenant_warehouse_sku_unique` **WHERE status = 'draft'** — one standing draft per scope; the re-breach repoint updates it in place (never duplicates).
- `suggested_pos_status_check` — `draft|submitted|dismissed`; `submitted_po_id` nullable, set exactly once at submit.
- `*_tenant_isolation` ×3 — the standard fail-closed RLS guard; breach rows are tenant secrets like everything else.
- Keyset indexes on every table (tenant-first `(tenant_id, …, created_at, id)`).

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

## The worker — scope enumeration and the cap

`ReplenishmentSchedulerWorker` (`jobs.module.ts:428`) is the `CountSchedulerWorker` shell: env `REPLENISHMENT_SCHEDULER_POLL_MS` (unset/0 = OFF; boot-loud on garbage), single-flight (`this.running`), auth-db enumeration with per-scope catch/log/skip (a poison scope never starves the tick).

**Scope enumeration is two queries, not one guess** (`jobs.module.ts:482-489`):

1. distinct `(tenant, warehouse)` from `reorder_policies` — warehouses with configured overrides;
2. every warehouse of every tenant carrying at least one SKU default > 0 (point OR qty — a point-0 SKU with a qty is not an alert source, and a scope whose SKUs all read effective point 0 short-circuits in the sweep anyway).

The union is a deduped Map, deterministic: **policy scopes first** (a configured override is the sharpest alert source), then defaults.

**The per-tick cap (200, `MAX_REPLENISHMENT_SCOPES_PER_TICK`) is a ROTATING window** — this is a review finding's fix, worth its paragraph. A head-only slice of a deterministically-ordered enumeration would carry the SAME head every tick and starve everything past the cap forever. Each truncating tick instead carries a wrap-around window starting at an in-memory `tickOffset` that advances one scope per truncated tick; every scope is swept within ⌈length / cap⌉ + ticks, and the truncation warn quantifies the carry ("the rotating window advances each tick until every scope is swept"). Scope counts larger than one tick can carry remain LOUDLY bounded — FR-22's ≤ 5-minute detection bound holds when `REPLENISHMENT_SCHEDULER_POLL_MS ≤ 300000` and the cycle fits the cap.

```mermaid
sequenceDiagram
    participant ENV as setInterval(poll)
    participant W as SchedulerWorker.tick
    participant DB as auth db
    participant S as ReplenishmentSweep
    ENV->>W: tick() (single-flight shed)
    W->>DB: policy scopes ∪ defaulted-SKU scopes (2 SQL, deterministic order)
    W->>W: dedupe; ≤200-carried (rotating window if truncated, warn)
    loop each carried scope — catch/log/skip per scope
        W->>S: sweepScope(tenant, warehouse)
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
| `sweepScope(tenantId, warehouseId)` | The worker's per-scope entry (see the sweep section) |

Keyset cursors are the house `(createdAt, id)` opaque envelope (`decodeCursorSafe` → `400 invalid-cursor`); page rows compose without repeats — proven by the cursor-chain exhaustion walks in `test/replenishment.spec.ts`.

**Cross-module reads the module takes** (all in-tx via facades, never direct table reaches):

| Facade | Read | Why |
|---|---|---|
| `InventoryFacade.atp` | The ONLY ATP read, outside any tx | The architecture spine; fallible 503 is the sweep's skip signal |
| `CatalogFacade.getSkuReorderDefaultsInTx` | ALL tenant SKUs `{id, code, name, uom, reorderPoint, reorderQty}` | The tenant-wide defaults + the identity source for candidates |
| `InboundFacade.createPurchaseOrderInTx` | The PO mint on the submit arm's held tx | The inbound module remains the only PO writer |
| `InboundFacade.findDefaultVendorInTx` | Deterministic min `(created_at, id)` default vendor | ≥ 2 defaults possible (no single-default unique by design); null when none — a vendor-less draft requires the submit edit |

`outbound`/`movements`/`putaway` never see this module; the ledger is untouched (replenishment invents NO quantities — it freezes an ATP snapshot and lets PO receipts do the rest).

HTTP lives in the api shell (`src/api/replenishment.controller.ts`) — 7 routes, thin DTO mapping, `assertOwnTenant` per method. Note: **the policy delete is the repo's FIRST `@Delete` route** (PUT/POST destructive verbs elsewhere) — idempotent and snapshot-returning (the deleted row), so it lives within the same `Idempotency-Key` contract the POST-destructives carry.

---

## Events

Deliberately exactly two (and one deliberate absence):

| Event | When | Payload | Consumers |
|---|---|---|---|
| `replenishment.breach_detected` | Breach OPEN | `{breachId, warehouseId, skuId, atpMilli, pointMilli, breachAt, notifyRole: 'ops_manager'}` | **None yet** — the relay only logs; Epic 9's panel reads `notifyRole` |
| `replenishment.suggested_po_submitted` | Submit arm | `{suggestedPoId, poId, poCode, warehouseId, vendorId, quantityMilli}` | None yet |
| — | RECOVERY | **no event, by design** — surface-visible state change only | — |

Events are audit-adjacent, not delivery. The `notifyRole` hint is the `count.variance.threshold_exceeded` precedent.

---

## Gotchas (the ones that caused real findings)

- **Head-only scope slices starve.** The first shipped cap sliced the same deterministic head every tick — scopes past 200 were NEVER swept and the warn lied ("swept on the next tick"). The rotating window fixed it; any new enumerated-cap worker must rotate or order-shuffle, not slice-head.
- **A nested transaction while holding one is the pool deadlock.** The submit arm mints via `createPurchaseOrderInTx` on the SAME connection. The false precedent that almost shipped: the sync-report apply arm was cited as an inner-transaction precedent — withdrawn; sync-report calls no facade and writes in its caller's tx.
- **The response carrier must be FLAT.** The PO mint's natural return is the wrapped `{purchaseOrder: {…}}`; submit's HTTP response wraps the FLAT snapshot — `body.purchaseOrder` IS the PO. (An earlier wrapped reading made the FE read `undefined` and silently drop the minted code.)
- **A down reservation store is not ATP 0.** The fail-closed `atp()` throw propagates as the scope's skip. Any new read path that invents a default figure here mints false breaches wholesale during an outage.
- **Cold-scope bootstrap is a known gap** — see `deferred-work.md`: a warehouse whose tenant carries ONLY fresh reservation activity gets enumerated only via its SKU defaults; the ATP fail-closed marker self-heals from reservation/stock activity (the startup rebuild's owners-set and the not-ready grant repair `reservation.service.ts:917`), so a brand-new tenant with no activity sweeps to "candidates × no reading" until then.