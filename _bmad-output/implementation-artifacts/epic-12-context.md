# Epic 12 Context: Storage Conformance, Segregation & Location Types

<!-- Compiled from planning artifacts. Edit freely. Regenerate with compile-epic-context if planning docs change. -->

## Goal

Epic 12 makes storage conformance a rule instead of a habit: every SKU and every location carries a storage class (and, where applicable, a hazard class) from a controlled vocabulary, and putaway and pick refuse a non-conforming placement — a frozen SKU cannot enter an ambient bin and an oxidiser cannot sit beside a fuel, by rule not convention (AD-18). It adds a hazard segregation matrix, a secure/cage class for high-value and controlled stock, locations beyond bins (yards, floor-stack, tanks, silos), dimensional and weight capacity on the location model, and temperature excursions as ledger events so cold-chain custody is reconstructible. It is a Phase 3 domain epic and the hard gate in front of the regulated epics (16/17/18), which reuse its location-and-status gating model.

**Planning-source caveat:** the PRD has **not** been rewritten for the multi-domain expansion and does not know FR-40…FR-45 exist, and the epics file carries no story breakdown for this epic (expansion epics have summaries only). Treat the PRD as stale for any scope question here. The authoritative sources are the approved sprint change proposal (2026-09-17), AD-18 in the architecture spine, the UX contract amendments (UX-DR29/30), and the sprint status file, which holds the story list below.

## Stories

- Story 12-1: Storage class and conformance
- Story 12-2: Hazard segregation matrix
- Story 12-3: Secure locations
- Story 12-4: Non-bin location types
- Story 12-5: Temperature excursions
- Story 12-6: Cold-chain reporting
- Story 12-7: Web storage and segregation admin
- Story 12-8: Mobile conformance refusal and excursions

## Requirements & Constraints

- **Storage class is first-class on SKUs and locations,** drawn from a controlled vocabulary (ambient, chilled, frozen, controlled, hazardous, secure). Putaway and pick refuse a non-conforming placement, and the refusal names the rule and the parties.
- **Incompatible goods cannot be co-located.** A segregation matrix over hazard classes refuses placements that put incompatible classes together, naming both parties in the refusal.
- **High-value and controlled stock is held in secure/cage-class locations,** and movement into or out of them is authority-gated and audited.
- **Locations may be non-bin** — yards, floor-stack areas, tanks, silos — and they participate in putaway and pick under their own placement rules, not as second-class citizens.
- **Location capacity is dimensional and weight-bearing,** not a bare unit count; oversize and floor-stacked goods must be placeable. This extends the capacity model Epic 11 introduced on bins to the new location types.
- **Temperature excursions are ledger events** recorded against the affected stock; the affected units are quarantined pending review — never silently written off or left in ATP.
- **Cold-chain state is reportable end to end:** for any dispatched unit, the storage classes and excursions it passed through are reconstructible from the ledger alone.
- **Success looks like:** a cold-chain or hazmat operator's warehouse can be configured and policed entirely by the system's placement rules, with the mobile scan path enforcing them in real time — including in a dead zone.

## Technical Decisions

- **AD-18 — conformance is a command-layer rule.** Enforcement lives in the command layer, never as a UI convention or a bin-naming habit. Both vocabularies are backed by DB CHECKs, never free text — the pre-existing free-text bin type with no constraint is exactly the pattern this epic replaces.
- **The server command layer is the authority; the device is the fast mirror.** The mobile client evaluates conformance on-device against the cached snapshot so the refusal is sub-500 ms and dead-zone tolerant, but every placement is re-checked server-side at command entry regardless — an offline-replayed op that is non-conforming still quarantines, following the existing replay conflict taxonomy.
- **Excursions ride the ledger, not a side book.** An excursion is a registered ledger event type under AD-11's additive-grammar rule, so replay-reconciliation, the ledger timeline and audit all see it; quarantine of affected units uses the existing QC-hold/quarantine semantics.
- **Non-bin locations extend the location model, they do not fork it.** Yards, floor-stack areas, tanks and silos join the existing putaway/pick seams with their own placement rules; Epic 20 later puts measured stock and level reconciliation on this same substrate.
- **Module ownership follows AD-6:** location master data and vocabularies in tenancy, bin/placement enforcement in putaway (and pick in outbound), excursion and conformance events through the inventory ledger. No module reaches into another's tables.
- **Conventions carry over unchanged:** fractional quantities per Epic 10, money in integer paise (AD-9), tenant+warehouse scope on every new path (AD-3), commands via the shared command layer with role-epoch re-evaluation (AD-10).

## UX & Interaction Patterns

- **Conformance refusal on the scan path (UX-DR29):** a non-conforming putaway or pick rejects in **< 500 ms with the ✕ Rejected banner** (UX-DR4), names both parties and the rule, and offers the nearest conforming location. It evaluates on-device where the storage class is in the cached snapshot, so it works in a dead zone. Rejected scans never queue. The design rationale: *a conformance refusal the floor never sees is a cold-chain break the backend correctly prevented.*
- **Excursion capture (UX-DR30):** an operator records a temperature excursion against a location or handling unit from the task screen; affected stock shows a **quarantine badge everywhere it appears**; the excursion lands in the Conflicts & Reviews queue (UX-DR11) with the reading, affected units and ledger context.
- **Web admin surfaces:** storage/hazard class admin on SKUs and locations, segregation-matrix configuration, and the excursion review queue ride the established data-table, approval-card and ledger-timeline patterns (UX-DR8/11/14) — no new interaction vocabulary.
- **Accessibility floor holds as everywhere else:** the refusal banner is never colour-only, announces the rule and nearest conforming location via platform accessibility APIs, and honors Reduce Motion and dynamic type (UX-DR22).

## Cross-Story Dependencies

- **Depends on:** Epic 2 (ledger, ATP, quarantine semantics), Epic 3 (mobile scan substrate, directed putaway, bin administration) and Epic 11 (the finished location model and dimensional capacity). Dependency is Epic 12 ← 2+3+11.
- **Backend first within the epic:** the model stories (12-1…12-6) precede the web surfaces (12-7) and mobile scan-path work (12-8) that consume them; surfaces ride their own epic, executed backend-first within it.
- **Hard gates this epic opens:** **Epics 16, 17 and 18** (customs, excise, controlled goods) all reuse this location/status gating model — Epic 12 before 16/17/18 is one of the programme's only hard gates. **Epic 15** (handling units) and **Epic 20** (bulk and tank storage) also build on it.
- **Preference, not gate:** Epic 5 (transfers, adjustments, counts) was re-sequenced to follow this epic to avoid building them twice against the location model — counting bins works without storage classes, and the revisit point is when yards and tanks arrive.
- **Phase 3 reorderability:** the epic is additive by construction; it can move within Phase 3 by market demand without rework, subject only to the gates above.