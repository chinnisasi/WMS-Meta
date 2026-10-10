---
title: 'Fix: a new or cold warehouse takes orders without a restart — ATP self-arms its reservation counters'
type: 'bugfix'
created: '2026-10-10'
status: 'ready-for-dev'
route: 'dispatch'
review_loop_iteration: 0
context:
  - 'docs/design/SYSTEM-DESIGN.md'
  - 'docs/design/IMPLEMENTATION-GUIDE.md'
  - 'docs/design/modules/inventory.md'
  - 'docs/design/modules/replenishment.md'
  - 'docs/design/modules/outbound.md'
  - '_bmad-output/implementation-artifacts/epic-21-retro-2026-10-10.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** The epic-21 retro (A2, finding R1) found that a warehouse created after the backend starts cannot take orders: `POST …/outbound/orders` answers 503 `reservation-store-unavailable` ("counters are being (re)built from the journal — ATP is unavailable, not zero"), and nothing ever heals it.
- `ReservationService.atp` fails closed when the warehouse's ready marker is missing (`reservation.service.ts:796-802`).
- Only `rebuildCounters` arms the marker (`:913`). It is reached by:
  - the startup rebuild, which targets only warehouses that already have reservations or stock (`:417-423`, `:854-871`);
  - the parity pass, which sees only scopes with live reservations;
  - the not-ready *grant* repair (`:1110-1120`).
- Order intake reads ATP (`order.command.ts:1192`) before it ever grants, so the repair is never reached.

**Who hits it:**
- every newly created warehouse;
- a stock-less warehouse even after a restart;
- every warehouse after a Valkey flush;
- the replenishment sweep and channel availability sync. This is PENDING `replenishment` "Cold-scope bootstrap gap".

**Approach:**
- A not-ready ATP read repairs the warehouse from the journal itself — the rebuild the grant path already triggers — and then answers the same request.
- **Every rebuild of one warehouse is single-flight**, whoever starts it (an ATP read, a grant repair, the parity pass, startup, or the facade). Overlapping rebuilds can no longer clobber each other's counters.
- A repair that fails backs off briefly instead of retrying on every read.
- No migration, and no new dependency from tenancy to inventory.

## Boundaries & Constraints

**Always:**
- **Single-flight inside `rebuildCounters`.**
  - Its per-target body moves to a private `rebuildWarehouse(tenantId, warehouseId)`.
  - `ReservationService` keeps an in-process `inFlight: Map<"tenant:warehouse", Promise<ReservationRebuildReport>>`. `rebuildCounters` loops its targets as today, but for each target either joins the in-flight promise or starts `rebuildWarehouse` and stores it. The entry is deleted in `finally`.
  - Every existing caller therefore shares it unchanged: `onModuleInit`, `parityPass` `:1058`, the facade `rebuildReservationCounters`, and the grant repair.
  - The disarm → seed → correction → arm order **inside** `rebuildWarehouse` is unchanged. So are `rebuildCounters`' signature, targets and return value.
- **`ensureReady(tenantId, warehouseId, trigger: 'atp' | 'grant'): Promise<boolean>`** (private). In order:
  1. If a *failure backoff* entry for the warehouse is younger than `READY_REPAIR_BACKOFF_MS = 5000`, return `false` without rebuilding.
  2. If no rebuild is in flight, **re-check `isReady`** (double-checked). If true, return true without rebuilding.
  3. Otherwise call `rebuildCounters(tenantId, warehouseId)`, which joins or starts the shared flight.
  4. On success, clear any backoff and return the fresh `isReady`.
  5. On a throw, record the backoff, log **once per backoff window** (tenant, warehouse, trigger, error), and return `false`. It never throws.
- **`atp()`.** When `isReady` is false, it calls `ensureReady(…, 'atp')`.
  - `true` → **re-run the Postgres input transaction** (on-hand, QC-held, in-transit, buffer), then continue the normal read.
  - `false` → throw exactly today's `reservationStoreUnavailable(...)` (same code, status and detail).
  - A Valkey error on `isReady` stays the existing `valkeyDown` path; there is no repair.
