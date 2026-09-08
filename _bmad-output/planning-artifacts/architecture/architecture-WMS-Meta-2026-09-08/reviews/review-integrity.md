# Data-Integrity Review — WMS v1 Architecture Spine

**Reviewer:** data-integrity review (ledger / projection / reservation consistency)
**Scope:** `ARCHITECTURE-SPINE.md` (2026-09-08, draft) + PRD addendum §1.1–1.3
**Date:** 2026-09-08
**Method:** stress each consistency seam the spine leaves underspecified: Valkey↔Postgres split-brain, reservation lifetime, negative-stock invariants, count-task snapshot semantics, outbox relay failure, replay-reconciliation behavior, idempotency scope, FEFO/batch/in-transit semantics.

---

## Verdict

**CONDITIONAL ADOPT — the ledger-first paradigm (AD-1) is sound and well-chosen, but the spine introduces a second state store (Valkey) into the stock hot path without defining the recovery contract between the two stores.** The single most dangerous gap: reservations are *not* ledger events, yet "ATP state is rebuilt from the ledger on cold start" — so every restart is an oversell window unless a write-ahead reservation journal exists. Nine findings below; 2 critical, 4 high, 3 medium, 1 low. None require a paradigm change; all require explicit spine text before FR-5/FR-12/FR-24 build.

---

## Findings

### IN-01 · CRITICAL — No write-ahead order between Valkey reservation and ledger; cold-start rebuild silently drops live reservations

**Where:** AD-1, AD-2, addendum §1.1 ("event stream to persistence", "ATP state is rebuilt from the ledger on cold start and on drift").

**The hole.** The spine defines *where* a reservation decision happens (one Valkey Lua script) but never the *ordering and recovery contract* between that decision and durable persistence. Three concrete failure sequences, all unhandled:

1. **Grant-then-crash.** Lua script grants ATP to order O; process dies before the ledger event / order-state row commits. On cold start, "ATP state is rebuilt from the ledger" — the ledger contains *no reservation event* (a reservation is not a stock movement, so AD-1 never wrote one), so the rebuild produces ATP that includes stock O now considers sold. A second channel buys the same unit: oversell, and the ledger replay cannot even detect it because no event pair exists.
2. **Crash-then-grant (inverse).** Ledger event commits (e.g. `grn.received`), process dies before Valkey mirror refresh. Valkey now understates ATP until some unspecified refresh; the spine names "on drift" rebuild but defines neither the drift detector nor which store wins.
3. **Cold-start ambiguity.** AD-2 says rebuild *from the ledger*; AD-1 says the ledger is the only stock truth. But reservation state is genuinely *not derivable* from the ledger alone — it is a function of open order lines, channel buffers, and count-task holds. The spine's own two ADs disagree about whether reservations are reconstructible at all. What wins when "ledger says one thing and Valkey another" at cold start is undefined — the worst possible time to improvise.

Note that channel safety buffers (FR-24/25) are themselves long-lived reservations; they are equally unrecoverable under the current text.

**Required spine changes.**

- **Tighten AD-2** with an explicit write-ahead order: *every grant/release decided in Valkey must be journaled as an append-only `reservation.*` record (a separate Postgres reservation log, not a ledger stock event) committed in the same transaction as the order-line state change it drives, before the command service acknowledges the grant. The Valkey key carries the journal sequence; a grant without a journal row is void at recovery.*
- **Define cold start as a three-input rebuild, not a ledger rebuild:** (a) ATP base state replayed from ledger + checkpoints; (b) active reservations replayed from the reservation journal (open grants minus releases, minus reaper expiry); (c) reconciliation pass: any Valkey key not backed by a live journal row is deleted; any journal row with no Valkey key is re-applied. **Postgres wins on every divergence** — Valkey is a cache of decided state, never a source of state.
- **Define the drift detector** as a job, not an ad-hoc notion: periodic sampled comparison journal↔Valkey per warehouse (cheap, bounded), with a full rebuild trigger on tenant/warehouse isolation rather than a global lock.

---

### IN-02 · CRITICAL — Offline mobile picks bypass the reservation hot path entirely (AD-2 vs AD-4 contradiction)

**Where:** AD-2 ("The relational DB never sits in the reservation hot path"), AD-4 (offline scan decisions run on-device, only ledger persistence waits for network).

