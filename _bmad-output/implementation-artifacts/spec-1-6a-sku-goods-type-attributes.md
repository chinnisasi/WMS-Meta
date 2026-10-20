---
title: '1-6a SKU goods-type attributes — drug schedule, food category and allergens, dangerous goods, high value, fragile, stack limit'
type: 'feature'
created: '2026-10-20'
status: 'done'
baseline_commit: '39cfc720a60916e7f07d2b9bd923a9371620f672'  # wms-be; wms-fe: 073d08e34b40528e6eaf1bce721f74077ae9ca42; wms-mobile: b6a2e3b89c957e4524e713c27fc76a41982e9c9d
route: 'dispatch'
review_loop_iteration: 0
context:
  - 'docs/initiatives/production-readiness.md'
  - 'docs/design/SYSTEM-DESIGN.md'
  - 'docs/design/IMPLEMENTATION-GUIDE.md'
  - 'docs/design/modules/catalog.md'
  - 'docs/design/modules/putaway.md'
  - 'docs/design/frontend/IMPLEMENTATION-GUIDE.md'
  - 'docs/design/mobile/IMPLEMENTATION-GUIDE.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** The warehouse holds every kind of goods (D8), but a SKU cannot say it is a scheduled drug, a food (and with which allergens), a dangerous good, high value, fragile, or limited in how high it stacks. The floor handles a glass bottle, a UN1203 drum and a phone alike, and stories 1-6b (segregation) and 1-6c (licences) have no fields to act on.

**Approach:** New per-SKU attributes on the SKU master, the single-SKU create, the edit PATCH and the catalog import, shown on the web and sent to the handheld. Fragile, high value, DG and the stack limit show as **handling warnings** where goods are handled. A DG class **derives the hazard class** that drives today's segregation.

**Decisions (user, 2026-10-20):**
1. **Capture plus warnings.**
   - Web badges on the pack bench, order detail and picklist.
   - Handheld notes on **receive, pick, pack and putaway**. Returns receiving, transfers and counts are PENDING.
   - The stack limit is shown, not enforced (PENDING).
   - Drug schedule, food category and allergens are captured only, for 1-6b and 1-6c.
2. **High value is an independent flag.** It is a handling and insurance marker; placement stays governed by storage class.
3. **DG sets hazard.** The primary DG class derives `hazardClass`:

   | DG class | `hazardClass` |
   |---|---|
   | 1.x | `explosive` |
   | 2.x | `gas` |
   | 3 | `flammable` |
   | 5.1 | `oxidizer` |
   | 6.1 | `toxic` |
   | 8 | `corrosive-acid`, `corrosive-base`, or none — the user chooses explicitly, with no silent default. A corrosive set to none is not segregated until 1-6b (PENDING). |
   | 4.x, 5.2, 6.2, 7, 9 | none derived; `hazardClass` stays the user's choice |

   The existing hazard edit guard runs on the resulting value.
4. **Vocabularies, closed** (TS tuple + DB CHECK + DTO `@IsIn`):
   - **Drug schedules:** `G`, `H`, `H1`, `X`, `C`, `C1`, `NDPS`.
   - **Allergens (FSSAI 2020):** `gluten-cereals`, `crustaceans`, `milk`, `eggs`, `fish`, `peanuts`, `tree-nuts`, `soybean`, `sulphite`.
   - **Food category:** `dairy`, `meat-poultry-seafood`, `fresh-produce`, `bakery-cereals`, `ready-to-eat`, `beverages`, `oils-fats`, `spices-condiments`, `confectionery`, `packaged-dry-grocery`, `infant-food`, `other-food`, `non-food`.
     - `non-food` means declared not food; null means not set.
5. **Subsidiary DG classes are captured now:** up to two, from the DG class vocabulary, never equal to the primary, and only with a primary. They are shown in the badge ("DG 3 (6.1) · UN1230"). The hazard class derives from the primary only; 1-6b reads the subsidiaries.

