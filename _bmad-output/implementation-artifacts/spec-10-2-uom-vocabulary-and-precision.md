---
title: 'Story 10.2: UoM becomes a closed vocabulary with declared precision'
type: 'feature'
created: '2026-09-18'
status: 'done'
route: 'dispatch'
review_loop_iteration: 0
baseline_commit: 'e50d03da9b4bb9f82a6a9e07c5a0c97bddfcf58d' # wms-be main
context:
  - '_bmad-output/implementation-artifacts/epic-10-context.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** `skus.uom` is free `text` with no CHECK and no vocabulary — `pcs`, `PCS` and `pieces` can coexist as three different units. Story 10.1 made quantities fractional but had nothing to ask how precise a given unit may be, so it did two things it explicitly deferred here: it **rounds** a too-fine value at the edge (`18.4567` silently becomes `18.457`) instead of refusing it, and it guards the serial rule with a **hand-maintained discrete allowlist** (`uom-precision.ts`) that fails closed but gives a false refusal for any legitimate discrete unit nobody thought to list.

**Approach:** `uom` becomes a **closed vocabulary**, each unit declaring the decimal precision it may express (`each` = 0 dp, `kg` = 3 dp). A quantity finer than its unit's declared precision becomes a **typed refusal naming the unit and the precision**, replacing the silent rounding. The vocabulary makes the serial rule answerable by lookup rather than by list, so `uom-precision.ts` is deleted, and it makes a database CHECK writable for the first time — closing the deviation 10.1 recorded from this repo's own "command layer rejects first, CHECKs are the backstop" convention.

**Decided (technical, from investigation):**
- **Precision is a property of the UNIT, not of the SKU.** A kilogram is three-decimal everywhere; it does not depend on what is measured in it. This is what lets the device validate offline from a unit it already knows.
- **Conversion and precision validation move from the controller edge INTO the commands.** Today `toMilli` runs while building the facade argument, *before* the idempotency replay lookup. An edge-level precision check would therefore refuse a queued device op with `400` **before** the command could re-serve its stored snapshot — so replaying an op that already committed would answer 400 instead of its original 201. Correctness forces the check behind the replay lookup.
- **The device validates precision on-device, from the catalog snapshot.** `CatalogSnapshotSkuDto` already carries `uom` (`receiving.dto.ts:422`); it gains the unit's precision alongside, following the additive snapshot precedent of stories 3.5 and 4.3. Without this the scan path cannot meet UX-DR26's inline refusal, and a dead-zone scan would queue only to be refused on replay.
- **Computed quantities need no per-site precision check.** Every derivation in the codebase is `min`, `max`, addition or subtraction over stored milli values, and those operations are **closed under alignment** — a multiple of 10^k combined with a multiple of 10^k stays one. There is no division over a quantity anywhere in `src/`. So aligning at the write edges aligns everything downstream, and the ~15 derivation sites need nothing.
- **The vocabulary follows the repo's own precedent exactly**, which is uniform across ten existing enums: a TS `as const` tuple beside the command that owns it, a hand-written `CHECK ("uom" IN (...))` in a migration, `@IsIn` + `@ApiProperty({ enum })` over the same tuple, and an e2e test pinning the TS list and the DB constraint together. No `pgEnum`, no lookup table — neither exists anywhere in this repo.
- **The migration surface is trivial.** CSV import is the only creator of SKUs (there is no `POST /skus`), `PatchSkuDto` carries no `uom`, so a SKU's base unit is immutable after import — and only four distinct UoM strings exist in the entire codebase: `pcs`, `kg`, `box`, `case`.

