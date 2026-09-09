---
title: 'Transactional outbox substrate and relay'
type: 'feature'
created: '2026-09-09'
status: 'done'
route: 'dispatch'
baseline_commit: 'c9e0c930bf9bf4036af3d44a0403d5c5c1f912eb'
review_loop_iteration: 0
context: []
story_key: 'outbox-relay'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** Every domain event publishes post-commit through a log-only bus with no durable substrate: a crash (or a throwing bus) between commit and publish loses the event; `users.command.ts` re-publishes on idempotent replay (retro `epic-1-retro-item-3`); and stories 2.2/2.3 have no reliable delivery to consume. `outbox.seam.ts` and the `jobs/` shell exist as contracts with zero implementations.

**Approach:** Realize AD-7 for v1: an append-only `outbox_messages` table; every in-scope command appends its event to the outbox in the SAME transaction as its write, gated by `!replayed` (suppression parity — adds the missing gate to `users.command.ts`); an outbox relay in the jobs shell drains pending rows (session-advisory-locked, at-least-once), publishes through the existing `EVENT_BUS`, retries with backoff, and quarantines after N attempts (DLQ) with an operator replay path. Delivered rows delete on ack (events derive from committed state). Retrofit scope per the human's Open Question answer.

## Boundaries & Constraints

**Always:**
- Outbox append commits in the same transaction as the domain write — never post-commit.
- At-least-once delivery (crash between publish and ack re-publishes; consumers own exactly-once effect per AD-5); no delivery cursors or per-consumer state.
- Drain through explicit per-tenant context (AD-3); session-level advisory lock per drain cycle serializes relay instances; oldest-first (`created_at, id`) within a tenant; bounded `drain(limit)`, sheddable (AD-17).
- Failures retry with exponential backoff, quarantine after N=5 with last error recorded; a quarantined row re-drains only by operator action.
- Events publish through the existing `EVENT_BUS` — `LoggingEventBus` stays; no new subscriber machinery.
- `outbox_messages`: `tenant_id` + RLS declared in migration SQL only (0006 pattern); tenantTimestamps; uuidv7 ids.
- Suppression parity: every command with an idempotency replay path inserts its outbox row only when `!replayed`.

