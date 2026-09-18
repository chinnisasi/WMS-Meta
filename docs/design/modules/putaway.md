# Putaway module

> Directed putaway — derived tasks, capacity-ranked bin suggestion, the scan-verified placement command — plus bin *operational* state (`blocked`), and the ranking/occupancy/rejection primitives that bin administration reuses.

All paths are relative to `workspace/core/backend/wms-be/`.

Files: `src/modules/putaway/putaway.module.ts`, `putaway.command.ts`, `putaway.facade.ts`, `bin-state.command.ts`, `putaway.dto.ts`. HTTP shell: `src/api/putaway.controller.ts`; the `blocked` toggle keeps its old URL in `src/modules/tenancy/tenancy.controller.ts:391`.

**Read this first if the task mentions merge or retire.** The task brief says story 3.6's bin administration lives in this module. In the code as it stands it does not: `mergeBin` and `retireBin` are implemented in `src/modules/tenancy/bin.command.ts:462` and `:765`, and only the `blocked` toggle re-homed here (`bin-state.command.ts:20-34`, and tenancy's own header comment at `bin.command.ts:176-181` says so). The `bins` ownership split is real and is described under *Bin administration and the shared `bins` boundary* below — it just runs in the other direction from what the brief implies.

---

## Owns

One module-exclusive table.

