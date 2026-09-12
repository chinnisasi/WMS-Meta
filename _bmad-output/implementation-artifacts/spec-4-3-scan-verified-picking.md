---
title: 'Story 4.3: Scan-verified picking with offline tolerance'
type: 'feature'
created: '2026-09-12'
status: 'in-review'
route: 'dispatch'
review_loop_iteration: 0
baseline_commit: '877993f' # wms-be main
context:
  - '_bmad-output/implementation-artifacts/epic-4-context.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** 4.2's picklists are inert. Nothing on the floor can act on them, the mobile inbox's Pick tab is a placeholder, and the reserved stock an order holds has no path to actually leaving its bin.

**Approach:** Make a picklist line pickable. The device scans bin then item, the server draws the reserved units through the ledger and settles the hold in one transaction, and the whole flow rides epic 3's offline substrate so a dead zone costs nothing.

**Decided (2026-09-12, human):**
- **Scope split.** AD-14's `state_epoch` and the 4-case conflict taxonomy are their own story, `4-3b-state-epoch-and-conflict-taxonomy`, landing with or before 4.4 (whose short-pick re-planning *is* taxonomy case 3). `state_epoch` has no producer, wire field or comparison contract defined anywhere, and 3.5 deferred it on the reasoning that the ledger's sufficiency guard plus replay re-authorization already covers concurrent divergence. 4.3 ships on exactly that proven behaviour.
- **"Nearest correct bin" means the next bin on this picklist's walk** that holds the expected SKU, by `walkSeq`. Bins carry no spatial data, so a physical "nearest" is unimplementable; next-on-route is both honest and more useful — it is where the operator is heading anyway.
- **Rejected replays quarantine client-side only** — server rejects with a 4xx and full rollback, the client parks the op with session attribution, and it surfaces in the sync summary. No backend rejected-op table; Epic 5's story 5.5 adds the web queue.
- **Banner state-truth follows the spine, and the epic-3 debt is fixed here.** A queued op shows `↻ Recorded · queued`, never green; green `✓` means the server settled it. The same correction applies to the shipped receiving and putaway screens, closing retro F-2. The pick mockup shows green-while-queued; UX-DR24 makes the spine win.

**Decided (technical, from investigation):**
- The op type is **`pick.record`**, never `pick.task` — `src/state/op-dispatch.test.ts` fabricates `'pick.task' as never` to prove its exhaustiveness guard throws, and reusing that string turns the test into a real dispatch.
- Pick tasks reach the device through the **sealed catalog snapshot**, additively, exactly as 3.5 added `putawayTasks`; `parseCatalogSnapshot` defaults the new array so older caches keep parsing.
- Replay stays **strictly FIFO by sequence** (what the client implements today). AD-4's "replays in task order" wording is unresolved against that; 4.3b settles it.

## Boundaries & Constraints

