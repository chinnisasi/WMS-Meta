# Compliance module

> Temperature excursions (FR-44): an operator records a °C reading against a bin, every affected (sku, bin) scope is quarantined through the ordinary QC-hold semantics, and the excursion itself is a registered zero-delta ledger event — so cold-chain custody is reconstructible from the ledger alone (FR-45). Story 12-6 adds the FR-45 reader: the cold-chain trace, reconstructed from `ledger_events` alone. Story **1-6c** adds the **drug and FSSAI licences**: the statutory licences held by a client brand or by a site, the coverage gaps wherever drug or food goods are, and an expiry warning from 60 days out (§Drug and FSSAI licences).

All paths below are relative to `workspace/core/backend/wms-be`. Story 12-5 activated this module (an empty spine placeholder before it); story 12-6 added the read side.

Files: `src/modules/compliance/{compliance.module,excursion.command,excursion.facade,cold-chain.facade,licence.command,licence.facade}.ts` + the API surface `src/api/{compliance.controller,compliance.dto,licences.controller,licences.dto}.ts`; the licence rule set is the shared primitive `src/shared/primitives/licence.ts` (1-6c).

---

## Owns

One table, module-exclusive:

| Table | Holds | Invariants and where they live |
| --- | --- | --- |
| `temperature_excursions` (`drizzle/0038_temperature_excursions.sql`) | One row per recorded excursion: origin `bin_id`, `reading_c` numeric(6,2), `note` (nullable), `hold_ids uuid[]` (the QC holds this excursion created — links the queue item to its holds without touching `qc_holds`), `status` `open|resolved`, `recorded_by`, `occurred_at` (business time — the operator's reading instant), `resolved_by`/`resolved_at`. | `temperature_excursions_status_check` (`open|resolved`) and the fail-closed RLS policy live **only in the migration SQL** (the 0008 hand-append pattern — schema.ts deliberately carries neither; the snapshot's `isRLSEnabled: false` is why the next `db:generate` must not re-emit them). `tenantTimestamps` for the keyset cursor. |

| `licences` (`drizzle/0084_licences.sql`, 1-6c) | One row per statutory licence: `client_id` (nullable — the holding brand), `warehouse_id` (nullable — a site licence's site, or a client licence's premises), `kind`, `number`, `valid_from`/`valid_until` (IST `date`s, nullable), `note`, `status` `active\|withdrawn`, and the sweep's state `upcoming_warned_on`, `expired_warned_on`, `open_warning_id` | CHECKs only in the migration: `licences_kind_check` (the seven kinds), `licences_holder_check` (a client or a site), `licences_fssai_number_check` (14 digits; registration `2…`, state/central `1…`), `licences_drug_number_check` (normalised `^[A-Z0-9 /.-]{1,50}$`), `licences_validity_order`, `licences_valid_until_required` (FSSAI and NDPS), `licences_status_check`, `licences_note_length` (1–200, trimmed). The SQL-only **family unique** `licences_family_number_unique (tenant_id, CASE WHEN kind LIKE 'fssai-%' THEN 'fssai' ELSE kind END, number) WHERE status = 'active'`. RLS: the tenant arm plus the 0041 `app.client_id` clause on `client_id` (a site licence — null client — is invisible to a portal stamp; proved as `wms_rls_probe` in `test/client-isolation.spec.ts`). Never deleted; kind, client and site fixed after the add |

