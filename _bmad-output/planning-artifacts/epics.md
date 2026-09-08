---
project_name: WMS-Meta
created: 2026-09-08
updated: 2026-09-08
inputDocuments:
  - _bmad-output/planning-artifacts/prds/prd-WMS-Meta-2026-09-07/prd.md
  - _bmad-output/planning-artifacts/prds/prd-WMS-Meta-2026-09-07/addendum.md
  - _bmad-output/planning-artifacts/architecture/architecture-WMS-Meta-2026-09-08/ARCHITECTURE-SPINE.md
  - _bmad-output/planning-artifacts/ux-designs/ux-WMS-Meta-2026-09-08/DESIGN.md
  - _bmad-output/planning-artifacts/ux-designs/ux-WMS-Meta-2026-09-08/EXPERIENCE.md
stepsCompleted:
  - step-01-validate-prerequisites
  - step-02-design-epics
  - step-03-create-stories
  - step-04-final-validation
---

# WMS-Meta - Epic Breakdown

## Overview

This document provides the complete epic and story breakdown for WMS-Meta, decomposing the requirements from the PRD, UX Design contract, and Architecture spine into implementable stories.

## Requirements Inventory

### Functional Requirements

FR1: An Owner can register a Tenant, create Warehouses, and define Zones and Bins (manual grid generator or import) before any stock exists — bin codes unique per Warehouse (duplicates rejected naming the conflicting code); a Tenant with zero Warehouses cannot create stock records; system emits and tracks a setup-completion checklist per Tenant. (PRD FR-1)

FR2: An Ops Manager can import SKUs from CSV/XLSX (SKU, name, UoM, UoM conversions, GST rate, HSN, batch/serial flags, reorder defaults) and manage SKUs individually thereafter — a 5,000-row import with 30 bad rows commits 4,970 and produces a downloadable per-row error report; "fix mode" re-import accepts only previously failed rows; duplicate SKU codes rejected, not merged. (PRD FR-2)

FR3: An Owner can invite users, assign roles (Owner, Ops Manager, Operator, Accountant), and permissions gate every capability — an Operator cannot approve over-threshold adjustments or change Channel settings; role changes take effect on the user's next action, not next login; all role changes audit-logged. (PRD FR-3)

FR4: The system records every stock movement as an append-only Ledger event (type, SKU, Batch/Serial, from/to Bin, qty, actor, timestamp, reference document) and derives on-hand and ATP from it — no code path mutates a quantity without a Ledger event; on-hand recomputes exactly by replaying events; events are immutable, corrections are new events. (PRD FR-4)

FR5: The system maintains per-Channel-visible ATP in real time and accepts Reservations atomically at order-accept time — two concurrent reservations for the last unit: exactly one succeeds, loser gets a deterministic outcome; ATP never exceeds on-hand − QC-held − reserved − buffers at any read. (PRD FR-5)

FR6: A Batch-tracked SKU records mfg/expiry per Batch and picks FEFO by default; a Serial-tracked SKU records unit-level identity through receive → pick → dispatch — FEFO override requires reason code + audit log; a serial cannot be in two Bins' on-hand (duplicate scans rejected naming the conflicting location); full movement history for a dispatched serial/batch in one query. (PRD FR-6)

FR7: An Ops Manager can create POs (vendor, lines, qty, cost, expected date), amend before receipt, and close with open quantities cancelled or carried — a PO line always shows ordered / received-to-date / open quantity; a closed PO cannot receive (attempted receipt rejected naming PO state). (PRD FR-7)

FR8: An Operator can receive against a PO on mobile by scanning SKU/barcode and entering/scanning quantities, producing a GRN per delivery; blind-receive permitted with reason code and dashboard flagging — over-receipt requires Ops Manager approval and creates an over-receipt event; partial GRN leaves the PO line open with correct remaining qty; GRN creation ≤ 4 scans + 1 confirm for a single-SKU single-lot pallet. (PRD FR-8)

FR9: An Ops Manager can place received stock into QC Hold (bin-level quarantine) and release to ATP after inspection — QC-held stock excluded from ATP and unpickable (pick request rejected); release records inspector, decision, timestamp in the Ledger. (PRD FR-9)

FR10: The system suggests a putaway Bin per GRN line and an Operator scan-confirms actual placement (differing from suggestion allowed with a reason) — full/blocked Bin rejects placement naming capacity/block reason; suggestion ≠ actual recorded and accuracy measurable. (PRD FR-10)

FR11: An Ops Manager can create, block, merge, or retire Bins; a Bin with on-hand stock cannot be deleted, only retired-after-empty — blocking removes the Bin from putaway suggestions and picking immediately; retire-with-stock rejected naming the SKUs/quantities blocking it. (PRD FR-11)

FR12: An Ops Manager can create orders manually; Channel orders ingest automatically with idempotent de-duplication — same channel payload delivered twice creates exactly one order; manual order exceeding ATP warned and either backordered or blocked per policy. (PRD FR-12)

FR13: The system groups accepted orders into Waves by configurable policy and generates Picklists (single-order or batch) with a directed pick path — batch Picklist path visits each Bin at most once with total steps ≤ sum of single-order paths; wave release respects carrier cutoffs configured per Channel/carrier. (PRD FR-13)

FR14: An Operator picks against a Picklist on mobile scanning Bin then item; the client queues operations locally during connectivity loss and replays idempotently on reconnect — wrong-item/wrong-bin scan rejected < 500 ms on-device with specific reason; offline scans land in the Ledger in order and exactly once; client shows queue depth (not an error) while offline; nothing lost on force-quit. (PRD FR-14)

FR15: An Operator can short-pick (bin has less than task quantity) with a reason; the task system re-plans (alternate Bin suggestion or partial order) without manual replanning — short-pick triggers alternate-Bin suggestion within the same Picklist when stock exists elsewhere; short-picks aggregated in the dashboard as a slotting/accuracy signal. (PRD FR-15)

FR16: An Operator at a Pack Station scans the picked order, confirms contents (weight/dims optional), and generates a packing slip — pack scan mismatching Picklist contents rejected naming the discrepancy; pack completion emits the packing event to the Ledger and moves the order to Ready-to-Dispatch. (PRD FR-16)

FR17: The system rates the shipment across configured carriers, generates label and manifest, records Dispatch with carrier + tracking ID; tracking syncs back to the Channel — label-generation failure surfaces a retryable error and never marks the order dispatched; Dispatch closes the Reservation and writes the outbound Ledger event atomically; tracking webhooks update Channel status. (PRD FR-17)

FR18: An Ops Manager can create a Transfer Order (Bin→Bin or Warehouse→Warehouse) executing as a two-sided event (outbound confirm, inbound confirm) with in-transit state — in-transit stock excluded from ATP of both ends until inbound confirm; each leg writes its own Ledger events correlated by Transfer Order ID. (PRD FR-18)

FR19: An authorized user can adjust stock with a reason code; adjustments beyond a configurable quantity/value threshold require Owner approval — an unapproved over-threshold adjustment cannot change ATP (sits pending, approver notified); every adjustment traceable to actor, reason, and produced Ledger events. (PRD FR-19)

FR20: The system generates count tasks by ABC class and schedule; an Operator counts a Bin on mobile while operations continue — expected quantity is Bin state at count start; concurrent picks/receipts during counting flagged, not lost; counted ≠ expected creates a variance record, never a silent write-off. (PRD FR-20)

