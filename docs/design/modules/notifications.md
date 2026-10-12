# Notifications module

> The web notification panel (story 9-2, UX-DR12/UX-DR25, FR-22): one bell for what is actionable, routed to who can act, resolving itself when the source clears. The module owns a **projection**: six modules' outbox events raise and resolve entries, a member sees only the sources it holds the capability to act on, and the bell shows a dot (never a count) when an open entry surfaced since the member last opened the panel. Story **9-2b** adds the **mobile pushes**: a second subscriber queues `push_deliveries` rows for the handhelds that can act, and a worker sends them through the `PushGateway` port (§Mobile pushes).

Source: `workspace/core/backend/wms-be/src/modules/notifications/`. Every `file:line` below is relative to `wms-be/`. Read [`../IMPLEMENTATION-GUIDE.md`](../IMPLEMENTATION-GUIDE.md) first; the subscriber follows `invoicing/eway.delivery.ts`.

**The module exists for one rule: an entry is a projection of its source's events, never a read of the source's tables.** The panel spans six modules (inventory, movements, inbound, tenancy, replenishment, channels). Each source's raise event inserts an entry keyed by the occurrence's own id; its resolve event marks it resolved. The panel is then one indexed read however many modules feed it, and the resolve events keep it honest.

---

## Owns

| Table | Holds | Key invariants |
|---|---|---|
| `notifications` (`schema.ts:4652`) | One row per source occurrence: `source_type`, `source_id` (the occurrence's id: the pending adjustment, the over-receipt, the episode…), nullable `warehouse_id`, `summary` jsonb (a per-source allowlist; null only on a tombstone), `raised_at` (the raise event's `occurredAt` — orders the list), `surfaced_at` (when the projection wrote the raise — drives the dot), `resolved_at` + `resolution` | **Unique `(tenant_id, source_type, source_id)`** — the idempotency of every subscriber |
| `notification_reads` (`schema.ts:4682`) | Per member: `last_opened_at` | PK `(tenant_id, user_id)`; no foreign key (house convention — the user is the session user) |
| `push_deliveries` (`schema.ts:4704`, 9-2b) | The mobile push queue: one row per (relayed outbox event, eligible handheld) — `kind`, `tab`, `warehouse_id` (new-work only), `approval_source` (approval only), `status`, `gateway`, `error_code`, `attempts`, `next_attempt_at` | **PK `(tenant_id, event_id, device_id)`** — the enqueue's idempotency; index `(tenant_id, status, next_attempt_at)` — the claim's read |

Migration `drizzle/0067_notifications.sql` (additive; no data statement, so no pre-flight). drizzle-kit generated the tables, the column and the indexes; everything below the marker is hand-amended:

- **`notifications_source_type_check`** — the eight source types. Pinned against `NOTIFICATION_SOURCE_TYPES` (`notification-sources.ts:23`) by `test/notifications.spec.ts` (IMPLEMENTATION-GUIDE §4's three layers: the TS tuple, the CHECK, the API's discriminated union).
- **`notifications_shape_check`** (not in the spec — added in the build): (1) a raised row (`summary` set) carries both `raised_at` and `surfaced_at`; (2) a tombstone (`summary` null) is always resolved; (3) `resolved_at` and `resolution` are set together or not at all. This is why `raised_at` and `surfaced_at` are **nullable** columns: a tombstone has neither.
- **Indexes:** `notifications_tenant_source_unique`; `notifications_tenant_raised_at_id_idx` on `(tenant_id, raised_at DESC NULLS LAST, id DESC NULLS LAST)` — the list's exact order.
- **RLS:** `notifications_tenant_isolation`, `notification_reads_tenant_isolation` (the plain tenant policy, the 0056 shape — operator-only surfaces, never read by the portal). The `client-isolation` pin moved 99 → 101.
- **The probe** (the 0064/0066 model): the accepted shapes are inserted and rolled back by a sentinel, so a CHECK that refuses everything cannot pass; each refused shape (unknown source type, raised without either instant, unresolved tombstone, resolved without a resolution, a resolution without `resolved_at`) must be refused **by its named constraint**.
- Also in 0067: **`integrations.sync_episode_id`** (uuid, nullable) — owned and written by **channels**, not here (see `channels.md` §Sync-health episodes).

Migration `drizzle/0068_mobile_pushes.sql` (9-2b, additive, no data statement). drizzle-kit generated the table, the three `devices` push columns (tenancy's — see `tenancy.md`), `waves.cutoff_risk_alerted_on` (outbound's — see `outbound.md`) and the indexes; hand-amended below the marker:

