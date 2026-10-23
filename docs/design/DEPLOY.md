# Deploy runbook

**How the system is built into images, migrated, started and stopped.** One document for the operator; story 6-2a wrote §1–§7, story 6-2b added **§8 AWS** — the staging and production environments (Terraform in `infra/`) and the deploy pipeline (`.github/workflows/deploy.yml`) that automates §3. Neither has been applied to a real account yet: the account, domain and zone are placeholders until the operator fills them in (§8). `deploy/compose.yml` runs the whole stack locally.

Companions: `SYSTEM-DESIGN.md` (the processes, readiness, the migrator), `../repos/wms-be/README.md` and `../repos/wms-fe/README.md` (the contracts), `PENDING.md` (what is not done).

---

## 1. The processes

Two images, four kinds of process. The wms-be image is the **same image for every backend process** (decision 2); the processes differ only by environment.

| Process | Image | Count | Command | Takes traffic |
|---|---|---|---|---|
| **migrate** | wms-be | one-shot, per deploy | `bun run db:migrate:deploy && bun run db:provision-roles` | no |
| **api** | wms-be | 1..N | the image default, `bun src/main.ts` | yes — the load balancer's target; target health on `/api/v1/health` (liveness), readiness the deploy's gate (6-2b A7) |
| **worker** | wms-be | **exactly 1** | the image default | no (it listens on `PORT`, but nothing routes to it) |
| **web** | wms-fe | 1..N | the image default, `node start-standalone.mjs` → Next's `server.js` (port `3001`); it **refuses to start** (exit 1) without an absolute http(s) `WMS_API_BASE_URL` | yes |

**Exactly one worker task, deployed stop-then-start (minimum healthy 0 %, maximum 100 %).** Seven jobs are not proven safe to run twice at once — Reconciliation, ReservationReaper, CountScheduler, ReplenishmentScheduler, ChannelsSync, WaveCutoffSweep and SessionPurge (A8; the audit is in `PENDING.md`). Five document their own two-instance safety (the outbox relay's advisory lock; the storage snapshots, push sender, audit export and ledger integrity workers' comments in `jobs.module.ts`); the licence expiry sweep says nothing either way and belongs in the same audit. One task is the rule for all of them until the audit says otherwise. A rolling worker deploy would briefly run two.

**The API task sets no `*_POLL_MS`.** Every background job is env-gated off by default (`parsePollMs`: unset or `0` = off), so the API runs none; the worker sets all thirteen.

**Both images run as non-root** (wms-be: `bun`, uid 1000; wms-fe: `node`, uid 1000) and carry no secret: every key, password and URL comes from the task's environment at run time. In the wms-be image the code and `node_modules` are **root-owned**: the runtime user can run them, never rewrite them (code review C19).

### Health

| Route | Answers | Use it for |
|---|---|---|
| `GET /api/v1/health` | 200 whenever the process is up. Touches nothing | liveness: the container health check (the image's `HEALTHCHECK`, and on ECS the task definition's own `healthCheck` — Fargate ignores the Dockerfile's; both `bun -e fetch(…)`, Alpine has no curl) and the **ALB target group** (6-2b A7) |
| `GET /api/v1/health/ready` | 200 `{status:'ready', migration:'<tag>'}` when both Postgres pools answer `select 1`, Valkey answers `PING`, and the database has applied **at least** every migration the image bundles; else **503** `not-ready` with `failing: [<check>…]` (`database`, `auth-database`, `valkey`, `migrations-unreadable`, `migrations-behind`). Names only — the reasons go to the task's log | the deploy's gate: after the api roll, the pipeline polls it on the public API host until 200 (≤ 5 min) before it touches the worker (6-2b A7). **Not** the target group's check |

**At or after, never equal (A2).** The check is `max(created_at)` of `drizzle.__drizzle_migrations` ≥ the bundled journal's last `when` (drizzle stores no tag, only the journal's `when`). After the migrator runs, the database is AHEAD of the old tasks still serving — they stay ready, because **migrations are additive** (the assumption that makes this safe: a migration never removes what the previous image reads). An image whose migrations have not run is BEHIND and is never ready, so it never takes traffic. The app role reads the migrations table through the grant in `scripts/provision-roles.sql`.

Each probe query runs in its own transaction under `SET LOCAL statement_timeout` = the 2 s check bound, so a hung probe is cancelled by the server rather than left running on the request pool (code review C3).

**Readiness covers SHARED dependencies, so every task fails together** (code review C28). Postgres, Valkey and the schema are the same for every API task: when one is down, every task's `/health/ready` answers 503 at once. That is deliberate — a task that cannot reach the database cannot serve. **So the target group checks liveness, not readiness** (6-2b A7): with `/ready` as target health, a shared-dependency outage would mark every task unhealthy and ECS would stop and replace them all — a restart storm that cures nothing. Readiness is instead the deploy's gate (above). The ALB still **fails open** (its default: targets that are ALL unhealthy all receive traffic), so a total liveness failure surfaces as the API's own errors rather than the ALB's 503. The target-group values are in §8.

For the web, the container health is `GET /runtime-config.js` (the one route that reads no session and redirects nowhere).

### Graceful shutdown

`SIGTERM` (or `SIGINT`) runs Nest's shutdown sequence (A1, `src/shared/lifecycle/shutdown.ts`) and exits **0**:

1. the listener stops accepting connections; a new request on a kept-alive connection is answered `503` with `Connection: close`;
2. every worker clears its timer and waits for the tick already running; in-flight HTTP requests finish — both bounded by one shared 20 s drain deadline;
3. the HTTP server closes, destroying any socket left;
4. the Postgres pools end (3 s for an in-flight query) and Valkey quits.

A sequence still running after **25 s** is ended by the force exit (exit 1). Set the orchestrator's stop timeout to **30 s** (`stopTimeout` on ECS, `stop_grace_period` in compose). The drain's 20 s is counted from the **signal** (the first signal fixes the deadline), and a second SIGTERM during the drain is ignored rather than killing the process (code review C4/C5).

**Behind the ALB (code review C28):** readiness does not flip to 503 on SIGTERM — the order is the orchestrator's. ECS deregisters the task from the target group first and sends SIGTERM after; set the target group's **deregistration delay to 20–25 s**, so a request the ALB routed just before deregistration still finds the task draining (the 20 s drain, inside the 25 s force exit, inside the 30 s stop timeout). A longer delay only waits; a shorter one can cut requests the ALB still routes.

**The web's drain is unbounded and exits 143** (code review C30, corrected by 6-2b): Next 16's standalone `server.js` does wait for in-flight requests on SIGTERM, but with no bound of its own, and it exits 143 rather than 0. The 30 s ECS stop timeout bounds it in practice; its requests are page renders and `/runtime-config.js` (short; the browser retries a navigation). A bounded drain that exits 0 is **6-2c**'s.

