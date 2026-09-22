---
title: 'Web variant and kit surfaces'
type: 'feature'
created: '2026-09-22'
status: 'ready-for-dev'
route: 'dispatch'
review_loop_iteration: 0
baseline_commit: 'wms-be e6cd193 / wms-fe de96601'
context:
  - '_bmad-output/implementation-artifacts/epic-11-context.md'
  - 'docs/design/SYSTEM-DESIGN.md'
  - 'docs/design/IMPLEMENTATION-GUIDE.md'
  - 'docs/design/modules/catalog.md'
  - 'docs/design/modules/outbound.md'
  - 'docs/design/frontend/SYSTEM-DESIGN.md'
  - 'docs/design/frontend/IMPLEMENTATION-GUIDE.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** Stories 11-3/11-4 shipped the product/variant and kit models with no web UI: a size×colour range renders nowhere, a kit's composition has no editor, an exploded order renders as a flat line list, and compositions can be created only by API (FR-37/FR-38; UX-DR28).

**Approach:** Web surfaces on the existing models, plus the import column deferred from 11-4 — a **Products card** in the Settings catalog stack where a product row expands to its variant matrix (attach/detach variants via the existing SKU PATCH), **kit composition create/edit** as a row action on the SKU table (POST/PUT kit routes), **parent/child rendering** of exploded kit lines in the order-detail panel, and a `kit_components` CSV import column. No new backend model, route or capability — the only backend change is the additive import column.

**Decisions (2026-09-22):** all surfaces live in the **Settings catalog stack** — no new nav item, no new route (human decision); kit component quantities are entered/displayed in base UoM decimal units, never raw milli (FE converts at the API boundary; import column uses the same convention).

## Boundaries & Constraints

