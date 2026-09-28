---
title: 'Story 21-2 — client isolation RLS (app.client_id, policies, DB-level probe)'
type: 'feature'
created: '2026-09-28'
status: 'ready-for-dev'
route: 'dispatch'
review_loop_iteration: 0
baseline_commit: '30aba7a (main, post-21-1 merge #55)'
context:
  - '_bmad-output/implementation-artifacts/epic-21-context.md'
  - '_bmad-output/specs/spec-3pl/architecture.md'
  - '_bmad-output/specs/spec-3pl/schema.md'
  - '_bmad-output/specs/spec-3pl/SPEC.md'
  - 'docs/design/SYSTEM-DESIGN.md'
  - 'docs/design/IMPLEMENTATION-GUIDE.md'
  - 'docs/design/modules/inventory.md'
  - 'docs/design/modules/tenancy.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** The client dimension landed (21-1) but nothing enforces it at the database: a portal session for client A could still query client B's SKUs, orders, POs and ledger events. Tenant-level RLS does not provide client isolation (AD-3 scopes tenant + warehouse only), and the `clients_tenant_isolation` policy 0040 added ships with no DB-level probe.

**Approach:** Land AD-24 — a second fail-closed RLS session variable `app.client_id` on the four stamped tables, the transaction-scoped stamping primitive beside `setTenantScope`, and the DB-level isolation probe in the `wms_rls_probe` shape. Operator sessions are unchanged: they leave `app.client_id` unset and see the whole tenant (cross-client waves untouched). A portal session sets it, and the database — not the application — makes other clients' rows unreachable.

## Boundaries & Constraints

**Always:**
- AD-24 predicate shape (ratified): extend each of the four stamped tables' `*_tenant_isolation` policy with a null-tolerant client clause — `USING (tenant arm AND (NULLIF(current_setting('app.client_id', true), '') IS NULL OR client_id = NULLIF(current_setting('app.client_id', true), '')::uuid))`, and the repo convention of an identical `WITH CHECK` arm. "Fail-closed" is the NULLIF idiom: missing/empty/expired setting → NULL → row invisible; set-but-wrong → binds.
- **DECISION (human, 2026-09-28): the `clients` table gets the client clause too** (Option A) — `NULLIF(current_setting('app.client_id', true), '') IS NULL OR id = NULLIF(...)::uuid` replaces the tenant-only predicate on `clients_tenant_isolation`; portal sessions see only their own client row, operator sessions see all. 0041 rewrites five policies, and the probe adds the clients arm. Token gate resolved: keep the full spec (overage accepted).
- Policy changes only in migration SQL (house rule); the migration is policy-only (`drizzle-kit` is blind to RLS) with the standard journal + snapshot pair.
- Probe proven at the database, not only via API (CAP-2): non-superuser role, zero foreign rows, foreign writes rejected.
- The scoping primitive stamps transaction-local (`set_config(..., true)`), mirroring `setTenantScope` — scope dies with the transaction.

