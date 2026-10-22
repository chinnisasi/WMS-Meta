# Mail module

> Transactional email (story 5-1a): an **in-transaction queue** (`email_messages`) that a business command writes in its own transaction, and a **sender worker** that renders a code-defined template and sends it through the `EmailGateway` port — SES v2 in ap-south-1 (D6), or the capturing `log` provider, or `off`. Delivery is **at-most-once**. The first and only mail is the **user invitation** (invite, the reactivation of a never-accepted invitee, and Resend invite). Password reset by email is 5-1b; invoice and alert mail is 5-1c.

Source: `workspace/core/backend/wms-be/src/modules/mail/`. Every `file:line` below is relative to `wms-be/`. Read [`../IMPLEMENTATION-GUIDE.md`](../IMPLEMENTATION-GUIDE.md) first; the sender follows `notifications/push.sender.ts` (`notifications.md` §Mobile pushes).

**The module exists for one rule: a mail is queued in the transaction that wants it, never on the outbox.** The outbox is at-least-once and its payloads are plain jsonb many subscribers read — an invite's raw token there would be a secret at rest in a shared queue. Queueing in the command's own transaction gives exactly one row per committed command (a rollback queues nothing, a replay returns before any write), and the secret is sealed in the row and wiped once the row is final.

---

## Owns

| Table | Holds | Key invariants |
|---|---|---|
| `email_messages` (`schema.ts`, migration `0089_email_messages.sql`) | One row per message: `tenant_id`, `user_id` (what it concerns — nullable for future templates), `template`, `to_email`, `params` (jsonb — the template's parameters, **never a body, never the token**), `sealed_secret`, `status`, `attempts`, `next_attempt_at`, `provider_message_id`, `error_code`, timestamps | CHECKs only in `0089`: `email_messages_template_check` (`user-invite`), `email_messages_status_check` (the seven statuses), **`email_messages_secret_wipe_check`** (`sealed_secret IS NULL OR status IN ('pending','sending')` — the wipe is a schema fact), `email_messages_attempts_check` (≥ 0). RLS `email_messages_tenant_isolation` (the plain tenant policy). Indexes `(tenant_id, status, next_attempt_at)` (the claim) and `(tenant_id, user_id, created_at DESC)` (the users list's latest invite per user). No FK. Probed in the migration (every status accepted, every refused shape refused by its named CHECK) |

Written **only** under `src/modules/mail` (`test/architecture.spec.ts` "the mail module (story 5-1a)").

---

## Public seam — `mail.facade.ts` only

Other modules import `mail.facade` and nothing else under `src/modules/mail`; the shells may wire `mail.module` (`app.module.ts`, `jobs.module.ts`), and `main.ts` runs `mail.config`'s boot check. Mail imports nothing from tenancy (both pinned).

**Free functions over the caller's transaction** (a function import — the caller needs no Nest import of `MailModule`):

- `queueEmailInTx(tx, {tenantId, template, to, params, secret?, sourceRef: {userId}})` → `{id, status}` — **the only writer of a new row.** `EMAIL_PROVIDER=off` → the row is `skipped` (`provider-off`); an address outside `EMAIL_ALLOWLIST_DOMAINS` → `skipped` (`allowlist`); otherwise `pending`, due now, with `secret` sealed (`mail-secrets.ts`, AAD `tenant_id:id`). A skipped row stores no secret.
- `cancelUserEmailsInTx(tx, tenantId, userId, template, reason)` → count — every live (`pending`/`sending`) row of the user and template → `cancelled` with `error_code` = `superseded` (a newer token) or `deactivated`, secret wiped.
- `latestUserEmailsInTx(tx, tenantId, userIds, template)` → `Map<userId, {status, updatedAt}>` — `DISTINCT ON (user_id)` by `created_at DESC, id DESC`, one indexed read.
- `inviteAcceptUrl(tenantId, token)` → the accept link from `WEB_BASE_URL` (`links.ts`: `{WEB_BASE_URL}/accept-invite?tenant=<id>&token=<raw>`), or `null` when no base URL is configured (possible only under `off`). The emailed link and a response's `inviteUrl` are built by the same function — one string.

