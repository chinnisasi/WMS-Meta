# Epic 4 Context: Outbound — Order to Dispatch Through Dead Zones

<!-- Compiled from planning artifacts. Edit freely. Regenerate with compile-epic-context if planning docs change. -->

## Goal

Take an order from creation to dispatch: manual entry and (adapter-ready) idempotent ingestion reserve ATP at accept time — oversell protection starts at accept, not dispatch; waves group accepted orders into picklists with directed pick paths; Ramesh picks scan-verified on mobile through Wi-Fi dead zones (offline queue, idempotent replay, short-pick re-planning); the pack station verifies contents before a label prints; carrier rating/labels/dispatch close the order with tracking writeback. Realizes UJ-2 — picking is the floor's second polished flow and the first epic where the mobile client's task-type extension (pick) is exercised end-to-end.

## Stories

- Story 4.1: Orders — manual entry, idempotent ingestion, acceptance reservation
- Story 4.2: Waves and picklists
- Story 4.3: Scan-verified picking with offline tolerance
- Story 4.4: Short-pick re-planning
- Story 4.5: Pack station verification
- Story 4.6: Carrier rating, labels, and dispatch

## Requirements & Constraints

- Orders: manual creation (multi-line, per-SKU qty); a manual order exceeding ATP is warned and either backordered or blocked per policy. Ingested channel orders de-duplicate idempotently — the same payload delivered twice creates exactly one order (channel adapters themselves wire in Epic 7; the ingestion machinery and idempotency contract land here). Acceptance reserves ATP atomically via Epic 2's reservation machinery; ingested order → reservation ≤ 10 s p95. A cancelled order releases its reservation atomically.
- The order state machine is exclusively owned by the outbound module (AD-6) — no other module may add or transition order states.
- Waves: accepted orders group by configurable policy (carrier cutoff, priority, size) into single-order or batch picklists; wave release respects carrier cutoff times configured per channel/carrier. A batch picklist's directed path visits each bin at most once with total steps ≤ the sum of single-order paths for the same orders.
- Picking: scan bin then item; wrong-item/wrong-bin scans reject < 500 ms on-device with a specific reason and the nearest correct bin offered. Offline tolerance ≥ 30 minutes with zero scan loss; ops queue FIFO and replay idempotently, in order, exactly once; queue depth shows as an amber chip, never an error; force-quit loses nothing.
- Offline settling rule (AD-14): pick tasks carry their reservation from wave release; the offline client settles pre-reserved task stock only — granting new ATP, releasing foreign reservations, or accepting fresh orders is always online. Per-bin `state_epoch` is captured at task start; conflicts resolve by the 4-case taxonomy (quantity unchanged → apply; reservation valid → settle; bin moved on → short-pick/re-plan; unresolvable → quarantine) without blocking other tasks. Bin on-hand never goes negative.
- Short-pick: operator short-picks with a reason; alternate-bin suggestion arrives within the same picklist when stock exists elsewhere, otherwise a partial-order path; re-planned tasks arrive as new task cards linked to the original ref; short-picks aggregate as a slotting/accuracy signal.
- Pack: pack scan mismatching picklist contents is rejected naming the discrepancy; completion (weight/dims optional) emits the packing ledger event and moves the order to Ready-to-Dispatch; a packing slip is produced.
- Dispatch: rate across configured carriers behind the `CarrierAdapter` port (candidate ports: Delhivery, Blue Dart, Ecom Express, Shiprocket — final set pending OQ1); label failure surfaces a retryable inline error and never marks the order dispatched; dispatch closes the reservation and writes the outbound ledger event atomically; tracking syncs back (channel writeback machinery exercised; channel side lands in Epic 7). Label generation p95 ≤ 5 s.
- Waves at risk of missing a carrier cutoff show amber with time remaining on the Outbound surface.

## Technical Decisions

