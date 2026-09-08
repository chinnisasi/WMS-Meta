---
id: SPEC-WMS-Meta
companions:
  - ../planning-artifacts/prds/prd-WMS-Meta-2026-09-07/prd.md
  - ../planning-artifacts/prds/prd-WMS-Meta-2026-09-07/addendum.md
  - ../planning-artifacts/architecture/architecture-WMS-Meta-2026-09-08/ARCHITECTURE-SPINE.md
sources: []
---

> **Canonical contract.** This SPEC and the files in `companions:` are the complete, preservation-validated contract for what to build, test, and validate. Source documents listed in frontmatter are for traceability — consult them only if you need narrative rationale or prose color this contract intentionally omits.

# Warehouse Management System (WMS) — v1

## Why

Small e-commerce sellers in India run warehouses on spreadsheets, WhatsApp, and memory: oversold flash sales, expired batches shipped, unexplained variances, dispatches blocked by GST paperwork. Existing tools gate warehousing behind order-management add-ons or are enterprise-priced. This is a **pain to solve** for that seller (owner, ops head, accountant) and an **opportunity to capture**: inventory correctness as the non-negotiable core — every movement an auditable event, ATP reserved in real time, no channel selling what the floor can't ship — plus India-compliance nativity (GST, e-way, local carriers) that competitors treat as an export feature. The wedge is the minimum end-to-end process (receive, putaway, pick, pack, ship, count) done correctly and fast; the system the *floor* actually uses.

## Capabilities

- **CAP-1**
  - **intent:** A tenant owner can onboard self-serve — provision tenant/warehouse/zones/bins, import the catalog with partial-commit + row-level error reports, and invite users into 4 permission-gated roles (FR-1…3).
  - **success:** A 5,000-row import with 30 bad rows commits 4,970 and produces a downloadable per-row error report; "fix mode" re-import takes only previously failed rows; an Operator cannot approve over-threshold adjustments or change Channel settings; role changes take effect on the user's next action.
- **CAP-2**
  - **intent:** The system keeps inventory correct via an append-only ledger, real-time ATP, atomic reservations, and batch-FEFO/serial traceability (FR-4…6).
  - **success:** Two concurrent reservations for the last unit → exactly one succeeds, loser gets a deterministic outcome; on-hand for any SKU/bin re-computes exactly by replaying events; a dispatched serial's full movement history returns in one query; a FEFO override requires a reason code and is audit-logged.
- **CAP-3**
  - **intent:** Ops can create POs and the floor receives against them scan-first (partial and blind), with QC holds quarantining suspect stock out of ATP (FR-7…9).
  - **success:** GRN creation takes ≤ 4 scans + 1 confirm for a single-SKU single-lot pallet; a partial GRN leaves the PO line open with correct remaining quantity; over-receipt requires Ops Manager approval; a pick request against QC-held stock is rejected.
- **CAP-4**
  - **intent:** The system directs putaway by rules and lets Ops administer bins (block/merge/retire) without code changes (FR-10, 11).
  - **success:** A full/blocked bin rejects placement naming the reason; blocking removes a bin from suggestions and picking immediately; retire-with-stock is rejected naming the SKUs/quantities blocking it; suggestion ≠ actual is recorded and measurable.
- **CAP-5**
  - **intent:** Orders (manual + idempotent channel ingestion) group into waves/picklists that the floor picks scan-verified with offline tolerance, with short-pick re-planning (FR-12…15).
  - **success:** The same channel payload delivered twice creates exactly one order; scans performed offline land in the ledger in order and exactly once (end-to-end idempotency test); a wrong-item scan is rejected in < 500 ms on-device with a specific reason; a batch picklist's path visits each bin at most once.
- **CAP-6**
  - **intent:** Pack stations verify picked orders and the system rates, labels, manifests, and dispatches with tracking writeback to the Channel (FR-16, 17).
  - **success:** A pack scan mismatching the picklist is rejected with the discrepancy named; label-generation failure surfaces a retryable error and never marks the order dispatched; dispatch closes the reservation and writes the outbound ledger event atomically.
- **CAP-7**
  - **intent:** Stock moves between bins/warehouses as Transfer Orders and corrections as reason-coded, approval-gated adjustments (FR-18, 19).
  - **success:** In-transit stock is excluded from ATP at both ends until inbound confirm; an unapproved over-threshold adjustment cannot change ATP — it sits pending with the approver notified.
- **CAP-8**
  - **intent:** ABC-scheduled and on-demand cycle counts run bin-by-bin without freezing operations, variances routing into approval with ledger history attached (FR-20, 21).
  - **success:** Concurrent picks/receipts during a count are flagged, not lost; counted ≠ expected creates a variance record, never a silent write-off; variance resolution is itself audit-logged.
- **CAP-9**
  - **intent:** The system watches reorder points, alerts on breach and expiry, and drafts (never auto-submits) suggested POs (FR-22, 23).
  - **success:** Alert latency from ATP breach ≤ 5 minutes; a drafted PO is editable before submission; a batch within expiry lead days appears on the expiry dashboard and in FEFO pick suggestions.
- **CAP-10**
  - **intent:** Channels (Shopify, Amazon.in, Flipkart, manual) sync availability from ATP with per-channel Safety Buffers and backorder policy; orders ingest idempotently and fulfillment writes back (FR-24, 25).
  - **success:** Availability sync latency p95 ≤ 60 s; buffer exhaustion on a channel zeroes that channel's listing before the shared pool empties; ingested order → reservation completes ≤ 10 s p95; a channel-cancelled order releases its reservation atomically.