**`MailFacade`** (injectable, exported by `MailModule`) — the jobs shell's seam: `sendDue(tenantId, limit?)` → `MailSendSummary`, `maxPerTick()`. Re-exports the vocabularies (`EMAIL_STATUSES`, …) and the sweep bounds the worker's discovery query uses.

---

## Flows

### Queue in the command, send from the worker

```mermaid
sequenceDiagram
    participant C as UsersCommand (invite / reactivate / resend)
    participant F as mail.facade (queueEmailInTx)
    participant Q as email_messages
    participant W as EmailSenderWorker (jobs)
    participant A as AUTH_DATABASE (read-only)
    participant S as MailSender (sendDue)
    participant G as EmailGateway

    C->>C: authority → replay → … → the user write
    C->>F: queueEmailInTx(tx, {to, params, secret: raw token})
    F->>Q: INSERT pending (secret sealed) — or skipped (off / allowlist)
    C->>C: audit → idempotency key → COMMIT (the row commits with the invite)
    W->>A: tenants with mail work (due pending, pending > 24 h, sending > 10 min, final > 90 days)
    W->>S: sendDue(tenantId, remaining of EMAIL_MAX_PER_TICK)
    Note over S,Q: tx A — sending > 10 min → failed 'stale'; pending > 24 h → expired;<br/>purge final > 90 days (≤ 1,000); claim ≤ limit due pending FOR UPDATE SKIP LOCKED;<br/>per row: off → skipped; outside allowlist → skipped; open the secret (else failed 'unsealable');<br/>render (else failed 'render'); → sending; COMMIT
    loop each claimed row, one at a time
    S->>Q: own tx — still `sending`? touch updated_at (no row → cancelled since the claim: skip)
    S->>G: send(email) — no transaction held
    G-->>S: {ok, providerMessageId} | {ok: false, code}
    S->>Q: own tx — outcome, only if still `sending`: sent (MessageId) / pending + backoff / pending + 60 s (config) / failed
    end
    S-->>W: MailSendSummary (configCodes)
    W->>W: config fault seen? log ONCE per tick across tenants
```

### The lifecycle

```
pending ──claim──▶ sending ──ok───────────────────────────▶ sent        (provider_message_id)
   ▲                  │──permanent / suppressed────────────▶ failed <code>
   │                  │──transient (5th attempt)───────────▶ failed <code>
   │                  │──transient (< 5)───────────────────▶ pending, backoff min(2^(n−1)·30 s, 30 min)
   │                  │──config───────────────────────────▶ pending + 60 s, NO attempt spent
   │                  │──unknown outcome (timeout)─────────▶ failed 'stale'   — never re-sent
   │                  └──still sending after 10 min────────▶ failed 'stale'   — never re-sent
   ├── at claim: provider off / outside allowlist ─────────▶ skipped
   ├── at claim: secret does not open ─────────────────────▶ failed 'unsealable'
   ├── at claim: params do not render ─────────────────────▶ failed 'render'
   ├── created > 24 h ago ─────────────────────────────────▶ expired
   └── a newer token / the user deactivated / accepted ────▶ cancelled ('superseded' / 'deactivated' / 'accepted')
```

Every arrow into a final status wipes `sealed_secret` (the CHECK refuses otherwise). Final rows are purged after 90 days; the `user.invited` / `user.invite_resent` audit rows are the durable record.

**At-most-once is deliberate.** SES has no idempotency key: a `sending` row that outlived its process may have gone out, so it is failed, never re-sent; a timeout after the request left is treated the same way. Resend invite exists for the rare loss.

---

## Commands and guards (in tenancy, the first user)

The commands live in `tenancy/users.command.ts`; this module only queues, cancels and reads.

