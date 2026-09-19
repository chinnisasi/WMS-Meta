---
title: 'Story 10.5: web fractional quantity surfaces — decimals render, inputs accept, precision comes from the SKU'
type: 'feature'
created: '2026-09-19'
status: 'ready-for-dev'
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
- [ ] `wms-be src/modules/catalog/catalog.dto.ts` + `sku.command.ts` -- add `uomPrecision` to `SkuResponse` and derive it in `toSnapshot` -- the web's precision source, per the guide's preferred option
- [ ] `wms-be` test -- pin the field on list/get/patch payloads -- the contract is tested, not asserted
- [ ] `wms-fe` -- merge wms-be main, `bun run api:generate`, commit regenerated client -- generated types are the only source
- [ ] `wms-fe src/lib/format-quantity.ts` (NEW) + unit test -- one formatting statement, not per-surface copies
- [ ] `wms-fe src/lib/outbound-orders.ts` + `src/components/outbound/outbound-orders.tsx` -- decimal labels + decimal line input with per-SKU step; widen `parseDraftLines` in place
- [ ] `wms-fe src/lib/outbound-waves.ts` + `outbound-waves.tsx` -- labels through the helper
- [ ] `wms-fe src/lib/over-receipt.ts` + `inbound-cards.tsx` + `over-receipt-queue.tsx` -- PO/GRN/QC/over-receipt labels through the helper
- [ ] `wms-fe src/components/settings/sku-table.tsx` -- reorder inputs accept decimals, step per precision, server-refusal branch
- [ ] `wms-fe import-catalog.tsx` verification + unit tests for the widened `parseDraftLines` arms

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

## Verification

**Commands:**
- wms-be: `bun run test` / `bun run typecheck` / `bun run lint` -- green; no migration emitted (`bun run db:generate` emits nothing)
- wms-be: `bun run openapi:export` then regenerate & commit in wms-fe -- `git diff --exit-code` clean on regenerated files
- wms-fe: `bun run test` / `bun run typecheck` / `bun run lint` / `bun run build` -- green

**Manual checks:**
- With a local stack: create a kg SKU, order 2.5, verify order/wave/PO labels render `2.500 kg`; enter `2.5004` and see the server's precision refusal in the order form and the reorder form.