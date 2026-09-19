---
title: '10-3 Catch weight and handling units'
type: 'feature'
created: '2026-09-18'
status: 'done'
route: 'dispatch'
baseline_commit: '07259090f912abe5704cf083ada8c2894ec93aa5'
review_loop_iteration: 1
context:
  - '_bmad-output/implementation-artifacts/epic-10-context.md'
  - 'docs/design/SYSTEM-DESIGN.md'
  - 'docs/design/IMPLEMENTATION-GUIDE.md'
  - 'docs/design/modules/inventory.md'
  - 'docs/design/modules/inbound.md'
  - 'docs/design/modules/outbound.md'
  - 'docs/design/modules/catalog.md'
  - 'docs/design/PENDING.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** Catch-weight goods — meat, fish, cheese, produce — are handled by unit and priced by weight: a case of beef is *one* case weighing 18.4 kg, and the next weighs 18.6 kg. Nothing can hold a per-unit actual weight. `skus` has only `batch_tracked`/`serial_tracked`; `stock_on_hand` is keyed `(tenant, warehouse, sku, bin)` and carries quantity alone. The one weight field that exists (`pack.weightGrams`) is a per-**parcel** gross shipping weight, written into `reference_doc` jsonb and never read back — a different concept at a different granularity.

**Approach:** A `handling_units` table holding one row per physical unit: its immutable captured weight, its SKU and batch, its provenance, and its own status lifecycle. It is a **relational satellite record, deliberately NOT a ledger-tracked entity.** A `catch_weight_tracked` flag on `skus` gates the behaviour and rides the device catalog snapshot so mobile can prompt offline. Weight is **integer grams**, never a milli-unit quantity.

**The table, at field level:**

| Column | Type | Notes |
|---|---|---|
| `id` | `uuid` pk, uuidv7 | |
| `tenant_id` | `uuid not null` | the RLS predicate; policies are single-dimension on this alone |
| `warehouse_id` | `uuid not null` | pack's cross-warehouse 404 guard — **not** part of RLS |
| `sku_id` | `uuid not null` | pack checks it against the line's SKU |
| `batch_id` | `uuid null` | set when the SKU is batch-tracked; what makes `catch_weight × batch` genuinely usable |
| `grn_line_id` | `uuid not null` | provenance — which receipt line produced this unit |
| `weight_grams` | `integer not null` | **immutable**; CHECK `> 0 AND <= MAX_HANDLING_UNIT_WEIGHT_GRAMS` |
| `status` | `text not null default 'active'` | CHECK against the four-value vocabulary |
| `packed_order_line_id` | `uuid null` | **set once**, at pack, by conditional write on `status = 'active'` |
| `created_at` / `updated_at` | `tenantTimestamps` | the repo's shared column pair |

Statuses: `active` · `pending_approval` · `rejected` · `packed`. No FK constraints (repo convention). RLS policy and both CHECKs live **only** in the migration.

**Decisions taken (human):**

1. **Capture once at receipt; carry.** *(2026-09-18)* FR33 is authoritative over UX-DR27's "receive + pack" phrasing: one weight per unit, captured at receipt, **immutable**, read at pack and invoice. No re-weigh. *Accepted consequence:* drip loss between receipt and dispatch is invoiced at the receipt weight. Shrinkage is not modelled.
2. **Tied to an order at PACK, by scan.** *(2026-09-18)* The pick path is untouched, preserving its ≤ 4-scans-plus-confirm budget. Between pick and pack the specific units are deliberately unknown — they are physically on the cart. Mobile's scan surface is **10-6**; this story provides the API and the refusals.
3. **A satellite record, not a ledger entity.** *(2026-09-19, replacing the original decision 3 — see Spec Change Log)* `ledger_events` gains **no column**. Association and lifecycle live on `handling_units` itself. Tamper evidence comes from `handlingUnitIds` riding the **already-hashed** `reference_doc` of the existing per-line `pack.packed` event, which changes no historical event's bytes. **Accepted and documented: a handling unit has no queryable location between receipt and pack.** Unlike serials — which earn ledger-derived location by fanning out at putaway and pick — nothing here tracks a unit mid-life, and this design does not pretend otherwise. Mid-life traceability is epic 15's problem, alongside move-as-unit.

## Boundaries & Constraints

**Always:**
- **Catch weight is never a quantity.** It never enters `quantity_delta`, never touches `toMilli`/`assertRecordableQuantity`, never reaches the Valkey ATP path. A case of beef is quantity `1`, weight `18400 g`. Violating this re-opens 10-1's completed migration.
- **Weight is integer grams.** Weight has no reservation, so the 2⁵³ Lua/JS ceiling that forced quantity to milli-units does not bind it.
- **A captured weight is immutable.** No UPDATE of `weight_grams`, ever.
- **`handling_units` carries its own `batch_id`.** This is what makes `catch_weight × batch` genuinely usable rather than nominally allowed — the unsolved `serials`-have-no-batch problem behind the `pick.command.ts:748` refusal is avoided by not repeating its shape.
- **`catch_weight × serial` is refused** with a named error. Two per-unit identity systems over one unit is its own change.
- **Pack admits only `active`, and every path that can consume a unit must either move its status or be REFUSED.** There is no third option: a consuming path that leaves a unit `active` ships goods that inventory says do not exist. Because a handling unit has no location, an aggregate-scoped operation cannot infer which units it touched — so a path either names units explicitly, or it is refused for catch-weight SKUs.
  - **Adjustment names them.** `AdjustStockCommand` gains `handlingUnitIds`, mirroring its existing `serialRefs` channel. The operator knows which case is damaged.
  - **QC hold refuses them.** `qc.command.ts:188-190` already refuses serial-tracked bulk holds because "the movements carry no serial arms, so the serials' location records would stay at the origin bin while their stock relocates" — that reasoning transfers verbatim. A catch-weight QC hold is refused by name and deferred, rather than silently leaving pack open.
