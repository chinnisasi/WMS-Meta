---
title: 'Story 1.5 — Users, roles, and permission gating'
type: 'feature'
created: '2026-09-08'
status: 'done'
route: 'dispatch'
review_loop_iteration: 1
baseline_commit: 'meta 6d1e104f15909ba49231aeb838e56c3098e86d60 · wms-be b73075a5951d02ecef01b3469607fbfa74c46f88 · wms-fe 1288907976a8701cbeb90d1faa21e7722b48baa3'
context: []
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** The tenant has exactly one user (the owner) with no roles, no permissions, and no way to invite a team — the last unfinished step of the epic-1 onboarding funnel. Every capability built in stories 1.2–1.4 is open to any signed-in session, and the setup checklist `users` step is hardcoded pending.

**Approach:** Introduce the four roles (Owner, Ops Manager, Operator, Accountant) as a role on each user, a capability→role permission map enforced at command-service entry (authority is a per-command DB read of the current role — never a JWT claim), team invitation with a pending/accepted lifecycle, an append-only audit trail for user/role actions, a Users card on /settings (invite, list, change role) plus an accept-invite page, and surface gating in the FE (hide surfaces, never "blocked" screens). Checklist `users` step checks off when a non-owner user exists.

## Boundaries & Constraints

**Always:**
- Authority is re-evaluated at command-service entry against the role read from the DB in the same tenant transaction (satisfies "next action, not next login"). The JWT stays transport-only with no role claim; `TenantSessionGuard` remains transport-only.
- Denied mutations return RFC 9457 problem-details with machine-readable `code: 'role-denied'` naming the role and the capability; reads are never blocked mid-flight.
- Every role change and invitation writes an audit row (actor, action, target, timestamp, idempotency reference) in the same transaction as the mutation.
- The last Owner of a tenant cannot be demoted or have their role changed away from Owner; such attempts fail with `code: 'last-owner'`.
- All new tables carry `tenant_id`, get hand-written `ENABLE ROW LEVEL SECURITY` + `<table>_tenant_isolation` policy DDL in the new migration, and RLS is proven by a probe test.
- Invited users get credentials via a one-time invite link (hashed token, 7-day expiry) returned in the invite response; the invitee sets their own password on the accept-invite page. No email delivery.
- Permission matrix: Owner = all capabilities including `users.invite` / `users.role_change`; Ops Manager = all operational mutations (warehouses, zones, bins, catalog import, SKU edit) but no user management; Operator = read-only; Accountant = read-only.
- Mutating endpoints carry the ULID `Idempotency-Key` contract (AD-5).
- Emails are globally unique (one account per email) — inviting an email that already has an account fails with `code: 'email-exists'`.

**Never:**
- No email delivery — invite links/tokens are returned in the API response for the owner to share out-of-band.
- No password-reset, no session revocation, no refresh-token flow, no fine-grained per-resource ACLs — four coarse roles only.
- Do not gate the checklist read or any GET with roles (reads stay open to any tenant member).
- Do not let drizzle-kit generate RLS policies; do not touch `app_metadata`, the event-bus/outbox seam signatures, or the AUTH_DATABASE (BYPASSRLS) routing of registration/sign-in.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Owner invites new user | `POST …/users` {email, role}, email unseen | 201: user `status: 'invited'` + one-time invite token returned; audit row; `user.invited` event | Duplicate email (any tenant) → 409 `email-exists`; caller lacks `users.invite` → 403 `role-denied` |
| Invited user accepts | `POST /tenants/:tenantId/accept-invite` {token, password} | 200: status → `active`, password set; `user.accepted` event | Unknown/used/expired token → 400 `invite-invalid` |
| Sign-in before accepting | sign-in as `invited` user | 403 `invite-pending` | N/A |
| Role change | `PATCH …/users/:userId` {role} by Owner | 200; audit row; effective on that user's next command (DB-read authority) | Target is last Owner → 409 `last-owner`; caller lacks `users.role_change` → 403 `role-denied` |
| Role-denied mutation | Operator calls catalog import (or any capability their role lacks) | 403 `role-denied` naming role + capability; no partial writes | N/A |
| Checklist users step | ≥1 user with role ≠ owner exists (invited or active) | `users` step `done: true` with real detail; else pending | N/A |
| Cross-tenant RLS probe | non-BYPASSRLS role queries new tables with foreign `app.tenant_id` | 0 rows | N/A |

</frozen-after-approval>

## Code Map

