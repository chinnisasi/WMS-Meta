---
title: 'Async audit export — the Owner exports a filtered audit trail of up to 1M events to CSV, and is notified when it is ready'
type: 'feature'
created: '2026-10-13'
status: 'done'
route: 'dispatch'
review_loop_iteration: 0
baseline_commit: 'wms-be d1e62ad9bd695b506f72b8eafed6cfffa3fc601c; wms-fe 45ed1392e33dace46259cfac6cdd2330bec2ec1c'
context:
  - '_bmad-output/implementation-artifacts/epic-9-context.md'
  - '_bmad-output/implementation-artifacts/spec-9-3a-audit-trail-and-ledger-navigation.md'
  - 'docs/design/SYSTEM-DESIGN.md'
  - 'docs/design/IMPLEMENTATION-GUIDE.md'
  - 'docs/design/API-SURFACE.md'
  - 'docs/design/modules/reporting.md'
  - 'docs/design/modules/tenancy.md'
  - 'docs/design/modules/notifications.md'
  - 'docs/design/modules/billing.md'
  - 'docs/design/frontend/SYSTEM-DESIGN.md'
  - 'docs/design/frontend/IMPLEMENTATION-GUIDE.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** FR-28 / story 9.3 requires that an export of 100k audit events completes asynchronously and notifies on completion. 9-3a shipped the owner's paged audit read (`GET …/reporting/audit`), but nothing can export it. The repo has no file storage, no server-side CSV writer, no file-download route, and no per-user notification audience: 9-2's entries route by capability only.

**Approach:**
- **Backend:**
  - an owner-only keyed command queues an export of the current audit filters;
  - an env-gated worker writes the matching rows to a gzipped CSV behind a storage port, with a Postgres implementation;
  - completion or failure raises a notification for **the requester only**, the first per-user audience;
  - files expire after 7 days.
- **Web:** "Export these results" and a "Your exports" list in the Audit section on `/reports`, with an authenticated Download.

**Decisions (human, 2026-10-13):**
1. **Storage:** Postgres, behind a port. The gzipped CSV bytes live in their own table and are served by an authenticated download route. 9-3c's S3 can replace the implementation later.
2. **Lifetime:** a finished export (ready or failed) stays 7 days. Then its file is deleted, and the row stays as history with status `expired`.
3. **Size cap:** up to 1,000,000 events. A larger match fails with `too-many-events` ("narrow the filters or dates"). 100k is the performance target, not the ceiling.
4. **Pick-up:** a "Your exports" list on `/reports`. The notification links there; it does not download.

## Boundaries & Constraints

**Always:**

- **The owning module is tenancy.** Tenancy owns `audit_events` and `users` (`tenancy.md`), so exporting them needs no new read exception.
  - Tenancy owns `audit_exports` and `audit_export_files` and is the only module that writes them. An ownership block in `architecture.spec.ts` pins this, following the 9-2 notifications block.
  - **Reporting stays read-only and gains no code.** The routes sit in the api shell's `ReportingController`, which calls `TenancyService`.
  - Worker-written lifecycle events are **outbox events only, never `audit_events` rows**. The worker is unkeyed and outside the audit rule.
- **The filter is shared, not copied.**
  - **New file:** `src/shared/db/audit-filter.ts`, following the `warehouse-filter.ts` precedent. It imports only `auditEvents` from the schema and contains no `join`. It takes from `reporting/audit.ts`:
    - the inline filter array, as `auditFilterSql(tenantId, filters): SQL[]`;
    - `escapeLikePrefix`;
    - `AUDIT_ACTION_PREFIX_RE`;
    - the `AuditFilters` type.
  - **`audit.ts` re-exports the moved names**, so `test/audit-trail.spec.ts` and the 9-3a guard block pass unchanged. That guard block is extended to the new file with the same rules.
  - Tenancy may not import reporting (only the api shell may), which is why the code moves rather than being imported.
- **The request:** `POST /tenants/{t}/reporting/audit/exports`.
  - **Body** `AuditExportRequestDto`: `{actorUserId?, actionPrefix?, targetType?, targetId?, from?, to?}`. It shares a base DTO, `AuditFilterBaseDto`, with `AuditTrailQueryDto`, plus `assertInstantRange`. `Idempotency-Key` is required.
  - **Access:** `TenantSessionGuard` and `assertOwnTenantToken`.
  - **In one transaction:**
    1. **Lock.** `pg_advisory_xact_lock(hashtext('audit-export:' || tenant || ':' || requester))`.
    2. **Replay under the lock.** The hash is over `{arm: 'audit-export', tenantId, requestedBy, ...filters}`, with absent keys omitted and instants canonicalised. A same-key replay re-serves the original 202 snapshot, `queued` status included. A different body is 422 `idempotency-key-reuse`.
    3. **Guard.** `assertPermission(getMemberRoleIn(tx, …), 'audit.view')`; anything else is 403 `role-denied`.
    4. **Active check.** An active export (`queued`/`running`) for this requester answers 409 `export-in-progress`.
    5. **Writes:**
       - insert the `audit_exports` row as `queued`;
       - write the audit row `audit_export.requested` (target `audit_export` → the export id; actor the requester; `reference` = key);
       - write the key last.
  - **Backstop.** A 23505 on the partial unique `audit_exports_active_unique` maps to the same 409.
  - **Vocabulary.** `audit_export` joins `AUDIT_TARGET_TYPES`, and the action joins `AUDIT_NEW_ACTIONS` with an `expectAuditRow` pin.
  - **The answer** is always 202 `AuditExportDto`.