- Authority before validation; tightening rules behind the replay lookup; cheap shape checks above the transaction (the three tiers, `IMPLEMENTATION-GUIDE.md` §1).
- **`catalog` owns `handling_units` exclusively (AD-6).** `serials` has exactly one writer — `catalog.facade.ts:381` — and every other module reads it or goes through the facade. Inbound, outbound and inventory mutate handling units only through new `catalog.facade` methods, never by touching the table. This is the rule `architecture.spec.ts` exists to enforce, and catalog currently has no block in it.
- **Handling-unit ids are supplied per SKU**, alongside the existing `scanned` array — never per order line. `pack.command.ts:344-346` states that the bench counts SKUs and *cannot* tell which line of a two-line order a unit belongs to. The command assigns units to lines server-side using the same `picks.orderLineId` split that already derives per-line `packedQty`, consuming ids in sorted order so the assignment is deterministic and replayable.
- **The id list is SORTED before hashing**, matching `scanned` in the same command (`pack.command.ts:198-207`). Scanning A,B,C is the same physical act as C,B,A and must not create two packs.

**Never:**
- **No `ledger_events` column and no new ledger event type.** Hashing a new column would change the canonical bytes of every pre-existing event and break `verifyChain` a second time on top of 0026; not hashing it would leave the invoice-determining field outside the tamper-evident chain.
- **No mid-life location tracking, and no claim of any.** Putaway, pick and bin merge continue to move aggregate quantity with no per-unit reference — none of them can consume a unit, so none can open the pack guard. QC hold *can*, which is why it is refused above rather than left silent.
- **No independent location and no move-as-unit** (FR54 / epic 15, deferred).
- No reuse of `pack.weightGrams` for catch weight — parcel gross vs per-unit net are different concepts.
- No returnable-container custody or deposits (FR52-53, epic 15).
- No web or mobile surfaces — 10-5 and 10-6 own those.
- No change to `uom_conversions.factor`.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Receive catch-weight stock | GRN line, `catch_weight_tracked`, qty 6, six weights | 6 `handling_units` rows, `status: 'active'`, each with its own `weight_grams`, `sku_id`, `batch_id`; ledger unchanged — one `grn.received` per line as today | N/A |
| Receipt weight count mismatch | Weights absent, short, or long vs `qty` | `400` naming both counts | Shape check **above** the transaction |
| Over-receipt split | qty 6, PO ceiling admits 4 | **All 6 rows created.** The 4 applied are `active`; the 2 excess are `pending_approval` | Approval flips to `active`; rejection flips to `rejected`. Neither creates nor destroys rows |
| Non-catch-weight SKU sends weights | Flag false, weights supplied | `400` — meaningless for this SKU | Fail closed; never ignored |
| Weight out of bounds | `0`, negative, non-integer, `> MAX_HANDLING_UNIT_WEIGHT_GRAMS` | `400` naming the bound | Mirrors `assertWeight` (`pack.command.ts:645`) |
| `catch_weight` + `serial_tracked` SKU | Both flags true | `400` naming both and why | Explicit refusal |
| `catch_weight` + `batch_tracked` SKU | Both flags true | **Accepted** — the unit row carries `batch_id` directly | N/A |
| Pack scans units | Ids listed **per SKU**, beside `scanned` | `status → 'packed'`; units assigned to lines server-side from the `picks.orderLineId` split, sorted ids consumed in order; ids ride each line's existing `pack.packed` `reference_doc` | N/A |
| Adjustment names units | `handlingUnitIds` on a catch-weight adjustment | Named units leave `active`; ledger quantity moves as today | Count must equal `|quantityDelta|` — `400` otherwise, mirroring the serial-count rule |
| Adjustment omits units | Catch-weight SKU, no ids | `400` naming the requirement | Fail closed — an untargeted write-off would leave pack open |
| QC hold on a catch-weight SKU | `placeHold` for such a SKU | `400` naming the SKU and why it is unsupported | Precedented refusal (`qc.command.ts:188-190`); deferred, not silently wrong |
| Pack: unknown / other tenant / other warehouse | Id absent, foreign tenant, foreign warehouse | `404` | Resolved inside the tenant transaction; never leaks existence |
| Pack: unit's SKU ≠ the line's SKU | Mismatch | `422` naming both SKUs | Checked against the unit's own row |
| Pack: duplicate id in one request | Same id twice | `400` naming the duplicate | Shape check, above the transaction |
| Pack: unit not `active` | Already `packed`, `rejected`, or adjusted away | `409` naming the current status | Conditional write `.where(status = 'active')`; empty result → 409. A QC-held unit cannot occur — such a hold is refused upstream |
| Pack: id count ≠ the SKU's packed quantity | 3 ids for a packed quantity of 4 | `422` naming both counts | A catch-weight SKU must account for every unit |
| Replay of receipt or pack | Same key + same payload | Original snapshot; no second row, no status re-flip | Behind the replay lookup |
| Device reads snapshot | Catalog snapshot fetched | `catchWeightTracked` per SKU, so the device prompts offline | N/A |

</frozen-after-approval>

## Code Map

