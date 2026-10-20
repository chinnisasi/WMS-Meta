---
title: '1-6b goods-type segregation — the matrix extended to food, allergens, drugs and chemicals'
type: 'feature'
created: '2026-10-20'
status: 'ready-for-dev'
baseline_commit: '8b71f1d015077c9651d33176a78675769ddb224c'  # wms-be; wms-fe: 05209991212593b180919df3d405032d2dfa04bc; wms-mobile: f81fd3adc208dc4f472c1738d5e7ff0f140e9f28
route: 'dispatch'
review_loop_iteration: 0
context:
  - 'docs/initiatives/production-readiness.md'
  - 'docs/design/SYSTEM-DESIGN.md'
  - 'docs/design/IMPLEMENTATION-GUIDE.md'
  - 'docs/design/modules/catalog.md'
  - 'docs/design/modules/putaway.md'
  - 'docs/design/modules/tenancy.md'
  - 'docs/design/modules/inventory.md'
  - 'docs/design/modules/movements.md'
  - 'docs/design/frontend/IMPLEMENTATION-GUIDE.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** Segregation (12-2) reads only `hazard_class`, one value per SKU. Story 1-6a captured more: drug schedules, food category, allergens, DG subsidiary classes, and class-8 corrosives with no acid/base choice. Nothing reads them. Food can share a bin with a corrosive or a lithium battery, raw chicken can share a bin with salad, and a flammable liquid with a toxic subsidiary risk can sit beside an acid.

**Approach:** Replace the two-class predicate with one predicate over a SKU's **segregation profile**. Every existing gate calls it:
- the putaway suggestion and placement;
- bin merge;
- transfer receive;
- the SKU edit guard.

The matrix read and its web card list the new rules. The handheld code is unchanged: segregation stays server-side, and the refusal codes are unchanged.

**The terms:**
- **Profile:** `{hazardClass, dgClass, dgSubsidiaryClasses, drugSchedules, foodCategory, allergens}`. It is **empty** when all of these hold: no hazard class, no DG class, no subsidiaries, no schedules, and a category that is null or `non-food`. The allergen set is ignored for emptiness, because allergens need a food category (1-6a CHECK).
- **Food:** `foodCategory` is set and is not `non-food`.
- **Drug:** `drugSchedules` is non-empty.
- **Chemical:** has a `hazardClass` or a `dgClass`, and is neither food nor a drug (decision 8).
- **Hazard set:** `hazardClass` plus each subsidiary mapped through `DG_HAZARD_MAP` (decision 1).

**The rules (user, 2026-10-20).** Two SKUs in one bin conflict when any rule fires. Rules are checked in this order.

| # | Code | Fires when | `description` (served verbatim) |
|---|---|---|---|
| 1 | `hazard-pair` | Any pair across the two hazard sets is incompatible under 12-2's `hazardClassesCompatible` | `Hazard classes that react — the grid above — never share a bin. A DG subsidiary risk counts like its primary class.` |
| 2 | `explosive-dg` | One hazard set holds `explosive` and the other SKU has any DG class | `An explosive never shares a bin with any dangerous good, including DG classes with no hazard class (4, 5.2, 6.2, 7, 9, 8 none).` |
| 3 | `food-chemical` | One is food and the other a chemical | `Food never shares a bin with a chemical — any SKU with a hazard class or a DG class that is not itself a food or drug.` |
| 4 | `drug-chemical` | One is a drug and the other a chemical | `A scheduled drug never shares a bin with a chemical.` |
| 5 | `allergen-mismatch` | Both are food and their allergen sets differ | `Two foods share a bin only when they declare the same allergens. No allergens entered counts as allergen-free.` |
| 6 | `raw-ready-to-eat` | One is `meat-poultry-seafood` and the other is `dairy`, `ready-to-eat`, `fresh-produce`, `bakery-cereals` or `infant-food` | `Raw meat, poultry and seafood never share a bin with dairy, ready-to-eat food, fresh produce, bakery and cereals, or infant food.` |

**Decisions (user, 2026-10-20):**
- Rules 3, 4, 5 and 6 as above.
- Food is kept from any DG class.
- An empty allergen set means allergen-free and the rule is strict. Sealed retail packs are refused too (PENDING).
- `dairy` joins rule 6.
- Explosives are widened to any DG (rule 2).

