---
title: '5-1a email service and invite emails — an SES-backed mail queue with a sealed-secret sender worker; user invites are emailed'
type: 'feature'
created: '2026-10-23'
status: 'ready-for-dev'
route: 'dispatch'
review_loop_iteration: 0
context:
  - 'docs/initiatives/production-readiness.md'
  - 'docs/design/SYSTEM-DESIGN.md'
  - 'docs/design/IMPLEMENTATION-GUIDE.md'
  - 'docs/design/API-SURFACE.md'
  - 'docs/design/PENDING.md'
  - 'docs/design/modules/tenancy.md'
  - 'docs/design/modules/notifications.md'
  - 'docs/design/frontend/SYSTEM-DESIGN.md'
  - 'docs/design/frontend/IMPLEMENTATION-GUIDE.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** The backend cannot send email. An owner inviting a user must copy a one-time link and hand it over themselves. Password reset (6.1), invoice delivery and alerts are all blocked on having a mailer.

**Approach:**
- An **email queue** (`email_messages`), written **inside the business transaction** that wants the mail.
- A **sender worker** (the push-sender pattern) that renders a code-defined template and sends it through an **`EmailGateway` port**: SES v2 in `ap-south-1` (D6), with log and unconfigured implementations for dev and tests.
- The first user is **user invites and invite reissues**.
- Secrets needed only at send time (the invite token) are **sealed** in the row and **wiped** once the message is sent or finally fails.