**Always:**
- No new capability: product and kit writes stay gated by `sku.edit` (the 11-3/11-4 precedent) — the FE capability mirror is untouched.
- Variant attach/detach rides the existing SKU edit PATCH (absent = unchanged, `null` = detach); the matrix joins `GET /catalog/skus?productId=` with `GET /catalog/products` client-side — no BE read additions.
- The kit editor and the import column route through the existing command-side guards (`kit-already-composed`, `kit-sku-holds-stock`, `kit-component-is-kit`, `kit-self-reference`, `duplicate-kit-component`, `kit-component-not-found`, `empty-kit-composition`); import resolves compositions AFTER all SKU rows, reusing the kit store's guards.
- `kit_components` cell grammar = the `uom_conversions` precedent: `code:qty;code:qty`, qty a decimal in the component's base UoM, parsed to milli and checked against the component's declared precision (the explosion's rule).
- Expanded rows follow the 4-2b pattern: surface-owned `aria-expanded`/`aria-controls` via `expandedRowId`, inline `role="alert"` errors in the row, instant expand/collapse (UX-DR28 + UX-DR22); error mapping branches on `problem.code` into the shared `FeedbackBanner` copy, never prose.
- Kit and variant quantities are displayed and entered in base UoM units (decimal), never raw milli; the FE converts at the API boundary.

**Never:**
- No BE model/route/capability changes beyond the import column; no openapi schema change (CSV columns are not contract), so the generated FE client needs no regen.
- No device catalog-snapshot change (mobile is 11-7's); no kit-of-kit, no product deletion, no SKU create (import stays the only creator).
- No new nav plumbing or route change; no changes to wave/pick/pack rendering (they see child lines already).

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Expand product row | click on a product row's disclosure | variant matrix: attached SKUs (code, name, barcode, axis values), a11y per 4-2b; empty product → "no variants" + attach CTA | list-load failure → inline `role="alert"` + Retry in the row |
| Attach variant | choose an unattached SKU + fill values for each axis | 200; matrix refreshes; SKU table reflects attachment on next revision bump | `validation-failed` naming `variantValues`+axis, `duplicate-variant-values` → mapped inline banner |
| Detach variant | matrix row action | `PATCH productId: null`; values cleared; matrix shrinks | 404/transport → standard read/write reasons |
| Create product | name + 1–3 axes | 201; duplicate name → 409 | `duplicate-product-name`, `product-has-variants` on axes edit → mapped |
| Kit create on a plain SKU | component picker + per-component decimal qty | 201; SKU row gains a kit marker (from `GET /catalog/kits` join) | all seven kit arms mapped; `kit-already-composed` switches the row to the edit form |
| Order detail with exploded kit | order carries parent + child lines | parent line renders with its children grouped/indented beneath it (parent holds nothing; child statuses as before); plain orders render exactly as today | N/A |
| Import `kit_components` | `kit_components=pad:2;tape:1` on a non-kit SKU row | composition created in-transaction after SKU resolution; component resolved by code incl. an earlier row of the same file | row errors name the cell: unknown code, component is a kit, kit holds stock, qty below component precision, SKU already a kit |
| Import, no cell | `kit_components` blank | no composition, unchanged from today | N/A |

</frozen-after-approval>

## Code Map

- `wms-fe/src/components/settings/products-card.tsx` (NEW) -- the Products card: DataTable (name, axes, skuCount) + expanded-row variant matrix; create/edit product form (`fetchApiCreateProduct`/`fetchApiEditProduct` wrappers to add in `src/lib/api/client.ts` — SDK functions `createProduct`/`editProduct`/`listProducts` exist unused in `sdk.gen.ts`)
- `wms-fe/src/lib/use-catalog.ts` -- products list hook following the preferred `ResourceState`/`Reloadable` shape (the `use-outbound-orders.ts` exemplar), rev bump on `CATALOG_CHANGED_EVENT`
- `wms-fe/src/components/settings/sku-table.tsx` -- gains a Kit row action (create form for a plain SKU, PUT edit for a kit-marked row); kit marker from a kits-list join; edit form area pattern (`SkuEditForm` below the table) is the template for both new forms
- `wms-fe/src/components/outbound/outbound-orders.tsx` (`OrderDetailPanel`, ~L610-656) -- group child lines (`parentLineId`) under their parent in the flat `<ul>`; parents show backorder state
- `wms-be/src/modules/catalog/import.command.ts` -- `kit_components` in OPTIONAL_COLUMNS (after `variant_values`, L121); cell parser beside `parseVariantValuesCell` (L1110); resolution AFTER all SKU rows commit, reusing `kit.store.ts` guards + `quantity.ts` precision helpers; row errors via the `rowError` helper
- `wms-be/test/kits.spec.ts` -- kit_components import arms (kit fixtures live here; the products.spec.ts import-header pattern is the CSV template)
- Not to change: `users.ts` (capability mirror), generated client (no contract change), `useSkus` legacy hook (do not extend the old shape), any outbound command (display only)

## Tasks & Acceptance

**Execution:**
- [ ] `wms-be/src/modules/catalog/import.command.ts` -- `kit_components` column + parser + post-resolution pass through the kit guards -- the deferred import support
- [ ] `wms-be/test/kits.spec.ts` -- the import I/O arms incl. file-internal component resolution and precision refusal -- the proof
- [ ] `wms-fe/src/lib/api/client.ts` + `src/lib/use-catalog.ts` -- product/kit wrappers + hooks -- data layer
- [ ] `wms-fe/src/components/settings/products-card.tsx` + `settings/page.tsx` -- products card + variant matrix -- the variant surface
- [ ] `wms-fe/src/components/settings/sku-table.tsx` -- kit marker + create/edit kit forms -- the kit editor
- [ ] `wms-fe/src/components/outbound/outbound-orders.tsx` -- parent/child line rendering -- the order display
- [ ] `wms-fe` component tests for the new surfaces (happy-dom render helper exists) -- the FE pins
- [ ] meta `docs/` -- frontend module docs, `docs/repos/wms-be/README.md` import header (fixes the stale 11-2 columns debt), PENDING, deferred-work closure -- keep the docs true

**Acceptance Criteria:**
- Given a product with two attached variants, then the Settings products card expands to a matrix showing both with their axis values; attaching a third SKU with duplicate values is refused by name inline.
- Given a kit SKU with a composition, then the SKU table marks it, the editor PUTs a replacement BOM, and an order containing it renders its children grouped under the parent line.
- Given a CSV with a `kit_components` cell referencing an earlier row's SKU code, then the composition is created with the file-internal reference; a cell naming an unknown code or a kit as component is refused by row.
- Given the whole suite, then `bun run test/typecheck/lint/build` pass in both repos and the FE drift + capability-mirror guards pass with no generated-client change.

## Design Notes

- **No BE read additions:** `GET /catalog/skus?productId=` was built in 11-3 as "the 11-6 matrix's data source" (`catalog.controller.ts:70`); the FE joins it with the products list for names/axes. `parentLineId` already rides `OrderLineDto` (`outbound.dto.ts:163`). Only the import column is backend work.
- **Kit-ness is derived, not flagged:** the SKU table's kit marker comes from a `GET /catalog/kits` join — no BE `isKit` field is added (the 11-4 no-flag decision holds).
- **Import kit resolution must run after SKU resolution** (a component may be an earlier row of the same file) and inside the same transaction; the kit-sku-holds-stock guard decides against the freshly imported rows' final state.

## Verification

**Commands:**
- `wms-be`: `bun run test && bun run lint && bun run typecheck` -- expected: green, new import arms pass
- `wms-fe`: `bun run test && bun run typecheck && bun run lint && bun run build` -- expected: green incl. new component tests
- `wms-fe`: `bun run check:capability-mirror` -- expected: pass with no users.ts change

**Manual checks (if no CLI):**
- Walkthrough: expand a product row with keyboard (aria-expanded announced), attach + duplicate-value refusal, kit create → order with kit line shows parent/child grouping.