**Decisions (agent):**
1. **Subsidiaries:** 1.x → explosive, 2.x → gas, 3 → flammable, 5.1 → oxidizer, 6.1 → toxic. The rest (4.x, 5.2, 6.2, 7, 8, 9) add no hazard. Subsidiary 8 records no acid/base choice, so it adds nothing (PENDING).
2. **Same codes per gate.**

   | Gate | Code |
   |---|---|
   | Placement | 400 `bin-segregation-conflict` |
   | Merge | 400 `bin-segregation-conflict` |
   | Transfer receive | 409 `bin-segregation-conflict` |
   | Edit guard | 409 `hazard-segregation-conflict` |

   - The problem `title` stays as today for `hazard-pair` and `explosive-dg`.
   - The other four rules use `Target bin holds goods that must be kept apart`.
3. **Edit guard: refuse only what the edit makes worse.**
   - The guard body runs when the profile changes. Arrays are compared as sorted sets; the hazard class is 1-6a's `effectiveHazard`.
   - For each binmate (stock bins and QC-hold origins), compute `conflictKeys(profile, binmate)`. The keys are `hazard-pair:<x>|<y>` per incompatible sorted class pair, plus each other rule's code that fires.
   - The edit is refused when the new keys are not a subset of the stored keys.
   - So 12-2's explosive → flammable beside an oxidizer is still refused (`test/sku-attributes.spec.ts:888–926` stays green unchanged), and a rename in an already-mixed bin passes.
4. **Own-SKU and moved-vs-moved rules are unchanged.**
   - Own-SKU pairs skip.
   - Merge does not re-check moved rows against each other.
   - Transfer keeps landing-vs-landing.
   - An empty profile skips wherever a null class skipped.
5. **Not retroactive.** Mixed bins are not moved or refused until their next gated write. `scripts/segregation-conflicts.ts` lists them. It reads each bin's occupant profiles and calls the TS predicate, with no SQL copy of the rules.
6. **Matrix read.**
   - `classes` and `incompatible` are unchanged.
   - It gains a required `rules: [{code, description}]` in table order. `code` is a plain string, not an OpenAPI enum.
   - It is served from `GOODS_SEGREGATION_RULES` in the primitive.
7. **No migration.** No idempotency hash changes.
8. **A food or drug that is also DG is not a chemical.**
   - Spirits (UN3065, DG 3) can sit beside juice.
   - Such a SKU still obeys rules 1 and 2 and its food or drug rules.
9. **Detail wording.**
   - Each rule has a template naming both SKU codes, the facts that fired, and the bin. It is oriented incoming/edited vs occupant/binmate.
   - `hazard-pair` names the first incompatible pair, walking the incoming set and then the occupant set in `HAZARD_CLASSES` order.
   - Only the first rule that fires per pair is named.
10. **Kits** hold no stock (`assertKitSkuHoldsNoStock`), so they never meet a gate.
11. **Handheld operator path, unchanged and now documented.**
    - A queued putaway or transfer refused at replay is re-plannable (`replay-classification.ts:37`). It retries at least 5 minutes apart, then quarantines.
    - On the web review queue, Apply re-places into the same bin and is refused again until the occupant leaves. Discard is the way out.
    - Ops queued before the deploy into bins that were legal then take this path. The handheld follows the server's `suggestedBin`, which never names a conflicting bin.

## Boundaries & Constraints

**Always:**
- **Primitive: `src/shared/primitives/segregation.ts`.**
  - `SegregationProfile` and `isEmptyProfile`.
  - `EMPTY_PROFILE_SQL`, the SQL condition for a non-empty profile:

    ```sql
    hazard_class is not null
    or dg_class is not null
    or cardinality(dg_subsidiary_classes) > 0
    or cardinality(drug_schedules) > 0
    or (food_category is not null and food_category <> 'non-food')
    ```

    An e2e pins it against `isEmptyProfile`.
  - `hazardSet`, `goodsConflict(a, b): {rule, …facts} | null` (symmetric), `conflictKeys`, `GOODS_SEGREGATION_RULES`, and the detail templates.
  - It imports `hazardClassesCompatible`, which is unchanged.
  - Unit tests cover:
    - every rule in both argument orders;
    - each subsidiary mapping, 8 included;
    - the rule order;
    - decision 8;
    - empty vs anything;
    - allergen superset and equal sets;
    - `conflictKeys` subset cases.