- `src/shared/db/schema.ts:378-398` (`serials`) — the shape reference for a per-unit identity table, **with a stated divergence**: `handling_units` adds `warehouse_id`, `batch_id` and `status`, because it is not ledger-tracked and must answer from its own row what serials answer from the ledger. `serials.status` exists but nothing updates it (`catalog.facade.ts:285,394` are reads) — so a written-later column is a **new pattern here**, justified on merits, not by analogy.
- `src/modules/inventory/ledger.service.ts:208-227` (`canonicalEventBytes`) — the fixed hash field list. **Do not add to it.** `referenceDoc` is hashed at `:224`, and a new optional key leaves historical events' bytes untouched because their stored jsonb lacks it. This is why the ids ride the reference doc.
- `src/modules/inventory/ledger-registry.ts:118-135` — the `'pack'` reference-doc arm; `handlingUnitIds?: readonly string[]` is added here. `:332-336` keeps `allowsBatchArm`/`allowsSerialArm` **false** — untouched by this story.
- `src/modules/catalog/catalog.facade.ts:381` (`ensureSerials`) — **the ownership seam to copy.** The only writer of `serials` in the repo; inventory, outbound, putaway, inbound and tenancy all read serials but never write them. The handling-unit facade methods live beside it.
- `src/shared/db/schema.ts:284-285` (`skus` flags) — `catch_weight_tracked` joins them. Branch precedent: `pick.command.ts:646,748`, `receiving.command.ts:952`, `qc.command.ts:181`.
- `src/modules/inbound/receiving.command.ts:227` (`submitGoodsReceipt`), `GrnLineInput` at `:49-63`, the `applied = min(qty, remaining)` split at `:415-419`, the `goods_receipt_lines` insert at `:497-508` (`schema.ts:1204-1226`), the `grn.received` append at `:513-538` — **the ledger append is NOT modified**; unit rows are written alongside it.
- `src/modules/inbound/receiving.command.ts:677-800` (`decideOverReceipt`) — appends a second `grn.received` on approval. The `pending_approval → active | rejected` flip goes here. **The spec's first draft missed this path entirely.**
- `src/modules/inventory/inventory.command.ts:491-546` — the serial fan-out in `adjustToSnapshot`, the precedent for an adjustment naming per-unit identities. Catch-weight adjustments must move unit `status`, or pack fails open.
- `src/modules/inbound/qc.command.ts:188-190` — the serial-tracked bulk-hold refusal whose reasoning transfers verbatim to catch weight; the catch-weight refusal goes beside it.
- `src/modules/inventory/inventory.command.ts:52-96` (`AdjustStockCommand`) + `inventory.dto.ts:185` (`serials?`) — the aggregate command shape and the existing per-unit channel `handlingUnitIds` mirrors. **`inventory.dto.ts` needs the new field; the first revision named only the command file.**
- `src/modules/outbound/pack.command.ts:82-93` (`scanned`, per-SKU), `:227` (`aggregateScan`), `:344-346` (**"the bench counts SKUs and cannot tell which line"** — why ids are per-SKU), `:427` (`packedQty` derived from `picks`, not from the scan).
- `src/modules/outbound/pack.command.ts:96-97` (per-order `weightGrams` — a different concept), `:198-207` (**the sort-before-hash precedent to follow**), `:594-629` (`assertScanMatchesPicked`, SKU-aggregated — the per-line unit check is new), `:645` (`assertWeight`, the bounds shape to mirror).
- `src/modules/inbound/receiving.facade.ts:64-77` + `receiving.dto.ts:413-443` — the catalog snapshot gains `catchWeightTracked`. **Constraint:** runs on the caller's transaction (`receiving.facade.ts:330-332`); a nested pool-opening read caused a documented deadlock.
- `src/shared/primitives/quantity.ts` — **reference only.** Catch weight must never acquire `toMilli`/`assertRecordableQuantity`.
- `test/fractional-quantity.spec.ts:95` and `test/uom-precision.spec.ts:76` — the migration-proof harness (`describe('migration NNNN, applied to pre-X data')`, journal trimmed to the prior idx). 0028 is additive, but the harness is the house standard for proving a migration ran.
- `drizzle/` — highest is `0027_uom_vocabulary.sql`; next is **0028**. Every migration through 0027 has a tracked `meta/NNNN_snapshot.json`; `git add` the new one.

## Tasks & Acceptance

**Execution:**
- [x] `drizzle/0028_catch_weight_handling_units.sql` -- create `handling_units`; add `skus.catch_weight_tracked` default `false`; RLS policy + status CHECK **here, never in `schema.ts`** -- repo convention. **No `ledger_events` change.**
- [x] `drizzle/meta/_journal.json` + `drizzle/meta/0028_snapshot.json` -- journal entry with matching tag; snapshot **tracked in git** -- an untracked snapshot makes the next `db:generate` emit a duplicate
- [x] `src/shared/db/schema.ts` -- declare `handlingUnits` and the `skus` flag -- structure only
- [x] `src/modules/catalog/handling-unit.ts` -- `HANDLING_UNIT_STATUSES` as an `as const` tuple, `MAX_HANDLING_UNIT_WEIGHT_GRAMS`, `assertCatchWeightGrams` -- one resolution point; the status tuple follows the controlled-vocabulary pattern (tuple + DB CHECK + e2e pin)
- [x] `src/modules/catalog/catalog.facade.ts` -- `createHandlingUnits`, `settleHandlingUnitIntake` (`pending_approval → active | rejected`), `markHandlingUnitsPacked`, `markHandlingUnitsAdjusted`, all on the caller's transaction -- **the single write seam** covering all four transitions; siblings never touch the table (AD-6)
- [x] `src/modules/inbound/receiving.command.ts` + `receiving.dto.ts` -- per-unit `weightsGrams` on the GRN line; count check above the transaction; unit rows created **through the catalog facade** inside it, `active` for applied and `pending_approval` for excess
- [x] `src/modules/inbound/receiving.command.ts` (`decideOverReceipt`) -- flip `pending_approval → active` on approve, `→ rejected` on reject -- the path the first draft missed
- [x] `src/modules/inventory/inventory.command.ts` + `inventory.dto.ts` -- `handlingUnitIds` on the adjustment, count-checked against `|quantityDelta|` above the transaction, status moved **via the facade** -- without a way to NAME the units, the write-off is untargetable and pack fails open
- [x] `src/modules/inbound/qc.command.ts` -- refuse a catch-weight SKU by name, beside the existing serial-tracked refusal at `:188-190` -- the same reasoning; deferred rather than silently wrong
- [x] `src/modules/catalog/sku.command.ts` + `import.command.ts` -- persist `catch_weight_tracked`; refuse `catch_weight && serial_tracked` by name
- [x] `src/modules/outbound/pack.command.ts` + `outbound.dto.ts` -- **per-SKU** handling-unit ids; sorted before hashing; server-side assignment to lines from the `picks.orderLineId` split; the full refusal set; conditional `status = 'active'` write; ids into each line's existing `pack.packed` reference doc
- [x] `src/modules/inventory/ledger-registry.ts` -- add `handlingUnitIds?` to the `'pack'` arm only -- arms append; no event type is reshaped and no hashed field list changes
- [x] `src/modules/inbound/receiving.facade.ts` + `receiving.dto.ts` -- `catchWeightTracked` in the catalog snapshot, on the caller's transaction
- [x] `test/catch-weight.spec.ts` -- every I/O matrix row over real HTTP, including a **fractional-quantity** catch-weight SKU and the full over-receipt approve/reject cycle
- [x] `test/architecture.spec.ts` -- a `catalog` block asserting `handling_units` (and `serials`, `batches`, `skus`) are written only by `catalog` -- catalog has NO block today, so this closes a standing gap while the table is new and the guard is free

