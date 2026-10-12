# Notifications module

> The web notification panel (story 9-2, UX-DR12/UX-DR25, FR-22): one bell for what is actionable, routed to who can act, resolving itself when the source clears. The module owns a **projection**: six modules' outbox events raise and resolve entries, a member sees only the sources it holds the capability to act on, and the bell shows a dot (never a count) when an open entry surfaced since the member last opened the panel. Mobile pushes are story **9-2b**.

Source: `workspace/core/backend/wms-be/src/modules/notifications/`. Every `file:line` below is relative to `wms-be/`. Read [`../IMPLEMENTATION-GUIDE.md`](../IMPLEMENTATION-GUIDE.md) first; the subscriber follows `invoicing/eway.delivery.ts`.

**The module exists for one rule: an entry is a projection of its source's events, never a read of the source's tables.** The panel spans six modules (inventory, movements, inbound, tenancy, replenishment, channels). Each source's raise event inserts an entry keyed by the occurrence's own id; its resolve event marks it resolved. The panel is then one indexed read however many modules feed it, and the resolve events keep it honest.

---

## Owns

| Table | Holds | Key invariants |
|---|---|---|
| `notifications` (`schema.ts:4633`) | One row per source occurrence: `source_type`, `source_id` (the occurrence's id: the pending adjustment, the over-receipt, the episode…), nullable `warehouse_id`, `summary` jsonb (a per-source allowlist; null only on a tombstone), `raised_at` (the raise event's `occurredAt` — orders the list), `surfaced_at` (when the projection wrote the raise — drives the dot), `resolved_at` + `resolution` | **Unique `(tenant_id, source_type, source_id)`** — the idempotency of every subscriber |
| `notification_reads` (`schema.ts:4663`) | Per member: `last_opened_at` | PK `(tenant_id, user_id)`; no foreign key (house convention — the user is the session user) |

Migration `drizzle/0067_notifications.sql` (additive; no data statement, so no pre-flight). drizzle-kit generated the tables, the column and the indexes; everything below the marker is hand-amended:

- **`notifications_source_type_check`** — the eight source types. Pinned against `NOTIFICATION_SOURCE_TYPES` (`notification-sources.ts:23`) by `test/notifications.spec.ts` (IMPLEMENTATION-GUIDE §4's three layers: the TS tuple, the CHECK, the API's discriminated union).
- **`notifications_shape_check`** (not in the spec — added in the build): (1) a raised row (`summary` set) carries both `raised_at` and `surfaced_at`; (2) a tombstone (`summary` null) is always resolved; (3) `resolved_at` and `resolution` are set together or not at all. This is why `raised_at` and `surfaced_at` are **nullable** columns: a tombstone has neither.
- **Indexes:** `notifications_tenant_source_unique`; `notifications_tenant_raised_at_id_idx` on `(tenant_id, raised_at DESC NULLS LAST, id DESC NULLS LAST)` — the list's exact order.
- **RLS:** `notifications_tenant_isolation`, `notification_reads_tenant_isolation` (the plain tenant policy, the 0056 shape — operator-only surfaces, never read by the portal). The `client-isolation` pin moved 99 → 101.
- **The probe** (the 0064/0066 model): the accepted shapes are inserted and rolled back by a sentinel, so a CHECK that refuses everything cannot pass; each refused shape (unknown source type, raised without either instant, unresolved tombstone, resolved without a resolution, a resolution without `resolved_at`) must be refused **by its named constraint**.
- Also in 0067: **`integrations.sync_episode_id`** (uuid, nullable) — owned and written by **channels**, not here (see `channels.md` §Sync-health episodes).

The module writes no `audit_events`, appends no outbox events, and stores no idempotency keys.

---

## Public seam

`NotificationsModule` provides `NotificationsDeliveryHandler` and `NotificationsFacade`, and exports **the facade alone** (`notifications.module.ts`). The api shell's `NotificationsController` (`src/api/notifications.controller.ts`) is the HTTP surface.

| Method (`notifications.facade.ts`) | Does | Called by |
|---|---|---|
| `list(tenantId, userId, {cursor?, limit?})` :85 | Visible, non-tombstone entries, newest `(raised_at, id)` first, keyset-paged (default 25, max 100) | `GET /tenants/{t}/notifications` |
| `status(tenantId, userId)` :140 | `{hasNew}` — the bell's dot | `GET …/notifications/status` |
| `opened(tenantId, userId)` :173 | Upserts `last_opened_at = now()`, returns `{hasNew: false}` | `POST …/notifications/opened` |

Every method re-reads the caller's role **in its own tenant transaction** (`getMemberRoleIn`; a removed member is refused there, `403 role-denied`) and maps it through `visibleSourceTypes(role)` (`notification-sources.ts:473`). A role that can act on no source gets an empty list and `hasNew: false` without a query.

**The one cross-module import** is tenancy's role read and capability map (`getMemberRoleIn`, `ROLE_CAPABILITIES`). The routing rule is the commands' own authority, never a copy of it. Beyond that the module imports two status tuples from `schema.ts` (`COUNT_VARIANCE_STATUSES`, `REJECTED_OP_STATUSES` — vocabularies, not tables) and nothing of any sibling.

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

**The subscriber** (`notifications.delivery.ts`). It subscribes to every key of `EVENT_ROUTES` in `onModuleInit` (:57). `deliver` (:64), in order:

