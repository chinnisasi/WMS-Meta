---
title: 'Real-time ATP and atomic reservations'
type: 'feature'
created: '2026-09-09'
status: 'done'
route: 'dispatch'
review_loop_iteration: 1
baseline_commit: 'b0b14ad'
context: []
story_key: '2-3-real-time-atp-and-atomic-reservations'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** Nothing protects sellable stock — `stock_on_hand` has no reserved concept and the 2.2 quarantine flag gates nothing, so two consumers can sell the same last unit. Architecture mandates the shape: one atomic decision point (pre-declared-keys Valkey Lua, AD-2), Postgres as reservation truth, TTL'd holds with reaper and serialized terminal transitions (AD-12).

**Approach:** Add Valkey (9.1) carrying only atomic decision state: per-(warehouse, sku) reserved counters, tenant-namespaced. ONE pre-declared-keys Lua script grants/releases; each winning grant journals durably to a new Postgres `reservations` table (journal is truth — Postgres wins on divergence; cold start rebuilds Valkey from it). Real-time ATP = on-hand (open-quarantined scopes excluded, consuming the 2.2 flag) − reserved − QC-held − buffer (named zero-valued hooks, AD-13). A sheddable reaper in the jobs shell expires held rows past TTL.

## Boundaries & Constraints

**Always:**
- Exactly ONE check-and-decrement: every grant/release goes through the pre-declared-keys Lua script (AD-2). No keyless EVAL.
- Journal-first commit-then-apply: journal row commits, Valkey mirror follows; a missed mirror is repaired toward Postgres, never the reverse.
- Records carry `owner_type`/`owner_id`, TTL (`expires_at`), state `held→committed→released/expired`; terminal transitions serialize via conditional UPDATE — exactly one winner (AD-12).
- ATP never exceeds on-hand − reserved − QC-held − buffer at any read; open-quarantined (sku, bin) on-hand is excluded — the quarantine flag now gates ATP.
- Grant idempotent per (owner_type, owner_id, warehouse, sku): repeat grant while held returns the existing reservation; a repeat grant whose quantity DIFFERS from the held row is rejected with a deterministic 409 conflict (quantity mismatch — human decision at review loop 1, 2026-09-09).
- Tenant-namespaced keys (AD-3); Valkey availability boot-validated like the DB; reaper is a sheddable worker (env gate, shed, unref — 2.2 conventions).
- RLS fail-closed hand-appended (0008 pattern), `tenantTimestamps`, uuidv7 on the new table; migration 0009.

**Never:**
- No per-channel backorder (Epic 7): the race loser gets a deterministic `unavailable` reject, never a retry.
- No batch/serial dimensions (2.4); no bin-level reservation keys — scope is (tenant, warehouse, sku).
- No CI load-test pipeline: deterministic concurrency tests here; the 2-hour 15×-rate rehearsal (NFR-2) is a documented ops ritual, not automation.
- No QC-hold/buffer surfaces — hooks only.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Behavior | Error Handling |
|----------|--------------|-------------------|----------------|
| Healthy grant | reserved < available | Counter decremented; journal row `held` with TTL; ATP drops by qty | N/A |
| Last-unit race | 2 concurrent grants, 1 unit | Exactly one wins; loser gets deterministic `unavailable` | Deterministic reject, no retry |
| Commit | Owner commits held row | `held→committed` (conditional UPDATE — one winner); units stay deducted until the consuming ledger movement | Second commit: deterministic no-op/conflict |
| Release | Owner releases held row | `held→released`; counter restored | Release of non-held row: deterministic conflict |
| TTL expiry | Held past `expires_at` | Reaper transitions `expired` (serialized), restores counter | N/A |
| Valkey lost/divergent | Counter missing or disagrees | Rebuild from journal (Postgres wins); grants fail closed while rebuilding | Grant during rebuild: `unavailable`, never oversell |
| Quarantined scope | Open quarantine (sku, bin) | Scope's on-hand excluded from ATP; grant over remaining sellable rejects | N/A |
| Adjustment mid-grant | `stock.adjusted` commits during grant | Grant reads the committed projection; no oversell across the interleave | N/A |

