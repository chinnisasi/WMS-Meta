---
title: 'Mobile pushes — new work, approvals awaiting and wave cutoff at risk, sent to the handhelds that can act'
type: 'feature'
created: '2026-10-12'
status: 'ready-for-dev'
route: 'dispatch'
review_loop_iteration: 0
context:
  - '_bmad-output/implementation-artifacts/epic-9-context.md'
  - '_bmad-output/implementation-artifacts/spec-9-2-notification-panel-and-pushes.md'
  - 'docs/design/SYSTEM-DESIGN.md'
  - 'docs/design/IMPLEMENTATION-GUIDE.md'
  - 'docs/design/API-SURFACE.md'
  - 'docs/design/modules/notifications.md'
  - 'docs/design/modules/tenancy.md'
  - 'docs/design/modules/outbound.md'
  - 'docs/design/modules/movements.md'
  - 'docs/design/mobile/SYSTEM-DESIGN.md'
  - 'docs/design/mobile/IMPLEMENTATION-GUIDE.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** Story 9.2 restricts mobile pushes to three kinds: task assignment, approval-needed and at-risk cutoff. 9-2 shipped only the web panel. Nothing can reach a handheld today:
- the app has no push library;
- `devices` has no token;
- no backend code sends anything;
- nothing computes "at risk".

**Approach:**
- **Registration:** the handheld registers an Expo push token together with the warehouse it works in.
- **Queueing:** the notifications module turns the relevant outbox events into queued push deliveries. Queueing never touches the network.
- **Sending:** a separate sender worker sends the queue through a `PushGateway` port. The port is `unconfigured` by default, and `expo` once credentials are set.
- **At-risk:** an outbound sweep raises the at-risk event.
- **Taps:** a tap opens the inbox, and only when that is safe. A push is never a source of truth.

**Decisions (human, 2026-10-12):**
1. **"Task assignment" means new work in a warehouse.** There is no assignment model. A push goes to every eligible handheld whose registered warehouse is the work's warehouse when:
   - a wave is released (tab Pick);
   - a count is created on demand or as a recount (tab Count);
   - an inbound transfer is confirmed for the destination warehouse (tab Transfer).
2. **Approval-needed is a heads-up push.** It goes to handhelds whose bound operator is in the 9-2 audience for that source. The text says to decide on the web. There are no mobile approval screens.
3. **At-risk reuses the web's 60-minute rule.** A wave still `planned`, with `0 < minutes to its policy cutoff ≤ 60` (IST, `WAVE_CUTOFF_TIMEZONE`), raises `wave.cutoff_at_risk` once per wave per IST date. It is pushed to handhelds whose operator's role holds `waves.manage`.
4. **Delivery is a port selected by env.**
   - `PUSH_GATEWAY=unconfigured` is the default. It records each send it would have made and makes no network call.
   - `expo` posts to the Expo push API with `EXPO_ACCESS_TOKEN`.
   - The mobile app registers only when an EAS `projectId` is configured and it is not running in Expo Go.

## Boundaries & Constraints

**Always:**

*Eligibility*
- An eligible handheld must meet all of these:
  - `devices.status = 'active'`;
  - a non-null `push_token` and `operator_user_id`;
  - its operator's `users` row is `status = 'active'`, has `client_id IS NULL`, and has a floor role or `accountant`. This is the same rule as badge-in, `enrollment.command.ts:513-530`.
- On top of that, each kind has an audience:
  - **new-work:** a floor role (owner, ops_manager, operator), plus `push_warehouse_id` must equal the event's warehouse;
  - **approval:** the role passes 9-2's `SOURCE_AUDIENCE` predicate for that source, reused rather than re-derived. Any warehouse;
  - **at-risk:** the role holds `waves.manage`. Any warehouse.
- Eligibility is checked twice: when the delivery is queued, and again when it is sent. A device revoked, unbound or re-registered in between is skipped.

