---
title: '6.1a Secure sessions — revocable sessions, staff offboarding, lockout, shift-length handheld sessions'
type: 'feature'
created: '2026-10-18'
status: 'in-review'
baseline_commit: '41eb113152bafba1827af7efaacc4f7d5f2686cc'  # wms-be; wms-fe: caf526919642948035a3082869dac6c1aec0317f; wms-mobile: 265f1b6f8724dcb5c1e0af1e0cfd298a833bb1ab
route: 'dispatch'
review_loop_iteration: 0
context:
  - 'docs/initiatives/production-readiness.md'
  - 'docs/design/SYSTEM-DESIGN.md'
  - 'docs/design/IMPLEMENTATION-GUIDE.md'
  - 'docs/design/modules/tenancy.md'
  - 'docs/design/modules/clients.md'
  - 'docs/design/frontend/SYSTEM-DESIGN.md'
  - 'docs/design/frontend/IMPLEMENTATION-GUIDE.md'
  - 'docs/design/mobile/SYSTEM-DESIGN.md'
  - 'docs/design/mobile/IMPLEMENTATION-GUIDE.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** Sessions are not production-grade in any of the three apps.

- **No offboarding.** A staff member who leaves cannot be removed: users are only `invited | active`. Their badge-in on a handheld keeps working.
- **Web and portal sessions cannot be revoked.** They are stateless 15-minute JWTs with no refresh, so people are thrown to /login with no message mid-task. "Sign out" only forgets the token in that browser.
- **No lockout:** passwords and handheld PINs can be guessed without limit.
- **Handhelds:**
  - A badge-in lasts 30 days.
  - An expired session shows nothing; scans just queue silently.
  - A device stays bound to one operator until it is re-enrolled, so shift handover is impossible.
  - The device credential itself expires after 30 days with no renewal, so every handheld would need re-enrolling monthly.