</frozen-after-approval>

## Open Questions

- RESOLVED at CHECKPOINT 1 (2026-09-09, human approved): option (a) — **no HTTP surface in this story**; facade + jobs only, `openapi` diff must stay empty. Reads become HTTP in 2.5, order wiring in Epic 4.

## Code Map

- `src/modules/inventory/ledger.service.ts` — reuse `warehouseAdvisoryLock` (L119), `appendMovement` (L281), `insufficientOnHand` problem-error pattern. **Do not change** `addToOnHand` (L408) — stays the only stock write (architecture.spec L106).
- `src/modules/inventory/inventory.facade.ts` — extend with atp/grant/commit/release pass-throughs (sibling modules import only facade/module/dto — architecture.spec L132).
- `src/shared/db/schema.ts` — `reservations` beside `inventoryQuarantines` (L659 pattern); `tenantTimestamps` L22; migration `0009` (RLS hand-append per `drizzle/0008` tail).
- `src/jobs/jobs.module.ts` — `ReconciliationWorker` (L130) is the reaper template (env gate, shed, unref, shutdown).
- `src/shared/db/db.ts` (L100) — boot-validation pattern for the new Valkey client module.
- `test/ledger.spec.ts` (L342 Promise.all concurrency), `test/reconciliation.spec.ts` — worker/concurrency precedents; jest `maxWorkers: 1` set.
- `docker-compose.yml` + CI workflow — add Valkey 9.1 service container; `VALKEY_URL` env.

## Tasks & Acceptance

**Execution:**
- [x] Infra: Valkey 9.1 in `docker-compose.yml` + CI service container; `VALKEY_URL` in `.env.example`, boot-validated.
- [x] `src/shared/valkey/` (new): ioredis client module + tenant-namespaced hash-tagged key builders (`wms:{tenantId}:wh:{warehouseId}:res:{skuId}`); the ONE pre-declared-keys Lua script (grant: check+decrement; release: increment — KEYS only).
- [x] `schema.ts` + `drizzle/0009_*.sql`: `reservations` journal (owner_type, owner_id, warehouse, sku, qty, state CHECK, expires_at, timestamps, RLS hand-appended) + index `(tenant_id, state, expires_at)`.
- [x] `src/modules/inventory/reservation.service.ts` (new): grant (idempotency probe → script → journal insert, compensating release on journal failure), commit/release (serialized conditional UPDATE, then script), rebuild-from-journal, ATP computation (quarantine-excluded on-hand − reserved − zero hooks).
- [x] `jobs.module.ts`: `ReservationReaper` (`RESERVATION_REAPER_POLL_MS` gate; expires holds, restores counters).
- [x] Review loop 1 (2026-09-09): reaper cycle gains the journal-vs-counter parity pass (mismatch → warehouse rebuild from journal); grant idempotency rejects quantity mismatch 409.
- [x] Review loop 1 patch queue: grant validation (ttlSeconds upper bound, non-empty scope ids), missing-counter repair arm fail-closed wrap, reaper plumbing unit block (sibling `ReconciliationWorker` pattern), boot-rebuild observation test, real-socket bounded-failure test, unique-violation re-probe + rebuild correction-pass tests, `.env.example` reaper gate warning, `getCounter` finite guard, uuid guard on terminal-transition ids, interleave test asserts the adjustment's settled outcome, trailing newlines on new files.
- [x] `inventory.facade.ts` + module wiring: pass-throughs.
- [x] `test/reservations.spec.ts`: the I/O matrix — last-unit race, bounded concurrent burst (zero oversell, no deadlock), TTL reaper, terminal-transition serialization, divergence rebuild, quarantine exclusion, idempotent grant.