**The hole.** A picker in a dead zone scans a pick for an order that a channel session reserved *concurrently*. The on-device decision engine (addendum §1.3: accept/reject, FEFO) has no view of Valkey — it validates against a stale on-device mirror at best. At replay time the pick ledger event lands *after* the channel reservation was granted against the same ATP. Two outcomes, both broken:

- The pick is accepted and the ledger records stock the reservation already sold → ATP goes negative at replay, or
- The replay is rejected as a conflict and escalates to human review (AD-4) for what is actually a *routine concurrency* case — meaning the escalation queue floods during any network partition, defeating "dead zones don't stop the floor."

AD-2 and AD-4 as written are mutually unsatisfiable: AD-2 forbids a second check-and-decrement; AD-4 requires mutations to happen where Valkey is unreachable.

**Required spine changes.**

- **Amend AD-4:** offline pick grants carry a *reservation token or explicit offline-eligibility class*. Two viable mechanisms — the spine must pick one: (a) **ring-fenced floor stock**: each warehouse maintains an offline allowance (a standing reservation held in Valkey, journaled per IN-01) that offline picks draw from; channel ATP excludes it; (b) **task pre-reservation**: a pick task is only pushed to a device after its allocation is reserved in Valkey, and offline *completion* of a reserved task is a release-consume, not a fresh grant — conflicts only arise for tasks reserved before disconnect whose reservation expired, which is IN-03's reaper's problem, not the picker's.
- State explicitly: **offline replays never create new ATP grants**; they settle or fail existing ones. Anything else reintroduces check-then-write.

---

### IN-03 · HIGH — Reservation lifetime is undefined: no TTL, no leak reaper, no cancel-vs-dispatch race guard

**Where:** AD-2, AD-4; FR-24/25 (channels), FR-12–17 (orders/dispatch).

**The hole.** The spine never says when a reservation ends. Concrete leaks and races:

- **Accepted-but-never-dispatched channel order.** Reservation granted at acceptance (AD-2); the channel never confirms, or the merchant never dispatches. Under the current text the reservation lives until someone notices. Multiply by a busy season: ATP silently shrinks until the warehouse looks out of stock while bins are full — the exact unauditable-quantity failure AD-1 exists to prevent, re-created one layer up.
- **Cancel racing dispatch.** Customer cancels while the pack station is printing a label; cancel command and dispatch command are independent writes. If release is "release the reservation key" and dispatch is "consume the reservation + write `order.dispatched`," the interleaving cancel-releases → dispatch-consumes-nothing writes a dispatched order with unreserved stock, or vice versa. There is no defined terminal-state machine guard.
- **Client-generated Idempotency-Key retry of a grant** (AD-5) — is a retried grant the same reservation or a second one? Undefined.

**Required spine changes.**

- **New Rule (under AD-2):** *every reservation is created with a TTL and an owner (order line / buffer / count task); TTL expiry is a state transition, not silent decay — the reaper flips the owner's state (back to ATP, order → payment-pending/cancelled, channel order cancelled) and journals the release. Lease renewal is explicit and owned by the order state machine, never by wall-clock luck.*
- **New Rule:** *`order.cancelled` and `order.dispatched` are serialized through the reservation key itself — dispatch consumes the reservation inside the same Lua script family as release; both transitions are terminal-state guarded in the command service (AD-10) so only one can win, and the loser is a deterministic no-op with an audit trail.*
- **Clarify AD-5 interplay:** an Idempotency-Key retry of a grant returns the *original* grant outcome (same reservation), never a fresh decrement.

---

### IN-04 · HIGH — Idempotency key scope, payload binding, and retention are unspecified (and must not live in Valkey)

**Where:** AD-5; addendum §1.1 ("idempotency keys on every write"); 7-year audit posture implied by ledger immutability.

**The hole.** "The backend stores key → response" leaves open every question that decides whether this actually de-dupes:

- **Scope.** Key `01J...` from tenant A's mobile vs tenant B's webhook vs two different endpoints — global key space means cross-tenant collisions return *another tenant's cached response* (an NFR-4 class defect); per-endpoint means a retried webhook and its REST twin double-write. Unscoped keys also make the store enumerable/forgeable.
- **Payload binding.** Same key, different body (buggy client, or an attacker probing) — replay the cached response, reject with 409/422, or process? Undefined; the wrong default silently accepts a *different* mutation under the first's receipt.
- **Retention vs audit.** The ledger retains 7 years; the key→response table cannot usefully retain 7 years of full responses, but dropping it too early breaks exactly the offline-replay and webhook-retry cases (retries can arrive hours/days later). Also: the de-dupe insert **must be in the same Postgres transaction as the ledger event** — if it is a separate write (or a Valkey write), a crash between them re-opens IN-01's window from the idempotency side.
- **Store choice.** AD-2 bans Postgres from the *reservation* hot path; nothing says the idempotency store is Postgres. If anyone puts it in Valkey, idempotency evaporates on flush/failover while ledger events remain — at-least-once becomes at-least-twice.

