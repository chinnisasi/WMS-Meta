---
title: 'SKU physical attributes and origin'
type: 'feature'
created: '2026-09-19'
status: 'in-review'
route: 'dispatch'
review_loop_iteration: 0
baseline_commit: 'wms-be 478df1f / wms-fe 9bd46eb'
context:
  - '_bmad-output/implementation-artifacts/epic-11-context.md'
  - 'docs/design/SYSTEM-DESIGN.md'
  - 'docs/design/IMPLEMENTATION-GUIDE.md'
  - 'docs/design/modules/catalog.md'
  - 'docs/design/frontend/SYSTEM-DESIGN.md'
  - 'docs/design/frontend/IMPLEMENTATION-GUIDE.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** A SKU carries no physical attributes anywhere — no weight, no dimensions, no country of origin — so nothing can rate a parcel, print a label, or check whether stock fits a bin (FR-36; the second hard input behind 4-6d and the direct input to 11-5).

**Approach:** Five nullable catalog columns on `skus` — `weight_grams`, `length_mm`, `width_mm`, `height_mm` (positive integers, capped), `country_of_origin` (ISO 3166-1 alpha-2) — validated in the edit command behind its replay lookup and in the import row parser, echoed through the SKU API, editable in the existing web SKU edit form, and importable as new optional CSV columns. Mobile needs no change.

### Decisions (human-readable record of calls taken in planning)

- **Attributes are optional, never required at create.** Unlike 11-1's addresses, SKU creation is import-only with an existing corpus of import files; forcing weight would break every import in flight. A SKU without weight/dims is simply unrateable — 4-6d refuses rating for it and names the gap; 11-5 skips capacity checks for it. No backfill.
- **Integer storage, WYSIWYG everywhere:** weight in **grams**, dimensions in **millimetres** — the `handling_units.weightGrams` precedent (integer grams + named cap), extended to millimetres. No decimals, no `numeric`, no conversion layer: CSV columns, API fields and FE inputs all speak grams and millimetres. Carrier adapters (4-6d) convert at their own edge.
- **Country of origin is ISO 3166-1 alpha-2** uppercase (`/^[A-Z]{2}$/`, e.g. `IN`, `CN`) — the import-documentation standard. India-only system ≠ India-only origin.

## Boundaries & Constraints

**Always:**
- When present, `weightGrams` is a positive whole number ≤ 1,000,000 (1 tonne — the `MAX_HANDLING_UNIT_WEIGHT_GRAMS` precedent) and each dimension is a positive whole number of millimetres ≤ 10,000; `countryOfOrigin` matches `/^[A-Z]{2}$/`.
- Attribute validation lives in the **command** behind the replay lookup (the 10.2 rule) and in the import row parser; DTOs mirror the same bounds.
- PATCH semantics follow the `hsn` precedent: field **absent** = unchanged, `null` = cleared; unset attributes read back `null`.

**Never:**
- No catch-weight conflation — `weightGrams` is the static catalog weight for rating/labels; Epic 10's per-handling-unit actual weight stays separate (AD).
- No decimals for physical measures anywhere (paise/grams/milli-units philosophy).
- No device catalog snapshot change (`SkuSummary` stays as-is — weight is not a scan-time concern); no mobile changes; no new error codes (400 `validation-failed`).
- No SKU create command (creation stays import-only per planning) and no rate/label behavior (that is 4-6d).

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| PATCH sets attributes | `weightGrams: 500, lengthMm: 200, widthMm: 150, heightMm: 100, countryOfOrigin: "IN"` | 200; echoed in edit response and list; `catalog.sku_edited` emitted as before | N/A |
| Weight out of range | `weightGrams: 0`, `-5`, or `1000001` | 400 `validation-failed` naming `weightGrams` | edit command, 400 |
| Non-integer dimension | `lengthMm: 12.5` | 400 naming `lengthMm` (whole millimetres only) | edit command, 400 |
| Bad country | `countryOfOrigin: "in"` or `"IND"` | 400 naming `countryOfOrigin` (two uppercase letters) | edit command, 400 |
| Absent vs null | PATCH omitting a field leaves it; `weightGrams: null` clears it | Cleared reads back `null` | N/A |
| Empty patch | no field present (attributes count as fields) | 400 `empty-sku-edit` (existing refusal, message now names the new fields) | 400 |
| Import with new columns | CSV with `weight_grams,length_mm,width_mm,height_mm,country_of_origin` | SKUs created with attributes; blank cell → `null`; bad value = per-row error (fix mode) | row error |
| Import, unknown column | CSV header with a column outside the closed set (still) | 400 file-unreadable — the closed-header contract is unchanged | 400 |
| Pre-11.2 edit key replay | idempotency key minted before this story, same body | **200 replay** — absent optional keys are dropped by the hash, so the hash shape is unchanged (no 10.2-style break) | N/A |
| Pre-11.2 SKU read | SKU row predating the migration | Attributes read `null` in list and edit responses | N/A |