**Backend (wms-be) — new users/permissions live in the tenancy module (it owns `users`):**
- `src/shared/db/schema.ts:57-67` -- `users` table: add pgEnum `user_role` ('owner'|'ops_manager'|'operator'|'accountant'), `role` (default 'operator'), `status` ('invited'|'active'), `inviteTokenHash`, `inviteExpiresAt`. New `audit_events` table (id, tenantId, actorUserId, action, targetType, targetId, reference, occurredAt). Keep L53 email-uniqueness comment.
- `drizzle/0005_*.sql` (next migration; drizzle-kit for DDL, then hand-append RLS DDL per `0001_greedy_scarecrow.sql:47-69` pattern) -- new columns/tables + `ENABLE ROW LEVEL SECURITY` + policies for `audit_events` (and `users` policy already exists — verify it still matches).
- `src/modules/tenancy/permissions.ts` (NEW) -- capability constants + `ROLE_CAPABILITIES` map + `assertPermission(session-loaded role, capability)`; used at command-service entry, not in the guard.
- `src/modules/tenancy/users.controller.ts` (NEW) + `users.command.ts` (NEW) -- `POST /tenants/:tenantId/users` (invite), `GET …/users` (cursor list), `PATCH …/users/:userId` (role), `POST /tenants/:tenantId/accept-invite` (unauthenticated, token+password, AUTH_DATABASE path like `sign-in.command.ts:21-24`), `GET /tenants/:tenantId/me`. Publish `user.invited` / `user.role_changed` / `user.accepted` via EVENT_BUS after commit (pattern: `warehouse.command.ts:139`).
- `src/modules/tenancy/tenancy.service.ts:266-330` -- replace hardcoded users step (L321-328) with a real count of non-owner users; keep `SetupChecklistStepKey` shape.
- `src/modules/tenancy/sign-in.command.ts` -- extend response with `user {id, email, role, status}`; reject `invited` users with 403 `invite-pending`.
- Gating call sites: `registration`/`warehouse`/`zone`/`bin` commands and `catalog` module commands (`sku.command.ts`, `import.command.ts`) get `assertPermission` at entry via a facade-provided role lookup (catalog must not read tenancy tables — add `getMemberRole(tenantId, userId)` to the existing TenancyService facade pattern, `tenancy.service.ts:75-120`).
- `src/modules/tenancy/idempotency-guard.ts:11-56`, `src/shared/db/tenant-scope.ts:21-39` -- reuse as-is.
- `test/tenancy.spec.ts:90-124` (helpers) + NEW `test/users.spec.ts` -- copy register/sign-in helpers; add role helper; e2e for every matrix row + RLS probe (`tenancy.spec.ts:661+` pattern).

**Frontend (wms-fe):**
- `src/lib/api/generated/**` -- regenerated only (`bun run api:generate`); never hand-edit.
- `src/lib/api/client.ts:113-350` -- add `fetchApiInviteUser` / `fetchApiListUsers` / `fetchApiSetUserRole` / `fetchApiAcceptInvite` / `fetchApiMe` wrappers with `ApiProblem` conversion.
- `src/lib/users.ts` (NEW: `USERS_CHANGED_EVENT`) + `src/lib/use-users.ts` (NEW) -- copy `use-catalog.ts` external-store pattern.
- `src/components/settings/users-card.tsx` (NEW) -- invite form (email + role select, ULID key, FeedbackBanner outcome), user `DataTable` (email, role, status pill), inline role-change per row (sku-table.tsx:82-93 pattern); show one-time invite link after invite.
- `src/app/accept-invite/page.tsx` (NEW) -- token + password form → sign-in redirect.
- `src/lib/auth.ts:26-31` + `auth-forms.tsx:115-120` -- `StoredSession` gains `user {id, email, role}`; bootstrap `/me` refetch on load so role changes surface without re-login.
- `src/components/shell/sidebar.tsx:27-53` + `src/lib/navigation.ts:14-27` + settings cards (`warehouse-create-form.tsx`, `import-catalog.tsx`, `sku-table.tsx`) -- hide surfaces whose capabilities the session role lacks (read-only roles see tables, not forms).
- `src/components/settings/setup-checklist-card.tsx` -- no change needed (steps are backend-computed); verify users step renders done.
- Colocated `*.test.ts` bun tests for the new lib modules + client wrappers.

## Tasks & Acceptance