FR21: A variance routes to the configured approver with the Bin's Ledger history attached; resolution is approve-adjust or recount — resolution references the Ledger events considered and is itself audit-logged; recount replaces the variance's expected basis. (PRD FR-21)

FR22: An Ops Manager can set per-SKU (per-Warehouse) reorder points; the system alerts on breach and drafts a suggested PO from default vendors and quantities — alert latency from ATP breach ≤ 5 minutes; drafted PO editable before submission; system never auto-submits in v1. (PRD FR-22)

FR23: For Batch-tracked SKUs, the system alerts on approaching expiry (configurable lead days) and shows aging stock by Batch — a Batch within expiry lead days appears on the expiry dashboard and in pick suggestions. (PRD FR-23)

FR24: An Ops Manager can connect a Channel, configure its Safety Buffer and backorder policy (accept/reject), and the system syncs Channel-available quantity from ATP — availability sync latency ≤ 60 s from ATP change; buffer exhaustion on a Channel reduces that Channel's synced quantity to 0 before the shared pool reaches 0. (PRD FR-24)

FR25: Channel orders ingest automatically (idempotent), reserve ATP at acceptance, and fulfillment/dispatch status writes back to the Channel — ingested order → reservation ≤ 10 s at p95; cancelled-on-channel orders release their Reservation atomically. (PRD FR-25)

FR26: The system generates GST-compliant invoices per dispatch (from SKU GST/HSN data and place-of-supply rules) and supports single and batch E-way Bill generation for consignments above threshold — invoice line values reconcile exactly to dispatched qty × rate × GST; e-way generation failure retryable and never blocks recording the Dispatch; HSN summary produces per-period totals for filing. (PRD FR-26)

FR27: An Ops Manager can see real-time KPIs (dock-to-stock, pick rate, order accuracy, oversell/backorder events, sync health per Channel) for any administered Warehouse — KPI values reconcile to the Ledger (projections, not side-computed); dashboard renders < 2 s p95 at 100k Ledger events/month. (PRD FR-27)

FR28: An Owner can view and export the audit trail of all state-changing actions (who, what, when, reference document) with filters — any Ledger event reachable from its reference document in ≤ 2 navigations; export of 100k events completes asynchronously and notifies on completion. (PRD FR-28)

FR29: An Operator sees their assigned/pickable tasks (picklists, putaways, counts, transfers) in one mobile inbox and works them in suggested order — task state matches server state after reconnect (offline test suite); a task claimed by another Operator disappears from the inbox within one poll/refresh cycle. (PRD FR-29)

FR30: The mobile client scans barcodes via device camera and paired HID scanners, supporting Code 128, EAN-13, QR at minimum; the product generates SKU barcode values at catalog entry — scan-to-decision ≤ 1.5 s on mid-range Android, on-device where network-independent; a barcode value resolving to two SKUs within a Tenant prevented at catalog entry. (PRD FR-30)

### NonFunctional Requirements

NFR1: Inventory correctness — zero tolerance for ledger/derived-state divergence; automated replay-reconciliation runs continuously and alerts on any mismatch (validates FR-4 constantly, not just at test time). (PRD NFR-1)

NFR2: Peak-load resilience — order acceptance + reservation sustained at 15× the tenant's median order rate for 2 hours without oversell or reservation-pool deadlock; load-tested before every peak season. (PRD NFR-2)

NFR3: Offline floor tolerance — mobile client operates through connectivity loss ≥ 30 minutes with zero scan loss; queued-work replay idempotent and order-preserving per task. (PRD NFR-3)

NFR4: Multi-tenant isolation — `tenant_id` scoped on every data access path; a cross-tenant read is a severity-1 defect; noisy-neighbor load-shedding protects interactive scanning paths over background sync. (PRD NFR-4)

NFR5: Auditability — every state change attributable to actor, time, and reference; audit retention ≥ 7 years (GST book-keeping norms); tamper-evident per AD-16. (PRD NFR-5 + SPEC constraint)

NFR6: Platform latency budgets — web dashboard p95 < 2 s; scan decision feedback ≤ 1.5 s on-device; availability sync p95 ≤ 60 s; carrier label gen p95 ≤ 5 s. (PRD NFR-6)

### Additional Requirements

From `ARCHITECTURE-SPINE.md` (architecture-WMS-Meta-2026-09-08, status: final) — all ADs are binding constraints (SPEC), not suggestions:

- AD-1 — Event-sourced modular monolith: append-only ledger is the only stock truth; on-hand/ATP are derived projections; continuous replay-reconciliation (quarantine → rebuild → alert), never auto-heal.
- AD-2 — Postgres is the reservation truth; Valkey Lua scripts make atomic reservation decisions only (pre-declared keys, hash-tag co-location); durable reservation journal in Postgres; on divergence Postgres wins; commit-then-apply order.
- AD-3 — Tenant + warehouse scope on every path including background jobs, exports, and Valkey key namespacing; Postgres RLS as defense-in-depth.
- AD-4 — Offline-first mobile: encrypted SQLite (WAL) device store + FIFO outbox replay; scan decisions on-device; device enrollment/revocation; replayed ops re-authorized against the badge-in session that created them.
- AD-5 — Idempotency keys (ULID) on all mutating endpoints; channel webhooks derive idempotency from integration + event ID + verified payload hash, tenant-scoped, windowed.
- AD-6 — Module boundaries: communicate through interfaces + events, never tables; exclusive entity ownership — tenancy: warehouse/zone/bin master; putaway: bin operations; catalog: batch/serial identity; ledger: quantities; outbound: order state machine.
- AD-7 — Transactional outbox for integration events; DLQ; sync-lag SLO surfaced per channel.
- AD-8 — OpenAPI as the API contract; server and clients from generated types (openapi-typescript 7.13 / @hey-api/openapi-ts 0.99.x).
- AD-9 — Integers for quantities (base-UoM) and money (paise), GST basis points; UTC everywhere; UUIDv7 IDs; regulatory constants (e-way thresholds, GST rates) as versioned config, never code literals.
- AD-10 — One command layer shared by web/mobile/APIs; role-epoch re-evaluation at command entry (JWT is transport, not authority).
- AD-11 — Versioned ledger event registry (event grammar changes are additive migrations); per-warehouse gap-free ledger sequence.
- AD-12 — Reservation records carry TTL + reaper + terminal-transition serialization.
- AD-13 — Channel buffers are standing reservations on the ledger; inventory publishes unallocated sellable only.
- AD-14 — Offline work settles pre-reserved task stock only; per-bin state_epoch; 4-case conflict taxonomy (settled / re-authorized / rejected / quarantined); non-negativity enforced server-side.
- AD-15 — KMS-enveloped secrets, rotation, device delete-on-disconnect.
- AD-16 — Hash-chained ledger events + WORM anchor for audit; digest exports; 7-year lifecycle.
- AD-17 — Background work is sheddable before interactive scanning; per-tenant integration metering + circuit breakers (the monetization metering surface).