**Acceptance Criteria:**
- Given six cases received at six weights, when the GRN is submitted, then six `handling_units` rows exist with those exact gram values and the ledger records quantity `6`, not `110400`.
- Given a case **named** in a write-off adjustment, when it is scanned at pack, then the pack is **refused** — the fail-open case the review found.
- Given a catch-weight SKU, when a QC hold is attempted on it, then it is refused by name — not accepted with the unit left `active`.
- Given an order with two lines for one catch-weight SKU, when units are packed, then each unit lands on a determinate line by the `picks` split, and a replay of the same request reproduces the identical assignment.
- Given a batch-tracked catch-weight SKU, when a unit is received and later read, then its batch is recoverable **from its own row**, with no ledger traversal.
- Given `verifyChain` runs over a warehouse with catch-weight stock, when it recomputes, then it reports **no new severity-1 events** — this story adds no hashed field.
- Given reconciliation runs, when it folds the ledger, then it reports **no divergence** — weight is absent from the fold by design.
- Given `bun run db:migrate && bun run db:generate` on a fresh database, then **no new migration is emitted**.

## Implementation Notes

**Deviations taken during implementation, with reasons.**

- **The facade is a thin delegate over file-level in-tx functions** (`handling-unit.store.ts`), not the sole implementation. Putting the writes only on `CatalogFacade` forced `InventoryModule → CatalogModule`, a module-evaluation cycle (catalog → tenancy → putaway → inventory) that `forwardRef` cannot unwind; it broke 25 suites at import time. The repo's existing escape is the file-level in-tx helper (`ensureReceivingBinInTx`, `openQcHoldsForBinsInTx`). AD-6 still holds: every write executes inside `modules/catalog`, and `architecture.spec.ts` pins that.
- **The read-side status guard was removed** in pack and adjustment so the conditional `.where(status = 'active')` write is the sole authority; the 409 re-reads the still-locked rows to name each real status. With both present, the spec's own mutation check did not bite.
- **`MAX_HANDLING_UNIT_WEIGHT_GRAMS = 1_000_000`** (1,000 kg). The spec named the constant, not its value.
- **The fractional-quantity refusal moved to the SHELF, not the bench.** Review found a catch-weight order could be picked and then never packed. The guard now sits in `pick.command.ts`, where the operator can still act, rather than at pack with the hold already committed.

**A latent flake fixed in passing:** `blindReceipt` called `nowUtc()` per invocation, so the replay test hashed two different payloads across a second boundary. It now takes the instant as a parameter.


## Spec Change Log

**2026-09-19 — loop 1 design review, `bad_spec`.** The original decision 3 put a `handling_unit_ref` column on `ledger_events`, mirroring `serial_ref`, and wrote one `pack.packed` event per handling unit.

*What triggered the change:* triage findings 1-6. The analogy to `serials` was drawn from its **shape** while omitting the **mechanism** that gives the shape meaning — serials earn ledger-derived location by fanning out at putaway and pick, which this design did nowhere. That produced four separate defects: an unimplementable ref at an aggregate receipt event, a false "location is ledger-derived" claim, a `catch_weight × batch` combination advertised as supported but with no path to recover a unit's batch, and a pack that fails open on a written-off case.

*What the amendment avoids:* hashing a new `ledger_events` column would have changed the canonical bytes of **every pre-existing event**, reporting severity-1 across the whole chain on top of 0026's existing break — a second, avoidable corruption of the system's own correctness oracle.

**2026-09-19 — loop 2, `patch`.** Four findings against the revised model; the satellite-record decision itself held. The
frozen block gained an explicit consume-a-unit rule (name them or refuse them), catch-weight QC holds became a named
refusal, and pack's handling-unit ids moved from per-line to per-SKU to match the command's actual scan model. No
model change, so no renegotiation was required.

*KEEP on any re-derivation:* weight as **integer grams** and its justification (no reservation ⇒ the 2⁵³ ceiling does not bind); weight **excluded from `foldLedgerInTx`** with the stated reasoning that a catch weight is an attribute, not a conserved delta; capture-once-at-receipt; association at pack, not pick, to protect the scan budget; and the explicit, documented absence of mid-life location rather than an implied claim of it.