*Queue then send*
- The outbox handler is `PushEnqueueHandler`. It only inserts `push_deliveries` rows (`pending`, `ON CONFLICT (tenant_id, event_id, device_id) DO NOTHING`) in its own tenant transaction. It never calls the network, so a push outage can never stall the relay or quarantine the rows the 9-2 projection shares.
- The `PushSenderWorker` is env-gated by `PUSH_SENDER_POLL_MS`, absent = off, `.env.example` 5000.
  - **Per tick:** it finds tenants with due rows through the read-only BYPASSRLS `AUTH_DATABASE` (the `ReplenishmentSchedulerWorker` precedent). For each tenant it calls `NotificationsFacade.sendDuePushes(tenantId)`.
  - **That call claims due rows** (`pending` with `next_attempt_at <= now()`, at most 100) with `FOR UPDATE SKIP LOCKED`. It marks them `sending` and commits, then sends one batch. In a second transaction it writes each ticket's outcome.
  - **At-most-once:** a row found `sending` for more than 5 minutes is marked `failed` (`stale`) and is never re-sent.
- **The send outcome classification is one table, `PUSH_ERROR_CLASS`:**

  | Outcome | Classification | What happens to the row |
  |---|---|---|
  | Ticket `ok` | — | `sent` |
  | `DeviceNotRegistered` | permanent | `failed`; the token is cleared, but only if still equal to the sent token |
  | `MessageTooBig`, `InvalidProviderToken` and unknown codes | permanent | `failed` |
  | `MessageRateExceeded`, network, timeout, HTTP 429/5xx | transient | back to `pending`; `attempts += 1`; `next_attempt_at` = now + `min(2^(attempts-1)·5 s, 5 min)` |
  | HTTP 401/403, `InvalidCredentials` | config fault | logged at error once per tick; rows back to `pending` |

  - A transient outcome after 5 attempts becomes `failed`.
  - A config fault never counts as an attempt; rows older than 1 hour become `failed`.
  - Only the error **code** is stored or logged, never Expo's message, because it contains the token.

*Staleness*
- At enqueue, an event whose `occurredAt` is more than 30 minutes old is acked without queueing. This covers the deploy backlog and operator replays of quarantined rows.
- An at-risk event whose cutoff has already passed is acked.
- Messages carry `ttl: 3600`.

*Token ownership*
- A token belongs to at most one device across all tenants:
  - **On registration**, the PUT clears the same token from every other device row in the tenant.
  - **At send time**, the sender reads through `AUTH_DATABASE` the device with the latest `push_registered_at` holding that token, across tenants. If that device is not the row's device, the row is marked `failed` (`superseded`) and the token is cleared on its own device row. This write stays inside the row's own tenant.

*Payloads*
- A payload carries a fixed title and body per kind, plus `data: {kind, tab}`.
  - `tab` is one of `Pick | Count | Transfer | All`, case-sensitive.
  - There is no business data, no `badge`, and no `sound` override.
- Android delivery fields: `channelId: 'work'` and `priority: 'high'`.

*Module boundaries*
- Tenancy owns every `devices` read and write. Notifications calls these functions in `tenancy.service.ts`:
  - `listPushTargets`;
  - `getPushTargetsIn`, the eligibility re-check;
  - `clearPushTokenIn(tx, tenantId, deviceId, token)`, which clears only `WHERE push_token = token`.
- `pushDeliveries` joins notifications' `OWN_SCHEMA_NAMES`.

*Mobile, under the zero-scan-loss rules*
- **The permission prompt happens only on `/inbox`, never on a task screen.** It is preceded by creating the Android `work` channel (HIGH importance). It is asked at most once, governed by `canAskAgain`.
- **A token refresh is silent.** After badge-in and after any successful `refreshCatalogSnapshot`, the PUT is re-sent only if permission is already `granted` and `lastWarehouseId` exists.
- **A tap navigates only on an allowlist.** The device phase must be `badged` and the current path `/inbox` or `/health`. Every other screen is a no-op, including all task screens, `self-test`, `badge-in`, `enroll` and `revoked`.
- **A tap that launches the app** is held as pending until the phase is `badged`, then applied through the gate's own route (`/inbox?tab=…`). Duplicates are dropped by `request.identifier`.
- **When the app comes back to the foreground**, it checks permission. If permission is no longer `granted` and a token was registered, it sends `DELETE`.

