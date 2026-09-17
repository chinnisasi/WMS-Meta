---
title: 'Story 10.1: Fractional quantity migration — integers in base UoM become milli-units'
type: 'feature'
created: '2026-09-17'
status: 'done'
route: 'dispatch'
review_loop_iteration: 0
baseline_commit: '5ee44c7c563947c99bc01b077de034702d116cdc' # wms-be main
context:
  - '_bmad-output/implementation-artifacts/epic-10-context.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** Every quantity in the system is an `integer` in the SKU's base UoM (AD-9 as originally adopted). Measured goods cannot live inside that: a grain depot books tonnes to three decimals, a chemical plant books litres, a fishmonger books kilograms — and none of them can be expressed. The "just use a tiny base unit" escape fails twice: `integer` overflows before silo scale (2,147,483,647 g ≈ 2,147 t), and there is no decimal at any base unit. This blocks Epics 5, 14, 19 and 20, and it is the **only non-additive change** in the multi-domain programme — every epic built on integer quantities is an epic to rewrite.

**Approach:** Quantities become **scaled integers in milli-units** — base UoM × 10³, stored as `bigint`. Nothing decimal exists inside the domain; conversion happens only at the API and UI edges. `src/shared/primitives/quantity.ts` is the single chokepoint the whole change is enforced through. The migration's acceptance test is not a unit test but story 2.2's **replay-reconciliation**: after the change, recomputing every derived balance from the ledger must reproduce it exactly.

**Decided (2026-09-17, human):**
- **Milli, not micro.** The binding limit is not `bigint` but the **2⁵³ exact-integer ceiling of IEEE doubles**, which quantities cross twice — Lua 5.1 in the Valkey reservation script, and JavaScript itself. At ×10⁶ that leaves ~9.0 × 10⁹ base units, capping a grams-based silo at ~9,007 t — still reachable, and it would reintroduce the exact class of bug this migration exists to remove. At ×10³ the ceiling is ~9.0 × 10¹² base units. The 2⁵³ budget is split between range and precision; finer scale buys precision by spending range.
- **Declared precision is capped at 3 dp**, which covers every UoM the domain list needs: kg, litre, tonne, metre at 3 dp; each at 0 dp.
- **Pre-launch: migrate in place.** No environment holds live tenant data, so a single forward migration multiplies every quantity column by 1000 in place. No expand → dual-write → backfill → cut over → contract, and no rollback rehearsal. This is a **dated assumption, not a permanent licence**: the moment a real tenant exists, any future representation change must use expand-contract instead, and this story is the last one that gets to rewrite quantity columns in place.

**Decided (technical, from investigation):**
- **Quantities stay JS `number`.** `BigInt` is refused: `quantityDelta` is JSON-serialized into the **ledger hash chain** (`ledger.service.ts:207-224`), and `JSON.stringify` throws on a BigInt. At milli scale `Number.isSafeInteger` covers the full usable range, so the branded types keep working as the guard.
- **postgres.js returns `int8` as a JS string.** Every raw-SQL quantity read needs `Number(...)` at its boundary — `binOccupancyInTx:781` and `binCandidatesInTx:759` already do exactly this and are the pattern to copy. Drizzle columns use `bigint(..., { mode: 'number' })`, whose mapper is `Number(value)`.
- **Serial-tracked SKUs must use a 0-dp UoM.** Four sites assert `serials.length !== qty` (`inventory.command.ts:217`, `putaway.command.ts:383`, `pick.command.ts:733`, `bin.command.ts:574`) — a unit count is literally an array length. A serialized unit is discrete by definition, so this is **one validation rule at catalog entry**, not four conversion sites.
- **`bins.capacity`, `skus.reorder_point` and `skus.reorder_qty` scale too.** All three are UoM-denominated and compared against quantities; scaling quantities alone would silently break every capacity gate.
- **`uom_conversions.factor` stays an integer multiplier.** A box of 12 is 12 whether quantities are scaled or not. Fractional conversions (kg↔lb) belong to story 10-2's UoM vocabulary.

## Boundaries & Constraints