- Stack (web-verified 2026-09-08): Node 24 LTS, TypeScript 6.x, NestJS 12.0, Drizzle ≥0.45.2, PostgreSQL 18.6, Valkey 9.1, Zod 4.x; Next.js 16.3 + TanStack Query 5.x (web); Expo SDK 57 / RN 0.86 + expo-sqlite WAL (mobile); AWS ap-south-1 `[ASSUMPTION]`.
- Module seed: 13 NestJS modules — tenancy, catalog, inventory (depends on nothing), inbound, putaway, outbound, movements, replenishment, channels, compliance, reporting, carriers, notifications — plus api/ and jobs/ shells.
- No starter template specified — Epic 1 Story 1 establishes the monorepo scaffold (NestJS api + Next.js web + Expo mobile + Drizzle migrations + OpenAPI generation) per the spine's structural seed.
- Integration surfaces for epics: Shopify, Amazon.in, Flipkart (channel adapters); Delhivery, Blue Dart, Ecom Express, Shiprocket (carrier adapters); GST/e-way path (OQ3); Tally/Zoho Books explicitly out (v2).
- Regulatory-watch process: e-way thresholds and GST rules change — versioned config with a tracked update process (never hardcoded).
- Infra requirements implied: Valkey, Postgres 18.6, object storage for exports/labels, KMS, webhook ingestion + DLQ observability, sync-lag metrics.

### UX Design Requirements

From `DESIGN.md` + `EXPERIENCE.md` (ux-WMS-Meta-2026-09-08, both status: final — the pair is one UX design contract):

