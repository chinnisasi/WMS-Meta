---
story: fix-a1-fe-product-axes-edit
title: "Fix A1: product edit prefills display grammar but parses comma-separated — axes silently corrupted on save"
status: ready-for-dev
epic: null
retro: epic-11-retro-2026-09-22 (F1, action item epic-11-retro-a1-fix-fe-axes-edit-corruption)
context:
  - '_bmad-output/implementation-artifacts/epic-11-retro-2026-09-22.md'
  - 'docs/design/frontend/IMPLEMENTATION-GUIDE.md'
  - 'docs/design/modules/catalog.md'
---

# Fix A1 — product edit axes corruption (frontend)

## Intent

Close the silent-data-corruption defect the epic-11 retro found (F1): the product edit form prefills the axes field with the **display** grammar (`productAxesLabel` → `"size · colour"`), but `parseProductAxes` splits on commas only — so saving an unattached product's edit, even a name-only change, PATCHes `axes: ["size · colour"]`: one axis literally named `"size · colour"`, which passes every backend check. No error, the product's identity is corrupted, and the variant label then renders `size · colour: M`.

## Verified defect (not assumed — checked against the code)

- `wms-fe/src/components/settings/products-card.tsx:508` — `useState(product ? productAxesLabel(product.axes) : '')`: the edit prefill uses the table-cell join (`' · '`).
- `wms-fe/src/lib/catalog-products.ts:23-27` — `parseProductAxes` splits on `','` only; `"size · colour"` survives as one axis.
- Backend accepts it: `assertAxes` checks count (1–3), length (≤32), distinctness — a 13-char unique axis passes.
- Test gap: the component suite pins only the **create** path's POST payload; the edit prefill round-trip is untested — exactly the verification gap that let the defect ship.

## Code Map

| File | Change |
| --- | --- |
| `wms-fe/src/components/settings/products-card.tsx` | The edit prefill becomes `product.axes.join(', ')` — the field now round-trips through `parseProductAxes` unchanged; the table cell keeps `productAxesLabel` (display grammar unchanged) |
| `wms-fe/src/components/settings/products-card.test.tsx` | Edit round-trip regression tests (below). Two harness prerequisites: (a) the stubbed fetch router (`:112-146`) has no PATCH `/catalog/products/{id}` handler — add one, or an edit save falls through to the `404 'Unrouted in this test'` arm and fails for the wrong reason; (b) add a fixture product with `axes: ['size','colour']` and `skuCount: 0` — `prod-1` (the only `['size','colour']` fixture) has `skuCount: 2` so its PATCH carries the name alone and the axes assertion fails confusingly, while the only `skuCount: 0` fixture (`prod-empty`) has axes `['size']` |

## Tasks & Acceptance

- [ ] Edit prefill: `product ? product.axes.join(', ') : ''` — a saved edit with the field untouched sends the product's existing axes verbatim.
- [ ] **AC1 — the corruption is closed:** a test that seeds the fixture product (axes `['size','colour']`, `skuCount: 0`), opens its edit form, changes nothing (or only the name), saves, and asserts the PATCH body carries `axes: ['size','colour']` — never `['size · colour']`. This is the test that would have caught F1.
- [ ] **AC2 — display untouched:** the products table's axes cell still renders `size · colour` (the `productAxesLabel` join) — the fix changes only the input field's prefill.
- [ ] **AC3 — the create path is unchanged:** the existing create-form POST test still pins the same payload.
- [ ] No backend change: no DTO, route or openapi diff.

## Design Notes

- **Why prefill, not parse:** making `parseProductAxes` also accept `' · '` would paper over the mismatch while leaving two grammars in one field — and an axis name containing `·` (legal) could then never be entered. The input's grammar is the comma-separated entry form; the prefill must speak it. Display and input are different grammars and now live at different sites.
- **Out of scope (recorded, not fixed here):** F19 — `parseProductAxes`' comment claims client-side refusal of anything the backend would 400, but duplicate axis names are parsed and sent; the refusal renders via the mapper today. One-line addition if routed later, kept out to keep this fix one defect.
- **Out of scope:** F4/F5 (fetch cap + empty state, action item a4) — separate fix.

## Verification

```
cd workspace/core/frontend/wms-fe
bun run lint && bun run typecheck
bun test src/components/settings/products-card.test.tsx   # bun:test, NOT jest
bun run test   # full FE suite
```

## Spec Change Log

- 2026-09-22 — created from epic-11 retro F1 (action item a1). Defect claims verified against the code at the cited lines before freezing.
- 2026-09-22 — design-review triage (3 findings, none blocking substance): runner corrected (`bun test` — the FE suite is bun:test, not jest); AC1's harness prerequisites named (PATCH `/catalog/products/{id}` stub handler + a `skuCount: 0` fixture with `['size','colour']` axes); AC1's cheaper test shape named (seed the fixture, open the edit form).
- 2026-09-22 — code-review triage (three context-free lenses over the implemented diff; the prefill fix itself verified correct): the save-success path now pinned (form closes, row refreshes, no `role="alert"`) — the round-trip test had asserted only the outgoing request; the stub-handler comment reworded (the test records the outgoing request before routing, so the handler's necessity is response-handling, not request capture). Recorded: an axis name containing a comma still round-trips corruptly (pre-existing, symmetric victim of the entry-vs-display grammar split — PENDING.md); an attached product's disabled axes field now shows `size, colour` where it showed `size · colour` (intended — the field speaks entry grammar everywhere).