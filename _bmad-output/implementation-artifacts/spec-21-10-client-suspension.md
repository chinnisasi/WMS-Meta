---
title: 'Client suspension — an owner suspends and reactivates a client, making the portal gates reachable'
type: 'feature'
created: '2026-10-11'
status: 'done'
route: 'dispatch'
baseline_commit: '2fea21bbdc9946993bcffabc2d18d209074f8aa9'
review_loop_iteration: 0
context:
  - '_bmad-output/implementation-artifacts/epic-21-context.md'
  - '_bmad-output/implementation-artifacts/spec-21-2b-client-admin-and-attribution.md'
  - '_bmad-output/implementation-artifacts/spec-21-7-client-portal.md'
  - '_bmad-output/implementation-artifacts/epic-21-retro-2026-10-10.md'
  - 'docs/design/SYSTEM-DESIGN.md'
  - 'docs/design/IMPLEMENTATION-GUIDE.md'
  - 'docs/design/API-SURFACE.md'
  - 'docs/design/modules/clients.md'
  - 'docs/design/frontend/SYSTEM-DESIGN.md'
  - 'docs/design/frontend/IMPLEMENTATION-GUIDE.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** The epic-21 retro (X2, action A3) found that nothing can suspend a client.
- `clients.status` allows `active | suspended | departed` (`schema.ts:137`, CHECK `0040:96-102`).
- These refuse a suspended client:
  - the portal guard (`portal-session.guard.ts:76-78`);
  - portal sign-in (`sign-in.command.ts:111-113`);
  - portal `me` (`clients.facade.ts:357-359`);
  - portal ASN announce (`asn.command.ts:597-599`);
  - portal-user invite (`users.command.ts:212-225`);
  - rate cards (`rate-card.command.ts:511-528`).
- But no command writes `suspended`, so every one of those gates is reachable only by SQL.
- 21-7b's accepted risk (unlimited portal ASNs, PENDING `:135`) rests on clients being suspendable.

**Approach:** An owner-only command moves a client between `active` and `suspended`, with a Settings row action. The existing gates become reachable. The three gates whose status read takes no lock get a row lock, so a request in flight cannot commit past a suspension.