- **The grant's not-ready branch** (`runGrantScript` `:1110-1120`, which serves both `grant` `:517` and `increaseStandingBuffer` `:1860`) calls `ensureReady(…, 'grant')`, **ignores its result**, and still returns `store-down` for that request. There is no retry, and grant semantics are unchanged.
- **Callers pass a validated warehouse.** `atp` does not check the warehouse exists; a read for an unknown UUID would now arm a ready key for it. All current callers validate first. Record this as an invariant in `inventory.md`.
- **New test file `test/cold-warehouse-intake.spec.ts`.** HTTP, real Postgres and Valkey, no `rebuildReservationCounters` call, and the reaper and parity job not scheduled (their env gates unset; assert it).
  - **New warehouse.** Create a warehouse over HTTP after app start, receive stock the suites' usual way, `POST` an order → 201 with a reservation.
  - **Stock-less.** The facade ATP read on a new warehouse → ATP 0.
  - **Flushed.** `DEL` the ready key, then the next order → 201.
  - **Concurrent cold, 5 reads.** Spy `rebuildCounters`/`rebuildWarehouse` with a `mockImplementation` gated on a test-held deferred, so all five overlap. Exactly one `rebuildWarehouse` runs, and all five answer.
  - **Grant + read.** Hold the gate, fire a grant until the spy is called once, then fire a read and release. One rebuild; the grant is store-down, the read answers.
  - **Parity + read.** Start a facade or parity rebuild under the gate, fire a read and release. One rebuild, and a grant committed in between is not lost: the counter equals the journal sum.
  - **Repair fails.** Force `rebuildWarehouse` to throw. The read is 503 with today's detail; `Logger.prototype.error` (or the instance's `logger`) is called once. K = 5 further reads inside 5 s run **no** rebuild. After the backoff (fake clock or an injectable `now`), one more attempt is made.
  - **Sweep.** A replenishment policy on a new warehouse; `ReplenishmentFacade.sweepScope` called directly (the worker is env-gated) → `evaluated > 0`, no throw.
- **Existing tests change.** `test/reservations.spec.ts:594-625` and `:678` asserted the fail-closed read.
  - `:594` now asserts the read rebuilds and answers `{onHand: 2, reserved: 1, atp: 1}`. It proves the grant's store-down arm separately: delete the key again, and the grant → 503 with the spy called once.
  - `:678` proves `onModuleInit` rebuilds, with a spy that attributes the call to init.
- **Comments.** Reword the "cold-start bootstrap" comments in the test files that say the rebuild call is *needed* for readiness (grep finds 11). The call may stay as a state reset.

**Never:**
- arming the marker outside `rebuildWarehouse`;
- arming it at warehouse creation, or wiring tenancy to inventory;
- changing the grant or release Lua scripts or the marker key;
- a Valkey-side lock;
- a grant retry in the same request;
- treating a failed repair as ATP 0;
- widening the startup or parity discovery.

## I/O & Edge-Case Matrix

| Scenario | State | Expected | Error |
|---|---|---|---|
| New warehouse | Created after start, stock received | The first order is 201 and reserves | — |
| Stock-less | New warehouse, no stock | ATP read → 0 | — |
| Flushed | The ready key deleted | The next order rebuilds, then succeeds | — |
| Concurrent cold | 5 overlapping reads | One rebuild; all answer | — |
| Grant + read | A not-ready grant overlapping a read | One rebuild; the grant is store-down, the read answers | — |
| Parity + read | A parity or facade rebuild in flight, plus a read | One rebuild; no increment lost | — |
| Repair fails | `rebuildWarehouse` throws | — | 503, today's detail; one log; no rebuild for 5 s |
| Valkey down | `isReady` throws | — | Unchanged `valkeyDown` path |
| Sweep | `sweepScope` over a fresh warehouse with a policy | The scope is evaluated | — |

