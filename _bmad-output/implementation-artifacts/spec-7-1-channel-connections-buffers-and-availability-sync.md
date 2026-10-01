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
- **Arm-5 refusal surface: per-item 409 → 200 + refused verdicts.** The frozen row's "per-item `409 buffer-over-ceiling`" ships instead as a 200 carrying per-item verdicts — a refused item's verdict carries `code: 'buffer-over-ceiling'` and the old standing figure (the FE, the controller and the 25 suite tests all agree on the 200 shape; the frozen sentence stays as written). The request-level 409 remains the concurrent-idempotency case only.
- **T2's increase-arm machinery.** The frozen T2 sentence ("existing row `releaseInTx` + delta, absent row `grantInTx`") describes the decrease arm; the increase arm runs probe → the GRANT script (counter arbitrates `reserved + delta ≤ ceiling`) → journal UPDATE/INSERT under the A2 stock-row revalidation (the `applyStandingBuffer` head documents the real shape) — counter and journal end equal without a post-commit mirror on the increase.
## Review Triage Log

*(step-04's three reviewers — blind-hunter (18 findings), verification-gap (2 pre-verified gaps + 3 others), edge-case-hunter (22 claims, coverage disclosed) — every entry verified first-hand at the cited code before a verdict: BE `channels.command.ts` (all seven hash/replay/settle paths), `reservation.service.ts` `applyStandingBuffer`/`channelVisibleQuantity`, `jobs.module.ts` tick, `channel-availability.delivery.ts`, `channels.dto.ts`, `channels.view.ts`, 0050 + 0048/0049, FE `channels-view.tsx`/`channels.ts`, PENDING.md, API-SURFACE.md, repo READMEs.)*

| # | Source | Verdict | Route | Finding (verified) |
| --- | --- | --- | --- | --- |
| 1 | edge/blind 16 | high | patch | **`retryConnection` and `disconnect` share an identical `payloadHash`** (`hashCommandPayload({tenantId, connectionId})` both, `channels.command.ts:640` / `:819`): a caller reusing one key across the two arms settles the second arm from the first's key row without any work — a disconnect under a retry-settled key answers 204 and never deletes. Fix: an arm discriminator inside each hash object (same key + different arm then 422s `idempotency-key-reuse`, the honest contract). |
| 2 | edge | high | patch | **Orphaned standing buffers on a concurrent disconnect.** `setConnectionBuffers` locks the connection only in Phase-1; the per-item `applyChannelBuffer` txs never re-check it. A disconnect committing between the phases mints `held` rows (`expires_at: null`) for a deleted owner that no surface can release (the reaper skips TTL-null rows). Fix: Phase-3's key tx re-checks the connection and releases every owner row it still finds (by reservation id, through `releaseReservationInTx`, with the post-commit mirrors), exactly the delete's own semantics. |
| 3 | blind/edge 7 | high | patch | **The sync worker's non-503 `throw error` aborts the cycle** (`jobs.module.ts:767`), so a deterministically-failing head connection starves every later connection every cycle — contradicting its own "a poison connection must not starve the rest" doc. Fix: log-and-continue for every failure (the 503 stall case keeps its stamping branch); the outer catch stays the cycle-level log. |
| 4 | blind 15 / edge 9 | high | patch | **`BufferEditor.addRow` keys are `new-${prev.length}`** — add, remove, re-add mints a duplicate React key (add×2 → `new-0`,`new-1`; remove the first; re-add → `new-1` again); `patch()` then edits both rows. Fix: a monotonic per-editor key sequence. |
| 5 | blind 4 / edge 6 / verigap | medium | patch | **The refusal path's standing read is `.catch(() => 0)`** (`channels.command.ts:574–577`): a failing `channelVisibleQuantity` report reports "refused, standingMilli 0" while the old buffer still stands — the FE renders the lie. Fix: drop the catch (a store-down read 503s the whole request, the same fail-closed shape the item arbiter itself carries). |
| 6 | verigap-2 (dup: blind 17) | medium | patch | **The backorder-policy arm has no driving FE test** (`client.ts` PUT at `channels-view.tsx:501` is never dispatched; `updateConnectionConfigReason` covered nowhere), while the wms-fe README says the suite "pins every arm". Fix: one test driving the select (PUT body + fresh key + saved sentence + re-read + refusal mapper) plus a `channels.test.ts` pin on `updateConnectionConfigReason`. |
| 7 | verigap-1 | medium | patch | **The delivery handler's two ACK-without-effect branches are untested** (malformed payload → ack `:60–65`; connection-gone → ack `:68–73`); a fail-loud refactor ships every suite still green. Fix: two `channel-sync.spec.ts` tests seeding those outbox rows directly, asserting ack-delete with no meter row and no stamp. |
| 8 | blind 5 | medium | patch | **The DELETE `@Delete` route documents only 400/401/403/404** but both 409 (`concurrentIdempotency`, phase-2 key insert) and 422 (`idempotency-key-reuse`, replay hash mismatch) are reachable arms. Fix: the two `@ApiResponse` rows, like every sibling route. |
| 9 | edge 10 | medium | patch | **A removed-then-re-added scope is silently cleared:** `removeRow` queues the old scope into `cleared`; re-adding the scope with a new figure still sends the trailing 0-clear, which the per-item order applies LAST — the re-set buffer ends 0. Fix: when building `items`, drop a `cleared` entry whose scope any row re-introduces. |
| 10 | edge 13 | medium | patch | **`BufferEditor` row state never re-derives after a list re-read** (initializer only runs on mount; the editor has no entry-keyed remount) — after save/retry the editor prefills stale figures. Fix: key the editor by a buffers fingerprint (or `entry.updatedAt`) so a re-read remounts it. |
| 11 | blind 2 | medium | patch | **`channel-registry.ts:13` claims "a new channel is one registration and no migration"** while `channels.md:31` (truthfully) says the `provider` CHECK's IN-list must be widened by a migration. Fix: the comment. |
| 12 | blind 7 | medium | patch | **`docs/repos/wms-be/README.md`'s AUTH_DATABASE contract omits the ChannelsSyncWorker's BYPASSRLS enumeration** — now the fifth sanctioned cross-tenant read; the contract of record is stale by one consumer. Fix: extend the enumeration sentence. |
| 13 | blind 10 | medium | patch | **The buffers PUT writes no audit row** where every sibling command does (replenishment's five, the channels arms' five) and the command-skeleton's step 10. Fix: one `channels.buffers_set` audit row in Phase-3's key tx (no outbox event — no consumer exists; the next publish cycle already carries the availability delta). |
| 14 | blind 1 | false | — | Frozen matrix row 5's doubled `channels/channels/` path — the frozen section is not editable and change-log entry 1 already records the taken route. |
| 15 | blind 13 | false | — | Missing statement-breakpoints at 0050's joins — false: 0050's markers match the 0048/0049 hand-append convention verbatim (ENABLE + CREATE POLICY pairs share a chunk by convention everywhere). |
| 16 | blind 6 | false | — | "Revoke failed, delete blocked, connection still standing" — cannot occur: the disconnect NEVER blocks the delete on the revoke (verified `channels.command.ts:690–746`); its real documentation gap is finding 8. |
| 17 | blind 18 | false | — | No polling on `useChannelConnections` — the repo-wide convention (no surface polls; FE re-reads on explicit mutation + the nav's reload-on-visit); per-surface polling would be a new cross-cutting decision, not a 7-1 slip. |
| 18 | blind 16 / edge 12 | low | patch | **The buffer editor sends empty `''` ids** when warehouses/SKUs are missing or a row is left on the blank option — the served `400` bypasses the promised local refusal. Fix: local refusal naming the missing selection. |
| 19 | blind 14 | low | patch | The FE idempotency test pins `length ≥ 26` where the wire contract is exactly 26 — `toBe(26)`. |
| 20 | edge 14 | low | patch | **`fieldSpecs` returns `CHANNEL_CREDENTIAL_FIELDS[provider]` unguarded** — a mirror-missed provider's entry crashes the card column on `.filter`. Fix: `?? []`. |
| 21 | edge 11 | low | patch | No local guard for a save exceeding the 200-item BE bound → whole-request 400 with no verdicts (a 200-buffer connection + one add). Fix: a local refusal naming the bound. |
| 22 | edge 20 | low | patch | **`API-SURFACE.md:197` lists `rotatedAt/By` in the GET list entry** — true of the mutation snapshots' `ChannelConnectionResponse` only; the list entry dto omits them. Fix: the doc row. |
| 23 | edge 21 / (blind) | medium | patch | **No change-log entry for the arm-5 refusal reshape** — the frozen row's "per-item `409 buffer-over-ceiling`" ships as `200` + `refused` verdicts (the FE, controller and 25 tests all agree with the 200 shape; only the frozen sentence disagrees). Fix: a change-log entry documenting the reshape (frozen text untouched). |
| 24 | edge 23 | low | patch | **T2's increase-arm machinery sentence** ("existing row `releaseInTx` + delta, absent row `grantInTx`") describes the DECREASE arm; the increase is probe → grant script → journal UPDATE/INSERT under the A2 revalidation (as `reservation.service.ts`'s own head documents). Fix: a change-log entry. |
| 25 | edge 22 | false | — | Crash-after-items-before-key-insert replay "applies different verdicts" — the change-log'd replay semantics (absolute targets, "a partial run's re-application is a no-op") cover this; a pre-settle crash is not entitled to the settled response, and the re-application is the documented safe path. |
| 26 | verigap | false | — | "Dead `testAvailabilityArm`" — it IS used: `test/channel-sync.spec.ts:14,51` registers it as the test adapter's arm through `admitTestProviderInDb`. |
| 27 | verigap | false (partial) | patch (comments) | `LoggingEventBus` "retired" is deliberate (`shared.module.ts:41`) and its carriers-file mentions are accurate lineage citations — but `inventory.module.ts:29`'s "stays the delivery seam untouched" is now false. Fix: that one comment. |
| 28 | edge 4 | low | defer | Rotate commits between the revoke read and the delete re-lock: the new blob is deleted locally while the stale one was revoked — unreachable until a real transport exists (the port 501s today), and the window is milliseconds. PENDING with 7-2's transport story (re-read the credential at the re-lock, or revoke again post-re-lock). |
| 29 | edge 3 | low | patch | **Concurrent same-key disconnects: the phase-2 loser 404s** where `retryConnection`'s double-replay check would 204. Effect done, but the arms are asymmetric. Fix: re-run `replayDisconnect` before the phase-2 404. |
| 30 | edge 5 | low | defer | Concurrent same-target `applyStandingBuffer` increases: the INSERT path 409s + compensates exactly (unique index); the UPDATE path ends counter-over-reserved by one delta (**fail-safe direction**) with journal correct, healed by the parity pass. Serialization belongs to the core and is not worth it now — PENDING note. |
| 31 | blind 11 | low | defer | `channelVisibleQuantity` reads pool ATP and the owner buffer in two txs — a concurrent reservation bakes a staleness delta into one publish figure, self-correcting next cycle (RN-6's committed-read semantics, same as step-03's minor note). Fixing means a combined core read — PENDING. |
| 32 | edge 16 | low | defer | Row deleted between `integrationForDelivery` and `recordDelivery` → rethrow burns the relay's retry budget (5) then DLQ noise for a dead connection; millisecond window, bounded. PENDING (have `recordDelivery` report gone and skip the rethrow if a consumer ever feels it). |
| 33 | edge 18 | low | defer | `integration_calls` rows for a disconnected connection are never cleaned (no FK/cascade, no retention policy). PENDING: an ops retention/cleanup policy question, not a 7-1 defect (append-only meter by id). |
| 34 | blind 8/9/12/19 + edge 17/19 | — | docs (step-05) | Meta-doc round at close: PENDING grows the F5 wire-shape row (promised in the change log), the truncation-signal row (B9 — the same shape as movements' 5-1 entry), the six defer rows above; `docs/design/modules/channels.md` says its envelope CHECK honestly (prefix-only `v1:` — the carriers precedent — not the full four-part shape) and drops the doubled-path claim; `API-SURFACE.md` GET row loses `rotatedAt/By`; PENDING.md gets its blank line before `## movements`; `channel-availability-port.ts:38`'s "FULL snapshot" wording gains the 200-cap caveat (BE comment → patch round). |

*(The patch round — one implementation agent, no push — executes entries 1–13, 18–21, 27, 29, the BE comment of 34, and the two spec change-log additions of 23–24 (the tail section; the frozen rows stay untouched). The meta-doc rows — 22, 34's meta parts, the PENDING additions, the 28/30–33/31 defer rows — land at step-05's docs commit.)*

*(Patch round applied and RE-VERIFIED first-hand: BE `972f5e3` — every hunk of the 8-file diff read personally, incl. the arm discriminators, the disconnect double-replay, the Phase-3 compensator (compensation rides the key tx, mirrors only on the committed path), the audit row, the 409/422 arms and the worker's log-and-continue; FE `122a497` — the editor fixes read personally, plus one comment of the agent's own made honest (the re-added scope's cleared entry is dropped for ANY row value, not kept-both). Suites on my side at settled load: BE four-suite set **65/65** (the prior 63 + the two new delivery-arm tests), FE `channels-view` **17/17** + `lib/channels` **13/13**, `tsc --noEmit` clean both repos. Step-04 closes; step-05 presents.)*
