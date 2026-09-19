---
title: 'Story 10.5: web fractional quantity surfaces — decimals render, inputs accept, precision comes from the SKU'
type: 'feature'
created: '2026-09-19'
status: 'in-progress'
route: 'dispatch'
review_loop_iteration: 0
baseline_commit: '68c18f83d77c71d17f824532392e664da4533526' # wms-fe main (post 10-2)
context:
  - '_bmad-output/implementation-artifacts/epic-10-context.md'
  - 'docs/design/frontend/SYSTEM-DESIGN.md'
  - 'docs/design/frontend/IMPLEMENTATION-GUIDE.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** the backend has been fractional since 10-1/10-2 (milli-units, per-UoM declared precision, server refuses too-fine values), but every web surface still assumes integers: order lines refuse `2.5` (`parseDraftLines` regex `^\d+$`, `step={1}`), reorder inputs coerce with bare `Number()` and no validation, quantity labels interpolate raw numbers with no precision-aware formatting, and the client cannot know a SKU's precision at all — `SkuResponse` does not carry `uomPrecision` (only the mobile device snapshot does). The web contract is "never assume a quantity is an integer; render at the UoM's declared precision; align decimals; never round on input" — none of it is met.

**Approach:** one backend field makes precision available everywhere — `SkuResponse` gains `uomPrecision` (backend derives it from `uom`, as the device snapshot already does); regenerate the wms-fe client (also picking up 10-4's `actual_weight`); then a single `formatQuantity` helper and the per-surface widening: all quantity labels render at declared precision with the unit named per row, and all quantity inputs accept decimals with `step` set from the SKU's precision, letting the server remain the refusal authority.

</frozen-after-approval>

## Boundaries & Constraints

**Always:**
- Render a quantity at its UoM's **declared** precision, never storage precision; align on the decimal point (`tabular-nums`), and name the unit per row in any column that mixes units.
- Never round, truncate or precision-clamp on input — the backend's precision refusal (naming unit and precision) is the authority; client validators only decide *shape* (a decimal literal, within the magnitude cap).
- Client types come from regeneration only; new backend fields land in wms-be first, then `bun run api:generate`.

**Never:**
- Never hand-edit `src/lib/api/generated/` (CI diff guard).
- Never mirror a `UOM_PRECISION` table client-side or infer precision from the unit string in the web — the field comes from the server.
- No new surfaces (inventory/moves/reports pages stay placeholders), no mobile changes, no ledger/KPI surfaces (they do not exist yet).

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| 3-dp display | kg SKU, server sends `2.5` | renders `2.500 kg` (declared precision, unit named) | N/A |
| 0-dp display | each SKU, server sends `3000` | renders `3,000 each` — no `.000` suffix on 0-precision units | N/A |
| Decimal order line | kg SKU, operator types `2.5` | accepted; line commits; labels render `2.500` | server precision refusal renders via `ApiProblem` branch, copy untouched |
| Too-fine order line | kg SKU, operator types `2.5004` | client passes it through; server refuses naming unit + precision | refusal surfaces under the error contract |
| Reorder inputs | kg SKU reorder qty `1.25` | accepted (PATCH); too-fine → server refusal, shown on the row | server refusal surfaces |
| Import report | row error for a too-fine reorder_qty | `error.detail` renders verbatim (already generic) | N/A |

## Code Map

**wms-be (one additive field):**
- `src/modules/catalog/catalog.dto.ts:69-127` — `SkuResponse` gains `uomPrecision` (integer, derived — never an input); doc sentence mirrors the mobile snapshot's.
- `src/modules/catalog/sku.command.ts:376-410` — `toSnapshot` is the module's ONE SKU read shape (every list/get/patch response routes through it): add `uomPrecision: uomPrecision(row.uom)` there (function already imported in this module) — the mobile snapshot mapping at `catalog.facade.ts:226` already proves the pattern.
- `test/uom-precision.spec.ts` (or catalog spec) — pin `uom_precision` present and equal to the unit's places on list/get/patch payloads.

**wms-fe:**
- `bun run api:generate` — regenerates the client against merged wms-be main (picks up `uom_precision` and 10-4's `actual_weight`; the stale "positive integer" doc remnant on quantity fields disappears from the source).
- `src/lib/format-quantity.ts` (NEW) — `formatQuantity(qty: number, precision: number): string` (`toFixed(precision)` + `toLocaleString` grouping of the integer part) and `quantityInputLabel(precision)`; unit tests pin `2.5/3 → '2.500'`, `3000/0 → '3,000'`, no `.000` on 0-precision.
- `src/lib/outbound-orders.ts:118-165,341-377` — `orderSummary`/`lineQuantityLabel` take the SKU's precision and unit; `parseDraftLines` regex widened from `^\d+$` to decimal-literal acceptance (leading digits optional per line? no — still `≥ 1` magnitude server-side; keep `MAX_LINE_QUANTITY`), error copy updated to "decimal at the SKU's unit precision" without client precision-clamping.
- `src/components/outbound/outbound-orders.tsx:203-217` — line quantity input `step={precisionStep}` / `min` per SKU precision; error branch unchanged.
- `src/lib/outbound-waves.ts:339-405` + `src/components/outbound/outbound-waves.tsx:1020` — `waveSummary`/`pickLineQuantityLabel` format through the helper (precision + unit per line).
- `src/lib/over-receipt.ts:13-14` + `src/components/inbound/inbound-cards.tsx:174-180,516-527` + `src/components/conflicts/over-receipt-queue.tsx:200-206` — PO line rows, GRN Units column, QC-hold picker, over-receipt queue all format through the helper; the GRN `totalUnits - appliedUnits` arithmetic stays on raw numbers (format only at render).
- `src/components/settings/sku-table.tsx:194-195,249-271` — reorder point/qty inputs: step from the SKU's precision, decimal-literal validation (no `Number()` bare coercion on the way in), non-negative check kept.
- `src/components/settings/import-catalog.tsx:152-231` — no change expected (detail renders verbatim); verify a precision refusal row renders.

**Patterns:** hook exemplar `src/lib/use-inbound.ts`; wrappers only in `src/lib/api/client.ts` (no new endpoints needed); exemplar data components `inbound-cards.tsx`/`outbound-orders.tsx`; DataTable `numeric` column already right-aligns (`data-table.tsx:14,72,94`).

## Tasks & Acceptance

**Execution:**
- [x] `wms-be src/modules/catalog/catalog.dto.ts` + `sku.command.ts` -- add `uomPrecision` to `SkuResponse` and derive it in `toSnapshot` -- the web's precision source, per the guide's preferred option
- [x] `wms-be` test -- pin the field on list/get/patch payloads -- the contract is tested, not asserted
- [x] `wms-fe` -- after the wms-be leg: `bun run openapi:export` in wms-be (updates its checked-in `openapi/openapi.json`), then in wms-fe `bun run api:generate` and commit the regenerated client + the BE export commit precedes it -- generated types are the only source; the export lives in the wms-be branch so CI's diff guard passes before the FE PR opens
- [x] `wms-fe src/lib/format-quantity.ts` (NEW) + unit test -- one formatting statement, not per-surface copies
- [x] `wms-fe src/lib/outbound-orders.ts` + `src/components/outbound/outbound-orders.tsx` -- decimal labels + decimal line input with per-SKU step; widen `parseDraftLines` in place
- [x] `wms-fe src/lib/outbound-waves.ts` + `outbound-waves.tsx` -- labels through the helper
- [x] `wms-fe src/lib/over-receipt.ts` + `inbound-cards.tsx` + `over-receipt-queue.tsx` -- PO/GRN/QC/over-receipt labels through the helper
- [x] `wms-fe src/components/settings/sku-table.tsx` -- reorder inputs accept decimals, step per precision, server-refusal branch
- [x] `wms-fe import-catalog.tsx` verification + unit tests for the widened `parseDraftLines` arms

**Acceptance Criteria:**
- Given a kg SKU ordered at `2.5`, when the order is created from the web, then the line, wave and order summaries render `2.500 kg` — and a too-fine edit (`2.5004`) surfaces the server's refusal naming the unit and precision.
- Given an each-counted SKU, when any quantity renders, then no `.000` suffix appears and grouping applies to the integer part.
- Given a mixed-precision SKU list, when a column mixes units, then each row names its own unit.
- Given reorder point/qty on a 3-dp SKU, when the ops manager saves `1.25`, the PATCH succeeds; `1.2504` is refused by the server and the row shows the refusal.
- Given the generated client, then no hand-edited generated file exists and CI's regeneration diff is clean.

## Implementation Notes

- **Precision source (decided, once):** backend adds `uom_precision` to `SkuResponse` — the guide's preferred option; the hand-mirrored `UOM_PRECISION` table is rejected (a second statement of a server rule). All surfaces take precision from the SKU payload; no surface infers it from the unit string.
- **No client-side precision vocabulary.** The client validates *shape* (a decimal literal, within the magnitude cap) and defers precision refusals to the server — its refusal text already names unit and precision byte-identically across HTTP and CSV (story 10-4).
- **Format at render only.** Display arithmetic (GRN pending units, wave shortfall totals) runs on raw numbers; `toFixed(precision)` at render absorbs float dust because every value is already at-declared-precision server-side — this is why the helper takes precision, not storage units.
- **Integer-clean display sites stay untouched:** waves priority/cap, bin capacity inputs, KPI tiles (placeholders) — counts are counts (the guide's whole-unit cases).

**Progress (2026-09-19, implementation session):** both legs implemented and committed locally (no push, no PRs). wms-be `556cdae` (SkuResponse.uomPrecision, derived in `toSnapshot`, pinned on list/patch payloads + the OpenAPI schema) and `22ce4f2` (the stale "positive integer" quantity descriptions in the putaway and over-receipt DTOs left the source — the regeneration claim in the Intent held only after this; descriptions only, validators untouched). wms-fe `20d37b8` (regenerated client; `format-quantity.ts`; orders/waves/inbound/conflicts/settings surfaces; widened `parseDraftLines` with the ≥1 magnitude floor kept). Verification: wms-be test 585/585, typecheck/lint green, `db:generate` emits nothing; wms-fe test 259/259, typecheck/lint/build green, `api:generate` idempotent, capability mirror matches. Two deltas from the Code Map worth knowing: the GRN **Units** column stays a raw cross-line aggregate — `GoodsReceiptEntryDto` carries no per-row unit to name — and the wave/order totals sentences format at a shared unit only when every line resolves to the same (uom, precision), keeping the raw unit-agnostic fallback otherwise; mixed-unit totals were already a raw unit-agnostic sum. Manual stack checks (order 2.5 → `2.500 kg`, `2.5004` refusal copy on screen) were not run — no local stack exercised in this session.

**Fix round (2026-09-19, after diff review):** wms-fe `b4d1a63`, two items. (a) The `parseDraftLines` magnitude floor above was wrong — the backend order-line floor is `@Min(0.001)` (`outbound.dto.ts:63`), not 1, so 0.5 kg is accepted server-side and the parser's `< 1` floor refused a valid body, deciding more than shape. The floor now refuses only `<= 0` (zero is backend-refused too, so "nothing is sent that the backend would only 400" still holds); copy reads "Every quantity is a decimal greater than zero, at the SKU's unit precision."; tests re-pinned (0.5 accepted, 0 refused, 0.0004/2.5004 pass through). (b) The import report's per-row error table gains a covering component test: `ImportResult` is exported and pinned to render `error.detail` VERBATIM (string equality, not containment) for a row carrying the backend's `precisionRefusalDetail` text, alongside rowNumber, code and the null-skuCode placeholder. Post-fix verification: wms-fe 263/263 tests, typecheck, lint and build all green. The GRN **Units** deviation recorded above stands as deliberate, not an oversight: `GoodsReceiptEntryDto` carries no per-row unit, so a per-row named unit there would be fabricated.

**Step-03 verification (2026-09-19, main agent):** both diffs read in full against Tasks & Acceptance — every task above is genuinely done in the commits, not just reported. The fix-round delta (`b4d1a63`) was re-read after commit: the floor now refuses only `<= 0` with the `@Min(0.001)` backend floor cited in the comment, and `import-catalog.test.tsx` pins `error.detail` by string equality. Matrix test audit: all six rows are covered — 3-dp display (`formatQuantity` + label tests), 0-dp display (`3000/0 → '3,000'`), decimal order line (2.5 and 0.5 accepted pins), too-fine pass-through (0.0004/2.5004 + unchanged `ApiProblem` branch), reorder inputs (`parseQuantityInput` tests + per-precision step), import report (verbatim-detail component test). One correction to the implementation agent's report: it described a "pre-existing minimum: 1 on placed quantity" as still refusing sub-1 placements — the request validator is `@Min(0.001)` (`putaway.dto.ts:53`); the `minimum: 1` it saw is `ApiProperty` schema metadata on the *response* DTO (`PutawayPlacementDto.qty`), which is stale documentation, not a gate. Tracked as a review finding.

## Verification

**Commands:**
- wms-be: `bun run test` / `bun run typecheck` / `bun run lint` -- green; no migration emitted (`bun run db:generate` emits nothing)
- wms-be: `bun run openapi:export` then regenerate & commit in wms-fe -- `git diff --exit-code` clean on regenerated files
- wms-fe: `bun run test` / `bun run typecheck` / `bun run lint` / `bun run build` -- green

**Manual checks:**
- With a local stack: create a kg SKU, order 2.5, verify order/wave/PO labels render `2.500 kg`; enter `2.5004` and see the server's precision refusal in the order form and the reorder form.