UX-DR1: Implement the DESIGN.md token layer as the shared design system: web inherits shadcn/ui defaults plus the brand delta (primary #1E4E8C, accent/scan-accepted green #16794C, warning amber #B45309, and their dark-mode foregrounds); mobile maps the same hues into its platform theme. All unlisted web tokens inherit shadcn defaults — no second brand hue, no gradients, no decorative color coding.
UX-DR2: Typography discipline: 28px semibold tabular-nums `kpi` style on every KPI tile value; tabular numerals on every aligned numeric column (bin codes, quantities, money, timestamps); mobile scan-result is the largest text on any task screen (platform Title-1 class). No display serif, no all-caps labels.
UX-DR3: Shape system: 4px inputs/table cells, 6px buttons/cards/banners, 8px dialogs, pills only on status badges — crisper than defaults ("instrument" posture).
UX-DR4: Scan banner component (mobile): full-width, ≥96px min-height, state-coded by fill + glyph + word — ✓ Accepted (server-confirmed, online), ↻ Recorded · queued (on-device pass, persistence pending — never green-accepted while queued), ✕ Rejected (< 500 ms, reason + nearest correct bin offered; rejected scans never queue), ⚠ Held for review (server-quarantined replayed op, links to sync summary). Never color-only (WCAG 1.4.1); appears ≤ 1.5 s of scan.
UX-DR5: Web IA: sidebar surfaces — Overview, Inventory, Inbound, Outbound, Moves, Conflicts & Reviews (the single human-review queue: quarantined replay conflicts, over-receipt approvals, escalated variances), Notifications (bell panel), Replenishment, Channels, Compliance, Reports/Audit, Settings (incl. floor-device enrollment/revocation and setup checklist).
UX-DR6: Mobile IA: device enrollment (first run) → badge-in (offline session restore from device cache; first-ever badge-in requires connectivity) → task inbox with All/Pick/Putaway/Count/Transfer switcher (in-surface, not app-level tabs) → task flows → sync summary screen after replay (settled/rejected/quarantined counts per task) with retraction display for queued ops the server later rejected.
UX-DR7: KPI tile pattern: value + muted label + delta caption; click-through to the underlying ledger-filtered list; reconciles to ledger so no "estimated" state exists. Overview carries today's dock-to-stock, pick rate, short-picks, GRN variances, expiry alerts, sync health, dispatch pipeline.
UX-DR8: Data table pattern: dense rows (~40px), cursor pagination (infinite scroll banned), sticky header, column filter presets, async export for big pulls; row actions on hover (desktop) / tap (touch); inline-editable cells where editable (reorder points, thresholds); stale-data inline refresh banner, never auto-refresh lists.
UX-DR9: Manual entry is a first-class one-tap fallback at every scan step (SKU code / bin code / qty) — the non-visual path, the damaged-label path, the HID-less path.
UX-DR10: Task card (mobile inbox): type icon, order/PO ref, item count, claimed-by state; optimistic claim disappearing for others within one refresh cycle; re-planned tasks (short-pick alternates) arrive as new cards linked to the original task ref; claim-lost state shows "Claimed by {other} while offline" with the operator's queued lines and their disposition.
UX-DR11: Review queue item (Conflicts & Reviews): quarantined event with on-device snapshot, server state, and ledger context side by side; resolve (apply / recount / discard-to-audit) writes to the audit trail; batch-resolve for similar conflicts.
UX-DR12: Notification panel: newest-first, amber treatment, click-through to source; mobile pushes restricted to task assignment + approval-needed + at-risk cutoff; reorder/expiry/breach alerts are panel entries only (≤ 5 min from breach per FR-22); no badge-count spam.
UX-DR13: Qty stepper (mobile receive/count): large +/− glove-usable, scan increments where applicable, manual entry as deliberate fallback tap.
UX-DR14: Ledger timeline component: vertical event list with event type, signed qty, actor, time, reference-doc link (≤ 2 navigations); used in Inventory and approvals.
UX-DR15: Approval card: pending adjustment/variance with reason code, threshold context inline, ledger-history link, approve/reject/recount actions; over-receipt approvals land here mid-receive; over-threshold routes to Owner.
UX-DR16: Import wizard (Settings → Catalog): upload → progress → row-level error report download → fix-mode re-import; partial commit shown honestly; duplicate barcode→two-SKU rows rejected naming the conflicting SKU.
UX-DR17: Offline state treatment (mobile): work continues with queue chip showing count — amber, never red, no error styling; on-device decisions display as Recorded · queued, not green-accepted; device revoked mid-shift shows an explicit full-screen state, never silent mass quarantine; queued ops transfer to quarantine with session attribution preserved.
UX-DR18: Replay/sync states: subtle "Syncing…" chip during replay with settled count; every replayed item re-authorized against the badge-in session that created it; rejections quarantine to Conflicts & Reviews and surface in the sync summary without blocking further work.
UX-DR19: Live KPI tiles: streamed best-effort, may lag under peak by design (AD-17 sheds background before scanning); stale-data banner is the governing pattern; carrier cutoff pressure shows amber with time remaining on at-risk waves.
UX-DR20: Web interaction primitives: ⌘K command palette (navigate + actions); Esc closes any dialog, Enter commits; hover reveals row actions on desktop, tap on touch; surface-hidden permission model (no "blocked" screens); permission changes enforced on next action with the role reason, never mid-keystroke lockouts.
UX-DR21: Mobile interaction primitives: scan → banner → next as the universal verb; camera + HID interchangeable at every scan step; HID keeps capture-field focus across banner swaps (a next scan is never silently lost) and never splices into mid-typed manual entry; buttons ≥ 48dp; swipe never destroys work; receive budget ≤ 4 scans + 1 confirm as the design ceiling for a single-SKU single-lot GRN.
UX-DR22: Accessibility floor: WCAG 2.2 AA on web; platform accessibility APIs (VoiceOver/TalkBack) on mobile announcing every task state; dynamic type honored (scan banner legible at largest setting); Reduce Motion makes banner swaps instant; focus traversal matches reading order; scan targets ≥ 48dp; dark-mode banner fills always pair with their dark-foreground tokens (white on dark fills fails AA and is forbidden).
UX-DR23: Responsive behavior: web ≥ 1024px full sidebar + tables; 768–1023px sidebar collapses to icons; < 768px read + simple actions; mobile iOS/Android parity following system dark mode.
UX-DR24: Key-screen composition references: mockups/key-mobile-pick.html, key-mobile-receive.html, key-web-overview.html (inline-linked in EXPERIENCE.md; spines win on conflict).
UX-DR25: Banned everywhere: infinite scroll, hover-only affordances on touch surfaces, modal stacks > 1 deep, celebratory animations, badge-count notification spam, hover-only row actions on `sm` viewports.

### FR Coverage Map

FR1: Epic 1 — Tenant/warehouse/zone/bin provisioning, setup checklist
FR2: Epic 1 — Catalog import (partial commit, fix mode), SKU management
FR3: Epic 1 — Users, roles, permission gating, audit-logged role changes
FR4: Epic 2 — Append-only ledger events; on-hand/ATP derived; hash chain (AD-16)
FR5: Epic 2 — Real-time ATP, atomic reservations (Postgres truth + Valkey decisions)
FR6: Epic 2 — Batch FEFO + serial unit traceability, one-query movement history
FR7: Epic 3 — PO creation/lifecycle, ordered/received/open tracking
FR8: Epic 3 — Scan receiving + GRN (partial, blind, over-receipt approval)
FR9: Epic 3 — QC hold/release, ATP exclusion
FR10: Epic 3 — Directed putaway, suggestion ≠ actual recorded
FR11: Epic 3 — Bin administration (block/merge/retire rules)
FR12: Epic 4 — Manual order entry + idempotent order ingestion (channel adapters wire in Epic 7)
FR13: Epic 4 — Wave/picklist generation, directed pick path, carrier cutoffs
FR14: Epic 4 — Scan-verified picking, offline queue + idempotent replay
FR15: Epic 4 — Short-pick re-planning, alternate-bin suggestions
FR16: Epic 4 — Pack station verification, packing slip
FR17: Epic 4 — Carrier rating/labels/manifests/dispatch, tracking writeback
FR18: Epic 5 — Transfer orders, two-sided events, in-transit ATP exclusion
FR19: Epic 5 — Reason-coded adjustments, threshold approval gating
FR20: Epic 5 — ABC cycle count scheduling/execution without ops freeze
FR21: Epic 5 — Variance review/resolution with ledger history
FR22: Epic 6 — Reorder points, breach alerts (≤ 5 min), suggested PO drafts
FR23: Epic 6 — Expiry/aging alerts, expiry dashboard
FR24: Epic 7 — Channel config, safety buffers, availability sync (≤ 60 s)
FR25: Epic 7 — Idempotent channel ingestion → reservation, fulfillment writeback
FR26: Epic 8 — GST invoicing, single/batch e-way bills, HSN summary
FR27: Epic 9 — Real-time KPI dashboard reconciling to ledger
FR28: Epic 9 — Global audit trail, filtered view, async export
FR29: Epic 3 — Mobile task inbox (born here; extended by Epics 4/5 with new task types)
FR30: Epic 3 — Camera + HID barcode scanning, catalog barcode uniqueness (extended by later epics)

## Epic List

### Epic 1: Foundation — Tenant Onboarding & Team
Priya can sign up, configure her warehouse (zones/bins), import her catalog with fix-mode, and invite her team with role-gated permissions. Story 1.1 establishes the monorepo scaffold (NestJS api + Next.js web + Expo mobile + Drizzle + OpenAPI generation) and the DESIGN.md token layer in the web shell.
**FRs covered:** FR-1, FR-2, FR-3

### Epic 2: Inventory Backbone — One Trusted Number
The ledger exists; every movement is an event; ATP is real-time and reservations are atomic; batch/serial traceability works; audit substrate is hash-chained. The system Priya can trust at 11:59 PM (AD-1/2/11/12/16).
**FRs covered:** FR-4, FR-5, FR-6

### Epic 3: Receiving & Putaway — The Floor's First Flow
Ramesh receives against POs scan-first (partial, blind, over-receipt gating, QC holds) and puts away with directed suggestions; bin administration works. The mobile scan client is born here: device enrollment, badge-in, task inbox, camera/HID scanning, the 4-state scan banner, offline queueing primitives (FR-29/FR-30 established, extended by later epics). Realizes UJ-1.
**FRs covered:** FR-7, FR-8, FR-9, FR-10, FR-11, FR-29, FR-30

### Epic 4: Outbound — Order to Dispatch Through Dead Zones
Orders (manual + idempotent ingestion) reserve ATP; waves/picklists generate; Ramesh picks scan-verified with offline tolerance and short-pick re-planning; pack station verifies; carrier labels and dispatch complete with tracking writeback. Realizes UJ-2.
**FRs covered:** FR-12, FR-13, FR-14, FR-15, FR-16, FR-17

### Epic 5: Moves, Counts & Approvals — Variance With an Explanation
Transfers with in-transit state; reason-coded adjustments gated by approval thresholds; cycle counts without ops freeze; variance review with ledger history attached. Realizes UJ-4's counting half.
**FRs covered:** FR-18, FR-19, FR-20, FR-21

### Epic 6: Replenishment & Stock Intelligence
Reorder points alert on breach within 5 minutes and draft (never auto-submit) suggested POs; expiry/aging dashboards keep batches FEFO-honest. Realizes UX Flow 5.
**FRs covered:** FR-22, FR-23

### Epic 7: Channels & Oversell Protection — The Headline Promise
Shopify/Amazon.in/Flipkart connect; availability syncs from ATP through standing buffers; orders ingest idempotently and reserve atomically; backorder policy; channel-cancel releases. Zero oversells at 15× volume. Realizes UJ-3.
**FRs covered:** FR-24, FR-25

### Epic 8: India Compliance — GST & E-way
Dispatches generate GST-compliant invoices from SKU GST/HSN data; single and batch e-way bills; HSN summary for filing. The accountant never touches the GST portal by hand.
**FRs covered:** FR-26

### Epic 9: Operational Visibility — Dashboard, Notifications & Audit
Priya's live KPI home reconciling to the ledger; the bell/notification panel; the Owner's filterable, exportable audit trail (async export). Cross-cutting close that aggregates everything shipped before it.
**FRs covered:** FR-27, FR-28

**Dependency flow (all backward):** Epic 2 ← 1; Epic 3 ← 1+2; Epic 4 ← 2+3; Epic 5 ← 2+3; Epic 6 ← 2; Epic 7 ← 2+4; Epic 8 ← 4; Epic 9 ← 2+4. No epic requires a future epic to function.

## Epic 1: Foundation — Tenant Onboarding & Team

Priya can sign up, configure her warehouse (zones/bins), import her catalog with fix-mode, and invite her team with role-gated permissions.

### Story 1.1: Monorepo scaffold and design system shell

As the delivery team,
I want the monorepo scaffold and shared design system established once, per the architecture spine,
So that every subsequent story builds on the same substrate instead of re-deciding structure.

**Acceptance Criteria:**

**Given** a fresh checkout, **when** the dev commands run, **then** api (NestJS 12), web (Next.js 16), and mobile (Expo 57) each boot locally with a health check
**And** Drizzle migration tooling is configured against Postgres with the spine conventions available: UUIDv7 IDs, UTC timestamps, integer base-UoM quantities and paise (AD-9)
**And** the OpenAPI pipeline generates typed clients for web (openapi-typescript / @hey-api/openapi-ts) from the api contract (AD-8)
**And** the web shell renders with the DESIGN.md token layer (brand delta colors, 28px tabular-nums KPI style, 4/6/8px radius scale, sidebar IA skeleton) and the Expo app boots with the platform theme mapping of the same hues
**And** the web shell carries its interaction primitives: ⌘K command palette (navigate + actions), Esc closes the topmost layer, Enter commits (UX-DR20)
**And** the banned-patterns list (UX-DR25: infinite scroll, hover-only touch affordances, modal stacks > 1 deep, celebratory animation, badge-count spam) is enforced in review/lint conventions
**And** the shell implements the responsive contract: ≥ 1024px full sidebar + tables; 768–1023px sidebar collapses to icons; < 768px read + simple actions — with web contrast at WCAG 2.2 AA (UX-DR22/23)
**And** the repo passes lint + tests in CI with the pre-commit workspace guard intact

### Story 1.2: Tenant registration and warehouse creation

As an Owner,
I want to register my tenant and create warehouses,
So that my business has its own isolated WMS with its stocking sites defined.

**Acceptance Criteria:**

**Given** no account exists, **when** an Owner registers, **then** a Tenant and its Owner user are created with the tenant scope key stamped on every row (AD-3)
**And** **given** a registered Tenant, **when** creating a Warehouse, **then** the Warehouse is created with a unique code and appears in the warehouse switcher
**And** **given** a Tenant with zero Warehouses, **when** any stock record creation is attempted, **then** it is rejected (no orphan inventory)
**And** a cross-tenant read attempt under another tenant's session fails (RLS defense-in-depth verified by test, NFR-4)

### Story 1.3: Zones, bins, and the setup checklist

As an Owner,
I want to define Zones and Bins by grid generator or manual entry,
So that the floor has valid locations before any stock exists.

**Acceptance Criteria:**

**Given** a Warehouse, **when** the grid generator runs (e.g. A-01-01…Z-12-10 style), **then** all Bins are created in their Zones with code, capacity, and type
**And** **when** a Bin code duplicates an existing code in the same Warehouse, **then** it is rejected naming the conflicting code
**And** **when** a Bin is created, **then** it is immediately usable as a putaway/pick target in later epics (no dormant state)
**And** the system emits and tracks a setup-completion checklist per Tenant whose steps check off as they are satisfied (catalog imported, users invited, bins defined…)

### Story 1.4: Catalog import with partial commit and fix mode

As an Ops Manager,
I want to import my catalog from CSV/XLSX and fix errors without starting over,
So that a 5,000-row sheet becomes live SKUs in one session.

**Acceptance Criteria:**

**Given** a 5,000-row import with 30 bad rows, **when** the import runs, **then** 4,970 rows commit and a downloadable row-level error report names each bad row and reason (FR-2)
**And** **when** re-importing in fix mode, **then** only previously failed rows are processed
**And** **when** a duplicate SKU code appears, **then** it is rejected, not silently merged
**And** **when** a barcode value resolves to two SKUs in the Tenant, **then** the row is rejected naming the conflicting SKU (FR-30 consequence)
**And** SKU barcode values are generated at catalog entry; SKUs are individually editable afterward
**And** the flow follows the import wizard pattern: upload → progress → error report → fix-mode re-import, with partial commit shown honestly (UX-DR16)

### Story 1.5: Users, roles, and permission gating

As an Owner,
I want to invite users and assign the four roles with permission sets,
So that approvals and sensitive views are gated by role.

**Acceptance Criteria:**

**Given** a registered Tenant, **when** an Owner invites a user with a role (Owner, Ops Manager, Operator, Accountant), **then** the user can sign in and sees only their role's surfaces (surface-hidden permission model, UX-DR20)
**And** an Operator cannot approve an over-threshold adjustment or change Channel settings (permission gates verified)
**And** **when** a user's role changes, **then** it takes effect on their next action, not next login (AD-10 role-epoch re-evaluation) — the next denied save fails naming the role reason, never mid-keystroke (UX-DR20)
**And** every role change is written to the audit trail with actor, time, and reference (NFR-5)

## Epic 2: Inventory Backbone — One Trusted Number

The ledger exists; every movement is an event; ATP is real-time and reservations are atomic; batch/serial traceability works; audit substrate is hash-chained.

### Story 2.1: Append-only ledger core and derived quantities

As an Ops Manager,
I want every stock movement recorded as an immutable Ledger event with on-hand derived from it,
So that any quantity in the system is explainable and re-derivable.

**Acceptance Criteria:**

**Given** any stock movement (receipt, putaway, pick, dispatch, transfer, adjustment, count variance), **when** it executes, **then** exactly one Ledger event is written with type, SKU, Batch/Serial, from/to Bin, qty, actor, timestamp, and reference document
**And** no code path mutates a quantity without writing a Ledger event (verified by architecture test)
**And** **when** on-hand for any SKU/Bin is recomputed by replaying its events, **then** it matches the derived value exactly (FR-4)
**And** Ledger events are immutable — corrections happen as new events
**And** each Warehouse's ledger sequence is gap-free and events follow the versioned event registry (additive grammar changes only, AD-11)
**And** events are hash-chained with a WORM anchor, and digest exports are producible (AD-16)

### Story 2.2: Continuous replay-reconciliation

As an Owner,
I want the system to continuously verify derived state against replayed ledger truth,
So that any divergence is caught and quarantined, never silently absorbed.

**Acceptance Criteria:**

**Given** derived projections exist, **when** the reconciliation job replays them continuously, **then** any mismatch quarantines the affected scope, triggers a rebuild, and alerts — never auto-heals (NFR-1, AD-1)
**And** a deliberately injected divergence is detected within one reconciliation cycle in test
**And** reconciliation runs as sheddable background work — under peak it yields to interactive scanning (AD-17, NFR-4)
**And** reconciliation alerts surface with the divergent scope and event range named

### Story 2.3: Real-time ATP and atomic reservations

As an Ops Manager,
I want ATP maintained in real time and reservations accepted atomically at order-accept time,
So that two channels can never both sell the last unit.

**Acceptance Criteria:**

**Given** one unit available, **when** two reservations race concurrently, **then** exactly one succeeds and the loser receives a deterministic unavailable outcome (FR-5)
**And** at any read, ATP never exceeds on-hand − reserved (− QC-held/buffer hooks, populated by later epics)
**And** reservation decisions execute atomically via Valkey Lua with pre-declared keys, while Postgres holds the durable reservation journal — on divergence, Postgres wins (AD-2)
**And** reservation records carry TTL with a reaper and serialize terminal transitions (AD-12)
**And** sustained acceptance + reservation at 15× median order rate for 2 hours shows zero oversell and no pool deadlock (NFR-2, load-test)

### Story 2.4: Batch and serial traceability

As an Ops Manager,
I want batch FEFO rotation and unit-level serial identity through receive → pick → dispatch,
So that expired stock doesn't ship and every serialized unit's history is one query away.

**Acceptance Criteria:**

**Given** a Batch-tracked SKU, **when** stock is received, **then** mfg/expiry dates are recorded per Batch and picks default to FEFO order (FR-6)
**And** **when** an Operator overrides FEFO, **then** a reason code is required and the override is audit-logged
**And** a Serial-tracked SKU records unit identity end-to-end; a serial cannot be in two Bins' on-hand simultaneously — duplicate scans are rejected naming the conflicting location
**And** given a dispatched serial/batch, the full movement history returns in one query

### Story 2.5: Inventory surfaces — stock, batches, and the ledger timeline

As an Ops Manager,
I want to browse stock by Bin and SKU, inspect batch/serial detail, and trace any quantity through its ledger timeline,
So that "why is this number what it is" is always a click-through, not an export.

**Acceptance Criteria:**

**Given** stock exists, **when** the Inventory surface loads, **then** stock lists by Bin/SKU with dense data-table behavior (cursor pagination, sticky header, tabular numerals, filter presets — UX-DR8)
**And** a SKU/Bin's ledger timeline shows event type, signed qty, actor, time, and reference-doc link (UX-DR14)
**And** any Ledger event is reachable from its reference document in ≤ 2 navigations (FR-28 consequence, established early)
**And** batch/serial detail views show dates, FEFO order, and unit history

## Epic 3: Receiving & Putaway — The Floor's First Flow

Ramesh receives against POs scan-first (partial, blind, over-receipt gating, QC holds) and puts away with directed suggestions; the mobile scan client is born here.

### Story 3.1: PO creation and lifecycle

As an Ops Manager,
I want to create and manage POs with open-quantity tracking,
So that receiving has its basis and open quantities stay visible until closed.

**Acceptance Criteria:**

**Given** a Vendor, **when** an Ops Manager creates a PO with lines (SKU, qty, cost, expected date), **then** the PO is open and amendable before receipt
**And** a PO line shows ordered, received-to-date, and open quantity at all times (FR-7)
**And** **when** a PO is closed with open quantities cancelled or carried, **then** attempted receipt against it is rejected naming the PO state

### Story 3.2: Mobile client substrate — enrollment, badge-in, inbox, scanning

As an Operator,
I want to enroll my device, badge in, and work from one task inbox with camera or paired-HID scanning,
So that the floor has one surface for every task type that never waits for network.

**Acceptance Criteria:**

**Given** a fresh device, **when** enrollment runs, **then** the device binds to the tenant/operator and web Settings can revoke it (wipe-flagged) (FR-29, AD-4/15)
**And** badge-in assigns the session to the operator; **given** no connectivity, **when** the device has a cached session, **then** badge-in restores it — first-ever badge-in requires connectivity (UX-DR6)
**And** the task inbox shows assigned/pickable tasks with an All/Pick/Putaway/Count/Transfer switcher; a task claimed by another Operator disappears within one refresh cycle; claim-lost shows "Claimed by {other} while offline" with queued-line disposition (FR-29, UX-DR10)
**And** scanning works via camera and paired HID (Code 128, EAN-13, QR) with scan-to-decision ≤ 1.5 s on-device on a mid-range Android (FR-30)
**And** the scan banner shows the four honest states with glyph + word within 1.5 s — ✓ Accepted / ↻ Recorded · queued / ✕ Rejected (< 500 ms with reason + nearest correct bin) / ⚠ Held for review; rejected scans never queue; manual entry is a one-tap fallback at every scan step; HID keeps capture-field focus across banner swaps (UX-DR4/9/21)
**And** offline work queues to an encrypted SQLite WAL store with FIFO outbox; force-quit loses nothing; the queue chip shows count in amber, never red (UX-DR17)
**And** the mobile accessibility floor holds: every task state announced via platform accessibility APIs ("Bin accepted", "Wrong item — expected SKU …"), dynamic type honored (scan banner legible at largest setting), Reduce Motion makes banner swaps instant, targets ≥ 48dp, glove- and one-handed-usable (UX-DR22)
**And** mid-shift device revocation shows an explicit full-screen "Device revoked by {admin}" state — queued ops transfer to quarantine with session attribution preserved, never a silent mass quarantine (UX-DR17)

### Story 3.3: Scan-based receiving and GRN

As an Operator,
I want to receive against a PO by scanning, producing a GRN,
So that deliveries land in the system in seconds, not spreadsheets.

**Acceptance Criteria:**

**Given** a PO, **when** receiving a single-SKU single-lot pallet, **then** GRN creation takes ≤ 4 scans + 1 confirm (FR-8); quantities enter via the glove-usable qty stepper or scan increments (UX-DR13)
**And** a partial GRN leaves the PO line open with correct remaining quantity
**And** **when** receiving exceeds the PO's open quantity, **then** an over-receipt event is created and Ops Manager approval is requested mid-receive — the task continues, never hard-blocks (UX-DR15)
**And** blind receive (no PO) is permitted with a reason code; blind GRNs are flagged on the dashboard for PO-matching
**And** receipts write Ledger events through Epic 2; queued receipts replay in order and exactly once

### Story 3.4: QC hold and release

As an Ops Manager,
I want to quarantine suspect stock and release it after inspection,
So that unverified goods never reach ATP.

**Acceptance Criteria:**

**Given** received stock, **when** an Ops Manager places it in QC Hold, **then** it is excluded from ATP and cannot be picked — a pick request against it is rejected (FR-9)
**And** **when** released after inspection, **then** inspector, decision, and timestamp are recorded in the Ledger
**And** QC-held stock is visible on the Inbound surface with its hold reason

### Story 3.5: Directed putaway

As an Operator,
I want system-suggested putaway bins and scan-confirm placement,
So that dock-to-stock is fast and suggestion accuracy is measurable.

**Acceptance Criteria:**

**Given** a GRN, **when** putaway begins, **then** the system suggests a Bin per GRN line (velocity, capacity, zone rules) and the Operator scan-confirms actual placement (FR-10)
**And** **when** placement differs from the suggestion, **then** it is allowed with a recorded reason and is measurable per report (SM-3)
**And** placing stock into a full or blocked Bin is rejected naming the capacity or block reason

### Story 3.6: Bin administration

As an Ops Manager,
I want to block, merge, or retire bins without code changes,
So that location management keeps pace with the floor.

**Acceptance Criteria:**

**Given** a Bin with on-hand stock, **when** deletion is attempted, **then** it is rejected — only retire-after-empty is permitted (FR-11)
**And** **when** retire-with-stock is attempted, **then** it is rejected naming the SKUs/quantities blocking it
**And** **when** a Bin is blocked, **then** it is removed from putaway suggestions and picking immediately
**And** merging Bins consolidates their stock with correlated Ledger events

## Epic 4: Outbound — Order to Dispatch Through Dead Zones

Orders (manual + idempotent ingestion) reserve ATP; waves/picklists generate; picking is scan-verified with offline tolerance; pack verifies; carrier labels and dispatch complete with tracking writeback.

### Story 4.1: Orders — manual entry, idempotent ingestion, acceptance reservation

As an Ops Manager,
I want orders created manually and ingested idempotently with ATP reserved at acceptance,
So that oversell protection starts at accept time, not dispatch time.

**Acceptance Criteria:**

**Given** ATP, **when** a manual order exceeds it, **then** the order is warned and either backordered or blocked per policy (FR-12)
**And** **when** the same channel order payload is delivered twice, **then** exactly one order is created (idempotency keys per AD-5; channel adapters wire into this machinery in Epic 7)
**And** order acceptance reserves atomically via Epic 2's reservation machinery; ingested order → reservation ≤ 10 s at p95 (FR-25 consequence, established here)
**And** a cancelled order releases its reservation atomically
**And** the order state machine lives in the outbound module with exclusive ownership (AD-6)

### Story 4.2: Waves and picklists

As an Ops Manager,
I want accepted orders grouped into waves and picklists with directed pick paths,
So that floor throughput scales without headcount.

**Acceptance Criteria:**

**Given** accepted orders, **when** wave generation runs, **then** orders group by configurable policy (carrier cutoff, priority, size) into single-order or batch Picklists (FR-13)
**And** a batch Picklist's path visits each Bin at most once with total steps ≤ the sum of single-order paths for the same orders
**And** wave release respects carrier cutoff times configured per Channel/carrier

### Story 4.3: Scan-verified picking with offline tolerance

As an Operator,
I want to pick scan-first even through Wi-Fi dead zones,
So that nothing is lost and I never wait for the network.

**Acceptance Criteria:**

**Given** a Picklist, **when** picking on mobile, **then** the flow scans Bin then item; a wrong-item or wrong-bin scan is rejected < 500 ms on-device with a specific reason and nearest correct bin offered (FR-14)
**And** **given** connectivity loss, **when** scans continue, **then** operations queue FIFO and replay idempotently in order, exactly once — verified by end-to-end idempotency test (NFR-3); queue depth shows as a chip, never an error; force-quit loses nothing
**And** offline picking settles pre-reserved task stock only; each op carries per-bin state_epoch for conflict detection; conflicts follow the 4-case taxonomy (settled / re-authorized / rejected / quarantined) (AD-14)
**And** replayed ops re-authorize against the badge-in session that created them; rejections quarantine to review and surface in the sync summary without blocking further work; a subtle "Syncing…" chip shows the settled count (UX-DR18)

### Story 4.4: Short-pick re-planning

As an Operator,
I want short-picks to trigger automatic re-planning,
So that a short bin doesn't stall the wave.

**Acceptance Criteria:**

**Given** a bin with less than task quantity, **when** the Operator short-picks with a reason, **then** an alternate-Bin suggestion arrives within the same Picklist when stock exists elsewhere — otherwise a partial order path (FR-15)
**And** re-planned tasks arrive as new task cards linked to the original task ref (UX-DR10)
**And** short-picks aggregate in the dashboard as a slotting/accuracy signal (SM-3)

### Story 4.5: Pack station verification

As an Operator,
I want pack scans to verify picked orders and produce packing slips,
So that mismatches are caught before a label is printed.

**Acceptance Criteria:**

**Given** a picked order at a Pack Station, **when** the pack scan mismatches its Picklist contents, **then** it is rejected naming the discrepancy (FR-16)
**And** **when** pack completes (weight/dims optional), **then** the packing Ledger event is emitted and the order moves to Ready-to-Dispatch
**And** a packing slip is generated/printed

### Story 4.6: Carrier rating, labels, and dispatch

As an Ops Manager,
I want the system to rate, label, manifest, and dispatch with tracking writeback,
So that dispatch completes even when a carrier API is degraded.

**Acceptance Criteria:**

**Given** a Ready-to-Dispatch order, **when** rating runs, **then** the shipment rates across configured carriers (v1 adapter ports: Delhivery, Blue Dart, Ecom Express, Shiprocket — final set pending OQ1) (FR-17)
**And** **when** label generation fails, **then** a retryable inline error surfaces and the order is never marked dispatched; dispatch state unchanged (UX-DR19 label-failure state)
**And** dispatch closes the Reservation and writes the outbound Ledger event atomically
**And** tracking webhooks update the Channel within the carrier's feed latency; label generation is p95 ≤ 5 s (NFR-6)
**And** waves at risk of missing a carrier cutoff show amber with time remaining (UX-DR19)

## Epic 5: Moves, Counts & Approvals — Variance With an Explanation

Transfers with in-transit state; reason-coded adjustments gated by thresholds; cycle counts without ops freeze; variance review with ledger history; one consolidated human-review queue.

### Story 5.1: Transfer orders

As an Ops Manager,
I want Bin→Bin and Warehouse→Warehouse transfers as two-sided ledger events,
So that in-transit stock is never sellable at either end.

**Acceptance Criteria:**

**Given** stock, **when** a Transfer Order executes, **then** it runs as outbound confirm + inbound confirm with in-transit state (FR-18)
**And** in-transit stock is excluded from ATP of both source and destination until inbound confirm
**And** the two legs write their own Ledger events correlated by Transfer Order ID
**And** transfer-confirm appears as a mobile task type in the inbox (FR-29)

### Story 5.2: Stock adjustments with approval thresholds

As an authorized user,
I want to adjust stock with reason codes, gated by quantity/value thresholds,
So that corrections are controlled and traceable.

**Acceptance Criteria:**

**Given** a stock correction, **when** an authorized user submits an adjustment with a reason code, **then** Ledger events record it with actor, reason, and references (FR-19)
**And** an adjustment over the configurable threshold cannot change ATP — it sits pending with the approver notified, presented as an approval card with threshold context and ledger-history link (UX-DR15)
**And** approval or rejection is itself audit-logged

### Story 5.3: Cycle count scheduling and execution

As an Ops Manager,
I want ABC-scheduled and on-demand counts executed bin-by-bin on mobile,
So that counting never freezes operations.

**Acceptance Criteria:**

**Given** ABC classification, **when** the schedule generates count tasks, **then** Operators count Bins on mobile while operations continue (FR-20); on-demand counts are also possible
**And** a count task's expected quantity is the Bin state at count start; concurrent picks/receipts during counting are flagged, not lost
**And** counted ≠ expected creates a variance record — never an immediate silent write-off
**And** the count flow uses the glove-usable qty stepper with manual-entry fallback (UX-DR13)

### Story 5.4: Variance review and resolution

As an approver,
I want variances routed with the Bin's ledger history and resolvable by approve-adjust or recount,
So that every variance ends with an explanation, not guesswork.

**Acceptance Criteria:**

**Given** a variance record, **when** it routes to the configured approver, **then** the Bin's Ledger history is attached (FR-21)
**And** resolution is approve-adjust or recount; the resolution references the Ledger events considered and is audit-logged
**And** a recount replaces the variance's expected basis with the recount snapshot
**And** variances over threshold route to the Owner with notification (FR-19)

### Story 5.5: Conflicts & Reviews — the human-review queue

As an Ops Manager,
I want one queue for quarantined replay conflicts and pending approvals,
So that nothing needing human judgment is buried inside a module.

**Acceptance Criteria:**

**Given** a quarantined replay conflict (AD-14 case 4), **when** the queue loads, **then** it shows the event with its on-device snapshot, server state, and ledger context side by side (UX-DR11)
**And** resolution — apply / recount / discard-to-audit — writes to the audit trail; batch-resolve works for similar conflicts
**And** over-receipt approvals (Epic 3) and escalated variances (Epic 5) land in the same queue
**And** the surface is permission-gated and hidden (not blocked) for roles without access (UX-DR20)

## Epic 6: Replenishment & Stock Intelligence

Reorder points alert on breach within 5 minutes and draft (never auto-submit) suggested POs; expiry/aging alerts keep batches FEFO-honest.

### Story 6.1: Reorder points, breach alerts, and suggested POs

As an Ops Manager,
I want per-SKU reorder points with breach alerts and pre-drafted suggested POs,
So that stockouts are prevented without the system auto-spending.

**Acceptance Criteria:**

**Given** SKUs, **when** an Ops Manager sets per-SKU (per-Warehouse) reorder points, **then** the system alerts on ATP breach within ≤ 5 minutes (FR-22)
**And** a suggested PO is drafted from default vendors and quantities, editable before submission — the system never auto-submits in v1
**And** alerts surface as panel entries and on the Replenishment surface (UX-DR12); inline-editable reorder-point cells (UX-DR8)

### Story 6.2: Expiry and aging alerts

As an Ops Manager,
I want expiry-approaching and aging-batch alerts,
So that batches ship FEFO before they expire.

**Acceptance Criteria:**

**Given** Batch-tracked SKUs, **when** a Batch approaches expiry within configurable lead days, **then** it appears on the expiry dashboard and in FEFO pick suggestions (FR-23)
**And** aging stock is visible by Batch
**And** expiry alerts are panel entries with amber treatment, click-through to the batches (UX-DR12)

## Epic 7: Channels & Oversell Protection — The Headline Promise

Shopify/Amazon.in/Flipkart connect; availability syncs from ATP through standing buffers; orders ingest idempotently and reserve atomically; channel-cancel releases.

### Story 7.1: Channel connections, buffers, and availability sync

As an Ops Manager,
I want to connect channels, configure safety buffers and backorder policy, and sync availability from ATP,
So that channels can only sell what the floor can ship.

**Acceptance Criteria:**

**Given** channel credentials, **when** an Ops Manager connects Shopify, Amazon.in, or Flipkart, **then** secrets are KMS-enveloped with rotation and delete-on-disconnect (AD-15)
**And** per-channel Safety Buffer and backorder policy (accept/reject) are configurable (FR-24)
**And** availability syncs from ATP with p95 ≤ 60 s latency; buffer exhaustion on a channel reduces that channel's synced quantity to 0 before the shared pool reaches 0 (FR-24, AD-13 standing reservations)
**And** buffers are ledger-backed standing reservations; inventory publishes unallocated sellable only (AD-13)
**And** sync health surfaces per channel with lag + retry queue via the transactional outbox; failures dead-letter; per-tenant call metering circuit-breaks runaway sync loops (AD-7/17)

### Story 7.2: Channel order ingestion and fulfillment writeback

As the system,
I want channel orders ingesting idempotently into reservations with fulfillment writeback,
So that marketplace orders reserve in seconds and status flows back without duplicates.

**Acceptance Criteria:**

**Given** a channel webhook, **when** delivered, **then** ingestion is idempotent via integration + event ID + verified payload hash, tenant-scoped and windowed (AD-5) — the same payload twice creates exactly one order
**And** ingested order → reservation completes ≤ 10 s at p95 under normal load (FR-25)
**And** **given** a marketplace API degrades mid-sale, **when** sync fails, **then** the Channels surface shows amber health with lag + retry while acceptance and reservations continue server-side — oversell protection never depends on a channel API's availability (UX-DR19)
**And** fulfillment/dispatch status writes back to the Channel; a channel-cancelled order releases its reservation atomically

## Epic 8: India Compliance — GST & E-way

Dispatches generate GST-compliant invoices; single and batch e-way bills; HSN summary for filing.

### Story 8.1: GST-compliant invoicing

As an Accountant,
I want invoices generated per dispatch from SKU GST/HSN data and place-of-supply rules,
So that dispatches produce compliant documents with no manual work.

**Acceptance Criteria:**

**Given** a dispatch, **when** invoicing runs, **then** the invoice line values reconcile exactly to dispatched qty × rate × GST computation (FR-26)
**And** GST rates and HSN codes come from catalog data; place-of-supply rules apply; money math uses paise and GST basis points as integers (AD-9)
**And** invoices are listed on the Compliance surface with document access

### Story 8.2: E-way bills and HSN summary

As an Accountant,
I want single and batch e-way bill generation and per-period HSN totals,
So that filing week closes without touching the GST portal by hand.

**Acceptance Criteria:**

**Given** consignments above the e-way threshold, **when** generation runs (single or batch), **then** e-way bills generate without manual portal steps (FR-26)
**And** e-way thresholds are versioned config data, never code literals (AD-9); the generation path handles OQ3 (portal vs GSP) behind the adapter port
**And** **when** generation fails, **then** it is retryable and never blocks recording the Dispatch
**And** the HSN summary produces per accounting-period totals for filing (SM-8 target: ≥ 90% eligible dispatches system-generated by month 3)

## Epic 9: Operational Visibility — Dashboard, Notifications & Audit

Live KPIs reconciling to the ledger; the notification panel; the Owner's filterable, exportable audit trail.

### Story 9.1: Operational dashboard

As an Ops Manager,
I want live KPIs per warehouse that reconcile to the ledger,
So that the dashboard is truth, not estimates.

**Acceptance Criteria:**

**Given** ledger activity, **when** the Overview loads, **then** it shows dock-to-stock, pick rate, short-picks, GRN variances, order accuracy, oversell/backorder events, expiry alerts, sync health, and dispatch pipeline for any administered Warehouse (FR-27)
**And** KPI values are ledger projections — reconciling to the ledger, with no "estimated" state (UX-DR7); tiles click-through to the underlying ledger-filtered list
**And** the dashboard renders < 2 s at p95 for a Tenant with 100k Ledger events/month (NFR-6)
**And** tiles stream best-effort and may lag under peak (AD-17 shedding); the stale-data banner governs; lists never auto-refresh (UX-DR19)

### Story 9.2: Notification panel and pushes

As an Ops Manager,
I want a single notification panel with mobile pushes only where they matter,
So that attention is spent on what is actionable.

**Acceptance Criteria:**

**Given** system events (task assignments, approvals awaiting, reorder breaches, expiry, QC, sync health), **when** the bell panel opens, **then** entries are newest-first, amber-treated, and click-through to source (UX-DR12)
**And** mobile pushes are restricted to task assignment + approval-needed + at-risk cutoff; reorder/expiry/breach alerts are panel entries only
**And** reorder breach alerts arrive ≤ 5 minutes from ATP breach (FR-22 latency); no badge-count notification spam (UX-DR25)

### Story 9.3: Global audit trail and async export

As an Owner,
I want to view and export the full audit trail with filters,
So that compliance and investigation are self-serve.

**Acceptance Criteria:**

**Given** all state-changing actions, **when** the Reports/Audit surface loads, **then** the Owner sees a filterable trail (who, what, when, reference document) (FR-28)
**And** digest exports are producible from the hash chain with the WORM anchor (AD-16); audit retention is ≥ 7 years with a lifecycle policy (NFR-5)
**And** export of 100k events completes asynchronously with completion notification
**And** any Ledger event is reachable from its reference document in ≤ 2 navigations (FR-28)