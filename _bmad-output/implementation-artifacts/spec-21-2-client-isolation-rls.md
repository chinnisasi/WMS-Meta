---
title: 'Story 21-2 — client isolation RLS (app.client_id, policies, DB-level probe)'
type: 'feature'
created: '2026-09-28'
status: 'done'
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
- [x] `drizzle/0041_client_isolation_rls.sql` (+ journal idx 41 + snapshot copy, git-added) -- policy-only migration: recreate the four stamped tables' `*_tenant_isolation` policies with the extended predicate (DROP + CREATE, USING + identical WITH CHECK), plus the decided `clients_tenant_isolation` client clause; light fail-fast guard asserting the stamped tables carry `client_id`; header comment naming the probe file -- the story's core deliverable.
- [x] `src/shared/db/tenant-scope.ts` -- optional `clientId` on `withTenantTransaction`'s options that stamps `app.client_id` transaction-local via the same `set_config` idiom -- the session-variable plumbing 21-7 will consume; operator call sites unchanged.
- [x] `test/client-isolation.spec.ts` -- the DB-level probe (wms_rls_probe, advisory key 742105): portal-shaped session sees own rows and zero rows for the sibling client's skus/orders/POs/ledger events; WITH CHECK rejects foreign-client inserts with 42501 and allows own; operator-shaped session (client unset) still sees both clients; unscoped session sees zero rows; batches/stock rows ride their SKU join to the same isolation; the `clients`-table tenant policy probe (21-1 deferred-work carry-forward).
- [x] `test/tenant-scope`-level coverage -- the primitive sets both variables when clientId is given and leaves `app.client_id` untouched when omitted (operator shape preserved).

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

*Step-04, iteration 1. Layers: blind-hunter (15), edge-case-hunter (5), verification-gap (1 + 1 contrast note). All claims verified first-hand against the diff, the test file, the migration and the surrounding code before verdicts.*

