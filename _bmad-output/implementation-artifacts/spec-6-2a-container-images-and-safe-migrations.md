---
title: '6-2a container images and safe migrations — production images for wms-be and wms-fe, graceful shutdown, a readiness check, a guarded migration runner, CI image builds'
type: 'feature'
created: '2026-10-23'
status: 'ready-for-dev'
route: 'dispatch'
review_loop_iteration: 0
context:
  - 'docs/initiatives/production-readiness.md'
  - 'docs/design/SYSTEM-DESIGN.md'
  - 'docs/design/IMPLEMENTATION-GUIDE.md'
  - 'docs/design/PENDING.md'
  - 'docs/design/frontend/SYSTEM-DESIGN.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** Nothing can be deployed. There is no image, no readiness check, and no graceful shutdown: the 13 workers' shutdown hooks never run. The migration runner applies everything in one transaction with no lock, so every plain index build locks its table. Six of those builds need a by-hand CONCURRENTLY runbook scattered across PENDING and SQL comments. The web app's API address is fixed at build time.

**Approach:**
- **Images.** A production image per app: wms-be on Bun, run as non-root; wms-fe as a Next.js `standalone` build with the API address supplied at runtime.
- **Lifecycle.** Graceful shutdown, and a readiness route (database, Valkey, migration state).
- **Migrations.** A guarded deploy migrator: advisory lock, dry run, and a refusal of a locking index build on a large table unless the index was pre-built.
- **Local and CI.** A production-like compose in the meta repo, and CI jobs that build each image and smoke-run it.
- **Runbook.** One deploy runbook doc.

**Decisions (recommended, taken autonomously under the user's standing instruction, 2026-10-23):**
1. **Split.** The AWS environments and the deploy pipeline are 6-2b (deferred-work). **Nothing is pushed or applied anywhere real**; images are built and smoke-tested in CI only.
2. **One wms-be image for every process.** The API task and the worker task(s) run the same image and differ only by the existing `*_POLL_MS` env vars (the jobs are already gated that way). There is no new entrypoint.
3. **Bun pinned to CI.** wms-be `packageManager`/`.bun-version` = `1.4.0`; wms-fe = `1.4.2` (their CI versions). Each image uses `oven/bun:<that version>-alpine`. The old `1.2.20` pin is removed.
4. **wms-be image.**
   - **Build:** multi-stage, `bun install --frozen-lockfile --production`; it copies `src`, `drizzle`, `scripts/provision-roles.sql` and `tsconfig*`.
   - **Run:** user `bun` (non-root), `CMD ["bun","src/main.ts"]`, `EXPOSE 3000`, a `HEALTHCHECK` on `/api/v1/health`.
   - **Files:** a `.dockerignore`. No secrets in the image.
5. **Graceful shutdown.** `app.enableShutdownHooks()`. On SIGTERM the HTTP server stops accepting, in-flight requests finish (≤ 25 s, under a 30 s stop timeout), workers stop their timers and finish the current tick (their existing `onModuleDestroy` hooks), and the DB and Valkey pools close.
6. **Readiness.** A new **`GET /api/v1/health/ready`** (unauthenticated, no tenant data):
   - `select 1` on both pools;
   - a Valkey `PING`;
   - the database's latest applied migration (drizzle's migrations table) equals the image's bundled journal's last entry.

   Each failing check gives **503** naming it; otherwise 200 `{status:'ready', migration:'<tag>'}`. `/health` stays a liveness check only.
7. **The guarded migrator** (`bun run db:migrate:deploy`, `src/shared/db/migrate-deploy.ts`) runs these steps in order:
   1. Take a session `pg_advisory_lock` (one migrator at a time).
   2. List the pending migrations.
   3. For each pending SQL, find its `CREATE [UNIQUE] INDEX` statements on existing tables. If the target table's estimated rows (`pg_class.reltuples`) is at least **`MIGRATE_LARGE_TABLE_ROWS` (default 100 000)** and that index does not already exist **and valid** (`pg_index.indisvalid`), **refuse**, printing the exact `CREATE INDEX CONCURRENTLY IF NOT EXISTS …` to run first (the runbook).
   4. `--dry-run` prints the plan and changes nothing; `--allow-locking` overrides the refusal (logged).
   5. Then it calls the existing drizzle migrate.

   `db:migrate` (dev and tests) is unchanged.