**Never:**
- No push for reorder, expiry, breach, QC, sync health or rejected ops (UX-DR25), and no push for scheduled counts.
- No badge counts, no new task screens, no assignment model, no mobile approvals.
- No Expo receipt polling, and no network call inside an outbox handler.
- No cross-tenant writes.
- No `expo-notifications` import in any module a bun test loads without a `mock.module` stub (mobile IMPLEMENTATION-GUIDE §8).

## I/O & Edge-Case Matrix

| Scenario | State | Expected |
|---|---|---|
| A wave is released in WH-A | 2 eligible devices registered to WH-A, 1 to WH-B | 2 `pending` rows, then 2 sends with kind `new-work` and tab `Pick` |
| The outbox row is delivered again | rows exist | no new rows, no re-send |
| Scheduled count tick creates 30 tasks | — | no pushes |
| Adjustment pending approval | owner device (any warehouse), operator device | owner queued; operator not |
| Count variance over threshold | ops_manager device | none (owner-only per 9-2) |
| Operator deactivated or moved to client after enqueue | row `pending` | at send: `failed` (`ineligible`), not sent |
| Planned wave, cutoff 18:00, now 17:00 / 17:01 / 17:59 / 18:00 IST | not alerted | 60 → raise; 59 → raise; 1 → raise; 0 → none |
| Same wave, next tick | alerted for today's IST date | nothing |
| Wave released or cancelled | — | no event |
| Event replayed 2 h later | — | acked, not queued |
| Batch of 100: 99 ok, 1 `DeviceNotRegistered` | — | 99 `sent`; 1 `failed`; its token cleared if unchanged |
| Expo 503 | — | rows `pending` with backoff; relay unaffected |
| Process crashes after send, before outcome | rows `sending` | after 5 min `failed` (`stale`); never re-sent |
| `EXPO_ACCESS_TOKEN` invalid | — | error log; rows retried; `failed` after 1 h |
| Same phone re-enrolled into tenant B | tenant A row still active with the same token | tenant A's row `failed` (`superseded`); its token cleared |
| PUT with enrollment-only credential | `userId` null | 401 |
| PUT from a revoked or rebound device | — | 403 `device-revoked` |
| PUT for another tenant's warehouse | — | 404 `not-found` |
| Mobile: no `projectId`, or Expo Go | — | no prompt, no PUT |
| Mobile: no `lastWarehouseId` | — | no PUT until a snapshot has been fetched |
| Mobile: tap on `/pick`, `/self-test` or `/badge-in` | — | no navigation |
| Mobile: tap on inbox, same tab as showing | — | inbox refreshes the snapshot and re-reads it |
| Mobile: tap launches the app | phase resolves `badged` | lands on `/inbox?tab=…` once; not re-applied after restart |
| Mobile: permission revoked in settings | token registered | on next foreground, `DELETE` |

</frozen-after-approval>

## Code Map

Paths relative to `workspace/core/backend/wms-be/src` (BE) and `workspace/core/mobile/wms-mobile` (M).

- **Devices:**
  - `shared/db/schema.ts:1619-1660` (`devices`), `:80` (`users.status`);
  - `modules/tenancy/enrollment.command.ts:251-259` (each mint is a new row; there is no re-enroll path), `:513-530` (the badge-in eligibility rule to mirror), `:568` (`revokeDevice`, which clears the push columns), `:745-755` (`selfTestEcho`, the lock + `active` + bound-to-session model for PUT/DELETE);
  - `device-session.guard.ts:23-31` (transport-only; it accepts the enrollment credential, where `userId` is null, `jwt-session.ts:154-155`);
  - `api/devices.controller.ts:229-262` (self-test, which rejects a null `userId`);
  - `tenancy.service.ts:86-108` (`assertWarehouseInTenant`), `:163-187` (`getMemberRoleIn`, which does not check status).
- **Notifications (9-2):**
  - `notification-sources.ts:461-480` (`SOURCE_AUDIENCE`);
  - `notifications.delivery.ts:39-44,166` (single-subscriber assumption, now false; `isDataFault`);
  - `notifications.facade.ts:11`;
  - `api/notifications.controller.ts:88` ("the one exception" wording, to update).
