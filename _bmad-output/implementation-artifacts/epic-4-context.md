# Epic 4 Context: Outbound — Order to Dispatch Through Dead Zones

<!-- Compiled from planning artifacts. Edit freely. Regenerate with compile-epic-context if planning docs change. -->

## Goal

Complete the outbound loop end to end: orders (manual plus idempotent ingestion machinery) reserve ATP at accept time — not dispatch time — so oversell protection starts at acceptance; accepted orders group into waves and directed picklists; operators pick scan-first on mobile through Wi-Fi dead zones with nothing lost; short-picks re-plan themselves; the pack station verifies contents; and carrier rating, labels, manifests and dispatch close the loop with tracking writeback. This is the epic that realizes the "pick and pack through a dead zone" promise (UJ-2) and feeds the channels epic (7) its reservation and ingestion machinery.

## Stories

- Story 4.1: Orders — manual entry, idempotent ingestion, acceptance reservation
- Story 4.2: Waves and picklists
- Story 4.3: Scan-verified picking with offline tolerance
- Story 4.4: Short-pick re-planning
- Story 4.5: Pack station verification
- Story 4.6: Carrier rating, labels, and dispatch

## Requirements & Constraints

- **Orders** — manual creation by an Ops Manager; a manual order exceeding ATP is warned and either backordered or blocked per policy. The same channel-order payload delivered twice creates exactly one order; the ingestion machinery built here is channel-agnostic (channel adapters wire in during Epic 7). Cancelled orders release their reservation atomically.
- **Waves/picklists** — grouping runs on configurable policy (carrier cutoff, priority, size) into single-order or batch picklists. A batch picklist's path visits each bin at most once, with total steps no worse than the sum of the same orders picked singly. Wave release respects carrier cutoffs configured per channel/carrier.
- **Picking** — scan bin then item; wrong-item/wrong-bin scans are rejected on-device in under 500 ms with a specific reason and the nearest correct bin offered. Offline scans queue FIFO and replay in order, exactly once; nothing is lost on force-quit; queue depth is shown as a chip, never an error. Short-picks (bin holds less than task quantity) are taken with a reason and trigger automatic re-planning — alternate-bin suggestion within the same picklist when stock exists elsewhere, else the partial-order path. Short-picks aggregate on the dashboard as a slotting/accuracy signal.
- **Pack** — a pack scan mismatching picklist contents is rejected naming the discrepancy; pack completion (weight/dims optional) emits the packing ledger event and moves the order to Ready-to-Dispatch; a packing slip is produced.
- **Dispatch** — rates across configured carriers (v1 adapter ports: Delhivery, Blue Dart, Ecom Express, Shiprocket; final set is an open question). Label-generation failure surfaces a retryable inline error and never marks the order dispatched. Dispatch closes the reservation and writes the outbound ledger event atomically. Tracking webhooks update the channel within carrier feed latency.
- **Latency/load budgets** — ingested order → reservation ≤ 10 s at p95; label generation p95 ≤ 5 s; order acceptance + reservation sustains 15× the tenant's median order rate for 2 hours with zero oversell and no reservation-pool deadlock; offline tolerance ≥ 30 minutes with zero scan loss. Success metric: mis-picks + pack mismatches ≤ 2 per 1,000 dispatched lines by week 12.

## Technical Decisions

