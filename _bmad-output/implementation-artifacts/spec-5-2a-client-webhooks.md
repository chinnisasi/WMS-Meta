---
title: '5-2a client webhooks — signed, SSRF-guarded, at-least-once HTTPS webhooks per client on receipt and dispatch, with a delivery log, redelivery, secret rotation and auto-disable'
type: 'feature'
created: '2026-10-23'
status: 'ready-for-dev'
route: 'dispatch'
review_loop_iteration: 0
context:
  - 'docs/initiatives/production-readiness.md'
  - 'docs/design/SYSTEM-DESIGN.md'
  - 'docs/design/IMPLEMENTATION-GUIDE.md'
  - 'docs/design/API-SURFACE.md'
  - 'docs/design/PENDING.md'
  - 'docs/design/DEPLOY.md'
  - 'docs/design/modules/clients.md'
  - 'docs/design/modules/notifications.md'
  - 'docs/design/modules/inbound.md'
  - 'docs/design/modules/outbound.md'
  - 'docs/design/frontend/SYSTEM-DESIGN.md'
  - '_bmad-output/implementation-artifacts/spec-5-1a-email-service-and-invite-emails.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** A client brand learns that its goods were received or its order shipped only by polling the portal or asking the warehouse. Its own systems (an ERP, a storefront, an OMS) cannot react. The roadmap row 5.2 ★ asks for outbound webhooks and email on receipt and dispatch, plus tracking in the portal. Today nothing pushes to a client: the only outbound HTTP is channel writeback to Shopify (`channels/channel-http.ts:91`), there is no SSRF guard anywhere in `src`, and the two source events have no client-facing consumer (`grn.recorded`, `receiving.command.ts:2013`, has no subscriber at all; `order.dispatched`, `dispatch.command.ts:478`, feeds only invoicing `invoicing/delivery.ts:53` and channel writeback `channels/channel-writeback.delivery.ts:221`).

**Approach:**
- A new module, **`client-webhooks`**, owning three tables: endpoints, events and deliveries.
- **Staff configure endpoints per client** in Settings → Clients: an HTTPS URL, the event types it subscribes to, and a server-generated signing secret that is shown once.
- **An outbox subscriber** turns `grn.recorded` and `order.dispatched` into one frozen, versioned, minimised **webhook event** per client, with one **delivery** row per subscribed active endpoint. It makes no network call.
- **A sender worker** (the 9-2b push pattern) signs and POSTs each delivery through a **guarded HTTPS transport**.
  - It retries with backoff; delivery is at-least-once.
  - It auto-disables an endpoint that keeps failing and raises an owner panel entry.
- Staff see a **delivery log** and can redeliver.