| Table | Holds | Invariants / CHECKs |
| --- | --- | --- |
| `putaway_placements` (`src/shared/db/schema.ts:1349`) | One row per completed placement: `grnId`/`grnLineId`, sku, optional batch, `qty` (milli-units), `fromBinId` (always the system Receiving bin), `toBinId`, `suggestedBinId` (the **server's re-derived** suggestion at placement time), `reasonCode` (fixed mismatch enum, null when the suggestion was followed), `placedBy`, `placedAt` (device time), `deviceId`. | `putaway_placements_qty_check CHECK (qty > 0)` (`drizzle/0015_silent_grey_gargoyle.sql:36`); RLS in the same migration. No FKs — uuid columns asserted in-command. |

**There is no task table.** Tasks are derived on every read from GRN lines joined to the Receiving bin's projections (`putaway.facade.ts:216`). There is no claim, no lock, no assignment state in v1 — two operators can pull the same task and the server's per-placement remaining check is what resolves it.

**Co-owned, see below:** `bins` is tenancy master data; this module writes exactly one column of it (`blocked`) from `bin-state.command.ts:125`.

**Never written here:** every stock table. Placement stock moves only as `putaway.placed` ledger events through `InventoryFacade`; `test/architecture.spec.ts:116` fails the build on any stock-table write outside the inventory module.

---

## Public seam

`putaway.module.ts:31` exports **two** providers — the facade and, unusually, `BinStateCommand` (because the tenancy controller keeps the `PATCH .../bins/{binId}` URL and delegates into it).

### `PutawayFacade` (`putaway.facade.ts`)

| Method | Does | Called by |
| --- | --- | --- |
| `placePutaway(command, idempotencyKey)` → `PutawayPlacementSnapshot` (`:110`) | Delegates to `PutawayCommand`. | `api/putaway.controller.ts:72` |
| `listPlacements(tenantId, query)` → `Page<PutawayPlacementEntry>` (`:123`) | Keyset page, newest first, with GRN code, SKU/batch codes, target-bin code and suggested-bin code joined (the suggested bin uses a `bins` alias, `:129`). Web is read-only — web never places. | `api/putaway.controller.ts:159` |
| `getPutawayTasks(tenantId, warehouseId)` → `readonly PutawayTask[]` (`:202`) | Opens its own tenant transaction and calls the in-tx form. | `api/putaway.controller.ts:128` |
| `getPutawayTasksInTx(tx, tenantId, warehouseId)` (`:216`) | The same derivation on the **caller's** transaction. | `ReceivingFacade.getCatalogSnapshot` (`receiving.facade.ts:381`) |
| `getBinSummariesInTx(tx, tenantId, warehouseId)` → `readonly PutawayBinSummary[]` (`:364`) | Every non-retired bin of the warehouse — blocked and system bins **included**, so the device can reject a scan against them before queueing. In-tx only; the snapshot is its sole consumer. | `receiving.facade.ts:380` |

### `BinStateCommand.setBlocked(command, idempotencyKey)` → `BinSnapshot` (`bin-state.command.ts:52`)

Called from `tenancy.controller.ts:404`. The response shape and URL are tenancy's `BinSnapshot` — only the command logic lives here.

### File-level exports other modules consume

`putaway.command.ts` exports read-only derivation helpers and problem factories that `src/modules/tenancy/bin.command.ts:35-42` imports directly:

- `binCandidatesInTx(tx, tenantId, warehouseId)` (`:768`) — the ranked eligible-bin list.
- `binOccupancyInTx(tx, tenantId, warehouseId, binId)` (`:810`) — one bin's total on-hand.
- `binFull(binCode, capacity, occupancy)` (`:916`), `binBlocked(binCode)` (`:926`), `binRetiredAsTarget(binCode)` (`:940`), `binRetiredAsSource(binCode)` (`:954`).
- `receivingBinOnHandInTx` (`:834`), `resolveSerialRefsInTx` (`:879`), `suggestBinInTx` (`:733`), `isMismatchReason` (`:722`).

This is a deliberate seam: the capacity gate and its rejection wording exist once, so a merge and a placement refuse a full or blocked bin with the identical problem type and message.

---

## Commands

Both commands follow the repo's invariant order inside `withTenantTransaction`: **authority → idempotency replay → validation → master-data asserts → movement(s) → own-table write → in-tx outbox → audit → idempotency-key snapshot.** Replay semantics are the repo-wide ones (same hash → stored snapshot; different hash → 422 `idempotency-key-reuse`; concurrent key insert → 409 `conflict`).

### `putaway.place` — `PutawayCommand.placePutaway` (`putaway.command.ts:199`)

Device-authenticated (`DeviceSessionGuard` at the shell, badge-in required — `api/putaway.controller.ts:79-83`). Guards, in execution order:

1. Device row `.for('update')`, fail-closed: missing, non-`active`, or `pinHash === null` → `deviceRevoked()` (`:231-241`).
2. Operator role re-read from the DB → `assertPermission('putaway.execute')` (`:245-248`). This is the **first non-empty operator capability** — owner/ops_manager/operator hold it, accountant does not (`src/modules/tenancy/permissions.ts:123-129`).
3. Idempotency replay (`:251`).
4. Shape validation: `occurredAt` a Z-suffixed UTC instant; `qty > 0` and `<= fromMilli(MAX_PLACEMENT_QTY)`; `reasonCode`, when present, inside `PUTAWAY_MISMATCH_REASON_CODES` (`:264-286`).
5. `assertWarehouseInTenant`, then the GRN line joined to its GRN — 404 if unknown, then four cross-checks that are each a 400: the line belongs to the named GRN, the GRN was recorded in this warehouse, the line's SKU equals the named SKU, and `appliedQty > 0` (`:288-331`).
6. SKU row read; **then** conversion + the UoM precision refusal (`:353-358`). Below this point only `scaled.qty` is read — `command.qty` is base units and is never touched again.
7. Batch arm: batch-tracked SKU requires a batch that exists for that SKU (404), untracked SKU must carry none (400), **and the batch must be the GRN line's own batch** (400 — a batch from another line of the same SKU would record the placement against the wrong line, `:396`).
8. Serial arm (mirrors `stock.adjustment`): serial-tracked requires one serial per unit, no duplicates, `serials.length === fromMilli(scaled.qty)`; untracked must carry none (`:405-430`). `resolveSerialRefsInTx` then resolves numbers → catalog ids inside the tx; an unknown number is a 400 — a placement *moves* intaken stock, it never creates serial identity.
9. `ensureReceivingBinInTx` (`:436`) — the from-bin identity, tenancy-owned.
10. **Remaining check**: `remaining = min(line.appliedQty, receivingBinOnHandInTx(...))`; `scaled.qty > remaining` → 400 naming the remaining quantity (`:440-452`).
11. **Target bin**, read `.for('update')` (`:454-495`): 404 if not in this warehouse; `systemOwned` → 400 (placements land in storage bins only); `retiredAt !== null` → 400 `bin-retired`; `blocked` → 400 `bin-blocked`.
12. **Capacity gate**: `binOccupancyInTx(target) + scaled.qty > target.capacity` → 400 `bin-full` naming bin, capacity and occupancy (`:496-505`).
13. **Suggestion re-derivation + mismatch reason** (`:506-525`) — see Key algorithms.

Writes: ledger movements (below), one `putaway_placements` row, an `audit_events` row (`action: 'putaway.placed'`, `reference` = the idempotency key), the device heartbeat, and the idempotency key.

Ledger: `putaway.placed`, `fromBinId: receivingBin → toBinId: targetBin`. Non-serial — one event per batch arm carrying `scaled.qty` (`:572-591`). Serial-tracked — `lockSerialsInTx` over the whole sorted set **before the first append** (the `stock.adjustment` deadlock rule), then one magnitude-`QUANTITY_SCALE` event per serial, each still carrying the batch ref (`:544-570`).

Emits outbox `putaway.recorded` (`:640`) with base-unit quantities.

### `bin.blocked` — `BinStateCommand.setBlocked` (`bin-state.command.ts:52`)

Guards: `assertPermission('bin.block')` (`:65`) → replay (`:70`) → `assertWarehouseInTenant` → the bin row locked `.for('update')` (`:95-100`, the `mergeBin` shape — guards run against the locked row *before* any write, so a rejection never depends on an UPDATE rolling back) → **`systemOwned` → 400** (blocking Receiving or QC-hold would drop the warehouse's intake/quarantine out of the flow with no unblock path on the device, `:109-116`) → **`retiredAt !== null` → 409 `bin-retired`**.

Writes `bins.blocked` + `updated_at`. Emits outbox `bin.blocked` and an `audit_events` row (`action: 'bin.blocked'`).

---

## Key algorithms

### Bin suggestion and ranking (`putaway.command.ts:733` / `:768`)

`binCandidatesInTx` is one grouped query: every bin of the warehouse where `blocked = false AND system_owned = false AND retired_at IS NULL`, left-joined to `stock_on_hand`, `occupancy = coalesce(sum(quantity), 0)::bigint`, ordered by **occupancy ascending, then bin code ascending**. Capacity is *shared base-UoM space* — occupancy is the bin's total across every SKU, not per-SKU.

`suggestBinInTx` walks that ordered list and returns the **first** candidate where `occupancy + qty <= capacity`, or `null`. So the rule is: lowest-occupancy bin that fits, ties broken by code. This is the recorded FR-10 v1 deviation — capacity only. No velocity class, no zone affinity, no SKU-to-bin affinity, no nightly job; those ship with the deferred report story (`:727-732`).

The `rationale` string is operator-facing and speaks base units: `Lowest occupancy (o/c) — room for r` (`:748`), or `No storage bin has room for these units` when nothing fits (`putaway.facade.ts:344`).

### Task derivation (`putaway.facade.ts:216-349`)

1. Find the warehouse's Receiving bin **read-only** (`code = 'RECEIVING' AND system_owned = true`). A warehouse that never received anything has no bin and therefore no tasks — return `[]` (`:225-240`). Note this does *not* ensure the bin; only the commands create it.
2. Read every GRN line of the warehouse with `applied_qty > 0`, ordered by GRN code, then line `created_at`, then id — oldest receipt first (`:243-264`).
3. Read the Receiving bin's `stock_on_hand` (per sku) and `batch_on_hand` (per sku+batch) into two maps (`:290-311`).
4. Per line: `remaining = min(line.appliedQty, onHand)` where `onHand` is the batch map's entry for a batch-tracked line and the plain map's otherwise. `remaining <= 0` → no task (already placed, or the stock moved elsewhere). A line whose SKU vanished from the catalog is skipped (`:317-330`).
5. Attach the suggestion by scanning the single pre-fetched `candidates` list for the first fit (`:330`) — one candidate query for the whole page, not one per task.

**Completion is approximate by construction.** The on-hand fold is per `(sku, batch)`, not per GRN line, so when two GRNs carry the same `(sku, batch)` the projection cannot attribute stock to a line. Both lines will report the same `remaining` until enough of it is placed. This is documented at `:193-200` and is the reason the placement command re-checks `min(applied, receiving-bin on-hand)` server-side rather than trusting the task.

### The capacity gate and its two lock layers (`putaway.command.ts:454-505`)

The target bin row is taken `.for('update')` **before** the occupancy read. Without that lock two concurrent placements into the same bin would each read the pre-append occupancy, both pass the gate, then append serially — leaving the bin over capacity. The Receiving-bin *drain* side needs no bin lock; the ledger's own insufficiency guard covers it (a losing race is a 422 `insufficient-on-hand` quarantine, never a corrupted projection).

Lock order is `bins` row → serial locks → the warehouse advisory lock inside the ledger append. No other path locks bin rows first, so the order stays acyclic (`:455-462`). `mergeBin` deliberately takes the *same* bin-row lock (id-sorted for its two rows, `bin.command.ts:503-519`), which is what serializes merges against placements.

### Suggestion re-derivation and the reason-code strip (`putaway.command.ts:506-525`)

The suggestion baked into the device snapshot is **advisory**. At placement the server re-derives it from current state, then:

- `suggestedBinId !== command.toBinId && reasonCode === null` → 400 demanding a code from the fixed enum.
- `suggestedBinId === command.toBinId` → the submitted reason is **stripped to null**, not rejected (`:525`). This is the subtle one: the server's re-derived suggestion legitimately differs from the device's stale task-level suggestion, so an operator who followed *their* screen may arrive carrying a reason for a target that now *is* the server's choice. Rejecting would fail a correct placement; recording the reason would pollute the SM-3 suggestion-vs-actual report with false mismatches.

`recordedReason` (not `command.reasonCode`) is what lands in the row, the ledger `referenceDoc`, and the outbox payload (`:605`, `:537`, `:659`).

### Bin administration and the shared `bins` boundary

`bins` (`schema.ts:201`) is **tenancy-owned master data** written by two modules:

| Writer | Columns | Why |
| --- | --- | --- |
| `src/modules/tenancy/bin.command.ts` | create / grid-generate (`code`, `capacity`, `type`, `zone_id`), `retired_at` + `retired_by` (merge's source retirement at `:701`, retire at `:894`) | Structural master data: what bins exist, and the terminal end of a bin's life. |
| `src/modules/putaway/bin-state.command.ts:123` | `blocked` | **Operational** state: a blocked bin drops out of putaway suggestions and rejects placements the moment it flips. The module that consumes the flag owns the flag. |

And the traffic runs both ways: tenancy's `bin.command.ts:35-42` imports `openQcHoldsForBinsInTx` from **inbound** and `binOccupancyInTx` / `binFull` / `binBlocked` / `binRetiredAsSource` / `binRetiredAsTarget` from **putaway**. Shared rejection helpers common to both sides live in a third file, `src/modules/tenancy/bin.errors.ts` (`binNotFound`, `binRetired409`, `binHoldOpen`), explicitly so there are no verbatim copies (`bin.errors.ts:3-7`).

**How the architecture test permits this.** `test/architecture.spec.ts` does not enforce module boundaries generally — it enumerates specific tables and specific module roots: the stock/ledger set (`:31`), the order/wave/pick set (`:210-224`), and `carrier_connections` (`:375`). For each it asserts "no write outside that module root" and "no sibling reaches past the facade." **`bins` appears in none of those enumerations**, and there is no putaway or tenancy entry at all. So the split is permitted by deliberate omission, not by an exception clause. Two consequences:

- Adding `bins` (or `zones`) to a future `STOCK_TABLES`-style list would immediately fail the build on `bin-state.command.ts`. If a boundary guard is ever wanted here, it must be column-aware, not table-aware.
- The cross-module *imports* are equally unguarded: the facade-reach-through checks are written per-module (`modules/inventory`, `modules/outbound`, `modules/carriers`) and no such check exists for putaway, inbound or tenancy. Importing `binOccupancyInTx` directly is therefore legal today — but it is a file-level pure read-only helper, which is the pattern that keeps it defensible (the same shape as `assertWarehouseInTenant`).

### Merge and retire (in tenancy, reusing this module's primitives)

Recorded here because the rejections and the capacity arithmetic are this module's code.

**`mergeBin` (`bin.command.ts:462`)** — capability `bin.retire`; both bin rows locked `.for('update')` **id-sorted before any arm is read**; guards in order: same-bin, either side system-owned, source retired (`binRetiredAsSource`), target retired (`binRetiredAsTarget`), target blocked (`binBlocked`) — **a blocked *source* is allowed by design, it is the only way to empty a blocked bin** (`:459-461`) — then the open-QC-hold guard (409 `bin-merge-hold-open`), then the all-or-nothing capacity gate `targetOccupancy + movedUnits > target.capacity` → `binFull` (`:656-664`). Arms are enumerated in three shapes matching the projections: serial-tracked SKUs enumerate through `InventoryFacade.serialsLocatedInBinInTx` and **refuse the merge outright if the serial count disagrees with the on-hand projection** (`:596-612`); batch-tracked SKUs enumerate `batch_on_hand` rows; untracked SKUs move on one plain arm. One `bin.merged` event per arm, then the source retires in the same commit — "merge is retire-with-stock."

**`retireBin` (`bin.command.ts:765`)** — one-way and terminal. Guards: `bin.retire` → replay → row locked → system bin 400 → already retired 409 `bin-retired` → **open QC hold 409** → empty gate: every non-zero plain and batch on-hand arm is named in a 400 `bin-not-empty` (`:844-890`). The row is never deleted — the `(warehouse_id, code)` unique index keeps the code reserved forever. `bins_retired_pairing CHECK` (`drizzle/0016_numerous_bloodscream.sql:6`) makes `retired_at`/`retired_by` all-or-nothing.

The QC-hold guard on *retire* is the non-obvious one: the hold has already moved the bin's stock into the QC bin, so the empty gate alone would happily retire it — and then the release could never return the stock to the origin bin it recorded (`bin.command.ts:829-833`).

---

## Invariants

| Invariant | Enforced by |
| --- | --- |
| A placement is a real ledger relocation, never a `stock_on_hand` write. | `InventoryFacade.appendLedgerEventInTx` only; `test/architecture.spec.ts:116` fails the build otherwise. |
| Stock always leaves the system Receiving bin. | `fromBinId` is `ensureReceivingBinInTx`'s bin, never caller-supplied (`putaway.command.ts:436`, `:568`, `:589`). |
| Placements land in storage bins only — never system, retired or blocked bins. | `putaway.command.ts:477-494`. |
| Never over-place a GRN line. | `remaining = min(line.appliedQty, receiving-bin on-hand)` re-derived server-side at every placement (`:447`). |
| A bin never exceeds its capacity. | `.for('update')` on the target row before the occupancy read, then the gate (`:454-503`); the same gate covers merge (`bin.command.ts:657`). |
| The recorded suggestion is the **server's**, at placement time. | `suggestBinInTx` re-derived in-command (`:508`); `suggestedBinId` stored from it, never from the request. |
| A reason code is required exactly when the actual bin differs from the server's suggestion — and stripped when it does not. | `:520-525`. |
| One ledger event per serial unit, batch arm carried on each. | `:544-591`; `putaway.placed` registers `allowsSerialArm: true` (`ledger-registry.ts:266`). |
| Serials are resolved, never created, by a placement. | `resolveSerialRefsInTx` 400s on an unknown number (`:879`). |
| Retirement is terminal; the code stays reserved. | `bins_retired_pairing` CHECK + `bins_warehouse_id_code_unique`; no delete path exists anywhere. |
| System bins can never be blocked, merged or retired. | `bin-state.command.ts:109`; `bin.command.ts:532-541`, `:820`. |
| Retired bins never suggest, never appear in the device snapshot, and refuse as source or target. | `isNull(bins.retiredAt)` in `binCandidatesInTx` (`:796`) and `getBinSummariesInTx` (`putaway.facade.ts:387`); `binRetiredAsTarget`/`binRetiredAsSource`. |
| Quantities are milli-units in the domain, base units at every edge. | `assertRecordableQuantity` on the way in (`:355`); `fromMilli` in the snapshot, the outbox payload, the list read, `binCandidatesInTx`'s rationale, and `bin-state.command.ts:136`. |

---

## Events

**Ledger event type** — `putaway.placed` (`src/modules/inventory/ledger-registry.ts:266`): reference kind `putaway` (`grnId`, `grnLineId`, optional `reasonCode`, optional `suggestedBinId`), `allowsBatchArm: true`, `allowsSerialArm: true`. Both bin arms ride **one** event: the ledger folds `+toBin / −fromBin` from the single magnitude, which is why a relocation is one event and not two.

Adjacent and worth knowing: `bin.merged` (`ledger-registry.ts:286`, reference kind `bin-merge`) is the same relocation shape, emitted by tenancy's merge.

**Outbox types:** `putaway.recorded` (`putaway.command.ts:640`) · `bin.blocked` (`bin-state.command.ts:150`). Merge and retire emit `bin.merged` / `bin.retired` from tenancy.

**Audit rows** (`audit_events`, `reference` = the idempotency key): `putaway.placed` on `targetType: 'putaway_placement'` (`putaway.command.ts:670`) · `bin.blocked` on `targetType: 'bin'` (`bin-state.command.ts:165`).

---

## Gotchas

1. **`getBinSummariesInTx` and `getPutawayTasksInTx` are in-tx only, on purpose.** Their only consumer is the device catalog snapshot, which composes every part on one transaction. Calling a pool-opening facade method from inside the snapshot's own transaction reserves a second pooled connection while holding the first; postgres.js queues connection requests with no timeout, so enough concurrent snapshots deadlock the pool permanently and strand connections at the server (`putaway.facade.ts:208-215`, `receiving.facade.ts:368-379`). If you add a read to the snapshot, add it as an `…InTx` passthrough.

2. **Task `remaining` is approximate when two GRNs share a `(sku, batch)`.** The Receiving-bin fold cannot attribute stock to a line, so both lines show the same remaining until enough is placed (`putaway.facade.ts:193-200`). Never treat a task's `qty` as a reservation; the placement command's own `min(applied, on-hand)` check is the authority.

3. **The bin-row `.for('update')` in the placement command is load-bearing, not defensive.** Remove it and two concurrent placements into one bin both pass the capacity gate and then append serially — over capacity, with no error anywhere (`putaway.command.ts:454-462`).

4. **A stale reason code on a matching target is stripped, not rejected** (`putaway.command.ts:519-525`). Changing this to a 400 breaks correct placements made from a slightly stale snapshot; changing it to "record whatever the client sent" pollutes the SM-3 mismatch report.

5. **The idempotency payload hash fingerprints the RAW serial numbers, never the resolved ids** (`putaway.command.ts:222-225`), and since story 10.2 it is over **base** units (`:205-216`). A key written by a pre-10.2 build answers 422 `idempotency-key-reuse` rather than replaying — deliberate, no compatibility branch, pinned as EXPECTED by the cross-version replay guard in `test/picking.spec.ts`.

6. **`command.qty` must not be read after `scaled` exists** (`putaway.command.ts:353-358`). Everything below that point is milli-units; one stray `command.qty` is a 1000× error that no CHECK catches (`qty > 0` still passes).

7. **The batch on a placement must be the GRN line's own batch** (`putaway.command.ts:396`). Both batches belong to the same SKU and both exist, so nothing but this explicit check stops a placement being recorded against the wrong line.

8. **Serial locks are taken over the whole sorted set before the first append** (`putaway.command.ts:546`) — the `stock.adjustment` deadlock rule. Appending per serial and locking lazily reintroduces the deadlock between two placements that touch overlapping serial sets.

9. **`getPutawayTasksInTx` reads the Receiving bin, it does not ensure it** (`putaway.facade.ts:225-240`). A read must not create master data; a warehouse with no receipts correctly returns no tasks.

10. **The `blocked` toggle keeps tenancy's URL and response shape** (`tenancy.controller.ts:391-407`, returning tenancy's `BinSnapshot`). Only the logic moved. Changing the response shape here is an FE-contract break even though the file lives in this module.

11. **`bins` writes are split by column, but nothing mechanically enforces the split.** No architecture test covers `bins` — see *Bin administration and the shared `bins` boundary*. The convention is the only guard; a `retired_at` write added here, or a `blocked` write added to `bin.command.ts`, would pass CI.