</frozen-after-approval>

## Code Map

- `wms-be/src/shared/db/schema.ts:287-326` -- `skus` — add 5 nullable columns: `weightGrams`/`lengthMm`/`widthMm`/`heightMm` (integer), `countryOfOrigin` (text); comment the caps
- `wms-be/drizzle/` + `meta/_journal.json` -- migration `0031_sku_physical_attributes.sql` — additive columns + **hand-appended CHECKs** (`> 0 AND <= cap`, country regex), the 0006-0010/0019/0021/0025/0028 pattern declared only in migration SQL
- `wms-be/src/modules/catalog/sku-attributes.ts` (NEW) -- `MAX_SKU_WEIGHT_GRAMS = 1_000_000`, `MAX_SKU_DIMENSION_MM = 10_000`, `ORIGIN_RE`, `assertSkuAttributes(fields)` (whole-number/ceiling/country, throws 400) — one validator both the edit command and the import parser call
- `wms-be/src/modules/catalog/sku.command.ts:158-200` -- `EditSkuCommand` + `fields` gains the 5 optional fields (empty-patch refusal message lists them); `assertSkuAttributes` behind the replay lookup (10.2 rule); update snapshot; the spread-hash means **no replay break** (absent keys drop)
- `wms-be/src/modules/catalog/catalog.dto.ts` -- `PatchSkuDto` gains the 5 optional fields (`@IsInt @Min @Max` / `@Matches`), `SkuResponse` gains them nullable
- `wms-be/src/modules/catalog/import.command.ts:86-100` -- OPTIONAL_COLUMNS gains `weight_grams, length_mm, width_mm, height_mm, country_of_origin`; row parser maps them via the shared validator, blank → null, bad value → per-row error
- `wms-be/test/sku-attributes.spec.ts` (NEW) -- the I/O matrix incl. the no-break replay pin (legacy-key replay → 200)
- `wms-fe/src/lib/api/generated/` -- `bun run api:generate`; `PatchSkuDto`/`SkuResponse` grow the fields
- `wms-fe/src/components/settings/sku-table.tsx:156-335` -- `SkuEditForm` gains gram/millimetre inputs (labeled "(g)" / "(mm)", `parseQuantityInput` grammar) + origin input; table gains a weight·dims summary column between HSN and Tracking
- `wms-fe` tests -- pin the new fields in a new `sku-table.test.tsx` (none exists today) + `client.test.ts` PATCH-body case

## Tasks & Acceptance

**Execution:**
- [x] `wms-be/src/shared/db/schema.ts` + `drizzle/0031_sku_physical_attributes.sql` -- 5 additive columns, hand-appended CHECKs, `db:generate` + rename + snapshot commit -- the model's spine
- [x] `wms-be/src/modules/catalog/sku-attributes.ts` (NEW) -- caps, regex, `assertSkuAttributes` -- one validator, two callers
- [x] `wms-be/src/modules/catalog/sku.command.ts` -- edit command fields + behind-replay validation + snapshot echo -- the write boundary
- [x] `wms-be/src/modules/catalog/catalog.dto.ts` -- DTO mirrors + response fields -- the wire contract
- [x] `wms-be/src/modules/catalog/import.command.ts` -- 5 new optional columns + row parsing -- the closed-header contract forces this
- [x] `wms-be/test/sku-attributes.spec.ts` (NEW) + `catalog.spec.ts` seeds -- I/O matrix incl. no-break replay -- the proof
- [x] `wms-be` -- re-export `openapi.json` -- drift guard
- [x] `wms-fe/src/lib/api/generated/` -- `bun run api:generate` -- consume the contract
- [x] `wms-fe/src/components/settings/sku-table.tsx` -- edit-form fields + table column -- the user enters the attributes
- [x] meta `docs/` -- module doc `catalog.md`, API-SURFACE rows, `PENDING.md` (4-6d inputs note), repo READMEs -- keep the docs true

