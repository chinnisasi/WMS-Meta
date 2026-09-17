# Epic 10 Context: Quantity Model — Measured Goods & Catch Weight

<!-- Compiled from planning artifacts. Edit freely. Regenerate with compile-epic-context if planning docs change. -->

## Goal

Epic 10 is the one foundational migration of the multi-domain expansion and the Tier 0 gate in front of everything measured. Quantities stop being integers in a base unit and become fractional: scaled integers in milli-units, with each unit of measure declaring the real decimal precision it is allowed to express. Catch weight arrives alongside — as a per-handling-unit *actual weight*, deliberately not as a quantity — so the risky change stays confined to the quantity columns and the commands that write them. This is cheapest now: every epic built on integer quantities is an epic to rewrite, the migration surface is four epics rather than nine, and it unblocks measured verticals (grain, fertilizer, cement, chemicals, petroleum, LPG, bulk alcohol, length-measured steel and pipe) plus catch-weight goods (meat, fish, cheese).

**Planning-source caveat:** the PRD has **not** been rewritten for the multi-domain expansion — it still describes a single-vertical India D2C product and does not know FR-31…FR-74 exist. Treat it as stale for any scope question about this epic. The authoritative sources here are the approved sprint change proposal (2026-09-17), the amended AD-9 plus AD-18…AD-22 in the architecture spine, and the UX contract (DESIGN.md / EXPERIENCE.md), all of which post-date it.

## Stories

- Story 10-1: Fractional quantity migration
- Story 10-2: UoM vocabulary and precision
- Story 10-3: Catch weight and handling units
- Story 10-4: Measured stock reconciliation
- Story 10-5: Web fractional quantity surfaces
- Story 10-6: Mobile decimal entry and catch-weight capture

## Requirements & Constraints

- **Fractional quantities everywhere.** Every quantity in the system honours its base UoM's declared decimal precision (each = 0 dp, kg/litre/tonne = 3 dp). A quantity finer than the declared precision is **rejected, never silently rounded**.
- **UoM is a controlled vocabulary.** Units come from a closed list with declared conversions and precision, enforced at the database level, never free text — `pcs`, `PCS` and `pieces` must not be able to coexist as three units. Free-text UoM is refused at catalog entry.
- **Catch weight is a separate concept.** A handling unit (pallet, case, cylinder, keg) may carry its own identity, location and actual weight. A case of beef is *one* unit weighing 18.4 kg — handled by unit, priced by weight. The weight is captured at receipt and carried through pack to invoice. It is never modelled as quantity.
- **Reconciliation is the acceptance test.** Replay-reconciliation must reproduce every derived balance exactly after the migration; a rounding policy is declared once and applied everywhere.
- **Success looks like:** a grain depot books stock in tonnes to three decimals and a fishmonger records per-case catch weight, and replay reproduces every balance.
- **Ordering:** this epic blocks Epics 5, 14, 19 and 20. Nothing in it may wait on a later epic.

## Technical Decisions

- **Representation:** quantities are scaled integers in milli-units (base UoM × 10³) stored as `bigint`. Decimal conversion happens **only at the API and UI edges** — no decimal representation exists inside the domain. `bigint` milli-units reach ~9.2 × 10¹² base units, ample for silo and tank scale; the old `integer` base-unit approach overflows well before it (2,147,483,647 g ≈ 2,147 t).
- **Why not `numeric`:** the reservation path decrements ATP counters in Valkey through a Lua script, and Lua numbers are IEEE doubles. Decimals crossing that boundary reintroduce exactly the float errors the primitive-type rule exists to prevent. One exact representation everywhere beats two representations plus a conversion boundary in the most concurrency-sensitive code in the system. Revisit only if a UoM ever needs more than six decimal places.
- **Unchanged primitives:** money stays integer paise, GST rates stay basis points, timestamps stay ISO-8601 UTC, ids stay UUIDv7. Every ledger event's `qty` stays signed by movement direction.
- **Migration oracle:** the continuous replay-reconciliation job recomputes derived quantities from the ledger and compares them to live counters — after migration it must reproduce every balance. Build the migration so that job is the gate, not an afterthought.
- **Ledger grammar is closed.** New event types are added by registration against the versioned envelope, never by free-form emission; consumers compile against the registry. Migrating quantity representation must not change the event grammar or the per-warehouse sequence ordering that replay depends on.
- **Command layer owns mutation.** Precision validation and UoM conformance are command rules, enforced server-side, not UI conventions.
- **Handling-unit identity** (identity + location + actual weight) is the same mechanism that later carries returnable containers as assets; model it so Epic 15 extends it rather than replacing it.
- **Blast radius:** the migration touches every quantity column in the schema and every command that writes one, plus the Valkey ATP counters and the mobile client's cached snapshot. The exact column inventory is in the codebase — read it there.