- **Occupant reads.** These four filter with `EMPTY_PROFILE_SQL` instead of `hazard_class is not null`, and return the profile:
  - `occupantHazardClassesInTx`;
  - `binOccupantHazardPairsInTx`;
  - `assertPlacementGatesInTx`'s inline query;
  - the `binCandidatesInTx` aggregate.

  The `binCandidatesInTx` aggregate carries only `skuId`s per bin. Their profiles come from one keyed query over the distinct ids, not from a jsonb blob per row. Each read keeps `quantity > 0` and its lock window.
- **Incoming SKU reads** widen to the profile:
  - placement `putaway.command.ts:376–397` and `SkuPhysicalAttributes` `:1185`;
  - the task list `putaway.facade.ts:339–358`;
  - merge `onHandRows`;
  - transfer `skuRows` `inventory.facade.ts:2355`.
- **Merge.** The `row.hazardClass === null` skip and the `targetOccupants.length > 0` gate (`bin.command.ts:932`) become empty-profile checks.
- **Edit guard.**
  - One grouped occupant query covers the stock bins and the hold origins, with no N+1.
  - The 409 detail lists every newly conflicting bin, binmate and hold.
- **API text.** Every description saying "naming both SKUs and both classes" is reworded to name the rule:
  - `api/putaway.controller.ts:65`;
  - `api/movements.controller.ts:205`;
  - `tenancy/tenancy.controller.ts:689`;
  - `catalog.controller.ts:546–553`.

  `CatalogSegregationMatrix` (`catalog.facade.ts:154`) and `SegregationMatrixResponse` (`catalog.dto.ts:804`) gain `rules` through a nested `SegregationRuleDto`. Commit `bun run openapi:export`.
- **Backend tests.**
  - `test/putaway.spec.ts`: one placement refusal per rule; a suggestion skip; `putawayTasks[].suggestedBin` never names a conflicting bin.
  - `test/bin-admin.spec.ts`: merge.
  - `test/movements/transfer.spec.ts`: the first segregation case in that file.
  - `test/sku-goods-type.spec.ts`: the edit guard and its matrix rows.
  - `test/segregation-matrix.spec.ts`: the six `rules`, verbatim.
  - An e2e for `scripts/segregation-conflicts.ts`: two seeded mixed bins (food + DG 9; `[milk]` + `[]` food) are listed, and a clean bin is not.
- **Web.**
  - `segregation-matrix-card.tsx`:
    - render `rules` as a list keyed on `code` below the grid;
    - rewrite the header copy and the doc comment (`:18–21`, `:64–66`): drop "a null-class SKU may sit beside anything", and say that the grid covers hazard classes and the list covers goods-type rules;
    - pin both in the card test.
  - `zone-bin-setup.tsx` merge refusal: add an explicit `bin-segregation-conflict` case returning `detail`, with a component test.
  - `sku-admin.ts:102`: change the fallback to `This change conflicts with stock in the same bins — relocate it first.` and update its pin (`sku-admin.test.ts:112`).
  - Run `api:generate`.
- **Meta docs.**
  - Update the module docs, `API-SURFACE.md`, and `docs/repos/wms-be/README.md:216` (the null-class sentence).
  - `docs/repos/wms-fe/README.md`.
  - `docs/repos/wms-mobile/README.md:56`: correct "dropped" to re-plannable, and name the wider rule set.
  - `PENDING.md`:
    - close the two 1-6a segregation entries;
    - add: not retroactive (with the script); the sealed-pack allergen strictness; subsidiary 8 has no acid/base; 5.2 vs flammable and other unmapped-class pairs; raw vs cooked/canned meat; veg/non-veg; the putaway "no room" rationale when segregation is the cause; the decision-11 operator path and the review Apply that re-refuses;
    - extend the unlocked-occupant race (putaway) to all six fields;
    - add count-variance corrections and the QC-release hold-origin landing to the named bypasses.

**Never:**
- No handheld code or snapshot change.
- No retroactive relocation.
- No per-tenant matrix.
- No zone or adjacent-bin rules.
- No change to the bypasses: `stock.adjust`, count-variance corrections, `qc.released`, picks, or receipts into system bins.
- No licences (1-6c).
- No drug-vs-food or drug-vs-drug rule.
- No client dimension: two clients' foods obey the same rules.
- No migration.

## I/O & Edge-Case Matrix

The profiles not stated in a row are empty.

