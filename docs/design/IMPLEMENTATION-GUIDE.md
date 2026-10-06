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
- [ ] `bun run db:generate` afterwards must report **"No schema changes"** — the only check that the hand-written SQL and `schema.ts` agree
- [ ] `git status --short` must show **no untracked files**

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
- An OpenAPI path-list assertion for every new route

**For a data migration**, the harness exists — `test/fractional-quantity.spec.ts` is the model: copy the real `drizzle/` folder, delete the migration under test, trim the journal, run the repo's own migrator against a scratch database, seed representative rows, apply the migration **inside one transaction** (as the real runner does), then assert. Build the "before" state from the repo's own history, never a hand-written replica.

**Prove your test bites.** Mutate the code it covers and watch it fail. If it doesn't, it isn't a test.

---

## 6. Errors

RFC 9457 problem details: `{type, title, status, code, detail, instance}`. `code` is the machine-readable branch key — **clients branch on `code`, never on prose**.

A refusal names the rule and the offender:

> `Base UoM "kg" is a measured unit … give it a whole-unit UoM, or leave it untracked`
> `reasonCode must be one of ["bin-empty","damaged",…] (got "xyz")`

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

## 8. Before you say it's done

```bash
bun run test && bun run lint && bun run typecheck && bun run build
bun run db:migrate && bun run db:verify     # against a freshly reset DB
bun run db:generate                          # must report "No schema changes"
git status --short                           # must show NO untracked files
```

Run the **full** suite, not a scoped subset. `architecture.spec.ts` is what guards module boundaries, and a scoped run skips it.