**Execution:**
- [x] `wms-be/src/shared/db/schema.ts` -- add role/status/invite columns + `audit_events` table + pgEnum -- schema source of truth
- [x] `wms-be/drizzle/0005_*.sql` -- generate migration, hand-append RLS DDL -- irreversible schema step
- [x] `wms-be/src/modules/tenancy/permissions.ts` (NEW) -- capability map + assertPermission -- single authorization primitive
- [x] `wms-be/src/modules/tenancy/users.command.ts` + `users.controller.ts` (NEW) -- invite/list/role/accept-invite/me + audit writes + events -- the users surface
- [x] `wms-be/src/modules/tenancy/tenancy.service.ts` -- real users checklist step + `getMemberRole` facade method -- checklist + cross-module role lookup
- [x] `wms-be/src/modules/tenancy/sign-in.command.ts` -- user payload + invite-pending rejection -- FE session needs role
- [x] `wms-be` catalog + tenancy command call sites -- assertPermission at entry -- gating the 1.2–1.4 surfaces
- [x] `wms-be/test/users.spec.ts` (NEW) + helper updates -- e2e every matrix row + RLS probe + checklist
- [x] `wms-fe` -- regen client, client.ts wrappers, `users.ts`/`use-users.ts`, `users-card.tsx`, `/accept-invite`, session user + /me bootstrap, surface gating, bun tests -- the consuming side (lands after backend)
- [x] `docs/repos/wms-be/README.md` + `docs/repos/wms-fe/README.md` (meta) -- update interface contracts (users/roles/me/accept-invite endpoints, session user shape)

**Acceptance Criteria:**
- Given an Owner session, when they invite a user and share the link, then the invitee accepts with their own password and appears `active` in the users table, and the checklist `users` step reads done.
- Given an Operator session, when any gated mutation is attempted, then it fails 403 `role-denied` naming the role and capability, while reads succeed.
- Given a role changed for a signed-in user, when that user's next command arrives, then the new role applies without re-login.
- Given only one Owner exists, when their role is changed, then 409 `last-owner` and no mutation persists.
- Given every role change and invite, then an audit row with actor/action/target/time/reference exists in the same transaction.

## Implementation Notes

## Spec Change Log

## Review Triage Log