| Scenario | Input / State | Expected | Error |
|---|---|---|---|
| Subsidiary | bin: acid; place DG 3 (sub 6.1) | refused, `hazard-pair` toxic/corrosive-acid | 400 `bin-segregation-conflict` |
| Subsidiary self | DG 3 (sub 6.1) beside flammable | allowed | N/A |
| Explosive vs DG 9 | bin: DG 9 battery; place DG 1.1 | refused, `explosive-dg` | 400 |
| Food vs DG 9 | bin: DG 9; place rice | refused, `food-chemical` | 400 |
| Legacy hazard | bin: SKU with hazard `toxic`, no DG (12-2 data); place rice | refused, `food-chemical` (newly) | 400 |
| Drug vs 8 none | bin: DG 8 none; place an `H` drug | refused, `drug-chemical` | 400 |
| Food + drug | a food + `H` SKU beside DG 8 none | refused, `food-chemical` (first) | 400 |
| Spirits | whisky (beverages + DG 3) beside juice (beverages) | allowed | N/A |
| Spirits vs oxidizer | whisky beside DG 5.1 | refused, `hazard-pair` | 400 |
| Allergen | `[milk]` confectionery beside `[]` confectionery | refused, `allergen-mismatch` | 400 |
| Allergen superset | `[milk]` beside `[milk, eggs]` | refused | 400 |
| Allergen equal | both `[eggs, milk]` | allowed | N/A |
| Allergen vs non-food | `[peanuts]` food beside a t-shirt | allowed | N/A |
| Raw | chicken beside paneer (dairy) / salad | refused, `raw-ready-to-eat` | 400 |
| Own SKU | rice tops up its own bin | allowed | N/A |
| Empty | non-food, no DG, no schedule, beside anything | allowed, response byte-identical | N/A |
| Merge | source rice → target holding DG 9 | refused whole | 400 |
| Transfer | land rice into a bin holding DG 6.1 | refused | 409 `bin-segregation-conflict` |
| Edit: food added | an empty-profile SKU binned beside DG 8 none; PATCH `{foodCategory:'dairy'}` | unchanged | 409 `hazard-segregation-conflict` |
| Edit: schedule added | same bin; PATCH `{drugSchedules:['H']}` | unchanged | 409 |
| Edit: becomes chemical | a flammable drug binned beside rice; PATCH `{drugSchedules:[]}` | unchanged | 409 |
| Edit: allergen removed | `[milk]` food beside `[milk]` food; PATCH `{allergens:[]}` | unchanged | 409 |
| Edit: food → non-food | DG 3 beverage beside juice; PATCH `{foodCategory:'non-food'}` | unchanged | 409 |
| Edit: unrelated | bin already mixed (rice + DG 9 via `stock.adjust`); PATCH the rice `{name}` | 200 | N/A |
| Edit: same conflict | rice beside DG 9; PATCH rice `{allergens:['milk']}` (keys `{food-chemical}` unchanged) | 200 | N/A |
| Edit: 12-2 regress | explosive beside oxidizer; PATCH `{hazardClass:'flammable'}` | unchanged | 409 |
| Matrix | GET segregation-matrix | `classes` and `incompatible` as before, plus 6 `rules` verbatim in order | N/A |

</frozen-after-approval>

## Code Map

All backend paths are under `workspace/core/backend/wms-be/`.

- **Primitives:**
  - `src/shared/primitives/hazard.ts`: pairs `:64`, `hazardClassesCompatible` `:81`, `enumerateIncompatiblePairs` `:115`, factories `:163` (400) and `:178` (409).
  - `goods-type.ts`: `DG_HAZARD_MAP` `:118`, `CORROSIVE_DG_CLASS` `:133`, vocabularies `:26–68`.
  - Name the new predicate `goodsConflict`, so it does not clash with `segregationConflict`.
- **Putaway** (`putaway.command.ts`):
  - incoming read `:376–397`;
  - placement gate `:654–685` (own-SKU skip `:671`);
  - `SkuPhysicalAttributes` `:1185`;
  - `candidateFitsSku` `:1259` (skip `:1278`);
  - `binCandidatesInTx` `:1324` (aggregate `~:1356`);
  - `occupantHazardClassesInTx` `:1531` (filter `:1555`);
  - `binOccupantHazardPairsInTx` `:1586` (filter `:1609`);
  - `binSegregationConflict` `:1807`.

  In `putaway.facade.ts`: the SKU select `:339–358`, candidates `:401`, rationale `:445` (unchanged). The rule that these sites stay in sync is commented at `putaway.command.ts:707`.