- **Outbound module owns the order state machine exclusively** (AD-6): no other module may add or transition order states. Waves, picklists, picks, pack and dispatch live in the outbound module; carrier adapters live in a separate carriers module. Both depend on the inventory module; neither is depended on by it.
- **Reservation truth (AD-2/AD-12)**: acceptance reserves through the single Valkey Lua decision point with pre-declared keys; the durable reservation record (owner, TTL, state held→committed→released/expired) lives in Postgres in the same transaction as the order state. Postgres wins on divergence. Dispatch/cancel serialize through the reservation identity so exactly one terminal transition wins; a reaper transitions expired holds; a losing racer gets a deterministic backorder/reject outcome, never an error retry.
- **Idempotency by contract (AD-5)**: every mutating call carries a client-generated ULID key, tenant-scoped, de-duped in the write transaction. Channel webhooks (later) derive their key from (integration, event-id, verified payload hash).
- **Offline picking (AD-4/AD-14)**: pick tasks carry their reservation from wave release; the offline client settles pre-reserved task stock only — granting new ATP, releasing foreign reservations, or accepting fresh orders is always online. Each op carries the per-bin `state_epoch` captured at task start; conflicts resolve by the 4-case taxonomy (settled / re-authorized / rejected / quarantined), never auto-merged. Bin on-hand never goes negative server-side. Replayed ops re-authorize against the badge-in session that created them.
- **Integration crossings (AD-7)**: state change and outbound event commit in one Postgres transaction; carrier/tracking effects publish at-least-once via the transactional outbox with a DLQ. External failures retry with backoff and never block or roll back domain state — dispatch records first, label retries follow.
- **Ledger discipline (AD-1/AD-11)**: pack and dispatch write registered ledger event arms (e.g. `order.dispatched`); every event is hash-chained, gap-free sequenced per warehouse, with signed qty and reference doc.
- All quantities/money follow the deterministic primitives (AD-9): scaled-integer milli-units, integer paise, UTC, UUIDv7. Mutations enter through one command layer with role-epoch re-evaluation (AD-10); tenant + warehouse scope on every path (AD-3).

## UX & Interaction Patterns

- **Scan banner (mobile)**: four honest states — ✓ Accepted (server-confirmed), ↻ Recorded · queued (on-device pass, persistence pending — never shown as green-accepted while queued), ✕ Rejected (< 500 ms on-device, reason + nearest correct bin; rejected scans never queue), ⚠ Held for review (server quarantined a replayed op). Appears ≤ 1.5 s of the scan; never color-only; dark-mode fills pair with dark-foreground tokens.
- **Pick flow**: badge-in → inbox (task card: type icon, order ref, item count, claimed-by) → directed path → scan bin, scan item, banner per line. Manual entry is a one-tap fallback at every scan step; camera and HID interchangeable; HID keeps capture-field focus across banner swaps. Re-planned short-pick tasks arrive as new cards linked to the original task ref; claim-lost shows "Claimed by {other} while offline" with the queued lines' disposition.
- **Offline/sync treatment**: queue chip shows count in amber, never error styling; "Syncing…" chip with settled count during replay; a queued op the server later rejects surfaces as a retraction in the sync summary, never silently corrected; rejections quarantine to Conflicts & Reviews without blocking further work.
- **Web Outbound surface**: orders, waves, picklists, pack/dispatch pipeline; at-risk waves show amber with time remaining to carrier cutoff; label failure shows a retryable inline state. Data tables are dense with cursor pagination (infinite scroll banned), sticky headers, tabular numerals, stale-data banner instead of auto-refresh. The ledger timeline (event type, signed qty, actor, time, reference-doc link) is the explanation surface for any quantity.
- Accessibility floor: WCAG 2.2 AA on web; every task state announced via platform accessibility APIs on mobile; targets ≥ 48dp; scan banner legible at largest dynamic type.

## Cross-Story Dependencies

- **Backward (required)**: Epic 2 (ledger, ATP, atomic reservation machinery, replay-reconciliation) and Epic 3 (mobile substrate: device enrollment, badge-in, task inbox, scanning, offline outbox primitives — picking adds a task type, it does not rebuild the substrate).
- **Forward**: Epic 7 wires channel adapters into Story 4.1's idempotent ingestion and reservation machinery — build it channel-agnostic. Epic 8 invoices from dispatches; Epic 9's dashboard aggregates short-picks, order accuracy and the dispatch pipeline; short-pick aggregation feeds the SM-3 slotting/accuracy signal.
- **Sequencing note**: the execution plan splits this epic in Phase 1 as 4-2d → 4-6c → 4-6d before Epics 5–9; the carrier-rating story (4-6d) is gated by Epic 11 (structured shipment addresses and SKU weight/dimensions), which lands in Phase 0.