**Decided (2026-09-18, human):**
- **The vocabulary is CANONICAL UNITS plus a generous ALIAS MAP** — two lists, not one. Canonical units are what the system stores and what declares a precision; aliases are what an import file may say. `kgs`, `kilogram`, `kilo`, `"Kg."` all resolve to `kg`; `pcs`, `pc`, `piece`, `pieces`, `nos`, `no`, `unit`, `item` all resolve to `each`. A closed vocabulary exists to stop `pcs`/`PCS`/`pieces` becoming three units, and an alias map solves that without listing every spelling as its own unit — generous spelling surface, narrow storage surface. This preserves 10.1's normalization tolerance by design rather than by accident.
- **Canonical set = the domain list, no imperial.** Count and packaging at 0 dp (`each`, `box`, `case`, `carton`, `pack`, `pallet`, `bag`, `drum`, `roll`, `crate`, `bundle`, `pair`, `dozen`); mass at 3 dp (`g`, `kg`, `tonne`); volume at 3 dp (`ml`, `litre`, `kl`); length at 3 dp (`mm`, `cm`, `m`); area at 3 dp (`sqm`, `sqft`). Covers every approved tier — FMCG, pharma, apparel, spares, cold chain, agri, petroleum, construction. **`lb`, `oz`, `gallon`, `ft`, `inch` are deliberately excluded**: they are only useful to a tenant who also *converts* (stocks in kg, quotes in lb), and conversions do not exist. Shipping them now would deliver the half that does not work. The asymmetry favours breadth otherwise — a missing unit is a blocked onboarding needing a migration and a deploy, an extra unit is one line and a declared precision.
- **`uom_conversions.factor` stays an integer.** Same reasoning, same decision: nothing in the codebase multiplies by it, so a fractional factor has no consumer, and changing its type would break 10.1's guard test asserting no other column moved. Imperial units and fractional conversions are **one later story**, not two stubs.
- **`bins.capacity` is whole units only.** It is the one quantity with no unit at all — a bin holds many SKUs measured differently, and `putaway.command.ts:737` calls it "shared base-UoM space". A capacity of 2.5 means nothing an operator can act on. Comparing a whole-unit capacity against a fractional on-hand still works.

**Known consequence, accepted:** with `each` canonical, today's `pcs` SKUs normalize to `each`, so that field changes in API responses. Trivial at four distinct strings and pre-launch, but it is a visible change, not a silent one.

## Boundaries & Constraints

**Always:**
- **A precision refusal must never break a replay.** The check lives behind the idempotency lookup; an op that committed once replays its stored snapshot forever, whatever the current rules say. This is the constraint that shapes the story.
- **The device refuses before it queues.** A too-precise scan is refused on-device inside UX-DR4's Rejected banner (< 500 ms, naming the unit and the precision), from the cached snapshot, in a dead zone. A rejected scan never queues.
- The refusal follows the house shape already established by `serialTrackedFractionalUomDetail` and `assertRecordable`: name the field, the unit, the declared precision, and the offending value — never bare "invalid".
- **The TS vocabulary and the DB CHECK are pinned together by an e2e test**, as `orders.spec.ts` pins `ORDER_STATUSES` against `orders_status_check`. A new unit is added by a migration that drops and re-adds the CHECK, per the 0023/0024 precedent.
- The serial rule is re-expressed as a lookup against the vocabulary's precision (`precision === 0`), and `src/modules/catalog/uom-precision.ts` is **deleted**. Its two refusal sites and their message content stay — `test/fractional-quantity.spec.ts:800,815` pins the quoted unit and the phrase.
- An unknown unit is refused at catalog import as a **row-level** error, so the rest of the file still commits and `fix` mode can re-submit the row.
- Normalization tolerance survives: case, surrounding whitespace, and trailing spreadsheet punctuation (`"Kg."`) still resolve to the canonical unit.
- **Existing data is brought onto the vocabulary in the same migration.** Any stored quantity that is finer than its unit's new precision is aligned, and the alignment is visible in the migration, not implicit.

