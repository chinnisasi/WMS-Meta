# Implementation guide (low-level design)

**Read this before writing backend code.** It is the set of patterns every story repeats. Following it is not style preference — most of it exists because a review caught the alternative failing.

Companion docs: `SYSTEM-DESIGN.md` (how the system fits together), `../repos/wms-be/README.md` (what the API exposes).

---

## 1. The command skeleton

Every mutating operation is a command service method. **The order below is load-bearing** — each step exists because something breaks if it moves. `putaway/bin-state.command.ts` is the tightest complete example; `outbound/pack.command.ts` is the richest.

**Three tiers, not two.** Where a check lives is decided by *what it can do*, and getting this wrong ships a real defect (story 10.2 finding #17):

| Tier | What lives here | Why |
|---|---|---|
| **Above the transaction** | Cheap **request-shape** checks needing no DB row — a serial count against a quantity, a malformed id | They are the same checks in the same order they always were. A malformed request must still answer **400, not 404**, and one carrying a used key must still answer **400, not replay** |
| **Inside, before replay** | Authority (`assertPermission`) | An unauthorised caller must not learn what exists from your error messages |
| **Behind the replay lookup** | Only rules that can **tighten** — a precision refusal, a new vocabulary constraint | A committed op must re-serve its snapshot whatever today's rules say |

`inventory.command.ts:243-251` and `:302-312` carry this distinction in their own comments; read them before moving a check.

```ts
async doThing(command: DoThingCommand, idempotencyKey: string): Promise<Snapshot> {
  // 0. Cheap SHAPE checks that need no DB row stay HERE, above the transaction.
  assertSerialCountMatches(command);

  // 1. Hash the payload BEFORE the transaction. Fixed key order.
  //    Normalise collections first — key order must not make a replay look different.
  const payloadHash = hashCommandPayload({ tenantId, ...fields });

  return withTenantTransaction(this.db, command.tenantId, async (tx) => {
    // 2. Authority FIRST, inside the tx, re-read from the DB every time.
    //    Before any validation 400, before any state is touched.
    assertPermission(await getMemberRoleIn(tx, tenantId, actorUserId), 'thing.execute');

    // 3. Replay lookup. A key that already committed returns its snapshot and
    //    NOTHING below this line runs.
    const replayed = await this.replay(tx, tenantId, idempotencyKey, payloadHash);
    if (replayed !== null) return replayed;

    // 4. Parent-scope asserts (warehouse in tenant, bin in warehouse, sku in tenant) → 404.
    // 5. Lock the target row `.limit(1).for('update')`, 404 if absent.
    // 6. Re-run replay() UNDER THE LOCK — the same-key race fix.
    // 7. Guards against the locked row, before any write.
    // 8. The write, conditional where a terminal transition is involved:
    //      .where(eq(table.status, 'expected')).returning()
    // 9. outbox.append(tx, { messageId: uuidv7(), tenantId, type, occurredAt, payload })
    // 10. tx.insert(auditEvents)
    // 11. tx.insert(idempotencyKeys) LAST — unique violation → 409 "Concurrent idempotent request"
    //
    // Return post-commit work from the callback; never do it inside.
  });
}
```

**Why the order:**

- **Authority before validation.** Stated in `api/inventory.controller.ts`: *"the capability assert precedes any validation 400"*. Otherwise an unauthorised caller learns what exists from your error messages.
- **Replay before everything else.** A committed op must re-serve its snapshot whatever the current rules say. Story 10.2 moved all nine quantity conversions off the controller edge into the commands for exactly this reason: an edge-level refusal answers 400 to an op that already committed.
- **Idempotency key last.** It is the commit marker. Written earlier, a later failure leaves a key with no work behind it.
- **Post-commit work returns from the callback.** Valkey counter mirrors run after the transaction commits (journal-first). A decrement that outlived a rollback reads as ATP the journal still holds.

**Lock ordering across lock families (story 5-1's review defect).** When a command needs more than one lock family — bin-row `.for('update')`, the serial advisory locks, the per-warehouse advisory — derive the order from the codebase's canonical acyclic chain, **bin-row → serial advisory → warehouse advisory** (documented at `inventory.facade.ts`'s `lockWarehouseInTx` doc and restated at `pick.command.ts`; sorted by uuid within a family when there are several). Do NOT invent a per-command order from what "feels safe": the ledger's `appendMovement` re-acquires the warehouse advisory inside the append, so any writer that takes the advisory before its bin rows deadlocks against putaway/pick, which hold the bin row and block on the advisory inside their own append. And any **staleness gate (an epoch compare, a re-read-then-assert) runs UNDER the locks**, never before them — a pre-lock read races the concurrent write it is guarding against and lets genuinely-moved state slip past the refusal (read → lock → compare).

### Post-commit side effects must not throw

```ts
// dispatch.command.ts: "NOTHING HERE MAY THROW"
for (const scope of restores) {
  try { await this.inventory.restoreReservedUnits(...); }
  catch (err) { this.logger.error(...); }   // log, never rethrow
}
```

The transaction already committed. Throwing returns 500 for work that succeeded, and a replay then serves the stored snapshot without re-attempting the mirror. Counters self-heal via the reaper's parity pass; a 500 does not.

---

## 2. Type boundaries — where values change shape

**This is the single richest source of defects in this codebase.** Four boundaries, each with a rule.

| Boundary | Behaviour | Rule |
|---|---|---|
| **postgres.js → JS** | `int8`/`bigint` comes back as a **string**; `int4` as a number | Every raw-SQL read of a bigint column needs `Number(...)` at its boundary. `binOccupancyInTx` is the model |
| **Drizzle `bigint`** | `mode: 'number'` maps via `Number(value)`; `mode: 'bigint'` returns a real BigInt | Use `mode: 'number'`. BigInt **throws on `JSON.stringify`**, and `quantity_delta` is serialised into the ledger hash chain |
| **JS / Lua doubles** | Exact only to 2⁵³ | Quantities are milli-units, so the usable ceiling is ~9.0 × 10¹² base units. `assertExactQuantity` guards it |
| **Valkey Lua** | Lua 5.1 numbers are IEEE doubles; `tostring` uses `%.14g` | Counters stay INCRBY-parsable integer strings. Never a decimal, never exponential notation |
| **base ↔ milli** | Base units on the wire; milli-units below the command line; base units back out | **The richest source of defects in the last two stories.** Convert *inside* the command, behind the replay lookup — never at the controller edge |

**Two concrete traps that shipped and were caught in review:**

```ts
// Trap 1 — a `::bigint` sum typed as a number, then compared strictly.
const rows = await db.execute(sql`... coalesce(sum(quantity),0)::bigint as reserved ...`)
  as unknown as { reserved: number }[];        // ← the cast LIES
if (counter !== reserved) { /* ALWAYS true: number !== string */ }

// Trap 2 — an untyped bound parameter beside an integer literal.
sql`greatest(${delta}, 0)`          // Postgres resolves this to int4 → 22003 overflow
sql`greatest(${delta}::bigint, 0)`  // correct
```

**The base↔milli floor, which has now shipped twice.** `assertExactQuantity` guards the 2⁵³ *ceiling*. Nothing guards the *floor*: a positive value below half a milli-unit rounds to **zero**. That filed a real pick as an empty-bin short pick (10.1 #6) and made a `0.4` bin capacity permanently unfillable (10.2 #9). **A non-zero input that scales to zero must be refused, never written.**

**The nine quantity write edges** — every one needs conversion, precision validation, and a test that sends a *fractional* value. A suite seeding `pcs` and whole integers proves nothing: `inventory.controller` adjustments · `outbound` order lines, pack scan, pick qty · `receiving` GRN lines · `inbound` PO create and amend · `putaway` placements · `catalog` import reorder fields.

`test/architecture.spec.ts` guards the `::int` and untyped-parameter classes. When you add a quantity-bearing query, assume the guard is the only thing standing between you and a production overflow.

---

## 3. Migrations

Checklist. **Every item has been missed at least once.**

- [ ] `drizzle/NNNN_descriptive_name.sql` — hand-named when hand-written
- [ ] **A journal entry** in `drizzle/meta/_journal.json` (`{idx, version, when, tag, breakpoints}`), `tag` matching the filename
- [ ] **A `drizzle/meta/NNNN_snapshot.json`, and `git add` it.** Story 10.1 shipped one untracked; drizzle-kit diffs against the newest *committed* snapshot, so the next `db:generate` on another machine emits a duplicate type change, and a plausible "fix" applies the data change twice
- [ ] RLS policy for any new table — **migration SQL only, never `schema.ts`**
- [ ] CHECK constraints — same rule. Widening one means DROP then re-ADD (the 0023/0024 precedent)
- [ ] **A CHECK arm over a NULLABLE column must say `IS NOT NULL` before `IN (…)`.** `NULL IN (…)` is NULL, and a CHECK treats NULL as a pass — 0013's `po_id IS NULL AND blind_reason_code IN (…)` admitted a GRN with neither a PO nor a reason for three epics; nothing noticed until 21-6's migration probed it (0064 closed it)
- [ ] **Probe every new CHECK in the post-migration assertion with a refused insert** (and one accepted shape, rolled back by a sentinel exception, so a CHECK that refuses everything fails too) — 0064 is the model; it is what caught the hole above
- [ ] `bun run db:generate` afterwards must report **"No schema changes"** — the only check that the hand-written SQL and `schema.ts` agree
- [ ] `git status --short` must show **no untracked files**
- [ ] **The migrator applies every pending migration in ONE transaction** (`drizzle-orm/pg-core/dialect.js` wraps the whole pending set in one `session.transaction`), and Postgres refuses to USE an enum value inside the transaction that added it (`55P04`). So **never use a new enum value in the migration that adds it — nor in any later migration that might run in the same deploy**: compare `col::text` in a CHECK, and never write the new value in a probe. Splitting the `ALTER TYPE … ADD VALUE` into its own file does not help — both files still run in one transaction. 0065 (story 21-7, `user_role` gains `client`) is the model: the pairing CHECK compares `role::text`, and the direction that needs a `client` row is proved in jest, where the value has long been committed

**For a data migration, additionally:**

- [ ] A **fail-fast guard** at the top that `RAISE`s if already applied. A re-run that silently transforms data twice passes every CHECK and nothing notices
- [ ] A **pre-flight block** listing everything unmappable at once — an operator should fix all rows in one pass, not one row per run
- [ ] **Paired columns round together.** Rounding `ordered_qty` and `received_qty` independently can invert their relationship
- [ ] **Dedupe BEFORE the UPDATE when rewriting a column in a unique index.** Normalising two rows onto the same value raises `23505` and aborts the deploy mid-migration. Dedupe on the *resolved* value, ahead of the rewrite — not after (10.2 #5)
- [ ] **A test that executes it against seeded pre-migration data.** See §5

RLS policy shape — the `NULLIF` is load-bearing, because PG18 returns `''` for an expired transaction-local setting and the row must then be invisible, not an error:

```sql
CREATE POLICY "t_tenant_isolation" ON "t"
  USING ("tenant_id" = NULLIF(current_setting('app.tenant_id', true), '')::uuid)
  WITH CHECK ("tenant_id" = NULLIF(current_setting('app.tenant_id', true), '')::uuid);
```

No FK constraints anywhere — uuid column plus index, validated in the command transaction.

---

## 4. Controlled vocabularies

Uniform across eleven enums. **Three mirrored layers:**

1. **TS tuple** beside the command that owns it — `export const X = [...] as const` + `type = (typeof X)[number]`
2. **DB CHECK** in a migration — `CHECK ("col" IN (...))`. Widening drops and re-adds
3. **API** — `@IsIn(X)` + `@ApiProperty({ enum: [...X] })` over *the same tuple*

**A nullable enum must list `null` in its values** (8-2b): `@ApiProperty({ type: String, nullable: true, enum: X })` exports `nullable: true` but the generated FE type drops the `| null` (hey-api reads the enum), so a client sees `'manual' | 'gateway'` for a column that is null on every pending row. Write `enum: [...X, null]`. Older DTOs (`InvoiceEntryDto.supplyType`) still carry the lossy form.

Plus **an e2e test pinning the TS list against the DB constraint** (`orders.spec.ts` does this for `ORDER_STATUSES`). Without it the three copies drift silently.

**Replacing a vocabulary, list or guard set: the new one must admit everything the old one did, asserted mechanically.** Story 10.2 replaced a 57-entry allowlist with a 24-entry one and silently made eleven units unrepresentable; any stored row using one would have aborted the migration. The fix is the pattern to copy: **freeze the old set in the new file and assert at module load** that every member still resolves. A review is not a substitute for an assertion.

**A guard over free text must fail CLOSED.** An allow-list of what is permitted, never a deny-list of what is forbidden — every spelling nobody thought of is a silent accept. The same rule governs status guards: an allow-list of legal states, so a new state arm is a compile or runtime error rather than a silent fall-through (`outbound.md` Gotchas #1, #2, #11).

**Changing the representation of a hashed field is a cross-deploy break.** Idempotency payload hashes and `source_payload_hash` are computed over command fields; change a field's *units* or shape and no key written by the deployed build can replay — it answers `422`, or `order-source-conflict` for a channel redelivery. 10.2 did this across nine commands in five modules. Decide it explicitly, record it, and pin it.

**A command that the sync-report replay rebuild can re-execute receives its stored payload RAW (21-6).** Optional keys a device omitted arrive as `undefined`, not `null`, and every `=== null` check then takes the wrong branch (`grn.submit` 500'd on a payload without `weightsGrams`). Normalise each optional field (`?? null`) right after hashing and before any rule reads it — never in the hash itself, whose shape is the cross-version contract.

**Adding an optional field to a hashed payload: the conditional-key exception (8-1d).** The house convention is an always-present key (`destination: … ?? null`, `consigneeGstin`), and each one added that way was an accepted, pinned break — every in-flight key answered `422`, every channel redelivery `order-source-conflict`. For a field almost no request carries, that break buys nothing, so 8-1d's `consigneeLegalName` joins **both** order hashes (`payloadHash` and `sourcePayloadHash`) **only when present**: normalised first (JS trim, blank = absent), then spread in at a fixed position (right after `consigneeGstin`) as `...(name === null ? {} : { consigneeLegalName: name })`. A request without it hashes byte-for-byte as before. Rules if you reuse it:
- normalise *before* deciding presence, so `''` and `'   '` hash as absent, never as a different key;
- fix the key's position, so a request with it always hashes the same;
- pin it with a **golden** test that writes the expected JSON out key by key (`test/issuance-gate-parity.spec.ts`), so an always-present key — the default instinct — fails loudly;
- every refusal of the field (here: no GSTIN beside it, over 100 code points) stays behind the replay lookup, never in the DTO.
Use the exception only for a genuinely optional field; a field that changes what the command *does* for every request still belongs in the always-present form.

**Never retarget a test that failed because of your change.** First establish what it was pinning. 10.2 edited the repo's only cross-version replay guard to match the new convention, which destroyed its only purpose. If the old behaviour is genuinely gone, the test asserts the *new* expectation and says so — it is not quietly re-aimed.

No `pgEnum` for new vocabularies — `userRoleEnum` exists but extending a Postgres enum needs `ALTER TYPE`, where a CHECK is dropped and re-added like everything else here.

---

## 5. Tests

**A test that would pass against broken code is worse than no test** — it converts a gap into false confidence. Both recent migration stories shipped one.

Concretely avoid:

```ts
expect(events.every(e => e.event_hash.length === 64)).toBe(true);  // a length, not a value
expect(skuId).toBeDefined();                                        // filler
// …and a fixture whose largest value is 500, when the cast under test only matters above 2,147,483
```

**E2E suite shape:**
- `useSuiteDatabase('name')` **first** in `beforeAll` — one cloned DB per suite
- Seed through **real HTTP** (register tenant → sign in → act), not raw inserts, unless the test is about the DB itself
- `cleanupRows()` + close `DATABASE`/`AUTH_DATABASE` clients + `suiteDb.drop()` in `afterAll`
- A `wms_rls_probe` cross-tenant test for every new table — connect as a non-superuser and assert zero rows
- **jest e2e is RLS-inert.** Dev and CI connect as the superuser `wms` (`src/shared/db/db.ts`; only production's `wms_app` binds RLS — `scripts/provision-roles.sql`), so an HTTP test proves the APP predicate and nothing else: a read whose isolation rests on RLS passes every e2e test with the policy deleted. **Isolation is proved as `wms_rls_probe`** — run the read's own query shape, scope-stamped, with the app predicate removed, and assert only the scoped rows come back (21-7's `test/client-isolation.spec.ts` Part 3). Where a read must carry both layers, pin the stamp with an architecture scan as well (21-7: every portal facade read passes `{ clientId }`)
- An OpenAPI path-list assertion for every new route

**For a data migration**, the harness exists — `test/fractional-quantity.spec.ts` is the model: copy the real `drizzle/` folder, delete the migration under test, trim the journal, run the repo's own migrator against a scratch database, seed representative rows, apply the migration **inside one transaction** (as the real runner does), then assert. Build the "before" state from the repo's own history, never a hand-written replica.

**Prove your test bites.** Mutate the code it covers and watch it fail. If it doesn't, it isn't a test.

---

## 6. Errors

RFC 9457 problem details: `{type, title, status, code, detail, instance}`. `code` is the machine-readable branch key — **clients branch on `code`, never on prose**.

A refusal names the rule and the offender:

> `Base UoM "kg" is a measured unit … give it a whole-unit UoM, or leave it untracked`
> `reasonCode must be one of ["bin-empty","damaged",…] (got "xyz")`

**A `ProblemException`'s `title` argument never reaches the wire when it carries a detail** (found in 21-8). The exception's `message` is `detail ?? title`, and `ProblemDetailsFilter` renders `title` from `exception.message` — so the wire `title` equals the `detail` (`assertMeteringPeriod`'s "Invalid metering period" never appeared either). Put everything a client must read in `detail`, assert `code` and `detail` in tests, and do not promise a title in a spec.

**Never interpolate a raw domain value into operator-facing text without converting it at the edge.** Quantities are milli-units internally; printing one directly shows 2000 where the user asked for 2. Caught in review on story 10.2 across six sites.

---

### Route declaration order

**A literal route segment must be declared before a sibling `:param` route in the same controller.** Express matches routes in declaration order, so `GET /invoices/hsn-summary` declared after `GET /invoices/:invoiceId` is captured by the param route and answers `400 invoiceId must be a uuid` — or, for a param route without a shape check, a `404` or a wrong read. Declare the literal first, say why in a comment, and pin it with a test that calls the literal route and expects its own response (8-2a's `invoicing-hsn.spec.ts` asserts both the behaviour and the method order on the controller prototype).

---

## 7. Cross-repo

Backend first, always. A story spanning repos lands the additive backend change, then the frontend that consumes it.

- After a contract change: `bun run openapi:export` (be) → `bun run api:generate` (fe) → commit the regenerated client
- A new capability must be mirrored in `wms-fe/src/lib/users.ts`; `check:capability-mirror` reads the backend source and fails CI naming the drift
- **The FE `generated-client` job stays red until the backend PR merges.** Expected, not a defect
- Update the interface contract in `docs/repos/<repo>/README.md` when the change lands
- Meta repo last

---

## 7a. The one read-only exception: reporting (story 9-1, decision 6)

AD-6's rule — a sibling reads another module only through its facade — has **exactly one named exception**: the reporting module's dashboard tiles (`src/modules/reporting/kpis.ts`) read the owning modules' tables directly, in read-only SQL. A KPI routed through a facade would need a bespoke "count my rows in this window" method per tile, each a second definition of the KPI free to drift from the first. The terms, all guarded by `test/architecture.spec.ts`:

- **Reporting writes nothing** — no Drizzle `.insert/.update/.delete`, no raw `INSERT`/`UPDATE … SET`/`DELETE`/`TRUNCATE` anywhere under `src/modules/reporting`;
- **only the api shell imports it** (plus the root `app.module.ts` composition) — no module may build on a read model that bypasses facades;
- **it owns no table** — the facts it needed (`pack_verification_failures`, `ingest_backorder_refusals`) are owned and written by **outbound**, the module whose refusals they record.

This is not a precedent. A new read model that wants the same freedom takes its own human decision and its own guard block. A new KPI belongs in `kpis.ts`, names its source and its drill, and is either `reconciles: true` (proven by paging its drill in `test/reporting.spec.ts`) or says why not. Details: `modules/reporting.md`.

**List windows (9-1).** A list that takes a time window uses `src/shared/primitives/instant-range.ts`: `@IsInstant()` (an ISO-8601 instant **with** a zone designator — a bare local time is refused), `assertInstantRange(from, to)` in the controller (`from ≥ to` → `400 validation-failed`), `@BooleanFlag()` + `@IsBoolean()` for a flag (exactly `'true'`/`'false'`, anything else refused by name), `@RepeatableParam()` for `?type=a&type=b`. The window is half-open `[from, to)` on a **server-stamped** column, and the list's cursor must carry the full-precision instant (`fullPrecisionInstant`) — a drill paged to exhaustion is a promise, and a truncated cursor silently breaks it.

**Best-effort side facts (9-1).** A fact recorded *about a refusal* (a failed pack verification, a reject-policy refusal) is written **after** the refused work rolled back or released — never in a second transaction while the first holds its locks (pool deadlock, outbound Gotcha 10) — in its own `try/catch` that logs, so the caller gets exactly the refusal it always got. Throw a **typed** subclass of `ProblemException` that renders the identical problem and carries the fact's fields (`PackMismatchError`), and catch it around the one transaction every entry path reaches.

---

## 7b. Client attribution (story 21-2b)

**Documents and ledger rows derive their client from their SKUs — never stamp `self`.** The SKU is the source of truth for ownership (AD-23). A writer of `orders`, `purchase_orders`, `ledger_events` (or any future client-scoped document — an ASN, a client invoice) reads its SKUs' `client_id` and calls `assertSingleClientInTx(tx, tenantId, clientIds, subject)` (`modules/clients/clients.facade.ts`), which returns the one client or refuses **409 `mixed-client`** naming the clients. `ensureSelfClientInTx` is for registration and the single-client import default only; a writer that reaches for it attributes a client's goods to the tenant, silently. The ledger append reads the SKU row and throws on a missing one — it never falls back. A refusal that names a client prints the tenant's own as "<tenant name> (your company)" (`getClientLabelsInTx`), never the internal `self` code. Details: `modules/clients.md`.

## 7c. Three patterns from rate cards (story 21-3)

**An exported, mutable command clock for time rules behind the replay lookup.** A rule that tightens with time ("≥ today", "≥ tomorrow", "only before its date") must sit behind the replay lookup (§1), and the only proof is a test that commits an op, moves the clock past the boundary, and replays the same key. So the command reads "now" from an exported object — `export const rateCardClock = { now: () => Date.now() }` in `billing/rate-card.command.ts` — never from `new Date()` inline or the database's `now()`. Tests **assign** `rateCardClock.now = () => ms` (jest's `restoreMocks: true` would undo a `spyOn` between tests) and restore it in `afterAll`. Any read the same rule depends on (the in-force default `at`) uses the same clock, so the suite is deterministic across IST midnight.

**A BEFORE-trigger freeze whose parent lookup fails closed under RLS.** When a trigger guards a child row by its parent's state (rate-card lines: "the parent card must be a draft"), it reads the parent through the session's own RLS — keep it `SECURITY INVOKER`. A parent the session cannot see reads as **missing**, and missing must refuse (`parent_status IS DISTINCT FROM 'draft'`), never pass. Two consequences to write down in the tests: a client-scoped (portal) write is refused by the trigger with **`P0001`, not RLS's `42501`** — BEFORE triggers run before the WITH CHECK arm — and a `FOR SHARE` parent lookup also needs the parent's UPDATE policy to admit the session, so an operator-only UPDATE policy makes the parent invisible to a portal session. Probe for `P0001` there, and pin the `42501` arm on the parent table. Also make the parent's delete refuse while children exist, or a direct delete leaves orphans the child trigger then refuses to remove.

**Moving a primitive to `shared/` without changing a module's error contract.** When a helper moves to `shared/primitives` (21-3: `istDateOf`, `isIsoDate` from invoicing to `time.ts`), the shared copy throws a neutral error (`RangeError`) and the old module **re-exports a wrapper** that rethrows its own typed failure — `invoicing/eway-threshold.ts`'s `istDateOf` still throws `ArithmeticOverflowError`, because `eway.delivery.ts` acks exactly that type as a data fault. A plain re-export would have turned a data fault into a retry loop. Pin both: the shared helper's behaviour and the module wrapper's error type.

## 7d. Proving "every transaction before T has finished" (story 21-4)

A projection that buckets by a **server-stamped instant** (`recorded_at`) cannot trust a wait: the stamp is taken before the locks and the commit, and nothing bounds a transaction's length. The check the storage snapshots use (`billing/storage-snapshot.ts`, human-decided 2026-10-07):

- `now ≥ T + margin` (clock skew), **and**
- no OTHER client backend of this database in `pg_stat_activity` has an open transaction with `xact_start < T`.

Every stamp is taken inside a transaction that began no later than the stamp, so this covers a transaction with or without an xid, and every count stamped the same way. Run it **before** the reads that depend on it (READ COMMITTED: anything not open at the probe is visible to the next statement).

**Two proofs that look right and are not:** `pg_snapshot_xmax(pg_current_snapshot())` is `latestCompletedXid + 1`, so a transaction still running with a newer xid is at or above it, unlisted — the proof passes while it is open. Recording your own `pg_current_xact_id() + 1` and waiting for a later xmin fixes that but misses a transaction that has stamped and **not yet taken an xid** (written nothing). Both were caught by held-open-transaction tests (`test/metering.spec.ts`).

**The price is visibility.** A role sees other users' transactions only with `pg_read_all_stats` (or as the same role); a hidden row reads `<insufficient privilege>`. Detect it and **refuse** — never treat an invisible session as idle. A deploy keeps all app connections on one role or grants `pg_read_all_stats`.

## 7e. The client portal — AD-4 amended for the fence only (story 21-7)

**The token used to be transport, never authority.** A client-portal user's session token now carries a `client_id` claim (`signTenantSession(…, clientId?)` adds it only when given — an operator token's payload keys stay exactly `sub, tenant_id, iat, exp`, pinned byte for byte in `test/portal.spec.ts`). The claim has **one** use: the fence.

- **The fence.** `TenantSessionGuard` and `AnySessionGuard`'s web arm refuse a token carrying `client_id` with 403 `role-denied`, detail exactly `This is an operator surface.` — one check in front of every operator route, so no copied `assertOwnTenant` can forget it. A new operator route gets the fence by using the guard; nothing else to remember.
- **The reverse fence.** Portal routes (`GET /tenants/{t}/portal/…`, `src/api/portal.controller.ts`) are behind `PortalSessionGuard` (clients module), which admits ONLY a `client_id` token (else 403 `role-denied`, `This is a client-portal surface.`) and **re-reads the user and the client every request** inside a client-stamped tenant transaction — never `AUTH_DATABASE`: user missing / not active / another client → 401; client not active → 403 `client-suspended`. That is where an untrusted party holds the session and where suspension must bite before the 15-minute expiry.
- **Why the claim cannot go stale:** `users.client_id` is written only by the invite insert (the DTO, the command, the 0065 pairing CHECK and an architecture scan), and a client user's role never changes. Capabilities stay a per-command DB read; `ROLE_CAPABILITIES.client` was empty in 21-7 and holds exactly `asn.announce` since 21-7b.
- **Both families are now exclusive in both directions** — `verifyTenantSession` refuses a token carrying `device_id` (the old one-way hole: a badge-in token opened the web surface), and `verifyDeviceSession` refuses one carrying `client_id`. A present `client_id` that is not a UUID string (`null` included) is an invalid token, never "no client".
- **A portal read is two layers, both required:** the owning module's facade method `(tenantId, clientId, query)` opens `withTenantTransaction(db, t, fn, { clientId })` (RLS) AND the query carries an explicit `client_id = $client` on a stamped table, reaching inherited rows (stock, reservations, lines) only through a join to a stamped parent. Never reuse an operator read route for the portal; the response is an exact key allowlist rebuilt key by key, never a spread of the operator view.
- **A portal WRITE re-reads the user and the client in its OWN transaction (21-7b).** The guard's re-read ran in another transaction; on a read that window is harmless, on a write a suspended brand's in-flight request would commit. So a portal command (`AsnCommand.announce` is the model) opens `withTenantTransaction(db, t, fn, { clientId: command.clientId })` itself and, before the replay lookup: `assertPermission(getMemberRoleIn(…), '<capability>')` → one read of the member's status and `client_id` (not `active` → 401 `unauthenticated`; `client_id ≠ command.clientId` → 403 `role-denied`, which also refuses an owner, who holds every capability) → `getClientStatusInTx` (not `active` → 403 `client-suspended`). The client comes from `PortalSession`, never the body (`forbidNonWhitelisted` makes a body `clientId` a 400). Its other rules: a **separate command**, never a flag on the operator one (the operator hash and response stay byte-identical, pinned by an `idempotency_keys` golden); a fingerprint that starts with `surface: 'portal'` (`idempotency_keys` is unique on `(tenant_id, key)` across surfaces, so without it an identical payload re-serves the other surface's snapshot); reads of client-owned rows filtered by the session client (an unknown and another client's id are the SAME 404 — never confirm another client's row exists); the stored snapshot is the portal's own shape, rebuilt on the same transaction. Proofs: an architecture scan of the command for the `{ clientId: command.clientId }` stamp (the facade only delegates), and a `wms_rls_probe` arm that runs the WHOLE write set (every insert, plus the read-back) under the client stamp with a positive control — a policy that refused one of those tables to a stamped session would 500 every portal write in production while every superuser e2e test stayed green.
- **Role checks over a growing vocabulary are allowlists.** The device role re-checks were `role === 'accountant'` denylists and silently admitted the fifth role; they are now `isFloorRole` (`FLOOR_ROLES` in `permissions.ts`).

## 8. Before you say it's done

```bash
bun run test && bun run lint && bun run typecheck && bun run build
bun run db:migrate && bun run db:verify     # against a freshly reset DB
bun run db:generate                          # must report "No schema changes"
git status --short                           # must show NO untracked files
```

Run the **full** suite, not a scoped subset. `architecture.spec.ts` is what guards module boundaries, and a scoped run skips it.