1. Unknown type → return.
2. `occurredAt` not an ISO-8601 UTC instant → log, **ack**.
3. Decode the payload (`decodeRaise`/`decodeResolve`); malformed → log, **ack**; the variance `ignore` → return.
4. One `withTenantTransaction` of its own, one upsert:
   - **raise** (`raise` :129): insert `{summary, warehouse, raised_at = occurredAt, surfaced_at = now()}`; on conflict update the same fields **only where `summary IS NULL`** (filling a tombstone keeps `resolved_at`/`resolution`). A row that already has a summary is a re-delivery: no change, not even a different summary or instant.
   - **resolve** (`apply` :85): insert a tombstone `{summary: null, raised_at: null, surfaced_at: null, resolved_at = occurredAt, resolution}`; on conflict set `resolved_at`, `resolution` **only where `resolved_at IS NULL`** (resolved once).
5. **Errors** (`isDataFault` :166): a `ProblemException` < 500, or SQLSTATE class **22** (data exception) or **23** (integrity violation) anywhere on the error's `cause` chain → log, **ack**. Anything else → log and **rethrow**, so the relay re-delivers. This is safe because no other subscriber exists on these event types today and both upserts are idempotent.

**`opened`** takes **no `Idempotency-Key`** — the one mutating route without one (API-SURFACE records the exception). Setting a time to now is naturally idempotent, and a retry only moves it forward. Any member may call it; a role that sees nothing just records an open.

**The HTTP guards**, in order: `TenantSessionGuard` (401; a client-portal token → `403 role-denied`) → `assertOwnTenantToken` (`403 permission-denied`) → the query DTO (`limit` 1–100 → else `400 validation-failed`) → the facade (`decodeCursorSafe` → `400 invalid-cursor`; the role re-read — a user who is not a member → `403 role-denied`).

---

## Key algorithms

**The list** (`list` :85). Filter: tenant, `source_type IN visible`, `summary IS NOT NULL` (tombstones are never served), and with a cursor the row comparison `(raised_at, id) < (cursor instant, cursor id)`. Order: `raised_at DESC NULLS LAST, id DESC NULLS LAST` — **exactly the index's order**, so the index can serve the page with no Sort (the patch commit `59402fc` records an EXPLAIN showing an Index Scan with the keyset comparison as an index condition). A bare `desc` means NULLS FIRST and does not match the index (code review BE2). The cursor is the house codec over the raw `raised_at::text` instant (`fullPrecisionInstant`), with a local `CURSOR_INSTANT_RE` and `decodeCursorSafe`.

**The dot** (`status` :140). True iff some visible, non-tombstone, **open** (`resolved_at IS NULL`) entry has `surfaced_at > last_opened_at` — or the member has no `notification_reads` row and such an open entry exists. One `LEFT JOIN … LIMIT 1`. Consequences:

- Resolved entries never light it, so a first-time member with only resolved history sees no dot.
- An entry whose raise committed before the member's open but was projected after it **does** light it, because the dot compares `surfaced_at`, not `raised_at`.

**Why two instants.** `raised_at` is when the thing happened, which is what the list orders by. `surfaced_at` is when the panel could first show it. Driving the dot from `raised_at` would hide every entry the relay delivers after an open.

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
| Only this module writes the two tables; it reads no sibling's table; only the api shell and root import it | `test/architecture.spec.ts` "the notification panel is notifications-module-owned (story 9-2)" — with a meaningfulness check (the detectors bite on hard-coded specimens; the delivery and facade really write) |

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

---

## Gotchas

- **No backfill at deploy.** Only events relayed after 9-2 is running project an entry. A pending adjustment, open breach or QC hold that was raised before the deploy never surfaces, and when it later resolves, its resolve inserts a tombstone that nothing will ever fill (PENDING). The same applies to a breaker already open at deploy: it carries no `sync_episode_id`, so its recovery emits nothing (channels only closes episodes it opened).
- **A pre-9-2 variance resolve leaves a tombstone.** A `count.variance.resolved` without the `overThreshold` field (an event committed before 9-2) resolves as before — at worst one tombstone per in-flight event. Only an explicit `false` is ignored.
- **`surfaced_at` is the transaction's `now()`, not its commit time.** A raise transaction that starts before a member's `opened` and commits after it can carry a `surfaced_at` earlier than `last_opened_at`, so that entry would not light the dot. The window is one short transaction wide (PENDING).
- **Policy delete does not always clear the breach entry.** The breach's `policy-removed` arrives only when the SKU's default point is 0 (or the SKU is gone). With a default above 0 the scope stays a sweep candidate, and the sweep's `recovered` (or nothing, if still below the default) decides — see `replenishment.md`. The first build cleared the entry unconditionally while the breach stayed open in the queue (code review BE1).
- **The resolution lists must follow their emitters.** A new breach reason or rejected-op status the panel does not list would be acked as malformed and the entry would stand open forever. The pins fail the build/suite first; keep them.
- **Order the list the way the index is built** — `DESC NULLS LAST` on both keys (BE2).
- **The drain is sequential** (channels' epic-7 gotcha): this handler adds one short tenant transaction per relayed source event. It makes no network call, so it does not add the latency coupling that gotcha warns about.
