# Deploy runbook

**How the system is built into images, migrated, started and stopped.** One document for the operator; story 6-2a wrote it. Nothing here is provisioned yet: the AWS environments, the registry and the pipeline are **story 6-2b** (`docs/design/PENDING.md` → deploy). Until then the images are built and smoke-run in CI only (`image` jobs), and `deploy/compose.yml` runs the whole stack locally.

Companions: `SYSTEM-DESIGN.md` (the processes, readiness, the migrator), `../repos/wms-be/README.md` and `../repos/wms-fe/README.md` (the contracts), `PENDING.md` (what is not done).

---

## 1. The processes

Two images, four kinds of process. The wms-be image is the **same image for every backend process** (decision 2); the processes differ only by environment.

| Process | Image | Count | Command | Takes traffic |
|---|---|---|---|---|
| **migrate** | wms-be | one-shot, per deploy | `bun run db:migrate:deploy && bun run db:provision-roles` | no |
| **api** | wms-be | 1..N | the image default, `bun src/main.ts` | yes — the load balancer's target, health on `/api/v1/health/ready` |
| **worker** | wms-be | **exactly 1** | the image default | no (it listens on `PORT`, but nothing routes to it) |
| **web** | wms-fe | 1..N | the image default, `node start-standalone.mjs` → Next's `server.js` (port `3001`); it **refuses to start** (exit 1) without an absolute http(s) `WMS_API_BASE_URL` | yes |

**Exactly one worker task, deployed stop-then-start (minimum healthy 0 %, maximum 100 %).** Seven jobs are not proven safe to run twice at once — Reconciliation, ReservationReaper, CountScheduler, ReplenishmentScheduler, ChannelsSync, WaveCutoffSweep and SessionPurge (A8; the audit is in `PENDING.md`). Five document their own two-instance safety (the outbox relay's advisory lock; the storage snapshots, push sender, audit export and ledger integrity workers' comments in `jobs.module.ts`); the licence expiry sweep says nothing either way and belongs in the same audit. One task is the rule for all of them until the audit says otherwise. A rolling worker deploy would briefly run two.

**The API task sets no `*_POLL_MS`.** Every background job is env-gated off by default (`parsePollMs`: unset or `0` = off), so the API runs none; the worker sets all thirteen.

**Both images run as non-root** (wms-be: `bun`, uid 1000; wms-fe: `node`, uid 1000) and carry no secret: every key, password and URL comes from the task's environment at run time. In the wms-be image the code and `node_modules` are **root-owned**: the runtime user can run them, never rewrite them (code review C19).

### Health

| Route | Answers | Use it for |
|---|---|---|
| `GET /api/v1/health` | 200 whenever the process is up. Touches nothing | the container `HEALTHCHECK` (the image's own, through `bun -e fetch(…)` — Alpine has no curl) and liveness |
| `GET /api/v1/health/ready` | 200 `{status:'ready', migration:'<tag>'}` when both Postgres pools answer `select 1`, Valkey answers `PING`, and the database has applied **at least** every migration the image bundles; else **503** `not-ready` with `failing: [<check>…]` (`database`, `auth-database`, `valkey`, `migrations-unreadable`, `migrations-behind`). Names only — the reasons go to the task's log | the load balancer's target health; the deploy's "new tasks are ready" gate |

**At or after, never equal (A2).** The check is `max(created_at)` of `drizzle.__drizzle_migrations` ≥ the bundled journal's last `when` (drizzle stores no tag, only the journal's `when`). After the migrator runs, the database is AHEAD of the old tasks still serving — they stay ready, because **migrations are additive** (the assumption that makes this safe: a migration never removes what the previous image reads). An image whose migrations have not run is BEHIND and is never ready, so it never takes traffic. The app role reads the migrations table through the grant in `scripts/provision-roles.sql`.

Each probe query runs in its own transaction under `SET LOCAL statement_timeout` = the 2 s check bound, so a hung probe is cancelled by the server rather than left running on the request pool (code review C3).

**Readiness covers SHARED dependencies, so every task fails together** (code review C28). Postgres, Valkey and the schema are the same for every API task: when one is down, every task's `/health/ready` answers 503 at once. That is deliberate — a task that cannot reach the database cannot serve — and it relies on the load balancer **failing open**: an AWS ALB whose targets are ALL unhealthy routes to all of them anyway, so requests reach the API and fail with the API's own errors instead of the ALB's 503. A target group that does not fail open must not use `/health/ready`. The IaC values (thresholds, intervals) are 6-2b's.

For the web, the container health is `GET /runtime-config.js` (the one route that reads no session and redirects nowhere).

### Graceful shutdown

`SIGTERM` (or `SIGINT`) runs Nest's shutdown sequence (A1, `src/shared/lifecycle/shutdown.ts`) and exits **0**:

1. the listener stops accepting connections; a new request on a kept-alive connection is answered `503` with `Connection: close`;
2. every worker clears its timer and waits for the tick already running; in-flight HTTP requests finish — both bounded by one shared 20 s drain deadline;
3. the HTTP server closes, destroying any socket left;
4. the Postgres pools end (3 s for an in-flight query) and Valkey quits.