| # | Finding (source) | Verdict | Evidence & route |
|---|---|---|---|
| 1 | `clientId: ''` slips past `!== undefined` and stamps the operator shape — the fail-closed primitive's one silent fail-open input, unpinned by any test (VG primary + BH-3 + EC-1, same root cause) | medium | Verified TRUE: the branch admits `''`, `set_config('app.client_id','',true)` → `NULLIF('','')` → NULL → the clause passes for every row. No production consumer exists (21-7 is the first), but the portal is the leak-risk concentration the design names. **patch**: throw on `''` in the clientId branch + Part-1 test; plus one policy-level probe documenting raw `''` = operator shape (the deliberate `NULLIF` contract). |
| 2 | No UPDATE or DELETE probes — WITH CHECK also governs UPDATE (a portal session rewriting its own row's `client_id` to the sibling's must refuse) and USING governs DELETE (cross-client DELETE silently deletes nothing) (BH-2) | medium | Verified TRUE — the suite proves INSERT + SELECT only, on the story whose deliverable IS the DB-level proof. **patch**: add the two arms (own-row `client_id` rewrite → 42501; sibling DELETE → 0 deleted). |
| 3 | The `clients` binding-column check is vacuous: `toContain('id')` is satisfied by `tenant_id` (BH-7) | medium | Verified TRUE — `id` is a substring of `tenant_id`, so the structural assertion proves nothing about the clients policy's binding column. **patch**: assert the full `"id" = NULLIF(current_setting('app.client_id'` expression. |
| 4 | The fail-fast guard checks only the four stamped tables, but section 2 also DROPs/CREATEs `clients_tenant_isolation` — a drifted DB fails mid-migration with 42704 instead of the guard's named diagnosis (BH-9 + EC-4) | low | Verified TRUE (guard VALUES list lacks 'clients'). Unreachable in the normal journal-ordered path, but the guard's own promise is incomplete for one line's cost. **patch**: add `('clients')` to the VALUES list. |
| 5 | `expectCount` builds SQL via `sql.unsafe` with string-interpolated table/predicate — an injection-shaped pattern inside the security-verification suite (BH-13) | low | Verified TRUE (`test/client-isolation.spec.ts:144-153`). Inputs are internal constants today; the pattern is still the wrong one to ship here. **patch**: interpolate the table through the postgres tagged template like every other probe. |
| 6 | Snapshot 0041 is 4-space JSON (0040/drizzle-kit is 2-space) and three new files lack trailing newlines — the next `db:generate` rewrites the whole snapshot (BH-11) | low | Verified TRUE first-hand (0041 4-space, 0040 2-space; `endswith('\n')` false). **patch**: reformat to 2-space + trailing newlines. |
| 7 | Direct un-joined reads on inherited tables (stock/batch, order/PO lines, bins, users, vendors…) return the sibling client's rows — only the join-shaped read is proven (BH-1 + EC-5) | low, by design | Verified TRUE at the DB level — and it is the ratified AD-24 placement decision ("tables referencing a SKU get no column — four more places for the value to disagree with itself", spec-3pl schema.md), documented in the spec's Design Notes, the 0041 header and clients.md. App-layer filters stay authoritative; the first portal consumer must route reads through the stamped tables. **defer** → deferred-work.md: 21-7's read paths must join through the stamped tables (or add EXISTS arms). |
| 8 | A portal session can UPDATE/DELETE its OWN `clients` row (name, status, system_owned), not merely read it — the policy grants write power the header doesn't state (BH-5) | low | Verified TRUE (one-policy-per-table shape; the insert arm is deliberately pinned by the probe). Unreachable: no app query mutates `clients` outside `ensureSelfClientInTx` (operator-shaped, registration-time), and 21-7 is read-mostly. Restricting arms adds policy complexity for an unreachable path. **reject**. |
| 9 | `clientId` non-empty non-uuid string should be regex-validated at the primitive (EC-2) | false | Verified: `setTenantScope` validates nothing either — the house idiom; a malformed non-empty value fails closed LOUDLY (22P02 from the policy cast on the first query — no leak, a hard error). Adding uuid validation would diverge from the tenant arm's contract for no reachable leak. |
| 10 | Wrap the policy's `::uuid` cast in a regex CASE so a malformed `app.client_id` binds to nothing instead of erroring 22P02 (EC-3) | false | Verified: the existing tenant arm behaves identically (malformed `app.tenant_id` → 22P02) — this is the house idiom, not a new hazard class. An error is fail-closed (no rows returned); changing it would make 0041's policies diverge from all 44 existing ones. |
| 11 | The guard has no biting test, unlike 0040's guard which client-dimension.spec.ts exercises (VG other-findings) | low | Verified TRUE. Reachable only by applying 0041 to a pre-0040 database — impossible in every normal path (journal order, CI migrations job). The biting test requires the optional Part-A harness the spec deliberately skipped for a policy-only migration. **reject** (cost exceeds value; contrast recorded here). |
| 12 | The STAMPED_TABLES comment claims a drift guard that doesn't exist — add an `information_schema` cross-check (BH-6) | low | Verified the comment; it states a caution about the future, not a claim of enforcement. Consistent with 21-1 triage #8: the list tests a frozen-at-birth migration; a fifth stamped table arrives with its own migration and suite, and cross-check machinery adds cost for no reachable drift. **reject**. |
| 13 | The 44-policy global count is brittle — the next legitimate policy anywhere breaks it opaquely (BH-8) | low | Verified present. The next story updates the count in the same commit that adds its policy — a one-line, locally-visible edit in a suite whose subject is the policy inventory. Cosmetic. **reject**. |
| 14 | The probe-role helper is the fourth copy (batch-serial, bin-admin precedents) — extract to test/support (BH-14) | low | Verified duplication exists; same class as 21-1 triage #9 (cosmetic duplication of a frozen pattern). Extraction is a test-infra refactor beyond this story's diff. **reject**. |
| 15 | Header never enumerates `users.client_id`/`bins.dedicated_client_id` as deliberately clause-free (BH-10) | low | Cosmetic doc nit; `docs/design/modules/clients.md` documents both ("nullable by design, inert until 21-7") and the spec's Boundaries record the decision. **reject**. |
| 16 | Header should state the owner-bypass assumption (no FORCE RLS; the guard applies to non-owner sessions) (BH-15) | low | Cosmetic doc nit; the assumption is documented in clients.md and the probe's existence encodes it. **reject**. |
| 17 | No interface-contract/module-doc update accompanies the new seam (BH-12) | not a code defect | Meta docs land last per the ordering rules — step-05 updates clients.md (the seam) and the wms-be contract. Recorded, not a diff finding. |
| 18 | Guard coverage note: 0041's guard can only trigger on out-of-order manual application (VG, folded into #11) | — | Same finding as #11; recorded once. |

