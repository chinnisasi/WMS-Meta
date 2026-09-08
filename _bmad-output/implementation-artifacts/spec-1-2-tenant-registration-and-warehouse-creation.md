---
title: 'Story 1.2 — Tenant registration and warehouse creation'
type: 'feature'
created: '2026-09-08'
status: 'done'
baseline_commit: 'meta 7146a24174a89c5e99f4e4ab2a5fe224cfa4f7e7 · wms-be f53742baaff54668566c7f8c611bec6b3a0f78af · wms-fe 952a9d86b97f9fd1cb06a1a7b2beaf6541eee4d9'
route: 'dispatch'
review_loop_iteration: 2
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
- [x] `wms-be/src/modules/tenancy/**` (review loop 1) -- auth-time reads (sign-in, registration replay lookup) move to a dedicated `AUTH_DATABASE` BYPASSRLS connection (`DATABASE_AUTH_URL`, falls back to `DATABASE_URL`); tenant-scoped paths unchanged; payload hash covers `{name, ownerEmail}` only — the task originally said `passwordHash`, corrected during the rework (scrypt salt is random per call, so a hash-based fingerprint breaks replay; see Design Notes); concurrent same-key warehouse create returns 409 `conflict` instead of 500; owner emails normalized (`trim().toLowerCase()`); `Bearer` scheme matched case-insensitively; unknown-email sign-in burns a dummy scrypt round; CI `lint-and-test` gains a `db:migrate` step; OpenAPI gains a bearer security scheme.
- [x] `wms-be/test/**` (review loop 1) -- add: warehouse same-key replay + same-key/different-payload 422; RLS INSERT (`WITH CHECK`) probe under the non-superuser role; duplicate-email rollback assertion; cursor-pagination chain + `invalid-cursor` 400. (31/31 e2e pass.)
- [x] `wms-fe/src/**` (review loop 1) -- sign-out affordance calling `clearSession()`; `readSession()` made side-effect-free (no clear/dispatch inside the snapshot getter); switcher loads all cursor pages and re-fetches on session identity; active-warehouse storage scoped per tenant; bun tests for `readSession` (expiry/corruption, no mutation) and the `ApiProblem` code mapping. (Lint/typecheck/tests/build green; client regenerated from the bearer-scheme spec.)
- [x] `wms-fe/src/proxy.ts` (review loop 2) -- auth gate (Next 16 renames middleware to proxy): signed-out `(app)` requests redirect to `/login`; signed-in requests to `/login`//register` redirect to the app; presence-only `wms-session-hint` cookie mirrors the session for the server-side gate; Settings in-page prompt stays as fallback.
- [x] `wms-fe/src/components/shell/**` (review loop 2) -- warehouse switcher extracted to `warehouse-switcher.tsx` over the shared `useTenantWarehouses` hook; renders in the mobile header menu (visibility via `className` per mount). `WarehouseList` (Settings) now uses the same hook — tenant-identity scoping + full cursor chain.
- [x] `wms-be/**` (review loop 2 patches) -- cursor payload `id` validated (uuid) so crafted cursors 400 not 500; DTO input normalization (`@Transform` trim on emails, warehouse code/name trimmed before uniqueness); OpenAPI tightened (`format: email`, `limit` min/max, `format: uuid` path param); role-provisioning SQL (`scripts/provision-roles.sql`) + loud fallback warning for `DATABASE_AUTH_URL`; guard docstring corrected; `hashCommandPayload` comment corrected; tests: JWT negative paths (expired/wrong-secret/tampered → 401), `AUTH_DATABASE` e2e under an RLS-binding role (`wms_auth_probe`), RLS WITH CHECK probe assertion awaited, `afterAll` closes `AUTH_DATABASE`. (34/34 e2e pass; lint/typecheck/build green.)
- [x] `wms-fe/**` (review loop 2 patches) -- `WarehouseList` matches the switcher contract (tenant-identity-scoped fetch + render filter, full cursor chain); `client.test.ts` asserts the `Authorization` header (present signed-in, absent signed-out) and its stub no longer leaks (fresh globals per test); `auth.test.ts` covers the hint-cookie lifecycle. (31 unit tests pass; lint/typecheck/build green.)
- [x] `wms-be/**` (review loop 3 patches) -- registration rework: payload fingerprint → replay lookup → `hashPassword` only on miss (replays stop paying scrypt); publish-after-commit guarded in both command services (a throwing bus logs and returns the 201); `LoggingEventBus` drops event payloads from its log line (owner emails are PII); migration `0002` adds the `idempotency_keys(key)` index (registration replay no longer sequential-scans); OpenAPI `Idempotency-Key` header gains the ULID pattern/length, response ids gain `format: uuid` + uuid-v7 examples; `provision-roles.sql` dead `\set` lines removed with an in-file note; `.env.example` `JWT_SECRET` replace-before-running warning; redundant `Number(query.limit)` dropped; e2e additions: malformed `Idempotency-Key` on warehouse create (400) and `limit` bounds (0/201 → 400, 1/200 → 200). (36/36 tests incl. e2e pass; lint/typecheck/build green; spec re-exported.)
- [x] `wms-fe/**` (review loop 3 patches) -- expiry watchdog in `auth.ts` (timer dispatches `SESSION_CHANGED_EVENT` at `expiresAt`, rescheduled on rewrite, cleared on clear — the silent-submit no-op E1 fix); 401 response interceptor in `client.ts` (`clearSession()` on the backend's unauthenticated verdict); hint-cookie hardening (`Secure` on https; written only after `localStorage.setItem` succeeds; `ensureSessionHint()` bootstrap re-assert on the first API call); switcher gains Esc + outside-click dismissal and an `onPicked` prop the mobile menu uses to close the header nav; the cursor-chain walk extracted to `fetch-all-warehouses.ts`. Tests: `proxy.test.ts` (gate matrix), `fetch-all-warehouses.test.ts` (page merge, single page, 20-hop bound), `client.test.ts` (Idempotency-Key header, 401 clears session, 409 leaves it), `auth.test.ts` (expiry timer fires + reschedule cancels, bootstrap re-assert). (47 unit tests pass; lint/typecheck/build green; client regenerated from the tightened spec.)

**Acceptance Criteria:**
- Given no account exists, when an Owner registers, then a Tenant and its Owner user are created with `tenant_id` stamped on every row.
- Given a registered Tenant, when creating a Warehouse with a unique code, then it appears in the warehouse switcher.
- Given a Tenant with zero Warehouses, when any stock-record creation is attempted, then it is rejected — enforced by the tenancy `requireActiveWarehouse` guard (Epic 2 consumes it) and verified by test in this story.
- Given a cross-tenant read attempt under another tenant's session, then it fails (RLS verified by test).
- Given both repos, when lint + tests + typecheck + build run, then all pass; the OpenAPI drift guards stay green.

## Implementation Notes

- (empty)

## Spec Change Log

- **2026-09-08 — Review loop 1 (intent_gap resolution + bad_spec amendment).** The review found that sign-in and registration replay read the database before any tenant context exists, so the fail-closed RLS policies hide every row under the non-superuser deployment role the wms-be README mandates — the frozen RLS mandate and the "lookup by key alone" note were mutually unsatisfiable as written. **Human resolution (2026-09-08):** (1) *auth-time reads go through a dedicated BYPASSRLS connection* — a second Drizzle/postgres-js instance (`AUTH_DATABASE` token, `DATABASE_AUTH_URL` env, falling back to `DATABASE_URL`) used only by sign-in and the registration replay lookup; every tenant-scoped path stays on the fail-closed scoped connection, and the README contract must document that the auth connection's role carries BYPASSRLS (or superuser) while the app role does not. (2) *Sign-out is in scope:* a sign-out affordance that calls `clearSession()` — the session lifecycle the story introduced must be closable, not just 15-min-TTL-expiring. (3) *Rework on top of a safety commit* rather than a strict revert: the step-03 implementation is preserved as commit `29fd6f1` (wms-be) / `01b5ee2` (wms-fe), and the rework applies the human resolutions plus the 17 verified patch findings (see Review Triage Log) as amendments. **KEEP (must survive the rework):** the fail-closed RLS policies with the NULLIF empty-string guard; the wms_rls_probe non-superuser e2e pattern; same-transaction idempotency de-dupe; the command-layer shape (validate → hash → write → emit) with `LoggingEventBus`; the (app)/(auth) route-group split; the localStorage session contract in `lib/auth.ts` with `useSyncExternalStore` subscriptions; problem-code-branched feedback banners; generated-client-only API types. Known-bad state avoided: auth-time reads on the tenant-scoped connection (silent 401/replay loss under the mandated deployment role).
- **2026-09-08 — Review loop 2 (intent_gap resolution).** Round-2 review surfaced three scope questions the captured intent did not settle. **Human resolutions (2026-09-08):** (1) *auth gating is in scope* — a small Next.js middleware redirects signed-out visitors of `(app)` surfaces to `/login` and redirects signed-in users away from `/login`/`/register`; the Settings form's in-page signed-out prompt stays as the fallback. (2) *Mobile warehouse switcher is in scope* — the same switcher affordance renders in the mobile header menu. (3) *Sign-in rate limiting is deferred, tracked* — consistent with the minimal-sign-in decision; recorded in `deferred-work.md`. Handling: safety commit of the loop-1 rework, then apply resolutions + the 13 loop-2 patch groups on top. **KEEP (must survive):** everything in the loop-1 KEEP list, plus the AUTH_DATABASE pattern, the pure `readSession()` snapshot contract, per-tenant active-warehouse keys, and the cursor-chain switcher. Known-bad states avoided: shipping a session lifecycle with no way in or out of the app shell; a mobile viewport that cannot pick a warehouse.
- **2026-09-08 — Review loop 3 (patch round, no loopback).** Round-3 review returned no intent_gap and no bad_spec — all 27 rows routed as verified patches or rejections — so the loop count stays 2 and no human resolution was needed. Patches applied on top of the loop-2 state (backend-first): the silent-expiry pair (expiry watchdog timer + 401 response interceptor), publish-after-commit guards, payload redaction in the event log, the idempotency key index, and the test gaps (proxy gate, cursor walk, header interceptor). Rejections recorded in the triage log with refutations. Known-bad state avoided: a UI that renders signed-in forever against a dead token; a 500 that converts committed registration work into a phantom failure.

## Review Triage Log

*Review loop 1 — 3 layers (blind-hunter 16, edge-case-hunter 19, verification-gap 7); duplicates across layers filed as separate rows, grouped at routing.*

*Review loop 2 — 3 layers (blind-hunter 18, edge-case-hunter 11, verification-gap 5 = 34 findings) over the rework diff; triaged below.*

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

*Review loop 2 rows:*
- Registration idempotency still not concurrently safe across tenants (same key, concurrent different-email submits mint two tenants) — **carried · rejected (low)** — same location and claim as the round-1 rejected row; the pre-transaction lookup and unguarded idempotency INSERT are unchanged by the rework. No corruption: both registrations are individually valid, the global email unique arbitrates same-email, and a foreign-row replay 422s on hash mismatch (no cross-tenant leak). The fix still adds advisory-lock machinery for a microsecond race.
- Concurrent registration replay lookup can return an arbitrary tenant's row — **carried · rejected (low)** — same claim, different reviewer: the returned row's payload hash is compared before use, so an arbitrary winner can only produce a correct replay or a 422; nothing leaks.
- `WarehouseList` (Settings) renders the previous tenant's warehouses after an identity switch — **low** — verified: fetch effect deps are `[sessioned, revision]` (`warehouse-create-form.tsx:174`) — presence, not identity — and the render guard (`:176`) checks only `items` non-null, unlike the switcher's `page.tenantId !== tenantId` filter.
- `WarehouseList` fetches only the first page (no cursor follow) while the switcher follows the chain — **low** — verified: single `fetchApiListWarehouses` call (`:164`), no cursor loop; the loop-1 pagination fix was adopted in one consumer only.
- `TenantSessionGuard` docstring claims "authority is re-evaluated at command-service entry" but `assertOwnTenant` lives in the controller only — **low** — verified: `assertOwnTenant` appears only at `tenancy.controller.ts:125,147`; the command services trust `command.tenantId`. The comment is wrong (or the check is misplaced); any future non-HTTP caller bypasses the check.
- No provisioning path for the two DB roles the design mandates (non-superuser app role, BYPASSRLS auth role) — **medium** — verified: both READMEs and `.env.example` mandate the roles; no migration, script, or documented SQL creates either. A deployment following the docs alone cannot satisfy the contract.
- `DATABASE_AUTH_URL` falls back to `DATABASE_URL` silently — **low** — verified: `createLazyAuthDatabase` falls back without a boot-time signal; an operator forgetting the var gets fail-closed 401s indistinguishable from wrong passwords.
- No auth gate on any `(app)` surface — **medium** — verified: `(app)/layout.tsx` renders `AppShell` unconditionally; no `middleware.ts`; nothing in `(app)/**` routes on session state. Twelve placeholder surfaces render full chrome signed-out; `/login` does not redirect a signed-in user away.
- Warehouse switcher is desktop-only (`hidden lg:block`); mobile header has sign-out but no switcher — **medium** — verified: switcher visibility class in `sidebar.tsx`; `app-shell.tsx` mobile menu gained only the sign-out button. Mobile users cannot see or pick the active warehouse.
- No rate limiting or lockout on `POST /tenants/sign-in` — **medium** — verified: no throttle in the sign-in path or controller; the dummy-scrypt timing work shows enumeration was considered, repeated attempts were not; absent from spec and `deferred-work.md`.
- `idempotency_keys` retention deferral is untracked in `deferred-work.md` — **low** — verified: Design Notes say "retention bounded later (AD-5)" but no deferred-work entry records an owner or trigger.
- JWT verification reject paths have no direct tests (tampered signature, wrong secret, `alg: none`, expired) — **medium** — pre-verified (verification-gap): `test/` never imports `signTenantSession`/`verifyTenantSession`; the only bearer-negative e2e is a *missing* header. A signature/exp regression stays green and a forged `tenant_id` would pass the guard.
- Switcher 20-hop cursor cap silently truncates (>1000 warehouses unpickable) — **rejected (low)** — 20 pages × 50 = 1,000 warehouses per tenant; far outside everyday use at this stage, and surfacing truncation adds UI state for data no tenant has.
- Frozen I/O & Edge-Case Matrix never extended with sign-in rows — **rejected** — the fix edits this build's spec (frozen matrix); triage does not amend the spec.
- Per-tenant active-warehouse localStorage keys accumulate forever — **rejected (low)** — convenience data by design: a returning tenant keeping their pick is correct; clearing them on sign-out needs cross-tenant key enumeration for no observed harm.
- Spec hygiene: "Implementation Notes — (empty)" placeholder; Verification cites a `test:e2e` script name matching no repo script — **rejected** — spec edits.
- Diff artifact concatenates three repos with unprefixed paths — **rejected** — a property of the review staging file, not of the change; nothing downstream consumes it.
- `hashCommandPayload` "canonical JSON" comment overstates the guarantee (key-order dependent) — **low** — verified: `JSON.stringify` with no key sort; stable only because call sites construct objects with fixed key order.
- Sign-in 500s when a user row exists without its tenant row — **false** — unreachable: no code path deletes or orphans tenants (registration creates both in one transaction); same reasoning as the round-1 no-FK rejection.
- Cursor payload `id` is not format-validated; a crafted cursor 500s — **low** — verified: `decodeCursor` checks `typeof` only; `tenancy.service.ts:89` casts `before.id::uuid`, so a base64-valid cursor with a garbage id raises a PG cast error (500) instead of `400 invalid-cursor`.
- RLS WITH CHECK probe assertion may not be awaited — **low** — verified: `expect(foreignInsert).rejects.toThrow(...)` at `tenancy.spec.ts:464` lacks `await`; the matcher can resolve after the test completes, leaving the write-side backstop unenforced.
- `afterAll` never closes the `AUTH_DATABASE` pool — **low** — verified: teardown ends only the `DATABASE` client; the suite's "worker process has failed to exit gracefully" warning corroborates the open handle.
- Sign-in DTO does not trim email (padded paste → 400, command normalization unreachable) — **low** — verified: bare `@IsEmail()` with no `@Transform`; leading/trailing whitespace fails validation before the command's `trim().toLowerCase()` can run.
- Warehouse codes/names stored unnormalized (whitespace variants distinct; whitespace-only name passes) — **low** — verified: `code`/`name` pass through verbatim into the `(tenant_id, code)` unique index; `" BLR-01"` and `"BLR-01"` coexist and the 409 names a code the user believes they fixed.
- Concurrent same-key same-payload warehouse loser 409s `duplicate-warehouse-code` (not `conflict`) — **rejected (low)** — microsecond race; the loser's retry replays the original 201; the `conflict` branch stays reachable for same-key/different-code, so no client contract is broken.
- Switcher bounded follow claim (pages beyond 20 never fetched) — **rejected (low)** — duplicate of the 20-hop cap row above.
- Cause-chain walk capped at depth 5 → deep 23505 falls through to 500 — **rejected (low)** — postgres.js/Drizzle error nesting never approaches 5 wrappers; mirrors the round-1 exotic-timestamp rejection.
- Bearer-token interceptor header never asserted by any test — **medium** — pre-verified (verification-gap): deleting the interceptor body keeps lint/typecheck/tests/build green because the only exercised flow needs no auth header; every signed-in warehouse call would 401 in production with CI green.
- Auth-time reads never exercised under a role where RLS actually binds — **medium** — pre-verified (verification-gap): `DATABASE_AUTH_URL` appears nowhere in `test/`/CI; both connections are the same superuser in every verification environment, so the rework's core failure mode (401s under the deployment role) cannot fail the suite.
- No test rejects a present-but-invalid bearer token — **medium** — pre-verified (verification-gap): no expired, wrong-secret, or tampered-payload token is ever sent; all e2e tests use legitimately signed unexpired tokens.
- `client.test.ts` `afterEach` deletes the global `fetch` permanently — **low** — verified (verification-gap): under `bun test`'s single-process runner the stub removal leaks to later files; harmless today, an order-dependent trap next.
- OpenAPI documents a weaker contract than validation enforces — **low** — verified: `ownerEmail` has no `format: email`, `limit` no minimum/maximum, `tenantId` no `format: uuid`; 400s for `limit=0` or non-UUID paths are undocumented on the list endpoint.


*Review loop 3 rows (patch round — no intent_gap, no bad_spec; loop count stays 2):*
- `provision-roles.sql` defines psql `\set` variables the CREATE ROLE statements never use — **low** — verified: the DO block hardcodes `change-me-*`; an operator edits dead lines.
- Registration replay lookup `WHERE key = $1` sequential-scans — only index is `(tenant_id, key)` — **medium** — verified: `drizzle/0001` has no key-only index; the auth path scans a table that grows on every mutating request.
- `hashPassword` (full scrypt round) runs before the replay lookup — replays pay ~100 ms to discard it — **low** — verified: hashing precedes the lookup in `registration.command.ts`.
- OpenAPI `Idempotency-Key` header has no minLength/pattern — **low** — verified: bare `type: string` in `IDEMPOTENCY_HEADER`.
- OpenAPI response id examples are ULID-shaped and response ids lack `format: uuid` — **low** — verified: `0198abcdef0102030405060708090ab` examples contradict the uuid-v7 ids the path params correctly declare.
- Sign-in 500s when a user row exists without its tenant row — **carried · false** — same claim/location as the round-2 rejected row (unreachable; no deletion path).
- `useTenantWarehouses` swallows fetch errors with no surfaced failure — **rejected (low)** — documented behavior (comment in the hook); the error-surfacing surfaces (forms) report API errors; adding error state + retry to quiet chrome is not a direct correction.
- `proxy.ts`, `useTenantWarehouses`, and the extracted switcher have zero tests — **medium** — pre-verified (verification-gap): no test file imports any of them; the proxy's redirect logic, the hook's cursor chain, and the identity filter can all regress with the suite green.
- Switcher listbox has no Escape/outside-click dismissal; picking from the mobile menu leaves the nav open — **low** — verified: no Esc handler; no `onPicked` callback to the shell menu; the repo's own ⌘K convention (Esc closes) is not applied.
- `WarehouseList` shows no empty-state while the switcher does — **rejected (low)** — the empty state's audience is already on the page that hosts the create form.
- Hint cookie lacks `Secure` — **low** — verified: `SameSite=Lax` only; free hardening on HTTPS deployments.
- `eventBus.publish` awaited unguarded after commit — a throwing bus 500s already-committed work — **medium** — verified: both command services await the publish bare; the seam contract permits throwing implementations; a 500 after commit turns the original 201 into a replay on retry.
- `LoggingEventBus` logs full event payloads — owner emails land in logs — **low** — verified: `event-bus.ts:17` stringifies `event.payload` into the log line.
- e2e never exercises malformed `Idempotency-Key` on warehouse endpoints nor `limit` boundary validation — **low** — verified: those guards are tested only on `POST /tenants` (if at all); the list/create routes' enforcement is unpinned.
- `.env.example` ships a placeholder `JWT_SECRET` with no replace-before-running warning — **low** — verified: `tenantSessionSecret()` validates length only, so the example value passes unchanged.
- Submit silently no-ops when the session expires between render and submit — **medium** — verified: `onSubmit` does `if (session === null) return;` with no feedback; the round-2 purity fix removed the dispatch that used to flip the form.
- No notification fires at token expiry — UI keeps rendering signed-in until some other event — **medium** — verified: no timer in `auth.ts`; grouped with the row above (one root cause: expiry is silent).
- No response interceptor on 401 — a dead token is retried forever and the UI never routes back to `/login` — **medium** — verified: only a request interceptor exists in `client.ts`.
- Registration while a hint cookie is present bounces `/login` back to `/` — **false** — the proxy gate already redirects hint-bearing users away from `/register`, so the flow requires a state the gate prevents.
- Hint cookie written even when `localStorage.setItem` threw (private mode) — proxy admits a session-less user — **low** — verified: `writeSessionHint` runs unconditionally after the try/catch.
- Hint cookie cleared by the browser but localStorage session still valid — proxy forces re-login despite a live token — **low** — verified: nothing re-asserts the cookie after browser-side clears.
- Deep-link destination lost on the auth redirect (no `next` param) — **rejected (low)** — polish; param plumbing through sign-in is more than a direct correction for a placeholder-surface product.
- Unlisted public files (robots.txt, manifest) 302 to `/login` — **rejected (low)** — no such files exist in the repo; speculative.
- Same-tenant re-login never refetches the warehouse list — **false** — re-login transitions `tenantId` through null (effect re-runs); a direct same-tenant overwrite leaves identical data.
- `registration.command.ts` `replayed` flag is always false — dead vestige — **low** — verified: replays return before the transaction; the guard is always true.
- Redundant `Number(query.limit)` after `@Type(() => Number)` — **low** — verified: cosmetic duplicate conversion.
- `client.test.ts` leaks deleted globals via `afterEach` — **carried · fixed** — round-2 row; the loop-2 patch already moved to fresh per-test globals.

## Design Notes

- RLS mechanism (spine leaves open): per-request DB transaction runs `SET LOCAL app.tenant_id = '<uuid>'`; policies are `USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid)` (fail-closed; PG 18 returns `''` not NULL when unset). App layer stays authoritative; RLS is the backstop. Verified by the `wms_rls_probe` non-superuser e2e role (the docker-compose `wms` user is a superuser and bypasses RLS).
- **Auth-time reads (review loop 1 decision):** sign-in and the registration replay lookup run *before* any tenant context exists, so they read through a dedicated `AUTH_DATABASE` connection (`DATABASE_AUTH_URL`, falling back to `DATABASE_URL`) whose role carries BYPASSRLS (or superuser). Every tenant-scoped path stays on the fail-closed scoped connection; the auth connection is never used for writes.
- Idempotency: unique `(tenant_id, key)` + payload-hash comparison; hash mismatch → 422 `idempotency-key-reuse`; the registration fingerprint covers `name` + normalized `ownerEmail` — never password material (the raw password is an offline oracle; the salted scrypt hash is not replay-deterministic); retention bounded later (AD-5).
- Sign-in (if Open Question (a)): `POST /tenants/sign-in` → HS256 JWT, 15-min expiry, `tenant_id`+`sub` claims; no refresh in this story. Sign-out is a client-side `clearSession()` affordance (sidebar, beside the theme toggle).

## Verification

**Commands:**
- `bun run db:migrate` + `bun run db:verify` (wms-be) -- expected: migration applies cleanly; round-trip green
- `bun run test` (wms-be) -- expected: all pass incl. RLS + idempotency replay e2e
- `bun run openapi:export` then `bun run api:generate` (wms-be → wms-fe) -- expected: regenerated client with new endpoints/types
- `bun run lint && bun run test && bun run typecheck && bun run build` (wms-fe) -- expected: all green
- `bun run test:e2e`-style supertest run covers both happy and error rows of the I/O matrix