**Always:**
- **Replay-reconciliation is the acceptance gate, not an afterthought.** After migration, `replayInTx` must reproduce every `stock_on_hand` and `batch_on_hand` balance exactly, on a database with representative data in every quantity column.
- **The replay fold must not lose precision.** `foldLedgerInTx` accumulates into a JS `Map<string, number>` (`ledger.service.ts:1136`) and divergence is an exact `!==` compare (`:1217`, `:1262`, `:1326`, `:1358`). Float rounding there would manufacture **false quarantines** — the migration's own oracle becoming the thing that breaks. Every accumulator must stay inside the safe-integer range and be asserted to.
- **Every `::int` cast over a quantity becomes `::bigint`.** Seven sites: `reservation.service.ts:59`, `:795`, `:1043`, `:1083`, `replan.ts:294`, `pack.command.ts:326`, `dispatch.command.ts:298`. Under milli-units `::int` raises `integer out of range` at ~2.1 million base units — reachable by a real warehouse, and the immediate blocker ahead of any Lua concern.
- **Every quantity CHECK constraint is re-created against the new column type** — 16 across migrations 0006, 0009, 0010, 0011, 0013, 0015, 0017, 0018, 0019, 0022, including the compound ones (`goods_receipt_lines_applied_le_physical`, `order_lines_reserved_qty_lte_qty`, `picklist_lines_slice_shape`, `picklist_lines_short_pairing`).
- **Scale-aware constants move with the quantities:** `MAX_SCAN_QUANTITY` (`pack.command.ts:39`), `bufferUnits()` (`reservation.service.ts:78`), and every DTO `@Max(2147483647)` bound.
- The Valkey counter stays an **INCRBY-parsable decimal integer string** — no `INCRBYFLOAT`, no exponential notation. Milli-unit values must stay well inside Lua's exact range and away from the `%.17g` formatting threshold.
- **No user-visible behaviour changes.** A tenant using each-counted SKUs sees identical numbers, identical refusals and identical API responses before and after.
- The ledger event grammar, the per-warehouse sequence, the hash chain's canonical form and the outbox contract are **unchanged** — this migrates representation, not meaning.

**Never:**
- No `numeric` columns, no decimals inside the domain, no `BigInt` values in code that reaches `JSON.stringify`.
- No catch weight — that is a per-handling-unit actual weight (AD-22, story 10-3) and folding it in would widen the migration for no reason.
- No UoM vocabulary, no per-UoM precision table, no precision validation — story 10-2. This story scales the representation; 10-2 teaches the system which precisions are legal.
- No change to money (integer paise), GST (basis points), sequences, epochs, `attempts`, row counts, `walk_seq`/`slice_seq`, or `credential_version`.
- No web or mobile surface — stories 10-5 and 10-6.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Existing each-counted stock | on-hand 500 pcs before migration | reads 500 pcs after; stored as 500000 | N/A |
| Replay after migration | any seeded warehouse | `replayInTx` reproduces every balance exactly; **zero divergences, zero quarantines** | a single divergence fails the story |
| Fractional receipt | 18.4 kg received | stored 18400; reads back 18.4 | N/A |
| Sub-milli precision | 18.4567 kg | accepted and stored as 18457 (rounded at the edge) — *precision refusal arrives with 10-2* | N/A |
| Large measured balance | 9 × 10¹¹ base units accumulated | exact; no overflow, no rounding | beyond ~9.0 × 10¹² → typed refusal, never a silent wrap |
| Aggregation over quantities | `sum()` across many rows | `::bigint`, returned as string, coerced at the boundary | `::int` anywhere → the story is not done |
| Serial-tracked SKU | catalog entry with a 3-dp UoM | refused at catalog entry naming the UoM and the rule | `400 validation-failed` |
| Serial movement | 5 serials, qty 5 units | `serials.length` compared against **unscaled** unit count, not milli-units | mismatch → existing refusal, unchanged |
| Capacity gate | bin capacity 1000, occupancy 500, putaway 10 | fits — capacity and occupancy both scaled, comparison unchanged in meaning | N/A |
| ATP reservation | grant against a scaled ceiling | Valkey counter holds milli-units as a decimal integer string; grant/release arithmetic exact | counter unparsable → existing fail-closed path |
| Replay of a pre-migration idempotency snapshot | stored snapshot with unscaled quantities | re-served **as stored** — a historical response is not rewritten | N/A |

</frozen-after-approval>

## Code Map

