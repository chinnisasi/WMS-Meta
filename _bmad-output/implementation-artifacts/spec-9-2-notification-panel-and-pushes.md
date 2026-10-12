---
title: 'Notification panel — one bell for what is actionable, routed to who can act, resolving itself when the source clears'
type: 'feature'
created: '2026-10-12'
status: 'ready-for-dev'
route: 'dispatch'
review_loop_iteration: 0
context:
  - '_bmad-output/implementation-artifacts/epic-9-context.md'
  - '_bmad-output/implementation-artifacts/spec-9-1-operational-dashboard.md'
  - '_bmad-output/implementation-artifacts/spec-9-1b-dashboard-click-through.md'
  - 'docs/design/SYSTEM-DESIGN.md'
  - 'docs/design/IMPLEMENTATION-GUIDE.md'
  - 'docs/design/API-SURFACE.md'
  - 'docs/design/modules/replenishment.md'
  - 'docs/design/modules/channels.md'
  - 'docs/design/modules/inventory.md'
  - 'docs/design/modules/inbound.md'
  - 'docs/design/frontend/SYSTEM-DESIGN.md'
  - 'docs/design/frontend/IMPLEMENTATION-GUIDE.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** Story 9.2 (UX-DR12, UX-DR25, FR-22) asks for one notification panel: newest-first, amber-treated entries that click through to their source, with no badge-count spam. Today none of it exists:
- the `notifications` module is an empty placeholder;
- `/notifications` is a placeholder page;
- the shell has no bell;
- approval and alert events reach the outbox, but their only "consumer" is the event bus's log line (PENDING `replenishment` "No notification delivery").

**Approach:**
- **The notifications module:**
  - owns a `notifications` table, filled by idempotent outbox subscribers;
  - each source's raise event inserts an entry, and its resolve event marks the entry resolved;
  - a per-user "last opened" time drives the bell's dot.
- **A capability-routed list API.**
- **The bell and panel** in the shell, and a real `/notifications` page.
- **Backend events:** the sources that lack a raise or resolve event get one.

**Decisions (human, 2026-10-12):**
1. **Split.** 9-2 ships the **web panel**. Mobile pushes (task assignment, approval-needed, at-risk cutoff) are **9-2b**, recorded in backlog and deferred-work.
2. **Sources.** Six existing events, plus two new backend events:
   - adjustment awaiting approval;
   - count variance over threshold;
   - over-receipt awaiting approval;
   - reorder breach;
   - expiry/aged batch alert;
   - QC hold placed;
   - **new:** channel sync health degraded/recovered;
   - **new:** a device op rejected into the review queue.

   Task assignment is 9-2b.
3. **Routed by who can act.** A member sees only the entries whose source they hold the capability to act on.
4. **A dot, plus auto-resolve.** The bell shows a **dot** (never a count) when an **open** entry visible to the user surfaced after the user's last panel open. Entries show "resolved" when their source clears. There is no per-entry read state.

## Boundaries & Constraints

**Always:**
- **Sources.** Each row is raise → resolve; the source id is the entry's `source_id`, minted fresh per occurrence.

  | `source_type` | Raise | Resolve | Who sees it |
  |---|---|---|---|
  | `stock-adjustment` | `stock_adjustment.pending_approval` | `stock_adjustment.approved` / `.rejected` (`pendingAdjustmentId`) | `adjustments.approve` |
  | `count-variance` | `count.variance.threshold_exceeded` | `count.variance.resolved` (`varianceId`) | **owner only** (`count.command.ts:1180-1186`) |
  | `over-receipt` | `over_receipt.requested` | `over_receipt.approved` / `.rejected` (`overReceiptId`) | `review.decide` |
  | `rejected-op` | **new** `device.rejected_op.raised` | `device.rejected_op.resolved` (`rejectedOpId`) | `review.decide` |
  | `reorder-breach` | `replenishment.breach_detected` | **new** `replenishment.breach_cleared` (`breachId`) | `replenishment.manage` |
  | `batch-alert` | `replenishment.batch_alert_raised` | **new** `replenishment.batch_alert_cleared` (`alertId`) | `replenishment.manage` |
  | `qc-hold` | `qc_hold.placed` | `qc_hold.released` (`holdId`) | `qc.manage` |
  | `channel-sync` | **new** `channel.sync.degraded` | **new** `channel.sync.recovered` (`episodeId`) | `channel.manage` |

  - `source_type` is a closed TS tuple plus a migration CHECK, pinned together (§4).
  - The existing payloads' `notifyRole` hints are ignored.