**Always:**
- The pick draw and the hold settlement commit **in one transaction** — the ledger `pick.picked` append and the reservation's `held → committed` together, or neither. This needs an in-tx `commitReservation` passthrough on `InventoryFacade`; the existing one opens its own transaction and cannot nest.
- Stock moves only through the ledger (AD-16) — the pick command never writes `stock_on_hand`. A draw that would overdraw fails `422 insufficient-on-hand` and rolls the whole transaction back, persisting nothing and leaving the idempotency key unconsumed.
- `picklist_lines` gains a `picked` status arm. It must stay **outside `'cancelled'`**, or the `picklist_lines_open_order_line_unique` partial index frees the order for re-waving while it is being picked.
- The bin and batch a line names are **suggestions re-derived server-side at pick time** (the 4.2 decision, the putaway precedent). A scan against a different bin is checked against live stock, not against the plan.
- Device authority is re-read at command entry inside the transaction: device row `FOR UPDATE` fail-closed on non-`active`, then the operator's role (`picks.execute`, new, Operator + Ops Manager + Owner). The badge-in session that created an op is what authorizes its replay — a token is transport, never authority.
- Every mutation carries an `Idempotency-Key` (the op's client ULID) with payload-hash replay; the key commits with the writes, last. Same key + same payload re-serves the original response.
- On-device rejection is **synchronous** — pure resolver functions over the sealed snapshot, no awaits, so the <500 ms budget is structural rather than aspirational. A rejected scan never enters the queue.
- Full-quantity picks only: a line is picked for exactly its planned `qty`. Reservations are whole-quantity rows with no partial commit.

**Never:**
- No `state_epoch`, no 4-case taxonomy, no conflict re-planning (4.3b and 4.4).
- No short-pick — the button, the reason enum, the alternate-bin re-plan (4.4). A line that cannot be picked is simply left unpicked.
- No backend rejected-op or review table; no Conflicts & Reviews surface (Epic 5).
- No pack, dispatch, or order-state transition (4.5/4.6) — picking a line does not advance the order's status.
- No web Outbound surface (`4-2b`).

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Pick a line online | correct bin + item scanned, stock present | `201` pick snapshot; ledger `pick.picked` draws the bin, hold `committed`, line `picked`; outbox + audit | already picked (same key) → replayed snapshot |
| Wrong item scanned | item not on this picklist | rejected on-device in <500 ms, reason names the expected SKU; **nothing queues** | N/A — never reaches the server |
| Wrong bin scanned | bin holds no line of this picklist | rejected on-device, reason + the next walk bin holding the expected SKU | no such bin on the walk → reason only |
| Pick offline | connectivity lost mid-picklist | op queues FIFO, banner `↻ Recorded · queued`, queue chip increments (amber, never an error) | force-quit → queue intact (WAL, synchronous append) |
| Replay after reconnect | N queued picks | replay in enqueue order, each idempotent; settled count in the sync summary | first unreachable stops the drain, tail stays queued |
| Replay of a stale pick | bin drained by another wave before replay | `422 insufficient-on-hand` naming the bin's live on-hand; nothing persists | op quarantines client-side with session attribution, replay continues |
| Replay after revocation | device revoked mid-shift | `403 device-revoked`; that op and the whole tail quarantine with attribution | full-screen revoked state, never silent |
| Serial-tracked line | serials scanned for the drawn units | one ledger event per serial unit, both bin arms | wrong count / duplicate / elsewhere → `400`/`409` naming it |
| Wrong authority | non-operator role, foreign tenant, bare device credential | nothing written | `403 role-denied` / `permission-denied`, `403 badge-in-required` |

</frozen-after-approval>

## Code Map

- `workspace/core/backend/wms-be/src/modules/putaway/putaway.command.ts:186` — `placePutaway` is the command to copy end to end: `hashCommandPayload` before the tx (`:193`), device `FOR UPDATE` fail-closed (`:209-222`), `assertPermission` (`:227`), replay read (`:231-243`), validation-before-writes (`:245`), bin row lock then ledger append (`:415`, `:483`), outbox (`:583`), audit (`:607`), `writeIdempotencyKey` last (`:619`). Lock order bins-row → serial → warehouse is documented acyclic at `:408-413`; keep it.
- `workspace/core/backend/wms-be/src/modules/inventory/ledger.service.ts:266-273` — the sufficiency guard that throws `insufficient-on-hand` (422) and aborts the tx. This *is* 4.3's conflict behaviour; `appendMovement` (`:438-453`) also enforces ledger-registry arms.
- `workspace/core/backend/wms-be/src/modules/inventory/ledger-registry.ts` — `registerLedgerEventType` (`:98`), definition shape (`:79-90`), and the `LedgerReferenceDoc` union (`:19-76`) whose trailing comment already reserves `pick` as a future kind. Needs a `pick` arm + `pick.picked` registration with both batch and serial arms allowed.
- `workspace/core/backend/wms-be/src/modules/inventory/inventory.facade.ts:485` — `commitReservation` opens its **own** transaction (`reservation.service.ts:446`); there is no `commitReservationInTx`. Add one alongside `reservationsByIdsInTx` (`:511`). Committing settles the hold only — it does not move stock and leaves the Valkey counter untouched (`reservation.service.ts:437-441`).
- `workspace/core/backend/wms-be/src/modules/outbound/wave.command.ts:141-165` — `PicklistLineSnapshot`; status arms at `:38-48`. `PICKLIST_LINE_STATUSES` gains `picked`. The partial unique index is `schema.ts:1651-1654`.
- `workspace/core/backend/wms-be/src/api/putaway.controller.ts:76-81` — the device-route entry trio: `assertOwnTenantToken` → `badgeInRequired()` when `session.userId === null` → `parseRequiredIdempotencyKey`. `DeviceSessionGuard` + `CurrentDeviceSession` at `src/modules/tenancy/device-session.guard.ts:16,34`.
- `workspace/core/backend/wms-be/src/api/devices.controller.ts` — `GET .../devices/catalog-snapshot` is the sealed offline surface; add `pickTasks` additively beside `bins`/`putawayTasks`.
- `workspace/core/mobile/wms-mobile/src/putaway/draft.ts` + `app/putaway.tsx` — the flow template: pure draft module (`createPutawayDraft` `:60`, `resolveBinBarcode` `:89`, `verifyTaskSku` `:108`, `evaluateBin` `:151`, `confirmPayload` `:191`) plus one screen wiring `onScanEvent` (`app/putaway.tsx:101`). Synchronous resolvers are what buy the <500 ms budget.
- `workspace/core/mobile/wms-mobile/src/offline/engine.ts:21` — `replayOutbox(store, send, attribution)`; FIFO by `seq`, `break` on first unreachable (`:66`), revoked quarantines the tail (`:48-64`). `src/offline/types.ts:15` — widen `OpType`.
- `workspace/core/mobile/wms-mobile/src/state/op-dispatch.ts:21,42,44-72` — `OpSenders`, `defaultOpSenders`, and the `const exhaustive: never` guard that fails to compile until the new arm is added. **`op-dispatch.test.ts:117-128` fabricates `'pick.task' as never`** — do not name the op that.
- `workspace/core/mobile/wms-mobile/app/inbox.tsx:24,94-118` — `TASK_TABS` already contains `'Pick'`, currently rendering the "task types arrive with later epics" placeholder; the sync summary is inline JSX at `:140-162`.
- `workspace/core/mobile/wms-mobile/src/components/scan-banner.tsx:28` + `src/theme.ts:82` — the four banner states. `queued` must read `Recorded · queued`; `app/receive.tsx` and `app/putaway.tsx` carry the wording to correct.
- `workspace/core/mobile/wms-mobile/src/state/catalog-snapshot.ts:11` — `parseCatalogSnapshot` defaults missing arrays; the new `pickTasks` array defaults here.
- Tests: `wms-be test/putaway.spec.ts:797-850` (the stale-op-behind-the-advisory-lock proof) and `test/waves.spec.ts` fixtures; `wms-mobile src/offline/engine.test.ts:116` (cross-type FIFO — the template for a `pick.record` replay test), `src/putaway/draft.test.ts`.

## Tasks & Acceptance

**Execution:**
- [x] `wms-be drizzle/0019_*.sql` — `picks` table (the settlement record) + the `picked` arm on the `picklist_lines` status CHECK + hand-appended RLS
- [x] `wms-be src/shared/db/schema.ts` — the `picks` table per conventions
- [x] `wms-be src/modules/inventory/ledger-registry.ts` — the `pick` reference-doc arm + `pick.picked` registration (batch and serial arms allowed)
- [x] `wms-be src/modules/inventory/inventory.facade.ts` — `commitReservationInTx` passthrough
- [x] `wms-be src/modules/outbound/pick.command.ts` — `recordPick`: device authority, replay, validation, bin lock, ledger draw + hold commit in one tx, line flip, outbox, audit, key
- [x] `wms-be src/modules/tenancy/permissions.ts` — `picks.execute` (Operator + Ops Manager + Owner)
- [x] `wms-be src/api/outbound.controller.ts` + `devices.controller.ts` — `POST .../picks` (device-gated) and `pickTasks` on the catalog snapshot
- [x] `wms-be test/picking.spec.ts` — the matrix e2e including the stale-replay 422 and the serial arm
- [x] `wms-mobile src/picking/draft.ts` — pure resolvers: bin, item, expected-SKU verification, the next-walk-bin hint, `confirmPayload`
- [x] `wms-mobile app/pick.tsx` + `app/inbox.tsx` — the pick flow and the task list replacing the placeholder
- [x] `wms-mobile src/offline/types.ts`, `src/state/op-dispatch.ts`, `src/api.ts`, `src/state/catalog-snapshot.ts` — the `pick.record` op end to end
- [x] `wms-mobile src/components/scan-banner.tsx` + `app/receive.tsx` + `app/putaway.tsx` — `Recorded · queued` wording, closing retro F-2
- [x] `wms-mobile src/picking/draft.test.ts` + `src/offline/engine.test.ts` — resolver arms and a `pick.record` FIFO replay test
- [x] `wms-be bun run openapi:export` + `wms-fe bun run api:generate` — additive contract

**Acceptance Criteria:**
- Given a released picklist, when the correct bin and item are scanned, then the ledger draws those units, the hold reads `committed` and the line reads `picked` — all from one transaction
- Given connectivity is lost, when picks continue, then each queues FIFO showing `Recorded · queued`, the app survives force-quit with the queue intact, and reconnect replays them in order exactly once
- Given a queued pick whose bin drained before replay, when it replays, then it fails `422 insufficient-on-hand`, persists nothing, and quarantines client-side with session attribution while the rest of the queue continues
- Given a wrong-item or wrong-bin scan, then it is rejected on-device without queuing, naming the expected SKU and the next walk bin that holds it

## Implementation Notes

**Landed as** WMS-BE #24 (backend), WMS-Mobile #4 (device), WMS-FE #16 (client regeneration), in that merge order.

**The one transaction.** `PickCommandService.recordPick` composes the `pick.picked` ledger append and the reservation's `held → committed` through two `InventoryFacade` in-tx passthroughs (`appendLedgerEventInTx`, the new `commitReservationInTx`), so both land in the caller's `withTenantTransaction` or neither does. The outbound module still writes no inventory table — the architecture test pins that (`the pick command moves stock ONLY through the inventory facade`).

**A pick is a pure draw.** `fromBinId` is the bin the operator scanned, `toBinId` is null, the delta is negative. The frozen matrix's serial row says "both bin arms", which is carried over from the putaway relocation; a pick has no destination bin in this story (pack/dispatch are 4.5/4.6 and the Never list excludes them), so inventing a staging bin would be scope the story rejects. The serial arm is therefore one magnitude-1 draw event per unit, with the batch arm riding each event — both projections drain, and the ledger's own `serial-elsewhere` guard still decides location truth.

**The hold settles on the LAST slice.** An order line whose reserved quantity spans two bins emits two picklist slices that share one `reservation_id`, and a reservation is a whole-quantity row with no partial commit. Committing on the first slice would settle units still sitting in the other bin, so the command settles only when no sibling slice of that order line is still `planned`. `picks.reservation_committed` records which pick did it (with a CHECK pairing it to a non-null `reservation_id`).

**`cancelWave` no longer touches picked lines.** Story 4.2's cancel flipped *every* line of the wave to `cancelled`, which is exactly what frees its orders through the partial unique index. With a `picked` arm that would free an order line whose units have already left the bin, so the flip now excludes `picked`. This is the same invariant the spec states from the other side ("it must stay outside `'cancelled'`") — the status arm alone was not enough; the cancel path had to stop overwriting it.

**The batch is re-derived, not carried.** The device sends no `batchId` at all. The server re-derives the FEFO arms inside the bin that was actually scanned, against live `batch_on_hand` and the catalog's batch status/expiry (a blocked or expired batch is never drawn — epic-2 retro a13's draw side). Expiry is judged against the op's own `occurredAt`, so a pick queued before a batch expired is not re-judged at replay. A draw spanning several batches emits one event per arm; the pick row then records `batch_id` null (the arms are on the events).

