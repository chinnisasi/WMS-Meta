
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
