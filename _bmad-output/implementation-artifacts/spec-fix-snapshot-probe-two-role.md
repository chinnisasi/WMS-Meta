---
title: 'Session-visibility fix — the §7d probe counts sessions it cannot see, and the provisioned app role can see them all'
type: 'bugfix'
created: '2026-10-16'
status: 'done'
route: 'dispatch'
review_loop_iteration: 0
baseline_commit: 'wms-be ea3ecbf13084c1d4df4371a7f0dce11d9109ec62'
context:
  - 'docs/design/IMPLEMENTATION-GUIDE.md'
  - 'docs/design/modules/tenancy.md'
  - 'docs/design/modules/billing.md'
  - '_bmad-output/implementation-artifacts/epic-9-retro-2026-10-14.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** This is Epic 9 retro action item 1, finding F1 (high). The design review corrected the diagnosis.

**What the §7d probe should do.** The probe is `openSessionsInTx` in `src/shared/db/open-transactions.ts`. It should refuse whenever a session is hidden from the probing role. On Postgres 18 it does not.
- A session of another role, seen by a role without `pg_read_all_stats`, has `backend_type`, `state`, `xact_start` and `xid` all NULL, with `query = '<insufficient privilege>'`.
- The probe filters `backend_type = 'client backend'` **before** it counts hidden rows. So a hidden session is silently dropped: `hidden = 0` and `oldest = NULL`.
- Reproduced on the dev database: as a non-superuser role, with a superuser transaction held open, the probe's own query returned `NULL | 0`.

**The two callers therefore proceed without their guarantee.** A transaction that began before the snapshot instant and is still open is invisible, so it can be missed. The callers are:
- the 9-3b audit export claim;
- the 21-4 storage snapshots.

**Why production hits it.** The production design runs two roles, via `scripts/provision-roles.sql`: `wms_app` for `DATABASE_URL`, and a BYPASSRLS `wms_auth` for `DATABASE_AUTH_URL`. The script never grants `pg_read_all_stats`, so every `wms_auth` session and every superuser or operator session is invisible to `wms_app`.

**What hid the defect:**
- Dev and CI run `DATABASE_URL` as the superuser, which sees everything.
- The two refusal tests stub the probe.
- The one real-probe test runs as the superuser.

**The retro got it wrong too.** It said "stays Preparing… forever"; the effect is the opposite. The docs promise "the job refuses and logs; it never guesses" (IMPLEMENTATION-GUIDE §7d; `billing.md:196`), and that promise is false today.

**Approach:**
- **Fix the probe.** It counts a hidden row whatever its `backend_type`, so a deployment that misses the grant refuses, as designed.
- **Fix the provisioning script.** It grants `pg_read_all_stats` to the app role, so the provisioned two-role deployment sees every session and runs.
- **Prove both.** A new suite runs the real script under non-superuser roles, against the real probe.

## Boundaries & Constraints

**Always:**

- **The probe's filter.** It becomes `datname = current_database() and pid <> pg_backend_pid() and (backend_type = 'client backend' or backend_type is null)`.
  - `hidden` keeps its rule: `state is null or query = '<insufficient privilege>'`.
  - The `oldest` aggregate is unchanged; a hidden row's `xact_start` is NULL and already filtered out of it.
  - The comment states why `backend_type is null` is admitted: hidden rows NULL every per-backend column except `datname` and `usename`. A visible non-client backend (autovacuum, walsender) is still excluded by its non-null type.
- **Accepted consequence.** Without the grant, a hidden autovacuum worker in this database also counts as hidden, causing a brief refusal. This fails safe, and with the grant such a worker shows its type and is excluded.
- **The grant.** `scripts/provision-roles.sql` gains `grant pg_read_all_stats to wms_app;`, with a comment naming the §7d probe and its two callers.
  - The script stays idempotent: re-running the grant gives only a NOTICE.
  - `wms_auth` gets nothing new.
