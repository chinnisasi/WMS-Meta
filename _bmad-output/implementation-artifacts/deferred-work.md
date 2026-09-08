
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