- **accept-invite tenantId unvalidated** (blind/edge) — low — Verified: the controller takes `@Param('tenantId')` but the command input is `{token,password}` only, so any tenant URL accepts any token. No cross-tenant harm (acceptance is scoped to the token's own tenant), but the link contract is unenforced. → patch
- **auth-time replay lookup not tenant-scoped** (blind/edge) — reject(low) — The lookup is `eq(key)` on the AUTH connection as claimed, but the FE generates a fresh ULID per submit, so a cross-tenant key collision is practically unreachable; the fix adds branching for a state no shipped client can produce.
- **raw invite token persisted in the idempotency snapshot; comment says "never stored"** (blind) — low — Verified at `users.command.ts:48` vs the snapshot insert: the comment is false; persisting the raw token is inherent to replay (the same link must be re-served). → patch (correct the comment)
- **accept-invite writes no audit_events row** (blind/edge) — low — Verified: only `publishSafely('user.accepted')`. The frozen block mandates audits for invites/role changes only, but the event type promises the action and the fix is one call in the same tx. → patch
- **successful invite doesn't refresh the users table** (blind) — low — Verified in the diff: `onInvited` only sets the link display; the invited user stays invisible until an unrelated refetch. → patch
- **non-reactive `readSession()` gating** (blind) — low (partial) — UsersCard/ImportCatalog/WarehouseCreate gates re-render via their outer `useSyncExternalStore`; only `SkuTableCardSessioned`'s `canEditSku` is stale after a `/me` role rewrite. → patch (sku-table only)
- **README names the invite expiry field `expiresAt`** (blind/vergap) — medium — Verified at `docs/repos/wms-be/README.md:27,52`: the actual field is `inviteExpiresAt`; the breakage-catch contract names a nonexistent field twice. → patch
- **README overstates re-invite semantics** (blind/vergap) — low — Verified: a fresh key on a still-invited email hits the email pre-check → 409 `email-exists` (the `dup2` test asserts it); the doc's "re-inviting re-serves the same token" holds only for same-key replay. → patch
- **README email-exists qualifier "active user" is wrong** (vergap) — low — Verified: the pre-check has no status filter; an *invited* email in any tenant also 409s. → patch (grouped above)
- **`users.status` free text vs pgEnum** (blind/edge) — false — No program path writes a value outside `USER_STATUSES`; DTO validation and all writers use the const. Only manual DB edits could reach the claimed outcome.
- **drizzle snapshot contradicts migration RLS** (blind) — false — `0001_snapshot.json` shows the same `isRLSEnabled: false` for tables whose RLS is hand-written in SQL; drizzle snapshots never capture hand-written DDL. Established pattern, not a contradiction.
- **checklist users step wording/predicate mislead** (blind) — false — The predicate (`ne(users.role,'owner')`) matches the frozen intent verbatim ("checks off when a non-owner user exists"), and "N team member(s) invited" is past-tense-accurate prose.
- **authorization plumbing copy-pasted; UUID_RE drift** (blind) — reject(low) — Per-command duplication matches the surrounding code idiom (CLAUDE.md: match the local pattern); the `/i` flag drift is harmless (backend-generated cursors are canonical-case).
- **assertOwnTenant re-implemented + double imports** (blind) — reject(low) — Developer-only cosmetic duplication; no caller will diverge.
- **two diverged rejectionReason mappers** (blind) — false — Per-component `rejectionReason` is the established idiom (6 pre-existing implementations in sku-table, import-catalog, warehouse-create-form, zone-bin-setup, auth-forms); users-card follows it.
- **wms_rls_probe DDL not advisory-locked** (blind) — medium — Verified at `test/users.spec.ts:630-639`: bare `admin.unsafe` CREATE ROLE + GRANT while the same file's `wms_auth_probe` block (L49-50) is wrapped in `pg_advisory_xact_lock(742105)` — the exact tuple-concurrently-updated race the diff fixes elsewhere. → patch
- **FE capability mirror has no cross-repo drift guard** (blind) — defer — Real risk; the proportionate fix (generating the mirror from the backend) is new cross-repo build machinery, not a direct correction.
- **client.test.ts invite stub uses `expiresAt`** (blind) — low — Verified in the diff; the stub mismatches the real contract field. → patch
- **coverage gaps: FE component tests, expired-token e2e, dead tenant param** (blind) — reject(low) — The expired-token path shares the exact `invite-invalid` branch already pinned by unknown/used-token tests; FE component tests would need a new harness; the dead `tenant` destructure is cosmetic.
- **concurrent double-accept of the same token** (edge) — medium — Verified: the accept UPDATE filters only on `users.id`, so a second concurrent transaction re-succeeds after the first commits; the one-time boundary is not atomic. → patch
- **accept fingerprint excludes password** (edge) — false — Same discipline as registration (commented as such); a same-key replay re-serving the first response is the established AD-5 idempotency semantics, not a defect.
- **concurrent last-owner bypass** (edge) — medium — Verified: the guard is a count-then-update; two concurrent demotions of a two-owner tenant can leave zero owners, breaking a frozen boundary. → patch
- **role change on concurrently-deleted target → 500** (edge) — false — No code path deletes users anywhere in the system; the state is unreachable.
- **corrupted status bypasses invite-pending** (edge) — false — Status is only ever written as `'invited'`/`'active'` by the program; a corrupted value is unreachable, and the DUMMY_HASH sentinel still fails the password closed.
- **invite/setUserRole omit @ApiHeaders(Idempotency-Key)** (edge) — medium — Verified: `users.controller.ts` decorates only accept-invite (L164); every other mutating route (catalog import/edit, tenancy mutations) documents the header, and the generated FE types lack it for these two. → patch (+ spec re-export + client regen)
- **bin.block gating never exercised by a non-owner** (vergap, pre-verified) — medium — Filed evidence complete: owner-only tests cannot observe the gate; deletion of the assert goes undetected. → patch
- **generateGrid bin.create denial untested** (vergap, pre-verified) — medium — Pre-verified; the operator could mass-generate bins with the assert removed and CI stays green. → patch
- **sku.edit denial untested for read-only roles** (vergap, pre-verified) — medium — Pre-verified; only an ops_manager 200 exists. → patch (one group with the two above)
- **migration 0005 owner backfill never verified against pre-0005 rows** (vergap) — defer — Per filed disposition: no migration-state test harness exists (fresh-DB migrate is the established CI pattern); risk window is a single deploy.
- **duplicate WarehouseList for read-only roles** (vergap) — low — Verified: the form's denied branch renders `<WarehouseList />` while the Settings page renders it again below. → patch

## Design Notes

- Authorization example (command entry, inside `withTenantTransaction`):
  ```ts
  const role = await tx.getMemberRole(tenantId, session.userId);
  assertPermission(role, 'catalog.import'); // throws role-denied problem-details
  ```
- Roles are a row attribute read per command — no role epoch counter needed; the DB read *is* the epoch.
- Audit `reference` column stores the idempotency key so retried commands dedupe visibly.

## Verification

**Commands:**
- `bun run db:migrate && bun run test` (wms-be) -- expected: all suites pass incl. new users.spec.ts + RLS probe
- `bun run lint && bun run typecheck` (both repos) -- expected: clean
- `bun run test && bun run build` (wms-fe) -- expected: pass, build green