- **Event changes.** All are additive and emitted in the transaction that makes the change.
  - **`device.rejected_op.raised`.** Emitted in `recordSyncReport` beside the insert (`sync-report.command.ts:611-629`), **only when** `inserted.length > 0`. Payload: `{rejectedOpId: inserted[0].id, opId, opType, problemCode, deviceId, operatorUserId}`.
  - **`replenishment.breach_cleared`** with `{breachId, warehouseId, skuId, reason}`:
    - in `recoverBreach` (pass it the breach row; `sweep.ts:331-341`) with `reason: 'recovered'`;
    - in dismiss (`replenishment.command.ts:716-729`) with `'dismissed'`;
    - in the suggested-PO actioned flip (`:864-871`) with `'actioned'`;
    - in policy deletion (`:663`), for each open breach of that policy, with `'policy-removed'`.
  - **`replenishment.batch_alert_cleared`** with `{alertId, warehouseId, reason}`, one event per alert:
    - in the expiry scan's auto-resolve (`expiry.scan.ts:194-208`) with `'resolved'`;
    - in dismiss (`replenishment.command.ts:1046-1058`) with `'dismissed'`.
  - **The "no outbox event" rule is reversed** for both replenishment events. This reverses `sweep.ts:329-332`, `expiry.scan.ts:192-196` and `replenishment.md`; update those comments and docs.
  - **Channel sync (`channels.events.ts` constants).**
    - **`channel.sync.degraded {connectionId, episodeId}`:**
      - Emitted on a breaker transition **closed → open** in `recordDelivery` (`channels.publish.ts:369-378`).
      - It mints `episodeId = uuidv7()` and stores it on the integration (`sync_episode_id`, a new nullable column in 0067).
      - Half-open → open (`:370`; the stored spelling is `'half-open'`) emits nothing, keeping the episode.
    - **`channel.sync.recovered {connectionId, episodeId, reason}`:**
      - On open/half-open → **closed** (`:356-366`), with `reason: 'recovered'`; clears `sync_episode_id`.
      - **In disconnect** (`channels.command.ts:903`), when an episode is open, with `reason: 'disconnected'`.
    - Lag-based health is **not** a trigger.
  - **`over_receipt.requested` and `.approved`/`.rejected` gain `warehouseId`** (`receiving.command.ts:1118-1131,1420-1434`).
  - **`count.variance.resolved` gains `overThreshold: boolean`** (true iff a threshold-exceeded event was raised for it, `count.command.ts:910-914`).
- **Migration `0067_notifications.sql`** (§3 checklist; additive):
  - **`notifications`:**
    - columns: `id` uuidv7, `tenant_id`, `source_type` (CHECK), `source_id` uuid, `warehouse_id` nullable, `summary` jsonb nullable (null only on a tombstone), `raised_at`, `surfaced_at`, `resolved_at` nullable, `resolution` nullable, `created_at`, `updated_at`;
    - **unique** `(tenant_id, source_type, source_id)`;
    - index `(tenant_id, raised_at desc, id desc)`;
    - tenant RLS (the `0056:133-141` pattern).
  - **`notification_reads`:** PK `(tenant_id, user_id)`, `last_opened_at`, tenant RLS. There is no foreign key (house convention); the user is the session user.
  - **`integrations.sync_episode_id`:** uuid, nullable.
  - Probe, journal, snapshot.
