
- source_spec: `_bmad-output/implementation-artifacts/spec-1-1-monorepo-scaffold-and-design-system-shell.md`
  summary: DESIGN.md (the authoritative token source every repo's tests/docs cite) is not committed to any repository — `_bmad-output/` is untracked in the meta repo.
  evidence: Verified — `_bmad-output/` shows as untracked in meta git status; wms-fe token tests and both interface-contract READMEs cite a path that exists in no clone. Settle by committing the planning artifacts (or a copy of DESIGN.md) to the meta repo — a meta-repo tracking decision for the owner.
- source_spec: `_bmad-output/implementation-artifacts/spec-1-1-monorepo-scaffold-and-design-system-shell.md`
  summary: The temporary `mobile/` app inside wms-fe hand-writes `HealthResponse` instead of generating types from the OpenAPI contract; nothing verifies it stays aligned.
  evidence: Verified — `mobile/src/api.ts:6-18` hand-mirrors the backend shape with an untyped `res.json()` cast and has zero test coverage. Settle at extraction to the wms-mobile repo: generate mobile types from the same spec (or add a small comparison test against `openapi/openapi.json`).

## Deferred from: code review of spec-1-1 (2026-09-08)

- `decodeCursor` throws a plain Error (renders as 500 internal-error through the problem-details filter) and never validates `createdAt` as a real ISO-8601 UTC instant, though `assertUtcIso` exists in the same shared layer — a garbage-but-base64-decodable cursor would flow into future keyset SQL. Deferred because the primitive has zero consumers until the first list endpoint (story 1.2); where the 400 mapping belongs (primitive vs controller) is unsettled until then. Settle when wiring the first cursor-paginated endpoint: map malformed cursors to 400 `validation-failed` and validate the payload shape there.

- source_spec: `_bmad-output/implementation-artifacts/spec-1-2-tenant-registration-and-warehouse-creation.md`
  summary: `requireActiveWarehouse(tenantId)` returns the newest warehouse (arbitrary "active"), which will collide with the frontend's localStorage-picked warehouse once Epic 2 defines a real active-warehouse concept.
  evidence: Unverified design prediction (maybe-false; medium if true) — nothing in Story 1.2 contradicts it. What would settle it: Epic 2's active-warehouse design (server-side pick vs the sidebar's per-viewer pick) — decide one authority and align `requireActiveWarehouse` or the switcher to it.

- source_spec: `_bmad-output/implementation-artifacts/spec-1-2-tenant-registration-and-warehouse-creation.md`
  summary: Drizzle-orm 0.45 cannot model RLS in `schema.ts` (no `enableRLS` export; `pgPolicy` declarations would conflict with the hand-written 0001 policy DDL), so the drizzle snapshot records `isRLSEnabled: false` — RLS state is invisible to drizzle-kit.
  evidence: Verified against the installed toolchain — `drizzle-orm/pg-core` 0.45.2 exports only `pgPolicy`; declaring the four policies in schema would make the next `generate` emit `CREATE POLICY` against already-existing policies (migration apply failure). Residual risk is a from-scratch migration regeneration losing the hand-written RLS block, not forward generation. Settle when: drizzle-orm ships `enableRLS` (or the repo upgrades drizzle-kit) — then declare RLS+policies in schema.ts and regenerate the snapshot chain in one migration.

## Deferred from: review loop 2 of spec-1-2 (2026-09-08)

- source_spec: `_bmad-output/implementation-artifacts/spec-1-2-tenant-registration-and-warehouse-creation.md`
  summary: `POST /tenants/sign-in` has no rate limiting or lockout — password brute-force is unthrottled. Human resolution (2026-09-08): deferred, tracked — consistent with the minimal-sign-in decision (HS256, no refresh).
  evidence: Verified — no throttle in `sign-in.command.ts` or the controller. Settle when: the auth-hardening/infrastructure story lands (per-IP + per-email attempt counter, 429 after N failures, or an upstream WAF/rate-limiter at the edge).
- source_spec: `_bmad-output/implementation-artifacts/spec-1-2-tenant-registration-and-warehouse-creation.md`
  summary: `idempotency_keys` retention is unbounded — one row per mutating request, no cleanup job or trigger.
  evidence: Verified — Design Notes say "retention bounded later (AD-5)" but nothing records an owner. Settle when: data-retention policy is defined (a scheduled job deleting rows older than N days is safe — rows only matter for replays of recent requests).

- source_spec: `_bmad-output/implementation-artifacts/spec-1-3-zones-bins-and-the-setup-checklist.md`
  summary: The tenancy domain events (`zone.created`, `bins.generated`, `bin.blocked`) — and the 1.2 predecessors — have no test observation; pin them when the first real subscriber/outbox lands.
  evidence: Verification-gap layer grep — no test reads the `EVENT_BUS` seam; the only registered implementation is the log-only `LoggingEventBus` with no subscribers, so a removed publish or drifted payload fails nothing in CI today.