**Never:**
- No `pgEnum` and no lookup table — neither exists in this repo, and the enum-by-CHECK pattern is uniform across ten precedents.
- No change to the milli-unit representation, the scale, or `MAX_QUANTITY_BASE` — 10.1 settled those.
- No per-site precision guard on derived quantities; alignment is closed under the operations used, and scattering checks would imply otherwise.
- No new reservation, ledger or outbox semantics. This story constrains inputs; it does not change what a movement means.
- No web or mobile surface beyond the snapshot field and the regenerated client — stories 10-5 and 10-6.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Quantity within precision | `18.4` kg on a 3-dp unit | accepted, stored 18400 | N/A |
| Quantity too precise | `18.4567` kg | refused, naming the unit, its precision and the value | `400 validation-failed` |
| Whole-unit violation | `2.5` on an `each` SKU | refused — `each` declares 0 dp | `400 validation-failed` |
| Unknown unit at import | `uom` outside the vocabulary | that row fails, the rest of the file commits, `fix` mode can re-submit | row error `validation-failed` naming the unit |
| Normalization | `"Kg."`, `" KG "` | resolve to the canonical unit and are accepted | N/A |
| Replay of a committed op | queued device op, same `Idempotency-Key`, rules since tightened | **the stored snapshot is re-served** — the precision check sits behind the replay lookup | never a 400 |
| Device, offline, too precise | scan finer than the unit allows, no network | refused on-device < 500 ms inside the Rejected banner, naming the unit; **never queued** | N/A |
| Device, offline, within precision | valid scan, no network | queues and replays normally | N/A |
| Serial-tracked SKU | `serialTracked` on a unit whose precision > 0 | refused at import and on PATCH, naming the unit and the rule | `400 validation-failed` |
| DB backstop | a write attempting an unknown unit | refused by the CHECK | `23514` |
| Vocabulary drift | TS tuple and DB CHECK disagree | the e2e pin fails | N/A |
| Derived quantity | a short-pick remainder over aligned inputs | stays aligned; no check needed, none added | N/A |

</frozen-after-approval>

## Code Map

- `src/modules/catalog/uom-precision.ts` — **the file this story deletes.** `DISCRETE_UOMS` (~57 entries, `:41-98`), `normalizeUom` (`:105`, strips trailing `. , ; :`), `isDiscreteUom` (`:110`, no external caller), `isFractionalUom` (`:118`), `serialTrackedFractionalUomDetail` (`:127`). Only two consumers: `sku.command.ts:206,211` and `import.command.ts:744,747`. Its header already names 10.2 as its replacement. **Preserve:** fail-closed default, normalization tolerance, both refusal sites, and the message content pinned at `test/fractional-quantity.spec.ts:800,815`.
- `src/shared/db/schema.ts:281` (`skus.uom`, `text`, no CHECK, no index) and `:318-324` (`uomConversions.uom` + `factor: integer`, unique on `(skuId, uom)`). DDL in `drizzle/0004_previous_otto_octavius.sql:29,41-59`.
- **The vocabulary precedent, uniform across ten enums.** TS tuple beside its command: `ORDER_STATUSES` (`order.command.ts:54`), `SHORT_PICK_REASON_CODES` (`pick.command.ts:52`), `BLIND_REASON_CODES` (`receiving.command.ts:38`), `BIN_TYPES` (`tenancy.dto.ts:208`). DB CHECK in a migration: `orders_status_check`, `reservations_state_check` (`0009:38`), `devices_status_check` (`0012:40`), `picklist_lines_reason_code_check` (`0022:51`). Widening precedent: `drizzle/0023_packed_order_arm.sql` and `0024_dispatched_order_arm.sql` drop and re-add. API: `@IsIn(X)` + `@ApiProperty({ enum: [...X] })` over the same tuple (`outbound.dto.ts:660-664` carries the comment that they must be one tuple). Pin: `orders.spec.ts:906-920`.
- **The nine `toMilli` edges that move into commands.** SKU in scope: `inventory.controller.ts:118`, `outbound.controller.ts:101` (per line), `:194` (per line), `:556`, `receiving.controller.ts:117` (per line), `inbound.controller.ts:155`/`:275` (per line), `putaway.controller.ts:96`. **Harder:** `catalog.controller.ts:223-224` converts `reorderPoint`/`reorderQty` *before* any DB read, while the SKU's unit is only in the row the command later reads at `sku.command.ts:192-197`. `tenancy.controller.ts:285,333` (`bins.capacity`) has no SKU at all — see Open Question 1.
- `src/shared/primitives/quantity.ts` — `toMilli` (`:113-126`, `Math.round`, half-up toward +∞, asymmetric on negatives and **unpinned by tests for the negative tie**), `fromMilli` (`:135-147`), `scalesToZero` (`:154-161`), `QUANTITY_FIELD_DESCRIPTION` (`:58-61`, interpolated into nine DTO descriptions and published to OpenAPI — its "is rounded to 3 decimal places" wording becomes a lie and must change).
- `src/api/outbound.controller.ts:700-711` and `src/api/inventory.controller.ts:727-738` — two **duplicated** `assertRecordable` helpers, the existing "too fine" refusal. The house shape to generalize, and the duplication to collapse while moving it.
- `src/modules/inbound/receiving.dto.ts:422` (`CatalogSnapshotSkuDto.uom`) + `:449-471` (snapshot shape) + `src/modules/catalog/catalog.facade.ts:164-177` (`getSkuSummariesInTx`) + `src/modules/inbound/receiving.facade.ts:324-394`. The snapshot gains precision here. **Constraint:** everything must run on the caller's transaction (`receiving.facade.ts:330-333`) — a nested pool-opening read caused a documented deadlock.
- `src/modules/catalog/import.command.ts:698-748` — row validation order (`:692-694`), `UOM_MAX = 32` (`:40`), `uom` read at `:714` **trimmed but not lower-cased**, `rowError` (`:383-390`), row codes documented only in an `@ApiProperty` string (`catalog.dto.ts:30`). `catalog_import_errors.code` has no DB CHECK, so a new row arm needs no migration. `parseQuantityMilli` (`:688`) is the CSV quantity edge.
- `src/modules/catalog/sku.command.ts:192-213` — the PATCH path that re-reads the SKU row; the natural home for the moved `reorderPoint`/`reorderQty` conversion and the serial-rule lookup.
- `drizzle/` — next index is **0027**; a hand-written migration needs its journal entry **and** a tracked `0027_snapshot.json`. The 10.1 review found that snapshot untracked; `git add` it.
- `test/fractional-quantity.spec.ts:750-756` — the test that currently pins *rounding* (`18.4567` → `18457`) with the comment "the refusal arrives with story 10.2". **This story flips it**; it is the matrix row that changes meaning.