**"Nearest correct bin" = next on the walk.** `nextWalkBinFor` returns the next stop by `walkSeq` carrying the expected SKU, falling back to the first such stop when the operator has walked past it, and null when the walk carries none (the rejection then names the reason only). A bin that is *another stop of the same walk for the same SKU* is not rejected — it passes as `offPlan`, because the plan's bin is a suggestion and the server re-checks live stock.

**Rejected replays.** The engine now stamps session attribution on `rejected` outcomes and continues the drain past them (the tail is not blocked). The outcome stays in the summary's `rejected` bucket rather than `quarantined`: `quarantined` is the revocation semantics (the whole tail stranded, the device dead), and a 422 stale pick is a single refused op the operator can re-record. "Quarantines client-side only" is honoured in the sense the decision names — parked on the device, surfaced in the sync summary, with no backend rejected-op table.

**Retro F-2 closed.** `scanStates.queued.word` is now `Recorded · queued`; `app/putaway.tsx`'s bin-mismatch banner stopped using the green `accepted` state for an on-device decision. `app/health.tsx` keeps the amber fill for its pending probe but overrides the word to `Checking` — it records nothing, so the queue vocabulary would be a lie there.

**Two non-determinism defects found in review, and their root causes.** Both were invisible on a warm database and reproducible on a fresh one.