**Decisions (recommended, taken autonomously under the user's standing instruction, 2026-10-23; revised by the design review):**
1. **Split.** Password reset by email (the 6.1 remainder) is 5-1b; invoice and alert emails are 5-1c (deferred-work).
2. **The queue is written in the transaction, not the outbox.** The invite, the reactivate and the new **resend** each write their `email_messages` row in their own transaction. A replay writes nothing (verified: each command replays before any write), and a rolled-back command sends nothing.
3. **Sealing.**
   - **Helper.** A shared `src/shared/crypto/seal.ts` (`seal(keyEnv, plaintext, aad)` / `open`, kid lookup and `_PREVIOUS` rotation) is extracted from `second-factor-secrets.ts`. The 2FA helper keeps its behaviour, and the architecture pins are updated: each key env has a single reader.
   - **What is sealed.** The invite token is sealed under `EMAIL_SEAL_KEY` (≥ 32 characters; `_PREVIOUS` refused when too short), with AAD `tenantId:messageId`.
   - **Wipe.** A CHECK enforces `sealed_secret IS NULL` unless the status is `pending` or `sending`.
   - **Honest framing.** The raw token also sits in the invite's idempotency snapshot (pre-existing), so sealing is defence in depth (PENDING: redact the snapshot).
4. **Provider, env and environments.**
   - **Variables:**
     - `EMAIL_PROVIDER` = `ses` | `log` | `off` (default `off`);
     - `EMAIL_FROM` (a verified SES identity) and an optional `EMAIL_REPLY_TO`;
     - `WEB_BASE_URL` (absolute; `https` required in production; normalised);
     - `EMAIL_SEND_POLL_MS`, `EMAIL_MAX_PER_TICK` (default 10, sized to the SES rate) and `EMAIL_ALLOWLIST_DOMAINS`.
   - **Allowlist.** When set, an address outside the allowlist is `skipped` — the staging and seed guard.
   - **Boot.** Boot refuses `ses` or `log` without `EMAIL_FROM`, `WEB_BASE_URL` and the key.
   - **Environments:** local `log`; tests `log` with capture; staging `ses` in the SES sandbox with the allowlist; production `ses` with production access.
   - **Client.** `@aws-sdk/client-sesv2` with `maxAttempts: 1` and a request timeout well under the stale bound.
5. **Delivery is AT-MOST-ONCE** (the push precedent).
   - **Statuses:** `pending → sending → sent | failed`, plus `skipped`, `expired` (not sent within 24 h), `cancelled` (superseded by a newer invite token or a deactivation).
   - **Stale and timeout.** A stale `sending` row (over 10 min) becomes `failed 'stale'` and is never re-sent; a network timeout counts as stale. SES has no idempotency key, and a resend exists for the rare loss.
   - **Record.** The SES `MessageId` is stored.
   - **Error classification:**
     - **Transient** (`TooManyRequestsException`, `LimitExceededException`, 5xx, `InternalServiceError`): retried with backoff `min(2^(n-1)·30s, 30 min)`, at most 5 attempts.
     - **Config** (`AccountSuspendedException`, `SendingPausedException`, `MailFromDomainNotVerifiedException`, access or credential errors, `NotFoundException`, sandbox "address not verified"): spends no attempt, is logged once per tick by code, and stays `pending` until expiry.
     - **Permanent** (`BadRequestException`, other `MessageRejected`): `failed` with the code.
   - **Suppression pre-check.** Before sending, `GetSuppressedDestination`: a suppressed address gives `failed 'suppressed'`. SES otherwise accepts and silently drops; a later bounce shows as `sent` until an SNS intake exists (PENDING).
6. **Templates** (`src/modules/mail/templates/*.ts`): text plus minimal HTML.
   - **Escaping.** Every parameter is HTML-escaped; the subject has CR and LF stripped.
   - **Headers.** From: `"{tenant name} via WMS" <EMAIL_FROM>`. Reply-To: the inviting owner's email (else `EMAIL_REPLY_TO`).
   - **Body:** who invited them, the role, the accept link, the expiry (IST date), and a line saying that if they weren't expecting this they can ignore it. A portal invite says "{tenant} has invited you to the {client} portal".
   - **Transactional only:** no tracking pixel, no link rewriting, no unsubscribe (the invite is a service mail). English only (PENDING: locales).
   - **Name reads.** The tenant name and the client name are read in the command's transaction: a tenancy-local tenant read, plus `LockedClientFacts` widened with `name`.
7. **Sends and the link.**
   - **Which commands queue mail:** invite, reactivate (a never-accepted user) and a new **`POST …/users/{id}/resend-invite`**. Resend is owner-only (`users.invite`), keyed and audited `user.invite_resent`; it is for an `invited` user, mints a fresh token and cancels older rows.
   - **Deactivation** cancels non-final rows for that user.
   - **One link.** The backend returns the full **`inviteUrl`** (built from `WEB_BASE_URL`) in the invite, reactivate and resend responses, so the emailed link and the copy link are the same.
8. **Visibility.**
   - **Responses.** The invite, reactivate and resend responses carry `inviteEmail: {status} | null`, optional so older stored snapshots replay unchanged (`?? null`).
   - **List.** The users list carries `inviteEmail: {status, updatedAt} | null` on a list-only DTO field, filled only when the caller holds `users.invite`.
   - **Web wording:**
     - "Queued to send…" for `pending` or `sending`;
     - "Sent to the mail service" for `sent`;
     - nothing for `skipped`;
     - "Not sent — resend or copy the link" for `failed`, `expired` and `cancelled`.
   - **Refresh.** The web polls the list every 5 s, for at most 60 s, while a row is pending or sending.
9. **Privacy and retention.**
   - **What is stored.** No body is stored, only the template id and parameters; there is a `user_id` column.
   - **Logging.** The log gateway prints the template id and message id only; tests read captured messages in memory.
   - **Retention.** Every final status is purged after 90 days through a discovery arm of its own, so idle tenants are purged too. The `user.invited` audit row is the durable record.

## Ops prerequisites (owned with 6.2; documented in `modules/mail.md` and the BE README)

- SES domain identity with Easy DKIM, a custom MAIL FROM (SPF) and a DMARC record.
- Production access requested; account-level suppression enabled (bounces and complaints).
- The sending quota and rate known, with `EMAIL_MAX_PER_TICK` and the poll interval set under them.

## Boundaries & Constraints

**Always:**
- **Sender:** claims `FOR UPDATE SKIP LOCKED` (`EMAIL_MAX_PER_TICK`) and commits `sending` before the gateway call.
- **Migration `0089_email_messages.sql`:**
  - columns: `id`, `tenant_id`, `user_id`, `template`, `to_email`, `params`, `sealed_secret`, `status`, `attempts`, `next_attempt_at`, `provider_message_id`, `error_code`, timestamps;
  - CHECKs: status, template, the wipe pairing;
  - RLS (tenant arm);
  - indexes: `(tenant_id, status, next_attempt_at)` and `(tenant_id, user_id, created_at desc)`;
  - probes.
  
  It is generated after **0088 (WMS-BE #123) merges**: the implementer waits or rebases; the journal is never hand-edited.
- **Architecture pins:**
  - other modules import only `mail.facade`;
  - `email_messages` is written only in `src/modules/mail`;
  - mail imports nothing from tenancy;
  - `EMAIL_SEAL_KEY` has a single reader.
- **The accept page stays a non-mutating GET form** (the accept is a POST), with `Referrer-Policy: no-referrer` and "Ask whoever invited you to send a new invitation" copy.

**Never:**
- No password reset, invoice or alert mail.
- No bounce webhook.
- No raw token in the outbox, in logs, or after the final status.
- No handheld mail; no bulk mail.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|---|---|---|---|
| Invite, `ses` | the owner invites `a@x.in` | invited; one `pending` row sealed; the worker sends and stores `MessageId`; `sent`, seal null; the response gives `inviteUrl` + `inviteEmail.status` `pending` | — |
| Invite replay | same key | no second row; the cached response | — |
| Provider `off`, or an address outside the allowlist | invite | the row is `skipped`; the link shown | — |
| Transient error | throttling | retried with backoff; `sent` later | 5 attempts → `failed`, wiped |
| Config error | SES sending paused | stays `pending`, no attempt spent, logged once per tick | 24 h → `expired`, wiped |
| Suppressed address | on the SES suppression list | `failed 'suppressed'` | — |
| Stale `sending` | the worker died mid-send | `failed 'stale'`, never re-sent | — |
| Resend | owner, an `invited` user | a fresh token; the old row `cancelled`; a new row; audited | not `invited` → 409 |
| Deactivate an invited user | — | its pending row `cancelled`, wiped | — |
| Template injection | tenant name `<a href=x>\r\nBcc:` | escaped in the HTML; the subject has no CR or LF | — |
| Boot misconfig | `ses` without `EMAIL_FROM` | refuses to boot, named | — |

</frozen-after-approval>

## Code Map

### Backend (`workspace/core/backend/wms-be`)

**`src/modules/mail/` (new module)**
- `email.gateway.ts`: the `EMAIL_GATEWAY` token, `EmailGateway {send(msg)}`, `SesEmailGateway` (`SESv2Client` `SendEmailCommand`, injected `Pick<SESv2Client,'send'>`), `LogEmailGateway` (capture) and `UnconfiguredEmailGateway`, plus `emailGatewayFromEnv` (the `push-gateway.ts:185` pattern).
- `mail.facade.ts`: `queueEmailInTx(tx, {tenantId, template, to, params, secret?, sourceRef})`, the only writer; it seals the secret.
- `mail.sender.ts`: claim, stale reset, expiry, send, wipe, and a 90-day purge (the `push.sender.ts:70-198` pattern).
- `templates/invite.ts`: renders `{subject, text, html}`.
- `mail.config.ts`: the env parse and boot assert, called from `main.ts` beside `assertSecondFactorKeyConfigured`.

**Wiring**
- `src/jobs/jobs.module.ts`: `EmailSenderWorker` (`parsePollMs('EMAIL_SEND_POLL_MS')`, single-flight, `AUTH_DATABASE` tenant discovery of due rows).
- `src/modules/tenancy/users.command.ts`:
  - `invite` (`:191`) and reactivation (`:768-790`) call `queueEmailInTx` (the raw token as the secret), cancelling older rows;
  - deactivation (`:729-737`) cancels non-final rows;
  - a new `resendInvite`.
- Responses gain `inviteUrl` and `inviteEmail`.
- `src/modules/tenancy/users.*` list read joins the latest invite message per user to fill `inviteEmail`.

**Secret sealing:** extract `src/shared/crypto/seal.ts` from `second-factor-secrets.ts` (`:50-78`); update `test/architecture.spec.ts:3130-3146`.

**Name reads:** widen `LockedClientFacts` (`clients.facade.ts:532`) with `name`; a tenancy-local tenant name read.

**Migration and config**
- `drizzle/0089_email_messages.sql` + `schema.ts`.
- `.env.example` and the README "Environment" section.
- `package.json` gets `@aws-sdk/client-sesv2`, pinned to the S3 client's version.

**Tests:** `test/mail.spec.ts` (new) covers every matrix row (capture gateway, the worker's `tick()`), sealed-token wipe, RLS isolation and a boot-assert unit; `src/modules/mail/*.spec.ts` covers the SES gateway against `aws-sdk-client-mock` (transient vs permanent classification) and the template render.

### Web (`workspace/core/frontend/wms-fe`)

- `src/components/settings/users-card.tsx`:
  - the status words (decision 8);
  - the backend `inviteUrl` for the copy link;
  - a **Resend invite** action for invited users (owner);
  - polling while pending;
  - the post-invite message by status.
- `src/app/accept-invite/page.tsx`: the copy and the referrer meta.
- `src/lib/users.ts`: status words, with tests.
- Regenerate the client.

### Mobile

None.

## Tasks & Acceptance

**Execution:**
- [ ] BE: mail module, gateway, sealing, sender worker, templates, config, migration 0089 (after #123), invite and reactivate wiring, list field; OpenAPI; tests.
- [ ] Web: users card status and message, words, tests; regenerated client.
- [ ] Meta docs:
  - `SYSTEM-DESIGN.md` (the mail module, the in-transaction queue);
  - a new `modules/mail.md`;
  - `tenancy.md` (invites);
  - `API-SURFACE.md`;
  - IMPLEMENTATION-GUIDE (the "queue mail in the transaction; seal secrets" rule);
  - READMEs and the env docs;
  - PENDING: close "no mailer"; add an SNS bounce intake, locales, an explicit resend, 5-1b, 5-1c.

**Acceptance Criteria:**
- Given `EMAIL_PROVIDER=log`, when an owner invites `a@x.in`, then one invite message is captured with the tenant name, the role and a working accept link, and the stored row holds no token after the send.
- Given `EMAIL_PROVIDER=off`, when an owner invites, then the invite works exactly as today (link shown), and the row is `skipped`.

## Design Notes

- **Why not the outbox.** The outbox is at-least-once and its payloads are plain jsonb in `outbox_messages`; a raw token there is a secret at rest in a queue many consumers read. Queueing in the command's own transaction gives exactly one row per committed invite, with the secret sealed.
- **Why SES account suppression.** It blocks hard-bounced and complaining addresses at the provider with no public webhook endpoint (which needs deployability, 6.2). Our row records the refusal code.

## Verification

**Commands:**
- `bun run test -- test/mail.spec.ts test/users.spec.ts src/modules/mail` (wms-be, run alone): pass.
- `bun run db:generate` clean; `bun run lint && bun run typecheck` (wms-be, wms-fe); `bun test` (wms-fe): pass.

## Implementation Notes

## Spec Change Log

## Review Triage Log

Design review, 2026-10-23 (backend B, web W). Every accepted finding is folded into the spec above; all choices are recommended, taken autonomously.

| ID | Verdict | Finding → resolution |
|---|---|---|
| B1 | high | SES suppression returns 200 and silently drops. A `GetSuppressedDestination` pre-check; "sent to the mail service" wording; SNS intake PENDING. |
| B2 | high | Stale reset double-sends; the idempotency header claim is false. At-most-once (stale → failed); `maxAttempts: 1`; `MessageId` stored. |
| B3 | high | Deactivate and reactivate leave mail holding dead tokens. A `cancelled` status; supersede on every token change. |
| W1 | high | "Copy the link" dead-ends after a reload; no resend. A resend-invite command. |
| W2 | high | "Invite emailed" was unconditional. `inviteEmail` status on responses; wording by status. |
| B4 | medium | The error classes were incomplete. Transient, config and permanent table. |
| B5 | medium | The seal helper is not reusable as is. Extract `seal.ts`; architecture pins. |
| B6 | medium | The log gateway would leak the token; the snapshot already holds it. Log ids only; PENDING redaction. |
| B7 | medium | Purge and expiry miss idle tenants; retention half-stated. A discovery arm; 90 days for every final status. |
| B8 | medium | Template injection. Escaping, CR/LF strip, a render test. |
| B9 | medium | Wipe not enforced; the list join unindexed. CHECKs; `user_id` + index. |
| W3 | medium | Stored snapshot DTOs at risk. Optional fields; a list-only DTO. |
| W4 | medium | Status never refreshes. Light polling. |
| W5 | medium | Two link bases. The backend `inviteUrl`. |
| W6 | medium | The seed and staging would email strangers. The env matrix and the allowlist. |
| W7 | medium | Ops prerequisites missing. A section; a per-tick cap. |
| W8 | medium | Email content underspecified. From, Reply-To, body lines, portal wording, no tracking. |
| B10 | low | Name sources unstated. Named. |
| B11 | low | Boot assert narrow. URL and `_PREVIOUS` checks; `log` needs the key. |
| B12 | low | No module-direction pins. Architecture pins. |
| W9 | low | Accept page copy and referrer. Updated. |
| W10 | low | Status visible to non-owners; docs list. Owner-only field; docs added. |