(PENDING finding #1, the device token on the web, was already closed by 21-7: `jwt-session.ts:134`. Only its PENDING row is stale.)

**Approach:** One session model across backend, web, portal and handheld:

- **Server-side session records.** Every web, portal and badge-in session gets a `sessions` row. Short access tokens carry the session id and the token kind. Every guard checks the session row and the user's status, so revoking a session, deactivating a user, suspending a client or revoking a device takes effect on the next request.
- **Web and portal stay signed in while in use.** A rotating refresh token sits in an httpOnly cookie, bounded by idle and absolute limits. Sign-out ends the session on the server.
- **Owners deactivate and reactivate staff.**
- **Lockout** applies to password sign-in and to badge-in PINs.
- **Handheld sessions last one shift.** The handheld gets a re-badge prompt, a badge-out that frees the device for the next operator, and a device credential that renews itself.

**Decisions (user, 2026-10-18):**
1. **Limits are the recommended defaults, as constants** (not tenant settings):
   - **Web staff:** idle 2 h, absolute 12 h.
   - **Portal:** idle 2 h, absolute 7 days.
   - **Badge-in:** absolute 12 h, with no idle limit.
   - **Lockout:** 5 consecutive failures → 15 min.
   - **Attempt limits and the PIN lockout key:** amendments A1–A3 below.
2. **One story.** The spec is kept whole, over the 1,600-token guideline, because it is one session model.

**Design-review amendments (2026-10-18, confirmed by the user at the checkpoint):**
- **A1. PIN lockout is per device, not per (device, operator).** The PIN belongs to the device (`devices.pin_hash`), so a per-operator lock gives an attacker 5 guesses per operator email.
- **A2. Attempt limits.**
  - The badge-in limit is keyed on the device (30 a minute per device), because every handheld shares the warehouse's one NAT address.
  - Web sign-in is limited per client IP at 300 a minute, with a configured trusted-proxy hop count.
  - Both limits are stored in Postgres.
- **A3. Password lockout is keyed on (email, client IP),** whether or not the account exists. Unknown emails are therefore indistinguishable, and an attacker cannot lock an owner out of their own network. An owner can unlock, and a CLI unlock (`bun run auth:unlock <email>`) is the fallback when every owner is locked.
- **A4. Scans queued under one operator are never replayed under another.** They go to the web review queue, attributed to their creator, and nothing is lost.
- **A5. Supervisors get "Release device"** in the Devices card, which frees a device held by an operator who has gone home.

## Boundaries & Constraints

**Always:**

*Tokens and rollout*
- **Access JWTs carry `kind` and `sid`.**
  - `kind` ∈ {`web`, `portal`, `device`, `badge`}; `sid` is the session id (`device` credentials have none).
  - Each verifier requires its own kind, and the claim-shape exclusions stay as a second check.
  - **Legacy shapes are accepted for one TTL after deploy:** a no-`kind` token with `device_id` and no `sub` is a device credential. A no-`kind` badge token (`sub` present, no `sid`) and a no-`sid` web token answer the session-ended 401 below. A test pins each shape.
- **Web 401s are split.**
  - 401 `token-expired`: the access token expired and a refresh can fix it.
  - 401 `session-ended` with `reason` ∈ {`signed-out`, `idle`, `absolute`, `deactivated`, `role-changed`, `client-suspended`, `refresh-reuse`, `legacy`}: the session is over.
- **Device and badge routes keep 401 `unauthenticated`** and add the same `reason` field. Handhelds already in the field keep their queue on `unauthenticated` (`replay-classification.ts:57-60`); any other code is dropped as `rejected` (`:147`).

*Sessions*
- **The `sessions` table** (migration):
  - Columns: `id`, `tenant_id`, `user_id`, `kind` (`web|portal|badge`), `device_id?`, `client_id?`, `refresh_hash?`, `prev_refresh_hash?`, `rotated_at?`, `created_at`, `last_used_at`, `idle_expires_at`, `absolute_expires_at`, `revoked_at?`, `revoked_reason?`.
  - Indexes: unique `refresh_hash`; `(user_id) WHERE revoked_at IS NULL`; `(tenant_id, client_id)`; `(device_id)`.
  - RLS on `tenant_id`, with a `wms_rls_probe` test.
  - A daily job purges rows ended more than 30 days ago.
- **Which connection does what:**
  - The cookie-only paths use `AUTH_DATABASE` (`wms_auth`, BYPASSRLS): the sign-in insert, and the refresh and sign-out lookups by `sid`. These are the only RLS-exempt access.
  - Guards read the session and user rows in a tenant-scoped transaction, the way `portal-session.guard.ts:68-81` does.
  - Every time comparison uses the database's `now()`.
  - `last_used_at` and `idle_expires_at` move forward only through a guarded request: `UPDATE … WHERE last_used_at < now() - interval '60 s'`. **Refresh never extends the idle window.**
- **The refresh cookie:**
  - Value `<sid>.<secret>`, httpOnly, `SameSite=Strict`, `Path=/api/v1/tenants/session`.
  - `Secure` unless `COOKIE_SECURE=false` (dev only; Safari refuses `Secure` on http://localhost). A cookie parser is added.
  - CORS: `credentials: true` for allow-listed origins only.
  - Refresh and sign-out require an allow-listed `Origin` and the header `X-WMS-Session: 1`.
  - **Deploy constraint for 6.2:** the web and API must share a registrable domain that is not on the public suffix list (not `*.elb.amazonaws.com` or `*.cloudfront.net`).
- **`POST /tenants/session/refresh`:**
  1. Lock the row `FOR UPDATE`.
  2. If the token matches `refresh_hash`, rotate it.
  3. If it matches `prev_refresh_hash` within 30 s of `rotated_at`, return the current pair. This is a tab race, not reuse.
  4. If it matches `prev_refresh_hash` after that window, revoke the session as `refresh-reuse`.
- **`POST /tenants/session/sign-out`** revokes the session and clears the cookie. It works with an expired access token.

*Revocation and offboarding*
- **Revocation seam:** tenancy exports `revokeSessionsInTx(tx, filter, reason)`. Its callers:
  - a role change revokes the user's web sessions;
  - deactivation revokes all of the user's sessions;
  - client suspend revokes portal sessions by `client_id`;
  - device revoke and Release revoke badge sessions by `device_id`.
- **User status gains `deactivated`.**
  - Both `USER_STATUSES` copies change (`schema.ts:80`, `tenancy.dto.ts:259` → `portal.dto.ts:88`).
  - A **new** `users_status_check` CHECK is added. There is none today; its migration pre-flight lists offending rows, and a test pins TS to the database.
  - A `status_before_deactivation` column is added.
- **Deactivate / reactivate:** `POST /tenants/{t}/users/{id}/deactivate` and `/reactivate`.
  - Capability `users.role_change`, idempotency-keyed with `arm` in the hash.
  - A no-op (already in that state) writes nothing but stores the key.
  - Audit `user.deactivated|reactivated`, added to `AUDIT_NEW_ACTIONS` (`shared/primitives/audit.ts:111`) and the `UserAction` union.
  - The last-owner guard counts **active** owners only, in both demote and deactivate, under the existing `FOR UPDATE`.
  - Self-deactivation is allowed only when another active owner exists. Reactivate never answers `last-owner`.
  - Deactivating an `invited` user clears the invite token. Reactivating restores `status_before_deactivation`, and an invited user gets a fresh invite token in the response, as invite returns it.
  - Deactivation also deletes the user's push registrations.
- **A deactivated user:** sign-in answers the same 401 `unauthenticated` as a wrong password, and badge-in answers 401 `badge-invalid`.

*Lockout and attempt limits*
- **Counters live in tables:** `signin_attempts(email_hash, ip, failures, locked_until)` and `devices.failed_badge_ins` / `devices.badge_locked_until`.
- **The count is committed before the expensive check.** It is incremented in its own committed transaction, with one atomic `UPDATE … RETURNING`, **before** the scrypt check. The badge-in throw at `enrollment.command.ts:573` would otherwise roll it back.
- A success resets the counter.
- While locked, the answer is 423 `sign-in-locked` or `badge-locked` with `retryAfterSeconds`, whatever the password.
- Attempt limits (A2) answer 429 `rate-limited` with `retryAfterSeconds`.
- **Unlock routes:**
  - `POST /tenants/{t}/users/{id}/unlock` (`users.role_change`) clears every `signin_attempts` row for that email.
  - `POST /tenants/{t}/devices/{id}/unlock` (`device.manage`) clears the device's PIN lock.
  - Both are keyed and audited.
- The user list DTO gains an optional `lockedUntil`. It is optional so a replayed invite response stays valid.

*Handheld*
- **Badge-in:**
  - The badge session's absolute limit is 12 h.
  - `BadgeInResponse` adds `deviceToken` and `deviceTokenExpiresInSeconds` (a rolling 30 days). The old credential stays valid until its own expiry.
  - The app writes the new credential **before** the session. A failed write never fails the badge-in.
- **Badge-out:** `POST /devices/badge-out` revokes the badge session, unbinds the operator and deletes the push registration. The server does not police the queue.
- **The device refuses badge-out while scans are queued:** "Sync your N queued scans before badging out". Supervisors use **Release device** (`POST /devices/{id}/release`, `device.manage`, keyed, audited) when the operator has left.
- **Replay authority (A4):**
  - Each queued op records its creator's user id.
  - On replay, ops whose creator differs from the badged operator are moved to the **retained/sync-report path**, the way revocation strands a queue (`engine.ts:226-247`), and are shown for web review.
  - The server also refuses an op whose `X-Op-Operator` header differs from the session's operator, with 409 `operator-mismatch`, which the device classifies as retained. An absent header is accepted, for old builds.
- **Offline badge-in verifies the PIN locally.**
  - A salted slow-hash PIN verifier is kept in the sealed store.
  - Offline failures count locally under the same 5 / 15-minute rule.
  - A cached session is never restorable after a session end or a badge-out (`device-store.ts:204-216` checks only the email today).
- **On screen:**
  - **Session ended** (the 12 h limit, or revoked by the server) shows over the current task without unmounting it. Badging back in as the same operator returns to it. The queue is kept.
  - A warning appears 30 minutes before the 12 h limit.
  - Locked and rate-limited messages show the minutes remaining.

*Web and portal*
- **No refresh-ahead timer.** A request whose access token has expired refreshes first; a 401 `token-expired` refreshes once and retries a **clone** of the request (same Idempotency-Key).
- Refresh is serialised across tabs with `navigator.locks`, re-reading storage after the lock is taken.
- The sign-in, refresh and sign-out calls never trigger a refresh.
- **Stored session:**
  - `StoredSession` adds `refreshUntil`. `readSession` stays pure and treats an expired access token as refreshable, not signed out.
  - The hint cookie's Max-Age follows `refreshUntil`.
  - The shells refresh before deciding to route to /login.
- **Signed out:** `session-ended` clears the session and /login shows the reason. The login copy "Sessions last 15 minutes" is removed (`login/page.tsx:23`). Sign-out calls the server.
- **Team card:**
  - A Status column that shows Deactivated. Today anything not `invited` reads Active (`users-card.tsx:112`).
  - Deactivate and Reactivate through a confirmation row.
  - Unlock when `lockedUntil` is set.
- **Devices card:** Unlock and Release device.
- Both cards read the role through the session subscription (the frontend guide gotcha).
- Copy lives in each form's own reason map. There is no shared map.

*Zero scan loss*
- Every session end keeps queued scans: expiry, deactivation, revoke, lockout, badge-out refusal and operator change. They either replay under their own creator or go to web review.

**Never:**
- No 2FA (6.1b) and no password or PIN reset (needs email, 5.1).
- No SSO.
- No refresh token in `localStorage`.
- No in-memory counters.
- No change to the replay fate table beyond the `reason`-carrying 401 and `operator-mismatch` → retained.

## I/O & Edge-Case Matrix

| Scenario | State | Expected |
|---|---|---|
| Web user active 20 min, or a tab reopened after a laptop sleep | Access token expired, refresh valid | Refresh before the request or route; the user notices nothing |
| Two tabs refresh at once | Same rotating token | The second gets the current pair (30 s grace); no sign-out |
| Idle 2 h | — | 401 `session-ended` `idle` → /login "Signed out after 2 hours of inactivity" |
| Owner deactivates Ravi | Ravi has a tab open, a handheld badged in, and 3 queued scans | Web → /login "Your account has been deactivated". Handheld → Session ended. His scans go to web review under his name, and the next operator never replays them |
| Stolen refresh token used after rotation | More than 30 s later | Session revoked `refresh-reuse`; both holders signed out |
| 5 wrong passwords from one IP | Real or unknown email | 6th → 423 `sign-in-locked` for that email from that IP only; identical for an unknown email; the owner signs in from elsewhere |
| 5 wrong PINs on HH-07 | Any operator emails | HH-07 badge-in locked 15 min; supervisor Unlock |
| 30 operators badge in at 07:00 behind one NAT | — | All succeed (limit is per device) |
| Badge out with queued scans | — | Refused on the device; supervisor Release device if the operator has left |
| Handheld on today's app after the backend deploys | Session expired | 401 `unauthenticated` (+ `reason`) → scans stay queued |
| Device enrolled 20 days before the deploy | Legacy credential, no `kind` | Badge-in works, and the credential renews |
| Last active owner deactivates self | — | 409 `last-owner` |
| Offline badge-in with a wrong PIN | Cached session | Refused; counts toward the local lock |

</frozen-after-approval>

## Code Map

**wms-be**
- `src/modules/tenancy/jwt-session.ts`:
  - signers `:58` (web/portal), `:183` (device), `:193` (badge); verifiers `:125-140`, `:252-262`.
  - TTLs `:11` and `:21`.
  - Add `kind` and `sid`, plus a separate badge TTL.
- `src/modules/tenancy/tenant-session.guard.ts:27`, `any-session.guard.ts:58`, `device-session.guard.ts:33`, `src/modules/clients/portal-session.guard.ts:49` (already reads the user and client per request; extend it to the session row).
- `src/modules/tenancy/sign-in.command.ts:57`: the lockout, the session row, the refresh cookie. `passwords.ts:39` `DUMMY_HASH` keeps the timing uniform.
- `src/modules/tenancy/enrollment.command.ts`: badge-in `:547` (PIN check `:568`, binding rule `:513-516`), revoke `:624`. Add badge-out, the PIN lockout and credential renewal.
- `src/modules/tenancy/users.command.ts` and `users.controller.ts` (`:139` PATCH role): deactivate and reactivate, and session revocation on a role change.
- `src/modules/clients/clients.command.ts` `updateStatus`: revoke portal sessions on suspend.
- `src/shared/db/schema.ts:80` `USER_STATUSES`; `users` (`:113` area) and `devices` lockout columns; new `sessions` table + migration.
- `src/app.factory.ts:23-29`: CORS `credentials: true`, and cookie parsing for the refresh route.
- More backend files:
  - `src/shared/primitives/audit.ts:111` `AUDIT_NEW_ACTIONS`;
  - `src/modules/tenancy/tenancy.dto.ts:259` (second `USER_STATUSES`) → `src/api/portal.dto.ts:88`;
  - `users.command.ts:394-410` (last-owner guard; count active only), `:529` (accept-invite requires `invited`);
  - `provision-roles.sql` (`wms_auth` is BYPASSRLS, `:6-7,32`);
  - `clients.command.ts:403` (the `arm` hash pattern).
- **A test helper `mintSessionToken(...)`** inserts the session row. There are 8 `signTenantSession(` call sites in 5 suites, plus the local-dev runbook.
- Tests: `test/tenancy.spec.ts:303,488`, `test/users.spec.ts`, `test/devices.spec.ts:262,437,541,600`, `test/portal.spec.ts:605-720`, `test/review-reports.spec.ts:495`. Add a new `test/sessions.spec.ts`.

**wms-fe**
- `src/lib/auth.ts`:
  - `StoredSession` `:59-70`, `readSession` `:93` (keep it pure);
  - expiry timer `:141-152`: replace hard expiry with refresh-ahead.
- `src/lib/api/client.ts`: request interceptor `:384-394`, the 401 interceptor `:401-406` (refresh once, then clear with a reason), `fetchApiSignIn` `:542` (now `credentials: 'include'`).
- `src/components/auth/sign-out.tsx:27`: call the server. `auth-forms.tsx:287-308` `rejectionReason`: add `account-locked`, `rate-limited`, `session-ended`.
- `src/app/(auth)/login/page.tsx:16-25` `loginNotice`: the signed-out reasons. Shells: `app-shell.tsx:32-42`, `portal-shell.tsx:30-56`.
- Settings `users-card.tsx` (`:112` the status display): status, deactivate/reactivate, unlock. `devices-card.tsx`: unlock and release. Both read the role through `useSyncExternalStore`.
- `src/proxy.ts:20-39`: the hint cookie gate (Max-Age follows `refreshUntil`).
- Tests: `lib/auth.test.ts:185-284`, `lib/api/client.test.ts:406-417`, `auth-forms.test.tsx`, `users-card.test.tsx`, `portal.test.tsx:230-245`.

**wms-mobile**
- `src/state/device-store.ts`:
  - `BadgeSession` `:40-44`, badgeIn `:174-187`, expiry check `:122,205-219`;
  - replay `:382-394`, `markRevoked` `:445`, `reset` `:450`.
  - Add the `session-ended` phase, badgeOut, and storage of the renewed credential (`device-token` secret, `:155`).
- `src/state/replay-classification.ts:57-60`: 401 `session-ended` → queued + phase `session-ended`.
- `app/badge-in.tsx:40-52`: locked and rate-limited copy. A new screen for session-ended, or reuse badge-in with a notice. A Badge out action in the task shell.
- `src/api.ts:61-90,139-149`: the badge-out call, reading the renewed credential.
- More handheld files:
  - `src/offline/engine.ts:125` (rejected ops dropped), `:226-247` (the strand/retained path, reused for operator change);
  - `src/api.ts:108-114` (`BadgeInResponse`), `:168-195` (push registration);
  - `app/index.tsx:21-34` (phase routing: show session-ended as an overlay, not a re-route).
- Tests: `src/offline/engine.test.ts` (`:71,426,625`), `replay-classification.test.ts`, `device-store.test.ts`, `api.test.ts`.

## Tasks & Acceptance

**Execution:**
- [x] wms-be: migration (`sessions`, user status `deactivated`, lockout columns) → token `kind`/`sid` → guards → sign-in lockout + refresh + sign-out routes → deactivate/reactivate/unlock → badge-in lockout, renewal, badge-out → role-change and suspend revocation → OpenAPI export. Each route gets cases in `test/sessions.spec.ts` / `users.spec.ts` / `devices.spec.ts` covering every matrix row.
- [x] wms-fe: regenerate the client → refresh-once interceptor and refresh-ahead → server sign-out → signed-out reasons → Team/Devices card actions → tests.
- [x] wms-mobile: session-ended phase and screen → lockout copy → badge-out → credential renewal → tests (queue kept across session-ended, badge-out refused with queued ops).
- [x] meta: close PENDING #1 as "closed by 21-7", PENDING :142 (PIN lockout) and :148 (portal revocation); record the 6.2 domain constraint; update `tenancy.md` (sessions, kinds, lockout), the API surface, and the frontend and mobile design docs.

**Acceptance Criteria:**
- Given any revoke path (sign-out, deactivate, role change, client suspend, device revoke), when the affected token is used again, then it answers 401 `session-ended` (403 `device-revoked` / `client-suspended` where those already apply) without waiting for expiry.
- Given a handheld with queued scans whose session ends, when the operator badges in again, then every queued scan replays and none is lost.

## Design Notes

**Why server-side sessions and not a denylist.** Every guard except the portal one trusts the token alone (`tenant-session.guard.ts:27` reads nothing). A row read per request is one indexed lookup on a table bounded by the number of active sessions. It makes revocation immediate and gives one place for idle and absolute limits. The portal guard already pays this cost.

**Why badge-out needs an empty queue.** Replay authenticates with the *current* badge session (`device-store.ts:382-394`). The creator's session is used only for attribution text. Letting operator B inherit A's queue would post A's scans under B's authority.

**Why Postgres for lockout.** Valkey's client is reservation-specific (`shared/valkey/valkey.client.ts:31`), and a Valkey outage would silently disable lockout (fail-open) or block every sign-in (fail-closed). Two columns per row survive restarts and need no new dependency.

**Why the 401 code stays `unauthenticated` on devices.** Handhelds update later than the backend. The field build drops any unknown 401 code as a refusal (`replay-classification.ts:147`), so a new code would delete queued scans on deploy day. A `reason` field is additive.

## Verification

**Commands:**
- wms-be: `bun run test -- test/sessions.spec.ts`, then the full `bun run test`, `bun run lint`, `bun run typecheck`, and the OpenAPI export plus drift check.
- wms-fe: `bun test && bun run typecheck && bun run lint && bun run build`.
- wms-mobile: `bun test && bun run typecheck && bun run lint`.

**Manual checks:**
- Live: sign in on the web and stay active for 20 minutes without being signed out.
- Deactivate a user while their tab is open and see the reason on /login.
- Lock an account with 5 wrong passwords, then unlock it as owner.
- Open two tabs, wait 16 minutes, then click in both: no sign-out.
- Badge in on a handheld, then deactivate the operator: the session-ended screen appears and the queued scans reach web review.

## Implementation Notes

**How it was built.** Four implementation sub-agents stalled (no output for 600 s — the spec plus nine context docs), two of them after partial work: the 0074 migration, the token rewrite, and the handheld's `session.ts` / `offline-pin.ts` / API plumbing. That work was reviewed and kept; the rest was implemented directly in the main session (the workflow's no-subagent fallback), committing per step.

**wms-be** (`feat/6-1a-secure-sessions`): `sessions.ts` (store, `checkSessionInTx`, `revokeSessionsInTx`, refresh rotation with the 30 s grace, purge); `auth-attempts.ts` (counted-before-scrypt lockout, attempt windows, `clientIpOf` with `TRUSTED_PROXY_HOPS`); `session-cookie.ts` (cookie, Origin + `X-WMS-Session`, the 401 shapes); `session.command.ts` + routes `session/refresh`, `session/sign-out`; all four guards re-read the session (`verifyWebRequest`, `verifyDeviceRequest`); badge-in lockout / 12 h session / credential renewal; badge-out, release, device unlock; users deactivate / reactivate / unlock; role-change and client-suspend revocation; `SessionPurgeWorker`; `bun run auth:unlock`.
- **Decisions taken in implementation** (none user-visible beyond the spec):
  - A badge session revoked by **device revoke** answers the existing `403 device-revoked`, not the 401 — the handheld quarantines on that code (fate table). Found by `test/devices.spec.ts`.
  - A portal session revoked by **client suspend** answers `401 session-ended` `client-suspended`, and stays ended after reactivation (sign in again). The portal guard's per-request client read still answers `403 client-suspended` for a suspension made outside the command (SQL). `test/clients.spec.ts` updated to the new contract.
  - A role change revokes the target's **web** sessions only when the role actually changed.
  - A re-badge on the same device ends the previous badge session as `released`.
  - Two no-op arms declared to the audit guard: `users.deactivate:already-deactivated`, `users.reactivate:not-deactivated`.
- Existing suites updated for the new contract: token pins (`portal.spec.ts`), expiry (`tenancy.spec.ts`), role change (`users.spec.ts`), suspend (`clients.spec.ts`), fence tokens (`audit-*`, `notifications.spec.ts`), the cookie routes allowlisted in the guard-coverage test, and `picking.spec.ts`'s SQL un-revoke also revives the badge session.

**wms-fe:** `session-refresh.ts` (single-flight + `navigator.locks`, plain `fetch`), `api/base-url.ts`; `auth.ts` (`refreshUntil`, `sessionEndsAt`, `accessTokenExpired`, `clearSession(reason)`, `signedOutLoginHref`); client interceptors (refresh-before, retry-once on `token-expired` from a pre-send clone, `session-ended` → reason); login notices (`SESSION_ENDED_NOTICE`); server sign-out; Team card (status chips, Deactivate / Reactivate / Unlock via `ConfirmRow`, role through the subscription); Devices card (Badge-in locked, Unlock, Release device). Tests: `session-refresh.test.ts` (11), `session-admin.test.tsx` (7).

**wms-mobile:** `device-store.ts` (`sessionEnded` with the phase kept `badged`, renewed credential written first, PIN verifier, offline restore under the local lock, `badgeOut`, creator id at enqueue, replay passes `currentOperatorId`, a 401 → `markSessionEnded`); `engine.ts` (A4 hold, code `operator-changed`); `replay-classification.ts` (`operator-mismatch` → quarantined, `sessionEndFromError`); `components/session-overlay.tsx` mounted in `_layout.tsx`; Badge out in the inbox; badge-in copy from `session.ts`. New dependency `@noble/hashes` (pure-JS scrypt for Hermes). Tests: `secure-sessions.test.ts` (13), `device-store-sessions.test.ts` (6).

**meta:** PENDING (#1 closed by 21-7; :142 PIN lockout and :148 portal revocation closed; six new entries), `tenancy.md` *Sessions*, API surface, frontend and mobile designs, the three repo contracts.


## Spec Change Log

## Review Triage Log

### Design review — 2026-10-18 (3 reviewers: security, handheld/offline, web/data/checklists; 37 raw → 25 after dedup)

| # | Finding (reviewers) | Verdict | Disposition |
|---|---|---|---|
| D1 | A new 401 code on device routes makes field handhelds drop queued scans (`replay-classification.ts:57-60,147`; `engine.ts:125`) (all 3) | high — verified | Device and badge routes keep 401 `unauthenticated` and add a `reason` field |
| D2 | Requiring `kind` cuts off every enrolled handheld, whose 30-day credentials have none (`jwt-session.ts:21,183`) (all 3) | high | Legacy shapes accepted for one TTL, pinned by tests |
| D3 | Deactivation releases the binding, so the next operator replays the leaver's queue under their own authority (`enrollment.command.ts:569-572`, `device-store.ts:382-395`) (2) | high | A4: different-creator ops go to retained/web review; the server checks `X-Op-Operator` → 409 `operator-mismatch` |
| D4 | Lockout counters written in the badge-in/sign-in transaction roll back on the throw (`enrollment.command.ts:573`); `AUTH_DATABASE` is read-only by convention; check-then-scrypt race (sec) | high | Own committed transaction, atomic `UPDATE … RETURNING` before scrypt |
| D5 | A single `refresh_hash` cannot detect reuse; the refresh lookup's connection is unnamed (sec) | high | Cookie `<sid>.<secret>` + `prev_refresh_hash` + `FOR UPDATE`; `AUTH_DATABASE` named for cookie-only paths |
| D6 | Multi-tab refresh races revoke the family and sign the user out everywhere (sec, web) | high | 30 s grace returns the current pair; `navigator.locks` on the web |
| D7 | A tab reopened after 15 min signs out: `readSession` nulls on access expiry (`auth.ts:113`), and the hint cookie dies with it (`proxy.ts:39`) (web) | high | `refreshUntil`; expired access = refreshable; hint Max-Age; refresh before routing |
| D8 | A refresh-ahead timer keeps sessions alive forever, so the idle limit never fires (web) | high | No timer; only guarded requests extend idle |
| D9 | "Session-ended by access expiry" cannot be told apart on the wire; there is no reason source for the shell copy (web, handheld) | high | 401 `token-expired` vs `session-ended` + `reason` |
| D10 | Which connection reads `sessions` is unstated; the e2e suite does not enforce RLS (guide §5) (web) | high | Named per path; `wms_rls_probe` test; indexes listed |
| D11 | PIN lockout per (device, operator) contradicts the per-device columns and lets an attacker rotate emails; the PIN belongs to the device (`schema.ts:1808`) (all 3) | high | A1: per device (needs user confirmation) |
| D12 | The per-IP limit of 20/min refuses a warehouse's shift change behind one NAT; there is no trusted-proxy handling (grep: none) (all 3) | high | A2: badge-in per device; sign-in per IP at 300/min with a trusted-hop config; stored in Postgres (needs user confirmation) |
| D13 | Offline badge restore never checks the PIN (`device-store.ts:204-216`) — verified | high | Local slow-hash PIN verifier + local lock; no restore after a session end or badge-out |
| D14 | 423 vs 401 reveals real emails (sec) | medium | A3: counters keyed on (email hash, IP) for any email |
| D15 | Owner-lockout denial of service; with every owner locked nobody can unlock (sec) | medium | A3: per (email, IP) + CLI unlock |
| D16 | Badge-out "with an empty queue" is unenforceable offline; the device deadlocks when the operator leaves (handheld) | high | Enforced on the device; A5 supervisor Release device |
| D17 | Last-owner guard counts deactivated owners (`users.command.ts:394-410`); reactivate `last-owner` is meaningless (sec) | medium | Active owners only; self-deactivate rule; dropped from reactivate |
| D18 | Reactivating an invited user strands them (`users.command.ts:529`) (sec) | medium | `status_before_deactivation`; fresh invite token |
| D19 | Cookie scoped to the refresh path never reaches sign-out; CSRF beyond SameSite; no cookie parser; `Secure` on localhost; public-suffix hosting (sec, web) | medium | Path `/api/v1/tenants/session`; Origin + `X-WMS-Session`; parser; `COOKIE_SECURE`; 6.2 constraint |
| D20 | `USER_STATUSES` has two copies; no status CHECK exists today (a new CHECK on live rows); Team card shows non-invited as Active (`users-card.tsx:112`) (web) | medium | Both copies; new CHECK with pre-flight and pin; status display |
| D21 | `lockedUntil` on `UserResponse` breaks stored invite replays; deactivate/reactivate need an `arm` hash; unlock routes, capabilities and audit vocabulary unspecified (web) | medium | Optional on the list DTO; `arm`; routes and capabilities named; `AUDIT_NEW_ACTIONS` + `UserAction` |
| D22 | Push registrations survive badge-out and deactivation (`api.ts:168-195`); the session-ended screen would unmount the task (`index.tsx:21-34`) (handheld) | medium | Deleted on both; overlay keeps the task; 30-min warning |
| D23 | Credential renewal contract and failure rules unstated (`api.ts:108-114`) (handheld) | medium | `deviceToken` fields; old credential stays valid; write before session; never fail badge-in |
| D24 | `last_used_at` write amplification; two clocks (sec) | low | Conditional update; DB `now()` only |
| D25 | No purge of session rows; hand-minted tokens break in 5 suites and the runbook; "shared problem-code map" does not exist; client suspend needs a seam; PENDING :142/:148 also close (web) | low | Purge job; `mintSessionToken` helper; per-form maps; `revokeSessionsInTx`; PENDING rows listed |