- **Vocabulary CHECKs** — `push_deliveries_kind_check` (`new-work | approval | at-risk`), `_tab_check` (`Pick | Count | Transfer | All`, case-sensitive), `_status_check` (`pending | sending | sent | failed`), `_gateway_check` (NULL or `unconfigured | expo`), `_approval_source_check` (NULL or `stock-adjustment | count-variance | over-receipt`). Pinned against the TS tuples in `push-rules.ts` by `test/push.spec.ts`.
- **`push_deliveries_shape_check`** — a new-work row carries `warehouse_id` and only a new-work row does; an approval row carries `approval_source` and only an approval row does; `attempts >= 0`. These two columns are not in the spec: they carry what the **send-time** audience re-check needs, which the spec's column list could not express.
- **RLS:** `push_deliveries_tenant_isolation` (the plain tenant policy). The `client-isolation` pin moved 101 → 102.
- **The probe** (the 0064/0067 model): every kind, tab, status, gateway and approval source accepted and rolled back by a sentinel; eleven refused shapes, each by its named constraint (a lower-case tab included).

The module writes no `audit_events`, appends no outbox events, and stores no idempotency keys.

---

## Public seam

`NotificationsModule` provides, **in this order**, `NotificationsDeliveryHandler`, `PushEnqueueHandler`, the `PUSH_GATEWAY` port (`pushGatewayFromEnv()`), `PushSender` and `NotificationsFacade`, and exports **the facade alone** (`notifications.module.ts`). The provider order is load-bearing — see §Mobile pushes, *Handler order*. The api shell's `NotificationsController` (`src/api/notifications.controller.ts`) is the HTTP surface; the jobs shell's `PushSenderWorker` is the only other importer (through the facade).

| Method (`notifications.facade.ts`) | Does | Called by |
|---|---|---|
| `list(tenantId, userId, {cursor?, limit?})` :104 | Visible, non-tombstone entries, newest `(raised_at, id)` first, keyset-paged (default 25, max 100) | `GET /tenants/{t}/notifications` |
| `status(tenantId, userId)` :159 | `{hasNew}` — the bell's dot | `GET …/notifications/status` |
| `opened(tenantId, userId)` :193 | Upserts `last_opened_at = now()`, returns `{hasNew: false}` | `POST …/notifications/opened` |
| `sendDuePushes(tenantId)` :99 (9-2b) | One send of the tenant's due pushes (`PushSender.sendDue`): claim ≤ 100 → one gateway call → outcomes; returns a `PushSendSummary` | the jobs shell's `PushSenderWorker`, once per due tenant per tick |

The facade also re-exports `PUSH_SENDING_STALE_MS`, so the worker's due-tenant query uses the sender's own stale bound (code review BE5).

Every method re-reads the caller's role **in its own tenant transaction** (`getMemberRoleIn`; a removed member is refused there, `403 role-denied`) and maps it through `visibleSourceTypes(role)` (`notification-sources.ts:473`). A role that can act on no source gets an empty list and `hasNew: false` without a query.

**The cross-module imports** are tenancy's: the role read and capability map (`getMemberRoleIn`, `ROLE_CAPABILITIES`, `isFloorRole`), and — 9-2b — the push-target functions (`listPushTargets`, `getPushTargetsIn`, `clearPushTokenIn`, `pushTokenOwners`), because tenancy owns every `devices` read and write. The routing rule is the commands' own authority, never a copy of it. Beyond that the module imports two status tuples from `schema.ts` (`COUNT_VARIANCE_STATUSES`, `REJECTED_OP_STATUSES` — vocabularies, not tables) and nothing of any sibling.

---

## The sources

Each source is one raise event and its resolve event(s). The event type strings are the emitters', repeated as literals in `NOTIFICATION_SOURCES` (`notification-sources.ts:223`) because this module may import no sibling's internals. `test/notifications.spec.ts` pins the five new event types to the emitters' constants, and every source's raise and resolve types to the suite's per-source fixtures.

