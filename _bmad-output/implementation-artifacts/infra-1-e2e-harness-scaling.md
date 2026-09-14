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

## Outcome: partial (superseded — see RESOLVED below)

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

## RESOLVED by infra-2 — and the cause was outside this codebase

**supertest binds each suite's server with `app.listen(0)`** (`lib/test.js:63`), so the OS assigns a port from the **ephemeral range** (49152–65535 on macOS). Other local services live in that same range. On the machine where this was investigated, **Ollama's UI listened on `127.0.0.1:56745`**. A request built against a port the test server no longer owned reached Ollama, and the suite received a valid `200 OK` carrying a 6.3 KB HTML page titled *Ollama*.

Every symptom follows from that: a wrong-but-valid status on an unrelated route, a different test each run, no relation to what changed, immunity to database isolation, sensitivity to timing rather than logic, and correlation with suite count only because more suites mean more server churn.

**Fix (WMS-BE #26):** one jest setup file patches `net.Server.prototype.listen` so `listen(0)` binds into 21000–24999, retrying on `EADDRINUSE`. The OS never auto-assigns from that range.

**Verification:** 15 consecutive fresh-database full runs, 15 clean, with Ollama still listening on 56745 throughout — the hostile condition present, not removed.

| Stage | Failure rate |
| --- | --- |
| Before any work | ~1 in 5 |
| After infra-1's per-suite databases | ~1 in 7 |
| After infra-2's port fix | **0 in 15** |

## The premise of this story was wrong

**CI never saw this.** Fifteen of fifteen recent CI runs succeeded across every branch, because nothing else listens in that range on a runner. The claim that drove both infra stories — that CI was untrustworthy and would degrade as suites were added, and therefore should land before story 4.4 — was false. This only ever cost local runs.

## The lesson, for whoever hits something like this next

Nine hypotheses were eliminated before the right one, and **every single one was about our own system**: parallelism, ordering, advisory locks, teardown, pool sizing, HTTP keep-alive, idempotency-key collision, ULID collision, shared database state. The bug was outside it.

The tell was present in the very first failure examined — a `200` on a route where this app has **no code path that returns 200** — and it was read as "a different handler of ours" rather than "not our app at all".

**Capture the response body, not just its status.** One failing response body ended an investigation that nine measured hypotheses could not. The body said `<title>Ollama</title>`.

## What infra-1 still bought

Per-suite database isolation is kept on its own merits, independent of a flake it did not cause: migrations run **once per run** instead of once per suite (a full run takes ~50 s), suites can no longer corrupt each other's fixtures, idempotency rows, advisory locks or connection budget, and `maxWorkers: 1` — which existed only because suites shared a database — is now a free choice rather than a constraint.
