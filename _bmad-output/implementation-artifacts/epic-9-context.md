# Epic 9 Context: Operational Visibility — Dashboard, Notifications & Audit

<!-- Compiled from planning artifacts. Edit freely. Regenerate with compile-epic-context if planning docs change. -->

## Goal

Give the Ops Manager a live KPI home that is truth, not estimates — every tile a projection over the ledger — plus one notification panel that spends attention only on what is actionable, and give the Owner a filterable, exportable, tamper-evident audit trail so compliance and investigation are self-serve. This is the cross-cutting close of the core programme: it aggregates signals from everything shipped before it (receiving, putaway, picking, dispatch, channels, replenishment/expiry, compliance) rather than adding new domain behaviour. Later expansion work (excursion, recall and statutory-register reporting) joins this audit surface.

## Stories

- Story 9.1: Operational dashboard
- Story 9.2: Notification panel and pushes
- Story 9.3: Global audit trail and async export

## Requirements & Constraints

- **Dashboard (FR-27):** per administered Warehouse, show dock-to-stock, pick rate, short-picks, GRN variances (incl. blind GRNs flagged for PO-matching), order accuracy, oversell/backorder events, expiry alerts, sync health per Channel, and dispatch pipeline. KPI values reconcile to the ledger — no "estimated" state exists. Dashboard renders < 2 s p95 for a tenant with 100k ledger events/month (NFR-6).
- KPIs back the product's success metrics, so their definitions must be measurable as stated: order accuracy = mis-picks + pack mismatches per 1,000 dispatched lines; dock-to-stock = delivery arrival to bin-located stock (median clock-hours); oversell = channel orders accepted where dispatchable stock was insufficient. Scan-rejection rate and adjustment count are counter-metrics — never presented as things to minimise.
- **Notifications:** sources are task assignments, approvals awaiting, reorder breaches, expiry, QC, sync health. Reorder breach alerts arrive ≤ 5 min from ATP breach (the only specified latency); expiry and QC have none. Mobile pushes are restricted to task assignment, approval-needed and at-risk carrier cutoff — reorder/expiry/breach alerts are panel entries only. No badge-count spam.
- **Audit trail (FR-28):** Owner sees all state-changing actions — who, what, when, reference document — with filters. Any ledger event is reachable from its reference document (GRN, order, adjustment) in ≤ 2 navigations. Export of 100k events completes asynchronously and notifies on completion.
- Every state change is attributable to actor, time and reference; audit retention ≥ 7 years implemented as a lifecycle (partitioning + archive tiering + restore-verified backups), not a policy statement (NFR-5). Exports carry a verifiable digest from the hash chain with the WORM anchor (AD-16).
- No custom report builder in v1 — fixed dashboards plus export.

## Technical Decisions

- **The reporting module owns FR-27/FR-28** (dashboard projections, audit trail, exports); **the notifications module** owns alerts and task push. Both read other modules only through facades and subscribe to domain events — never another module's tables. Reporting depends on inventory, not the reverse.
- **KPIs are ledger projections (AD-1)** — re-derivable from the ledger, never side-computed or independently stored numbers. Snapshots/checkpoints may avoid full-replay cost, but must be rebuildable.
- **Background work is sheddable (AD-17):** projections, exports and alerts yield to the scan path and order-accept traffic under load. Tiles stream best-effort and may lag at peak by design.
- **Tenant and warehouse scoping (AD-3) extends to reporting queries, projection rebuilds and export workers** — explicit tenant context, per-tenant artifact paths; any superuser bypass is a named, audited exception. Client scoping (AD-23/24) likewise: reporting and export paths take explicit client context or deliberately none; `ledger_events` carries `client_id`, D2C is the one-client case, no branching on 3PL-ness.
- **Tamper-evidence (AD-16):** ledger events are hash-chained; the chain head is periodically anchored to WORM-locked object storage (S3, ap-south-1); a chain break is a severity-1 alert. Digest exports must be verifiable against that anchor.
- **Exports and notification delivery cross the outbox (AD-7):** state change and outbound event commit in one transaction; relay is at-least-once with dead-letter; consumers are idempotent (AD-5).

## UX & Interaction Patterns

- **Overview** (sidebar, app-open home): KPI tiles = value + muted label + delta caption, each clicking through to the underlying ledger-filtered list. Live tiles stream best-effort; the **stale-data banner** is the governing pattern — inline refresh banner, manual refresh only, lists never auto-refresh. Carrier-cutoff pressure shows amber with time remaining on at-risk waves.
- **Notifications** (bell on web, system push on mobile): single panel, newest-first, amber-treated entries, click-through to source.
- **Reports / Audit** (sidebar): data table with cursor pagination, sticky header, column filter presets, async export for big pulls.
- Banned everywhere: infinite scroll, badge-count notification spam, modal stacks > 1 deep, hover-only affordances on touch / `sm` row actions, celebratory animation. Composition reference: the `key-web-overview` mockup (spine wins on conflict).

## Cross-Story Dependencies

- **Epic 9 ← Epics 2 + 4** (hard): the ledger, hash chain and reference-document linkage (Epic 2 established the ≤ 2-navigation rule early) and the outbound/dispatch pipeline.
- Tiles and panel entries consume signals owned elsewhere: receiving/GRN variances (Epic 3), short-picks and order accuracy (Epic 4), oversell/backorder and sync health (Epic 7), reorder/expiry alerts (Epic 6), conflicts and approvals (review queue), compliance artifacts (Epic 8). A tile whose source epic has not shipped must be handled explicitly, not faked.
- **Within the epic:** 9.3's async-export completion notification rides 9.2's notification panel; 9.1's tile click-throughs and 9.3's audit list share the ledger-filtered list surface.
- Epic 21 (per-client dashboards/reporting) and Epics 12/16-18 (excursion, recall, statutory registers) later extend these surfaces — keep the dashboard and audit trail client- and domain-agnostic.