## Tasks & Acceptance

**Execution:**
- [x] `wms-be src/modules/catalog/uom.ts` — the vocabulary: the `as const` tuple, each unit's declared precision, normalization, and the lookup helpers; `uom-precision.ts` deleted
- [x] `wms-be drizzle/0027_*.sql` + journal + **tracked** snapshot — the `skus_uom_check`, the `uom_conversions_uom_check`, and the alignment of any stored quantity finer than its unit now allows
- [x] `wms-be src/shared/primitives/quantity.ts` — precision-aware conversion and refusal; the two duplicated `assertRecordable` helpers collapsed into it; `QUANTITY_FIELD_DESCRIPTION` corrected
- [x] `wms-be` the nine `toMilli` edges — conversion moved from controller into command, **behind the idempotency replay lookup**
- [x] `wms-be src/modules/catalog/sku.command.ts` + `import.command.ts` — the serial rule as a precision lookup; the unknown-unit row error
- [x] `wms-be` the catalog snapshot — the unit's precision alongside `uom`, on the caller's transaction
- [x] `wms-be src/api/**` + DTOs — `@IsIn` + `@ApiProperty({ enum })` on every UoM field
- [x] `wms-be test/uom-precision.spec.ts` — the matrix, the TS↔DB vocabulary pin, and the replay-after-tightening case
- [x] `wms-be test/fractional-quantity.spec.ts` — flip the rounding test to a refusal
- [x] `wms-be bun run openapi:export` + `wms-fe bun run api:generate`

**Acceptance Criteria:**
- Given a unit declaring 0 dp, when a fractional quantity is submitted for a SKU in it, then it is refused naming the unit, its precision and the value
- Given a device op that already committed, when it replays after the rules tighten, then the stored snapshot is re-served and no precision check runs
- Given the catalog snapshot, when the device reads a SKU, then the unit's precision is present and a too-precise scan is refused on-device without queueing
- Given the vocabulary tuple and the DB CHECK, when they disagree, then an e2e test fails
- Given a CSV row with an unknown unit, when the file is imported, then only that row fails and `fix` mode can re-submit it

## Implementation Notes

