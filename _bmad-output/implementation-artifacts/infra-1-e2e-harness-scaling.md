---
title: 'Infra 1: the wms-be e2e harness fails intermittently as suite count grows'
type: 'chore'
created: '2026-09-12'
status: 'in-progress'
route: ''
---

## Problem

The `wms-be` e2e suite fails **intermittently — roughly 1 run in 5** — once the suite count grows past the low twenties. A different test fails each time, in a different suite, with no relationship to what changed.

This is **not** caused by any feature story. It was found during story 4.3's review and initially misattributed to it; the experiment below settles that.

## Evidence

Procedure for every run: drop the `public` and `drizzle` schemas, `FLUSHALL` Valkey, `bun run db:migrate`, `bun run test`.

| Tree | Suites | Result |
| --- | --- | --- |
| `main` | 22 | 6 runs, 0 failures (two separate batches of 3) |
| story 4.3 branch | 24 | 1 failure in 5 (and 3-in-3 before two real bugs in it were fixed) |
| **`main` + 2 throwaway duplicate suites, zero 4.3 code** | **24** | **1 failure in 5** |

The last row is the decisive one: copying `waves.spec.ts` and `orders.spec.ts` to `zz-dup-a.spec.ts` / `zz-dup-b.spec.ts` on `main` reproduces the same failure rate with none of 4.3's code present. Suite **count** is the variable, not the story.

## Failure signature

- Always a **wrong bare HTTP status on an unrelated route** — observed: `expected 201, got 200` (orders create), `expected 409, got 200` (PO amend), `expected 200, got 403` (sign-in), plus occasional 5 s test timeouts with one suite stalling for ~153 s.
- Never the same test twice; observed across `orders`, `receiving`, `catalog`, `devices`, `inbound`, `picking`.
- **Vanishes under instrumentation** — which marks it as timing, not logic.

## What shipped

**One database per e2e suite.** `test/support/global-setup.js` builds a `wms_template` database once per run and migrates it; `useSuiteDatabase(slug)` in `test/support/suite-db.ts` clones it per suite and rewrites `DATABASE_URL`/`DATABASE_AUTH_URL` before the app is created, so everything downstream follows without touching each suite's internals. The clone is dropped in `afterAll`, and leftovers from an interrupted run are swept at the next `globalSetup`. 19 suites converted; `architecture`, `outbox-worker` and `pick-truncation` never touch Postgres and were left alone.

Wins independent of the flake:

- Migrations run **once per run** instead of once per suite; a full run dropped to **~50 s**.
- Suites can no longer corrupt each other's fixtures, idempotency rows, advisory locks or connection budget.
- `maxWorkers: 1` exists only because suites shared a database. That constraint is now gone and parallelism could be raised — deliberately NOT done in the same change, because it would have invalidated the flake measurement.
- Two `pg_stat_activity` probes (`ledger`, `putaway`) were scoped with `datname = current_database()`; that view is cluster-wide and they were one step from counting a sibling database's backends.

## Outcome: partial

The flake is **reduced, not eliminated** — 15 consecutive fresh-database runs after the change: **13 clean, 2 failed** (~1 in 7, from ~1 in 5).

The two failures were `tenancy` with the original `expected 201, got 200` signature, and `ledger`'s lock-waiter probe timing out.

**The `tenancy` failure is the important result**: the original signature still occurs while every suite has its own database. Shared database state was never the cause.

## Ruled out, each by measurement

Do not re-tread these. Every one cost a batch of runs:

| Hypothesis | Verdict |
| --- | --- |
| Test parallelism | `maxWorkers: 1` — suites are serial |
| Suite ordering | 16 shuffled orderings behaved identically |
| Advisory-lock id mismatch | Irrelevant under a single worker |
| Teardown completeness | Every suite closes its app and both clients |
| Connection-pool sizing | 10 → 4 in the test env: no effect (1 failure in 5) |
| HTTP keep-alive | No effect — and `superagent` sets `agent: false`, so supertest never pooled sockets in the first place |
| Cross-suite idempotency-key collision | Every key is a ULID (80 random bits); replays return **201** here, so an observed 200 is a different handler's response, not a replay |
| ULID collision | `crypto.getRandomValues`, 80 bits |
| **Shared database state** | **Disproven by this story's own change** |

## What is left, and what is known about it

The residual failure is in the **HTTP/app layer, not the database**. A POST that normally answers 201 occasionally answers 200, on an isolated database, with a fresh idempotency key, over a non-pooled socket. In this codebase a POST answering 200 means a handler that declares `@HttpCode(HttpStatus.OK)` — so the response looks like it came from a *different route than the one requested*.

Next steps for whoever picks this up:

1. Instrument server-side (not client-side — the bug hides from client instrumentation): log method, matched route handler and status for every request, and catch the mismatch at the source.
2. Determine whether the `ledger` lock-waiter probe is the same bug or an independently timing-sensitive test; it polls `pg_stat_activity` for a blocked backend and gives up after a fixed number of tries.
3. Consider whether raising `maxWorkers` now changes the rate — it would be strong evidence either way, and it is newly safe to try.
