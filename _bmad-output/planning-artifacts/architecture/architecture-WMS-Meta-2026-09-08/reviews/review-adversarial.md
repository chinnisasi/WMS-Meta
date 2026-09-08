# Adversarial Architecture Review — WMS v1 Architecture Spine

- **Artifact reviewed:** `ARCHITECTURE-SPINE.md` (draft, 2026-09-08), against `prd.md` + `addendum.md` (2026-09-07)
- **Method:** adversary at the module seams. For each hole below, two units one level down (two modules, two teams, two repos building independently from the spine alone) are constructed such that **each one obeys every AD-1…AD-10 and every Consistency Convention to the letter**, and yet the two cannot be integrated without renegotiating an unpinned contract. A finding counts only if no existing AD or Convention text forbids it — that is what makes it a hole rather than a violation.
- **Reviewer:** adversarial architecture review (bmad-review posture), 2026-09-08

---

## Verdict

**Not adoptable as-is.** The spine's ten ADs correctly target the right failure classes (oversell, replay, tenancy, coupling), but the contracts that the ADs *point at* — the ledger event envelope, the reservation persistence model, the ATP formula decomposition, entity ownership of Bin/Batch/Order, and the offline-replay conflict policy — are named but never pinned. Five findings are critical: each one is a seam where two conformant builds produce a system that cannot be reconciled after the fact, i.e. exactly the class of defect the spine exists to prevent (oversell, replay divergence, unreconcilable projections). All are closeable with 5 new ADs and 5 tightened ADs/Conventions; none require reopening the stack or paradigm decisions.

**Score: 6/10 as a build-substrate. Strong on failure modes it knows about; unprotected at every seam between two modules that both obey it.**

| # | Finding | Severity |
|---|---|---|
| 1 | Ledger event schema, type registry, and event ownership unpinned | **Critical** |
| 2 | Reservations are not ledger events — rebuild-from-ledger is vacuous; Valkey↔Postgres atomicity seam at grant and release | **Critical** |
| 3 | Per-channel Safety Buffers: FR-5's ATP invariant is uncomputable under AD-6's dependency direction | **Critical** |
| 4 | Offline replay vs concurrent server mutation: no bin-level non-negativity, no conflict taxonomy, head-of-line blocking unpinned | **Critical** |
| 5 | Dispatch closes reservation "atomically" — impossible across Postgres and Valkey; ordering unpinned | **Critical** |
| 6 | Two owners of Bin: tenancy creates, putaway administers; putaway absent from the AD-6 dependency graph | High |
| 7 | Two owners of Batch (and Serial): catalog's tables vs inbound's creation vs the ledger's dimension | High |
| 8 | Order state machine ownership + cancel-vs-inflight-offline-picks gap | High |
| 9 | Task claim race (FR-29) and cross-module task-inbox ownership | High |
| 10 | In-transit representation unpinned (transit bin vs extra event fields vs projection) | Medium |
| 11 | QC hold: three overlapping hold mechanisms, one unpinned "pickable" predicate, hold-as-event vs hold-as-flag | Medium |
| 12 | "Domain events" conflation: the graph wires only inventory to events; compliance/reporting/audit of non-stock actions has no source | Medium |
| 13 | Idempotency key scope, storage, and TTL unpinned | Medium |
| 14 | Channel order → warehouse assignment and multi-warehouse channel availability unpinned | Medium |
| 15 | Buffer-exhaustion timing and sync-staleness interaction (UJ-3 semantics) | Medium |

---

## Critical findings

### C-1. The ledger event schema and event-type registry are unpinned — two teams write conformant, mutually unintelligible ledgers

**AD-1's field list** (`type, sku, batch/serial, from_bin, to_bin, qty, actor, timestamp, reference_doc, idempotency_key`) is a *field-name list, not a schema*. The Convention table pins event-type *naming* (`<domain>.<verb-past>`) but not *ownership* of the type namespace.

**Pair:**