**Where each conversion landed.** Every `toMilli` edge moved from its controller into the command that owns the write, positioned after the idempotency replay lookup AND after the read that yields the SKU's `uom`:

| Command | Position |
| --- | --- |
| `inventory.command.adjust` | after `assertSkuInTenant` (which now selects `uom`) |
| `order.command.createOrder` | in the preflight tx, after `assertSkuIdsInTenant` (now returns a `skuId → uom` map) |
| `pack.command.packOrder` | `assertScanPrecision` after the SKU read; `aggregateScan` does the arithmetic only |
| `pick.command.recordPick` | `scaled` built after the SKU read; nothing below reads `command.qty` |
| `receiving.command.submitGoodsReceipt` | `lines` built after `loadSkus` |
| `po.command.create` / `.amend` | `scaleLines` after `assertSkuIdsInTenant` |
| `putaway.command.placePutaway` | `scaled` built after the SKU read |
| `sku.command.edit` | after the SKU row re-read, beside the serial rule |
| `bin.command.createBin` / `.generateGrid` | `assertWholeUnitCapacity` after the replay lookup (no SKU — capacity has no unit) |

The two `assertRecordable` helpers collapsed into `assertRecordableQuantity` in `quantity.ts`, which refuses in order: out of exact range → finer than the unit → would scale to zero. The third arm is now structurally unreachable (the finest unit declares `QUANTITY_DECIMALS` places) and is kept as a backstop with that noted.

**Precision is read from the value's decimal string, not from arithmetic.** `decimalPlaces` uses `String(n)` — the shortest decimal that round-trips, i.e. the literal the client sent. `value * 10 ** p % 1` cannot do this job and the error falls on the honest side: `1.005 * 1000` is `1004.9999999999999`, so a weight a scale prints every day would be refused as too fine (thousands of values in any 3-dp range do this). A tolerance does not rescue it either — the absolute error scales with the magnitude, so the epsilon that forgives 1.005 is the wrong epsilon at 9 × 10¹¹. Pinned in `pagination.spec.ts`.

**`@IsIn` has no request field to guard.** CSV import is the only creator of SKUs and `PatchSkuDto` carries no `uom`, so every UoM DTO field is a RESPONSE field; all three (`SkuResponse.uom`, `SkuUomConversionResponse.uom`, `CatalogSnapshotSkuDto.uom`) carry `@ApiProperty({ enum: [...UOMS] })` and the generated FE client now types them as the closed union. The request-side gate is the import command's `resolveUom` row error plus the DB CHECK.

**Bin capacity: one rule at three gates, enforced in the command.** Whole units, at least one. The DTO *documents* it (`minimum: 1`) but does not validate it — an `@IsInt()` there would refuse a fractional value in the ValidationPipe, in front of the replay lookup, which is the exact defect the rest of this story exists to avoid. `assertWholeUnitCapacity` owns the refusal and `bins_capacity_whole_units` (`% 1000 = 0 AND > 0`) is the DB backstop.

**Migration 0027's quantity alignment touches zero rows today** and says so: 0026 multiplied every quantity by exactly 1000, so every pre-existing value is already a multiple of it. The statements are written anyway (an alignment claimed in a comment is not auditable), and `ledger_events` is deliberately NOT rewritten — it is append-only, trigger-guarded and hash-chained, so a misaligned event raises instead.

## Spec Change Log

## Review Triage Log

**Loop 1 — three layers over the complete diff (untracked files included this time; the 10.1 pass omitted them). ~30
findings: 7 high, 13 medium, 10 low. All route to `patch` — and one of them is a defect in THIS SPEC'S frozen block,
not in the code. No loopback: its resolution has exactly one possible reading.**

