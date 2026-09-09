---
title: 'Append-only ledger core and derived quantities'
type: 'feature'
created: '2026-09-08'
status: 'done'
route: 'dispatch'
review_loop_iteration: 0
baseline_commit: 0a5b519d1b9fd379c0d327f171a57ba6d861f5de
context: []
story_key: '2-1-append-only-ledger-core-and-derived-quantities'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** The WMS has no stock truth. Every quantity later epics write (receipts, picks, adjustments, orders) must be explainable and re-derivable from a single immutable record, or the "one trusted number" promise fails the first time two numbers disagree. Today `src/modules/inventory/` is an empty stub and no movement can be recorded anywhere.

**Approach:** Realize the inventory module with an append-only ledger as the only stock truth: every movement is one immutable, hash-chained, registry-registered event committed in the same transaction as its derived on-hand projection; replaying a SKU/bin's events reproduces on-hand exactly. A minimal Ops-Manager adjustment command is the first movement producer so the core is exercisable end-to-end. (Outbox delivery is split to a follow-up spec — see deferred-work.md; the ledger ships with `LoggingEventBus` as the delivery seam.)

## Boundaries & Constraints

**Always:**
- Ledger events are immutable — corrections are new compensating events; UPDATE/DELETE on the events table is rejected at the database (trigger), not just by convention.
- Event insert and projection update commit in ONE transaction (`withTenantTransaction`); every event carries `tenant_id`, `warehouse_id`, event type, SKU, signed qty (base-UoM integer, `BaseQuantity`-derived), from/to bin (nullable), actor, `occurred_at`, `recorded_at`, and a typed `reference_doc` union arm.
- Event grammar is a versioned, registered schema (AD-11): event types exist only by registration in a versioned registry; additive changes only — never renumber, never repurpose an arm.
- Hash chain (AD-16): each event stores its predecessor's hash and its own hash over the canonical event bytes; per-tenant chain. **Anchor decision (human, 2026-09-08, Option A):** chain heads anchor to an append-only Postgres table (`ledger_anchors` with digest + seq range + anchored-at); a verifiable digest export over an event range is producible on demand as an artifact; the anchor target is an interface so a real external WORM store swaps in later without touching the chain. A verification function detects any break and surfaces it as a severity-1 alert (log + alert event).
- Per-warehouse `seq` is gap-free and unique per tenant+warehouse; `seq` is the replay order. Concurrency is safe (advisory-lock-per-warehouse inside the tx is the sanctioned mechanism — no retry loops on sequence races).
- On-hand is a derived projection maintained in the same tx as the event; a `replay(sku, bin)` (and full-warehouse) function recomputes on-hand from events and must match the projection exactly — delivered here, consumed by 2.2's continuous job.
- New tables carry `tenant_id` + RLS policy declared in migration SQL only (never in `schema.ts`); ledger queries flow through `withTenantTransaction`.
- Only the inventory module may write stock/ledger tables; consumers go through `InventoryFacade`. Enforce with a new architecture test (first one in the repo).

**Never:**
- No outbox table, no relay worker, no retrofit of the epic-1 command files' `publishSafely` call sites — split to its own spec (deferred-work.md); `LoggingEventBus` stays the delivery seam untouched.
- No Valkey/Redis, reservation, QC-hold, or buffer logic — story 2.3's ground. ATP is not implemented here (only the projection the formula will subtract from).
- No batch/serial rotation or unit-history logic — story 2.4. Event envelope reserves the nullable batch/serial arms; nothing populates them.
- No continuous reconciliation job — story 2.2. Deliver the replay/verify functions; do not schedule them.
- No FE changes; no hand-written API types; no editing of emitted events; no module importing another module's internals (facade only).

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Happy path: manual adjustment | Ops Manager, valid SKU+bin, signed delta, ULID idempotency key, reason note | Exactly one ledger event + updated on-hand projection in one commit; response carries event id, seq, new on-hand | N/A |
| Idempotent replay, same actor/role | Same key, same payload | Original response replayed from snapshot; no second event | 422 `idempotency-key-reuse` on payload mismatch |
| Concurrent adjustments, same warehouse | Two parallel commands, different keys | Both commit with distinct gap-free seqs; projection sums both; no lost update | N/A |
| Actor lost capability before replay | Replay of idempotent key after role change | 403 `role-denied` naming role+capability before replay lookup (epic-1 carve-out parity) | N/A |
| Capability missing | Operator calls adjustment endpoint | 403 `role-denied` | ProblemException, RFC 9457 body |
| Replay equivalence check | Any SKU/bin with events | `replay(sku, bin)` output equals stored projection exactly; mismatch fails loudly (test + debug tool, no auto-heal) | Test failure names the divergent scope |
| Chain tamper probe | Direct SQL UPDATE of a settled event's qty | Verification (run in test + anchor job) detects the break; severity-1 alert surfaces scope + seq range | N/A |
| Append-only enforcement | UPDATE or DELETE on `ledger_events` | Database raises; row unchanged | N/A |