- The `outbound` module owns orders, the order state machine, waves, picklists, picks, pack, and dispatch (FR-12…15); `carriers` owns carrier adapters, rating, labels, manifests (FR-17). Both write ledger events through Epic 2's inventory module and consume reservations through its interfaces.
- Reservations are durable first-class records with a lifecycle (AD-12): `held→committed→released/expired`, TTL + reaper, terminal transitions serialized through the reservation identity. Availability always reads ATP net of all live reservation states; cancel-vs-dispatch double-release is impossible.
- Pick/transfer tasks reserve at wave release (AD-14), not at task claim; offline replay re-authorizes against the badge-in session that created the op (Epic 3 substrate — same outbox, idempotency keys, sync-summary patterns).
- Transactional outbox for integration events with DLQ and sync-lag SLO (AD-7): state change and event commit in one Postgres transaction; carrier API failures retry with backoff and never block or roll back domain state — dispatch records first, label retries follow.
- Idempotency keys (ULID) on all mutating endpoints; channel-order ingestion derives idempotency from integration + event ID + verified payload hash (AD-5) — tenant-scoped and windowed.
- External credentials (carrier API keys) are tenant-scoped under envelope encryption with KMS master key, referenced by id — never env/code; rotation first-class; disconnect deletes (AD-15). Secret material never appears in logs or ledger events.
- Command layer rules carry over: mutations only through command services with role-epoch re-evaluated at command entry; clients hold no business rules beyond on-device scan validation, which mirrors — never overrides — server rules.
- Ledger event types are added by registration (additive grammar arms, AD-11); per-warehouse gap-free sequence continues.

## UX & Interaction Patterns

- Web Outbound surface: orders, waves, picklists, pack/dispatch pipeline; carrier-cutoff pressure visible as amber at-risk waves with time remaining; label/API failure shows a retryable inline error with dispatch state unchanged.
- Mobile pick flow (mockup: `mockups/key-mobile-pick.html` — spine wins on conflict): inbox Pick tab → directed pick path → scan bin, scan item, green-tick banner per line. Universal verb scan → banner → next with manual entry as one-tap fallback at every step; camera and HID interchangeable; HID keeps capture-field focus across banner swaps; targets ≥ 48dp.
- Task cards for pick/pack tasks follow the Epic 3 card pattern; re-planned short-pick tasks arrive as new cards linked to the original ref; claim-lost shows "Claimed by {other} while offline" with queued-line disposition.
- Offline treatment (UX-DR17/18): amber queue chip with count; "Syncing…" chip with settled count during replay; on-device passes show "Recorded · queued", never green while queued; rejected replayed ops quarantine and surface in the sync summary without blocking work.
- Accessibility floor: every task state announced via platform APIs; scan-result is the largest text on task screens; Reduce Motion makes banner swaps instant.
- Microcopy: numbers and verbs, no exclamation marks.

## Cross-Story Dependencies

- Depends on Epic 2: reservations (AD-2/12), ATP, ledger, FEFO batch draw (picks default FEFO; FEFO override needs reason + audit), QC-held exclusion already enforced.
- Depends on Epic 3: mobile substrate (enrollment, badge-in, inbox, scanning, outbox/replay, sync summary) — pick is a new task type in the same inbox; bins/putaway state feeds pick-path suggestions; blocked bins are unpickable.
- Within the epic: 4.1's accepted orders are 4.2's wave input; 4.2's picklists are 4.3's task substrate; 4.3's short-pick (4.4) feeds re-planned cards; 4.5 consumes picked orders; 4.6 consumes Ready-to-Dispatch.
- Later epics: Epic 7's channel adapters plug into 4.1's ingestion machinery and 4.6's tracking writeback; Epic 5 reuses the epoch/conflict and task-card patterns for counts/transfers.

## Open items claimed into this epic

- Epic 2 retro a2 (grant-ceiling vs concurrent-adjustment race) and a8 (503 fail-closed ATP needs its own machine code) — both are story-4.1 spec decisions.
- Epic 3 retro a7 (vacuous facade-guard test + AD-6 read policy) — story-4.1 spec or the first refactor pass.
- Epic 2 retro a13: blocked-batch status draw-side unenforcement — the FEFO draw consumed by picking must consult batch status.