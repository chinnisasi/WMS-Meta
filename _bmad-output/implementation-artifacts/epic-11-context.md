# Epic 11 Context: Product & Shipment Model

<!-- Compiled from planning artifacts. Edit freely. Regenerate with compile-epic-context if planning docs change. -->

## Goal

Epic 11 completes the product and shipment model the MVP's later stories assume: structured, pincode-bearing addresses on the order destination and the warehouse origin unblock carrier rating and labelling (parked story 4-6d); SKU weight, dimensions and country of origin unblock labels, manifests and dimensional capacity; a two-level product→variant identity makes size×colour ranges first-class without touching the ledger (AD-19); and kits/bundles hold their stock on components, exploding the BOM at order acceptance. It is the second Phase 0 foundation (alongside Epic 10) and the hard gate in front of Epic 7 — a Shopify product maps to variants, so without variants the channel mapping is lossy by construction.

**Planning-source caveat:** the PRD has **not** been rewritten for the multi-domain expansion and does not know FR-35…FR-39 exist, and the epics file carries no story breakdown for this epic (the expansion epics have summaries only). Treat the PRD as stale for any scope question here. The authoritative sources are the approved sprint change proposal (2026-09-17), AD-19 in the architecture spine, the UX contract amendment (UX-DR28), and the sprint status file, which holds the story list below.

## Stories

- Story 11-1: Shipment address model
- Story 11-2: SKU physical attributes and origin
- Story 11-3: Product variants
- Story 11-4: Kits and bundles
- Story 11-5: Dimensional capacity
- Story 11-6: Web variant and kit surfaces
- Story 11-7: Mobile variant-aware picking

## Requirements & Constraints

- **Addresses are structured, not free text.** An order carries a destination address and a warehouse carries an origin address, both with a pincode — carriers rate, label and manifest from them. No address, no rating.
- **A SKU carries physical attributes:** weight, dimensions, and country of origin. These feed carrier rating/labels and dimensional capacity checks (and later import documentation).
- **Products and variants are two-level.** A product groups variants that differ on declared axes (size, colour); each variant remains a SKU. Channel mappings bind to variants, and no ledger event changes shape because of this.
- **Kits and bundles are compositions, never stock.** A kit is composed of component SKUs; stock is held on the components only. A kit allocates by exploding its BOM at order acceptance — it is never counted as independent inventory.
- **Bin and location capacity is dimensional and weight-bearing,** not a bare unit count — oversize and floor-stacked goods must be placeable, and a placement that does not fit the capacity is refused.
- **Success looks like:** story 4-6d (carrier rating → labels → dispatch) and Epic 7's channel mapping build directly on this epic's model with no rework.

## Technical Decisions

- **AD-19 — the SKU stays the ledger's unit.** `products` sits **above** `skus`; a SKU remains what every ledger event, reservation, pick and bin quantity references. Variants are an identity and presentation concern; **no table below the catalog ever learns what a variant is.** This is what keeps apparel support and Shopify's product→variant mapping additive instead of forcing a ledger migration.
- **Module ownership:** FR-35…39 live across the **catalog** (products, variants, attributes, kits) and **outbound** (order destination address, acceptance-time BOM explosion) modules, per the spine's module map.
- **Kit allocation rides the existing reservation machinery** — exploding the BOM at acceptance means reserving the components through Epic 2's atomic reservation path, not a parallel booking system.
- **Static SKU weight ≠ catch weight.** The SKU's weight is a catalog attribute used for rating and dimensional capacity; the per-handling-unit actual weight from Epic 10 (AD-22) remains a separate concept captured at receipt. Do not conflate them.
- **Dimensional capacity extends the bin model, not the putaway algorithm** — capacity becomes dimensional/weight-bearing on the location, and putaway's existing full/blocked checks consume it. (Epic 12 later adds storage classes and more location types on the same location model.)
- **Quantity, money and precision conventions carry over unchanged** — fractional quantities follow Epic 10's representation, money stays integer paise (AD-9).

## UX & Interaction Patterns

- **Variant-aware surfaces (UX-DR28):** a size×colour range renders as **one product row expanding to a variant matrix** via the DataTable expanded-row pattern (established in 4-2b) — never as N unrelated SKU rows.
- **Mobile pick path:** the variant (size/colour) is the **first element announced after the scan result** and the largest distinguishing text on the task screen — picking the wrong size is the dominant apparel error, and font size is not reading order.
- **Accessibility of the variant matrix:** expansion is a named disclosure (`aria-expanded`, "Expand variants for {product}") announced on change, exposed as a `treegrid` or a labelled independent region — never a bare table nested in a `<td>`, which breaks screen-reader table navigation. Row actions are keyboard-reachable on every viewport.
- **Reduce Motion:** variant row expand/collapse is instant (UX-DR22's floor extends to this epic's affordances).

## Cross-Story Dependencies

- **Depends on:** Epic 1 (catalog, SKUs, UoM) and Epic 2 (ledger, reservations, ATP — kits allocate through them).
- **Within the epic, backend first:** the model stories (11-1…11-5) precede the web surfaces (11-6) and mobile variant-aware picking (11-7) that consume them; surfaces ride their own epic rather than being deferred, executed backend-first within the epic.
- **Blocks:** story 4-6d (carrier rating/labels need addresses + weight/dims — the only hard gate) and **Epic 7** (channel mapping binds product→variants). Epic 12 builds on this epic's location model (12 ← 2+3+11), and Epic 19's production kits extend the kit model (19 ← 2+10+11) — shape both to be extended, not replaced.
- **Independent of Epic 10:** the two Phase 0 foundations do not gate each other; Phase 0 orders this epic after Epic 10 only for sequencing convenience.