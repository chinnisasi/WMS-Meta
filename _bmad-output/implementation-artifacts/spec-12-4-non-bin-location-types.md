---
title: 'Story 12-4 — Non-bin location types (yard, floor-stack, tank, silo)'
type: 'feature'
created: '2026-09-24'
status: 'done'
route: 'dispatch'
baseline_commit: 'wms-be@b7e47727 / wms-fe@3712047c / meta@e30963f'
review_loop_iteration: 2
context:
  - '{project-root}/_bmad-output/implementation-artifacts/epic-12-context.md'
  - '{project-root}/docs/design/SYSTEM-DESIGN.md'
  - '{project-root}/docs/design/IMPLEMENTATION-GUIDE.md'
  - '{project-root}/docs/design/modules/tenancy.md'
  - '{project-root}/docs/design/modules/putaway.md'
  - '{project-root}/docs/design/API-SURFACE.md'
  - '{project-root}/docs/design/frontend/IMPLEMENTATION-GUIDE.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** The location model (`bins` table) admits only four loosely-validated types (shelf/pallet/floor/staging, DTO-`@IsIn` with no DB backstop), so yards, floor-stack areas, tanks and silos cannot be modeled — bulk storage assets would have to be faked as ordinary shelf bins with no type-driven placement rules.

**Approach:** Treat `bins` as THE location model — extend it, never fork it. Replace the loose `BIN_TYPES` vocabulary with a real `LocationType` vocabulary (adding `floor-stack`, `yard`, `tank`, `silo`), add the DB CHECK backstop (AD-18 three-layer), and give the bulk asset types (`tank`, `silo`) their own placement rules — single-SKU occupancy, weight-defined capacity required, never auto-suggested — applied inside the existing gate list so placement, merge, suggestion and pick all see ONE predicate.

## Boundaries & Constraints

**Always:**
- One table, no fork: non-bin locations are `bins` rows with new types; `stock_on_hand`, `batch_on_hand`, `bin_state_epochs` and `ledger_events.from_bin_id/to_bin_id` key on them unchanged (this is the Epic-20 substrate).
- Three layers in lockstep: DB CHECK + vocabulary constant + DTO `@IsIn` (the 12-1 storage-class pattern).
- The fit-predicate arm list stays IDENTICAL at all three sites — placement guards, `candidateFitsSku`, `mergeBin` target gates (the marked SYNC HAZARD).
- The four original types keep their exact meaning; all pre-existing bins conform with zero data mutation.
- Pick draws stay structurally untouched: a draw from a yard/tank/floor-stack location runs the same gates (system/retired/blocked → class → secure → serial/FEFO) and no capacity check.

