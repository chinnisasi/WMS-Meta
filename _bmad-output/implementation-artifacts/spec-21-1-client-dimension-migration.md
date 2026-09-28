---
title: 'Story 21-1 — client dimension migration (migration A)'
type: 'feature'
created: '2026-09-28'
status: 'done'
route: 'dispatch'
review_loop_iteration: 0
baseline_commit: '770617b'
context:
  - '_bmad-output/implementation-artifacts/epic-21-context.md'
  - '_bmad-output/specs/spec-3pl/schema.md'
  - '_bmad-output/specs/spec-3pl/architecture.md'
  - '_bmad-output/specs/spec-3pl/SPEC.md'
  - 'docs/design/SYSTEM-DESIGN.md'
  - 'docs/design/IMPLEMENTATION-GUIDE.md'
  - 'docs/design/modules/tenancy.md'
  - 'docs/design/modules/inventory.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** The WMS has no client concept, so it cannot hold different companies' goods in one building with attribution answerable from the ledger — the precondition for every 3PL story (21-2…21-8).

**Approach:** Land migration A: a `clients` table with exactly one system-owned `self` client per tenant, `client_id NOT NULL` backfilled on `skus`, `orders`, `purchase_orders`, `ledger_events`, and the two designed nullable columns (`bins.dedicated_client_id`, `users.client_id`) — guarded and proven on Epic 10-1's migration harness. D2C keeps working unchanged: every existing row belongs to the `self` client.

## Boundaries & Constraints

**Always:**
- AD-23: exactly one system-owned `self` client per tenant (partial unique index), created inside the registration transaction; `client_id` NOT NULL wherever it appears.
- Migration follows the 10-1 machinery: hand-written `drizzle/0040_*.sql` + journal entry + snapshot (git-added), fail-fast `RAISE` guard, pre-flight block listing every unmappable row at once, post-migration assertion that every row carries a client.
- Repo conventions: UUIDv7 ids, `tenant_id` on the new table, `*_tenant_isolation` policy on it, CHECKs in migration SQL only, no FK constraints (validated in the command tx).
- The migration test executes against seeded pre-migration data built from the repo's own migration journal (the `test/fractional-quantity.spec.ts` Part-A pattern).

**Never:**
- No RLS client clauses (`app.client_id`) and no isolation probe — that is 21-2's story; this migration only adds the standard tenant policy on the new table.
- No client CRUD API, no portal, no billing tables (migration B), no FE change, no mobile change.
- No representation change to any existing column (no type rewrites, no hash re-derivation) — the 10-1 "last in-place migration" licence is spent.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Backfill | Pre-migration DB with tenants + skus/orders/POs/ledger rows | Migration assigns every row to that tenant's `self` client; post-assertion passes | Any row without a client after UPDATE → fail-fast `RAISE` (migration aborts, tx rolls back) |
| Fresh tenant | POST /api/v1/tenants after migration | `clients` row (`code='self'`, `system_owned=true`) created in the SAME tx as the tenant | Tenant row exists with no self client → impossible (same tx); partial unique index would refuse a second |
| Duplicate self client | Second `system_owned` insert for one tenant | Rejected | Unique partial index `(tenant_id) WHERE system_owned` |
| Self client vocabulary | `status='departed'` on a system-owned client | Rejected by CHECK | — |

</frozen-after-approval>

## Code Map

- `drizzle/0039_cold_chain_order_index.sql` (latest) — **next index is 0040**; `drizzle/meta/_journal.json` + `meta/0039_snapshot.json` — the registration pair to extend.
- `drizzle/0026_fractional_quantity_milli_units.sql:57-67` — the fail-fast `RAISE` guard pattern to copy.
- `test/fractional-quantity.spec.ts` — the Part-A (pre-migration schema + seeded rows + in-tx apply) / Part-B (HTTP matrix) harness to copy; the model per IMPLEMENTATION-GUIDE §5.
- `src/modules/tenancy/registration.command.ts:61-133` — `register()` single tx: insert tenants → owner user → outbox → idempotency; add the self-client insert here.
- `src/modules/tenancy/receiving-bin.ts:45-49` — the lazy `ensure…InTx` seeding precedent (QC-HOLD) for the self-client ensure helper.
- `src/shared/db/schema.ts` — table definitions live here (e.g. `bins` with `systemOwned`, `schema.ts:280` precedent); `clients` registers here.
- `test/architecture.spec.ts:545,699` — ownership-block pattern (carriers describe) for the new `clients` block.
- `test/users.spec.ts:660-720` — `wms_rls_probe` shape (21-2 will reuse; not this story).
- RLS facts: 43 `*_tenant_isolation` policies, all `USING/WITH CHECK ("tenant_id" = NULLIF(current_setting('app.tenant_id', true), '')::uuid)`; the four scoped tables' policies at 0004:75, 0006:63, 0011:61, 0017:40.
- Zero `client_id`/`clientId` exists anywhere in `src/` or migrations today — greenfield.