</frozen-after-approval>

## Code Map

Paths are relative to `workspace/core/backend/wms-be`.

- `src/modules/inventory/reservation.service.ts`:
  - `atp` `:771-830` (inputs transaction `:775-788`, not-ready throw `:796-802`, per-SKU heal `:808-816`);
  - `rebuildCounters` `:849-920` (targets `:854-871`, the per-target body `:875-920` → `rebuildWarehouse`);
  - `onModuleInit` `:413-435`;
  - `parityPass` `:1002-1060` (its rebuild `:1058`);
  - `runGrantScript` not-ready `:1110-1120`, serving `grant` `:517` and `increaseStandingBuffer` `:1860`;
  - `channelVisibleQuantity` `:2092-2101`;
  - fields `:397-404`. The class is a default-scope singleton (`:395`).
- `src/modules/inventory/inventory.facade.ts:1525` (`atp`) and `:1530` (`rebuildReservationCounters`).
- ATP readers covered, unchanged:
  - `outbound/order.command.ts:1192` (`reserveLine`, outside any transaction; kit components too);
  - `replenishment/replenishment.sweep.ts:98` (`sweepScope` returns `evaluated: 0` before ATP when there are no candidates, `:86-91`);
  - `channels.publish.ts:126` and `channels.command.ts:665` via `channelVisibleQuantity`.
  - `channels.ingest.command.ts:190` only builds the order command.
- Tests:
  - `test/reservations.spec.ts:594-625`, `:678` (rewritten);
  - `test/replenishment.spec.ts:461` (the direct `sweepScope` pattern);
  - Valkey at `redis://localhost:56379/0`, with `afterAll` key cleanup (`orders.spec.ts:20,233-237`);
  - the worker env gates in `src/jobs/jobs.module.ts` (`RESERVATION_REAPER_POLL_MS` `:303`, `REPLENISHMENT_SCHEDULER_POLL_MS` `:463`).

## Tasks & Acceptance

**Execution:**
- [ ] `src/modules/inventory/reservation.service.ts` -- `rebuildWarehouse` and the in-flight map inside `rebuildCounters`; `ensureReady` with the double-check and backoff; the `atp` not-ready branch with the input re-read; the grant not-ready branch -- the fix.
- [ ] `test/cold-warehouse-intake.spec.ts` -- every matrix row, with the gating and spies named in Boundaries -- the regression.
- [ ] `test/reservations.spec.ts` -- rewrite `:594-625` and `:678` -- they asserted the old fail-closed read.
- [ ] The test files with "needed for readiness" bootstrap comments -- reword them -- truth.
- [ ] Meta docs:
  - `docs/design/modules/inventory.md`:
    - `:529` the readiness section: repair-on-read, single-flight for every rebuild, backoff;
    - `:470` the invariant row: repair before 503;
    - `:517` and `:540`: "until a read or grant repairs";
    - the stale line refs (`:585`, `:604-611`, `:912-923`);
    - the validated-warehouse invariant.
  - `docs/design/modules/replenishment.md:252`: remove the cold-scope gotcha.
  - `docs/design/PENDING.md`:
    - close `:232` (Cold-scope bootstrap gap) and `:233` (R1);
    - add the cross-instance limit and the inline-rebuild latency (Design Notes).

**Acceptance Criteria:**
- Given a running backend, when an owner creates a warehouse, receives stock and places an order, then the order is accepted without a restart.
- Given the full BE suite, lint and typecheck, when run, then they pass.

## Implementation Notes

## Spec Change Log

## Review Triage Log

Design review (2026-10-10), two lenses: concurrency and invariant (K), and claims, coverage and testability (T).