**Decisions (agent):**
6. **The fields** (all nullable unless stated):

   | Column | Type and rule |
   |---|---|
   | `drug_schedules` | `text[] NOT NULL DEFAULT '{}'`. A drug can carry several schedules (C + H, H1 + NDPS). |
   | `food_category` | `text` |
   | `allergens` | `text[] NOT NULL DEFAULT '{}'`. Non-empty only when the food category is set and is not `non-food`. |
   | `dg_un_number` | `text`, 4 digits, `0001`–`3599` |
   | `dg_class` | `text`: `1.1`–`1.6`, `2.1`–`2.3`, `3`, `4.1`–`4.3`, `5.1`, `5.2`, `6.1`, `6.2`, `7`, `8`, `9` |
   | `dg_subsidiary_classes` | `text[] NOT NULL DEFAULT '{}'` |
   | `dg_packing_group` | `text`: `I`, `II` or `III`. Optional, because 1-6a only captures it. |
   | `high_value` | `boolean NOT NULL DEFAULT false` |
   | `fragile` | `boolean NOT NULL DEFAULT false` |
   | `max_stack_layers` | integer, 1–100: how many of the SKU's outermost received units may stand on one another; `1` reads "Do not stack" |

   - Every array is stored sorted and unique.
   - Pairing rules:
     - the UN number and the DG class are both set or both null;
     - subsidiaries and a packing group need a DG class;
     - classes 1.x, 2.x, 5.2, 6.2 and 7 take no packing group.
7. **Derivation semantics.** `resolveHazardClass(merged, requested)` is the one predicate. Here `requested` is the request's `hazardClass`: absent, `null`, or a value.
   - **Mapped class, not 8:**
     - requested absent → the derived value (it replaces any stored class; the web shows the change before saving);
     - requested equal to the derived value → that value;
     - anything else, `null` included → 400 `dg-hazard-mismatch`.
   - **Class 8:**
     - requested `corrosive-acid`, `corrosive-base` or explicit `null` → that value;
     - requested absent → the stored value when the stored value is a corrosive, or when the DG class is unchanged (null included); otherwise 400 `dg-hazard-required`;
     - any other class → 400 `dg-hazard-mismatch`.
   - **Unmapped class or no DG class:** `hazardClass` behaves as today. Switching from a mapped class to an unmapped one, or clearing the DG fields, keeps the stored hazard class (the web form re-enables the select showing it).
   - **A hazard-only PATCH** is judged against the stored DG class by the same rules.
   - **Create and import** have no stored state, so an absent or blank hazard derives; class 8 must name its choice (import cell `none` for explicit none).
8. **Nothing else couples.**
   - DG and drug schedule never touch `storageClass`.
   - Food, DG and drug fields may coexist (UN3065 alcohol is food and DG).
   - All edits are allowed while stock exists; the only stock-aware check is the existing hazard guard on a hazard change.
9. **Kits** take the fields like any SKU, display only. Handling notes show the SKU actually handled: a kit's components on pick and pack, and each exploded child line in order detail.
10. **Canonical before hashing:**
    - The API accepts `dgUnNumber` as `^(UN)?\d{4}$` (case-insensitive); the `UN` prefix is stripped before hashing and storage.
    - Arrays are sorted and de-duplicated before hashing.
    - Create hashes each new key **only when present** (the `clientId` precedent), so pre-1-6a idempotency keys keep their hash.
    - PATCH hashes present keys.
11. **No new capability, audit action or event:** `sku.edit`, `sku.edited`, `catalog.sku_edited`.

## Boundaries & Constraints

**Always:**
- **Migration 0083:**
  - fail-fast against a second run → columns → CHECKs → an assert with probes in the 0082 style (one accepted and one refused shape per CHECK, each refusal by constraint name);
  - commit the snapshot and journal entry; `db:generate` must report no changes.
  - **The CHECKs:**
    - each vocabulary, with the arrays as `x <@ ARRAY[…]::text[]`;
    - the UN-number range;
    - the stack bounds;
    - `cardinality(dg_subsidiary_classes) <= 2`, with the primary not among the subsidiaries;
    - the decision-6 pairing rules;
    - allergens only with a food category that is not `non-food`;
    - **`skus_dg_hazard_derived`:** a mapped non-8 class implies `hazard_class` equals its mapped value; class 8 implies `hazard_class` is null or one of the two corrosives.
  - Vocabulary pins compare each tuple to its named constraint, using the regex `'([^']+)'::text`.