*The device catalog snapshot was nesting transactions.* `getCatalogSnapshot` already held a tenant transaction and then called three facade reads inside `Promise.all` that each opened their own — four pooled connections per request (measured: peak 4 on this branch, 3 on main). postgres.js queues connection requests with no timeout, so past `max / 4` concurrent snapshots every outer transaction waited forever for a nested one that could never be granted: a permanent deadlock whose stranded server-side connection outlived the request *and* the suite that caused it, which is why arbitrary later suites failed. The three reads now ride in-tx passthroughs (`getBinSummariesInTx`, `getPutawayTasksInTx`, `getPickTasksInTx` — the `reservationsByIdsInTx` shape), peak 4 → 2, and the sealed snapshot becomes one consistent read rather than four MVCC snapshots stitched together. Residual, pre-existing and untouched: `catalog.getSkuSummaries` still opens its own transaction, but sequentially rather than as fan-out, so the peak stays 2.

*The picking suite's replay assertions were time-dependent.* `pick()` minted `occurredAt` per call, truncated to whole seconds, so a same-key "replay" sent a **different payload** whenever the two requests straddled a second boundary and the server correctly answered `422 idempotency-key-reuse`. Proven deterministically: with a forced 1.1 s gap the old helper fails `expected 201, got 422`, the fixed one passes. `bodyFor()` now stamps the time once and replay tests re-post the same object — which is what the device does anyway, since a queued op stamps `occurredAt` at enqueue and replays those bytes.