| # | Lens | Finding | Verdict | Disposition |
|---|---|---|---|---|
| 1 | K | Parity and facade rebuilds bypass the single-flight. An overlapping rebuild's forced SET (`:897`) can drop a grant's increment that lands between them, and the fix would make the overlap routine | high — verified, `:877,897,906-913,1058` | Fixed: single-flight moved inside `rebuildCounters`; Parity + read row |
| 2 | T | Check-then-act: a read that saw not-ready just before another flight finished starts a second, disarming rebuild; "exactly once" flakes | high | Fixed: double-checked `isReady`; gated-spy tests |
| 3 | T | `reservations.spec.ts:594-625` and `:678` assert the fail-closed read and will break | high — verified | Fixed: both rewritten |
| 4 | K, T | A failing repair re-runs a full rebuild and logs on every read (sweep and publish loops) | medium | Fixed: 5 s backoff, one log per window |
| 5 | K | Inline rebuild latency on order intake, and a herd after a flush | medium | Accepted with a PENDING note: a rebuild is two journal sums and one SET per SKU; no deadline race (Design Notes) |
| 6 | K | The cross-instance limit was understated: an overlap can drop an increment, not just 503 | medium | Fixed: Design Notes and PENDING reworded |
| 7 | K | The read mixes pre-rebuild on-hand with post-rebuild reserved | low | Fixed: inputs re-read after a repair |
| 8 | T | Grant + read, and Sweep, don't say how a test forces or drives them | medium | Fixed: the deferred-gated spy; a policy plus direct `sweepScope` |
| 9 | K, T | Any UUID can now arm a ready key | low | Fixed: the validated-warehouse invariant recorded (all callers validate) |
| 10 | T | Code Map refs are loose (`:190` is not an ATP read; `increaseStandingBuffer` unnamed) | low | Fixed |
| 11 | T | Bootstrap comments are in 11 files, not 3 | low | Fixed: grep-driven |
| 12 | T | The docs task misses `inventory.md:470,517,540` and stale refs, `replenishment.md:252`, PENDING `:232,:233` | medium | Fixed |
| 13 | K | The grant must ignore `ensureReady`'s boolean | low | Fixed: stated |
| 14 | K | The post-check → `getCounter` window under another rebuild | low | Accepted: no worse than today's normal path; Design Notes reworded |
| 15 | K, T | The "exactly once" spy flakes if the reaper or parity job runs | low | Fixed: assert the gates are unset |

## Design Notes

- **Why repair on read, not arm at creation.** Arming at creation fixes only new warehouses, needs a tenancy → inventory dependency, and leaves stock-less-after-restart and post-flush warehouses cold. The read is where readiness is needed, and the grant path already established that a cold read may trigger its rebuild.
- **Why single-flight inside `rebuildCounters`, not in the read.** Every rebuild disarms and then force-SETs counters. Two overlapping rebuilds of one warehouse can therefore overwrite an increment made between them. Sharing one flight per warehouse across *all* callers removes the overlap within a process. The marker still goes up only at the end of a completed flight.
- **What "never decides against a partial mirror" means now:** not under its *own* process's rebuild. The window between the re-check and the counter read is the same as today's normal path.
- **Accepted limit: cross-instance.** The flight map is per process. Two instances can still rebuild one warehouse at once, as today's grant repair already can, and an overlap can drop an in-flight increment until the next parity pass heals it. A Valkey lock goes to PENDING if multi-instance deploys arrive.
- **Accepted latency.** The first read of a cold warehouse pays one rebuild (two journal-sum reads and one SET per SKU) inline; there is no deadline race. Record it in PENDING with the herd-after-flush note.

## Verification

**Commands:**
- `cd workspace/core/backend/wms-be && bun run test -- test/cold-warehouse-intake.spec.ts test/reservations.spec.ts` -- expected: pass (never two jest runs at once)
- `cd workspace/core/backend/wms-be && bun run test && bun run lint && bun run typecheck` -- expected: pass

**Manual checks:**
- With the dev server running: register, create a warehouse, receive, and order without restarting → 201.