## Review Triage Log

**Loop 1 — design review, three layers over the SPEC (no code exists yet). Claim-verification: clean bar four citation
drifts, all fixed. Edge-case: 11 findings, 7 high. Self-review found one more the agents missed. Verdict: the design's
central analogy is wrong and the frozen block needs renegotiating — `bad_spec`, not `patch`.**

| # | Finding | Layer | Verdict | Evidence |
|---|---------|-------|---------|----------|
| 1 | **Adding `handling_unit_ref` to `ledger_events` breaks the hash chain a second time.** `canonicalEventBytes` (`ledger.service.ts:208-227`) has a fixed field list including `batchRef`/`serialRef`. Hash the new column and every pre-migration event's canonical bytes change, so `verifyChain` reports severity-1 on all of them — on top of 0026's existing break. Don't hash it and the field deciding what a customer is invoiced sits outside the tamper-evident chain | self | **high — bad_spec** | Found before the agents reported; neither raised it, because they checked claims I made and I made none about hashing. `referenceDoc` IS hashed (`:224`), and a new optional key does NOT change old events' bytes, since their stored jsonb simply lacks it — that is the hash-safe route |
| 2 | **Receipt is aggregate, so `handling_unit_ref` cannot be written there at all.** One `grn.received` per GRN LINE (`receiving.command.ts:513-538`), singular ref column. Six units off one line cannot each get a ledger row without fanning receipt out per unit — which the spec's own I/O matrix says it is not doing | edge | **high — bad_spec** | Verified. The Task bullet "permit `handling_unit_ref` on ... `grn.received`" is unimplementable as written |
| 3 | **"Location is always re-derived from the ledger" is FALSE for handling units.** Serials earn that property by fanning out at putaway (`putaway.command.ts:540-583`, one event per `serialRef`) and pick. `putaway.command.ts` appears nowhere in this spec. From receipt to pack no query can answer "where is unit X" | edge | **high — bad_spec** | Verified. The analogy to `serials` was drawn from its SHAPE while omitting the mechanism that gives the shape meaning. This is the root cause of findings 2, 5, 6 and 8 |
| 4 | **`catch_weight × batch` is marketed as supported but no path exists for a unit to carry its batch.** `serials` has no `batchId`, which is exactly why `batchTracked && serialTracked` is refused at `pick.command.ts:748` as unsolved. `handling_units` mirrors `serials`, receipt stays aggregate, and the pack arm keeps `allowsBatchArm: false` — so a unit's batch is unrecoverable at both ends | edge | **high — bad_spec** | Verified. Meat is lot-tracked, so this is the primary domain combination, not a corner. A recall could not trace it |
| 5 | **Pack fails OPEN: an adjusted-away unit is still packable.** `handling_units` has no status column by design, and adjustments never touch it, so a case written off as damaged passes unknown/duplicate/already-packed and ships | edge | **high — bad_spec** | Verified. `stock.adjusted` already fans per-unit for serials (`inventory.command.ts:491-546`); the spec touches no adjustment path |
| 6 | **Over-receipt splits quantity from unit count.** `submitGoodsReceipt` settles `applied = min(qty, remaining)` (`:415-419`) and holds `excess` for a later approval that appends a SECOND `grn.received` (`:677-800`). The shape check ties weights to full `qty`, so either unit count exceeds ledger quantity until approval, or the excess weights are dropped | edge | **high — bad_spec** | Verified. Neither branch is specified |
| 7 | **Nothing enforces "N live units ↔ quantity N" anywhere** — no CHECK, no job, no query. Combined with 5 and 6, the acceptance criterion holds only at the instant of a clean fully-applied receipt | edge | **medium-high — patch** | Correct. Distinct from the reconcile-weight question, which the Design Notes answer correctly |
| 8 | **Pack refusals incomplete**: a unit whose SKU is not on the line, a cross-warehouse unit (`handling_units` has no warehouse column), and any count mismatch between scanned ids and `packedQty` are all unstated | edge | **medium-high — patch** | Verified; `assertScanMatchesPicked` (`pack.command.ts:594-629`) is SKU-aggregated only |
| 9 | **Two order lines for one SKU leave the unit's `orderLineId` unspecified.** `order_lines` has no unique on `(order_id, sku_id)` | edge | **medium — patch** | Verified against schema |
| 10 | **`handlingUnitIds` hash normalisation unspecified, and the repo has two opposing precedents.** `pack.command.ts:198-207` sorts `scanned` before hashing; `pick.command.ts:349-365` deliberately does NOT sort `serials`. An identity list argues for unsorted; CLAUDE.md's "normalise collections before hashing" argues sorted | edge | **medium-high — patch** | Verified both sites. Exactly the defect class the repo rule exists to prevent; whichever is copied blindly, a benign re-scan either replays or throws a spurious 422 |
| 11 | Order-cancel-after-pack | edge | **false** | Correctly refuted by the reviewer itself: `cancelOrder` refuses any non-`accepted` order (`order.command.ts:530,552`) and pack flips to `ready_to_dispatch`. Recorded so it is not re-raised |
| 12 | `assertWeight` cited at `:644`, actually `:645`; serials comment `:371-376` actually `:366-375`; serial index `:554-556` actually `:554-558` | claims | **low — fixed** | All four citation drifts corrected in place |
| 14 | **The first revision had three modules writing `handling_units` directly — an AD-6 violation.** `serials` has exactly ONE writer, `catalog.facade.ts:381`; inventory, outbound, putaway, inbound and tenancy all read it and never write it | self | **high — fixed** | Found by self-review after the revision, before commit. Writes now route through new `catalog.facade` methods. `architecture.spec.ts` has no `catalog` block, so nothing would have caught this — the story now adds one |
| 13 | Spec claimed `serials` carries mutable status as precedent for a set-once column | self | **medium — corrected** | `serials.status` exists but grep finds NO update of it (`catalog.facade.ts:285,394` are reads). Serials rows are written once. So a set-once column has no precedent here and must be justified on merits, not by analogy |