- source_spec: `_bmad-output/implementation-artifacts/spec-1-4-catalog-import-with-partial-commit-and-fix-mode.md`
  summary: `skus` lacks a `(tenant_id, created_at, id)` composite keyset index (the SKU list pages with `WHERE tenant_id ORDER BY created_at DESC, id DESC`; `catalog_imports` got one, `skus` didn't).
  evidence: Verified in schema.ts/0004 SQL — only bare `skus_tenant_id_idx` + `(created_at, id)`. Fix is a new migration; per-tenant catalogs are small at this stage. Settle when: catalog volumes grow (Epic 2/3 consumption or the bin-administration-style catalog story).
- source_spec: `_bmad-output/implementation-artifacts/spec-1-4-catalog-import-with-partial-commit-and-fix-mode.md`
  summary: The catalog domain events (`catalog.imported`, `catalog.sku_edited`) have no test observation; pin them when the first real subscriber/outbox lands.
  evidence: Verified — no test reads the `EVENT_BUS` seam; only consumer is the log-only `LoggingEventBus` (mirrors the 1.3 deferral for the tenancy events).
- source_spec: `_bmad-output/implementation-artifacts/spec-1-4-catalog-import-with-partial-commit-and-fix-mode.md`
  summary: No retention/cleanup story for the catalog append-only tables (`catalog_imports`, `catalog_import_errors`) — this story adds three more append-only tables alongside `idempotency_keys` (1.2 deferral).
  evidence: Verified — rows are written forever with no pruning; the import-error ledger is the fix-mode input so recent rows are load-bearing, but old rows have no owner. Settle when: the data-retention policy is defined.

- source_spec: `_bmad-output/implementation-artifacts/spec-1-5-users-roles-and-permission-gating.md`
  summary: The wms-fe `ROLE_CAPABILITIES` UI mirror has no cross-repo drift guard — nothing fails in wms-be CI when the backend capability matrix changes.
  evidence: `src/lib/users.ts` hand-duplicates `wms-be/src/modules/tenancy/permissions.ts`; the only pin is a hardcoded capability-count assertion in `src/lib/users.test.ts`. Settling it needs generating the mirror from the backend (shared constants or an OpenAPI extension), which is new cross-repo build machinery beyond this story.
- source_spec: `_bmad-output/implementation-artifacts/spec-1-5-users-roles-and-permission-gating.md`
  summary: Migration 0005's owner backfill (`UPDATE users SET role = 'owner'`) is never verified against a database containing pre-0005 user rows.
  evidence: CI migrates only fresh databases, so a regenerated migration silently dropping the hand-appended UPDATE would go undetected until deploy, demoting every pre-existing account to `operator`. Settling it needs a migration-state test harness (apply 0001–0004, seed rows, apply 0005, assert role) the repo doesn't have; a release-checklist note is the interim guard.

- source_spec: `_bmad-output/implementation-artifacts/spec-2-1-append-only-ledger-core-and-derived-quantities.md`
  summary: ~~Transactional outbox substrate + relay (jobs shell) and the retrofit of the five epic-1 command files' `publishSafely` call sites onto in-tx outbox inserts with `{snapshot, replayed}` suppression parity~~ **RESOLVED 2026-09-09** — landed as its own spec (`spec-outbox-relay.md`, PR #9, merged `ee543d9`); retrofit scope widened at CHECKPOINT 1 to all 12 publish sites across 9 files (AD-6 as tightened); retro item `epic-1-retro-item-3` (users.command replay suppression) closed.
  evidence: Implemented per spec with migration 0007, `PostgresOutboxSink`/`PostgresOutboxRelay`, env-gated `OutboxRelayWorker`, and the 11-type event coverage pinned in `test/outbox.spec.ts` / `test/outbox-worker.spec.ts`; review triaged 38 findings (9 patch groups applied, 5 deferred above, 14 rejected); 119/119 tests green.

## Deferred from: review of spec-2-1 (2026-09-08)

- source_spec: `_bmad-output/implementation-artifacts/spec-2-1-append-only-ledger-core-and-derived-quantities.md`
  summary: `idempotencyKeyReuse()` lives in `tenancy/registration.command.ts`, and `inventory.command.ts` adds an eighth importer across three modules (users/warehouse/zone/bin within tenancy, catalog sku/import cross-module since epic 1) — the helper belongs beside `hashCommandPayload` in `tenancy/idempotency-guard.ts`.
  evidence: Verified import graph (`grep idempotencyKeyReuse src/`) — the misplacement is pre-existing epic-1 shape, not introduced by this story; the fix is a cross-module refactor moving the helper and updating all import sites, belonging to its own cleanup rather than this story's patch.
- source_spec: `_bmad-output/implementation-artifacts/spec-2-1-append-only-ledger-core-and-derived-quantities.md`
  summary: No controller in `src/api` validates uuid path params with `ParseUUIDPipe` (incl. the two new inventory routes) — a non-uuid path param reaches the drizzle `::uuid` binding and renders as 500 instead of 400.
  evidence: Verified — repo-wide grep finds zero `ParseUUIDPipe` in `src/api`; the new endpoints mirror every epic-1 controller's shape. Settling it is a repo-wide hardening pass (add the pipe across all controllers), not a per-endpoint patch.
- source_spec: `_bmad-output/implementation-artifacts/spec-2-1-append-only-ledger-core-and-derived-quantities.md`
  summary: The RLS policies' `NULLIF(current_setting('app.tenant_id', true), '')::uuid` cast errors the session (22P02) instead of failing closed when the setting holds a non-uuid non-empty string — now on six policies across three migrations.
  evidence: Confirmed as coded, but it is the 0005-established repo-wide pattern (app code always sets a validated uuid via `withTenantTransaction`); settling it needs one shared `to_uuid_or_null` hardening across all policies in a single follow-up migration.
- source_spec: `_bmad-output/implementation-artifacts/spec-2-1-append-only-ledger-core-and-derived-quantities.md`
  summary: ~~`anchorChain` commits a digest without running the chain verifier over the anchored range — full verify-before-anchor (recompute the range's hashes before committing) is the fuller guarantee~~ **RESOLVED 2026-09-09** — landed in Story 2.2 exactly as this entry anticipated (the reconciliation story as runner): `anchorChain` now runs `verifyChainInTx` over its range inside the anchor transaction and refuses to commit an anchor over a broken range (PR #10, merged `b0b14ad`).
  evidence: Implemented per spec-2-2 with the anchor-refusal path pinned by `test/reconciliation.spec.ts` ("verify-before-anchor: a tampered ledger range refuses the anchor, commits nothing, and fires the severity-1 alert").

## Deferred from: review of spec-outbox-relay (2026-09-09)

- source_spec: `_bmad-output/implementation-artifacts/spec-outbox-relay.md`
  summary: Consolidated RLS ::uuid-cast hardening now spans seven policies across four migrations (0007's `outbox_messages_tenant_isolation` joins the 2.1-deferred list) — non-uuid non-empty `app.tenant_id` errors the session (22P02) instead of failing closed.
  evidence: Verified in `drizzle/0007_pretty_silver_samurai.sql` — same `NULLIF(current_setting(...))::uuid` pattern as 0005/0006; app code always sets a validated uuid via `withTenantTransaction`. Settle with the already-deferred shared `to_uuid_or_null` hardening in one follow-up migration covering all policies.
- source_spec: `_bmad-output/implementation-artifacts/spec-outbox-relay.md`
  summary: `drizzle/meta/0007_snapshot.json` records `outbox_messages` as `isRLSEnabled: false` while migration 0007 enables RLS — the snapshot misrepresents the live table (extends the 1.4-deferred drizzle-RLS limitation to the new table).
  evidence: Verified — drizzle 0.45 cannot model RLS; the hand-appended policy is invisible to drizzle-kit. Settle when drizzle-orm ships `enableRLS` (same trigger as the existing entry).
- source_spec: `_bmad-output/implementation-artifacts/spec-outbox-relay.md`
  summary: The operator DLQ runbook (quarantined rows + `OUTBOX_OPERATOR_REPLAY_SQL`) exists only in code — no operator-facing doc says quarantined rows exist or how to re-drain them.
  evidence: Verified — the SQL is exported in `src/shared/events/outbox.ts` with a doc comment, nothing else. Settle in the post-merge meta docs pass (interface contract + ops note), which is already planned for this story.
- source_spec: `_bmad-output/implementation-artifacts/spec-outbox-relay.md`
  summary: A hung `drain()` (no statement/connection timeout is configured on the postgres.js pool) would leave the worker's `running` flag stuck true — the relay silently stops draining.
  evidence: Maybe-false (unverified) — a hang needs an indefinite connection stall; if true, severity medium (silent stop). Settle by configuring/verifying postgres.js `connection_timeout`/statement timeouts, then decide whether the worker needs a drain timeout race.
- source_spec: `_bmad-output/implementation-artifacts/spec-outbox-relay.md`
  summary: `verifyChain`'s new fail-loud contract for the chain-broken alert append (a throwing append now rejects `verifyChain` instead of being swallowed) is unpinned by any test.
  evidence: Verified — `test/ledger.spec.ts` tamper probe exercises the success arm only; re-wrapping the append in try/catch would pass unchanged. The failure arm needs a fault-injected `OUTBOX_SINK` stub; settle when the next ledger-verification story touches `verifyChain` anyway.
- source_spec: `_bmad-output/implementation-artifacts/spec-2-3-real-time-atp-and-atomic-reservations.md`
  summary: The `db:verify` drift guard round-trips only `app_metadata`, so hand-appended migration SQL (RLS policies and CHECK constraints on 0006-0009 tables) is never verified to exist by CI.
  evidence: Verification-gap review of story 2-3 (triage row R62): `src/shared/db/verify.ts:11-22` round-trips only app_metadata; a regeneration or dropped hand-append on any of these tables would pass the migrations CI job. Pre-existing repo-wide pattern (0006-0008), extended by 0009 — not caused by story 2-3; a repo-wide guard fix belongs to its own change.

## Deferred from: review of spec-2-4 (2026-09-09)

- source_spec: `_bmad-output/implementation-artifacts/spec-2-4-batch-and-serial-traceability.md`
  summary: The adjustment endpoint's OpenAPI failure surface is under-documented — the new 400/404/409 `serial-elsewhere`/422 `@ApiResponse` descriptions (and the batch/serial arms' error semantics) are not in `openapi/openapi.json`.
  evidence: Verified — only the request-body schemas gained properties; no response-documentation additions were made. Deferred because frozen CHECKPOINT 1 pins the 2.4 openapi diff to request-body-additive only; HTTP error-surface documentation belongs to story 2.5, which owns the inventory HTTP read/response surfaces.

## Deferred from: review of spec-3-1 (2026-09-09)

- source_spec: `_bmad-output/implementation-artifacts/spec-3-1-po-creation-and-lifecycle.md`
  summary: The PO responses pin `openQty` with `minimum: 0` in `openapi/openapi.json`, but story 3.3's over-receipt-approval design may let received exceed ordered (openQty negative) — under the additive-only OpenAPI rule (AD-8), relaxing a schema constraint later is a breaking contract change.
  evidence: Verified — the PO line response schemas declare `openQty` with `minimum: 0`; 3.1's invariant holds (received ships 0), but the 3.3 over-receipt decision could invalidate it. Settle when story 3.3 defines over-receipt semantics: either relax `minimum` in that story's additive diff or confirm the floor holds.
- source_spec: `_bmad-output/implementation-artifacts/spec-3-1-po-creation-and-lifecycle.md`
  summary: `decodeCursorSafe` now exists in a 4th place (`inbound.facade.ts`, alongside tenancy.service, inventory.facade, and the reservation read) and `canonicalInstant` in a 5th — the A3-style consolidation that unified `UUID_RE` did not cover these.
  evidence: Verified by grep — four module-local `decodeCursorSafe` copies and five `canonicalInstant` copies; the inbound copy additionally diverged (shape-regex instead of `Date.parse`, patched back to parity in this story). Settle with a shared-primitive cleanup: export one `decodeCursorSafe`/`canonicalInstant` from `src/shared/primitives/` and update all call sites.
- source_spec: `_bmad-output/implementation-artifacts/spec-3-1-po-creation-and-lifecycle.md`
  summary: The new `vendor.manage`/`po.manage` capabilities widen the unguarded wms-fe `ROLE_CAPABILITIES` UI mirror — nothing fails in wms-be CI when the backend capability matrix changes (open retro item A12, epic-1 item 4).
  evidence: Verified — `wms-fe/src/lib/users.ts` hand-duplicates the backend matrix; the capability-count pin there now drifts from `permissions.ts`. Settle with the A12 cross-repo drift guard (generate the mirror from the backend or pin via OpenAPI extension) — existing deferred machinery, not this story's patch.

## Deferred from: review of spec-3-2 (2026-09-09)

- source_spec: `_bmad-output/implementation-artifacts/spec-3-2-mobile-client-substrate-enrollment-badge-in-inbox-scanning.md`
  summary: The pre-auth idempotency replay lookup (device enroll, like registration/accept-invite before it) queries `idempotency_keys` by key alone — a tenant A replay of a tenant B's key is answered with tenant B's cached response instead of a 422.
  evidence: Verified — `enrollment.command.ts:332-336` key-only AUTH_DATABASE lookup, identical to the accepted precedent `registration.command.ts:74-78` (documented intentional at `docs/repos/wms-be/README.md:19`). Requires knowing a foreign tenant's key to exploit; response is a 422-shaped error, no data leak. Consolidate all three pre-auth commands onto a payload-hash-including lookup in one shared-primitives change.

## Deferred from: review of spec-3-3 (2026-09-10, review iteration 1)

- source_spec: `_bmad-output/implementation-artifacts/spec-3-3-scan-based-receiving-and-grn.md`
  summary: The mobile repo's real HTTP transport is never executed by any test — every suite injects fake senders, so a transport regression in `submitGoodsReceipt` (wrong path, dropped `Idempotency-Key` header, payload serialization drift) would quarantine every offline device receipt at replay with all test suites green.
  evidence: Verified — `src/api.ts:213` defines the real sender; `op-dispatch.test.ts` and `engine.test.ts` both inject fakes; the payload shape is pinned on both sides (`draft.test.ts` payload `toEqual`, wms-be e2e) but the transport wrapping is not. Settle with a stubbed-`fetch` transport test in the mobile repo — a test harness convention that repo does not have today; a separate initiative, not this story's patch.

## Deferred from: review of spec-3-4 (2026-09-10, review iteration 1)

- source_spec: `_bmad-output/implementation-artifacts/spec-3-4-qc-hold-and-release.md`
  summary: The holds-list keyset cursor encodes the ms-truncated canonical instant (`canonicalInstant` = `toISOString()`, ms precision) while the ledger's `created_at` keeps Postgres microseconds — rows whose `created_at` shares the boundary millisecond but carries a later sub-ms component are skipped on the next page. Same root cause as epic-2 retro item A1 (the shared cursor primitive encodes from the already-canonicalized item value via `buildPage`).
  evidence: Verified (edge-hunter E5, triage row E5) — `src/shared/primitives/pagination.ts` `buildPage` encodes from `items.at(-1).createdAt`, which the facades map through `canonicalInstant` before returning; `qc_holds` list is one more call site of the pre-existing pattern. Settle with epic-2-retro-a1 (encode full timestamptz precision in `encodeCursor`/`decodeCursorSafe`), not a story-local patch.

## Deferred from: planning spec-3-5 (2026-09-10)

- source_spec: `_bmad-output/implementation-artifacts/spec-3-5-directed-putaway.md`
  summary: The web suggestion-vs-actual putaway report surface (SM-3) — a report reading `putaway_placements` (compliance rate, per-line suggestion vs actual + recorded reason) — plus the pieces that make suggestions meaningful over time: the SKU velocity class (derived from ledger movement history), a nullable `zones.putaway_class` affinity field with the Settings zone-form dropdown, and the PRD's nightly slotting-suggestions job.
  evidence: Split at story 3.5's token gate (spec ≈2,700 tokens vs the 1,600 ceiling); the backend + mobile operator flow are one goal, the report surface is independently shippable (reads `putaway_placements`, no flow dependency). Human decision 2026-09-10: Split.

## Deferred from: review of spec-3-5 (2026-09-10, review iteration 1)

- source_spec: `_bmad-output/implementation-artifacts/spec-3-5-directed-putaway.md`
  summary: `PUTAWAY_MISMATCH_REASON_CODES` is hand-copied across surfaces without a drift guard (wms-be `putaway.dto.ts`, mobile `src/putaway/draft.ts`, the openapi enum, and the mobile UI's reason labels) and the web report surface has no FE consumer in this story (the Split). Settle with the deferred report story: export the enum from the OpenAPI document (the FE mirror pattern) or add a cross-repo drift test when the report story consumes placements.
  evidence: Verified (blind-hunter B15, triage row blind-15) — the enum literal appears in ≥4 places; the FE `api:generate` client regenerates it but nothing consumes it this story. The report surface (SM-3) is the human-deferred Split from the planning gate; the drift guard rides with it.

## Deferred from: review of spec-3-6 (2026-09-10, review iteration 1)

- source_spec: `_bmad-output/implementation-artifacts/spec-3-6-bin-administration.md`
  summary: The merge capacity gate counts arms but never cross-checks them — a batch arm's `batch_on_hand` sum could disagree with the merged `quantity`, and a serial arm with `batchRef: null` (a serial relocated by a hypothetical path that writes serial location without a matching batch projection delta) would merge into a batch-less stock row. Maybe-false (medium if true) — no shipped path is known that writes one without the other.
  evidence: Triage rows #10/#30/#33 (blind/edge) — `mergeBin` trusts `binOccupancyInTx`'s independently-derived stock vs batch vs serial triple without an equality assert between batch sums and arm counts. Settle with a projection-invariant proof or divergence test: either prove every ledger write path keeps `sum(batch_on_hand)` ≡ `stock_on_hand` per bin, or add the cross-check gate in `mergeBin`.
- source_spec: `_bmad-output/implementation-artifacts/spec-3-6-bin-administration.md`
  summary: Asymmetry — `mergeBin` cross-checks serial location against arm quantity via `serialsLocatedInBinInTx`, but `retireBin`'s empty gate trusts `stock_on_hand`/`batch_on_hand` alone; a bin with zero projections but a stale serial-location ledger entry (no known writer) would retire and strand the serial's location pointer on a retired bin.
  evidence: Triage rows #2/#31 (blind/edge, maybe-false) — no shipped path writes a serial-location ledger event without a matching projection delta, so the case is unreachable today. Settle by proving the invariant (no `to_bin_id` ledger append without a matching `stock_on_hand`/`batch_on_hand` delta in the same commit), or mirror the serial cross-check into `retireBin`.
- source_spec: `_bmad-output/implementation-artifacts/spec-3-6-bin-administration.md`
  summary: The merge all-or-nothing capacity gate (and retire empty gate) hold bin rows FOR UPDATE, but `adjustStock` still enforces no capacity check at all — a concurrent adjustment can move stock into the target after the gate read, overflowing it (the gate is correct only against commands that take the same row lock).
  evidence: Triage row #32 (edge, pre-existing) — verified `adjustStock` has zero capacity references (story 2.4 shipped it advisory on purpose); merge/retire now enforce hard limits but the two paths don't share a lock discipline. Settle with the stock-adjustment-hardening initiative: give adjustStock the bin-row lock and a capacity decision (reject or warn), one story covering all writers.

## Deferred from: code review of spec-4-1-orders-manual-entry-idempotent-ingestion-acceptance-reservation (2026-09-10)

- **Keyset cursors truncate microseconds to milliseconds** (`wms-be src/modules/outbound/outbound.facade.ts:160-167`) — `canonicalInstant` drops Postgres's microsecond `timestamptz` precision before the cursor is encoded, so rows created in the same millisecond as a page boundary can be skipped by the `(created_at, id) < (cursor…)` predicate. Pre-existing pattern, shared with `putaway.facade.ts` and the other list surfaces. Orders is the first table expected to see bulk ingestion (Epic 7), where sub-millisecond clustering is the normal case — fix it across all list surfaces together, before 7.2.
- **Orphan holds have no reaper** (`wms-be src/modules/outbound/order.command.ts:288-306`, `:583-601`) — a process crash between the grant phase and the create tx, or a `releaseAll` that itself fails while the store is down, leaves `held` reservations belonging to no order. They suppress ATP for the full 7-day TTL and nothing can release them. The direction is fail-safe (ATP understated, never oversold) and the code documents it, but a reconciler is new surface rather than this story's patch.
- **Order TTL equals counter TTL** (`wms-be src/modules/outbound/order.command.ts:99`, `src/modules/inventory/reservation.service.ts`) — `ORDER_RESERVATION_TTL_SECONDS` and `COUNTER_TTL_SECONDS` are both exactly 7 days, so a long-lived order hold ages out in the same window as the Valkey counter that arbitrates it. The order TTL should be strictly below the counter TTL, with the relationship asserted rather than left as a coincidence of two independently declared constants. Settle it alongside the reservation-expiry UX that story 4.1 explicitly excluded.
- **`orders_tenant_created_at_id_idx` is unused** (`wms-be drizzle/0017_ambiguous_santa_claus.sql`) — every read story 4.1 ships is by primary key (detail) or warehouse-scoped (list, which uses `orders_tenant_warehouse_created_at_id_idx`). No tenant-wide order list exists yet. Revisit when 4.2 defines the Outbound surface's reads rather than amending a CI-verified migration now.
- **Retry exhaustion is indistinguishable from out-of-stock** (`wms-be src/modules/outbound/order.command.ts:551-576`) — once the exhaustion path correctly backorders instead of throwing, a line contended off four attempts looks identical to a line with zero ATP: no log line, no response signal. Surfacing the difference needs a per-line reason code in the order response, a shape decision that belongs with 4.2's Outbound surface.
- **Grant-vs-quarantine remains a residual oversell race** (`wms-be src/modules/inventory/reservation.service.ts`, `revalidatedCeiling`) — epic-2 retro A2's re-validation locks the scope's `stock_on_hand` rows, which serializes grant-vs-adjustment (the race the retro named). It does not cover every ceiling contributor: `committedCeiling` also subtracts `qcHeldUnits` and excludes open `inventory_quarantines` scopes, so a QC hold or quarantine opened between the grant probe and the journal write lowers the ceiling without touching a locked row, and the grant can still journal above it. Closing it means widening the `FOR UPDATE` to those tables, which needs a lock-ordering audit first — the QC and quarantine commands take these locks in the opposite order, so a naive widening trades a rare oversell for a deadlock. Resolved by human decision 2026-09-11 as comment-correction now, fix in Epic 5 where the quarantine and variance work lives.

## Deferred from: build step-01 scope split of story 4.2 (2026-09-11)

- source_spec: none
  summary: The web Outbound surface — the orders card (deferred out of story 4.1), the waves/picklists UI, and the `orders.manage` FE permissions mirror in `wms-fe src/lib/users.ts`.
  evidence: Split from story 4.2 at the multi-goal gate (human decision 2026-09-11). Waves/picklists backend and the Outbound web surface are two independently shippable deliverables — each reviewable and mergeable as its own PR. The backend is what unblocks story 4.3 (mobile picking needs picklists as its task substrate); the web surface does not. **Tracked as its own story, not a deferred bullet** — `4-2b-outbound-web-surface` in sprint-status.yaml — because this surface has already been deferred once (out of 4.1) and `src/app/(app)/outbound/page.tsx` is still a literal placeholder reading "functionality lands in a later story". It must not slip a third time.

## Deferred from: code review of spec-4-2-waves-and-picklists (2026-09-12)

- source_spec: `_bmad-output/implementation-artifacts/spec-4-2-waves-and-picklists.md`
  summary: Batch expiry is judged on a UTC day boundary, so a batch expiring today stops being drawable from 05:30 IST — inside a codebase that otherwise reasons in Asia/Kolkata.
  evidence: `wave.command.ts` does `Date.parse(batch.expiryDate) >= now` on a `YYYY-MM-DD` column, which parses as UTC midnight. Real, but NOT introduced by story 4.2 — the shipped FEFO path at `src/api/inventory.controller.ts:368` uses the identical comparison, so this is a repo-wide semantic. Fixing it only in waves would make waves and stock adjustments disagree about what "expired" means. Fix both together, ideally when warehouses gain a timezone column.

- source_spec: `_bmad-output/implementation-artifacts/spec-4-2-waves-and-picklists.md`
  summary: A reservation can expire between wave generation and release, so a released picklist may direct picks against holds that no longer exist.
  evidence: Reachable via the 7-day reservation TTL and the reaper on an order still `accepted`. Bounded by the story's frozen design: a picklist's bin/batch is a suggestion re-derived at pick time, never an allocation, so story 4.3 re-validates before any draw. A release-time hold re-read would be a second, weaker guard invented outside the module that owns reservations — close it as part of 4.3's re-derivation instead.

- source_spec: `_bmad-output/implementation-artifacts/spec-4-2-waves-and-picklists.md`
  summary: Two open waves can suggest the same bin units for different orders; the second picker finds the bin already emptied.
  evidence: The direct and intended consequence of the frozen decision that a picklist line is a suggestion, not a bin-level allocation — reservations bind to (tenant, warehouse, sku) with no bin, and the spec's Never list forbids bin-level reservation. Closing it requires bin-level allocation machinery that Epic 2 does not have. Revisit if short-picks caused by cross-wave bin contention show up as a real signal in 4.4's short-pick aggregation.

## Deferred from: build step-01 scope split of story 4.3 (2026-09-12)

- source_spec: none
  summary: AD-14's per-bin `state_epoch` and the full 4-case conflict taxonomy (apply / settle / re-plan / quarantine) for offline replay.
  evidence: Split from story 4.3 at the multi-goal gate (human decision 2026-09-12). `state_epoch` is specified in ARCHITECTURE-SPINE.md:124 but has **no producer, no wire field and no comparison contract** anywhere in either codebase — story 3.5 deferred it explicitly, reasoning that "the ledger's sufficiency guard plus replay re-authorization covers concurrent divergence: a losing replay fails 422 insufficient-on-hand and quarantines, never corrupts". That remains true for 4.3's pick flow, which ships on the same proven behaviour. **Tracked as its own story** — `4-3b-state-epoch-and-conflict-taxonomy` in sprint-status.yaml — to land with or before 4.4, whose short-pick re-planning IS taxonomy case 3. Two things it must settle that the planning set leaves open: the taxonomy label mismatch (ARCHITECTURE-SPINE.md:124 says apply/settle/re-plan/quarantine, epics.md:505 says settled/re-authorized/rejected/quarantined — the spine wins per UX-DR24), and replay ordering (AD-4 says "replays in task order"; review-offline.md:106 proposes strictly chronological FIFO with task order as presentation only — the mobile client implements strict FIFO by sequence today).

## Deferred from: code review of spec-4-3-scan-verified-picking (2026-09-12)

- source_spec: `_bmad-output/implementation-artifacts/spec-4-3-scan-verified-picking.md`
  summary: A rejected op is deleted from the durable outbox, so a refused pick is unrecoverable after an app restart — nothing to review, replay, or reconcile against the physical move the operator already made.
  evidence: `wms-mobile/src/offline/engine.ts` filters the rejected op out of `remaining` and `replaceOps` drops it from SQLite; only the in-memory `lastSummary` survives, and that is lost on relaunch. UX-DR17 says physical picks are never silently written off. NOT introduced by 4.3 — this is epic 3's replay engine, and the story's frozen decision deliberately chose "exactly what epic 3 built", listing the durability gap as a known trade-off. Real fix is a durable client-side quarantine table or Epic 5's story 5.5 server-side review queue; settle it there rather than half-building one here.

- source_spec: `_bmad-output/implementation-artifacts/spec-4-3-scan-verified-picking.md`
  summary: `occurredAt` is trusted from the device with no skew bound, so a skewed clock or a long-queued op can judge batch expiry against the wrong instant.
  evidence: The pick path uses device time per AD-1, exactly as `putaway.place` has since story 3.5 — so bounding it only in picking would make the two flows disagree about what "now" means for expiry. Fix both together, ideally alongside the `Asia/Kolkata` vs UTC expiry-boundary item already deferred from story 4.2 (same root question: whose clock and whose day decides expiry).

- source_spec: `_bmad-output/implementation-artifacts/spec-4-3-scan-verified-picking.md`
  summary: The whole-quantity hold commits when the last `planned` slice is picked, even if `unfulfillable` sibling slices of the same order line were never drawn.
  evidence: The "last open slice" query filters `status = 'planned'` only. Committing a hold for units that never left a bin overstates what was fulfilled. This is the story 4.4 boundary: settling partially needs partial-commit machinery that reservations do not have (they are whole-quantity rows, `reservation.service.ts`). Record it rather than invent a half-measure — 4.4's short-pick re-planning is where partial fulfilment gets designed.

- source_spec: `_bmad-output/implementation-artifacts/spec-4-3-scan-verified-picking.md`
  summary: Rejected-but-retryable replay outcomes (409 concurrent-idempotent-request, 422 insufficient-on-hand) are deleted from the outbox rather than kept for a later attempt.
  evidence: Pre-existing epic-3 replay semantics shared by every queued op type, not introduced by 4.3. Changing it alters the replay contract for receiving and putaway too, and deciding WHICH codes are retryable is precisely the classification work AD-14's 4-case taxonomy exists to do — so it belongs with `4-3b-state-epoch-and-conflict-taxonomy`, not here.

- source_spec: `_bmad-output/implementation-artifacts/spec-4-3-scan-verified-picking.md`
  summary: A SKU that is BOTH batch- and serial-tracked cannot be picked — the command refuses it with a 400 rather than guessing which batch each serial belongs to.
  evidence: Introduced by the review pass on 4.3. The pick payload carries serial numbers but no batch; `serials` (schema.ts) holds no `batch_id`; and the ledger's serial guard validates LOCATION only. The original code paired FEFO arms to serials positionally, so a unit put away under batch Y could be drawn labelled batch X and `batch_on_hand` would mis-fold with nothing to catch it. Refusing is honest and cheap; the real fix is a `serialBatchInTx` read on `InventoryFacade` that resolves each serial's batch from the `batch_ref` on its latest ledger event (the putaway per-serial events carry it), which is a new inventory seam and its own change. No fixture in either codebase is currently both-tracked, so nothing regresses today.

- source_spec: none
  summary: Tenant-scoped carrier API credentials under envelope encryption — referenced by id, rotation first-class, disconnect deletes, secret material never in logs or ledger events (AD-15, FR-17).
  evidence: Split from story 4.6 at the scope gate (2026-09-15, Sasidhar chose dispatch-first). Independently shippable — it is an admin/settings capability with no dispatch dependency, and dispatch needs no carrier at all. Substrate is further along than the epic context implies: `wms-be/src/shared/crypto/envelope.ts` already provides AES-256-GCM seal/open with a documented KMS stand-in (`DEVICE_ENCRYPTION_KEY`), built generically for story 3.2's device enrollment. What does not exist is the tenant-scoped credential table, rotation, or disconnect-deletes. Note the master key is a STAND-IN, not a real KMS — that swap is its own decision when this lands.

- source_spec: none
  summary: The `CarrierAdapter` port and rate-shopping across configured carriers (FR-17).
  evidence: Split from story 4.6 at the scope gate (2026-09-15). `wms-be/src/modules/carriers/carriers.module.ts` exists but is a 15-line story-1.1 spine placeholder with no providers — the AD-6 module boundary is declared, the implementation is entirely greenfield. Pairs naturally with the credential store above as one "carrier substrate" story. OQ1 (final carrier set — Delhivery, Blue Dart, Ecom Express, Shiprocket) was deliberately left OPEN at the 4.6 gate: decide it here, when the port shape is concrete, rather than guessing up front and baking a provider's API shape into the port.

- source_spec: none
  summary: Label generation through the carrier adapter — retryable inline failure that never marks the order dispatched, p95 ≤ 5s.
  evidence: Split from story 4.6 at the scope gate (2026-09-15). Depends on both carrier-substrate items above. AD-7 explicitly decouples it from dispatch ("dispatch records first, label retries follow"), which is the seam that made dispatch-first the natural split. Retry substrate already exists and does not need building: `wms-be/src/shared/events/outbox.ts` carries a 5-attempt budget, exponential backoff `min(2^(n-1)·5s, 5min)`, and quarantine past budget.

- source_spec: none
  summary: Carrier manifest generation (FR-17).
  evidence: Split from story 4.6 at the scope gate (2026-09-15). Depends on the carrier substrate. Nothing in the epic's acceptance criteria for dispatch requires a manifest, so it carries no coupling risk to the dispatch story.

- source_spec: none
  summary: Tracking writeback — syncing carrier tracking numbers back toward the originating channel.
  evidence: Split from story 4.6 at the scope gate (2026-09-15). The epic context already notes the channel side lands in Epic 7, so only the writeback machinery is in scope here and it has no consumer until then. Depends on labels having produced a tracking number.

- source_spec: `_bmad-output/implementation-artifacts/spec-4-6-dispatch-terminal-order-transition.md`
  summary: A dispatched order's carrier, tracking number and dispatch time are readable only by scanning `ledger_events.reference_doc` — there is no read-back endpoint and no status filter on the order list.
  evidence: Review loop 1, blind hunter; verified. `OrderDto` exposes only `status`, `OrderListQuery` (outbound.dto.ts) carries just `cursor`/`limit`, and there is no `GET .../orders/{orderId}/dispatch`. So "what is the tracking number for order X" and "which orders shipped today" need a raw jsonb scan. Deferred rather than patched because the surface belongs to `4-2b`/the carrier arc, which will also replace the free-text carrier fields with a real carrier id and an adapter-issued tracking number — building a read path against the interim shape would be work thrown away.

- source_spec: `_bmad-output/implementation-artifacts/spec-4-6-dispatch-terminal-order-transition.md`
  summary: A short-shipped order leaves no queryable trace and schedules no backorder follow-on.
  evidence: Review loop 1, blind hunter; verified. `shortfallQty` is computed per line and journalled into the dispatch reference doc, but `order_lines.status` stays on its acceptance-time reservation arm (`open`/`backordered`), `reserved_qty`/`reservation_id` are deliberately left alone, and no arm or flag marks a partially-shipped order. Nothing downstream can find short-shipped orders. Pre-existing shape rather than something 4.6 caused — the order-line status vocabulary predates it — and a backorder follow-on is a product decision, not a patch.

- source_spec: `_bmad-output/implementation-artifacts/spec-4-6-dispatch-terminal-order-transition.md`
  summary: An order packed and then abandoned understates ATP indefinitely — dispatch is now the ONLY `committed → released` writer and nothing sweeps a stalled one.
  evidence: Review loop 1, blind hunter; verified. `expireDue()` (reservation.service.ts) selects `state = 'held'` only, cancel refuses a `ready_to_dispatch` order, and 4.6 makes dispatch the sole retirement path. So a sale cancelled after packing, a lost parcel, or an operator who never dispatches leaves committed holds deducting ATP forever, with no operational escape hatch. This is the stalled-order variant of the exact double-deduction 4.6 exists to fix. The frozen block knowingly accepted ATP being wrong for the pick→dispatch window, but that decision assumed the window closes; it does not contemplate an order that never dispatches. Needed a human decision — an expiry arm for committed holds, an un-pack path, or an ops tool — so it was recorded rather than guessed at. **RESOLVED (2026-09-16, Sasidhar chose the expiry arm):** the reaper now sweeps `committed` alongside `held`. `expires_at` is set at GRANT and never refreshed by the commit, so the bound is the acceptance TTL — an order dispatched inside it never meets the path, a stalled one self-heals. No dispatch change was needed: its retirement loop reads `state = 'committed'`, so a row the reaper already expired is invisible to it (no double restore, no conditional-update 409). The un-pack path was rejected because it contradicts story 4.5's frozen "no re-opening a packed order" and would add the state machine's first backwards transition; an ops tool was rejected because it requires someone to notice, and nobody noticing is the whole defect.

- source_spec: `_bmad-output/implementation-artifacts/spec-4-6-dispatch-terminal-order-transition.md`
  summary: The idempotency scaffolding (`replay`, `writeIdempotencyKey`, the under-lock same-key re-read, the post-commit mirror loop) is now duplicated verbatim across nine command files.
  evidence: Review loop 1, blind hunter; verified — nine files define `private async writeIdempotencyKey` and nineteen sites raise "Concurrent idempotent request". The concrete harm is demonstrated by this very story: 4.5's same-key race fix had to be re-implemented by hand in `dispatch.command.ts`, and finding #1 of this loop (the cancel/dispatch hash collision) is a defect in exactly the copied preamble. A shared replay/insert helper would leave each command's policy untouched. Pre-existing across all nine, so not this story's to fix.

- source_spec: none
  summary: Outbound waves and picklists web surface — policies, generation, release, cancel, the picklist view, and carrier-cutoff pressure shown as amber at-risk waves with time remaining.
  evidence: Split from 4-2b at the scope gate (2026-09-16, Sasidhar chose orders-first). Independently shippable: its own capability (`waves.manage`), its own backend surface (story 4.2, merged), and its own user goal. The amber indicator IS buildable — verified that `WavePolicyDto` exposes `cutoffLocalTime` (HH:MM) and `cutoffTimezone` (Asia/Kolkata), and that the cutoff gates RELEASE rather than generation, so "planning ahead of a cutoff is the point". Deferred behind orders because every wave screen references orders and orders have no upstream dependency.

- source_spec: none
  summary: Pack station and dispatch web surface — scan verification against what was picked, and closing the order with carrier and tracking.
  evidence: Split from 4-2b at the scope gate (2026-09-16). Two capabilities (`pack.execute`, `dispatch.execute`) over two merged backend surfaces (4.5, 4.6). Grouped as one follow-on because they are sequential operator actions on the same order at the end of the flow. Note when it is specced: the dispatch screen's `carrierName`/`trackingNumber` are INTERIM free text that the carrier arc (4-6b/4-6c) will replace with a real carrier id and an adapter-issued tracking number, so any UI built against them is temporary by design.

- source_spec: none
  summary: The epic's "label/API failure shows a retryable inline error with dispatch state unchanged" has no backend to consume.
  evidence: Split from 4-2b at the scope gate (2026-09-16), but genuinely blocked rather than merely deferred: labels live in 4-6c, which is backlog. Epic context line 43 asks for this on the Outbound surface; it cannot be built until the carrier arc lands, and belongs with whichever story ships label generation.

- source_spec: `_bmad-output/implementation-artifacts/spec-4-2b-outbound-orders-surface.md`
  summary: `DataTable`'s new expanded-row branch — and every other rendered component in wms-fe — has no automated test, because the repo has no DOM test infrastructure at all.
  evidence: Review loop 1, verification-gap; pre-verified by mutation. Rendering the detail row unconditionally, or hard-coding `colSpan={1}`, leaves all 114 tests passing while injecting a stray row into the six surfaces that do not opt in (`app/(app)/page.tsx`, `settings/sku-table.tsx`, `settings/devices-card.tsx`, `settings/users-card.tsx`, `settings/zone-bin-setup.tsx`, `inbound/inbound-cards.tsx`). `package.json` carries no `@testing-library/*`, `happy-dom`, `jsdom` or Playwright, and no `.test.tsx` exists. NOT patched here by deliberate decision: story 4-2b's frozen block forbids introducing a component-test framework, because doing so inside a surface story would make it also a test-infrastructure story. When that infrastructure is added, `DataTable`'s two row-shapes (opt-in returns a node / returns null) are the first thing it should pin — it is the shared primitive every list surface in the app renders through. **RESOLVED (2026-09-16):** happy-dom is preloaded via `bunfig.toml`, `src/lib/test/render.ts` is a hand-rolled ~30-line helper on `react-dom/client` (chosen over @testing-library to hold the repo's four-runtime-dependency line; revisit if the component suite grows), and `data-table.test.tsx` pins five shapes — each verified by mutation. Coexistence was the real work: the pure-logic suites hand-shim globals and `delete` them, which a real DOM survives neither of (happy-dom's `localStorage` is an accessor with no setter, and `delete` would strip the global for every later file), so `src/lib/test/globals.ts` defines-and-restores instead. All 124 pre-existing tests kept their spy-based assertions. **Still open: 4-2b's own screen has no component tests** — the infrastructure now exists, so that is a backfill someone can do, and 4-2c/4-2d should write them as they go.

- source_spec: `_bmad-output/implementation-artifacts/spec-4-2c-outbound-waves-surface.md`
  summary: The at-risk countdown's 30-second refresh is pinned by no test — delete the interval and the amber chip freezes at whatever it read on mount, with nothing failing.
  evidence: Review loop 1, verification-gap; pre-verified. `cutoffStatus` itself is exhaustively tested by injecting `now` (zones, both DST transitions, midnight rollover, the threshold boundary at second resolution) — which is precisely why those tests cannot observe the tick. The component tests freeze `Date` and assert a single paint; a repo-wide grep finds no `setInterval`/`setSystemTime`/fake-timer control in any test. The failure mode is the one the warning exists to prevent: a wave that crosses into the threshold while the page is open never lights amber. Deferred because closing it needs timer control the suite uses nowhere yet — a test-infrastructure change rather than a surface one, the same reasoning that kept DOM testing out of 4-2b.

- source_spec: `_bmad-output/implementation-artifacts/spec-4-2c-outbound-waves-surface.md`
  summary: `roleHasCapability` throws a TypeError on any role string absent from `ROLE_CAPABILITIES`, crashing whichever surface called it.
  evidence: Review loop 1, edge-case; I confirmed it directly. `src/lib/users.ts` does `ROLE_CAPABILITIES[role].includes(capability)` with no fallback, and `src/lib/auth.ts` validates a stored session's role only as `typeof role === 'string'` — not as one of the four known arms. So a fifth role added backend-side, a session stored by a newer deploy, or tampered localStorage takes down every gated surface (Outbound, Settings, Inbound, Conflicts). **Pre-existing since story 1.5 and NOT caused by 4-2c** — which is why it is recorded rather than patched here — but it is crash-class and the fix is one token: `(ROLE_CAPABILITIES[role] ?? []).includes(capability)`. Worth picking up on its own, ideally with a test pinning that an unknown role simply has no capabilities. Note the CI capability-mirror guard does not catch this: it compares the two lists, not what happens to a role outside them.

- source_spec: none
  summary: Rate shopping — fan out quotes across a tenant's configured carriers behind the `CarrierAdapter` port and rank them (FR-17).
  evidence: Split from 4-6b at the scope gate (2026-09-16, human chose substrate-first). Independently shippable once the substrate below it exists: the credential store and the port are what it consumes, and nothing in dispatch, waves or pack calls rating today. Kept out of 4-6b because rating is the one piece of the carrier arc that cannot be built against the current schema at all — see the address-model entry below, which is its hard prerequisite. Sequence it after 4-6b and after an address model exists; it is a sibling of 4-6c (labels), not a dependency of it.

- source_spec: none
  summary: There is no shipment address model anywhere in the system — no destination on an order, no origin on a warehouse — so nothing can be rated, labelled or manifested.
  evidence: Discovered at the 4-6b scope gate (2026-09-16) and verified by direct search. `orders` (`schema.ts:1409`) carries status, source and the channel arms only; `warehouses` (`schema.ts:130`) carries `code` and `name` only; a repo-wide grep of `wms-be/src` for pincode / postal / address / consignee returns ZERO hits. Indian carrier rating is origin-pincode → destination-pincode by weight and zone, so rate shopping, label generation and manifests are each blocked on this, not merely sequenced after it. Related: parcel weight and dimensions exist only as OPTIONAL fields inside `ledger_events.reference_doc` jsonb (`ledger-registry.ts:129-134`) with no durable column and no read path — the same jsonb-only shape already recorded for dispatch carrier/tracking. This is 4.1 / tenancy territory (order schema + ingestion + the Outbound surface), not carrier territory, which is why it is its own item rather than a task inside any carrier story.

- source_spec: `_bmad-output/implementation-artifacts/spec-4-6b-carrier-substrate-credentials-and-adapter-port.md`
  summary: The carriers facade's sibling-facing read seam is exercised by nothing — `openCredentialForAdapterUse`'s tenant predicate, `resolveConnection`, and the uuid/limit guards on the facade's rotate/disconnect/list paths are all unpinned.
  evidence: Review loop 1, verification-gap (pre-verified) plus two edge-case findings, same root cause. Demonstrated: delete `eq(carrierConnections.tenantId, tenantId)` from the `where` in `openCredentialForAdapterUse` and ANY tenant could open ANY other tenant's carrier credential by connection id — the full suite still passes, because `test/carriers.spec.ts` asserts decryption by importing `openCredential` from `carrier-credentials.ts` directly and goes around the facade entirely. Likewise the facade's rotate/disconnect take a non-uuid `connectionId` unguarded (a `::uuid` cast error would be a 500) and `listConnections` takes limit 0/negative/fractional unguarded — both unreachable over HTTP, where `assertUuidParam` and the DTO bounds cover them. Deferred rather than patched because NOTHING calls this seam today: no regression ships, and 4-6c's label flow brings the first real caller plus a natural end-to-end path to assert against. **When 4-6c lands, pin the tenant predicate FIRST** — it is the one line standing between a connection id and another tenant's plaintext.

- source_spec: `_bmad-output/implementation-artifacts/spec-4-6b-carrier-substrate-credentials-and-adapter-port.md`
  summary: Rotating `CARRIER_ENCRYPTION_KEY` is unsupported — every stored blob becomes unopenable, and idempotent replay silently breaks because `payload_hash` is a master-key HMAC.
  evidence: Review loop 1, blind hunter; verified. `credentialHmac` keys the digest with `carrierMasterKey()` and `payload_hash` is durable, so after a key change a legitimate client retry of an in-flight connect/rotate hashes differently and answers 422 `idempotency-key-reuse` instead of replaying. That is the smaller half: the same rotation makes every `credential_sealed` blob permanently unopenable, which `.env.example` states outright. Out of 4-6b's frozen scope ("no real KMS integration — the env-var master key stays the documented stand-in"), and the honest fix is not a patch but a key-management story: a key id carried in the sealed blob and in the hash input, plus a re-seal path. Settle it with the real-KMS swap, which the 4.6 gate already recorded as its own decision.

- source_spec: `_bmad-output/implementation-artifacts/spec-4-6b-carrier-substrate-credentials-and-adapter-port.md`
  summary: The carrier-connections keyset cursor inherits the repo-wide millisecond-truncation bug — same-millisecond rows below the boundary row are silently skipped.
  evidence: Review loop 1, blind hunter + edge-case, independently. `toConnectionView` runs `canonicalInstant` (`new Date(v).toISOString()`, millisecond precision) BEFORE `buildPage` encodes the cursor, while the next page compares against Postgres `created_at` values carrying microseconds. NOT introduced by this story — it is present at every `buildPage(rows.map(toView))` site in the repo and is ALREADY TRACKED as epic-2 retrospective action item a1 ("Fix keyset cursor to full timestamp precision"), still open. Recorded here only so the carrier list is known to be affected; the fix belongs to that action item as one shared correction, not to a per-table patch. Impact here is negligible in practice (a tenant has at most three connections).

- source_spec: `_bmad-output/implementation-artifacts/spec-10-4-measured-stock-reconciliation.md`
  summary: Six deferred review findings from 10-4's code review (all low; verified against the implementation before triage).
  evidence: (1) The post-discard re-earn upsert's CONFLICT-arm `incremental_count: 0` reset is untested — the arm covers a concurrent re-creation that cannot occur inside the single-transaction delete→replay→upsert flow; the insert arm is the one that lands and it is tested. (2) The knob's "1 alternates" semantic is unit-tested but never exercised e2e — the counter rule (bounded increments, full resets) is what makes 1 alternate, and it is tested at N=2 and the default-20 march. (3) `CycleDetection.fullPass` is not surfaced on `ReconcileReport` — cadence is observable only through the counter; a pass-kind field is an observability addition to a payload contract, a candidate for a follow-up if operators need it. (4) The import edge's over-ceiling refusal sentence is unpinned (its precision sibling is pinned) — the realistic slip (an arm-name drift) is compiler-caught and the core's ceiling arm is covered at the HTTP path. (5) The non-negative refusal exists in two near-identical sentences (import regex arm, core sign arm) — the story's "stated once" claim covers the precision/scale/ceiling rule; the sign arm is documented defense in depth. (6) `RECORDABLE_QUANTITY_ARM_TITLES.sign` is unreachable under today's two call shapes — the map is type-exhaustive for the arm union and the arm becomes reachable for any future `non-negative` caller.

- source_spec: `_bmad-output/implementation-artifacts/spec-10-4-measured-stock-reconciliation.md`
  summary: `reconciliation-fractional.spec.ts`'s `beforeAll` calls `Logger.overrideLogger(false)` (process-global) which persists into later suites in the same jest worker — the same leak class as the env knobs, but pre-dating story 10-4 and harmless for the current suite set.
  evidence: Found by the loop-1 re-review of the patch commit as a non-blocking observation; the patch's own env-leak fix (afterAll delete) does not change it. Worth folding into the same hygiene pass if jest worker behavior ever makes an assertion order-sensitive.
- source_spec: none
  summary: Handling units gain their own location and move-as-unit semantics — a pallet moves its contents in one operation while the contents stay individually traceable (FR54).
  evidence: Split from story 10-3's intent at the step-01 scope gate. FR33 (epic 10) and FR54 + Epic 15 "Returnable Containers & Handling Units" (Tier 2) both claim "a handling unit carries its own location". Building the independently-located entity inside 10-3 would introduce a THIRD stock granularity beside the (bin, sku, batch) projection key, inside the Tier 0 story that gates epics 5, 14, 19 and 20. 10-3 therefore builds identity + actual weight only, with location inherited from the stock the unit represents. Adding a nullable location column later is additive and needs no ledger denormalisation, so the deferral is low-regret — unlike the AD-3 client dimension, which is the counter-example.

- source_spec: `_bmad-output/implementation-artifacts/spec-10-3-catch-weight-handling-units.md`
  summary: A background coherence check that live handling-unit count equals on-hand quantity for every catch-weight SKU.
  evidence: Design-review finding 7 (loop 1). Story 10-3 establishes the invariant "N live handling units ↔ quantity N" and pins it with tests at each write path, but nothing detects DRIFT once it happens — there is no CHECK that can express it (the two sides live in different tables) and no job that walks it. This is distinct from the reconcile-weight question, which 10-3 answers deliberately: weight is an attribute, not a conserved delta, so it is correctly absent from `foldLedgerInTx`. Count coherence is a different property and wants the same treatment quantity already gets — a periodic pass that compares and alerts. Cheapest once story 10-4 (measured stock reconciliation) is building in that area.

- source_spec: `_bmad-output/implementation-artifacts/spec-10-3-catch-weight-handling-units.md`
  summary: No read-back path exists for a handling unit's captured weight — no GET route, and the GRN response returns handling-unit ids without their weights.
  evidence: Code-review finding 40 (loop 3). Story 10-3 captures per-unit weights and stores them correctly, but nothing outside the database can read one: the e2e suite has to query `handling_units` with raw SQL to see a weight at all. Deferred rather than patched because the consumers do not exist yet — 10-5 owns the web surfaces and epic 8 owns invoicing, and the spec's Never list explicitly excludes both. Whichever lands first should expose the read; `handlingUnitsOfGrnLinesInTx` was written for exactly that and currently has no caller.

- source_spec: `spec-10-6-mobile-decimal-and-catch-weight-capture.md`
  summary: The replay single-flight wiring in `device-store.ts` (`enqueueOp` awaiting `settled()`, `replay()` routing through the gate) has no store-level test and can regress green.
  evidence: Verified by the review's mutation run — deleting the `settled()` await leaves all 203 tests passing. The module imports `expo-secure-store` and cannot be imported by the test suite; making it injectable (or mocking the secure store) is its own change before the wiring can be pinned. The extracted gate's contract is pinned in `replay-gate.test.ts`.
- source_spec: `spec-10-6-mobile-decimal-and-catch-weight-capture.md`
  summary: The byte-mirrored server literals (`precisionRefusalDetail` copy, `MAX_HANDLING_UNIT_WEIGHT_GRAMS`) are enforced by hand only — no mechanism observes both repos, so server-side drift fails no test anywhere.
  evidence: Verified by search — mobile CI runs `bun test` + `tsc` only; `src/api.ts` is hand-written with no openapi guard; no BE↔mobile drift-guard tooling exists in the meta repo. A wording change in `wms-be/src/shared/primitives/quantity.ts` would leave wms-mobile green while the device speaks a second refusal wording. Needs a cross-repo drift guard (the same class the wms-fe drift guard already covers for generated clients).
- source_spec: `_bmad-output/implementation-artifacts/spec-10-7-mobile-pack-bench.md`
  summary: Pack cards carry no human-readable order identifier (orders table has no code column).
  evidence: Review round 1 W3 (blind-hunter B7) — two packable orders are indistinguishable on the bench; the gap is pre-existing orders-table design, a schema addition outside story 10-7's scope.
- source_spec: `_bmad-output/implementation-artifacts/spec-10-7-mobile-pack-bench.md`
  summary: The device's parcel-weight bound (`MAX_PARCEL_WEIGHT_GRAMS`) is pinned to nothing — no check compares it to the server's advertised `weightGrams` maximum.
  evidence: Review round 2 R2-27 (verification-gap, pre-verified): the server can lower `MAX_WEIGHT_GRAMS` while both suites stay green; a divergence drops completed counts at replay as a visible rejection. Same root cause as the cross-repo mirror drift guard deferred from story 10-6 (V3).

- source_spec: `_bmad-output/implementation-artifacts/spec-11-3-product-variants.md`
  summary: `docs/repos/wms-be/README.md`'s documented import header line omits the 11.2 columns (catch_weight_tracked, weight_grams, length_mm, width_mm, height_mm, country_of_origin) even though OPTIONAL_COLUMNS carries them — stale since 11-2.
  evidence: README surface bullet (the "Documented header:" line) predates 11-2 and was not touched by 11-3's diff; the code's OPTIONAL_COLUMNS is the authority. A docs-only correction, pre-existing debt.

- source_spec: `_bmad-output/implementation-artifacts/spec-11-4-kits-and-bundles.md`
  summary: ~~CSV import gains an optional `kit_components` column so kit compositions can be loaded without API calls.~~ **Closed 2026-09-22 by story 11-6** — the column landed (`import.command.ts`'s kit pass, cell grammar `code:qty;code:qty`, resolution after every SKU row through the kit store's guards, `catalog.kit_created` event parity), pinned by the 11.6 import describe in `test/kits.spec.ts`.
  evidence: Split from story 11-4 at step-02 (spec over the 1600-token gate); user chose to defer. Import support lands with the 11-6 surfaces, consistent with 11-2/11-3's import-references precedent.

## Deferred from: three-layer review of spec-11-5-dimensional-capacity (2026-09-21)

- source_spec: `_bmad-output/implementation-artifacts/spec-11-5-dimensional-capacity.md`
  summary: `normalizeBin`'s pre-11.5 idempotency-snapshot fallback (absent capacity fields → null) is untested — no test replays a snapshot stored without the four fields.
  evidence: Review layer 3, triage #13. The fallback is the same additive-nullable pattern as the retirement pair (`retiredAt`/`retiredBy`), so the risk is low; crafting a legacy snapshot row is its own test setup. First story touching `normalizeBin` should add the arm.

- source_spec: `_bmad-output/implementation-artifacts/spec-11-5-dimensional-capacity.md`
  summary: Stock adjustments bypass ALL bin capacity gates — no bin-row lock, no unit/weight/volume check — so any bin can be parked over every limit by an adjustment, after which every placement/merge into it refuses.
  evidence: Review layer 2, triage #16 (adjacent, pre-existing for the unit gate; 11-5 widens the class to weight/volume). The gates fire on placement and merge by design (the 11-5 frozen Never list) — an adjust-side gate is a scope decision for a follow-up story, not a 11-5 patch.

- source_spec: `_bmad-output/implementation-artifacts/spec-11-5-dimensional-capacity.md`
  summary: A concurrent adjustment can race a placement past a stale (lower) load — the bin-row `.for('update')` serializes only gate-compliant writers, and adjust takes no bin-row lock.
  evidence: Review layer 2, triage #16. Same pre-existing race the unit gate has; 11-5 does not widen the mechanism, only the currency. Fix shape would be a bin-row lock (or epoch re-check) in the adjust path — its own story.

- source_spec: `_bmad-output/implementation-artifacts/spec-11-5-dimensional-capacity.md`
  summary: `setBlocked`'s bin lock query omits the `tenantId` predicate (`bin-state.command.ts`), unlike `editBinCapacity`'s identical lookup which includes it.
  evidence: Review layer 2, triage #16. RLS-covered today (the tenant tx scopes every query), so not a defect — an inconsistency. One-line fix whenever `bin-state.command.ts` is next touched; not patched in 11-5 to keep the review patch scoped.

- source_spec: `_bmad-output/implementation-artifacts/spec-11-6-web-variant-and-kit-surfaces.md`
  summary: The Settings page fetches the whole SKU catalog 2–3× per mount with no shared cache — `useCatalogSkus` is instantiated separately in `VariantMatrix` (products card) and `KitForm` (SKU table), each running `fetchAllPages` over the entire tenant, on a page that already holds the paged SKU table.
  evidence: Review blind-hunter finding 10 (11-6 triage, deferred as entry 10). Real but bounded today — small tenants pay nothing; a 10k-SKU tenant pays 3 × 200+ page fetches per mount. The fix shape is a shared catalog context (one fetch, many readers) — a refactor beyond this story's patch round. Acknowledged by the implementer during step-03.

## Deferred from: three-layer review of fix-a2 (epic-11 retro F2 patch) (2026-09-22)

- source_spec: `_bmad-output/implementation-artifacts/spec-fix-a2-be-kit-create-write-skew.md`
  summary: The kit guard's RESERVATION half is not serialized against order-create — `assertKitSkuHoldsNoStock` also refuses a SKU with live reservations, but order-create reads kit-ness with no SKU-row lock (`order.command.ts:381`), so a concurrent kit create and order create can both commit: an order line holding a reservation against a kit SKU, never exploding, never pickable.
  evidence: Blind-hunter lens on the fix-a2 diff. Pre-existing — fix A2's scope was the three +stock writers (all now serialize on the SKU row); the reservation writer was never in scope. Fix shape is the same `.for('update')` SKU lock in the order-create path's kit probe (order-create already locks only the orders row). Recorded in PENDING.md (catalog section).

## Deferred from: three-layer review of story 12-1 (2026-09-23)

- source_spec: `_bmad-output/implementation-artifacts/spec-12-1-storage-class-and-conformance.md`
  summary: A wave line shorted purely by the storage-class filter carries no reason naming the conflict — the line reads `unfulfillable` with a `shortfallQty` indistinguishable from an empty-stock shortfall, so an operator cannot tell that drawable-looking stock exists but is excluded by class.
  evidence: Blind-hunter lens, triage #12. The frozen I/O matrix chose "per existing shortfall arm"; naming the conflict (which bin excluded, which class) needs a reason surface on the line — admin/mobile-surface material for stories 12-7/12-8, not a backend data change.

- source_spec: `_bmad-output/implementation-artifacts/spec-12-1-storage-class-and-conformance.md`
  summary: A placement or merge committing between the SKU class-edit guard's stock/hold scans and the edit's commit parks non-conforming stock the scans just proved absent — the mirror direction of the unlocked-read race already recorded as accepted currency at PENDING.md (putaway:57); same window, opposite ordering.
  evidence: Edge-case lens, triage #11. Both orderings share the same root cause (placement reads the SKU unlocked; the class-edit guard takes no locks on the stock writers) and the same failure mode (one placement of non-conforming stock per window, then refused by every downstream gate). Accepted currency — recorded here so the mirror direction is explicit beside the PENDING entry.

## Deferred from: three-layer review of story 12-2 (2026-09-24)

- source_spec: `_bmad-output/implementation-artifacts/spec-12-2-hazard-segregation-matrix.md`
  summary: The placement's co-location gate reads the target bin's occupant classes unlocked inside the bin-row lock window, so an OCCUPANT's hazard edit can commit between the gate's read and the placement's write and co-locate an incompatible pair — the occupant-side half of the unlocked-read currency, which PENDING.md (putaway:58) records only for the INCOMING SKU's read (triage #6).
  evidence: Edge-case lens, verified. The hazard-edit guard locks only the SKU row and the placement locks only the bin row; the shape is the same accepted currency as 11-5's bin-load race and 12-1's unlocked class read (one misplaced placement per window, then refused by every downstream gate). Fix shape is locking occupant SKU rows in the co-location read — heavier than the accepted family, so currency. The PENDING currency entry should be extended to name the occupant-side window (and its mirror: a placement committing between the hazard-edit guard's occupant scan and the edit's commit).

- source_spec: `_bmad-output/implementation-artifacts/spec-12-2-hazard-segregation-matrix.md`
  summary: The suggestion rationale collapses segregation refusals into "No conforming storage bin has room for these units" — an operator whose every bin is blocked by the matrix is told the bins have no room, though capacity exists (triage #9).
  evidence: Blind-hunter lens. The spec chose the wording deliberately (the 12-1 currency kept the rationale unchanged); surfacing which rule excluded the bin is admin/mobile-surface material for stories 12-7/12-8, beside the 12-1 wave-line reason gap already recorded above.

- source_spec: `_bmad-output/implementation-artifacts/spec-12-2-hazard-segregation-matrix.md`
  summary: The 409 `hazard-segregation-conflict` remedy says "relocate the stock or release the holds first", but there is no gated bin-to-bin relocation surface to do it with — placement requires Receiving as its from-bin and merge requires an empty source (retire is terminal), so the operator has no first-class move-stock-between-bins flow (triage #24).
  evidence: Edge-case lens, verified against the seams: the two relocation writers that exist (placement, merge) are both shaped for other jobs, and `stock.adjust` is the named bypass, not an operator remedy. A gated bin-to-bin relocation (guards mirroring the placement gates, one ledger arm) is Epic-5-shaped inventory work, not a 12-2 patch — deferring with the remedy's wording unchanged, since the sentence remains true (release-the-holds works today, and relocate becomes possible when the surface exists).

- source_spec: `_bmad-output/implementation-artifacts/spec-12-3-secure-locations.md`
  summary: QC-release secure-authority gate rules on an unlocked origin read — a concurrent storage-class edit can flip the bin to `secure` between the read and the commit, so a release answers 200 without `secure.move`.
  evidence: `src/modules/inbound/qc.command.ts` release path reads `originRows` without `.for('update')` (the hold path locks its origin at :264); verified 2026-09-24 in step-04 review of 12-3. The 12-3 frozen block explicitly declined the lock fix (PENDING `inbound:45`, pre-existing currency); the PENDING entry is the tracker — extending it with the lock would close the race.

- source_spec: `_bmad-output/implementation-artifacts/spec-12-3-secure-locations.md`
  summary: The generated FE client lies about `SkuResponse.hazardClass` nullability — `@hey-api/openapi-ts` 0.99.0 renders enum+nullable fields without `| null` (plain-nullable fields like `hsn` render fine), so FE types claim a hazard class is always one of the seven classes while the runtime returns null for every plain SKU.
  evidence: Found 2026-09-24 while regenerating the client for WMS-FE #36 — BE `catalog.dto.ts:233` declares `@ApiProperty({ enum: HAZARD_CLASSES, nullable: true })`, the committed `openapi.json` carries `"nullable": true`, and `types.gen.ts:475` emits `hazardClass: 'explosive' | … | 'gas'` with no null arm. Fix: upgrade/patch the generator (or reshape the DTO to a oneOf) and regenerate; until then any FE consumer reading a SKU's hazardClass works against a false type.

- source_spec: `_bmad-output/implementation-artifacts/spec-12-4-non-bin-location-types.md`
  summary: `stock.adjust` bypasses the bulk-asset single-SKU occupancy gate — an adjustment can add a second SKU into a holding tank (triage #15).
  evidence: Blind-hunter lens, verified. The standing containment pattern: the 11-5/12-1/12-2/12-3 gates carry the identical documented bypass (PENDING `inventory` entries), and the state is recoverable via draws (the draw path has no gate). Recovering an over-mixed tank is possible today only through that bypass-in-reverse; a PENDING entry names the new gate.

- source_spec: `_bmad-output/implementation-artifacts/spec-12-4-non-bin-location-types.md`
  summary: The FE mirrors "which types are bulk" (`BULK_ASSET_TYPES`, `GRID_TYPES`) and the weight cap (`MAX_BIN_WEIGHT_GRAMS = 100_000_000`) by hand, with no cross-repo parity pin — a BE-side change to either set fails only at runtime (triage #16, re-raised by review 2 for the cap).
  evidence: Verification-gap lens, verified (the FE cap matches the backend today). Semantic classifications cannot ride the generated openapi, so some mirror is unavoidable; the missing piece is a parity checker — systemic work beside triage #17, and 12-7's storage admin will reshape the FE surface anyway.

- source_spec: `_bmad-output/implementation-artifacts/spec-12-4-non-bin-location-types.md`
  summary: The putaway mismatch-reason enum is hand-kept in five places (BE primitive, BE DTO, BE openapi-derived FE types, two wms-mobile mirrors) with no cross-repo parity test — this story updated three of the five and the drift class just bit (triage #17).
  evidence: Verification-gap lens. The BE-internal half is fixed (one `mismatch-reason.ts` source, re-exported); the cross-repo half needs a parity checker — systemic, deferred to 12-8, which touches the mobile mirrors anyway. The FE create-picker and mobile reason mirrors each carry their own local pin from this story.

- source_spec: `_bmad-output/implementation-artifacts/spec-12-4-non-bin-location-types.md`
  summary: The suggestion rationale text misstates exclusion reasons for pools emptied by exclusion — a tank-only warehouse says "No conforming storage bin has room for these units" though the tank was excluded by type, not capacity (triage #18).
  evidence: The wording pre-exists 12-4 (any pool-empty-by-exclusion case produced it — 12-2's triage #9 already records the same collapse for segregation refusals); 12-4 adds a new trigger without changing the shape. Fix belongs with the rationale-reasoning work deferred there (12-7/12-8 admin/mobile surfaces).

- source_spec: `_bmad-output/implementation-artifacts/spec-12-5-temperature-excursions.md`
  summary: The CI migrations drift guard (src/shared/db/verify.ts) round-trips only app_metadata, so hand-appended table CHECKs (e.g. 0038's temperature_excursions_status_check) are pinned by no automated verification.
  evidence: Observation filed by the 12-5 verification-gap layer; the RLS half of the same migration is covered by the e2e RLS probe, the CHECK half is not. Nothing in the current code path can violate the CHECK (the command writes only 'open'/'resolved'). Settling it = extending verify.ts to round-trip table-level CHECK constraints — an infra change beyond story 12-5.

- source_spec: `_bmad-output/implementation-artifacts/spec-12-6-cold-chain-reporting.md`
  summary: The hand-emitted 0039 expression index (ledger_events_order_ref_idx) is invisible to the drizzle snapshot and its existence/definition is asserted by no automated check — verify.ts round-trips only app_metadata.
  evidence: 12-6 verification-gap layer + triage #7/#26. The index is confirmed present in the dev DB (pg_indexes verified) and usable only when the query carries the `? 'orderId'` qual (now patched into ledgerEventsByOrderRefInTx), but a future hand-edited migration could drop or reshape it with nothing failing. Settling it = extending src/shared/db/verify.ts introspection to assert index existence/definition (and, separately, a documented procedure for the next hand-emitted index) — an infra change beyond story 12-6; same family as the 12-5 CHECK-drift-guard defer.
- source_spec: `_bmad-output/implementation-artifacts/spec-21-1-client-dimension-migration.md`
  summary: No index on any new `client_id` column (skus, orders, purchase_orders, ledger_events, bins.dedicated_client_id, users.client_id) — 21-2/21-4 specs should add client-filtered indexes when the first client-filtered queries land.
  evidence: Verified — the 0040 migration and its snapshot add the columns with no indexes; the migration header itself justifies the denormalisation with "billing aggregates over ledger_events constantly". Additive later (CREATE INDEX is no-representation-change), so deferring costs nothing now.
- source_spec: `_bmad-output/implementation-artifacts/spec-21-1-client-dimension-migration.md`
  summary: The `clients_tenant_isolation` policy migration 0040 adds ships with no DB-level probe — triage consciously confirms 21-2's ratified isolation-probe deferral covers the tenants-only policy on `clients`, not just the `app.client_id` clauses.
  evidence: Verified — no `wms_rls_probe` test touches `clients` (grep over test/); the app connects as table owner and bypasses RLS, so no existing test would fail if the policy were absent or inverted. Every other tenant-isolated table has a probe (catalog/ledger/orders/users specs); 21-2's probe harness is the designed home for this one.
- source_spec: `_bmad-output/implementation-artifacts/spec-21-2-client-isolation-rls.md`
  summary: Inherited tables (stock_on_hand, batch_on_hand, order/purchase-order lines, bins, users, vendors — every table without a client_id column) remain tenant-only at the RLS layer: a portal-scoped session reading them WITHOUT joining through a stamped table (skus) gets the sibling client's rows. 21-7's portal read paths must route every client-facing read through the stamped tables (or add EXISTS arms) — the join discipline is what closes this.
  evidence: Verified — blind-hunter + edge-case layers both grounded it; the 0041 policies filter only the five client-bearing tables, and the probe asserts the join-shaped read (the path the app uses). The direct-read exposure is the ratified AD-24 selective-placement decision (no client_id on inherited tables), not a defect, but the first real portal consumer (21-7) inherits the constraint and must design its reads accordingly.
- source_spec: `_bmad-output/implementation-artifacts/spec-4-2d-outbound-pack-and-dispatch-surface.md`
  summary: The FE pack-bench bound constants (`MAX_WEIGHT_GRAMS`, `MAX_DIMENSION_MM`, `MIN_SCAN_QTY`) mirror backend decorators by comment only — no check fails when the backend's bounds change.
  evidence: Verified first-hand that the values match today (pack.command.ts:72/74, outbound.dto.ts:978) and that the generated client carries no min/max metadata; a backend tightening or loosening diverges silently (operators falsely refused, or guaranteed-400 round trips). Settled by a drift-guard script comparing the FE constants against the BE decorators, same shape as `check-capability-mirror.ts`.
- source_spec: `_bmad-output/implementation-artifacts/spec-4-6c-labels-manifests-and-tracking-writeback.md`
  summary: The sandbox adapter registers unconditionally — production tenants see "Sandbox Express" in the carriers catalogue and connection picker with no flag or gate distinguishing hash-issued tracking from a real carrier's (triage #2).
  evidence: Verified at carrier-registry.ts:174. The frozen spec deliberately classes the sandbox with envelope.ts/LoggingEventBus as a documented stand-in; whether it is env-gated for production is a product decision for 4-6d's design, where real API credentials arrive.
- source_spec: `_bmad-output/implementation-artifacts/spec-4-6c-labels-manifests-and-tracking-writeback.md`
  summary: The adapter label call runs inside the held transaction while the order row is locked — safe for the in-process sandbox arm, but 4-6d's real HTTP transports must not inherit a network round-trip inside a lock-holding transaction (triage #3/#18).
  evidence: Verified at shipment.command.ts:248. Deliberate for the sandbox arm (no I/O); 4-6d's design needs the label arm pulled out of the held tx (or a Promise.race timeout guard) before real carriers land.
- source_spec: `_bmad-output/implementation-artifacts/spec-4-6c-labels-manifests-and-tracking-writeback.md`
  summary: Auto-stamped carrier/tracking bypass the MAX_*_LENGTH assertText checks free text is subject to — a real-carrier adapter emitting an over-long tracking enters the ledger where free text is refused (triage #15).
  evidence: Verified — stamped values consumed at dispatch.command.ts:368-369/:460-461 with no length check. Unreachable with the sandbox (bounded deterministic values); clamp at stamp time in 4-6d.
- source_spec: `_bmad-output/implementation-artifacts/spec-4-6c-labels-manifests-and-tracking-writeback.md`
  summary: The dispatch auto-stamp shipment read is unlocked — a concurrent manifest flipping the shipment to manifested between read and ledger append double-records the hand-over (triage #17).
  evidence: Verified shape at dispatch.command.ts:275-288. Narrow race (dispatch and manifest on one order concurrently, different capabilities), harmless with the sandbox; lock the read (for('update')) in 4-6d when real transports land.
- source_spec: `_bmad-output/implementation-artifacts/spec-4-6c-labels-manifests-and-tracking-writeback.md`
  summary: `createdBy`/`labelledBy` render as raw uuids on the pack & dispatch surface; the fixtures hide it by using email-like strings (triage #7).
  evidence: Verified — bare uuid columns, no user join anywhere in the BE, and real renders will show uuid strings. Same already-shipped 4-2d pattern for actor fields; user-name resolution is a system-wide concern, its own change.
- source_spec: `_bmad-output/implementation-artifacts/spec-4-6c-labels-manifests-and-tracking-writeback.md`
  summary: `useLabelledShipments` issues one GET per ready_to_dispatch order per render (25+ at default page size), ungated by canLabel, refiring on every OUTBOUND_CHANGED_EVENT; each expanded row re-reads its own shipment (triage #9/#24).
  evidence: Verified. Correctness holds (allSettled absorbs failures; point lookups are cheap); the per-order-read choice is the spec's stated rationale for not shipping a list-shipments route. A batched shipments-by-orders route or capability gating is follow-up work.
- source_spec: `_bmad-output/implementation-artifacts/spec-4-6c-labels-manifests-and-tracking-writeback.md`
  summary: The manifests pager is one-way — no UI path back to the newest page after paging older, and OUTBOUND_CHANGED refetches re-run against the stale active cursor, so a manifest created after paging is invisible until reload (triage #14).
  evidence: Verified at use-outbound-labels.ts:207-259. UX hardening (head-reset on refetch / a "back to newest" affordance); the list is page-scoped and short in practice.
- source_spec: `_bmad-output/implementation-artifacts/spec-4-6c-labels-manifests-and-tracking-writeback.md`
  summary: `useCarrierConnections` walks keyset pages in an unbounded `for(;;)` — a server that keeps returning a non-null cursor hangs the picker indefinitely (triage #23/#31).
  evidence: Verified at use-outbound-labels.ts:74-86. Backend keyset cursors terminate by construction, so the loop is unreachable today; a page cap is defensive hardening, pre-existing in shape across the repo's walkers.
- source_spec: `_bmad-output/implementation-artifacts/spec-4-6c-labels-manifests-and-tracking-writeback.md`
  summary: The manifest command validates/normalizes shipmentIds BEFORE the transaction and replay — a same-key retry with a malformed body 400s instead of replaying, unlike shipment.command's deliberate validation-after-replay for measurements (triage #19).
  evidence: Verified: manifest.command.ts:111 normalizes before the tx, shipment.command.ts:177-180 validates after replay with the stated rationale. Structurally required today (the sorted collapsed set IS the payload-hash input, unlike label's raw measurements); harm needs a direct API caller retrying a committed manifest with a malformed body. Document the divergence or align in a consistency pass.
- source_spec: `_bmad-output/implementation-artifacts/spec-4-6d-carrier-rate-shopping.md`
  summary: A mid-read `disconnect` (a hard DELETE, AD-15) between the connection walk and the in-tx credential open throws `carrierConnectionNotFound` (404 `not-found`) — the whole rates read 404s with the same arm the route reserves for "no order", and `fetchApiGetOrderRates` maps any 404 `not-found` to null, so the strip silently vanishes (triage D1).
  evidence: Verified — disconnect is a hard delete (carrier.command.ts:362-363), `openCredentialForAdapterUseInTx` throws `carrierConnectionNotFound()` on a missing row (carriers.facade.ts:250-252), and the FE fetcher's 404→null mapping is not order-scoped (client.ts fetchApiGetOrderRates docstring overclaims). Window is sub-second and self-healing (the picker drops the connection on its own refetch); when the read is next touched (real transports), give the credential-open miss its own problem code so the 404-null mapping stays order-scoped.
- source_spec: `_bmad-output/implementation-artifacts/spec-4-6d-carrier-rate-shopping.md`
  summary: `refusalOf` copies the carrier problem's `detail` uncapped into the rate item and the FE chip renders it raw — when real transports land, a carrier SDK error page pasted into detail flows verbatim into the strip chip (triage D2).
  evidence: Verified at rate.service.ts:302-315 (no cap) and pack-dispatch.tsx's refusal chip (raw `item.refusal.detail`). Unreachable today — only the typed fixed-prose 501 flows through; carrier error shaping/capping belongs to the real-transports story beside the 4-6c adapter-call defers.
- source_spec: `_bmad-output/implementation-artifacts/spec-5-1-transfer-orders.md`
  summary: Web `/moves` transfers surface (list + create + detail + confirm) deferred from story 5-1 to a follow-up FE story.
  evidence: 5-1's epic ACs name no web surface; the backend-first ordering (4-6b→4-6d precedent) lands BE + mobile first. The FE surface needs the capability mirror, a referenceDoc-filtered or detail-embedded ledger-legs view, and regen after the BE routes exist.

- source_spec: `_bmad-output/implementation-artifacts/spec-5-2-stock-adjustments-with-approval-thresholds.md`
  summary: No withdraw/cancel verb or TTL exists for abandoned adjustment pends — a pending row created in error lives until an owner rejects it.
  evidence: Blind-hunter finding verified against the frozen intent, which settles the flow as pending→decide with exactly two outcomes; the operational gap is real but adding a third terminal path is beyond this story's intent. Candidate PENDING.md entry alongside the over-receipt flow, which has the same shape.
- source_spec: `_bmad-output/implementation-artifacts/spec-5-2-stock-adjustments-with-approval-thresholds.md`
  summary: A pend whose FEFO-resolved batch is consumed before approval re-executes against the stale batch and 422s — the only recourse is reject and re-raise; no re-request/re-resolve flow exists.
  evidence: Designed behavior (rollback-leaves-pending is the frozen boundary and the stored-arms re-execution is the human-approved decision), but a real operational dead-end for approvers; surface it in the 5-4/5-5 consolidated review queue UX rather than adding an API arm now.
- source_spec: `_bmad-output/implementation-artifacts/spec-5-2-stock-adjustments-with-approval-thresholds.md`
  summary: The approval-threshold flow cannot be disabled via the API — PUT requires a non-null threshold and there is no DELETE/nulling verb, so disable is SQL-only (triage #23/#44/#54).
  evidence: Verified — `stock_adjustment_policies.quantity_threshold` is nullable and its CHECK admits null, but the PUT DTO requires non-null and no other write path exists; the frozen I/O note names the ABSENT row as the disable mechanism. An ops-grade disable verb (DELETE or PUT null) is a follow-up surface for the 5-4/5-5 queue UX story.
- source_spec: `_bmad-output/implementation-artifacts/spec-5-2-stock-adjustments-with-approval-thresholds.md`
  summary: Approve/reject carries no decision note — the decide command records status/decided_by/decided_at only (triage #24).
  evidence: Verified against the frozen decision contract (exactly two outcomes, no note channel). A note field is a queue-UX want for 5-4/5-5; adding one now would touch the decision command, DTO and audit row for no current consumer.
- source_spec: `_bmad-output/implementation-artifacts/spec-5-2-stock-adjustments-with-approval-thresholds.md`
  summary: The requester is never notified of the decision outcome — the outbox notifies the owner at pend creation only; the decide path writes audit + terminal status with no outcome outbox row (triage #25).
  evidence: Verified at the decide command (no outbox insert on either terminal arm). Notification plumbing for the requester belongs with the 5-4/5-5 review-queue UX, beside the row-16 re-request defer.
- source_spec: `_bmad-output/implementation-artifacts/spec-5-2-stock-adjustments-with-approval-thresholds.md`
  summary: `fullPrecisionInstant` (src/shared/primitives/time.ts) matches and then DISCARDS any non-UTC offset in the raw `::text` instant, emitting a Z-suffix — if a deployment ever ran a non-UTC session TZ, keyset cursors would misorder pages (triage #49).
  evidence: Verified by regex read and a repo-wide grep finding no session-TZ pinning in the db config. Harm requires a non-UTC deployment TZ (unconfirmed); when the primitive is next touched, either pin the session TZ at the pool level or parse the offset into the comparison.
- source_spec: `_bmad-output/implementation-artifacts/spec-5-3-cycle-count-scheduling-and-execution.md`
  summary: No index support for the per-class scheduler scan (no `skus (tenant_id, abc_class)` index in 0045) and `count_variances` lacks a `task_id` index (review triage BH-15).
  evidence: Verified — migration 0045 adds neither index. The scheduler scan is less costly than the review claimed (the join drives off warehouse-scoped stock_on_hand rows, not full sku scans), but the `count_variances.task_id` index IS needed: 5-4's resolution surface and the submit/recount arms look variance rows up by task. Add both indexes in the next movements migration (5-4's) rather than touching the landed 0045.

- source_spec: `spec-5-4-variance-review-and-resolution.md`
  summary: An empty-string `quantityThreshold` coerces to 0 via the DTO's @Type(() => Number) — silently enabling owner-only routing — because class-transformer's Number() coercion passes @IsInt; 5-2's AdjustmentPolicyDto carries the same hole (house-wide validation-convention gap).
  evidence: Would settle with a unit test PUTting `quantityThreshold: ""` — today it becomes a 0 threshold; the fix is a shared string-rejection transform convention applied across both policy DTOs, not a story-local guard.
- source_spec: `spec-5-4-variance-review-and-resolution.md`
  summary: wms-fe's generated API SDK was not regenerated for the ledger-timeline's new optional `binId` query param (InventoryControllerListEventsData still carries the pre-5-4 shape) — the capability-only drift guard cannot see it.
  evidence: Verified first-hand (types.gen.ts ~line 4757); harmless until the consumer lands — regen with 5-5's ledger-history component; consider extending the drift guard to query shapes.
- source_spec: `spec-5-4-variance-review-and-resolution.md`
  summary: The ledger timeline's new binId filter (fromBin = bin OR toBin = bin) has no supporting index; a rejected low finding worth revisiting when 5-5 defines the ledger-history read pattern.
  evidence: Verified real (both reviews); the read is brand new with no consumers yet — adding `(tenant_id, from_bin_id)`/`(tenant_id, to_bin_id)` indexes is a small next-migration candidate against 5-5's measured usage.

- source_spec: `spec-5-5-conflicts-reviews-the-human-review-queue.md`
  summary: The quarantined-replay-conflict residents (AD-14 case 4) are split out of 5-5 as their own cross-repo story — a mobile sync-summary report upload, a rejected-ops table + read endpoint + resolve arms (apply/recount/discard-to-audit) on wms-be, and a web queue tab.
  evidence: Investigated 2026-09-29 — mobile-rejected ops exist nowhere server-side (`engine.ts` deletes terminal ops, `lastSummary` is in-memory only, no rejected-op endpoint or table); the split keeps 5-5 FE-only (its spec, human split decision 2026-09-29) while the residents slice is independently shippable.
- source_spec: `spec-5-5-conflicts-reviews-the-human-review-queue.md`
  summary: `@hey-api/openapi-ts` 0.99.0 drops `| null` on enum+nullable fields — a second instance of the closed 5-3 `hazardClass` family: 5-5's regen carries `SkuResponse.abcClass` as `'a'|'b'|'c'` with no null arm though the BE marks it nullable ("or null when it is not yet classified").
  evidence: Found 2026-09-30 in the 5-5 step-03 regen — BE catalog DTO declares abcClass nullable, committed `openapi.json` carries `"nullable": true`, `types.gen.ts` emits the three-class union hard-required (`types.gen.ts:485`), and `catalog-kits.test.ts`'s fixture gained `abcClass: 'a'` to satisfy the false type. Fix is the standing one: upgrade/patch the generator (or reshape the DTOs to a oneOf) and regenerate — one fix makes `hazardClass` and `abcClass` honest together.

- source_spec: `_bmad-output/implementation-artifacts/spec-5-6-ad14-quarantined-replay-residents.md`
  summary: The count-screen guard's call sites are consumed by nothing testable — review triage RV3, verdict low, defer.
  evidence: Verified 2026-09-30 (`review_loop_iteration: 1`) — the repo's verification convention pins decision logic in `draft.ts` (`countScanAccepts` deny-by-default is verified there), and the call sites are one-line consumers with no screen harness; closing it means standing up app/-screen testing beyond this change. Filed as an open item for the epic-5 retro.

- source_spec: `spec-6-1-reorder-points-breach-alerts-and-suggested-pos.md`
  summary: A warehouse whose reservation counters were never bootstrapped (created after the last inventory-core boot, with no stock or reservations at boot) fails every ATP read closed (`reservation-store-unavailable`) and is skipped by the replenishment sweep with an error log each tick, until some grant's not-ready repair or a service restart rebuilds the counters — new-tenant warehouses therefore get no breach detection until their first reservation activity.
  evidence: `atp()` throws fail-closed when the ready marker is absent (`reservation.service.ts:658-664`, designed A8 behavior — never invent an ATP figure); the only rebuild triggers are startup discovery (`reservation.service.ts:296-308`, tenants owning reservations-or-stock at boot) and the not-ready grant repair (`:917`); the sweep skips the scope per the frozen matrix. The gap is the inventory core's missing eager bootstrap on new-warehouse/SKU creation — pre-existing (stories 2.3/4.1), surfaced by the replenishment worker's per-tick error logs. Settle by: an eager counters rebuild when a warehouse is created or its first SKU gets a reorder point (inventory core), or worker-side scope health logging that distinguishes not-ready from store-down.

- source_spec: `_bmad-output/implementation-artifacts/spec-6-2-expiry-and-aging-alerts.md`
  summary: `batches_tenant_expiry_idx` (0049) has no consuming query today — the expiry scan's intake read filters `(tenant_id, sku_id IN)` via `batches_tenant_sku_idx`; the index costs every batch write and carries a comment now reworded to admit it is provisioned-for-future use.
  evidence: `git grep expiry_date -- src/` over the feat/6-2 branch finds no SQL predicate or ORDER BY outside schema definitions / comments; FEFO expiry ordering is JS-side in `inventory.controller.ts`. Review triage (all three lenses, verdict medium) fixed the comments and kept the provisioned index — decide at the first expiry-range read story whether the consumer materializes or the index is dropped.

- source_spec: `_bmad-output/implementation-artifacts/spec-6-2-expiry-and-aging-alerts.md`
  summary: Dismissed batch alerts re-raise with fresh `batch_alert_raised` events on every conditioned scan — an operator cannot silence a slow-moving aged alert, rows and events accumulate per cycle.
  evidence: Open-only partial unique makes a dismissed row a new-row license (e2e pins A1's re-raise); the outcome is real (alert fatigue + unbounded row growth) but ratified by design — the frozen lifecycle decision, the FE success sentence, and PENDING's BY-DESIGN recording all pre-date this finding. The candidate fix (an explicit suppression lifecycle state on the row) is a new lifecycle design for a future story.

- source_spec: `_bmad-output/implementation-artifacts/spec-6-2-expiry-and-aging-alerts.md`
  summary: FE ships the expiry-alert OFF state with no path to ON — the config PUT has no web client wrapper, so every tenant's path to enabling the feature is a hand-rolled API call.
  evidence: Ratified scope cut — PENDING records the missing FE editor ("the route is live and capability-gated, only the web consumer is missing — 6-2 scope cut"). The minimal editor (two integer inputs + PUT with an `ulid()` key, the policy-upsert precedent) is a follow-up surface story.

- source_spec: `_bmad-output/implementation-artifacts/spec-6-2-expiry-and-aging-alerts.md`
  summary: The batch-alerts queue's actual read shape (warehouseId + status, often + kind) has no composite supporting index — the three keyset indexes are each single-filter, so the highest-frequency read residual-scans retained history.
  evidence: Verified index set (`tenant_id, <one filter>, created_at, id` × three) against the FE's always-sent warehouseId+status filter; the harm's magnitude over a large retained-history table is unverified (maybe-false — planner behavior not demonstrated; medium if true). Settle by: an `EXPLAIN` on a seeded large table (or the row-growth lifecycle bounding finding 12's accumulation) at the next scale-review point.

- source_spec: `_bmad-output/implementation-artifacts/spec-7-1-channel-connections-buffers-and-availability-sync.md`
  summary: Concurrent same-target `applyStandingBuffer` increases on one scope leave the counter over-reserved by one delta (both writers probe the same `previousMilli` and both run their grant deltas; the journal's A2-serialized UPDATE pins the target absolutely, so the journal is correct) — fail-safe direction, self-corrected by the reaper's parity pass.
  evidence: `increaseStandingBuffer` probes outside any lock (`reservation.service.ts:1809-1840`); the INSERT path 409s + compensates exactly via `reservations_open_owner_scope_unique` (`:1940-1947`); the UPDATE path with an existing row carries no CAS — the two grants both hit the counter (`:1859-1870`) while the journal ends at `targetMilli` (`:1890-1892`). Everyday use is unlikely (the FE busy-guards saves; double-flight needs two deliberate concurrent PUTs); fixing needs a core-side per-owner serialization (a scope-row FOR UPDATE around the probe) — a core change out of this story's boundary, and the parity pass bounds the harm.

- source_spec: `_bmad-output/implementation-artifacts/spec-7-1-channel-connections-buffers-and-availability-sync.md`
  summary: `channelVisibleQuantity` reads the pool ATP and the owner's own buffer sum in two separate transactions — a concurrent reservation between the reads bakes a staleness delta into one published figure or a refusal's `standingMilli`; self-correcting on the next publish cycle.
  evidence: `channelVisibleQuantity` (`reservation.service.ts:2092+`) calls `this.atp(...)` (own tx) then `withTenantTransaction` for `channelBufferUnitsInTx`. RN-6 mandates committed reads per scope; a combined single-tx arm does not exist for (atp ∪ own-buffer). Direction of staleness: a buffer increase between the reads overstates `V(c)` by the delta until the next cycle. Settle by: one combined core read arm if a consumer ever cares, or accept as publish-cycle semantics.

- source_spec: `_bmad-output/implementation-artifacts/spec-7-1-channel-connections-buffers-and-availability-sync.md`
  summary: Rotate commits between the disconnect's credential read and its delete re-lock — the NEW blob is deleted locally while only the stale one passed the revoke attempt (provider-side the stale credential dies, the last-rotated one dies un-revoked).
  evidence: Disconnect reads the credential from Phase-1's row (`channels.command.ts:698`), revokes outside any lock, and Phase-2 deletes whatever row then exists (`:721-746`); rotate locks and replaces in between. Unreachable harm today — the port's revoke arm answers the typed `501 channel-transport-unconfigured` for all three providers. Settle by: the 7-2/live-transport story re-reading the sealed credential at the delete re-lock (or attempting the revoke again post-re-lock) as part of its real revocation design.

- source_spec: `_bmad-output/implementation-artifacts/spec-7-1-channel-connections-buffers-and-availability-sync.md`
  summary: Row deleted between `integrationForDelivery` and `recordDelivery` → the handler rethrows and the relay burns its five-attempt budget before quarantining — DLQ noise for a connection that no longer exists.
  evidence: The designed ACK branch covers "connection left BEFORE delivery" (`channel-availability.delivery.ts:68-73`); the AFTER-read window (`:120`'s `recordDelivery` against a vanished row, handler rethrow at `:122-124`) is a millisecond race. Bounded: five attempts → quarantine. Settle by: having `recordDelivery` report the gone-row and skip the rethrow in that case only.

- source_spec: `_bmad-output/implementation-artifacts/spec-7-1-channel-connections-buffers-and-availability-sync.md`
  summary: `integration_calls` rows for a disconnected connection are never cleaned (no FK, no cascade, no retention policy) — append-only metered history accumulates forever under a deleted connection id.
  evidence: Migration `0050` defines `integration_calls` with no FK to `integrations` (checked the CREATE TABLE); disconnect Phase-2 deletes the connection + mappings but preserves its meter rows. A retention/cleanup policy (or a documented keep-for-history rationale) is an ops-grade question, not a 7-1 defect.

- source_spec: `_bmad-output/implementation-artifacts/spec-7-2-channel-order-ingestion-and-fulfillment-writeback.md` (code review, iteration 2)
  summary: The ingest-verification meter opens a transaction and a newest-row SELECT per refused request, and its read-then-insert window can mint more than one row per 60 s — a tamper/storm costs a short tx per bad request and a window's cap can be briefly over-set.
  evidence: `recordIngestVerificationRefused` (`channels.publish.ts`) opens `withTenantTransaction` and SELECTs the window's newest row serially per call; no lock protects the window check against two concurrent refusals. Correctness fine (a few extra coarse rows); the bloom/cap alternative is the 5-x metering machinery re-derivable later.

- source_spec: `_bmad-output/implementation-artifacts/spec-7-2-channel-order-ingestion-and-fulfillment-writeback.md` (code review, iteration 2)
  summary: A concurrent dedup loser meters `accepted` even though its order was released — the meter can overstate accepted orders at contended SKUs.
  evidence: Outcome label derives from a pre-create read (`channels.ingest.command.ts` ~:186-193) then `createOrder` resolves the loser via `resolveDedupLoser`; the loser's meter row answers `accepted`/`backordered` per the stale read. The ORDER system stays correct (the losing delivery is released; the winner is the order). Settle by: metering from the command's post-facade outcome value.

- source_spec: `_bmad-output/implementation-artifacts/spec-7-2-channel-order-ingestion-and-fulfillment-writeback.md` (code review, iteration 2)
  summary: The disconnect's post-commit revoke block can be skipped by a crash between phase-2's commit and the attempt — the channel-side key stays live with no local record.
  evidence: Phase-1 replay settle returns before the revoke; the revoke runs after the phase-2 commit within the same request (`channels.command.ts` disconnect flow). A crash in the gap leaves Shopify's webhook secret + token live while `integrations` is deleted. Settle by: a background reaper sweeping connections deleted while `revoked_at` is unset (an ops-grade job, not a request path).

- source_spec: `_bmad-output/implementation-artifacts/spec-7-2-channel-order-ingestion-and-fulfillment-writeback.md` (code review, iteration 2)
  summary: One availability-publish delivery carries all ≤ 200 scopes through the arm in a single sequential lane — a slow channel response serializes the publish behind it; fine at 15× smoke, unbounded at larger scope counts.
  evidence: `channel-availability.delivery.ts` (~:103/:107) invokes the arm once with `request.scopes`; `channel-http.ts` is sequential per attempt; 7-1's concurrency shape was accepted there and this story adds no lane. Settle by: lane split or batched posts when scope counts grow (the SKU × warehouse ceiling can exceed 200 rows).

- source_spec: `_bmad-output/implementation-artifacts/spec-7-2-channel-order-ingestion-and-fulfillment-writeback.md` (code review, iteration 2)
  summary: `parseOrderRef` accepts any string ≤ 200 including `/`, `?` and `..` — an externally-controlled identifier with no shape policy; safe today (parameterized reads only), a hazard if the ref ever flows into a path-like surface.
  evidence: `channel-shopify-port.ts` `parseOrderRef`; lookups ride typed SQL parameters. Settle by: a stricter ref shape (Shopify ids are numeric strings) at the parse arm.

- source_spec: `_bmad-output/implementation-artifacts/spec-7-2-channel-order-ingestion-and-fulfillment-writeback.md` (code review, iteration 2)
  summary: A mappings GET racing the disconnect's phase-2 delete answers 200 with empty rows for a connection that is being deleted — a transient read-your-deletion oddity, no stale data leaks after the commit.
  evidence: Mappings GET does not lock or recheck connection existence beyond the initial read. Settle by: 404 on the row-missing race if a consumer ever surfaces it.

- source_spec: `_bmad-output/implementation-artifacts/spec-7-2-channel-order-ingestion-and-fulfillment-writeback.md` (Spec Change Log #5 / triage row 38) — **RESOLVED 10-02-2026**

  The 2-hour 15× NFR-2 acceptance run was driven by the user on 2026-10-02 against the patch-round tree (wms-be `44dfd4a`): 7,200 s at the recorded invocation, 100% of target achieved, 3,597 deliveries, p50 69 ms / p95 419 ms (gate ≤ 4,000 ms), > 5 s fraction 0, 7,106 concurrent adjustments, oversells 0 (all parity sweeps empty), no pool deadlock. Report committed at wms-be `artifacts/nfr2-2h-report.json` (commit `cec7c73`); the retained suite DB was dropped. No settlement left.

## Deferred from: code review of spec-8-1-gst-compliant-invoicing (2026-10-03)

- **Kit orders always park `awaiting-data`, even when priced at create.** The parent's frozen `ratePaise` drops with the zero-pick parent line, and the components are exploded with `rate_paise = null`, so every kit dispatch needs per-component manual pricing. Reason for deferring: per-component manual pricing works for 8-1, and splitting a kit's price across components needs a rounding rule designed on purpose, not improvised.

## Deferred from: bmad-build scope split of story 8-2 (2026-10-03)

- source_spec: none
  summary: E-way bills — single and batch generation above a versioned-config threshold behind the EwayGateway port, with sealed GSP/portal credentials and the OQ3 (portal vs GSP) decision; the core of story 8-2.
  evidence: Split from the 8-2 intent as an independently shippable goal; it reads the invoice number/date/value that the invoice regulatory pass (taken first) may change.
- source_spec: none
  summary: HSN summary — per accounting-period HSN totals for GST filing, a read model over issued invoices; the second half of story 8-2.
  evidence: Split from the 8-2 intent as an independently shippable goal; it sums invoice values whose rounding and revision semantics the regulatory pass settles first.
- source_spec: none
  summary: Web inputs for GSTINs and prices — tenant gstin on register, warehouse gstin on warehouse create, consigneeGstin and per-line ratePaise on the order form (none exist today, so invoices cannot issue from the UI alone).
  evidence: Split from the 8-2 intent (carried from the 8-1 seed run) as an independent FE-only deliverable.

## Deferred from: code review of spec-8-1b-invoice-regulatory-pass (2026-10-03)

- source_spec: `_bmad-output/implementation-artifacts/spec-8-1b-invoice-regulatory-pass.md`
  summary: Voided invoices — extend `invoices_issued_stamped_check` to `invoice_no IS NULL OR origin_gstin IS NOT NULL` (so a voided number cannot escape the per-GSTIN unique through a NULL GSTIN) and pin the voided half of the freeze with a test.
  evidence: The freeze and the docs cover voided rows, but no code path creates one until the void/credit-note story; that story must add the constraint and the test together.

## Deferred from: code review of spec-8-1c-web-gstin-and-price-inputs (2026-10-03)

- source_spec: `_bmad-output/implementation-artifacts/spec-8-1c-web-gstin-and-price-inputs.md`
  summary: Order outcome — add an "invoice will wait for pricing" note when NO line is priced (today only a partly priced order is noted).
  evidence: Pre-existing outcome copy (the wholly unpriced case predates 8-1c); the invoice's awaiting state is still visible on /compliance.
- source_spec: `_bmad-output/implementation-artifacts/spec-8-1c-web-gstin-and-price-inputs.md`
  summary: Decide whether the invoice pricing panel (`parseRateDraft`, 8-1b) should also refuse ₹0, as the order form now does.
  evidence: The 8-1c human decision refused ₹0 on the order form because a typed rate is frozen; a panel rate freezes into an issued invoice just as permanently. Human decision needed.
- source_spec: `_bmad-output/implementation-artifacts/spec-8-1c-web-gstin-and-price-inputs.md`
  summary: Cross-repo drift guard for the FE `GSTIN_RE` mirror against wms-be `src/shared/primitives/gstin.ts`.
  evidence: The mirror test compares against a literal; 8-2's regulatory pass will change the backend regex, so the guard belongs there.

- source_spec: `_bmad-output/implementation-artifacts/spec-8-2b-e-way-bills.md`
  summary: E-way generate's malformed-gateway-result arm and its taken-EWB-number arm have no tests; the sandbox adapter can produce neither (code review C13).
  evidence: Verified by grep in test/eway.spec.ts. Add the tests with the first live EwayGateway adapter, which is where those results become reachable.

- source_spec: `_bmad-output/implementation-artifacts/epic-8-retro-2026-10-05.md`
  summary: The GSTIN_RE FE↔BE drift guard is still missing, and the earlier deferral's rationale ("8-2's regulatory pass will change the backend regex") no longer holds — 8-1b and 8-2 left both regexes unchanged (BE `shared/primitives/gstin.ts`, FE `lib/gstin.ts`).
  evidence: Verified at the epic-8 retro (R6). Folded into retro action A5 (one FE↔BE constants drift guard) and A1 (GSTIN state-prefix validation changes both files together).

- source_spec: `_bmad-output/implementation-artifacts/spec-9-1-operational-dashboard.md`
  summary: 9-1b dashboard click-through (frontend only) — the Ledger page at /inventory (URL-driven filters by event type, date range, reference doc and shortPick, with views for pack-verification failures and reservation refusals) and URL filters on /replenishment (alert kind/status), /outbound (order status), /conflicts (queue incl. over-receipts) and /channels.
  evidence: Split from 9-1 at the human's request (2026-10-06) to halve the review surface; 9-1 ships every backend list filter and drill definition, so 9-1b is frontend-only and needs no backend or migration change.

- source_spec: `_bmad-output/implementation-artifacts/spec-21-5-client-invoices.md`
  summary: 21-5b — dispute drill-down: expand a client invoice line to the source records (GRN lines, picks, first-dispatch order events, per-day/per-SKU storage) that produced its quantity, reusing 21-4's shared predicates.
  evidence: Split by the human on 2026-10-07 when scoping 21-5; independently shippable after 21-5's invoice lines exist.
- source_spec: `_bmad-output/implementation-artifacts/spec-21-5-client-invoices.md`
  summary: Epic-8 retro A5 invoicing cleanup — extract generator.ts and eway-bills.tsx, de-duplicate state maps/instant regex/FE IST handling/loader helpers, one FE-BE constants drift guard, converge the idempotency skeleton, lock the config commands, fix supplyType nullable-enum.
  evidence: Split by the human on 2026-10-07; a pure refactor with no 21-5 dependency, reviewed better on its own diff.
- source_spec: `_bmad-output/implementation-artifacts/spec-21-5b-dispute-drill-down.md`
  summary: Test the refresh restamp of `client_invoices.storage_measured_through` when the content hash is unchanged but the group watermark moved.
  evidence: 21-5b code review (verification-gap); reverting `restampMeasuredThroughInTx` fails no test. Impact is limited to breakdown 404s on zero-stock days; the setup needs a client in two groups with out-of-step snapshot watermarks.
- source_spec: `_bmad-output/implementation-artifacts/spec-21-6-advance-shipment-notices.md`
  summary: ~~21-6b — the handheld receives against an ASN: parse the snapshot's `openAsns` arm (`?? []` default), an ASN context in the receive draft beside `poId`, `asnId`/`asnLineId` on the `grn.submit` payload without changing existing PO/blind hashes, ASN refusals in the replay fate table, ASN cards in the inbox and choose step.~~ **DONE 2026-10-09 by story 21-6b** (`spec-21-6b-handheld-asn-receiving.md`) — wms-mobile parses `openAsns`, receives against an ASN through the one draft/resolver/progress path, and leaves PO and blind payloads byte-identical; wms-fe retired the "next handheld update" notice.
  evidence: Split by the human on 2026-10-08 when scoping 21-6; a separate repo (wms-mobile, hand-written API types) and independently shippable once 21-6's server side lands.
- source_spec: `_bmad-output/implementation-artifacts/spec-21-6-advance-shipment-notices.md`
  summary: De-flake `test/ledger.spec.ts` "idempotency race: a concurrent same-key submit collides on the unique key as 409 conflict" — it polls a fixed number of times for the second request to block (`expect(blocked).toBe(true)`, ~:891) and fails under full-suite load.
  evidence: Failed in the full wms-be run during 21-4 (2026-10-07) and again during 21-6 (2026-10-08); passed 3/3 run alone both times; neither story touched ledger or idempotency code. Fix: wait on pg_locks / pg_stat_activity for the blocked backend with a generous deadline rather than a fixed poll count.
- source_spec: `_bmad-output/implementation-artifacts/spec-21-6b-handheld-asn-receiving.md`
  summary: Receive-draft line resolution with the same SKU on two PO/ASN lines — every scan resolves to the first open line, so its overflow pends as an over-receipt while the second line stays open; resolve against draft-remaining open qty instead.
  evidence: `resolveLineRefs` in wms-mobile `src/receiving/draft.ts` keeps the pre-21-6b `resolvePoLineId` rule (first line with cached openQty > 0, ignoring units already in the draft); found by 21-6b code review (C9).
