---
title: 'Story 4.3: Scan-verified picking with offline tolerance'
type: 'feature'
created: '2026-09-12'
status: 'ready-for-dev'
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
- [ ] `wms-be drizzle/0019_*.sql` — `picks` table (the settlement record) + the `picked` arm on the `picklist_lines` status CHECK + hand-appended RLS
- [ ] `wms-be src/shared/db/schema.ts` — the `picks` table per conventions
- [ ] `wms-be src/modules/inventory/ledger-registry.ts` — the `pick` reference-doc arm + `pick.picked` registration (batch and serial arms allowed)
- [ ] `wms-be src/modules/inventory/inventory.facade.ts` — `commitReservationInTx` passthrough
- [ ] `wms-be src/modules/outbound/pick.command.ts` — `recordPick`: device authority, replay, validation, bin lock, ledger draw + hold commit in one tx, line flip, outbox, audit, key
- [ ] `wms-be src/modules/tenancy/permissions.ts` — `picks.execute` (Operator + Ops Manager + Owner)
- [ ] `wms-be src/api/outbound.controller.ts` + `devices.controller.ts` — `POST .../picks` (device-gated) and `pickTasks` on the catalog snapshot
- [ ] `wms-be test/picking.spec.ts` — the matrix e2e including the stale-replay 422 and the serial arm
- [ ] `wms-mobile src/picking/draft.ts` — pure resolvers: bin, item, expected-SKU verification, the next-walk-bin hint, `confirmPayload`
- [ ] `wms-mobile app/pick.tsx` + `app/inbox.tsx` — the pick flow and the task list replacing the placeholder
- [ ] `wms-mobile src/offline/types.ts`, `src/state/op-dispatch.ts`, `src/api.ts`, `src/state/catalog-snapshot.ts` — the `pick.record` op end to end
- [ ] `wms-mobile src/components/scan-banner.tsx` + `app/receive.tsx` + `app/putaway.tsx` — `Recorded · queued` wording, closing retro F-2
- [ ] `wms-mobile src/picking/draft.test.ts` + `src/offline/engine.test.ts` — resolver arms and a `pick.record` FIFO replay test
- [ ] `wms-be bun run openapi:export` + `wms-fe bun run api:generate` — additive contract

**Acceptance Criteria:**
- Given a released picklist, when the correct bin and item are scanned, then the ledger draws those units, the hold reads `committed` and the line reads `picked` — all from one transaction
- Given connectivity is lost, when picks continue, then each queues FIFO showing `Recorded · queued`, the app survives force-quit with the queue intact, and reconnect replays them in order exactly once
- Given a queued pick whose bin drained before replay, when it replays, then it fails `422 insufficient-on-hand`, persists nothing, and quarantines client-side with session attribution while the rest of the queue continues
- Given a wrong-item or wrong-bin scan, then it is rejected on-device without queuing, naming the expected SKU and the next walk bin that holds it

## Implementation Notes

## Spec Change Log

## Review Triage Log

## Design Notes

**Why the draw and the commit must share a transaction.** The reservation is what makes the units this order's; the ledger event is what moves them. Split across two transactions, a crash between them either frees stock that has physically left the bin (overselling it) or holds stock that was never drawn. `commitReservation` opening its own transaction is the single reason a passthrough is needed — the 4.1 grant path could not nest for the same reason and solved it by ordering, but a pick has no fail-safe ordering available: both directions of a half-completed pick are wrong.

**Why 4.3 needs no epoch.** A pick that replays against a drained bin is caught by the ledger's fold guard, which refuses to write a negative on-hand and aborts the transaction whole. Nothing persists, the idempotency key is never consumed, and the client parks the op. That is a correct, fail-closed outcome for every conflict this story can produce — `state_epoch` earns its keep when a conflict needs *classifying* (settle vs re-plan vs quarantine), which is exactly what 4.4's short-pick re-planning introduces.

## Verification

**Commands:**
- `cd workspace/core/backend/wms-be && bun run test && bun run lint && bun run typecheck && bun run build && bun run db:migrate && bun run db:verify`
- `cd workspace/core/mobile/wms-mobile && bun run test && bun run typecheck`
- `cd workspace/core/frontend/wms-fe && bun run test && bun run lint && bun run typecheck && bun run build` — stays green after `api:generate`
