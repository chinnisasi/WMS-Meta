---
title: '6.1b Owner two-factor sign-in — authenticator-app codes and backup codes on the web'
type: 'feature'
created: '2026-10-18'
status: 'done'
baseline_commit: 'c13ceb613f6e4fdfc328b984eeb6fb2f11913085'  # wms-be; wms-fe: 448eec99dfbdc9273cbd17fb1ad05bd38423f858 (branches feat/6-1b-owner-two-factor-sign-in)
route: 'dispatch'
review_loop_iteration: 0
context:
  - 'docs/initiatives/production-readiness.md'
  - 'docs/design/SYSTEM-DESIGN.md'
  - 'docs/design/IMPLEMENTATION-GUIDE.md'
  - 'docs/design/modules/tenancy.md'
  - 'docs/design/frontend/SYSTEM-DESIGN.md'
  - 'docs/design/frontend/IMPLEMENTATION-GUIDE.md'
  - '_bmad-output/implementation-artifacts/spec-6-1a-secure-sessions.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** An owner's account is guarded by a password alone. An owner can export the whole audit trail, approve stock adjustments, invite and remove staff, and reset devices, so a phished or reused password gives an attacker the whole tenant. The architecture security review (S-7) asked for owner MFA to be an explicit decision, and deferred-work (2026-10-18) split it out of 6.1 as 6.1b.

**Approach:** Add a second step to web sign-in using an authenticator app (RFC 6238 TOTP), with single-use backup codes for a lost phone.
- After the right password, an enrolled user is asked for a 6-digit code before any session exists.
- An owner who hasn't enrolled yet gets the enrolment step instead, also before any session exists.
- Signed-in staff get a **My account → Security** page.
- Another owner can reset a colleague's 2FA, handing over a one-time enrolment code; a CLI covers the sole owner.
- The portal and the handheld are untouched.

**Decisions (user, 2026-10-18):**
1. **Owners must use 2FA; every other web staff role (`ops_manager`, `operator`, `accountant`) may opt in.** `secondFactorRequired(role)` is `role === 'owner'`. Every owner enrols at their first sign-in after the deploy.
2. **No "remember this browser".** A web session already lasts up to 12 h.
3. **One story**, kept whole over the 1,600-token guideline.
4. **Owner badge-in stays allowed** (design review S3). A badge session is fenced off every web route (`tenant-session.guard.ts:74`) and reaches only floor commands. The accepted risk is recorded in Design Notes and `tenancy.md`, and the handheld is unchanged.
5. **Enrolment after a reset needs a one-time enrolment code** (design review S4).
   - The reset (web or CLI) returns an 8-character code valid for 72 h, which the resetting owner hands over in person.
   - The first enrolment after the deploy, and after a promotion to owner, needs no code. Today's sign-in is password-only, so this is no weaker.
   - It is audited with the client IP and visible to other owners.

## Boundaries & Constraints

**Always:**

*The sign-in branch*
- **`POST /tenants/sign-in` is unchanged up to `clearSignInAttempts`** (`sign-in.command.ts:152`).
- **No second factor needed** (not enrolled and not required): the body is byte-identical to today's `SignInResponse`.
- **Enrolled user:** 200 `TotpChallengeResponse { challenge: 'totp', challengeToken, expiresInSeconds: 300 }`.
- **Required but not enrolled:** 200 `EnrollChallengeResponse { challenge: 'enroll', challengeToken, expiresInSeconds: 600, secret, otpauthUri, enrolmentCodeRequired }`.
- **Both challenge arms** create no session row and set no cookie.
- **The pending secret is reused:** `users.mfa_pending_secret_sealed` / `mfa_pending_created_at` is kept for 24 h. A second enrolment challenge (re-sign-in, another tab) shows the **same** QR code, so an app that scanned the first one still works.
- **OpenAPI:** three schemas in a plain `oneOf` (`@ApiExtraModels`). Each challenge DTO has a required `challenge` enum; the web narrows with `Object.hasOwn(body, 'challenge')`.
- **Deploy skew:** the new web sends `X-WMS-Second-Factor: 1` on sign-in. When a challenge would be issued and that header is absent, the answer is 409 `client-outdated` ("Reload this page to sign in"). An open tab with an old bundle therefore never writes a broken session.