## UX & Interaction Patterns

- **Quantity field is dual-mode, selected by the SKU's UoM.** Each-counted UoMs keep the existing gloves-friendly +/− stepper unchanged; measured UoMs render a decimal keypad. An operator never meets a stepper that cannot reach the value.
- **Display at declared precision, never storage precision:** `18.4 kg`, never `18.400000 kg`. In tables, align on the decimal point with tabular numerals — the point must form a line.
- **Decimal keypad rules (mobile):** every key ≥ 48dp with a ≥ 8dp gutter; **both `.` and `0` are oversized** — they sit adjacent on every layout and a mis-hit is a 10× or 100× error, so sizing only one defends the wrong half of the confusable pair. Per-key confirmatory haptic/audible feedback is expected. The field stays a **real text input** so HID scanners, dictation and assistive text entry reach it.
- **Precision refusal is inline and named:** a typed value finer than the declared precision is refused naming the precision, never silently rounded, and the refusal announces its rule in the same announcement as the state (never visual-only).
- **Catch-weight capture (mobile receive + pack):** prompts for the handling unit's actual weight *after* the item scan. A connected scale or meter reading is a scan-equivalent input, with manual entry as the named fallback. Quantity and weight are distinct **in the accessible name, not only visually** — "Catch weight, kilograms, one decimal place, 18.4" vs "Quantity, eaches, 6"; never "enter 18.4 pieces".
- **Captured catch weight survives** banner swaps, task suspension and app backgrounding — the analogue of the HID focus rule.
- **Hardware vs typed input differ:** a scale reading finer than declared precision is **rounded with both values shown** ("Scale: 18.4567 → recorded 18.5 kg"); inline refusal is reserved for typed entry, where the operator can act.
- **Order-of-magnitude guard:** an entered weight deviating from the handling unit's nominal weight by an order of magnitude requires an explicit confirm — target size alone cannot defend against a 10× error.
- **Mobile snapshot must carry declared UoM precision and catch-weight tolerance**, since the device validates entry on the scan path offline.

## Cross-Story Dependencies

- **Within the epic:** backend first — the migration (10-1) precedes the UoM vocabulary/precision rules (10-2) and catch-weight handling units (10-3); reconciliation (10-4) proves them; the web (10-5) and mobile (10-6) surfaces consume the finished API. Surfaces ride their own epic by decision (2026-09-17), executed backend-first *within* the epic — do not defer them.
- **Depends on:** Epic 1 (catalog, SKUs, UoM on SKU) and Epic 2 (ledger, derived quantities, ATP/reservations, and the replay-reconciliation job that acts as this migration's oracle).
- **Blocks:** Epic 5 (transfers, adjustments, cycle counts), Epic 14 (traceability/shelf life), Epic 19 (manufacturing WIP), Epic 20 (bulk and tank storage). Epic 5 was re-sequenced behind this epic specifically to avoid rewriting it on the new quantity model.
- **Runs alongside:** Epic 11 (product & shipment model) is the other Phase 0 foundation; it is independent of this epic and does not gate it.
