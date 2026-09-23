---
story: 12-2-hazard-segregation-matrix
title: "12-2 hazard segregation matrix — FR-41 on the backend"
type: 'feature'
created: '2026-09-23'
status: 'in-progress'
baseline_commit: '4bd00f5'
route: 'dispatch'
review_loop_iteration: 0
epic: 12
context:
  - '_bmad-output/implementation-artifacts/epic-12-context.md'
  - 'docs/design/SYSTEM-DESIGN.md'
  - 'docs/design/IMPLEMENTATION-GUIDE.md'
  - 'docs/design/modules/putaway.md'
  - 'docs/design/modules/catalog.md'
  - 'docs/design/modules/tenancy.md'
  - 'docs/design/API-SURFACE.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** FR-41 — incompatible goods cannot be co-located: a segregation matrix over hazard classes refuses the placement naming both parties. 12-1's storage class is a (SKU, bin) rule; it says nothing about two hazardous SKUs sharing one bin (an oxidiser beside a fuel). Today nothing stops it.

**Approach:** SKUs gain a nullable `hazard_class` from a controlled vocabulary (CHECK-backed, the 12-1 three-layer pattern), and one symmetric pairwise predicate in a shared primitive — `hazardClassesCompatible(a, b)` — is imported by the same gated-writer set 12-1 established: the putaway suggestion walk, the placement guard, and `mergeBin`, plus a SKU hazard-edit guard mirroring 12-1's `storage-class-conflict`. The matrix is encoded ONCE in TS; the co-location rule reads the target bin's current occupants.

## Boundaries & Constraints

**Always:**
- The matching rule (the default matrix) lives once in `src/shared/primitives/hazard.ts` — no SQL-side copy, exactly the 12-1 hierarchy precedent. The candidate list stays SKU-agnostic.
- Segregation is a **co-location** rule (SKU × SKU-in-bin), unlike storage class's (SKU × bin) rule: the gate reads the *occupants'* hazard classes, so a hazard-capable SKU may still enter an empty bin of the right storage class.
- Conformance stays a command-layer rule (AD-18); every refusal names both parties and both classes.
- The SYNC HAZARD rule extends: the hazard arm must land in `candidateFitsSku` + the placement guard + `mergeBin` in one commit.