*`sign_in_challenges` (migration 0075, RLS on `tenant_id`)*
- **Columns:** `id`, `tenant_id`, `user_id`, `purpose` (`totp|enroll`), `secret_hash`, `enabled_at_seen?` (the user's `mfa_enabled_at` when it was issued), `failures`, `ip`, `created_at`, `expires_at`, `consumed_at?`.
- **Token:** `<id>.<secret>`, where the secret comes from `newSecret()` (`sessions.ts:104`), the hash is sha256, and the comparison is constant-time. It is not bound to the IP; the IP is kept for the audit.
- **CHECKs:** the `purpose` vocabulary; `failures` between 0 and 5; `expires_at > created_at`; `(purpose = 'totp') = (enabled_at_seen IS NOT NULL)`.
- **Indexes:** `(expires_at)` for the purge; `(tenant_id, user_id) WHERE consumed_at IS NULL`.
- **Lookup:** by id on `AUTH_DATABASE` (tenant and user), as `sessionTenantOf` does. Every write runs in that tenant's transaction.
- **Clearing open challenges.** Any change to a user's 2FA or status deletes their open challenges: reset, disable, confirm, deactivation, a role change.

*Verifying a code — one function for every route that takes one*

`verifySecondFactorInput(user, input, purpose)` is shared by the sign-in step and every self-service route. It runs in this order:

1. **Rate limit.** `hitRateLimit` per IP.
2. **tx1, committed before any check** (the `countBadgeInAttemptInTx` precedent, `auth-attempts.ts:173-178`):
   - Lock the challenge `FOR UPDATE`, when one is involved.
   - Validate the challenge. Unknown, wrong secret, expired, consumed or `failures ≥ 5` → 401 `challenge-ended`.
   - Check the user lock. `mfa_locked_until > now()` → 423 `second-factor-locked` with `retryAfterSeconds`.
   - Increment `challenge.failures` and `users.mfa_failures`. The 5th consecutive failure sets the lock; escalation is below.
   - Commit.
3. **Check the code with no transaction open.**
   - Open the sealed secret and accept a TOTP code at steps t−1, t or t+1.
   - Where a backup code is allowed, accept one of the user's unused codes.
   - Wrong → the count already stands. On the sign-in step, answer 401 `second-factor-invalid` with `attemptsLeft`. On self-service routes, answer **422** `second-factor-invalid`, because a 401 would sign the web user out (`client.ts:440-466`).
4. **tx2:**
   - Lock the user `FOR UPDATE`, then the challenge.
   - Re-check `consumed_at IS NULL` and `status = 'active'`.
   - For `totp`, check `mfa_enabled_at = enabled_at_seen`. For `enroll`, check `mfa_enabled_at IS NULL`. Any mismatch → 401 `challenge-ended`.
   - Advance `mfa_last_step` to the **matched** step: `… WHERE mfa_last_step IS NULL OR mfa_last_step < $matched`. 0 rows → `second-factor-invalid`, a reuse.
   - Or spend the backup code: `UPDATE … SET used_at = now() WHERE used_at IS NULL RETURNING`, audited `user.backup_code_used`.
   - Consume the challenge.
   - Reset `mfa_failures` and `mfa_lock_cycles` to 0.
   - Then do the route's work.

**Escalating lockout.**
- Each lock lasts 15 min and increments `mfa_lock_cycles`. The **3rd** consecutive cycle without a success sets `mfa_locked_until = 'infinity'`, which only an owner's Unlock or the CLI clears.
- Each new lock is audited once, as `user.second_factor_locked` (actor the system, reference `ip:<address>`).
- `users.mfa_failed_since_success` counts every wrong code since the last success. The successful response carries it as an optional `secondFactorFailedAttempts`, and the web shows "N failed two-factor attempts since your last sign-in".

**Unlock.**
- A new `clearSecondFactorLockInTx(tx, tenantId, userId)` is called inside the existing `unlockUser` transaction (`users.command.ts:792-818`, which deletes `signin_attempts` inline) and by `auth:unlock` inside `withTenantTransaction`. It is never called on a bare `db`, because RLS would match 0 rows.
- The list DTO's `lockedUntil` becomes the later of the sign-in lock and the 2FA lock.

*`POST /tenants/sign-in/second-factor { challengeToken, code, enrolmentCode? }`* (not keyed: it issues a credential)
- **`totp`:** verify as above (TOTP or a backup code), then `issueWebSession`. The 6.1a session creation is extracted from `sign-in.command.ts:156-188`.
- **`enroll`:**
  - **TOTP code only:** no backup code exists yet.
  - **Enrolment code:** when the user holds one (`users.mfa_enrol_code_hash`, unexpired), `enrolmentCode` must match it. A wrong or missing code counts as a wrong code.
  - **tx2 then:** seals the pending secret as the user's secret, sets `mfa_enabled_at`, clears the pending secret and the enrolment code, creates 10 backup codes, issues the session and audits `user.second_factor_enabled` (reference `challenge:<id>@<ip>`).
  - **The response** carries `backupCodes`. This is the only time they appear.

*TOTP and secrets*
- **Algorithm:** SHA-1, 6 digits, a 30 s step, 20-byte base32 secret. The `otpauthUri` issuer is `WMS (<tenant name>)` and the label is the email. Built on `node:crypto` HMAC with no new backend dependency, and tested against the RFC 6238 vectors. The TOTP function is exported for the scripts and tests.
- **`second-factor-secrets.ts` is the only reader of `MFA_ENCRYPTION_KEY`** (an architecture pin; tenancy's `envelope` importers are exactly `enrollment.command.ts` and this file).
  - It seals with AES-256-GCM, with **associated data** `tenant_id:user_id`, so a secret copied to another row will not open.
  - The format carries a key id. `MFA_ENCRYPTION_KEY_PREVIOUS`, when set, still opens old blobs while the key rotates.
  - **The app refuses to boot when `MFA_ENCRYPTION_KEY` is missing or under 32 characters** (guide §8's fail-the-boot rule). Without the key, every owner would be locked out on deploy day.
- **Backup codes:** 10 per set, 10 base32 characters shown as `XXXXX-XXXXX`. Input is case-insensitive and ignores hyphens and spaces.
  - **Storage:** `user_backup_codes(id, tenant_id, user_id, code_hash, used_at?, created_at)`, with RLS. The hash is HMAC-SHA256 under a pepper derived from the key (HKDF info `backup-codes`) over `user_id || code`.
  - **Constraints:** unique `(user_id, code_hash)`; index `(user_id) WHERE used_at IS NULL`.
  - **Replacement:** a set is replaced whole, never appended to.

*My account → Security* (routes `/tenants/{t}/me/second-factor[/…]`, matching GET `:tenantId/me` at `users.controller.ts:277`; the caller acts only on themselves; staff web sessions only)
- **Why not keyed:** the responses carry secrets or backup codes. A lost response is recovered by regenerating.
- **`GET`** answers `{ enabled, enabledAt, required, backupCodesRemaining }`.
- **`POST …/setup`** answers `{ secret, otpauthUri }` and stores the pending secret.
  - When 2FA is off, it needs the current **password**. A wrong password counts on `signin_attempts` (email, IP), as at sign-in, and answers 422 `password-invalid`.
  - When 2FA is on, it needs a current **code** (a TOTP or a backup code) through the shared verifier.
- **`POST …/confirm { code }`** checks the code against the pending secret, then:
  - makes the pending secret the active one;
  - sets `mfa_last_step` to the matched step **unconditionally** (a new secret starts its own sequence);
  - replaces the backup codes and returns them;
  - audits `user.second_factor_enabled`.
- **`POST …/backup-codes { code }`** regenerates the codes and audits `user.backup_codes_regenerated`.
- **`POST …/disable { code }`** turns 2FA off and audits `user.second_factor_disabled`. If 2FA is required for the user, the answer is 409 `second-factor-required`.
- **Other sessions end.** confirm (when replacing), disable and backup-codes revoke the user's **other** web sessions with the new reason `second-factor-changed`. The caller's own session stays.
- **The self-service audit reference** is a fresh uuidv7 per call.

*Reset by another owner*

`POST /tenants/{t}/users/{id}/second-factor/reset` uses `users.role_change`, is idempotency-keyed (`arm: 'second-factor-reset'`), and runs in this order:

1. `assertPermission`.
2. Replay.
3. Lock the target `FOR UPDATE`; an unknown target is 404.
4. Replay again, under the lock.
5. Self-target → 409 `self-reset`.
6. No 2FA and no pending enrolment code → a no-op that stores the key (`AUDIT_NO_OP_ARMS` `users.resetSecondFactor:not-enrolled`).
7. Clear the secret, the pending secret, the backup codes, the counters and the open challenges, and set a new enrolment code (sha256 hash; 72 h).
8. Revoke the target's web sessions as `second-factor-reset`.
9. Audit `user.second_factor_reset` (reference = the key).
10. Store the key.

- **Response:** `{ enrolmentCode, enrolmentCodeExpiresAt }`. The snapshot carries the code, as the invite response carries its token (`users.command.ts:314`). It is short-lived and useless without the password.
- **Tests:** a `raceTwice` / `waitParked` test.
- **CLI:** `bun run auth:reset-2fa <email>` (modelled on `scripts/auth-unlock.ts`) prints the enrolment code and audits with the system as actor and reference `cli`.

*Vocabularies*
- `SESSION_REVOKE_REASONS` (`sessions.ts:27`) and its CHECK gain `second-factor-reset` and `second-factor-changed`, as do `SESSION_END_DETAIL` (`session-cookie.ts:115`) and the web's `SESSION_ENDED_NOTICE`.
- The CHECK is re-added on `sessions`, which takes a brief exclusive lock and a scan. The table holds only live sessions and those ended within 30 days, which is acceptable at deploy.
- **Six actions** go into both `SecurityAuditAction` (`sessions.ts:70`) and `AUDIT_NEW_ACTIONS` (`audit.ts:111`), each pinned by `expectAuditRow`:
  - `user.second_factor_enabled`
  - `user.second_factor_disabled`
  - `user.backup_codes_regenerated`
  - `user.backup_code_used`
  - `user.second_factor_locked`
  - `user.second_factor_reset`

*Purge* — `SessionPurgeWorker.tick` (`jobs.module.ts`) gains its own block. It finds tenants with challenges through `AUTH_DATABASE`, uses a try/catch per tenant, deletes challenges that expired over a day ago, and clears pending secrets older than 24 h.

*Web*
- **Session routes.** `isSessionRoute` (`client.ts:396-398`) gains `sign-in/second-factor`. `writeSession` refuses a body without a string token or a finite expiry.
- **The login form two-step** (`auth-forms.tsx:140-156`) switches in place.
  - **On entering step two:**
    - the email is kept and the password cleared;
    - an `aria-live` region announces the step;
    - the `?ended=` banner hides.
  - **`totp` step:**
    - a 6-digit input with `autoComplete="one-time-code"`, `inputMode="numeric"`, spaces stripped, and autofocus;
    - "Use a backup code" switches to text input (`autoCapitalize="characters"`, hyphens accepted);
    - "N attempts left" is shown.
  - **`enroll` step:**
    - the QR code with `role="img"` and an `aria-label`;
    - the secret in groups of four, with Copy and a "Copied" message in `aria-live`;
    - "Expires in m:ss";
    - the enrolment-code field when `enrolmentCodeRequired`;
    - then the code.
  - **When the challenge ends** (on the client at `expiresInSeconds`, or on a `challenge-ended` from the server), the form returns to the password step with "Sign in again" and focus on the password.
- **Backup codes** come from one shared `BackupCodesPanel`, used at enrolment and on Security.
  - It offers Copy and Download (the existing `downloadText`, `lib/csv.ts:38`).
  - The Continue button stays disabled until "I've saved these codes" (a real labelled checkbox) is ticked, and a `beforeunload` guard warns while the codes are not yet acknowledged.
  - **`writeSession` and the redirect run only on Continue.** Until then the access token is held in component state.
- **`qrcode`** is added pinned (`bun add -E qrcode`, `bun add -d -E @types/qrcode`), loaded with `import()` in the enrolment step only. It is rendered from `QRCode.create(uri).modules` into React `<rect>`s, never as inner HTML, and the URI never leaves the browser.
- **The Security page** is `/account/security` under `(app)`, so portal users never reach it (`portal.ts:54-60`); a test pins that.
  - The link sits beside both Sign out mounts (`sidebar.tsx:67-70`, compact at icon width, and `app-shell.tsx:121-124`).
  - Replace runs: the current code, then the QR code, then the confirm code, then the codes panel.
  - Turn off is hidden when 2FA is required.
  - A warning shows at 2 or fewer codes left, including 0.
- **Team card** (`users-card.tsx`; the role subscription is at `:85`).
  - The "2FA On/Off" chip shows only to `canChangeRole`, and not at all when the field is undefined.
  - Reset 2FA appears when `canChangeRole && !isSelf && secondFactorEnabled === true`.
  - The reset result shows the enrolment code once, with Copy.
  - The list DTO's `secondFactorEnabled` is optional (the snapshot rule).
- **Copy** lives in `src/lib/second-factor.ts`: `secondFactorReason` (with tests) for `second-factor-invalid`, `second-factor-locked`, `challenge-ended`, `client-outdated`, `password-invalid` and `second-factor-required`; an unknown `challenge` value → "Reload this page"; the notices "An owner reset your two-factor sign-in — sign in and set it up again." and "Your two-factor settings changed on another device — sign in again."

*Tests and scripts*
- **`test/support/sign-in.ts`:**
  - `mintSessionToken({ tenantId, userId, kind })` uses `withTenantTransaction` + `createSessionInTx` + `signTenantSession`. Every suite that needs a session but isn't testing sign-in uses it. The negative-path hand-mints stay.
  - `signInAs(app, email, password)` completes any challenge with the exported TOTP (secret cached per email), and waits for the next step when the current one is spent. It is used only where sign-in itself is under test.
- **Retargeted tests (guide §4):** body-shape tests that assert an owner's sign-in body (`tenancy.spec.ts:303`, `users.spec.ts:255`) are explicitly retargeted to the two-step flow.
- **Scripts:** `seed-demo.ts` and the `loadtest-*` scripts use a `scripts/lib` helper on the exported TOTP. `seed-demo` prints the owner's `otpauthUri` and backup codes beside the password (`:1143`).
- **`test/second-factor.spec.ts`** covers every matrix row, the RFC vectors, the AAD and key-id cases, the migration probes and `wms_rls_probe` on both new tables and the `users` writes.

**Never:**
- No 2FA for portal users or on the handheld (decision 4).
- No SMS or email codes (there is no mailer; that is 5.1), no WebAuthn, and no "remember this browser".
- No second factor on refresh.
- No secret or backup code in logs, audit rows, `idempotency_keys` or any later response. The reset's enrolment code follows the invite-token precedent instead.
- No test-only bypass flag or injectable clock in production code.

## I/O & Edge-Case Matrix

| Scenario | State | Expected |
|---|---|---|
| Enrolled owner, right password then right code | — | 200 challenge, then 200 session + cookie |
| Same code twice (replay or two tabs) | Step spent | 2nd → `second-factor-invalid` |
| Concurrent verifies of one challenge | — | One session; the other `challenge-ended` |
| 5 wrong codes across 3 challenges | — | 6th → 423; one `user.second_factor_locked` row |
| Third lock cycle without a success | — | Locked until an owner Unlock or the CLI |
| Next successful sign-in after failures | 7 wrong codes earlier | "7 failed two-factor attempts since your last sign-in" |
| Wrong code on Security | Signed in | 422; still signed in; counts toward the lock |
| User deactivated during the challenge | — | Verify → `challenge-ended`; no session |
| Owner's first sign-in after the deploy | Not enrolled | Enrol step, no enrolment code; session after confirm; 10 codes, Continue only after "saved" |
| Re-sign-in mid-enrolment | Pending secret < 24 h | Same QR; the already-scanned app works |
| Sign in again right after enrolling | Same 30 s step | The code from the next step works (the helper waits) |
| Replace authenticator, confirm within one step | — | Accepted (new secret, own sequence); other sessions end |
| Lost phone, has backup codes | — | A backup code signs in, or replaces via Security; that code is spent |
| Owner B resets A | A has a tab open | A's tab → /login with the reset notice; B sees the enrolment code; A enrols only with it |
| Attacker with A's password after the reset | No enrolment code | Enrolment refused (wrong-code count) |
| Sole owner lost everything | — | `bun run auth:reset-2fa <email>` prints the enrolment code |
| Old web bundle open during deploy | Owner signs in | 409 `client-outdated` "Reload this page"; nothing written |
| `MFA_ENCRYPTION_KEY` unset | — | The app refuses to boot |
| Owner badge-in on a handheld | — | Unchanged (decision 4) |

</frozen-after-approval>

## Code Map

**wms-be**
- `src/modules/tenancy/sign-in.command.ts:152-188`: branch after `clearSignInAttempts`; extract `issueWebSession` from `:156-188`.
- `src/modules/tenancy/tenancy.controller.ts:148-172`: set the cookie only when a session was issued; add `sign-in/second-factor` with the same cookie handling; read `X-WMS-Second-Factor`.
- New:
  - `second-factor.ts`: TOTP, base32, backup-code format and HMAC, the challenge store, `verifySecondFactorInput`.
  - `second-factor-secrets.ts`: the key, AAD, key id.
  - `second-factor.command.ts`: the sign-in step, self-service and reset.
- Do not change `src/shared/crypto/envelope.ts` (its `seal`/`open` default to the device key, `:37,46`). The 2FA wrapper does its own GCM with AAD.
- `auth-attempts.ts`:
  - `countBadgeInAttemptInTx` `:173-178` is the commit-first precedent.
  - `hitRateLimit` `:73`.
  - Export `minutesText` `:64`.
- `users.command.ts:792-818` `unlockUser` calls `clearSecondFactorLockInTx`; `:799` is the capability-check pattern; the deactivate and role-change paths clear open challenges.
- `sessions.ts`: `:27` revoke reasons, `:70` `SecurityAuditAction`, `:104` `newSecret`, `:443-456` the purge (unchanged; add a block beside it). `session-cookie.ts:115` `SESSION_END_DETAIL`.
- `users.controller.ts`: `me` routes beside `:277`; reset beside unlock `:229`. `clients.command.ts:404` is the `arm` pattern.
- `src/shared/db/schema.ts` `users` (`:101-129`) gains `mfa_secret_sealed`, `mfa_enabled_at`, `mfa_last_step` bigint ≥ 0, `mfa_failures` ≥ 0, `mfa_lock_cycles` ≥ 0, `mfa_failed_since_success` ≥ 0, `mfa_locked_until`, `mfa_pending_secret_sealed`, `mfa_pending_created_at`, `mfa_enrol_code_hash`, `mfa_enrol_code_expires_at`. The CHECKs pair each secret with its date and the code hash with its expiry. The two new tables are listed above.
- `drizzle/0075_second_factor.sql`: generated, then hand-edited below the marker following 0074.
  - CHECKs, RLS, and the re-added revoke-reason CHECK.
  - Probes: the new reasons are accepted and an unknown one is refused; the `users` pairing; the challenge purpose and failure bounds.
- `src/jobs/jobs.module.ts` `SessionPurgeWorker.tick`: a challenge block.
- `src/shared/primitives/audit.ts:111`; `test/support/audit-guard.ts:61` `AUDIT_NO_OP_ARMS`.
- `tenancy.dto.ts:404`: `SignInResponse` unchanged.
  - Add `TotpChallengeResponse`, `EnrollChallengeResponse`, the verify response (with optional `backupCodes` and `secondFactorFailedAttempts`), the me DTOs and the reset response.
  - The list DTO gains optional `secondFactorEnabled`.
  - The `oneOf` precedent is `notifications.dto.ts:192`.
- `scripts/auth-reset-2fa.ts` (new), plus `scripts/auth-unlock.ts` (clear the 2FA lock in a tenant transaction), `scripts/lib/`, `seed-demo.ts:240-253,1143`, `loadtest-*.ts`, and `package.json`.
- Tests:
  - `test/support/sign-in.ts` (new), `test/second-factor.spec.ts` (new).
  - `test/architecture.spec.ts` (the key and envelope-importer pins).
  - The 35 local `signIn` helpers in the 70 suites; `sessions.spec.ts:646-647`, `tenancy.spec.ts:303`, `users.spec.ts:255`.

**wms-fe**
- `src/lib/api/client.ts:396-398` (`isSessionRoute`), `:602` `fetchApiSignIn` (the header; returns the union), and a new `fetchApiSecondFactor`.
- `src/lib/auth.ts:175` `writeSession` (the guard).
- `src/components/auth/auth-forms.tsx:136-156,289,296`; new `SecondFactorStep`, `EnrollStep` and `BackupCodesPanel`.
- New `src/lib/second-factor.ts` (narrowing, `secondFactorReason`, input normalisation).
- `src/lib/portal.ts:83` `SESSION_ENDED_NOTICE`.
- New `src/app/(app)/account/security/page.tsx`; `sidebar.tsx:67-70`; `app-shell.tsx:121-124`.
- `src/components/settings/users-card.tsx:85,93,122`.
- Tests:
  - `auth-forms.test.tsx` (stub at `:40`).
  - New `second-factor.test.ts(x)` and `account-security.test.tsx`.
  - A portal redirect test.
  - A test that a wrong code on Security keeps the session.

**meta:**
- `tenancy.md`: a *Second factor* subsection, the schema, the commands, and decision 4's risk.
- `API-SURFACE.md`.
- `frontend/` route map: `/account/security`.
- PENDING tenancy: close 6.1b; add a 6.2 entry for provisioning `MFA_ENCRYPTION_KEY` and the runbook for losing it (every owner must use the CLI reset).
- The `docs/repos/wms-be` and `wms-fe` contracts.

## Tasks & Acceptance

**Execution:**
- [x] wms-be, in order:
  1. 0075 and the schema.
  2. `second-factor-secrets.ts` and the boot check.
  3. `second-factor.ts`, with the RFC vectors.
  4. The sign-in branch and `issueWebSession`.
  5. The second-factor route.
  6. The lockout, escalation and unlock.
  7. Self-service.
  8. The reset and the CLI.
  9. The vocabularies, audit and purge.
  10. The test helpers, then migrating the suites to them.
  11. The scripts.
  12. `second-factor.spec.ts`.
  13. The OpenAPI export.
- [x] wms-fe, in order:
  1. Regenerate the client.
  2. `lib/second-factor.ts`, the interceptor and `writeSession` guards.
  3. The login two-step and `BackupCodesPanel`.
  4. The Security page and links.
  5. The Team card.
  6. Notices.
  7. Tests.
- [x] wms-mobile: no change (decision 4).
- [x] meta: the Code Map docs.

**Acceptance Criteria:**
- Given an owner, when only the right password has been given, then no `sessions` row exists for them until a valid code is accepted.
- Given any response, audit row, log line or `idempotency_keys` row, then no TOTP secret or backup code appears in it except the one response that issues it.
- Given a wrong code, when the request fails, then its count is already committed (pinned by a test that fails if the counting is moved into the checking transaction).
- Given the full `bun run test`, then every suite passes with no bypass flag and no injected clock.

## Design Notes

**Why a challenge and not a half-session.** Sign-in is the only place a web session is created. The callers of `createSessionInTx` are sign-in and badge-in only; registration and accept-invite issue no session. Holding the session back until the second step means no guard or token kind has to learn about a password-only state.

**Why count in tx1 and check outside.** A count made in the transaction that then refuses would roll back with the refusal, and guessing would be unlimited. Holding a lock on one connection while counting on another drains the pool under load. 6-1a's badge-in sets the precedent: commit the count, then check.

**Why escalate.** Five tries every 15 minutes is 480 a day, which gives about a 13% chance of a hit within a month against three accepted steps. Three cycles followed by a hard lock caps an attacker at 15 guesses before a human acts. A hard-locked sole owner uses the CLI.

**Why per user.** The password lock is per (email, IP) so that an outsider cannot lock an owner out (A3). Whoever reaches the second step has the password, so keying on the user stops them rotating addresses.

**Owner badge-in (decision 4, accepted risk).** `FLOOR_ROLES` includes owner (`permissions.ts:412`). Badge-in needs the device, its PIN and the email; no password, no code. The badge session is fenced off every web route (`tenant-session.guard.ts:74`), so it reaches picks, putaway, receipts, counts, transfers and excursions, but not users, devices, settings, exports or adjustments approval on the web. Revisit if owners stop working the floor.

**Why reset uses an enrolment code.** Without it, whoever enrols first after a reset owns the factor. A reset is exactly when someone may be holding a phished password. The code travels outside the system (in person), as an invite token does.

## Verification

**Commands:**
- wms-be: `bun run test -- test/second-factor.spec.ts`, then the full `bun run test`, `bun run lint`, `bun run typecheck`, `bun run openapi:export` and the drift check. Never run two jest invocations at once.
- wms-fe: `bun test && bun run typecheck && bun run lint && bun run build`. The drift guard fails until the backend PR merges; this is expected.

**Manual checks:**
- Live:
  - Enrol with a real authenticator app.
  - Sign in again with a code, then with a backup code.
  - Owner B resets A, and A enrols with the enrolment code.
  - Lock with five wrong codes, then Unlock.
  - With an old bundle tab open, sign in: "Reload this page".

## Implementation Notes

**How it was built.** Implemented directly against this spec (wms-be `feat/6-1b-owner-two-factor-sign-in`: three commits; wms-fe: one commit; meta docs uncommitted for the review pass). Nothing pushed.

**wms-be.** Migration `0075_second_factor.sql` (generated, hand-amended below the marker: the pairing/counter CHECKs, the challenge CHECKs, RLS on both tables, the revoke-reason CHECK re-added, a post-migration probe with accepted and refused shapes; `db:generate` reports no changes). `second-factor-secrets.ts` (the only `MFA_ENCRYPTION_KEY` reader; GCM + AAD + key id; HKDF pepper; `assertSecondFactorKeyConfigured`, called by `main.ts` before `createApp`). `second-factor.ts` (TOTP/base32 on `node:crypto`, backup codes, the challenge store, `verifySecondFactorInput` + `commitSecondFactorInTx`, the escalating lock, the purge block). `second-factor.command.ts` (the sign-in step, Security, the reset, `resetSecondFactorInTx` shared with the CLI). `sign-in.command.ts` branches after `clearSignInAttempts` and exports `issueWebSessionInTx`. `users.command.ts`: unlock clears the 2FA lock in its transaction; deactivation and a role change clear open challenges; the list adds `secondFactorEnabled` and the later lock. Scripts: `auth-reset-2fa.ts`, `auth-unlock.ts` (2FA lock in a tenant transaction), `scripts/lib/two-step-sign-in.ts` for `seed-demo` (prints the owner's URI and backup codes) and the three load tests.
- **Tests:** `test/second-factor.spec.ts` (36 — the RFC 6238 vectors for SHA-1/256/512, AAD and key-id rotation, the boot check, the vocabulary pin and CHECK refusals, `wms_rls_probe` on both tables and the `users` writes, every matrix row, the six `expectAuditRow` pins, the reset race via `raceTwice`/`waitParked`, the CLI run as a subprocess, the no-leak scan, the purge, the OpenAPI paths and `oneOf`). `test/support/sign-in.ts` (`mintSessionToken`, `mintSignIn`, `signInAs`); a codemod moved 149 `…/sign-in` chains in 69 suites to `mintSignIn`; sign-in-under-test cases were retargeted explicitly (`tenancy.spec`, `users.spec`, `sessions.spec`, `portal.spec` — the portal one now pins that the portal needs no header and answers the 6-1a body). Architecture pins: the key's one reader, tenancy's envelope importers, `main.ts` runs the check. `MFA_ENCRYPTION_KEY` for the suites comes from a jest setup file. Mutation-checked: deleting the reset's second replay fails the race test (409); undoing the tx1 count fails the "ALREADY COMMITTED" test.
- **Decisions taken in implementation:**
  - **An expired enrolment code still blocks enrolment** (required whenever `mfa_enrol_code_hash` is set; an expired one never matches) — the literal "when the user holds one (unexpired)" would let anyone enrol freely 72 h after a reset. The owner resets again. Recorded in PENDING.
  - **The reset's no-op arm** is "no `mfa_enabled_at` AND no enrolment code at all" (an expired code is re-issued); its answer is `{enrolmentCode: null, enrolmentCodeExpiresAt: null}` (`AUDIT_NO_OP_ARMS` `users.resetSecondFactor:not-enrolled`).
  - **The reset's audit row** is written with `tx.insert(auditEvents)` (the static audit-rule scan needs the reference in the command file); its action string is typed against `SecurityAuditAction`.
  - **Lock mechanics:** the 5th wrong code sets the lock after the check, in its own short transaction (and resets `mfa_failures`, so each cycle allows five); tx1 also locks as a backstop if a count is already at the limit. A permanent lock reads `9999-12-31T23:59:59.999Z` in `lockedUntil` and `retryAfterSeconds: null` in the 423.
  - **New refusal codes beyond the spec's list** (each worded on the web): `second-factor-not-enabled`, `second-factor-setup-expired`, `second-factor-changed` (409 on Security when the factor moved between tx1 and tx2 — a 401 there would sign the web user out).
  - **The purge block** does not add to `SessionPurgeWorker.tick`'s returned count (6-1a's test pins it as sessions purged).
  - **Self-service rate limit** shares the sign-in IP limit (300/min) under its own bucket.
- **Verification:** `bun run test` (91 suites), `lint`, `typecheck`, `db:migrate` + `db:generate` (no changes), `openapi:export`.

**wms-fe.** Client regenerated. `lib/second-factor.ts` (narrowing by the presence of `challenge`, `secondFactorReason`, input normalisation, copy), `lib/use-second-factor.ts`; `isSessionRoute` gains `sign-in/second-factor`; `fetchApiSignIn` sends `X-WMS-Second-Factor: 1` and returns the union; new wrappers for the second step, Security and the reset; `writeSession` refuses a non-session body (returns `boolean`). `LoginForm` two-step (`second-factor-steps.tsx`), `qr-code.tsx` (`qrcode` 1.5.4 pinned, `@types/qrcode` 1.5.6, `import()` only), `backup-codes-panel.tsx`; the `?ended=` notice moved into the form so step two can hide it. `/account/security` (`security-view.tsx`) linked beside both Sign out mounts. Team card: chip, Reset 2FA, the enrolment code once. Notices for the two new reasons.
- **Tests:** `lib/second-factor.test.ts` (17), `auth-forms.test.tsx` (+9: header, in-place switch, attributes, backup code, `challenge-ended`, the held session until "I've saved", the enrolment code field, failed attempts, reload), `components/account/account-security.test.tsx` (8, incl. a 422 keeping the session and the portal redirect pin in the lib test), `client.test.ts` (a second-step 401 never clears a session).
- **Verification:** `bun test` (1724 pass), `typecheck`, `lint`, `build`, `check:capability-mirror`. The `generated-client` drift job stays red until the backend merges (expected).

**Not done / left for review:** no live manual run with a real authenticator app (the spec's manual checks); `bun run loadtest:smoke` not run locally.

## Spec Change Log

### 2026-10-18 — code review: reset follow-through (user chose "patch in place" over a full loopback)
- **Trigger:** code review E1/E2/E13 + verification-gap "other" — a reset of a non-owner never asks for the enrolment code (sign-in challenges only enrolled or required users, `sign-in.command.ts:254`); an expired enrolment code never matches, so the owner burns attempts toward the permanent lock; the Team card offers Reset only when `secondFactorEnabled`, so a lost or expired code can be re-issued only by the CLI.
- **Amended (outside the frozen block):** (a) sign-in issues the `enroll` challenge to any staff user holding an enrolment code, not only owners — a reset user re-enrols with the code; (b) an expired enrolment code answers the password step with 403 `enrolment-code-expired` ("Ask an owner to reset your two-factor sign-in again") — no challenge, nothing counted; (c) the user list DTO gains optional `secondFactorResetPending`, and the Team card offers Reset when `secondFactorEnabled === true || secondFactorResetPending === true`.
- **Known-bad state avoided:** a reset user locked out with no web recovery; an orphaned enrolment code for staff.
- **KEEP:** everything else in the implementation — the verifier's commit-first order, the reset's guard order and race test, the key handling, the test-helper migration, the web two-step.

## Review Triage Log

### Design review — 2026-10-18 (3 reviewers: security 15, data/conventions 15, web 12; 42 raw → 27 after dedup)

| # | Finding (reviewers) | Verdict | Disposition |
|---|---|---|---|
| R1 | Wrong-code counts roll back with the 401, so guessing is unlimited; counting on a second connection under a lock drains the pool (sec, data) | high | Verified the precedent at `auth-attempts.ts:173-178`. tx1 counts and commits; the check runs with no transaction; tx2 consumes |
| R2 | A wrong code on a signed-in route answers 401 → `signOutFrom` clears the session; `sign-in/second-factor` is not a session route (web) | high | Verified at `client.ts:396-398,440-466`. Self-service wrong codes are 422; route added to `isSessionRoute`; test |
| R3 | Self-service routes have no attempt limit or reuse rule, so a stolen session can brute-force `setup` and attach its own authenticator (sec) | high | One `verifySecondFactorInput` for every code-bearing route |
| R4 | 5 per 15 min with no escalation reaches ~13% a month; the audit signal is invisible (sec) | high | A hard lock after 3 cycles; failed-attempt count shown after the next sign-in |
| R5 | Owners badge in with PIN + email and no second factor (sec) | high/med | Verified at `permissions.ts:412`. **User decision 4:** allowed, risk recorded |
| R6 | First enroller wins after a reset or the deploy (sec) | med | **User decision 5:** an enrolment code after a reset; the deploy-day first enrolment is accepted and audited with the IP |
| R7 | An old bundle in an open tab writes a NaN session → redirect loop (web) | high | `X-WMS-Second-Factor` header → 409 `client-outdated`; `writeSession` guard |
| R8 | A new secret per enrolment challenge → the scanned app fails → locked out before ever enrolling (web) | high | The pending secret is reused for 24 h |
| R9 | Verify never re-reads the user, so a deactivated user gets a session; two enrolment tabs overwrite each other (sec, data) | high | tx2 locks the user and re-checks status and `enabled_at_seen` / `IS NULL`; state changes delete open challenges |
| R10 | `unlockSignIn` is not what the web Unlock calls; an update on a bare `db` matches 0 rows under RLS (data) | high | Verified at `users.command.ts:792-818` (inline delete) and `auth-unlock.ts:24`. `clearSecondFactorLockInTx` in both, plus an RLS probe |
| R11 | `setup` with 2FA off needs nothing; a stolen or pre-deploy session enrols its own factor (sec) | med | `setup` needs the password when off and a code when on |
| R12 | "A worried user signs out" ends only their own session (sec) | med | Replace, disable and regenerate revoke other web sessions (`second-factor-changed`) |
| R13 | A lost phone with backup codes left cannot replace the authenticator (sec) | med | Backup codes are accepted on self-service code routes |
| R14 | `mfa_last_step` semantics: the matched step vs the current one; replace within one step; re-sign-in after enrolment (sec, data) | med | The matched step; confirm sets it unconditionally; matrix rows |
| R15 | The test helper cannot sign in repeatedly within 30 s; `openTestSession` cannot work without a tenant or kind; body-shape tests break (sec, data) | med | `mintSessionToken({tenantId,userId,kind})` for non-sign-in suites; `signInAs` waits a step; retargets named |
| R16 | Scripts cannot use the Nest test helper; the demo owner would be enrolled with a secret nobody holds (data) | med | `scripts/lib` on the exported TOTP; `seed-demo` prints the URI and codes |
| R17 | Audit references unspecified (`expectAuditRow` needs one per reference); enrolment at sign-in not audited; only the reset in `AUDIT_NEW_ACTIONS` (sec, data) | med | References per event; six actions in both lists |
| R18 | Reset guard order, the replay under the lock, the no-op arm name and the race test unstated (data) | med | Order written out; arm named; `raceTwice` test |
| R19 | Backup codes as unsalted sha256 of 50 bits can be cracked offline in bulk (sec, data) | med | HMAC with a derived pepper over `user_id || code`; unique and partial indexes |
| R20 | Missing key → every owner 503 on deploy day; no key id or rotation; secrets can be copied between rows (sec, data) | med | Boot refuses; key id + `…_PREVIOUS`; AAD `tenant:user`; PENDING runbook |
| R21 | Migration CHECKs, indexes, probes and the lock cost of the revoke-reason CHECK unlisted (data) | med-low | Listed |
| R22 | The purge finds tenants from `sessions` only and has no per-tenant try/catch (data) | low-med | Own block, own discovery, try/catch |
| R23 | Writing the session before "I've saved" → a reload loses the codes (web) | med | `writeSession` on Continue; `beforeunload`; `downloadText` |
| R24 | Security link only in the sidebar; expiry, focus and a11y unspecified (web) | med | Both mounts; expiry, focus, aria-live and input attributes specified |
| R25 | Team chip leaks which owners lack 2FA; reset gating; undefined field (web) | med | Chip for `canChangeRole` only; hidden when undefined; reset gate stated |
| R26 | `oneOf` "discriminated by presence" is not OpenAPI; `qrcode` unpinned and rendered via inner HTML (web, data) | low | Three schemas, `@ApiExtraModels`; `-E`, `import()`, rendered to `<rect>`s |
| R27 | Code Map line refs: `SecurityAuditAction` `:70`; me path style; `SESSION_END_DETAIL`; envelope importer pin; `seal` default key; role subscription at `users-card.tsx:85` (data, web) | low | Corrected |
| — | Challenge token entropy, constant-time comparison, IP binding (sec) | low | `newSecret()`; constant-time; not bound, IP audited |
| — | Unkeyed self-service routes (data) | false | Sound: no guard requires keys, and the audit rule covers keyed commands only; the lost-response recovery is stated |

### Code review — 2026-10-18 (blind hunter 14, edge-case hunter 13, verification-gap 3 + 2, orchestrator 1; 33 raw)

| # | Finding (layer) | Verdict | Route / disposition |
|---|---|---|---|
| C1 | Deadlock: tx1 locks the challenge then updates the user; tx2 locks the user then the challenge — a duplicate verify overlapping another's tx2 aborts with 40P01 → 500 (orchestrator) | high — `second-factor.ts:521-608` vs `:688-701`; the concurrency test's timing never overlaps | patch: tx1 locks the user `FOR UPDATE` first, then the challenge (one order everywhere) |
| C2 | Reset follow-through: non-owner reset never asks for the code; expired code is a dead end toward the hard lock; Team card cannot re-reset (edge ×3, gap-other) | high | user chose patch in place — Spec Change Log 2026-10-18 |
| C3 | A reuse caught at commit (step spent, backup code spent) counts but never sets the lock, and answers `attemptsLeft: 0` (blind, edge) | medium — `commitSecondFactorInTx` throws after tx1's count with no `settleFailure` | patch: settle the lock after the rollback and report the real attempts left |
| C4 | An undecryptable secret (key lost / rotated away) reads as a wrong code and walks the user into the permanent lock, unlogged (blind) | medium — `verifySecondFactorInput` catch → `secret = null` | patch: open the secret before counting; failure logs and answers 503 `second-factor-unavailable`, nothing counted |
| C5 | Reset and disable leave `mfa_failed_since_success`, so the first sign-in after re-enrolment reports stale failures (edge, blind, gap-other) | low — direct correction | patch |
| C6 | `setup`'s password path decides "2FA off" outside the lock; a concurrent confirm lets a password replace an active factor (blind) | medium | patch: re-check `mfa_enabled_at IS NULL` under the lock, else 409 `second-factor-changed` |
| C7 | Web stores `expiresAt`/`refreshUntil` from Continue time, not arrival (edge, blind) | low — direct correction | patch |
| C8 | `auth:reset-2fa` has no no-op arm, resets portal users, audits every run (blind, edge) | medium | patch: no-op when nothing to reset (no audit); refuse `client` users |
| C9 | `:` in a tenant name or email breaks the otpauth label (edge) | low — direct | patch |
| C10 | `MFA_ENCRYPTION_KEY_PREVIOUS` set but short is silently ignored → old secrets unreadable (edge) | medium | patch: boot refuses it, like the main key |
| C11 | `auth:unlock` prints "no lock to clear" after clearing a 2FA lock (edge) | low — direct | patch |
| C12 | A wrong enrolment code reads as a wrong authenticator code, so users retype the TOTP and burn attempts (edge) | low — copy only | patch: the detail names both codes on an enroll challenge that needs one |
| V1 | Open challenges ending on a role change / deactivate→reactivate untested; `:534` never opens a challenge (gap) | gap | patch: rewrite `:534`; add the reactivate case |
| V2 | Expired enrolment code never tested (gap) | gap | patch (covered with C2's 403) |
| V3 | `auth:unlock` clearing the 2FA lock never run (gap) | gap | patch: spawn test beside `auth:reset-2fa`'s |
| B1 | Anyone with the password sees the pending secret during an owner's first enrolment (blind) | false — decision 5 accepts first enrolment on the password (today's sign-in is password-only); the pending-secret reuse is R8 | reject |
| B2 | Deploy-day trust on first use; 6-1a sessions not ended (blind) | false — decision 5; spec states pre-deploy sessions run to their end | reject |
| B3 | A phone clock ahead (t+1) spends the next step (blind) | low — inherent to the RFC window | reject |
| B4 | No re-seal on rotation; no count of rows on the old key (blind) | medium | defer — already recorded in PENDING by the implementation |
| B5 | Enrolment code plaintext in the reset snapshot; 40-bit unsalted hash; stale replay (blind) | false/low — the snapshot is the frozen invite-token precedent; the code is 72 h and useless without the password | reject |
| B6 | Security's password typos share the sign-in counters (blind) | false — the spec says "counts on `signin_attempts` (email, IP), as at sign-in" | reject |
| B7 | 409 `client-outdated` still clears the attempt counter (blind) | low — the password was right, and a right password resets the count | reject |
| B8 | No step-up for reset/unlock; no out-of-band notice of 2FA events (blind) | medium | defer — notices need the mailer (5.1); step-up is its own story (a stolen owner session already holds every owner power) |
| B9 | Anyone with the password can hard-lock an owner (blind) | false — the designed trade (Design Notes "Why escalate", R4) | reject |
| B10 | ~70 suites no longer exercise HTTP sign-in (blind) | false — R15's design; sign-in itself is covered by the sign-in suites | reject |
| E3 | A non-owner disabling between the outer read and the lock gets an enroll challenge (edge) | low — needs the user's own concurrent disable; fix adds a branch | reject |