- **The primitive:** `src/shared/primitives/goods-type.ts` holds:
  - the tuples, `DG_HAZARD_MAP` and `DG_CLASSES_WITHOUT_PACKING_GROUP`;
  - `canonicalGoodsType(input)` (strip `UN`, sort and de-duplicate);
  - `assertGoodsType(merged)` → 400 `validation-failed` naming the field;
  - `resolveHazardClass`;
  - unit tests.

  Create, edit and import call these.
- **API:**
  - `SkuResponse`, `CreateSkuDto` and `PatchSkuDto` gain `drugSchedules`, `foodCategory`, `allergens`, `dgUnNumber`, `dgClass`, `dgSubsidiaryClasses`, `dgPackingGroup`, `highValue`, `fragile`, `maxStackLayers`.
  - An explicit `null` for `highValue`, `fragile` or one of the three arrays is 400 at the controller (the `storageClass` precedent, `catalog.controller.ts:564`).
  - Nullable enums keep the existing declaration. The generated web types will drop `| null` on them, so the web keeps the cast pattern (`sku-table.tsx:788`).
  - `normalizeStoredSku` serves `[]`, `null` and `false` on pre-1-6a replays.
  - The create and edit 400 descriptions name `dg-hazard-mismatch` and `dg-hazard-required`.
  - `PatchSkuDto.hazardClass`'s description ("null clears … always succeeds") is reworded for decision 7.
- **The edit pipeline:** behind the replay and the SKU `FOR UPDATE`:
  1. merge each field as `fields.x !== undefined ? fields.x : current.x` (never `??`);
  2. `assertGoodsType(merged)`;
  3. `resolveHazardClass` → `effectiveHazard`, held apart from `fields` and the hash;
  4. `effectiveHazard` (when it differs from the stored value) drives **both** the existing guard condition (`:1163`) and the update (`:1566`).
- **Import:**
  - Ten new optional columns, appended after `barcodes`: `drug_schedules`, `food_category`, `allergens`, `dg_un_number`, `dg_class`, `dg_subsidiary_classes`, `dg_packing_group`, `high_value`, `fragile`, `max_stack_layers`.
  - Cell grammar: trimmed and case-insensitive. Lists are separated by `;`, with blanks and duplicates folded. `UN1203` and `1203` are both accepted. Packing group is `I`/`II`/`III`. Booleans use `parseTracked`. A `hazard_class` cell follows decision 7 (`none` = explicit none).
  - Row errors are coded `dg-hazard-mismatch`, `dg-hazard-required` or `validation-failed`, naming the column.
