# Epic 13 Context: Returns & Reverse Logistics

<!-- Compiled from planning artifacts. Edit freely. Regenerate with compile-epic-context if planning docs change. -->

## Goal

Introduce the platform's first reverse flow. A dispatched order's units can be authorized for return, received and inspected scan-first on the existing mobile substrate against that authorization, and then dispositioned on the web — restocked to sellable, quarantined for review, or scrapped. Every outcome is its own registered ledger event, never a sign-flipped receipt or a reversal of the dispatch, so receiving analytics and inbound KPIs stay clean and the ledger stays append-only. This is a Tier 1 (Phase 3) domain epic: additive by construction, requiring no ledger migration. Planning gap: no PRD journey exists yet for a returns session (who inspects, what they decide, where the judgement call sits) — the UX spine explicitly declines to invent one, so story specs must make those decisions explicitly.

## Stories

- Story 13.1: Return authorization
- Story 13.2: Return receipt and inspection
- Story 13.3: Return disposition
- Story 13.4: Web returns and disposition
- Story 13.5: Mobile return task type

## Requirements & Constraints

- **Authorization (RMA):** only a *dispatched* order's units can be authorized for return; the authorization names the expected units and a reason.
- **Receipt & inspection:** returned units are received and inspected scan-first on mobile, against the authorization, reusing the receiving/offline/scan substrate rather than a parallel one.
- **Disposition:** every returned unit is dispositioned — restock, quarantine, or scrap — and each outcome is a distinct ledger event. Only a restock returns the unit to ATP.
- **Interim state is named:** a unit received but not yet dispositioned is in "received, awaiting disposition" and is **excluded from ATP** until dispositioned.
- Batch/serial identity must be carried through the return (serial cannot be in two bins' on-hand; full movement history of a dispatched serial/batch stays queryable in one query — the return extends that history).
- Quantities follow the fractional quantity model (milli-unit scaled integers internally, decimals only at API/UI edges, at the UoM's declared precision).
- Outside Tier 0, no story may require a ledger migration; a story that needs one is wrong and goes back to planning.

## Technical Decisions

- **Reverse movements are registered event types:** new arms are registered in the inventory module's ledger event registry (versioned envelope, typed `reference_doc` union, pinned batch/serial arms) — `return.received`, `return.restocked`, `return.scrapped`. Never free-form emission, never a negative-quantity receipt, never a dispatch reversal. Disposition decides which arm is written. Quarantine's representation (its own arm vs. a held state) must be decided explicitly in the spec — the planned arm list names only received/restocked/scrapped.
- **New `returns` module** owns RMAs and disposition; it crosses into inventory only through its public seam/events, never its tables.
- **Ledger is the only stock truth:** every movement writes one immutable ledger event in the same transaction as the relational state it drives; ATP/on-hand/held quantities are projections, re-derivable by replay; corrections are new events. Replay-reconciliation must still reproduce every balance.
- **One command layer:** all mutations (web, mobile replay, jobs) enter through command services that re-check role/approval gates against the current role epoch and write audit + events. Every write is idempotent by contract.
- **ATP arithmetic:** inventory publishes unallocated sellable = on-hand − QC-held − committed; awaiting-disposition and quarantined returned stock must land outside sellable.
- **Client dimension:** ledger events (and orders) carry a non-null `client_id`; return events inherit the client of the originating order/SKU and respect client RLS.
- **Offline:** mobile return scans queue in the encrypted outbox and replay with client-generated idempotency keys, re-authorized server-side; conflicts are never auto-merged; bin on-hand never goes negative.
- Contracts flow through OpenAPI; clients consume generated types.

## UX & Interaction Patterns

- **Web:** a "Returns" sidebar section holding return authorizations, the returns queue, and the disposition decision (restock / quarantine / scrap) presented as the existing **approval card** pattern (reason, context inline, ledger-history link, actions).
- **Status badge:** "↩ Awaiting disposition" — amber, word-first, lowest in badge ordering; a badge never degrades to glyph-only.
- **Mobile:** a new **Return** chip in the task-inbox switcher (All / Pick / Putaway / Count / Transfer / Return) and a linear **return-receipt** task flow (scan → banner → next, camera + HID interchangeable, manual entry as named fallback).
- The return flow reuses the receiving flow's **shape but not its decision basis**: receiving refuses wrong items on-device against the PO; a **blind return** (no cached authorization) cannot refuse on-device, so every scan reads as queued and the server decides later — this divergence must be stated **on the task screen**.
- Replay dedupe anchors to the RA line where one exists, otherwise to a device-minted op id bound to the badge-in session.
- Queue state is shown as a queued count, never as an error; server-rejected queued ops appear in the sync summary with retraction display. Every refusal announces its rule and alternative in the same accessible announcement.

## Cross-Story Dependencies

- Depends on Epics 2 (ledger/ATP), 3 (receiving substrate, QC hold, mobile scan flow) and 4 (dispatched orders). Built after the Phase 0 foundations (Epic 10 fractional quantities, Epic 21-1/21-2 client dimension), whose conventions apply.
- Within the epic: 13.1 (authorization) precedes 13.2 (receipt), which precedes 13.3 (disposition events); 13.4 (web) and 13.5 (mobile) consume the backend endpoints — backend lands first.
- Phase 3 epics are reorderable by demand; no other epic gates or is gated by Epic 13. Epic 21's billing metering (projection over ledger events) may later consume return events.