---

## 2. Environment

Built from a grep of every `process.env.*` the backend reads — `test/env-example.spec.ts` fails when the code reads a variable `.env.example` does not document (A9). **A** = the API task, **W** = the worker task, **M** = the migrate task.

### wms-be — connections and the HTTP edge

| Variable | Where | Value |
|---|---|---|
| `DATABASE_URL` | A W | `postgres://wms_app:…@host/db` — the **non-superuser** app role, so RLS binds. **M:** the database **owner** (a superuser or the managed master user) |
| `DATABASE_AUTH_URL` | A W | `postgres://wms_auth:…` — the BYPASSRLS auth-time role. Unset falls back to `DATABASE_URL` with a loud warning; that only works where the app role is a superuser (dev, CI) |
| `VALKEY_URL` | A W | `redis://host:6379/0` (ElastiCache Valkey). Required: reservations fail closed without it |
| `PORT` | A W | `3000` (the image default) |
| `CORS_ORIGIN` | A | **the web origin**, e.g. `https://app.example.in` (comma-separated for several). The refresh cookie rides it with credentials |
| `TRUSTED_PROXY_HOPS` | A | **`1` behind the ALB.** `0` (the default) reads the socket address, which behind a load balancer is the ALB's — every caller would share one rate-limit bucket and one lockout counter |
| `COOKIE_SECURE` | A | unset (Secure). `false` only for local Safari, never deployed |
| `NODE_TLS_REJECT_UNAUTHORIZED` | — | **never in production.** Node's own switch; the push and channel transports honour it for a local self-signed sandbox only |

### wms-be — keys (secrets)

| Variable | Where | |
|---|---|---|
| `JWT_SECRET` | A W | HS256 session signing, ≥ 16 characters |
| `MFA_ENCRYPTION_KEY` | A W | ≥ 32. **The process refuses to boot without it.** Losing it makes every enrolled authenticator unreadable |
| `MFA_ENCRYPTION_KEY_PREVIOUS` | A W | only while rotating the MFA key |
| `DEVICE_ENCRYPTION_KEY` | A W | ≥ 32, device enrollment |
| `CARRIER_ENCRYPTION_KEY` | A W | ≥ 32, carrier credentials. Losing it loses every stored carrier credential |
| `CHANNEL_ENCRYPTION_KEY` | A W | ≥ 32, sales-channel credentials. Losing it loses every stored channel credential |
| `EMAIL_SEAL_KEY` | A W | ≥ 32 (5-1a). **Required with `EMAIL_PROVIDER=ses` or `log` — the process refuses to boot without it.** Seals a queued invite's token until it is sent; losing it fails only queued, unsent mail |
| `EMAIL_SEAL_KEY_PREVIOUS` | A W | only while rotating the email seal key |
| `EMAIL_PROVIDER` | A W | `off` (default — invite mail `skipped`) \| `log` (captured, ids logged) \| `ses` (SES v2 in `AWS_REGION`; SDK credential chain). `ses`/`log` need `EMAIL_FROM`, `WEB_BASE_URL` and `EMAIL_SEAL_KEY` — the boot fails naming the missing one (5-1a). The API queues the mail in the invite transaction, so it needs the provider settings as well as the worker |
| `EMAIL_FROM`, `EMAIL_REPLY_TO` | A W | the verified SES sending address (bare); the fallback Reply-To |
| `WEB_BASE_URL` | A W | the web app's absolute base URL (`https` in production) — the invite response's `inviteUrl` and the emailed link |
| `EMAIL_MAX_PER_TICK` | W | default 10. The cap is **per worker process**, and each message makes **two** SES calls (the suppression pre-check, then the send): keep (processes × cap × 2) ÷ poll seconds under the SES rate |
| `EMAIL_ALLOWLIST_DOMAINS` | A W | **staging only** — other domains are `skipped` |
| `AWS_REGION` (with `EMAIL_PROVIDER=ses`) | A W | default `ap-south-1`. Read by the worker with `LEDGER_ANCHOR_WORM=s3`, and by **the API and the worker with `EMAIL_PROVIDER=ses`** (every API task builds the SES client at boot; the API task role needs no SES permission — it never sends, only the worker does) |
| `EXPO_ACCESS_TOKEN` | W | only with `PUSH_GATEWAY=expo` |
| `WMS_APP_PASSWORD`, `WMS_AUTH_PASSWORD` | **M only** | applied by `db:provision-roles` as a SCRAM-SHA-256 verifier computed in the process (the plaintext never reaches the server); **required when `NODE_ENV=production`** — the image sets it, and the script exits 1 without both (C2). Never on the API or worker |

### wms-be — side-effect ports (modes, never credentials)

| Variable | Where | Value |
|---|---|---|
| `PUSH_GATEWAY` | W | `unconfigured` (default, no network) \| `expo` (needs `EXPO_ACCESS_TOKEN`; boot fails without it) |
| `PUSH_HTTP_TIMEOUT_MS` | W | default 10000 |
| `EWAY_GATEWAY` | A W | `unconfigured` (default) \| `sandbox` |
| `CHANNEL_HTTP_TIMEOUT_MS` | A W | default 10000 |
| `LEDGER_ANCHOR_WORM` | A W | `none` (default) \| `s3` (needs `LEDGER_ANCHOR_S3_BUCKET`; S3 Object Lock bucket, `PENDING.md` inventory). **On the API too** (corrected by 6-2b): the API reports the mode on the ledger-integrity read (`ledger-integrity.ts` — `wormStore: this.wormStore.mode`), so an API without it reads "WORM storage not configured" while the worker copies. Only the worker calls S3 |
| `LEDGER_ANCHOR_S3_BUCKET`, `AWS_REGION`, `LEDGER_ANCHOR_RETENTION_DAYS` | A W | with `s3` only (the boot validates them on both); region default `ap-south-1`, retention default 2557 days |

### wms-be — the worker's jobs (W only; unset = off)

