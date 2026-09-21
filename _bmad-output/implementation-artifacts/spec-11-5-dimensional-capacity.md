---
title: 'Dimensional capacity (FR-39)'
type: 'feature'
created: '2026-09-21'
status: 'ready-for-dev'
baseline_commit: 'f67a206' # wms-be main HEAD when implementation began
route: 'dispatch'
review_loop_iteration: 0
context:
  - '_bmad-output/implementation-artifacts/epic-11-context.md'
  - 'docs/design/SYSTEM-DESIGN.md'
  - 'docs/design/IMPLEMENTATION-GUIDE.md'
  - 'docs/design/modules/putaway.md'
  - 'docs/design/modules/tenancy.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** A bin's only capacity is a bare whole-unit count that treats every base unit as equal space, and the SKU physical attributes story 11-2 landed (`weight_grams`, `length_mm`/`width_mm`/`height_mm`) have zero consumers. A bin full of small items and a bin holding one heavy crate look identical; an oversize SKU places into any bin with a spare unit.

**Approach:** Bins gain optional physical capacity — internal dimensions (mm) and a max weight (grams), all nullable = unconstrained = exactly today's behavior. The three existing capacity gates (putaway placement, `mergeBin`, the bin suggestion) extend to consume the new attributes alongside the unit gate, sharing one load-read. No new module ownership, no putaway-flow change.

## Boundaries & Constraints

**Always:**
- Gates stay at the existing three sites only — placement gate (`putaway.command.ts:496-505`), `mergeBin` overflow (`bin.command.ts:651-664`), suggestion fit (`binCandidatesInTx`/`suggestBinInTx` + the facade task-derivation fit). No fourth gate.
- Every new rejection follows `binFull`'s shape: 400, named problem code, message naming the bin and both numbers (existing and new load vs limit).
- All load arithmetic is integer-exact, milli-scaled, no rounding (see Design Notes).
- A bin is full when ANY declared gate trips. The unit gate (`capacity`, unchanged) stays; SKUs without attributes contribute only units.