| # | Finding | Layer | Verdict | Evidence |
|---|---------|-------|---------|----------|
| 1 | Eleven units 10.1 treated as discrete — `bottle`, `can`, `set`, `tray`, `tin`, `jar`, `tube`, `sheet`, `bar`, `cylinder`, `keg` — are absent from both the canonical set and the alias map | blind + edge | **high — patch (SPEC DEFECT)** | Verified: zero occurrences of each in `uom.ts`. **The frozen block's enumeration is wrong**, not the implementation — the canonical set was recommended without cross-checking it against the allowlist it replaced, so a narrowing shipped as a broadening. `bottle`, `can`, `tray`, `set` are ordinary warehouse units, and any stored row using one hard-fails `skus_uom_check` and aborts the migration. Patched rather than looped back because the reading is unambiguous: nothing previously valid may become unrepresentable. **Fixed:** the eleven added as canonical 0-dp units with plural aliases (35 total), and 10.1's full allowlist frozen in `uom.ts` and asserted resolvable-and-0-dp at load, so the regression cannot recur silently |
| 2 | `UOM_ALIASES[normalized] ?? null` inherits from `Object.prototype` | edge | **high — patch** | Proved by execution: `constructor` → `function`, `__proto__` → `object`, `toString`/`valueOf` → `function`, so `?? null` never fires. A CSV cell spelling a prototype key resolves to a Function, skips the unknown-unit refusal and corrupts the import. **Fixed:** map built on `Object.create(null)`, probed in the suite |
| 3 | The idempotency fingerprint silently changed from milli to base units across nine commands, and `order.command`'s `sourcePayloadHash` with it | v-gap + edge | **high — accepted, recorded** | Verified across all nine sites. A key or channel payload from the deployed build recomputes differently, so `payloadHash !== stored` answers **422 `idempotency-key-reuse`**, and channel dedup answers `order-source-conflict` instead of recognising a redelivery — the exact failure the replay-ordering work exists to prevent, moved from the precision check to the hash comparison. `pick.command.ts:355` states the house rule being broken. **Human decision: accept under the pre-launch premise**, as 10.1 accepted its own hash break; no compatibility branch. **Fixed:** a note at every affected fingerprint recording the convention change and that no pre-10.2 key can replay |
| 4 | The repo's only cross-version replay guard was retargeted to the new convention | v-gap | **high — patch** | Smoking gun in the diff: `picking.spec.ts:1890` changed from `qty: toMilli(body.qty)` to `qty: body.qty`, with a comment explaining the new convention — a deliberate accommodation that destroyed the test's only purpose. It now pins same-version replay and cannot detect a convention change. **Fixed:** original kept, plus a sibling seeding a 10.1-convention milli hash and asserting `422`, pinning the accepted break as EXPECTED — the shape 10.1 used for its `verifyChain` break |
| 5 | Normalization and the alias rewrite can collapse two conversion rows for one SKU onto the same canonical unit | blind + edge | **high — patch** | `uom_conversions_sku_id_uom_unique` on `(skuId, uom)` (`schema.ts:323`); the identity-conversion DELETE ran *after* the UPDATEs, too late to help. A `23505` aborts the migration mid-deploy. **Fixed:** identity-delete and `(sku_id, canonical)` dedup both run on the RESOLVED value ahead of every UPDATE, keeping the oldest uuidv7 |
| 6 | Migration 0027's ~90 lines of data movement are pinned only by a `String.includes` substring check | v-gap | **high — patch** | Demonstrated: flipping the alias UPDATE's predicate from `= a.alias` to `= a.canonical` ships a migration that maps nothing and still passes, then aborts a real deploy at `skus_uom_check`. 10.1 built exactly the right harness one story ago and this story did not reuse it. **Fixed:** `migration 0027, applied to pre-vocabulary data` on the 10.1 harness — journal trimmed to idx ≤ 26, seeded with `pcs` / `" Kg. "` / `boxes`, a colliding conversion pair, an identity conversion, a sub-500-milli capacity and a misaligned ledger event. Mutation-checked both ways |
| 7 | The precision refusal is untested at six of nine write paths, including both device routes | v-gap | **high — patch** | Demonstrated by mutation: swapping `assertRecordableQuantity` for `toMilli` at pick, putaway, receiving, PO, order and pack leaves every suite green, because every other suite seeds `pcs` SKUs and sends whole integers. A pick of `2.5` on an each-counted SKU would be silently recorded. **Fixed:** device-route coverage for receiving and pick; mutation-checked |
| 8 | Per-column rounding can diverge `sum(batch_on_hand)` from `stock_on_hand` and push `reserved_qty` past `qty` | edge | **medium — patch** | Each projection rounded independently, some with a `greatest(…, 1000)` floor and some without, so the relationship can invert and ATP go negative. **Fixed:** `stock_on_hand` follows its batch rows by captured delta; paired columns round in one statement with the dependent half clamped; a post-alignment `DO` block asserts all four pairings |
| 9 | A `bins.capacity` below 500 milli rounds to `0` | edge | **medium — patch** | `0.4` was legal under 10.1's `@Min(0.001)`, and `bins.capacity` carries no positivity CHECK, so the bin silently becomes permanently unfillable — `occupancy + qty > capacity` refuses every putaway. **Fixed:** capacity floors at one whole unit; the CHECK is now `% 1000 = 0 AND > 0` |
| 10 | An unmappable spelling surfaces as a bare `23514` naming one value | blind + edge | **medium — patch** | The file's own ledger guard shows the better pattern. An operator would fix one row per migration run. **Fixed:** pre-flight `DO` block listing every unresolvable spelling from both tables at once |
| 11 | "No `pgEnum` exists in this schema" is false | blind | **medium — patch** | `schema.ts:57` declares `userRoleEnum`. Asserted in `uom.ts`, in migration 0027, **and in this spec's frozen block** — I propagated it from the investigation without checking. The CHECK choice stands; the justification was a falsehood. **Fixed in code:** an enum needs `ALTER TYPE` to extend, a CHECK is dropped and re-added like the other ten vocabularies. The frozen block is left as written; this row is the correction |
| 12 | The TS↔migration alias pin is one-directional, and the whole-unit set is hardcoded thirteen times | blind + edge | **medium — patch** | An alias in SQL but absent from TS passes silently; adding a 0-dp unit would miss all thirteen rounding statements invisibly. **Fixed:** pairs parsed out of the SQL and compared as sets both ways; the migration declares the set ONCE in a temp table that every statement reads, pinned against `WHOLE_UNIT_UOMS` |
| 13 | `@IsInt() @Min(1)` on bin capacity validates in FRONT of the replay lookup | v-gap | **medium — patch** | Directly defeats `bin.command.ts:245`'s deliberate positioning, whose own comment says a refusal in front of the replay would answer 400 to an op that already committed. **Fixed:** DTO documents the bound without validating it; the command owns the refusal |
| 14 | Bin capacity `0` is accepted by the command and the CHECK but refused by the DTO's `minimum: 1` | blind | **medium — patch** | A non-HTTP caller could create a permanently unfillable bin the API contract calls impossible. **Fixed:** one rule at all three gates |
| 15 | `tenancy.spec.ts:1177`'s RLS fixture now has two reasons to fail | blind | **medium — patch** | Inserts `capacity: 1` (one milli) and asserts `/row-level security/i`; the new CHECK gives the same insert a second failure mode, so the assertion depends on which error Postgres raises first. **Fixed:** `toMilli(1)`, matching `bin-admin.spec.ts:926` |
| 16 | Two DTOs still publish 10.1's "below 0.001 is refused" sentence beside the new per-unit text | blind | **medium — patch** | Reads as nonsense for an `each` SKU, where anything below 1 is refused. `quantity.ts` already concedes the branch is structurally unreachable. **Fixed:** sentence dropped from both published descriptions |
| 17 | The zero-delta and serial-count checks moved from before the transaction to inside it | v-gap | **medium — patch** | A request both malformed and scoped to a nonexistent warehouse now answers 404 where it answered 400; one carrying a used key replays 201 where it answered 400. **Fixed:** cheap shape checks restored ahead of the scope reads; only the precision rule sits behind the replay, with a comment saying why |
| 18 | `unknownUomDetail` samples eight packaging units and can print a negative remainder | edge | **low — patch** | `UOMS.slice(0, 8)` shows an operator whose cell says `pounds` nothing resembling mass or volume; "and N more" goes negative if the vocabulary shrinks below the sample size. **Fixed:** one unit per family, remainder clamped, OpenAPI enum named as the full list |
| 19 | Six exports have no consumer | blind | **low — patch** | `isUom`, `isWholeUnitUom`, `spellPrecision`, `normalizeUomInput`, `decimalPlaces`, `scalesToZero`. A closed vocabulary's value comes from one resolution point; every extra exported predicate is a way to bypass it. **Fixed:** `isUom` deleted, the rest made private; `decimalPlaces`/`isAtPrecision` gained unit tests |
| 20 | Both controllers end with three newlines | blind | **false** | The claim was that this trips `no-multiple-empty-lines` in CI. Confirmed three newlines by `od -c`, but `bun run lint` passes with the same eslint config CI runs — the rule is not enabled. Cosmetic, not a gate |
| 21 | `@IsIn(UOMS)` is described in a doc comment but exists nowhere | blind + edge | **low — patch (comment)** | Accurate, and correctly so: there is no `POST /skus` and `PatchSkuDto` carries no `uom`, so every UoM field is a response field. The request-side gate is the import row error plus the DB CHECK. The comment described a validator the code does not have |
| 22 | `decimalPlaces`'s exponential-notation branch is unreachable | v-gap | **low — rejected** | True but harmless: JS emits exponential form only below `1e-6` (caught by the `scalesToZero` backstop) or at/above `1e21` (beyond `MAX_QUANTITY_BASE`). Dead code guarded by other checks, not a live risk. Removing it would trade a cheap guard for a reasoning burden on the next reader |
| 23 | The `pcs` → `each` rewrite is irreversible and unrecorded | blind | **low — accepted, recorded** | Correct: no `uom_legacy` column, no audit row, no down migration. Already named in the frozen block as a known accepted consequence; at four distinct spellings and pre-launch it is fine. Recorded here so the absence reads as a decision rather than an omission |
| 24 | The alias VALUES block is copy-pasted verbatim twice in the migration | blind | **low — patch** | ~110 pairs duplicated for `skus` and `uom_conversions`, a guaranteed future divergence. **Fixed:** superseded by the temp-table declaration in finding 12 — the map now exists once and both UPDATEs read it |