| `source_type` | Raise (emitter) | Resolve → resolution | `source_id` | Who sees it | `summary` allowlist | Web link (open / resolved) |
|---|---|---|---|---|---|---|
| `stock-adjustment` | `stock_adjustment.pending_approval` (inventory) | `stock_adjustment.approved` → `approved`, `.rejected` → `rejected` | `pendingAdjustmentId` | `adjustments.approve` (owner) | `{skuId, quantityDelta, reasonCode}` | `/conflicts?queue=adjustment-pendings` |
| `count-variance` | `count.variance.threshold_exceeded` (movements) | `count.variance.resolved` → its `status`: `adjusted` \| `recounted`; **ignored when `overThreshold: false`** | `varianceId` | **role `owner`** (the resolve's frozen-threshold guard, not a capability) | `{skuId, delta}` | `/conflicts?queue=variances` |
| `over-receipt` | `over_receipt.requested` (inbound) | `over_receipt.approved` → `approved`, `.rejected` → `rejected` | `overReceiptId` | `review.decide` | `{grnCode, skuId, excessQty}` | `/conflicts?list=over-receipts&warehouseId=…&status=pending` / the same without `status` |
| `rejected-op` | **`device.rejected_op.raised`** (tenancy, new) | `device.rejected_op.resolved` → its `status`: `applied` \| `recounted` \| `discarded` | `rejectedOpId` | `review.decide` | `{opType, problemCode}` (no warehouse stored) | `/conflicts?queue=rejected-ops` |
| `reorder-breach` | `replenishment.breach_detected` | **`replenishment.breach_cleared`** (new) → its `reason`: `recovered` \| `dismissed` \| `actioned` \| `policy-removed` | `breachId` | `replenishment.manage` | `{skuId, atpQty, pointQty}` (base units, converted from the payload's milli) | `/replenishment` |
| `batch-alert` | `replenishment.batch_alert_raised` | **`replenishment.batch_alert_cleared`** (new) → its `reason`: `resolved` \| `dismissed` | `alertId` | `replenishment.manage` | `{kind, skuId, batchCode, expiryDate \| ageDays}` (the detected field only) | `/replenishment?list=batch-alerts&warehouseId=…&kind=…` (both) |
| `qc-hold` | `qc_hold.placed` (inbound) | `qc_hold.released` → `released` | `holdId` | `qc.manage` | `{skuId, reason}` | `/inbound` |
| `channel-sync` | **`channel.sync.degraded`** (channels, new) | **`channel.sync.recovered`** (new) → its `reason`: `recovered` \| `disconnected` | `episodeId` | `channel.manage` | `{connectionId}` | `/channels` |

- **Routing is `SOURCE_AUDIENCE`** (`notification-sources.ts:461`): the capability the source's **resolving command** enforces. The payloads' `notifyRole` hints are ignored — they disagree with who can act (the stock adjustment's hint is `owner`, which is right; the breach's is `ops_manager`, but the owner holds `replenishment.manage` too). With today's matrix: the owner sees all eight; the ops manager six (not `stock-adjustment`, not `count-variance`); operator, accountant and client none.
- **`SOURCE_RESOLUTIONS`** (`:53`) is each source's closed resolution list. The count-variance and rejected-op lists are **derived** from the shared status tuples minus `open`; the breach, batch-alert and channel lists are pinned to the emitters' runtime tuples (`BREACH_CLEARED_REASONS`, `BATCH_ALERT_CLEARED_REASONS`, `CHANNEL_SYNC_RECOVERED_REASONS`) by a compile-time type equality and a runtime test. A resolve whose resolution is outside its list is **malformed**: logged and acked, nothing written.
- **Warehouse:** read from the payload where it carries one (`warehouseId` absent or null → null; anything else must be a uuid or the payload is malformed). The rejected-op and channel-sync sources store none.
- **The summary is built key by key, never spread** from the payload. Raw payloads carry `notifyRole`, tenant ids and actor ids. Text fields are bounded (1–500 chars); numbers must be finite.

---

## Flows

### Raise → entry → dot → open

```mermaid
sequenceDiagram
    participant SRC as source command (any of six modules)
    participant O as outbox (AD-7)
    participant R as outbox relay
    participant H as NotificationsDeliveryHandler
    participant DB as notifications (tenant tx)
    participant W as web bell
    participant F as NotificationsFacade

    SRC->>O: append raise event (same tx as the state change)
    R->>H: deliver(event) via EVENT_BUS
    H->>H: route by event.type; occurredAt must be an ISO UTC instant
    H->>H: decodeRaise — ids + allowlisted summary, or null (malformed → log, ack)
    H->>DB: INSERT … ON CONFLICT (tenant, source_type, source_id)<br/>DO UPDATE … WHERE summary IS NULL
    Note over DB: new row: raised_at = occurredAt, surfaced_at = now()
    W->>F: GET …/notifications/status (shell mount, each pathname change)
    F->>DB: role → visible types; any OPEN entry with surfaced_at > last_opened_at (or no read row)?
    F-->>W: {hasNew: true} → amber dot
    W->>F: GET …/notifications?limit=10 (panel opened)
    F-->>W: newest (raised_at, id) first
    W->>F: POST …/notifications/opened (once the list loaded)
    F->>DB: upsert notification_reads.last_opened_at = now()
    F-->>W: {hasNew: false}
```

### Resolve, and the out-of-order arm

```mermaid
sequenceDiagram
    participant R as outbox relay
    participant H as NotificationsDeliveryHandler
    participant DB as notifications

    alt resolve after its raise (the normal order)
        R->>H: resolve event
        H->>DB: INSERT tombstone … ON CONFLICT DO UPDATE<br/>SET resolved_at = occurredAt, resolution WHERE resolved_at IS NULL
        Note over DB: the existing row is stamped; a second resolve changes nothing
    else resolve BEFORE its raise
        R->>H: resolve event
        H->>DB: INSERT tombstone (summary, raised_at, surfaced_at NULL; resolved)
        R->>H: the late raise
        H->>DB: ON CONFLICT DO UPDATE SET summary, warehouse, raised_at, surfaced_at WHERE summary IS NULL
        Note over DB: filled, still resolved — listed as resolved, lights no dot
    else count.variance.resolved with overThreshold: false
        R->>H: resolve event
        Note over H: decoded as 'ignore' — no row (no raise will ever come)
    end
```

---

## Commands and guards

The module has no commands in the house-skeleton sense. Its writes are the subscriber's two upserts and the reader's `opened`.

**The subscriber** (`notifications.delivery.ts`). It subscribes to every key of `EVENT_ROUTES` in `onModuleInit` (:60). `deliver` (:67), in order:

1. Unknown type → return.
2. `occurredAt` not an ISO-8601 UTC instant → log, **ack**.
3. Decode the payload (`decodeRaise`/`decodeResolve`); malformed → log, **ack**; the variance `ignore` → return.
4. One `withTenantTransaction` of its own, one upsert:
   - **raise** (`raise` :132): insert `{summary, warehouse, raised_at = occurredAt, surfaced_at = now()}`; on conflict update the same fields **only where `summary IS NULL`** (filling a tombstone keeps `resolved_at`/`resolution`). A row that already has a summary is a re-delivery: no change, not even a different summary or instant.
   - **resolve** (`apply` :88): insert a tombstone `{summary: null, raised_at: null, surfaced_at: null, resolved_at = occurredAt, resolution}`; on conflict set `resolved_at`, `resolution` **only where `resolved_at IS NULL`** (resolved once).
5. **Errors** (`isDataFault` :169, exported since 9-2b for the push enqueue): a `ProblemException` < 500, or SQLSTATE class **22** (data exception) or **23** (integrity violation) anywhere on the error's `cause` chain → log, **ack**. Anything else → log and **rethrow**, so the relay re-delivers. Since 9-2b the three approval raises have a **second** subscriber, the push enqueue. A re-delivery is still safe: both writes are idempotent, and this handler subscribes first, so its entry is already written when the push handler runs.

**`opened`** takes **no `Idempotency-Key`** — one of the natural-upsert exceptions, with the handheld's `PUT`/`DELETE …/devices/push-registration` (9-2b; API-SURFACE records them). Setting a time to now is naturally idempotent, and a retry only moves it forward. Any member may call it; a role that sees nothing just records an open.

**The HTTP guards**, in order: `TenantSessionGuard` (401; a client-portal token → `403 role-denied`) → `assertOwnTenantToken` (`403 permission-denied`) → the query DTO (`limit` 1–100 → else `400 validation-failed`) → the facade (`decodeCursorSafe` → `400 invalid-cursor`; the role re-read — a user who is not a member → `403 role-denied`).

---

## Key algorithms

**The list** (`list` :85). Filter: tenant, `source_type IN visible`, `summary IS NOT NULL` (tombstones are never served), and with a cursor the row comparison `(raised_at, id) < (cursor instant, cursor id)`. Order: `raised_at DESC NULLS LAST, id DESC NULLS LAST` — **exactly the index's order**, so the index can serve the page with no Sort (the patch commit `59402fc` records an EXPLAIN showing an Index Scan with the keyset comparison as an index condition). A bare `desc` means NULLS FIRST and does not match the index (code review BE2). The cursor is the house codec over the raw `raised_at::text` instant (`fullPrecisionInstant`), with a local `CURSOR_INSTANT_RE` and `decodeCursorSafe`.

**The dot** (`status` :140). True iff some visible, non-tombstone, **open** (`resolved_at IS NULL`) entry has `surfaced_at > last_opened_at` — or the member has no `notification_reads` row and such an open entry exists. One `LEFT JOIN … LIMIT 1`. Consequences:

- Resolved entries never light it, so a first-time member with only resolved history sees no dot.
- An entry whose raise committed before the member's open but was projected after it **does** light it, because the dot compares `surfaced_at`, not `raised_at`.

**Why two instants.** `raised_at` is when the thing happened, which is what the list orders by. `surfaced_at` is when the panel could first show it. Driving the dot from `raised_at` would hide every entry the relay delivers after an open.

---

## Mobile pushes (story 9-2b)

Three kinds reach a handheld, and nothing else does (UX-DR25): **new work** in the handheld's warehouse, **approval waiting** (a heads-up — the decision is taken on the web) and **wave cutoff at risk**. A push carries a fixed title and body and `data: {kind, tab}` — no SKU, no quantity, no warehouse name. A tap only ever opens the handheld's inbox, which re-reads the server (`../mobile/SYSTEM-DESIGN.md` §Push notifications).

Files: `push-rules.ts` (the vocabularies, audiences, copy, classification and timing, pure), `push.enqueue.ts` (the queue writer), `push.sender.ts` (the sender), `push-gateway.ts` (the port and its two adapters).

### Queue, then send

The relay is one serial loop for every tenant, and it quarantines a row after five throws. A push provider outage inside a handler would stall it, and could quarantine the approval rows the 9-2 projection shares. So the outbox handler **only inserts rows**, and a separate worker sends them.

```mermaid
sequenceDiagram
    participant SRC as source command / cutoff sweep
    participant O as outbox
    participant R as outbox relay
    participant D as NotificationsDeliveryHandler (9-2)
    participant E as PushEnqueueHandler
    participant T as tenancy push-target fns
    participant Q as push_deliveries
    participant W as PushSenderWorker (jobs)
    participant S as PushSender (sendDuePushes)
    participant A as AUTH_DATABASE (read-only)
    participant G as PushGateway

    SRC->>O: append event (same tx)
    R->>D: deliver — the panel entry first (approval raises)
    R->>E: deliver
    E->>E: uuidv7 eventId older than 30 min? ack, no push
    E->>E: intentOf — kind, tab, audience facts (or none)
    E->>T: listPushTargets(tx) — base-eligible handhelds
    E->>Q: INSERT pending … ON CONFLICT (tenant, event, device) DO NOTHING
    W->>A: tenants with due rows (pending past next_attempt_at, or sending past 5 min)
    W->>S: sendDuePushes(tenantId)
    Note over S,Q: tx A — sending > 5 min → failed stale; pending created > 30 min → failed expired;<br/>claim ≤ 100 due pending FOR UPDATE SKIP LOCKED
    S->>T: getPushTargetsIn(tx, deviceIds) + pushAudienceAllows → else failed ineligible
    S->>T: pushTokenOwners(authDb, tokens) — latest registration across tenants
    Note over S,Q: not the owner → failed superseded + clearPushTokenIn (own tenant only);<br/>the rest → sending; COMMIT
    S->>G: send(messages) — one call, no transaction held
    G-->>S: one ticket per message, in order
    Note over S,Q: tx B — per ticket, only rows still `sending`: sent / failed / pending + backoff
    S-->>W: PushSendSummary (configCodes)
    W->>W: config fault seen? log ONCE per tick across tenants
```

**The enqueue** (`PushEnqueueHandler.deliver`, `push.enqueue.ts:128`), in order:

1. `occurredAt` not an ISO UTC instant → log, ack.
2. **Staleness:** the event's age is measured from **its server-minted append time — the uuidv7 timestamp of the outbox row id (`eventId`)**, via `uuidv7TimestampMs` (`shared/primitives/ids.ts`). Older than 30 minutes (`PUSH_STALE_EVENT_MS`) → ack, no push. An id that is not a uuidv7 cannot be dated → log, ack, **never** a fallback to `occurredAt`. `occurredAt` is business time and can be device time (a count or a transfer confirm queued offline). Code review BE1; the human amended the spec's rule to this on 2026-10-12.
3. `intentOf` → the kind, tab and audience facts (the table in §Events consumed), or nothing. A malformed at-risk payload is logged; an at-risk event whose cutoff (its `istDate` at `cutoffLocalTime`, IST) has passed by `pushClock.now()` is acked.
4. One tenant transaction: `listPushTargets` filtered by `pushAudienceAllows`; insert one `pending` row per target (`next_attempt_at = now()`), `ON CONFLICT DO NOTHING`.
5. **Errors:** `isDataFault` (9-2's) → log, ack; anything else → log, rethrow (the relay re-delivers; every subscriber on these types is idempotent).

**The sender** (`PushSender.sendDue`, `push.sender.ts:104`) — three steps, two transactions:

1. **Claim (tx A).** Fail `stale` every row `sending` for more than 5 minutes (`PUSH_SENDING_STALE_MS`). Fail `expired` every `pending` row created more than 30 minutes ago (`PUSH_PENDING_EXPIRY_MS` — code review BE2; it bounds every retry path). Select up to 100 due `pending` rows `FOR UPDATE SKIP LOCKED`, ordered `(next_attempt_at, created_at, event_id, device_id)`. Re-check each one (below); the survivors become `sending` with `gateway = <mode>`. **Commit.**
2. **Send.** One `gateway.send(messages)`, outside any transaction. The port never throws; if it does (a programming error), the rows stay `sending` and the stale sweep fails them — never a duplicate.
3. **Outcomes (tx B).** Per ticket, updating only rows still `sending` (so a row the stale sweep already failed is never resurrected). A missing ticket reads as `bad-response`. The outcome is classified by `PUSH_ERROR_CLASS` (below).

### The delivery lifecycle

```
pending ──claim──▶ sending ──ticket ok──────────────▶ sent
   ▲                  │──permanent / 5th transient──▶ failed (<code>)
   │                  │──transient / config─────────▶ pending (backoff / +30 s)
   │                  └──still sending after 5 min──▶ failed (stale)      — never re-sent
   ├── at claim: not eligible any more ─────────────▶ failed (ineligible)
   ├── at claim: token owned by another device ─────▶ failed (superseded)
   └── pending, created > 30 min ago ───────────────▶ failed (expired)
```

`PUSH_LOCAL_FAILURES` = `stale | expired | ineligible | superseded` — the codes the sender writes itself, never a gateway code. **At-most-once on a crash** is deliberate: a duplicate "New work ready" is noise; a missed one is recovered the next time the operator opens the inbox.

### `PUSH_ERROR_CLASS` — the one classification table

`push-rules.ts:189`. Codes are Expo's ticket `details.error`, or the gateway's own whole-request codes.

| Code | Class | The row |
|---|---|---|
| ticket `ok` | — | `sent` |
| `DeviceNotRegistered` | permanent | `failed`; the device's token is cleared **only if it still equals the token sent** (`clearPushTokenIn`, compare-and-clear) |
| `MessageTooBig`, `InvalidProviderToken`, any unlisted code, any unlisted `http-4xx`, `bad-response`, `unknown-error` | permanent | `failed` with the code |
| `MessageRateExceeded`, `network`, `timeout`, `http-429`, any `http-5xx` | transient | `pending`, `attempts + 1`, `next_attempt_at = now + min(2^(attempts−1)·5 s, 5 min)` (`pushBackoffMs`); the 5th attempt → `failed` |
| `http-401`, `http-403`, `InvalidCredentials` | config | `pending` **without spending an attempt**, retried after 30 s (`PUSH_CONFIG_FAULT_RETRY_MS`); `failed` once older than 1 h (the 30-minute expiry normally ends it first). The codes are **returned** in `PushSendSummary.configCodes`, and the worker logs them **once per tick** across every tenant (code review BE4) |

`classifyPushCode` reads the table, then `http-5xx` → transient, else → permanent: an unknown failure is never retried blind. **Only codes are stored or logged** (`boundedCode`: `[A-Za-z0-9_.-]`, ≤ 64 chars). Expo's error **messages** contain the token and are never read.

### `PUSH_COPY` — fixed copy per kind

`push-rules.ts:101`:

| Kind · tab | Title | Body |
|---|---|---|
| new-work · `Pick` | New work ready | Picks released in your warehouse |
| new-work · `Count` | New work ready | A count was created |
| new-work · `Transfer` | New work ready | An inbound transfer is on its way |
| approval · `All` | Approval waiting | Decide it on the web |
| at-risk · `All` | Wave cutoff in under an hour | A planned wave isn't released yet |

The wire message (`messageFor`, `push.sender.ts`) is exactly `{to, title, body, data: {kind, tab}, ttl: 3600, channelId: 'work', priority: 'high'}` — no `badge`, no `sound`. A row whose kind/tab has no copy (new-work on `All`) is never sent; it fails `ineligible`.

### Eligibility — checked at enqueue and again at send

**Base eligibility is tenancy's** (`PushTarget`, `tenancy.service.ts`): the device is `active` with a non-null `push_token` and `operator_user_id`; its operator's `users` row is `active`, has `client_id IS NULL`, and holds a floor role or `accountant` — the badge-in allowlist. **Each kind narrows it** (`pushAudienceAllows`, `push-rules.ts:143`):

| Kind | Audience | Warehouse |
|---|---|---|
| new-work | a floor role (`isFloorRole` — not the accountant) | the device's `push_warehouse_id` must equal the work's |
| approval | the role passes 9-2's `SOURCE_AUDIENCE` for that source (`visibleSourceTypes`, reused): `stock-adjustment` and `count-variance` → owner; `over-receipt` → owner + ops manager | any |
| at-risk | the role holds `waves.manage` (owner, ops manager) | any |

`APPROVAL_PUSH_SOURCES` is the three 9-2 sources that are decisions; the rejected op is a review, not an approval, and stays off the handheld. A module-load assertion fails the boot if one of them has no 9-2 audience.

**The send-time re-check** reads `getPushTargetsIn(tx, tenantId, deviceIds)` inside the claim transaction and re-runs `pushAudienceAllows` against the row's stored `kind`, `warehouse_id` and `approval_source`. A device revoked, unbound, unregistered or re-registered to another warehouse — or whose operator was deactivated, moved to a client or demoted — since the enqueue is `failed` `ineligible`, never sent.

### Token ownership

A token belongs to at most one device across all tenants. There is no re-enroll path (each mint is a new `devices` row), so a phone re-enrolled into tenant B leaves tenant A's row holding the same token, and no write may cross tenants. Two halves:

- **In-tenant, at registration:** the PUT clears the token from every other device row of the tenant (`EnrollmentCommand.registerPush`).
- **Cross-tenant, at send:** `pushTokenOwners(authDb, tokens)` is a **read-only** query on the BYPASSRLS `AUTH_DATABASE` — for each token, the row with the latest `push_registered_at` (ties broken by id) is the owner. A claimed row whose device is not the owner is `failed` `superseded`, and the token is cleared from **its own** device row in its own tenant (`clearPushTokenIn`). The owner keeps it. The partial index `devices_push_token_idx` serves the read.

### Handler order

On the three approval raises, two subscribers run: the 9-2 projection and the push enqueue. The event bus runs handlers in subscription order, and a throw stops the rest. **`NotificationsDeliveryHandler` is listed before `PushEnqueueHandler` in `notifications.module.ts`**, so the panel entry is written before the push handler can throw. `test/push.spec.ts` pins it behaviourally: with the enqueue mocked to reject, the relay still writes the panel entry; with the gateway answering 503, the outbox row is acked, the entry is written, and the push waits `pending` with a 5 s backoff.

### The gateway

`PushGateway.send(messages) → PushTicket[]` (one per message, in order; never throws). Selected at boot by `PUSH_GATEWAY` (`pushGatewayFromEnv`):

- **`unconfigured`** (default when unset) — records each message it would have sent (bounded at 10 000, the e2e suite reads it) and logs `kind/tab` only; every ticket `{ok}`, no network. Rows read `sent` with `gateway = 'unconfigured'`.
- **`expo`** — one https POST to `https://exp.host/--/api/v2/push/send`, ≤ 100 messages, `Authorization: Bearer EXPO_ACCESS_TOKEN`, timeout `PUSH_HTTP_TIMEOUT_MS` (default 10 s). Boot **fails** without the token, and on any other mode value. Whole-request outcomes apply to every message: transport failure → `network` / `timeout`; status ≥ 400 → `http-<status>`; a 2xx that is not JSON or whose `data` is not one ticket per message → `bad-response`. Otherwise per ticket: `status: ok` → `{ok}`, else `details.error` (or `unknown-error`).

**No receipt polling** — a ticket `ok` means Expo accepted the message, which is all the row records (PENDING).

### The worker

`PushSenderWorker` (`jobs/jobs.module.ts:1001`), env-gated by `PUSH_SENDER_POLL_MS` (unset or `0` = off; `.env.example` 5000). Each tick finds the due tenants on `AUTH_DATABASE` (`pending` past `next_attempt_at`, or `sending` past the stale bound — so a crashed send's rows are swept even with nothing else due), calls `sendDuePushes` per tenant, logs and skips a failing tenant, and logs config faults once. Single-flight per process; two processes are safe (`SKIP LOCKED`, `sending` committed before the send).

---

## Invariants

| Invariant | Enforced by |
|---|---|
| One entry per source occurrence | the unique `(tenant_id, source_type, source_id)`; the upserts' `WHERE` arms |
| A late raise never reopens a settled entry | the tombstone + `ON CONFLICT … WHERE summary IS NULL` (fill keeps `resolved_at`) |
| A tombstone is always resolved; a raised row carries both instants; `resolved_at` ⇔ `resolution` | `notifications_shape_check` (probed in 0067) |
| `source_type` is the eight, in TS and SQL alike | `notifications_source_type_check` + the vocabulary pin in `test/notifications.spec.ts` |
| A resolution is one its emitter can send, and the panel stores no other | `SOURCE_RESOLUTIONS` derived or pinned; an off-list resolve is malformed and acked |
| A member sees only what it can act on | `visibleSourceTypes` over `ROLE_CAPABILITIES`, re-read per request in the transaction |
| The summary never carries a raw payload field outside the allowlist | the per-source decoders build it key by key |
| Only this module writes its three tables; it reads no sibling's table; only the api shell, the jobs shell (9-2b) and root import it, and the jobs shell only through the facade | `test/architecture.spec.ts` "the notification panel is notifications-module-owned (story 9-2)" — with a meaningfulness check (the detectors bite on hard-coded specimens; the delivery, the facade, the push enqueue and the sender really write) |
| A push is queued once per (event, device), and never re-sent after it may have gone out | the PK + `ON CONFLICT DO NOTHING`; the claim commits `sending` before the network call; a stale `sending` row becomes `failed`, never `pending` |
| The push enqueue (an outbox handler) makes no network call | `test/architecture.spec.ts` (9-2b): `push.enqueue.ts` and `notifications.delivery.ts` import no `http(s)`, no `fetch`, no `PushGateway`; meaningful — `push.sender.ts` does |
| `kind`, `tab`, `status`, `gateway`, `approval_source` are one vocabulary in TS and SQL | the 0068 CHECKs + the tuple pins in `test/push.spec.ts` |

---

## Events consumed

Produced: none. Consumed (all through the relay and the routed `EVENT_BUS`):

| Event | Emitter | Fields read |
|---|---|---|
| `stock_adjustment.pending_approval` / `.approved` / `.rejected` | inventory | `pendingAdjustmentId`, `warehouseId?`; raise: `skuId`, `quantityDelta`, `reasonCode` |
| `count.variance.threshold_exceeded` / `count.variance.resolved` | movements | `varianceId`, `warehouseId?`; raise: `skuId`, `delta`; resolve: `status`, `overThreshold` (9-2) |
| `over_receipt.requested` / `.approved` / `.rejected` | inbound | `overReceiptId`, `warehouseId` (9-2); raise: `grnCode`, `skuId`, `excessQty` |
| `device.rejected_op.raised` (9-2) / `device.rejected_op.resolved` | tenancy | `rejectedOpId`; raise: `opType`, `problemCode`; resolve: `status` |
| `replenishment.breach_detected` / `replenishment.breach_cleared` (9-2) | replenishment | `breachId`, `warehouseId`; raise: `skuId`, `atpMilli`, `pointMilli`; resolve: `reason` |
| `replenishment.batch_alert_raised` / `replenishment.batch_alert_cleared` (9-2) | replenishment | `alertId`, `warehouseId`; raise: `kind`, `skuId`, `batchCode`, `expiryDate` \| `ageDays`; resolve: `reason` |
| `qc_hold.placed` / `qc_hold.released` | inbound | `holdId`, `warehouseId?`; raise: `skuId`, `reason` |
| `channel.sync.degraded` (9-2) / `channel.sync.recovered` (9-2) | channels | `episodeId`, `connectionId`; resolve: `reason` |

Every other payload field is ignored. Events committed **before 9-2 deployed** are never re-read (see the gotchas).

**Consumed by the push enqueue (9-2b)** — event types repeated as literals in `push.enqueue.ts:34-37` and pinned to the emitters by `test/push.spec.ts`:

| Event | Emitter | Push | Fields read |
|---|---|---|---|
| `wave.released` | outbound | new-work · `Pick` | `wave.warehouseId` |
| `count.created` | movements | new-work · `Count` — **only `origin` `on_demand` or `recount`**; a scheduled count is never pushed | `origin`, `warehouseId` |
| `transfer.outbound-confirmed` | movements | new-work · `Transfer`, to the **destination** warehouse | `destWarehouseId` |
| `stock_adjustment.pending_approval`, `count.variance.threshold_exceeded`, `over_receipt.requested` | inventory, movements, inbound | approval · `All` — only if 9-2's `decodeRaise` accepts the payload | the 9-2 raise decoder's fields |
| `wave.cutoff_at_risk` (9-2b) | outbound's cutoff sweep | at-risk · `All` — acked once its cutoff has passed | `waveId`, `cutoffLocalTime`, `istDate` |

---

## Gotchas

- **No backfill at deploy.** Only events relayed after 9-2 is running project an entry. A pending adjustment, open breach or QC hold that was raised before the deploy never surfaces, and when it later resolves, its resolve inserts a tombstone that nothing will ever fill (PENDING). The same applies to a breaker already open at deploy: it carries no `sync_episode_id`, so its recovery emits nothing (channels only closes episodes it opened).
- **A pre-9-2 variance resolve leaves a tombstone.** A `count.variance.resolved` without the `overThreshold` field (an event committed before 9-2) resolves as before — at worst one tombstone per in-flight event. Only an explicit `false` is ignored.
- **`surfaced_at` is the transaction's `now()`, not its commit time.** A raise transaction that starts before a member's `opened` and commits after it can carry a `surfaced_at` earlier than `last_opened_at`, so that entry would not light the dot. The window is one short transaction wide (PENDING).
- **Policy delete does not always clear the breach entry.** The breach's `policy-removed` arrives only when the SKU's default point is 0 (or the SKU is gone). With a default above 0 the scope stays a sweep candidate, and the sweep's `recovered` (or nothing, if still below the default) decides — see `replenishment.md`. The first build cleared the entry unconditionally while the breach stayed open in the queue (code review BE1).
- **The resolution lists must follow their emitters.** A new breach reason or rejected-op status the panel does not list would be acked as malformed and the entry would stand open forever. The pins fail the build/suite first; keep them.
- **Order the list the way the index is built** — `DESC NULLS LAST` on both keys (BE2).
- **The drain is sequential** (channels' epic-7 gotcha): this handler adds one short tenant transaction per relayed source event. It makes no network call, so it does not add the latency coupling that gotcha warns about.
- **Push staleness is the append time, never `occurredAt` (9-2b, code review BE1).** The first build aged an event by `occurredAt`, which is device time for a count or a transfer confirm queued offline — a handheld with a fast clock, or one that synced hours later, decided whether a push went out. The uuidv7 `eventId` is minted server-side at append. A future emitter that appends with a non-uuidv7 id gets **no pushes** (logged), not a fallback.
- **A pending row expires (BE2).** Without the 30-minute pending expiry, a transient backoff or a config fault could send "New work ready" an hour late. Any new retry path is bounded by it.
- **The provider order in `notifications.module.ts` is load-bearing.** Moving `PushEnqueueHandler` above `NotificationsDeliveryHandler` lets a push-queue failure stop the panel entry being written on that attempt.
- **Cross-tenant ownership can regress** (code review BE3, PENDING). Ownership is "the latest `push_registered_at` among rows holding the token". If tenant B (the newer owner) clears its token — a DELETE, a revoke, a `DeviceNotRegistered` — tenant A's older row becomes the latest again and is sent to. A tombstone of superseded tokens is the fix.
- **Expo refuses a mixed-project batch** (code review BE7, PENDING). Expo answers `PUSH_TOO_MANY_EXPERIENCE_IDS` when one request carries tokens of more than one Expo project. The gateway reads that as a whole-request 4xx → `http-400` → permanent, so a batch mixing two app builds fails entirely. One project per deployment today.
- **Only codes, never messages.** Expo's error messages embed the token; `boundedCode` is the only path a code takes to a column or a log line.
- **The sweep tests depend on the date** (PENDING). `test/push.spec.ts`'s cutoff tests freeze `WAVE_CLOCK` and `pushClock` at 2026-10-12 while the sweep's outbox append mints a real-time uuidv7, so the enqueue's staleness check compares a frozen "now" against a real append time. Run after that date the age comes out negative and the check passes vacuously; run more than 30 minutes before the frozen instant the event would read as stale. Mint the append id from the frozen clock, or freeze the uuidv7 source too.
