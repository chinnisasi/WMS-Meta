---
title: 'Client portal — a client user signs in and reads its own stock, orders, inbound and invoices, isolated by the database'
type: 'feature'
created: '2026-10-09'
status: 'done'
route: 'dispatch'
baseline_commit: '43c326211855cd0dd6d1ec88411612edd3f4b9e7'
review_loop_iteration: 0
context:
  - '_bmad-output/implementation-artifacts/epic-21-context.md'
  - '_bmad-output/specs/spec-3pl/SPEC.md'
  - '_bmad-output/specs/spec-3pl/architecture.md'
  - '_bmad-output/specs/spec-3pl/schema.md'
  - '_bmad-output/implementation-artifacts/spec-21-2-client-isolation-rls.md'
  - 'docs/design/SYSTEM-DESIGN.md'
  - 'docs/design/IMPLEMENTATION-GUIDE.md'
  - 'docs/design/API-SURFACE.md'
  - 'docs/design/modules/clients.md'
  - 'docs/design/modules/tenancy.md'
  - 'docs/design/modules/inventory.md'
  - 'docs/design/modules/outbound.md'
  - 'docs/design/modules/inbound.md'
  - 'docs/design/modules/billing.md'
  - 'docs/design/frontend/SYSTEM-DESIGN.md'
  - 'docs/design/frontend/IMPLEMENTATION-GUIDE.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** CAP-8: a client brand cannot see its own stock, orders, inbound or invoices without an operator relaying them.