- **`audit_exports`.** RLS uses the `<table>_tenant_isolation` NULLIF policy. **No FKs** (§3).
  - **Columns:**
    - `id` (uuidv7), `tenant_id`, `requested_by`;
    - `filters jsonb`: the validated body, absent keys omitted, `from`/`to` canonical UTC;
    - `snapshot_at timestamptz`: the request transaction's `now()`, so it equals the row's `created_at`;
    - `status` (`queued|running|ready|failed|expired`), `attempts int default 0`;
    - `started_at`, `heartbeat_at`, `finished_at`, `expires_at`;
    - `row_count`, `byte_size` (gzipped), `sha256` (hex of the uncompressed CSV bytes, BOM included);
    - `failure_reason` (`too-many-events|interrupted|export-error`);
    - `created_at`, `updated_at`.
  - **Per-status shape CHECK**, with each refused shape probed in 0070:

    | Status | `started_at` | `heartbeat_at` | `finished_at` / `expires_at` | ready fields¹ | `failure_reason` |
    |---|---|---|---|---|---|
    | `queued` | null | null | null | null | null |
    | `running` | set | set | null | null | null |
    | `ready` | — | — | set | set | null |
    | `failed` | — | — | set | — | set |
    | `expired` | — | — | set | kept | kept |

    ¹ `row_count`, `byte_size` and `sha256`. A dash means the CHECK does not constrain the column. `expired` keeps whatever it had, so history survives.
  - **Indexes:** `(tenant_id, requested_by, created_at DESC)`, and the partial unique `audit_exports_active_unique (tenant_id, requested_by) WHERE status IN ('queued','running')`.
- **`audit_export_files`** (RLS, no FK): `export_id` PK, `tenant_id`, `content bytea`. It is a separate table so a list never reads bytes.
  - **Port:** `AuditExportStore { put(tx, tenantId, exportId, bytes); open(tx, tenantId, exportId) → Buffer | null; remove(tx, tenantId, exportId) }`.
  - **Binding:** token `AUDIT_EXPORT_STORE`, bound to `PostgresAuditExportStore`.
- **The worker.** `AuditExportWorker` in `jobs/jobs.module.ts` runs when `AUDIT_EXPORT_POLL_MS` is set, on the `PushSenderWorker` shape:
  - `parsePollMs`, single-flight `running`, per-tenant `try/catch`;
  - `AUTH_DATABASE` discovery: `select distinct tenant_id from audit_exports where status = 'queued' or (status = 'running' and heartbeat_at < now() - interval '15 minutes') or (status in ('ready','failed') and expires_at < now())`.
  - It calls `TenancyService.runDueAuditExports(tenantId)`, which runs these steps in order:
  1. **Reclaim.** A `running` row with `heartbeat_at` older than 15 minutes goes back to `queued` while `attempts < 3`. Otherwise it becomes `failed`/`interrupted`, with `finished_at`, `expires_at = now() + 7 days`, and `audit_export.failed` appended in the same transaction.
  2. **Expire.** Each `ready`/`failed` row past `expires_at` is handled in one transaction: `store.remove`, set `expired`, and append `audit_export.expired` (`{exportId, requestedBy}`).
  3. **Prove the snapshot (§7d).** Take the oldest `queued` row. It is claimable only when both hold:
     - `now() ≥ snapshot_at + 5 s`;
     - no other client backend has an open transaction with `xact_start < snapshot_at`.

     A hidden session counts as not proven; nothing is claimed and the worker logs it. The probe moves from `billing/storage-snapshot.ts` (`openSessionsInTx`) to `src/shared/db/open-transactions.ts`, and billing calls it with unchanged behaviour (its suite pins that).
  4. **Claim** that row: `FOR UPDATE SKIP LOCKED`. It becomes `running`, with `attempts + 1` and `started_at = heartbeat_at = now()`. Commit before working, and remember the claimed `attempts`.
  5. **Write.** Page the rows matching `auditFilterSql(filters)` with `created_at < snapshot_at`.
     - **Order:** `created_at DESC, id DESC`.
     - **Cursor:** keyed on **the full-precision `created_at::text`** (`fullPrecisionInstant`, the `audit.ts:136-145` rule).
     - **Pages:** `auditExportLimits.pageSize` rows per page (default 5,000), each in its own tenant transaction under a 30 s `statement_timeout`. Each page left-joins `users` for `actor_email` and ends with `heartbeat_at = now() WHERE id AND status='running' AND attempts = claimed`.
     - **Output:** rows stream through `zlib.createGzip` into memory, with a SHA-256 over the uncompressed bytes.
     - **Cap:** reading row `auditExportLimits.maxRows + 1` (default 1,000,000) stops the run with `too-many-events`.
  6. **Finish**, in one transaction, conditional on `status='running' AND attempts = claimed`. If zero rows match, the run was reclaimed: discard everything, append nothing, store nothing.
     - **On success:** `store.put`, then `ready` with the counts, `finished_at`, and `expires_at = finished_at + 7 days`. Append `audit_export.ready` (`{exportId, requestedBy, rowCount}`).
     - **On any failure:** `failed` with its reason. An unexpected throw, including a page's 57014, is `export-error` and is logged. Append `audit_export.failed` (`{exportId, requestedBy, reason}`).
     - **The worker never throws out of a tick.**
  - **Injectable limits.** `auditExportLimits = { pageSize, maxRows }` is an exported mutable object (the `pushClock` / `reservationRepairClock` precedent), so tests can shrink both.
