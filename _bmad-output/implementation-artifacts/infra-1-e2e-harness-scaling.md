---
title: 'Infra 1: the wms-be e2e harness fails intermittently as suite count grows'
type: 'chore'
created: '2026-09-12'
status: 'backlog'
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

## Leads, in the order worth trying

1. **Pool sizing.** Each suite boots a Nest app whose `DATABASE` and `AUTH_DATABASE` clients each open `max: 10` (`src/shared/db/db.ts`) against a server with `max_connections = 100`, and 24 suites run serially through it. `postgres.js` queues connection requests with **no timeout**, so pressure never surfaces as an error — it surfaces as a request that waits forever, which fits the 153 s suite exactly. A per-environment `POOL_MAX` (`NODE_ENV === 'test' ? 4 : 10`) was tried during 4.3 and **did not close it** (1 failure in 5 after), so it is necessary-at-best, not sufficient. It was deliberately NOT shipped with 4.3; re-try it here as one part of a fix rather than the whole.
2. **`ProblemDetailsFilter`'s `headersSent` early-return** (`src/shared/problem-details/problem.filter.ts:64`) is the only path in the app that emits a response with no body. Worth instrumenting to catch a response whose headers were already sent, and working back to what sent them — accepting that the flake hides under instrumentation.
3. **Per-suite isolation.** Every suite shares one Postgres database and mutates `process.env.DATABASE_AUTH_URL` in `beforeAll`; under `maxWorkers: 1` that env is process-wide across every suite in the run. A database-per-suite (or at least a schema-per-suite) would remove the shared-resource coupling entirely rather than tuning it.

## Ruled out (do not re-tread)

- **Test parallelism** — `jest.config.js` sets `maxWorkers: 1`; suites are serial.
- **Suite ordering** — 16 shuffled orderings behaved the same as the default.
- **The advisory-lock id mismatch** — `picking.spec` used 742108 where others used 742107; aligned as hygiene, not a fix, and irrelevant under a single worker.
- **Teardown completeness** — every suite calls `app.close()` and ends both clients.

## Why it matters now

Epic 4 has three stories left, each adding suites. The rate scales with suite count, and a CI that is red one run in five is a CI people learn to re-run rather than read — at which point it stops catching anything, including the real defects this same review pass found (two cross-tenant credential leaks, a phantom-stock cancel hole).