**Decisions (recommended, taken autonomously under the user's standing instruction, 2026-10-23):**
1. **Split by user goal.**
   - **5-2a** is webhooks: system-to-system integration, the highest value for a multi-client 3PL, and it needs no unmerged mailer.
   - **5-2b** is email on receipt and dispatch to the client's `operations` contacts, through 5-1a's queue. It needs WMS-BE #125 merged and a digest decision for D2C volume.
   - **5-2c** is portal tracking: dispatch carrier and tracking on portal orders, a portal receipt list, and a read-only portal view of the client's webhooks.
   - Portal self-service management of endpoints waits for 5.4's client-admin role.
   - More event types (packed, manifested, delivered/POD once 4.9 emits one, ASN) are their own entry.
   - All four are in deferred-work.
2. **Who configures.** Staff only, behind the existing **`clients.manage`** (owner-only, `permissions.ts:222`), on the client's behalf. Webhook endpoints are part of the client's master configuration, beside contacts.
   - The portal has a single `client` role, so a client admin does not exist yet (`ROLE_CAPABILITIES.client` = `asn.announce`, `orders.place`, `permissions.ts:455`).
   - No new capability, so there is no FE mirror churn.
   - Reads (endpoints, deliveries, bodies) are also `clients.manage`, because URLs and payloads are integration detail.
3. **Event types and naming.**
   - The public vocabulary is `WEBHOOK_EVENT_TYPES = ['receipt.recorded', 'order.dispatched']`, plus the non-subscribable `webhook.test`.
   - It is "recorded", not "completed": one GRN is one receipt, and a PO may stay open across several.
   - `receipt.recorded` is sourced from `grn.recorded`; `order.dispatched` from `order.dispatched`. Nothing else feeds them.
4. **The envelope** (`schemaVersion: 1`, frozen at enqueue, stored as the exact bytes sent): `{id, type, schemaVersion, occurredAt, createdAt, client: {code}, data}`.
   - `id` is the webhook event's uuidv7. It is stable across retries and redeliveries, so it is the consumer's dedupe key.
   - `occurredAt` is the source event's `occurredAt`; `createdAt` is the enqueue time.
   - A breaking change means `schemaVersion: 2`. Fields may be added within v1 and are never renamed or removed.
5. **Payload minimisation (an allowlist, built key by key).**
   - `receipt.recorded` data: `{receiptId, grnCode, warehouseCode, purchaseOrderCode | null, asnCode | null, recordedAt, lines[{skuCode, skuName, uom, batchCode | null, qty, appliedQty, excessQty, damagedQty?, shortQty?}]}`.
     - Line fields keep the GRN snapshot's names and meanings verbatim (`receiving.command.ts:1971-1990`), in base units.
     - Excluded: no device, operator, review-op, rejected or unmatched lines, and no internal SKU or line ids.
   - `order.dispatched` data: `{orderId, clientOrderRef | null, channelRef | null (externalEventId), warehouseCode, dispatchedAt, carrierName | null, trackingNumber | null, totalUnits, lines[{skuCode, skuName, orderedQty, dispatchedQty, shortfallQty}]}`.
     - Excluded: no consignee name, address, phone or GSTIN, no `dispatchedBy`, and no reservation or ledger ids.
   - A body over 512 KiB drops `lines` and carries `linesOmitted: true, lineCount: N`.
6. **Where the client comes from (no emitter changes).**
   - For a receipt: `goodsReceipt.clientId`. A receipt without one (an older build's mixed-client blind receipt, `receiving.command.ts:1290-1291`) produces no webhook; it is logged and acked.
   - For a dispatch: the payload carries no `clientId` (`dispatch.command.ts:452-471`). The subscriber reads it through a new `OutboundFacade.orderClientIdsInTx`.
   - SKU labels come through a new `CatalogFacade.skuLabelsInTx`, PO codes through a new `InboundFacade.poCodesByIdsInTx` (beside `grnCodesByIdsInTx`, `inbound.facade.ts:480`), and the warehouse code through tenancy's `getWarehouseCodeInTx` (`tenancy.service.ts:136`). The client code comes from `getClientsInTx` (`clients.facade.ts:545`).
7. **Existing consumers are untouched — the proof.**
   - No emitter file changes. `receiving.command.ts` and `dispatch.command.ts` keep their bytes, and only facade files gain the three reads.
   - The subscriber registers in **`onApplicationBootstrap`**. Every existing handler subscribes in `onModuleInit` (`invoicing/delivery.ts:52`, `channel-writeback.delivery.ts:55`, the notifications pair). Because the bus runs handlers in subscription order (`event-bus.ts:48-56`), the webhook handler is always last, and a throw from it cannot stop invoicing or writeback on that attempt.
   - The handler acks data faults (log only) and rethrows only on database errors. A rethrow re-delivers the row to the earlier handlers, which are idempotent by contract (AD-5, `event-bus.ts:38-40`), exactly as any handler's throw does today.
   - Pins:
     - a test reads the bus's handler list for both types and asserts the webhook handler is last;
     - with the enqueue mocked to reject, the dispatch still issues its invoice and the outbox row re-drains;
     - a golden of the `order.dispatched` and `grn.recorded` outbox payloads is unchanged.
8. **Idempotent fan-out.**
   - One webhook event per source event: a partial unique index on `(tenant_id, source_event_id)`, where the source event id is the outbox row id (`outbox.ts:211`).
   - One delivery per (event, endpoint): unique, `ON CONFLICT DO NOTHING`.
   - The endpoints a delivery goes to are those `active` and subscribed at enqueue time. An endpoint created later never receives earlier events, and there is no backfill at deploy.
9. **Signing follows the Standard Webhooks scheme**, so receivers can verify with off-the-shelf libraries.
   - Headers: `webhook-id` (the event id), `webhook-timestamp` (unix seconds, set per attempt), and `webhook-signature: v1,<base64 HMAC-SHA256(secret, "{id}.{timestamp}.{body}")>`.
   - `content-type: application/json` and `user-agent: WMS-Webhooks/1`.
   - The secret is `whsec_` + base64 of 32 random bytes.
   - Receivers are told to refuse a timestamp more than 5 minutes off; that is the replay window. The docs and the panel's "How to verify" text say so.
10. **Secrets.**
    - The secret is sealed at rest with 5-1a's shared `src/shared/crypto/seal.ts` (`seal(keyring, plaintext, aad)`, kid plus `_PREVIOUS` rotation), under a new `WEBHOOK_SEAL_KEY` (≥ 32 characters) with AAD `tenantId:endpointId`. Its only reader is `webhook-secrets.ts`, pinned.
    - The secret is shown **once**, in the create and rotate responses. The stored idempotency snapshot omits it, so a replay answers `signingSecret: null` and a lost secret is recovered by rotating. This is the 5-1a B6 lesson: no raw secret in `idempotency_keys`.
    - A `secret_hint` (the last 4 characters) is stored for display.
    - **Rotation** keeps the previous secret for 24 h. Deliveries in that window carry two signatures (`v1,<new> v1,<old>`).
    - The secret never appears in logs, the outbox, audit `changes` or any read.
11. **SSRF protection, fail-closed** (`webhook-http.ts`, the only file that opens a socket to a client URL).
    - **At save:** a WHATWG-parsed URL with:
      - `https:` only;
      - no userinfo and no fragment;
      - a host that is a DNS name with a dot, not an IP literal, not `localhost`, and not ending in `.local`, `.localhost`, `.internal` or `.home.arpa`;
      - port 443 or 1024–65535;
      - at most 2048 characters.
      
      It is stored normalised (lower-case host, default port stripped).
    - **At every send:** `https.request` uses a custom `lookup` that resolves all addresses and refuses if **any** is outside the allowlist:
      - IPv4 public unicast, so not 0/8, 10/8, 100.64/10, 127/8, 169.254/16, 172.16/12, 192.0.0/24, 192.0.2/24, 192.168/16, 198.18/15, 198.51.100/24, 203.0.113/24, 224/4 or 240/4;
      - IPv6 inside `2000::/3` but not `2001:db8::/32`, `2002::/16` or `2001::/32`. Mapped, NAT64, ULA, link-local and loopback all fall outside, so they are refused.
      
      The validated address is the one connected to, so it is DNS-rebinding safe. TLS SNI and certificate checks still use the hostname.
    - **Transport rules:** `agent: false`; redirects are never followed (a 3xx is the failure `redirect`); proxy env vars are ignored; a total timeout of `WEBHOOK_HTTP_TIMEOUT_MS` (default 10 s, max 30 s); at most 4 KiB of the response is read, then the socket is destroyed.
    - **Outcome:** a refusal is the permanent failure `target-blocked`.
12. **Delivery (at-least-once, unordered).**
    - **Statuses:** `pending → sending → succeeded | failed`.
    - **Success** is any 2xx.
    - **Failures:** any other status, a transport error, `timeout`, `tls` or `dns-failed` is retried with full-jitter backoff `min(2^(n−1)·60 s, 6 h)`, up to 8 attempts. `Retry-After` on a 429 or 503 is honoured, up to 1 h.
    - **Permanent failure:** `target-blocked` fails at once.
    - **Expiry:** a pending delivery older than 72 h fails `expired`.
    - **Stale sends:** a `sending` row older than 5 min (the worker died mid-send) returns to `pending`, with the attempt counted as `stale`. It may be re-sent; the receiver dedupes on `webhook-id`.
    - **No ordering guarantee:** each event is a self-contained snapshot carrying `occurredAt`. There are at most 2 in flight per endpoint per tick.
13. **Auto-disable.**
    - Every failed attempt increments the endpoint's `consecutive_failures` and sets `failing_since` if unset; any 2xx resets both.
    - At ≥ 10 consecutive failures spanning ≥ 24 h, the endpoint becomes `disabled`, with reason `failing` and a new `disabled_episode_id`. Its pending deliveries fail `endpoint-disabled`.
    - It is audited (`SYSTEM_ACTOR_ID`) and appends `webhook_endpoint.disabled`.
    - The notifications module projects that as a new panel source, `webhook-disabled` (audience `clients.manage`, owner only). It is resolved by `webhook_endpoint.enabled` (resolution `re-enabled`) or `webhook_endpoint.deleted` (`deleted`).
    - A manual disable raises nothing.
14. **Commands** (`ClientWebhooksCommand`). Every one is keyed, audited, owner-only and staff-only; target type `webhook_endpoint` (new in `AUDIT_TARGET_TYPES`).
    - **create:** ≤ 5 endpoints per client, else 409 `webhook-endpoint-limit`; a URL duplicated per client is 409 `duplicate-webhook-url`; a departed client is 409 `client-departed` via `assertClientTakesWorkInTx`.
    - **update:** `{url?, description?, eventTypes?, status?}`.
      - `status: 'disabled'` sets reason `manual`.
      - `'active'` clears the reason, the episode and the counters, and appends `.enabled`.
      - An unchanged edit is a no-op that stores the key (`clientWebhooks.update:unchanged` in `AUDIT_NO_OP_ARMS`): a status is not idempotent in value (the 21-10 rule).
    - **delete:** removes the endpoint and its deliveries, and appends `.deleted`.
    - **rotate-secret.**
    - **test:** enqueues one `webhook.test` event (data `{endpointId}`) to this endpoint only; 409 `webhook-endpoint-disabled` when the endpoint is not active.
    - **redeliver:** a final delivery (`failed` or `succeeded`) goes back to `pending`, with attempts set to 0 and `redelivery_count + 1`. It sends the same bytes with a fresh timestamp and signature. A non-final one is 409 `delivery-in-progress`.
    - **Guard order** (the §1 skeleton):
      1. shape checks above the transaction (URL rules and the event-type vocabulary, 400 `validation-failed` naming the rule);
      2. the hash;
      3. `clients.manage`;
      4. replay;
      5. `lockClientInTx` (404; `FOR NO KEY UPDATE`, the contacts lock);
      6. replay again under the lock;
      7. the endpoint by (tenant, client, id) (404 — an unknown id and another client's id are the same 404);
      8. the guards;
      9. the write;
      10. outbox;
      11. audit;
      12. the key.
    - **Fingerprints** start `{arm: '<verb>', tenantId, clientId, …}`, with `eventTypes` sorted and the URL normalised.
15. **Env and ops.**
    - **The port:** `WEBHOOK_GATEWAY` = `off` (default; the sender claims nothing and rows stay pending until they expire) | `https`. `https` fails the boot without a valid `WEBHOOK_SEAL_KEY`. Create and rotate answer 409 `webhooks-unavailable` when the key is unset.
    - **The worker:** `WEBHOOK_SEND_POLL_MS` (5000 recommended), `WEBHOOK_MAX_PER_TICK` (default 50), `WEBHOOK_HTTP_TIMEOUT_MS`.
    - **Discovery:** due tenants are discovered on `AUTH_DATABASE`.
    - **Where they are documented:** `.env.example`, the README and DEPLOY §2.
    - **Egress** is ECS through NAT (6-2b). The guard is what stops a client URL reaching the VPC, RDS, Valkey or the task metadata endpoint `169.254.170.2`.
16. **Retention.** Final deliveries are purged after 30 days, and events with no deliveries left after 30 days, through a discovery arm of their own so idle tenants are purged too. The audit rows are the durable record. No response body is stored: status code, duration and a bounded error code only.
17. **Web** (Settings → Clients, `clients-card.tsx` panels, beside Contacts):
    - A **Webhooks** panel, `canManage` only, listing endpoints: URL, events, status ("Active", "Disabled — by staff", "Disabled — failing since {IST}"), the last success, and `whsec_…{hint}`.
    - Add and edit, with a one-time secret dialog (copy, "You won't see this again — rotate to get a new one").
    - Rotate, Send test, Enable/Disable, and Delete with an inline confirm.
    - A deliveries drawer: status, attempts, last code or HTTP status, time, payload view, and Redeliver.
    - A "How to verify" block (the Standard Webhooks steps and the 5-minute window).
    - The panel source gets a label and the link `/settings?tab=clients`.
    - The client is regenerated.
18. **Mobile.** Unchanged.

</frozen-after-approval>

## Design Review Amendments

These come from the design review on 2026-10-23: a claims check (K1–K20, against origin/main, the 5-1a and 6-2c branches, and Bun/Node experiments) and a blind review (B1–B24). They are recommended and taken autonomously. **Where an amendment differs from the frozen Intent or from the Boundaries and Matrix below, the amendment wins.**

**A1. Events are keyed by subject, with a reconcile arm (K1/B18). Supersedes decision 8's key.**
- **The key.** `webhook_events` is unique on `(tenant_id, event_type, subject_id)`, where `subject_id` is the GRN id or the order id. It replaces `source_event_id`; `webhook.test` events no longer exist (A4).
- **Why.** An earlier handler that throws five times quarantines the outbox row, and the webhook handler never ran for it. The relay deletes acked rows (`outbox.ts:234`) and keeps quarantined ones.
- **The reconcile arm.** Each sender tick, per due tenant, reads quarantined `grn.recorded` and `order.dispatched` outbox rows less than 72 h old, through a new read-only seam `quarantinedMessagesInTx(tx, tenantId, types, since)` in `shared/events/outbox.ts`. Only clients with an active endpoint count. It feeds them to the same enqueue function; the subject unique makes this idempotent. An operator replay of the row (`OUTBOX_OPERATOR_REPLAY_SQL`) then dedupes too.
- **Deviation from the ask (rescan orders and GRNs from their tables).** A rescan needs a second payload builder from tables, because the dispatch's carrier and tracking live only in the ledger `reference_doc` (deferred-work, the 4.6 entry). An acked row was, by definition, seen by every handler. A quarantined row is therefore the only way an event goes missing, so the quarantine read is exact.
- **Quarantine visibility.** The relay logs every quarantine as one structured `error` line, `outbox.quarantined type=… tenant=… event=…`, which 6.3's log alerting picks up. A panel source for it needs the relay to append to the outbox it drains, so it is PENDING.
- **Pin.** An earlier `order.dispatched` subscriber is mocked to throw ×5. The row quarantines, the reconcile tick enqueues exactly one event, and a later operator replay adds none.

**A2. Retry schedule, the expiry clock, bulk redeliver and purge (K2/B1/B9). Supersedes decisions 12 and 16 where they differ.**
- **Schedule.** Retries run at 1 m, 5 m, 30 m, 2 h, 6 h, 12 h, 24 h and 24 h after successive attempts: **9 attempts**, the last about 68.6 h after the first, inside the 72 h expiry. Each wait gets 0 to −10 % jitter (never later, so the schedule stays inside the expiry). A `Retry-After` on a 429 or 503 replaces the wait when it is longer, capped at 24 h.
- **Expiry clock.** A new column, `pending_since` (NOT NULL), is set on insert and reset by a redeliver, a bulk redeliver, a held release and a stale return. Expiry is `pending_since` + 72 h → `failed expired`.
- **Bulk redeliver.** `POST …/{e}/deliveries/redeliver {since, statuses: ['failed','expired']}` resets at most 1000 rows, oldest first, and answers `{redelivered, remaining}`. It is keyed and audited (`webhook_endpoint.bulk_redelivered`, `changes` = since, statuses and count), refused on a non-active endpoint, and declared before `deliveries/:deliveryId` (§6).
- **Purge clock.** Final rows are purged once `coalesce(succeeded_at, last_attempt_at, created_at)` is older than 30 days. Events are purged once they have no deliveries left and are older than 30 days.
- **A purged delivery.** Redeliver or read of a missing delivery whose uuidv7 timestamp is older than 30 days answers **410 `delivery-purged`**. Any other missing id is 404.

**A3. Concurrency and fairness (K3/B3/B4). Supersedes decision 12's "≤ 2 per endpoint per tick".**
- **Limits.** Global send concurrency is 8 per process (`WEBHOOK_SEND_CONCURRENCY`). The tick budget is 60 s of wall clock: after it no new send starts, and claimed rows not yet started return to `pending` with no attempt spent, in a final transaction.
- **The claim SQL** enforces at most **2 `sending` rows per endpoint across ticks**: a window `row_number() over (partition by endpoint_id order by next_attempt_at, id)` plus the endpoint's live `sending` count, ≤ 2. It interleaves endpoints round-robin.
- **Tenant window.** Tenants are visited through a rotating window (IMPLEMENTATION-GUIDE §8's head-only-slice lesson).
- **Stale bound.** `WEBHOOK_STALE_MS` is fixed at 300 s and asserted at boot to be ≥ 2 × `WEBHOOK_HTTP_TIMEOUT_MS` and > the tick budget.
- **Stale returns.** A stale return counts as an attempt (code `stale`) but **not** as a failure toward auto-disable.
- **Pin.** A fairness test: one endpoint's fake port hangs until timeout, and another tenant's delivery succeeds within one poll.

**A4. The endpoint lifecycle at claim and in commands (K4/B20/B21/K16). Supersedes decision 14's delete and test, and decision 15's `off`.**
- **Re-read at claim.** Every claim re-reads the endpoint and the client:
  - deleted → `failed endpoint-deleted`;
  - disabled → `failed endpoint-disabled`, except reason `failing` (A5);
  - event type no longer subscribed → `failed unsubscribed`;
  - client departed → `failed client-departed`.
- **URL change.** It resets the counters and `failing_since`. Pending rows simply go to the new URL, which is read at send.
- **Narrowing event types.** Pending and held rows of a dropped type become `failed unsubscribed` in the same transaction.
- **Soft delete.** Delete sets `status = 'deleted'` and `deleted_at`. The row and its deliveries stay readable until the 30-day retention arm removes them; delete always succeeds.
- **Client departure.** The clients module emits no event on a status change (`clients.md` §Suspension: "No outbox event"). So the webhooks module handles departure **lazily**: enqueue skips departed clients (`departedClientIdsInTx`), and the claim auto-disables the endpoint with reason `client-departed` (system actor, no panel entry). A reactivated client's endpoint stays disabled until staff enable it.
- **The `self` client** (system-owned) may not have endpoints: 400 `validation-failed`, "The warehouse's own client cannot have webhooks." This follows the portal-invite precedent.
- **Redeliver refusals.** A single or bulk redeliver to a non-active endpoint answers 409 `webhook-endpoint-disabled`.
- **Test is a synchronous guarded send** from the API process.
  - It sends the `webhook.test` envelope (`data {endpointId}`, a fresh uuidv7 id) and answers `{statusCode | null, errorCode | null, durationMs}`.
  - It is allowed on a disabled endpoint, so staff can check a fix before enabling. It never touches the counters, stores no event or delivery, and is audited `webhook_endpoint.test_sent` (`changes` = the outcome codes).
  - Because of this, the API task also needs egress and the A14 egress deny.
- **`WEBHOOK_GATEWAY=off`.** The sweep (expiry, purge, reconcile, departure) still runs; sends do not.
  - **Placement deviation from K7:** `WEBHOOK_GATEWAY` is read on the API **and** the worker. The API reads it only for the warning, because it cannot see the worker's env otherwise.
  - With `off`, the create, update and test responses carry `warnings: ['webhooks-unavailable']`, and the panel shows the banner "Deliveries are paused on this server." Test is refused with 409 `webhooks-unavailable`.
  - The key-missing refusal (decision 15) is unchanged.

**A5. Hold while failing (B2). Supersedes decision 13's "pending deliveries fail".**
- **New status `held`.** When an endpoint is auto-disabled for `failing`, its pending rows become `held`, and new events still create deliveries in `held`.
- **Cap.** At most 10,000 held rows per endpoint; past that the oldest is failed `held-overflow`. A held row older than 30 days is failed `held-expired`.
- **Re-enable.** `PATCH {status: 'active', held: 'release' | 'discard'}`. `held` is required when held rows exist (409 `held-decision-required`). `release` → `pending` with a new `pending_since`; `discard` → `failed discarded`. Both are audited in `changes`.
- **Manual disable and `gone` do not hold.** Those rows fail `endpoint-disabled`.

**A6. Kit parent lines are dropped (K5).** Verified: the dispatch snapshot has one line per `order_lines` row (`dispatch.command.ts:325-329`, 354-405), kit parents included. A kit parent carries no picks, so it reads `dispatchedQty 0` and a full shortfall. The enqueue drops the parents through a new `OutboundFacade.kitParentLineIdsInTx(tx, tenantId, orderLineIds)` (a line with children, `order_lines.parent_line_id`, `schema.ts:3040`). The components remain. A golden pins it.

**A7. Signature details (K6/B6). Amends decision 9.**
- **The key** is the base64-decoded bytes after `whsec_`, not the string.
- **Multiple signatures** are space-separated `v1,<sig>` entries, and receivers accept any match.
- **Reference vector**, frozen in `webhook-signature.spec.ts`: secret `whsec_MfKQ9r8GKYqrTwjUPD8ILPZIo2LaLaSw`, id `msg_p5jXN8AQM9LWM0D4loKWxJek`, timestamp `1614265330`, body `{"test": 2432232314}` → `v1,g0hM9SsE+OTPJTGt/tmIKtSyZlE3uFJELVlNIOLJ1OE=`. I verified this with `node:crypto` on 2026-10-23.
- **Library check.** The same headers and body also verify with the `standardwebhooks` npm package, added as a pinned devDependency.

**A8. 6-2c conditionals (K7).** I verified these on `origin/feat/6-2c-runtime-hardening`: `JOB_POLL_VARIABLES` (`process-role.ts:45`), `WORKER_JOBS` (`worker-heartbeat.ts:38`), `InFlightTick.track(job, pollMs, noProgressMs)` (`shutdown.ts:103`), `beat()` and `ConfigRefusal`.
- **If 6-2c merges first:**
  - add `WEBHOOK_SEND_POLL_MS` to `JOB_POLL_VARIABLES` and `webhook-sender` to `WORKER_JOBS`;
  - call `track`, and `beat()` once per completed send;
  - set a no-progress bound above the 60 s tick budget (120 s);
  - throw `ConfigRefusal` for poll parsing and for `https`-without-key.
- **Otherwise** use main's shape and note it for 6-2c's rebase.
- **Env placement:** `WEBHOOK_SEAL_KEY` on API and worker; `WEBHOOK_GATEWAY` on API and worker (A4's deviation, where only the worker's value controls sending); the rest worker only.

**A9. The notifications CHECK is re-added `NOT VALID` (K8). Amends the Boundaries' notifications item.**
- `notifications_source_type_check` is re-added `NOT VALID`. The new list is a superset, so existing rows still pass; that holds by construction, and the §4 assertion pins it.
- `VALIDATE CONSTRAINT` goes in a later migration (PENDING deploy).
- The probe still proves that a new insert of an unknown type is refused, since `NOT VALID` constraints check new rows.

**A10. Resolve events carry the episode (K9). Amends decision 13.**
- `webhook_endpoint.enabled`, `.deleted` and the new `.manually_disabled` each carry `{endpointId, clientId, episodeId | null}`. `episodeId` is the pre-clear `disabled_episode_id`.
- A failing (or gone) → manual transition emits `.manually_disabled`, resolution `manually-disabled`.
- The notifications decoder acks a resolve with `episodeId: null` silently: no tombstone, no log.
- `SOURCE_RESOLUTIONS['webhook-disabled']` = `re-enabled | deleted | manually-disabled`, pinned to the emitter's tuple.
- The raise `webhook_endpoint.disabled` is emitted for reasons `failing` and `gone` only.

**A11. When the handler rethrows (K10). Amends decision 7.** The enqueue rethrows only on a connection or serialization error: SQLSTATE class `08`, `40001` or `40P01`, or a pool/connect error. Everything else is logged and acked, data faults included. Design Notes record the cost of a rethrow.

**A12. Counters are atomic and count final failures (K11/B22). Supersedes decision 13's threshold.**
- **Atomic SQL.** The outcome write uses `SET consecutive_failures = consecutive_failures + 1, failing_since = coalesce(failing_since, now())`, and the reset uses `= 0, failing_since = NULL`, each `WHERE status = 'active'`.
- **What counts.** Only a delivery's **final** failure counts: the 9th attempt, a permanent code (A18), or `expired`. Retries, stale returns and `target-blocked` do not.
- **Threshold.** ≥ 10 consecutive final failures with `failing_since` ≥ 24 h ago.
- **Decided under a lock.** The auto-disable decision runs under `FOR UPDATE` on the endpoint row. Lock order is the client, then the endpoint; the sender takes only the endpoint, and nothing locks an endpoint before its client.
- **Pin.** A success and a failure outcome are written in both orders against one endpoint, with no CHECK violation and a correct final state.

**A13. Transport mechanics (K12). Amends decision 11.**
- The `lookup` override answers both the single-address and `{all: true}` call shapes, and refuses if **any** resolved address fails.
- `autoSelectFamily: false`.
- On `socket` `connect`, `socket.remoteAddress` must be in the validated set, else the socket is destroyed (`target-blocked`) before TLS bytes.
- jest runs on Node, but production runs Bun. So a Bun-run smoke, `scripts/webhook-transport-smoke.ts`, joins CI's image smoke (6-2c precedent). It proves the pinned-IP connect, the private-address refusal and the redirect refusal under Bun.

**A14. Address and host rules (K13/B11). Amends decision 11.**
- **More IPv4 and IPv6 denials:** `192.88.99.0/24`, `2001::/23` (replacing the narrower `2001::/32`) and `3fff::/20`.
- **At save:**
  - one trailing dot is stripped;
  - after WHATWG parsing, a host that is all digits, hex or dotted-numeric is refused, so `2130706433`, `0x7f.1` and `127.1` are refused, and `localhost.` is refused after the strip;
  - hosts in `WEBHOOK_DENY_HOSTS` (the deployment's own API and web hostnames, from the env) are refused at save and at send.
- **`WEBHOOK_DENY_CIDRS`** is optional and adds to the denylist.
- **NAT64/DNS64.** `64:ff9b::/96` is outside `2000::/3`, so it is refused; a DNS64 resolver could otherwise hand back an embedded private IPv4. This is documented.
- **The infra ask (6-2d, deferred-work).** An SG/NACL egress deny on the API and worker tasks for the VPC CIDR, `169.254.0.0/16` and `fd00:ec2::/32`, as the second layer.

**A15. TLS posture (B12).**
- `rejectUnauthorized: true` always, with no opt-out.
- `minVersion: 'TLSv1.2'`; the system CA store; no client certificate (mTLS is PENDING).
- SNI and certificate checks use the hostname while the IP is pinned.
- **Pin.** A mismatched or self-signed certificate gives `tls-cert` and no request body is written.

**A16. Stable egress IPs (B13).** The 6-2d ask also covers stable NAT EIPs, published in DEPLOY §2 and shown in the panel's "How to verify" block for receiver allowlists. The runbook says that changing them needs client notice.

**A17. Rotation (K14/B7). Amends decision 10.**
- **`POST …/rotate-secret {revokePrevious?: boolean}`.** `true` means no overlap, and is audited distinctly as `webhook_endpoint.secret_revoked`.
- **A second rotation within 24 h** drops the oldest previous secret; the UI warns.
- **Signing.** Sends always sign with the current secret, plus the previous one during its overlap.
- **Re-seal.** `bun run webhooks:reseal` re-seals every secret under the current `WEBHOOK_SEAL_KEY`, so `WEBHOOK_SEAL_KEY_PREVIOUS` can be retired. It has a runbook in DEPLOY.
- **An unopenable secret at send** is a **config** fault: code `secret-unavailable`, no attempt spent, a retry after 60 s, logged once per tick, never counted toward auto-disable. Its rows expire on the normal clock.

**A18. The outcome fate table (B5). Supersedes decision 12's classification.**

| Outcome | Fate | Counts toward auto-disable |
|---|---|---|
| 2xx | `succeeded` | resets |
| 408, 429, 5xx | retry (A2) | when final |
| network, timeout, `dns-failed`, `tls-handshake` | retry | when final |
| `tls-cert` (an invalid or mismatched certificate) | retry (the receiver may be mid-renewal) | when final |
| 3xx (`redirect`), 400, 401, 403, 404, 413, other 4xx | `failed` at once with `http-<code>` | yes |
| 410 | `failed http-410`; the endpoint is auto-disabled **at once**, reason `gone` (in the CHECK) | — |
| `target-blocked` | retry | **never** |
| `secret-unavailable` | config (A17) | never |

**A19. Secret handoff (B8).** Staff hand the secret to the client out of band, and staff attest that the client owns the URL; the create form carries the checkbox "The client asked for this URL". This is accepted. PENDING: a secure handoff (5.4 client admin, or a single-use reveal link).

**A20. Rate limits (B10).** Single redeliver, bulk redeliver and test are limited to 10 per minute per endpoint (a Valkey counter; the 6-1a `rate-limited` precedent). Past the limit they answer 429 `rate-limited` with `retryAfterSeconds`.

**A21. Schema version per endpoint (B14).**
- `webhook_endpoints.schema_version smallint NOT NULL DEFAULT 1`, with CHECK `IN (1)`. A future v2 widens it.
- The envelope's `schemaVersion` is the endpoint's own, so the body is built per version; v1 only today.
- The docs tell receivers to ignore unknown fields and event types.

**A22. Quantities are decimal strings (B15). Amends decision 5.**
- Every quantity is a decimal **string** at the SKU UoM's precision: `"12.500"` for `kg` at 3, `"4"` for `pcs`. It is formatted from milli-units, never from a float.
- `uom` on every line is the SKU's **base** UoM, so dispatch lines gain `uom` through `skuLabelsInTx`.
- **Pin.** A golden with a fractional catch-weight line.

**A23. Dispatch semantics (B16). Amends decision 5.**
- **One dispatch per order** is verified: dispatch requires `ready_to_dispatch` (`dispatch.command.ts:262-266`), the write is conditional on it (`:306`, "an order dispatches once", `:316`), and nothing sets an order back to it except pack (`pack.command.ts:595`, from `accepted`). So `orderId` identifies the dispatch and no `dispatchId` is added.
- **`channelRef`** is renamed `channelOrderRef`: `orders.external_event_id`, the sales channel's order reference, null for staff and portal orders.
- **Corrections and reversals are not emitted in v1**: a later receipt adjustment, an over-receipt approval or a return. This is documented.
- **Ordering guidance:** events are independent facts. Order by `occurredAt` and join on entity ids.

**A24. Body limit and receipt semantics (B17/K15). Amends decision 5.**
- **One limit.** `WEBHOOK_BODY_MAX_BYTES = 262144` (256 KiB) is one constant, used by the builder and written into the CHECK; a test pins the two equal.
- **Omitted lines.** With `linesOmitted: true`, staff can **download the stored body** from the delivery drawer (`GET …/deliveries/{d}` already returns it). A client pull endpoint for the lines is PENDING.
- **What `receipt.recorded` means.** One GRN was recorded. `qty` is the good units received on the line, `appliedQty` the part credited to the document, `excessQty` the part awaiting over-receipt approval, and `damagedQty`/`shortQty` appear when > 0.
  - A per-line `qcHeld: boolean` comes from a new `InboundFacade.receiptQcHeldLineIdsInTx(tx, tenantId, grnId)`: lines with a `qc_holds` row of `kind = 'receipt'`, `schema.ts:2785-2787`.
  - The GRN snapshot carries only the count `qcHeldLines` (`receiving.command.ts:2004`), so the per-line flag needs that read.
  - `toleranceQty` is deliberately dropped: it is a warehouse policy detail inside `appliedQty`.

**A25. The handler-order rule (B19/K20).**
- The handler-order pin reads `RoutedEventBus`'s private `handlers` map through a cast, `(bus as unknown as {handlers: Map<…>})`. That is stated in the test.
- New IMPLEMENTATION-GUIDE rule: **only the client-webhooks enqueue subscribes in `onApplicationBootstrap`.** Every other handler stays in `onModuleInit`, and a second "last" subscriber would make the order ambiguous again. An architecture scan pins it.

**A26. Privacy (B23/K19).**
- The delivery log stays behind `clients.manage`.
- DEPLOY and the privacy notes state the 30-day body retention.
- Error codes name no internal address: `target-blocked` carries no IP or range.
- Audit `changes` store the URL without its query string. A query may carry a receiver token.

**A27. Observable acceptance criteria (B24).** The Tasks & Acceptance ACs below replace the original three. Each names its oracle.

**A28. Indexes (K18). Amends the Boundaries.** All are `IF NOT EXISTS`:
- `webhook_deliveries_due_idx (next_attempt_at) WHERE status IN ('pending','sending')`, for discovery and the claim;
- `webhook_deliveries_purge_idx (tenant_id, coalesce(succeeded_at, last_attempt_at, created_at)) WHERE status IN ('succeeded','failed')`;
- `webhook_deliveries_held_idx (tenant_id, endpoint_id, created_at) WHERE status = 'held'`;
- the existing `webhook_deliveries_claim_idx` is dropped from the plan, superseded by the due index.

### Amended Boundaries (they replace the matching items above)

- **`webhook_endpoints`** adds:
  - `schema_version smallint default 1` (CHECK `IN (1)`) and `deleted_at timestamptz NULL`.
  - `status` CHECK `IN ('active','disabled','deleted')`, with `(status = 'deleted') = (deleted_at IS NOT NULL)`.
  - `disabled_reason IN ('manual','failing','gone','client-departed')`.
  - The episode pairing becomes `(disabled_episode_id IS NOT NULL) = coalesce(disabled_reason IN ('failing','gone'), false)`.
  - The URL unique becomes partial: `WHERE status <> 'deleted'`. The limit of 5 counts non-deleted rows.
- **`webhook_events`** has `subject_id uuid NOT NULL` instead of `source_event_id`.
  - Unique `webhook_events_subject_unique (tenant_id, event_type, subject_id)`.
  - Type CHECK `IN ('receipt.recorded','order.dispatched')`; `_source_check` is dropped.
  - `_body_check` is `octet_length(body) <= 262144`.
- **`webhook_deliveries`** status is `IN ('pending','sending','held','succeeded','failed')`.
  - `pending_since timestamptz NOT NULL`.
  - The A28 indexes.
- **Probe** additions:
  - refused: a `deleted` row without `deleted_at`; `gone` without an episode; schema version 2; an 8th status; a 262,145-byte body;
  - accepted: `held` and `client-departed`.
- **Env:** `WEBHOOK_SEND_CONCURRENCY` (8), `WEBHOOK_DENY_HOSTS`, `WEBHOOK_DENY_CIDRS`, plus A8's placement.

### Amended matrix rows

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|---|---|---|---|
| Relay redelivers / reconcile | the same subject twice, or a quarantined row re-read | one event (subject unique) | — |
| An earlier handler quarantines | invoicing throws ×5 on a dispatch | the reconcile tick enqueues the webhook | — |
| Receiver 500s | — | 9 attempts over about 68.6 h | then `failed`; one final failure counted |
| Receiver 404 / 401 | — | `failed http-404` at once | counts as final |
| Receiver 410 | — | `failed http-410`; the endpoint disabled `gone`; panel entry | — |
| DNS rebinding / private | resolves to `169.254.170.2`, or public plus private | no connect; retried as `target-blocked` | never disables |
| Numeric host | `https://2130706433/`, `https://0x7f.1/`, `https://localhost./` | 400 at save | — |
| Failing endpoint | 10 final failures, ≥ 24 h | `disabled`/`failing`; pending and new rows `held`; re-enable needs `held: release \| discard` | > 10,000 held → `held-overflow` |
| Test | an endpoint (any status) | a synchronous send; outcome returned; counters untouched | gateway off → 409 `webhooks-unavailable` |
| Self client | create on `self` | 400 | — |
| Departed client | its endpoint at claim | rows `failed client-departed`; the endpoint disabled `client-departed` | — |
| Purged | redeliver a delivery older than 30 days | 410 `delivery-purged` | — |
| Kit order | a kit parent with 2 components | the body lists the 2 components only | — |


## Boundaries & Constraints

**Always:**
- **Dependency:** the code branches after **WMS-BE #125 (5-1a) merges**, for `seal.ts`. Never copy `seal.ts`, and never fall back to `envelope.ts`, which has no kid, no rotation and no AAD.
- **Migration** `drizzle/NNNN_client_webhooks.sql`, at the next free number at code time (after #125's 0089 and whatever has merged since; generate, never hand-edit the journal). It is additive with no data statements, so it needs no pre-flight.
  - **`webhook_endpoints`**
    - Columns: `id` uuid PK, `tenant_id`, `client_id`, `url` text, `description` text NULL, `event_types` text[], `status` text default `'active'`, `disabled_reason` text NULL, `disabled_at` NULL, `disabled_episode_id` uuid NULL, `secret_sealed` text, `secret_hint` text, `previous_secret_sealed` NULL, `previous_secret_expires_at` NULL, `consecutive_failures` int default 0, `failing_since` NULL, `last_success_at` NULL, `created_by` uuid, `created_at`, `updated_at`.
    - CHECK `_url_check`: `url LIKE 'https://%' AND char_length(url) <= 2048`.
    - CHECK `_event_types_check`: `cardinality >= 1`, `<@ ARRAY['receipt.recorded','order.dispatched']`, no NULLs, no duplicates (the `client_contacts_roles_check` shape, 0077:94-99).
    - CHECK `_status_check`: `IN ('active','disabled')`.
    - CHECK `_disabled_shape_check`: `(status = 'disabled') = (disabled_reason IS NOT NULL AND disabled_at IS NOT NULL)`, `disabled_reason IS NULL OR disabled_reason IN ('manual','failing')`, and `(disabled_episode_id IS NOT NULL) = coalesce(disabled_reason = 'failing', false)`. The coalesce is load-bearing: §3's NULL trap.
    - CHECK `_previous_secret_check`: both or neither.
    - CHECK `_failures_check`: `consecutive_failures >= 0 AND (failing_since IS NULL) = (consecutive_failures = 0)`.
    - CHECK `_description_check`: NULL or btrim length 1–200.
    - Indexes: `CREATE UNIQUE INDEX IF NOT EXISTS webhook_endpoints_client_url_unique (tenant_id, client_id, url)` and `… IF NOT EXISTS webhook_endpoints_tenant_client_idx (tenant_id, client_id, created_at)`.
  - **`webhook_events`**
    - Columns: `id`, `tenant_id`, `client_id`, `event_type`, `source_event_id` uuid NULL, `body` text, `created_at`.
    - CHECK `_type_check`: the three types.
    - CHECK `_source_check`: `(event_type = 'webhook.test') = (source_event_id IS NULL)`.
    - CHECK `_body_check`: `octet_length(body) <= 524288`.
    - Indexes: `UNIQUE … IF NOT EXISTS webhook_events_source_unique (tenant_id, source_event_id) WHERE source_event_id IS NOT NULL` and `webhook_events_tenant_created_idx (tenant_id, created_at)`.
  - **`webhook_deliveries`**
    - Columns: `id`, `tenant_id`, `client_id`, `event_id`, `endpoint_id`, `status` default `'pending'`, `attempts` int default 0, `next_attempt_at`, `claimed_at` NULL, `last_attempt_at` NULL, `last_status_code` int NULL, `last_error_code` NULL, `last_duration_ms` int NULL, `succeeded_at` NULL, `redelivery_count` int default 0, timestamps.
    - CHECK `_status_check`: the four statuses.
    - CHECK `_shape_check`: `(status = 'sending') = (claimed_at IS NOT NULL)`, `(status = 'succeeded') = (succeeded_at IS NOT NULL)`, `attempts >= 0`, `redelivery_count >= 0`, `last_duration_ms IS NULL OR >= 0`.
    - CHECK `_status_code_check`: NULL or 100–599.
    - CHECK `_error_code_check`: NULL or `~ '^[A-Za-z0-9_.-]{1,64}$'`.
    - Indexes: `UNIQUE … IF NOT EXISTS webhook_deliveries_event_endpoint_unique (tenant_id, event_id, endpoint_id)`, `… IF NOT EXISTS webhook_deliveries_claim_idx (tenant_id, status, next_attempt_at)` and `… IF NOT EXISTS webhook_deliveries_log_idx (tenant_id, endpoint_id, created_at DESC, id DESC)`.
  - **RLS** on all three: the tenant arm plus the 0041 `app.client_id` clause on `client_id` (the `client_contacts_tenant_isolation` shape, 0077:116-123), so a future portal read is isolated by the database. The `client-isolation` table-count pin moves by +3.
  - **Notifications CHECK:** `notifications_source_type_check` is dropped and re-added with every member on main at code time plus `webhook-disabled`. The 0084:126 precedent; assert the old set is a subset (§4).
  - **Probe:** a `DO` block (the word INDEX never appears inside it). Accepted shapes are inserted and rolled back by a sentinel. Each refused shape is refused by its named constraint:
    - a non-https URL;
    - empty, unknown or duplicate event types;
    - disabled with no reason;
    - a `failing` reason without an episode, and an episode on `manual`;
    - one previous-secret column without the other;
    - `failing_since` with 0 failures;
    - a test event with a source id;
    - `sending` without `claimed_at`;
    - a status code of 99;
    - an error code with a space;
    - the `webhook-disabled` notification accepted and an unknown source type refused.
- **Architecture block** (`test/architecture.spec.ts`):
  - only `src/modules/client-webhooks` writes the three tables;
  - it imports siblings only through their facades or exported `…InTx` functions (tenancy's `getMemberRoleIn`, `assertPermission`, `getWarehouseCodeInTx`);
  - `webhook.enqueue.ts` imports no `node:http(s)`, `net`, `tls`, `dns`, `fetch` or `webhook-http`, while `webhook.sender.ts` does (a meaningfulness check);
  - `WEBHOOK_SEAL_KEY` has one reader.
- **Logs** carry the tenant, endpoint and delivery ids, the URL **host** only, and the code. Never a query string, a header, a body or a secret.
- **The worker** follows `PushSenderWorker` (IMPLEMENTATION-GUIDE §8): `parsePollMs`, single-flight, `InFlightTick`, a `beforeApplicationShutdown` settle, one try/catch per tenant, and `tick()` public.
  - The claim is `FOR UPDATE SKIP LOCKED`, with `sending` committed before any network call.
  - Outcomes are written only where `status = 'sending' AND claimed_at = $claimed`, so it is safe in two processes.

**Never:**
- No change to any outbox payload, emitter or existing subscriber.
- No webhook for any event other than the two.
- No portal route.
- No email (5-2b).
- No inbound/consumer-side webhooks: the channels `webhooks.controller.ts` is untouched; the new controller is `src/api/client-webhooks.controller.ts`.
- No response body stored; no redirects followed; no HTTP (non-TLS) targets.
- No secret in a snapshot, log, audit row or read.
- No per-tenant opt-out of the SSRF guard.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|---|---|---|---|
| Create | owner, `https://hooks.acme.in/wms`, `[order.dispatched]` | 201 `{endpoint, signingSecret: 'whsec_…'}`; audited; the replay gives `signingSecret: null` | the 6th → 409 `webhook-endpoint-limit` |
| Bad URL | `http://…`, `https://10.0.0.5/`, `https://localhost/`, `https://u:p@x.in/` | 400 `validation-failed` naming the rule | — |
| Dispatch | client ACME, one active endpoint subscribed | one event (minimised body), one delivery; signed POST; 2xx → `succeeded` | — |
| Receipt, no client | an old mixed-client blind GRN | no event; logged; acked | — |
| Relay redelivers | the same outbox row twice | still one event and one delivery | — |
| Enqueue DB error | transient | the row re-drains; the invoice issued once; the webhook handler ran last | quarantined after 5: webhooks only lose it |
| Receiver 500 / timeout | — | `pending`, backoff, attempts + 1; counters up | 8th → `failed` |
| DNS rebinding | the host resolves to `169.254.170.2`, or to public plus private | no connection; `failed target-blocked` | — |
| Redirect | 302 to an internal host | not followed; retried as `redirect` | — |
| Rotation | rotate, then deliver within 24 h | two `v1,` signatures; the old one is dropped after 24 h | — |
| Failing endpoint | 10 failures over ≥ 24 h | `disabled`/`failing`; pending → `failed endpoint-disabled`; panel entry; re-enable resolves it | — |
| Stale send | the worker crashed mid-POST | after 5 min → `pending` (attempt `stale`); re-sent with the same `webhook-id` | — |
| Redeliver | a failed delivery | `pending`, same bytes, new timestamp; audited | non-final → 409 `delivery-in-progress` |
| Other client | an endpoint id of client B under client A | 404 | — |

## Code Map

### Backend (`workspace/core/backend/wms-be`)

This branches after WMS-BE #125 merges. The migration takes the next free number after 0089.

**The new module, `src/modules/client-webhooks/`**
- `webhook-rules.ts` (pure, unit-tested):
  - the tuples: event types; endpoint statuses and reasons; delivery statuses; error codes;
  - `normaliseWebhookUrl` (A14's save rules, trailing dot, numeric hosts, `WEBHOOK_DENY_HOSTS`);
  - the A18 fate table, `classifyOutcome`;
  - the A2 schedule, `webhookRetryDelayMs`;
  - the A12 auto-disable predicate;
  - `WEBHOOK_BODY_MAX_BYTES`;
  - the boot assert on the stale bound.
- `webhook-payloads.ts`:
  - the v1 builders, key by key (decision 5 as amended by A6, A22, A23, A24);
  - decimal-string quantities from milli-units;
  - the 256 KiB fallback.
- `webhook-secrets.ts`:
  - the keyring over 5-1a `seal.ts` (the `mail-secrets.ts:30-40` shape);
  - `generateSigningSecret`;
  - `openSigningKeys` (current plus an in-window previous);
  - the `webhooks:reseal` script body.
- `webhook-signature.ts`: Standard Webhooks signing (A7).
- `webhook-http.ts`, the only socket to a client URL. It has:
  - the guarded `lookup` (all shapes; any-bad refuses);
  - the A14 ranges plus `WEBHOOK_DENY_CIDRS`;
  - the `remoteAddress` re-check;
  - `autoSelectFamily: false` and `agent: false`;
  - no redirects;
  - TLS ≥ 1.2 with `rejectUnauthorized`;
  - the timeout and a 4 KiB read.
  
  Its resolver is injectable.
- `webhook.enqueue.ts`:
  - subscribes in `onApplicationBootstrap` (A25);
  - `enqueueFromSource(tx, type, payload)`, shared with the reconcile arm (A1);
  - rethrows only on A11's classes;
  - subject unique and `ON CONFLICT DO NOTHING`;
  - held rows for a failing endpoint (A5);
  - skips departed clients and `self`.
  
  The model is `notifications/push.enqueue.ts:117-224`.
- `webhook.sender.ts`, per tenant:
  1. the sweep: stale return, expiry on `pending_since`, `held-expired`/`held-overflow`, purge, departure, reconcile;
  2. the claim (A3 SQL);
  3. the endpoint re-read (A4);
  4. sends under concurrency 8 and the 60 s budget;
  5. outcomes, conditional on the claim and on `status = 'active'` (A12);
  6. auto-disable under `FOR UPDATE`.
  
  The model is `notifications/push.sender.ts:104-198`.
- `client-webhooks.command.ts`, all keyed and audited, with A20's rate limit on test and redeliver:
  - create, update (including `held` release/discard), soft delete;
  - rotate (`revokePrevious`);
  - test (synchronous);
  - redeliver and bulk redeliver.
- `client-webhooks.facade.ts`: the reads, `sendDueWebhooks(tenantId)` and `testSend`.
- `client-webhooks.dto.ts` and `client-webhooks.module.ts`.

**Sibling seams added (reads only)**
- `OutboundFacade.orderClientIdsInTx` and `kitParentLineIdsInTx` (beside `orderRefsInTx`, `outbound.facade.ts:1391`).
- `CatalogFacade.skuLabelsInTx` → `{code, name, uom, uomPrecision}` (beside `skuFactsInTx`, `catalog.facade.ts:943`).
- `InboundFacade.poCodesByIdsInTx` and `receiptQcHeldLineIdsInTx` (beside `grnCodesByIdsInTx`, `inbound.facade.ts:480`).
- `shared/events/outbox.ts`: `quarantinedMessagesInTx`, read-only, plus the structured quarantine log line (A1). This is the only change under `shared/events`; it touches neither `drain` nor `append`.
- Tenancy: `getWarehouseCodeInTx` (`tenancy.service.ts:136`), `getMemberRoleIn`, `assertPermission`. Clients: `lockClientInTx` (`clients.facade.ts:375`), `getClientsInTx` (`:545`), `assertClientTakesWorkInTx` (`:417`), `departedClientIdsInTx`.

**Wiring**
- `src/api/client-webhooks.controller.ts`, under `:tenantId/clients/:clientId/webhook-endpoints`:
  - GET and POST;
  - PATCH and DELETE `/:endpointId`;
  - POST `/:endpointId/rotate-secret` and `/:endpointId/test`;
  - GET `/:endpointId/deliveries`;
  - POST `/:endpointId/deliveries/redeliver`, which is a literal, so it is declared first;
  - GET `/:endpointId/deliveries/:deliveryId`;
  - POST `/:endpointId/deliveries/:deliveryId/redeliver`.
- `src/jobs/jobs.module.ts`: `WebhookSenderWorker`, plus the A8 conditionals.
- `main.ts`: the boot asserts (key with `https`, the stale bound).
- `package.json`: the `webhooks:reseal` script and the `standardwebhooks` devDependency.

**Notifications**
- `notification-sources.ts`: the `webhook-disabled` source, added to `NOTIFICATION_SOURCE_TYPES` `:25`, `SOURCE_RESOLUTIONS` `:68`, `NOTIFICATION_SOURCES` `:371` and `SOURCE_AUDIENCE` `:740`.
  - Raise: `webhook_endpoint.disabled` (`failing`/`gone`).
  - Resolve: `.enabled`, `.deleted`, `.manually_disabled` carrying `episodeId`; a null one is acked silently (A10).
  - Summary: `{endpointId, clientId, host, reason}`.
  - The literals are pinned in `test/notifications.spec.ts`.

**Audit** (`src/shared/primitives/audit.ts`)
- The `webhook_endpoint` target.
- Actions: `webhook_endpoint.created`, `updated`, `deleted`, `secret_rotated`, `secret_revoked`, `test_sent`, `redelivered`, `bulk_redelivered` (each `expectAuditRow`), and `auto_disabled` (system, unkeyed).
- `clientWebhooks.update:unchanged` goes in `AUDIT_NO_OP_ARMS`.

**Migration** (Boundaries as amended): `schema.ts`, `.env.example`, the README, `openapi.json`.

**Tests**
- `test/client-webhooks.spec.ts`: every matrix and amended row, through HTTP and through `sendDueWebhooks` with a fake port.
- The handler-order pin (A25) and the quarantine pin (A1).
- The fairness test (A3) and the outcome-order test (A12).
- A same-key parked-waiter race on create.
- A `wms_rls_probe` arm per table, with a positive control.
- Unit specs: rules, payload goldens (fractional, kit, omitted lines), the signature vector plus `standardwebhooks`, and the transport (local TLS server: pinned connect, redirect, bad certificate, `remoteAddress` mismatch).
- `scripts/webhook-transport-smoke.ts`, run under Bun (A13).

**Do not touch:** `inbound/receiving.command.ts`, `outbound/dispatch.command.ts`, `invoicing/*`, `channels/*`, and `shared/events/*` apart from the one read seam and the log line.

### Web (`workspace/core/frontend/wms-fe`)

- `src/components/settings/client-webhooks.tsx` (new), mounted as `panel.kind === 'webhooks'` in `clients-card.tsx:288-318`. It has:
  - the endpoint list and the add/edit form (with the A19 attestation checkbox);
  - the one-time secret dialog;
  - rotate (with "end the old secret now" and the 24 h warning);
  - test, which shows the synchronous outcome;
  - enable with the release/discard choice, disable, delete;
  - the deliveries drawer (single and "Redeliver failed since…", body download);
  - the "Deliveries paused" banner on `warnings`;
  - "How to verify" (Standard Webhooks steps, the 5-minute window, the egress IPs).
- `src/lib/client-webhooks.ts`: words for statuses, reasons and codes; IST times; with tests.
- `src/lib/notifications.ts`: the `webhook-disabled` label and the link `/settings?tab=clients`.
- Regenerate the client.

### Mobile

None.

## Tasks & Acceptance

**Execution:**
- [ ] BE (after #125): the migration; the module; the five sibling reads and the outbox seam; the controller; the worker; the notifications source; the audit vocabulary; env and boot asserts; the reseal script; OpenAPI; tests including the Bun smoke.
- [ ] Web: the panel, dialogs and drawer; the notification label; tests; the regenerated client.
- [ ] Meta docs:
  - new `modules/client-webhooks.md`: the flows as sequence diagrams, the fate table, the receiver verification guide and the v1 payload reference;
  - SYSTEM-DESIGN (the module and the worker);
  - `notifications.md`;
  - `clients.md`;
  - API-SURFACE;
  - DEPLOY §2 (env placement, egress IPs, 30-day retention, the reseal runbook);
  - IMPLEMENTATION-GUIDE: customer URLs go only through `webhook-http.ts`; only the webhook enqueue subscribes in `onApplicationBootstrap`;
  - both READMEs;
  - PENDING: quarantine panel source, `VALIDATE` of the notifications CHECK, secure secret handoff, mTLS, a client pull for omitted lines, per-endpoint ordering, corrections/reversal events, the portal view, the client admin.

**Acceptance Criteria:**
- **Dispatch delivers once, verifiably, and nothing else changes.**
  - *Given* an active ACME endpoint subscribed to `order.dispatched`, *when* an ACME order is dispatched and the relay and the sender run, *then* the fake port records exactly one POST.
  - Its `webhook-id` equals the stored event id, its body equals the stored bytes, and `standardwebhooks.Webhook(secret).verify(body, headers)` passes.
  - The **unchanged golden pins** of the `order.dispatched` and `grn.recorded` outbox payloads pass, and the existing invoicing and channel-writeback specs pass without edits. That is the oracle for "invoicing and writeback unchanged".
- **Handler order.** *Given* the app booted, *when* the bus's private handler map is read, *then* the webhook enqueue is the last handler for both types. *Given* the enqueue mocked to reject, *when* a dispatch relays, *then* its invoice is issued once.
- **Quarantine reconcile.** *Given* invoicing's handler mocked to throw ×5 on a dispatch, *when* the row quarantines and one sender tick runs, *then* exactly one `webhook_events` row exists for that order. A second tick and an operator replay add none.
- **SSRF.** *Given* an injected resolver answering `169.254.170.2` (or `[public, 10.0.0.1]`), *when* the delivery is sent, *then* a `net.connect`/`tls.connect` spy records **zero** calls, the row is `pending` with `target-blocked`, and `consecutive_failures` is unchanged.
- **Save-time host rules.** *Given* `https://2130706433/`, `https://0x7f.1/` and `https://localhost./`, *when* each is created, *then* each answers 400 `validation-failed` naming the host rule.
- **Expiry clock.** *Given* a delivery whose `pending_since` is set to 72 h + 1 ms ago, *when* the sweep runs, *then* it is `failed expired`. At 72 h − 1 ms it stays `pending`. *Given* a redeliver, *then* `pending_since` is now.
- **Fairness.** *Given* tenant A's endpoint port hangs until timeout and tenant B has one due delivery, *when* one tick runs, *then* B's delivery is `succeeded` within that tick.
- **Fractional golden.** *Given* a catch-weight `kg` line of 12.5 kg dispatched, *then* the body's line reads `"dispatchedQty": "12.500", "uom": "kg"`, compared against a key-by-key golden.
- **Signature vector.** *Given* the A7 reference inputs, *then* `sign()` returns `v1,g0hM9SsE+OTPJTGt/tmIKtSyZlE3uFJELVlNIOLJ1OE=`.
- **No secret at rest outside the seal.** *Given* a create replayed with the same key, *then* the response has `signingSecret: null`, and no `idempotency_keys`, `audit_events` or `outbox_messages` row contains the secret's text.

## Design Notes

- **Why a queue table and not a network call in the relay.** The relay is one serial loop for every tenant, and it quarantines after five throws (`outbox.ts:18`). A slow client endpoint inside a handler would stall every tenant's invoicing. This is the 9-2b push precedent.
- **Why at-least-once here, when push and mail are at-most-once.** A machine consumer dedupes cheaply on `webhook-id`, and a missed dispatch is a lost business fact.
- **Why freeze the body at enqueue.** Redeliveries must send the same facts, even after a SKU rename. The signature covers the stored bytes.
- **The cost of a rethrow (A11).** A rethrow re-drains the whole outbox row, so invoicing (idempotent, a no-op on its second run) and channel writeback (which reads back channel state, then may call Shopify again) run again. That is an extra Shopify round trip per retry. It is why only connection and serialization errors rethrow.
- **Why the reconcile arm reads quarantine, not the tables (A1).** An acked outbox row was seen by every handler; only a quarantined one can have skipped ours. Rebuilding a dispatch from tables would need the carrier and tracking out of the ledger `reference_doc`, which means a second builder that could drift from the first.
- **Why hold, not fail, while failing (A5).** A receiver outage of over a day is the common case for auto-disable. Holding lets staff release the backlog once the receiver is fixed, instead of rebuilding it by bulk redeliver; the cap bounds the table.

## Verification

**Commands:**
- `bun run test -- test/client-webhooks.spec.ts test/notifications.spec.ts test/architecture.spec.ts src/modules/client-webhooks` (wms-be, run alone; never two jest runs at once): pass. Then the full suite.
- `bun scripts/webhook-transport-smoke.ts` (wms-be, under Bun): pass.
- `bun run db:migrate && bun run db:verify`; `bun run db:generate` reports no schema changes; `git status --short` is clean.
- `bun run lint && bun run typecheck && bun run build` (wms-be, wms-fe); `bun test` (wms-fe): pass. Re-run typecheck on the merged result (§8).

## Implementation Notes

## Spec Change Log

## Review Triage Log

Design review, 2026-10-23: claims check K1–K20 (against origin/main, 5-1a, the 6-2c branch, and Bun/Node experiments) and blind review B1–B24. All choices are recommended, taken autonomously. Every accepted finding is folded into `## Design Review Amendments`.

| ID | Verdict | Finding → resolution |
|---|---|---|
| K1 | high | Keying by outbox row id loses the webhook when an earlier handler quarantines the row → A1 (subject key, quarantine reconcile; deviation: reads quarantine rather than rescanning the tables, see Design Notes) |
| K2 | high | The backoff could not reach the 72 h expiry, and expiry measured from creation punishes redeliver → A2 |
| K3 | high | Per-tick cap only; one slow endpoint starves the rest; stale bound unrelated to the timeout → A3 |
| K4 | high | Claim ignores endpoint changes; URL/type edits and delete strand rows; `off` stops the sweep → A4 |
| K5 | medium | Kit parent lines ship as zero-dispatched and fully short (verified `dispatch.command.ts:325-329`) → A6 |
| K6 | medium | The HMAC key is the decoded secret, not the string; separator unstated; no vector → A7 (vector verified with `node:crypto`) |
| K7 | medium | The 6-2c worker contract (`JOB_POLL_VARIABLES`, `WORKER_JOBS`, `track`/`beat`, `ConfigRefusal`, verified on the branch) → A8 |
| K8 | medium | Re-adding the notifications CHECK scans the table under ACCESS EXCLUSIVE → A9 (`NOT VALID`; VALIDATE in PENDING) |
| K9 | medium | Resolve events lacked the episode; failing → manual left the entry open → A10 |
| K10 | medium | "Rethrow on database errors" was too broad; a rethrow re-runs writeback → A11 + Design Notes |
| K11 | high | Read-modify-write counters race; auto-disable not serialised → A12 |
| K12 | high | `lookup` with `{all:true}`, happy-eyeballs and Bun parity unproved → A13 |
| K13 | high | Missing ranges, trailing-dot and numeric hosts, self-hostnames → A14 |
| K14 | medium | Rotation overlap, double rotation, retiring the seal key, an unopenable secret → A17 |
| K15 | medium | Body limit and the omitted-lines path → A24 |
| K16 | medium | `self` client and departure unhandled → A4 |
| K17 | maybe-false | Not in the coordinator's decision list; no amendment. Settled by reading K17's own text |
| K18 | low | Claim and purge indexes not partial → A28 |
| K19 | low | Privacy of logs and audit `changes` → A26 |
| K20 | low | The handler-order pin reads a private field → A25 |
| B1 | high | Retry window vs expiry → A2 |
| B2 | high | Auto-disable drops in-flight business events → A5 (hold; manual disable does not hold) |
| B3 | high | Head-of-line blocking across tenants → A3 |
| B4 | medium | No global concurrency or tick budget → A3 |
| B5 | high | No outcome fate table; 4xx retried for 72 h; 410 ignored → A18 |
| B6 | medium | Signature header format → A7 |
| B7 | medium | Rotation semantics → A17 |
| B8 | medium | Secret handoff and URL ownership → A19 (accepted out-of-band; PENDING) |
| B9 | medium | Expiry clock → A2 (`pending_since`) |
| B10 | medium | Test and redeliver can be used as a request cannon → A20 |
| B11 | high | Host-parsing bypasses → A14 |
| B12 | high | TLS posture unstated → A15 |
| B13 | medium | Receivers cannot allowlist our egress → A16 + 6-2d deferred entry |
| B14 | low | Versioning per receiver → A21 |
| B15 | medium | Float quantities lose precision → A22 |
| B16 | medium | Dispatch identity, `channelRef` naming, corrections, ordering → A23 (one dispatch per order verified at `dispatch.command.ts:262-316`) |
| B17 | medium | Receipt semantics; omitted lines unrecoverable → A24 |
| B18 | high | Missed events → A1 |
| B19 | low | Handler-order fragility → A25 (IMPLEMENTATION-GUIDE rule plus a scan) |
| B20 | medium | Edits and delete vs pending rows → A4 |
| B21 | medium | Test on a disabled endpoint; redeliver to a disabled one → A4 |
| B22 | high | Counter races → A12 |
| B23 | low | Delivery log access and retention → A26 |
| B24 | medium | ACs not observable → A27 + the rewritten Tasks & Acceptance |