**Loop 2 — second design pass, targeted at the REVISED model. The core held: the reference-doc hash claim, the RLS
shape and receipt idempotency were all independently verified sound. Four further findings, three sharing one root
cause. All patched; no third loop needed.**

| # | Finding | Layer | Verdict | Evidence |
|---|---------|-------|---------|----------|
| 15 | **The adjustment task was unimplementable.** `AdjustStockCommand` (`inventory.command.ts:52-96`) carries an aggregate `quantityDelta` plus `serialRefs` — its only per-unit channel — and catch-weight SKUs are barred from being serial-tracked. With no location on the unit either, nothing could select WHICH of N units a write-off touched, so the "written-off case is refused at pack" criterion was unsatisfiable | edge | **high — patch** | Verified. **Fixed:** `handlingUnitIds` added to the adjustment, mirroring `serialRefs`, count-checked against `|quantityDelta|`. `inventory.dto.ts:185` also named, which the first revision missed |
| 16 | **A direct self-contradiction inside the frozen block.** One Boundary required QC-held units to leave `active`; another said QC hold has no per-unit reference. `placeHold` (`qc.command.ts:141-260`) moves a whole `(sku,bin)` scope with no unit identifiers, so the first rule was unimplementable | edge | **high — patch** | Verified. **Fixed:** catch-weight QC holds are now **refused by name**, directly beside the existing serial-tracked refusal at `:188-190`, whose stated reasoning — location records stranded at the origin bin while stock relocates — transfers verbatim. Refused and deferred beats silently fail-open |
| 17 | **The facade covered two of four transitions, and one method named a status that does not exist.** `markHandlingUnitsReleased` targeted "released", absent from the four-value vocabulary, and the `pending_approval → active\|rejected` flip had no method at all | edge | **medium-high — patch** | Correct on both counts. **Fixed:** four methods now cover four transitions, and `settleHandlingUnitIntake` replaces the misnamed one |
| 18 | **"Ids supplied per ORDER LINE" fought the pack command's own architecture.** `pack.command.ts:344-346` states the bench counts SKUs and *cannot* tell which line of a two-line order a unit belongs to; `scanned` is per-SKU (`:82-93`, `:227`) and per-line `packedQty` derives from `picks` (`:427`), never from the scan | edge | **medium — patch** | Verified. **Fixed:** ids are per-SKU, and line assignment is derived server-side from the existing `picks.orderLineId` split with sorted ids consumed in order — deterministic and replayable, and it stops demanding a distinction the scan model was designed not to make |
| 19 | Over-receipt with `applied = 0` for a line | edge | **false (consistent)** | Reviewer's own verdict: no `grn.received` fires (`:513` guards `applied <= 0`), the `goods_receipt_lines` row is still written, and all units are `pending_approval`. Follows from the general over-receipt row; recorded so it is not re-raised |
| 20 | Reference-doc hash safety · RLS single-dimension on `tenant_id` · single replay point in `submitGoodsReceipt` | edge | **confirmed sound** | All three independently verified: `JSON.stringify` drops absent and `undefined` keys alike and `verifyChainInTx:1767` rebuilds the doc from the DB row, so historical bytes are untouched; no existing policy predicates on `warehouse_id` (`0010_sharp_hardball.sql:47-65`); the replay lookup at `:288-298` precedes every write |

**Root cause of 15, 16 and 18.** All three are the accepted "no mid-life location" limitation biting harder than the
first revision admitted. Without a location, an **aggregate-scoped** operation cannot know which units it touched. The
resolution is a rule rather than three patches: *a path that can consume a unit either names units explicitly, or it is
refused for catch-weight SKUs.* Adjustment names them; QC hold is refused. Putaway, pick and bin merge consume nothing,
so they stay aggregate and untouched.


**Loop 3 — CODE review, three layers over the 161.5 kB diff. 25 findings. No `intent_gap`, no `bad_spec`, so no
loopback: every entry is a local defect in the diff, not a hole in the intent. 8 high, 12 medium, 3 low, 2 rejected.
Two of the highs were independently found by two layers each, and one was found in a test I added myself.**

