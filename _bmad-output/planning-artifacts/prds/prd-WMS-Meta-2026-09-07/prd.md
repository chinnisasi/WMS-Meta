---
title: Warehouse Management System (WMS)
status: draft
created: 2026-09-07
updated: 2026-09-07
---

# PRD: Warehouse Management System (WMS)
*Working title — confirm.*

## 0. Document Purpose

This PRD defines a launch-grade, multi-tenant B2B warehouse management SaaS for small- and medium-business e-commerce sellers, launching India-first. It is written for the PM (Sasidhar), downstream `bmad-ux` / `bmad-architecture` / epic-and-story workflows, and any external collaborator. Vocabulary is anchored in §3 Glossary and used verbatim everywhere; features are grouped in §4 with globally numbered FRs (FR-1…FR-N) for stable downstream reference; user journeys are numbered UJ-1…UJ-N and referenced by ID. Assumptions made without confirmation are tagged `[ASSUMPTION]` inline and indexed in §9. Technical *how* (event ledger design, offline sync, tenancy model) lives in `addendum.md` alongside this PRD — this document stays capability-focused. Inputs for this PRD: three web-research digests (Zoho Inventory feature/integration survey; best-in-class WMS feature survey; WMS scalability-pattern survey), archived in `addendum.md`.

## 1. Vision

Small e-commerce sellers in India run their warehouses on spreadsheets, WhatsApp groups, and memory. Stock lives in one head, orders arrive across Shopify, Amazon.in, and Flipkart, and the cost is concrete: oversold flash-sale items, expired batches shipped to customers, count variances nobody can explain, and dispatches held hostage by GST paperwork. Existing tools either treat warehousing as an afterthought (order-management-first products gate bins and picklists behind add-ons) or are enterprise WMSs priced and complex for a 5,000 sq ft operation.

This product is a warehouse management system built for that seller: a web dashboard for the operations head, a scan-first mobile client for floor operators that keeps working through Wi-Fi dead zones, and inventory correctness as the non-negotiable core — every stock movement is an auditable event, availability is reserved in real time, and no channel can sell what the floor can't ship. It speaks India's compliance language natively (GST, e-way bills, India carriers) instead of treating them as an export feature.

The wedge is the minimum end-to-end process — receive, putaway, pick, pack, ship, count — done correctly and fast. Expansion follows the seller's growth: more warehouses, batch/serial traceability, more channels, deeper analytics. The product competes on being the system the *floor* actually uses, and on inventory numbers that are right at 11:59 PM during a flash sale.

## 2. Target User

### 2.1 Jobs To Be Done

- **Functional (owner/founder):** "When I sell on three channels, let me trust one stock number, so that I stop refunding oversells and stop losing selling days to stockouts."
- **Functional (ops head):** "When stock arrives, let my team receive, putaway, and pick with scanners and zero guesswork, so that throughput scales without headcount."
- **Functional (ops head):** "When a customer asks where their order is, let me see pick → pack → dispatch status in one screen, so that support answers take seconds."
- **Functional (accountant/owner):** "When goods move, let GST and e-way documentation generate themselves, so that compliance never blocks a dispatch."
- **Emotional (owner):** confidence during a flash sale instead of dread — the system held, nothing oversold, the floor wasn't chaos.
- **Social (owner):** presenting clean stock and dispatch reports to a marketplace account manager, a bank, or an investor without a spreadsheet reconciliation week.

### 2.2 Non-Users (v1)

- Mid-market/enterprise warehouses needing labor management, engineered standards, or yard management — different product, different sales motion.
- 3PLs running many client brands with per-client billing — a v2 wedge, not v1.
- Businesses whose core need is accounting, not warehousing — we integrate with Tally/Zoho Books rather than replace them.
- Retail POS-centric single-store shops.

### 2.3 Key User Journeys

- **UJ-1. Priya onboard her catalog and receive the first PO.**
  - **Persona + context:** Priya, operations head at a 30-person D2C home-goods seller in Bengaluru, moving off spreadsheets after a double-oversell incident.
  - **Entry state:** registered tenant on the web dashboard; one warehouse configured; catalog CSV exported from their current sheet.
  - **Path:** imports the catalog (SKU, name, UoM, GST rate, HSN) → reviews and fixes the row errors the import report flags → defines zones and bins on a simple grid (A-01-01 style) → creates a PO for 200 units across 4 SKUs → hands the PO number to the floor.
  - **Climax:** Ramesh scans the delivery against the PO on the mobile app; Priya watches received-vs-ordered fill in live on her dashboard, and dock-to-stock time is captured automatically.
  - **Resolution:** stock exists in bins with batch dates; reorder thresholds set from import defaults; the spreadsheet is now the backup, not the source.
  - **Edge case:** the delivery is short 20 units of one SKU — she records a partial GRN against the PO, and the open quantity stays visible on the PO until closed.