**Required spine changes — tighten AD-5:**

- *Scope: `(tenant_id, endpoint_class, idempotency_key)` unique index; keys are tenant-scoped and endpoint-class-scoped, never global.*
- *Payload binding: store a hash of the normalized request; same key + same hash → replay stored response; same key + different hash → reject with `409 idempotency_conflict`, never process.*
- *Atomicity: the de-dupe row and the first ledger event commit in one transaction; the unique index is the concurrency guard (losing racer reads, never writes).*
- *Retention: keys retained ≥ 90 days as full records, thereafter as (key, hash, outcome-code) tombstones for the audit horizon — retention policy stated, not discovered in an incident.*
- *Store: Postgres only. Valkey may cache de-dupe lookups but is never authoritative.*

---

### IN-05 · HIGH — Negative-stock invariant not stated; same-bin concurrency control and short-pick FEFO swap undefined

**Where:** AD-1, AD-9 (signed qty), FR-15 (picks), FR-18/19 (adjustments, approval).

**The hole.** AD-1 makes the ledger the truth but never asserts the invariant the truth must satisfy. Three scenarios:

- **Concurrent pick + adjustment on one bin.** Both enter the command layer (AD-10) as Postgres writes against projections. Without a per-bin (or per-bin-batch) serialization discipline — a version check, an advisory lock, or a derived-state revalidation inside the command's transaction — two interleaved events can each see a positive bin and jointly drive it negative. Replay-reconciliation (IN-08) would then "alert" on a projection whose divergence is actually a *command-layer* invariant failure; the alert cannot fix an invariant the spine never declared.
- **Short pick with FEFO batch swap.** Allocated batch B1 has 3 units; picker finds 2 (damage/short). The on-device engine (addendum §1.3) will suggest B2 — but the swap touches *batch-level* ATP, not just SKU-level. If the pick event writes `qty=3` against B1 and B2 in a free-form way, or if the swap happens without re-allocating the remaining 1 unit from B1, you get batch-negative / SKU-positive states that no replay can reconcile into a coherent allocation story.
- **No declared exception path.** Adjustments (FR-19) legitimately can produce negative deltas; without naming adjustment as the *only* invariant-exception path (and gating it behind FR-19 approval), engineers will quietly add special cases elsewhere.

**Required spine changes.**

- **New Rule (under AD-1):** *a ledger event may never drive a bin-batch quantity below zero, enforced at command time by revalidating against event-derived state inside the command's transaction with a per-(bin, batch) serialization key. The only event type permitted to produce a negative-deriving effect is `adjustment.*`, and only through the FR-19 approval gate; such events are flagged for the reconciliation job to re-verify against the physical count.*
- **New Rule (short pick):** *a short pick is one atomic command that (a) closes the original allocation against the picked qty, (b) re-runs FEFO for the shortfall as a fresh allocation, and (c) journals both batch-level deltas as two ledger events with the same `reference_doc` — never a hand-edited batch field on the original event.*
- **Clarify replay determinism:** derived state is replayed in a **server-assigned monotonic sequence per (tenant, warehouse)**, not by UUIDv7 `event_id` — client-generated ULIDs (AD-4/AD-9) plus clock skew make ID-order replay non-deterministic for concurrent offline replays. (This sequence assignment is also what the count-variance mechanism in IN-06 and drift detection in IN-01 depend on.)

---

### IN-06 · HIGH — FR-20 "variances flagged, not lost" has no mechanism: count-task expected-quantity snapshot vs concurrent movements

**Where:** movements module (FR-20, FR-21), AD-1, AD-10.

**The hole.** The spine maps counts to the movements module and otherwise is silent. Two equally broken naive implementations:

- **Snapshot at task creation, freeze semantics:** any pick/transfer/putaway on the counted bins during the count window is recorded as a *phantom variance* (movement happened, count says otherwise) — the variance is "flagged" as loss that never happened.
- **No snapshot, live comparison:** variance is computed against whatever the projection says at submit time — movements during the count are silently absorbed into the variance. This is literally "lost," the failure FR-20 forbids.