**The snapshot's `pickTasks` is composed at the api SHELL, not inside `ReceivingFacade`.** The first attempt had `InboundModule` import `OutboundModule` so the receiving facade could call `OutboundFacade` inside its own transaction. That edge — not any query — turned out to be the trigger for a cross-suite flake: with it, `test/receiving.spec.ts` fails roughly 1 run in 29 **in isolation** (3 failures across ~87 fresh runs), always as a bare `200` carrying the wrong or an empty body on some unrelated route, and always vanishing the moment any diagnostic is attached. `main` is 30/30 clean on the identical loop; stubbing the edge out is 50/50 clean; composing at the shell instead is 50/50 clean with the feature intact. The controller now calls `receiving.getCatalogSnapshot(...)` and `outbound.getPickTasks(...)` sequentially and merges — the AD-6 cross-facade-at-the-shell pattern story 2.4 established for the adjustment's batch/serial arms. Each read is one transaction on one connection, taken after the other has been released. **The underlying reason a module-graph edge perturbs request handling is not established** — the evidence is causal, not mechanistic, and it is recorded here so the next person does not re-derive it.

**The last nested transaction in the snapshot is gone.** `catalog.getSkuSummaries` still opened its own; it now has an in-tx passthrough like the other three. Measured peak concurrent tenant transactions for one snapshot request: **3 on `main` → 2 after the first de-nesting pass → 1 now.**