**Never:**
- No capacity gating at receiving/QC-hold/adjust intake — intake is ungated today and stays so; the gates fire on placement and merge only.
- No removal or reinterpretation of `bins.capacity` (Epic 12's storage-class work revisits the unit count; this story composes with it, it does not replace it).
- No catch-weight/handling-unit weights in the arithmetic — static SKU attributes only (epic decision).
- No putaway flow change: same candidate ordering (lowest occupancy, then code) among bins that FIT; no zone affinity, no velocity class.
- No FE/mobile surface work (11-6/11-7 consume); the device snapshot shape is unchanged.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Place within all gates | Bin unconstrained (attrs null), any SKU | 200, unchanged behavior | N/A |
| Unit gate trips | occupancy + qty > capacity | 400 `bin-full` (existing, unchanged) | N/A |
| Weight gate trips | Bin has `max_weight_grams`; Σ(qty×weight) + incoming > limit | 400 `bin-overweight` naming bin, limit, load | N/A |
| Volume gate trips | Bin has all three dims; Σ(qty×dims) + incoming > limit | 400 `bin-volume-exceeded` naming bin, limit, load | N/A |
| Dim fit trips | SKU dim > same bin dim (both sides present, per-dimension) | 400 `bin-item-oversize` naming bin and dimension | N/A |
| SKU without attrs | SKU attrs null | Contributes units only; volume/weight/dim gates skip it | N/A |
| Bin without attrs | Bin attrs null | Unit gate only (today's behavior) | N/A |
| Suggestion | Candidate fails any new gate | Skipped; next-lowest-occupancy fitting bin; none fit → suggestion null, task rationale unchanged wording | N/A |
| Merge | Target's weight/volume/dim fit exceeded by moved load | Same three new arms, naming the target bin | N/A |
| Create/grid/PATCH | Dim/weight fractional, zero, negative, or over cap | 400 `validation-failed` | N/A |

</frozen-after-approval>

## Code Map

- `workspace/core/backend/wms-be/drizzle/0034_bin_dimensional_capacity.sql` -- NEW migration: additive nullable columns + CHECKs on `bins` (hand-appended CHECK pattern, 0028/0031)
- `workspace/core/backend/wms-be/src/shared/db/schema.ts:216-243` -- `bins` gains `lengthMm/widthMm/heightMm/maxWeightGrams` (int, nullable)
- `workspace/core/backend/wms-be/src/modules/tenancy/tenancy.dto.ts:341-423,464-510` -- `CreateBinDto`/`GenerateBinsDto`/PATCH body gain optional attrs; `BinResponse` echoes them (raw integers, no fromMilli)
- `workspace/core/backend/wms-be/src/modules/tenancy/bin.command.ts:974-990` -- `assertWholeUnitCapacity`'s sibling `assertBinCapacityAttributes`; create/grid pass attrs through; `mergeBin:651-664` gate extension
- `workspace/core/backend/wms-be/src/modules/putaway/putaway.command.ts:809-827` -- `binOccupancyInTx` extended to a load-read (units + weight + volume, one grouped query joining `skus`); new rejection helpers beside `binFull:916`
- `workspace/core/backend/wms-be/src/modules/putaway/putaway.command.ts:727-806` -- `suggestBinInTx`/`binCandidatesInTx` + shared fit predicate
- `workspace/core/backend/wms-be/src/modules/putaway/putaway.facade.ts:313-346` -- task-derivation fit uses the same predicate (sku rows must carry weight/dims)
- `workspace/core/backend/wms-be/src/modules/putaway/bin-state.command.ts` -- the PATCH route's state command: unchanged; capacity attributes dispatch to a new tenancy command (see Design Notes)
- `workspace/core/backend/wms-be/src/modules/catalog/sku-attributes.ts:23-25` -- SKU-side caps (read-only reference; no catalog code changes)
- `workspace/core/backend/wms-be/test/putaway.spec.ts`, `test/bin-admin.spec.ts`, `test/api.spec.ts` -- gate arms, validation, contract drift
- `docs/design/API-SURFACE.md`, `docs/design/modules/putaway.md`, `docs/design/modules/tenancy.md`, `docs/repos/wms-be/README.md` -- meta docs (final task)

## Tasks & Acceptance

**Execution:**
- [x] `drizzle/0034_bin_dimensional_capacity.sql` -- add the four nullable columns with CHECKs (dims 1..100000 mm; weight 1..100000000 g) -- bins are bigger than SKUs; a floor location is an area
- [x] `src/shared/db/schema.ts` -- mirror the columns on `bins` -- single source the store reads
- [x] `tenancy.dto.ts` + `bin.command.ts` -- DTO fields + `assertBinCapacityAttributes` (positive whole integers within caps; null/absent = leave unchanged/clear per verb); create/grid/PATCH pass-through -- one validation door, `assertWholeUnitCapacity`'s sibling
- [x] `bin.command.ts` (PATCH arm) -- new `editBinCapacity` command following the command skeleton (hash, replay, `bin.create` capability, zone/bin locks) -- dimensions survive a warehouse retrofit
- [x] `putaway.command.ts` -- load-read + three new rejection helpers + gate extension at placement (after the unit gate, inside the existing `.for('update')` window) -- the gates share one read
- [x] `putaway.command.ts` + `putaway.facade.ts` -- candidate query gains weight/volume loads; shared `candidateFitsSku` predicate used by suggestion, placement re-derivation, and task derivation -- suggestion never points at a bin the gate refuses
- [x] `bin.command.ts` `mergeBin` -- target load gates + per-moved-SKU dim fit -- a merge cannot overflow what a placement cannot
- [x] tests -- matrix arms in `test/putaway.spec.ts` + `test/bin-admin.spec.ts`, contract drift in `test/api.spec.ts` -- the gates are the story
- [x] `docs/...` meta docs + openapi re-export -- contract currency

**Acceptance Criteria:**
- Given a bin with `max_weight_grams` set and stock whose scaled load exceeds it, when a placement targets it, then 400 `bin-overweight` and the bin state is unchanged.
- Given a SKU with dims and a bin whose volumetric limit is exceeded, when suggested or placed, then the bin is skipped/refused with `bin-volume-exceeded`, and a same-size SKU without attributes still places under the unit gate alone.
- Given an existing bin (no attrs) with existing stock, when any placement/merge/suggestion runs, then behavior is byte-identical to today (gates inert).

## Implementation Notes

*(append-only implementation log — nothing below modifies the frozen block)*

- **Outbox/audit decision.** `editBinCapacity` emits outbox `bin.capacity_changed` (`{binId, warehouseId, lengthMm, widthMm, heightMm, maxWeightGrams}` — the post-write values, possibly null) plus an audit row `action: 'bin.capacity_changed'`, same shape as `bin.blocked`. The spec's Design Notes were silent on the event; `setBlocked` was the template. `createBin` still emits nothing (its 1.3 rule stands).
- **`binItemOversize`'s detail names the SKU code** in addition to the bin, dimension and both numbers: a merge moves many SKUs, so the offending SKU is part of the rejection's identity, not decoration.
- **`fromMilliText` (BigInt-safe milli→text formatter)** was added next to the rejection helpers because `fromMilli` throws past 2^53 and the weight/volume loads are numeric-string sums read as BigInt — the operator-facing "carries X g of its Y g max weight" numbers must not go through `fromMilli`.
- **Load arithmetic.** `binOccupancyInTx` returns `BinLoad { units, weightLoad, volumeLoad }` from one grouped query (`stock_on_hand ⋈ skus`): units as `coalesce(sum(quantity),0)::bigint`, the loads as `coalesce(sum(quantity::numeric * coalesce(attr,0)),0)::numeric`. The `::numeric` sums read back as **strings**; every gate comparison is BigInt against `limit × QUANTITY_SCALE`. Never `::bigint` — a huge-qty × max-attr product would overflow int8.
- **Idempotency payload hash.** `createBin`, `generateGrid` and `editBinCapacity` fold the four attribute keys into `hashCommandPayload`. Because `JSON.stringify` drops `undefined` keys, a pre-11.5 fingerprint (which never carried the keys) is byte-identical to a payload that sends them as `undefined` — older keys replay unchanged. `assertBinCapacityAttributes` sits **behind** the replay lookup (the `CreateBinDto.capacity` no-refusal-before-replay rule).
- **Merge arm attribution.** `MergeArm` gained `skuCode` + the four SKU attrs so `mergeBin` can (a) compute `movedWeight`/`movedVolume` as BigInt reduce-sums over the arms and (b) run the per-moved-SKU dim-fit loop over `new Map(arms.map(a => [a.skuId, a])).values()` — dedup by skuId because batch arms split one SKU across rows.
- **Test design (putaway).** New zone D with bins coded `0-D`/`0-V`/`0-W`/`0-F` so they sort before every `A-*` bin: with all four empty, the `0-*` group ranks first in the suggestion, so `0-D` being skipped by dim fit makes the skip observable regardless of the older bins' occupancies. `0-W` is filled to exactly its 5000 g limit first so the second placement trips `bin-overweight` with both numbers ('10000'/'5000'); `0-V` likewise to 1 000 000 000 mm³ before the volume arm. PUT-D (the gated SKU) is created by catalog import then PATCHed with its attributes; PUT-B stays attribute-less to pin fail-open.
- **Test design (bin-admin).** Merge targets A-20..A-26 are pre-loaded to exactly their limits so each rejection arm fires on the first moved unit; the fitting merge into A-26 asserts the raw-attrs echo. The 0034 round-trip asserts the four columns in `information_schema`, the four CHECK names in `pg_constraint`, and that raw inserts of `length_mm = 0` and `max_weight_grams = 100000001` reject naming the CHECK — CHECKs exist only in migration SQL, never `schema.ts`.
- **`editBinCapacity` allows system bins.** They are tenancy-owned structure; only putaway's `blocked` toggle refuses them. Retired bins 409 (`binRetired409`) — a retired bin's capacity is dead history.
- **DTO/controller shape.** `PatchBinDto.blocked` went optional, so the controller's setBlocked call needs `dto.blocked!` — sound because the both/neither arms return earlier (lint's no-non-null-assertion sensitivity stayed clean).
- **Verification.** `bun run test` 691/691 (38 suites), `bun run lint` / `bun run typecheck` / `bun run build` clean, `bun run db:generate` reports "No schema changes" (the hand-named SQL matches drizzle's output exactly; journal tag sed-fixed to the filename), snapshot chain `0034_snapshot.prevId` matches the 0033 snapshot id. Contract drift: `bun run openapi:export` re-exported; the FE drift guard stays red until the BE PR merges (expected on cross-repo stories).

## Spec Change Log

## Review Triage Log

## Design Notes

**The arithmetic (all-integer, no rounding).** 1 mm³ = 1 milli-ml, so a SKU's per-unit volume in scaled units is `length_mm × width_mm × height_mm`. Weight is grams as-is. Define the load as `Σ(quantity_milli × per-unit-attribute)` over the bin's `stock_on_hand` rows joined to `skus`, computed in SQL as `sum(quantity * coalesce(attr, 0))::numeric`, read as string, compared as BigInt against `limit × QUANTITY_SCALE`:

```sql
-- volume: Σ(qty_milli × l × w × h) ≤ (L × W × H) × 1000   [bin dims]
-- weight: Σ(qty_milli × weight_grams) ≤ max_weight_grams × 1000
```

Exact for fractional quantities, and `::numeric` sums cannot overflow. The `::bigint` cast the occupancy reads use today would overflow on adversarial (huge-qty × max-dim) products — the new reads must NOT cast to bigint.

**Ownership.** Bin master data (structure) is tenancy's; `blocked` is putaway's (re-homed precedent). The four attributes are structure → tenancy owns their writes. The existing PATCH `bins/:binId` route carries putaway's `{blocked}` state command; capacity attributes on the same body dispatch to a new tenancy `editBinCapacity` command (same route, per-body dispatch — the re-homing precedent in reverse). Gated by `bin.create` (the bin master-data capability) — no new capability, so no FE capability-mirror change and wms-fe is untouched.

**Coexistence (deliberate).** A dimmed SKU counts toward the unit gate AND the volumetric/weight gates — conservative double-count, chosen so existing warehouses behave byte-identically and the model is explainable ("full when any declared limit trips"). Epic 12's storage-class work decides the unit gate's fate; this story must not prejudge it.

**Fail-open on missing attributes.** A SKU without dims contributes nothing volumetrically; a bin without limits is unconstrained. Fail-closed would 400 every placement in every existing warehouse. Oversize therefore only binds once both sides are dimensioned — acceptable for v1, and the reason the `bin-item-oversize` arm checks per-dimension (both-sides-present) rather than requiring all six values.

**Occupancy source.** `stock_on_hand` is the authoritative bin quantity — `batch_on_hand` is a per-batch breakdown folded beside the plain fold with the SAME magnitude (ledger.service.ts:546-548), not a second pool. The new load reads join `stock_on_hand` only, exactly like `binOccupancyInTx`. No batch arm in the load.

**Extension shape (Epic 19/20).** FR-71's measured-stock capacity (tanks/silos, capacity in the stock's own UoM) lands later as additional limit columns + gate arms on this same location model; nothing here should foreclose it — the limits are per-bin declarative columns and the gates are arms of one check.

## Verification

**Commands:**
- `bun run test` (wms-be) -- expected: full suite green including new gate/validation arms
- `bun run lint && bun run typecheck` -- expected: clean
- `bun run openapi:export` -- expected: the re-exported spec carries the new DTO fields; the FE drift guard stays red until the BE PR merges (expected on cross-repo stories)
- Migration: `bun run db:migrate` against the ephemeral test Postgres (the test bootstrap applies migrations) -- expected: 0034 applies clean; existing `bins` rows unchanged