| # | Finding | Layer | Verdict | Evidence |
|---|---------|-------|---------|----------|
| 21 | **A fractional-UoM catch-weight order is picked, then can NEVER be packed.** Nothing refuses a fractional quantity at order entry, wave or pick — `pick.command.ts` and `order.command.ts` contain no `catchWeightTracked` reference at all. `packedUnitCount` throws 422 at the bench, with stock already committed and picks not undoable. Worse, `ids.slice(0, 1.5)` silently truncates, so a 1.5/1.5 two-line split stamps one case on one line and two on the other | blind + edge + v-gap | **high — patch** | Verified: grep for `catchWeightTracked` in both commands returns nothing. Found by all three layers independently. The spec already establishes "a case is a whole thing" at receipt; the code failed to apply it upstream of pack |
| 22 | **Neither pack nor adjustment checks a unit's batch.** `batch_id` is justified in three doc comments as what makes `catch_weight × batch` usable, and `pack.command.ts` contains no `batchId` reference. A FEFO pick allocating LOT-A can be packed with a LOT-B case, and the recall trace the column exists for points at the wrong lot | blind + edge | **high — patch** | Verified: zero `batchId` occurrences in `pack.command.ts` |
| 23 | **`catchWeightTracked` can be flipped on a SKU with live units.** `sku.command.ts:299-300` writes the flag unconditionally. Turning it off strands active units and ships them uncounted; turning it on wedges pack forever | edge | **high — patch** | Verified at the cited lines — no live-unit guard exists |
| 24 | **A fractional PO open quantity desynchronises unit count from quantity.** `Math.floor(entry.applied / QUANTITY_SCALE)` on an `applied` that can be fractional leaves half a case of live on-hand backed by no `active` unit — un-packable forever | blind + edge | **high — patch** | Both layers, same line. The comment acknowledges the rounding; the case is neither refused nor tested |
| 25 | **Pack's foreign-SKU 422 and not-catch-weight 400 arms never execute in any test — including the test I tightened.** The covering test scans `PLAIN-CASE` qty 1 against an order picked for `CW-CASE` qty 2, so `assertScanMatchesPicked` throws `pack-mismatch` 422 *before* `resolveHandlingUnits` runs. **My own loop-3 edit tightened the assertion to `toBe(422)` and wrote a comment claiming it pins the contract — it passes on the wrong arm.** Delete either guard and the suite stays green | v-gap + blind | **high — patch (MY ERROR)** | Pre-verified by the layer. I tightened a status assertion without checking *which* 422 it caught, then asserted in a comment that it pinned something it does not |
| 26 | **The "pre-10.3 fingerprints are byte-identical" claim has no test on any of the three commands.** Both replay tests submit both attempts on the *same* build, so they hash identically whatever the shape is. The repo's own precedent (`picking.spec.ts:1876-1899`) hand-seeds a legacy fingerprint | v-gap | **high — patch** | Pre-verified. Changing `?? undefined` to nothing at `receiving.command.ts:292` makes every queued pre-10.3 GRN answer 422 instead of replaying, invisibly. This is the device-outbox path |
| 27 | **A successful `PATCH catchWeightTracked` is never asserted to persist.** The one PATCH test targets a serial SKU and returns at the exclusivity refusal before the `updates` map is built. Delete `sku.command.ts:299-300` and the PATCH silently no-ops, green | v-gap | **high — patch** | Pre-verified. It is the ONLY path by which an existing SKU can become catch-weight |
| 28 | **Unbounded work per request.** Up to 250k ids can reach pack (500 lines × 500 ids) with no command-tier cap, each issuing its own `UPDATE`; `createHandlingUnitsInTx` builds one INSERT that passes Postgres's 65,535-parameter limit at ~7,280 units, giving an untyped 500; `StockAdjustmentDto` caps at a bare `1000` in the decorator only | blind + edge | **medium — patch** | Verified against `MAX_SCAN_LINES` and the insert shape. Sibling surfaces use named constants enforced in the command tier too |
| 29 | **`uom_conversions` is guarded against raw SQL but not against Drizzle.** `RAW_CATALOG_TABLES` lists it; `CATALOG_TABLES` does not, so `.insert(uomConversions)` outside catalog passes the new ownership guard | blind + edge | **medium — patch** | Verified at `architecture.spec.ts:381-382`. One-word fix |
| 30 | **`receiving.controller.ts:124` alone does not collapse `[]` to absent**, breaking a convention the diff states three times. An `[]` on a non-catch-weight line then trips the length check first and answers the *catch-weight* message instead of "is not catch-weight tracked" | blind | **medium — patch** | Verified: `?? null` at the cited line vs the sibling controllers' normalisation |
| 31 | **The adjustment fingerprint does not sort `handlingUnitIds`; pack does.** The same physical write-off retried with ids in another order fingerprints differently and answers 422 instead of replaying | edge | **medium — patch** | Verified inconsistency between `inventory.command.ts:208-209` and `pack.command.ts:239` |
| 32 | **`stock.adjusted` records no `handlingUnitIds`.** Pack's consumption is hash-chained; the write-off — the one path that destroys value — is not, and the asymmetry is stated nowhere | blind | **medium — patch** | Verified. Additive optional key on the existing arm; the same hash-safe pattern already used for pack |
| 33 | **`resolveHandlingUnits` uses an optional chain where a missing SKU should be an error**, silently skipping catch-weight accounting so units ship still `active` | edge | **medium — patch** | Verified at `pack.command.ts:383-388` |
| 34 | **The weight CHECK can drift upward from `MAX_HANDLING_UNIT_WEIGHT_GRAMS` invisibly.** Statuses are pinned by asserting `pg_get_constraintdef` contains each member; the weight bound is only probed behaviourally with `0/-1/MAX+1`, which still passes if the TS constant is raised | blind | **medium — patch** | Verified. I flagged this one-directional pin myself earlier and did not act on it |
| 35 | **`handlingUnitsOfGrnLinesInTx` + its facade face have no caller and no test.** Documented as "the unlocked read for surfaces"; no surface reads it, and the architecture test's seam loop omits it | blind + v-gap | **medium — patch** | Verified by grep. Exactly the `openCredentialForAdapterUse` shape already in `PENDING.md` — delete it or pin it |
| 36 | **`weight_grams` is documented immutable and nothing enforces it.** No trigger, no test; the range CHECK happily admits a *different* in-range weight, and the suite itself freely UPDATEs the column | blind | **medium — patch** | Verified. Smallest honest fix is a source-scan assertion that no path updates it |
| 37 | **The tamper-evidence rationale overstates what shipped.** Only the *ids* ride `pack.packed`'s reference doc; `grn.received` gains nothing, so an `UPDATE weight_grams` after receipt leaves `verifyChain` green. The migration header claims the design protects the invoice-deciding field | blind | **medium — patch (doc)** | Verified. A confidently-wrong load-bearing comment is the exact class this project keeps getting burned by; correct the wording |
| 38 | Naming slips: `lockHandlingUnitsInTx` is the only facade method keeping the `InTx` suffix; `packedIds` names the written-off set in `moveHandlingUnitsOutOfActive` | blind | **low — patch** | Verified. Direct renames, no complexity added |
| 39 | The test comment at `catch-weight.spec.ts:1181-1188` asserts it pins the different-SKU contract; it does not | v-gap | **low — patch** | Same root cause as 25; fixed with it |
| 40 | No read-back path exists for a weight — no GET route, and the GRN response returns ids only | blind | **medium — defer** | Real, but its consumers are 10-5 (web surfaces) and epic 8 (invoicing), neither of which exists. The spec's Never explicitly excludes surfaces. Deferred with the consumer named |
| 41 | The facade seam is bypassable — siblings import the store's in-tx functions directly rather than going through `CatalogFacade` | edge (claim) | **low — rejected** | True but harmless: the writes still execute inside `modules/catalog`, so AD-6 holds and the architecture guard is honest. This is the repo's documented escape for a module-evaluation cycle (`ensureReceivingBinInTx`). No facade-level invariant exists to bypass |
| 42 | Snapshot/OpenAPI could not be reviewed — excluded from the supplied diff | blind | **false (my staging call, separately verified)** | My exclusion, and a fair complaint. Both were verified by other means: `db:generate` reports "No schema changes", the OpenAPI drift check is clean, and the edge-case layer independently confirmed `0028_snapshot.json` is present and staged |