**The pick-task read is bounded and indexed.** It runs inside the snapshot every device refreshes, so it is capped at `MAX_SNAPSHOT_PICK_TASKS` (500) stops and truncated on **picklist boundaries** — a half-delivered walk would make `nextWalkBinFor` point at a stop the snapshot does not contain. Migration `0020` adds a PARTIAL `picklist_lines_pickable_walk_idx (tenant_id, picklist_id, walk_seq, id) WHERE status = 'planned' and bin_id is not null` (it holds open floor work only, so it does not grow with picking history, and its column order serves the walk-order sort) plus `picklists_tenant_warehouse_status_idx` and `waves_tenant_status_idx`. EXPLAIN confirms the partial index drives the plan with PK joins and no sequential scans.

**Not done / deliberate:** the `picks.execute` capability is NOT mirrored into `wms-fe src/lib/users.ts` — the FE mirror is already missing `orders.manage` / `waves.manage` (deferred to `4-2b`), there is no web pick surface in this story, and `picks.execute` is a device capability. It belongs with `4-2b`'s mirror pass.

## Spec Change Log

**2026-09-12 — code-map corrections found during implementation (no scope change):**
- The sealed catalog snapshot is served by `src/api/receiving.controller.ts:119` and composed in `src/modules/inbound/receiving.facade.ts`, not `devices.controller.ts` (the Code Map named the wrong file). `pickTasks` was added there, additively beside `bins`/`putawayTasks`, with `InboundModule` now importing `OutboundModule` (acyclic — outbound imports shared/inventory/catalog only).
- The banner's `queued` word lives in `src/theme.ts`'s `scanStates`, which `src/components/scan-banner.tsx` renders; changing it there also reaches `app/health.tsx`, whose pending arm now overrides the word to `Checking` (a health probe records nothing).
- The I/O matrix's serial row says "both bin arms". A pick has no destination bin in this story, so it ships as a pure draw (`fromBinId` = the scanned bin, `toBinId` null), one magnitude-1 event per serial unit with the batch arm carried. See Implementation Notes.
- Story 4.2's `cancelWave` had to change: it flipped every line to `cancelled`, which would have freed an order line whose units were already drawn. It now excludes `picked` lines.

## Review Triage Log

_Three layers (blind hunter, edge cases, verification gaps) — 2026-09-12. Verification-gap findings arrive pre-verified; every other claim was re-checked against the source before grading._

