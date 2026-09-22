---
title: 'Web variant and kit surfaces'
type: 'feature'
created: '2026-09-22'
status: 'done'
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
- [x] `wms-be/src/modules/catalog/import.command.ts` -- `kit_components` column + parser + post-resolution pass through the kit guards -- the deferred import support
- [x] `wms-be/test/kits.spec.ts` -- the import I/O arms incl. file-internal component resolution and precision refusal -- the proof
- [x] `wms-fe/src/lib/api/client.ts` + `src/lib/use-catalog.ts` -- product/kit wrappers + hooks -- data layer
- [x] `wms-fe/src/components/settings/products-card.tsx` + `settings/page.tsx` -- products card + variant matrix -- the variant surface
- [x] `wms-fe/src/components/settings/sku-table.tsx` -- kit marker + create/edit kit forms -- the kit editor
- [x] `wms-fe/src/components/outbound/outbound-orders.tsx` -- parent/child line rendering -- the order display
- [x] `wms-fe` component tests for the new surfaces (happy-dom render helper exists) -- the FE pins
- [x] meta `docs/` -- frontend module docs, `docs/repos/wms-be/README.md` import header (fixes the stale 11-2 columns debt), PENDING, deferred-work closure -- keep the docs true

**Acceptance Criteria:**
- Given a product with two attached variants, then the Settings products card expands to a matrix showing both with their axis values; attaching a third SKU with duplicate values is refused by name inline.
- Given a kit SKU with a composition, then the SKU table marks it, the editor PUTs a replacement BOM, and an order containing it renders its children grouped under the parent line.
- Given a CSV with a `kit_components` cell referencing an earlier row's SKU code, then the composition is created with the file-internal reference; a cell naming an unknown code or a kit as component is refused by row.
- Given the whole suite, then `bun run test/typecheck/lint/build` pass in both repos and the FE drift + capability-mirror guards pass with no generated-client change.

## Review Triage Log

**Round 1 (step-04, three layers over the combined diff — blind-hunter 16, edge-case-hunter 9, verification-gap 4+4).** Two claims the implementer's context pre-flagged (the fix-mode comment, the missing kit event) were re-verified by all three layers independently.

