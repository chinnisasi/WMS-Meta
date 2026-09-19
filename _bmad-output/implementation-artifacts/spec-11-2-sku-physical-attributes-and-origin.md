---
title: 'SKU physical attributes and origin'
type: 'feature'
created: '2026-09-19'
status: 'in-progress'
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
- [ ] `wms-be/src/shared/db/schema.ts` + `drizzle/0031_sku_physical_attributes.sql` -- 5 additive columns, hand-appended CHECKs, `db:generate` + rename + snapshot commit -- the model's spine
- [ ] `wms-be/src/modules/catalog/sku-attributes.ts` (NEW) -- caps, regex, `assertSkuAttributes` -- one validator, two callers
- [ ] `wms-be/src/modules/catalog/sku.command.ts` -- edit command fields + behind-replay validation + snapshot echo -- the write boundary
- [ ] `wms-be/src/modules/catalog/catalog.dto.ts` -- DTO mirrors + response fields -- the wire contract
- [ ] `wms-be/src/modules/catalog/import.command.ts` -- 5 new optional columns + row parsing -- the closed-header contract forces this
- [ ] `wms-be/test/sku-attributes.spec.ts` (NEW) + `catalog.spec.ts` seeds -- I/O matrix incl. no-break replay -- the proof
- [ ] `wms-be` -- re-export `openapi.json` -- drift guard
- [ ] `wms-fe/src/lib/api/generated/` -- `bun run api:generate` -- consume the contract
- [ ] `wms-fe/src/components/settings/sku-table.tsx` -- edit-form fields + table column -- the user enters the attributes
- [ ] meta `docs/` -- module doc `catalog.md`, API-SURFACE rows, `PENDING.md` (4-6d inputs note), repo READMEs -- keep the docs true

**Acceptance Criteria:**
- Given a SKU edited with valid attributes, then the edit response and the SKU list echo them field-for-field, and a pre-11.2 row reads `null`.
- Given an edit or import row with a badly-shaped attribute (zero, negative, over-cap, fractional, wrong country shape), then the API or import run refuses it by name, and nothing partial is written.
- Given an in-flight idempotency key minted before this story, then an identical PATCH still replays 200.
- Given the openapi export and the FE generated client, then both regenerate with zero drift-guard failures.

## Implementation Notes

## Spec Change Log

## Review Triage Log

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