- **The log text.** The refusal logs at `audit-export.runner.ts:241` and `storage-snapshot.ts:192-193` change their advice to grant `pg_read_all_stats` to the app role: they name `current_user` and print the exact `GRANT` statement, and point to `scripts/provision-roles.sql`. *(Amended by the human, 2026-10-16, after code review: the "keep every app connection on one role" alternative is dropped. With the fixed filter, hidden autovacuum workers count, so a one-role deployment without the grant refuses at random.)* The comment at `storage-snapshot.ts:34-36` changes the same way. No other runner or snapshot logic changes.
- **The new suite, `test/session-visibility.spec.ts`.** It runs against the suite database URL; the probe filters on `datname`.
  - **Setup.** Read `scripts/provision-roles.sql` and make these replacements, then run the result as one multi-statement `tx.unsafe` in a superuser transaction holding `pg_advisory_xact_lock(742105)`, the cross-suite role lock from `test/users.spec.ts:664`:
    - `wms_app` → `wms_sv_app` and `wms_auth` → `wms_sv_auth` (exact whole-word replacement; neither name contains the other);
    - the two `change-me-*` placeholders → test passwords.

    Pass `onnotice: () => {}` so re-runs stay quiet.
  - **Held sessions.** One `wms_sv_auth` connection opens a transaction, reads its own `now()` (the expected start), and holds the transaction open. A second `wms_sv_auth` connection stays connected and idle.
  - **Positive case.** Run `openSessionsInTx` through `withTenantTransaction` on a drizzle database created from the `wms_sv_app` URL; any uuid serves as the tenant id. Expect:
    - `hidden: false`;
    - `oldestXactStart` ≤ the held transaction's start (both truncated to milliseconds);
    - the held transaction **seen**, not merely tolerated.
  - **Negative control.** Under the same advisory lock, `revoke pg_read_all_stats from wms_sv_app`, then re-run the probe. Expect `hidden: true` and `hiddenCount ≥ 2` (the two auth sessions). Re-grant under the lock in a `finally`. Revocation takes effect in sessions already open, so no reconnect is needed.
  - **Regression pin.** That negative control is also the probe-filter regression test: with the old filter it reads `hidden: false`.
  - **Re-run.** Executing the substituted script a second time succeeds and changes nothing.
  - **Teardown.** Release the held transaction, close every connection, and end the drizzle client with `$client.end()`. The roles are cluster-wide and harmless to leave (the `wms_rls_probe` precedent).
- **The docs follow the code.**
  - **IMPLEMENTATION-GUIDE §7d** gains a gotcha: a hidden row has a NULL `backend_type`, so never filter on `backend_type` before counting hidden rows. The probe silently ignored hidden sessions until this fix.
  - **The deploy requirement** now reads "the app role must hold `pg_read_all_stats`; the provisioning script grants it" at every site, with no one-role alternative (amended, as above):
    - IMPLEMENTATION-GUIDE §7d;
    - `tenancy.md:508`;
    - `billing.md:196,214`;
    - `docs/repos/wms-be/README.md:300`;
    - `wms-be/README.md:63`;
    - PENDING (billing, the session-visibility entry).
  - **Managed Postgres.** The README adds the check `select pg_has_role('wms_app', 'pg_read_all_stats', 'USAGE')`. On PG16+ a grant needs ADMIN OPTION on `pg_read_all_stats`, so on a managed Postgres the master user runs it; verify on the target.
  - **The retro.** The retro document corrects F1's diagnosis, closes action item 1, and records action item 6 as partly served. The suite proves the probe under two roles, not the jobs end to end.

**Never:**
- No change to the callers' claim or snapshot logic beyond the log text, and no new env var.
- No grant to `wms_auth`.
- No switch of CI's `DATABASE_URL` to a non-superuser role (that is action item 6).
- No exclusion of any role's sessions from the probe.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Provisioned app role | Script run; an auth session holds a transaction; an idle auth session | `hidden: false`; `oldestXactStart` ≤ the held start | — |
| Grant missing | `pg_read_all_stats` revoked | `hidden: true`, `hiddenCount ≥ 2`; both jobs refuse and log | — |
| Script re-run | Executed twice | Succeeds; nothing changes | — |
| Grant deleted from the script | Script text without the grant | Positive case fails | — |
| Existing behaviour as superuser | The existing suites | Unchanged; `metering.spec.ts` and `audit-export.spec.ts` stay green | — |

</frozen-after-approval>

