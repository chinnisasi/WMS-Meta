# Epic 7 Context: Channels & Oversell Protection — The Headline Promise

<!-- Compiled from planning artifacts. Edit freely. Regenerate with compile-epic-context if planning docs change. -->

## Goal

External sales channels — Shopify, Amazon.in, Flipkart — connect to the WMS so channel-listed availability syncs from ATP through per-channel Safety Buffers, and channel orders ingest idempotently and reserve ATP atomically at acceptance. The epic is the headline promise: zero oversells at 15× median order volume through a flash sale, with one channel's buffer exhausting before the shared pool empties and a losing racer resolved deterministically by the configured backorder policy — never a cancel-and-apologize. It works through degraded marketplace APIs: acceptance and reservation continue server-side while only the sync degrades.

## Stories

- Story 7.1: Channel connections, buffers, and availability sync
- Story 7.2: Channel order ingestion and fulfillment writeback

## Requirements & Constraints

- An Ops Manager connects Shopify, Amazon.in, or Flipkart with per-channel credentials; per-channel Safety Buffer and backorder policy (accept/reject) are configurable; disconnect deletes the credentials and revokes tokens.
- Availability syncs from ATP with p95 latency ≤ 60 s from an ATP change. Buffer exhaustion on a channel reduces that channel's synced quantity to 0 **before** the shared pool reaches 0.
- Channel orders ingest automatically and idempotently: the same webhook payload delivered twice creates exactly one order. Ingested order → reservation completes ≤ 10 s at p95.
- Fulfillment/dispatch status writes back to the channel; an order cancelled on the channel releases its reservation atomically.
- Oversell events: zero tolerated at any load — an oversell is a channel order accepted where dispatchable stock was insufficient; measured continuously, load-tested at 15× median order rate for 2 hours with no reservation-pool deadlock.
- Assumption carried from planning: marketplace partner-API approvals (Amazon.in, Flipkart) may slip; the fallback launches Shopify + manual orders first with marketplaces as fast-follow. Adapter design must not assume a specific marketplace's API contract shape.

## Technical Decisions

- **Channels is a NestJS module communicating through interfaces and events, never tables.** The outbound module exclusively owns the order state machine and Epic 4's idempotent ingestion machinery (manual + channel ingestion is one path); the inventory module owns quantities. A channel adapter never writes stock or order state directly.
- **Standing reservations (AD-13).** A channel's Safety Buffer is a standing reservation held through the shared atomic-reservation script (Postgres as reservation truth, Valkey Lua for atomic decisions, Postgres wins on divergence), owned by the channels module. The inventory module publishes only unallocated sellable quantity (on-hand − QC-held − committed) and knows nothing of channels; channel-visible availability = unallocated − that channel's standing reservation. Sync delivers the arithmetic result; it never performs buffer math itself.
- **Webhook idempotency (AD-5).** Channel webhooks derive a deterministic idempotency key from (integration, event ID, signature-verified payload hash), tenant-scoped and windowed. Signature verification is a precondition for any effect — there is no unverified ingest.
- **Transactional outbox (AD-7).** State change and outbound integration event commit in one transaction; a relay publishes at-least-once to a DLQ. Availability sync carries the 60 s SLO as sync-lag surfaced per channel; external failures retry with backoff and never block or roll back domain state. Every integration call is metered per tenant and circuit-broken on runaway volume (sync storms) — background/shedding work yields to interactive scanning under peak.
- **Credential handling (AD-15).** Channel secrets are stored per-tenant under KMS envelope encryption, referenced by id — never env vars or code; rotation is first-class; disconnect deletes credentials and revokes tokens; secrets never appear in logs, exports, or ledger events.
- **Permission gate.** Channel settings are not available to Operators; access is enforced by the shared command layer with role re-evaluation at command entry, not on login.

## UX & Interaction Patterns

- The web sidebar gains a **Channels** surface: connections, per-channel buffers, backorder policy, and sync health per channel.
- Degraded-channel state is shown in-line: a marketplace API failing mid-sale shows the Channels surface's health as **amber with lag + retry** (last-sync time and a retry action), never a global modal, while acceptance and reservations continue server-side. Sync health also appears on the Overview dashboard.
- This epic has no new mobile surface — oversell protection lives behind the API; floor scans are unaffected.

## Cross-Story Dependencies

- **Epic 7 ← 2 + 4 + 11.** Reservations and derived ATP (Epic 2) and the order state machine with idempotent ingestion and acceptance reservation (Epic 4 story 4-1) are prerequisites; Epic 11's two-level product→variant model is a hard gate because a Shopify product maps to variants and channel mappings bind to variant SKUs without any ledger change.
- Within the epic: 7.1 (standing-buffer machinery, connections, outbox sync) precedes 7.2 (ingestion and writeback) — 7.2's fulfillment writeback rides the same outbox 7.1 establishes.
- Epic 9 (dashboard/aggregation) consumes the per-channel sync-health KPIs this epic produces.
- Load-test success at 15× (NFR-2) is verified on the joint machinery of 7.1 + 7.2 and Epic 2's reservation core before the epic can close.