A sequence still running after **25 s** is ended by the force exit (exit 1). Set the orchestrator's stop timeout to **30 s** (`stopTimeout` on ECS, `stop_grace_period` in compose). The drain's 20 s is counted from the **signal** (the first signal fixes the deadline), and a second SIGTERM during the drain is ignored rather than killing the process (code review C4/C5).

**Behind the ALB (code review C28):** readiness does not flip to 503 on SIGTERM — the order is the orchestrator's. ECS deregisters the task from the target group first and sends SIGTERM after; set the target group's **deregistration delay to 20–25 s**, so a request the ALB routed just before deregistration still finds the task draining (the 20 s drain, inside the 25 s force exit, inside the 30 s stop timeout). A longer delay only waits; a shorter one can cut requests the ALB still routes.

**The web has no graceful drain** (code review C30): Next's standalone `server.js` exits on SIGTERM without waiting for in-flight requests. Its requests are page renders and `/runtime-config.js` (short; the browser retries a navigation), so this is accepted for now; a drain wrapper is 6-2b's.

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
| `EXPO_ACCESS_TOKEN` | W | only with `PUSH_GATEWAY=expo` |
| `WMS_APP_PASSWORD`, `WMS_AUTH_PASSWORD` | **M only** | applied by `db:provision-roles` as a SCRAM-SHA-256 verifier computed in the process (the plaintext never reaches the server); **required when `NODE_ENV=production`** — the image sets it, and the script exits 1 without both (C2). Never on the API or worker |

### wms-be — side-effect ports (modes, never credentials)

| Variable | Where | Value |
|---|---|---|
| `PUSH_GATEWAY` | W | `unconfigured` (default, no network) \| `expo` (needs `EXPO_ACCESS_TOKEN`; boot fails without it) |
| `PUSH_HTTP_TIMEOUT_MS` | W | default 10000 |
| `EWAY_GATEWAY` | A W | `unconfigured` (default) \| `sandbox` |
| `CHANNEL_HTTP_TIMEOUT_MS` | A W | default 10000 |
| `LEDGER_ANCHOR_WORM` | W | `none` (default) \| `s3` (needs `LEDGER_ANCHOR_S3_BUCKET`; S3 Object Lock bucket, `PENDING.md` inventory) |
| `LEDGER_ANCHOR_S3_BUCKET`, `LEDGER_ANCHOR_RETENTION_DAYS` | W | with `s3` only; retention default 2557 days |
| `AWS_REGION` | A W | default `ap-south-1`. Read by the worker with `LEDGER_ANCHOR_WORM=s3`, and by **the API and the worker with `EMAIL_PROVIDER=ses`** (every API task builds the SES client at boot; the API task role needs no SES permission — it never sends, only the worker does) |
| `EMAIL_PROVIDER` | A W | `off` (default — invite mail `skipped`) \| `log` (captured, ids logged) \| `ses` (SES v2 in `AWS_REGION`; SDK credential chain). `ses`/`log` need `EMAIL_FROM`, `WEB_BASE_URL` and `EMAIL_SEAL_KEY` — the boot fails naming the missing one (5-1a). The API queues the mail in the invite transaction, so it needs the provider settings as well as the worker |
| `EMAIL_FROM`, `EMAIL_REPLY_TO` | A W | the verified SES sending address (bare); the fallback Reply-To |
| `WEB_BASE_URL` | A W | the web app's absolute base URL (`https` in production) — the invite response's `inviteUrl` and the emailed link |
| `EMAIL_MAX_PER_TICK` | W | default 10. The cap is **per worker process**, and each message makes **two** SES calls (the suppression pre-check, then the send): keep (processes × cap × 2) ÷ poll seconds under the SES rate |
| `EMAIL_ALLOWLIST_DOMAINS` | A W | **staging only** — other domains are `skipped` |

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

Backend first, then the web (the cross-repo rule). Every step gates the next.

1. **Build** both images from the merged commits (CI's `image` jobs prove they build and boot).
2. **Pre-build any large index** the migrator would refuse (§5). Run its `--dry-run` against production first: it prints the plan and changes nothing (exit 2 when a real run would refuse).
3. **Run the migrate task** — `bun run db:migrate:deploy && bun run db:provision-roles`, as the owner. A refusal (exit 2) stops the deploy with nothing applied. `db:provision-roles` runs **every** deploy: it is idempotent, and it is what grants the app role the new tables (default privileges) and the migrations table (readiness).
4. **Start the new API tasks; wait for `/health/ready` = 200** on them. Old tasks stay ready throughout (at-or-after).
5. **Roll the API** (the load balancer drains the old tasks; their SIGTERM drains in-flight requests).
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
- Under Bun (the wms-be runtime), a `SIGTERM` during a request lets it finish (200), refuses a new connection, and exits 0. **The drain is verified on Node by the jest suite and on Bun by hand only** (code review C26) — a Bun in-image drain smoke belongs to 6-2b's pipeline.