- `src/shared/primitives/quantity.ts` — **the chokepoint.** `BaseQuantity`/`baseQuantity()` (non-negative, `Number.isSafeInteger`) and `SignedQuantity`/`signedQuantity()`. Every quantity in the system passes a brand here; scaling is enforced in this file plus the DB columns, not across 39 call sites.
- `src/shared/db/schema.ts` — the 15 in-scope quantity columns: `ledgerEvents.quantityDelta:509`, `stockOnHand.quantity:585`, `batchOnHand.quantity:631`, `reservations.quantity:916`, `purchaseOrderLines.orderedQty:1053`/`receivedQty:1054`, `goodsReceiptLines.qty:1207`/`appliedQty:1208`, `overReceipts.excessQty:1245`, `putawayPlacements.qty:1352`, `orderLines.qty:1471`/`reservedQty:1472`, `picklistLines.qty:1680`/`shortfallQty:1687`, `picks.qty:1794`. Plus the three UoM-denominated siblings that must scale with them: `bins.capacity:211`, `skus.reorderPoint:285`, `skus.reorderQty:286`. **Out:** `unit_cost_paise`, `gst_rate_bps`, `seq`, `schema_version`, `from_seq`/`to_seq`, `last_seq`, `invalid_attempts`, `epoch` (already bigint), `attempts`, import row counts, `priority`, `max_orders`, `slice_seq`, `walk_seq`, `credential_version`, `uom_conversions.factor`.
- **The 16 CHECK constraints**, by migration: 0006 (`stock_on_hand_quantity_nonnegative`), 0009 (`reservations_quantity_positive`), 0010 (`batch_on_hand_quantity_nonnegative`), 0011 (`ordered_qty_positive`, `received_qty_nonnegative`), 0013 (`over_receipts_excess_qty_positive`, `goods_receipt_lines_qty_positive`, `applied_qty_nonnegative`, `applied_le_physical`), 0015 (`putaway_placements_qty_check`), 0017 (`order_lines_qty_positive`, `reserved_qty_nonnegative`, `reserved_qty_lte_qty`), 0018 (`picklist_lines_qty_nonnegative`, `shortfall_qty_nonnegative`), 0019 (`picks_qty_positive`), 0022 (`picklist_lines_slice_shape`, `picklist_lines_short_pairing` — the compound ones; read both bodies). **No CHECK exists on `ledger_events.quantity_delta`.**
- `src/modules/inventory/ledger.service.ts` — the projection and replay core. `appendMovement:438` (inserts `quantityDelta:510`), `addToOnHand:621` (`sql\`${quantity} + ${delta}\``:666), `addToBatchOnHand:686`, `foldLedgerInTx:1067` (**the JS `Map<string, number>` accumulator at `:1136`**), `replayInTx:1179` (exact compares `:1217`/`:1262`), `reconcileScanInTx:1295` (`:1326`/`:1358`), `rebuildProjectionsInTx:1445`, `rebuildBatchArmInTx:1549`. Hash canonicalization at `:207-224` — **`quantityDelta` is JSON-serialized here; this is why BigInt is refused.** `Math.abs(quantityDelta)` at `:539`/`:1130`.
- `src/modules/inventory/reservation.service.ts` — `::int` casts at `:59`, `:795`, `:1043`, `:1083`; `bufferUnits():78`; `grant:269`/`grantInTx:1405`; `restoreReservedUnits:1477`; `restoreCounter:959`; `compensate:937`; `rebuildCounters:637`. Failure semantics are **logged, never thrown** — counter stays high, ATP understated, repaired by the next parity pass. Preserve that.
- `src/shared/valkey/reservation-scripts.ts` — the only two Lua scripts. Grant `:32-54` (`tonumber(ARGV[1])`, ceiling compare `:48`, `INCRBY :51`), release `:68-80` (`reserved - qty :74`, `SET ... KEEPTTL :78`). Registered in `valkey.client.ts:70-71`; counter read/write `:118-133`. Key shape in `reservation-keys.ts:20-27`. **No float-capable command exists** — the counter must stay an integer string.
- `src/shared/db/db.ts:12` — `postgres(url, { max: 10 })`, **no `types` override**, so `int8` → JS string. `binOccupancyInTx:781` and `binCandidatesInTx:759` show the correct `Number(...)` boundary coercion; copy that pattern, do not invent another.
- **The four serial/array-length sites**: `inventory.command.ts:217` (+ per-serial loop `:472`), `putaway.command.ts:383` (+ `:507`), `pick.command.ts:733`, `bin.command.ts:574`. These compare a unit count to `Array.length` and must see **unscaled** units.
- **Other `::int` aggregations**: `replan.ts:294`, `pack.command.ts:326`, `dispatch.command.ts:298`. Already-safe `::bigint` sums: `putaway.command.ts:733`/`:772`, `receiving.facade.ts:231-232`.
- **JS arithmetic over quantities to audit**: `bin.command.ts:621` (`reduce` then capacity compare `:628`), `replan.ts:120-125`, `reservation.service.ts:1014`, `order.command.ts:719`, `receiving.command.ts:430`, `putaway.command.ts:407`/`:699`/`facade:322`.
- **DTO edges** (`@Max(2147483647)` bounds to revisit, decimal conversion to add): `inventory.dto.ts:112-116`, `inbound.dto.ts:122-125` (**no `@Max` today**), `receiving.dto.ts:78-82`, `putaway.dto.ts:50-54`, `outbound.dto.ts:60-64`/`:612-616`/`:932-936`, `tenancy.dto.ts:232-236`/`:271-274`, `catalog.dto.ts:150-160`.
- `src/modules/inventory/reconcile.ts` — the story-2.2 job: `reconcile:140`, `detect:378`, repair `:230`, quarantine insert `:193`. Scheduled from `src/jobs/jobs.module.ts:128-176`.
- `drizzle/` — next migration index is **0026**; hand-written SQL needs a hand-written `_journal.json` entry **and** a `0026_snapshot.json`. Nothing in CI catches a missing snapshot; `bun run db:generate` reporting "no changes" is the only check that schema and migration agree.