</frozen-after-approval>

## Code Map

- `workspace/core/backend/wms-be/src/modules/inventory/inventory.module.ts` -- empty stub; becomes the realized module (ledger + projections + adjustment command). Imports `SharedModule` only; exports `InventoryFacade`.
- `workspace/core/backend/wms-be/src/shared/db/schema.ts` -- single shared schema file (~450 lines, load-bearing comments); add `ledger_events`, `stock_on_hand`, `ledger_anchors` here; RLS goes in migration SQL only.
- `workspace/core/backend/wms-be/drizzle/` -- migrations `0000..0005`; next is `0006`; generate with `bun run db:generate`, hand-append RLS/trigger DDL into the generated file (see `0005` for the RLS policy pattern).
- `workspace/core/backend/wms-be/src/shared/events/event-bus.seam.ts` + `event-bus.ts` -- `DomainEvent`/`EventBus` seam + `LoggingEventBus` (publish logs, subscribe is a no-op). Leave untouched — the outbox relay (split spec) replaces delivery later.
- `workspace/core/backend/wms-be/src/modules/tenancy/idempotency-guard.ts` + `src/shared/idempotency/idempotency.seam.ts` -- `@IdempotencyKey`, `hashCommandPayload`, key contract to reuse for the adjustment command.
- `workspace/core/backend/wms-be/src/modules/tenancy/permissions.ts` -- `CAPABILITIES`/`ROLE_CAPABILITIES`; add ledger capability/ies here (mirrors into wms-fe `src/lib/users.ts` — note for the FE drift-guard deferred item).
- `workspace/core/backend/wms-be/src/shared/db/tenant-scope.ts` -- `withTenantTransaction` + `set_config('app.tenant_id')`; the only sanctioned write path.
- `workspace/core/backend/wms-be/src/shared/primitives/` -- `ids.ts` (uuidv7/ulid), `quantity.ts` (`BaseQuantity`, non-negative — ledger needs a signed-delta sibling), `time.ts` (`nowIso`, `assertUtcIso`), `pagination.ts` (cursor).
- `workspace/core/backend/wms-be/src/shared/problem-details/problem.exception.ts` -- `ProblemException` + `isUniqueViolationOn`; new error codes must be kebab and registered in the problem-details contract.
- `workspace/core/backend/wms-be/src/api/api.module.ts` -- the only HTTP surface; wire the adjustment command + event-timeline read endpoint here.
- `workspace/core/backend/wms-be/test/users.spec.ts` -- exemplar for HTTP-level integration tests over real Postgres (55432) with RLS probe role; migrations are applied by CI/hand, not by tests.
- `workspace/core/backend/wms-be/.github/workflows/ci.yml` -- `lint-and-test` (migrate→lint→test→typecheck→build), `migrations` (migrate→`db:verify` round-trip), `openapi` (export→diff) must all stay green.

## Tasks & Acceptance

**Execution:**
- [x] `workspace/core/backend/wms-be/src/shared/db/schema.ts` + `drizzle/0006_*.sql` -- add `ledger_events` (tenant/warehouse-scoped, unique `(tenant_id, warehouse_id, seq)`, `prev_hash` chain column), `stock_on_hand` (sku/bin/tenant keyed), `ledger_anchors`; RLS policies + append-only trigger in hand-appended DDL; keep `db:verify` round-trip green.
- [x] `workspace/core/backend/wms-be/src/modules/inventory/` -- realize the module: versioned event registry (registration-only grammar), ledger append service (advisory lock per warehouse, gap-free seq, hash computation), `replay(sku, bin)`/`replay(warehouse)` + projection updater committed in the same tx, chain verify + anchor + digest export service.
- [x] `workspace/core/backend/wms-be/src/modules/inventory/inventory.command.ts` + `src/api/` controller -- `stock.adjustment` command: capability assertion, ULID idempotency, in-tx event+projection commit; cursor-paginated event-timeline read endpoint with `problem()` codes.
- [x] `workspace/core/backend/wms-be/test/architecture.spec.ts` (new) -- first architecture test: no `UPDATE`/`DELETE` on ledger tables in code, no stock-table writes outside the inventory module, no second quantity-mutation path; plus `test/ledger.spec.ts` covering the I/O matrix.
- [x] `workspace/core/backend/wms-be/openapi/openapi.json` -- regenerate the committed OpenAPI export after the new routes exist (CI `openapi` job diffs it).

