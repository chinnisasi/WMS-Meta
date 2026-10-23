---
title: '6-2c runtime hardening — keep-alive above the ALB (proven under Bun), a worker heartbeat on a health-only listener, a bounded web drain, a Bun in-image drain smoke, digest-pinned root-owned images, the RDS CA with verify-full'
type: 'feature'
created: '2026-10-23'
status: 'ready-for-dev'
route: 'dispatch'
review_loop_iteration: 0
context:
  - 'docs/initiatives/production-readiness.md'
  - 'docs/design/SYSTEM-DESIGN.md'
  - 'docs/design/IMPLEMENTATION-GUIDE.md'
  - 'docs/design/DEPLOY.md'
  - 'docs/design/PENDING.md'
  - 'docs/design/frontend/SYSTEM-DESIGN.md'
  - '_bmad-output/implementation-artifacts/spec-6-2a-container-images-and-safe-migrations.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** The images 6-2a built and 6-2b deploys are not safe to put behind real traffic yet. These are the gaps:
- **Keep-alive.** The API closes idle keep-alive sockets after 5 s, but the ALB keeps them for 60 s. The ALB can reuse a socket the API just closed, which gives intermittent 502s. This is the go-live gate (DEPLOY.md §8.8 on #219).
- **Worker health.** A worker whose job loop has hung still answers 200, and its port serves the full API.
- **Web drain.** The web's drain has no bound, and it exits 143.
- **Drain under Bun.** The drain is proven on Node only. The image runs Bun.
- **Base images.** They are pulled by mutable tags, and the web image is owned by its runtime user.
- **Database TLS.** Connections use `sslmode=require`, which postgres.js turns into `rejectUnauthorized: false`: encrypted, but no certificate check.

**Approach:** Make code and image changes in wms-be and wms-fe, each proven by a test or an in-image CI smoke. Expose the interface that 6-2d's Terraform and pipeline will consume. Update the meta docs and compose to match.

**Decisions (recommended, taken autonomously, 2026-10-23):**
1. **Scope and split.** 6-2c covers wms-be, wms-fe, and the meta docs plus `deploy/compose.yml`. Anything in `infra/**` or `.github/workflows/deploy.yml` goes to **6-2d** (deferred-work), because those files exist only on unmerged WMS-Meta #219. Nothing is pushed and no AWS call is made.
2. **BE keep-alive.** `createApp` sets `keepAliveTimeout = 65_000` and `headersTimeout = 66_000` on `app.getHttpServer()` for every caller. They are exported constants, not env vars, because they are tied to the ALB's 60 s. Proof under Bun is the CI image smoke (decision 8).
   - **Bun facts** (recorded in Design Notes): the server honours `keepAliveTimeout`. It accepts `headersTimeout` but does not enforce it. The value is still set for parity with Node, since jest runs on Node.
3. **Web keep-alive.** The wms-fe image sets `ENV KEEP_ALIVE_TIMEOUT=65000`, which Next's standalone `server.js` reads. The web target group sits behind the same ALB, so it faces the same 502 race. That makes this part of the same gate, even though the original list omitted it.
4. **Process role.** A new `WMS_PROCESS_ROLE` takes `api` (the default, when unset) or `worker`. Any other value makes boot exit 1.
   - **`worker`:** the Nest app is initialised with **no API listener** (`createApp(false)` then `app.init()`). A health-only `node:http` listener runs on `PORT`. If no job is enabled, boot exits 1.
   - **`api`:** unchanged, including local dev running jobs in one process when `*_POLL_MS` are set.
5. **Heartbeat lives in process, not in Valkey.** This overrides the "Valkey key per job" note in 6-2b's decision 10, for two reasons. The health check must judge *this* task's loop: a shared key could be fresh from another task. And Valkey being down must not restart the worker (the C28 shared-dependency rule).
   - **Stamping:** `InFlightTick.track(job, pollMs)` registers an enabled job. Every settled tick stamps `lastSettledAt`, which starts at registration time.
   - **Staleness:** a job is **stale** when `now − lastSettledAt > max(3 × pollMs, WORKER_HEARTBEAT_STALE_MS)`. The default for `WORKER_HEARTBEAT_STALE_MS` is 900 000, and it must be a positive integer, otherwise boot exits 1.
   - **What it signals:** loop liveness only. A tick that throws still settles; errors stay in the logs and belong to 6.3 alarms.
6. **Worker routes** (health-only listener; anything else gets 404):
   - **`GET /api/v1/health`:** 200 with the API's liveness body, so the current #219 health check keeps working.
   - **`GET /api/v1/health/worker`:** 200 `{status:'ok', jobs:[{job, pollMs, lastTickAt, staleAfterMs}]}`, or 503 `application/problem+json` with `code:'worker-stale'`, `detail:'Stale: <jobs>'` and `failing:[<jobs>]` (the `not-ready` shape).
   - **Shutdown:** the listener closes in `onModuleDestroy`.
   - **Not an OpenAPI route:** no client regeneration is needed. API-SURFACE gets a note.
7. **Bounded web drain.** `scripts/start-standalone.mjs` keeps Next's own SIGTERM drain (`server.close`, then `nextServer.close`) and adds two things:
   - a bound: an unref'd timer, `WEB_SHUTDOWN_FORCE_EXIT_MS` (default 25 000), that ends in exit 1;
   - a `process.exit` wrapper that maps Next's 143 (SIGTERM) and 130 (SIGINT) to **0**, but only after the wrapper's own listener saw that signal.
8. **In-image smokes on the BE CI `image` job.** A committed `scripts/image-smoke.ts`, run with Bun on the runner against the container, has two modes:
   - **`keepalive`:** the response carries `Keep-Alive: timeout=65`, and a second request on the same socket after **61 s** idle answers 200.
   - **`drain`:** send `POST /api/v1/echo` with half the body, SIGTERM the container, send the rest 3 s later. Expect 200 with the echo, a new connection during the drain getting no 200, and container exit **0**.
   - **FE equivalents:** the FE `image` job checks that an idle SIGTERM exits 0, and a 61 s keep-alive reuse through the same script copied into wms-fe.
9. **Digest pins.** Every `FROM` is a literal `image:tag@sha256:<multi-arch index digest>`, and the `BUN_VERSION`/`NODE_VERSION` ARGs are removed.
   - **Test:** one per repo asserts every `FROM` carries a digest, that the bun tag equals `.bun-version`, and that the FE node tag is `22-alpine`.
   - **Refresh:** no Dependabot; refreshing pins goes to PENDING.
10. **wms-fe image is root-owned.** It has no `--chown`. Only `/app/.next/cache` is created and owned by `node`. CI asserts the cache is writable and that `server.js` and `.next/server` are not.
11. **RDS CA and verify-full.**
    - **The bundle:** commit AWS's public **global** bundle as `certs/rds-global-bundle.pem` (it covers `rds-ca-rsa2048-g1`, #219 `data.tf:60`). The image copies it root-owned and sets `ENV PGSSLROOTCERT=/app/certs/rds-global-bundle.pem`.
    - **The helper:** a new `postgresTlsOptions(url, env)` is applied wherever a pool is created (`db.ts`, `migrate-deploy.ts`, `provision-roles.ts`).
    - **`verify-full`:** read the PEM from `PGSSLROOTCERT` and pass `ssl: {ca, rejectUnauthorized: true}`, which overrides the URL's sslmode.
    - **`verify-ca`:** refused (use verify-full).
    - **`sslrootcert` in the URL:** refused, because postgres.js forwards it as a startup parameter and the server fails with 42704.
    - **Missing or unreadable `PGSSLROOTCERT`, or a file with no certificate:** a clear error.
    - **Other sslmodes:** unchanged. In production, a one-time warning names the pool when sslmode is not `verify-full`. It is a warning, not a refusal, until 6-2d flips the URLs.
12. **CI TLS smoke** (BE `image` job). Generate a throwaway CA and start a TLS Postgres on a docker network with alias `pg-tls` (in the SAN), then run `db:migrate:deploy` from the image in three ways:
    - with `?sslmode=verify-full` and `PGSSLROOTCERT` set to the CI CA: succeeds;
    - with the image's default bundle: fails, exit non-zero;
    - through an alias that is not in the SAN: fails.
13. **Meta lands last, after #219.** DEPLOY.md, PENDING, SYSTEM-DESIGN and the contracts are also edited by #219, so the meta PR is opened after #219 merges (rebased onto it). `deploy/compose.yml`'s worker gets `WMS_PROCESS_ROLE=worker` and a healthcheck on `/api/v1/health/worker`.
14. **What does not change.** No DB migration (checked: the heartbeat is in memory, and TLS is client-side). No mobile change. No OpenAPI change. Worker gating is unchanged.

**The interface 6-2d consumes:**
- **Worker task:**
  - env `WMS_PROCESS_ROLE=worker`, and optionally `WORKER_HEARTBEAT_STALE_MS`;
  - healthCheck `bun -e "fetch('http://127.0.0.1:3000/api/v1/health/worker').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"`;
  - port 3000.
- **DB URLs:** `?sslmode=verify-full`, once an image from 6-2c is running.
- **Image env:** `PGSSLROOTCERT` and `KEEP_ALIVE_TIMEOUT` are baked into the images; there is nothing to set.
- **Exit codes:** BE and FE exit 0 on a graceful stop. BE exits 1 on the force exit or a boot refusal (bad role, no jobs, bad TLS configuration). FE exits 1 on the drain bound or a bad `WMS_API_BASE_URL`.

## Boundaries & Constraints

**Always:**
- Every claim about Bun is proven in the built image in CI, not on Node.
- No secrets in images. The CA bundle is public and committed.
- `.env.example` documents every new variable the BE reads (`test/env-example.spec.ts`).
- The images stay non-root.

**Never:**
- No edits under `infra/**` or `.github/workflows/deploy.yml` (6-2d).
- No registry push and no AWS call.
- No `NODE_EXTRA_CA_CERTS`: it would widen the trust used for every outbound TLS call.
- No test-only route in the production image.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|---|---|---|---|
| ALB reuse | API image, idle keep-alive 61 s, then a request | 200 on the same socket; `Keep-Alive: timeout=65` | — |
| Drain under Bun | echo request in flight at SIGTERM | 200 echo; a new connection gets no 200; exit 0 | past 25 s → exit 1 |
| Worker healthy | role worker, jobs ticking | `/health/worker` 200 lists every enabled job | — |
| Worker hung | a tick never settles past `max(3×poll, 15 min)` | 503 `worker-stale`, `failing:['<job>']` | — |
| Worker misconfig | role worker, no `*_POLL_MS` / role `foo` / bad stale ms | exit 1 with the reason | — |
| Worker API surface | role worker, `GET /api/v1/tenants/me` | 404 (health-only listener) | — |
| Web drain | SIGTERM, render in flight | finishes; exit 0 | hung past 25 s → exit 1 |
| verify-full | RDS URL `?sslmode=verify-full`, bundled CA | connects, cert and host verified | wrong CA / host not in SAN → connect error |
| verify-full, no CA | `PGSSLROOTCERT` unset or unreadable | pool creation throws naming `PGSSLROOTCERT` | — |
| sslrootcert in URL | `?sslrootcert=/x` | throws: use `PGSSLROOTCERT` | — |
| require in production | `NODE_ENV=production`, `sslmode=require` | connects; one warning per pool | — |

</frozen-after-approval>

## Design Review Amendments

Design review, 2026-10-23: a claims check (K1–K15, against origin/main, with experiments) and a blind review (B1–B18). All choices are recommended, taken autonomously. **These amendments override the frozen Intent wherever they differ.**

**A1 — The web drain stops keep-alive (K1; amends decision 7).** The wrapper captures Next's `http.Server` before `await import(server)`, by wrapping `http.createServer` on the `node:http` module object (Next calls `_http.default.createServer`, `start-server.js:31,247`). On SIGTERM it does three things:
- sets `keepAliveTimeout = 1`;
- adds `Connection: close` to every response not yet sent;
- calls `closeIdleConnections()` after each response finishes.

Why it is needed: without it, a keep-alive client whose request was in flight at SIGTERM holds Next's `server.close` open until the keep-alive timeout expires, which is 65 s after decision 3. Verified in node 22: the process was still alive at 10 s. With the fix it exited 1 s after the response.

**A2 — The BE drain closes kept-alive sockets (K1/B8; amends Code Map: `http-drain.ts` changes).** From the signal on, `HttpDrain` sets `Connection: close` on every in-flight response whose headers are not yet sent. It also calls `closeIdleConnections()`, which Bun 1.4.0 has as a function, after each response finishes. The drain smoke gains a reused-idle-socket case: open keep-alive, one request, idle, SIGTERM, then a request on the same socket. It must get either 200 with `Connection: close`, or a clean close before any byte of the request is accepted.

Verified on the 6-2a image under Bun: the idle socket was closed at SIGTERM before reuse. The in-flight keep-alive request answered 200, but with `Connection: keep-alive`, and its socket was destroyed about 5 ms later by `forceCloseConnections` — the race this amendment removes.

**A3 — Staleness means "no progress" (K2/B1/B2/B3/B4; supersedes decision 5's rule).**
- **What `InFlightTick` stamps:**
  - `lastStartedAt` when a tick starts;
  - `lastProgressAt` on start, on every `beat()` and on settle.
- **Where stamping happens:** inside `InFlightTick` itself, never in the worker's `tick()`. So every early return — `running` shed, lock not acquired, flag off — still stamps.
- **Beating:** each worker calls `this.ticks.beat()` once per unit of its loop (Design Notes table).
- **When a job is stale:**
  - (a) **loop dead:** no tick in flight and `now − lastStartedAt > pollMs + 60 000`, measured from registration before the first tick;
  - (b) **no progress:** a tick in flight and `now − lastProgressAt > noProgressMs(job)`.
- **The bound:** `noProgressMs` defaults per job (Design Notes table). `WORKER_HEARTBEAT_STALE_MS`, when set, raises every job's bound to at least its value.
- **Parsing:** an integer ≥ 60 000. Below that, 0, or non-numeric → boot refuses (exit 78).
- **Tests:**
  - "lock not acquired → still fresh" (the outbox relay's `pg_try_advisory_lock` shed, `outbox.ts:79`);
  - "a 20-minute tick that beats stays healthy";
  - "a hung tick goes stale at its bound";
  - "a cleared timer goes stale at pollMs + 60 s".

**A4 — The DB TLS configuration is validated at boot (K3).** For both roles, `main.ts` runs `postgresTlsOptions` on `DATABASE_URL`, and on `DATABASE_AUTH_URL` when set, without connecting. An error exits **78**, which a spawned-process test pins. The migrate and provision CLIs do the same before connecting.

**A5 — The 6-2d ordering rules (K4/B6/B13).** They are stated in the interface (below) and in DEPLOY.md §8.8:
1. The worker-health gate is met only when 6-2d sets `WMS_PROCESS_ROLE=worker` and switches the probe path, in one change.
2. The TLS switch: every service and the migrate task must be running an image ≥ 6-2c before the secrets change to `verify-full`.
3. After that, the pipeline refuses BE images older than the 6-2c merge SHA.
4. Operator-run scripts: in the image, `PGSSLROOTCERT` is already set. On a laptop, download the same bundle, then `export PGSSLROOTCERT=<path>` (a DEPLOY.md snippet).

**A6 — A worker step in the BE CI `image` job (K5).**
- **Healthy run:** start the container with role worker and `OUTBOX_RELAY_POLL_MS=1000`. Expect `/api/v1/health/worker` 200 listing `outbox-relay` and `/api/v1/tenants/me` 404. Then `docker kill -s TERM` and `docker wait` give exit 0.
- **No jobs:** role worker with no `*_POLL_MS` gives exit 78.

**A7 — The TLS smoke covers every pool (K6; amends decision 12).** After `db:migrate:deploy`, it also runs `db:provision-roles` and then the API, both with verify-full URLs. `/health/ready` must answer 200, which proves the app and auth pools.

**A8 — Timeout and timing invariants (K7/B11/K12/B9/B5).**
- **Keep-alive:**
  - the ALB `idle_timeout` must be below `HTTP_KEEP_ALIVE_TIMEOUT_MS/1000 − 5`;
  - it must also be below the web image's `KEEP_ALIVE_TIMEOUT/1000 − 5`.
- **Stopping:**
  - `deregistration_delay` must be at least the longest expected request;
  - each app's bound (BE 25 s force exit, FE 25 s drain bound) + 5 s ≤ ECS `stopTimeout` ≤ 120;
  - the BE bound waits for in-flight ticks up to the 20 s shared drain deadline, then exits 75 at 25 s.
- **Machine-readable copy:** each app repo carries `runtime-contract.json`, which a test pins to the code's constants:

  ```json
  {"httpKeepAliveTimeoutMs":65000,"httpHeadersTimeoutMs":66000,"shutdownForceExitMs":25000,"shutdownDrainMs":20000}
  ```

  The FE file is `{"keepAliveTimeoutMs":65000,"shutdownForceExitMs":25000}`. Meta gets `deploy/runtime-contract.json` (both merged) for 6-2d's tftest to read; keeping the copies in step is a PENDING item (A16).
- **Restart timing:** a stale worker is restarted after its threshold + ECS `interval × retries`. With the values below that is the stale bound + 45 s; for example, a 2 s job whose loop dies is restarted about 107 s later.
- **Body stall (B11):** Bun does not cut a request whose body stalls mid-way (15 s, 30 s and 70 s all answered 200). The bound on a body stall is therefore the ALB's 60 s idle timeout. Mobile sync uploads must expect that and retry, which the WAL already does. Recorded in PENDING for mobile.

**A9 — A production API role refuses jobs (K8/B7).** With role `api` and `NODE_ENV=production`, any `*_POLL_MS` set to a non-zero value makes boot refuse (exit 78), unless `WMS_API_RUNS_JOBS=1`. Dev and test, where `NODE_ENV` is not production, are unchanged.

**A10 — Role and listener details (K9/B18).**
- **Role parsing:** an empty `WMS_PROCESS_ROLE` means `api`. `WORKER_HEARTBEAT_*` is parsed in every role.
- **Where the listener lives:** `WorkerHealthServer` is a provider of `JobsModule`. An `EADDRINUSE` (or any listen error) rejects `app.init()`, which crashes to exit 1.
- **Readiness of `/health/worker`:** it answers 503 `not-ready` until `main.ts` marks registration complete, which happens after the no-jobs check.
- **The api role:** the main API answers 404 for `/api/v1/health/worker` (no such Nest route).

**A11 — One problem shape, one field name (K10; amends decision 6).**
- **The 503 body:** built with `problem('worker-stale', 503, 'Worker stale', 'Stale: <jobs>', {failing})` from `src/shared/problem-details/problem-details.ts:23`. A test pins it.
- **The 200 body:** `{status:'ok', jobs:[{job, pollMs, inFlight, lastStartedAt, lastProgressAt, noProgressMs}]}`. `lastProgressAt` is the one progress field; `lastTickAt` is dropped.

**A12 — An early SIGTERM (K11).** A SIGTERM that arrives before the captured server exists, or before it listens, exits 0 at once.

**A13 — Compose and the AC (K12).**
- `stop_grace_period: 35s` on `api`, `worker` and `web`.
- AC 2's worker 404 check runs through `docker compose exec worker bun -e "fetch(…)"`.

**A14 — Stricter TLS parsing (K13/B14; amends decision 11).**
- **URL parameters:** every `ssl*` URL parameter except `sslmode` is refused (`sslrootcert`, `sslcert`, `sslkey`, `sslnegotiation`, …).
- **Parsing:** the query is read the way postgres.js reads it (split at the first `?`, `URLSearchParams`), so multi-host URLs parse.
- **Environment:** a set `PGSSLMODE` or `PGSSL` is refused (exit 78). postgres.js ignores `PGSSLMODE` silently, so it would mislead an operator.
- **Host:** must be the RDS-assigned endpoint, so the certificate's SAN matches. RDS Proxy would need a different trust source (recorded).
- **From warning to refusal:** with `DATABASE_TLS_REQUIRE_VERIFY_FULL=1`, which 6-2d sets, a non-verify-full sslmode refuses boot (78) instead of warning.
- **The bundle test:** checks only the target CA (subject contains `ap-south-1` and `RSA2048 G1`) and requires ≥ 180 days left. The refresh owner and cadence go to PENDING.
- **Architecture test:** `postgres(` may appear under `src/` only in `db.ts`, `migrate-deploy.ts` and `provision-roles.ts` (verified: origin/main has no other site).

**A15 — Writable paths and read-only runs (K14/B15).**
- **Revalidation guard:** an FE test fails on `export const revalidate`, `revalidatePath(` or `revalidateTag(` under `src/` (none exist today). Root ownership (decision 10) relies on no ISR writes.
- **Read-only runs:** CI runs both images with `--read-only --tmpfs /tmp`, plus `--tmpfs /app/.next/cache:uid=1000,gid=1000` for the web, and passes the smokes there. Verified locally on the 6-2a images: BE `/health` 200 and FE `/login` 200, with no EROFS.
- **Ownership checks:** BE: uid ≠ 0, `/app/src/main.ts` root-owned and not writable. FE: `server.js` and `.next/server` not writable, `.next/cache` writable.
- **The interface:** the writable paths are `/tmp`, plus `/app/.next/cache` for the web.

**A16 — Duplicated smoke script (K15).** The script is plain ESM (`scripts/image-smoke.mjs`) so both Bun and Node run it. A copy lives in each repo, and the copies are recorded in PENDING (deploy) to be kept in step. There is no cross-repo hash test, because CI can't see the other repo.

**A17 — ECS health-check values (B5).**
- **Values:** worker healthCheck interval 15, timeout 5, retries 3, `startPeriod` 60 (boot plus the first 2 s tick).
- **Command:** `fetch(…, {signal: AbortSignal.timeout(2000)})`.
- **Binding:** the listener binds `0.0.0.0`.
- **A blocked event loop:** it fails the probe, so the task is unhealthy. That is intended.

**A18 — Distinct exit codes (B10).**

| Code | Meaning | Where |
|---|---|---|
| **78** | boot or config refusal | bad role, no jobs, heartbeat parse, TLS config, API with jobs, missing MFA key (now 78), FE bad `WMS_API_BASE_URL` (was 1) |
| **75** | drain-timeout force exit | `armForceExit`, was 1; the FE bound |
| **1** | crash | — |
| **0** | graceful stop | — |

FE signal mapping: only SIGTERM's 143 maps to 0; SIGINT stays 130. Recorded in DEPLOY.md and the interface. The FE CI refusal step now expects 78.

**A19 — Dependabot and the build platform (B12; supersedes decision 9's "no Dependabot").**
- **Dependabot:** `.github/dependabot.yml` in wms-be and wms-fe (docker ecosystem, weekly, digest updates).
- **Platform:** CI builds and smokes with `--platform linux/amd64`, matching #219's `runtime_platform` `X86_64` (`ecs.tf:189-192`) and its `buildx --platform linux/amd64` (`deploy.yml:178`).
- **Dockerfile test:** also checks the variant (`-alpine`).
- **No leftover build args:** no `--build-arg BUN_VERSION` remains (verified: none in compose, either repo's CI, or #219).

**A20 — Smoke mechanics (B16).**
- **Client placement:** the smoke client runs as a container on the same docker network as the image under test (the image itself, `bun`/`node` + the mounted script).
- **Signals:** `docker kill -s TERM` then `docker wait` for the exit code.
- **Readiness:** a readiness loop with a 60 s timeout before any probe.
- **Assertions:** a close is asserted by its error type (`ECONNRESET`, `EPIPE`, or end of stream), not by a timing guess.
- **The CA:** generated with fixed permissions (key `0600`, copied in for uid 70).
- **Retries:** at most one retry per probe, logged.

**A21 — Acceptance sharpened (B17).** It replaces Tasks & Acceptance's AC list (below). The negative control: CI `sed`-patches a temp copy of `app.factory.ts` to keep-alive 5000, builds `wms-be:negative`, and the keepalive smoke must **fail** against it. No production code path is added.

**A22 — Interim operator note (B6).** Until 6-2d lands, DEPLOY.md says the worker still runs the full API listener and `sslmode=require`.

**Amended Boundaries.**
- **Always:** smokes run in a container on the docker network with `--read-only`. Exit codes follow A18. Every `postgres(` goes through `postgresTlsOptions`.
- **Never:** no `NEXT_MANUAL_SIG_HANDLE`.

**Amended matrix rows.**

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|---|---|---|---|
| Worker misconfig | role worker, no `*_POLL_MS` / role `foo` / `WORKER_HEARTBEAT_STALE_MS` < 60000 or 0 | exit **78** with the reason | — |
| Worker hung (replaces) | in-flight tick with no `beat()` past `noProgressMs(job)` | 503 `worker-stale`, `failing:['<job>']` | — |
| Worker loop dead | no tick started for `pollMs + 60 s` (timer gone) | 503 `worker-stale` | — |
| Long healthy tick | 20-min tick calling `beat()` per unit | 200 | — |
| Lock not acquired | relay tick sheds on `pg_try_advisory_lock` | stays fresh | — |
| Before registration | `/health/worker` during boot | 503 `not-ready` | — |
| API role + jobs in prod | `NODE_ENV=production`, `OUTBOX_RELAY_POLL_MS=2000`, no `WMS_API_RUNS_JOBS` | exit 78 | — |
| BE reused idle socket at SIGTERM | keep-alive idle, SIGTERM, request on it | 200 with `Connection: close`, or a clean close before bytes are accepted | — |
| Web keep-alive in flight at SIGTERM | keep-alive client, render in flight | response with `Connection: close`; exit 0 well under 25 s | past 25 s → exit **75** |
| Early SIGTERM (web) | before Next listens | exit 0 at once | — |
| TLS config at boot | `?sslrootcert=/x`, `PGSSLMODE` set, or verify-full without a CA | exit 78, before any connection | — |
| Strict TLS flag | `DATABASE_TLS_REQUIRE_VERIFY_FULL=1`, `sslmode=require` | exit 78 | — |
| Drain timeout | BE or FE past 25 s | exit **75** | — |

**The interface 6-2d consumes (supersedes the frozen list).**
- **Worker task:**
  - **Environment:** `WMS_PROCESS_ROLE=worker`, set together with the healthCheck change (A5.1). `WORKER_HEARTBEAT_STALE_MS` is optional (≥ 60000).
  - **healthCheck:**
    ```
    ["CMD","bun","-e","fetch('http://127.0.0.1:3000/api/v1/health/worker',{signal:AbortSignal.timeout(2000)}).then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"]
    ```
    with interval 15, timeout 5, retries 3, startPeriod 60.
  - **Port:** 3000.
- **API task:** no `*_POLL_MS` (otherwise exit 78); `WMS_API_RUNS_JOBS` unset.
- **DB TLS:**
  - **Order:** the A5.2 order, then `?sslmode=verify-full` in every DB URL.
  - **Strict flag:** `DATABASE_TLS_REQUIRE_VERIFY_FULL=1` on the api, worker and migrate tasks.
  - **Host:** the RDS endpoint, not a proxy.
  - **Minimum image:** the pipeline refuses BE images older than the 6-2c SHA (A5.3).
- **Timing:** the A8 inequalities — the ALB idle 60 s is below 65 − 5 ✓, and the ECS `stopTimeout` 30 is at least 25 + 5 ✓. A tftest reads `deploy/runtime-contract.json`.
- **Container:** `readonlyRootFilesystem` is allowed. The writable paths are `/tmp` and, for the web, `/app/.next/cache`, so those need volumes. The platform is `linux/amd64`.
- **Exit codes (A18):** 0 graceful, 78 config, 75 drain timeout, 1 crash. The circuit breaker should treat 78 as "do not retry" (6-2d's note).

## Code Map

**wms-be** (origin/main `9a246e7`):
- `src/app.factory.ts:31,78-80`. Set `keepAliveTimeout`/`headersTimeout` on `app.getHttpServer()` right after `NestFactory.create`, and export `HTTP_KEEP_ALIVE_TIMEOUT_MS = 65_000` and `HTTP_HEADERS_TIMEOUT_MS = 66_000`.
- `src/main.ts:5-27`. The boot sequence:
  1. `parseProcessRole`;
  2. heartbeat env parse;
  3. TLS validation (A4);
  4. API-jobs refusal (A9);
  5. the existing MFA check;
  6. `createApp(role==='api')`; for the worker, `app.init()`, the no-jobs check, then `markWorkerRegistrationComplete()`.

  Refusals throw a `ConfigRefusal` error, which the catch maps to exit 78; anything else exits 1.
- `src/shared/lifecycle/shutdown.ts:27,80-110,129-148`. Add `InFlightTick.track(job, pollMs, noProgressMs)` and `beat()`, and stamp start, beat and settle inside the class. `armForceExit` exits **75**. Keep the module-level state plus reset-seam pattern (`resetShutdownDrainDeadline`, :49).
- `src/shared/lifecycle/http-drain.ts:35-74`. On the signal, set `Connection: close` on in-flight responses not yet sent, and call `closeIdleConnections()` on every `finish` (A2).
- New `src/shared/lifecycle/worker-heartbeat.ts`: the registry, `parseHeartbeatEnv`, `staleJobs(now)`, the registration-complete flag. New `src/shared/lifecycle/worker-health-server.ts`: a `node:http` server on `0.0.0.0:PORT`, bodies via `problem()` (`problem-details.ts:23`).
- `src/jobs/jobs.module.ts`. Register `WorkerHealthServer` in providers (:1802). Each of the 13 workers calls `this.ticks.track(...)` after its env gate (pattern :205-213) and `this.ticks.beat()` per loop unit. The units are listed in the Design Notes table, with their lines:

  | Line | Worker |
  |---|---|
  | :474 | count-scheduler |
  | :612 | replenishment-scheduler |
  | :836 | channels-sync |
  | :990 | storage-snapshot |
  | :1188 | push-sender |
  | :1294 | wave-cutoff-sweep |
  | :1400 | audit-export |
  | :1532 | ledger-integrity |
  | :1657 | session-purge |
  | :1735 | licence-expiry |

- New `src/shared/db/pg-tls.ts`. `postgresTlsOptions(url, env)` and `assertDatabaseTlsConfig(env)`. Call it from `db.ts:11-14` (both pools via `createDatabase`), `migrate-deploy.ts:761` and `provision-roles.ts:71`. postgres.js facts: `index.js:443-445` (sslmode→ssl), `:487-488` (unknown query parameters become startup parameters), `connection.js:283-286`.
- `Dockerfile`:
  - digest-pinned literal `FROM`s, and the ARGs removed;
  - `COPY certs/ ./certs/` (root-owned);
  - `ENV PGSSLROOTCERT=/app/certs/rds-global-bundle.pem`;
  - exit codes in the comments.
- New files: `certs/rds-global-bundle.pem`, `runtime-contract.json`, `scripts/image-smoke.mjs`, `.github/dependabot.yml`.
- `.github/workflows/ci.yml` `image:` job: `--platform linux/amd64`, a docker network, `--read-only`, the keepalive smoke, the negative control, the drain smoke with reuse, the worker step, the TLS smoke, and the ownership checks.
- `.env.example`: `WMS_PROCESS_ROLE`, `WORKER_HEARTBEAT_STALE_MS`, `WMS_API_RUNS_JOBS`, `PGSSLROOTCERT`, `DATABASE_TLS_REQUIRE_VERIFY_FULL`.

**wms-fe** (origin/main `2e145db`):
- `scripts/start-standalone.mjs:29-36`. The bad-URL exit becomes 78. Before `await import(server)` it installs the `http.createServer` capture, the SIGTERM listener (A1, A12), the 25 s bound (exit 75), and the exit wrapper mapping 143→0 for SIGTERM only.
- `Dockerfile`: digests, no `--chown`, `mkdir .next/cache && chown node`, `ENV KEEP_ALIVE_TIMEOUT=65000`.
- New files: `runtime-contract.json`, `scripts/image-smoke.mjs` (copy, A16), `scripts/dockerfile.test.ts`, `scripts/no-revalidate.test.ts`, `.github/dependabot.yml`.
- `.github/workflows/ci.yml` `image:` job: refusal expects 78, plus `--read-only` and tmpfs, keepalive, the keep-alive drain, ownership. Also `.env.example` (`WEB_SHUTDOWN_FORCE_EXIT_MS`).
- Next facts:
  - `node_modules/next/dist/server/lib/start-server.js:31,247` (`_http.default.createServer`, which can be captured), `:248-249` (keepAliveTimeout), `:321-389` (cleanup, then 143);
  - standalone `server.js` reads `KEEP_ALIVE_TIMEOUT`.

**Meta:**
- `deploy/compose.yml:93,97-120`: the worker role, a healthcheck on `/api/v1/health/worker`, `stop_grace_period: 35s` on api, worker and web.
- New `deploy/runtime-contract.json`.
- Docs:
  - DEPLOY.md: §1 processes, Health and Graceful shutdown, exit codes; §2 env; §8.8 gate and interim note;
  - PENDING (deploy): close C26/C30/C31/C19; add digest refresh via Dependabot review, CA bundle refresh, runtime-contract and smoke-copy sync, Bun not enforcing `headersTimeout`, the audit-export and ledger-integrity per-page beat, RDS Proxy trust;
  - PENDING (mobile): uploads bounded by the ALB's 60 s;
  - SYSTEM-DESIGN "Processes, readiness and deploys"; frontend SYSTEM-DESIGN:15; API-SURFACE health note; `docs/repos/wms-be|wms-fe/README.md`.

**#219, read-only reference:** `edge.tf:43,70`, `ecs.tf:104-108,133-143,189-192`, `secrets.tf:33`, `data.tf:60`, `deploy.yml:178`.

## Tasks & Acceptance

**Execution:**
- [ ] wms-be `src/app.factory.ts`, `src/main.ts` — timeouts, role, the boot-refusal chain (78), worker init and registration flag.
- [ ] wms-be `src/shared/lifecycle/{shutdown,http-drain,worker-heartbeat,worker-health-server}.ts`, `src/jobs/jobs.module.ts` — track, beat, the staleness rules, `Connection: close` on drain, the listener, 13 workers.
- [ ] wms-be `src/shared/db/{pg-tls,db,migrate-deploy,provision-roles}.ts` — the helper, the boot validation, the strict flag.
- [ ] wms-be `certs/rds-global-bundle.pem` — download once from `https://truststore.pki.rds.amazonaws.com/global/global-bundle.pem` and record its sha256, certificate count and the target CA's expiry in Implementation Notes.
- [ ] wms-be `Dockerfile`, `.env.example`, `runtime-contract.json`, `scripts/image-smoke.mjs`, `.github/{workflows/ci.yml,dependabot.yml}`.
- [ ] wms-be tests:
  - `test/http-timeouts.spec.ts` — the values, and `runtime-contract.json` matching them.
  - `test/worker-heartbeat.spec.ts` — every row of A3, plus parse.
  - `test/worker-health-server.spec.ts` — 200 body, pinned 503 problem, `not-ready` before registration, 404, close on shutdown, `EADDRINUSE` → exit 1.
  - `test/boot-refusals.spec.ts` — spawned: bad role, no jobs, heartbeat parse, TLS config, API with jobs in production, MFA → each exit 78.
  - `test/pg-tls.spec.ts` — every helper row, including multi-host, `PGSSLMODE` and the strict flag.
  - `test/rds-ca-bundle.spec.ts` — the target CA, ≥ 180 days left.
  - `test/postgres-sites.spec.ts` — `postgres(` only in the three files.
  - `test/dockerfile.spec.ts` — digest, `-alpine`, tag = `.bun-version`.
  - Extend `test/shutdown.spec.ts` — force exit 75, `Connection: close` on in-flight responses, a role-worker exit 0.
- [ ] wms-fe `scripts/start-standalone.mjs` plus its test. Spawn it with `WMS_STANDALONE_SERVER` set to a fixture that copies Next's cleanup and serves through the captured `http.createServer`, and check:
  - a keep-alive in-flight request at SIGTERM → `Connection: close`, exit 0 in under 5 s;
  - hung → 75 at a short bound;
  - early SIGTERM → 0;
  - SIGINT → 130;
  - a bad URL → 78.

  Also `Dockerfile`, `scripts/dockerfile.test.ts`, `scripts/no-revalidate.test.ts`, `runtime-contract.json`, `scripts/image-smoke.mjs`, `ci.yml`, `dependabot.yml`, `.env.example`.
- [ ] Meta (after #219 merges, decision 13): compose, `deploy/runtime-contract.json`, the docs listed in the Code Map, and DEPLOY.md's exit-code table and §8.8 ordering (A5, A22).

**Acceptance Criteria:**
- **Keep-alive (AC1, self-checking).** Given the BE CI `image` job, when the keepalive smoke idles a socket for 61 s against `wms-be:ci`, then the reused request answers 200 with `Keep-Alive: timeout=65`. Against `wms-be:negative` (keep-alive patched to 5000 by `sed` on a temp copy), the same smoke fails, and the job asserts that failure.
- **Compose (AC2).** Given `deploy/compose.yml` up with the worker's 13 `*_POLL_MS`:
  - `docker compose exec worker` shows `/api/v1/health/worker` answering 200 with all 13 jobs;
  - `/api/v1/tenants/me` on the worker answers 404;
  - `docker compose stop api worker web` exits each with 0.
- **Web drain (decision 7, A1).** Given the FE image under `--read-only`, when a keep-alive client has a request in flight at SIGTERM, then it gets its response with `Connection: close` and the container exits 0 in under 5 s.
- **Digest pins (decision 9).** Given either Dockerfile, when one `FROM` loses its `@sha256:` or its `-alpine` variant, then the Dockerfile test fails.
- **Ownership (decision 10).** Given either image, when CI checks ownership, then the uid ≠ 0, code paths are not writable, and only the A15 paths are.
- **TLS rejects (decision 11).** Given a verify-full URL, when the CA does not match or the host is outside the SAN, then `db:migrate:deploy` from the image exits non-zero, and nothing is applied.
- **TLS smoke (decision 12, A7).** Given the CI TLS Postgres, when migrate, provision and the API all run with verify-full and the CI CA, then `/health/ready` answers 200.
- **Hung job.** Given a unit fixture job whose tick never settles and never beats, when its `noProgressMs` passes (fake clock), then `/health/worker` answers 503 `worker-stale` naming it, and not before.

## Design Notes

**Experiments run for this spec (2026-10-23).** Bun 1.4.0 is wms-be's `.bun-version`; Node 22.23.4 is the wms-fe image's runtime. Scripts are in the session scratchpad.

| Check | Result |
|---|---|
| Bun `node:http`, default keepAliveTimeout | 5000. An idle socket closed at 6.0 s (`Keep-Alive: timeout=5`) — the 502 race |
| Bun, `keepAliveTimeout=65000` | closed at 66.0 s. A **second request after 61 s idle → 200** |
| Bun, Nest 12 + platform-express, KA 8000 via `getHttpServer()` | closed at 9.0 s: honoured through Nest's adapter |
| Bun `headersTimeout` 3000 / 9000 / 60000 | readable but **not enforced**: an incomplete header block closes at ~12 s whatever the value (Bun's own idle timer) |
| Bun, 15 s and 45 s handlers | 200 (no idle cut while a handler runs) |
| Bun, body stalled mid-way 15 s / 30 s / 70 s (handler reads the body) | 200 every time — Bun does not cut body stalls (A8) |
| Bun `closeIdleConnections` / `closeAllConnections` | both functions |
| Node 22, KA 65000, default headersTimeout 60000 | reuse after 61 s → 200 |
| wms-be:6-2a image: echo half-sent, SIGTERM, rest after 3 s | **200 echo**; new connection closed unanswered; **exit 0** |
| wms-be:6-2a image: idle keep-alive socket reused after SIGTERM | closed at the signal before reuse (clean). The in-flight keep-alive request: 200 but `Connection: keep-alive`, socket destroyed ~5 ms later (A2) |
| Node 22: fixture copying Next's cleanup, keep-alive client in flight at SIGTERM | no fix: **still alive at 10 s** (held by keep-alive). With A1: exits 1 s after the response (K1 confirmed) |
| Next 16.3.4 standalone, `http.createServer` wrapped before import | captured 1 server, listening, `keepAliveTimeout` 65000 from `KEEP_ALIVE_TIMEOUT` |
| `--read-only --tmpfs /tmp` (+ `.next/cache` tmpfs) on both 6-2a images | BE `/health` 200; FE `/login` 200; no EROFS; BE `/app/src` root-owned, not writable by `bun` |
| postgres.js 3.4.9 under Bun, TLS PG 18 with a test CA | `require`: TLSv1.3 but unverified. URL `verify-full` without a CA: `UNABLE_TO_VERIFY_LEAF_SIGNATURE`. `ssl:{ca}`: OK. Wrong CA: fails. Host not in SAN: `ERR_TLS_CERT_ALTNAME_INVALID`. `ssl` option overrides URL `require`. `sslrootcert` in URL: **42704** from the server. `NODE_EXTRA_CA_CERTS` also works (not chosen) |
| Next 16.3.4 standalone in the 6-2a image | SIGTERM → exit **143**. Root-owned `/app` with only `.next/cache` node-owned: `/login` 200, `/` 307, runtime config served, nothing written. With the exit wrapper → exit **0** |

**Job table: the heartbeat bounds (A3).**
- **pollMs:** from `.env.example` and compose.
- **Hung Postgres socket:** about 13 min to surface an error. postgres.js `keep_alive` 60 s then Linux keepalive probes 9 × 75 s; outstanding writes retransmit up to ~15 min. The pools set no global `statement_timeout`.
- **Bounds:** the default `noProgressMs` sits above that, so one hung socket surfaces as a logged error and recovery rather than a restart. A true hang past it restarts the task.
- **beat():** called per unit, so a long cycle across many tenants stays fresh.

| Job | pollMs | Tick shape (`jobs.module.ts`) | `beat()` per | Lock / shed | Default `noProgressMs` |
|---|---|---|---|---|---|
| outbox-relay | 2 000 | one `drain(limit)` batch (:237) | — | `pg_try_advisory_lock` shed (`outbox.ts:79`) | 20 min |
| reconciliation | 2 000 | one partition (:310) | — | — | 20 min |
| reservation-reaper | 2 000 | one expiry pass (:391) | — | — | 20 min |
| count-scheduler | 3 600 000 | loop over scopes (:474) | scope | — | 20 min |
| replenishment-scheduler | 60 000 | policy and default scopes (:612) | scope | — | 20 min |
| channels-sync | 60 000 | per connection, external HTTP (:836) | connection | — | 20 min |
| storage-snapshot | 300 000 | per tenant (:990) | tenant | per-warehouse advisory lock (`storage-snapshot.ts:23`) | 20 min |
| push-sender | 5 000 | per tenant (:1188) | tenant | — | 20 min |
| wave-cutoff-sweep | 60 000 | per tenant (:1294) | tenant | — | 20 min |
| audit-export | 10 000 | per tenant; one export may page a large tenant (:1400) | tenant | xact lock (`audit-export.command.ts:160`) | **60 min** (no per-page beat without a facade seam — PENDING) |
| ledger-integrity | 3 600 000 | per scope chain (:1532) | scope | — | **60 min** (one long chain — PENDING per-page) |
| session-purge | 86 400 000 | three purge blocks (:1657) | block | — | 20 min |
| licence-expiry | 3 600 000 | per tenant (:1735) | tenant | — | 20 min |

**Why a health-only listener, not none.** ECS container health checks run a command inside the container, so a listener isn't strictly required. But #219 already probes `:3000/api/v1/health` on the worker. Keeping that path on a tiny listener means the 6-2c image deploys with no Terraform change, and 6-2d then only swaps the path and sets the role, as one change (A5.1).

**Why `Connection: close` and `closeIdleConnections` on both sides (A1, A2).** A load balancer that holds a kept-alive socket to a draining task may send one more request on it. Telling it `Connection: close` on the last response, and closing idle sockets as soon as they go idle, removes that race. Without it, Node's `server.close` waits on that socket, which is the 65 s hang found in K1.

## Verification

**Commands:**
- **wms-be:**
  - `bun run test -- test/http-timeouts.spec.ts test/worker-heartbeat.spec.ts test/worker-health-server.spec.ts test/boot-refusals.spec.ts test/pg-tls.spec.ts test/rds-ca-bundle.spec.ts test/postgres-sites.spec.ts test/dockerfile.spec.ts test/shutdown.spec.ts test/env-example.spec.ts`, then lint, typecheck, build;
  - `docker build --platform linux/amd64 .`;
  - the `image` job's steps locally (network, `--read-only`, keepalive + negative control, drain + reuse, worker, TLS).
  - Expected: all pass, and the negative control fails as asserted.
- **wms-fe:** `bun test`, lint, typecheck, `bun run build`, `docker build --platform linux/amd64 .`, the `image` job's steps locally.
- **meta:** `docker compose -f deploy/compose.yml config`, then `up --build` and AC2.

## Implementation Notes

## Spec Change Log

## Review Triage Log

Design review, 2026-10-23. K = claims check against origin/main (with experiments); B = blind review. All choices are recommended, taken autonomously. Every finding was accepted; partial applications are noted in the row.

| ID | Verdict | Finding → resolution |
|---|---|---|
| K1 | high | Next's `server.close` is held by a keep-alive client in flight, and with `KEEP_ALIVE_TIMEOUT=65000` that means 65 s. Confirmed by experiment. → A1 |
| K2 | high | "No settle" staleness falsely flags long healthy ticks and misses a dead loop. → A3 |
| K3 | medium | A TLS config error surfaces only at first query. → A4 (boot validation, exit 78) |
| K4 | medium | The 6-2d ordering (role and path, TLS switch, minimum image) is unstated. → A5 |
| K5 | medium | No in-image proof of the worker role. → A6 |
| K6 | medium | The TLS smoke covered only the migrator, not both app pools. → A7 |
| K7 | medium | The timeout invariant is not machine-readable; restart timing unstated. → A8 (`runtime-contract.json`) |
| K8 | medium | A production API with `*_POLL_MS` silently runs jobs twice. → A9 |
| K9 | low | Empty role, parse scope, the listener's module, `EADDRINUSE` unstated. → A10 |
| K10 | low | The 503 body is ad hoc; two names for the progress field. → A11 (`problem()`, `lastProgressAt`) |
| K11 | low | A SIGTERM before Next registers its cleanup is undefined. → A12 |
| K12 | low | Compose grace equals the bound; timing inequality; the AC's 404 check is unreachable from the host. → A13, A8 |
| K13 | medium | Other `ssl*` URL parameters, multi-host parsing, `PGSSLMODE` silently ignored by postgres.js. → A14 |
| K14 | low | Root ownership assumes no ISR writes, and nothing guards it. → A15 (the no-revalidate test) |
| K15 | low | The smoke script is duplicated across repos. → A16 (a PENDING entry; a hash test is impossible across repos) |
| B1 | high | A per-tenant loop longer than 3×poll reads stale. → A3 (`beat()`) |
| B2 | high | A dead timer with a 24 h poll is not detected for 72 h. → A3 rule (a) |
| B3 | high | Early returns and lock sheds must stamp. → A3 (stamped inside `InFlightTick`; lock test) |
| B4 | medium | The heartbeat setting has no minimum. → A3 (≥ 60000; 0 invalid) |
| B5 | medium | ECS health-check values, a probe timeout, the bind address. → A17 |
| B6 | medium | Operators get no interim note before 6-2d. → A5, A22 |
| B7 | medium | Same as K8. → A9 |
| B8 | high | The BE drain lets a reused idle socket race. → A2 (verified: closed at the signal; the in-flight response said keep-alive) |
| B9 | low | The BE bound value and how it relates to the ticks. → A8 |
| B10 | medium | Exit 1 is ambiguous (config, timeout or crash). → A18 (78/75/1) |
| B11 | low | The ALB idle against Bun; a body stall. → A8 (Bun does not cut 15/30/70 s stalls; the ALB 60 s is the bound; mobile PENDING) |
| B12 | low | Digest refresh, the build platform, the variant check. → A19 (Dependabot supersedes decision 9's "none"; `linux/amd64`) |
| B13 | medium | Nothing stops an old image after the switch to verify-full. → A5.3 |
| B14 | medium | RDS Proxy, the bundle test's brittleness, other `postgres(` sites, warn vs refuse. → A14 |
| B15 | medium | Read-only root filesystem and writable paths unproven. → A15 (verified locally) |
| B16 | low | Smoke flakiness (host networking, timing asserts). → A20 |
| B17 | medium | The ACs were not self-checking; several decisions had no AC. → A21 (the ACs rewritten) |
| B18 | low | `/health/worker` before registration, and on the api role. → A10 |

**Not applied as asked.** Per-page beats inside the audit-export and ledger-integrity facades need a seam across a module boundary. They beat per tenant or scope with a 60 min bound instead, and PENDING records the deeper beat.