## Tasks & Acceptance

**Execution:**
- [x] `src/shared/db/schema.ts` -- register the `clients` table (id uuidv7 PK, tenant_id, code, name, status, systemOwned, timestamps) -- TS mirror of the migration; `bun run db:generate` must report "No schema changes" once the migration lands. *(verified first-hand: `bun run db:generate` → "No schema changes, nothing to migrate 😴", tree clean)*
- [x] `drizzle/0040_client_dimension.sql` (+ `_journal.json` entry + `0040_snapshot.json`, git-added) -- create `clients`; insert one `self` client per existing tenant; add `client_id` to the four tables with backfill then NOT NULL; add `bins.dedicated_client_id`, `users.client_id`; unique `(tenant_id, code)` + partial unique `(tenant_id) WHERE system_owned`; CHECKs on status vocabulary and `system_owned ⇒ NOT departed`; `clients_tenant_isolation` policy; fail-fast guard + pre-flight + post-assertion -- the story's core deliverable. *(178 lines, read in full; journal idx-40 + snapshot in commit 4903bd0)*
- [x] `src/modules/clients/` -- minimal module: `clients.schema` re-export + `ensure-self-client.ts` (`ensureSelfClientInTx(tx, tenantId)`, idempotent, uuidv7 id) -- gives the table a module owner per AD-6 before 21-2+ build on it.
- [x] `src/modules/tenancy/registration.command.ts` -- call `ensureSelfClientInTx` inside `register()`'s transaction -- D2C tenants are born client-ready; no branch on "3PL mode".
- [x] `test/client-dimension.spec.ts` -- Part A: build a pre-0040 DB from the repo journal, seed tenants with skus/orders/POs/ledger rows, apply 0040 in one tx, assert every row carries the tenant's self client and the guard refuses re-application; Part B: over HTTP, register a tenant (self client exists, exactly one), confirm the four tables' writes carry `client_id = self` -- proves the migration AND the registration seam. *(10/10 under jest; two seeded tenants so a single-tenant mapping bug cannot pass)*
- [x] `test/architecture.spec.ts` -- `clients` ownership block (only the clients module writes `clients` tables; registration reaches it through the module's ensure function) -- closes the ownership question before other modules touch the table. *(25/25 under jest; the meaningfulness test asserts the ensure really writes the table and registration/ledger reach it through the seam)*

**Acceptance Criteria:**
- Given a pre-migration DB with tenants and rows, when migration 0040 applies, then every row of the four tables carries that tenant's `self` client and `bun run db:generate` reports no schema changes.
- Given a fresh tenant over HTTP, when registration completes, then exactly one `system_owned` `self` client exists for it, created in the same transaction (a failed registration leaves no client).
- Given any writer path, when the four tables gain rows, then each row's `client_id` is NOT NULL and equals the `self` client for D2C tenants.
- Given the architecture spec runs, when a non-clients module writes `clients` rows directly, then the test fails.

## Implementation Notes

- **Ledger backfill needs the append-only trigger dance** (defect found and fixed during implementation): migration 0040's `ledger_events` backfill is an UPDATE, which fires the 0006 `ledger_events_append_only` BEFORE UPDATE row trigger and would abort the migration. The migration disables the trigger, backfills, and re-enables it — all inside the migration's single transaction, so a failure rolls the disable back too. (0026's `SET DATA TYPE` table rewrite did not fire row triggers, which is why that migration needed no dance.)
- **Two harness-suite regressions during implementation, fixed by the implementer before commit:** (a) a fixture sweep wrongly added `client_id` to uom-precision's pre-0027 Part-A seed — reverted, with a comment explaining the Part-A DB is frozen at 0026 and needs no scaffolding; (b) fractional-quantity's chain verifier (a drizzle read) now requires `client_id` in the SELECT — the harness applies 0040 as explicitly-commented scaffolding after seeding. Note: that suite verifies the chain valid before and after the **0026** apply (its own subject); the chain's integrity across the 0040 apply is proven by client-dimension Part A's byte-identical `event_hash` assertions, not by fractional-quantity.
- **The 14 non-passing tests in the implementation agent's full-suite run are NOT pre-existing**: `/tmp/full-test.log` (09:36) is the run BEFORE the two fixes above; the post-fix re-run (`bun run test --` fractional + uom) is 53/53 — re-verified first-hand at step-03.

## Spec Change Log

## Review Triage Log

*Step-04, iteration 1. Layers: blind-hunter (16), edge-case-hunter (3), verification-gap (1 + 2 assurances). All claims verified first-hand against the diff and surrounding code before verdicts.*

| # | Finding (source) | Verdict | Evidence & route |
|---|---|---|---|
| 1 | No index on any new `client_id` column, while billing "aggregates over ledger_events constantly" (blind) | low | True (no indexes) but no consumer filters `client_id` in this diff; 21-2/21-4 will. Indexes are purely additive later (no representation change). **defer** → deferred-work.md, for the 21-2/21-4 specs. |
| 2 | No FK or tenant-consistency constraint `client_id → clients.id` (blind; edge-case) | false | Repo-wide convention: no FKs anywhere, validated in the command tx (CLAUDE.md, epics). The ensure resolves the client inside the caller's tenant-scoped tx — cross-tenant client ids cannot arise from any app writer. |
| 3 | Code↔migration deploy coupling undocumented — writers hard-fail where 0040 hasn't run (blind) | false | General repo deploy model: every migration-coupled feature (0026 milli-units included) behaves the same; migrations and code ship in one deploy. No new hazard class. |
| 4 | `ensureSelfClientInTx` stamps regardless of `status` (suspended self client) (blind) | false | No code path can suspend a client today (no CRUD API; vocabulary inert). AD-23's CHECK already bars `departed` for system-owned. The suspended-self semantics question belongs to the story that makes the state reachable (21-2 admin). |
| 5 | Helper's error arms untested: no-name throw, non-system `self` re-select refusal, concurrent conflict (blind) | low | True — the arms guard states the program cannot reach today (no client CRUD; tenant and self client are born in one tx). Fix = adding unit tests, not a direct correction → **reject**. Note carried forward: 21-2's spec should exercise these arms once the helper gains real consumers. |
| 6 | Byte-identity claim broader than its proof — Part A test 3 compares only `event_hash` + `quantity_delta`, not all pre-existing columns (blind) | low | True as filed. Hash byte-identity covers every hash-input column, and the UPDATEs set only `client_id` — but the header's claim is "all pre-existing columns", and the test proves less. **patch**: extend test 3 to capture all pre-existing columns of every seeded row before/after and compare. |
| 7 | `clients_tenant_isolation` ships with no probe; every other tenant-isolated table has one (blind + verification-gap primary, same root cause) | low | Verified: no `wms_rls_probe` test touches `clients`; app runs as table owner (RLS bypassed). The ratified story boundary puts the DB-level isolation probe in 21-2 — triage consciously confirms that deferral covers the tenants-only policy on `clients`, not just the `app.client_id` clauses. **defer** → deferred-work.md; 21-2's probe must cover the policy this migration added. |
| 8 | `CLIENT_STAMPED_TABLES` hand-maintained, not cross-checked against the migration (blind) | low | The list tests migration 0040, which is frozen at birth; a future `client_id` on a 5th table arrives with a new migration and its own suite. Cross-check machinery adds cost for no reachable drift. **reject**. |
| 9 | Raw self-client subselect copy-pasted ~10 sites in 6 test files (blind) | low | The identity predicate is frozen by AD-23 (self + system_owned, at birth) — it will not change. Cosmetic duplication. **reject**. |
| 10 | Post-assertion message names tables+counts but not tenant ids (blind) | low | Fires only on a tenant deleted mid-migration (the pre-flight exists precisely so this never happens). Cosmetic diagnostics on a near-unreachable path. **reject**. |
| 11 | §4 header says "four tables" but the section ALTERs six (bins/users are attribute columns) (blind) | low | Comment structure nit. **reject**. |
| 12 | fractional-quantity re-implements the migration-apply loop instead of sharing `migrationStatements()` (blind) | low | 8-line test-harness duplication; the two harnesses assert different migrations. Cosmetic. **reject**. |
| 13 | inbound.spec.ts fixture fabricates the self client as 'Foreign Vendor' (blind) | false | The fixture tenant has NO `tenants` row at all — raw probe rows for the cross-tenant RLS test — so the name=tenant-name invariant is vacuous for it, and the test asserts nothing about client names. The invariant governs migration/ensure-created clients, which the fixture does not simulate. |
| 14 | Guard paragraph's snapshot-missing motivation doesn't match the guard's mechanism (blind) | low | Documentation nit inside the migration header; the guard's actual job (refuse re-application) is unaffected and tested. **reject**. |
| 15 | Architecture raw-SQL regex misses schema-qualified/CTE write forms (blind) | low | Every architecture guard in this repo is a pattern scan with the same property; the drizzle-pattern check covers the drizzle writers, which are the only ones that exist. **reject**. |
| 16 | Part B failed-registration asserts a global `count(*) from clients` delta (blind) | false | The suite DB is created fresh per run (`useSuiteDatabase('clientdim')` — the NOTICE confirms), and no other test in the suite registers tenants, so the global delta of exactly 1 is exact within the run. |
| 17 | `onConflictDoNothing` target covers only (tenant_id, code); a partial-index conflict would 23505 instead of idempotently returning (edge-case) | false | The 23505 arm requires a system-owned NON-self client to already exist — unreachable under AD-23 (exactly one system-owned client per tenant, born 'self'; no other system-owned creator exists). If it were ever reached, a loud 23505 on the next write is the correct outcome, not silent adoption. The legitimate concurrent-ensure race conflicts on (tenant_id, code), which the target covers. |
| 18 | `bins.dedicated_client_id` / `users.client_id` can be set to another tenant's client (edge-case) | false | Nothing in this diff writes either column (nullable by design, left NULL, asserted NULL in Part A). The validation belongs to the future writer tx that sets them — the repo's no-FK convention puts it there. No reachable bad outcome. |
| 19 | Spec claim: fractional-quantity "verifies the chain valid both before and after" the 0040 scaffolding (edge-case) | claim-true, rejected | Verified TRUE — `chainBefore` is captured after the 0040 apply; no chain check precedes it. The fix is a spec-text edit → rejected per the rule. Corrected directly below as a step-03 factual error, not a code change. |
| 20 | VG assurances: (a) on PG 18.6 a WITH CHECK 42501 fires before a 23502, so the updated probe fixtures' NULL `client_id` subselects still yield the expected /row-level security/ errors; (b) the 0039→0040 snapshot delta adds only the designed objects | no defect | Both are verification results the layer ran itself; recorded for the record. |

## Design Notes

- **RLS client clauses deferred to 21-2** (deviation from spec-3pl's migration-A description, which bundles them): the ratified story table puts "second RLS session variable + fail-closed policies + DB-level isolation probe" in `21-2-client-isolation-rls`. Landing the clause in 21-1 without the DB-level probe ships an unverified leak-guard; landing it in 21-2 puts the enforcement and its proof in one story. `clients_tenant_isolation` (tenant-only) still lands here — every table gets one.
- **In-place licence justification** (the 10-1 "last in-place migration" caveat): backfilling a NEW column changes no representation — `event_hash`, quantity columns and all existing columns are byte-identical before/after; only inserts change shape. This is why an in-place migration is still correct pre-launch; state it in the migration header comment.
- **Portal persona**: `users.client_id` (nullable) lands here per design, but the fifth-persona question (new `user_role` value vs orthogonal to `client_id`) is 21-2/21-7's — the column is inert until a portal session exists.
- `departed` is in the status vocabulary now even though offboarding is a non-goal: CHECK widening needs DROP/re-ADD (0023/0024 precedent), so freezing the full designed vocabulary at birth is cheaper.

## Verification

**Commands:**
- `bun run test -- test/client-dimension.spec.ts` -- **10/10 passed (2.9s), verified first-hand at step-03.** IMPORTANT: run via jest (`bun run test -- <file>`), never the bare `bun test` CLI — bun's runner hangs forever on `expect(...).rejects` against postgres.js's Promise subclass (the query is never sent; see the be-bun-test memory). The suite's guard-refusal test bites: it re-runs the migration's first statement against the migrated DB and asserts the `RAISE`.
- `bun run test -- test/architecture.spec.ts` -- **25/25 passed (0.2s), verified first-hand.**
- `bun run test -- test/fractional-quantity.spec.ts test/uom-precision.spec.ts` -- **53/53 passed (4.7s), verified first-hand** (the migration-harness neighbours this story touched).
- `bun run db:generate` -- **"No schema changes, nothing to migrate 😴", verified first-hand** (schema.ts ↔ 0040 snapshot in sync).
- `git status --short` -- **clean, verified first-hand** (journal + snapshot committed in 4903bd0).
- `bun run lint && bun run typecheck` -- **both exit 0, verified first-hand.**

**Manual checks:**
- `drizzle/0040_client_dimension.sql` header states the in-place justification and names its test file. *(present, lines 7-16 + 24-27)*
- Writer coverage: `grep` for `.insert(skus|orders|purchaseOrders|ledgerEvents)` in `src/` finds exactly 5 sites (catalog import, ledger append, PO create, PO carried successor, order create) — all client-stamped through `ensureSelfClientInTx`.