## Design Notes

- **Why null-tolerant, not bare equality:** a bare `client_id = NULLIF(...)` clause would hide EVERY row from operator sessions (unset → NULL → no match), breaking cross-client waves and all existing operator flows. The ratified shape makes unset = the operator shape; the leak the design guards is a portal session with a wrong/empty client context binding to nothing rather than seeing everything. The residual exposure — a portal session that never sets the variable sees the whole tenant — is closed by 21-7, whose session layer is the only thing that creates portal sessions; this story lands the enforcement, the primitive and the proof.
- **Inherited tables need no clause and get none:** stock/batch/reservation rows carry no `client_id` (AD-24 placement is selective — "four more places for the value to disagree with itself"); their isolation rides on every consumer query joining through `skus`, which the policy now filters. The probe asserts the join-shaped query, which is how the app actually reads batches.
- **Why DROP + CREATE, not CREATE OR REPLACE:** ALTER POLICY with a new USING is equivalent here, but DROP+CREATE matches the repo's migration-idiom minimalism and reads identically to 0001/0003/0004's policy blocks.
- **Deferred decisions recorded here so they are not re-litigated:** client_id indexes → 21-4; fifth persona → 21-7; suspended-self semantics → the story that makes client CRUD real (21-1 triage #4 said "21-2 admin" but no CRUD exists in the ratified scope); cross-client wave test → the wave epic.

## Verification

**Commands (all re-run first-hand at step-03/step-04, wms-be on `feat/21-2-client-isolation-rls`):**
- `bun run test -- test/client-isolation.spec.ts` -- **17/17 passed** (jest; 14 pre-patch, 17 after the review patch). Never the bare `bun test` CLI (hangs on `.rejects` + postgres.js).
- `bun run test` (full suite) -- **796/796, 44/44 suites, exit 0 post-patch, verified first-hand** (793/793 pre-patch, implementer-run).
- `bun run db:generate` -- **"No schema changes, nothing to migrate 😴"** (policies are snapshot-invisible).
- `bun run typecheck` / `bun run lint` -- both exit 0.
- `db:migrate` + `db:verify` on the dev DB -- 0041 applied cleanly, round-trip clean (implementer-run).

**Manual checks:**
- `drizzle/meta/0041_snapshot.json` differs from `0040_snapshot.json` only in `id`/`prevId` (verified programmatically); post-patch it is a 2-space byte-style copy with a trailing newline.
- The five recreated policies carry the client clause on the correct binding column (`client_id` ×4, `id` on `clients`) — asserted non-vacuously by the structural test, re-verified by reading the migration.
- Bite-proofs (implementer-run): removing the `setClientScope` call fails exactly the 2 primitive tests; reverting the `skus` policy to tenant-only fails 5 probe tests.
- The patch's one deliberate deviation from the triage instruction: the 0041 guard's VALUES list became `(table, binding_column)` pairs — `clients` binds on `id`, so a literal `column_name='client_id'` row for it would have failed every database. Verified correct against the guard's actual mechanism.

**Review:** three layers (blind-hunter 15, edge-case 5, verification-gap 1), 18 triage rows, 6 patches applied and re-verified, 1 defer (inherited tables' join-riding read constraint → 21-7), 11 rejects with refutations. No loopbacks.