- **UJ-2. Ramesh pick and pack through a Wi-Fi dead zone.**
  - **Persona + context:** Ramesh, floor operator, part of a 4-operator team, works aisles where Wi-Fi drops.
  - **Entry state:** logged into the mobile scan client; a picklist of 12 orders released to him.
  - **Path:** scans his badge → the client shows the directed pick path → he scans each bin, scans the item, the line ticks green → Wi-Fi drops in aisle C; he keeps scanning — the client queues locally and shows queued-count, not an error → connectivity returns and the queue replays silently.
  - **Climax:** all 12 orders picked, zero scan errors, no "wait for network" moments.
  - **Resolution:** orders land at the pack station; Ramesh's pick rate for the shift is recorded.
  - **Edge case:** he scans an item that isn't on the picklist — the client rejects it loudly (wrong item/wrong bin reason) and offers the nearest correct bin.

- **UJ-3. Priya survive a flash sale without an oversell.**
  - **Persona + context:** Priya, during a 2-hour Instagram-live sale synced to Shopify and Amazon.in.
  - **Entry state:** real-time Available-to-Promise per channel with safety buffers configured; sale is live.
  - **Path:** orders flood in; the system reserves stock atomically at order-accept time, not dispatch time → buffers go to zero as true availability drops → channels are auto-quantity-synced; one channel's buffer exhausts and that channel's listing shows reduced quantity before the pool is empty → an order that loses the race is auto-accepted as a backorder per her policy, not a cancel-and-apologize.
  - **Climax:** zero oversells; cancellations stay in normal ranges despite 15× order volume.
  - **Resolution:** post-sale report shows per-channel reservations, buffer events, and backorders taken.
  - **Edge case:** two channels race for the last unit — one reservation wins deterministically; the loser follows the configured backorder policy.

- **UJ-4. Ankit close the month with a clean count and clean dispatches.**
  - **Persona + context:** Ankit, founder, also covers for the accountant during GST filing week.
  - **Entry state:** web dashboard; a scheduled cycle count on the fastest-moving ABC class is due.
  - **Path:** assigns the count to Ramesh's mobile client (no ops freeze) → Ramesh counts bin by bin; a variance appears on one SKU → Ankit reviews the movement ledger for that bin — every receipt, pick, and adjustment is one tap away → approves an adjustment with a reason code → generates e-way bills for the day's dispatches in one batch.
  - **Climax:** variance explained and closed in minutes from the audit trail, not an hour of guesswork; e-way bills batch-generated without touching the GST portal by hand.
  - **Resolution:** the month closes with a variance report and a compliant dispatch trail.
  - **Edge case:** the variance exceeds the approval threshold — it escalates to Ankit's role before it can be applied.

## 3. Glossary