**Acceptance Criteria:**
- Given any movement executes, when it commits, then exactly one ledger event exists and the on-hand projection already reflects it in the same transaction — and replaying that SKU/bin's events from zero reproduces the projection exactly.
- Given two concurrent adjustments on the same warehouse, when both commit, then the seq sequence is gap-free and unique with both events durable and projections correct.
- Given a direct SQL tamper of a settled event, when the chain verifier runs, then the break is detected naming the scope and seq range (severity-1 alert path).
- Given the architecture test suite, when it runs in CI, then any new code path that mutates stock state without a ledger event (or writes stock tables from outside the inventory module) fails the build.

## Implementation Notes

## Review Triage Log

Verdicts rendered after all three layers reported; each finding verified at its cited location (verification-gap rows arrive pre-verified). Grouping/routing follows the table.

| # | Layer | Finding | Verdict | Evidence |
|---|-------|---------|---------|----------|
| 1 | blind | `replayInTx` ignores the `binId` filter when folding events — scoped replay folds all bins of the SKU and reports every other bin as phantom divergence (`projectedQuantity: null`) | medium | Confirmed at `ledger.service.ts` `replayInTx` — the event query conditions carry tenant/warehouse/skuId only; the projection query narrows by `binId`, so every other bin with a real projection row is pushed as a divergence. False `matches: false` on a healthy ledger — Story 2.2's reconciliation would false-quarantine. |
| 2 | blind | Unsafe-integer `quantityDelta` (e.g. `1e16`) passes `@IsInt()`, `signedQuantity` throws a plain Error, nothing maps it → 500 instead of the documented 400 | medium | Confirmed — `assertNonZeroDelta` (command) calls `signedQuantity` outside any try/catch; `quantity.ts:34` throws plain `Error`; only the `occurredAt` branch is mapped to 400. Three layers independently flagged. |
| 3 | edge | Int4-overflowing delta (`2147483648`) passes the safe-integer guard → Postgres integer-out-of-range on the projection write → 500, not 4xx | medium | Confirmed — `signedQuantity` guards `Number.isSafeInteger` only; `quantity_delta`/`quantity` are int4 (0006). Same root cause as #2: no upper bound anywhere in the pipeline. |
| 4 | edge | GET events with a non-uuid `warehouseId` path param reaches the `::uuid` cast → 500 | low | Confirmed at the code level — no `ParseUUIDPipe` anywhere in `src/api`; but the new endpoints mirror every epic-1 controller's shape (repo-wide pattern, not introduced here). |
| 5 | edge | Crafted cursor `createdAt` (zone-less/non-ISO) passes `Date.parse` and shifts the page boundary via the PG timestamptz cast | low | Confirmed — `decodeCursorSafe` validates only via `Date.parse` (NaN check); PG's timestamptz grammar accepts more shapes than strict ISO. Root cause shared with #8: the read path emits PG text shape, so strict pinning is impossible until that is normalized. |
| 6 | edge | Concurrent `anchorChain` calls (no advisory lock, no unique `(tenant,warehouse,to_seq)` index) both read the same `lastToSeq` and commit overlapping anchors | medium | Confirmed — `anchorChain` takes no advisory lock; 0006 declares only the PK on `ledger_anchors`. Two concurrent calls duplicate overlapping anchor rows, poisoning Story 2.2's verification basis. |
| 7 | edge | Seq gap inside the anchor range (out-of-band deletion via replication role) — `anchorChain` commits a digest over a silently partial range | medium | Confirmed — `anchorChain` never asserts `rows.length === toSeq - fromSeq + 1` before computing the digest. |
| 8 | edge | `replay(sku, bin)`: binId filters the projection query but not the event fold — sibling-bin buckets reported as divergences | medium | Same defect as #1 (independent trace, same conclusion). |
| 9 | edge | `verifyChain(fromSeq..toSeq)` with zero rows in range returns `ok: true, eventCount: 0` — deletion-class tampering (tail delete) verifies clean | medium | Confirmed — `verifyChainInTx` returns `ok: true` with `toSeq: fromSeq - 1` when no rows exist; anchors are written but never consulted by the verifier. |
| 10 | edge | TRUNCATE fires neither the UPDATE nor DELETE row triggers — `TRUNCATE ledger_events` bypasses the append-only guarantee | medium | Confirmed — both 0006 triggers are `BEFORE UPDATE OR DELETE ... FOR EACH ROW` (row-level triggers don't fire on TRUNCATE); the architecture test's regexes also scan only insert/update/delete forms. |
| 11 | edge | `app.tenant_id` set to a non-uuid non-empty string makes the policy's `::uuid` cast error the session instead of failing closed | low | Confirmed as coded, but it is the 0005-established repo-wide RLS pattern (all six policies identical); app code always sets a uuid via `withTenantTransaction`. Not this story's deviation. |
| 12 | edge | Tampered `occurred_at`/`recorded_at` that `Date` cannot parse makes `verifyChain` throw RangeError (500) instead of returning a ChainBreakReport | medium | Confirmed — `canonicalInstant` is unguarded and runs inside the per-row recompute with no try/catch; the severity-1 alert path never fires for that tamper shape. |
| 13 | edge | Architecture-test regexes scan only literal table names — aliased imports (`const soh = stockOnHand; tx.insert(soh)`) evade all three gates | low | Confirmed the regexes match literal names only (read the spec file), but the fix (AST/import-statement alias resolution) adds real machinery to a documented best-effort backstop; the DB trigger + RLS are the runtime backstops. |
| 14 | vg (pre-verified) | The cross-tenant path gate `assertOwnTenant` on the two new endpoints is never exercised — a foreign-session HTTP request asserting 403 `permission-denied` exists nowhere | medium | Filed evidence complete: all suite requests carry the single suite tenant; the only foreign-tenant usage is the raw-SQL RLS probe; `listEvents` has no second gate. Delete-or-invert demonstration holds — no test would fail. |
| 15 | vg (pre-verified) | The append-only trigger on `ledger_anchors` is enforced by no test (only `ledger_events` is probed; the suite's own anchor cleanup runs under replication-role bypass) | medium | Filed evidence complete — the only trigger test touches `ledger_events` exclusively; no drift guard observes the hand-appended DDL. |
| 16 | vg (pre-verified) | `ledger_anchors` insert-side RLS (`WITH CHECK`) is the only new-table RLS arm with no test | medium | Filed evidence complete — write-side probes cover `ledger_events` and `stock_on_hand` only; a forged cross-tenant anchor would ship undetected. |
| 17 | vg (pre-verified) | The adjustment command's documented 400 branches (non-UTC `occurredAt`, zero delta) are never exercised | medium | Filed evidence complete — `occurredAt` has zero occurrences in the suite; no `quantityDelta: 0` anywhere. A dropped try/catch or removed guard ships as 500-for-400 (or a silent no-op event) without CI failing. |
| 18 | vg (pre-verified) | The 409 concurrent-same-key conflict mapping has no test (the suite's concurrency test stamps fresh keys per call, so inserts never collide) | medium | Filed evidence complete — `adjust(opsToken, …)` without a key auto-generates ULIDs; the insert-collision branch is unreachable from every existing test. |
| 19 | vg (pre-verified, "Other") | Integer `quantityDelta` beyond safe range passes `@IsInt()`, reaches `signedQuantity`'s plain Error, renders as 500 | medium | Pre-verified by that layer; independently confirmed by my read of `quantity.ts:33-38` and the command's unguarded call site. |
| 20 | blind | Anchor/digest artifacts attest ranges without checking contiguity; `anchorChain` never verifies before anchoring | medium | Confirmed (same defect as #7); the verify-before-anchor half is a fuller addition deferred separately. |
| 21 | blind | Nothing prevents duplicate/overlapping anchors under concurrency | medium | Same defect as #6 (independent trace). |
| 22 | blind | The `LedgerAnchorStore` read seam is dead: `latest()` has zero call sites, `anchorChain` re-implements the query inline — a swapped-in external WORM store would be written through the seam but never read through it | medium | Confirmed — `anchorChain` queries `ledger_anchors` directly (`lastRows` read); the seam's stated purpose (frozen block: swap without touching the chain) is defeated on the read side. |
| 23 | blind | Append-only enforcement misses TRUNCATE at both layers | medium | Same defect as #10 (independent trace). |
| 24 | blind | Tamper with an unparseable timestamp can 500 the verifier instead of reporting a break | medium | Same defect as #12 (independent trace). |
| 25 | blind | The two endpoints serialize the same ledger timestamps differently: timeline read returns raw PG timestamptz text, adjustment snapshot returns app ISO; OpenAPI promises ISO-8601 | medium | Confirmed — facade selects the raw columns (drizzle `mode: 'string'` = PG text shape); the snapshot path returns app-level ISO. The hash path normalizes via `canonicalInstant`, the read path doesn't. FE consumers in 2.5 inherit the inconsistency. |
| 26 | blind | Facade limit clamp contradicts the documented 400 (ValidationPipe + `@Min/@Max` already reject; the clamp is dead code via HTTP) | low | Confirmed — `Math.min(Math.max(...))` clamp duplicates DTO validation with opposite behavior; direct deletion. |
| 27 | blind | Timeline index omits `warehouse_id` — multi-warehouse tenants scan tenant-wide per page | low | Confirmed — index is `(tenant_id, created_at, id)`; every query filters warehouse. Direct correction (composite index). |
| 28 | blind | The 422 names the bin with an opaque uuid while the human code is fetched and discarded | low | Confirmed (`assertBinInWarehouse` returns `{id, code}`, call site discards `code`), but the fix threads `binCode` through the `LedgerMovement` envelope — added plumbing, and the uuid unambiguously identifies the bin. Rejected: unlikely met in everyday use as a harm, fix is more than a direct correction. |
| 29 | blind | Post-commit `stock.adjusted` bus event carries `occurredAt: nowIso()` (publish instant) instead of the ledger event's business time | low | Confirmed — line `occurredAt: nowIso()` in the post-commit publish; `snapshot.event.occurredAt` holds the right value. Direct one-liner. |
| 30 | blind | Cross-module reach: `idempotencyKeyReuse` imported from `tenancy/registration.command` | low | Confirmed the import, but the misplacement is pre-existing — `users/warehouse/zone/bin` commands import it within tenancy and `catalog/sku.command` + `catalog/import.command` have imported it cross-module since epic 1. Repo-wide helper-placement concern. |
| 31 | blind | Unnecessary `forwardRef` in command and facade (no cycle: `LedgerService` imports neither) | low | Confirmed — `ledger.service.ts` imports nothing from command/facade; all providers in one module. Direct deletion. |
| 32 | blind | Missing e2e coverage for diff-documented behavior: zero-delta 400, malformed `occurredAt` 400, unsafe `quantityDelta`, limit 400, cross-tenant 403, missing key 400, same-key 409, anchor validation, anchors trigger/RLS, DELETE tamper | low | Overlaps rows 14–18 (pre-verified) except the extras (limit 400, missing key 400, DELETE-then-verify probe) — all folded into the same test-batch patch. |
| 33 | blind | The reviewed diff omits the drizzle meta files the change stages (migration ships unregistered?) | false | Refuted: `git status` shows `M drizzle/meta/_journal.json` (contains the 0006 entry) and `A drizzle/meta/0006_snapshot.json` staged — the journal was excluded from the review diff by the code-only scoping, not from the change. |
| 34 | blind | Capability mirror gap acknowledged but unguarded; the interface-contract doc update is not part of this change | false | Refuted on both parts: the FE mirror drift guard is already tracked as deferred item `epic-1-retro-item-4` (logged since the epic-1 review), and `docs/repos/wms-be/README.md` IS updated (Story 2.1 section, uncommitted in the meta repo — invisible to a wms-be-only diff). |
| 35 | blind | Controller nits: identity expression on `limit`, pointless `[...page.items]` spread | low | Confirmed — both are direct deletions. |
| 36 | blind | Minor duplications: two identical `invalid-cursor` blocks in `decodeCursorSafe`; `lastSeq` recomputed every `verifyChainInTx` iteration; two separate imports from `problem.exception` | low | Confirmed — all three are direct corrections. |
| 37 | blind | OpenAPI nits: empty 201/200 `description`s; events 400 description omits skuId validation; brittle `>40` scannability floor; blind `as StockAdjustmentSnapshot` cast | low | Confirmed the description gaps (direct fills). The `>40` floor is the test's documented vacuity backstop (rejected); the snapshot cast mirrors the established epic-1 idempotency replay pattern (rejected as pre-existing). |
| 38 | edge | Architecture test regexes scan only literal table names — aliased imports evade | low | Same claim as #12's alias half; rejected there (AST machinery on a documented best-effort backstop). The TRUNCATE half routes to patch under row 10. |

**Routing (grouped by shared root cause; no intent_gap, no bad_spec, review_loop_iteration stays 0):**

- **patch** — 13 entries:
  1. Quantity-delta input bounds → 500 (rows 2, 3, 19): int4 `@Min/@Max` in the DTO + e2e cases.
  2. Scoped replay phantom divergences (rows 1, 8): filter the event fold by `binId`.
  3. Anchor/digest artifacts over incomplete ranges (rows 7, 9, 20): contiguity assertion in `anchorChain`/`exportDigest`; `verifyChain` reports a break on missing rows in an explicit range.
  4. Concurrent anchors can overlap (rows 6, 21): advisory lock in `anchorChain` + unique `(tenant_id, warehouse_id, to_seq)` index.
  5. Dead anchor read seam (row 22): route `anchorChain`'s latest-anchor read through `LedgerAnchorStore`.
  6. TRUNCATE bypass (rows 10, 23): `BEFORE TRUNCATE` statement triggers + architecture-test regex.
  7. Unparseable tampered timestamp 500s the verifier (rows 12, 24): per-row try/catch → ChainBreakReport.
  8. Timeline timestamps in PG text shape vs ISO contract (rows 5, 25): normalize through `canonicalInstant` in the facade read; strict ISO pin in `decodeCursorSafe`.
  9. Dead limit clamp (row 26): delete.
  10. Timeline index omits `warehouse_id` (row 27): composite index.
  11. Post-commit bus event business time (row 29): one-liner.
  12. Code nits (rows 31, 35, 36, 37): forwardRef removal, import merge, decodeCursor block merge, lastSeq hoist, controller identity/spread, OpenAPI descriptions.
  13. Missing e2e pins (rows 14–18, 32): cross-tenant 403, anchors trigger, anchors WITH CHECK, the two 400 branches, 409 conflict, TRUNCATE, int4 overflow, DELETE-then-verify.
- **defer** — 4 entries (appended to deferred-work.md): `idempotencyKeyReuse` helper placement (row 30); repo-wide path-param UUID validation incl. the new routes (row 4); RLS `::uuid` cast hardening on the 0005-established pattern (row 11); anchor-time chain verification beyond the contiguity check (row 20's deferred half).
- **rejected** — rows 28, 33, 34, 37-partial, 38-alias, 12-alias per the refutations above.

## Design Notes

Signed-delta quantity: `quantity.ts` brands `BaseQuantity` as non-negative; ledger events carry a signed movement delta — add a sibling branded signed-integer type rather than loosening `BaseQuantity` (on-hand stays non-negative; a projection must never go below zero — an over-draw adjustment is rejected naming the bin and current on-hand).

## Verification

**Commands:**
- `cd workspace/core/backend/wms-be && DATABASE_URL=postgres://wms:wms@localhost:55432/wms DATABASE_AUTH_URL=postgres://wms:wms@localhost:55432/wms JWT_SECRET=local-dev-secret-0123456789abcdef-9f8e7d6c5b4a bun run db:migrate && bun run test` -- expected: all existing specs green (users/catalog regressions intact) + new ledger/architecture specs pass
- `bun run db:generate && git diff --exit-code drizzle/` after schema edits -- expected: no uncommitted drift (schema ↔ migrations round-trip)
- `bun run lint && bun run typecheck` -- expected: clean
- `bun run openapi:export && git diff --exit-code openapi/` -- expected: committed spec matches routes
- Manual: mint a session JWT (HMAC, claims `sub`+`tenant_id`), POST an adjustment with an ULID idempotency key, then re-POST it — expect snapshot replay, single event row, projection unchanged; replay a second key with a mutated payload → 422.