**Never:**
- No new ledger event type (a segregation refusal is a guard, not a movement).
- Bins do NOT gain a hazard column in this story — the co-location rule is occupant-based; bin-side hazard designation is 12-3/12-4 material (recorded narrowing).
- No pick-draw or wave/pool-filter change (drawing FROM a bin co-locates nothing).
- `stock.adjust` stays a named bypass (the 12-1 precedent — extend its PENDING entry).
- No mobile snapshot, no FE file, no `bins.type` writer, no QC-release logic change.
- **The decided vocabulary and default matrix** (human decision 2026-09-23): `explosive, oxidizer, flammable, corrosive-acid, corrosive-base, toxic, gas` — 7 classes. Matrix: `explosive` segregates from ALL; `oxidizer`↔`flammable` (FR-41's oxidiser/fuel example), `oxidizer`↔`gas`, `corrosive-acid`↔`corrosive-base`, `corrosive-acid`↔`toxic`. Covers the stated industries (chemicals → acids/bases/toxic, LPG → gas, ammonium nitrate → oxidizer, ammunition → explosive); 12-7's admin surface can widen it. The full spec is kept despite ~3,500 tokens (single goal; the size is design detail) — human decision 2026-09-23.
</frozen-after-approval>

## Code Map

- `src/shared/db/schema.ts` — add `skus.hazardClass` (nullable text, no default) beside `skus.storageClass` (:413); doc comment naming the shared primitive and the CHECK's migration-only home. **Bins gain nothing.**
- `drizzle/0036_*.sql` — **run `bun run db:generate` first** (ADD COLUMN + snapshot + journal row), **then hand-append `skus_hazard_class_check`** (`col IN (...) OR col IS NULL` — nullable, so the null arm is required; the 0035 convention). Forward-only.
- `src/shared/primitives/hazard.ts` (new) — `HAZARD_CLASSES` (the decided 7-class vocabulary), `hazardClassesCompatible(a, b)` (symmetric pair set + the explosive universal rule), `assertHazardClass(fields)` (the `assertStorageClass` shape — skips undefined/null so PATCH's null-clears verb survives), refusal factories: `segregationConflict(detail)` 400 `bin-segregation-conflict` (placement/merge) and `segregationStateConflict(detail)` 409 `hazard-segregation-conflict` (SKU edit guard) — the 12-1 split (device-facing refusal vs state conflict), deliberate.
- `src/modules/putaway/putaway.command.ts` — `SkuPhysicalAttributes` (:853-863) gains `hazardClass: string | null`; `PutawayBinCandidate` (:834) gains `hazardClasses: readonly string[]`; `binCandidatesInTx` (:924, the grouped query) aggregates the occupants' classes (`array_agg(distinct skus.hazard_class) filter non-null` through the existing stock_on_hand→skus join — one query still); `candidateFitsSku` (:929-960) gains the hazard arm AFTER the class gate (SKU side: for each occupant class, incompatible → no fit). Placement: the SKU read (~:470) gains `hazardClass`; the re-derivation attr object (:588-594) feeds it; after the locked-row class gate (:539-547), before the load read, a new exported `occupantHazardClassesInTx(tx, tenantId, binId)` (distinct hazard classes of OTHER skus with `quantity > 0` in the bin — the same join shape as `binOccupancyInTx` :1065-1101) → any incompatible pair → 400 naming both SKU codes and classes. The task derivation's facade projection (`putaway.facade.ts:281-296`) gains `hazardClass` (it feeds `candidateFitsSku` at :343).
- `src/modules/tenancy/bin.command.ts` — `mergeBin`: `onHandRows` projection (:680-692) gains `hazardClass`; after the class gate (:711-723) the hazard gate reads the TARGET bin's occupants via `occupantHazardClassesInTx` and checks each moved SKU's class (moved-vs-moved is NOT re-checked — the source bin already co-locates them; recorded). Tenancy imports the putaway helper (the `binBlocked` precedent).
- `src/modules/catalog/sku.command.ts` — `EditSkuCommand` (:85-133) gains optional-PATCH-semantics `hazardClass` (undefined = unchanged; **null = clear** — the 11.2 attribute template, and unlike `storageClass` the column is nullable so the explicit-null 400 guard is NOT added); it joins the empty-patch refusal list (:180-196). The write arm (:688) carries it. **Hazard-edit guard** (in the edit tx, behind the replay, only on a CHANGE): for every non-system bin where the SKU holds stock (tenant-wide `stock_on_hand` join, the 12-1 SKU-guard shape), read the bin's OTHER occupants' hazard classes + the open QC holds on THIS SKU (origin-bin attribution — a later release would return these units to the origin bin); any bin where the new class conflicts with an occupant → 409 `hazard-segregation-conflict` naming warehouse, bin code and the conflicting SKU. Held units already sit in the system QC bin — excluded like every staging location.
- `src/modules/catalog/catalog.dto.ts` — `PatchSkuDto` (:241) gains optional `hazardClass` (`@IsIn` via the shared validator's vocabulary; nullable — no explicit-null 400 at the controller, the 11.2 template governs).
- `src/modules/catalog/import.command.ts` — `OPTIONAL_COLUMNS` (:142 area) gains `hazard_class`; the attribute block (:1215-1243) parses it — **blank cell → null** (the column is nullable; the 12-1 blank→ambient choice was NOT NULL-specific); per-row `assertHazardClass` beside the 12-1 site; the row error maps `hazardClass` → `hazard_class` (the 12-1 replace pattern).
- `src/modules/catalog/sku.command.ts` (snapshot/replay) — `SkuSnapshot` (:46-93) gains `hazardClass?: string | null`; the first-run snapshot and the replay serve point (:318-335) carry it (`hazardClass: stored.hazardClass ?? null` — a pre-12.2 legacy snapshot normalizes absence to null; the byte-identical legacy-digest property holds because absent optional keys drop out of the hash). Controller response mapping spreads it.
- Tests: `test/putaway.spec.ts` (placement refusal naming both SKUs, suggestion filter via `createClassBin`, task-derivation filter) · `test/bin-admin.spec.ts` (merge hazard gate, both directions: moved vs occupants) · `test/sku-attributes.spec.ts` (SKU edit guard incl. the hold arm + the null-clears verb + a class-carrying replay, import blank→null + vocabulary row error) · CHECK probe for `skus_hazard_class_check` (the 0034/0035 23514 pattern). Bootstrap: `useSuiteDatabase` + `createApp(false)`.
- Do NOT touch: the ledger registry, `qc.command.ts` release logic (pinned indirectly by the edit guard), `receiving.facade.ts` snapshot (12-8's), any FE file, `stock.adjust`.

## Tasks & Acceptance

**Execution:**
- [ ] Migration `0036` — `bun run db:generate`, then hand-append the CHECK; journal row comes from generate.
- [ ] `src/shared/primitives/hazard.ts` — vocabulary, `hazardClassesCompatible`, `assertHazardClass`, the two refusal factories.
- [ ] `schema.ts` — `skus.hazardClass` with doc comment.
- [ ] Putaway — candidate shape (+ `hazardClasses` aggregate), `candidateFitsSku` hazard arm, placement co-location query + refusal, facade projection.
- [ ] Tenancy — merge hazard gate (projection + target-occupant read).
- [ ] Catalog — SKU edit field (DTO + empty-patch list + write arm) + 409 guard with the hold arm, import column, snapshot/replay normalization.
- [ ] Tests per suite above; `bun run openapi:export` (additive-only — FE regen is NOT this story).
- [ ] `docs/design/PENDING.md` — extend the adjustment-bypass entry to name the hazard gate.

**Acceptance Criteria:**
- Given a bin holding an oxidiser-class SKU, when a flammable SKU is placed into it, then the placement 400s `bin-segregation-conflict` naming both SKUs and classes, and nothing is written; when the suggestion runs for the flammable SKU, that bin is never suggested.
- Given the same bin, when a non-hazardous SKU is placed into it, the placement succeeds — a null class carries no segregation rule (deliberate narrowing, recorded).
- Given a merge whose source holds a hazard class incompatible with a target-bin occupant, when `mergeBin` runs, it refuses whole naming both parties, before any arm moves.
- Given a SKU edited to a hazard class incompatible with its current binmates, the edit 409s `hazard-segregation-conflict` naming the bin and the party; the same edit clearing the class (null) always succeeds.
- Given an open QC hold on the edited SKU whose origin bin holds an incompatible occupant, the edit 409s on the hold arm — a later release can never return stock to a conflicting bin.
- No existing sequential behavior changes — the full suite stays green.

</frozen-after-approval>

## Implementation Notes

## Spec Change Log

## Review Triage Log

## Design Notes

- **Two rules, one shape.** 12-1's rule is (SKU, bin): static, encoded in a rank table. 12-2's rule is (SKU, SKU-in-bin): dynamic, encoded as a symmetric pair set. Both live in TS primitives, both are imported by the same gated-writer set, both refusal families split 400-device-facing from 409-state-conflict. A placement now runs: structural arms → storage-class gate → **hazard co-location gate** → capacity gates.
- **The co-location read is one grouped query** (`occupantHazardClassesInTx`): `select distinct skus.hazard_class from stock_on_hand join skus where bin_id = ? and quantity > 0 and hazard_class is not null and sku_id <> incoming` — inside the bin-row `.for('update')` window, so a concurrent placement cannot slip an incompatible unit between the scan and the write (the 12-1 edit-guard serialization argument).
- **`binCandidatesInTx` gains one aggregate, not a query.** The candidate list stays one grouped query (the SKU-agnostic rule); `array_agg(distinct hazard_class)` rides the existing stock_on_hand→skus join. Bins with no hazardous occupants carry an empty array — the walk's common case pays one aggregate, not a N+1.
- **Default matrix is safe by construction:** no pre-existing state can become conflicting because no hazard class existed before; every existing SKU reads null — rule-free. No backfill.
- **Null carries no rule, in both directions:** a non-hazardous SKU may share a bin with hazardous stock (the matrix rules pairs of classes), and hazardous stock never refuses a placement by its own presence alone. This is the recorded FR-41 narrowing — FR-41 refuses *incompatible pairs*, not hazard-presence.
- **Residual races, recorded in PENDING by this story:** (a) `stock.adjust` bypasses the co-location gate (the 12-1 class-gap precedent, same entry); (b) the placement reads the incoming SKU's hazard class unlocked (the 12-1 unlocked-SKU-read currency covers the same window).
- **Legacy digests:** `EditSkuCommand.hazardClass` absent drops out of the payload hash (`JSON.stringify` drops undefined), so a pre-12.2 key replays byte-identically; a stored legacy snapshot serves `hazardClass: null` on replay (the `storageClass ?? 'ambient'` pattern's nullable twin).

## Verification

**Commands:**
- `cd workspace/core/backend/wms-be && bun run lint && bun run typecheck` — exit 0.
- `bunx jest test/putaway.spec.ts test/bin-admin.spec.ts test/sku-attributes.spec.ts` — all green.
- `bun run test` — full suite green, fresh-isolated (one run at a time: two concurrent jest processes race on the template DB); **this is also the migration proof** (global-setup applies `0036` to `wms_template`).
- Migration CHECK proof against `wms_template`: `skus.hazard_class` nullable + `skus_hazard_class_check` present in `information_schema.table_constraints`; a live insert of `hazard_class = 'biohazard'` expects 23514; a live insert of `null` succeeds (nullable arm).
- `bun run openapi:export && git diff --stat openapi/openapi.json` — additive-only (new nullable `hazardClass` on `SkuResponse`/`PatchSkuDto`).