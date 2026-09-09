# Epic 2 Context: Inventory Backbone — One Trusted Number

<!-- Compiled from planning artifacts. Edit freely. Regenerate with compile-epic-context if planning docs change. -->

## Goal

Build the correctness engine of the WMS: an append-only inventory ledger that is the single source of truth for every stock quantity, with on-hand and ATP as derived projections. Every movement — receipt, putaway, pick, dispatch, transfer, adjustment, count variance — becomes an immutable, explainable event; ATP is real-time and reservations are atomic so two channels can never both sell the last unit; batch/serial traceability makes expired stock unshippable and unit history one query away. This is the foundation every later epic (receiving, outbound, counts, channels, dashboards) depends on — the system the business can trust at 11:59 PM during a flash sale.

## Stories

- Story 2.1: Append-only ledger core and derived quantities
- Story 2.2: Continuous replay-reconciliation
- Story 2.3: Real-time ATP and atomic reservations
- Story 2.4: Batch and serial traceability
- Story 2.5: Inventory surfaces — stock, batches, and the ledger timeline

## Requirements & Constraints

- Every stock movement writes exactly one immutable ledger event carrying type, SKU, batch/serial, from/to bin, signed quantity, actor, occurred-at/recorded-at timestamps, and a reference document — committed in the same transaction as any relational state it drives.
- No code path may mutate a quantity without writing a ledger event (verified by architecture test); corrections are new events, never edits.
- Replaying any SKU/bin's events must reproduce its derived on-hand exactly.
- Continuous replay-reconciliation detects divergence, then quarantines the affected scope → rebuilds projections → alerts, naming the divergent scope and event range — it never silently repairs. It runs as sheddable background work that yields to interactive scanning under peak load.
- At any read, ATP never exceeds on-hand − reserved − QC-held − buffers. QC-held and buffer slots are hooks this epic leaves; later epics populate them.
- Two concurrent reservations for the last unit: exactly one succeeds; the loser receives a deterministic unavailable outcome (backorder or reject per policy) — never an error retry.
- Reservation acceptance must sustain 15× the tenant's median order rate for 2 hours with zero oversell and no reservation-pool deadlock (load-tested).
- Batch-tracked SKUs record mfg/expiry per batch and pick FEFO by default; FEFO override requires a reason code and is audit-logged. A serial can exist in at most one bin's on-hand; duplicate serial scans are rejected naming the conflicting location. Full movement history for a dispatched serial/batch returns in one query.
- Each warehouse's ledger sequence is gap-free; the sequence number is the replay order.

## Technical Decisions

- Event-sourced modular monolith: the ledger is the only stock truth; on-hand/ATP are projections. The inventory module (ledger, projections, ATP, reservation script + journal) depends on nothing; every stock-touching module depends on it, and it may never import another module's interface.
- Exclusive entity ownership: catalog owns batch/serial identity, ledger owns batch/serial quantities; tenancy owns bin master data, putaway owns bin operational state.
- Reservations have a single atomic decision point — a pre-declared-keys Valkey Lua script (hash-tag co-location for multi-key ops); no module implements a second check-and-decrement. Postgres holds the durable reservation journal (owner, TTL, state held→committed→released/expired, serialized terminal transitions); Postgres wins on all divergence — cold start rebuilds Valkey from ledger + journal; commit-then-apply ordering.
- The ledger event envelope is a versioned, registered schema: typed `reference_doc` union, pinned batch/serial discriminated-union arms; new event types are added by registration, not free-form emission; grammar changes are additive migrations only.
- Tamper-evident substrate: events are hash-chained (each carries its predecessor's hash), the chain head is periodically anchored to WORM-locked storage, and verifiable digest exports are producible; any chain break is a severity-1 alert.
- Integers for quantities (base-UoM), UTC timestamps, UUIDv7 IDs; ULID idempotency keys on all mutating endpoints; mutation only through command services (role-epoch re-evaluated at command entry).
- Divergence handling: quarantine → rebuild → alert, never auto-heal.

## UX & Interaction Patterns

- Inventory surface: dense data tables (~40px rows) with cursor pagination (infinite scroll banned), sticky headers, filter presets, tabular numerals on all aligned numeric columns, row actions on hover (desktop) / tap (touch), stale-data refresh banner — lists never auto-refresh.
- Ledger timeline: vertical event list showing event type, signed quantity, actor, time, and a reference-document link (any event reachable from its reference doc in ≤ 2 navigations — a contract established here, consumed by later epics).
- Batch/serial detail views show dates, FEFO order, and per-unit history; QC-held and buffer ATP deductions are hooks in the ATP formula but their surfaces live in later epics.

## Cross-Story Dependencies

- Depends on Epic 1: tenants, warehouses, zones/bins, and SKUs (with batch/serial tracking flags) must exist before any movement can be recorded.
- Within the epic: 2.1 (ledger core) is the substrate for all others; 2.2 (reconciliation) verifies 2.1's projections; 2.3 (ATP/reservations) and 2.4 (traceability) ride on ledger events; 2.5 (surfaces) renders the ledger and projections.
- Later epics consume this one, not vice versa: Epic 3's receiving populates QC-held ATP; Epics 4/5/7 use the reservation machinery; channel safety buffers become standing reservations in Epic 7 — this epic publishes only unallocated sellable quantity and stays channel-agnostic.