**Required spine changes — new Rule (movements module):**

- *A count task pins an expected-quantity snapshot (per bin, per batch) at creation, anchored to the ledger sequence (IN-05).*
- *Variance at count submit = counted − expected, adjusted by **replaying all ledger events with sequence in (snapshot marker, submit)** for those bins — a concurrent movement during the count window is therefore neither phantom nor lost; the system distinguishes "counted during movement" from "stock actually missing."*
- *Bins with movements inside the window are flagged for a re-count or manager confirmation rather than auto-posting an adjustment; the posted count variance is itself a ledger event, idempotent per task, which re-pins the snapshot it corrects.*
- *Blind-count discipline (operator sees counted qty, not expected) is the default, since expected-on-screen counts anchor to stale numbers by construction.*

---

### IN-07 · MEDIUM — Outbox relay failure modes undefined: no lag SLO for channel availability sync, no DLQ, no poison-message policy

**Where:** AD-7; FR-24/25 (near-real-time availability sync); NFR-2 (peak load).

**The hole.** AD-7 says "at-least-once," "retry with backoff," "never block or roll back the domain state." All correct, and all silent on the operational contract:

- **Relay down / saturated during peak.** Availability sync to channels falls behind while local ATP keeps moving — the channel buffer (FR-25) is the only protection, and its size assumption ("per-channel safety buffers") is only valid for a *bounded* sync lag. The spine never states that bound, so nobody can size the buffer or page anyone when it is exceeded.
- **Poison message.** One malformed channel payload retried forever with backoff can head-of-line block a per-key ordered queue. No DLQ, no max-retry-then-quarantine, no per-aggregate ordering statement (global ordering is neither needed nor achievable at-least-once).
- **Silent success ambiguity.** "Dispatch records first, label/eway retries follow" is good — but nothing defines how long the label may lag or what surfaces when it exceeds that.

**Required spine changes — tighten AD-7:**

- *Availability-sync lag carries an explicit SLO (e.g., p95 ≤ 5 s under NFR-2 baseline, hard alert at 60 s sustained) and the FR-25 buffer sizing is documented as a function of that SLO.*
- *Per-aggregate ordering (per channel listing / per order), not global; a message failing N attempts moves to a dead-letter with an operator-visible replay tool; DLQ depth is an alerting metric.*
- *Outbox depth and oldest-unpublished age are first-class dashboards for the channels and carriers modules — relay health is observable, not inferred from missing external state.*

---

### IN-08 · MEDIUM — Replay-reconciliation: alert-only vs auto-rebuild is undecided, and divergence's effect on the write path is unspecified

**Where:** AD-1 ("A continuous replay-reconciliation job (NFR-1) alerts on any projection divergence").

**The hole.** "Alerts" answers neither question an on-call engineer will ask: (a) does anything *fix* the divergence, and (b) may the system keep taking writes while a projection disagrees with the ledger? Two failure modes of the job itself are also uncovered: a reconciliation job that reads projections *while* they are being written (false positives), and a corrupted *checkpoint/snapshot* (addendum §1.1) that replays divergently forever — the job would alert forever with no path to convergence.

**Required spine changes — tighten AD-1:**

- *Divergence handling is tiered: projections are auto-rebuilt from the ledger on detection (they are, by AD-1, derivable — rebuilding is always safe); ATP-facing divergence additionally alerts and, if repeated after rebuild within a window, **quarantines the affected write path** (reject new reservations for that warehouse) until human disposition — because persistent ATP divergence is IN-01's signature, not a rendering bug.*
- *Reconciliation reads a consistent snapshot (ledger sequence watermark) and only flags divergence past the watermark; a checkpoint that fails validation twice is discarded in favor of full replay, and checkpoint corruption is itself an alert.*
- *Reconciliation runs per (tenant, warehouse) partition with bounded replay windows (checkpoints, addendum §1.1) — full-replay cost on a 7-year ledger is a design constraint, not an afterthought.*

---

### IN-09 · MEDIUM — Batch FEFO across bins and warehouse transfers: in-transit batch state and ATP exclusion (FR-18) semantics undefined

**Where:** AD-1 (in-transit named only as a projection), movements module (FR-18), catalog (batches), FR-5.

**The hole.**