## Tasks & Acceptance

**Execution:**
- [x] `wms-be src/shared/primitives/quantity.ts` — the scale constant, `toMilli`/`fromMilli` edge converters, and the branded guards taught the new range
- [x] `wms-be drizzle/0026_*.sql` + `_journal.json` + `0026_snapshot.json` — the 15 quantity columns plus `bins.capacity`, `skus.reorder_point`, `skus.reorder_qty` to `bigint`, values multiplied by 1000, all 16 CHECKs dropped and re-created
- [x] `wms-be src/shared/db/schema.ts` — the same columns as `bigint(..., { mode: 'number' })`, doc comments stating the scale
- [x] `wms-be src/modules/inventory/ledger.service.ts` — the fold accumulator and both compare paths; confirm the hash canonical form is byte-identical for an unchanged event
- [x] `wms-be src/modules/inventory/reservation.service.ts` + `src/shared/valkey/*` — the four `::int` casts, `bufferUnits()`, and the counter's scaled values
- [x] `wms-be` the three remaining `::int` aggregations — `replan.ts`, `pack.command.ts`, `dispatch.command.ts`
- [x] `wms-be src/modules/catalog/*` — refuse a serial-tracked SKU on a non-0-dp UoM at catalog entry
- [x] `wms-be` the four serial/array-length sites — compare against unscaled units
- [x] `wms-be src/api/**` + `src/modules/**/*.dto.ts` — decimal conversion at the edge, revised `@Max` bounds, `MAX_SCAN_QUANTITY`
- [x] `wms-be test/` — the matrix e2e, a migration-fidelity test, and a **replay-after-migration** test over representative data in every quantity column
- [x] `wms-be bun run openapi:export` + `wms-fe bun run api:generate`

**Acceptance Criteria:**
- Given a database seeded through every inbound and outbound flow, when the migration runs and replay-reconciliation executes, then every `stock_on_hand` and `batch_on_hand` balance reproduces exactly and **no quarantine row is written**
- Given an each-counted SKU, when any pre-migration flow is exercised after the migration, then every API response is byte-identical to before
- Given a measured SKU, when 18.4 kg is received, then on-hand reads 18.4 and the stored column holds 18400
- Given a serial-tracked SKU, when catalog entry names a 3-dp UoM, then it is refused naming the UoM and the rule
- Given any quantity aggregation in the codebase, when it is inspected, then no `::int` cast remains over a quantity column

## Implementation Notes