8. **wms-fe image and runtime config.**
   - **Build:** `output: 'standalone'` in a multi-stage image. The standalone `server.js` runs on **`node:22-alpine`** (Next's standalone server targets Node; Bun is used only to install and build). Port **`PORT` default 3001**.
   - **Runtime API address.** `NEXT_PUBLIC_API_BASE_URL` stays the dev and build default. A runtime **`WMS_API_BASE_URL`** is read by the server and injected as `window.__WMS_CONFIG__ = {apiBaseUrl}` in the root layout; `src/lib/api/base-url.ts` prefers it. One image then serves every environment.
9. **Compose.** Meta `deploy/compose.yml` builds both images from the workspace paths and runs Postgres 18, Valkey 9.1, a one-shot `migrate` service (`db:migrate:deploy` then `provision-roles.sql`, as the docs order it), the API, one worker and the web app. `.env` values are documented; no real secrets.
10. **CI.** Each repo's CI gains an **`image`** job: `docker build`, then run the container (wms-be against service Postgres and Valkey after migrating), then `curl` `/health` and `/health/ready` (or the web root). **No push.** Registry push is 6-2b.
11. **Runbook.** A new meta `docs/design/DEPLOY.md`:
    - the processes and their env vars (every var from `.env.example`, with the API vs worker split, and the missing `COUNT_SCHEDULER_POLL_MS`);
    - the required secrets;
    - the deploy order (migrate → readiness → roll);
    - **one consolidated CONCURRENTLY table** for 0058, 0061, 0069, 0078, 0081 and 0088 (the missing 0088 entry added) with the exact statements, plus the 0087 CHECK-scan note;
    - the cookie same-site domain rule (`PENDING:200`);
    - the role provisioning.

**Design-review amendments (recommended, taken autonomously, 2026-10-23) — these OVERRIDE decisions 5–11 where they differ:**
- **A1 Shutdown order.** It follows Nest's real hook order (`nest-application-context.js:126-129`):
  - **Workers:** each keeps its in-flight `tick()` promise; `beforeApplicationShutdown` clears the timer and awaits the tick (bounded).
  - **HTTP:** closes in `dispose`, created with `forceCloseConnections: true`.
  - **Pools:** a new lifecycle provider (never through `lazyDatabaseProxy`) runs `end({timeout})` for Postgres and `quit` for Valkey in `onApplicationShutdown`.
  - **Bound:** a 25 s `setTimeout(...).unref()` force exit. The order is tested.
- **A2 Readiness is "at or after", never "equal".**
  - **Ready** when the DB's latest applied migration is at or after the image's last journal entry: `max(created_at)` of `drizzle.__drizzle_migrations` ≥ the journal's last `when`. The `migration` field reports the tag matched by `when`.
  - **Behind** → 503 `migrations-behind`. **Ahead** → ready, because migrations are additive (a stated assumption; a matrix row is added).
  - **Grants:** `provision-roles.sql` grants `wms_app` usage on schema `drizzle` and select on its table.
  - **CI:** the smoke runs as `wms_app`, not the superuser.
- **A3 Index guard.**
  - **What it refuses:** any pending `CREATE [UNIQUE] INDEX` on an existing large table **without `IF NOT EXISTS`** (pre-building would then fail the migration with 42P07), and a missing or invalid index the operator must pre-build (the CONCURRENTLY statement is printed).
  - **Lint:** a test requires `IF NOT EXISTS` on every `CREATE INDEX` in migrations **≥ 0089** (0001–0088 run on empty tables in a first production deploy; none exists yet).
  - **Docs:** DEPLOY.md's table adds 0086 and states it is for re-deploys of existing databases.
- **A4 Size detection.** `reltuples < 0` (never analysed) is unknown, so it falls back to `pg_relation_size` ≥ `MIGRATE_LARGE_TABLE_BYTES` (default 64 MB). A test row covers it.
- **A5 Parser scope.**
  - Split on `--> statement-breakpoint` (as drizzle does) and strip comments.
  - Match `CREATE [UNIQUE] INDEX [IF NOT EXISTS] "n" ON ["s".]"t"`.
  - `DO`/`EXECUTE` blocks mentioning INDEX, and `ADD CONSTRAINT … UNIQUE|PRIMARY KEY`, are reported **"unparsed, review"** and refused unless `--allow-locking`.
  - Tables created earlier in the pending set are excluded.
  - Pending files come from `readMigrationFiles` (drizzle-orm/migrator) with drizzle's own `folderMillis > max(created_at)` rule.
- **A6 Lock.** One reserved connection (`$client.reserve()`, the outbox-relay pattern) holds `pg_advisory_lock` across the whole `migrate()` call. `lock_timeout` and `statement_timeout` are set. The test proves a second migrator waits and applies nothing twice.
- **A7 Web runtime config.**
  - **Delivery:** a dynamic route `/runtime-config.js` (never prerendered) serves `window.__WMS_CONFIG__ = {apiBaseUrl}` from `WMS_API_BASE_URL`, loaded by a `<script>` in the layout before the app scripts.
  - **Call-time reads:** `getApiBaseUrl()` is resolved at call time, and the import-time constants are converted: `base-url.ts:7`, `client.ts:487,494` (the generated client's `baseUrl` set lazily), `session-refresh.ts:21` and `channels-view.tsx:711`.
  - **CSP:** no CSP exists today, so a nonce is noted as PENDING for when CSP lands.
- **A8 One worker task.** DEPLOY.md requires **exactly one** worker task, deployed stop-then-start (minimum healthy 0%). Reconciliation, ReservationReaper, CountScheduler, ReplenishmentScheduler, ChannelsSync, WaveCutoffSweep and SessionPurge are not proven safe to run twice (PENDING: audit them).
- **A9 Env list from code.**
  - **Source:** DEPLOY.md's env list is built from a grep of `process.env.*`, and `.env.example` is fixed to match. It gains `CHANNELS_SYNC_POLL_MS`, `CHANNEL_ENCRYPTION_KEY`, `COOKIE_SECURE`, `EWAY_GATEWAY`, `MFA_ENCRYPTION_KEY_PREVIOUS` and `COUNT_SCHEDULER_POLL_MS`, while `NODE_TLS_REJECT_UNAUTHORIZED` is documented as never-in-production.
  - **Test:** every var the code reads appears in `.env.example`.
  - **Behind the ALB:** `TRUSTED_PROXY_HOPS=1` (else every caller rate-limits as the ALB), and `CORS_ORIGIN` = the web origin.
- **A10 Smaller items.**
  - The `ready` route goes through `openapi:export`, the FE client regen and API-SURFACE.
  - `HEALTHCHECK` uses `bun -e "fetch(…).then(r=>process.exit(r.ok?0:1))"` (alpine has no curl).
  - `provision-roles.sql` runs on every deploy, as the migrating owner, with passwords set out of band.
  - The implementer **verifies** that the `oven/bun:1.4.0-alpine`/`1.4.2-alpine` tags exist, and that the Bun-installed musl `sharp`/`@next/swc` work in `node:22-alpine`, recording both.

## Boundaries & Constraints

**Always:**
- No secrets in images or compose files (`.env.example`-style placeholders only).
- The images run as non-root.
- A failing readiness check never leaks internals (check names only).
- The migrator's refusal is deterministic and tested, against a seeded large-estimate table in a test database (set `reltuples` by `ANALYZE` on generated rows, or stub the estimate through a seam).
- `db:migrate`, the tests' template build and the existing CI jobs are unchanged.

**Never:**
- No cloud resources, no registry push, no IaC (6-2b).
- No DB migration.
- No change to the worker gating.
- No mobile build changes.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|---|---|---|---|
| Ready | DB and Valkey up, migrations current | `/health/ready` 200 `{status:'ready', migration:'0088_…'}` | — |
| Behind | the image bundles 0089, the DB is at 0088 | 503 `migrations-behind` | — |
| Ahead | the DB is at 0089, the image bundles 0088 (old tasks during a roll) | 200 ready | — |
| Never-analysed large table | `reltuples = -1`, 200 MB | refused as large by size | — |
| Index without IF NOT EXISTS | pending plain `CREATE INDEX` on a large table | refused: rewrite the migration with IF NOT EXISTS | — |
| Valkey down | — | 503 `valkey` | — |
| SIGTERM | requests in flight, workers ticking | in-flight requests finish; no new requests; workers finish their tick; exit 0 within 30 s | — |
| Migrate, small table | pending `CREATE INDEX` on a small table | applied | — |
| Migrate, large table, not pre-built | estimated rows ≥ threshold | refused, printing the CONCURRENTLY statement; nothing applied | — |
| Migrate, large table, pre-built and valid | the index exists and is valid | applied (`IF NOT EXISTS` skips) | an invalid index → refused, with drop and rebuild advice |
| Two migrators | concurrent runs | the second waits on the lock | — |
| Dry run | `--dry-run` | prints the plan; no change | — |
| FE runtime config | `WMS_API_BASE_URL=https://api.x` | the browser calls `https://api.x` | unset → build default |
| Image smoke (CI) | built image + services | `/health` and `/health/ready` 200 | the job fails |

</frozen-after-approval>

## Code Map

### wms-be

- `Dockerfile` and `.dockerignore` (new).
- `package.json` `packageManager` and `.bun-version`.
- `src/main.ts` and `src/app.factory.ts`: `enableShutdownHooks`, a bounded shutdown (a 25 s force exit), pool closes in their modules' `onModuleDestroy`/`onApplicationShutdown`.
- `src/api/health.controller.ts`: the `ready` route; a small `ReadinessService` (pools, the Valkey client, the bundled journal read from `drizzle/meta/_journal.json`).
- `src/shared/db/migrate-deploy.ts` (new) and a `db:migrate:deploy` script, with a seam for the row estimate.
- `.github/workflows/ci.yml`: the `image` job.
- Tests:
  - `test/readiness.spec.ts` (ready, behind, Valkey down through a stub);
  - `test/migrate-deploy.spec.ts` (refuse, pre-built valid or invalid, dry run, lock);
  - a shutdown unit test (worker timers cleared).

### wms-fe

- `Dockerfile`, `.dockerignore`, `next.config.ts` (`output: 'standalone'`).
- `package.json` (`packageManager`, `start` with `PORT` default 3001).
- `src/app/layout.tsx`: injects `__WMS_CONFIG__` from `process.env.WMS_API_BASE_URL` (escaped JSON).
- `src/lib/api/base-url.ts`: prefers it.
- `.github/workflows/ci.yml`: the `image` job.
- Tests for `base-url.ts` and the layout injection.

### Meta

- `deploy/compose.yml` and `deploy/.env.example` (new).
- `docs/design/DEPLOY.md` (new).
- PENDING: close the scattered CONCURRENTLY entries into DEPLOY.md, with pointers; 6-2b.

## Tasks & Acceptance

**Execution:**
- [ ] wms-be: image, Bun pin, shutdown, readiness, migrate-deploy, CI image job, tests.
- [ ] wms-fe: image, standalone, runtime config, port, CI image job, tests.
- [ ] Meta: compose, DEPLOY.md, PENDING; `SYSTEM-DESIGN.md` (processes, readiness, the migrator); frontend SYSTEM-DESIGN (runtime config); READMEs.

**Acceptance Criteria:**
- Given `deploy/compose.yml`, when `docker compose up` runs locally, then migrate completes, the API reports ready, the worker runs its jobs, and the web app on `:3001` signs in against the API.
- Given a pending migration with a plain index on a table estimated over 100 000 rows, when `db:migrate:deploy` runs, then it refuses and prints the CONCURRENTLY statement, and applies after the index is pre-built.

## Design Notes

- **Why refuse instead of rewriting migrations to CONCURRENTLY.** drizzle runs pending migrations in one transaction, which cannot contain CONCURRENTLY. Pre-building the index by hand under the same name, then letting `IF NOT EXISTS` skip it, is the repo's existing runbook; the migrator now enforces it instead of trusting a reader of PENDING.

## Verification

**Commands:**
- wms-be: `bun run test -- test/readiness.spec.ts test/migrate-deploy.spec.ts` + lint + typecheck; `docker build .` and a smoke run.
- wms-fe: `bun test`, typecheck, lint, `bun run build` (standalone), `docker build .`.
- meta: `docker compose -f deploy/compose.yml config` validates.

## Implementation Notes

## Spec Change Log

## Review Triage Log

Design review, 2026-10-23 (D). Every accepted finding is folded into the spec above; all choices are recommended, taken autonomously. The amendments are A1–A10.

| ID | Verdict | Finding → resolution |
|---|---|---|
| D3 | critical | Readiness "equals" would 503 every old task after a migrate (outage). "At or after" (A2). |
| D5 | critical | Most existing index statements lack IF NOT EXISTS, so pre-building fails them. The guard refuses them; a lint for new migrations; 0086 added (A3). |
| D1 | high | No worker awaits its in-flight tick. Await in `beforeApplicationShutdown` (A1). |
| D2 | high | Pool close in the wrong phase; keep-alive sockets block close. The real hook order; `forceCloseConnections`; a lifecycle provider (A1). |
| D4 | high | drizzle stores no tag; the app role can't read the drizzle schema. Compare `created_at`/`when`; grants; smoke as `wms_app` (A2). |
| D6 | high | `reltuples = -1` reads as small. Size fallback (A4). |
| D9 | high | The layout is prerendered at build time; import-time URL constants. A dynamic route; call-time resolution (A7). |
| D7 | medium | Parser scope unstated (`DO` blocks, constraints, same-set tables). A5. |
| D8 | medium | Lock mechanics. A reserved connection across `migrate()` (A6). |
| D10 | medium | Seven workers are not proven safe to run twice. One worker task, stop-then-start; audit PENDING (A8). |
| D11 | medium | The env list is narrower than the code; proxy hops; CORS. From a grep, with a test (A9). |
| D12 | medium | OpenAPI regen; healthcheck command; role provisioning; unverified tags and binaries. A10. |