| # | Source | Finding | Verdict | Triage |
|---|--------|---------|---------|--------|
| 1 | blind + edge + gap | The code comments (`import.command.ts:202`, `:488`) claim fix mode can retry a refused kit composition; it cannot — the row's SKU committed, so a fix-mode resubmit dies at the tenant `duplicate-sku-code` check before the kit pass. Only the PUT route retries. Verified by me against `import.command.ts:247-262` + `:388-391`. | medium | **patch** (comment corrected; folded into entry 1) |
| 2 | blind + gap | The import kit pass writes `kit_compositions` directly and emits only `catalog.imported` — no `catalog.kit_created` per created kit, unlike `KitCommand` (docs list KitCommand as the events' only source). No consumer today (LoggingEventBus only logs), but 11-7's snapshot or any future consumer misses import-created kits. Verified. | medium | **patch** (entry 2) |
| 3 | blind + gap | The counts no longer partition: a kit-refused row is both committed and failed (13+10 > 16), the module doc still frames valid/errors as a partition, and the FE import banner's guidance ("re-import them as a fix run") is exactly the impossible path for kit-refused rows. Verified (verification-gap, pre-verified). | medium | **patch** (entry 1) |
| 4 | blind | `stockKits`/`heldKits`/kit-side `preexistingKitIds` guards are structurally unreachable for fresh imports, while the spec I/O matrix lists those arms as reachable row errors, and no test pins them. | low | **rejected** — deliberate fail-closed defense; code loudly refusing a state the program cannot reach is correct behavior, and the fix (removing guards or amending the frozen matrix) would weaken a boundary the frozen Always-names. |
| 5 | blind | The FE import card's fixed-header column list omits `variant_values` (11-3 debt) and `kit_components`, with no grammar example for the new cell — a user cannot discover the column from the UI. | medium | **patch** (entry 8) |
| 6 | blind + gap | The SKU table never renders the kits join's failed state — `kitOf` returns undefined for every row, so every kit renders as a plain SKU with a create-only Kit button; the outage is silent in the surface whose headline feature is the marker. Pre-verified (verification-gap read the component end to end; all kits stubs in tests return 200). | medium | **patch** (entry 3) |
| 7 | blind + edge | The saved-kit banner branches on component count, not mode: editing a kit down to one component says "X is now a kit" (and creating a multi-component kit says "kit updated"). Verified at `sku-table.tsx:202`. | low | **patch** (entry 4) |
| 8 | blind + edge | `groupKitLines` drops second-level descendants (a child of a child is grouped under its parent, but that parent renders as a child row, not a group, so the grandchild never renders). | low | **rejected** — the backend guarantees one-level explosion (flat BOM, pinned since 11-4); the function's missing-parent arm already covers the real defensive need, and the recursion fix adds complexity for data the program cannot produce. |
| 9 | blind | The order-detail summary line (`lineTotals(detail.data.lines)`) sums the flat list — a kit order's totals double-count contents (parent + children both counted; the line count is inflated too). Verified at `outbound-orders.tsx:627` + `outbound-orders.ts:100-111`. | medium | **patch** (entry 5) |
| 10 | blind | `useCatalogSkus` is instantiated separately in `VariantMatrix` and `KitForm` — the Settings page fetches the whole catalog 2–3× with no shared cache; unbounded duplicate fetching on a 10k-SKU tenant. | medium | **defer** (entry 10 — real scaling note; fix is a shared-catalog-context refactor beyond this story's patch round) |
| 11 | blind | `products-card.test.tsx`'s `stubRouter(role = 'owner')` accepts a role and discards it. | low | **rejected** — dead test parameter, no behavioral effect. |
| 12 | blind | `ProductsCardSessioned`'s `products ?? { onCursor: undefined }` null-fallback is dead — `useProducts` never returns null. | low | **rejected** — harmless defensive optional chain, no behavior change available. |
| 13 | blind | `parseKitComponentsCell` checks MAX_KIT_COMPONENTS only after parsing the whole cell; a pathological cell is split and built in full before refusal. | low | **rejected** — the file-size cap bounds cell length; the work before refusal is bounded and negligible. |
| 14 | blind | The 11.6 test pins only three shape arms; the separator-only `empty-kit-composition`, empty-code and over-long-code arms are untested. | low | **patch** (entry 2) |
| 15 | blind | The kit pass calls `validateRecordableQuantity(..., 'non-negative')` while the shape layer already refuses ≤ 0 — the mode label understates the invariant. | low | **rejected** — speculative drift note on a correct boundary; no harm reaches users or developers today. |
| 16 | blind | The edit-mode header renders `existing` from the parent's kits map (stale as the user edits rows) and the quantity tooltip falls back to `quantityInputLabel(0)` when the component SKU is unresolved. | low | **rejected** — cosmetic hint text; the header honestly describes the BOM the form opened with, and the tooltip fallback covers a transient load window. |
| 17 | edge | (Same location and claim as finding 1.) | — | carried |
| 18 | edge | (Same location and claim as finding 8.) | — | carried |
| 19 | edge | Inside the `kit-already-composed` recovery, the fresh kits-list `fetchAllPages` is not wrapped — if it throws, the rejection escapes onSubmit unhandled and the submission vanishes without feedback. Verified at `sku-table.tsx:638` (a throw inside the catch propagates; `finally` only resets pending). | low | **patch** (entry 7) |
| 20 | edge | While the kits join loads (or after it fails), `kitOf` returns undefined and existing kits appear as selectable components — the "guaranteed refusals filtered, not validated" contract breaks transiently. | low | **rejected** — a transient window that self-heals when the join lands; the server's `kit-component-is-kit` refusal renders by name in the interim. The persistent arm (failed join) is entry 3's fix. |
| 21 | edge | (Same location and claim as finding 7.) | — | carried |
| 22 | edge | With a zero-SKU tenant, the attach CTA copy reads "Every SKU already carries a variant on this product" — false. Verified at `products-card.tsx:326-328`. | low | **patch** (entry 6) |
| 23 | edge | The parent hold span renders `KIT_PARENT_HOLDS_LABEL` unconditionally — a dispatched kit order's parent still asserts "stock held on its components" after the holds were consumed. Verified at `outbound-orders.tsx:658`. | low | **patch** (entry 9) |
| 24 | edge | `attachCandidates` filters only `productId !== product.id`, so a SKU attached to a DIFFERENT product is offered — and the server's attach arm has no current-attachment guard (`sku.command.ts:376-414`), so the PATCH silently moves it off that product. The frozen matrix says "choose an unattached SKU". Verified. | medium | **patch** (entry 11 — the code deviates from the frozen wording; filter to `productId === null`) |
| 25 | edge | The frozen Decisions sentence says "FE converts at the API boundary"; the FE performs no conversion (the server converts decimals to milli at its own edge). | false | **rejected** — the finding's only fix is an edit to the frozen spec, and the normative content (decimals at the FE, never raw milli) is exactly what the code does; the parenthetical's misattribution changes no behavior. |
| 26 | gap | (Same claim as finding 3, fuller: the import card's overlapping-counts display and its fix-run remedy are untested for the new semantics.) | — | carried |
| 27 | gap | (Same claim as finding 6, pre-verified.) | — | carried |
| 28 | gap | The products card's cursor pagination is wired but never exercised — every fixture returns `nextCursor: null` and no test clicks Next, so a broken page-2 fetch ships undetected. | low | **patch** (entry 12) |
| 29 | gap | `inFileKitCodes` treats every row with a kit cell as a kit for sibling rows, including rows whose cell was refused — a sibling naming a refused kit is refused with "is itself a kit", false in that case. The mutual-pair refusal it pins is deliberate. | low | **rejected** — deliberate fail-closed file-internal consistency (if the refused kit is later composed via PUT, the sibling's reference would become kit-of-kit); the collateral is one imprecise error detail, not a wrong refusal. |
| 30 | gap | (Same claim as finding 2.) | — | carried |
| 31 | gap | The 11.6 test reaches into the 11.4 describe's fixture for `KIT-KE1`; a change to the 11.4 fixtures breaks the 11.6 arm with a failure pointing at the wrong describe. | low | **patch** (entry 2) |

**Grouping and routing.** No intent_gap, no bad_spec — no loopback. All surviving entries are patch, plus one defer:

- **Entry 1 (patch)** — findings 1, 3, 17, 26: the retry story for kit-refused rows is wrong in three places (BE comments, module-doc framing, FE import-card guidance) and the overlapping counts are unrendered/unpinned on the FE. Root cause: the kit pass's committed-and-failed row shape was never carried into the comment, the doc framing, or the card copy.
- **Entry 2 (patch)** — findings 2, 14, 30, 31: the import pass's event gap and the new suite's thin shape coverage share one site — the kit pass + its test describe.
- **Entry 3 (patch)** — findings 6, 27: the kits join's non-ready states have no UI arm in the SKU table.
- **Entry 4 (patch)** — findings 7, 21: the saved-kit banner branches on count, not mode.
- **Entry 5 (patch)** — finding 9: the order-detail summary sums the exploded flat list.
- **Entry 6 (patch)** — finding 22: the empty-catalog attach copy.
- **Entry 7 (patch)** — finding 19: unhandled rejection in the race-arm recovery.
- **Entry 8 (patch)** — finding 5: the import card's stale column list and missing grammar example.
- **Entry 9 (patch)** — finding 23: the dispatched parent's hold label.
- **Entry 10 (defer)** — finding 10: duplicate whole-catalog fetching (severity real, unbounded only at 10k-SKU scale; fix is a shared-catalog context).
- **Entry 11 (patch)** — finding 24: attach candidates include SKUs attached to other products (deviation from the frozen "unattached SKU" wording).
- **Entry 12 (patch)** — finding 28: cursor pagination untested.

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