| Command | Mail effect |
|---|---|
| `invite` | after the user insert, `queueInviteEmailInTx`: reads the **tenant name** (tenancy-local `tenants` read) and the **inviting owner's email** (the Reply-To) in the invite's transaction, the client's name from `shareLockClientInTx` (`LockedClientFacts.name`, widened in 5-1a); queues `user-invite` with the raw token as the secret. The response gains `inviteUrl` and `inviteEmail: {status}` (stored in the snapshot; a pre-5-1a snapshot replays `inviteEmail: null`, `inviteUrl` derived) |
| `acceptInvite` | `cancelUserEmailsInTx(…, 'accepted')` in the accept transaction — the token is spent, so a still-queued mail would carry a dead link |
| `setUserStatus` deactivate | `cancelUserEmailsInTx(…, 'deactivated')` beside the existing invite-token clear |
| `setUserStatus` reactivate (a never-accepted invitee) | a portal invitee's client `FOR SHARE`, active else **409 `client-not-active`** (the invite's and resend's gate); cancel older rows (`superseded`), queue a new one; the response gains `inviteUrl` / `inviteEmail` beside `inviteToken` |
| `resendInvite` (new — `POST …/users/{id}/resend-invite`) | `users.invite` → replay → lock the target `FOR UPDATE` (404) → replay again → `status = 'invited'` else **409 `user-not-invited`** → a portal user's client `FOR SHARE`, active else **409 `client-not-active`** → a fresh token and a new 7-day expiry (the old link dies) → cancel older rows (`superseded`) → queue → audit `user.invite_resent` → key. Hash `{arm: 'resend-invite', tenantId, targetUserId}` |

The users list (`GET …/users`) carries `inviteEmail: {status, updatedAt} | null` on each **invited** row (null on every other row) — a list-only DTO field (`UserListItemResponse`), filled only when the caller is an **active** member holding `users.invite` (absent otherwise).

---

## Key algorithms

### The gateway (`email.gateway.ts`) and `EMAIL_PROVIDER`

| Mode | Adapter | Behaviour |
|---|---|---|
| `off` (default) | `UnconfiguredEmailGateway` | never called — rows are `skipped` at queue time, and a pending row met at claim is `skipped` |
| `log` | `LogEmailGateway` | captures the rendered message in memory (bounded at 1,000; the e2e suites read it) and logs **only** `template` and message id — the body carries the one-time link. Answers `log-<id>` |
| `ses` | `SesEmailGateway` | `SESv2Client` in `AWS_REGION` (default ap-south-1), `maxAttempts: 1`, connection timeout 3 s, request timeout 15 s (`throwOnRequestTimeout`) — well under the 10-minute stale bound. **Before each send, `GetSuppressedDestination`:** found → `suppressed`; `NotFoundException` → send; any other error is classified (a transport error there is `network` — nothing left). Then `SendEmail` (simple content, text + HTML, UTF-8): From `"{tenant} via WMS" <EMAIL_FROM>` (a non-ASCII name as RFC 2047 encoded-words, each ≤ 75 characters, cut on code-point boundaries), Reply-To the inviter else `EMAIL_REPLY_TO`; the answer's `MessageId` is stored |

`emailGatewayFromEnv` runs the boot check first; `main.ts` runs it too (`assertMailConfigured`, beside `assertSecondFactorKeyConfigured`). **The boot refuses** `ses` or `log` without `EMAIL_FROM` (a bare address), `WEB_BASE_URL` (absolute http(s), no credentials/query/fragment, `https` under `NODE_ENV=production`, normalised without a trailing slash) or `EMAIL_SEAL_KEY` (≥ 32 characters; a set-but-short `_PREVIOUS` refuses too), and refuses a bad `EMAIL_REPLY_TO`, `EMAIL_MAX_PER_TICK` (1–1000, default 10), `EMAIL_ALLOWLIST_DOMAINS` or `AWS_REGION` — each naming its variable. The config is re-read per call (`mailConfigFromEnv`), so the suites switch `EMAIL_PROVIDER` / the allowlist per test.

**Environments:** local `log`; tests `log` with capture; staging `ses` in the SES sandbox **with** the allowlist; production `ses` with production access.