The module writes **no other table** (1-6c's sweep and commands write only `licences`, plus outbox and audit). The quarantine is inbound's `qc_holds` (written through `QcFacade.holdScopeInTx`, never directly); the ledger events are inventory's (written through `appendLedgerEventInTx`). The bin's on-hand sweep reads through `InventoryFacade.onHandInBinInTx`.

Not owned but read — **1-6c** reads `clients`, `warehouses`, `skus`, `stock_on_hand`, `purchase_orders`/`purchase_order_lines` and `advance_shipment_notices`/`asn_lines` directly (the 12-5 shared-substrate precedent): tenancy imports this module (the sync-report apply arm), so importing the catalog, inventory-read or tenancy modules would cycle. The holder checks use the clients module's file-level seam (`assertClientInTenantInTx`, `assertClientTakesWorkInTx`) and tenancy's `assertWarehouseInTenant` — functions, no Nest module import. Also: `bins` (origin bin, with a `.for('update')` lock — serialized against hold, merge and retire), `skus` (serial/catch-weight pre-flight), `warehouses`, `qc_holds` (only through the facade: `openHoldsForBinsInTx` for the skip arm), `idempotency_keys`, `outbox_messages`, `audit_events`.

## Public seam

`ExcursionFacade` (`src/modules/compliance/excursion.facade.ts`) — `recordExcursion`, `resolveExcursion`, `listExcursions`. `LicenceFacade` (1-6c, `licence.facade.ts`) — `addLicence` / `editLicence` / `withdrawLicence` (through `LicenceCommand`), `listLicences(tenantId, filters, istToday?)`, `coverageGaps(tenantId, istToday?)` and `sweepExpiry(tenantId, istToday)`; exported for the api shell's `LicencesController` and the jobs shell's `LicenceExpiryWorker`. `ColdChainFacade` (`src/modules/compliance/cold-chain.facade.ts`) — `getOrderColdChainTrace` (the FR-45 read, no capability gate — reads are never gated). The compliance module is a **consumer** of inventory's facade (ledger + sweep), inbound's facade (the hold core) and outbound's facade (order identity — `OutboundModule` imported 12-6; it exports only its facade and imports nothing back, so no cycle); compliance is imported by the api shell, tenancy (5-6, the sync-report apply arm) and — 1-6c — the jobs shell (`LicenceExpiryWorker`, through `LicenceFacade`).

## Flows

### recordExcursion — one excursion, N affected scopes

```mermaid
sequenceDiagram
    participant API as api shell
    participant C as ExcursionCommand
    participant Q as QcFacade (inbound)
    participant Inv as InventoryFacade (ledger)
    API->>C: recordExcursion (Idempotency-Key, excursion.record)
    C->>C: shape checks (bounds backstop, note ≤200, occurredAt UTC; note "" → null before the hash)
    C->>C: payloadHash over RAW request fields
    Note over C: tx begins
    C->>C: fresh role read → assertPermission('excursion.record')
    C->>C: replay lookup (same key + same hash → snapshot)
    C->>C: warehouse in tenant; bin row .for('update') (404) — system-owned refused (400)
    C->>C: onHandInBinInTx sweep — empty → 400 (FR-44 is against affected stock)
    C->>C: SKU pre-flight: any serial-tracked / catch-weight SKU → 400 naming every offender — ALL-OR-NOTHING, nothing written
    C->>Q: openHoldsForBinsInTx — scopes already under an open hold are SKIPPED (already out of ATP), not a 409
    loop per unheld scope
        C->>Q: holdScopeInTx (ordinary QC hold; reason 'temperature-excursion[: note…]', audit ref = excursionId)
    end
    C->>C: insert temperature_excursions row (holdIds, .returning createdAt)
    loop per AFFECTED scope (held or skipped)
        C->>Inv: appendLedgerEventInTx — zero-delta excursion.recorded, referenceDoc {kind:'excursion', excursionId, binId, readingC}
    end
    C->>C: snapshot (row's created_at) → outbox excursion.recorded → audit → idempotency key
    Note over C: tx commits
```

### resolveExcursion — the review flip, never a release

```mermaid
sequenceDiagram
    participant API as api shell
    participant C as ExcursionCommand
    API->>C: resolveExcursion (Idempotency-Key, review.decide)
    Note over C: tx begins
    C->>C: assertPermission('review.decide') → replay → row .for('update') (404)
    C->>C: conditional UPDATE status/resolvedBy/resolvedAt + rowcount backstop (second resolve → 409 excursion-resolved)
    C->>C: outbox excursion.resolved → audit → idempotency key
    Note over C: tx commits — the created QC holds are UNTOUCHED
```

Stock disposition is deliberately out of scope here: releasing is `qc.manage`'s (release returns the units) and write-off is `stock.adjust`. The resolve is a review decision, and the verbs stay separate so a future matrix change answers each question in the open.

## Commands

### `ExcursionCommand.recordExcursion`

Guard order (the command skeleton order — load-bearing): shape checks **before** the transaction (reading bounds −100..200 with a 2-decimal cap at the DTO, `maxDecimalPlaces: 2`; the command's 2dp normalization is the backstop so the ledger `referenceDoc.readingC` and the row agree; note length; `occurredAt` Z-suffixed UTC mapped to 400) → `payloadHash` over the **raw** request fields (never resolved instants; a whitespace-only note normalizes to `null` **before** the hash so both spellings of "no note" replay identically) → in-tx: **the 12-8 device arm first when `deviceId !== null`** (the putaway/grn.submit mirror: `.for('update')` device read, `403 device-revoked` on missing/inactive/unbadged — the web path sends null and skips the arm; `deviceId` is excluded from the payload hash, so pre-12-8 keys keep replaying) → fresh role read → `assertPermission('excursion.record')` → replay → `assertWarehouseInTenant` → bin row `.for('update')` 404 → system-owned refuse → sweep → pre-flight → skip → holds → row → events → snapshot → outbox → audit → idempotency key (unique-violation → 409 `conflict`).

The route accepts **either session family** since 12-8 (`AnySessionGuard`, the new tenancy guard): the branch key is the **presence of the `device_id` claim** in the token's unverified payload — load-bearing, because `verifyTenantSession` ignores `device_id` entirely (the PENDING-1 accident), so a tenant-first composite would silently route every device token down the web arm and revocation would never bite. The device arm is badge-in required (`401` on a bare credential).

Errors: `400 validation-failed` (bad shape, out-of-bounds reading, >2 decimals, oversized note, empty or system-owned bin, empty sweep, unquarantinable SKUs naming each offender and why) · `401` (no token, or a bare device credential without badge-in) · `403 role-denied` (`excursion.record`, or the hold core's `secure.move` on a cage-class bin) / `device-revoked` (the device arm) / `permission-denied` (cross-tenant) · `404` (warehouse/bin) · `409 conflict` (concurrent same-key) · `422 idempotency-key-reuse`.

**Ledger reach — the invariant that was nearly wrong:** the events cover every **affected** scope — every distinct SKU with on-hand > 0 in the bin — *including* scopes skipped because they already sit under an open hold. The skip governs the quarantine (no new hold, `holdIds` omits it), not the ledger: an excursion that quarantined nothing new still commits row + events, and FR-45 reconstructs the bin's exposure from the events alone. `holdIds` lists holds CREATED; the events record exposure; the two relationships are different and each is accurate.

### `ExcursionCommand.resolveExcursion`

`assertPermission('review.decide')` → replay → row `.for('update')` 404 / conditional UPDATE with a rowcount backstop → outbox `excursion.resolved` + audit → idempotency key. Errors: `403 role-denied` · `404` · `409 excursion-resolved` (terminal) · `422 idempotency-key-reuse`.

### `ExcursionFacade.listExcursions`

Keyset on `(created_at, id)` (newest first), `warehouseId` filter (foreign → `404`), `status=open|resolved` filter, `decodeCursorSafe` guard → `400 invalid-cursor`, default page 50 (1..200). The review-queue read for 12-7. **12-7 gave both mutations their first web consumers**: the `/conflicts` excursion queue consumes `listExcursions` (joining the affected-units labels to `GET /receiving/qc-holds` — an enrichment read whose failure degrades the card, never the queue) and gates resolve on `review.decide` with a per-click Idempotency-Key; the `/compliance` trace viewer consumes `getOrderColdChainTrace`.

## Cold-chain read (story 12-6, FR-45)

`GET /tenants/{t}/warehouses/{w}/cold-chain/orders/{orderId}` — one READ-ONLY reconstruction of a dispatched order's storage trace from `ledger_events` alone: never from projections, never from the `temperature_excursions` rows. No capability gate, no idempotency, no writes. Response shape: `{order, bins[], lines[]}` — per order line, one chain per picked batch/serial scope, each chain event annotated with its bins' **current** storage classes, plus the line's dwell-window-correlated `excursions[]`.

```mermaid
sequenceDiagram
    participant API as api shell
    participant F as ColdChainFacade
    participant Out as OutboundFacade (order identity)
    participant Inv as InventoryFacade (ledger feeds)
    API->>F: getOrderColdChainTrace (guard + asserts only)
    F->>Out: getOrder (its own tx, AD-6) — null or foreign warehouse → 404
    Note over F: withTenantTransaction begins
    F->>F: assertWarehouseInTenant (404)
    F->>Inv: ledgerEventsByOrderRefInTx — pick.picked + dispatch.dispatched by reference_doc->>'orderId' (0039 index)
    F->>F: no dispatch events → 409 order-not-dispatched
    F->>Inv: ledgerEventsByScopeRefsInTx — every picked scope's COMPLETE batch/serial history (other orders' picks included)
    F->>F: direct bins read — every chain bin's CURRENT storage class
    F->>Inv: ledgerExcursionEventsBySkuInTx — the lines' SKUs' excursion.recorded events
    F->>F: dwell windows per (scope, bin) → excursion correlation, deduped by excursionId per line
    Note over F: tx commits — response converted at this edge (fromMilli + canonicalInstant)
```

**The join chain rides the ledger's own reference docs:** the `dispatch.dispatched` events whose doc names the order → the `pick.picked` events with the same `reference_doc->>'orderId'` → those picks' `batch_ref`/`serial_ref` scopes → each scope's complete chain via the `(tenant, batch_ref, seq)` / `(tenant, serial_ref, seq)` trace indexes. Migration `0039` is index-only: the partial expression index `ledger_events_order_ref_idx` on `((reference_doc->>'orderId')) WHERE reference_doc ? 'orderId'` — **the query must carry the `? 'orderId'` qual itself** or the planner cannot use the index (predicate-implied-by has no `->>`-equality rule; the review proved it with EXPLAIN — `inventory.facade.ts` carries it).

**Chain semantics.** A scope's chain is its COMPLETE batch/serial history (all events, chronological by `seq`) — other orders' picks included, because the batch's history is the batch's history. Zero-arm events (pack, dispatch, excursion) never appear in chains: the chain queries match on identity arms, which those types do not carry. Dwell window per bin = `[min occurredAt where to_bin_id = bin, max occurredAt where from_bin_id = bin]` over the complete chain, visits merged, **open-ended** when the scope never left (departure null — leftover stock still there); windows are clamped against inverted business times (a backdated pick must not make departure precede arrival). An excursion attaches to a line when its `skuId` matches, its doc's `binId` is on the scope's chain, and its business time is inside the window — deduped by `excursionId` per line (two scopes that dwelt in the same bin correlate it once).

**Storage-class honesty.** Every chain event is annotated with the bins' **CURRENT** class; the report never fabricates historical classes. The annotation is sound because the 12-1/12-3 class-edit guards refuse a change that strands stock (temperature classes may only have moved colder for bins that held stock); a bin whose row is gone annotates `null`. The caveat is stated in the route's OpenAPI description.

Errors: `400 validation-failed` (malformed warehouseId/orderId) · `401` · `403` (foreign-tenant session) · `404 not-found` (missing order, order of another warehouse in the same tenant, or warehouse outside the tenant) · `409 order-not-dispatched` (the order exists but has no dispatch events — FR-45 names dispatched units).

## Drug and FSSAI licences (story 1-6c)

**What it records.** The Drugs & Cosmetics Act and FSSAI licences that make holding scheduled drugs and food legal, on their holder: a **client** brand (optionally for one site — its premises — or for none — a head-office or central licence) or a **site** (the 3PL's own). Blocking uncovered work is story 1-6d; this story records, shows the gaps and warns.

**Kinds are statutory forms (decision 1).** One need per schedule a SKU carries (`needsOf`, `shared/primitives/licence.ts`; an `H` + `NDPS` SKU needs both):

| Need | Covered by | For |
|---|---|---|
| `drug-20b` | `drug-20b` | schedules G, H, H1 |
| `drug-21b` | `drug-21b` | schedules C, C1 |
| `drug-20g` | `drug-20g` | schedule X |
| `ndps` | `ndps` | schedule NDPS |
| `fssai` | `fssai-registration`, `fssai-state`, `fssai-central` (any tier) | food — 1-6b's `isFood` |

`SCHEDULE_NEED` is a `Record` over 1-6a's `DRUG_SCHEDULES`, so a new schedule fails the compile until it has a need.

**Validity (decision 6).** Valid on D: `active`, `valid_from` null or ≤ D, `valid_until` null or ≥ D (`licenceValidOn`). FSSAI tiers and NDPS require `valid_until`; a drug form's is optional and labelled "Valid until / retention due" (perpetual licences pay a retention fee every five years). A licence with no `valid_until` never warns.

**Numbers (decision 7).** Normalised (trimmed, whitespace collapsed, upper-cased) before the hash. FSSAI: 14 digits — registration `2…`, state/central `1…`; drug and NDPS: 1–50 of `A–Z 0–9 space / . -`. Unique among the tenant's **active** licences per family (the three FSSAI tiers one family, each drug kind its own) — the index is the arbiter, caught by name → 409 `licence-number-taken`. A withdrawn licence frees its number.

### The master — add, edit, withdraw (`LicenceCommand`)

```mermaid
sequenceDiagram
    participant API as LicencesController
    participant C as LicenceCommand
    participant CL as clients.facade (fns)
    participant T as tenancy.service (fns)
    API->>C: add / edit / withdraw (Idempotency-Key, licences.manage)
    C->>C: shape (kind, holder present, dates YYYY-MM-DD) → normalise number, note, dates
    C->>C: payloadHash {arm: licence-add | licence-edit | licence-withdraw, tenantId, …normalised}
    Note over C: tx begins
    C->>C: assertPermission('licences.manage') → replay
    alt add
        C->>CL: assertClientInTenantInTx (404) — self → 400
        C->>T: assertWarehouseInTenant (404)
        C->>CL: assertClientTakesWorkInTx — FOR KEY SHARE, departed → 409 client-departed
    else edit / withdraw
        C->>C: licence row FOR UPDATE (404)
    end
    C->>C: replay again under the lock
    C->>C: edit/withdraw of a withdrawn licence → 409 licence-withdrawn
    C->>C: the rules on the MERGED row (400 naming the field)
    alt edit unchanged
        C->>C: store the key only (licences.edit:unchanged — no write, no audit)
    else
        C->>C: write (family unique → 409 licence-number-taken)
        C->>C: edit: validUntil changed AND its implied warning ≠ the warned one → outbox licence.expiry_warning_cleared (renewed), reset both warned dates
        C->>C: withdraw: an open warning → outbox licence.expiry_warning_cleared (withdrawn)
        C->>C: audit licence.added | edited | withdrawn (target licence) → key LAST
    end
```

- **The clear's outcome on an edit** is `expired` when the new date is already past, else `renewed`.
- **Edit semantics (decision 10):** `validFrom`, `validUntil`, `note` absent = keep, null = clear; `number` cannot be null (400). The hash omits absent keys and keeps nulls. Kind, client and site are not in the edit DTO (`forbidNonWhitelisted` → 400) — a correction is a withdraw plus a new add.
- **"Today"** for the edit's warning comparison and every read's `asOfDate` is `licenceClock` (`licence.command.ts`, the §7c mutable clock), read as an IST date.
- **The holder lock.** The add takes the client row `FOR KEY SHARE` (the "no new work" gate) so a departure cannot commit between the check and the insert. A site licence locks nothing: no row exists to lock, and the unique index and the key settle a duplicate.

### The reads — list and coverage gaps

`GET …/licences` — every licence (≤ 500), active first then `valid_until` soonest first, each with `expiryState` (`valid | upcoming | expired | withdrawn`) and `daysLeft` for the server's IST `asOfDate`. `GET …/licences/coverage` — the gaps:

```mermaid
sequenceDiagram
    participant F as LicenceFacade.coverageGaps
    participant DB as Postgres (tenant tx)
    F->>DB: goods = (stock_on_hand quantity > 0) ∪ (open PO + open line) ∪ (ASN announced / partially_received), joined to skus, filtered to drug or food SKUs IN SQL; clients not departed
    DB-->>F: distinct (client, site, sku, systemOwned, food_category, drug_schedules)
    F->>DB: active licences
    F->>F: per row needsOf(sku) → (client, site, need) and (site, need) SKU sets
    F->>F: site gap unless a site licence covers (siteLicenceCovers)
    F->>F: client gap unless a client licence covers (clientLicenceCovers) — never for `self` (decision 4)
    F-->>F: {asOfDate, gaps: [{holder, clientId?, warehouseId, need, coveredBy, skuCount}]} — per site: the site's gaps, then each client's, needs in vocabulary order
```

A client with no drug or food goods anywhere has no gap; a site counts only where goods are (there is no client–warehouse assignment). The web words each gap from `coveredBy`, so it mirrors no rule table.

### The expiry sweep (`LicenceFacade.sweepExpiry`, `LicenceExpiryWorker`)

```mermaid
sequenceDiagram
    participant W as LicenceExpiryWorker (jobs)
    participant A as AUTH_DATABASE (read-only)
    participant F as LicenceFacade.sweepExpiry
    participant O as outbox
    participant N as notifications (licence-expiry)
    W->>A: tenants with an active licence, valid_until ≤ today + 60, not warned for every state
    loop per tenant (try/catch)
        W->>F: sweepExpiry(tenantId, istToday)
        Note over F: own tenant tx — due rows ordered by id FOR NO KEY UPDATE SKIP LOCKED
        F->>F: raise nothing for: departed client · valid_until before its IST added date (historical) · a successor (same client, site, need) valid on valid_until + 1 — but clear an open warning (successor → renewed; past valid_until → expired) and stamp the current state's warned date, no raise or audit row, so the row leaves the due set
        alt upcoming (valid_until − 60 ≤ today ≤ valid_until), never warned
            F->>O: licence.expiry_upcoming {warningId (fresh), licenceId, kind, number, holder, holderName, siteCode?, validUntil, state, warehouseId}
            F->>F: audit licence.expiry_upcoming_raised (SYSTEM_ACTOR_ID) · upcoming_warned_on, open_warning_id
        else expired (today > valid_until), not warned expired
            F->>O: licence.expiry_warning_cleared {warningId: the open upcoming, outcome: expired}
            F->>O: licence.expired {fresh warningId, …}
            F->>F: audit licence.expired_raised · expired_warned_on (and upcoming_warned_on if unset), open_warning_id
        end
    end
    O->>N: raise → one entry per warning id; cleared → resolved (renewed | withdrawn | expired)
```

`LICENCE_EXPIRY_POLL_MS` gates the worker (unset/0 = off); suites drive `sweepExpiry` with an injected date and `tick(today)` once. Each warning has its own id because a notification row is unique per `(source_type, source_id)` and a re-raise is a no-op: one id per licence would swallow the expired warning and never resolve.

## Invariants

- **The ledger is the excursion's record (AD-11/FR-45).** One zero-delta `excursion.recorded` event per affected scope; both bin arms null (the zero-quantity envelope rule), `skuId` never null (hence one event per scope), batch/serial arms registry-closed. The relocation itself is the `qc.held` movements' work — the excursion event is the compliance fact, not a stock movement.
- **ONE hold implementation.** The module holds through `QcFacade.holdScopeInTx` and never writes `qc_holds` — no fork of hold semantics, so ATP exclusion, release, merge-guards and the ledger timeline all work unchanged. ATP drops purely because the units physically move into the system `QC-HOLD` bin (`qcHeldUnits`); `reservation.service.ts` is untouched.
- **All-or-nothing.** Any serial-tracked or catch-weight SKU in the bin refuses the ENTIRE excursion naming every offender — FR-44 never leaves units in ATP; per-unit quarantine stays Epic 15's.
- **Resolve is a review flip.** It releases nothing; the holds stay open until `qc.manage` disposes of them.
- **Manual capture only (UX-DR30).** No threshold model, sensor ingestion or auto-detection — an operator-captured reading against a bin; no handling-unit arm (Epic 15), no unit conversion (°C only).
- **A licence is never deleted (1-6c).** Withdraw is the only end; kind, client and site never change after the add; a number is unique per family among active licences only (the SQL-only family index).
- **One warning per term, its own entry (1-6c).** The warned dates are the sweep's state; a fresh `warningId` per raise is the entry's `source_id`; the open one is always resolved before another opens (the expired raise clears the upcoming; a renewing edit and a withdraw clear theirs).
- **The coverage read and the badge use the server's IST date (1-6c)** — never the browser's (`asOfDate` on both reads).
- **The trace reads the ledger only (12-6).** The cold-chain reconstruction reads `ledger_events` (through inventory's facade — the only ledger door) and `bins` directly (the 12-5 shared-substrate precedent); it never reads `temperature_excursions` rows or projections. Excursion correlation is dwell-window based from the events alone, because the excursion arm carries no batch/serial (one event per affected (sku, bin) scope).

## Events

**1-6c — licences.** Outbox: `licence.expiry_upcoming`, `licence.expired` (the `licence-expiry` panel source's two raises) and `licence.expiry_warning_cleared` (`outcome` ∈ `LICENCE_WARNING_OUTCOMES` = `renewed | withdrawn | expired`), pinned to the notifications module's literals by `test/notifications.spec.ts`. Audit: `licence.added`, `licence.edited`, `licence.withdrawn` (keyed, target `licence`) and the sweep's `licence.expiry_upcoming_raised` / `licence.expired_raised` (system actor, no key).


Ledger: `excursion.recorded` (registered in `ledger-registry.ts`, `sinceVersion: 1`, reference kind `excursion`, batch/serial arms closed). Outbox: `excursion.recorded` (payload carries `affectedSkus` = every affected scope, `holdIds` = the holds created) and `excursion.resolved` (from resolve). Audit: `excursion.recorded` (reference = the idempotency key) and `excursion.resolved` (reference = the excursion's idempotency key).

## Gotchas

- **Two licences of one holder and need are each other's successor (1-6c).** The sweep's successor rule mutes a warning when another active licence of the same client, site and need is valid the day after — a test that puts two expiring site licences of one kind at one site sees neither warn. Give each fixture its own holder (`test/licences.spec.ts` does).
- **The migration cannot prove RLS (1-6c).** The migrator is a superuser and bypasses RLS, so 0084's probe covers the CHECKs and the family index only; the site-row invisibility under a portal stamp is proved as `wms_rls_probe` in `test/client-isolation.spec.ts`.

- **The skip arm's ledger reach** — the first implementation emitted events only for *quarantined* scopes, which made an all-scopes-skipped excursion ledger-invisible (AD-11 violated). The 12-5 review caught it; the events loop walks the **sweep**, not the post-filter scopes. Do not "optimize" the loop back to the quarantined list.
- **The record snapshot's `createdAt` is the row's `created_at`**, never the business `occurredAt` — the row insert uses `.returning({ createdAt })` and the snapshot reports `canonicalInstant(row.createdAt)`. `createdAt` is the keyset cursor field; the record response and later list/resolve reads must agree on it.
- **`hold_ids` is a uuid[] column, not a join** — the queue item links its holds without cross-module table writes. Nothing else may infer excursion→hold from the ledger's `qc.held` events (their reference kind is `qc-hold`, holdId + fromBinId only); the linkage lives here.
- **The 403 on a secure bin comes from the hold core, not this module** — `assertSecureBinAuthority` fires when held units LEAVE the origin bin, so an operator recording a cage-class excursion is refused with `secure.move` even though `excursion.record` alone would admit them. The OpenAPI 403 arm documents both paths.
- **Ledger serial arms carry the resolved `serials.id`, not the scanned numbers** (found by 12-6's serial test) — an intake/adjust event's `serial_ref` is the catalog serial row's id, so a trace's serial scopes compare against resolved ids, never raw scan strings. Any future ledger query keyed by serial must resolve the scanned code to its id first.
- **The 0039 partial index needs its own qual in the query** — Postgres will not serve a partial index whose predicate (`reference_doc ? 'orderId'`) is not implied by the query's WHERE; an `->>'orderId' = $1` match alone plans a seq scan. Any query against that index must repeat the `? 'orderId'` predicate (the pattern lives in `ledgerEventsByOrderRefInTx`).