- **Merge:** `tenancy/bin.command.ts:671`; hazard arm `:915–947` (null skip `:932`, own-SKU `:935`).
- **Transfer** (`inventory/inventory.facade.ts`):
  - `assertPlacementGatesInTx` `:2259`;
  - `skuRows` `:2355`;
  - inline occupants `:2461–2473` (filter `:2472`, skip `:2477`);
  - title `:2484`;
  - landing-vs-landing `:2492–2510`.

  The caller is `movements/transfer.command.ts:1369`.
- **Edit guard** (`catalog/sku.command.ts`): the hazard arm `:1219–1336`, `effectiveHazard` `~:1139`. Every edit already holds the SKU lock (`:1149`).
- **Matrix read:** `catalog.facade.ts:154`, `:420`; `catalog.controller.ts:417`; `catalog.dto.ts:804`.
- **Bypasses (unchanged):**
  - `inventory.command.ts:916`;
  - `sync-report.command.ts:1412` (the review Apply re-enters `placePutaway`);
  - `return-receipt.command.ts:1080` (system bin).
- **Web** (`workspace/core/frontend/wms-fe/`):
  - `src/components/settings/segregation-matrix-card.tsx` (`:18–21`, `:64–66`, grid `:82–108`) and its test;
  - `src/lib/use-segregation-matrix.ts`;
  - `zone-bin-setup.tsx:1210–1264`;
  - `src/lib/sku-admin.ts:91–110` and `sku-admin.test.ts:112`.
- **Mobile (read only, workspace/core/mobile/wms-mobile/):**
  - `src/state/replay-classification.ts:27–46, 147–165`;
  - `src/offline/engine.ts:64–80`;
  - `app/putaway.tsx:356`.

## Tasks & Acceptance

**Execution:**
- [ ] `wms-be src/shared/primitives/segregation.ts` (+ spec) -- profile, `EMPTY_PROFILE_SQL`, hazard set, `goodsConflict`, `conflictKeys`, rules, templates -- the one rule set
- [ ] `wms-be putaway/{putaway.command,putaway.facade}.ts` -- profile reads, the sku-id aggregate plus the keyed profile read, placement gate -- suggestion + placement
- [ ] `wms-be tenancy/bin.command.ts`, `inventory/inventory.facade.ts` -- merge + transfer receive gates, the empty-profile skip, titles -- every gated writer
- [ ] `wms-be catalog/{sku.command,catalog.facade,catalog.controller,catalog.dto}.ts`, `api/{putaway,movements}.controller.ts`, `tenancy/tenancy.controller.ts` -- the `conflictKeys` edit guard, `rules`, API text -- decisions 2, 3, 6
- [ ] `wms-be scripts/segregation-conflicts.ts` -- the listing over the TS predicate -- decision 5
- [ ] `wms-be test/*` + `openapi/openapi.json` -- the matrix rows, the script e2e, the SQL pin, the export -- proof
- [ ] `wms-fe` regenerated types; matrix card rules + copy; merge refusal case; edit fallback copy; tests -- decision 6
- [ ] meta `docs/design/modules/{catalog,putaway,tenancy,inventory}.md`, `API-SURFACE.md`, `PENDING.md`, `docs/repos/wms-{be,fe,mobile}/README.md` -- per Boundaries

**Acceptance Criteria:**
- Given a bin holding a rule-conflicting SKU, when putaway tasks are listed (web and device snapshot) for the incoming SKU, then that bin is never the `suggestedBin`, and placing into it is refused, naming both SKUs and the rule.
- Given only empty-profile SKUs, when they are placed, merged or transferred, then the responses are byte-identical to before.
- Given Settings → Catalog, when the matrix card opens, then the grid is unchanged, and the copy and the six rule descriptions match the server.
- Given a seeded DB with two mixed bins, when `scripts/segregation-conflicts.ts` runs, then it lists exactly those two bins and the rule for each.

## Implementation Notes

## Spec Change Log

## Review Triage Log

**Design review, 2026-10-20.** Three reviewers: backend (B1–B11), edge cases and domain (E1–E14), web and handheld (F1–F8). 33 raw findings, 27 after merging duplicates. Three needed the user (allergen `[]` semantics, dairy, explosives; answered the same day). The rest are patched above or sent to PENDING. Re-checked by hand:
- the 12-2 guard test `sku-attributes.spec.ts:888–926` (B2 is real);
- the three `NOT NULL DEFAULT '{}'` arrays at `schema.ts:921–926` (B3 is real);
- the "no room" rationale at `putaway.facade.ts:445`;
- `MAX_REPLAN_ATTEMPTS = 3` with a 5-minute cooldown (`engine.ts:64–80`).