| Variable | Recommended | Job |
|---|---|---|
| `OUTBOX_RELAY_POLL_MS` | 2000 | outbox relay — **without it nothing downstream of a commit happens** (notifications, channels, invoices) |
| `OUTBOX_RECONCILE_POLL_MS` | 2000 | ledger-vs-projection reconciliation |
| `RECONCILE_FULL_PASS_EVERY` | 20 | bounded passes between full ones |
| `RESERVATION_REAPER_POLL_MS` | 2000 | expire held reservations, counter parity |
| `COUNT_SCHEDULER_POLL_MS` | 3600000 | ABC-scheduled cycle counts |
| `REPLENISHMENT_SCHEDULER_POLL_MS` | 60000 | reorder breaches + expiry/aging alerts |
| `CHANNELS_SYNC_POLL_MS` | 60000 | channel availability publishing |
| `STORAGE_SNAPSHOT_POLL_MS` | 300000 | daily storage snapshots (client billing) |
| `PUSH_SENDER_POLL_MS` | 5000 | mobile pushes |
| `WAVE_CUTOFF_SWEEP_POLL_MS` | 60000 | wave cut-off at risk |
| `AUDIT_EXPORT_POLL_MS` | 10000 | async audit exports |
| `LEDGER_INTEGRITY_POLL_MS` | 3600000 | ledger anchoring and re-verify; plus `MAX_LEDGER_INTEGRITY_SCOPES_PER_TICK` (50), `LEDGER_ANCHOR_MAX_RANGE` (10000), `LEDGER_ANCHOR_CHUNKS_PER_TICK` (10) |
| `SESSION_PURGE_POLL_MS` | 86400000 | purge ended sessions and counters — without it they grow without bound |
| `LICENCE_EXPIRY_POLL_MS` | 3600000 | drug/FSSAI licence expiry warnings |
| `EMAIL_SEND_POLL_MS` | 5000 | the email sender (5-1a) — off, invite mail queues and is never sent |

### wms-be — the migrator (M only)

| Variable | Default | |
|---|---|---|
| `MIGRATE_LARGE_TABLE_ROWS` | 100000 | a table at or over this `pg_class.reltuples` is "large" |
| `MIGRATE_LARGE_TABLE_BYTES` | 67108864 (64 MB) | for a table never analysed (`reltuples < 0`): its heap size instead |
| `MIGRATE_LOCK_TIMEOUT_MS` | 5000 | how long a DDL statement waits for its table lock before the deploy fails. **While it waits, every later lock request on that table — live reads and writes — queues behind it** (Postgres grants locks in order), so this bounds that stall to 5 s; it does not avoid it (code review C16) |
| `MIGRATE_STATEMENT_TIMEOUT_MS` | 600000 | one statement's ceiling |
| `MIGRATE_ADVISORY_WAIT_MS` | 600000 | how long a second migrator waits for the first |

### wms-fe

| Variable | Value |
|---|---|
| `WMS_API_BASE_URL` | **the API base the BROWSER calls**, e.g. `https://api.example.in/api/v1`. Read at run time and served as `/runtime-config.js` — one image serves every environment. **Required by the image**: unset or not an absolute http(s) URL, the start exits 1 (C6), and the route never serves an invalid value. Rendered URLs (the channel webhook rows) always use this public base (C7) |
| `WMS_API_INTERNAL_BASE_URL` | optional: the base the web **server's** own requests use (the Overview's health line) when it differs inside the network (compose: `http://api:3000/api/v1`). Requests only — never rendered (C7) |
| `NEXT_PUBLIC_API_BASE_URL` | build-time default only (dev). Never needed in a deployed image |
| `PORT`, `HOSTNAME` | `3001`, `0.0.0.0` (the image defaults) |

### The cookie rule (PENDING tenancy, 6-1a)

**The web and the API must share a registrable domain that is not on the public suffix list** — e.g. `app.example.in` and `api.example.in`. The refresh cookie is `SameSite=Strict`; hosted on `*.cloudfront.net` and `*.elb.amazonaws.com` (two different sites), it is never sent and every session ends at its 15-minute access token.

---

## 3. Deploy order

Backend first, then the web (the cross-repo rule). Every step gates the next. On AWS, `.github/workflows/deploy.yml` runs steps 1 and 3–7 (§8.5); step 2 stays a human's.

1. **Build** both images from the merged commits (CI's `image` jobs prove they build and boot).
2. **Pre-build any large index** the migrator would refuse (§5). Run its `--dry-run` against production first: it prints the plan and changes nothing (exit 2 when a real run would refuse).
3. **Run the migrate task** — `bun run db:migrate:deploy && bun run db:provision-roles`, as the owner. A refusal (exit 2) stops the deploy with nothing applied. `db:provision-roles` runs **every** deploy: it is idempotent, and it is what grants the app role the new tables (default privileges) and the migrations table (readiness).
4. **Roll the API** — new tasks join the target group once their liveness check passes; the load balancer drains the old ones, and their SIGTERM drains in-flight requests. Old tasks stay ready throughout (at-or-after).
5. **Wait for `/health/ready` = 200** before anything else moves (on AWS the pipeline polls the public API host, ≤ 5 minutes; a not-ready API stops the deploy with the worker and web untouched).
6. **Replace the worker: stop the old one, then start the new one** (minimum healthy 0 %). Its stop drains the tick in flight.
7. **Roll the web.**

**Rollback is the previous image, never the schema.** The schema only moves forward; an old image over a newer schema is ready by design. A migration that cannot run additively (a rename, a drop) needs its own two-step design, and the story that writes it says so.

---

## 4. Roles (`scripts/provision-roles.sql`)

Run by `bun run db:provision-roles` (`src/shared/db/provision-roles.ts`), on every deploy, after the migrator, as the owner:

- `wms_app` — `NOSUPERUSER NOBYPASSRLS`: the RLS policies bind. Select/insert/update/delete on every table (and every future one, by default privileges), `pg_read_all_stats` (the §7d session-visibility probe; `IMPLEMENTATION-GUIDE.md` §7d), and — 6-2a — usage on schema `drizzle` and select on its tables (readiness).
- `wms_auth` — `BYPASSRLS`, for sign-in and other context-free reads.
- **Passwords are set out of band**: `WMS_APP_PASSWORD` / `WMS_AUTH_PASSWORD` in the migrate task's environment (from the secrets manager) are applied every deploy with `ALTER ROLE … PASSWORD '<SCRAM-SHA-256 verifier>'` — the verifier is computed in the migrate process (PBKDF2-SHA-256, 4096 iterations, a fresh 16-byte salt), so **the plaintext never reaches the server or its statement log** (code review C1). With `NODE_ENV=production` (the image's default) both are **required**: the script exits 1 before connecting if either is unset or empty, so no role is left on the script's `change-me-*` placeholder (C2).
- On PG16+ the grantor of `pg_read_all_stats` needs ADMIN OPTION (a superuser or the managed master user).

---

## 5. Index builds on large tables

drizzle applies every pending migration in **one transaction**, where `CREATE INDEX CONCURRENTLY` is illegal, so an index build in a migration holds a SHARE lock on its table for the whole build — on `ledger_events` every pick, putaway, receipt and adjustment waits. The runbook: **build the index CONCURRENTLY by hand under the same name, check it is valid, then deploy** — the migration's `CREATE INDEX IF NOT EXISTS` is then a no-op.

`bun run db:migrate:deploy` (`src/shared/db/migrate-deploy.ts`) **enforces** it (decision 7, A3–A6):