- **The CSV** (RFC 4180, `\r\n`, UTF-8 with a BOM so Excel reads it):
  - **Header:** `recorded_at,occurred_at,actor_kind,actor_user_id,actor_email,action,target_type,target_id`.
  - **Instants** are IST: ISO-8601 with `+05:30` and milliseconds.
  - **`actor_kind`** is `system` for `SYSTEM_ACTOR_ID`, with an empty email. An unknown user also gets an empty email.
  - **Quoting:** a cell holding `,` `"` CR or LF is quoted.
  - **Formula guard:** a cell starting with `=` `+` `-` `@`, TAB or CR gets a leading `'`. This is the 21-5b rule (`wms-fe/src/lib/csv.ts:15-17`).
  - **`reference` is never exported** (9-3a's rule).
- **List:** `GET /tenants/{t}/reporting/audit/exports` returns **the caller's own** last 20 exports, newest first, unpaged. That is a documented exception to cursor paging. The read is `audit.view`-gated.
  - **Item:** `AuditExportDto {id, status, filters: AuditFilterBaseDto, requestedAt, startedAt, finishedAt, expiresAt, rowCount, byteSize, sha256, failureReason}`, each enum published.
- **Download:** `GET /tenants/{t}/reporting/audit/exports/{id}/file`, gated by `audit.view` **and** `requested_by = caller`.
  - **Refusals:**
    - another member's export, or an unknown id → 404 `export-not-found`;
    - `queued`/`running`/`failed` → 409 `export-not-ready`;
    - `expired` → 409 `export-expired`.
  - **Otherwise 200**, sent with `@Res()` and `res.end(buffer)` (the `openapi.controller.ts` precedent; ETag off). Headers:
    - `Content-Type: text/csv; charset=utf-8`;
    - `Content-Encoding: gzip`;
    - `Content-Length` (the gzipped size);
    - `Content-Disposition: attachment; filename="audit-export-<IST yyyyMMdd-HHmm>.csv"`;
    - `Cache-Control: no-store`.
  - **OpenAPI:** `@ApiProduces('text/csv')` with schema `{type: string, format: binary}`. The error arms are problem+json.
- **Notifications: the first per-user audience.**
  - **The column.** `notifications` gains a nullable `recipient_user_id`. A CHECK holds it in both directions: `source_type = 'audit-export'` ⇔ `recipient_user_id IS NOT NULL`.
  - **The audience type.** `SOURCE_AUDIENCE`'s value type gains `{capability, recipient: true}`.
  - **Reads.** `list` and `status` add `AND (recipient_user_id IS NULL OR recipient_user_id = $me)` beside the existing source-type filter. Every 9-2 source is unchanged, and this is pinned.
  - **The source `audit-export`** joins the TS tuple, the CHECK (by migration), the `EVENT_ROUTES`, and the DTO union. Its DTO is one summary arm: `AuditExportSummaryDto {status: 'ready'|'failed', reason?: enum, rowCount?}` (the `BatchAlertSummaryDto` shape).
    - **Raise:** `audit_export.ready` and `audit_export.failed` raise with `sourceId` = the export id, `warehouseId` null, and recipient = `requestedBy`.
    - **Resolve:** `audit_export.expired` resolves with resolution `expired`.
    - **Recipient on every path:** `DecodedRaise` and `DecodedResolve` both carry `recipientUserId`. The tombstone insert and the raise's `set` both write it, so an expired-before-ready delivery never leaves a null recipient.
    - **Audience:** `{capability: 'audit.view', recipient: true}`.
  - **Open until expiry (decision).** An entry stays open until expiry. Downloading does not resolve it. The dot clears on panel open, as for every source.
  - **Never pushed.** The source is not in `push.enqueue.ts`'s subscription list or `APPROVAL_PUSH_SOURCES`, and a test pins that it queues no push row.
- **Migration 0070** (§3 checklist; the probe DO-block covers every new CHECK and the widened source CHECK):
  - the two tables, their RLS and indexes;
  - `notifications.recipient_user_id` and its CHECK;
  - the widened `notifications_source_type_check`.
- **The web: the Audit section** (`components/reports/audit-trail.tsx`).
  - **"Export these results".** It posts the **applied** filters; its label says so ("Export the applied filters") and edits not yet applied are not sent. A **new Idempotency-Key is minted per click** (`client-invoices.tsx` precedent).
    - **Availability:** it stays enabled when the trail read failed with `report-unavailable`, the case export exists for. It is hidden on `role-denied`.
    - **After it posts,** the exports list reloads.
  - **"Your exports"** (`useAuditExports`, the §1 loader).
    - **Anchor:** the section is wrapped in an always-rendered `id="audit-exports"` element (loading and failed states included).
    - **Hash handling:** on mount, and on `hashchange` to `#audit-exports`, the list reloads and scrolls into view once ready.
    - **Columns:**
      - requested time (IST);
      - a filters summary: the actor from `useAuditMembers`, "System" for `SYSTEM_ACTOR_ID`, the target from `AUDIT_TARGET_LABEL`, and `to` shown as the IST day before the stored instant;
      - status;
      - events;
      - size;
      - expires;
      - Download, for `ready` rows.
    - **States:** `queued`/`running` read "Preparing…". A manual **Refresh** reloads; there is no polling. The empty state reads "No exports yet".
  - **Download.**
    - **Fetch:** through the generated client with `parseAs: 'blob'`, saved by a new `downloadBlob(filename, blob)` beside `downloadText` (`lib/csv.ts`). The bearer header rules out a plain link.
    - **Filename:** built on the client from the row's `requestedAt`, as `audit-export-<IST yyyyMMdd-HHmm>.csv`. CORS does not expose `Content-Disposition`, and no CORS change is made.
    - **Refusals:** a 409 or 404 shows the reason and reloads the list.
  - **`exportReason`** maps `role-denied`, `export-in-progress` ("An export is already running — wait for it to finish"), `export-not-ready`, `export-expired`, `export-not-found` and `validation-failed`.
  - **Labels:** `AUDIT_TARGET_LABEL` gains `audit_export` ("Audit export").
- **The web: notifications.**
  - **Source type:** `audit-export` joins `KNOWN_SOURCE_TYPES` (the `satisfies` row).
  - **Category:** "Audit export".
  - **Description:** "Audit export ready — N events", or "Audit export failed — " plus the reason. The reason copy is a `Record` over the reason enum:
    - `too-many-events` → "too many events; narrow the filters or dates";
    - `interrupted` → "interrupted; run it again";
    - `export-error` → "something went wrong; run it again".
  - **Link:** `/reports#audit-exports`.

**Never:**
- **Not in this story:**
  - S3 or signed URLs (9-3c);
  - a ledger digest or WORM anchor in the export (9-3c);
  - retention of `audit_events` itself (9-3d).
- **No export of other reports**, such as the ledger or the service report. The port is audit-only.
- **No auditing of downloads.** A download writes nothing (PENDING).
- **No portal access**, and no export by anyone but the requester. An owner cannot download another owner's export.
- **No auto-refresh or polling** of the exports list, and no push for the export source.
- **No new reporting code**, no fourth read-only exception, no FK, no CORS change, and no new capability.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Happy path | Owner exports `actionPrefix=transfer.`; worker ticks | 202 `queued`, then `ready`. The requester's panel shows "Audit export ready — N events" with the dot. | N/A |
| File equals paged read | `pageSize: 2`; a seeded tie group from one transaction straddles a page boundary | The gunzipped CSV rows equal the 9-3a read for the same filters with `to = snapshot_at`, after normalising instants to UTC, stripping the `'` prefix, and taking emails from `users` | — |
| Replay | Same key, same body (also with the export since `ready`) | The original 202 `queued` snapshot; no second export row; no second audit row | Different body → 422 `idempotency-key-reuse` |
| Same-key race | Two parked same-key requests | One export; the loser replays | — |
| Not owner | ops_manager posts, lists or downloads | 403 `role-denied`; nothing written | — |
| Second active export | Requester has one `queued` | 409 `export-in-progress` | — |
| Rows after the request | Events committed after `snapshot_at` | Not in the file | — |
| Open older transaction | A transaction with `xact_start < snapshot_at` still open | Stays `queued`; claimed after it ends, and its row is in the file | — |
| Over the cap | `maxRows: 3`, 4 matches | `failed`/`too-many-events`; no file stored | — |
| Reclaim races a live run | Runner A's heartbeat is backdated, and runner B reclaims and re-runs | A's finish updates zero rows and appends nothing. B's result stands, with exactly one `ready` event. | — |
| Crash | `running`, heartbeat older than 15 minutes, `attempts = 3` | `failed`/`interrupted`; the requester is notified | — |
| Download | ready / queued / expired / another's | 200; the raw gzip bytes' `Content-Length` and sha256 match the row (read with a raw body parser) / 409 `export-not-ready` / 409 `export-expired` / 404 `export-not-found` | — |
| Expiry | `ready` past `expires_at`, backdated in SQL | File row gone; `expired`; panel entry resolved; Download gone from the list | — |
| Expired before ready | Deliver `expired`, then `ready` | Entry resolved, and the recipient is set throughout; no other owner sees it | — |
| Other members' panels | Another owner | Never sees the requester's entry, in `list` or `status` | — |
| Formula cell | Email or action starting with `=`/`+`/`-`/`@`/TAB/CR | Exported with a leading `'` | — |
| Worker off | `AUDIT_EXPORT_POLL_MS` unset | Rows stay `queued`; the list reads "Preparing…" | The docs name the env var |

</frozen-after-approval>

## Code Map

Paths are under BE `workspace/core/backend/wms-be/src` and FE `workspace/core/frontend/wms-fe/src`.

- **The audit read to share:**
  - `modules/reporting/audit.ts`: `:35-42` (the constants and `AUDIT_ACTION_PREFIX_RE`), `:44` `AuditTrailQuery`, `:78` `escapeLikePrefix`, `:107` `readAuditPageInTx` (the inline filters to extract), `:136-145` (the `::text` cursor), `:173` `armAuditDeadline`.
  - `reporting.facade.ts:259` `auditTrail`, which carries the guard shape and the 57014 walk.
  - `api/reporting.controller.ts:116`.
  - `api/reporting.dto.ts:460` `AuditTrailQueryDto`; split its filter fields into `AuditFilterBaseDto`.
  - `shared/db/warehouse-filter.ts` is the precedent.
  - `test/audit-trail.spec.ts:11` imports `escapeLikePrefix`.
  - `test/architecture.spec.ts:2398-2420` holds the third-exception block; `:1611-1624` restricts who may import reporting.
- **Audit vocabulary:**
  - `shared/primitives/audit.ts`: `:31` `SYSTEM_ACTOR_ID`, `:44` `AUDIT_TARGET_TYPES`, `:99` `AUDIT_NEW_ACTIONS`.
  - The guard: `test/support/audit-guard.ts` (`expectAuditRow`).
- **Command template:**
  - `modules/clients/clients.command.ts`: `:471` `replay`, `:492` `audit`, `:517` `writeIdempotencyKey`.
  - `registration.command.ts:188-194` returns 422 on key reuse.
  - Race-test pattern: `test/inbound.spec.ts` (`raceTwice` + `waitParked`).
  - Permissions: `modules/tenancy/permissions.ts:266` (`audit.view`), `:407` `assertPermission`.
- **Tenancy:**
  - `tenancy.module.ts:76` exports `TenancyService` (`tenancy.service.ts:568`). Add `runDueAuditExports(tenantId)` there, plus the list and file reads and the request command.
  - New files: `audit-export.command.ts`, `audit-export.runner.ts`, `audit-export.store.ts`, `audit-export.csv.ts`.
  - Schema: `shared/db/schema.ts:96` `users`, `:194` `audit_events` (whose `created_at` is `now()`, the transaction start).
- **§7d probe:** `modules/billing/storage-snapshot.ts:259-282` `openSessionsInTx` moves to `shared/db/open-transactions.ts`.
- **Outbox:**
  - `OUTBOX_SINK` is provided by `SharedModule` (`shared.module.ts:48`); call it as `outbox.append(tx, {messageId, tenantId, type, payload, occurredAt})`.
  - Example: `putaway/bin-state.command.ts:156`.
  - Event constants are module-local (`invoicing/events.ts`).
- **Notifications:**
  - `modules/notifications/notification-sources.ts`: `:23` the tuple, `:111` `NotificationSummary`, `:122` `DecodedRaise`, `:223` `NOTIFICATION_SOURCES`, `:424` `EVENT_ROUTES`, `:461` `SOURCE_AUDIENCE`, `:473` `visibleSourceTypes`.
  - `notifications.delivery.ts`: `:101-125` the tombstone, `:132-151` `raise` and its `set`.
  - `notifications.facade.ts`: `:104` `list`, `:159` `status`.
  - Pushes: `push.enqueue.ts:116-122` (its subscription list) and `push-rules.ts` `APPROVAL_PUSH_SOURCES`.
  - DTOs: `api/notifications.dto.ts`, with `:63` `BatchAlertSummaryDto` as the shape and the discriminator around `:152`.
  - Migration: `drizzle/0067_notifications.sql`.
  - Ownership-block precedent: `test/architecture.spec.ts:1453`.
- **Jobs:**
  - `jobs/jobs.module.ts`: `:967` `parsePollMs`, `:996-1080` `PushSenderWorker`.
  - `modules/notifications/push.sender.ts:104` is the stale-and-claim pattern.
  - `shared/db/tenant-scope.ts:68` `withTenantTransaction`.
  - The clock precedent: `pushClock`, and `inventory/reservation.service.ts:58`.
- **Download:**
  - `api/openapi.controller.ts:20` is the `@Res()` precedent.
  - `app.factory.ts:24-29` sets CORS without `exposedHeaders`; leave it.
- **Migration:**
  - Latest `drizzle/0069_*`, so this one is 0070.
  - Update `drizzle/meta/_journal.json` and the snapshot.
- **FE:**
  - `components/reports/audit-trail.tsx`: `:42-47` the gate, `:52-54` the state, `:63-72` `from ≤ to`, `:183`.
  - `components/shared/surface.tsx:31-38` `Section` takes no `id`.
  - `lib/audit.ts`: `:22` `AUDIT_TARGET_LABEL`, `:121` `istDayEnd`, `:143`, `:173`.
  - `lib/use-audit-trail.ts`: `:34`, `:82`, `:97` `useAuditMembers`.
  - `lib/api/client.ts`: `:341` `API_BASE_URL`, `:361` the bearer, `:384` `ApiProblem`, `:1154` `fetchApiAuditTrail`.
  - The generated client: `client.gen.ts:181-198` (`response` beside `data`; error bodies parsed as JSON).
  - `lib/csv.ts`: `:15-17` the formula guard, `:38` `downloadText`.
  - `components/compliance/eway-bills.test.tsx:111,149` stubs `fetch` and `URL.createObjectURL`.
  - `client-invoices.tsx` mints a key per click.
  - `lib/notifications.ts`: `:28`, `:72`, `:127`, `:196`.

## Tasks & Acceptance

**Execution:**
- [x] **BE shared code:**
  - `shared/db/audit-filter.ts`, with `audit.ts` calling it and re-exporting the moved names, and the extended guard block;
  - `shared/db/open-transactions.ts`, called by billing;
  - the base DTO.
- [x] **BE migration 0070** (§3): tables, RLS, CHECKs, indexes, `recipient_user_id` and its CHECK, the widened source CHECK; journal, snapshot, probe.
- [x] **BE tenancy:**
  - the store port and the Postgres implementation;
  - the CSV writer;
  - the request command (lock, replay, guard, active check, audit row, vocabulary);
  - the runner (reclaim, expire, §7d probe, claim, write with heartbeat, conditional finish) behind `runDueAuditExports`;
  - the list and file reads;
  - the three outbox events;
  - `auditExportLimits`.
- [x] **BE api:** the three routes on `ReportingController`, the DTOs, `openapi.json`.
- [x] **BE jobs:** `AuditExportWorker`; `AUDIT_EXPORT_POLL_MS` in `.env.example` and the README.
- [x] **BE notifications:**
  - the recipient column through raise, the tombstone, `list` and `status`;
  - the `audit-export` source and its DTO;
  - the no-push pin.
- [x] **BE tests:**
  - every matrix row;
  - the tenancy ownership block;
  - the 9-2 sources unchanged.
  - Rows are backdated in SQL against `now()` (`push.spec.ts`), and the runner is driven through `runDueAuditExports`, not timers.
- [x] **BE load:** `scripts/loadtest-audit-export.ts` seeds 100k `audit_events`, runs one export, and reports its time and `byte_size`. Reported, not gated.
- [x] **FE:**
  - `api:generate`;
  - `downloadBlob`;
  - `useAuditExports`, the export button, the list with its anchor and hash handling, Download, `exportReason`;
  - `AUDIT_TARGET_LABEL`;
  - the notification source;
  - tests for every web row. Download tests serve plain CSV bytes.
- [x] **Meta docs:**
  - `tenancy.md` (the export), `notifications.md` (the per-user audience), `reporting.md` (the routes; no reporting code), `billing.md` (the probe moved);
  - IMPLEMENTATION-GUIDE: §8 (the new worker); §6 (a binary success response, `@Res()`); §7d (its second user);
  - API-SURFACE: the routes; the list's paging exception; the two new gated reads;
  - `frontend/SYSTEM-DESIGN.md`; both repo contracts; SYSTEM-DESIGN's background-jobs table;
  - PENDING:
    - close "the 9-3 export-completion hook";
    - add: no download audit; Postgres storage until S3; the whole file is held in memory, at the measured size; CORS does not expose `Content-Disposition`.

**Acceptance Criteria:**
- Given 100k seeded audit events and the worker on, when the owner exports with no filters, then the export reaches `ready`, the CSV holds 100k rows plus a header, and the requester's panel shows it. The load script reports the time and size.
- Given every backend suite, when it runs, then `assertEveryKeyAudited` passes. The export request is keyed and audited.
- Given the full BE and FE suites, lint, typecheck, build and the capability-mirror check, when run, then they pass.

## Implementation Notes

Built on wms-be `feat/9-3b-async-audit-export` (`d1e62ad..0839383`) and wms-fe on the same branch (`45ed139..89be835`), each one commit carrying the story and its code-review patch. Re-verified 2026-10-14: BE 81 suites / 1905 tests, lint, typecheck; FE 1482 tests, lint, typecheck, capability mirror (42), `next build`; the load script at 100k and at the 1M cap.

Implemented 2026-10-14 against the reviewed design. Where the code goes beyond, or reads, the frozen text:

- **`auditExportLimits` has a third field, `snapshotGraceMs`** (default 5,000 — the spec's 5 s). The §7d margin is read from it so a suite need not sleep 5 s per export; production never changes it. The spec names `{pageSize, maxRows}` only — this is additive, and `test/audit-export.spec.ts` pins the margin itself ("not claimed inside its clock-skew margin").
- **`AuditExportRunner.openSessions` is a plain field** set to the shared `openSessionsInTx` (the `ReportingFacade.auditRead` precedent), so the suite can stand in a hidden session; billing keeps its own `openSessionsInTx` method as a one-line delegate for the same reason (the metering suite patches it).
- **Two raises for one source.** `SourceSpec` gained an optional `moreRaises` list: `audit_export.ready` is the source's `raise`, `audit_export.failed` its second raise. `EVENT_ROUTES` routes both.
- **The §7d comparison** is `oldestXactStart ≤ snapshot_at`, both millisecond-truncated: truncation only moves either instant earlier-or-equal, and `≤` keeps every transaction that began before the snapshot on the "not proven" side.
- **The per-status CHECK is written as one implication per status**, so an unknown status passes it and is refused by `audit_exports_status_check` (the first draft's OR-of-arms form was refused by the shape CHECK first — the probe caught it). A fourth CHECK, `audit_exports_sha256_check` (`^[0-9a-f]{64}$` or null), is probed too.
- **The stored filters lower-case `actorUserId`/`targetId`** (uuids compare case-insensitively in SQL; the stored and hashed form is one spelling).
- **The web's `to` summary** shows the IST day of `to − 1 ms` — identical to "the IST day before the stored instant" for every export the web makes (its `to` is always an IST midnight), and still correct for an API caller's non-midnight `to`.
- **Load:** `bun scripts/loadtest-audit-export.ts` (2026-10-14, local compose Postgres 18): 100,000 events, no filters → `ready` in ~1.2 s (20 pages), `byte_size` 3,412,846 (18.3 MB uncompressed), sha256 verified over the HTTP download, the requester's panel shows "ready — 1,00,000 events". **At the cap** (re-verification, 2026-10-14, `--events 1000000`): `ready` in ~50 s (200 pages), `byte_size` 32,638,049 (182.6 MB uncompressed), the downloaded bytes and `Content-Length` equal it, sha256 matches; peak RSS 1.58 GB for the script's one process (seeding, the server, the runner and the download together — not the runner alone).
- **Existing tests adjusted for the change, not retargeted:** `test/notifications.spec.ts` (its eight `CASES` are the capability-routed sources; the vocabulary pin adds `audit-export`; the owner's routed list is the eight raised there), `test/client-isolation.spec.ts` (102 → 104 policies, the two new ones pinned to the plain tenant policy), `test/architecture.spec.ts` (the 9-3a guard block runs over `audit.ts` and `shared/db/audit-filter.ts`; a new tenancy-ownership block), and the web's `audit-trail.test.tsx` (it scopes to the trail's own request path and table, since the section now also reads `…/audit/exports`).

## Spec Change Log

## Review Triage Log

Design review (2026-10-13), two lenses: backend (K) and web/API/tests (W). 29 findings; overlaps are merged below.

| # | Lens | Finding | Verdict | Disposition |
|---|---|---|---|---|
| 1 | K | The 15-minute reclaim on `started_at` can run one export twice; a slow 1M-row run is about 100 minutes; the second runner's failure overwrites `ready` | high (verified: `jobs.module.ts:996` "Two instances are safe") | Fixed: a `heartbeat_at` per page; the stale rule reads it; finish and fail are conditional on `status` + claimed `attempts`; a race row |
| 2 | K | A resolve delivered before the raise leaves a tombstone with no recipient; the raise's `set` never fills it, so every owner sees the entry | high (verified: `notifications.delivery.ts:101-151`) | Fixed: `recipientUserId` on raise and resolve, written by both paths; a two-way CHECK; an ordering row |
| 3 | K, W | The keyset needs the full-precision `::text` cursor; tests at 5,000-row pages never cross a boundary | high (verified: `audit.ts:136-145`) | Fixed: stated; `auditExportLimits` injectable; `pageSize: 2` over a tie group |
| 4 | K, W | `Content-Disposition` is not readable cross-origin; the filename always falls back | high (verified: `app.factory.ts:24-29`) | Fixed: the web builds the name from `requestedAt`; no CORS change; PENDING |
| 5 | K, W | No lock is named, so a same-key race answers `export-in-progress` instead of replaying; hash inputs are unstated | medium (verified: §1 steps 5-6) | Fixed: an advisory xact lock on `(tenant, requester)`; replay under it; hash inputs; a 23505 backstop; a race row |
| 6 | K | `failure_reason` "null unless failed" breaks expiring a failed export | medium | Fixed: a per-status shape table; `expired` keeps history; every refused shape probed |
| 7 | K | `ON DELETE CASCADE` violates "no FKs anywhere" | medium (verified: IMPLEMENTATION-GUIDE §3) | Fixed: no FK; expiry removes the file explicitly |
| 8 | K | The snapshot gap has an existing proof (§7d); "reproducible" was false | medium (verified: `storage-snapshot.ts:259-282`) | Fixed: the §7d probe gates the claim; the probe moves to `shared/db`; an open-transaction row |
| 9 | K | The filter move misses the prefix regex and the test import; tenancy may not import reporting | medium (verified: `audit-trail.spec.ts:11`, `architecture.spec.ts:1611-1624`) | Fixed: move the regex; re-export; extend the guard block |
| 10 | K, W | The new target type breaks the web's `AUDIT_TARGET_LABEL` compile; reclaim-to-failed never notified | medium (verified: `wms-fe/src/lib/audit.ts:22`) | Fixed: label task; reclaim sets the dates and appends `failed` |
| 11 | W | "File equals paged read" cannot pass as written: later rows, `Z` vs IST, no emails in the read | medium | Fixed: compare with `to = snapshot_at`, normalised, emails from `users` |
| 12 | W | FE key policy undecided; a per-draft key would replay a stale `queued` | medium (verified: frontend IMPLEMENTATION-GUIDE:301) | Fixed: a key per click |
| 13 | W | The `#audit-exports` anchor is not buildable (`Section` has no `id`); a hash change on the page refreshes nothing | medium (verified: `surface.tsx:31-38`, `audit-trail.tsx:43-47`) | Fixed: an always-rendered wrapper; reload + scroll on mount and `hashchange` |
| 14 | W | jsonb `filters` is untyped in the client; `to` echoes the next IST day | medium (verified: `lib/audit.ts:121`) | Fixed: `AuditFilterBaseDto`; canonical storage; summary rules |
| 15 | W | The unpaged list and two new gated reads break API-SURFACE's written conventions | medium (verified: API-SURFACE:12-13) | Fixed: documented as named exceptions |
| 16 | W | No 410 precedent; the binary response and 202 are unspecified | medium | Fixed: 409 `export-expired`; decorators, `@Res()`, ETag off; always 202 |
| 17 | W | The formula guard is weaker than 21-5b's (TAB, CR) | medium (verified: `wms-fe/src/lib/csv.ts:15-17`) | Fixed: six characters |
| 18 | W | supertest inflates gzip, so a download test can't check the stored bytes | medium | Fixed: a raw body parser, then gunzip and compare the sha256 |
| 19 | K | The replay row had 409 for key reuse; the code answers 422 | low (verified: `registration.command.ts:188-194`) | Fixed |
| 20 | K | Worker events were ambiguous between outbox and audit rows | low | Fixed: outbox only |
| 21 | K | The jobs entry point and discovery predicate were unnamed | low | Fixed: `runDueAuditExports`; the predicate |
| 22 | K | The ~30 MB gzip figure is unverified (two random uuids per row); the send mechanism and the 57014 arm were unstated | low | Fixed: the load script reports `byte_size`; PENDING uses the measurement; `res.end`; 57014 → `export-error` |
| 23 | K | PENDING's "9-3 export-completion hook" should close | low | Fixed: docs task |
| 24 | W | Reason copy missing for two reasons; nested union; open-until-expiry implicit | low | Fixed: one summary DTO; a `Record` over reasons; the decision stated |
| 25 | W | UX states unspecified (503, role-denied, applied vs draft, empty state, refusals on Download) | low | Fixed |

Code review (2026-10-14), three layers: blind hunter (B), edge-case hunter (E), verification gap (V). 31 findings; the same claim from several layers shares one row.

| # | Layer | Finding | Verdict | Disposition |
|---|---|---|---|---|
| 1 | V, B, E | Clicking an `audit-export` bell entry while already on `/reports` never reloads "Your exports": Next's `<Link>` navigates with `history.pushState`, which fires no `hashchange`; the test dispatches a synthetic one | medium (verified: `notification-entry.tsx:38` is a `next/link`; Next's app router changes the URL with `pushState`) | Patch: the entry's click requests a reload and scroll explicitly; the test clicks the real link |
| 2 | V | The export's `to`, `actorUserId` and `targetType` never reach a 202 in a test, so dropping one from the controller's mapping or `toAuditExportDto` fails nothing | medium (verified: every successful `postExport` body in `audit-export.spec.ts`) | Patch: an e2e case posting all filters, asserting the file's rows and the echoed `filters` |
| 3 | V | The worker's discovery query is tested only on its `queued` arm; deleting the expiry or stale-running arm fails nothing | medium (verified: the only `worker.tick()` test seeds a `queued` row) | Patch: two `tick()` cases (an expired `ready`, a stale `running`) |
| 4 | B, E | A gzip `error` while `write` waits on `drain` never settles, so the single-flight tick hangs for every tenant; an error before `finish()` is an unhandled rejection | low (verified: `audit-export.csv.ts:101-115`; only reachable on a zlib failure) | Patch: race `drain` with `error`/`close`; attach a no-op catch to `done` |
| 5 | V | The 30 s per-page `statement_timeout` is never observed | low (verified: no test reads it) | Patch: assert `current_setting('statement_timeout')` inside a page (the `audit-trail.spec.ts:284` technique) |
| 6 | V | The server's `Content-Disposition` name is pinned by shape only; dropping the IST offset passes | low (verified: the regex at the download test) | Patch: an exact expected name |
| 7 | B | A `failed` export's download (409) and its expiry (no file) are untested | low | Patch: two assertions |
| 8 | E | `fullPrecisionInstant` drops the `::text` offset, so a non-UTC session `TimeZone` would shift the snapshot and the cursor | maybe-false — would be medium; the shared primitive predates this story and every cursor in the repo depends on a UTC session; settle by checking the deploy's `TimeZone` | Defer (`deferred-work.md`) |
| 9 | B | One large export holds the tick for every other tenant | low (measured: 100k in ~1.2 s; 1M in seconds, not the 100 min feared) | Rejected: low, and the fix adds a scheduler |
| 10 | B | `too-many-events` is found only after reading `maxRows` rows | low (same measurement) | Rejected: low; a pre-count adds a second query per export |
| 11 | B | An export waits `queued` for as long as any older transaction stays open (a backup, a leaked idle-in-transaction session) | low (verified: `claim` returns `open-transaction` with no deadline; it ends when that transaction ends) | Rejected: the §7d wait is the spec's choice; a deadline adds a failure reason. Noted in PENDING |
| 12 | B | The discovery query has no partial index; expired rows have no retention | low (exports are rare per tenant) | Rejected: low |
| 13 | B | No per-tenant cap on stored export bytes | low (one active export per requester, owner-only, audited, 7 days) | Rejected: low |
| 14 | B | The 1M cap was never measured | low | Rejected as a code defect. The re-verification runs the load script at 1M and records it |
| 15 | B, E | The load script's `toSeed` can go negative on a tenant with more rows | low | Rejected: low; a guard in a dev script |
| 16 | B | The 0070 probe does not cover every column of every status arm | low (verified: every status arm has at least one refused probe) | Rejected: low |
| 17 | B | The runner does not re-check the requester's authority before building | low (the download re-checks `audit.view`; nothing leaks) | Rejected: low |
| 18 | B | The download is always `Content-Encoding: gzip`, whatever `Accept-Encoding` says | low (the spec's decision; browsers and supertest inflate it) | Rejected: low; the contract says so |
| 19 | B | The owner-visibility assertion in `notifications.spec.ts` was weakened | false: the vocabulary test pins `[...CASES, 'audit-export']` to the tuple, so `CASES` still covers every capability source | Rejected |
| 20 | B | Two exports in one IST minute download under the same name | low (the browser de-duplicates) | Rejected |
| 21 | B | The filename logic exists in both repos | low (by design: CORS hides the header from the web) | Rejected |
| 22 | B | The review diff's web hunks have mismatched paths | false: an artefact of how the review diff was assembled, not of the change | Rejected |
| 23 | E | Sub-millisecond `from`/`to` are truncated by `canonicalInstant`, so the export can differ from the read | low (the web sends IST midnights; only a hand-built API call reaches it) | Rejected: low |
| 24 | E | If `finishFailed` throws, the summary reports the failure while the row stays `running` | low (logged; the reclaim recovers it) | Rejected: low |

## Design Notes

**Why tenancy, not reporting.** Reporting is guarded to write nothing and own no table (§7a). An export needs a job table and file bytes. Housing it in reporting would turn the third exception into a writer, or need a fourth exception. Tenancy already owns `audit_events` and `users`, so the export reads only its own tables.

**Why a snapshot instant, proven.** `audit_events.created_at` is the writing transaction's start. A transaction that began before the request but commits after it carries an earlier stamp, and a keyset read taken too early would miss it. `created_at < snapshot_at` plus the §7d proof makes the file exactly "the trail as of the request", and a re-run is reproducible.

**Why one transaction per page, with a heartbeat.** 9-3a's 5 s whole-read budget cannot cover 1M rows. Per-page transactions keep each statement short, as AD-17 wants for sheddable exports. The heartbeat tells a dead runner from a slow one. The conditional finish makes a reclaimed runner harmless.

**Why gzip at rest.** Storing compressed bytes keeps the bytea small. The app has no compression middleware, so the stored bytes go out as they are (`Content-Encoding: gzip`), and the browser's fetch inflates them. The load script measures the real size.

```text
recorded_at,occurred_at,actor_kind,actor_user_id,actor_email,action,target_type,target_id
2026-10-13T14:03:07.412+05:30,2026-10-13T14:03:07.412+05:30,user,0192…,owner@acme.in,transfer.created,transfer_order,0192…
```

## Verification

**Commands** (BE runs one jest invocation at a time):
- `cd workspace/core/backend/wms-be && bun run test -- test/audit-export.spec.ts` -- expected: all pass.
- `cd workspace/core/backend/wms-be && bun run test && bun run lint && bun run typecheck` -- expected: the full suite is green.
- `cd workspace/core/frontend/wms-fe && bun test && bun run lint && bun run typecheck && bun run check:capability-mirror` -- expected: green.
- `cd workspace/core/backend/wms-be && bun scripts/loadtest-audit-export.ts` -- expected: reports the time and size of the 100k export.
