---
title: '7.1 Channel connections, buffers, and availability sync'
type: 'feature'
created: '2026-10-01'
status: 'in-review'
baseline_commit: '5ea3f66866b12fe345f62434d5acbc32d990d997'
route: 'dispatch'
review_loop_iteration: 1
context:
  - '_bmad-output/implementation-artifacts/epic-7-context.md'
  - 'docs/design/SYSTEM-DESIGN.md'
  - 'docs/design/IMPLEMENTATION-GUIDE.md'
  - 'docs/design/modules/inventory.md'
  - 'docs/design/modules/outbound.md'
  - 'docs/design/modules/catalog.md'
  - 'docs/design/frontend/SYSTEM-DESIGN.md'
  - 'docs/design/frontend/IMPLEMENTATION-GUIDE.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

An Ops Manager connects a sales channel (Shopify, Amazon.in, or Flipkart) with envelope-encrypted per-tenant credentials, configures that channel's per-SKU Safety Buffers and backorder policy, and reads its sync health — on a real Channels surface replacing the `/channels` placeholder. Each configured buffer is a **ledger-backed standing reservation** (AD-13): a `held` reservations row through the shared atomic-reservation script, with no TTL, so it carves stock off the grantable pool and off every channel's published quantity until it is changed or a disconnect releases it. A sync worker publishes per-channel available quantity through the transactional outbox (sync-lag surfaced per channel, failures dead-letter), with per-tenant integration-call metering and a circuit breaker so a runaway sync loop sheds itself. Acceptance/reservation (7-2's story) continues server-side regardless of channel-API health — nothing in this story makes oversell protection depend on a channel being reachable.

## Boundaries (out of scope)

- **No order ingestion, no webhook endpoints, no fulfillment writeback** — all of 7-2. The `orders` table's `source:'ingested'` arm stays untouched; only the integrations identity it references is born here.
- **No real marketplace HTTP adapter.** The adapter is a port (the `CarrierAdapter`/`carrier-label-port` pattern): 7-1 ships machinery + transport-unconfigured arms; real transport lands with the launch story that has live credentials.
- **No mobile surface** (per the epic decision); **no notification/bell panel** (Epic 9 reads the KPIs this story exposes).
- **No auto-submit of anything external; no PO or replenishment coupling** (FR-23's dashboards read from ledgers, not from channels).

## Output/Input matrix

| # | Surface | In | Out / arms |
| --- | --- | --- | --- |
| 1 | `POST /:tenantId/channels/connections` | `{provider: shopify\|amazon-in\|flipkart, credentials: <provider-shaped>}` + idempotency key | `201` connection snapshot **without any credential material** / `400` shape / `403 channel.manage` / `409 connection-exists` (unique tenant+provider) |
| 2 | `PUT /:tenantId/channels/connections/:id/credentials` | rotated credentials + idempotency key | `200` snapshot / `400` / `403` / `404` — version bump, old-sealed blob replaced, rotation noted in audit |
| 2b | `PUT /:tenantId/channels/connections/:id` | `{backorderPolicy: accept\|reject}` + idempotency key | `200` snapshot / `400` / `403` / `404` — stored now, consumed by 7-2's ingestion acceptance |
| 3 | `DELETE /:tenantId/channels/connections/:id` | idempotency key | `204` — deletes the credential blobs, cancels its standing buffers, `404` when absent; disconnect leaves no readable secret and revokes (port attempt logged, not blocking) |
| 4 | `GET /:tenantId/channels/connections` | — | `200` rows: provider, health (`ok\|degraded\|error`), `lastSyncedAt`, `syncLagMs`, breaker state, buffer-bucket counts (no secrets) |
| 5 | `PUT /:tenantId/channels/channels/:connectionId/buffers` | `{items: [{warehouseId, skuId, bufferMilli}]}` + idempotency key | `200` per-item verdicts / `400` shape / `403` / `404` sku\|warehouse\|connection / per-item `409 buffer-over-ceiling` (the standing grant refused; the old buffer must stand — see RN-2) |
| 6 | `POST /:tenantId/channels/connections/:id/retry` | idempotency key | `200` — re-appends the availability snapshot, half-opens the breaker / `404` / `403` |
| 7 | FE `/channels` (replaces `SurfacePlaceholder`) | — | Connections cards (connect/rotate/disconnect), per-channel buffer editor (warehouse+SKU rows), sync-health inline (amber lag+retry, per UX-DR19); `channel.manage` rows in the capability mirror |

Standing-reservation core (no wire): `buffer` standing grant arm + `bufferUnits()` journal read (RN-1/RN-2); sync worker + adapter port + metering/circuit-breaker (RN-3..RN-6).

## Resolved decisions

- **Standing rows, not a config table:** a buffer's amount is its reservations row (`owner_type: 'buffer'`, `owner_id: <integrationId>`, `expires_at: null`) — zero buffer = no row; there is no `channel_buffers` config table and no duplicated truth. Channels sets/adjusts through the inventory **facade**, never Valkey or SQL directly.
- **`channel.manage` capability (owner + ops_manager only)** at command entry via `assertPermission`; reads ungated (the repo rule). Operators never reach any channel verb.
- **Credentials follow the 4.6b AD-15 stand-in:** `sealCredential`/`openCredential` + HMAC over the canonical sorted JSON, own master-key env (`CHANNEL_ENCRYPTION_KEY`, independent of `CARRIER_ENCRYPTION_KEY`), `credential_version` bump on rotation, sealed blob never selected onto any wire shape.
- **Sync health:** `degraded` = lagging or retrying (amber inline); `error` = dead-letter / breaker open (red, retry affordance); `ok` = within SLO. Lag is `now − lastSyncedAt` from the last delivered sync, not a promise.
- **Channel SKU mappings are 7-1 deliverables** (FQ-1, user-answered): a `channel_mappings` table in migration 0050 (tenant, integrationId, externalRef ↔ skuId, unique per (integration, externalRef)); the sync publishes only mapped scopes; 7-2's ingestion resolves webhook lines through the same rows.
- **Buffer granularity is per (integration, warehouse, sku)** (FQ-2, user-answered): the flash-sale knob is SKU-shaped; the buffer editor lists per-SKU rows.
- **Real transport lands with 7-2** (FQ-3, user-answered): 7-1's adapter is the port with transport-unconfigured arms; 7-2 also bears the HTTP client + retry/backoff utility.

</frozen-after-approval>

## Code Map

- **The seam the story rides (all verified against merged trees):** `src/modules/channels/channels.module.ts` — empty spine, intended owner; `app.module.ts:6,39` already imports it. FE `/channels` route exists as `SurfacePlaceholder`.
- **Reservation core:** `src/modules/inventory/reservation.service.ts` — `bufferUnits()` :120 placeholder (hardcoded 0) subtracted in `committedCeiling` :1102 and `atp()` :672; reaper `expireDue` :801 sweeps `state in ('held','committed') and expires_at `<=` now()` — NULL expiry rows escape naturally; `grant` :325 (probe → ceiling → Lua → journal, 409 `unavailable` vs 503 `reservation-store-unavailable` :229), `releaseInTx` :1357 (journal half; caller mirrors the net counter delta), `grantInTx` :1499 (no-arbitration in-tx grant, null on shortfall), `heldReservationsByOwnerInTx` :1612. Lua: `RESERVATION_GRANT_SCRIPT` (`src/shared/valkey/reservation-scripts.ts:42`), counters `wms:{tenant}:wh:{wh}:res:{sku}` keys. Schema `src/shared/db/schema.ts:1335` — partial unique `reservations_open_owner_scope_unique` `WHERE state='held'`.
- **Outbox + workers (reuse as-is):** `OutboxSink.append(tx)` / `OutboxRelay.drain` (`src/shared/events/outbox.ts`, DLQ via `markFailed` :257 after `OUTBOX_MAX_ATTEMPTS=5`); worker pattern `src/jobs/jobs.module.ts:141` `OutboxRelayWorker` (env-gated poll, `running` shed, `unref()`).
- **Idempotency:** `modules/tenancy/idempotency-guard.ts` (`parseRequiredIdempotencyKey`, `hashCommandPayload` — fixed field order, the `canonicalCredentialJson` sort precedent for payload fingerprints).
- **Credentials precedent:** `modules/carriers/carrier-credentials.ts` (`carrierMasterKey` :41, `sealCredential` :64, `openCredential` :73, HMAC :95); envelope `src/shared/crypto/envelope.ts`; vault rows `carrier_connections` `schema.ts:2288`.
- **Module exemplar:** `modules/replenishment/replenishment.module.ts` (providers command/sweep/facade, exports facade only); controllers in `src/api/*.controller.ts` with `TenantSessionGuard` + `@ApiHeaders(IDEMPOTENCY_HEADER)`; RLS hand-append after the drizzle section, next migration **0050** (`drizzle/` latest 0049).
- **Variant binding (for the mappings):** `products` `schema.ts:554` + `skus.productId` :474 + `variantValues` jsonb :485 — a "variant" IS a SKU row; `catalog.facade.ts findSku` :293 / listSkus. Channel-mapping tables are Epic-7's deliverable (PENDING :84).
- **What NOT to change:** the `orders` schema's ingested arm, `orders_source_event_unique`, the outbound order state machine, the `atp()` snapshot shape beyond the `buffer` field, `unavailable`/`reservation-store-unavailable` codes (the sync branches on them, PENDING :18), the outbox relay itself.
- **FE pattern:** the 6-1 four-file exemplar — page → `components/channels/channels-view.tsx` (+ test) → `lib/channels.ts` → `lib/use-channels.ts`; generated client from `openapi-ts.config.ts` (`bun run api:generate` → `src/lib/api/generated`).

## Tasks & Acceptance

### T1 — integrations identity + credentials (RN-4)

Migration 0050: `integrations` (tenant_id uuid, provider enum unique per tenant, status enum `connected|disconnected`, `credential_sealed` text, `credential_version` int, `backorder_policy` enum `accept|reject` default accept, sync-health stamps: `last_synced_at`, `last_attempt_at`, `last_error` text nullable) + `integration_calls` metering rows (tenant, integration, kind, status, latency_ms, at) + RLS fail-closed hand-appends (0048 pattern); `channel_mappings` per the frozen decision (mappings in 7-1). Commands: connect (validate provider shape, 409 unique), connection-config PUT (backorder policy, arm 2b), rotate, disconnect (delete credential blobs, release its standing buffers in-tx). Idempotency scaffolding per command. *Given a connected provider row exists **when** connect is called again with the same provider **then** 409 `connection-exists`.* *Given disconnect **when** the connection had standing buffers **then** the held rows release and the counter mirrors once (single net mirror).* *Given any secret **when** any response or audit payload is serialized **then** no credential material appears.*

### T2 — standing reservation core (RN-1/RN-2)

`grant` gains a standing arm (TTL-optional; `expires_at` null admitted for `owner_type='buffer'` grants only); `bufferUnits()` becomes the journal read (`sum held rows, owner_type='buffer'`, scope-keyed); the grant ceiling and ATP read drop the separate buffer term (buffers fold into `reserved` through the counter — the double-subtraction trap is the reason); `AtpSnapshot.buffer` reports the summed standing rows. `PUT buffers` flows: per item, one tenant tx — existing row `releaseInTx` + delta, absent row `grantInTx`; refusal leaves the old standing row in place (and mirrors nothing — counters only move on committed writes). *Given pool headroom < requested buffer **when** PUT is called **then** that item 409s with the pool figure in the message and the previous buffer still stands.* *Given expires_at null **when** the reaper runs **then** the row survives.* *(Accept: buffer set/adjust/release each leaves counter and journal sum equal — parity pass.)*

### T3 — sync worker, adapter port, metering, health (RN-3/5/6)

`ChannelsSyncWorker` in jobs.module (replenishment worker pattern: parse-Poll-Ms env-gated OFF default, running-shed, per-cycle scope bound): each cycle enumerates connections, computes per-channel visible quantity (see RN-6), meters, and appends outbox messages `channel.availability.published`; delivery through `ChannelAvailabilityPort` (port-only — DIRECT arms `501 channel-transport-unconfigured`, the `carrier-label-port` pattern), failures retry to DLQ. Circuit breaker per tenant+integration (consecutive-failure threshold in a const, state on the connection row, half-open on `retry`). Health read per FQ — lag from `last_synced_at`. *Given the Valkey store returns 503 during a compute pass **when** the worker runs **then** the cycle marks that connection `degraded` with the store-unavailable reason and publishes nothing (never invents zero — PENDING a8).* *Given N consecutive delivery failures **when** the breaker evaluates **then** the connection stops appending until retry half-opens it.*

### T4 — FE Channels surface (RN-7)

Replace `src/app/(app)/channels/page.tsx` (per the frozen granularity decision); the 4-file pattern; capability-mirror rows; tests pin: connect/rotate/disconnect arms, inline amber on `degraded`, retry affordance on `error`, buffer editor rows, no Operator-visible entry.

### T5 — verification

BE jest: connect/rotate/disconnect e2e with real facades (credential sealing round-trip, disconnect release + counter parity), standing-buffer arms (place, adjust, ceiling refusal, reaper-NULL-survival, parity pass), sync worker arms (mapped-scope compute, metering rows, breaker open/half-open, degraded-on-503, DLQ after max attempts), architecture-spec write partition update (channels owns its tables; the inventory core owns reservations writes). FE bun: surface tests. `bun run openapi:export` + FE `api:generate` + mirror + `db:verify` round-trip.

## Design Notes

**RN-1 — standing rows fold into `reserved`.** The dual-subtraction trap, stated: if buffers were both a held row (counted in the Valkey counter and thus in `atp()`'s `reserved`) AND a separate `buffer` formula term, ATP would subtract every buffer twice and the grant ceiling would too. Chosen layout: a buffer IS a `held` reservations row (owner_type `buffer`, `expires_at` null — the reaper's `expires_at <= now()` predicate skips nulls without a core change); the grant ceiling and the ATP read **drop the `bufferUnits()` term from their arithmetic** (single subtraction lives in the counter, which the Lua script already governs; the "formula never changes" contract is honored — the buffer simply becomes part of what `reserved` means); the snapshot's `buffer` field reports the journal sum for transparency. Existing tests are unaffected until a buffer exists (the term was 0).

**RN-2 — adjust is incremental, refusal is honest.** An adjust within one tx (delta grant or delta release, the existing `grantInTx`/`releaseInTx` pair) keeps counters moving once per commit; a refusal (`unavailable` shortfall) leaves the old buffer standing. Disconnect releases buffers in the same tx that deletes the credentials.

**RN-3 — the `unavailable` branch is 7-1's machine code (PENDING a8).** The sync treats 503 `reservation-store-unavailable` as "ATP read fail-closed" → degraded, publish last-known nothing-new; 409 `unavailable` as a real pool state → publish the clamped figure. The dual meaning stays, but the channel consumer now branches deliberately.

**RN-4 — credentials.** The 4.6b stand-in is the pattern of record: per-consumer master-key env, `sealCredential`/`openCredential`, the HMAC, version-bumped rotation, and no sealed blob on any wire shape. Rotation = rescale-in-place with version bump; disconnect = row delete (the audit records the event, not a secret hash of the content).

**RN-5 — metering + breaker.** `integration_calls` is the meter: rows are append-only per call. Circuit breaker = consecutive-failure count on the connection row (a const threshold, e.g. 5) — `open` refuses further appends, retry half-opens. The scope is 7-1's sync delivery calls; 7-2's webhook ingestion meters under the same table.

**RN-6 — per-channel visible quantity.** `V(c) = max(0, onHand − qcHeld − inTransit − Σheld − buffer(c) )` = the channel's share of the shared pool minus its own staleness margin. The exhaustion property is the AC's test: `V(c)` hits 0 while the pool (`atpRead`) still holds `buffer(c)` — never "cancel-and-apologize". Sync publishes ONLY mapped scopes (mappings are 7-1 deliverables); a connection with no mappings publishes nothing.

**RN-7 — FE.** The Channels surface is one card column (connections, health amber inline) + one buffer editor per connection; degraded shows lag + last effort inline, never a modal (UX-DR19).

## Step-03 Verification Record

*(this session's own read of the staged diffs + source files + first-hand test runs; not the implementer's report)*

**T1✓ T2✓ T3✓ T4✓ T5✓** — verified against `/tmp/71-core.diff`, migration `0050_channels_integrations.sql`, all ten `src/modules/channels/*` files, `channels.controller.ts` + `channels.dto.ts`, the `ChannelsSyncWorker` in `jobs.module.ts`, the architecture.spec additions, all three channel test suites, and the full FE diff (`/tmp/71-fe.diff`: view + lib + hooks + client wrappers + generated SDK + nav/capability mirror + 15-test surface suite + 200-line vocabulary suite). Test runs first-hand: `channel-buffers`/`channel-sync`/`channel-connections` **25/25 pass**; `reservations.spec` + `inventory-surfaces.spec` pass with `channel-buffers` alongside (**53/53**) — the standing arm did not disturb the reservation-core suites.

**Matrix audit (8 rows):** every arm has its controller route, dto shape, error arms and a passing test; the buffer route reads the single-`channels` segment; the DELETE is 204 with idempotent replay; the list carries no secrets (leak scans over response/outbox/audit/idempotency, both plaintext AND sealed blob).

**Post-patch verdict:** F1–F3 were fixed by the patch round and re-verified first-hand from the diff (dead code fully removed, no stray references; CHECK in place; no reference to the dead DTO in any json/openapi artifact). Re-run on the patched tree at settled load: the four suites **63/63 pass in 25s** — the interim "7 failed / 9 failed / 1,041s" runs coincided with a machine load spike (~40) and were CPU starvation, not code.

**Open findings (triaged → patch round):**
- **F1 (dead code, fixed):** `RESERVATION_MIRROR_INCREMENT_SCRIPT` + `ValkeyClient.incrementCounter` had zero callers — removed in wms-be `12350c2`.
- **F2 (doc-truth + missing guard, fixed):** migration 0050 lacked the envelope CHECK on `integrations.credential_sealed` that `channels.md` described and carriers' 0025 has as precedent — `integrations_credential_sealed_envelope` CHECK (LIKE 'v1:%') added in `12350c2`; the doc row is now true.
- **F3 (dead DTO, fixed):** `ChannelConnectionListResponse` removed in `12350c2`; the exported openapi never carried it (no drift impact).
- **F4 (doc-accuracy):** channels.md's event-payload row shows `{warehouseId, skuId, quantity, quantityMilli, publishedAt}`; the actual `PublishedScope` is `{warehouseId, skuId, visibleMilli}`. Fix the doc row.
- **F5 (wire-contract nicety, deferred):** the list-entry `buffers` array is `type: [Object]` on the wire, so the generated FE type is opaque `{[key: string]: unknown}`, stitched back via `entryBuckets`. A nested DTO class would keep it typed end-to-end; deferred as a PENDING row (the FE handles it honestly today).

*(F2/F4's doc fixes land in the meta repo at step-05's docs commit; F1/F2-code/F3 go to the implementation agent as one patch round.)*

## Spec Change Log

*(appended during implementation; each entry names the arm it changed)*

- **Arm-5 route path read as a type (route fixed at implementation).** The spec's `PUT /channels/connections/:id/buffers` was written with a doubled `channels/channels/` wire segment; implemented as `PUT /tenants/:tenantId/channels/connections/:connectionId/buffers` — one `channels` segment, under the existing connection nesting. No consumer ever held the doubled form.
- **Publish fan-out shape.** `ChannelsPublishService` publishes one snapshot per SKU × tenant warehouse (a scope = a mapped SKU at one warehouse), not one blob per connection — the envelope RN-6's `V(c)` defines per scope.
- **Revoke before delete.** The disconnect FIRST meters the marketplace revoke attempt through the port (logged, never blocking — an unreachable channel keeps no say; AD-15 makes deletion a local atomic act), THEN re-locks the row, deletes it with the sealed blob inside, drops the mappings and releases the buffers through the core. A failed revoke never blocks the delete (spec arm 3, read literally).
- **Facade-only mapping seed.** SKU mappings seeded through the inventory/catalog facade read (a connection with zero mappings publishes nothing) — there is no mapping-write route in 7-1; the surface edits buffers, mappings are a later deliverable.
- **`RoutedEventBus` provider swap.** The availability delivery goes through the shared `RoutedEventBus` with a `channel-availability-port` provider — the same port/adapter seam as the carriers' 4.6b (501 transport-unconfigured arms standing in).
- **RN-5 semantic pin: half-open only from open.** Manual retry from a *closed* breaker is still a normal re-append (it returns the snapshot) but does NOT flip the breaker through half-open; the half-open transition is reachable only from `open`.
- **Suite-side provider-CHECK swap.** `channels_integrations.provider` CHECK allows only the frozen three; the test adapter swaps the CHECK constraint suite-side (`admitTestProviderInDb`) on a throwaway clone the way suites already treat the provider CHECK on other tables.
- **ApiProperty nullable-union type pins.** `ChannelConnectionResponse` / list-entry dtos pin `type: String`/`Number` explicitly on every nullable union field (the carriers precedent) — tsc's jest decorator metadata renders `string | null` as `Object` under swc, which the served-vs-exported drift guard would otherwise catch per-arm. Should be the standing convention for any new nullable union exposed on the wire.