## Code Map

Paths are under `workspace/core/backend/wms-be`.

- **The probe:** `src/shared/db/open-transactions.ts:20-35`, the filter at `:26-28`.
- **Its callers:** `src/modules/tenancy/audit-export.runner.ts:122,218,236-243` (the log at `:241`); `src/modules/billing/storage-snapshot.ts:34-36` (comment), `:187-195` (the refusal log at `:192-193`), `:266`.
- **The script:** `scripts/provision-roles.sql`, with its role DO block, the `change-me-*` placeholders, and the schema and table grants.
- **Roles and tests today:**
  - `src/shared/db/db.ts:11-12` (`createDatabase`, `max: 10`) and `:31-47` (`createLazyAuthDatabase`);
  - `test/support/global-setup.cjs:59-69` (`wms_auth_probe`, `wms_rls_probe`);
  - `test/support/suite-db.ts:56,62` (each suite database is cloned from `wms_template`; its auth URL uses `wms_auth_probe`);
  - `test/users.spec.ts:655-700` (the role-creation pattern under lock 742105, and rewriting the URL's username and password).
- **Probe tests that missed it:** `test/audit-export.spec.ts:741` (stub); `test/metering.spec.ts:936-954` (stub, plus a real probe run as the superuser).
- **Tenant transaction:** `src/shared/db/tenant-scope.ts:28,68`.
- **Docs:**
  - `docs/design/IMPLEMENTATION-GUIDE.md` §7d ("The price is visibility");
  - `docs/design/modules/tenancy.md:508`;
  - `docs/design/modules/billing.md:196,214`;
  - `docs/repos/wms-be/README.md:300`;
  - `wms-be/README.md:63`;
  - `docs/design/PENDING.md` (billing);
  - `_bmad-output/implementation-artifacts/epic-9-retro-2026-10-14.md` (F1, action items 1 and 6).

## Tasks & Acceptance

**Execution:**
- [x] `src/shared/db/open-transactions.ts`: the filter and its comment.
- [x] `scripts/provision-roles.sql`: the grant and its comment.
- [x] Log text and comment: `audit-export.runner.ts:241`, `storage-snapshot.ts:34-36,192-193`.
- [x] `test/session-visibility.spec.ts`: every matrix row.
- [x] **Meta docs:** the §7d gotcha; the deploy-requirement sites; the README check; PENDING; the retro corrections.

**Acceptance Criteria:**
- Given the provisioned two-role setup, when the probe runs as the app role while an auth-role transaction is open, then it sees that transaction and reports nothing hidden.
- Given the grant missing, when the probe runs, then it reports the hidden sessions and both jobs refuse instead of proceeding.
- Given the full BE suite, lint and typecheck, when run, then they pass.

## Implementation Notes

Built on wms-be `fix/snapshot-probe-two-role` (`ea3ecbf..b16c133`, one commit with the code-review patch). Re-verified 2026-10-16: full BE run 83/84 suites, 1974/1975 tests; the one failure (`test/reporting.spec.ts`, untouched by this story) passes alone 25/25, a load flake. Lint and typecheck clean.

- **Setup revokes before running the script.** The roles are cluster-wide and persist across runs, so a grant left by an earlier run would let the positive case pass with the grant deleted from the script. The suite's setup revokes `pg_read_all_stats` from `wms_sv_app` (when the role exists) under lock 742105, then runs the substituted script — so the "grant deleted from the script" matrix row genuinely fails the positive case.
- **The substitution is asserted.** The suite checks the original script still contains `wms_app`, `wms_auth` and both `'change-me-*'` placeholders, and that none survive substitution — a renamed role or placeholder fails loudly instead of running the script against the real role names. The script's header comment mentions `'change-me-*'` (generic), which is left as is.
- **Extra pins beyond the matrix.** One test pins the provisioned role shape (`wms_sv_app` plain with `pg_read_all_stats`; `wms_sv_auth` BYPASSRLS without it). The negative control re-probes after the re-grant (visibility restored); the re-run compares each role's attributes, membership, table-grant count and schema usage before and after.
- **Mutation checks (run, then reverted):** the old filter → the negative control fails (`hidden` expected `true`, received `false`); the grant line deleted from the script → the role-shape and positive cases fail.
- **Code-review round 1 (after the human's amendment dropping the one-role alternative):**
  - The refusal logs call `sessionVisibilityAdviceInTx(tx)` (only on the refusal path), which reads `quote_ident(current_user)` and prints `GRANT pg_read_all_stats TO <role>;` with a pointer to the script. The one-role advice is gone from code, script, READMEs and meta docs.
  - `checkSessionVisibility(db, logger, worker)` (`shared/db/open-transactions.ts`) runs once from `AuditExportWorker` / `StorageSnapshotWorker` `onApplicationBootstrap` when the worker is enabled, on the app `DATABASE` (injected as an optional last constructor parameter): one warning when `pg_has_role(current_user, 'pg_read_all_stats', 'USAGE')` is false, one warning when the check itself fails, never a throw. Tested in the suite against the real non-superuser role (granted → silent; revoked → exactly one warning with the GRANT) and with a stub that rejects.
  - The script header says re-running is safe (existing roles keep their passwords), gives the one-line fix, and qualifies the NOTICE claim as "re-run by the same grantor".
  - The suite: the held start races the transaction's settlement; existing test roles get their passwords reset under the lock; the positive case asserts equality to the millisecond; every connection asserts `current_user`; after the revoke, `pg_has_role(…, 'MEMBER')` is asserted false before the negative probe.
- **The managed-Postgres check** lives in `wms-be/README.md` (the worker section) and `docs/repos/wms-be/README.md` (the storage-snapshot worker line).

## Spec Change Log

## Review Triage Log

Design review (2026-10-16), one backend lens with SQL experiments on PG 18.6. 8 findings.

| # | Finding | Verdict | Disposition |
|---|---|---|---|
| 1 | Hidden rows have a NULL `backend_type`, so the probe's `backend_type = 'client backend'` filter drops them before counting. The probe never detects a hidden session, and the jobs **proceed** without the guarantee. The spec, the retro and the docs assumed it refused | high (reproduced by the reviewer and again on the dev database: `NULL \| 0` as a non-superuser with a superuser transaction open) | Fixed: Problem rewritten; the probe filter is in scope; a §7d gotcha; the retro corrected; the negative control is now the regression pin |
| 2 | Once the filter is fixed, a hidden autovacuum worker would count as hidden without the grant | medium (unverified; it fails safe) | Accepted and recorded |
| 3 | The revoke and re-grant were unserialized and unguarded | medium | Fixed: under lock 742105, re-grant in `finally` |
| 4 | Doc, log and comment sites incomplete | medium (verified) | Fixed: all listed; the log text change allowed |
| 5 | Test details implicit (database URL, tenant id, client end, `now()` compare, notices, substitution) | low | Fixed |
| 6 | Managed-Postgres note had no concrete check | low | Fixed: the `pg_has_role` query; ADMIN OPTION on PG16+ |
| 7 | The query-text claim slightly overstated | low (verified: `inventory.facade.ts:583` inlines only a fixed `LEDGER_DOCUMENT_KEYS` name; no parameterless `.unsafe` with values in `src`) | Fixed: Design Notes names both |
| 8 | Action item 6 is only partly served: the probe is proven, not the jobs end to end | low | Fixed: wording |

Code review (2026-10-16), three layers: blind hunter (B), edge-case hunter (E), verification gap (V). V found no gaps; it independently reproduced the filter fix (old `hidden = 0`, new `hidden = 1`).

| # | Layer | Finding | Verdict | Disposition |
|---|---|---|---|---|
| 1 | B, E | With hidden rows now counted, a hidden autovacuum worker refuses a one-role deployment without the grant, so the documented "keep one role" alternative no longer works | medium (follows from the fix; matches design review #2) | **Human decision (2026-10-16): drop the alternative and require the grant.** Frozen wording amended. Patch: docs, the script comment and both logs (`current_user` plus the exact `GRANT`) |
| 2 | B | The grant exposes every session's query text to the app role; a narrower `SECURITY DEFINER` function was not considered | low (verified: values travel out of band; `$n` placeholders only) | **Human decision: keep the grant.** Patch: the trade-off and the definer-function alternative recorded in the README and Design Notes |
| 3 | B | Visible long transactions (an idle-in-transaction psql, a long `pg_dump`) now hold both jobs back, and this is undocumented | medium (the intended consequence of the fix) | Patch: PENDING and README, with `idle_in_transaction_session_timeout` and backup timing advice |
| 4 | B | A missing grant is found only at the first tick, with one error per scope per tick | low | Patch: one boot-time warning from each enabled worker when `pg_has_role(current_user, 'pg_read_all_stats', 'USAGE')` is false |
| 5 | B | The script header doesn't say a re-run is safe or that passwords are ignored for existing roles, and offers no one-line fix | low | Patch: the header says so and gives the one-line `GRANT` |
| 6 | E | `beforeAll` hangs until the jest timeout if the held auth transaction rejects before reporting its start (a login failure) | low | Patch: race the start against the transaction's settlement |
| 7 | E | The script never resets the password of a role that already exists, so leftover test roles can't log in | low | Patch: `alter role … password` before running the script |
| 8 | B | The positive case asserts `≤`, so an older foreign transaction would also pass | low | Patch: assert the oldest equals the held start to the millisecond (no other transaction in the suite database is older) |
| 9 | E | A unix-socket `DATABASE_URL` silently ignores the rewritten username | low (CI and dev use TCP) | Patch: assert the rewritten URL carries the user |
| 10 | E | On PG16+, a membership granted by another grantor survives the revoke | low (the suite's roles are only ever granted by the superuser) | Patch: assert `pg_has_role(…, 'MEMBER')` is false after the revoke |
| 11 | E | "A re-run only raises a NOTICE" holds only for the same grantor | low | Patch: reword the comment |
| 12 | B | The managed-Postgres grant path is unverified | low | Rejected: already stated as "verify on the target" with the `pg_has_role` check |
| 13 | B | No end-to-end run of the callers as the unprivileged role | low (V verified the stub plus probe coverage meets at both ends) | Rejected: action item 6 holds it |
| 14 | B | The test leaves LOGIN roles with fixed passwords on dev and CI clusters | low (the `wms_rls_probe` precedent) | Rejected |
| 15 | B | Per-scope refusal log noise | low (it predates this story, from 21-4) | Rejected: #4 adds the one early warning |

## Design Notes

**Why grant rather than exclude the auth role.** Excluding the auth role's sessions would rest the proof on an unenforced convention, that `wms_auth` never writes a row any snapshot reads, while it holds INSERT, UPDATE and DELETE grants today. The grant makes the probe see every session, including the auth role, an operator's psql and a backup, so the proof stays a proof.

**Why fix the probe as well as the grant.** The grant alone makes the provisioned deployment correct. But any deployment that misses it, or a role later added without it, would again silently skip invisible sessions. Counting hidden rows restores the documented promise: refuse, never guess.

**Cost of the grant.** `pg_read_all_stats` also exposes other sessions' query text. postgres.js sends parameters out of band, so parameterized text shows `$n` placeholders. The one inlined fragment, `inventory.facade.ts:583`, is a key name from the fixed `LEDGER_DOCUMENT_KEYS`, never a value. No `.unsafe()` in `src` carries literal values.

**The narrower alternative, not taken (human decision).** A `SECURITY DEFINER` function owned by a stats-reading role, returning only `min(xact_start)` and the hidden count, would give the probe what it needs without exposing query text to the app role. It was considered and not taken; the exposure is limited to `$n` placeholders as above, and the trade-off is recorded in `wms-be/README.md` and IMPLEMENTATION-GUIDE §7d.

**A consequence of full visibility.** Every session is now visible, so a long visible transaction (an idle-in-transaction psql, a long `pg_dump`) holds both jobs back until it ends. Recorded in PENDING (billing) and the README, with `idle_in_transaction_session_timeout` and backup timing as the advice.

## Verification

**Commands** (BE runs one jest invocation at a time):
- `cd workspace/core/backend/wms-be && bun run test -- test/session-visibility.spec.ts` -- expected: all pass, and the negative control reads `hidden`.
- `cd workspace/core/backend/wms-be && bun run test && bun run lint && bun run typecheck` -- expected: green.