- one migrator at a time (a session advisory lock on a reserved connection, held across the whole migrate);
- for every pending `CREATE [UNIQUE] INDEX` on an existing table at or over the thresholds (§2):
  - **no `IF NOT EXISTS`** → refused: a pre-built index would fail the migration with `42P07`. Rewrite the migration (new migrations) or accept the lock (`--allow-locking=<index>`, history);
  - **missing** → refused, printing the exact `CREATE INDEX CONCURRENTLY IF NOT EXISTS …`;
  - **exists but INVALID** (an interrupted concurrent build — `IF NOT EXISTS` would silently skip it) → refused: `DROP INDEX CONCURRENTLY "<name>";`, rebuild, re-check;
  - **exists, valid** → fine;
  - **exists, valid, but with ANOTHER definition** (the normalised `pg_get_indexdef` differs from the statement) → refused as a name collision: `IF NOT EXISTS` would keep the old definition (C9);
  - dropped earlier in the pending set — a name list or a schema-qualified name included — and re-created → refused (it cannot be pre-built under its name, C10);
  - an index name already used on another table → refused;
- a table renamed earlier in the pending set is judged, pre-built and checked under its **current** name — the printed statement targets it (C11); `CREATE TABLE IF NOT EXISTS` over a table that already exists creates nothing, so its indexes are still judged (C12); a partitioned table is judged by the sum of its partitions (C13);
- a `DO`/`EXECUTE` block mentioning INDEX, an `ADD [CONSTRAINT …] UNIQUE | PRIMARY KEY | EXCLUDE` (named or not) or an `ADD COLUMN … UNIQUE | PRIMARY KEY` is **"unparsed, review"**, refused when it can touch a large existing table — or, when it names no table that resolves (keywords such as `ON CONFLICT` are not tables), when the database holds any large table (C8, C14);
- a breakpoint chunk holding several statements is split on its top-level `;`, so each is judged;
- tables created (or renamed into) earlier in the pending set are excluded;
- `--dry-run` prints the plan, changes nothing (exit 2 when a refusal would stop a real run);
- **`--allow-locking=<index-name-or-migration-tag>[,…]` accepts exactly the refusals it names** — an index name, a migration's full tag or its four-digit number — and logs each; a refusal it does not name stays refused, and a bare `--allow-locking` is an error (exit 1) (C15). Each refusal prints the exact flag that would accept it.

New migrations (0089 on) must write every `CREATE INDEX` as `IF NOT EXISTS` — `test/migrate-deploy.spec.ts` lints it (A3).

After a hand build, check it:

```sql
select c.relname, i.indisvalid from pg_class c join pg_index i on i.indexrelid = c.oid where c.relname = '<name>';
```

### The consolidated table — for re-deploys of existing databases

**A first production deploy needs none of this**: every migration runs on empty tables (none exists in production yet, and the migrator excludes tables the pending set creates). This table is for a database that already holds data and is behind one of these migrations. Run each statement **outside any transaction** (psql autocommit), before the deploy that carries its migration. "Plain" means the migration's own statement has no `IF NOT EXISTS`: the guard refuses it on a large table whatever you pre-build, so the choice there is `--allow-locking=<that index>` in a window (the migration is history and is not rewritten).