- **CAP-11**
  - **intent:** Dispatches generate GST-compliant invoices and single/batch e-way bills without the accountant touching the GST portal by hand (FR-26).
  - **success:** Invoice line values reconcile exactly to dispatched qty × rate × GST; e-way generation failure is retryable and never blocks recording the dispatch; the HSN summary produces per-period totals for filing.
- **CAP-12**
  - **intent:** Ops sees real-time KPIs per warehouse and a global exportable audit trail (FR-27, 28).
  - **success:** KPI values reconcile to the ledger (projections, not side-computed); dashboard renders < 2 s p95 at 100k ledger events/month; export of 100k events completes asynchronously with completion notification; any ledger event is reachable from its reference document in ≤ 2 navigations.
- **CAP-13**
  - **intent:** Floor operators work from one mobile task inbox, scanning by camera or paired HID, offline-tolerant throughout (FR-29, 30).
  - **success:** Task state matches server state after reconnect (offline test suite); scan-to-decision ≤ 1.5 s on a mid-range Android on-device; a barcode value resolving to two SKUs within a tenant is prevented at catalog entry.

## Constraints

- NFR-1: zero tolerance for ledger/derived-state divergence — continuous replay-reconciliation alerts on any mismatch.
- NFR-2: order acceptance + reservation sustains 15× the tenant's median order rate for 2 h without oversell or reservation-pool deadlock; load-tested before every peak season.
- NFR-3: the mobile client operates through ≥ 30 min connectivity loss with zero scan loss; replay is idempotent and order-preserving per task.
- NFR-4: `tenant_id` scoped on every data access path; a cross-tenant read is severity-1; load-shedding protects interactive scanning paths over background sync.
- NFR-5: every state change attributable (actor, time, reference); audit retention ≥ 7 years (GST norms), tamper-evident per AD-16.
- NFR-6: latency budgets — web p95 < 2 s; scan decision ≤ 1.5 s on-device; availability sync p95 ≤ 60 s; carrier label gen p95 ≤ 5 s.
- Architecture spine AD-1…AD-17 are binding (companion `ARCHITECTURE-SPINE.md`): event-sourced modular monolith; Postgres-truth reservations with atomic Valkey decisions; buffers as standing reservations; offline work settles pre-reserved stock only; versioned ledger event registry; KMS-enveloped secrets; hash-chained audit; scan path protected over background work.
- India-first compliance native: GST/HSN on invoices, e-way thresholds as versioned config data (never code literals); India-region hosting preferred for GST-adjacent data (OQ6). Batch **and** serial tracking in v1 is a deliberate wedge — serial defers first under scope pressure.
- Data governance: tenant data isolated and exportable; no cross-tenant analytics without aggregation + consent; marketplace API terms respected in retention and sync patterns.
- Cost guardrails: integration call volumes metered per tenant with automatic circuit-breaking on runaway loops; the same counters keep commercial tiering technically meterable.

## Non-goals

- Not an ERP/accounting system — Tally/Zoho Books is the v2 boundary; compliance documents only, no ledgers of account.
- No labor management, yard management, or advanced picking strategies (zone/cluster/cartonization) — single-order + batch picking only in v1.
- No robotics/AMR, no RFID (barcode-era v1; scan-event abstraction keeps RFID tolerance).
- No native POS; no EDI (940/945/856) in v1; no 3PL multi-client billing (tenancy designed for it, product surface not).
- No custom report builder (fixed dashboards + export); no warehouse floor-plan visual editor (grid-based bins only).
- No RF handhelds or robotics-era devices in v1 (camera + HID only); no regional carriers beyond the v1 India set.

## Success signal

- **SM-1:** median time from tenant signup to first GRN ≤ 1 business day. **SM-2:** ≥ 70% of provisioned Operator seats scanning ≥ 4 days/week by week 8 per tenant. **SM-3:** mis-picks + pack mismatches ≤ 2 per 1,000 dispatched lines by week 12. **SM-4:** oversell events = 0 tolerated at any load. Counter-metrics (scan-rejection rate, adjustment count) are tracked, never minimized.

## Assumptions

- Batch and serial tracking both in v1 (serial defers first under scope pressure).
- Blind receiving permitted with reason codes + dashboard flagging (real vendors deliver unannounced).
- Slotting suggestions computed nightly, not real-time.
- Marketplace API approvals (Amazon.in, Flipkart) land in time; fallback launch = Shopify + manual.
- Camera scanning on mid-range Android meets the 1.5 s decision budget; RF handhelds out of v1.
- v1 carrier set: Delhivery, Blue Dart, Ecom Express, Shiprocket (pending commercial confirmation).
- Product name "WMS" is a working title; native apps over PWA; infra on AWS ap-south-1 (spine-tagged assumption).

## Open Questions

- OQ1: Which India carrier set is launch-realistic — direct APIs vs aggregator-first (Shiprocket), at what volume commitments? (Blocks only carrier-adapter detail; the adapter port is fixed.)
- OQ2: Do marketplace API partner approvals (Amazon.in SP-API, Flipkart) land in time, or does Shopify + manual launch alone satisfy the launch plan?
- OQ3: E-way Bill generation path — official portal APIs vs GSP intermediary for v1 reliability?
- OQ4: Pricing/packaging — warehouse-count vs order volume as metered axis, free-tier cut? (Commercial workstream; only "technically meterable" is a spec constraint.)
- OQ5: Serial tracking in v1 or v1.5? (Adds catalog + picking surface; spine's ledger union supports either.)
- OQ6: India-region hosting for GST data from day one, or platform default region at launch?