**Never:**
- No transfer/replenishment movement, no level or measured reconciliation (Epic 20), no `locations` table or `locationId` column, no new capacity columns (reuse 11-5's nullable mm/g fields).
- No mobile changes BEYOND the reason-enum mirror fix renegotiated by the human (2026-09-25): the `bulk-asset` code + label added to wms-mobile's two mirror enums (`src/api.ts`, `src/putaway/draft.ts`) and one parity assertion in its draft test — nothing else in mobile.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Different SKU into bulk asset | `putaway.place` targets a tank/silo whose occupants include another SKU | 400 `bin-occupancy-conflict` (detail names the holding SKU) | refused before capacity arms |
| Same SKU into bulk asset | tank holding SKU A, place SKU A again | success — existing gates still run | N/A |
| Bulk assets never suggested | suggestion re-derivation runs | `binCandidatesInTx` excludes tank/silo rows | N/A |
| Operator-directed bulk placement | suggestion picked another bin, operator targets a tank | requires reason code `bulk-asset` (new, in `PUTAWAY_MISMATCH_REASON_CODES`) | 400 outside the enum |
| Weight-defined bulk creation | create/edit tank or silo without `maxWeightGrams` | 400 | validation-failed arm |
| Grid mass-create | grid request naming tank or silo | 400 — bulk assets are unique, never gridded | validation-failed arm |
| Merge into bulk asset | `mergeBin` target is a tank holding a different SKU | 400 `bin-occupancy-conflict` | same arm as placement |
| Draw from non-shelf location | pick line whose stock sits in yard/tank/floor-stack | normal FEFO draw | N/A |
| DB backstop | write bypassing DTO with unknown type | CHECK `bins_type_check` rejects | migration-level |

</frozen-after-approval>

## Code Map

**wms-be:**
- `src/shared/primitives/location-type.ts` (NEW) -- `LOCATION_TYPES` (8 values, old 4 first), `LocationType`, `BULK_ASSET_TYPES = ['tank','silo']`; mirror the storage-class.ts header style.
- `src/modules/tenancy/tenancy.dto.ts:335` -- the `BIN_TYPES` const (also used :452, :566, :748): swap to the shared vocabulary (re-exported alias keeps churn low).
- `src/shared/db/schema.ts:256` -- comment says 12-4 "replaces" free-text `type`: update to the vocabulary treatment.
- `drizzle/0037_location_type_check.sql` (NEW) -- additive CHECK `bins_type_check`, 0035 pattern (CHECKs live only in migration SQL).
- `src/modules/tenancy/bin.command.ts` -- `createBin`/`generateGrid`/`editBinCapacity`: bulk-asset validations (require `maxWeightGrams`, grid refusal, no clearing it on a bulk asset); `mergeBin` target gate gains the occupancy arm.
- `src/modules/putaway/putaway.command.ts:64-70` -- add `bulk-asset` reason code; `:543-651` placement gate + `:1005-1051` `candidateFitsSku` gain the single-SKU occupancy arm; `:1061` `binCandidatesInTx` WHERE excludes bulk assets.
- `src/modules/outbound/pick.command.ts` -- verify-only: no structural change expected.

**wms-fe:**
- `src/components/settings/zone-bin-setup.tsx:36` (list), `:360`, `:491` (casts) -- offer the 8 types.
- `src/lib/api/generated/*` -- regenerate (`bun run api:generate`): the type enum and the `reasonCode` union grow.

**wms-mobile (renegotiated 2026-09-25 — triage #1):**
- `src/api.ts:249-263` + `src/putaway/draft.ts:22-30` -- the two mirror enums gain `'bulk-asset'` (mirrors self-describe as "mirror of the server's"); `MISMATCH_REASON_LABELS` gains its label.
- `src/putaway/draft.test.ts` -- one parity assertion pinning the mirror to the server's enum.

## Tasks & Acceptance

**Execution:**
- [x] `src/shared/primitives/location-type.ts` -- new vocabulary file -- one source of truth; BE tests may import it.
- [x] `src/modules/tenancy/tenancy.dto.ts` -- swap vocabulary in all three DTO spots -- DTO layer of the three-layer pattern.
- [x] `drizzle/0037_location_type_check.sql` -- DB backstop; additive, no data mutation.
- [x] `src/modules/tenancy/bin.command.ts` -- bulk validations + merge occupancy arm -- master-data side of the rules.
- [x] `src/modules/putaway/putaway.command.ts` -- occupancy arm in both predicate sites, candidate exclusion, new reason code -- the sync-hazard sites.
- [x] BE tests -- unit arms for every I/O row above -- pin the rules before review.
- [x] `src/components/settings/zone-bin-setup.tsx` + generated regen -- FE can create and list the new types.
- [x] wms-fe `src/lib/*` tests updated if fixtures pin the 4-value type union.
- [x] wms-mobile mirror enums + label + parity assertion -- renegotiated scope (triage #1): bulk placement must be possible from the device.

**Acceptance Criteria:**
- Given a tank holding SKU A, when `putaway.place` targets it with SKU B, then 400 `bin-occupancy-conflict`; with SKU A, success.
- Given bulk assets exist, when the suggestion re-derives, then tank/silo never appear; an operator targeting one while the suggestion picked another bin requires `bulk-asset`.
- Given createBin/generateGrid, then tank/silo require `maxWeightGrams` and refuse gridding; PATCH cannot clear it on a bulk asset.
- Given a pick line whose stock sits in a yard/floor-stack/tank, the draw runs the existing gates and succeeds unchanged.
- Migration `0037` applies with all pre-existing rows conforming; the migrations CI check passes.
- The FE settings form offers all 8 types and the generated client matches the new openapi.

## Implementation Notes

Implementation landed 2026-09-25 across three repos, reviewed twice (loop 1: 22 findings, one intent_gap resolved by the human renegotiating the frozen mobile boundary; loop 2: 34 logged findings — 11 patched, 1 reject on the frozen boundary, rest carried/deferred/rejected). BE commits 9d6f280→1b22a89 on `feat/12-4-non-bin-location-types`; FE fa7b3e8→997000c; mobile 6ab85bd.

Final verification (post review-2 patches): BE lint clean, tsc clean, 731/731 across 39 suites (137s); FE tsc clean, 348/348 across 25 files; mobile tsc clean, 20/20 draft tests; `bun run openapi:export` regenerated (three maxWeightGrams description lines). Migration `0037` is additive (CHECK + journal + snapshot), zero data mutation; the migrations CI job proves it on the PR.

Known limits, recorded rather than half-guarded: the bulk re-value guard counts on-hand load only (qcHolds carries no quantity, so held mass attributed to an origin bin is not computable from the hold rows — a release that would over-fill a re-valued asset is a PENDING note); `stock.adjust` remains the standing bypass for the occupancy gate.

## Spec Change Log

- **2026-09-25 — review loop 2, no loopback triggers.** Re-review of the patched tree (all three layers). 11 patch entries (#23-#26, #28-#34), one reject (mobile device pre-check, frozen boundary, #27), one carried defer (the FE weight-cap mirror note re-raises #16). No intent_gap, no bad_spec — the frozen block was untouched; the loop increment is the loopback bookkeeping only. KEEP instructions unchanged: the one-table/no-fork model, the ONE predicate behind the three sync-hazard sites, the zero-data-mutation migration, the mirror fix's minimalism.
- **2026-09-25 — review loop 1, triage #1 (intent_gap → human-resolved).** Trigger: the BE gate makes `bulk-asset` REQUIRED on bulk targets while the device (the only placement surface) carries a mirror enum without it — bulk placement impossible from mobile, no test anywhere failing. Amended: the frozen Never's "no mobile changes" renegotiated by the human to permit exactly the minimal mirror fix (two enums + label + parity assertion); mobile task added to Code Map and Tasks. Known-bad state avoided: shipping bulk assets with no working device path. KEEP instructions: the one-table/no-fork model, the ONE predicate behind the three sync-hazard sites, the zero-data-mutation migration, and the mirror fix's minimalism (enum + label + one assertion — no other mobile surface changes).

## Review Triage Log

| # | Finding | Verdict | Evidence / Route |
|---|---------|---------|------------------|
| 1 | **Mobile mirror never gained `bulk-asset`** — device bulk placement impossible (V1+B2) | high | Verified first-hand: `wms-mobile/src/putaway/draft.ts:22-30` and `src/api.ts:249-263` carry only the five old codes, no 'bulk' anywhere in mobile; the BE gate (`putaway.command.ts:729-739`) REFUSES any non-`bulk-asset` reason on a bulk target, and a tank is never suggested, so every device bulk placement is a mismatch → 400 at replay. **intent_gap** — the frozen Never ("no mobile changes") conflicts with the story's own "not second-class" intent (placement is a device-session command; the device is the only placement surface). Only the human can renegotiate the frozen line. |
| 2 | FE settings bulk behavior has zero test coverage (V2+B15) | medium | Verified: no test mounts `zone-bin-setup`; the conditional `maxWeightGrams` spread and `GRID_TYPES` filter regress invisibly (typecheck can't catch either — the field is optional in the DTO). **patch** — component test in the sibling-test style. |
| 3 | Occupancy-before-hazard ordering asserted in comments, never executed (B12) | medium | Real: only the weight arm proves ordering. An incompatible-hazard different-SKU placement into a tank would answer `bin-segregation-conflict` if the ordering broke. **patch** — one test arm. |
| 4 | `bulk-asset` reason accepted on non-bulk targets (E1) | low | Verified: the arm is one-directional (`isBulkAssetType && reasonCode !== 'bulk-asset'`); the recorded signal can be polluted. **patch** — symmetric refusal. |
| 5 | `occupantSkusInTx` runs unconditionally (B3) | low | Verified: both gates query before checking `isBulkAssetType`. **patch** — gate the read behind the type check. |
| 6 | Reason enum duplicated in BE command + DTO (B4) | low | Verified: `PUTAWAY_MISMATCH_REASON_CODES` and `PUTAWAY_MISMATCH_REASON_ENUM` are distinct consts typechecking independently. **patch** — re-export one from the other. |
| 7 | Device-catalog DTO description stale (B7) | low | Verified: `putaway.dto.ts:264` still says "shelf/pallet/floor/staging". **patch** — update description. |
| 8 | Grid DTO openapi enum advertises always-refused types (B8) | low | Real: `GenerateBinsDto` widened to 8 while `refuseBulkAssetGrid` rejects 2 of them. **patch** — narrow the grid DTO enum (runtime refusal stays as backstop). |
| 9 | Create/grid DTO `type` descriptions lack the bulk rules (B10) | low | Real. **patch** — extend the `@ApiProperty` descriptions (with #7, #8, + regen). |
| 10 | `binOccupancyConflict` title wrong for the empty-asset co-mix case (B11) | low | Real (the merge moved-vs-moved arm refuses an EMPTY asset). **patch** — wording. |
| 11 | FE manual form weight state not reset after create (B17) | low | Verified: only `setCode('')` in the success path. **patch** — reset alongside. |
| 12 | Trailing newlines missing (B19) | low | `0037_location_type_check.sql`, `location-type.ts`, `putaway.spec.ts`. **patch** — trivial. |
| 13 | Stale function name `bulkAssetOccupancyExceeded` in the primitive header (B1) | low | Verified: `location-type.ts:24` vs actual `bulkAssetOccupancyHolds` (:92). **patch** — one word. |
| 14 | PATCH null-clear on an ordinary bin untested though the test comment claims it (B13) | low | Verified: no test PATCHes `maxWeightGrams: null` on an ordinary bin. **patch** — one assertion. |
| 15 | `stock.adjust` bypasses the new occupancy gate (E2) | low | Pre-existing containment pattern — PENDING documents the identical bypass for the 11-5/12-1/12-2/12-3 gates; recoverable via draws (no gate on the draw). **defer** (+ PENDING entry at step-05). |
| 16 | FE re-hardcodes the bulk-type set and weight cap with no cross-repo pin (B5+V3) | low | Inherent repo split: "which types are bulk" is a semantic classification the generated openapi cannot carry, so some FE-side mirror is unavoidable; the missing piece is a parity pin. **defer** (with #17 — one systemic entry). |
| 17 | Reason enum hand-kept in five places, no parity test anywhere (V4) | medium | Developer-only harm, real: this story updated 3 of 5 copies and the drift class just bit. **defer** — a parity checker is systemic work (12-8 touches the mobile mirrors anyway); the BE-internal half is patched as #6. |
| 18 | Tank-only-warehouse rationale misstates the exclusion reason (B14) | low | The rationale text pre-exists 12-4 (any pool-empty-by-exclusion case produced it — system-bin-only warehouses, role-blind pool); 12-4 adds a new trigger. **defer**. |
| 19 | Unit `capacity` mandatory on bulk assets though they are "weight-defined" (B16) | low | Pre-existing mandatory DTO field; the unit gate behaves for a tank as for any bin (fill level in the SKU's UoM); no end-user harm shown. **reject**. |
| 20 | Hand-written journal timestamp (B18) | low | Cosmetic; drizzle does not consume the precision; no functional path touches it. **reject**. |
| 21 | Two ~170-line `it()` blocks (B20) | low | Consistent with the suites' existing long-form e2e its. **reject**. |
| 22 | `bin-occupancy-conflict` absent from API-SURFACE / contracts (B9) | false | The meta docs PR is this workflow's scheduled final step (code ships before the docs that describe it); the contract update lands at step-05. |
| 23 | Bulk-asset `maxWeightGrams` re-value below currently held mass is ungated (E3+B21) | medium | Verified round 2: `refuseBulkAssetWeightClear` (bin.command.ts:1674-1686) only covers the null clear — a PATCH to a smaller positive number strands load above the asset's defining limit, no later gate flags it; the adjacent class-edit stock-conformance guard is the mirror to follow. **patch** (review 2). |
| 24 | `candidateFitsSku` docblock claims the bulk arm runs "THIRD, after the hazard arm" (B22) | low | Verified round 2: the code places it second (after class, before the hazard walk). **patch** — truthful comment. |
| 25 | `location-type.ts` header says "nothing in this file runs outside a command transaction" (B23) | low | Verified round 2: `tenancy.dto.ts` consumes `LOCATION_TYPES`/`GRID_TYPES` in `@IsIn` validators that run in the ValidationPipe before any transaction. **patch** — reword the scope claim. |
| 26 | The symmetric `bulk-asset` refusal arm ships with zero test coverage (V5+B24) | low | Verified round 2: no test posts `reasonCode: 'bulk-asset'` to an ordinary bin (grep across test/ — the arm's error text has zero hits). **patch** — one arm. |
| 27 | Mobile device pre-check (`canConfirm`/`chooseReason`) has no bulk-asset arm (B25+E4+E5) | low | Real gap (operator learns the rule only at replay 400), but the renegotiated frozen boundary admits only the mirror fix — the pre-check extension is exactly the "nothing else in mobile" the human drew. **reject (frozen boundary)** + PENDING entry at step-05. |
| 28 | No-reason bulk placement answers the GENERIC six-code message (B26) | low | Verified round 2: the generic mismatch arm (reason required, target ≠ suggestion) fires first; the specific bulk arm only when some reason was supplied. **patch** — move the bulk arm before the generic arm (message-only; both 400 `validation-failed`). |
| 29 | `maxWeightGrams` DTO text advertises verbs bulk assets refuse (B27) | low | Verified round 2: CreateBinDto "Omit to leave the bin unconstrained; null to clear" and PatchBinDto "null to clear" are both 400s on tank/silo. **patch** — description caveats + regen. |
| 30 | `GenerateBinsDto.type` TS type stays `BinType` (8) while `@IsIn(GRID_TYPES)` accepts six (B28) | low | Verified round 2: server TS layer is looser than its own validator and than the FE generated contract. **patch** — narrow to `Exclude<LocationType, BulkAssetType>`. |
| 31 | 0037 comment's mirror claim stale after the grid narrowing (B29) | low | Verified round 2: the grid DTO validates `GRID_TYPES` imported from the primitive, not the `BIN_TYPES` re-export. **patch** — one-line comment fix. |
| 32 | FE create-picker vocabulary unpinned; `silo` never driven through the manual form (V6+B30) | low | Verified round 2: the new test pins the GRID picker only; deleting `silo` from `BIN_TYPES` passes every test. **patch** — create-picker full-vocabulary assertion + a silo payload arm. |
| 33 | Merge's occupancy-before-hazard ordering asserted in comments, pinned by no test (V7) | low | Verified round 2: the four merge tests' SKUs carry no hazard classes and sit under all limits — every assertion holds under any gate order (the placement pin from triage #3 has no merge counterpart). **patch** — one ordering arm. |
| 34 | FE `zone-bin-setup.test.tsx` lacks a trailing newline (B31) | low | Verified round 2 (file ends `;`, 0x3b) — the round-1 newline patch (#12) fixed the BE files but missed the FE file created in the same round. **patch** — trivial. |


## Design Notes

Decisions taken (flagged at approval; veto there if unwanted):
1. **`floor` stays alongside `floor-stack`** — no rename, no data mutation. `floor` = individual floor bins (spec 1.3); `floor-stack` = bulk stacked area. Renaming would be a shipped-convention change with data mutation for no capability gain.
2. **Tank/silo are single-SKU, weight-defined** (`maxWeightGrams` required) — physically you cannot co-mix or dimension-gate a tank; unit `capacity` stays optional.
3. **Tank/silo are never auto-suggested and are excluded from grids** — their suitability depends on measured fill (Epic 20); until then they are operator-directed bulk assets. Hence the `bulk-asset` mismatch reason code.
4. **Yard/floor-stack carry no extra rule** — the standard gates (class, secure, hazard, 11-5 capacity) already cover them; dims serve as footprint, per-axis oversize applies as-is.

The ledger, `stock_on_hand`, `batch_on_hand` and `bin_state_epochs` are untouched on purpose: Epic 20's measured-stock reconciliation lands on the same bin-keyed substrate, which is why this story must not fork the model.

## Verification

**Commands:**
- BE: `bun run lint` + `bun run test` -- expected: clean; full suite green at/above the current baseline, new arms for every I/O row.
- BE migrations CI job -- expected: `0037` applies, `bins_type_check` present.
- FE: `bun run api:generate` (drift guard) then `bun run typecheck` + `bun run test` -- expected: clean.

**Results (2026-09-25, post review-2):**
- BE: `bun run typecheck` clean; `bun run lint` clean; `bun run test` 731/731 across 39 suites (137s).
- FE: `bun run typecheck` clean; `bun run test` 348/348 across 25 files.
- Mobile: `tsc --noEmit` clean; 20/20 draft tests.
- `bun run openapi:export` regenerated; FE generated client matches (the drift guard re-proves it in CI after the BE PR merges).