- **Transfer leg structure is undefined.** Is a warehouse transfer one event or two (`transfer.shipped` at origin, `transfer.received` at destination), with an in-transit state between? Without typed in-transit events: batch identity in transit is ambiguous, ATP at origin may be double-counted or double-subtracted, and an abandoned transfer has no defined expiry/recovery.
- **ATP exclusion (FR-18) is stated in the PRD but not architecture.** "In-transit excluded from ATP" must say *which ATP*: origin ATP loses the units at ship event; destination ATP does not gain them until receive; batch-level ATP (not just SKU-level) tracks the transit leg, because expiry (AD-9 base-UoM + batch attributes) continues to run while stock is on a truck — an expired batch arriving must be received into QC-hold/adjustment, not sellable stock, and FEFO at the destination must order by expiry, not by receipt date.
- **FEFO across bins** needs a stated allocation unit: FEFO is evaluated over *batch×bin* candidates (expiry first, then bin policy), and a partial allocation across bins must produce one allocation record the pick commands settle against — otherwise the short-pick path (IN-05) has no allocation to close.

**Required spine changes.**

- **New Rule (movements/inventory):** *every warehouse transfer is two ledger events (`transfer.shipped` with `from_bin`+origin warehouse, `transfer.received` with `to_bin`+destination warehouse) sharing a `transfer_id` reference; in-transit is the state between them, excluded from ATP at both ends, tracked per batch, and subject to a reaper that flags transfers unreceived past a threshold for human resolution (never auto-recognized).*
- **New Rule:** *FEFO allocation is per (tenant, warehouse) over batch×bin candidates ordered by expiry then slotting policy; allocations are first-class records consumed by pick commands, and batch-level ATP is reservation-aware (IN-01) exactly like SKU-level ATP.*

---

### IN-10 · LOW — Ledger total order is unspecified (prerequisite the other findings already cite)

**Where:** AD-9 (UUIDv7), AD-4 (client ULIDs), AD-1 (replay).

**The hole.** Event-sourced replay needs a deterministic total order per warehouse; UUIDv7 is time-ordered only as generated *per clock*, and offline clients generate their own ULIDs with skewed clocks and replay in task order, not time order. Without a server-assigned sequence, "replay" is underdetermined and checkpoint anchors (addendum §1.1) have nothing stable to anchor to.

**Required spine change.** Fold into AD-1/AD-9: *the inventory module assigns a monotonic per-(tenant, warehouse) sequence on ingest; all projection replay and checkpoint anchoring use that sequence. `event_id` remains the identity, never the order.*

*(Rated low because it is cheap, mechanical, and IN-01/IN-05/IN-06/IN-08 already depend on it — but it must land in the spine, not in code.)*

---

## Summary of required spine edits

| # | Change | Type | Severity |
|---|---|---|---|
| IN-01 | Write-ahead reservation journal; 3-input cold-start rebuild; Postgres wins on divergence; defined drift detector | Tighten AD-2 | Critical |
| IN-02 | Offline picks never create ATP grants: ring-fenced floor stock or task pre-reservation | Tighten AD-4 | Critical |
| IN-03 | Reservation TTL + owner + reaper as state transitions; cancel/dispatch serialized through reservation key | New Rule under AD-2 | High |
| IN-04 | Idempotency scope `(tenant, endpoint_class, key)`, payload-hash binding, same-transaction de-dupe, Postgres-only, retention policy | Tighten AD-5 | High |
| IN-05 | Non-negative bin-batch invariant with per-(bin,batch) serialization; adjustment as sole gated exception; atomic short-pick reallocation; server-assigned replay sequence | New Rules under AD-1 | High |
| IN-06 | Count snapshot anchored to ledger sequence + window replay + blind counts + movement-during-count flagging | New Rule (FR-20) | High |
| IN-07 | Sync-lag SLO + buffer sizing coupling; per-aggregate ordering; DLQ + replay tool; outbox-depth observability | Tighten AD-7 | Medium |
| IN-08 | Tiered divergence handling: auto-rebuild, quarantine on persistent ATP divergence, watermark-based reconciliation, checkpoint validation | Tighten AD-1 | Medium |
| IN-09 | Two-event transfer legs with typed in-transit batch state; ATP exclusion at both ends; batch-aware FEFO allocation records | New Rules (FR-18/FR-5) | Medium |
| IN-10 | Server-assigned monotonic per-(tenant, warehouse) sequence as the replay order | Fold into AD-1/AD-9 | Low |

The paradigm needs no revision; the spine text does. Items IN-01, IN-02, IN-03, and IN-10 should be resolved before any FR-5/FR-12/FR-24 story is estimated, since all four change the shape of the inventory module's tables and the reservation script's contract.