**Never:**
- No portal session issuance/auth/CRUD (21-7 consumes this); no client admin or status transitions (nothing makes `suspended` reachable in this story either); no billing/ASN/reporting (21-3…21-8); no FE/mobile change; no command-layer branching on 3PL mode.
- No indexes on `client_id` columns — 21-2 adds no client-filtered app queries (the probe's are tiny); the deferral moves to 21-4 (metering aggregates) where the first real client-filtered queries land.
- No fifth-persona decision on `users.client_id` (new `user_role` value vs orthogonal) — the column stays inert; that decision belongs to 21-7.
- No cross-client wave test — waves are Phase 1 territory; that pin belongs to the wave epic's spec.

</frozen-after-approval>

## Code Map

- `drizzle/0040_client_dimension.sql:102-107` — the `clients_tenant_isolation` policy to leave as-is (tenant-only, per its header's RLS-SCOPE note) or extend per the open question; lines 14-21 already name 21-2 as the owner of the clauses.
- The four policies to extend (all identical tenant-only predicate): `skus_tenant_isolation` (drizzle/0004:75), `ledger_events_tenant_isolation` (0006:63), `purchase_orders_tenant_isolation` (0011:61), `orders_tenant_isolation` (0017:40). 44 policies total, all `*_tenant_isolation`, all `NULLIF(current_setting('app.tenant_id', true), '')::uuid`.
- `src/shared/db/tenant-scope.ts` (56 lines) — `setTenantScope` (lines 27-29) and `withTenantTransaction` (43-56) are the single choke point; `TenantDb`/`TenantTx` types at 7-12. The optional-clientId stamping primitive extends this file; ~30 call sites use `withTenantTransaction` and must be untouched.
- Probe harness to copy: `test/users.spec.ts:660-720` (role creation + advisory-lock serialization, key 742105), `test/orders.spec.ts:1007-1034` (session-scoped `set_config(..., false)` variant + 42501 write arm), `test/ledger.spec.ts:601-659` (multi-table loop). `test/support/global-setup.js:54-67` creates `wms_rls_probe` (nosuperuser) cluster-globally and grants it DML on all public tables — no new role needed.
- Probe fixtures: 21-1's patch already supplies `client_id` subselects in catalog/ledger/orders probe INSERTs — 21-2's suite follows the same identity predicate (`code='self' AND system_owned`); a second non-self client is seeded by direct SQL (no CRUD API exists).
- Part-A harness pattern (if a migration test is wanted): `test/client-dimension.spec.ts:103` trims the journal to `idx <= 39`; 21-2's would trim to `idx <= 40` and remove its own 0041 file.
- Migration pair to extend: `drizzle/meta/_journal.json` (idx 40 is last) + `drizzle/meta/0040_snapshot.json` (0041's snapshot is a copy — policies are snapshot-invisible).
- `src/shared/db/db.ts:32-46` — `DATABASE_AUTH_URL` (BYPASSRLS) paths are out of scope; dev runs as superuser `wms` and bypasses RLS, which is why the probe role is the only DB-level proof.

## Tasks & Acceptance

**Execution:**
- [ ] `drizzle/0041_client_isolation_rls.sql` (+ journal idx 41 + snapshot copy, git-added) -- policy-only migration: recreate the four stamped tables' `*_tenant_isolation` policies with the extended predicate (DROP + CREATE, USING + identical WITH CHECK), plus the decided `clients_tenant_isolation` client clause; light fail-fast guard asserting the stamped tables carry `client_id`; header comment naming the probe file -- the story's core deliverable.
- [ ] `src/shared/db/tenant-scope.ts` -- optional `clientId` on `withTenantTransaction`'s options that stamps `app.client_id` transaction-local via the same `set_config` idiom -- the session-variable plumbing 21-7 will consume; operator call sites unchanged.
- [ ] `test/client-isolation.spec.ts` -- the DB-level probe (wms_rls_probe, advisory key 742105): portal-shaped session sees own rows and zero rows for the sibling client's skus/orders/POs/ledger events; WITH CHECK rejects foreign-client inserts with 42501 and allows own; operator-shaped session (client unset) still sees both clients; unscoped session sees zero rows; batches/stock rows ride their SKU join to the same isolation; the `clients`-table tenant policy probe (21-1 deferred-work carry-forward).
- [ ] `test/tenant-scope`-level coverage -- the primitive sets both variables when clientId is given and leaves `app.client_id` untouched when omitted (operator shape preserved).

**Acceptance Criteria:**
- Given a portal session scoped to client A, when it queries skus/orders/POs/ledger events, then client B's rows are zero at the database level and B's client_id is rejected on write with 42501.
- Given an operator session (client variable unset), when it queries the same tables, then both clients' rows are visible — isolation did not partition the tenant.
- Given a session with no tenant variable, then zero rows (existing fail-closed idiom intact).
- Given `bun run db:generate`, then "No schema changes" (policies are migration-only).

## Implementation Notes

- Implementation is gated on WMS-BE #55 (21-1) merging first — satisfied: #55 merged 2026-09-28, wms-be main at `30aba7a` with 0040 present; branch `feat/21-2-client-isolation-rls` from that main.
- `ensureSelfClientInTx`'s error arms (21-1 triage #5) gain no new consumers in this story — the probe seeds clients by direct SQL — so that note stays carried forward to 21-7.

## Spec Change Log

## Review Triage Log

## Design Notes

- **Why null-tolerant, not bare equality:** a bare `client_id = NULLIF(...)` clause would hide EVERY row from operator sessions (unset → NULL → no match), breaking cross-client waves and all existing operator flows. The ratified shape makes unset = the operator shape; the leak the design guards is a portal session with a wrong/empty client context binding to nothing rather than seeing everything. The residual exposure — a portal session that never sets the variable sees the whole tenant — is closed by 21-7, whose session layer is the only thing that creates portal sessions; this story lands the enforcement, the primitive and the proof.
- **Inherited tables need no clause and get none:** stock/batch/reservation rows carry no `client_id` (AD-24 placement is selective — "four more places for the value to disagree with itself"); their isolation rides on every consumer query joining through `skus`, which the policy now filters. The probe asserts the join-shaped query, which is how the app actually reads batches.
- **Why DROP + CREATE, not CREATE OR REPLACE:** ALTER POLICY with a new USING is equivalent here, but DROP+CREATE matches the repo's migration-idiom minimalism and reads identically to 0001/0003/0004's policy blocks.
- **Deferred decisions recorded here so they are not re-litigated:** client_id indexes → 21-4; fifth persona → 21-7; suspended-self semantics → the story that makes client CRUD real (21-1 triage #4 said "21-2 admin" but no CRUD exists in the ratified scope); cross-client wave test → the wave epic.

## Verification

*(filled at step-03/step-05)*