- **Device snapshot:** `SkuSummary`, `CatalogSnapshot` and `CatalogSnapshotSkuDto` gain `fragile`, `highValue`, `maxStackLayers`, and `dg: {unNumber, class, subsidiaryClasses, packingGroup} | null`, through a named `CatalogSnapshotDgDto`.
- **OpenAPI:** run `bun run openapi:export` and commit it.
- **Web:**
  - **`src/lib/goods-type.ts`:** the vocabulary mirrors, the labels, and `handlingBadges(sku)`. Missing keys read as defaults. It returns e.g. `['Fragile', 'High value', 'DG 3 (6.1) · UN1230 · PG II', 'Do not stack' | 'Stacks ≤ 4']`.
  - **SKU table:**
    - A "Handling" column, `'—'` when empty.
    - Edit-form controls for every field.
    - The nine fields join the PATCH only when they change. Arrays are compared as sorted sets, the UN number without its prefix, and `''` and null are equal.
    - Dependent resets:
      - a food category of empty or `non-food` clears the allergens and sends `[]`;
      - clearing the DG class clears the UN number, subsidiaries and packing group;
      - the packing-group select offers nothing for classes without one;
      - a mapped class sets the hazard select and disables it, with the hint "Set by DG class 3";
      - class 8 offers acid, base or none, and starts on an empty "choose" option unless the stored value is a corrosive.
    - Accessibility: allergens and drug schedules are `fieldset`/`legend` checkbox groups (`client-contacts.tsx:344`); the disabled allergens group has an `aria-describedby` hint.
  - **Create card:** the same controls. `highValue` and `fragile` are always sent, like `batchTracked`; blank nullables and empty arrays are dropped, like `hazardClass`.
  - **Import help:** one sentence per new cell grammar. The column-count pin in `import-catalog.test.tsx` goes from 25 to 35.
  - **Badges:** a `flex-wrap` group, rendering nothing when empty, on:
    - pack-bench lines (`pack-dispatch.tsx:556`) and read-only pack lines (`:436`);
    - order-detail lines, kit child lines included (`outbound-orders.tsx:1051–1072`);
    - picklist stops (`outbound-waves.tsx:1076`; widen `PicklistPanel`'s prop to `SkuResponse`).
  - **Reason maps:** `skuMasterReason` (`sku-admin.ts:304`) and the edit form's hand-off list (`sku-table.tsx:1081`) gain the two codes.
  - **Fixtures:** `catalog-kits.test.ts:34` and the `sku-admin.test.ts:242` create-body pin are updated.
- **Mobile:**
  - `CatalogSku` gains **required** `fragile`, `highValue`, `maxStackLayers` and `dg` (the 1-4/1-4b precedent). `parseCatalogSnapshot` defaults them to `false`, `false`, `null` and `null`, and drops a `dg` unless `unNumber` is 4 digits and `class` is a non-empty string; anything else in `packingGroup` or `subsidiaryClasses` becomes `null` or `[]`.
  - **Pins and typed fixtures to update:** `device-store.test.ts:222, 295, 313, 547, 563, 567/583` (plus a malformed-`dg` pin beside `:585`), `returns/draft.test.ts:49`, `picking/draft.test.ts:55`, `putaway/draft.test.ts:40`, `receiving/draft.test.ts:77`, `packing/draft.test.ts:43`, `picking/variant.test.ts:27`, `receiving/draft-clients.test.ts:63`, `receiving/draft-policy.test.ts:108`, `lib/sku-resolution.test.ts:43`.
  - **`handlingNote(sku)`** (pure) returns e.g. "Fragile · High value · DG 3 (6.1) UN1230 PG II · Stacks ≤ 4", or null.
  - **Where the note shows:**
    - after both pick-header layouts, beside the bin/qty line (`app/pick.tsx:470–483`);
    - on each pack line, looking the SKU up in `snapshot.skus` by `line.skuId` at render (`PackLineDraft` is unchanged);
    - on the putaway header (`app/putaway.tsx:299`);
    - appended to the receive scan banner, `withInactiveWarning`-style (`app/receive.tsx`).
  - The note is text only: no colour-only meaning, nothing blocked, no prompt. A handheld shows the new note only after its snapshot refreshes.

**Never:**
- No enforcement: stack, high-value placement, or a DG bin rule beyond the hazard guard.
- No segregation matrix change and no use of the subsidiary classes (1-6b).
- No licences (1-6c).
- No SDS document.
- No DG on labels, manifests, e-way bills or invoices.
- No portal change.
- No handheld edit.
- No storage-class coupling.
- No backfill.
- No notes on returns receiving, transfers or counts (PENDING).

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected | Error |
|---|---|---|---|
| Food | PATCH `{foodCategory:'dairy', allergens:['milk','eggs','milk']}` | `['eggs','milk']` | N/A |
| Food cleared | stored dairy + milk; PATCH `{foodCategory:'non-food'}` with no allergens | unchanged | 400 `validation-failed` (allergens) |
| Drug | `{drugSchedules:['H','C']}` | `['C','H']` | N/A |
| DG derives | `{dgUnNumber:'un1203', dgClass:'3', dgPackingGroup:'II'}`, stored hazard `toxic` | `1203`, hazard `flammable` | N/A |
| DG mismatch | `{dgClass:'3', dgUnNumber:'1203', hazardClass:'toxic'}` or `hazardClass:null` | unchanged | 400 `dg-hazard-mismatch` |
| Class 8 | `{dgClass:'8', dgUnNumber:'1830'}`, stored hazard null, previous DG null | unchanged | 400 `dg-hazard-required` |
| Class 8 none | same + `hazardClass:null` | stored, hazard null | N/A |
| Class 8 kept | stored DG 8 + `corrosive-acid`; PATCH `{name:'x'}` | unchanged hazard | N/A |
| Mapped → unmapped | stored DG 3 + flammable; PATCH `{dgClass:'9', dgUnNumber:'3480', dgPackingGroup:null}` | hazard stays `flammable` | N/A |
| Hazard-only PATCH | stored DG 3; `{hazardClass:'gas'}` | unchanged | 400 `dg-hazard-mismatch` |
| Subsidiary | `{dgClass:'3', dgUnNumber:'1230', dgSubsidiaryClasses:['6.1','3']}` | unchanged | 400 `validation-failed` |
| Pairing | UN number without a class; PG `II` on class 2.1 | unchanged | 400 `validation-failed` |
| NOT NULL null | `{fragile:null}` / `{allergens:null}` | unchanged | 400 `validation-failed` |
| Derived blocked | a SKU binned beside an incompatible occupant gets `{dgClass:'1.1', dgUnNumber:'0004'}` | unchanged | 409 `hazard-segregation-conflict` |
| Stack | `maxStackLayers` 0 / 101 / 1 | refused / refused / stored, badge "Do not stack" | 400 `validation-failed` |
| Idempotency | same key, `allergens` reordered or `UN1203` vs `1203` | replays | N/A |
| Old create key | a pre-1-6a create body replayed under its key | replays (hash unchanged) | N/A |
| Import | `dg_un_number=UN1203; dg_class=3; hazard_class=` | hazard `flammable` | N/A |
| Import class 8 | `dg_class=8`, blank hazard / `none` | row error `dg-hazard-required` / stored, null | N/A |
| Import bad | `allergens=milk;peanut` | row error | `validation-failed` (allergens) |
| Replay | a pre-1-6a stored SKU response | `[]`, `false` and null defaults | N/A |
| Handheld | legacy snapshot; malformed `dg` | no notes; `dg` null | N/A |
| Handheld note | fragile + DG 3 (6.1) UN1230, stack 1 | pick and receive banner show "Fragile · DG 3 (6.1) UN1230 · Do not stack" | N/A |

</frozen-after-approval>

## Code Map

All backend paths are under `workspace/core/backend/wms-be/`.

- **Primitives:** `src/shared/primitives/hazard.ts:44` (`HAZARD_CLASSES`), `:144`; `storage-class.ts:48`, `:103`; `src/modules/catalog/sku-attributes.ts` (the bound pattern).
- **Schema:** `src/shared/db/schema.ts:869–912`, with the text-array precedent at `:422`. CHECK and probe precedents: `drizzle/0036_hazard_class.sql`, `drizzle/0082_sku_status.sql`.
- **DTOs** (`catalog.dto.ts`): `SkuResponse` `:168` (hazard `:305–324`), `CreateSkuDto` `:489`, `PatchSkuDto` `:666` (`:888`, `:898` the description to reword, `:907`).
- **Controller** (`catalog.controller.ts`): `:310` (create), `:546` (the 400 text), `:564` (explicit-null refusal), `:608` (edit), `:762 toSkuResponse`.
- **Commands** (`sku.command.ts`):
  - create hash `:500–525`, asserts `:577`, insert `:641`;
  - edit fields and hash `:882`, `:908`, `:923`, `:942`;
  - replay `:962`; asserts behind the replay `:1046`;
  - merge precedent `:1429`; hazard guard `:1163–1245`; update `:1566`;
  - `toSnapshot` `:1688`, `normalizeStoredSku` `:206`.
  - Hashing: `idempotency-guard.ts:56` (plain JSON); `canonicalPackaging` `:497` (the canonicalisation precedent).
- **Import** (`import.command.ts`): `OPTIONAL_COLUMNS` `:144–203`, `KNOWN_COLUMNS` `:204`, `rowError` `:1014`, `parseTracked` `:1127`, `validateRow` `:1203` (hazard cell `:1389`), `ValidRow` `:251`, insert `:642`, assembly `:1589`.
- **Device snapshot:** `catalog.facade.ts:234` (`SkuSummary`), `:536`; `inbound/receiving.dto.ts:753`; `receiving.facade.ts` (mirror); `receiving.controller.ts:237` (spreads the SKU).
- **Tests:** `test/sku-attributes.spec.ts:418–465`; `test/sku-deactivation.spec.ts:404` (the pin to copy, with the regex widened).
- **Web** (`workspace/core/frontend/wms-fe/`):
  - SKU admin: `src/lib/sku-admin.ts:24–96, 304, 360–475`; `sku-admin.test.ts:43, 242, 268`.
  - SKU table: `sku-table.tsx:211–223` (columns), `:657` (edit form), `:788–826` (PATCH build and casts), `:950` (selects), `:1062–1086` (refusals); `sku-create-card.tsx:118, 238`.
  - Import: `src/lib/catalog.ts:21–43`, `import-catalog.tsx:137`, `import-catalog.test.tsx:178`.
  - Precedents and fixtures: `client-contacts.tsx:344` (fieldset precedent), `catalog-kits.test.ts:34`.
  - Badge sites: `pack-dispatch.tsx:436, 556`; `outbound-orders.tsx:1051–1072`; `outbound-waves.tsx:1004, 1060, 1076`.
- **Mobile** (`workspace/core/mobile/wms-mobile/`):
  - `src/api.ts:1150`; `src/state/catalog-snapshot.ts:35–80`.
  - Screens: `app/pick.tsx:386, 470–483`; `app/pack.tsx:465`; `app/putaway.tsx:223, 299`; `app/receive.tsx` (the banner sites from 1-4b, `:262`, `:284`); `src/packing/draft.ts:130–152` (unchanged).
  - `docs/design/mobile/IMPLEMENTATION-GUIDE.md:150` (the optional-key alternative, not taken).

## Tasks & Acceptance

**Execution:**
- [x] `wms-be src/shared/primitives/goods-type.ts` (+ spec) -- tuples, map, canonicalisation, `assertGoodsType`, `resolveHazardClass` -- the one rule set
- [x] `wms-be drizzle/0083_sku_goods_type.sql` + schema + meta -- columns, CHECKs (the derivation backstop included), probes -- decisions 3, 5, 6
- [x] `wms-be catalog/{catalog.dto,catalog.controller,sku.command,catalog.facade}.ts`, `inbound/{receiving.dto,receiving.facade}.ts` -- fields, merge, `effectiveHazard` through guard and write, canonical hashing, replay defaults, snapshot -- decisions 7, 10
- [x] `wms-be catalog/import.command.ts` -- ten columns, cell grammar, derivation -- import parity
- [x] `wms-be test/sku-goods-type.spec.ts`, `openapi/openapi.json` -- every matrix row, the vocabulary pins, the export -- proof
- [x] `wms-fe` goods-type lib (+ tests), SKU table and create card, import help, badge sites, reason maps, fixtures, regenerated types -- decisions 1, 3, 7
- [x] `wms-mobile` api, snapshot parse, `handling-note.ts` (+ test), pick, pack, putaway and receive screens, the named pins and fixtures -- decision 1
- [x] meta `docs/design/modules/catalog.md` (goods-type section), `API-SURFACE.md`, `PENDING.md` (stack enforcement; DG on documents; class 8 none and the subsidiaries for 1-6b; explosive compatibility groups; EU allergens; returns, transfer and count notes), `docs/repos/wms-{be,fe}/README.md` -- the docs stay current

**Acceptance Criteria:**
- Given a fragile DG-3 SKU on a wave, when a picker opens its task on the handheld, then the header shows the handling note, and the web picklist stop and pack-bench line show the same badges.
- Given an import file and a single-SKU create with the same values, when both run, then the stored goods-type fields are equal, the derived hazard class included.
- Given a SKU with no goods-type data, when a handling screen renders it, then no badge or note appears; the SKU table's Handling cell shows `'—'`.

## Implementation Notes

Implemented 2026-10-20 against the baselines above; nothing committed or pushed.

- **Import chunk size (a defect the design missed).** The ten new `skus` columns pushed the catalog import's 2,000-row insert chunk past Postgres's 65,535 bind parameters (~37 columns × 2,000); `test/catalog.spec.ts`'s 5,000-row acceptance import answered 500. `INSERT_CHUNK_ROWS` is now 1,000; the rule ("a new column re-opens rows × columns") is in `IMPLEMENTATION-GUIDE.md` §3 and `modules/catalog.md`.
- **Create hash.** The goods-type keys join only when present, after `barcodes` and before the conditional `clientId` (golden in `test/sku-goods-type.spec.ts`). `hazardClass` keeps its pre-1-6a `?? null` shape, so on the create absent and explicit null hash alike; wherever both commit they leave the same class (absent with class 8 is refused, null with a mapped class is refused).
- **The pairing problem names the missing field.** A UN number without a class is refused naming `dgClass`, a class without a UN number naming `dgUnNumber`.
- **Web: the hazard key under a mapped DG class is omitted, not sent.** The server derives it (decision 7, absent → derived); the form shows the derived value disabled before saving. Class 8: the select starts on "Choose…" unless the stored value is a corrosive — or the SKU already is class 8 with none, where it starts on "none" (its stored choice). Moving INTO class 8 with "none" always sends `hazardClass: null`, even over a stored null, or the server would answer `dg-hazard-required`.
- **Web: the Handling column sits after Barcode,** not beside Hazard — two existing component pins fix the HSN → Weight · dims → Tracking → Storage → Hazard → Barcode run (11-2, 12-7), and they were kept rather than retargeted.
- **Web: order detail.** Badges render on each kit child and each plain line; a kit parent shows none (decision 9 — the SKU actually handled).
- **Mobile `dg` parse:** a `dg.unNumber` carrying the `UN` prefix is dropped (the server always strips it).

**Verification run:** wms-be `db:migrate` (0083's probes pass), `db:generate` (no changes), lint, typecheck, the full jest suite (104 suites; the one failure — the chunk size above — fixed and its suite re-run green), `openapi:export`; wms-fe `api:generate`, lint, typecheck, `bun run test` (2,126 pass), build, `check:capability-mirror`; wms-mobile typecheck, test (731 pass).

## Spec Change Log

## Review Triage Log

**Design review, 2026-10-20.** Three reviewers: backend (B1–B13), edge cases and domain (E1–E15), web and handheld (F1–F14). 42 raw findings, 30 after merging duplicates. Three needed the user (decisions 1, 3 and 5, revised the same day); the rest are patched above. Re-checked by hand: the hazard guard and the update are both gated on `fields.hazardClass !== undefined` (`sku.command.ts:1163`, `:1566`), so a DG-only PATCH would have skipped both.

- D1 high (B1, E1): the derived value would never reach the guard or the write, and explicit `null` was undefined. The `effectiveHazard` pipeline and decision 7.
- D2 high (B2): adding keys to the create hash would break every in-flight key. Hash new keys only when present (decision 10).
- D3 high (B3, E14): `??` merging would treat a clear as absent. Explicit `!== undefined` merge; matrix rows added.
- D4 med (E7): a drug can carry several schedules (C + H, H1 + NDPS). `drug_schedules text[]`.
- D5 med (E4) → user: subsidiary risks are captured now (decision 5).
- D6 med (E5) → user: class 8 takes acid, base or explicit none (decision 3).
- D7 med (E9) → user: receiving added to the handheld notes (decision 1).
- D8 med (E3, E6): a stored hazard overwritten silently, and stale after a mapped → unmapped switch. Decision 7 makes both explicit, and the web shows the change before saving.
- D9 med (B4): explicit `null` on NOT NULL fields would 500. Controller 400.
- D10 med (B5, E2, F2): raw vs normalised hashing; the UN-number DTO pattern. Decision 10.
- D11 med (B6, F1): the proposed generated-type fix is the existing bug. Keep the cast pattern.
- D12 med (B7, E11): DG/drug vs storage class undecided. Decision 8: no coupling.
- D13 med (B8): no DB backstop for the derivation. `skus_dg_hazard_derived`.
- D14 med (B9, E8): kits undecided. Decision 9.
- D15 med (E10): the stack limit never reached the floor, and its unit was undefined. In the snapshot and note; unit and "Do not stack" defined.
- D16 med (F3): no dependent-reset rules in the form. Specified.
- D17 med (F4): two reason paths. Both named.
- D18 med (F5, F6): required vs optional handheld keys, and the unnamed typed fixtures. Required; every fixture named.
- D19 med (F7): pack lines do not hold the SKU. Look it up at render.
- D20 low (B10): the vocabulary-pin regex fails on `1.1` / `H1` / `tree-nuts`. Widened.
- D21 low (B11, E12): import cell grammar and row-error codes. Specified.
- D22 low (B12): OpenAPI 400 text and `toSkuResponse`. Named.
- D23 low (B13): a matrix row lacked its UN number. Fixed.
- D24 low (E13): packing group optional. Stated as capture-only.
- D25 low (E15): `non-food` vs null, food + DG coexisting, EU allergens. Decided; EU allergens to PENDING.
- D26 low (F8): two pick-header layouts. The note goes after both.
- D27 low (F9): malformed `dg` undefined. Rule stated.
- D28 low (F10, F11): empty state; accessibility. Specified.
- D29 low (F12, F13): the create-body pin; the import help grammar. Specified.
- D30 low (F14, E11): kit child and read-only pack lines; capture-only fields shown only in the form; snapshot staleness; explosive compatibility groups. Stated, or sent to PENDING.

**Code review, 2026-10-20.** Three layers: blind hunter (H1–H11), edge-case hunter (C1–C6), verification gap (V1–V3). 20 findings, 13 after merging duplicates: 9 patched, 4 rejected (some groups merge a patched finding with a rejected one). No loopback: no finding traced to the frozen intent or to a spec gap. Re-checked by hand: the full wms-be run (104/104 suites, 2577 tests) passed with the 1,000-row insert chunk.

- C1 / H1 medium, patch: import row errors carry API wording ("or null for none", "send allergens: []"), so a user who types `null` is refused again. CSV wording, pinned.
- C3 medium, patch: the `hazard_class` cell was case-sensitive except for `none`, against the spec's case-insensitive rule. Lowercased.
- H3 medium, patch: the `skus_dg_hazard_derived` arms (a hand copy of `DG_HAZARD_MAP`) were probed only for classes 3 and 8. An e2e walks every mapped class against the DB.
- V2 medium, patch: the snapshot's `dg` was tested only at the facade, below the controller copy. A route-level assertion was added.
- H9 / V1 medium, patch: the create card reset a chosen hazard on a free → free DG switch (9 → 4.1), creating an unclassified SKU; the reset was untested at form level. It now keeps the choice, with form tests on both forms.
- H6 / V3 medium, patch: the web copies of the map, the no-packing-group list and the vocabularies were unpinned. Exact-equality tests.
- H10 low, patch (wording): `{dgClass:null}` with a stored UN number said "dgClass is missing". The detail now names what to clear.
- H5 low, patch (comment): the stale "12 sku columns" chunk comment.
- C2 low, patch: folded into C1 (the allergen and packing-group CSV wording).
- C4 / H2 low, reject: create hashes `hazardClass` as `?? null` (pre-1-6a), so absent and null share a hash; explicit null on nullable goods keys hashes apart from absent. Both need a client to resend one key with a semantically different body. Changing the hash for hazard would break pre-1-6a keys (decision 10).
- C5 low, reject: the receive note shows on the scan banner, as specced; later commit and quantity banners replace it.
- C6 / H7 low, reject: the web badge ("DG 3 (6.1) · UN1230 · PG II") and the handheld note ("DG 3 (6.1) UN1230 PG II") differ in separators. Both strings are the spec's own (Boundaries web bullet; matrix "Handheld note" row).
- H4 low, reject: OpenAPI `maxItems: 2` vs the DTO's larger `ArrayMaxSize` (duplicates fold first); the command enforces 2. Negligible.
- H8 low, reject: a malformed `dg` is dropped on the handheld. The DB CHECKs make a malformed server value unreachable.
- H11 low, reject: 0083 adds its CHECKs as separate statements under `ACCESS EXCLUSIVE`. `skus` is small (the 1-4b H9 reasoning).

## Design Notes

- **Why derive the hazard class.** Segregation (12-2) reads only `hazard_class`. A class 3 SKU without one would never be segregated, so the DG class feeds that one column and a CHECK keeps the two consistent.
- **Why stack limits are counted in layers.** "Stack at most 4 high" is how clients state it, and it stays true whatever the unit's height. Enforcement can multiply by the unit's height later.
- **Why the effective hazard is held outside `fields`.** `fields` is hashed. Folding a derived value into it would make the same request hash differently depending on stored state.

## Verification

**Commands:**
- `cd workspace/core/backend/wms-be && bun run db:generate` -- expected: no changes
- `bun run lint && bun run typecheck && bun run test` (wms-be; one jest run at a time) -- expected: green
- `cd workspace/core/frontend/wms-fe && bun run api:generate && bun run lint && bun run typecheck && bun run test` -- expected: green
- `cd workspace/core/mobile/wms-mobile && bun run typecheck && bun run test` -- expected: green