**Decisions (human, 2026-10-11):**
1. **Scope: the portal and client admin only.** Suspension stops what is already gated:
   - portal sign-in and every portal call (including the portal's invoice and service views);
   - portal ASN announce;
   - new portal users;
   - rate-card drafts and activation.

   Operator work continues: receiving, orders, picking, dispatch and billing for a suspended client behave as today.
2. **Open portal ASNs stay open.** Suspending cancels nothing; an operator can still cancel any ASN.

## Boundaries & Constraints

**Always:**
- **Route:** `PATCH /tenants/{t}/clients/{c}/status`.
  - **Body:** `UpdateClientStatusDto {status}`, validated against `CLIENT_STATUS_TARGETS = ['active','suspended'] as const`. The tuple is exported beside the command and used in `@IsIn` and `@ApiProperty({enum})`.
  - **Guards:** an `Idempotency-Key` is required, behind `TenantSessionGuard` and `assertOwnTenantToken`.
  - **Response:** 200 `ClientResponse {client}`.
  - **Declaration:** the literal `:clientId/status` segment is declared after `:clientId`, as with tax-details.
  - **Documented arms:** `@ApiResponse` documents every matrix arm, including 400 self, 409 `client-not-active` and 422 key reuse.
- **Command `ClientsCommand.updateStatus`.** It follows IMPLEMENTATION-GUIDE §1, in this order:
  1. Refuse a status outside `CLIENT_STATUS_TARGETS` → 400 `validation-failed`.
  2. Hash `hashCommandPayload({arm: 'status', tenantId, clientId, status})`. The key order is pinned by a golden test that reads `idempotency_keys.payload_hash`.
  3. Inside the transaction: `assertPermission(getMemberRoleIn(…), 'clients.manage')` (owner-only; otherwise 403 `role-denied`).
  4. Replay.
  5. UUID check.
  6. `SELECT … FOR UPDATE` on the client (404 `not-found`).
  7. **Replay again under the lock.**
  8. Self client → 400 `validation-failed` "The self client cannot be suspended or reactivated".
  9. `departed` → 409 `client-not-active` "Client "X" has departed — its status cannot change".
  10. **Same status → no-op.** Return the current client with no update and no audit, **but write the idempotency key**. Rename deliberately does not do this; for a status it matters, because a late retry of a stored no-op must never re-apply after someone else has changed the status.
  11. Update `status` and `updatedAt`.
  12. Audit `client.suspended` / `client.reactivated`, extending the union at `:368`.
  13. `writeIdempotencyKey` last.
  - No outbox event.
- **Lock the gates' status reads.**
  - Add `shareLockClientInTx(tx, tenantId, clientId)` to `clients.facade.ts`, beside `lockClientInTx`. It does `.for('share')` and returns the same facts as `getClientStatusInTx`.
  - Use it at the rate-card draft (`rate-card.command.ts:113`), the portal ASN announce (`asn.command.ts:597`) and the portal-user invite (`users.command.ts:212`).
  - `getClientStatusInTx` itself is **unchanged**, because its other callers are reads.
  - **Lock order:** client first, then documents; no transaction locks a card or ASN before the client, so there is no cycle. Under READ COMMITTED, a waiting `FOR SHARE` re-reads the committed `suspended`.
  - Existing drafts can still be edited or discarded (those paths never read status). Activation re-checks under its own lock, so this is harmless; record it in `clients.md`.
- **Effect.** Every gate reads status per request (the token carries only `client_id`, §7e).
  - A live portal session is cleared on its next call: `portalError` → `portal-shell.tsx:50-54` → `/login?portal=suspended`.
  - Reactivating restores access at once.
  - An invite issued before the suspension can still be accepted, but that user cannot sign in. Record this.
- **Web.**
  - **Shared confirm row.** Extract `components/settings/confirm-row.tsx` from `rate-cards-card.tsx:478-530`: props `question`, `confirmLabel`, `ariaLabel`, `run(key)`, `reason(error)`, `onDone`, with the `keyRef ??= ulid()` and `inFlight` pattern. Move rate cards onto it with no behaviour change; its tests still pass.
  - **Clients card panel state** (`clients-card.tsx`):
    - Replace `renaming` and `taxing` with one `panel` union, adding `suspend` and `reactivate`.
    - The confirm row renders in the panel below the table, keyed `` `${action}-${client.id}` ``, and unmounts on success. So Reactivate right after Suspend uses a fresh key.
  - **Status labels:** the Status column shows "Active" / "Suspended" / "Departed".
  - **Row actions:** owners (`canManage`) see Suspend (active) or Reactivate (suspended) on non-self rows; there is none on departed rows.
  - **Copy:**
    - **Suspend:** "Suspend {name}? Its portal users are signed out on their next action and cannot sign in, announce shipments or be invited, and its rate card cannot be changed. Warehouse work and billing continue (it cannot see invoices in the portal while suspended). Open ASNs stay open."
    - **Reactivate:** "Reactivate {name}? Its portal users can sign in again."
    - **Success:** "{name} is suspended." / "{name} is active again."
  - **Error copy.** Widen `clientReason`'s action to `'created' | 'renamed' | 'suspended' | 'reactivated'`. Add arms for:
    - `client-not-active` ("This client has departed — its status cannot change");
    - `validation-failed`, using the problem `detail`;
    - `role-denied`, `permission-denied`, `not-found`, `idempotency-key-reuse` and `conflict`.
  - **API wiring:** `fetchApiUpdateClientStatus`; `bun run api:generate`.
  - **Pickers:** the other client pickers (import, invoices) keep `clientLabel` unchanged, because operator work continues for suspended clients.
- **Tests (BE).**
  - **`test/clients.spec.ts`:**
    - every matrix row;
    - the hash golden;
    - the **late-retry case:** a no-op under K, reactivate under K2, replay K → the stored `suspended` snapshot and no write;
    - **portal end to end**, with `accept`/`portalUser` copied from `portal.spec.ts:356-365`: sign in (200) → suspend → portal `me` 403 `client-suspended` and sign-in 403 → reactivate → `me` 200;
    - audit rows asserted as at `:500`.
  - **Races,** deterministic per `channel-connections.spec.ts:505-535` (`pg_stat_activity` / `pg_blocking_pids`):
    1. A raw transaction locks the client `FOR UPDATE` and sets `suspended`. A rate-card draft POST and a portal ASN POST start without being awaited; once both are parked behind the holder, commit → both 409/403 (`client-not-active` / `client-suspended`).
    2. The mirror: the draft holds `FOR SHARE` (through a gated spy or a raw `FOR SHARE` holder), the suspend PATCH parks, and after release the suspend succeeds.
  - Update the stale comment at `rate-cards.spec.ts:314`.
- **Tests (FE).**
  - **`clients-card.test.tsx`:**
    - the actions show only for owners and only on eligible rows;
    - PATCH is sent with `Idempotency-Key` and the body `{status}`;
    - the key is reused on retry (`expect(patches[1]!.key).toBe(patches[0]!.key)`, as at `portal.test.tsx:611`);
    - Reactivate after Suspend uses a fresh key;
    - the list reloads;
    - the labels render. Fix the lowercase `'suspended'` assertion at `:138`, and add a `PATCH …/status` stub route with a failure switch.
  - **`clients.test.ts`:** each listed `clientReason` arm.
  - **The rate-cards card tests** pass unchanged on the extracted `ConfirmRow`.

**Never:**
- refusing operator work (orders, receipts, picks, dispatch, invoices) for a suspended client (decision 1);
- cancelling or closing ASNs on suspend (decision 2);
- `departed`, or any departure flow;
- session revocation;
- a per-user status;
- a new capability;
- an outbox event;
- changing `getClientStatusInTx`;
- status in other client pickers.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected | Error |
|---|---|---|---|
| Suspend | Active client, owner | 200 `suspended`; audit `client.suspended` | — |
| Reactivate | Suspended client | 200 `active`; audit `client.reactivated` | — |
| No-op | Status already equals the body | 200 current; no audit; the key is stored | — |
| Late retry | A stored no-op key replayed after another change | Returns the stored snapshot; no write | — |
| Live portal session | Suspended mid-session | The next call is 403 `client-suspended` and the portal signs out; reactivating restores access | — |
| In-flight announce or draft | Parked behind a committing suspend | Refused (`client-suspended` / `client-not-active`) | — |
| Replay | Same key, same body | The same body; no second audit | — |
| Key reuse | Same key, other body | — | 422 `idempotency-key-reuse` |
| Self client | `systemOwned` | — | 400 `validation-failed` |
| Departed | `status = departed` | — | 409 `client-not-active` |
| Bad body | `departed` or an unknown value | — | 400 `validation-failed` |
| Not owner | Operator, ops_manager, accountant | — | 403 `role-denied` |
| Other tenant | A token for another tenant | — | 403 `permission-denied` |
| Unknown client | Random UUID | — | 404 `not-found` |
| Operator work | An order for a suspended client | 201 as today | — |

</frozen-after-approval>

## Code Map

`wms-be` paths are relative to `workspace/core/backend/wms-be`; `wms-fe` paths to `workspace/core/frontend/wms-fe`.

- **BE command:** `src/modules/clients/clients.command.ts`:
  - the skeleton comment is `:143-155`;
  - `rename` (`:210`; its no-op returns before the key is written, `:252-255`);
  - `updateTaxDetails` (`:285`, with the `arm` hash at `:286` and replay under lock at `:308`);
  - the self refusal is at `:244-251`;
  - the audit union is at `:368`.
- **BE facade and route:**
  - `src/modules/clients/clients.facade.ts:178-193` (`getClientStatusInTx`; it takes no lock) — add `shareLockClientInTx` next to `lockClientInTx`;
  - `src/api/clients.controller.ts:96-138` (the rename and tax-details routes; 422 at `:107`; segment-order comment at `:131-132`);
  - `clients.dto.ts:127-166`.
- **Gates:**
  - `rate-card.command.ts:113` (draft; gets the share lock), `:229-231` (activate, already locked), `:131-189` (edit and discard: no status read), `:511-528`;
  - `asn.command.ts:548` (the comment), `:597-599` (gets the share lock);
  - `users.command.ts:212-225` (gets the share lock);
  - `portal-session.guard.ts:76-78`; `sign-in.command.ts:111-113`;
  - `permissions.ts:216,391-397`; `registration.command.ts:175-182` (422 key reuse).
- **Tests:**
  - `test/clients.spec.ts:237,250,302,335,486,489,500`;
  - `test/portal.spec.ts:356-397`;
  - `test/rate-cards.spec.ts:313-315`;
  - `test/portal-asn.spec.ts:467-513`;
  - `test/channel-connections.spec.ts:505-535` (the parked-waiter pattern).
- **Web:**
  - `components/settings/clients-card.tsx:79-131,174-176,299-342`;
  - `components/settings/rate-cards-card.tsx:478-530`;
  - `lib/clients.ts:38-43,197-225`;
  - `lib/api/client.ts:803,3346-3350`;
  - `components/portal/portal-shell.tsx:50-54`;
  - `lib/use-clients.ts`;
  - `components/settings/clients-card.test.tsx:61-90,131-205`.

## Tasks & Acceptance

**Execution:**
- [x] `wms-be` clients: `CLIENT_STATUS_TARGETS`, `updateStatus`, `shareLockClientInTx`.
- [x] `wms-be` gates: the share lock in the rate-card draft, ASN announce and portal invite.
- [x] `wms-be` api: the route, DTO and `@ApiResponse` arms; `openapi.json`.
- [x] `wms-be` tests: `clients.spec.ts` (matrix, golden, late retry, portal end to end) and the races.
- [x] `wms-fe`:
  - `api:generate` and the wrapper;
  - the extracted `confirm-row.tsx`, with rate cards moved onto it;
  - the clients-card panel union, labels, actions and copy;
  - the `clientReason` arms;
  - tests.
- [x] Meta docs:
  - `modules/clients.md` (`:7,108`: suspension exists; what it stops and what it doesn't; existing drafts stay editable; a pre-suspension invite can be accepted but cannot sign in);
  - `API-SURFACE.md`;
  - both repo contracts;
  - `frontend/SYSTEM-DESIGN.md:55,206`;
  - `frontend/IMPLEMENTATION-GUIDE.md:185,243`;
  - `PENDING.md`: amend `:122` (suspend and reactivate shipped; departure open), `:135` (suspendable in the UI), `:147` (closed: the share lock).

**Acceptance Criteria:**
- Given an owner and a client with a signed-in portal user, when the owner suspends the client in Settings, then the portal user's next action signs them out with the suspended message. After reactivation they can sign in again, with no SQL anywhere.
- Given the full BE and FE suites, lint and typecheck, when run, then they pass.

## Implementation Notes

Baselines: wms-be `2fea21bbdc9946993bcffabc2d18d209074f8aa9` (`baseline_commit`), wms-fe `86bdf8580c0ca72d4310f48894eecaf832bbe61d`.
- Work on `feat/21-10-client-suspension` in wms-be and wms-fe (already checked out). Leave everything uncommitted: no commit, push or PR.
- In wms-be, run `bun run test -- <file>`; never bare `bun test`, and never two jest invocations at once (globalSetup sweeps kill the other run's DBs). The ledger idempotency-race test can flake under full-suite load only; rerun it alone before blaming the story. In wms-fe, `bun test` is correct.
- Real Postgres and Valkey must be up for the BE suites (wms-be docker-compose).
- Edit meta docs in `/Users/sasidhar/Documents/WMS-Meta` (uncommitted, on the current branch).
- Do not touch wms-mobile.

## Spec Change Log

## Review Triage Log

Design review (2026-10-11), two lenses: backend (K) and web and tests (W).

| # | Lens | Finding | Verdict | Disposition |
|---|---|---|---|---|
| 1 | K, W | The matrix pinned the wrong codes: key reuse is 422, a non-owner is `role-denied` | high — verified, `registration.command.ts:175-182`, `permissions.ts:391-397` | Fixed |
| 2 | K, W | Announce (and invite) read status unlocked, so a suspend committing mid-request lets it commit (§7e) | medium — verified, `clients.facade.ts:178-193`, no FK to `clients` | Fixed: `shareLockClientInTx` at all three gates |
| 3 | K | Changing `getClientStatusInTx` in place would silently alter 7 callers | medium | Fixed: a new helper; the old one is unchanged |
| 4 | K | The no-op "rename precedent" is false (rename writes no key); writing the key is right for a status | medium | Fixed: departure recorded; late-retry test |
| 5 | W | The race test had no deterministic shape | medium | Fixed: the parked-waiter pattern |
| 6 | W | `ConfirmRow` is private and rate-card-typed; reusing it means copying (retro F4) | medium | Fixed: extracted `confirm-row.tsx` |
| 7 | W | A third panel state, and a Suspend → Reactivate key collision | medium | Fixed: a `panel` union; key per action and client |
| 8 | W | Reactivate copy and success copy missing; the rate-card refusal unstated | medium | Fixed |
| 9 | W | `clientReason` arms and action type | medium | Fixed: listed |
| 10 | W | `clients-card.test.tsx:138` breaks on the new labels; stub needs a PATCH route | medium | Fixed |
| 11 | K | The hash lacks an `arm` discriminator (tax-details has one) | low | Fixed: `arm: 'status'` + golden |
| 12 | K | Status is validated only in the DTO | low | Fixed: one tuple in the DTO, the OpenAPI enum and the command |
| 13 | K | The OpenAPI arms and route segment order were unspecified | low | Fixed |
| 14 | K | Existing drafts can still be edited or discarded | low — activation re-checks under its lock | Accepted: recorded in `clients.md` |
| 15 | K | The confirm text implied invoices stay visible in the portal | low | Fixed: copy |
| 16 | W | A pre-suspension invite can be accepted (the user still cannot sign in) | low | Accepted: recorded |
| 17 | W | Other pickers show no status | low | Decided: unchanged (operator work continues) |
| 18 | W | The FE design docs were missing from the docs task | low | Fixed |
| 19 | K, W | Gate line refs, per-request reads, token claims, portal-shell sign-out | — verified | No change |

**Code review (2026-10-11)** — Blind Hunter (B), Edge Case Hunter (E), Verification Gap (V) over the combined diff; 28 raw findings, 23 distinct.

| # | Layer | Finding | Verdict | Route |
|---|---|---|---|---|
| C1 | B, E | The suspend confirm text and DTO description overstate the server: existing drafts stay editable, and only NEW portal users are blocked | medium — verified against `clients.md` accepted edge #14 and the invite gate | patch |
| C2 | V, B | The invite gate's share lock has no race test; reverting it passes everything | medium — pre-verified gap | patch: third parked request |
| C3 | V | Replay under the lock is never exercised; deleting it turns a concurrent same-key retry into 409 | medium — pre-verified gap | patch: same-key race |
| C4 | B | `clientReason`'s `client-not-active` arm gives "departed" text for every action; the `validation-failed` fallback is wrong for a status change | low | patch: branch on action |
| C5 | B, E | Keep is clickable mid-request, so a "cancelled" suspend still lands | low — a one-attribute fix | patch |
| C6 | E | A late status response closes or overwrites a panel opened meanwhile | low | patch: same-panel guard |
| C7 | B | `CLIENT_STATUS_TARGETS` is not type-checked against the schema vocabulary | low | patch: `satisfies` |
| C8 | E | Race-test cleanup can leak a parked suspend into later tests if `waitParked` throws | low | patch: settle in-flight in `finally` |
| C9 | B | `clients.md` contradicts itself about `getClientStatusInTx` | low | patch: doc |
| C10 | B | FE guide refs are stale; `ConfirmRow` is listed under the wrong key lifetime | low | patch: doc |
| C11 | B | The PENDING "revisit with the status transitions" note is stale | low | patch: doc |
| C12 | B, E | `getClientStatusInTx` now has no callers, so a dead export invites a future gate to reopen the race | medium — verified (`clients.facade.ts:209`, no callers). The spec's "other callers are reads" premise was wrong; the frozen Never forbids changing it | defer: delete in 21-11 (doc warns meanwhile) |
| C13 | V | The rate-card cancel/discard failure path is untested after the `ConfirmRow` rewire | low — untested before the refactor too | defer |
| C14 | B | The documented 409 `conflict` and 401 arms are untested | low | defer |
| C15 | B | Terminal refusals (404, departed) leave a stale list and an open panel | low — adds branches; repeating just re-shows the refusal | reject |
| C16 | E | The suspend's `FOR UPDATE` would block FK `KEY SHARE` inserts | false — no foreign key references `clients` (grep) | reject |
| C17 | B | A replayed no-op returns the stored snapshot, which can contradict the current state | false — intended (decision recorded in Design Notes; the late-retry test pins it) | reject |
| C18 | B | The generated client, `openapi.json` and the spec were omitted from the reviewed diff | false — excluded on purpose as generated noise; the spec was provided as the claims file | reject |
| C19 | E | `ConfirmRow` with a null session does nothing silently | low — pre-existing behaviour of the extracted rate-cards row | reject |
| C20 | B | `CLIENT_STATUS_TARGETS` should live in `clients.schema` | low — location is the spec's choice | reject |
| C21 | B | `clients.md` should forbid `getClientStatusInTx` with an architecture rule | low — superseded by deleting it in 21-11 | reject |

## Design Notes

- **Why one PATCH with a status.** It matches the client admin's PATCH routes. The closed body subset leaves departure as a later, deliberate change.
- **Why refuse self.** Suspending the tenant's own client has no meaning (D2C has no portal), and every client command refuses self.
- **Why write the key on a no-op, unlike rename.** A rename is idempotent in value. A status is not: after someone reactivates, a late retry of a stored no-op "suspend" must replay the stored answer, not suspend again.
- **Why a share lock and not a re-read.** It closes the window where a suspend commits between a gate's read and its insert. It is the same fix PENDING `:147` proposed, now real because the writer exists.