- **Subscribers** (`notifications/notifications.delivery.ts`, modelled on `invoicing/eway.delivery.ts`). They subscribe in `onModuleInit`, decode ids only, and write in their own `withTenantTransaction`.
  - **Raise:** an upsert on the unique key.
    - A new row gets `raised_at` from the event's `occurredAt`, `surfaced_at = now()` and the `summary`.
    - If a tombstone exists, the raise fills `summary`, sets `raised_at` and `surfaced_at`, and keeps `resolved_at`.
    - A row that already has a summary is a re-delivery and changes nothing.
  - **Resolve:** sets `resolved_at` (the event's `occurredAt`) and `resolution` if not set. If no row exists, it inserts a **tombstone** (`summary` null) **except** for a `count.variance.resolved` with `overThreshold: false` (ignored, since no raise will come).
  - **`summary`.** A per-`source_type` allowlist, built key by key and never spread:
    - stock-adjustment `{skuId, quantityDelta, reasonCode}`;
    - count-variance `{skuId, delta}`;
    - over-receipt `{grnCode, skuId, excessQty}`;
    - rejected-op `{opType, problemCode}`;
    - reorder-breach `{skuId, atpQty, pointQty}`;
    - batch-alert `{kind, skuId, batchCode, expiryDate|ageDays}`;
    - qc-hold `{skuId, reason}`;
    - channel-sync `{connectionId}`.
  - **Errors.** Ack (log, no rethrow):
    - a malformed payload;
    - `ProblemException` < 500;
    - SQLSTATE classes **22** and **23**.

    Rethrow anything else. No other subscriber exists on these event types today, and handlers are idempotent, so a transient rethrow re-delivers safely.
  - **No outbox events of their own; no audit.**
- **API** `src/api/notifications.controller.ts`, behind `TenantSessionGuard` (which fences client tokens) and `assertOwnTenantToken`. The caller's role is read in the transaction, then mapped through `ROLE_CAPABILITIES` to the visible `source_type`s.
  - **`GET /tenants/{t}/notifications?cursor&limit`:**
    - visible, **non-tombstone** entries, newest `(raised_at, id)` first;
    - `limit` default 25, range 1–100, out of range → 400 `validation-failed`;
    - the house cursor codec: `fullPrecisionInstant`, a local `CURSOR_INSTANT_RE` and `decodeCursorSafe` → 400 `invalid-cursor` (`transfer.facade.ts:189-205`);
    - rows `{id, sourceType, sourceId, warehouseId, summary, raisedAt, resolvedAt, resolution}`, with `summary` an OpenAPI discriminated union by `sourceType`.
  - **`GET …/notifications/status`** → `{hasNew}`: true iff a visible, non-tombstone, **open** (`resolved_at IS NULL`) entry has `surfaced_at` after the caller's `last_opened_at`, or the caller has no read row. A first-time user with no open entries sees no dot.
  - **`POST …/notifications/opened`:** upserts `last_opened_at = now()` and returns `{hasNew: false}`. It takes **no** `Idempotency-Key`, because setting a time to now is naturally idempotent; record this exception in API-SURFACE.
  - A role that can act on no source gets an empty list and `hasNew: false`.
- **FR-22:** `.env.example` gains `REPLENISHMENT_SCHEDULER_POLL_MS=60000`. A deploy note says the ≤ 5 min bound needs it (with ≤ 200 scopes per tick, `replenishment.md:153`).
- **Web:**
  - **The bell.** A `<details>` sibling of the shell menu, beside Search (`app-shell.tsx:100-131`), following the menu's rules (`:73-94`).
    - **Closing:** Esc and an outside click close it; opening the palette or following a link closes it.
    - **Focus:** moves into the panel on open and returns to the bell on close.
    - **Accessibility:** the trigger is a button with `aria-expanded`. Its label is "Notifications" or "Notifications, new" when the dot shows. The amber dot is `aria-hidden` and never shows a number.
  - **Fetching.** `status` runs on shell mount and on each **pathname** change (the shell persists across routes in `(app)/layout.tsx`; query-only changes do not refetch). There is no polling.
  - **The panel body** mounts only while open, so `useSkuMap` and the warehouse list load only then. Opening it lists the newest 10 entries, calls `opened` (the wrapper is not the keyed-POST helper) and clears the dot. "See all" links to `/notifications`.
  - **`/notifications`:** the full keyset list (`DataTable` Prev/Next). The empty state comes from the API's empty response; the frontend mirrors no routing table.
  - **Entries:**
    - **Status:** open entries are amber; resolved entries are muted, with "Resolved · {resolution}".
    - **Content:** a category label, a one-line description from `summary` (the SKU code via `useSkuMap`, the warehouse via `warehouseDisplayLabel`), and the relative time with the IST absolute time as the title.
    - **Click-through links:**

      | Source | Open entry | Resolved entry |
      |---|---|---|
      | over-receipt | `/conflicts?list=over-receipts&warehouseId=…&status=pending` | `/conflicts?list=over-receipts&warehouseId=…` |
      | batch alert | `/replenishment?list=batch-alerts&warehouseId=…&kind=…` | same |
      | stock-adjustment, count-variance, rejected-op | `/conflicts` | same |
      | reorder-breach | `/replenishment` | same |
      | qc-hold | `/inbound` | same |
      | channel-sync | `/channels` | same |

      Every drill link must parse under 9-1b's `parseDrill`.
- **Tests:**
  - **BE harness:** the `drainAll` loop (`relay.drain(100)`, `eway.spec.ts:404-408`). Resolve-before-raise inserts the outbox rows directly with the resolve first, then drains.
  - **BE cases:**
    - each raise → an entry;
    - each resolve → resolved;
    - a tombstone, then the raise fills it;
    - re-delivery changes nothing;
    - an under-threshold variance resolve leaves no row;
    - a channel trips twice → two entries (episodes);
    - a disconnect while open → resolved `disconnected`;
    - a policy delete → breach cleared;
    - malformed and SQLSTATE-23 payloads are acked;
    - routing per role (owner, ops_manager, operator, accountant);
    - the client token is fenced;
    - keyset paging at `limit=2`, an invalid cursor and limit bounds;
    - the `status` rules: open only, `surfaced_at` vs `last_opened_at`, first-time user;
    - `opened`;
    - each new event emitted **only** on its transition (breaker; inserted rejected op; half-open → open emits nothing);
    - the payload additions;
    - the migration probe;
    - the architecture block: notifications tables written only by `modules/notifications`, with a meaningfulness check (`architecture.spec.ts:1391-1451`).
  - **FE** (`next/navigation` `usePathname` mocked as in `drill-screens.test.tsx:50`):
    - the dot shows and clears, and is never a number;
    - exactly one status call per pathname change, none on a timer and none on a query-only change;
    - the panel renders open and resolved entries, each link per source, and parses every drill link;
    - the panel body is lazy;
    - Esc, outside click and focus return;
    - page paging;
    - the empty state.
- **Docs:**
  - `modules/notifications.md` (new);
  - `modules/replenishment.md` (the reversed rule, the new events);
  - `channels.md` (episodes, the new events, disconnect);
  - `inbound.md` (the over-receipt `warehouseId`);
  - `tenancy.md` (rejected-op raised);
  - `movements` or `inventory.md` (`overThreshold`);
  - `SYSTEM-DESIGN.md` module map;
  - `API-SURFACE.md` (the new routes, the `opened` exception);
  - `frontend/SYSTEM-DESIGN.md`;
  - both repo contracts;
  - `PENDING.md`: close "No notification delivery"; correct the suggested-PO `notifyRole` note; add resolved-entry retention, lag-based sync health and the 9-3 export-completion hook.

**Never:**
- mobile push;
- a numeric badge;
- polling;
- per-entry read state;
- an action button in the panel;
- notifications reading another module's tables;
- lag-based sync-health notifications;
- task-assignment notifications;
- spreading a raw payload into `summary`.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected | Error |
|---|---|---|---|
| Raise | Over-receipt requested | An entry for `review.decide` holders; a dot for them | — |
| Resolve | Over-receipt approved | Resolved · approved | — |
| Out of order | Resolve before raise | A tombstone; the raise fills it, resolved; no dot | — |
| Late delivery | Raise committed before an open, projected after it | The dot shows (by `surfaced_at`) | — |
| Re-delivery | Same event twice | No change | — |
| Variance under threshold | Resolve with `overThreshold: false` | No row | — |
| Channel episodes | The same connection trips twice | Two entries | — |
| Disconnect | Episode open | Resolved · disconnected | — |
| Policy delete | An open breach | Resolved · policy-removed | — |
| Routing | Operator / accountant | Empty list, no dot | — |
| Client token | A portal session | — | 403 `role-denied` |
| First-time user | No read row, only resolved entries | No dot | — |
| Bad payload | Malformed / a constraint violation | Logged, acked | — |
| Paging | Invalid cursor / limit 101 | — | 400 `invalid-cursor` / `validation-failed` |

</frozen-after-approval>

## Code Map

Paths are relative to `workspace/core/backend/wms-be/src` (BE) and `workspace/core/frontend/wms-fe/src` (FE).

- **Outbox and bus:** `shared/events/outbox.ts:18,20-21,60-91,98-280`; `shared/events/event-bus.ts:38-63`; `event-bus.seam.ts` (`occurredAt`).
- **Model subscriber:** `modules/invoicing/eway.delivery.ts:41-113`, `delivery.ts:30-40,98-113`.
- **Sources:**
  - `inventory/inventory.command.ts:541-557`;
  - `inventory/adjustment-approval.command.ts:453,530`;
  - `movements/count.command.ts:910-928,1180-1186,1407-1425`;
  - `inbound/receiving.command.ts:1118-1131,1167,1420-1434`;
  - `inbound/qc.command.ts:460-475,515,686-700`;
  - `replenishment/replenishment.sweep.ts:69,240,300-313,329-341`;
  - `replenishment/replenishment.command.ts:663,699,716-729,864-876,1028,1046-1058`;
  - `replenishment/replenishment.expiry.scan.ts:192-208,262,284-305`;
  - `tenancy/sync-report.command.ts:512,539,611-629,823,993-1015`;
  - `channels/channels.publish.ts:266,270-282,356-378`;
  - `channels/channels.command.ts:96,903`;
  - `channels/channels.events.ts:9`.
- **Authority:** `tenancy/permissions.ts:149,168-173`, `ROLE_CAPABILITIES`, `getMemberRoleIn`.
- **Cursor:** `transfer.facade.ts:189-205`; `shared/primitives/time.ts` (`fullPrecisionInstant`).
- **Module and API:** `modules/notifications/notifications.module.ts`; `invoicing/invoicing.module.ts`; `api/invoicing.controller.ts:103-121`.
- **Migrations:** latest `0066`; `drizzle/0056_eway_bills.sql:133-141`; probe model `0064:186-320`; `test/architecture.spec.ts:1391-1451`; `test/eway.spec.ts:404-408` (`drainAll`).
- **Jobs:** `jobs/jobs.module.ts:463,484,585`; `.env.example`.
- **FE:**
  - `components/shell/app-shell.tsx:73-131`;
  - `components/shell/command-palette.tsx:52`;
  - `app/(app)/layout.tsx`;
  - `app/(app)/notifications/page.tsx`;
  - `lib/navigation.ts:42`;
  - `lib/drill.ts` (`parseDrill`, `warehouseDisplayLabel` :458);
  - `lib/use-inbound.ts:486-503` (`useSkuMap`);
  - `lib/api/client.ts:500` (keyed-POST helper);
  - `components/drill/drill-screens.test.tsx:50`.

## Tasks & Acceptance

**Execution:**
- [ ] `wms-be`: migration 0067 (tables, column, CHECK, RLS, probe), schema, the vocabulary tuple + pin.
- [ ] `wms-be` event changes: rejected-op raised; breach and batch-alert cleared (incl. policy delete); channel episodes + degraded/recovered + disconnect; over-receipt `warehouseId`; variance `overThreshold`.
- [ ] `wms-be` notifications module: subscribers, facade (list, status, opened), wiring.
- [ ] `wms-be` api: controller, DTOs (summary union), `openapi.json`.
- [ ] `wms-be` tests per Boundaries; the architecture block.
- [ ] `wms-be` `.env.example`.
- [ ] `wms-fe`: `api:generate`; wrappers and hooks; the bell + lazy panel; the `/notifications` page; entries and links; tests.
- [ ] Meta docs per Boundaries.

**Acceptance Criteria:**
- Given a pending over-receipt, when an owner opens the bell, then it is listed newest-first and amber. Clicking it opens the over-receipts queue filtered to pending in its warehouse. After approval, the entry shows resolved.
- Given an operator, when they open the bell, then the panel is empty and no dot ever shows.
- Given the full BE and FE suites, lint and typecheck, when run, then they pass.

## Implementation Notes

## Spec Change Log

## Review Triage Log

Design review (2026-10-12), two lenses: backend (K) and API, web and tests (W).

| # | Lens | Finding | Verdict | Disposition |
|---|---|---|---|---|
| 1 | K | A channel notifies only once: `connectionId` as the source id, so the next trip is swallowed | high — verified, `channels.publish.ts:356-378` | Fixed: episode ids (`integrations.sync_episode_id`) |
| 2 | W, K | The dot races the relay: an entry projected after an open never lights it | high | Fixed: `surfaced_at` drives the dot; `raised_at` (`occurredAt`) orders |
| 3 | W, K | The over-receipt payload has no `warehouseId`, so the drill link is never used | high — verified, `receiving.command.ts:1118-1131` | Fixed: additive payload field; `status=pending` for open entries |
| 4 | W, K | Disconnect deletes the connection, so a degraded entry is orphaned | high — verified, `channels.command.ts:903` | Fixed: recovered · disconnected |
| 5 | K | Under-threshold variance resolves leave unbounded tombstones | medium — verified, `count.command.ts:910-914,1407` | Fixed: `overThreshold` flag; no tombstone when false |
| 6 | K | Breaches orphaned when their policy is deleted | medium | Fixed: `breach_cleared` · policy-removed |
| 7 | W | `summary` had no shape; raw payloads carry `notifyRole`, `tenantId` and actor ids | medium | Fixed: a per-source allowlist; an OpenAPI union |
| 8 | W | The dot fires for resolved entries and for all history for first-time users | medium | Fixed: open entries only |
| 9 | K | Data-fault classification was undefined; bus ordering | medium | Fixed: SQLSTATE 22/23 + ProblemException < 500 acked; no other subscribers today |
| 10 | W | The cursor codec and default limit were unnamed | medium | Fixed |
| 11 | W | `useSkuMap` in the shell would page the catalog on every load | medium | Fixed: the panel body is lazy |
| 12 | W | The panel layer contract was unspecified | medium | Fixed: a `<details>` sibling, Esc/outside/focus, aria |
| 13 | K | The new replenishment events reverse a documented "no outbox event" rule | low | Fixed: acknowledged; comments and docs updated |
| 14 | K | Line refs; `recoverBreach` lacks warehouse and SKU | low | Fixed |
| 15 | K | Event naming style in `channels.events.ts` | low | Fixed: `channel.sync.degraded` / `.recovered` |
| 16 | K | The breaker spelling is `'half-open'`; half-open → open must emit nothing | low | Fixed |
| 17 | K | Index direction; `notification_reads` FK | low | Fixed: `desc, desc`; no FK by convention |
| 18 | W | Per-navigation cost and the test hooks | low | Fixed: pathname-only; tests named |
| 19 | W | `opened` without `Idempotency-Key` is a new exception | low | Fixed: documented in API-SURFACE |
| 20 | W | The FE must not mirror the routing table | low | Fixed |
| 21 | W | The test harness for the relay | low | Fixed: `drainAll` |
| 22 | W | Docs list gaps; `context:` missing API-SURFACE | low | Fixed |
| 23 | K | Verified: resolve ids match raise ids; capabilities and guards; cross-module permission import allowed; 0067 numbering; the env var absent | — | No change |

## Design Notes

- **Why entries are projected.** The panel spans six modules. A projection keyed on a per-occurrence source id is one indexed read, and the resolve events keep it honest.
- **Why `surfaced_at` beside `raised_at`.** `raised_at` is when the thing happened, which orders the list. `surfaced_at` is when the panel could first show it, which drives the dot. Using `raised_at` for the dot would hide entries the relay delivers late.
- **Why episodes for sync health.** A connection trips many times; each trip is a new thing to attend to. A per-episode id keeps the one-row-per-source rule true.
- **Why tombstones, but not for ordinary variances.** The relay can deliver a resolve before its raise, and a tombstone keeps the late raise from reopening a settled entry. An under-threshold variance never raises, so its resolve must not leave a row.
- **Why capability, not `notifyRole`.** The hints disagree with who can act. Capability is the rule the commands enforce.
- **Reversed rule.** The breach recovery and alert auto-resolve deliberately emitted no outbox event (they had no consumer). Notifications is now that consumer.