**Acceptance Criteria:**
- Given a SKU edited with valid attributes, then the edit response and the SKU list echo them field-for-field, and a pre-11.2 row reads `null`.
- Given an edit or import row with a badly-shaped attribute (zero, negative, over-cap, fractional, wrong country shape), then the API or import run refuses it by name, and nothing partial is written.
- Given an in-flight idempotency key minted before this story, then an identical PATCH still replays 200.
- Given the openapi export and the FE generated client, then both regenerate with zero drift-guard failures.

## Implementation Notes

## Implementation Notes (2026-09-19, implementation session)

- **All five tasks in the Code Map landed as specced; one task needed less than written:** `catalog.spec.ts` needed NO seed updates — the new import columns are optional, so every existing import fixture parses exactly as before; the matrix lives entirely in the new `test/sku-attributes.spec.ts` (11 tests).
- **The no-break replay claim is pinned, not just asserted:** `a pre-11.2 edit key … replays 200` mints a key with a body carrying zero attribute keys, replays it, and asserts the 200 re-serves the snapshot — a hash break would answer 422. The spread-hash reasoning (`JSON.stringify` drops `undefined` keys) is documented at the hash site in `sku.command.ts`.
- **DB CHECKs are probed directly:** raw-SQL inserts prove a zero weight and a lowercase origin are unstorable by ANY path, and that NULL stays legal — the 0028-pattern backstop works.
- **Controller edge convention:** `countryOfOrigin` follows `hsn` — `''` maps to `null` at the controller, and the DTO's pattern admits `''` so clearing from a web form works. The command re-checks the regex behind the replay.
- **Import row errors name the API field, not the CSV column, for value/range failures** (they render through `assertSkuAttributes`); only spelling failures (minus sign, non-numeric) name the CSV column — both verified by the import test's three failed rows and the fix-mode re-submit.
- **FE:** `attributeInput` keeps the form's established shape-vs-value split — blank clears (null), a malformed spelling refuses client-side naming the field and unit, a well-formed but out-of-bounds value is SENT so the server's named refusal renders (the same choice the reorder fields make; precision refusals stay the server's). `skuPhysicalLabel` never fabricates a `200×—×100` composite — partial axes render individually. New `sku-table.test.tsx` (5 tests) drives the real fetch wrapper through a stub.
- **Runner trap (recorded):** `bun test test/sku-attributes.spec.ts` (bun's own runner) hangs — it bypasses jest's `globalSetup` (template DB). Backend suites must run via `bun run test` / `npx jest`.

## Spec Change Log

## Review Triage Log

**Review of the implemented diff (step-04, iteration 0) — three layers: blind-hunter (10), edge-case-hunter (3), verification-gap (1 headline + 2 notes). 15 findings, verdicts rendered after verification at cited locations.**

| # | Finding | Verdict | Evidence / route |
|---|---------|---------|------------------|
| 1 | Missing EOF newlines on all new files | low | Confirmed: `0031_sku_physical_attributes.sql`, `sku-attributes.ts`, `import.command.ts`, `test/sku-attributes.spec.ts`, `sku-attributes.ts`/`.test.ts` (FE), `sku-table.test.tsx` all end without a newline. Direct correction → **patch** |
| 2 | `catalog.md:198` says fraction/over-cap import refusal "names the CSV column" | low | Confirmed wrong: `parseAttributeNumber` (`import.command.ts:966`) admits `^\d+(\.\d+)?$`, so fractions/over-cap reach `assertSkuAttributes` which names the API field — pinned by the import test (`byRow.get(3).detail` contains `widthMm`). Only minus/non-numeric names the CSV column. → **patch** (docs) |
| 3 | `wms-be/README.md:45` carries the same muddled wording | low | Same defect as #2 in the interface contract. → **patch** (docs) |
| 4 | No API test for dimension over-cap | low | Confirmed: only weight bounds and fractional `lengthMm: 12.5` are probed; nothing sends a dimension > 10,000. Direct test addition → **patch** |
| 5 | No API test for dimension floor | low | Confirmed: 0/negative tested only for `weightGrams`. Same root cause as #4 → **patch** |
| 6 | Controller `countryOfOrigin: ''` → null mapping untested | low | Pre-verified by the verification-gap layer (grep: no `''` arm in `test/`; the `hsn` template's `''` arm IS pinned at `catalog.spec.ts:603`). → **patch** |
| 7 | FE `attributeInput` onRejected branch untested | low | Confirmed: `sku-table.test.tsx` has 5 tests, none drives the malformed-spelling client refusal. → **patch** |
| 8 | Inconsistent cell accessors in `validateRow` (`get()` vs raw `v[...]`) | false | `parseAttributeNumber` trims internally (`(raw ?? '').trim()`, `import.command.ts:966`), so both access paths are normalized — no bad outcome occurs at the cited location |
| 9 | FE Origin input neither transforms nor hints case | false | By design: the frozen matrix pins server-side refusal for bad country ("400 naming `countryOfOrigin`"), and that refusal renders in the form; `maxLength={2}` does not block any designed path |
| 10 | Operator-facing vocabulary mismatch (`width_mm` vs `widthMm` for one cell) | false | Deliberate, recorded split (Implementation Notes: shape errors name the CSV column, value errors name the API field), pinned by test; changing it is a design renegotiation, not a patch |
| 11 | Pre-11.2 stored replay snapshot omits the five `SkuResponse` fields | false | Replay serves the stored pre-edit response verbatim — that is the idempotency contract; the only current consumer (`sku-table.tsx` `onSaved`) reads `updated.code` and reloads live rows |
| 12 | DTO mirrors precede the replay lookup (tightening would 400 a committed op) | false | Established pattern for every DTO-mirrored field (`gst_rate`, `hsn`); only live if a bound is tightened, and the stated convention is widen-only (0023/0024 precedent) |
| 13 | Native min/max/step blocks submit before designed refusals render | medium | Confirmed real: the four attribute inputs use `type="number"` with `min={1} max={1000000} step={1}` (`sku-table.tsx:327-369`) and the form has no `noValidate` — while the reorder fields carry an explicit comment (`:393`): "The input constrains NOTHING beyond non-negativity… `step="any"`". Over-cap/fractional entries hit generic native validation copy; the designed named refusals are unreachable through the form. Same site as #14 → **patch** |
| 14 | `type="number"` paste sanitization silently empties a field → read as clear | low | Same root cause as #13 (constrained number input instead of the form's precedent — 11-1 pincode uses `type="text" inputMode="numeric"`): a paste with a unit suffix sanitizes to `''`, which `attributeInput` maps to null → stored value cleared on save. → **patch** (grouped with #13) |
| 15 | Migration re-run against an already-migrated DB | false | The drizzle journal is the re-run guard for every migration in the repo (uniform pattern across all 31); a manually-lost journal row is not a reachable program state |

**Routing:** no intent_gap, no bad_spec, no defer. Six patch groups: EOF newlines; docs wording (#2+#3); FE input semantics (#13+#14); test gaps (#4+#5 dimension bounds, #6 `''` arm, #7 FE rejection branch).

## Design Notes

- **Why integers, not milli-units:** quantity milli-units exist because quantities accumulate arithmetically in the ledger. Weight/dims are read-only physical facts consumed by rating and capacity — the closer precedent is `handling_units.weightGrams` (10.3): plain integer, named cap, CHECKs in migration SQL. Millimetres keep the same honesty for dimensions; 1 mm granularity is finer than any carrier needs.
- **Why no hash break:** `SkuCommand.edit()` hashes `{tenantId, skuId, ...fields}` where every new field is optional — a pre-11.2 body leaves them `undefined`, and `JSON.stringify` drops `undefined` keys, so old hashes are reproduced exactly. Contrast 10.2, where the hashed *representation* changed (milli→base) and the break was accepted and pinned. Nothing is converted here, so there is nothing to break.
- **`hsn` is the semantic template:** nullable catalog text, PATCH absent = unchanged / `null` = cleared, read back `null` when unset. The attributes follow it exactly.
- **CHECKs, unlike 11-1:** the catalog module's own precedent (0028) declares integer-range CHECKs in migration SQL; 11-1 rejected them only because its frozen boundary was deliberately command-side. Here the catalog pattern applies.

## Verification

**Commands:**
- `wms-be`: `bun run db:migrate && bun run db:verify` -- expected: migrations apply, round-trip proves schema↔migrations match
- `wms-be`: `npx jest` -- expected: all suites green incl. the new `sku-attributes` suite
- `wms-be`: `npx tsc --noEmit && npx eslint .` -- expected: clean
- `wms-be`: `bun run openapi:export && git diff --exit-code openapi/` -- expected: only the intended contract additions
- `wms-fe`: `bun run api:generate && git diff --exit-code src/lib/api/generated` + `bun run test`, `bun run typecheck`, `bun run lint`, `bun run build` -- expected: green

**Manual checks (if no CLI):**
- Settings → SKU edit shows the new fields with (g)/(mm) labels; the table row shows the weight·dims summary.