- **Tenant** — one paying business on the platform. All data partitions by Tenant. A Tenant has one or more **Warehouses**.
- **Warehouse** — a physical stocking site belonging to a Tenant. The first-class partition key for operations and data.
- **Zone** — a subdivision of a Warehouse (receiving, bulk storage, forward pick, quarantine, dispatch). Zones contain **Bins**.
- **Bin** — the smallest stocked location, with a code (e.g., `A-03-12`), capacity, and type. Inventory is tracked at Bin level.
- **SKU** — a stock-keeping unit: the sellable/stockable item identity. Has UoM, GST rate, HSN code, and optional **Batch**/**Serial** tracking.
- **UoM** — unit of measure, with conversions (e.g., 1 carton = 12 pcs).
- **Batch** — a received lot of a SKU (with mfg/expiry dates where applicable). Batch-tracked SKUs rotate FEFO.
- **Serial** — a unit-level identity for serialized SKUs.
- **PO** — purchase order to a vendor; the basis of **Receiving**.
- **ASN** — advance shipping notice from a vendor; optional pre-registration of an inbound delivery. (v1: manual entry only.)
- **GRN** — goods receipt note: the record of what physically arrived against a PO (full or partial).
- **QC Hold** — a quarantine state blocking received stock from sale until inspected/released.
- **Putaway** — the move of received stock from dock to a Bin; **directed putaway** is system-suggested by rules (velocity, capacity, zone).
- **ATP (Available-to-Promise)** — real-time sellable quantity = on-hand − reserved − QC-held − safety buffer.
- **Reservation** — an atomic hold of ATP for an accepted order. The oversell-protection primitive.
- **Safety Buffer** — per-channel reserved quantity withheld from a channel's synced availability.
- **Picklist** — a released list of pick tasks for one or more orders, scan-verified on the mobile client.
- **Wave** — a scheduled grouping of orders into Picklists by policy (carrier cutoff, priority, size).
- **Pack Station** — a desk/flow where picked orders are verified, packed, labeled.
- **Dispatch** — the handover of a packed order to a carrier; closes the outbound loop and triggers tracking + inventory events.
- **Transfer Order** — a planned stock move between Bins or between Warehouses.
- **Adjustment** — a stock correction with reason code and approval path, recorded in the ledger.
- **Cycle Count** — a scheduled or on-demand count of a Bin/SKU subset that doesn't freeze operations.
- **Inventory Ledger** — the append-only event record of every stock movement; current quantities are derived views over it.
- **Channel** — an external sales surface (Shopify, Amazon.in, Flipkart, manual order entry) whose availability is synced from ATP.
- **E-way Bill** — the India GST e-way document required for consignment movement above threshold value.
- **GRN Variance** — difference between ordered and received quantity on a PO line.
- **Dock-to-Stock Time** — elapsed time from delivery arrival to Bin-located stock; a core KPI.

## 4. Features

### 4.1 Tenant Onboarding & Administration

**Description:** A new Tenant signs up, creates their first Warehouse, defines Zones/Bins, imports their catalog, and invites users with roles. The importer is forgiving by design: CSV/XLSX with a row-level error report the user can fix and re-upload without starting over. Roles: Owner, Ops Manager, Operator, Accountant — with permission sets that gate approvals and views. Realizes UJ-1.

**Functional Requirements:**

#### FR-1: Tenant and Warehouse provisioning

An Owner can register a Tenant, create Warehouses, and define Zones and Bins (manual grid generator or import) before any stock exists.

**Consequences (testable):**
- Bin codes are unique per Warehouse; duplicates are rejected with the conflicting code named.
- A Tenant with zero Warehouses cannot create stock records (no orphan inventory).
- System emits a setup-completion checklist and tracks its state per Tenant.

#### FR-2: Catalog import and management

An Ops Manager can import SKUs from CSV/XLSX (SKU, name, UoM, UoM conversions, GST rate, HSN, batch/serial flags, reorder defaults) and can manage SKUs individually thereafter.

**Consequences (testable):**
- A 5,000-row import with 30 bad rows commits the 4,970 good rows and produces a downloadable error report naming each bad row and reason.
- Re-import after fixing accepts only previously failed rows when the user selects "fix mode".
- Duplicate SKU codes are rejected, not silently merged.

#### FR-3: User, role, and permission management

An Owner can invite users, assign roles (Owner, Ops Manager, Operator, Accountant), and permissions gate every capability in this PRD.

**Consequences (testable):**
- An Operator cannot approve an Adjustment above the threshold (see FR-26) or change Channel settings.
- Role changes take effect on the user's next action, not next login.
- All role changes are audit-logged.

### 4.2 Inventory Backbone: Ledger, ATP, Traceability

**Description:** The core correctness engine. Every stock movement — receipts, putaways, picks, dispatches, transfers, adjustments, count variances — is an event in the append-only **Inventory Ledger**; on-hand quantities and ATP are derived views. ATP is computed in real time and **Reservations** are atomic, so two channels can never both sell the last unit. Batch-tracked SKUs rotate FEFO; serialized SKUs track unit identity. `[ASSUMPTION: batch and serial tracking are in v1 for batch-tracked categories (FMCG/food/pharma-adjacent sellers) — this is a differentiator vs Zoho's Premium gating; if scope pressure demands, serial tracking defers before batch tracking does.]` The architecture behind this feature is specified in `addendum.md` (ledger + projections, reservation mechanics).

**Functional Requirements:**

#### FR-4: Append-only Inventory Ledger

The system records every stock movement as a Ledger event (type, SKU, Batch/Serial, from/to Bin, qty, actor, timestamp, reference document) and derives on-hand and ATP from it.

**Consequences (testable):**
- No code path mutates a quantity without writing a Ledger event.
- On-hand for any SKU/Bin can be recomputed by replaying its events and matches the derived value.
- Ledger events are immutable; corrections happen as new events.

#### FR-5: Real-time ATP and atomic Reservation

The system maintains per-Channel-visible ATP in real time and accepts Reservations atomically at order-accept time.

**Consequences (testable):**
- Two concurrent reservations for the last unit: exactly one succeeds; the loser receives a deterministic "unavailable" outcome (backorder or rejection per policy, FR-24).
- ATP never exceeds on-hand − QC-held − reserved − buffers, at any read.
- Reservation round-trip completes under load spikes (see NFR-2) without oversell.

#### FR-6: Batch and serial traceability

A Batch-tracked SKU records mfg/expiry per Batch and picks FEFO by default; a Serial-tracked SKU records unit-level identity through receive → pick → dispatch.

**Consequences (testable):**
- FEFO override by an Operator requires a reason code and is audit-logged.
- A serial number cannot be in two Bins' on-hand simultaneously; duplicate scans are rejected with the conflicting location named.
- Given a dispatched serial/batch, the system returns its full movement history in one query.

### 4.3 Inbound: POs, Receiving & QC

**Description:** Ops creates POs (or receives them via integration, FR-27); floor receives against them on the mobile client by scanning, producing a GRN — partial receipts supported with open quantities staying visible. QC Holds quarantine suspect stock out of ATP until released. Receiving against a PO is deliberately the most polished flow in v1 — it's the single highest-leverage process per research. Realizes UJ-1.

**Functional Requirements:**

#### FR-7: PO creation and lifecycle

An Ops Manager can create POs (vendor, lines, qty, cost, expected date), amend them before receipt, and close them with open quantities cancelled or carried.

**Consequences (testable):**
- A PO line shows ordered, received-to-date, and open quantity at all times.
- A closed PO cannot receive; attempted receipt is rejected with the PO state named.

#### FR-8: Scan-based receiving and GRN

An Operator can receive against a PO on the mobile client by scanning SKU/barcode and entering/scanning quantities, producing a GRN per delivery; blind-receive (without PO) is permitted with a reason code. `[ASSUMPTION: blind receiving allowed in v1 because real vendors deliver unannounced; blind GRNs are flagged on the dashboard for PO-matching.]`

**Consequences (testable):**
- Receiving over the PO's open quantity requires Ops Manager approval and creates an over-receipt event.
- A partial GRN leaves the PO line open with correct remaining quantity.
- GRN creation takes ≤ 4 scans + 1 confirm for a single-SKU single-lot pallet (field-verified target).

#### FR-9: QC hold and release

An Ops Manager can place received stock into QC Hold (bin-level quarantine state) and release it to ATP after inspection.

**Consequences (testable):**
- QC-held stock is excluded from ATP and cannot be picked; a pick request against it is rejected.
- Release records inspector, decision, and timestamp in the Ledger.

### 4.4 Putaway & Location Management

**Description:** After GRN, the system suggests putaway Bins by rules (velocity class, capacity, zone compatibility) and the Operator scan-confirms the placement. Bins can be reordered, blocked, or re-dimensioned without code changes. Simple slotting suggestions (fast-movers toward the golden zone) are computed nightly from movement history. `[ASSUMPTION: nightly heuristic re-slotting suggestions rather than real-time optimization — right-sized for SMB v1.]`

**Functional Requirements:**

#### FR-10: Directed putaway

The system suggests a putaway Bin per GRN line and an Operator scan-confirms actual placement (which may differ from suggestion with a reason).

**Consequences (testable):**
- Placing stock into a full/blocked Bin is rejected with capacity or block reason named.
- Suggestion ≠ actual is allowed and recorded; suggestion accuracy is measurable per report (SM-3).

#### FR-11: Bin administration

An Ops Manager can create, block, merge, or retire Bins; a Bin with on-hand stock cannot be deleted, only retired-after-empty.

**Consequences (testable):**
- Blocking a Bin removes it from putaway suggestions and picking immediately.
- Retire-with-stock is rejected, naming the SKUs/quantities blocking it.

### 4.5 Outbound: Orders, Waves & Scan-Verified Picking

**Description:** Orders arrive from Channels (FR-24/FR-27) or manual entry; acceptance reserves ATP. Order grouping into Waves runs on policy (carrier cutoff, priority, size); the system generates directed Picklists (single-order and batch picking in v1 — batch is the one "advanced" pick method included because SMB sellers hit multi-order volume quickly). Floor operators pick scan-verified on the mobile client. Realizes UJ-2, UJ-3.

**Functional Requirements:**

#### FR-12: Manual order entry and channel order ingestion

An Ops Manager can create orders manually; Channel orders ingest automatically with idempotent de-duplication.

**Consequences (testable):**
- The same channel order payload delivered twice creates exactly one order.
- A manual order for quantity exceeding ATP is warned and either backordered or blocked per policy (FR-24).

#### FR-13: Wave and picklist generation

The system groups accepted orders into Waves by configurable policy and generates Picklists (single-order or batch) with a directed pick path.

**Consequences (testable):**
- A batch Picklist's path visits each Bin at most once, and total path steps ≤ sum of single-order paths for the same orders.
- Wave release respects carrier cutoff times configured per Channel/carrier.

#### FR-14: Scan-verified picking with offline tolerance

An Operator picks against a Picklist on the mobile client, scanning Bin then item; the client queues operations locally during connectivity loss and replays idempotently on reconnect. Realizes UJ-2.

**Consequences (testable):**
- A wrong-item or wrong-bin scan is rejected in < 500 ms on-device with a specific reason.
- Scans performed offline land in the Ledger in order and exactly once, verified by end-to-end idempotency test.
- Client shows queue depth (not an error) while offline; nothing is lost on force-quit.

#### FR-15: Short-pick handling

An Operator can short-pick (bin has less than task quantity) with a reason; the task system re-plans (alternate Bin suggestion or partial order) without manual replanning.

**Consequences (testable):**
- A short-pick event triggers an alternate-Bin suggestion within the same Picklist when stock exists elsewhere.
- Short-picks are aggregated in the dashboard (SM-3) as a slotting/accuracy signal.

### 4.6 Packing & Shipping

**Description:** Pack stations verify picked orders (scan), support packing slips, weight/dimension capture, carrier selection with rate comparison among configured India carriers, label generation, manifesting, and Dispatch handover. Tracking writes back to the Channel.

**Functional Requirements:**

#### FR-16: Pack station verification

An Operator at a Pack Station scans the picked order, confirms contents (with weight/dims optional), and prints/generates a packing slip.

**Consequences (testable):**
- Scanning an order at pack that mismatches its Picklist contents is rejected with the discrepancy named.
- Pack completion emits the packing event to the Ledger and moves the order to Ready-to-Dispatch.

#### FR-17: Carrier rating, label generation, and dispatch

The system rates the shipment across configured carriers, generates the carrier label and manifest, and records Dispatch with carrier + tracking ID; tracking status syncs back to the Channel.

**Consequences (testable):**
- Label generation failure (carrier API down) surfaces a retry-able error and does not mark the order dispatched.
- Dispatch closes the Reservation and writes the outbound Ledger event atomically.
- Tracking webhooks update order status on the Channel within the carrier's feed latency.

### 4.7 Inventory Moves: Transfers & Adjustments

**Description:** Between-Bin and between-Warehouse moves run as Transfer Orders with pick/confirm steps on mobile. Adjustments correct stock with reason codes and role-gated approval, always as Ledger events.

**Functional Requirements:**

#### FR-18: Transfer orders

An Ops Manager can create a Transfer Order (Bin→Bin or Warehouse→Warehouse); the move executes as a two-sided event (outbound confirm, inbound confirm) with in-transit state.

**Consequences (testable):**
- In-transit stock is excluded from ATP of both source and destination until inbound confirm.
- A Warehouse→Warehouse transfer's two legs each write their own Ledger events, correlated by Transfer Order ID.

#### FR-19: Stock adjustments with reason codes and approval

An authorized user can adjust stock with a reason code; adjustments beyond a configurable quantity/value threshold require Owner approval. Realizes UJ-4.

**Consequences (testable):**
- An unapproved over-threshold adjustment cannot change ATP; it sits pending with the approver notified.
- Every adjustment is traceable to actor, reason, and the Ledger events it produced.

### 4.8 Cycle Counting & Stock Audit

**Description:** ABC-classified scheduled counts plus on-demand counts, executed bin-by-bin on mobile without freezing operations. Variances route into the adjustment approval flow (FR-19) with the movement Ledger one tap away for explanation. Realizes UJ-4.

**Functional Requirements:**

#### FR-20: Cycle count scheduling and execution

The system generates count tasks by ABC class and schedule; an Operator counts a Bin on mobile while operations continue.

**Consequences (testable):**
- A count task's expected quantity is the Bin state at count start; concurrent picks/receipts during counting are flagged, not lost.
- Counted ≠ expected creates a variance record, never an immediate silent write-off.

#### FR-21: Variance review and resolution

A variance routes to the configured approver with the Bin's Ledger history attached; resolution is approve-adjust or recount.

**Consequences (testable):**
- Variance resolution references the Ledger events considered; the resolution action is itself audit-logged.
- Recount replaces the variance's expected basis with the recount snapshot.

### 4.9 Replenishment & Reorder Intelligence

**Description:** Per-SKU reorder points and quantities (imported defaults, later refined by velocity), low-stock and expiry alerts, and suggested PO drafts.

**Functional Requirements:**

#### FR-22: Reorder points, alerts, and suggested POs

An Ops Manager can set per-SKU (per-Warehouse) reorder points; the system alerts on breach and drafts a suggested PO from default vendors and quantities.

**Consequences (testable):**
- Alert latency from ATP breach ≤ 5 minutes.
- A drafted PO is editable before submission; system never auto-submits in v1.

#### FR-23: Expiry and aging alerts

For Batch-tracked SKUs, the system alerts on approaching expiry (configurable lead days) and shows aging stock by Batch.

**Consequences (testable):**
- A Batch within expiry lead days appears on the expiry dashboard and in pick suggestions (FEFO naturally prioritizes it).

### 4.10 Channel Integrations & Oversell Protection

**Description:** v1 ships with Shopify, Amazon.in, and Flipkart order/availability integration plus manual orders: order ingestion with idempotent de-dup, near-real-time availability sync with per-Channel Safety Buffers, and fulfillment writeback. Marketplace oversell protection is the headline promise — Reservations (FR-5) plus buffers plus sync. Realizes UJ-3. `[ASSUMPTION: Flipkart/Amazon.in via their official seller APIs with partner-registration lead time handled during build; if API approval slips, Shopify + manual launch and marketplace channels follow as fast-follow.]`

**Functional Requirements:**

#### FR-24: Channel configuration and availability sync

An Ops Manager can connect a Channel, configure its Safety Buffer and backorder policy (accept/reject), and the system syncs Channel-available quantity from ATP.

**Consequences (testable):**
- Availability sync latency ≤ 60 s from ATP change (per-channel target).
- Buffer exhaustion on a Channel reduces that Channel's synced quantity to 0 before the shared pool reaches 0.

#### FR-25: Order ingestion and fulfillment writeback

Channel orders ingest automatically (idempotent), reserve ATP at acceptance, and fulfillment/dispatch status writes back to the Channel.

**Consequences (testable):**
- Ingested order → reservation completes ≤ 10 s at p95 under normal load.
- Cancelled-on-channel orders release their Reservation atomically.

### 4.11 Compliance: GST & E-way Bills

**Description:** India-first compliance surface: GST rates/HSN on SKUs, GST-compliant invoices on dispatch, and batch E-way Bill generation for eligible consignments. Built for the accountant to use without touching the GST portal by hand for routine dispatches. Realizes UJ-4.

**Functional Requirements:**

#### FR-26: GST invoicing and E-way Bill generation

The system generates GST-compliant invoices per dispatch (from SKU GST/HSN data and place-of-supply rules) and supports single and batch E-way Bill generation for consignments above the threshold.

**Consequences (testable):**
- Invoice line values reconcile exactly to dispatched qty × rate × GST computation.
- E-way Bill generation failure (portal/API error) is retryable and never blocks recording the Dispatch itself.
- HSN summary report produces per accounting-period totals for filing.

### 4.12 Dashboard, Notifications & Audit Trail

**Description:** The Ops Manager's web home: today's dock-to-stock, pick rates, short-picks, open GRN variances, expiry alerts, channel sync health, and dispatch pipeline. Every state-changing action is attributable (actor, time, reference) and exportable.

**Functional Requirements:**

#### FR-27: Operational dashboard

An Ops Manager can see real-time KPIs (dock-to-stock, pick rate, order accuracy, oversell/backorder events, sync health per Channel) for any Warehouse they administer.

**Consequences (testable):**
- KPI values reconcile to the Ledger (KPIs are projections, not side-computed numbers).
- Dashboard renders < 2 s at p95 for a Tenant with 100k Ledger events/month.

#### FR-28: Global audit trail and export

An Owner can view and export the audit trail of all state-changing actions (who, what, when, reference document) with filters.

**Consequences (testable):**
- Any Ledger event is reachable from its reference document (GRN, order, adjustment) in ≤ 2 navigations.
- Export of 100k events completes asynchronously and notifies on completion.

### 4.13 Mobile Scan Client

**Description:** The floor surface (iOS/Android): badge-in, receive, putaway, pick, pack-assist, count, transfer-confirm — all scan-first, all offline-tolerant (FR-14 is the pattern; this feature covers the client's scope). Camera-scan on commodity phones is the v1 hardware story; keyboard-wedge/Bluetooth scanners pair as HID input. `[ASSUMPTION: camera scanning performance on mid-range Android is acceptable for v1; dedicated RF handhelds are explicitly out of scope for v1 — see Non-Goals.]`

**Functional Requirements:**

#### FR-29: Task inbox on mobile

An Operator sees their assigned/pickable tasks (picklists, putaways, counts, transfers) in one inbox and works them in suggested order.

**Consequences (testable):**
- Task state on client matches server state after reconnect (verified by offline test suite).
- A task claimed by another Operator disappears from the inbox within one poll/refresh cycle.

#### FR-30: Camera and HID barcode scanning

The mobile client scans barcodes via device camera and paired HID scanners, supporting the symbologies Tenant labels use (Code 128, EAN-13, QR at minimum). `[ASSUMPTION: Tenant-printed barcode labels use these symbologies; the product generates SKU barcode values at catalog entry.]`

**Consequences (testable):**
- Scan-to-decision (accept/reject feedback) ≤ 1.5 s on a mid-range Android device, on-device where network-independent.
- The same barcode value resolving to two SKUs within a Tenant is prevented at catalog entry.

## 5. Non-Goals (Explicit)

- **Not an ERP/accounting system.** Tally/Zoho Books integration (v2) is the boundary; we generate compliance documents, not ledgers of account.
- **No labor management, engineered standards, or payroll** in v1 — productivity signals (pick rate) exist as dashboards, not as management tooling.
- **No yard management, dock scheduling, or appointment management** in v1.
- **No advanced picking strategies** (zone, cluster, cartonization) in v1 — single-order + batch only.
- **No robotics/AMR orchestration, no RFID.** Barcode-era v1 by design; the scan-event abstraction keeps RFID-tolerance possible later.
- **No native POS.** Retail counter flows are out.
- **No 3PL multi-client billing** in v1 — tenancy is designed for it (Tenant partition everywhere), the billing/product surface is not.
- **No EDI (940/945/856) in v1** — API-based Channel feeds only; EDI is the enterprise wedge later.
- **No custom report builder in v1** — fixed dashboards + export; a builder follows demand.
- **No warehouse floor-plan visual editor** — grid-based bin management only in v1.

## 6. MVP Scope

### 6.1 In Scope

- Multi-Tenant onboarding: Warehouse → Zone → Bin setup, catalog import (FR-1, FR-2), roles (FR-3)
- Inventory Ledger, real-time ATP, atomic Reservation, batch/serial traceability (FR-4…FR-6)
- POs, scan receiving/GRN (incl. partial and blind), QC hold/release (FR-7…FR-9)
- Directed putaway, bin administration, nightly slotting suggestions (FR-10, FR-11)
- Manual + Channel orders, waves/picklists, scan-verified picking with offline queueing, short-pick re-planning (FR-12…FR-15)
- Pack station, India carrier rating/labels/manifests/dispatch, tracking writeback (FR-16, FR-17)
- Transfers, adjustments with approval thresholds (FR-18, FR-19)
- ABC cycle counting, variance review (FR-20, FR-21)
- Reorder points, low-stock/expiry alerts, suggested POs (FR-22, FR-23)
- Channel integrations: Shopify, Amazon.in, Flipkart — sync, buffers, oversell protection, writeback (FR-24, FR-25)
- GST invoicing + E-way Bill generation (single/batch) (FR-26)
- Web dashboard + audit export (FR-27, FR-28); mobile scan client with task inbox and camera/HID scanning (FR-29, FR-30)

### 6.2 Out of Scope for MVP

- Tally/Zoho Books sync (v2 — accountant exports cover filing week) `[NOTE FOR PM: highest-demand integration question from every comparable; revisit if launch feedback contradicts.]`
- EDI flows (v2+; enterprise/3PL wedge)
- Labor management, yard management, advanced slotting/forecasting (v3 territory)
- RFID, robotics orchestration (no v1 customer needs it; abstraction kept)
- 3PL billing (v2 candidate; tenancy prepared)
- Regional carriers beyond the v1 India carrier set `[ASSUMPTION: v1 carrier set = Delhivery, Blue Dart, Ecom Express, Shiprocket (aggregator cover for others); final list pending commercial conversations.]`
- Custom report builder, floor-plan editor (post-launch demand pull)

## 7. Success Metrics

**Primary**

- **SM-1:** Time-to-first-GRN: median time from tenant signup to first GRN recorded ≤ 1 business day. Validates FR-1, FR-2, FR-8. *(The onboarding funnel is the conversion surface.)*
- **SM-2:** Weekly active operators: % of provisioned Operator seats scanning ≥ 4 days/week, target ≥ 70% by week 8 per tenant. Validates FR-14, FR-29, FR-30. *(The floor adopting the tool is the product's core claim.)*
- **SM-3:** Order accuracy: mis-picks + pack mismatches per 1,000 dispatched lines ≤ 2 by week 12 per tenant. Validates FR-14, FR-16, FR-15.
- **SM-4:** Oversell events: 0 tolerated at any load; measured as channel orders accepted where dispatchable stock was insufficient. Validates FR-5, FR-24, FR-25.

**Secondary**

- **SM-5:** Dock-to-stock time: median ≤ 4 clock-hours from delivery arrival to bin-located stock per tenant. Validates FR-8, FR-10.
- **SM-6:** Availability-sync latency: p95 ≤ 60 s ATP-to-channel. Validates FR-24.
- **SM-7:** Count variance value: absolute variance value as % of inventory value per monthly close, trending down per tenant. Validates FR-20, FR-21, FR-19.
- **SM-8:** E-way batch usage: % of eligible dispatches with system-generated e-way bill ≥ 90% by month 3. Validates FR-26.

**Counter-metrics (do not optimize)**

- **SM-C1:** Scan-rejection rate — do not minimize. A rising rejection rate with rising accuracy (SM-3) means verification is working; minimizing it invites scan-through behavior.
- **SM-C2:** Adjustment count — do not minimize directly. Fewer adjustments can mean hidden write-offs; pair with SM-7 variance value and audit-trail usage (FR-28).

## 8. Open Questions

1. Which India carrier set is launch-realistic (direct APIs vs aggregator-first), and at what volume commitments? — resolve before architecture freezes carrier adapters.
2. Marketplace API partner-approval lead times (Amazon.in MWS/SP-API, Flipkart) — does Shopify + manual launch alone satisfy the launch plan if approvals slip?
3. E-way Bill generation path: official portal APIs vs GSP intermediary for v1 reliability?
4. Pricing and packaging: is warehouse-count the metered axis (Zoho's pattern) or order volume, and what's the free-tier cut? — commercial model, needs its own workstream.
5. Serial tracking in v1 or v1.5? — differentiator vs Zoho gating, but adds catalog and picking surface area (see ASSUMPTION in §4.2).
6. Data residency: India-region hosting for GST data from day one, or launch on the platform default region? — interacts with compliance positioning (§ Constraints).

## 9. Assumptions Index

- §4.2 — Batch and serial tracking both in v1 (serial defers first under scope pressure).
- §4.3 — Blind receiving permitted with reason codes and dashboard flagging.
- §4.4 — Slotting suggestions computed nightly, not real-time.
- §4.10 — Marketplace API approvals (Amazon.in, Flipkart) land in time; fallback is Shopify + manual launch.
- §4.13 — Camera scanning on mid-range Android meets the 1.5 s decision budget; RF handhelds out of v1.
- §6.2 — v1 carrier set: Delhivery, Blue Dart, Ecom Express, Shiprocket (pending commercial confirmation).
- §0 — Product name "WMS" is a working title; naming work not yet done.

## Cross-Cutting NFRs

- **NFR-1 — Inventory correctness:** zero tolerance for ledger/derived-state divergence; automated replay-reconciliation runs continuously and alerts on any mismatch. (Validates FR-4 constantly, not just at test time.)
- **NFR-2 — Peak-load resilience:** order acceptance + reservation sustained at 15× the tenant's median order rate for 2 hours without oversell or reservation-pool deadlock; load-tested before every peak season.
- **NFR-3 — Offline floor tolerance:** mobile client operation through connectivity loss of ≥ 30 minutes with zero scan loss; queued-work replay is idempotent and order-preserving per task.
- **NFR-4 — Multi-tenant isolation:** `tenant_id` scoped on every data access path; a cross-tenant read is a severity-1 defect. Noisy-neighbor load-shedding protects interactive scanning paths over background sync.
- **NFR-5 — Auditability:** every state change attributable to actor, time, and reference; audit retention ≥ 7 years (GST book-keeping norms).
- **NFR-6 — Platform latency budgets:** web dashboard p95 < 2 s; scan decision feedback ≤ 1.5 s on-device; availability sync p95 ≤ 60 s; carrier label gen p95 ≤ 5 s.

## Constraints and Guardrails

**Compliance (India-first):** GST/HSN correctness on invoices (FR-26), e-way bill thresholds current with regulation `[NOTE FOR PM: e-way thresholds and rules change; a tracked regulatory-watch process is required, not hardcoded constants.]`, 7-year audit retention (NFR-5), India data residency preferred for GST-adjacent data (Open Question 6).

**Privacy & data governance:** Tenant data is isolated and exportable; no cross-Tenant analytics without aggregation+consent; marketplace API terms (Amazon/Flipkart/Shopify) respected in data retention and sync patterns.

**Cost guardrails:** channel-sync and carrier-API call volumes are metered per tenant; runaway integration loops (sync storms) circuit-break automatically.

## Platform

- **v1:** responsive web dashboard (managers/admins) + native mobile scan client iOS/Android (operators). `[ASSUMPTION: native over PWA for camera scan performance and background queue reliability — revisit if a PWA + service-worker pattern proves sufficient.]`
- **v2+:** RF handheld support, carrier/device breadth, public API + webhooks for Tenant developers.

## Monetization

`[ASSUMPTION: tiered SaaS subscription with warehouse-count and order-volume as the metered axes, mirroring validated Zoho patterns — free tier to prove the funnel, paid tiers gating traceability and channel count. Commercial model is an open workstream (Open Question 4); the PRD requires only that tiering be technically meterable.]`