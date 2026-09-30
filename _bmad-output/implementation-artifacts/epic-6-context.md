# Epic 6 Context: Replenishment & Stock Intelligence

<!-- Compiled from planning artifacts. Edit freely. Regenerate with compile-epic-context if planning docs change. -->

## Goal

Give ops managers proactive stock intelligence so stockouts and expired stock are prevented without the system spending on its own: per-SKU (per-Warehouse) reorder points that alert on ATP breach within 5 minutes and pre-draft — but never auto-submit — suggested POs, plus expiry-approaching and aging-batch alerts that keep batch-tracked stock FEFO-honest. This is the "start of day" flow (UX Flow 5): Priya opens the bell panel, sees overnight breaches and an expiring batch, taps through to Replenishment, edits the drafted PO quantities, and submits — with alerts resolved before the floor's first pick. Deliberately small (two stories); it is pure read/alert/draftsurface over the ledger, with no new state the ledger doesn't already know about.

## Stories

- Story 6.1: Reorder points, breach alerts, and suggested POs
- Story 6.2: Expiry and aging alerts

## Requirements & Constraints

- Reorder points are per-SKU, per-Warehouse. On ATP breach, an alert reaches the ops manager within **5 minutes of the breach** — this is the only latency the PRD specifies, and it is a hard, testable consequence (FR-22).
- A suggested PO is drafted from default vendors and default quantities. The draft is editable before submission; **the system never auto-submits a PO in v1** — the human always commits the spend.
- For batch-tracked SKUs: when a batch approaches expiry within configurable lead days, it appears on an expiry dashboard and in FEFO pick suggestions (FR-23). Aging stock is visible by batch.
- Expiry lead days and reorder defaults are per-tenant configuration data, not code.
- Reorder breach and expiry alerts are **notification-panel entries only** (amber treatment, click-through to source). They are not mobile pushes — mobile pushes stay restricted to task assignment, approval-needed, and at-risk cutoff. No badge-count spam.
- Success looks like: breach alerts resolve before the floor's first pick; nothing reaches a stockout; nothing ships expired.
- Known future scope growth: a later market expansion amends this epic with seasonality-aware reorder points (seasonal retail vertical) — the reorder-point model should not preclude a temporal dimension, but nothing seasonal ships now.

## Technical Decisions

- A dedicated **replenishment module** owns reorder points, breach alerts, and suggested POs (FR-22/FR-23). It is a consumer of derived state, not a second balance book — breach detection reads ATP from the inventory core (ledger-as-truth); it never maintains or caches its own stock numbers.
- All state mutation goes through module command services (AD-10) — including scheduled work. Breach detection and expiry scanning are background jobs, and background jobs run through the same command layer via one scheduler: they re-evaluate authorization at command entry and take explicit `tenant_id`/`warehouse_id` context like any API request.
- Suggested POs flow into the PO lifecycle the inbound module already owns — the suggestion is a draft artifact, and submission rides the existing PO-creation path rather than a parallel one.
- Alert records must be shaped so they can land as notification-panel entries when the panel surface arrives.

## UX & Interaction Patterns

- Web-first, desktop-primary. Web < 768px is read + simple actions; heavy data work (editing reorder points, drafting POs) stays on desktop.
- Replenishment dashboard: reorder data table showing SKUs below point with suggested POs pre-drafted, ready to edit and submit in place (Flow 5).
- Reorder points inline-edit in the data table.
- Expiry dashboard: batches within lead days, amber treatment, click-through to the batch records; FEFO-priority flag on near-expiry stock.
- Data table pattern throughout: dense rows, cursor pagination (infinite scroll banned), sticky header, filter presets; stale-data inline refresh banner — never auto-refreshing lists.

## Cross-Story Dependencies

- **Epic 2 ← this epic.** 6.1 needs real-time ATP and non-negative reservations (story 2.3); 6.2 needs batch tracking and batch ledger history (story 2.4). Nothing else in the programme is a hard prerequisite.
- **Epic 3**: suggested POs ride the PO creation/lifecycle built in the inbound module; receiving consumes the resulting POs.
- **Epic 4**: FEFO pick suggestions (where near-expiry batches surface at pick) extend the picking flow's suggestion logic.
- **Epic 9** aggregates these alerts into the shared notification panel (bell) with its newest-first, amber, click-through contract — Epic 6 defines the alert entries; the full panel surface ships there, so the entry contract must stand on its own until then.
- Stories 6.1 and 6.2 are independent of each other and can land in either order.