- **Events:**
  - `wave.released` carries `wave.warehouseId` (`outbound/wave.command.ts:800-805,1350`);
  - `count.created` has `origin` `on_demand` (`movements/count.command.ts:574-581`), `scheduled` (`:1865-1877`) and `recount` (`:1968`, `:2051`);
  - `transfer.outbound-confirmed` carries `destWarehouseId` (`transfer.command.ts:1107-1116`);
  - approval raises as in 9-2.
- **Cutoff:**
  - `outbound/wave.command.ts:84` (`WAVE_CUTOFF_TIMEZONE`), `:711-723` (release allowed through the cutoff minute), `:1464` (`localTimeOfDay`);
  - `shared/primitives/time.ts:21` (`istDateOf`);
  - `wave.clock.ts:13` (`WAVE_CLOCK`);
  - web `wms-fe/src/lib/outbound-waves.ts:141`.
- **Relay facts:**
  - `shared/events/outbox.ts:18-28` (5 attempts, then backoff), `:88-91` (at-least-once), `:115-121,174-190` (serial and single-flight);
  - `event-bus.ts:30-33,54-55` (handler order; a throw aborts the rest).
- **Workers:** `jobs/jobs.module.ts:8-17` (facades only), `:116`, `:469-625` (`ReplenishmentSchedulerWorker`, AUTH_DATABASE discovery `:475-480`).
- **HTTP and gateway models:** `channels/channel-http.ts:96-198` (copy the shape; don't import it); `invoicing/eway-gateway.ts:6-53`.
- **Architecture:** `test/architecture.spec.ts:1471-1478` (`OWN_SCHEMA_NAMES`), `:1525` (raw `.execute(` ban), the write-ownership test.
- **Migrations:** latest `0067`; `0067_notifications.sql` is the probe model.
- **Mobile:**
  - `package.json`, `app.json:18-23`, `.github/workflows/ci.yml` (test + typecheck; there is no lint script);
  - `src/state/device-store.ts:181-187,288-296,392-406` (badge-in refresh, `refreshCatalogSnapshot`, reset purge);
  - `src/state/device-store-composition.test.ts:27-34` (`mock.module` stubs; add `expo-notifications` and `expo-constants`);
  - `app/_layout.tsx:16-40`, `app/index.tsx:16-43` (the gate's `replace`);
  - `app/inbox.tsx:42-48,70-72,77-116` (private `TaskTab`, `useState('All')`, a catalog effect on `[tab]`);
  - the task screens' refresh calls (`pick.tsx:148`, `putaway.tsx:95`, `count.tsx:196`, `receive.tsx:147`, `transfer.tsx:187`, `pack.tsx:156`);
  - `src/scanning/adapters.tsx:12-24` (wedge focus).

## Design

- **Migration `0068_mobile_pushes.sql`** (§3 checklist):
  - **`devices` columns:** `push_token text`, `push_warehouse_id uuid`, `push_registered_at timestamptz`, all nullable. Plus a partial index on `push_token WHERE push_token IS NOT NULL`, for the send-time ownership read.
  - **`push_deliveries` columns:**
    - keys: `tenant_id`, `event_id uuid`, `device_id uuid`;
    - fields: `kind text NOT NULL CHECK (new-work|approval|at-risk)`, `tab text NOT NULL CHECK (Pick|Count|Transfer|All)`, `status text NOT NULL CHECK (pending|sending|sent|failed)`, `gateway text NULL CHECK (unconfigured|expo)`, `error_code text NULL`, `attempts int NOT NULL DEFAULT 0`, `next_attempt_at timestamptz NOT NULL`, `created_at`, `updated_at`.
  - **`push_deliveries` keys and policy:** PK `(tenant_id, event_id, device_id)`; index `(tenant_id, status, next_attempt_at)`; tenant RLS (`NULLIF`).
  - **`waves`:** `cutoff_risk_alerted_on date`, nullable.
  - **Probe DO-block:** one accepted shape plus each refused CHECK, by name. The RLS probe test lists the new table.
- **Registration routes, `PUT` and `DELETE /tenants/{t}/devices/push-registration`:**
  - **Guard and auth:** `DeviceSessionGuard`, plus `session.userId !== null` (401) and `assertOwnTenant`.
  - **Inside the transaction:** lock the device, then require `active` and bound to `session.userId` (403 `device-revoked`).
  - **PUT body:** `{token: ^Expo(nent)?PushToken\[[^\]]{1,200}\]$, warehouseId: uuid}`. The warehouse is checked with `assertWarehouseInTenant` (404 `not-found`). PUT also clears this token from the tenant's other device rows.
  - **Response and idempotency:** both return 204. There is no Idempotency-Key, because they are natural upserts. Update the "one exception" wording in the controller and API-SURFACE. The error arms are 400, 401, 403 and 404 in `openapi.json`.
- **`PushGateway`** (`notifications/push-gateway.ts`):
  - **Signature:** `send(messages): Promise<Ticket[]>`, where `Ticket` is `{ok} | {code}` in input order.
  - **`expo` adapter:** one https POST to `https://exp.host/--/api/v2/push/send` with at most 100 messages, a Bearer token and `PUSH_HTTP_TIMEOUT_MS` (default 10 s).
  - **Whole-request outcomes:** a whole-request 4xx other than 401/403/429 marks the batch `failed` with that code.
  - **Selection:** boot fails on `expo` without a token.
- **Copy:** one table, `PUSH_COPY`:
  - new-work: "New work ready" / "Picks released in your warehouse" | "A count was created" | "An inbound transfer is on its way";
  - approval: "Approval waiting" / "Decide it on the web";
  - at-risk: "Wave cutoff in under an hour" / "A planned wave isn't released yet".
- **Sweep:**
  - `WaveCutoffSweepWorker`, env-gated by `WAVE_CUTOFF_SWEEP_POLL_MS` (`.env.example` 60000), calls `OutboundFacade.sweepCutoffRisk(tenantId)`. Tenants are discovered through `AUTH_DATABASE`.
  - In one tenant transaction it selects planned waves whose policy has a cutoff and computes the remaining minutes with `localTimeOfDay` and `WAVE_CLOCK`. For waves where `0 < r ≤ 60` it runs `UPDATE … SET cutoff_risk_alerted_on = istDateOf(now) WHERE … IS DISTINCT FROM … RETURNING`, then appends `wave.cutoff_at_risk {waveId, warehouseId, cutoffLocalTime, istDate}`.
- **Mobile:**
  - `bunx expo install expo-notifications`; the app.json plugin. `projectId` is `Constants.easConfig?.projectId ?? Constants.expoConfig?.extra?.eas?.projectId`.
  - **`src/push-routing.ts`** has no dependencies and holds the tested decisions:
    - `parseTab`, whose unknown value is `All`; `TaskTab` moves here from `inbox.tsx`;
    - `shouldNavigate(phase, pathname)`;
    - `registrationDecision({projectId, executionEnvironment, permission, canAskAgain, warehouseId, onInbox})`, returning `skip | ask | register | unregister`.
  - **`src/push.ts`** makes the Expo calls through injected ports. It covers the `work` channel, permission, the token, PUT/DELETE, `setNotificationHandler` (`shouldShowBanner`, `shouldShowList` true; `shouldSetBadge` false), and the response handling (`useLastNotificationResponse` + `clearLastNotificationResponseAsync`, dedupe by identifier, a pending tab applied by the gate).
  - **The inbox** reads `tab` and a `tap` nonce from params. Its catalog effect depends on both. After a tap it calls `refreshCatalogSnapshot(lastWarehouseId)`, then re-reads the snapshot. When a tap arrives while the inbox is already open, it uses `router.setParams`.
  - **README:** remote pushes need a dev build (no Expo Go), an EAS `projectId`, FCM `google-services.json` and APNs.

## Tasks & Acceptance

**Execution:**
- [ ] BE: migration 0068, schema, probe, journal and snapshot.
- [ ] BE: tenancy `listPushTargets`, `getPushTargetsIn` and `clearPushTokenIn`; revoke clears the push columns; the registration routes, DTOs and `openapi.json`.
- [ ] BE: `PushEnqueueHandler`, `PushGateway` (both adapters), `PUSH_COPY`, `PUSH_ERROR_CLASS`, `NotificationsFacade.sendDuePushes`, `PushSenderWorker`.
- [ ] BE: `OutboundFacade.sweepCutoffRisk`, `WaveCutoffSweepWorker`.
- [ ] BE: `.env.example` gets `PUSH_GATEWAY`, `EXPO_ACCESS_TOKEN`, `PUSH_HTTP_TIMEOUT_MS`, `PUSH_SENDER_POLL_MS` and `WAVE_CUTOFF_SWEEP_POLL_MS`.
- [ ] BE tests:
  - every backend matrix row;
  - the gateway against a stubbed https server (batch of 100, ticket order, each error class);
  - `OWN_SCHEMA_NAMES` and write ownership;
  - the RLS probe count;
  - a test that the 9-2 projection still writes when the push handler is subscribed and the gateway is down.
- [ ] Mobile: `expo-notifications`, `push-routing.ts` with tests, `push.ts`, the gate's pending tab, the inbox param + nonce, the foreground permission check, the composition-test stubs, README.
- [ ] Meta docs:
  - Update:
    - `notifications.md` (queue/send);
    - `tenancy.md`;
    - `outbound.md` (sweep);
    - `API-SURFACE.md`;
    - `mobile/SYSTEM-DESIGN.md`, correcting "shared handheld" to the one-operator binding;
    - both repo contracts, `wms-be` and `wms-mobile`, the latter with the `data.tab` vocabulary.
  - Add to `PENDING.md`:
    - receipt polling;
    - a real assignment model;
    - mobile approvals;
    - putaway and scheduled-count pushes;
    - EAS/FCM/APNs setup;
    - `push_deliveries` retention.
  - Correct the stale counts:
    - `CLAUDE.md` ("65 deferred items and 33 open retro actions");
    - the `PENDING.md` header;
    - `SYSTEM-DESIGN.md` ("28 migrations").

**Acceptance Criteria:**
- Given an eligible handheld registered to WH-A, when a wave is released in WH-A and the row is relayed twice, then exactly one push of kind `new-work`, tab `Pick` is sent.
- Given the gateway returning 503, when an approval event is relayed, then the 9-2 panel entry is written and the outbox row is acked. The push is retried by the sender with backoff.
- Given a planned wave 45 minutes from cutoff, when the sweep runs twice, then one `wave.cutoff_at_risk` is emitted, and only `waves.manage` holders' handhelds are queued.
- Given no `PUSH_GATEWAY` and no EAS `projectId`, when the full BE suite, lint and typecheck run and the mobile tests and typecheck run, then they pass and no network call is made.

## Implementation Notes

## Spec Change Log

## Review Triage Log

Design review (2026-10-12), two lenses: backend (K) and mobile/API/tests (M).

| # | Lens | Finding | Verdict | Disposition |
|---|---|---|---|---|
| 1 | K | The ledger couldn't deliver one-per-(event, device): crash after send, a mid-batch 503, `failed` re-sent | high | Fixed: claim `sending` committed before the send; stale → `failed`; per-batch outcomes; only `pending` re-sent |
| 2 | K | Sending inside the relay stalls every tenant and can quarantine the shared approval rows | high, verified `outbox.ts:18,115-121`, `event-bus.ts:54-55` | Fixed: enqueue-only handler + `PushSenderWorker` |
| 3 | K, M | No re-enroll path; the same token on two rows/tenants means duplicates and a cross-tenant leak | high, verified `enrollment.command.ts:251-259` | Fixed: in-tenant clear on PUT; a send-time cross-tenant ownership read via `AUTH_DATABASE`; no cross-tenant writes |
| 4 | K | Wrong architecture claims; no seam for clearing a token | high, verified `architecture.spec.ts:1471-1478` | Fixed: `OWN_SCHEMA_NAMES`; tenancy functions; compare-and-clear |
| 5 | M | The permission prompt could fire on a task screen and steal wedge-scanner focus | high, verified `pick.tsx:148`, `adapters.tsx:12-24` | Fixed: prompt only on `/inbox`; silent refresh elsewhere |
| 6 | M | A tap-guard denylist was incomplete (`self-test`, `badge-in`, `revoked`) | high | Fixed: allowlist (`badged` + `/inbox`/`/health`) |
| 7 | M | A tap that launches the app was lost or overwritten by the gate | high, verified `index.tsx:16-21` | Fixed: last-response + pending tab applied by the gate; identifier dedupe; clear |
| 8 | M | The test plan breaks the composition test; no pure surface | high, verified `device-store-composition.test.ts:27-34` | Fixed: `push-routing.ts`; injected ports; stubs |
| 9 | M | There is no mobile `lint` script | high, verified `package.json`, `ci.yml` | Fixed: removed from the verification and ACs |
| 10 | K | Membership is underspecified (status, client, role) | medium, verified `tenancy.service.ts:163-187` | Fixed: the badge-in eligibility rule, re-checked at send |
| 11 | K, M | The PUT/DELETE guard: enrollment credential, revoke race, error names, the "one exception" doc | medium, verified `device-session.guard.ts:23-31` | Fixed |
| 12 | K | Scheduled count ticks would flood devices | medium, verified `count.command.ts:1865-1877` | Fixed: on-demand + recount only |
| 13 | K | Deploy backlog and replays send stale pushes | medium | Fixed: a 30-min staleness ack; at-risk acked after cutoff; `ttl` |
| 14 | K | Expo error mapping too coarse; the error message leaks the token | medium | Fixed: `PUSH_ERROR_CLASS`; codes only |
| 15 | K | Sweep mis-specified: a fixed IST zone, helpers, AUTH discovery, facade | medium, verified `wave.command.ts:84,1464`, `time.ts:21` | Fixed |
| 16 | M | No Android channel or priority | medium | Fixed: the `work` channel before the prompt; `channelId`, `priority`, `ttl`; `shouldShowBanner` |
| 17 | M | Expo Go / dev build / FCM not stated | medium | Fixed: skip in Expo Go; the `easConfig` lookup; README + PENDING |
| 18 | M | No warehouse on a new device | medium, verified `device-store.ts:184-187` | Fixed: skip until `lastWarehouseId` |
| 19 | M | The inbox tab param: same-tab, already-open, refreshed snapshot never re-read | medium, verified `inbox.tsx:48,77-116` | Fixed: param + nonce; re-read after refresh |
| 20 | M | DELETE trigger undefined; permission revocation is undetectable server-side | medium | Fixed: foreground permission check; `canAskAgain` |
| 21 | K | Migration: NOT NULL, a `gateway` CHECK, probe shapes, retention | low | Fixed; retention → PENDING |
| 22 | M | Matrix gaps: cutoff boundaries, launch tap, revoked PUT, Expo Go | low | Fixed |
| 23 | K | Verified: `wave.released` carries the warehouse; transfer `destWarehouseId`; `SOURCE_AUDIENCE` covers the approvals; relay advisory lock | — | No change; "add warehouseId" task dropped |

## Design Notes

- **Why per-device:** the badge-in binding makes a device and its operator one-to-one today, and a token belongs to a device. If devices become shared, `listPushTargets` is the one place to change.
- **Why queue-then-send:** the relay is one serial loop for every tenant, and it quarantines a row after five throws. A third-party outage must not be able to delay invoicing or erase panel entries.
- **Why at-most-once on a crash:** a duplicate "New work ready" is noise. A missed one is recovered the next time the operator opens the inbox.
- **Why at-risk has no resolve:** a push can't be withdrawn, and the web's amber chip shows the live state.
- **Why approvals are heads-up only:** decisions live on the web, where 9-2's panel links to them.

## Verification

**Commands:**
- `cd workspace/core/backend/wms-be && bun run test && bun run lint && bun run typecheck`: everything passes. Use jest, one invocation at a time.
- `cd workspace/core/backend/wms-be && bun run db:generate`: reports "No schema changes"; a fresh migrate and `db:verify` both pass.
- `cd workspace/core/mobile/wms-mobile && bun test && bun run typecheck`: everything passes.