- **Team A (inbound module)** writes GRN receipts with `reference_doc: jsonb {po_id, grn_id, line_no}`, `batch: {batch_id: uuid}`, and event type `grn.received`; its adjustment events are two types `adjustment.increased` / `adjustment.decreased` with `qty` already signed.
- **Team B (movements module)** writes adjustments as one type `adjustment.applied` with `reference_doc: "ADJ-2026-09-0042"` (a human string, allowed — "reference document"), `batch: "LOT-88231"` (a code string, allowed — "batch/serial-aware"), and `qty` unsigned with a separate `direction` field.

Both pass every AD-1 check: immutable, typed, batch-aware, from/to bin, actor, reference, idempotency key, signed-by-direction (Team B's `direction` field arguably satisfies AD-9's "signed by movement direction, never by convention"). Both replay correctly *in isolation*. Integrated:

- The replay-reconciliation job (NFR-1) cannot apply both event grammars in one projection.
- `reference_doc` cannot be joined for FR-28's "any Ledger event reachable from its reference document in ≤ 2 navigations" — one is a typed FK, one is a string.
- FEFO (FR-6) cannot sort: one team's events carry batch ids, the other's carry opaque codes with the expiry living in catalog only.

No AD names an event-type registry, an event envelope version, or which module may mint new types. The Deferred section even says the batch/serial field is "a discriminated union either way" — and *never pins the union's arms*.

**Fix — new AD-11 (Ledger event contract is a versioned, inventory-owned schema):**

> **AD-11 — One ledger event envelope, owned by inventory** `[PROPOSED]`
> The inventory module owns the single `LedgerEvent` envelope (Zod schema, versioned): `event_id (UUIDv7), tenant_id, warehouse_id, from_warehouse_id?, to_warehouse_id?, from_bin, to_bin?, sku_id, batch_ref?|serial_refs?, qty (int, base UoM, signed), event_type, actor, occurred_at, reference (typed discriminated union: {kind:'po',…}|{kind:'order',…}|{kind:'adjustment',…}|…), idempotency_key`. Every event type is registered in an inventory-owned enum; modules add types via PR to that enum, never by inventing local strings. `reference_doc` is a typed union, not free text. Event payloads are validated at write and at replay; an unregistered type or malformed payload is a build/test failure, not a runtime write.

**Severity: Critical.** Every downstream finding compounds through this one.

---

### C-2. Reservations are not stock movements, so AD-1 and AD-2 contradict: "rebuilt from the ledger" has nothing to rebuild from; the grant seam leaks stock

AD-2: *"ATP state is rebuilt from the ledger on cold start and on drift."* AD-1: *"every stock movement writes one immutable ledger_event."* But **a reservation is not a stock movement** — nothing moves; it is a hold. FR-5's glossary ATP subtracts `reserved`, so reserved must be derivable — from what? The spine never says.

**Pair:**

- **Team A (channels module)** treats Valkey reservation keys as the live truth and rebuilds cold-start ATP from ledger on-hand minus nothing, reconstructing reservations by scanning the outbound module's order table for "accepted, not dispatched" orders.
- **Team B (outbound module)** writes a durable `reservation` row in *its own* Postgres table at accept (allowed — AD-1 only forbids storing quantities, and a reservation count is arguably not "on-hand/ATP/QC/in-transit"), and cold-start rebuilds Valkey from that table.

Both conform. Integrated: two reservation stores with different owners, different lifecycles (Team A's derived-from-orders store loses manual-order reservations with different policies; Team B's table is invisible to the channels module per AD-6). A crash between the order-accept DB commit and the Valkey script grants a reservation in exactly one of the two systems — either leaked stock (unsellable forever) or phantom availability (oversell). **No AD assigns ownership of the reservation record, its lifecycle, or the crash-recovery rule at the grant seam.**

**Fix — tighten AD-2 (and amend AD-1):**