**Process note.** The 10.1 review ran three of four layers against an incomplete diff because `git diff` omits untracked files. This round staged with everything included and verified the new files were present before dispatching — `uom.ts`, migration 0027 and the new spec file all appear. Findings 1, 5, 6 and 10 are all in those files and would have been invisible under the old staging.

## Design Notes

**Why derived quantities need no checks.** Every derivation in the codebase — FEFO splits, re-plan slices, over-receipt excess, PO open quantity, ATP — is `min`, `max`, addition or subtraction over stored milli values, and there is no division over a quantity anywhere in `src/`. Those operations are closed under alignment: combine two multiples of 10^k and you get a multiple of 10^k. So constraining the write edges constrains every derived value for free. Scattering guards across the ~15 derivation sites would not add safety; it would imply the closure property does not hold and invite someone to "fix" an edge by rounding mid-pipeline, which is exactly how a ledger loses a unit.

**Why the check cannot stay at the controller edge.** `toMilli` currently runs while building the facade argument, before the command opens its transaction and before `replay()` reads the idempotency row. A device that queued a scan under the old rules and replays it after the rules tighten would be refused at the edge — including when that exact op already committed, whose replay must return its original `201`. Moving conversion into the command puts the check behind the replay lookup, where a stored snapshot always wins. This also fixes the duplication: two hand-copied `assertRecordable` helpers become one.

## Verification

**Commands:**
- `cd workspace/core/backend/wms-be && bun run test && bun run lint && bun run typecheck && bun run build` — the **full** suite; the moved edges touch every quantity-bearing module.
- `bun run db:migrate && bun run db:verify` against a **freshly reset** database, then `bun run db:generate` — expected: **no new migration emitted**.
- `git status --short` — expected: **no untracked files**. The 10.1 review found `0026_snapshot.json` untracked; the same mistake here would make the next `db:generate` emit a duplicate type change.
- `grep -rn "uom-precision" src/ test/` — expected: no hit. The stopgap is deleted, not orphaned.
- `cd workspace/core/frontend/wms-fe && bun run test && bun run lint && bun run typecheck && bun run build` — stays green after `api:generate`.