- D1 high (B1, E1): `drugSchedules` was missing from the profile, the reads and the edit trigger. Added everywhere, with edit rows in both directions.
- D2 high (B2, E7): "newly incompatible" would pass 12-2's explosive → flammable edit. The `conflictKeys` subset rule (decision 3); the 12-2 test is named to stay green.
- D3 high (B3, E12): "any profile field set" admits every row because the arrays default to `'{}'`. `EMPTY_PROFILE_SQL` is pinned against `isEmptyProfile`.
- D4 high (E2) → user: `[]` is allergen-free and the rule stays strict; sealed packs go to PENDING.
- D5 high (E3): the retroactive SQL would copy the rules. A script over the TS predicate, with a pinned e2e.
- D6 high (F1): the card's "null-class may sit beside anything" copy becomes false. Rewritten and pinned; the be README is fixed.
- D7 high (F2): the handheld operator path after a refusal was unstated. Decision 11 plus PENDING; no handheld code change.
- D8 med (B4): the widened jsonb aggregate costs too much. A sku-id aggregate plus one keyed profile read.
- D9 med (B5): the unlocked occupant race widens. The PENDING entry is extended to all six fields.
- D10 med (B6, F5): wrong or missing Code Map references. Corrected; the snapshot `suggestedBin` AC added.
- D11 med (B7): the API descriptions and the problem title were under-listed. Four sites named; the title split decided (decision 2).
- D12 med (B8, E5) → user: explosives widened to any DG (rule 2). 5.2 vs flammable goes to PENDING.
- D13 med (E4) → user: dairy added. Raw/cooked and veg/non-veg go to PENDING.
- D14 med (E6): subsidiary 8 has no acid/base. Stated (decision 1), to PENDING.
- D15 med (E8): wording was defined for one rule only. Per-rule templates, the hazard-pair tie-break and the orientation (decision 9).
- D16 med (E9): the `rules` wording had no source. Six descriptions fixed in the table and asserted verbatim.
- D17 med (E10): kits undecided. Kits hold no stock (decision 10).
- D18 med (F3): the mobile README says "dropped". Corrected in the meta task.
- D19 med (F4): "no room" when segregation is the cause. Kept, sent to PENDING (12-2 triage #9 deferred the same).
- D20 low (B9): count corrections and the QC-release hold origin. Named as bypasses and in PENDING.
- D21 low (B10): array change detection. Sorted-set equality (decision 3).
- D22 low (B11): merge's null skip. Becomes the empty-profile skip.
- D23 low (E11): codes per gate. A table in decision 2.
- D24 low (E13): missing edge rows. Added: food + drug, legacy hazard, food → non-food, superset, cross-client (Never: no client dimension).
- D25 low (E14): subsidiary and order tests. Named in the primitive's tests.
- D26 low (F6): merge refusal rendered by the default branch. Explicit case plus a test.
- D27 low (F7, F8): the edit fallback says "hazard class"; the `rules` shape was open. Generic copy; `rules` required, `code` a plain string.

## Design Notes

- **Why a profile, not more hazard classes.** Food and allergens are not hazard classes. Folding them into `HAZARD_CLASSES` would put them in the hazard select and the `skus_dg_hazard_derived` CHECK. The profile keeps the 12-2 vocabulary, the grid and the DB untouched.
- **Why `conflictKeys` on edit.** "Refuse any conflict" would block a rename in a bin that was already mixed before this story. "Refuse only newly incompatible pairs" would wave through a change from one conflict to another (12-2's test). The subset of fired keys is the narrowest rule that keeps both right.
- **Why the script calls the predicate.** The rules exist once, in TypeScript (the 12-2 precedent). A SQL copy would drift on the first rule change.

## Verification

**Commands:**
- `cd workspace/core/backend/wms-be && bun run lint && bun run typecheck && bun run test` -- expected: green (one jest run at a time)
- `bun run openapi:export` -- expected: committed with no further diff
- `cd workspace/core/frontend/wms-fe && bun run api:generate && bun run lint && bun run typecheck && bun run test` -- expected: green. The FE `generated-client` CI check stays red until the BE PR merges.