> **AD-2 (tightened) — Reservation truth lives in Postgres; Valkey is a hot cache of it.** A reservation is a first-class record written by the inventory module in the same Postgres transaction as the state change that motivated it (order accept, backorder, buffer change), with states `active → released(consumed|cancelled|expired)`. The Valkey script remains the only *concurrency* mechanism; on commit the same request updates Valkey. A reconcile job continuously diffs Valkey active reservations against the Postgres reservation projection and repairs toward Postgres (Postgres is truth, Valkey is cache — the inverse of AD-2's current wording). Crashes at any point converge to the DB state; a released/expired reservation releases the Valkey key exactly once. Reservation leases get a TTL tied to order state, so orphaned grants expire.

**Severity: Critical** — this is the oversell-protection primitive's persistence model, currently undecided while presented as decided.

---

### C-3. Safety Buffers cannot exist where FR-5 and the glossary put them: the ATP formula needs them, but AD-6 forbids inventory from knowing channels exist

Glossary: *ATP = on-hand − reserved − QC-held − safety buffer* — the buffer term is inside ATP, and FR-5's testable invariant (*"ATP never exceeds on-hand − QC-held − reserved − buffers, at any read"*) binds the inventory module. AD-6: *"the inventory module depends on nothing."* Buffers are configured per Channel (FR-24), i.e., they are channels-module data. The inventory module therefore **cannot compute the ATP that FR-5 requires of it**.

**Pair:**

- **Team A (channels)** implements the buffer as a *sync-time subtraction*: `channel_qty = inventory.sellable() − buffer`. Valkey and the reservation script know nothing of buffers; the shared pool is intact.
- **Team B (channels)** implements the buffer as a *standing reservation*: at channel-connect time it holds `buffer` units through inventory's AD-2 script, so buffers consume the shared pool for everyone.

Both satisfy FR-24's testables. They produce **different oversell outcomes**: under Team A, channels X and Y each see `(pool − own buffer)` and can both sell into the other's buffer during a race — the exact double-sell UJ-3 forbids. Under Team B, FR-5's invariant holds but the AD-2 script now has a second class of holder, and buffer *configuration changes* become reservation mutations through a script whose contract ("grant/release of ATP… grant/release of ATP happens only inside a single Lua script") was written for order reservations.

**Fix — new AD-12 (ATP decomposition and buffer semantics):**

> **AD-12 — ATP is layered; buffers are standing reservations held by the channels module** `[PROPOSED]`
> The inventory module publishes exactly one number per (tenant, warehouse, SKU): **unallocated sellable** = on-hand − QC-held − active reservations. The channels module computes each channel's synced availability as `sellable − Σ buffers of all channels on that channel-warehouse pair`, and *implements each buffer as a standing reservation acquired via the AD-2 script*, so buffer enforcement is inside the same atomic grant path (no second decrement path — AD-2 preserved). Inventory's ATP projection reports buffer consumption as a channel-owned reservation class. FR-5's invariant is restated per-term so each term has one owner.

**Severity: Critical** — with Team A's (perfectly conformant) reading, SM-4 "zero oversell tolerated" is false at exactly the flash-sale moment the product exists for.

---

### C-4. Offline replay vs concurrent server mutation: no per-bin non-negativity invariant, no pinned conflict taxonomy, replay head-of-line blocking undecided

AD-4 pins replay *order* and *idempotency*, and says conflicts "can't be auto-merged — escalate to human review." It does not say **what a conflict is**, and the on-device decision engine validates against a *stale local snapshot* by construction.

**Pair (FR-29 / FR-15 / FR-20 seam):**

- Ramesh's device cached bin B with 5 units; he scans 5 picks offline. Meanwhile, server-side, a second operator's online picks already took those 5 (FR-20 also permits a concurrent count). Reconnect: Ramesh's 5 pick events replay against an empty bin.
- **Team A (mobile-platform team)** treats "ledger may go negative per (sku, batch, bin); drift is corrected by the next count" as the invariant — clamp nothing, let the projection show negative, flag for review.
- **Team B** holds "the ledger never drives any (sku, batch, bin) projection negative; a replayed event that would is quarantined and re-planned as a short-pick (FR-15)."

Both conform to AD-4 (order-preserving, idempotent, LWW-forbidden, human review) and AD-1. Integrated: one replay produces a negative bin on-hand that then flows into ATP; the other silently rewrites the operator's confirmed scans. Downstream incompatibilities: FR-20's "expected quantity is the Bin state at count start" is ambiguous against a *negative* bin state; FR-15's short-pick re-planning can be triggered either by the device (pre-replay) or the server (post-replay) — two teams build it in the two different places; and "escalate to human review" halts a FIFO replay at the head of the queue, blocking every queued task behind one conflicted scan — or doesn't, depending on the team.

**Fix — new AD-13 (Replay conflict policy):**

> **AD-13 — Ledger non-negativity and replay conflict taxonomy** `[PROPOSED]`
> The ledger rejects (or quarantines at replay) any event that would drive a (sku, batch, bin) on-hand projection negative; negativity is never a tolerated state, it is a conflict. Conflicts are an enumerated, versioned taxonomy — `stale_bin_stock`, `task_reassigned`, `order_cancelled`, `bin_blocked_since_scan` — each with one pinned server outcome: quarantine the event, continue replaying the rest of the queue (no head-of-line blocking), surface the quarantined set to review. On-device validation carries a `state_epoch` (bin-snapshot version) so the server can distinguish "stale but satisfiable" from "unsatisfiable" and route the first to short-pick re-planning (FR-15) and the second to review.

**Severity: Critical.**

---

### C-5. FR-17's "Dispatch closes the Reservation and writes the outbound Ledger event atomically" is not achievable as written — and the release ordering is unpinned

The reservation lives in Valkey (AD-2); the ledger event and order state live in Postgres (AD-1); there is no joint transaction. "Atomically" is unimplementable, and the two conformant orderings have opposite failure modes:

- **Team A:** release Valkey first, then commit the ledger event. Crash between → reservation leaks (stock unsellable, silent, invisible).
- **Team B:** commit ledger event first, then release Valkey. Crash between → reservation still held while stock physically left → ATP double-counted down, **or worse, the reverse flow at grant: reserve in Valkey, then commit order → crash → phantom availability at the moment of peak load**.

Same for FR-25 ("cancelled-on-channel orders release their Reservation atomically") and buffer changes. AD-1's "same transaction" rule and AD-2's Valkey script cannot both hold for reservation-affecting events without a pinned ordering + repair, and nothing in the spine supplies it. (C-2's fix supplies the persistence model; this finding is the *operation ordering* half.)

**Fix — tighten AD-2 with an explicit seam rule:**

> Postgres reservation state and the ledger event commit first, in one transaction; the Valkey script application is step two, driven by the committed event (outbox-style relay for the Valkey seam), with the C-2 reconcile job repairing Valkey toward Postgres. In the hot path, the *decision* (does the unit exist?) reads Valkey; the *commit* of the decision is durable in Postgres. Consequence: a crash between steps never loses sellable stock; it at worst transiently under-allocates, which is resolved by reconciliation — never the reverse.

**Severity: Critical** (pairs with C-2; the grant-side crash is the oversell vector).

---

## High findings

### H-1. Two owners of Bin, and putaway is missing from the AD-6 dependency graph entirely

Structural seed: **tenancy** owns "warehouses, zones, bins (FR-1, FR-3)"; **putaway** owns "directed putaway, *bin admin* (FR-11)" — create/block/merge/retire. So Bin creation and Bin blocking live in different modules. FR-11's testable says blocking removes the bin "from putaway suggestions *and picking* immediately" — picking is **outbound**, but the AD-6 graph has no `outbound → putaway` edge (outbound → inventory, outbound → catalog only). And the graph omits putaway, tenancy, replenishment, carriers, notifications altogether — five modules of the structural seed have no pinned dependency position, so two teams integrate them differently.

**Pair:** Team A (tenancy) models the Bin with `{code, capacity, type, zone}` and puts `blocked` there too, treating FR-11 as tenancy-surface admin; Team B (putaway) keeps bin master in tenancy but owns a private `bin_ops` state (blocked, velocity class, slotting score) and exposes `isPickable(bin)`. Outbound then either adds a `outbound → putaway` dependency (a graph the spine never drew — is it legal?), or subscribes to a `bin.blocked` event and derives its own pickable set in its own projection (a second owner of the same predicate). FR-10's capacity check and FR-11's retire-with-stock rejection each need on-hand — putaway must query inventory (legal) — but "immediately" in FR-11 is now a projection-lag question nobody pinned.

**Fix — tighten AD-6 (complete the graph, single pickability predicate):**

> Complete the dependency graph with all modules (tenancy as the root owner of Warehouse/Zone/**Bin master**; putaway → tenancy + inventory; outbound → putaway (bin state read), replenishment → inventory + catalog, carriers → outbound, notifications ← events). Bin *blocking/retire* is a command on the putaway module (FR-11) that writes to the tenancy-owned bin master via its interface — one row, one owner, no copied state. Publish `bin.blocked` / `bin.retired` as domain events; the "pickable" predicate is computed once (in inventory's projections) and consumed by putaway suggestions and outbound picking alike.

**Severity: High.**

### H-2. Two owners of Batch (and Serial): catalog's tables, inbound's creation act, and the ledger's dimension

The seed puts "batches, serials" in **catalog**; but a Batch comes into existence at GRN time with mfg/expiry (FR-8, FR-6) — **inbound's** act — and its stock whereabouts is a **ledger** dimension (AD-1). Three teams, three readings:

- **Team A (catalog):** Batch is a catalog aggregate; inbound calls `catalog.createBatch()` during GRN; batch master rows in catalog's tables; ledger carries `batch_id` FK.
- **Team B (inbound):** Batch is an inbound concept (a *received lot* — glossary literally says "a received lot of a SKU"); catalog holds only the *tracking flag*; batch attributes live on the GRN and propagate into the ledger.

Both conform. Integrated: two batch masters, FEFO (which needs expiry at *pick* time) reads one of them and is wrong for the other tenant's flow; serial-uniqueness (FR-6: "cannot be in two Bins' on-hand simultaneously") is enforced either in catalog (unique serial index) or in inventory (projection check at ledger write) — these fail differently under offline replay (a quarantined C-4 serial pick creates a transient duplicate the catalog-unique-index team treats as a hard error and the ledger-derived team treats as a conflict event).

**Fix — Rule in the Conventions table (Ownership column) + tighten AD-11:**

> **Rule — traceability ownership:** catalog owns Batch/Serial *identity and attributes* (id, SKU, mfg/expiry, status) and their creation API; the inbound GRN creates them through catalog's interface; the ledger carries batch/serial as typed references (C-1's discriminated union) and is the *only* source of batch/serial *location and quantity*; serial-uniqueness is enforced at ledger-write time by the inventory module (pre-event validation), not by a catalog index.

**Severity: High.**

### H-3. Order state machine: no owner named, and channel-cancel vs offline in-flight picks is unpinned

AD-10 says all mutation enters command services; it does not say *whose* command service owns the order state machine. `outbound` owns "orders" (structural seed) and `channels → outbound` is the only channel edge — but the pair is still constructible:

- **Team A (channels):** on webhook, channels itself decides accept/reject (it owns the backorder policy, FR-24), calls inventory's AD-2 script directly, then *creates* the order record in outbound via interface with state pre-set.
- **Team B (outbound):** channels forwards the raw payload; outbound's `acceptOrder` command owns the state machine, the reservation call, and the backorder decision.

Both satisfy FR-12/FR-25's testables. Integrated: the backorder policy is evaluated in two places; the `cancelled-on-channel` path (FR-25) releases the reservation (channels) while the order's picks may already be queued on a device (AD-4) — replay then writes pick events against a cancelled order, and nobody owns the resulting state (picked stock is in a tote belonging to no valid order). FR-17 "Dispatch closes the Reservation" is the only pinned transition seam; accept, cancel, short-pick-partial, and pack states are unpinned.

**Fix — new AD-14 (Order state machine ownership):**

> **AD-14 — Outbound owns the order state machine; channels is a transport** `[PROPOSED]`
> The outbound module owns the single order state machine; its states and allowed transitions are enumerated in the spine (draft → accepted → picking → picked → packed → ready-to-dispatch → dispatched → closed; cancelled; backordered). The channels module submits channel orders through outbound's `acceptOrder` command (AD-10) and receives the deterministic outcome; it never sets order state directly. Cancellation semantics are pinned: a cancel while picking releases the un-picked reservation remainder and converts picked units into a pinned ledger path (`pick.reversed` events + return-to-bin); a channel cancel arriving mid-replay quarantines the affected offline ops under AD-13's `order_cancelled` outcome.

**Severity: High.**

### H-4. FR-29 task-claim race: two operators, one picklist, both offline — and nobody owns the cross-module task inbox

FR-29's only testable about contention is "claimed by another Operator disappears within one poll/refresh cycle" — that constrains the *view*, not the *write*. The inbox aggregates tasks from four modules (picklists, putaways, counts, transfer confirms) with no owning module (`notifications` does "task push" only).

**Pair:**

- **Team A (outbound):** claim = server-side row update on the picklist at assignment time; the mobile client works only *assigned* tasks; a second operator's offline scans against a reassigned picklist are rejected at replay because the task's assignee no longer matches.
- **Team B (mobile platform):** claim = an on-device lease recorded locally and asserted at replay; any operator's scans are valid as long as the task was open at scan time (floor-first reading of AD-4's "scan decisions run on-device").

Both conform to AD-4/AD-5/AD-10. Integrated: the same physical pick can be scanned by two operators (different idempotency keys — AD-5 does not dedupe *different* keys for the *same* logical action), double-picking one bin; or a validly-scanned pick is discarded because a manager reassigned mid-scan. No AD defines a claim lease, a claim epoch on replayed operations, or whether "task open at scan time" or "task assigned to me" is the acceptance predicate.

**Fix — new AD-15 (Task claim and epoch):**

> **AD-15 — Tasks are claimed server-side with an epoch; replayed ops carry the epoch** `[PROPOSED]`
> Each module owns its tasks; claim is an atomic server transition (`open → claimed(operator, epoch)`) with a lease expiry. The mobile inbox is a read-only aggregated projection over module events (owned by the notifications module's read API), never a source of truth. Every offline operation records the task's `claim_epoch` at decision time; at replay the server accepts ops whose epoch matches the current epoch (progress may be acknowledged even after reassignment, by policy) and quarantines mismatches under AD-13. Two claims of one task resolve deterministically (first server-side claim wins; the loser is notified — never silently).

**Severity: High.**

---

## Medium findings

### M-1. In-transit representation unpinned (FR-18)

AD-1's envelope has `from_bin`/`to_bin` and one `warehouse_id` — a Warehouse→Warehouse transfer's outbound leg has no pinned field to say *where it is going*, and the in-transit projection (AD-1 lists "in-transit" as derived) has no pinned event pair. **Pair:** Team A encodes transit as `to_bin = TRANSIT/<transfer_id>` inside the source warehouse; Team B adds `to_warehouse_id` to the event and derives in-transit as "outbound leg without inbound leg, correlated by transfer id." Both conform; the in-transit projection, the ATP exclusion test (FR-18), and cross-warehouse traceability (FR-6) all read differently. **Fix:** folded into AD-11 (envelope carries `from_warehouse_id`/`to_warehouse_id`; in-transit is defined as the interval between the two correlated legs; the transit-bin hack is forbidden). **Severity: Medium.**

### M-2. QC hold: three overlapping mechanisms, one missing predicate

The PRD gives three ways stock stops being pickable: quarantine **zone type** (glossary), **QC Hold** bin-level state (FR-9), **bin block** (FR-11). AD-1 says QC-held is a ledger-derived projection, but hold/release are *not stock movements* — same shape of gap as C-2. **Pair:** Team A (inbound) keeps a QC flag on its own stock table and writes only `qc.released` events; Team B writes `qc.held`/`qc.released` event pairs at (sku, batch, bin) granularity and derives everything. Both conform; the ATP projection consumes one and breaks on the other; the FEFO pick engine needs held-*batch* granularity that "bin-level" doesn't specify. Also: does a `movements` transfer of QC-held stock require inbound's release first? Unowned. **Fix:** Rule — QC hold is a ledger event pair (`qc.held` / `qc.released`) at (sku, batch, bin) granularity, commanded by the inbound module (AD-10), consumed by inventory's ATP projection; the single pickability predicate is inventory's (see H-1); zone type is putaway-suggestion metadata, never an enforcement mechanism. **Severity: Medium.**

### M-3. "Domain events" graph wires only inventory to the bus; audit of non-stock actions (FR-28) and compliance inputs have no source

The AD-6 graph shows `inventory --> events` only. But FR-28's audit trail covers *all state-changing actions* (role changes, PO amendments, channel config changes), FR-26's invoice needs dispatch *metadata* (consignee, place of supply, taxable value) that no ledger event carries, and FR-27's KPIs need order lifecycle events. **Pair:** Team A (reporting) subscribes to all module events (reading the bus as shared); Team B (compliance) adds a `compliance → outbound` dependency to fetch order data at invoice time. One violates the pinned graph; the other is impossible under it. **Fix:** tighten AD-6: every module publishes domain events on the shared bus through the outbox (AD-7); the pinned graph constrains *direct interface* dependencies, not event subscriptions; the ledger event `reference` union (C-1) carries the ids, and consumers fetch documents through the owning module's read interface when they need payload detail. Reporting owns the audit projection; every module's command layer (AD-10) emits an `audit.*` event for non-stock state changes. **Severity: Medium.**

### M-4. Idempotency key scope, storage, and TTL unpinned (AD-5)

**Pair:** Team A scopes key uniqueness per (tenant, endpoint); Team B per (tenant, endpoint, request-hash); a webhook replayed by the channel *with a different payload but the same event id* dedupes under one and duplicates under the other. Storage: Team A stores key→response in the same transaction as the event (matches AD-5's wording); Team B in a Valkey side-cache with 24 h TTL — after 30 min offline (NFR-3's floor) plus a day in queue, a replay re-executes. **Fix:** Rule: idempotency keys are unique per (tenant, operation class); the key→response record commits in the same Postgres transaction as the effect; TTL ≥ 7 days (aligned with NFR-5's audit posture); external-webhook dedup uses the channel's own event id as the key, pinned per adapter. **Severity: Medium.**

### M-5. Channel order → warehouse assignment and multi-warehouse availability unpinned

Warehouse is the partition key (AD-3); channels sync "availability from ATP" (FR-24) — but ATP of *which warehouse*? **Pair:** Team A syncs per (channel, warehouse) with the channel listing each warehouse's quantity separately; Team B syncs the tenant-wide sum minus buffers and assigns the warehouse at ingestion by a rule it invents. Both conform; the same Shopify listing shows different numbers, and backorder policy evaluation (which happens against the pool) differs. **Fix:** Rule: channel availability is computed and synced per (channel, warehouse); the channels module assigns the fulfilling warehouse at ingestion via a pinned policy port (default: single-warehouse tenants trivially; multi-warehouse policy is a v1.5 decision point registered in Deferred). **Severity: Medium.**

### M-6. Buffer-exhaustion timing vs 60 s sync latency (UJ-3) — the promise relies on an unstated mechanism

UJ-3's "buffer exhaustion on a Channel reduces that Channel's synced quantity to 0 before the pool is empty" is only guaranteed if the sync formula subtracts *all* channels' buffers from each channel's view (i.e., Team B's reading of C-3) **and** if reservation rejections trigger an immediate (not 60 s-cadence) sync for that channel. **Pair:** Team A syncs on a 60 s cadence (meets FR-24's latency ceiling); Team B syncs event-triggered on reservation-win/reject plus cadence. During the 15× spike of NFR-2 these produce materially different channel-facing availability and different oversell exposure. **Fix:** Rule: availability sync is event-triggered (reservation granted/released, buffer changed, ledger event reducing sellable) with the 60 s value as the *p95 bound on the cadence fallback*, not the sole mechanism; per-channel exhaustion forces an immediate sync. **Severity: Medium.**

---

## Low

- **L-1.** Dock-to-stock (SM-5): "delivery arrival" is stamped by no one (ASN is manual-only in v1); reporting cannot derive the KPI without an inbound-owned arrival timestamp event. Fix: Rule — the GRN-open event carries `arrival_at` stamped by inbound; reporting derives. *(Low)*
- **L-2.** FR-12 manual-order vs channel-order dedup collision (same external order entered by hand during a webhook retry) has no pinned precedence. *(Low)*
- **L-3.** AD-9's "conversions applied only at presentation/ingest edges" leaves the *count* flow (FR-20, operator counts in cartons) on the ingest-edge side of the boundary — pin: count entry converts at the mobile ingest edge, ledger stays base-UoM. *(Low)*
- **L-4.** The spine's Stack table pins Drizzle "0.45.x" while noting 1.0 is RC — a minor version drift risk between teams; pin the upgrade rule (major-version bumps require spine amendment). *(Low)*

---

## Summary of proposed amendments

| Change | Type | Closes |
| --- | --- | --- |
| **AD-11** Ledger event envelope + type registry, inventory-owned, typed reference union, batch/serial discriminated union arms pinned | New | C-1, M-1 |
| **AD-2 tightened** Reservation truth in Postgres (states + lifecycle), Valkey as repaired cache; commit-then-apply ordering; orphan expiry; reconcile direction pinned | Tighten | C-2, C-5 |
| **AD-12** ATP decomposition: inventory publishes unallocated sellable; buffers are channels-owned standing reservations through the AD-2 script; per-channel sync formula pinned | New | C-3, M-6 |
| **AD-13** Ledger non-negativity invariant + replay conflict taxonomy (`stale_bin_stock`, `task_reassigned`, `order_cancelled`, `bin_blocked`), quarantine-and-continue (no head-of-line blocking), `state_epoch` on on-device decisions | New | C-4 |
| **AD-14** Outbound owns the order state machine; channels is a transport; cancel-mid-pick semantics pinned | New | H-3 |
| **AD-15** Server-side task claim with lease + epoch; replayed ops carry the epoch; inbox is a read-only projection | New | H-4 |
| **AD-6 tightened** Full dependency graph (add putaway, tenancy, replenishment, carriers, notifications); event subscriptions allowed for all modules, direct interfaces per graph; single pickability predicate | Tighten | H-1, M-3 |
| **AD-1 tightened** Reservations, QC holds, and bin blocks are explicitly *not* stock movements but *are* ledger-recorded state pairs (`reservation.granted/released`, `qc.held/released`) so every projection replays | Tighten | C-2, M-2 |
| **AD-5 tightened** Key scope per (tenant, operation class), response stored in the effect's transaction, TTL ≥ 7 days, webhook keys = channel event ids | Tighten | M-4 |
| **Conventions — Ownership rules** Bin master: tenancy (mutations via putaway); Batch/Serial master: catalog (created via inbound); order state machine: outbound; per-(channel,warehouse) availability; arrival timestamp: inbound | Tighten | H-1, H-2, M-5, L-1 |

**One-line verdict for the record:** the spine's failure modes are not in its ten decisions — they are in the eleven contracts those decisions presuppose and never pin; AD-11 through AD-15 plus the five tightenings above close every pair constructed here.