---
title: 'Story 1.2 — Tenant registration and warehouse creation'
type: 'feature'
created: '2026-09-08'
status: 'in-review'
baseline_commit: 'meta 7146a24174a89c5e99f4e4ab2a5fe224cfa4f7e7 · wms-be f53742baaff54668566c7f8c611bec6b3a0f78af · wms-fe 952a9d86b97f9fd1cb06a1a7b2beaf6541eee4d9'
route: 'dispatch'
review_loop_iteration: 1
context: ['_bmad-output/implementation-artifacts/epic-1-context.md']
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** The scaffold (1.1) has no domain tables — a seller cannot sign up, get an isolated tenant, or define stocking sites. Every later story needs tenants, the tenant-scoping discipline, and warehouses to exist.

**Approach:** In the tenancy module, land the first real tables (tenants, users, warehouses, idempotency keys) with `tenant_id` on every row, the first command services, real idempotency storage, and Postgres RLS as verified defense-in-depth; expose tenant registration and warehouse creation over OpenAPI; give the web app a registration page, warehouse creation in Settings, and a warehouse switcher in the sidebar.

## Boundaries & Constraints

**Always:**
- AD-3: every new table carries `tenant_id` (uuid v7, NOT NULL); `warehouses` is the first warehouse-scoped table pattern. App-layer scoping on every query path; Postgres RLS enabled on all new tables as defense-in-depth, verified by test (cross-tenant read under another tenant's session returns nothing).
- AD-5: every mutating endpoint requires a client `Idempotency-Key` (ULID) — real tenant-scoped storage (key + payload hash → response snapshot) de-duped in the same transaction as the write; replay returns the original response.
- AD-10: state changes enter through command services in the tenancy module (first precedent for the command layer); errors are RFC 9457 problem-details with machine-readable `code` (e.g. `duplicate-warehouse-code` naming the code).
- Warehouse codes unique per tenant (unique `(tenant_id, code)`); duplicate rejection names the conflicting code.
- Passwords hashed with `node:crypto` scrypt (no new dependency); deterministic primitives from 1.1 (uuidv7 ids, UTC timestamps) throughout.
- OpenAPI is the contract: regenerate the wms-fe client from the updated spec (pipeline + CI guards from 1.1).

**Never:**
- No zones/bins (1.3), no catalog (1.4), no role permission gating (1.5 — the Owner user carries no role enforcement yet), no refresh tokens, no email verification, no billing.
- No mobile changes (the Expo app keeps its health screen; contract unchanged for it).
- No stock/inventory tables — the zero-warehouse invariant is established as a tenancy export + test (below), consumed by Epic 2.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Registration | POST /tenants `{name, ownerEmail, password}` + valid Idempotency-Key | 201: tenant + owner user (user has no password hash exposed) | 409 `duplicate-email` if owner email exists |
| Replay | Same registration replayed with same key | Original 201 response re-served from idempotency store | N/A |
| Warehouse create | POST /tenants/{id}/warehouses `{code, name}` | 201: warehouse, unique code, appears in switcher | 409 `duplicate-warehouse-code` naming the code |
| Cross-tenant read | Session/`app.tenant_id` of tenant A; SELECT tenant B's warehouse rows | 0 rows (RLS + app scope) | N/A |

**Decisions (human-owned):**
- **Minimal sign-in is in scope:** `POST /tenants/sign-in` verifies the password and returns a short-lived HS256 JWT (hand-signed with `node:crypto`, no refresh) carrying `tenant_id` + `sub`. Warehouse endpoints require it; the web gets a `/login` page and the RLS AC is tested over real HTTP.

</frozen-after-approval>

## Code Map

- `workspace/core/backend/wms-be/src/modules/tenancy/` -- empty stub; receives schema, command services, controllers. Owns tenants, users, warehouses (spine AD-6).
- `workspace/core/backend/wms-be/src/shared/db/schema.ts` -- single-file schema convention; add `tenants`, `users`, `warehouses`, `idempotency_keys` (all uuidv7 PK, `timestamp with time zone, mode: 'string'`). Do NOT touch `app_metadata`.
- `workspace/core/backend/wms-be/src/shared/idempotency/idempotency.seam.ts` -- `parseIdempotencyKey()` shape validation is ready; the real table + same-transaction de-dupe land here-directed ("inside the tenancy module").
- `workspace/core/backend/wms-be/src/shared/db/db.ts` -- `createDatabase()`; **no DI provider exists yet** — add a `Database` provider (SharedModule) as the first wired DB consumer.
- `workspace/core/backend/wms-be/src/api/echo.controller.ts` -- the controller/DTO/OpenAPI pattern to copy (`@ApiExtraModels`, `problemJsonResponse`, ValidationPipe-enforced DTOs).
- `workspace/core/backend/wms-be/test/api.spec.ts` -- e2e pattern (supertest against `createApp(false)`); RLS test needs two tenant-scoped DB sessions (postgres-js `SET LOCAL app.tenant_id` per transaction).
- `workspace/core/frontend/wms-fe/src/app/` -- 12 placeholder surfaces; `/settings/page.tsx` hosts warehouse creation (EXPERIENCE.md puts warehouses there); `/register` is NEW, outside `AppShell` (signup must not render the app sidebar).
- `workspace/core/frontend/wms-fe/src/components/shell/sidebar.tsx` -- warehouse switcher goes here (mockup `key-web-overview.html` shows the `.wh` block: code+name, "1 of N", chevron).
- `workspace/core/frontend/wms-fe/src/lib/api/client.ts` -- follow the `fetchApiX` wrapper shape for the new endpoints; regenerate via `bun run api:generate`.
- No form/validation libs exist — hand-rolled `'use client'` forms; honest glyph+word+reason feedback per the accepted/rejected banner pattern (radius-md, one reason line).

## Tasks & Acceptance

**Execution:**
- [x] `wms-be/src/shared/db/schema.ts` + new drizzle migration -- add `tenants`, `users` (email unique, scrypt hash), `warehouses` (unique `(tenant_id, code)`), `idempotency_keys` (unique `(tenant_id, key)`, payload hash, response snapshot); enable RLS + policies on all four.
- [x] `wms-be/src/shared/db/db.ts` or `shared.module.ts` -- wire a `Database` DI provider (first real consumer).
- [x] `wms-be/src/modules/tenancy/**` -- registration + warehouse command services (the command-layer precedent: validate, hash, write, emit domain event via the seam), controllers with OpenAPI DTOs per the echo pattern, idempotency de-dupe in the same transaction, `requireActiveWarehouse(tenantId)` export.
- [x] `wms-be/test/**` -- e2e: registration, replay (same key), duplicate email, duplicate warehouse code (names code), RLS cross-tenant read via two `app.tenant_id` sessions, zero-warehouse invariant test.
- [x] `wms-fe/src/app/register/page.tsx` (+ `layout` route outside AppShell) -- registration form (business name, email, password), honest success/error states.
- [x] `wms-fe/src/app/login/page.tsx` -- sign-in form (email, password) storing the JWT for subsequent API calls (per the sign-in decision).
- [x] `wms-fe/src/app/settings/page.tsx` + `src/components/shell/sidebar.tsx` -- warehouse create form in Settings; sidebar switcher listing warehouses (code+name, count) fed from the generated client.
- [x] `wms-fe/src/lib/api/generated/**` -- regenerate from the updated OpenAPI doc (never hand-edit).
- [x] `docs/repos/wms-be/README.md`, `docs/repos/wms-fe/README.md` (meta) -- record the new endpoints, session model, RLS mechanism in the interface contracts.

**Acceptance Criteria:**
- Given no account exists, when an Owner registers, then a Tenant and its Owner user are created with `tenant_id` stamped on every row.
- Given a registered Tenant, when creating a Warehouse with a unique code, then it appears in the warehouse switcher.
- Given a Tenant with zero Warehouses, when any stock-record creation is attempted, then it is rejected — enforced by the tenancy `requireActiveWarehouse` guard (Epic 2 consumes it) and verified by test in this story.
- Given a cross-tenant read attempt under another tenant's session, then it fails (RLS verified by test).
- Given both repos, when lint + tests + typecheck + build run, then all pass; the OpenAPI drift guards stay green.

## Implementation Notes

- (empty)

## Spec Change Log

## Review Triage Log

*Review loop 1 — 3 layers (blind-hunter 16, edge-case-hunter 19, verification-gap 7); duplicates across layers filed as separate rows, grouped at routing.*

- Sign-in returns 401 for every user under the mandated non-superuser deployed RLS role — **high** — verified: `sign-in.command.ts:32-53` queries `users`/`tenants` unscoped; the fail-closed policies hide all rows with no `app.tenant_id`; `docs/repos/wms-be/README.md` mandates a non-superuser deployed role. The "table owner reads it directly" comment holds only for the dev superuser.
- Registration replay breaks under the same non-superuser role (replay re-runs the insert → 409 duplicate-email) — **high** — verified: `registration.command.ts:63-67` looks up by key alone before `setTenantScope` (`:79`); fail-closed RLS hides the stored row, contradicting the frozen Replay matrix row in the mandated deployment.
- Idempotency payload hash embeds the plaintext password — **medium** — verified: `registration.command.ts:55-59` hashes `{name, ownerEmail, password}`; sha256 over canonical JSON containing the raw password is offline-brute-forceable from a DB leak.
- CI `lint-and-test` never migrates its fresh Postgres — tenancy e2e suite red on every PR — **high** — pre-verified (verification-gap): `ci.yml` gives the job a postgres service + `DATABASE_URL` but no `db:migrate` (that step exists only in the separate `migrations` job); no globalSetup in `jest.config.js`.
- Warehouse same-key replay and 422 reuse never exercised — **medium** — pre-verified (verification-gap): every warehouse test uses a fresh ULID; no test resends the same key or sends same-key/different-payload.
- Frontend session/interceptor/ApiProblem layer has zero test coverage — **medium** — pre-verified (verification-gap): no test in either repo executes `client.ts` or `auth.ts`; interceptor/expiry/code-mapping regressions are invisible.
- Drizzle snapshot records `isRLSEnabled: false`, `policies: {}` for all four tables — **medium** — verified: `schema.ts` declares no `enableRLS`/`pgPolicy`; RLS exists only in hand-written migration SQL, so future `drizzle-kit generate` diffs against a snapshot blind to it.
- Concurrent same-key warehouse create: 409-conflict branch is dead code, real loser path 500s — **medium** — verified: `warehouse.command.ts:105` checks `IDEMPOTENCY_TENANT_KEY` inside the *warehouses*-insert catch (that constraint belongs to `idempotency_keys`, so it can never fire there); the actual idempotency insert at `:119` is unguarded → concurrent loser gets a raw 500 (different payload) or a misleading `duplicate-warehouse-code` 409 (same payload).
- `readSession()` clears + dispatches from inside a `useSyncExternalStore` snapshot getter — **medium** — verified: `auth.ts:39-42` calls `clearSession()` (localStorage remove + event dispatch) when expired; the getter runs during render for the switcher and both forms — a render-time side effect that can warn/loop.
- No sign-out affordance anywhere — **medium** — verified: `clearSession` has no caller in `src/`; the only way out of a session is the 15-minute TTL. The frozen intent doesn't address sign-out either way.
- Emails never normalized (case-variant duplicate tenants; sign-in casing mismatch) — **low** — verified: `registration.command.ts:80` stores `ownerEmail` verbatim; the global unique index is case-sensitive.
- Switcher counts one page; warehouses past page 1 unpickable — **low** — verified: `sidebar.tsx:70-86` fetches once (default limit 50, no cursor loop); "Warehouse N of M" counts only fetched items.
- OpenAPI documents 401/403 but defines no security scheme — **low** — verified: no `securitySchemes` in `openapi/openapi.json`; Swagger UI cannot exercise the warehouse endpoints.
- RLS e2e probe covers SELECT only — no INSERT/`WITH CHECK` under the non-superuser role — **low** — verified: `tenancy.spec.ts` RLS test only asserts read isolation.
- Cursor pagination (`nextCursor` chain, `invalid-cursor` 400) never exercised — **low** — verified: every list test creates one warehouse; `nextCursor` is always null.
- Duplicate-email test never asserts rollback of partial rows — **low** — verified: `tenancy.spec.ts:135-146` asserts the 409 body only.
- `Bearer` scheme matched case-sensitively — **low** — verified: `tenant-session.guard.ts:29` uses `startsWith('Bearer ')`; RFC 7235 schemes are case-insensitive.
- Timing side-channel enumerates emails (unknown email skips scrypt) — **low** — verified: `sign-in.command.ts:38` short-circuits before `verifyPassword` for unknown emails (≈0 ms vs ≈100 ms) despite the identical 401 body.
- Switcher keeps the previous tenant's warehouse list after cross-tab re-login — **low** — verified: fetch effect deps `[fetching, revision]` track session presence, not identity.
- Active-warehouse localStorage key is global across tenants — **low** — verified: `warehouses.ts` uses one un-namespaced key, never cleared on session change; a stale id falls back to index 0.
- `requireActiveWarehouse` returns the newest warehouse; will collide with the frontend's picked-warehouse notion in Epic 2 — **maybe-false** — a design prediction, not a current defect; settling it requires Epic 2's active-warehouse design.
- Migration never issues `FORCE ROW LEVEL SECURITY` (Design Notes say tests use it) — rejected — the fix is an edit to this build's spec, which triage does not make.
- No foreign keys on `tenant_id` — false — no code path in this story deletes or re-parents tenants/users/warehouses, so no orphan is reachable; revisit when deletion arrives.
- Future-dated `iat` accepted — false — forging `iat` requires the signing secret (HMAC verified at `jwt-session.ts:77-84`); `exp` is enforced; the server never issues future `iat`.
- Sign-in carries no `Idempotency-Key` despite AD-5 — false — sign-in is not a mutating endpoint (no state change); AD-5 covers mutating endpoints.
- Warehouse form click is a silent no-op when the session expired between render and submit — false — `clearSession()` inside `readSession()` dispatches the session-changed event, flipping the form to the honest signed-out prompt.
- Cursor cast can 500 on exotic timestamps — rejected (low) — `Date.parse` already rejects malformed components; the residual hole needs Date-parseable/PG-invalid values, unreachable in practice.
- Registration replay can 422 spuriously via a cross-tenant key collision — rejected (low) — needs a cross-tenant ULID collision or a payload-hash match an attacker cannot compute without the password.
- Concurrent registration with the same key → loser 409s duplicate-email — rejected (low) — no corruption (the global email unique arbitrates); the fix adds advisory-lock complexity for a microsecond race.
- Interceptor attaches the bearer token to anonymous endpoints — rejected (low) — anonymous endpoints ignore the header; no functional divergence.
- `unwrapError` falls back to status 400 on network failure — rejected (low) — `ApiProblem.status` is not consumed by any UI branch.
- `rejectionReason` duplicated across auth-forms and warehouse-create-form — rejected (low) — divergence risk only when editing both files' error handling; the fix is a refactor, not a direct correction.
- `client.ts` imports `../auth` vs the `@/lib/` alias — rejected (low) — cosmetic; both resolve identically.
- ~20 new files lack trailing newlines — rejected (low) — lint deliberately does not enforce; no functional harm.
- `sprint-status.yaml` says in-progress while the spec says in-review — false — the story is still in flight; the workflow updates sprint status at close-out.
- wms-fe generated-client drift guard checks out wms-be from the default branch — false — the prescribed backend-first PR order means the wms-fe PR runs against wms-be `main` already containing the tenancy spec.

## Design Notes

- RLS mechanism (spine leaves open): per-request DB transaction runs `SET LOCAL app.tenant_id = '<uuid>'`; policies are `USING (tenant_id = current_setting('app.tenant_id')::uuid)` with the table owner non-bypassing via `FORCE ROW LEVEL SECURITY` in tests. App layer stays authoritative; RLS is the backstop.
- Idempotency: unique `(tenant_id, key)` + payload-hash comparison; hash mismatch → 422 `idempotency-key-reuse`; retention bounded later (AD-5).
- Sign-in (if Open Question (a)): `POST /tenants/sign-in` → HS256 JWT, 15-min expiry, `tenant_id`+`sub` claims; no refresh in this story.

## Verification

**Commands:**
- `bun run db:migrate` + `bun run db:verify` (wms-be) -- expected: migration applies cleanly; round-trip green
- `bun run test` (wms-be) -- expected: all pass incl. RLS + idempotency replay e2e
- `bun run openapi:export` then `bun run api:generate` (wms-be → wms-fe) -- expected: regenerated client with new endpoints/types
- `bun run lint && bun run test && bun run typecheck && bun run build` (wms-fe) -- expected: all green
- `bun run test:e2e`-style supertest run covers both happy and error rows of the I/O matrix