**Acceptance Criteria:**
- Given one unit available, when two reservations race concurrently, then exactly one succeeds and the loser receives a deterministic unavailable outcome.
- Given any read, then ATP never exceeds on-hand − reserved (QC-held/buffer hooks at zero).
- Given Valkey state lost, when a rebuild runs, then counters are restored from the journal and Postgres wins on divergence.
- Given a held reservation past TTL, when the reaper runs, then it transitions to `expired` exactly once and the counter is restored.
- Given a burst of concurrent grants across many SKUs, then no oversell occurs and no grant deadlocks (bounded deterministic test).

## Implementation Notes

- Matrix-audit fix (2026-09-09, step-03): the "Adjustment mid-grant" matrix row had no covering test; adding it (`test/reservations.spec.ts` "adjustment committing mid-grant") exposed a **pre-existing 2.1 bug** — `addToOnHand`'s upsert put the raw signed delta in the speculative INSERT tuple, and Postgres evaluates table CHECKs on that tuple before the arbiter conflict fires, so **any negative stock adjustment against an existing row 500s** on `stock_on_hand_quantity_nonnegative` even though the UPDATE arm would land legally. Fixed in `ledger.service.ts` by clamping the speculative tuple (`greatest(delta, 0)` — a no-op on the insert arm, where the insufficient-on-hand guard already guarantees delta > 0). `addToOnHand` remains the only stock write; the architecture test still passes.

## Design Notes