### `EMAIL_ERROR_CLASS` — the one classification table (`mail-rules.ts`)

| Code | Class | The row |
|---|---|---|
| `TooManyRequestsException`, `InternalServiceErrorException`, `ThrottlingException`, `ServiceUnavailable`, `http-429` (an unnamed 429, or a 429 under an undocumented name), any `http-5xx`, `network` | transient | `pending`, `attempts + 1`, backoff min(2^(n−1)·30 s, 30 min); the 5th → `failed` |
| `LimitExceededException` (the daily quota — retried with backoff it would fail every queued invite within minutes), `AccountSuspendedException`, `SendingPausedException`, `MailFromDomainNotVerifiedException`, `NotFoundException` (on the send), access / credential errors (`AccessDeniedException`, `UnrecognizedClientException`, `InvalidClientTokenId`, `SignatureDoesNotMatch`, `ExpiredTokenException`, `CredentialsProviderError`, …), `address-not-verified` (the sandbox's `MessageRejected` "not verified") | config | `pending` again in 60 s **without spending an attempt**; returned in `configCodes`, logged once per tick by the worker; the 24-hour expiry ends it |
| `BadRequestException`, any other `MessageRejected`, `suppressed`, any unlisted code | permanent | `failed` with the code |
| `timeout` — no HTTP answer to `SendEmail` and no proof that no connection was made (`ECONNREFUSED`, `ENOTFOUND`, `EAI_AGAIN`, `ENETUNREACH`, `EHOSTUNREACH` prove it → `network`) | unknown outcome | `failed 'stale'` — never re-sent |

Only codes are stored or logged (`boundedEmailCode`: `[A-Za-z0-9_.-]`, ≤ 64). SES messages name the address and are read only to tell the sandbox refusal apart.

### Sealing (`mail-secrets.ts`, `shared/crypto/seal.ts`)

`seal.ts` (extracted in 5-1a from `tenancy/second-factor-secrets.ts`, unchanged in behaviour) is AES-256-GCM with associated data, a key id in the blob (`v1:<kid>:<iv>:<tag>:<ct>`) and `_PREVIOUS` rotation, over a **keyring** `{env, minLength, missing}` its caller names. It names no key itself. `mail-secrets.ts` is the only file that names `EMAIL_SEAL_KEY` (and `second-factor-secrets.ts` the only one that names `MFA_ENCRYPTION_KEY`) — pinned. The AAD is `tenant_id:message_id`, so a blob copied to another row will not open (`unsealable`).

**Honest framing:** the raw invite token also sits in the invite's idempotency snapshot (pre-existing since 1.5, so a replay re-serves the link) — sealing the queue is defence in depth, not the only copy (PENDING: redact the snapshot).

### Templates (`templates/*.ts`)

Code-defined, text plus minimal HTML, English only. `renderEmail(template, params, {tenantId, webBaseUrl, secret})` is exhaustive over `EMAIL_TEMPLATES`; the stored params are re-decoded at send time (a jsonb row is never trusted blind). **Every parameter is HTML-escaped**; the subject and the From display name pass through `headerText` (CR, LF and every control character removed). No tracking pixel, no link rewriting, no unsubscribe (a service mail).

`user-invite` body: who invited them, the role ("as an Ops Manager"), the accept link, the expiry as an IST date ("expires on 30 October 2026 (IST)"), and "If you weren't expecting this invitation, you can ignore this email". A portal invite reads "{tenant} has invited you to the {client} portal". Params stored: `{tenantName, inviterEmail, role, clientName, expiresAt}` — never the token.

### The worker (`jobs/jobs.module.ts` `EmailSenderWorker`)

Env-gated by `EMAIL_SEND_POLL_MS` (unset/`0` = off; `.env.example` 5000). Discovery on `AUTH_DATABASE` (a sequential scan — every arm filters on `status`, both indexes lead with `tenant_id`; PENDING) has four arms — due `pending`, `pending` past 24 h, `sending` past 10 min, and **final past 90 days** (its own arm, so an idle tenant is purged too). One `sendDue(tenantId, remaining)` per tenant inside its own try/catch; `remaining` is what is left of `EMAIL_MAX_PER_TICK` this tick — the SES rate is per account, not per tenant — and a tenant met after the budget is spent still gets its sweeps (a zero send limit). **The walk starts one tenant later each tick** (a per-instance tick counter, wrapping), so one tenant's backlog cannot starve the others. The cap is per worker process, and each message makes two SES calls — keep (processes × cap × 2) ÷ poll seconds under the SES rate. Single-flight, `unref`'d timer, the 6-2a shutdown drain. Two processes are safe (`SKIP LOCKED`; `sending` committed before the send).

---

## Invariants

| Invariant | Enforced by |
|---|---|
| One row per committed command; none on a rollback or a replay | the insert is in the command's transaction; every command replays before any write; `test/mail.spec.ts` (replay → one row; a 409 invite → no row) |
| No secret on a final row | `email_messages_secret_wipe_check` (probed in 0089); every final write sets `sealed_secret = null` |
| The token is never in `params`, the outbox, or a log line | the template builds the link at send time from the opened secret; the log gateway logs ids only; pinned in `test/mail.spec.ts` |
| A message is never sent twice, and a cancelled one never sent | `sending` committed before the provider call; each send is preceded by its own re-check (still `sending`, `updated_at` touched — so a long batch never ages stale) and followed at once by its own outcome write, touching only a row still `sending`; a stale `sending` row and a timeout become `failed 'stale'` |
| A cancel during a send stands | the outcome's `WHERE status = 'sending'` |
| Only mail writes `email_messages`; others import only `mail.facade`; mail imports nothing from tenancy; `EMAIL_SEAL_KEY` named in one file | `test/architecture.spec.ts` "the mail module (story 5-1a)" |
| `template` and `status` are one vocabulary in TS and SQL | the 0089 CHECKs + the pin in `test/mail.spec.ts` |

---

## Events

Produced: none (the audit rows are tenancy's: `user.invited`, `user.reactivated`, `user.invite_resent`). Consumed: none — mail is queued in-transaction, never from the outbox.

---

## Ops prerequisites (owned with 6.2)

- SES domain identity in ap-south-1 with **Easy DKIM**, a **custom MAIL FROM** (SPF) and a **DMARC** record.
- **Production access** requested; **account-level suppression** enabled for bounces and complaints.
- IAM: `ses:SendEmail` and `ses:GetSuppressedDestination`.
- The sending quota and rate known, with `EMAIL_MAX_PER_TICK` and `EMAIL_SEND_POLL_MS` set under them (sandbox: 1/s).

The BE README §Email carries the same list.

---

## Gotchas

- **"Sent" means the mail service accepted it**, not that it was delivered. There is no SNS bounce/complaint intake yet (PENDING), so a later bounce still reads `sent`; account suppression stops the *next* send to that address (`suppressed`). The web says "Sent to the mail service" for exactly this reason.
- **The sandbox looks like a config fault.** An unverified recipient in the SES sandbox is `address-not-verified` → config: the row waits (no attempt spent) and expires after 24 h. Staging runs with `EMAIL_ALLOWLIST_DOMAINS` so a seed or a stranger is `skipped`, not waiting.
- **Losing `EMAIL_SEAL_KEY` loses only queued mail** (it fails `unsealable`) — nothing durable is sealed under it. Rotate with `EMAIL_SEAL_KEY_PREVIOUS` while queued rows drain.
- **`WEB_BASE_URL` unset under `off` → `inviteUrl: null`**; the web falls back to its own origin. Under `ses`/`log` the boot refuses without it.
- **The worker's discovery query scans** — every arm filters on `status`, and no index leads with it; fine at invite volume (PENDING: a `(status, next_attempt_at)` index if the table grows).
- **The allowlist is checked twice** — at queue time and again at claim — so tightening it stops queued staging mail too.