**Why no loopback.** The rule prefers `bad_spec` when in doubt, and I am not in doubt here. Every high finding is the code
failing to apply a principle the spec already states — "a case is a whole thing" was established at receipt and not carried
to pick; `batch_id` was specified and not checked; the fingerprint convention was specified and applied inconsistently.
None requires re-deriving intent, and reverting ~3,000 lines of independently-verified-green code to add guards would
destroy verified work to fix defects whose smallest fixes are local.


## Design Notes

**Why weight does not reconcile, stated as a decision rather than left as an omission.** `foldLedgerInTx` (`ledger.service.ts:1088`) selects `quantity_delta` and accumulates it into `(sku,bin)` and `(sku,bin,batch)` maps. Quantity reconciles because it is a **conserved delta** — movements net out, so replaying them reproduces a balance. A catch weight is not a delta; it is an immutable attribute of an identified thing. Summing weights across a bin produces a number, but no invariant says that number must equal anything, so a fold over it could not detect an error. Weight's correctness property is narrower: **the value captured at receipt must be byte-identical when read later**, which a test pins directly. Story 10-4 owns measured *quantity* reconciliation and is unaffected.

**The mistake the design review caught, recorded because it generalises.** The first draft modelled `handling_units` on `serials` and inherited its *shape* — identity-only, no location column, "location is derived from the ledger" — without the *mechanism* that makes the shape work. Serials are ledger-derivable because they fan out per unit at putaway (`putaway.command.ts:540-583`) and pick. Handling units, in a design that touched neither, had ledger presence at no point in their life, so the inherited claim was simply false, and three further defects followed from it. **Copying a pattern means copying what makes it true, not what it looks like.**

**Why a satellite record is the right shape here.** A handling unit needs to answer three questions — what does it weigh, what batch is it, is it still live — at points where no ledger event names it. Ledger-derivation cannot answer any of them without per-unit events at receipt, putaway, pick and adjustment, which is a second serial system and roughly four times this story. Holding the answers on the row is honest about what is actually tracked, and the cost is stated plainly: **no mid-life location.**

**Why the association column is written-later, which nothing else here does.** `serials.status` exists but is never updated (`catalog.facade.ts:285,394` are reads), so a set-once column has no precedent in this schema and cannot lean on one. It stands on merits: a case ships exactly once, so a link table adds a join for nothing, and the single `active → packed` transition is exactly the conditional terminal write the command skeleton already prescribes — `.where(eq(status, 'active')).returning()`, empty result → `409`.

**Why sorted before hashing, when the repo has two precedents.** `pack.command.ts:198-207` sorts `scanned`; `pick.command.ts:349-365` deliberately does not sort `serials`. The conflict is only apparent: pick's stated reason is that a retry of the same body must replay, and sorting preserves that, since it is deterministic. Sorting changes only whether a *differently ordered* body collides — and scanning cases A,B,C into a parcel is the same physical act as C,B,A. Two orderings must not create two packs. Sorted, matching the sibling list in the same command.

## Verification

**Commands:**
- `cd workspace/core/backend/wms-be && bun run test && bun run lint && bun run typecheck && bun run build` -- the full suite; the snapshot and SKU flags touch several modules.
- `bun run db:migrate && bun run db:verify` against a **freshly reset** database, then `bun run db:generate` -- expected: **no new migration emitted**.
- `git status --short` -- expected: **no untracked files**, specifically `drizzle/meta/0028_snapshot.json`.
- `grep -rn "toMilli\|assertRecordableQuantity" src/modules/catalog/handling-unit.ts src/modules/inbound/receiving.command.ts` -- expected: no hit on any catch-weight path.
- `git diff -- src/modules/inventory/ledger.service.ts` -- expected: **`canonicalEventBytes` untouched**. A changed hash field list is the one edit that silently breaks every historical event.

**Mutation checks** -- each must make the suite FAIL; a guard no test exercises is the defect class behind 10.2 finding 7:
- Replace `assertCatchWeightGrams` with a pass-through.
- Remove the `status = 'active'` predicate from pack's conditional write -- must fail, or the written-off-case fail-open is unguarded.
- Skip the `pending_approval → active` flip in `decideOverReceipt` -- must fail.