| Migration | Table | Form in the migration | Pre-build (run first) |
|---|---|---|---|
| 0058 | `ledger_events` | `IF NOT EXISTS` | `CREATE INDEX CONCURRENTLY IF NOT EXISTS "ledger_events_tenant_warehouse_type_recorded_at_idx" ON "ledger_events" USING btree ("tenant_id","warehouse_id","type","recorded_at");` |
| 0061 | `ledger_events` | **plain** | `CREATE INDEX CONCURRENTLY IF NOT EXISTS "ledger_events_tenant_client_warehouse_recorded_at_idx" ON "ledger_events" USING btree ("tenant_id","client_id","warehouse_id","recorded_at");` |
| 0061 | `ledger_events` | **plain** | `CREATE INDEX CONCURRENTLY IF NOT EXISTS "ledger_events_tenant_client_type_recorded_at_idx" ON "ledger_events" USING btree ("tenant_id","client_id","type","recorded_at");` |
| 0069 | `audit_events` | **plain** | `CREATE INDEX CONCURRENTLY IF NOT EXISTS "audit_events_tenant_created_idx" ON "audit_events" USING btree ("tenant_id","created_at" DESC NULLS LAST,"id" DESC NULLS LAST);` |
| 0069 | `audit_events` | **plain** | `CREATE INDEX CONCURRENTLY IF NOT EXISTS "audit_events_tenant_actor_created_idx" ON "audit_events" USING btree ("tenant_id","actor_user_id","created_at" DESC NULLS LAST);` |
| 0069 | `audit_events` | **plain** | `CREATE INDEX CONCURRENTLY IF NOT EXISTS "audit_events_tenant_target_idx" ON "audit_events" USING btree ("tenant_id","target_type","target_id");` |
| 0069 | `audit_events` | **plain** | `CREATE INDEX CONCURRENTLY IF NOT EXISTS "audit_events_tenant_action_created_idx" ON "audit_events" USING btree ("tenant_id","action" text_pattern_ops,"created_at" DESC NULLS LAST);` |
| 0069 | `ledger_events` | `IF NOT EXISTS` | `CREATE INDEX CONCURRENTLY IF NOT EXISTS "ledger_events_grn_ref_idx" ON "ledger_events" USING btree ("tenant_id","warehouse_id",("reference_doc"->>'grnId')) WHERE "reference_doc" ? 'grnId';` |
| 0069 | `ledger_events` | `IF NOT EXISTS` | `CREATE INDEX CONCURRENTLY IF NOT EXISTS "ledger_events_po_ref_idx" ON "ledger_events" USING btree ("tenant_id","warehouse_id",("reference_doc"->>'poId')) WHERE "reference_doc" ? 'poId';` |
| 0069 | `ledger_events` | `IF NOT EXISTS` | `CREATE INDEX CONCURRENTLY IF NOT EXISTS "ledger_events_transfer_ref_idx" ON "ledger_events" USING btree ("tenant_id","warehouse_id",("reference_doc"->>'transferId')) WHERE "reference_doc" ? 'transferId';` |
| 0069 | `ledger_events` | `IF NOT EXISTS` | `CREATE INDEX CONCURRENTLY IF NOT EXISTS "ledger_events_adjustment_pending_ref_idx" ON "ledger_events" USING btree ("tenant_id","warehouse_id",("reference_doc"->>'adjustmentPendingId')) WHERE "reference_doc" ? 'adjustmentPendingId';` |
| 0069 | `ledger_events` | `IF NOT EXISTS` | `CREATE INDEX CONCURRENTLY IF NOT EXISTS "ledger_events_count_variance_ref_idx" ON "ledger_events" USING btree ("tenant_id","warehouse_id",("reference_doc"->>'countVarianceId')) WHERE "reference_doc" ? 'countVarianceId';` |
| 0078 | `qc_holds` | **plain** | `CREATE INDEX CONCURRENTLY IF NOT EXISTS "qc_holds_tenant_grn_line_idx" ON "qc_holds" USING btree ("tenant_id","grn_line_id");` |
| 0078 | `qc_holds` | **dropped and re-created** | none possible under its name (`qc_holds_open_scope_unique`): a window with `--allow-locking=qc_holds_open_scope_unique` |
| 0078 | `ledger_events` | `IF NOT EXISTS` | `CREATE INDEX CONCURRENTLY IF NOT EXISTS "ledger_events_hold_ref_idx" ON "ledger_events" USING btree ("tenant_id","warehouse_id",("reference_doc"->>'holdId')) WHERE "reference_doc" ? 'holdId';` |
| 0081 | `goods_receipt_notes` | `IF NOT EXISTS` | `CREATE INDEX CONCURRENTLY IF NOT EXISTS "goods_receipt_notes_tenant_client_warehouse_created_at_id_idx" ON "goods_receipt_notes" USING btree ("tenant_id","client_id","warehouse_id","created_at","id");` |
| 0081 | `goods_receipt_notes` | `IF NOT EXISTS` | `CREATE INDEX CONCURRENTLY IF NOT EXISTS "goods_receipt_notes_tenant_client_created_at_id_idx" ON "goods_receipt_notes" USING btree ("tenant_id","client_id","created_at","id");` |
| 0081 | `ledger_events` | `IF NOT EXISTS` | `CREATE INDEX CONCURRENTLY IF NOT EXISTS "ledger_events_tenant_client_warehouse_created_at_id_idx" ON "ledger_events" USING btree ("tenant_id","client_id","warehouse_id","created_at","id");` |
| 0081 | `orders` | `IF NOT EXISTS` | `CREATE INDEX CONCURRENTLY IF NOT EXISTS "orders_tenant_client_warehouse_created_at_id_idx" ON "orders" USING btree ("tenant_id","client_id","warehouse_id","created_at","id");` |
| 0081 | `products` | `IF NOT EXISTS` | `CREATE INDEX CONCURRENTLY IF NOT EXISTS "products_tenant_client_created_at_id_idx" ON "products" USING btree ("tenant_id","client_id","created_at","id");` |
| 0081 | `purchase_orders` | `IF NOT EXISTS` | `CREATE INDEX CONCURRENTLY IF NOT EXISTS "purchase_orders_tenant_client_warehouse_created_at_id_idx" ON "purchase_orders" USING btree ("tenant_id","client_id","warehouse_id","created_at","id");` |
| 0081 | `return_authorizations` | `IF NOT EXISTS` | `CREATE INDEX CONCURRENTLY IF NOT EXISTS "return_authorizations_tenant_client_created_at_id_idx" ON "return_authorizations" USING btree ("tenant_id","client_id","created_at","id");` |
| 0081 | `return_authorizations` | `IF NOT EXISTS` | `CREATE INDEX CONCURRENTLY IF NOT EXISTS "return_authorizations_tenant_client_warehouse_created_at_id_idx" ON "return_authorizations" USING btree ("tenant_id","client_id","warehouse_id","created_at","id");` |
| 0081 | `skus` | `IF NOT EXISTS` | `CREATE INDEX CONCURRENTLY IF NOT EXISTS "skus_tenant_client_created_at_id_idx" ON "skus" USING btree ("tenant_id","client_id","created_at","id");` |
| 0086 | `goods_receipt_notes` | **plain** | `CREATE INDEX CONCURRENTLY IF NOT EXISTS "goods_receipt_notes_tenant_gate_in_idx" ON "goods_receipt_notes" USING btree ("tenant_id","gate_in_id");` |

The statements were generated from the migrations by the migrator's own parser (`concurrentlyStatement`), not retyped. There is **no migration 0088** in the repo at 6-2a (the numbering runs 0000–0087); the spec's "0088 entry" is covered by the two entries that were missing from every runbook before this table — **0078** (`qc_holds`, and the hold-ref ledger index) and **0086** (`goods_receipt_notes`).

### Not an index, still a lock: 0087's CHECK scans

`0087_receipt_line_condition.sql` adds four `CHECK` constraints to `goods_receipt_lines` with plain `ADD CONSTRAINT`, each scanning the table once under the `ACCESS EXCLUSIVE` lock its `ADD COLUMN`s took — every receipt waits for the scans. The guard does not judge CHECKs (it judges index builds). On a re-deploy over a large `goods_receipt_lines`, schedule it in a window; a future CHECK on a large table is written `NOT VALID` and validated in a later migration (`VALIDATE CONSTRAINT` takes only a SHARE UPDATE EXCLUSIVE lock).

---

## 6. Locally and in CI

- **`deploy/compose.yml`** — the production-like stack: Postgres 18, Valkey 9.1, the one-shot `migrate` (as the owner), the `api` and one `worker` (as `wms_app`), and the `web`. Built from the workspace paths:

  ```bash
  docker compose -f deploy/compose.yml up --build    # web http://localhost:3001, API http://localhost:3000
  ```

  Every credential is a local placeholder with a default; override in `deploy/.env` (template `deploy/.env.example`, git-ignored). Stop your dev servers first — the stack publishes `3000` and `3001`.