| # | Finding | Verdict | Evidence | Route |
|---|---------|---------|----------|-------|
| 1 | `cancelOrder` was never hardened against picked lines, though `cancelWave` was | high | Confirmed: `grep picked` in `order.command.ts` returns nothing, while `wave.command.ts:873` carries `status <> 'picked'`. The hold settles only on the LAST slice, so an order with one drawn slice still holds a `held` reservation — cancel releases it while those units have physically left the bin. Phantom stock, in the overselling direction | patch |
| 2 | Snapshot truncation returns ZERO pick tasks when one picklist alone exceeds the ceiling | high | Confirmed at `pick.command.ts:837-846`: when every kept row belongs to `lastWhole`, the filter yields `[]`. Reachable today — a `batch` policy makes one picklist for up to 200 orders. Every device in that warehouse would see an empty walk with no way to work it down. Introduced by the truncation I asked for | patch |
| 3 | Two slices of one order line picked concurrently leave the hold `held` forever | medium | Both transactions read the sibling as still `planned` under snapshot isolation, so neither commits. No `FOR UPDATE` on the sibling read at `pick.command.ts:571-585`. ATP stays short permanently | patch |
| 4 | A batch+serial-tracked pick can attribute the wrong batch to each serial | medium | Confirmed: arms map to serials positionally (`batchPerUnit[index]`), `serials` carries no `batch_id`, and the ledger validates only serial location. `batch_on_hand` mis-folds. The combined arm is also untested — `PCK-SERIAL` is `batch_tracked=false`, `PCK-FEFO` is `serial_tracked=false` | patch |
| 5 | `picks` ships with RLS and two CHECKs unprobed; the suite provisions `wms_rls_probe` and never connects as it | high | Dropping the policy from `0019` leaves the whole suite green — every read in `picking.spec.ts` goes through the owner connection, which bypasses RLS. 4.2 shipped exactly this probe for its tables | patch |
| 6 | The `serials: null` body the device sends on every untracked-SKU pick is never posted in a test | high | Removing the controller's `?? undefined` makes `[...null]` throw, 500-ing 100% of non-serial picks from the floor — and all twelve tests still pass, because none puts the key in the body. `putaway.spec.ts:1030` is the precedent that exists precisely for this | patch |
| 7 | `commitInTx`'s not-held arm is untested — the expired-hold case an offline queue routinely produces | high | Deleting `eq(reservations.state,'held')` from the WHERE lets an `expired` hold be silently re-committed, violating AD-12's single-terminal-transition rule, and both settlement tests still pass because both supply a `held` row | patch |
| 8 | A FEFO draw spanning two batch arms is never exercised | medium | The one batch test draws 4 from a 6-unit batch — a single arm. Making the allocation loop `break` after the first arm would under-draw stock while recording the full qty, and every test still passes | patch |
| 9 | The truncation branch is unreachable from every test | medium | No fixture approaches 500 rows; the branch can be arbitrarily broken with the suite green. It also hides #2 | patch |
| 10 | The mobile legacy-snapshot default for `pickTasks` is unasserted | medium | `device-store.test.ts:30` uses `toMatchObject`, which ignores absent keys; deleting the `?? []` leaves both tests green while any device that upgraded without refreshing its seal crashes on `[...catalog.pickTasks]` — the exact case the line exists for | patch |
| 11 | Sync-summary attribution is read at REPLAY time, not enqueue time | medium | Confirmed: `QueuedOp` stores no operator or session; `device-store.ts` builds attribution from the current snapshot. After a badge change the summary names the wrong operator, contradicting UX-DR17's "session attribution preserved" | patch |
| 12 | The engine's new comment claims rejected ops are "parked CLIENT-SIDE" — the code deletes them | medium | Confirmed at `engine.ts:39-55`: the op is filtered out of `remaining` and `replaceOps` drops it from the durable outbox. Only the in-memory `lastSummary` survives. The behaviour is pre-existing epic-3; the false comment is new | patch |
| 13 | `Stop {walkSeq + 1} of {walk.length}` misreports once stops are picked | medium | `walkSeq` is the plan-time index over ALL slices; `walk.length` counts only unpicked ones. After 3 of 5 stops the header reads "Stop 4 of 2" | patch |
| 14 | The device never marks a stop consumed locally after enqueueing | medium | `app/pick.tsx` returns with the cached snapshot untouched, so offline the same stop can be taken twice; the second replay 409s and is dropped — avoidable churn on the path the story calls decided-on-device | patch |
| 15 | `binCode: row.binCode ?? ''` masks a broken stop | medium | `picklist_lines.bin_code` is nullable while `PickTaskDto.binCode` is not, and `resolveBinBarcode` matches exact codes — a stop with a bin that can never be scanned, rendering blank | patch |
| 16 | Two dead facade methods, both the pool-opening wrappers whose nesting caused the deadlock | medium | `OutboundFacade.getPickTasks` has no caller, and the `…InTx` switch orphaned `PutawayFacade.getBinSummaries`. Leaving them invites the exact re-introduction the fix documents | patch |
| 17 | `deriveBatchArms` reads every bin's batch stock to answer about one bin | medium | `batchOnHandByBinsInTx(tx, tenant, warehouse, [skuId])` then filters `binId` in JS, on the transaction-holding pick path | patch |
| 18 | `putaway.facade.ts` left bare lone blocks from the de-nesting refactor | low | A `no-lone-blocks` wart that makes both hunks unreadable as diffs | patch |
| 19 | `stopCount` names two different things | low | `PickTaskDto.stopCount` is distinct bins post-truncation; the picklist's is a line count. `WalkPicker` falls back between them, so the header can disagree with the list beneath it | patch |
| 20 | Pick-receipt DTO drift (server omits `suggestedBatchCode`; the client type drops seven fields) | low | Asymmetric on a field whose purpose is suggestion-vs-actual readability; this is the idempotent replay receipt and the two shapes should move together | patch |
| 21 | `PickCommandService.getPickTasks` takes a `tx` but omits the `…InTx` suffix, and shares its name with the pool-opening facade method | low | Opposite connection semantics, identical name — the confusion that produced the deadlock | patch |
| 22 | A test title promises three bin gates and exercises one | low | `'blocked, retired and system bins are unpickable'` covers `blocked` plus a 404; the retired and system arms never run | patch |
| 23 | Rejected ops are unrecoverable after an app restart | medium | Real, and it means a physically-picked item can vanish from every record — UX-DR17 says physical picks are never silently written off. But the behaviour predates 4.3 (epic 3's engine) and the frozen decision explicitly chose "exactly what epic 3 built", listing the durability gap as a known con | defer |
| 24 | `occurredAt` is trusted from the device with no skew bound | medium | A skewed clock or a long-queued op can judge batch expiry wrongly. Pre-existing: `putaway.place` trusts device time the same way (AD-1), so fixing it here alone would make the two flows disagree | defer |
| 25 | The hold commits while `unfulfillable` sibling slices are outstanding | medium | Real and unpinned by any test, but it is the 4.4 boundary: partial settlement needs the partial-commit machinery reservations do not have. Record it rather than invent a half-measure here | defer |
| 26 | Rejected-but-retryable codes (409 concurrent, 422 insufficient) are deleted from the outbox rather than retried | medium | Pre-existing epic-3 replay semantics, not introduced here; changing it alters every flow's replay contract and belongs with 4.3b's taxonomy work, which is where retryability is actually classified | defer |
| 27 | The device refuses an off-plan bin the server would accept | low | By design in this story — the on-device gate mirrors the plan, and the spec's Never list excludes re-planning. 4.4 owns alternate-bin picking | rejected |
| 28 | "devices.controller.ts unchanged" contradicts the task list | low | The task named the file loosely; `pickTasks` is composed in `receiving.facade.ts`, which is where the snapshot lives. No defect | rejected |


## Design Notes

**Why the draw and the commit must share a transaction.** The reservation is what makes the units this order's; the ledger event is what moves them. Split across two transactions, a crash between them either frees stock that has physically left the bin (overselling it) or holds stock that was never drawn. `commitReservation` opening its own transaction is the single reason a passthrough is needed — the 4.1 grant path could not nest for the same reason and solved it by ordering, but a pick has no fail-safe ordering available: both directions of a half-completed pick are wrong.

**Why 4.3 needs no epoch.** A pick that replays against a drained bin is caught by the ledger's fold guard, which refuses to write a negative on-hand and aborts the transaction whole. Nothing persists, the idempotency key is never consumed, and the client parks the op. That is a correct, fail-closed outcome for every conflict this story can produce — `state_epoch` earns its keep when a conflict needs *classifying* (settle vs re-plan vs quarantine), which is exactly what 4.4's short-pick re-planning introduces.

## Verification

**Commands:**
- `cd workspace/core/backend/wms-be && bun run test && bun run lint && bun run typecheck && bun run build && bun run db:migrate && bun run db:verify`
- `cd workspace/core/mobile/wms-mobile && bun run test && bun run typecheck`
- `cd workspace/core/frontend/wms-fe && bun run test && bun run lint && bun run typecheck && bun run build` — stays green after `api:generate`