**Never:**
- No external broker/queue (Kafka, webhooks, fan-out) — Postgres + in-process relay for v1.
- No new subscriber implementations, per-subscriber state, or event-grammar changes (payloads ride as `jsonb`).
- No dashboards/sync-lag SLO surfaces (IN-07 observability is later-epic); `status/attempts/next_attempt_at/last_error` are the substrate they will read.
- No retention/cleanup job (delete-on-ack is the v1 disposition); no client-side outbox (AD-4's is a client-side mechanism).

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Command commits | Any retrofitted command, fresh key | Exactly one pending row in the SAME commit; `occurredAt` = business time | N/A |
| Idempotent replay | Same key, same payload | Snapshot returned; NO second outbox row (incl. `users.command.ts` — retro item 3) | 422 key-reuse path unchanged |
| Relay drain | N pending rows | Publishes via `EVENT_BUS` in (created_at, id) order, deletes each; empty drain = no-op | N/A |
| Publish fails | Bus throws for one event | Row stays pending; attempts+1, backoff set, last_error recorded; later rows still drain | N/A |
| Max retries exhausted | attempts >= N | Row becomes `quarantined`; operator replay resets to pending, attempts 0 | N/A |
| Concurrent drains | Two relay cycles race | Session advisory lock serializes; no event publishes twice within a cycle | N/A |
| Cross-tenant isolation | Scoped session vs table | RLS fail-closed read + `WITH CHECK` (0006 probe pattern) | N/A |

</frozen-after-approval>

## Open Questions

*(none — all resolved at CHECKPOINT 1, 2026-09-09)*

- Retrofit scope: **RESOLVED (a) — all 12 publish sites** (5 tenancy files + catalog sku/import + inventory stock.adjusted/ledger.chain_broken). Human approved "Approve and continue" with the recommendation on the table; one delivery path everywhere per AD-6 as tightened, chain_broken alert gains durability.

## Code Map

- `wms-be/src/shared/events/outbox.seam.ts` -- EXISTING contract, zero impls: `OutboxMessage` + `OutboxRelay.drain(limit)`; extend as needed, keep the shape.
- `wms-be/src/shared/events/event-bus.seam.ts` + `event-bus.ts` -- `DomainEvent` + `EVENT_BUS` token; relay publishes through it. Register sink + relay beside the `EVENT_BUS` provider in `shared.module.ts:38`.
- `wms-be/src/jobs/jobs.module.ts` -- empty shell; add the poll-loop worker; env-gate OFF in tests (tests call `drain()` directly).
- Publish sites -- `tenancy/users.command.ts:546` `publishSafely` (3 sites, none replayed-gated — retro-3 target); `registration.command.ts:135`, `warehouse.command.ts:150`, `zone.command.ts:156`, `bin.command.ts:336,445`, `catalog/sku.command.ts:268`, `catalog/import.command.ts:363`, `inventory/inventory.command.ts:187-209`, `inventory/ledger.service.ts:456` (scope per Open Question).
- `wms-be/src/shared/db/schema.ts` -- add `outboxMessages`; RLS hand-appended in migration SQL only (0006 pattern); next migration `0007`. Advisory-lock precedent: `ledger.service.ts:264,493` via `tenant-scope.ts`.

## Tasks & Acceptance

**Execution:**
- [x] schema.ts + `drizzle/0007_*.sql` -- `outbox_messages` (uuidv7 id, tenant_id, type, payload jsonb, occurred_at, status 'pending'|'quarantined', attempts, next_attempt_at, last_error; index (tenant_id, status, next_attempt_at, created_at); RLS hand-appended; no delivered state — delete-on-ack).
- [x] `src/shared/events/outbox.ts` (new) + shared.module.ts -- `PostgresOutboxSink.append(tx, message)` (in-tx insert) + `OutboxRelay.drain(limit)` (per-tenant batches under session advisory lock, oldest-first, publish via `EVENT_BUS`, delete on ack, backoff/quarantine on failure).
- [x] `src/jobs/jobs.module.ts` -- `OutboxRelayWorker`: interval poll loop calling `drain()`, env-gated off in tests, sheddable (skip a cycle when one is already running).
- [x] Command retrofit (scope per Open Question) -- replace every in-scope post-commit publish with in-tx `outbox.append` gated by `!replayed`; `users.command.ts` gains its missing gate (retro item 3); delete `publishSafely` when its last call site moves.
- [x] `test/outbox.spec.ts` (new) -- I/O matrix: in-tx append + replay suppression (incl. a users-command case), drain order + delete-on-ack, failure backoff + quarantine + operator replay, concurrent-drain lock, RLS probes; recording fake `EVENT_BUS` proves delivery (first event-observation test in the repo).

**Acceptance Criteria:**
- Given any in-scope command commits, when the tx commits, then exactly one pending outbox row exists with business-time `occurredAt` — and on idempotent replay no second row is written.
- Given pending rows, when the relay drains, then every row publishes via `EVENT_BUS` oldest-first and is deleted in the same drain; re-draining publishes nothing.
- Given a throwing bus, when the drain runs, then failed rows re-drain after backoff with attempts/last_error recorded, and rows past N attempts quarantine for operator replay.
- Given two concurrent drain cycles, when both run, then the advisory lock serializes them and no event publishes twice within a cycle.

## Design Notes

Drain: `drain(limit)` loops tenants with pending rows (`select distinct tenant_id ... where status='pending' and next_attempt_at <= now()` oldest-first). The lock spans the whole cycle, not per tenant-tx: session-level `pg_try_advisory_lock` keyed on a fixed relay id at cycle start, released at cycle end. Within the lock: batch rows per tenant in (created_at, id) order, publish each via the bus, delete on success, on failure update attempts/backoff in a per-row tx. Backoff `min(2^(attempts-1) * 5s, 5min)`; N=5 then `quarantined`. Operator replay = reset status to pending, attempts 0 (facade method or documented SQL — no HTTP surface). `ledger.chain_broken` (if in scope) has no domain write to piggyback — append it in its own small `withTenantTransaction` so the severity-1 alert is durable like every other event.

## Verification

- In `wms-be` (env vars as in spec-2-1: `DATABASE_URL`, `DATABASE_AUTH_URL`, `JWT_SECRET`): `bun run db:migrate && bun run test` -- all existing specs green + new outbox spec passes (suppression parity observable: the users replay case writes NO outbox row)
- `bun run db:generate && git diff --exit-code drizzle/` -- no drift; `bun run lint && bun run typecheck` -- clean; `bun run openapi:export && git diff --exit-code openapi/` -- no diff (no HTTP surface)
- Manual: boot with the worker enabled, register a tenant, sign in — `tenant.registered` appears in the log via the relay and `select count(*) from outbox_messages` returns 0.
## Review Triage Log

Layers: blind-hunter (20), edge-case-hunter (13), verification-gap (4+1). 38 findings → verdicts verified at cited locations.

| # | Finding (layer) | Verdict | Evidence / route |
|---|---|---|---|
| 1 | `.env.example`/CI never set `OUTBOX_RELAY_POLL_MS` (V1+B1) | medium | Verified: grep finds the var only in `src/jobs/jobs.module.ts` — delivery dormant in every wired env, table grows, old log-on-publish disappears. → **patch** (add to `.env.example` with comment) |
| 2 | `drizzle/meta/0007_snapshot.json` records `isRLSEnabled: false` (B2) | low | Pre-existing drizzle 0.45 limitation, already deferred repo-wide; extends to 0007. → **defer** |
| 3 | `status` lacks a DB CHECK (B3+E2) | low | Verified: column is bare text; a typo'd state is invisible to drain+replay. CHECK enforces the spec's own contract. → **patch** (amend 0007) |
| 4 | Tenant-discovery query seq-scans (B4) | low | Verified claim, but delete-on-ack keeps the table near-empty at v1; index work is IN-07-scale. Everyday impact negligible. → **reject** |
| 5 | No cross-tenant fairness in `drainLocked` (B5) | low | Verified logic, but starvation needs sustained multi-tenant overload; fix adds scheduling policy beyond a direct correction; v1 deployments are single-tenant. → **reject** |
| 6 | Throw from ack-delete/`markFailed` aborts whole cycle (B6+E4+E7) | medium | Verified: `drainLocked` has no try/catch around the per-tenant block; one tenant's transient DB error blocks every later tenant for the cycle (repeats while it persists). → **patch** (per-tenant/per-row isolation) |
| 7 | Row stuck pending/never quarantines if `markFailed` keeps failing (B8) | medium | Verified: bookkeeping failure leaves attempts frozen; unbounded re-drain. Same root cause as #6. → **patch** |
| 8 | Delete-on-ack row count ignored (B7) | false | Session advisory lock = single writer; no concurrent mutator of a selected row; 0-row delete unreachable. |
| 9 | Operator replay runbook only in code (B9) | low | Documented SQL exists in-code; operator-facing docs are the post-merge meta docs pass already planned. → **defer** |
| 10 | `OutboxRelayWorker` untested (B10+V3) | medium | Verified: grep finds no test referencing the worker/`parseOutboxPollMs`; the only delivery driver never executes in CI. → **patch** (stub-relay unit tests) |
| 11 | `parseOutboxPollMs`/`outboxBackoffMs` no unit tests (B11) | low | Same root cause as #10. → **patch** |
| 12 | Command appends observed for 2 of 11 event types (B12+V2) | medium | Verified: only outbox.spec reads `outbox_messages`; other suites assert ledger/audit rows, not outbox rows; 9 appends can drift silently. → **patch** (per-command row+payload assertions) |
| 13 | Quarantined-row exclusion not directly asserted (B13) | low | Verified: reset-then-drain masks the `status='pending'` filter. Same root cause as #12. → **patch** (one assertion) |
| 14 | Missing trailing newlines trip CI (B14) | false | `bun run lint` green in verification; no prettier/format gate in CI checks. |
| 15 | `' '`,`'-0'` parse as 0 = silent off (B15) | low | Same effect as unset (the default); no distinct harm. → **reject** |
| 16 | Shutdown doesn't await in-flight tick (B16+E10) | low | Verified, but harmless under at-least-once (mid-cycle cut re-delivers next boot); awaiting adds lifecycle complexity. → **reject** |
| 17 | Append-site boilerplate could be defaulted (B17) | low | Explicit message shape matches the pre-existing seam contract the spec pinned to keep. Design preference. → **reject** |
| 18 | `publishedAt` dead field on write side (B18) | false | Field is populated by `drain`'s return (`outbox.ts:212`); it's the relay's return shape, pre-existing contract. |
| 19 | Logs lose diagnostics (B19) | low | Error detail persists in `last_error` (verified) and the worker logs `error.message`. → **reject** |
| 20 | Backoff assertions wall-clock-windowed, can flake (B20) | low | Verified: `Date.now()+4s/9s` windows at :331-334, :344-345; same class as the transient catalog flake last story. → **patch** (deterministic deltas) |
| 21 | RLS policy 22P02 on non-uuid setting (E1) | low | Pre-existing repo-wide pattern (2.1 review deferred the shared `to_uuid_or_null` hardening; app code always sets validated uuids); 0007 adds the 7th policy instance. → **defer** |
| 22 | `status` CHECK (E2) | — | Duplicate of #3; grouped. |
| 23 | `drain(NaN)` aborts (E3) | false | Only callers pass integer literals / `DEFAULT_OUTBOX_DRAIN_LIMIT`; NaN unreachable. |
| 24 | One tenant's tx throw skips later tenants (E4) | — | Duplicate of #6; grouped. |
| 25 | Unparseable `occurredAt` aborts cycle (E5) | false | Column is timestamptz — reads back as Date; appends all pass `nowIso()`; garbage unreachable. |
| 26 | Non-object jsonb payload (E6) | false | Payloads written only from `Record<string, unknown>` command payloads. |
| 27 | `markFailed` failure aborts drain (E7) | — | Duplicate of #6/#7; grouped. |
| 28 | Unlock error masks drain failure (E8) | low | Verified: bare `await` unlock in `finally`; a one-line `.catch` + log is a direct correction. → **patch** |
| 29 | `append` should validate occurredAt ISO (E9) | false | timestamptz rejects garbage loudly at insert (rolls back the whole write — which is the fail-loud behavior); no bad caller exists. |
| 30 | Shutdown kills in-flight drain (E10) | — | Duplicate of #16; rejected with it. |
| 31 | `OUTBOX_RELAY_POLL_MS=1` hammers DB (E11) | low | Self-inflicted config; floor check adds validation policy beyond direct correction. → **reject** |
| 32 | Hung drain leaves `running` stuck (E12) | maybe-false | Hang needs an indefinite connection stall (no statement timeout configured); if true, silent worker stop = medium. Settle: configure/verify postgres.js connection+statement timeouts. → **defer** |
| 33 | Host-exported env var races tests (E13) | low | Verified: no `delete process.env.OUTBOX_RELAY_POLL_MS` in beforeAll; one-line guard. → **patch** |
| 34 | Relay dormant in every wired env (V1) | — | Duplicate of #1; grouped. |
| 35 | Command append coverage (V2) | — | Duplicate of #12; grouped. |
| 36 | Worker bootstrap path untested (V3) | — | Duplicate of #10; grouped. |
| 37 | chain_broken fail-loud contract unpinned (V4) | low | Verified; pinning costs a fault-injected test for a DB-broken-only arm. → **defer** |
| 38 | `cleanupRows` doesn't delete `outbox_messages` (V-other) | medium | Verified: ledger.spec (and sibling suites) leave pending rows in the shared dev DB; every suite now writes rows; pollution grows unboundedly. → **patch** (add the delete to each suite's cleanup) |

**Routing summary:** 0 intent_gap, 0 bad_spec, **9 patch groups** (#1 adoption, #3 CHECK, #6/#7 drain fault isolation, #10/#11 worker tests, #12/#13 event coverage, #20 determinism, #28 unlock catch, #33 env guard, #38 cleanup), **5 defer**, 14 rejected. No loopback (review_loop_iteration stays 0).