- **CI** — each repo's `image` job builds its image and smoke-runs it (no push), on the Bun version in the repo's `.bun-version` (C18): wms-be migrates a fresh database **with the image** — the migrator then the roles, **twice**, so the second pass proves both are idempotent (C17) — runs it as `wms_app` with **no** `*_POLL_MS` (the API task's environment), probes `/health` and `/health/ready`, and checks a `SIGTERM` exits 0; wms-fe checks it refuses to start without a valid `WMS_API_BASE_URL` (exit 1), then runs it with one and checks the web root and that `/runtime-config.js` carries that address.

## 7. Recorded checks (A10)

- `oven/bun:1.4.0-alpine` and `oven/bun:1.4.2-alpine` exist (`docker manifest inspect`, 2026-10-22); `packageManager` and `.bun-version` pin wms-be to 1.4.0 and wms-fe to 1.4.2, their CI versions.
- The wms-fe build stage is `node:22-alpine` with the Bun binary copied from `oven/bun:1.4.2-alpine`: `bun install` picks the musl platform packages, `next build` loads the **native** `@next/swc-linux-*-musl` binding (not the WASM fallback), and the traced standalone server on `node:22-alpine` loads `sharp` 0.35.4 / libvips 8.18.6 and encodes a PNG. Checked on linux/arm64 locally; CI's `image` job builds linux/amd64.
- Under Bun (the wms-be runtime), a `SIGTERM` during a request lets it finish (200), refuses a new connection, and exits 0. **The drain is verified on Node by the jest suite and on Bun by hand only** (code review C26) — a Bun in-image drain smoke is **6-2c**'s (moved from 6-2b, which is IaC and pipeline only).

---

## 8. AWS (story 6-2b)

Staging and production in `ap-south-1` (D6), one account (A11), as Terraform in `infra/` (layout, apply commands and the bootstrap: **`infra/README.md`**), deployed by `.github/workflows/deploy.yml`. **Nothing here has been applied yet**: the account, the domain and the zone are `REPLACE_ME` placeholders, and the pipeline does nothing until §8.4 is done.

**The repositories and the workflow logs are public** (A9). tfvars hold no account value beyond the account ID, the domain, the zone and the operator's SSO role pattern; no secret goes in a tfvar, the repo or a log, and the pipeline never prints a task definition or an environment.

### 8.1 What runs where

| | Staging | Production |
|---|---|---|
| Hosts | `app.staging.<domain>`, `api.staging.<domain>` | `app.<domain>`, `api.<domain>` |
| Network | VPC over `ap-south-1a`/`1b`: public (ALB, NAT), app (ECS), data (RDS, Valkey — no route out); one NAT | the same; a NAT per AZ; interface endpoints for ECR, Secrets Manager and Logs |
| ALB | HTTPS only (HTTP → 301), TLS policy `ELBSecurityPolicy-TLS13-1-2-2021-06`, idle timeout 60 s, host routing; any other host → 404 | + deletion protection, access logs to S3 (90 days) |
| api | 1 task, 0.5 vCPU / 1 GB | 2 tasks, 1 vCPU / 2 GB, autoscaling on CPU 60 % up to 6 |
| worker | exactly 1, 0.5 / 1 GB, minimum healthy 0 % / maximum 100 % (stop-then-start), not on the ALB | the same |
| web | 1, 0.5 / 1 GB | 2 |
| migrate | a task definition only, 0.5 / 1 GB | the same |
| RDS Postgres 18 | `db.t4g.small`, single-AZ, gp3 50 → 500 GB, backups 7 days, no final snapshot | `db.t4g.medium`, Multi-AZ, backups 14 days, deletion protection, a named final snapshot |
| Valkey 8 | 1 × `cache.t4g.micro`, snapshots 1 day | 2 × `cache.t4g.small`, Multi-AZ failover, snapshots 7 days |
| Ledger anchors | Object Lock COMPLIANCE, **1-day** retention (the S3 path runs before production, A15) | 2557 days |
| Logs | `/wms/staging/{api,worker,web,migrate}`, 30 days | `/wms/production/…`, 90 days |
| Secrets recovery window | 0 (a re-create is never blocked) | 7 days |

Every service: Fargate X86_64 (the CI-verified images), `stopTimeout` 30 s, the deployment circuit breaker with rollback, Container Insights. Target groups: deregistration delay 25 s (§1); the API's health is **liveness** `/api/v1/health`, the web's `/runtime-config.js`, both interval 10 s, timeout 5 s, healthy 2, unhealthy 3, matcher 200; the API service has a 60 s health-check grace period. Each container has its own ECS `healthCheck` (30 s start period). RDS and Valkey maintenance: Sunday 21:30–22:30 UTC (03:00 IST); RDS backups 20:00–21:00 UTC. RDS forces TLS (`rds.force_ssl = 1`) and the URLs carry `sslmode=require`; `verify-full` needs the RDS CA bundle in the image (6-2c). Valkey: transit and at-rest encryption, an AUTH token, `maxmemory-policy noeviction`. The `t4g` instances run unlimited-credit; the CPU-credit alarm is 6.3's.

Not here: alarms, dashboards and a tested restore (6.3 — this story has backups on, nothing more); WAF and a CDN (6.4, `PENDING.md`).

### 8.2 The per-role environment (A5)

Set by `infra/modules/environment/ecs.tf`; `terraform test` in that directory pins the load-bearing rows. **Secrets** are Secrets Manager `valueFrom` references — never literals in the task definition.

| Role | Environment | Secrets |
|---|---|---|
| **api** | `NODE_ENV=production`, `PORT=3000`, `TRUSTED_PROXY_HOPS=1`, `CORS_ORIGIN=https://app.<host>`, `AWS_REGION=ap-south-1`, `LEDGER_ANCHOR_WORM=s3`, `LEDGER_ANCHOR_S3_BUCKET`, `LEDGER_ANCHOR_RETENTION_DAYS`, `EWAY_GATEWAY` (`unconfigured`), `CHANNEL_HTTP_TIMEOUT_MS` (10000). **No `*_POLL_MS`** | `DATABASE_URL` (wms_app), `DATABASE_AUTH_URL` (wms_auth), `VALKEY_URL`, `JWT_SECRET`, `MFA_ENCRYPTION_KEY`, `DEVICE_ENCRYPTION_KEY`, `CARRIER_ENCRYPTION_KEY`, `CHANNEL_ENCRYPTION_KEY` |
| **worker** | the api's, minus `CORS_ORIGIN` and `TRUSTED_PROXY_HOPS`; plus all thirteen `*_POLL_MS` at §2's recommended values, `RECONCILE_FULL_PASS_EVERY` (20), `MAX_LEDGER_INTEGRITY_SCOPES_PER_TICK` (50), `LEDGER_ANCHOR_MAX_RANGE` (10000), `LEDGER_ANCHOR_CHUNKS_PER_TICK` (10), `PUSH_GATEWAY` (tfvar `push_gateway`, default `unconfigured`), `PUSH_HTTP_TIMEOUT_MS` (10000) | the api's; plus `EXPO_ACCESS_TOKEN` only when `push_gateway = "expo"` |
| **migrate** | `NODE_ENV=production`, `MIGRATE_LARGE_TABLE_ROWS`, `MIGRATE_LARGE_TABLE_BYTES`, `MIGRATE_LOCK_TIMEOUT_MS`, `MIGRATE_STATEMENT_TIMEOUT_MS`, `MIGRATE_ADVISORY_WAIT_MS` (§2's defaults) | `DATABASE_URL` = the **owner** URL (the RDS master user `wms`), `WMS_APP_PASSWORD`, `WMS_AUTH_PASSWORD` — on no other role |
| **web** | `PORT=3001`, `HOSTNAME=0.0.0.0`, `WMS_API_BASE_URL=https://api.<host>/api/v1` | none |

**Not wired, on purpose:** `WMS_API_INTERNAL_BASE_URL` (unset: the web server's own requests take the public ALB through the NAT — accepted); `MFA_ENCRYPTION_KEY_PREVIOUS` (only while rotating: §8.7); `COOKIE_SECURE` (unset = Secure); the `EMAIL_*` settings and `WEB_BASE_URL` (story 5-1a wires `EMAIL_SEAL_KEY` on the api and worker — its secret exists with no value and no task references it, so nothing blocks a start).

**Who can read what** (A9): the api/worker execution role reads only the app secrets; a separate **migrate execution role** alone reads the owner URL and the role passwords; the web's reads none. Task roles: only the worker's has permissions — `s3:PutObject`, `s3:PutObjectRetention`, `s3:GetObject`, `s3:GetObjectVersion` on `ledger-anchors/*` and `s3:ListBucket` on the anchor bucket (the code's actions), `ses:SendEmail` on the domain identity and `ses:GetSuppressedDestination` (for 5-1a).

### 8.3 First-time order (A13)

1. **Bootstrap → global → staging apply → production apply** (`infra/README.md`; production's first apply passes `-var api_autoscaling=false`). Services are created at **desired 0** and every task definition names the non-existent tag `bootstrap`, so nothing starts.
2. **Set the out-of-band secrets** (below) in each environment.
3. **Create the GitHub environments, then set the role variables** (§8.4) — in that order.
4. **Check the master user's privileges** (A6, below), through a dry run — before the first real migrate.
5. **Deploy staging** (§8.5). Its first roll sets each service's count from the deploy parameter (api and web from tfvars, worker 1).
6. Promote to **production**; after it, `terraform apply` production once more without the flag, so API autoscaling exists.

#### Setting the out-of-band secrets

Terraform creates these secrets **with no value**, so a key is never in Terraform state and a lost state never loses one: `wms/<env>/jwt-secret`, `mfa-encryption-key`, `device-encryption-key`, `carrier-encryption-key`, `channel-encryption-key` (all required: an api or worker task cannot start until each has a value — it fails closed, `stoppedReason` names the secret), `email-seal-key` (5-1a; not read yet) and `expo-access-token` (only with `push_gateway = "expo"`). `terraform output out_of_band_secret_names` lists them.

Generate each value and pipe it in — **never on the command line** (argv lands in shell history and `ps`):

```bash
env=staging
for name in jwt-secret mfa-encryption-key device-encryption-key carrier-encryption-key channel-encryption-key; do
  openssl rand -hex 32 | tr -d '\n' \
    | aws secretsmanager put-secret-value --secret-id "wms/$env/$name" --secret-string file:///dev/stdin > /dev/null
done
```

(64 hex characters: over every minimum in §2.) The Expo token is pasted the same way (`… --secret-string file:///dev/stdin`, then the token and Ctrl-D). **Never regenerate a key that is in use**: the encryption keys seal stored data, and losing one loses what it sealed (§2). Production's 7-day recovery window is the undo for a deleted secret.

#### Check the master user's privileges (A6)

`db:provision-roles` creates `wms_auth` with `BYPASSRLS` and grants `pg_read_all_stats` to `wms_app`; on RDS the master user (`wms`, the migrate task's owner URL) must be able to do both, and that is **unverified** (AWS was not reachable when this was written). Before the first migrate, run as the master user:

```sql
select rolbypassrls from pg_roles where rolname = current_user;
select pg_has_role(current_user, 'pg_read_all_stats', 'USAGE WITH ADMIN OPTION');
```

The data subnets have no bastion, so run them in the migrate task (its `DATABASE_URL` is the owner URL). First dispatch the pipeline with `dry_run_migrations = true` — it changes nothing, and it registers a migrate revision with a real image. Then, with the operator's credentials:

```bash
env=staging
cat > a6.json <<'JSON'
{"containerOverrides":[{"name":"migrate","command":["bun","-e","import postgres from 'postgres'; const sql = postgres(process.env.DATABASE_URL); const [r] = await sql`select rolbypassrls as bypassrls, pg_has_role(current_user, 'pg_read_all_stats', 'USAGE WITH ADMIN OPTION') as read_all_stats_admin from pg_roles where rolname = current_user`; console.log('A6 check:', JSON.stringify(r)); await sql.end();"]}]}
JSON
td=$(aws ecs list-task-definitions --family-prefix "wms-$env-migrate" --sort DESC --max-items 1 --query 'taskDefinitionArns[0]' --output text)
net=$(aws ssm get-parameter --name "/wms/$env/deploy" --query Parameter.Value --output text \
  | jq -c '{awsvpcConfiguration: {subnets: .subnets, securityGroups: .security_groups, assignPublicIp: "DISABLED"}}')
aws ecs run-task --cluster "wms-$env" --task-definition "$td" --launch-type FARGATE \
  --network-configuration "$net" --overrides file://a6.json --query 'tasks[0].taskArn' --output text
# then read the line "A6 check: {…}" in the log group /wms/<env>/migrate
```

(The command was checked against the wms-be image and a local Postgres 18, where the owner is a superuser and both read `true`.) Both must be `true`. **If either is false, `provision-roles` cannot run: that is a go-live blocker** (`PENDING.md` deploy) — stop and investigate; there is no fallback.

### 8.4 Enabling the pipeline (A3, A4)

The workflow's `gate` job reads two **repository** variables, `AWS_DEPLOY_ROLE_ARN_STAGING` and `AWS_DEPLOY_ROLE_ARN_PRODUCTION`. While one is unset, a run for that environment prints "not configured" and succeeds with every later job skipped — no approval, no AWS call.

**Order matters** (design review D20): create and protect the environment **before** setting its variable, or a production run could deploy unapproved in between.

```bash
repo=chinnisasi/WMS-Meta
# Both environments: deployments from main only.
for env in staging production; do
  gh api -X PUT "repos/$repo/environments/$env" --input - <<<'{"deployment_branch_policy":{"protected_branches":false,"custom_branch_policies":true}}'
  gh api -X POST "repos/$repo/environments/$env/deployment-branch-policies" -f name=main -f type=branch
done
# Production: a required reviewer (the owner's user id: gh api users/<login> --jq .id).
gh api -X PUT "repos/$repo/environments/production" --input - <<<'{"reviewers":[{"type":"User","id":<id>}],"prevent_self_review":false,"deployment_branch_policy":{"protected_branches":false,"custom_branch_policies":true}}'
# Only now: the role ARNs (terraform output -raw deploy_role_arn in each env root).
gh variable set AWS_DEPLOY_ROLE_ARN_STAGING --repo "$repo" --body "<staging deploy role ARN>"
gh variable set AWS_DEPLOY_ROLE_ARN_PRODUCTION --repo "$repo" --body "<production deploy role ARN>"
```

Each deploy role trusts only `repo:chinnisasi/WMS-Meta:environment:<env>` with audience `sts.amazonaws.com` — a job outside that GitHub environment cannot assume it — and every job also checks `github.ref == refs/heads/main`. No AWS key exists anywhere (OIDC only). The deploy roles cannot read Terraform state (A10).

### 8.5 Deploying

Actions → **deploy** → Run workflow:

| Input | |
|---|---|
| `environment` | `staging` or `production` |
| `be_ref`, `fe_ref` | staging: any branch, tag or SHA (default `main`); **production: the full 40-character SHAs staging deployed** |
| `skip_migrations` | rollback: roll only, no migrate task |
| `dry_run_migrations` | run `db:migrate:deploy --dry-run` (no provisioning; with `--allow-locking=…` when `allow_locking` is set, so the plan judges what the real run would) and stop — nothing changes, nothing rolls; exit 2 is reported as "would refuse" |
| `allow_locking` | names passed as `--allow-locking=<names>` (§5); letters, digits, `_`, `,` and `-` only |

What a run does:

1. **build** (staging only, under the `staging` environment, one build at a time across runs): checks out WMS-BE and WMS-FE at the refs, resolves the full SHAs, and pushes `wms-be:<sha>` / `wms-fe:<sha>` to ECR — skipping an image already there. Tags are immutable: one image per SHA, never rebuilt. **Production never builds**: it fails before migrate unless both images exist in ECR **and** match `/wms/staging/deployed`, the SHAs staging last deployed successfully (A3). Only the staging role can push.
2. **deploy** (one job under `environment: <env>` — production waits for its reviewer here, once):
   - reads `/wms/<env>/deploy`, the SSM parameter Terraform writes (cluster, subnets, security group, each family's **base** revision, roles, target counts) — a missing key fails the run before anything changes;
   - **migrate**: registers a copy of the base migrate revision with the new wms-be image, `run-task`, polls `describe-tasks` (≤ 45 minutes, then **stops the task** — a running migrator holds the advisory lock the next deploy would wait on — and fails; the step's own bound is 60), prints the migrate log, then reads the `migrate` container's exit code — **0** continues; **2** fails "migration refused — see §5" with nothing applied; anything else, or no exit code at all (the task failed to start — e.g. a secret with no value), fails with the stopped reason. The services are untouched on every failure;
   - **roll** api → **readiness gate** (`https://api.<host>/api/v1/health/ready` = 200 within 5 minutes) → worker (stop-then-start) → web. For each: copy the base revision, assert its roles are this environment's, swap only the image, `update-service` (with the target count when the service is at 0), then poll `describe-services` (≤ 20 minutes) until the PRIMARY deployment is `COMPLETED` **on the revision just registered**. A `FAILED` rollout, or a PRIMARY on any other revision (the circuit breaker rolled back), fails the job and nothing later rolls;
   - staging only: records `{be, fe}` in `/wms/staging/deployed`.
3. The job summary lists the SHAs, the migrate outcome and each service as rolled, failed or not attempted.

**Mixed versions are safe.** A failed later roll leaves a newer api beside an older worker or web; migrations are additive (§1), so the old processes keep working over the new schema. Fix forward, or re-run with the same SHAs and `skip_migrations`.

**Shape changes take effect at the next run.** `terraform apply` updates the base revisions; the running tasks change only when the pipeline next copies them. An apply never reverts a deploy (the services ignore the task definition and the count).

**Concurrency.** One deploy per environment at a time, never cancelled in flight. GitHub keeps only the **newest pending** run in a concurrency group: a third run dispatched while one runs and another waits replaces the waiting one. **The same holds for the global `wms-build` group**, which every staging run's build joins: while one build runs, a second waiting staging run is **cancelled without a word** when a third is dispatched — only the newest waiting build survives. Check the run list after dispatching several staging runs back to back.

**Time limits.** The deploy job's bounded work is at most 125 minutes — the Migrate step ≤ 60 (its poll stops at 45), three rolls ≤ 20 each, the readiness gate ≤ 5 — so the job's timeout is **170 minutes**, below the deploy role's **180-minute** session (`role-duration-seconds` 10800 = the role's `max_session_duration`). The credentials never expire inside a run.

### 8.6 Rollback

Rollback is **the previous images, never the schema** (§3): run the pipeline with the previous SHAs and `skip_migrations = true`. The previous SHAs are in the last good run's summary (or `aws ecr describe-images`).

**Production refuses a rollback to SHAs staging did not deploy last.** Its `skip_migrations` run still checks `/wms/staging/deployed` (A3), so production cannot go straight back to an older SHA. Two ways back:

1. **Through staging** (the normal path): re-deploy staging at the older SHAs with `skip_migrations = true` — the images are already in ECR, nothing is rebuilt — which records them in `/wms/staging/deployed`; then run production with the same SHAs.
2. **ECS's previous revision** (the emergency path, minutes faster, outside the pipeline): with the operator's credentials, point each service back at the task-definition revision it ran before — `aws ecs update-service --cluster wms-production --service <api|worker|web> --task-definition <family>:<previous revision>`, api first, then worker, then web (the revisions are in `aws ecs list-task-definitions --family-prefix wms-production-<role> --sort DESC`). Then bring staging and the pipeline back in line (path 1) before the next production deploy.

### 8.7 Rotation

- **The generated database and Valkey credentials** (A16): `terraform apply -replace='module.environment.random_password.db_app'` (or `db_auth`) updates the password secret and the URL secret together; the **next pipeline run's** `provision-roles` changes the role's password and its roll picks up the new URL. Between the two steps new app connections fail — rotate in low traffic, and run the pipeline (`skip_migrations = false`, the deployed SHAs) straight after the apply. The master password (`db_master`) is applied by RDS as soon as possible after the apply; the migrate task reads it at its next run. The Valkey AUTH token rotation is not automated (ElastiCache's `ROTATE`/`SET` strategy) — `PENDING.md`.
- **`MFA_ENCRYPTION_KEY`**: set the old value as a new secret, wire it as `MFA_ENCRYPTION_KEY_PREVIOUS` on the api and worker (a Terraform change), then put the new key into `mfa-encryption-key` and deploy (§2, `PENDING.md` tenancy).

### 8.8 Go-live gate (6-2c)

**Before real traffic, 6-2c must land** — its keep-alive change is the gate: the ALB's idle timeout is 60 s and the BE's server keep-alive is Node's 5 s default, so the ALB can reuse a connection the API has just closed, which yields intermittent **502s**. 6-2c sets `keepAliveTimeout` 65 s / `headersTimeout` 66 s and **verifies it under Bun** (the BE runs `bun src/main.ts`). Staging may show intermittent 502s until then. 6-2c also brings the worker heartbeat (C31), the bounded web drain (C30), the Bun drain smoke (C26), digest-pinned bases (C19) and the RDS CA bundle with `verify-full`.