- The isolation that would make a portal safe exists (21-2's `app.client_id` RLS clause), but nothing stamps it.
- Nothing can create a client user (the invite takes `{email, role}` only).
- Every read route is member-open. A client user holding an ordinary session today would read the whole tenant: stock by bin, other clients' orders, cost prices.

**Approach:** Three parts.
- **A portal identity.** An owner invites a client user for one client. Sign-in mints a session token carrying a `client_id` claim.
- **A central fence.** Every operator route refuses a portal token at the guard. A separate set of `/portal` routes accepts only portal tokens and runs every query in a transaction stamped with the client.
- **A portal on the web.** Its own shell with four read surfaces: stock, orders, inbound and invoices.

**Decisions (human, 2026-10-09):**
1. **A portal user is a fifth role, `client`,** paired with `users.client_id` by a database CHECK and holding no capabilities.
2. **The portal is read-only.** Portal ASN entry is deferred to **21-7b** (`deferred-work.md`).
3. **Invoices show the invoice and its lines only.** The line drill-down and the rate card stay operator-side.
4. **Keep the full spec:** all four surfaces in one story, with the size overage accepted.

## Boundaries & Constraints

**Always:**

- **Migration 0065** (one file; journal, snapshot and `schema.ts` updated).
  - **Statements:**
    - `ALTER TYPE user_role ADD VALUE 'client'`;
    - a pre-flight that `RAISE`s with the count of `users` rows where `client_id IS NOT NULL`;
    - the CHECK `users_client_role_pairing`: `(role::text = 'client') = (client_id IS NOT NULL)`.
  - **The migrator applies every pending migration in ONE transaction** (`drizzle-orm/pg-core/dialect.js:60-71`). Postgres refuses to use an enum value in the transaction that added it (55P04). So nothing in 0065 may resolve `'client'` as a `user_role`: the CHECK compares `role::text`.
  - **The post-assertion** is a `DO` block, one per probe, each catching `check_violation` (the 0064 precedent). It inserts a user with role `operator` and a `client_id`, and `RAISE`s if the insert was admitted. The `client`-without-`client_id` direction is proved in jest.
- **Roles.**
  - `ROLE_CAPABILITIES.client` is the empty set.
  - `USER_ROLES` (`tenancy.dto.ts:241`) gains `client`, so the invite DTO, `UserResponse` and OpenAPI carry it.
  - `SetUserRoleDto` takes a new `ASSIGNABLE_ROLES` tuple (the four), so assigning `client` is a 400 `validation-failed`. The command also refuses a target whose role is `client` (400).
  - `BadgeInResponse` (`devices.dto.ts:87`) derives from `USER_ROLES`.
  - The three device role checks become a floor-role allowlist (`owner | ops_manager | operator`): `enrollment.command.ts:751`, `receiving.command.ts:409`, `sync-report.command.ts:561`.
  - Badge-in refuses a client user with 403 `role-denied`. The refusal sits **after** `pinOk && bound` and **before** the device update, so a wrong PIN stays 401 `badge-invalid` and a refused badge-in binds nothing.
- **Invite.**
  - Gains `clientId?`. It is required when the role is `client` and refused otherwise (400).
  - Guard order: authority → **replay** → client checks.
    - The client must belong to the tenant, read by tenant **and** id (404).
    - It must not be system-owned (400).
    - It must be `active` (409 `client-not-active`, the existing type).
  - The hash adds `clientId` only when present.
  - `UserView` and `UserResponse` gain `clientId: string | null`. Replays of stored invite and role-change snapshots normalise `user.clientId ?? null`.
- **Immutability.**
  - Only the invite insert writes `users.client_id`.
  - An architecture test scans `src/**` for any `clientId` inside `.update(users)` or `.set(`, with the house "the test is meaningful" companion.
  - "Never set to `client`" is enforced by the DTO and the command refusal, proven by HTTP tests, not by a scan.
- **Token (amends AD-4 for the fence only; see Design Notes).**
  - `signTenantSession(tenantId, userId, secret, now, clientId?)` adds `client_id` only when given. An operator payload's keys stay exactly `sub, tenant_id, iat, exp`.
  - `verifyTenantSession` returns `clientId: string | null`. It returns null (invalid) when `client_id` is present but not a UUID string (`null` included), or when `device_id` is present.
  - The device verifier rejects any token carrying `client_id`.
  - Sign-in passes `users.client_id`. The response gains `user.clientId` and a top-level `client: {id, code, name} | null`.
  - A client user whose client is not `active` is refused **after** the password check with 403 `client-suspended`, so a wrong password stays 401.
- **Fence.**
  - `TenantSessionGuard` and `AnySessionGuard`'s web arm refuse a token with `clientId` with 403 `role-denied`, detail exactly `This is an operator surface.`
  - The per-route refusals (`portalRefused`, `asnPortalRefused`, the usage refusal) stay.
- **`PortalSessionGuard`** (clients module, `@Injectable`, DI-wired, exported).
  - Accepts only a token with `clientId`, else 403 `role-denied` `This is a client-portal surface.`
  - Per request, inside `withTenantTransaction(db, tenantId, …)`, it re-reads the user (`getMemberClientIdIn` plus status) and the client (`getClientStatusInTx`):
    - user missing, not `active`, or with another `client_id` → 401;
    - client not `active` → 403 `client-suspended`.
  - It sets `request.portalSession = {userId, tenantId, clientId}`, read with `@CurrentPortalSession()`.
  - It never uses `AUTH_DATABASE`.
- **Portal reads.**
  - Every route is `GET /tenants/{t}/portal/…` in `src/api/portal.controller.ts`, behind `PortalSessionGuard` and `assertOwnTenant`. Each read is a facade method of its owning module (AD-6) taking `(tenantId, clientId, query)`.
  - **Two layers, both required:**
    1. the facade opens `withTenantTransaction(db, t, fn, {clientId})`;
    2. the query carries an explicit `client_id = $client` on a stamped table, and reaches inherited rows (stock, lines, reservations) only through a join to a stamped parent.
  - Order keyset: `(created_at desc, id)` with `fullPrecisionInstant`. Limit 1–100. A cursor the codec rejects → 400 `invalid-cursor`. A `status` outside its tuple → 400. A malformed id → the operator route's convention. An unknown or foreign id → 404.
  - **No `warehouseId` filter:** rows carry `warehouseName`, and the portal has no warehouse list.
  - Quantities are base units (`fromMilli`).
  - Each route's response is an **exact key allowlist** (below). No user id or email, actor, bin, warehouse code, cost, vendor, integration id, hash, note, gap or warning appears at any depth.

| Route | Exact keys |
|---|---|
| `portal/me` | `{user {id, email, role, status, clientId}, client {id, code, name}}` |
| `portal/stock?cursor&limit` | rows `{skuId, skuCode, skuName, baseUom, warehouseId, warehouseName, onHand, allocated}`, one per (SKU, warehouse) where either figure > 0. `onHand` = Σ `stock_on_hand` over **every bin**, receiving and QC included. `allocated` = Σ `reservations` with `owner_type='order'` and state `held`/`committed`. Each side is pre-aggregated per (sku, warehouse) and then FULL-joined, so there is no fan-out. Keyset `(skuCode, warehouseId)` with its own codec |
| `portal/orders?status&cursor&limit` | `{id, status, source, externalRef` (← `external_event_id`), `warehouseName, destinationName` (← `destination_contact_name`), `destinationCity, destinationPincode, lineCount` (top-level lines: `parent_line_id IS NULL`), `createdAt}` |
| `portal/orders/{id}` | the row plus `lines[{skuCode, skuName, qty, components[{skuCode, skuName, qty}]}]`, with `skus` LEFT-joined |
| `portal/inbound/asns?status…`, `/{id}` | `{id, code` (← `asn_code`), `status, expectedAt, warehouseName, lineCount, announcedTotal, receivedTotal, createdAt}`; detail adds `lines[{skuCode, skuName, announcedQty, receivedQty}]` |
| `portal/inbound/purchase-orders?status…`, `/{id}` | `{id, code, status, warehouseName, lineCount, orderedTotal, receivedTotal, createdAt}`; detail adds `lines[{skuCode, skuName, orderedQty, receivedQty, expectedDate}]` |
| `portal/invoices?cursor&limit` | non-draft (RLS **and** `status <> 'draft'`), keyset `(created_at desc, id)`: `{id, invoiceNo, fyLabel, periodStart, periodEnd, status, issuedAt, replacesInvoiceId, placeOfSupply, supplyType, totals {subtotal, cgst, sgst, igst, tax, roundOff, payable}}` |
| `portal/invoices/{id}` | the row plus `party {supplier {name, gstin, stateCode, stateName, address}, recipient {name, legalName, gstin, stateCode, stateName, address}}` (no `warehouseCode`, no recipient `code`), and `lines[{segmentFrom, segmentTo, chargeCode, basis, uom, quantity, unitAmountPaise, amountPaise, sac, gstBps, cgstPaise, sgstPaise, igstPaise}]`. **Dropped:** `statusNote` (operator-written), `gaps`, `gapCount`, `warnings`, `rateCardId`, line `id`, `clientId` |

- **Web (`wms-fe`).**
  - **Session.**
    - `SessionUser.clientId` is normalised to `null` when absent or `undefined` in `readSession`.
    - `StoredSession` gains `client`.
    - `refreshSessionUser` calls `/me` for operators and `portal/me` for clients, and compares `clientId`.
  - **Roles.**
    - `roleHasCapability` answers `false` for an unknown role.
    - The mirror gains `client: []`, and `check-capability-mirror.ts:17` gains `client`.
  - **Routing.**
    - Pages live at `src/app/(portal)/portal/{stock,orders,inbound,invoices}/page.tsx`. `src/app/(portal)/portal/page.tsx` redirects to `stock`.
    - `AppShell` renders nothing until the session is read, then:
      - a client session → `/portal/stock`, so no operator hook ever runs;
      - no session → `/login`.
    - `PortalShell`: an operator session → `/settings`, no session → `/login`.
    - Sign-in pushes a client user to `/portal/stock`.
  - **The portal shell.**
    - Nav: Stock, Orders, Inbound, Invoices; plus the client's name from the session and sign-out.
    - It listens for session change and expiry the way `AppShell` does.
    - On `client-suspended` it clears the session and goes to `/login` with "Your company's portal access is suspended."
    - No operator component is mounted inside it.
  - **Surfaces.** Each follows the house loader skeleton, with mappers in `lib/portal.ts` and hooks in `lib/use-portal.ts`. The invoice detail reuses the printable layout only if it renders from the portal DTO.
  - **Users card.**
    - `INVITE_ROLE_OPTIONS` adds `client`, with a picker of active non-self clients, shown when `showClients`.
    - The inline role select keeps the four.
    - A client user's row shows its role read-only, with the client's code.

**Never:**
- portal writes, ASN entry included;
- the drill-down or rate cards in the portal;
- client-side user administration;
- per-client reporting (21-8);
- refresh tokens or revocation;
- changing an operator token's claims;
- reusing an operator read route for the portal;
- `AUTH_DATABASE` in the portal guard;
- relying on RLS alone or on the app predicate alone.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected | Error |
|---|---|---|---|
| Invite a client user | role `client`, BRAND-A | `invited`, `clientId` set | — |
| Bad invite | `client` without `clientId` / `operator` with one / self / foreign-tenant / suspended client | — | 400 / 400 / 400 / 404 / 409 `client-not-active` |
| Replay after suspension | same key, client suspended since | the stored snapshot | — |
| Sign in | portal user, BRAND-A active | token carries `client_id`; body has `user.clientId` and `client` | — |
| Suspended | wrong password / right password / live token's next portal call | — | 401 / 403 `client-suspended` / 403 `client-suspended` |
| Fence | portal token → member-open GET, write, `AnySessionGuard` route | — | 403 `role-denied`, the operator-surface detail |
| Reverse fence | operator token → `/portal/*` | — | 403 `role-denied`, the portal detail |
| Odd tokens | `client_id: null` / non-UUID / with `device_id` | — | 401 |
| Isolation | A token; B has stock, orders, ASNs, POs, invoices | only A's rows; B's ids → 404 | — |
| Shared bin; allocated-only | A and B in one bin; A SKU with 0 on-hand, 5 allocated | one A row per (SKU, warehouse); the allocated-only row is listed | — |
| Drafts and voids | A has draft, issued, void | issued and void | — |
| Kit order | kit + 2 components | `lineCount` 1; components nested | — |
| Role change | to `client`, or of a client user | — | 400 |
| Badge-in | client user, wrong PIN / right PIN | — | 401 `badge-invalid` / 403, device unbound |
| Legacy | stored session without `clientId`; pre-21-7 invite replay | operator session; same hash, `clientId: null` | — |

</frozen-after-approval>

## Code Map

All `wms-be` paths are relative to `workspace/core/backend/wms-be`.

- **Sessions.**
  - `src/modules/tenancy/jwt-session.ts:44-61`.
  - `tenant-session.guard.ts:26-43`.
  - `any-session.guard.ts:31-77`: tries the device verifier first. It is used on 3 routes: `movements.controller.ts:185,339`, `compliance.controller.ts:53`.
  - `device-session.guard.ts`.
  - `sign-in.command.ts:43-107`.
  - `enrollment.command.ts`: badge-in `:509-525`; denylist `:751`.
- **Authority.**
  - `permissions.ts`: `ROLE_CAPABILITIES` `:265-355`, `assertPermission` `:366`.
  - `schema.ts:66-68` (enum) and `:90-108` (users). The comment at `:63-64` ("never a JWT claim") is amended.
  - `tenancy.dto.ts:241-276` (`USER_ROLES`, invite and set-role DTOs).
  - `devices.dto.ts:87`.
- **Users.**
  - `users.command.ts`: `invite` `:133` (hash `:135-139`, replay `:146-160`, insert `:177-191`); `setUserRole` `:253`.
  - `users.controller.ts:81,132,184`.
  - `tenancy.service.ts:126-133` (`getMemberClientIdIn`).
  - `clients.facade.ts` (`getClientStatusInTx`, `getClientInTx`).
- **Scope.**
  - `src/shared/db/tenant-scope.ts:68-86`.
  - `db.ts:20-50`: prod `wms_app` binds RLS, while **dev/CI connect as superuser `wms`, so RLS never applies in the jest e2e suites**.
  - `scripts/provision-roles.sql`.
  - RLS client clause: 0041 (skus, orders, purchase_orders, ledger_events, clients), 0062:409 (client_invoices, drafts hidden; lines via parent), 0064:148 (ASNs; lines via parent).
- **Operator reads to mirror, never reuse:**
  - `inventory.facade.ts:582`;
  - `outbound.facade.ts:614,636` and `order.command.ts:1433`;
  - `inbound.facade.ts:153,233,359,411`;
  - `client-invoices.ts:1147,1174` and `client-invoices.dto.ts:60-215`;
  - `pagination.ts`;
  - `time.ts` `fullPrecisionInstant`;
  - `decodeCursorSafe` is copied per facade (e.g. `putaway.facade.ts:46`).
- **Tests.**
  - `test/client-isolation.spec.ts` (`wms_rls_probe`; `:326` stamps; `:368,409` the probe role); `global-setup.cjs:48,60-63`.
  - `test/architecture.spec.ts:900-925` (the meaningful-test companion).
  - `test/users.spec.ts:817-892` (role matrix).
  - `test/tenancy.spec.ts:304-324` (token).
  - `test/issuance-gate-parity.spec.ts:355` (the hash-golden pattern).
  - **Fixtures broken by the CHECK:** `asn.spec.ts:500`, `client-invoices.spec.ts:930`, `invoice-records.spec.ts:542`, `metering.spec.ts:1212`.
- **Next migration: 0065.**
- **Web.** All `wms-fe` paths are relative to `workspace/core/frontend/wms-fe`.
  - `src/lib/auth.ts:19-80`.
  - `src/lib/api/client.ts:318,334,389,3055`.
  - `auth-forms.tsx:144-151`.
  - `src/app/(app)/layout.tsx`, `src/components/shell/app-shell.tsx:30`, `src/proxy.ts:29-34`.
  - `src/lib/users.ts:13,222-260`.
  - `scripts/check-capability-mirror.ts:17`.
  - `users-card.tsx:25,212,275`.
  - `src/lib/clients.ts`.
  - `client-invoices.tsx:556`.
  - `use-client-invoices.ts`.
  - `src/lib/test/render.ts`.

## Tasks & Acceptance

**Execution:**
- [x] `wms-be/drizzle/0065_portal_client_role.sql` (with journal, snapshot and `schema.ts`) -- the enum value, the pre-flight, the text-compared CHECK and the `DO`-block post-assertion.
- [x] `wms-be` tenancy -- token sign and verify, sign-in, both fence refusals, badge-in, the three allowlists, the role tuples and DTOs, invite and role-change rules, replay normalisation, `ROLE_CAPABILITIES.client`, the comment amendments.
- [x] `wms-be` clients -- `PortalSessionGuard`, `@CurrentPortalSession`, `portal/me`.
- [x] `wms-be` portal reads -- `portal.controller.ts`, the portal DTOs, one facade read per owning module with its cursor codec; then re-export `openapi.json`.
- [x] `wms-be` existing fixtures -- rewrite the four CHECK-broken fixtures to set `role='client', client_id=…` together, with the token minted **before** the update, so each still proves its per-route refusal (claim-less token, DB-read client).
- [x] `wms-be/test/portal.spec.ts` and `test/client-isolation.spec.ts` -- cover:
  - every matrix row;
  - the fence's exact detail on a member-open GET per controller plus one `AnySessionGuard` route;
  - **guard coverage:** every route has exactly one of the four guards, or is allowlisted by exact method and path (health, openapi, echo, webhooks, sign-in, register, accept-invite, `devices/enroll`, the not-found catch-all); every `portal/` route has `PortalSessionGuard` and no other route has it;
  - **an architecture test** that each portal facade read's `withTenantTransaction` passes `{ clientId }`, with its meaningful companion;
  - **probe arms run as `wms_rls_probe`:** the portal stock, order-line, PO-line and invoice-draft query shapes, client-stamped and with **no** app predicate, return only A's rows;
  - `[...ROLE_CAPABILITIES.client]` equals `[]`;
  - an operator token's key set equals `['sub','tenant_id','iat','exp']`, plus a pinned `signTenantSession` literal;
  - the invite hash golden read from `idempotency_keys` after a real operator invite (the 8-1d pattern);
  - the 0065 CHECK in the `client` direction;
  - deep exact-key `toEqual` on every portal response;
  - pagination: a second page across equal timestamps, a bad cursor, limit bounds.
- [x] `wms-fe` -- everything under Web, and:
  - run `bun run api:generate`;
  - `auth.test.ts`: a legacy session reads `clientId === null`, and there is no redirect loop between the shells;
  - `client.test.ts`: `refreshSessionUser` on a `clientId` change;
  - `users.test.ts`: an unknown role answers false;
  - `auth-forms.test.tsx`: pushes `/portal/stock` and `/settings`;
  - `AppShell` issues no operator fetch for a client session;
  - each surface's ready, empty and failed states;
  - `client-suspended` handling;
  - the invite form and the read-only client row.
- [ ] Meta docs:
  - `IMPLEMENTATION-GUIDE.md`: the AD-4 amendment; "the migrator runs all pending files in one transaction — never use a new enum value in the migration that adds it"; "jest e2e is RLS-inert; isolation is proved as `wms_rls_probe`";
  - `clients.md`;
  - `tenancy.md`;
  - `API-SURFACE.md`;
  - `frontend/SYSTEM-DESIGN.md` (route map, unknown role, `:217`);
  - the `wms-be`, `wms-fe` and `wms-mobile` contracts (`BadgeInResponse` role enum);
  - 3PL `architecture.md`;
  - `PENDING.md`: close the 21-2 item 7 carry-forward, the 21-5 portal DTO and the unknown-role crash; add portal ASN (21-7b), portal drill-down, rate-card visibility, a sellable/held stock split, a portal warehouse filter, client-side user admin and revocation.

**Acceptance Criteria:**
- Given BRAND-A and BRAND-B with stock in one shared bin, orders, an ASN each and an issued invoice each, when a BRAND-A user signs in and opens Stock and then Invoices on the web, then they see only BRAND-A's rows, never a bin, and no operator request is made.
- Given the full BE and FE suites, when run, then they pass.

## Implementation Notes

Baselines: wms-be `43c326211855cd0dd6d1ec88411612edd3f4b9e7` (`baseline_commit`), wms-fe `48320ab8c4b89694ae5d7b808a04b2cbd0930984`.
- Work on `feat/21-7-client-portal` in both repos (already checked out) and leave everything uncommitted: no commit, push or PR.
- In wms-be, run `bun run test -- <file>`; never bare `bun test`, and never two jest invocations at once (globalSetup sweeps kill the other run's DBs). The ledger idempotency-race test can flake under full-suite load only; rerun it alone before blaming the story.
- Edit meta docs in `/Users/sasidhar/Documents/WMS-Meta` (on `main`, uncommitted).
- Do not touch `wms-mobile` code; its README is a doc.

## Spec Change Log

## Review Triage Log

Design review, 2026-10-09: three lenses (adversarial 22, edge-case 23, verification-gap 13), consolidated into 30 rows. Every claim below was checked against the code before it was triaged; overlap is noted.

| # | Sev | Finding (lenses) | Verdict and evidence | Action |
|---|---|---|---|---|
| 1 | high | 0065/0066 split does not escape 55P04: the migrator runs all pending files in one transaction (A1, VG2) | TRUE: `dialect.js:60-71` wraps every pending migration in one `session.transaction` | patch: one migration, CHECK on `role::text`, no `'client'` cast in the probes; guide rule added |
| 2 | high | jest e2e connects as superuser, so RLS is inert and the "two layers" have no test that can fail (A4, VG1) | TRUE: `db.ts:29-47`, `provision-roles.sql` (prod `wms_app` binds; dev/CI `wms` bypasses) | patch: `wms_rls_probe` arms on the portal query shapes without the app predicate, plus an architecture test that every portal read passes `{clientId}` |
| 3 | high | the CHECK breaks four existing fixtures that set `client_id` on non-client roles (A3, VG3) | TRUE: `asn.spec.ts:500`, `client-invoices.spec.ts:930`, `invoice-records.spec.ts:542`, `metering.spec.ts:1212` | patch: rewrite with a pre-update token so the per-route refusals keep coverage |
| 4 | high | `/me` sits behind `TenantSessionGuard`, which now refuses portal tokens; no guard named (E1, E2, A6, VG6) | TRUE: `users.controller.ts:184-185` | patch: `/me` stays operator-only; new `portal/me` behind `PortalSessionGuard` |
| 5 | med | no source for the client's name in the shell (E17, A7) | TRUE: sign-in and `/me` return no client, and `/clients` is fenced | patch: `client` on the sign-in response and `portal/me` |
| 6 | med | guard-coverage allowlist misses `devices/enroll` and the not-found catch-all, and does not catch a wrong guard (E3, A5, VG6) | TRUE: `devices.controller.ts:118`, `not-found.controller.ts:11` | patch: complete allowlist by method and path; exclusive `PortalSessionGuard` assertion |
| 7 | high | device role re-checks are `=== 'accountant'` denylists that admit `client` (E23, A11, VG10) | TRUE: `enrollment.command.ts:751`, `receiving.command.ts:409`, `sync-report.command.ts:561` | patch: floor-role allowlist |
| 8 | med | badge-in refusal placement leaks role or binds the device (E4, A10) | TRUE: `enrollment.command.ts:509-525` folds wrong PIN and unbound into `badge-invalid` | patch: after `pinOk && bound`, before the update; tests for both |
| 9 | med | `USER_ROLES` drives the invite, set-role and response DTOs; the spec was silent (E5, A8) | TRUE: `tenancy.dto.ts:241-276`; FE `UserRole` derives from the response | patch: `USER_ROLES` gains `client`; `ASSIGNABLE_ROLES` for set-role |
| 10 | low | `BadgeInResponse` hard-codes the four roles (A11) | TRUE: `devices.dto.ts:87` | patch: derive from `USER_ROLES`; mobile contract note |
| 11 | med | invite client checks before the replay make a valid replay 409 (E6) | TRUE: replay at `users.command.ts:146-160` | patch: authority → replay → client checks |
| 12 | med | pre-21-7 snapshots lack `clientId` (E7, A9) | TRUE by construction | patch: normalise `?? null` on invite and role-change replay |
| 13 | med | `client-not-active` is already a 409; reusing it as a 403 gives one type two meanings (A15) | TRUE: `rate-card.command.ts:522` | patch: session arm is 403 `client-suspended` |
| 14 | med | the portal guard on `AUTH_DATABASE` widens the BYPASSRLS connection and bypasses the clients facade (A14) | TRUE: `sign-in.command.ts:33-36` scopes it to auth-time reads | patch: tenant-scoped re-read via `getMemberClientIdIn` + `getClientStatusInTx`; guard lives in clients (3PL `architecture.md`: clients owns portal scoping) |
| 15 | med | the claim as authority contradicts the written "never a JWT claim" rule, unrecorded (A13) | TRUE: `schema.ts:63-64`, `sign-in.command.ts:27-29` | patch: AD-4 amendment recorded in Design Notes and the guide |
| 16 | med | `client_id: null`, non-string, or with `device_id` has an undefined meaning (E9, A22) | TRUE: `AnySessionGuard` branches on claim presence | patch: all rejected, tested |
| 17 | high | the golden shape drops allocated-only rows; a per-bin join fans out (E10, E11, A16) | TRUE: the old golden filtered `quantity > 0` per bin | patch: pre-aggregate both sides, FULL join, keep either > 0 |
| 18 | med | the stock keyset cannot use `buildPage`'s `{createdAt, id}`; `decodeCursorSafe` is not in `pagination.ts` (E12, A16) | TRUE: `pagination.ts:8-64`; `putaway.facade.ts:46` | patch: own codec; Code Map fixed |
| 19 | med | which bins count as on-hand is undecided (A17) | Design gap | patch: every bin counts; the sellable/held split goes to PENDING |
| 20 | high | invoice field rule open-ended: `statusNote`, nested `party.supplier.warehouseCode`, `gapCount`, line `rateCardId` (E16, A18, VG9) | TRUE: `client-invoices.dto.ts:96,193,200`, line `:83` | patch: exact key allowlist; `statusNote` dropped; voids shown; deep `toEqual` |
| 21 | med | keysets, `lineCount` for kits, source columns and the warehouse filter's source are unstated (E13, E14, A19) | TRUE | patch: keyset per route; top-level `lineCount`; columns named; warehouse filter dropped (PENDING) |
| 22 | low | an order line whose SKU moved client vanishes under RLS (E15) | Mostly unreachable: 21-2b refuses a move with order history, leaving only the PENDING race | patch: `skus` LEFT-joined |
| 23 | med | FE routing: the group adds no segment, no `/portal` index, `AppShell` mounts and fires operator calls before redirecting, and a null session goes to `/settings` (E18, E19, A20) | TRUE: `proxy.ts`, `app-shell.tsx:30` | patch: folder layout, index page, render-gate, null → `/login`, a no-operator-fetch test |
| 24 | med | FE has no handling for suspension or expiry inside the portal (E20, E21) | Design gap | patch: `client-suspended` clears the session; the shell listens to session events |
| 25 | med | `ROLE_OPTIONS` is shared by invite and the inline role select (E22, A9) | TRUE: `users-card.tsx:25,212,275` | patch: split options; client row read-only with the client code |
| 26 | med | fence tests cannot tell the fence from the capability layer; `AnySessionGuard` may go untested (VG4) | TRUE: writes 403 `role-denied` anyway; 3 `AnySessionGuard` routes | patch: assert the exact detail on member-open GETs plus an `AnySessionGuard` route |
| 27 | med | `ROLE_CAPABILITIES.client` empty, operator token bytes and the invite hash are untested or tested self-referentially (VG5, VG7, VG8) | TRUE: `tenancy.spec.ts:304-324` reads claims singly; `hashCommandPayload` is `JSON.stringify` | patch: empty-set assertion, key-set and literal tests, hash golden via `idempotency_keys` |
| 28 | med | FE session tolerance and sign-in routing untested; the unknown-role test would be vacuous once `client` is mirrored (VG11) | TRUE: `readSession` returns the parsed object unchanged | patch: listed FE tests, unknown role via a cast |
| 29 | low | the immutability scan cannot see role values (A12, VG12) | TRUE: `role: command.role` | patch: the scan covers `client_id` only; role enforced by DTO + HTTP tests |
| 30 | low | "the two new tables" names nothing; FE verification skips `api:generate`; migration pre-flight and post-assertion arms unstated (A21, VG13, E8, A2) | TRUE | patch: sentence removed; `api:generate` added; `RAISE` pre-flight and `DO`/`check_violation` probes specified |

Code review, 2026-10-09: three layers (blind-hunter 15, edge-case 5, verification-gap 6), 26 rows. Every claim was checked at the cited code; 11 patch, 4 defer, 11 reject. No loopback.

| # | Verdict | Finding (layer) | Evidence | Route |
|---|---|---|---|---|
| C1 | medium | Suspension notice lost: `clearSession()` flips the shell decision to `/login`, whose effect replaces after `PORTAL_SUSPENDED_LOGIN` (EC-1) | TRUE: `portal-shell.tsx:41,45-47` — the last `router.replace` wins | patch |
| C2 | low | Address lines keyed by text collide when equal (EC-4) | TRUE; direct correction | patch |
| C3 | low | Badge-in refusal is a `=== 'client'` denylist beside the new allowlist rule (BH-1) | TRUE: `enrollment.command.ts` badge-in; a later role would bind devices | patch: allow floor roles + accountant explicitly |
| C4 | low | API-SURFACE "reads never capability-gated" and "limit 1–200" now false (BH-9) | TRUE | patch (docs) |
| C5 | low | Portal invoice `invoiceNo`/`fyLabel`/`issuedAt` nullable though always set; FE invents "Unnumbered" (BH-12) | TRUE: void is reachable only from issued/disputed (billing-model) | patch |
| C6 | medium | RLS-only probe arms omit ASN and header shapes; PENDING claims ASN lines proved (BH-8) | TRUE: `client-isolation.spec.ts` Part 3 | patch: add arms, narrow the claim |
| C7 | medium | ASN/PO paging and the PO status filter untested (VG-1) | Pre-verified gap | patch (tests) |
| C8 | medium | Storage-line milli→decimal and restated `compareLines` untested (VG-2) | Pre-verified gap | patch (tests) |
| C9 | medium | FE paging and ASN/PO line expanders untested (VG-3) | Pre-verified gap | patch (tests) |
| C10 | low | `any-session.guard.ts` docstring says the tenant verifier ignores `device_id` (VG other) | TRUE since 21-7 | patch |
| C11 | low | "badge-in token no longer opens a web route" has no direct assertion (VG other) | TRUE: only the combined-claim token is tested | patch (test) |
| C12 | medium (unverified scale) | No `(tenant_id, client_id, created_at, id)` index serves the portal keysets (BH-6) | TRUE: no such index; a busy brand's list sorts every page | defer |
| C13 | low | The stock read re-aggregates the client's whole stock per page (BH-7) | TRUE by construction (CTEs before the keyset) | defer (with C12) |
| C14 | medium | The RLS proof runs copies of the portal SQL, not the production functions (VG-4) | Pre-verified; a harness change beyond this story | defer |
| C15 | medium | No way to deactivate one portal user (BH-2) | TRUE, but pre-existing: no user deactivation exists for any role; suspending the client is the only lever | defer |
| C16 | false | A portal 401 leaves the user on a dead session (BH-3) | `client.ts:354` clears the session on every 401; the shell then routes to `/login` | reject |
| C17 | low | Malformed-id 400 vs invoice 404 differ (BH-4) | Spec-conformant ("the operator route's convention"); cosmetic | reject |
| C18 | low | Cursor decoders copied thrice (BH-5) | The house pattern already tracked in PENDING cross-cutting | reject |
| C19 | low | clients ↔ tenancy import cycle unguarded (BH-10) | Boots and every suite passes; harm is hypothetical future value imports | reject |
| C20 | low | `portal/me` repeats the guard's re-read (BH-11) | Two cheap reads; fixing adds request plumbing | reject |
| C21 | low | Invoices ordered by `created_at`, not issue order (BH-13) | Spec-mandated keyset; rows show period and issue date; drafts issue promptly | reject |
| C22 | low | `signTenantSession` positional optional args (BH-14) | Style; one caller | reject |
| C23 | low | Accept after client suspension untested (BH-15) | Suspension is SQL-only (PENDING); sign-in refuses it, tested | reject |
| C24 | low | Invite role stays `client` if the clients list reloads to null (EC-2) | Unlikely (one fetch); the guard would add a branch | reject |
| C25 | low | Empty client picker with no message (EC-3) | Needs every brand non-active — unreachable without SQL | reject |
| C26 | low | Invite vs concurrent suspension, unlocked read (EC-5) | No command suspends a client | reject |

## Design Notes

- **AD-4 amended, for the fence only.** The token used to be transport, never authority. `client_id` now becomes an authority claim with one use: refusing operator routes, across 164 guarded routes behind about 20 copied `assertOwnTenant`s, checked in one place.
  - It cannot go stale. The column is written only at invite, enforced by the DTO, the command, the CHECK and the scan.
  - Capabilities stay a per-command DB read.
  - The portal side re-reads the user and the client every request, because that is where an untrusted party holds the session and where suspension must bite before the 15-minute expiry.
- **Why two layers, and how each is proved.**
  - RLS alone does not cover inherited tables. An app predicate alone is AD-23's "the one that forgets is the leak".
  - The jest suite connects as a superuser, so HTTP tests prove only the predicate. The RLS layer is proved by probe arms run as `wms_rls_probe` with the predicate removed. That a portal read stamps at all is proved by the architecture test.
- **On-hand plus allocated, not ATP.** ATP reads Valkey fail-closed and subtracts channel buffers (another party's commercial setting). The two figures here are plain DB rows. Every bin counts, because the goods are in the building; the sellable split is PENDING.
- **Golden shape** for the stock read (pre-aggregate, then join):
  ```sql
  with oh as (select s.id sku, so.warehouse_id wh, sum(so.quantity) q from stock_on_hand so
              join skus s on s.id = so.sku_id and s.tenant_id = $t
              where s.client_id = $c group by 1,2),
       al as (select s.id sku, r.warehouse_id wh, sum(r.quantity) q from reservations r
              join skus s on s.id = r.sku_id and s.tenant_id = $t
              where s.client_id = $c and r.owner_type = 'order' and r.state in ('held','committed') group by 1,2)
  select … from oh full join al using (sku, wh) where coalesce(oh.q,0) > 0 or coalesce(al.q,0) > 0
  ```
  It runs inside `withTenantTransaction(db, t, fn, { clientId: c })`.

## Verification

**Commands:**
- `cd workspace/core/backend/wms-be && bun run test -- test/portal.spec.ts` -- expected: pass (never two jest runs at once)
- `cd workspace/core/backend/wms-be && bun run test -- test/client-isolation.spec.ts` -- expected: pass, including the new probe arms
- `cd workspace/core/backend/wms-be && bun run test && bun run lint && bun run typecheck` -- expected: the full suite passes, including the four rewritten fixtures
- `cd workspace/core/frontend/wms-fe && bun run api:generate && bun test && bun run typecheck && bun run lint && bun run check:capability-mirror` -- expected: pass (the mirror and generated-client guards fail in CI until the backend merges)

**Manual checks:**
- Real-HTTP smoke: invite a BRAND-A user, accept, sign in, call a member-open operator GET (403, operator-surface detail) and each portal route (A's rows only); suspend BRAND-A by SQL and see the next portal call return 403 `client-suspended`.