**The rule the change is built on.** A quantity is in **milli-units everywhere
below the HTTP edge** — every command, service, ledger call, Valkey counter and
database column — and in **base units the moment it leaves**: an HTTP response
body, an outbox payload, or a problem-details `detail` string. `toMilli` is
called in exactly one kind of place (a controller mapping a DTO onto a command,
plus the CSV importer, which is the same edge in a different costume) and
`fromMilli` in exactly one other (the function that NAMES an outgoing field —
a facade's read-model row map, a command's snapshot builder, a refusal's text).
Nothing in between converts, which is what makes a stray conversion visible.

**The trap that rule caught, twice.**
- `po.command.ts` `close()` read its lines through `linesOf()`, which is a READ
  shape and now converts out of milli-units, then wrote `ordered − received`
  straight back into the column. A 12-unit carried PO line landed on its
  successor as 0.012. Fixed by splitting `lineRowsOf()` (raw, milli, for the
  command paths) from `linesOf()` (converted, for responses) and pointing every
  arithmetic caller at the former.
- `addToOnHand`/`addToBatchOnHand` upsert with `greatest($1, 0)`. Postgres
  resolves an untyped parameter beside an integer literal as **int4**, so the
  fold died with a raw 22003 at ~2.1 million base units — the column was `bigint`
  and perfectly able to hold the value. Every bound quantity parameter in raw
  SQL now carries an explicit `::bigint`.

**The serial rule is one rule, not four conversions.** `isFractionalUom` +
`serialTrackedFractionalUomDetail` live in `src/modules/catalog/uom-precision.ts`
and are enforced at both catalog-entry doors (the importer's row validation and
the PATCH that flips `serialTracked` on). The four `serials.length` comparisons
now compare against `fromMilli(qty)` — a unit count against a unit count — and
a per-serial ledger event carries `QUANTITY_SCALE` milli-units, one whole unit.

**`assertExactQuantity` is the fold's smoke alarm.** It guards every JS-side
quantity accumulation — the replay fold's `Map<string, number>`, the bin-merge
`movedUnits` reduce, pack/dispatch `totalUnits` — so a sum past 2⁵³ is a named
failure instead of a silent rounding that would make reconciliation quarantine
healthy stock.

**Two consequences worth naming, both licensed by the pre-launch premise:**
1. **Idempotency payload hashes moved.** Commands fingerprint their own fields,
   which are now milli-units, so a key written before this deploy no longer
   replays — a queued offline op resent across the migration window answers 422
   `idempotency-key-reuse` instead of re-serving its snapshot.
2. **Pre-migration ledger hashes no longer verify.** `event_hash` covers
   `quantity_delta`, and the migration rewrites the column without rehashing
   (it cannot: the canonical form includes the timestamp normalizer and the
   sorted-key reference doc). `verifyChain` would report a severity-1 break on
   any event that predates the migration. The migration file says so at length.
   This is the sharpest reason the in-place licence expires with the first real
   tenant: a settled event's hash is evidence, and evidence is not something a
   forward migration gets to rewrite.

**Testing.** `test/fractional-quantity.spec.ts` is the story's own gate, in two
halves. Part A builds a database on the **pre-0026 schema** (the repo's own
migrations, journal trimmed to idx ≤ 25), seeds real rows into every one of the
18 in-scope columns, runs the story's migration SQL, and then asserts: every
column widened to `bigint` and nothing else did, every value is exactly ×1000
while money/GST/sequences did not move, all 18 CHECKs are back and still bite,
and `replayInTx` reproduces every balance with zero divergences. Part B drives
the matrix over HTTP on the migrated schema. `test/architecture.spec.ts` gained
a source scan that fails any `::int` cast over a quantity column.

## Spec Change Log

**2026-09-17 — matrix row 11 recorded as a dated limitation (human decision, not a code change).** The frozen I/O matrix says a pre-migration idempotency snapshot is "re-served **as stored**". The implementation cannot do that: commands fingerprint their own now-milli fields, so a key written before this deploy fails the payload-hash compare and answers `422 idempotency-key-reuse` — it never reaches the stored snapshot. **Accepted rather than fixed**, because the pre-launch premise means no such key exists in any environment; the row describes a situation that cannot occur. Making the replay path scale-aware would add a permanent compatibility branch to protect a one-time window with no data in it. The frozen row is left as written rather than edited — this entry is the correction.

**The same premise carries a sharper caveat, recorded here so it is not rediscovered.** `event_hash` covers `quantity_delta`, and the migration rewrites that column without rehashing — it cannot honestly, since the canonical form includes the timestamp normalizer and the sorted-key reference doc. `verifyChain` would therefore report a severity-1 chain break on any pre-migration event. Nothing schedules `verifyChain` today (it is reachable only through `inventory.facade.ts:430`), so nothing trips over it. **Both of these expire the moment a real tenant exists**: this is the last story permitted to rewrite quantity columns in place, and any later representation change must use expand → dual-write → backfill → verify → cut over → contract.

## Review Triage Log

**Review loop 1 (2026-09-18).** Twenty findings, all accepted and fixed. The
three that were live defects rather than hardening:

1. **The parity pass declared every scope divergent, every cycle.** The journal
   sum was widened to `::bigint`, which postgres.js returns as a STRING, but the
   raw row was typed `reserved: number` — so `counter !== reserved` compared a
   number against a string and was always true. Each reaper cycle rebuilt the
   first SKU's counters, and `rebuildCounters` disarms the ready marker first,
   so grants and ATP reads failed closed with a 503 for that window. It shipped
   green because every parity test asserted the counter ENDED correct, which a
   spurious rebuild also achieves. Fixed with the `Number(...)` every sibling
   `::bigint` read already had, and pinned by a new test that spies on
   `disarmReady`/`setCounter` and asserts a quiet scope produces neither —
   verified to fail on the reintroduced bug.
2. **`FRACTIONAL_UOMS` was a denylist over a free-text column, so it failed
   open.** `lb`, `oz`, `mg`, `quintal`, `gallon`, `sqft`, `cbm` and ordinary
   spreadsheet spellings like `"Kg."` were all unlisted, so a serial-tracked SKU
   measured in pounds sailed past the one rule the module exists to enforce.
   Inverted to a DISCRETE allowlist: an unrecognized unit is now treated as
   measured, so the failure mode is a readable 400 instead of a serialized SKU
   four call sites cannot convert. The normalizer strips trailing punctuation.
3. **A quantity below half a milli-unit vanished silently.** `toMilli(0.0004)`
   is 0, so a real pick was recorded as a zero-unit empty-bin short pick and a
   real adjustment wrote a zero-delta ledger event. Both edges now refuse a
   non-zero input that would scale to zero, by name.

The rest hardened what was already correct: the migration got a fail-fast guard
(it is not idempotent and a second run would scale everything by 1000 again);
`fromMilli` now validates its input as `toMilli` always did; `QUANTITY_SCALE` is
derived from `QUANTITY_DECIMALS`; the DTO bound and the command backstops are
now one constant in two units; the INCRBY path and three more accumulators got
the exactness guard; `BaseQuantity`/`parseInt0` were renamed to say what they
now mean; and the public OpenAPI description dropped the story identifier
external consumers cannot resolve.

Test coverage followed the same list: the architecture scan now covers `test/`
as well as `src/`, matches bare-column and `max`/`min`/`avg` casts as well as
`sum()`, and gained a second guard for the untyped-bound-parameter bug class
(`greatest(${delta}, 0)` resolving to int4) whose only defence had been a
comment. Part A of the story's own suite applies the migration in `beforeAll`
inside one transaction (as the real runner does), compares every column type
and every rendered CHECK predicate before and after, exercises the three
compound predicates behaviourally, seeds two values large enough that the
`::bigint` cast is load-bearing — verified by rewriting the cast and watching
the suite fail with 22003 — asserts the event hashes are carried byte-for-byte,
and pins the documented chain break with `verifyChain` on a chain that was
genuinely valid before the migration.


**Loop 1 — four layers. Three ran on an INCOMPLETE diff (my staging error: `git diff` omits untracked files, so migration 0026, `uom-precision.ts` and the 833-line test file were invisible); a fourth layer reviewed exactly those three afterwards and found the worst item in the set. ~30 findings: 6 high, 14 medium, 11 low. All route to `patch` — every root cause is a code deviation, none a spec defect, so no loopback.**

| # | Finding | Layer | Verdict | Evidence |
|---|---------|-------|---------|----------|
| 1 | `drizzle/meta/0026_snapshot.json` is UNTRACKED while every predecessor 0019-0025 is tracked | omitted-files | **high — patch** | drizzle-kit diffs `schema.ts` against the newest COMMITTED snapshot. On any other machine the next `db:generate` sees 18 `integer→bigint` still outstanding and emits a second type change; anyone "fixing" it the way 0026 was written scales by 1000 twice. My own earlier check (`ls`) proved the file exists on disk, not that it ships — CI runs only `db:migrate`/`db:verify`, so nothing catches it |
| 2 | `parityPass` compares `number !== string`, so divergence is ALWAYS true | blind + edge + v-gap | **high — patch** | Found independently by three layers; v-gap probed the live DB (`select 5::bigint, 5::int` → `{"b":"5","i":5}`). `reservation.service.ts:804` casts `::bigint` (postgres.js → string) and `:800` casts `as unknown as typeof live` so TypeScript never sees it. Consequence is worse than log noise: `rebuildCounters` calls `disarmReady` FIRST, so every reaper cycle opens a window where grants and ATP reads fail closed with 503. Every sibling `::bigint` site in the same change added `Number(...)`; this one did not |
| 3 | Operator-facing refusal text prints milli-units — 1000× wrong | edge | **high — patch** | Verified at `reservation.service.ts:296/343/438/439/1439` and `qc.command.ts:263`. Asking for 2 units prints "got 2000". `:296` is wrong twice: it still says "must be a positive integer in base UoM" when the value is neither. Breaks the frozen "no user-visible behaviour changes" boundary and the byte-identical-response AC. No test catches it because tests assert status codes and machine codes, never the human `detail` |
| 4 | The migration is re-runnable and silently scales a second time | omitted-files | **high — patch** | No `IF EXISTS` on the drops, constraints re-added at the bottom, and `SET DATA TYPE bigint USING (col::bigint * 1000)` is legal on a bigint column. Every CHECK still passes and replay stays self-consistent because both sides move — nothing would notice. Compounds #1, since a regenerated 0027 gets a fresh journal entry and applies happily |
| 5 | `FRACTIONAL_UOMS` is a denylist over a free-text field and fails OPEN | omitted-files + edge | **high — patch** | `import.command.ts:705` validates `uom` only for non-empty and length, so the vocabulary is open while the guard is a 33-entry set. Misses `lb`, `pound`, `oz`, `mg`, `quintal`, `gal`, `gallon`, `sqft`, `cbm`, and `"Kg."` (the normalizer only trims and lowercases). Note the asymmetry: imperial *length* is covered, imperial *mass* is not. Every miss silently admits exactly the contradiction the module exists to refuse |
| 6 | A positive sub-milli quantity rounds to zero and is written as zero | edge | **high — patch** | A pick qty above 0 but below 0.0005 passes `@Min(0)` and becomes a zero-unit empty-bin short pick; a stock adjustment likewise writes a zero-delta ledger event. Silent loss, not a refusal. `OrderLineInputDto` and `PackScanLineDto` got a `@Min(0.001)` floor; `StockAdjustmentDto` did not |
| 7 | Five `::int` sums over `reservations.quantity` survive in the test suite | blind + edge | **medium — patch** | `reservations.spec.ts` ×4 and `picking.spec.ts`; raises 22003 past ~2,147 base units. The sweep converted the analogous helpers in four other suites, so it is simply incomplete |
| 8 | The new `::int` guard cannot see the offenders, matches only `sum()`, and sits in the wrong describe | blind + edge | **medium — patch** | `architecture.spec.ts:54` builds its file list from `SRC_ROOT` only; the guard landed inside the story-4.6 carrier-credentials describe |
| 9 | The untyped-parameter half of the bug class has no regression guard | blind | **medium — patch** | `greatest(${delta}, 0)` → `greatest(${delta}::bigint, 0)` was fixed by hand at six sites; its own comment calls the cast "load-bearing, not decoration", and nothing prevents the next one |
| 10 | The fixture is too small to exercise the `::bigint` cast the migration header calls load-bearing | omitted-files | **medium — patch** | Largest seeded value is `bins.capacity = 500`; everything multiplies to under 10⁶. Rewriting the migration as `(col * 1000)` leaves every Part A assertion green |
| 11 | The hash assertion is vacuous and the documented severity-1 chain break is never exercised | omitted-files | **medium — patch** | `:196` asserts `event_hash.length === 64` — a length, not a value, and the fixture writes those hashes itself. `verifyChain` appears nowhere in 833 lines, while the migration header spends fifteen lines documenting the break it causes |
| 12 | The 18 CHECKs are name-checked only; no predicate compared, no compound one probed | omitted-files | **medium — patch** | A constraint re-created with a wrong body passes. The reviewer verified all 18 bodies by hand against 0013/0017/0022 and they are correct — but the test is not what established that |
| 13 | `excessQty` in three over-receipt outbox payloads is observed by no assertion | v-gap | **medium — patch** | Pre-verified by deletion: the only payload field any test reads is `overReceiptId`; dropping `fromMilli` ships 20000 on an external event contract with the suite green |
| 14 | Three response-edge conversions are observed by no assertion | v-gap | **medium — patch** | Placements `qty`, block/unblock `capacity`, and the **device catalog-snapshot bin `capacity`** — the last reaches the mobile client, which uses it for pre-queue bin checks |
| 15 | Part A applies the migration inside test #1, outside a transaction, with a partial type filter | omitted-files | **medium — patch** | Tests #2-#4 silently depend on #1; a focused run asserts against an unmigrated DB. Production wraps each migration file in one transaction, so the fixture exercises a weaker atomicity model than the runner. `data_type in ('integer','bigint')` hides a column moving from any other type |
| 16 | DTO ceiling and command ceiling now disagree | blind + edge | **medium — patch** | In the very file whose header warns that literals and constants "drift silently, and the DTO is the gate every HTTP caller actually hits". The refusal text prints a `.991` fraction |
| 17 | `fromMilli` validates nothing while `toMilli` validates everything; SCALE and DECIMALS are independent | blind | **medium — patch** | A string or NaN from an uncoerced int8 read reaches a response body as null/NaN rather than failing loudly — and #2 proves one such read exists. `fromMilli`'s `toFixed` round-trip is correct only while `10**DECIMALS === SCALE` |
| 18 | The Valkey INCRBY path and three accumulators take quantities unchecked | edge | **medium — patch** | Only `setCounter` fails fast; `counterRestores`, `appliedByPoLine` and the dispatch/pack restores sum milli quantities with no exactness assertion before reaching a ceiling comparison or the counter |
| 19 | An internal story identifier ships in the public API contract | blind | **medium — patch** | `QUANTITY_FIELD_DESCRIPTION` ends "a per-UoM precision refusal arrives with story 10.2" and is interpolated into every quantity field's `@ApiProperty` across seven DTOs, reaching `openapi.json` and the generated wms-fe client |
| 20 | `BaseQuantity`/`baseQuantity()`/`parseInt0` now mean the opposite of their names | blind | **low — patch** | The chokepoint file's central type name asserts base units while holding milli — the cheapest available defence against exactly the 1000× mistake this story exists to prevent |
| 21 | `expireDue` reads raw `quantity` through `authDb.execute` uncoerced | blind | **low — patch** | Dead today (nothing reads `hold.quantity`), but the `as unknown as T[]` cast hides the whole class from the type checker, and #2 is the same class live |
| 22 | `reorderPoint`/`reorderQty` accept fractions on discrete UoMs; sub-milli rounds to "no reorder point" | blind + edge | **low — patch** | A threshold of 50.5 pcs on an each-counted SKU; `0.0004` becomes `0`, which is a semantic change rather than a precision loss |
| 23 | PATCH-refusal test asserts the 400 but not that the SKU is unchanged | omitted-files | **low — patch** | Its import counterpart correctly asserts `count(*) = 0` |
| 24 | `reservation-scripts.ts:22-25` overstates its formatting guarantee | v-gap | **low — patch** | The `SET` path is genuinely safe; the *return* path goes through Lua `tostring` (`%.14g`) and would render ≥1e15 in exponential form. Harmless today — `reply[1]` is only compared against reason strings — but the comment licenses a future caller to parse it |
| 25 | `QUANTITY_COLUMNS` is hand-maintained while its comment claims the test walks it as a guard | omitted-files | **low — patch** | The reverse guard catches an unexpected widening, not a missing one. 18 verified correct independently; the test cannot re-verify it |
| 26 | The serial×fractional rule ships command-side only, with no DB backstop | omitted-files | **low — patch (comment)** | The repo states the "command layer rejects first, CHECKs are the backstop" convention in five migration comments. The counter-argument is sound (the UoM set lives in TypeScript), but the deviation should be named rather than silent; 10.2's closed vocabulary is where the CHECK becomes writable |
| 27 | Six `SET DEFAULT 0` statements in the migration are no-ops | omitted-files | **low — patch (comment)** | `0::int4 → 0::int8` is `0`; harmless and arguably good documentation, but the file reads as though they are load-bearing |
| 28 | The serial refusal text states a property of the UoM that is a property of the system | omitted-files | **low — patch** | "Base UoM \"mm\" is measured to three decimal places" is not true of millimetres; three places is this system's scale |
| 29 | `expectedDate` on the PO close successor is no longer `canonicalInstant`-normalized | edge | **maybe-false — defer** | Filed at low confidence as a deletion finding. The successor insert now carries the raw column value; whether the driver's format differs from the canonical form is not settled by the diff, and nothing in this story's scope touches timestamps. Settles by comparing a successor row's `expected_date` against `canonicalInstant` of the original |
| 30 | Pre-migration idempotency keys answer 422 rather than replaying their snapshot | triage | **accepted — recorded** | Matrix row 11 says "re-served as stored"; commands fingerprint now-milli fields so the hash compare fails first. Accepted by the human as a dated limitation under the pre-launch premise; see the Spec Change Log |


## Design Notes

**Why the replay fold is the riskiest line in the change.** `foldLedgerInTx` sums event magnitudes into a JS `Map<string, number>`, and `replayInTx` compares that total to the projected row with `!==`. Both sides scale by 1000 together, so the *comparison* stays valid — but the accumulator's headroom does not: a warehouse whose ledger sums to 10¹⁰ base units now accumulates 10¹³ milli-units, still inside 2⁵³ but a thousand times closer to it. Beyond the safe range the fold rounds, the compare fails, and `reconcile.ts:193` writes a quarantine for stock that is perfectly fine. The failure mode is not corrupt data — it is the correctness oracle crying wolf, which is worse, because it trains people to ignore it.

**Why `bigint` but `mode: 'number'`.** The column must be `bigint` for range; the JS value must be `number` because `quantityDelta` is JSON-serialized into the hash chain and `JSON.stringify` throws on a BigInt. `mode: 'number'` maps through `Number(value)`, which is exact to 2⁵³ — the full usable range at milli scale. Raw SQL is the gap: postgres.js hands back `int8` as a string with no Drizzle mapper in the way, so each raw read needs its own `Number(...)`, exactly as `binOccupancyInTx:781` already does.

## Verification

**Commands:**
- `cd workspace/core/backend/wms-be && bun run test && bun run lint && bun run typecheck && bun run build` — the **full** suite; this story touches every module.
- `bun run db:migrate && bun run db:verify` against a **freshly reset** database (drop `public` and `drizzle`, `FLUSHALL` Valkey, migrate).
- `bun run db:generate` — expected: **no new migration emitted**. The only check that the hand-written migration agrees with `schema.ts`.
- **The migration-fidelity run, which is the story's real gate:** seed a warehouse through receiving → putaway → order → wave → pick → pack → dispatch on the pre-migration schema, capture every balance, run the migration, then run replay-reconciliation and assert every balance reproduces and no quarantine row exists.
- `grep -rn "::int" src/` — expected: no hit over a quantity column.
- `cd workspace/core/frontend/wms-fe && bun run test && bun run lint && bun run typecheck && bun run build` — stays green after `api:generate`.