Grant: idempotency probe (open `held` row for owner+warehouse+sku → return it; quantity mismatch → 409 conflict) → Lua script, ceiling = committed on-hand passed as ARGV (win: counter decremented) → `INSERT reservations (held, expires_at = now + TTL)` → reply. Journal insert fails → compensating script release (the decrement never outlives a missing journal row). Commit leaves the counter unchanged (committed units stay deducted until Epic 4's dispatch movement); release/expired restore it. Reaper: `UPDATE … SET state='expired' WHERE id=… AND state='held'` (rowcount = one terminal winner), then script release — Postgres-driven expiry; key TTLs are a backstop only. **Parity pass (review loop 1 decision):** each reaper cycle ALSO compares every live scope's Valkey counter against its journal sum (`state IN ('held','committed')`) and triggers a warehouse rebuild from the journal on any value mismatch — a present-but-wrong counter (the rebuild residual race, failed compensations/restores) is thereby repaired toward Postgres instead of persisting silently. Repair/cold start: rebuild counters from `state IN ('held','committed')`; grants fail closed (`unavailable`) while rebuilding. ATP read fails closed when Valkey is unreachable. Loser outcome: `409 unavailable` problem-details (per-channel accept/backorder arrives with Epic 7).

## Verification

**Commands:**
- `docker compose up -d valkey`; in `wms-be` (env as spec-2-1 + `VALKEY_URL`): `bun run db:migrate && bun run test` — all green incl. `test/reservations.spec.ts`.
- `bun run db:generate && git diff --exit-code drizzle/` — no drift; `bun run lint && bun run typecheck` — clean; `bun run openapi:export && git diff --exit-code openapi/` — no diff (no HTTP surface).

**Manual checks:**
- `docker compose restart valkey` against a DB with held reservations → counters rebuilt from the journal; grants fail closed during the gap.

## Spec Change Log

- **2026-09-09, review loop 1** (triggering findings: triage rows R2/R11 — counter present-but-wrong is never detected, no scheduled repair trigger; R3/R16 — idempotent replay silently ignores a quantity mismatch). Amended: (a) frozen idempotency line — a repeat grant with a different quantity now rejects 409 conflict (human decision); (b) non-frozen Design Notes + Tasks — the reaper cycle carries a journal-vs-counter parity pass that rebuilds a warehouse on value mismatch (human decision: scheduled parity pass). Known-bad state avoided: a divergent-but-present counter silently overstating ATP until an arbitrary later rebuild, and an order line silently under-holding after a qty-increasing replay. KEEP instructions for re-derivation: the script-first grant shape (probe → Lua → journal → compensate-on-failure), the not-ready/missing-counter fail-closed arms, journal-first terminal transitions with conditional UPDATE, the rebuild disarm→seed→correction→arm shape, the reaper's env-gate/shed/unref/shutdown plumbing, and the fail-safe over-count direction comments all stay exactly as built.

## Review Triage Log

Step-04 triage (2026-09-09): 31 findings (blind-hunter 15, edge-case 12, verification-gap 4 — VG rows pre-verified per step-04). Verified each claim at its cited location before verdict.

- R1 — blind #1 — grant header comment "no interleave oversells" vs interleave test — **false** — the test itself states the same invariant ("ATP clamps at 0… never oversell", test L681-684); grant-first over-reserves but never oversells; no contradiction.
- R2 — blind #2 — no scheduled journal-vs-counter parity check — **high** — a counter that is present but WRONG is never detected (only missing/not-ready triggers a repair); reachable via the rebuild residual race documented at `reservation.service.ts:462-467` (in-flight grant's script wins pre-disarm, reseed clobbers the increment, its journal lands after the correction read → counter below journal → ATP overstates → oversell direction), and via failed compensations/restores; the "repaired by the next rebuild" comments have no scheduled trigger anywhere. **intent_gap** (grouped with R11).
- R3 — blind #3 — idempotent replay ignores quantity mismatch — **medium** — `grant()` L234-236 returns the probe hit without comparing quantity; a caller asking for 5 while holding 2 gets a success-shaped reply. The frozen idempotency line prescribes exactly this behavior, so changing it is a frozen-intent renegotiation. **intent_gap** (grouped with R16).
- R4 — blind #4 — no holder/actor ownership check on commit/release — **low, reject** — no caller exists in this story (facade-only, no HTTP by the CHECKPOINT 1 decision); the fix adds parameters/guards; authorization lands with the 2.5/Epic 4 surfaces.
- R5 — blind #5 — grant against unknown scope yields 409 not 404 — **false** — the frozen contract defines only the deterministic `unavailable` loser; ceiling 0 for an unknown scope IS the designed decision; no 404 branch exists in the intent.
- R6 — blind #6 — ttlSeconds unbounded above → RangeError 500 after compensating — **medium** — verified: L215-223 validates ≥0 integer only; ttl 9e12 → invalid Date → `toISOString` throws inside the journal tx → raw 500 (counter already compensated). Smallest fix = upper-bound check. **patch** (grouped with R18/R19).
- R7 — blind #7 — reaper due-holds query can't use the tenant-leading index — **low, reject** — negligible at any realistic near-term table size; the fix is a new migration index, more than a direct correction.
- R8 — blind #8 — rebuildCounters has no single-flight guard — **low, reject** — concurrent not-ready rebuilds are idempotent and converge (Postgres wins); harm is bounded redundant load; the fix adds locking complexity.
- R9 — blind #9 — onModuleInit rebuilds on every boot incl. shells — **low, reject** — the cold-start rebuild is the designed contract and the catch makes it best-effort by design; shells still boot.
- R10 — blind #10 — `.env.example` ships `RESERVATION_REAPER_POLL_MS=0` unwarned — **medium** — verified: unlike `OUTBOX_RELAY_POLL_MS` (2000 + "every deployment must set it"), the reaper example ships disabled with no deployment warning → a copied .env silently never expires holds (journal rows stay held, ATP shrinks). Tests delete the var anyway, so a live default would not race them. **patch**.
- R11 — blind #11 — release script floors at 0 and reports applied=1 — **low** — the floor is a deliberate design choice for an already-divergent counter, but the partial restore is invisible (no divergence signal); same root cause as R2 (value-divergence undetected). Grouped into R2's entry.
- R12 — blind #12 — 0009 snapshot records no RLS/policies — **false** — RLS is deliberately never modeled in schema.ts (the 0006-0008 hand-append convention, restated in 0009's comment); the snapshot gap is the accepted documented pattern, not a 2.3 defect.
- R13 — blind #13 — no outbox/audit events for the reservation lifecycle — **low, reject** — no consumer in this story; the event contract is Epic 4's wiring and would be new scope here.
- R14 — blind #14 — untested branches (unique-violation re-probe arm, rebuild correction pass) — **medium** — verified: no test triggers the concurrent same-owner unique violation or the correction pass; also noted (cosmetic): the rebuild report's scopes reflect only the first pass. **patch**.
- R15 — blind #15 — mixed bundle — split: (a) no operator surface for rebuild — **false** (CHECKPOINT 1: no HTTP surface in 2.3; 2.5 adds reads); (b) parser unit tests — covered by R28; (c) ttlSeconds:0 undocumented — **low, reject** (0 is a legitimate non-negative value; doc-only); (d) trailing newlines — **low, verified** (`reservation-keys.ts`, `reservation-scripts.ts`, `reservation.service.ts`) — **patch**.
- R16 — edge #1 — idempotent replay ignores quantity mismatch — duplicate of R3 (same location, same claim, same route).
- R17 — edge #2 — stale held snapshot (release between probe and reply) — **low, reject** — inherent to snapshot reads racing terminal transitions; the proposed re-select has the identical window; the journal is truth and the caller's next terminal write settles it.
- R18 — edge #3 — empty tenantId/warehouseId/skuId unvalidated — **medium** — verified: grant guards owner/quantity only; '' scope ids reach `eq(uuid, '')` → raw 22P02 500 (plus degenerate keys). Smallest fix: 400 on empty scope ids. **patch** (grouped with R6/R19).
- R19 — edge #4 — ttlSeconds upper bound — duplicate of R6.
- R20 — edge #5 — missing-counter repair arm not failure-wrapped — **medium** — verified: `reservation.service.ts:571-573` runs `journalReservedSum` + `setCounter` with no catch (unlike the not-ready arm's `.catch`); a DB/Valkey error escapes `runGrantScript` → unclassified 500 instead of the 409 `unavailable` contract. **patch**.
- R21 — edge #6 — re-probe failure replaces the original unique violation — **low, reject** — both paths surface an error to the caller; rethrowing the original changes only the error flavor.
- R22 — edge #7 — getCounter returns NaN on a corrupt non-numeric value — **low** — verified: `valkey.client.ts:103-106` does an unchecked `Number(raw)`; reachable only via out-of-band corruption. One-line `Number.isFinite` guard mapping to null (→ divergence heal). **patch**.
- R23 — edge #8 — whitespace-only POLL_MS coerces to 0 — **low, reject** — mirrors both sibling parsers exactly; changing only the reaper would diverge the established convention.
- R24 — edge #9 — a hung expireDue wedges the reaper forever — **low, reject** — identical to the ReconciliationWorker convention; a hung statement fails on connection teardown, not forever.
- R25 — edge #10 — non-uuid reservationId → raw 22P02 500 — **low** — verified: commit/release pass the id into `eq()` unguarded; the contract's 404 should apply. One-line format guard before the UPDATE (both arms). **patch**.
- R26 — edge #11 — expires_at from app clock vs reaper's DB now() — **low, reject** — sub-second skew in any NTP'd/compose deployment against a 900s default TTL; negligible.
- R27 — edge #12 — grant/release script sign-convention claim — **false** — the frozen "check+decrement" names the sellable pool; the counter tracks reserved units (inverted by design) and the script header (`reservation-scripts.ts:7-13`) documents the reconciliation explicitly.
- R28 — vgap #1 — reaper worker plumbing (parser + worker) has no test anywhere — **medium** (pre-verified) — repo-wide symbol search shows zero test references; the sibling ReconciliationWorker has the full mirror block at `test/reconciliation.spec.ts:977-1060`. **patch** (covers R15b).
- R29 — vgap #2 — onModuleInit never observed with non-empty state — **medium** (pre-verified) — the suite boots on an empty journal and its explicit rebuild at `test/reservations.spec.ts:308` masks any regression of the startup contract. **patch**.
- R30 — vgap #3 — bounded-failure contract never exercised against a real socket — **medium** (pre-verified) — the only unreachable-Valkey test (`:576-591`) stubs the rejection itself. **patch**.
- R31 — vgap #4 (other) — the interleave test never inspects the adjustment's allSettled rejection — **low** — verified at test L665-668; the clamp fix's carrier test should name its own failure. **patch**.

### Grouping & routing

| Group | Members | Highest verdict | Route |
| --- | --- | --- | --- |
| G1 — counter value-divergence (present-but-wrong) is undetected and no scheduled repair trigger exists | R2, R11 | high | **intent_gap → loopback** (mechanism unsettled by the frozen matrix row: scheduled parity vs read-path comparison vs accepted residual) |
| G2 — idempotent replay ignores quantity mismatch | R3, R16 | medium | **intent_gap → loopback** (the frozen idempotency line prescribes the current behavior; changing it renegotiates frozen intent) |
| P1 — grant input-validation gaps (TTL upper bound, empty scope ids) | R6, R18, R19 | medium | patch (queued for the post-loopback re-run) |
| P2 — missing-counter repair arm escapes the deterministic contract | R20 | medium | patch (queued) |
| P3 — reaper plumbing unit block | R28, R15b | medium | patch (queued) |
| P4 — boot-rebuild observation test | R29 | medium | patch (queued) |
| P5 — real-socket bounded-failure test | R30 | medium | patch (queued) |
| P6 — unique-violation + correction-pass tests | R14 | medium | patch (queued) |
| P7 — .env.example reaper gate warning/default | R10 | medium | patch (queued) |
| P8 — getCounter finite guard | R22 | low | patch (queued) |
| P9 — uuid guard on terminal-transition ids | R25 | low | patch (queued) |
| P10 — assert the adjustment's settled outcome | R31 | low | patch (queued) |
| P11 — trailing newlines | R15d | low | patch (queued) |

Rejected (false / low): R1, R4, R5, R7, R8, R9, R12, R13, R15a, R15c, R17, R21, R23, R24, R26, R27.

**Loopback (review_loop_iteration 0 → 1):** G1 and G2 are intent_gap — the frozen intent does not settle their resolutions, so the code change loops back to the human before any patch round. NOTE on revert: step-04 says intent_gap reverts code, but the implementation is already merged to main (PR #11, merged by the user) and the working tree carries two uncommitted fixes main still needs (the addToOnHand speculative-insert clamp, the interleave test) — a literal working-tree revert would destroy them, so the tree is preserved pending the human's resolution; re-derivation then happens as follow-up deltas.

### Round 2 (post-loop-1 re-review, 2026-09-09): 32 findings (blind 14, edge 13, verification-gap 5)

Checked against the existing rows first per step-04 — carried rows keep their verdict/route; everything else verified fresh.

- R32 — blind #1 — parity pass blind for drained scopes (zero live reservations) — **low, reject** — a stale-present counter over an empty journal scope only OVER-counts (ATP understated — the fail-safe direction) and is bounded by the 7-day counter TTL; the fix needs SCAN-based counter discovery, more than a direct correction.
- R33 — blind #2 — reaper head-of-line blocking (one poison hold aborts the cycle, starves later holds) — **medium** — verified: the per-hold loop in `expireDue()` has no error isolation; a repeatedly-failing tenant tx re-selects first every cycle (`order by expires_at asc`) and blocks all later holds. Smallest fix: per-row try/catch, continue. **patch**.
- R34 — blind #3 — unbounded parity-pass cost every cycle — **low, reject** — negligible at any realistic near-term scope count; the fix (every-Nth-cyle/bounding) adds config surface.
- R35 — blind #4 — reaper due-holds query can't use the tenant-leading index — **carried, low, reject** (same location and claim as R7; the code there still reads as the row describes).
- R36 — blind #5 — grant accepts non-empty but non-uuid scope ids — **medium** — verified: grant validates non-emptiness only; a malformed id reaches `eq(uuid, …)` → raw 22P02 500; same defect class as the fixed R18 and inconsistent with the file's own `UUID_RE` guard. **patch** (grouped with R46/R47/R48).
- R37 — blind #6 — migration comment overclaims "DB-enforced" — **false** — the comment's explanatory clause scopes the claim accurately (a typo'd state value drops the row from every `state`-filtered consumer); the value-set CHECK is exactly what is claimed.
- R38 — blind #7 — no event/audit seam for the reservation lifecycle — **carried, low, reject** (same claim as R13; no consumer in this story, Epic 4 wiring defines the contract).
- R39 — blind #8 — VALKEY_URL/reaper envs documented only in .env.example, no interface-contract update — **false** — the `docs/repos/wms-be/README.md` contract update is the story's already-agreed meta docs PR (last in the cross-repo order), not an omission.
- R40 — blind #9 — hook docstring contradicts the zero-arg signature — **low** — verified: the `qcHeldUnits`/`bufferUnits` docstring says "callers pass the scope through" but both take no arguments. Direct comment reword. **patch**.
- R41 — blind #10 — parity pass untested — grouped with R59 (same root cause).
- R42 — blind #11 — concurrent same-owner test wrongly pins every rejection to `unavailable` — **false** — the unique-violation loser's re-probe reads committed state in a fresh transaction, so the winner's row is always visible; rejections can only come from the script's ceiling check → `unavailable` is the correct pin.
- R43 — blind #12 — atp heal arm returns the journal sum read before SET NX — **low** — verified: a concurrent counter re-creation between the read and the NX makes the returned snapshot stale (transient, self-corrects on the next read). Smallest fix: read the counter back after the heal. **patch**.
- R44 — blind #13 — no length bound on ownerType/ownerId — **low, reject** — free-form text is the intentional design ("Epic 4's order lines are the first writers"); caps add validation surface for a marginal harm.
- R45 — blind #14 — trailing newlines still missing — **low** — verified: `valkey.client.ts`, `valkey.module.ts`, `docker-compose.yml`, `drizzle/0009_overjoyed_sway.sql`, `test/reservations.spec.ts` (the three files named in the round-1 brief WERE fixed; these five came from the PR #11 commit). **patch**.
- R46 — edge #1 — grant non-uuid scope ids → 22P02 500 — duplicate of R36 (same root cause).
- R47 — edge #2 — atp ids unvalidated → raw 22P02 — same root cause as R36. **patch** (grouped).
- R48 — edge #3 — rebuildCounters warehouseId unvalidated — same root cause as R36. **patch** (grouped).
- R49 — edge #4 — getCounter accepts finite negative/non-integer values — **low** — same line as the round-1 R22 fix; extend `Number.isFinite` to `Number.isInteger && ≥ 0`. **patch**.
- R50 — edge #5 — corrupt counter → Lua nil arithmetic error instead of 'missing-counter' — **low** — verified: `tonumber(nil-parsed GET)` → script error → grant 409s until the parity pass heals it within a cycle; the one-line nil guard makes the failure mode the designed divergence arm. **patch**.
- R51 — edge #6 — parity early-return skips stale counters over an empty journal — duplicate of R32 (same root cause, same verdict).
- R52 — edge #7 — correction pass heals only growth — **low, reject** — fail-safe direction, and bounded to one cycle by the newly-landed scheduled parity pass.
- R53 — edge #8 — findOpenHold matches past-TTL holds — **false** — the row is genuinely held until a terminal writer wins (expiry is a serialized conditional UPDATE, not a pre-filter); the same snapshot-race class as rejected R17.
- R54 — edge #9 — whitespace POLL_MS coerces to 0 — **carried, low, reject** (same claim as R23; mirrors both sibling parsers).
- R55 — edge #10 — ready marker armed without TTL — **low, reject** — the marker vanishes on any Valkey restart (→ fail-closed rebuild); the exotic DB-restore-while-Valkey-survives scenario is bounded by the parity pass; a marker TTL would add spurious not-ready windows.
- R56 — edge #11 — "ONE Lua script" claim — **false** — the frozen text names the decision point (no other decision paths); the Design Notes describe both scripts explicitly.
- R57 — edge #12 — commit calls no script vs the task line's "(then script)" — **low, reject** — the fix would edit the spec's task line (a spec edit is rejected per step-04), and the Design Notes already state commit leaves the counter untouched.
- R58 — edge #13 — trailing-newline claim unfulfilled — duplicate of R45 (verified true for the five files).
- R59 — vgap #1 — parity pass executed by tests but never checked — **medium** (pre-verified) — the TTL reaper test runs the pass with all counters agreeing; no test forces a wrong counter through `expireDueReservations()` and asserts the rebuild. **patch**.
- R60 — vgap #2 — 0009 CHECK constraints never tested for rejection — **medium** (pre-verified) — hand-appended SQL invisible to drizzle and to the `db:verify` guard; two raw-SQL rejection probes close it. **patch**.
- R61 — vgap #3 — release/expiry with an unreachable Valkey (restore-fails-loud contract) never exercised — **medium** (pre-verified) — the outage test mocks only grant/isReady. **patch**.
- R62 — vgap other — `db:verify` drift guard round-trips only app_metadata; hand-appended policy/CHECK SQL on 0006-0009 is unverified by CI — **defer** — pre-existing repo-wide pattern (0006-0008), not caused by this story.
- R63 — vgap other — correction pass growth-only residual — duplicate of R52 (same verdict).

### Round-2 grouping & routing

| Group | Members | Highest verdict | Route |
| --- | --- | --- | --- |
| H1 — scope-id format validation on grant/atp/rebuildCounters | R36, R46, R47, R48 | medium | patch |
| H2 — parity-pass divergence observation test | R41, R59 | medium | patch |
| H3 — 0009 CHECK-constraint rejection probes | R60 | medium | patch |
| H4 — restore-failure resilience test (release/expiry with Valkey down) | R61 | medium | patch |
| H5 — reaper poison-row isolation | R33 | medium | patch |
| H6 — trailing newlines (the five PR #11 files) | R45, R58 | low | patch |
| H7 — getCounter non-negative-integer guard | R49 | low | patch |
| H8 — Lua nil guard → 'missing-counter' | R50 | low | patch |
| H9 — atp heal re-read after SET NX | R43 | low | patch |
| H10 — hook docstring reword | R40 | low | patch |
| Defer | R62 | — | deferred-work.md (pre-existing db:verify blind spot) |

Carried (same verdict/route as logged rows): R35→R7, R38→R13, R54→R23. Rejected: R32/R51, R34, R37, R39, R42, R44, R52/R63, R53, R55, R56, R57.

No intent_gap/bad_spec this round → no loopback; patch groups H1-H10 route to the implementation subagent. review_loop_iteration remains 1.

Execution note on H6 (2026-09-09): trailing newlines were appended to the four hand-written files but **withheld from `drizzle/0009_overjoyed_sway.sql`** — that file is drizzle-kit-generated, its canonical form has no trailing newline, and appending one would make a future regeneration produce a phantom diff that fails the CI drift guard. Verified: `db:generate` clean, `git diff --exit-code drizzle/` passes with the file restored to drizzle's byte form.