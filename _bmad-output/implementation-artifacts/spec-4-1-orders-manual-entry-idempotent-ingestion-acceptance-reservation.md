---
title: 'Story 4.1: Orders — manual entry, idempotent ingestion, acceptance reservation'
type: 'feature'
created: '2026-09-10'
status: 'in-review'
route: 'dispatch'
baseline_commit: '33f57ea' # wms-be main
baseline_commit_fe: 'c2173d1' # wms-fe main
context:
  - '_bmad-output/implementation-artifacts/epic-4-context.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** Nothing outbound exists — the `outbound` module is a placeholder, orders cannot be created or ingested, and oversell protection cannot start at accept time. The Epic 2 reservation machinery has no consuming flow.

**Approach:** Fill the outbound module with the order aggregate and its state machine: one create endpoint serving manual entry and (adapter-ready) idempotent ingestion — acceptance reserves ATP per line atomically through Epic 2's reservation machinery; cancel releases atomically. Settles the two retro decisions claimed into this story: close the grant-ceiling gap by re-validating the committed ceiling under row lock inside the grant journal tx (epic-2 retro A2), and give the 503 fail-closed path its own machine code `reservation-store-unavailable` (A8).

**Decided (2026-09-10, human):**
- **Backend-only in this story** — the Outbound orders card + `orders.manage` FE mirror land with story 4.2's Outbound surface (the 3.1 precedent).
- **Fixed backorder policy** for v1 — over-ATP lines reserve partially and are marked `backordered` (shortfall visible in the response); per-channel configurable policy arrives with Epic 7.
- **Accepted-order reservation TTL = 7 days** — expiry is detected downstream at commit time (409 `conflict` "Reservation is not held"), not surfaced with new order-state machinery in this story.
- **Keep the full spec** (human accepted ~2,300 tokens vs the 1,600 ceiling).

**Decided (technical, from investigation + retro claims):**
- Channel-order dedup is a database-level partial unique index on (tenant, integration id, external event id) — the same payload twice returns the same order (idempotent success); a *different* payload on the same ref is `422 order-source-conflict` naming the existing order. Webhook signature verification and channel adapters themselves ride Epic 7; the ingestion endpoint is an authenticated API surface gated by `orders.manage`.
- Epic-3 retro a7: fix the vacuous facade-guard regex (it can never fire) this story; the broader AD-6 read-policy refactor of pre-existing table reads is a deferred cleanup, not this story's patch.

## Boundaries & Constraints

**Always:**
- Acceptance reserves per line via `InventoryFacade.grantReservation` (`owner_type: 'order'`), inside the order-create transaction — a reservation-store failure (503) fails the whole order creation (nothing accepted half-reserved); the deterministic 409 `unavailable` loser outcome is surfaced per policy (backorder or block).
- Line-level ATP split at accept: reserve `min(lineQty, ATP)`. Under backorder policy the unreserved remainder marks the line `backordered`; under block policy the whole creation is rejected. Fully-unavailable lines get no reservation.
- The order state machine lives only in the outbound module (text status + migration CHECK, additive arms: `accepted`, `cancelled` now — picking/packed/dispatched arms arrive with stories 4.3/4.5/4.6). No other module may add or transition order states (AD-6).
- Cancel is allowed while `accepted` (pre-pick), is idempotent-keyed, and releases all open order reservations atomically through the existing release path (terminal-transition serialization already guarantees cancel-vs-dispatch single-winner); outbox `order.cancelled` + audit row.
- All mutations carry required `Idempotency-Key` with payload-hash replay (422 `idempotency-key-reuse` on mismatch, concurrent duplicate → 409 `conflict`); commands re-read the member role at entry (`orders.manage`: Owner + Ops Manager; Operator/Accountant none); audit row + outbox `order.created`/`order.cancelled` in the same tx, outbox before the idempotency key.
- Grant-ceiling fix (A2) stays inside the inventory module: after the Valkey script win, the journal tx re-reads the ceiling contributors (`FOR UPDATE` on the stock rows), and a ceiling regression compensates (Valkey decrement, no journal row) returning 409 `unavailable` — the "never oversells" module-header claim is then true for grant-vs-stock, not just grant-vs-grant.
- Reads: `GET /tenants/{tenantId}/orders/{orderId}` (order + lines + per-line reservation state) and a warehouse-scoped cursor-paginated list (keyset `(created_at, id)` index from day one — the skus-index lesson). OpenAPI export + FE `api:generate` ride the story (additive).

**Never:**
- No channel adapters, webhook ingestion, signature verification, or Channels surface (Epic 7 plugs into the dedup machinery as-is).
- No waves, picklists, picking, pack, or dispatch (4.2+); no order amend/edit after acceptance (arrives with wave/picking semantics); no FE surface if the split below is chosen.
- No reservation expiry UX (order-state machinery for expired holds) — deferred; commit-time conflict is the backstop.
- No mobile changes (pick is story 4.3; the inbox is untouched here).

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Create manual order | multi-line (SKU, qty), ATP sufficient | `201` order snapshot `status: accepted`, per-line reservation ids; outbox `order.created` + audit | unknown warehouse/SKU → `404`; malformed lines → `400 validation-failed` |
| Create over-ATP (decided: backorder) | line qty > ATP | order accepted; partial line reserved + marked `backordered` with reserved/shortfall qty in response | N/A |
| Duplicate channel payload | same (integration, external event id) twice | second delivery returns the first order's snapshot (no new reservation) | different payload on same ref → `422 order-source-conflict` naming the existing order |
| Cancel accepted order | cancel command, reservations open | all open reservations released; status `cancelled`; outbox `order.cancelled` + audit | replay (same key) re-serves; unknown → `404`; already-cancelled replay under a new key → idempotent no-op semantics (`200` snapshot) |
| Reservation store down | Valkey unreachable / counters not-ready | order creation fails closed | `503 reservation-store-unavailable` (renamed; nothing written, retryable) |
| Grant loses the last unit | two concurrent accepts racing one unit | exactly one succeeds; the loser's line reserves its remaining ATP and marks the shortfall `backordered` | never both |
| Wrong authority | operator/accountant role, foreign tenant, missing key | nothing written | `403 role-denied` / `permission-denied`, `401`, `400 validation-failed` |
| Adjust-vs-grant race | adjustment commits between probe and journal tx | grant re-validates under row lock | regression → compensate + `409 unavailable`; ceiling test pins it |

</frozen-after-approval>

## Code Map

- `workspace/core/backend/wms-be/src/modules/outbound/outbound.module.ts` — placeholder; gains `OrderCommandService` + providers. Controllers live in `src/api/*` (e.g. `inbound.controller.ts:50`, `@Controller('tenants')`) — new `src/api/outbound.controller.ts` follows.
- `workspace/core/backend/wms-be/src/modules/inventory/reservation.service.ts` — `grant` (:244, probe tx :280-295 → Valkey `runGrantScript` :712 → journal INSERT, compensate :784), `release` (:406), `atp` (:440); `unavailable()` 409 (:159-163), 503 `not-ready` (:461-467) + `valkeyDown()` (:968-979); `committedCeiling` (:853). A2 re-validation goes between the script win and the journal INSERT; A8 renames both 503 arms.
- `workspace/core/backend/wms-be/src/modules/inventory/inventory.facade.ts` — `atp` (:489), `grantReservation` (:474), `commitReservation` (:479), `releaseReservation` (:484) — the outbound module's only inventory seam.
- `workspace/core/backend/wms-be/src/shared/db/schema.ts` — table conventions (uuidv7 ids, `tenantTimestamps`, RLS only in migrations :31-45); `reservations` table :865-897 (partial unique `reservations_open_owner_scope_unique` :886 — same-scope replay returns existing). New `orders` + `order_lines` mirror the PO tables' shape; highest migration is `drizzle/0016_*.sql`.
- `workspace/core/backend/wms-be/src/modules/inbound/po.command.ts:180-247` — the canonical command shape to copy: permission re-read → replay check → guards → writes (uuidv7) → snapshot → outbox append → (audit) → `writeIdempotencyKey` last.
- `workspace/core/backend/wms-be/src/shared/events/outbox.seam.ts:29-55` + `problem-details/problem.exception.ts` — `OutboxSink.append(tx, message)`; `ProblemException(code, status, title, detail)`; dotted event names (`order.created`, `order.cancelled`).
- `workspace/core/backend/wms-be/src/modules/tenancy/permissions.ts` — capability matrix; add `orders.manage` (Owner + Ops Manager). FE mirror `wms-fe/src/lib/users.ts:19-43` + `users.test.ts` pin bump ride the FE story.
- `workspace/core/backend/wms-be/test/reservations.spec.ts` — e2e bootstrap pattern (env defaults, poll-env deletion, `pg_advisory_xact_lock(742105)` role provisioning, `createApp()`, tenant/ops-session/warehouse/SKU fixtures, `expectProblem(status, code)`); race/burst arms assert against facades directly.
- `workspace/core/backend/wms-be/test/architecture.spec.ts` — the guard the outbound module must satisfy; the vacuous cross-module regex (:118-128, matches only `modules/inventory/` literal, never the `../inventory/` import form) — fix the pattern this story.

## Tasks & Acceptance

**Execution:**
- [x] `wms-be drizzle/0017_*.sql` — `orders` + `order_lines` (status CHECKs incl. line `open/backordered`, channel dedup partial unique index, `(tenant_id, warehouse_id, created_at, id)` keyset index) + RLS policies, hand-appended
- [x] `wms-be src/shared/db/schema.ts` — the two tables per conventions
- [x] `wms-be outbound module` — `createOrder` (manual + ingested paths, per-policy ATP split, per-line grants in-tx) + `cancelOrder` (release + audit) commands; `OutboundFacade` for reads
- [x] `wms-be src/api/outbound.controller.ts` — `POST .../orders`, `POST .../orders/{id}/cancel`, `GET .../orders/{id}`, `GET .../orders` (warehouse-scoped cursor list); OpenAPI annotations
- [x] `wms-be tenancy/permissions.ts` — `orders.manage` capability
- [x] `wms-be inventory/reservation.service.ts` — A2 ceiling re-validation under row lock + A8 503 rename to `reservation-store-unavailable` + F11 `ttlSeconds: 0` → 400
- [x] `wms-be test/architecture.spec.ts` — fix the vacuous facade-guard regex
- [x] `wms-be test/orders.spec.ts` — e2e per the matrix: policy arms, channel dedup arms, cancel/release, store-down, grant-loser race, adjust-vs-grant race, RLS, 0017 round-trip, accept→reservation timing sample
- [x] `wms-be bun run openapi:export` + `wms-fe bun run api:generate` — additive contract

**Acceptance Criteria:**
- Given ATP, when a manual order exceeds it, then the order is accepted with the over-ATP lines marked `backordered` and the shortfall visible in the response (FR-12, fixed backorder policy)
- Given the same channel order payload delivered twice, when the second delivery lands, then exactly one order exists and its snapshot is returned
- Given an accepted order, when cancellation is requested, then its reservations release atomically and the order reads `cancelled`
- Given two concurrent accepts racing the last unit, then exactly one reservation wins and the loser gets the deterministic policy outcome
- Given the reservation store is degraded, when an order is accepted, then it fails closed with `503 reservation-store-unavailable` and writes nothing

## Implementation Notes

## Spec Change Log

- **2026-09-10 (as-built deviation, resolved in planning):** the frozen "Always" bullet said grants reserve "inside the order-create transaction". As built, the per-line grants compose **outside** the order-create transaction: a grant is itself a multi-transaction atomic unit (probe tx → Valkey script → journal tx) and cannot nest. The invariant the bullet protects — "nothing accepted half-reserved" — is preserved by ordering instead: every grant lands BEFORE the create tx opens, and any failure in either phase (a 503 from the store, a rejected create tx) releases every granted hold (`releaseAll` with logged, never-masked failures left to the 7-day TTL + reaper). `order.command.ts` header documents this. No matrix row changes.

### Review Findings

_Four layers (blind hunter, edge cases, verification gaps, acceptance audit) — 2026-09-10. Every claim below was re-verified against the source before filing._

- [x] [Review][Decision] **RESOLVED (human, 2026-09-11): flip-first.** The conditional UPDATE + line reset + outbox + audit + key now commit together and the releases follow, so a crash leaves the order `cancelled` with live holds (ATP understated, reaper-recoverable) instead of freed stock under an `accepted` order. A hold committed inside the pre-check → release window can no longer be refused and is logged as an operational anomaly. Original finding: **Cancel is not atomic — releases commit in phase 2, the status flip in phase 3** — `order.command.ts:454-510` runs each `releaseReservation` in its own tx, then opens a *new* tx for `accepted → cancelled` + outbox + audit. A failure between them leaves stock released while the order still reads `accepted` with `reservationId`s pointing at released rows — the ATP-overstating direction. The frozen "Always" bullet says cancel "releases all open order reservations **atomically**"; the Spec Change Log's as-built deviation covers only the create path's grants, so nothing licenses splitting cancel. No compensation, no test. Options: (a) add an `InventoryFacade` in-tx multi-release so phases 2+3 become one tx (widens the facade surface, AD-6 seam), (b) accept + document the deviation and cover the window with the reaper, (c) reverse the order so the flip precedes the releases (order reads `cancelled` with holds briefly live — the fail-safe direction).
- [x] [Review][Decision] **RESOLVED (human, 2026-09-11): correct the comment, defer the race to epic 5.** `revalidatedCeiling` now states that it serializes grant-vs-adjustment only, and that QC holds and open quarantines contribute to the ceiling without being locked. Closing that race needs a lock-ordering audit against the QC/quarantine commands first. Original finding: **The A2 lock does not cover every ceiling contributor — grant-vs-quarantine/QC still races** — `revalidatedCeiling` (`reservation.service.ts:1060-1079`) locks only `stock_on_hand` rows, and its comment calls those "the ceiling's only contributors". They are not: `committedCeiling` = `committedOnHand - qcHeldUnits - buffer`, and `committedOnHand` subtracts open `inventory_quarantines` scopes (`reservation.service.ts:919-946`). A quarantine or QC hold opened between the probe and the journal tx lowers the ceiling without touching a locked row, so the grant can still journal above it — A2 closes grant-vs-adjustment but not grant-vs-quarantine. Options: (a) extend the `FOR UPDATE` to the quarantine + QC-hold rows (wider lock on a hot path, needs a lock-ordering review against the QC commands to avoid deadlock), (b) correct the comment and record the residual race as an open item for Epic 5.

- [x] [Review][Patch] Exhausted grant retries throw `409 unavailable` instead of backordering — the fixed-policy violation; `return null` below is unreachable dead code [`src/modules/outbound/order.command.ts:568-576`]
- [x] [Review][Patch] `counter === null` (evicted Valkey key) surfaces as a deterministic 409, silently backordering an in-stock line — A8's own distinction says a store fault is 503; `atp()` self-heals from the journal on the identical condition [`src/modules/inventory/reservation.service.ts:360`]
- [x] [Review][Patch] The cancel release loop swallows *any* 409 with `continue`, including the commit-caused conflict the guard 20 lines above exists to refuse [`src/modules/outbound/order.command.ts:479-491`]
- [x] [Review][Patch] A lost cancel flip still appends `order.cancelled` outbox + audit, unlike the already-cancelled branch that deliberately emits neither — duplicate events per cancellation [`src/modules/outbound/order.command.ts:505-533`]
- [x] [Review][Patch] Cancel never updates `order_lines` — `reserved_qty`, `status`, `reservation_id` keep claiming held stock after release; only the live `reservationState` tells the truth, so any roll-up (4.2's Outbound surface) double-counts [`src/modules/outbound/order.command.ts:493-533`]
- [x] [Review][Patch] Channel arms are silently dropped unless `source === 'ingested'`, so an adapter that sends the ref without the source gets duplicate orders on redelivery; the inverse case is already rejected [`src/api/outbound.controller.ts:87-88`]
- [x] [Review][Patch] The new outbound module-exclusivity guard scans zero files — the inventory twin got `expect(siblingModules.length).toBeGreaterThan(0)` in this same commit, the outbound copy omitted it; pin the regexes directly instead [`test/architecture.spec.ts:199-217`]
- [x] [Review][Patch] The A2 re-validation has no deterministic test — deleting the whole block still passed a full run 1 time in 5 [`test/orders.spec.ts:686`]
- [x] [Review][Patch] The multi-line grant-abort release is unobserved — the store-down test is single-line, so `releaseAll` runs over an empty array; deleting the release entirely left 19/19 green [`test/orders.spec.ts:626`]
- [x] [Review][Patch] The ingested channel-arm validation has no test — replacing the condition with `false` left 19/19 green, and the resulting nulls fall outside the dedup index [`test/orders.spec.ts`]
- [x] [Review][Patch] The list's warehouse-existence check has no test — commenting it out left 19/19 green; the regression ships a `200` empty page where the contract promises 404 [`src/modules/outbound/outbound.facade.ts:135`]
- [x] [Review][Patch] The RLS test's `order_lines` half is vacuous (no foreign `order_lines` row is inserted, so the count is 0 either way), and its 404 comment contradicts the 403 it asserts [`test/orders.spec.ts:842-869`]
- [x] [Review][Patch] The A2 block holds `FOR UPDATE` across a Valkey round-trip, but the client sets only `connectTimeout` — a hung-but-connected store blocks every stock mutation for the scope; no blocking commands exist, so `commandTimeout: 2_000` is safe [`src/shared/valkey/valkey.client.ts:43-47`]
- [x] [Review][Patch] `quantity` has `@IsInt() @Min(1)` and no upper bound — an int4 overflow raises 22003 after the grants land, returning 500 instead of 400 [`src/modules/outbound/outbound.dto.ts:38-43`]
- [x] [Review][Patch] The schema comment claims `integration_id` is "asserted in the command transaction"; there is no integrations table until Epic 7 and nothing asserts it — correct the comment [`src/shared/db/schema.ts`]
- [x] [Review][Patch] Dead exports (`ORDER_LINE_STATUSES`, `OrderLineStatus`, `ORDER_BACKORDER_POLICY`), status vocabulary duplicated in three places while `source` correctly derives its DTO enum, and every new file lands without a trailing newline — the `0017` SQL one matters because migrations are hand-appended here [`src/modules/outbound/order.command.ts`, `outbound.dto.ts`, `drizzle/0017_ambiguous_santa_claus.sql`]
- [ ] [Review][Patch] The A8 rename is a contract change to every reserving flow (QC, receiving, putaway), but `docs/repos/wms-be/README.md` still documents "409 unavailable / 503 fail-closed on Valkey down" — update in the meta docs PR [`docs/repos/wms-be/README.md`]

- [x] [Review][Defer] Keyset cursors truncate Postgres microseconds to milliseconds, so orders sharing a boundary millisecond can be skipped between pages [`src/modules/outbound/outbound.facade.ts:160-167`] — deferred: pre-existing pattern shared with `putaway.facade.ts` and the other list surfaces; orders is the first table facing bulk ingestion (Epic 7), so fix it there across all surfaces at once
- [x] [Review][Defer] A crash between the grant phase and the create tx, or a `releaseAll` that itself fails while the store is down, orphans holds that suppress ATP for the full 7-day TTL [`src/modules/outbound/order.command.ts:288-306`, `:583-601`] — deferred: fail-safe direction (ATP understated, never oversold) and documented in code, but no reaper covers it; a reconciler is new surface, not this story's patch
- [x] [Review][Defer] `ORDER_RESERVATION_TTL_SECONDS` exactly equals `COUNTER_TTL_SECONDS` (both 7 days), so a live order hold ages out in the same window as the counter that arbitrates it — deferred: the order TTL should be strictly below the counter TTL with the relationship asserted, not left as a coincidence of two independent constants; settle it with the reservation-expiry UX this story explicitly excludes
- [x] [Review][Defer] `orders_tenant_created_at_id_idx` serves no read this story ships (detail is by PK, list is warehouse-scoped) [`drizzle/0017_ambiguous_santa_claus.sql`] — deferred: 4.2 may add the tenant-wide order list; revisit then rather than amending a CI-verified migration now
- [x] [Review][Defer] Retry exhaustion is indistinguishable from genuine out-of-stock once the patch above lands — a contended SKU backorders with no log line and no response signal [`src/modules/outbound/order.command.ts:551-576`] — deferred: needs a response-shape decision (a per-line reason code) that belongs with 4.2's Outbound surface

**Rejected**

- `toLineDto` identity-spread and `OutboundFacade.snapshotOf` passthrough (low) — cosmetic indirection in a facade that 4.2 will extend anyway; deleting them now churns a file about to change.
- "Read route paths differ from the frozen spec" (`/outbound/orders` vs `/orders`) — false as a defect: the spec's Code Map fixes controllers under `src/api/*` following the `inbound.controller.ts` precedent, and `/outbound/` mirrors the shipped `/receiving/`, `/putaway/` surfaces. Recorded as a Spec Change Log entry instead of a patch.
- "Cancel adds a 409 the matrix does not contain" — false as a defect: the matrix's cancel row is not exhaustive of failure modes, and refusing to cancel an order whose stock a consuming flow already claimed is the only safe outcome. The patch above fixes the *hole* in that guard, not the guard.
- Missing 401 coverage on the outbound surface (low) — the auth guard is global and pinned by the existing suites; a per-surface 401 arm adds no signal.

## Review Triage Log

<!-- Append-only. Populated by step-04 on every review pass: one row per reviewer finding —
     verdict (high/medium/low/false/maybe-false) with its evidence: the refutation for
     false, what would settle it for maybe-false. Empty until the first review pass. -->

### Pass 1 (2026-09-10) — 16 blind + 3 verification-gap + 7 edge-case findings

| # | Layer | Finding | Verdict | Evidence |
|---|-------|---------|---------|----------|
| 1 | blind | `reserveLine`'s last attempt rethrows the race-loser 409 — creation aborts instead of backordering; trailing `return null` unreachable | medium | Verified: `raceLoser && attempt < MAX_GRANT_ATTEMPTS - 1` is false on attempt 4 → `throw err`; every loop arm returns/continues/throws so the trailing line is dead. Contradicts the fixed-backorder matrix row. PATCH |
| 2 | blind | Cancel flip-loser still appends `order.cancelled` outbox + audit | medium | Verified: `winner ?? fallback`, then unconditional outbox/audit appends — a concurrent cancel pair publishes the event twice for one flip. PATCH |
| 3 | blind | Cancel's committed-hold guard is check-then-act: a committing consumer between the read and the release is swallowed by the tolerant 409 catch | medium | Verified: `commit` and `release` both settle a non-held row via `terminalConflict` (409 `conflict`, `reservation.service.ts:433-489`) — indistinguishable at the cancel call site. Order can flip `cancelled` over a committed hold. PATCH (grouped with #19/#22) |
| 4 | blind | Cancel's releases are not compensated when the write tx fails | low | Real window but only under infra fault or a concurrent idempotency conflict; the conflict arm self-heals (the winner flips, the loser's retry replays), the fault arm heals on the same-key retry, and compensation would require re-granting holds (new machinery). REJECT (unlikely everyday; fix is not a direct correction) |
| 5 | blind | A2 re-validation classifies a null (unreportable) Valkey counter as the deterministic 409, contradicting the A8 503 split | medium | Verified: `counter === null \|\| counter > lockedCeiling → unavailable`. A store-state problem surfaces as "decision made: no stock" — the order module would backorder a line on a store outage instead of failing closed. PATCH |
| 6 | blind | A2 holds `FOR UPDATE` locks across the Valkey counter roundtrip | maybe-false | The mechanism is the frozen block's own mandate ("re-reads the ceiling contributors (FOR UPDATE on the stock rows)" inside the journal tx); any fix edits the frozen spec. The lock must span the journal decision anyway. REJECT (fix edits frozen spec — a human renegotiation, not a triage route) |
| 7 | blind | No DB CHECK backstop for the channel-arms-required-together rule | low | Real gap in 0017's stated backstop philosophy, but only a buggy direct-DB writer reaches it — every shipped path (command layer + partial unique index) enforces the contract; Epic 7 adapters go through the command layer. REJECT (unlikely met; fix adds a guard) |
| 8 | blind | A manual order carrying `integrationId`/`externalEventId` is silently accepted, fields dropped | medium | Verified: controller spreads channel arms only when `source: 'ingested'`; no cross-field validation — a believing client loses dedup protection on redelivery (duplicate orders → duplicate holds). PATCH (grouped with #24) |
| 9 | blind | TS arm registries vs 0017 CHECK arms can drift silently (no parity test) | low | Real maintenance hazard with 4.3/4.5/4.6 additive arms imminent; the migration's own comment warns the typo mode. Small parity test. PATCH |
| 10 | blind | Duplicate-SKU lines in one order: policy unspecified | low | No bad outcome today — each line legitimately gets its own hold; one-SKU-split-lines picking semantics are story 4.3's design space. REJECT |
| 11 | blind | Adjust-vs-accept race test nearly vacuous (accepts any outcome) | medium | Verified: `order === null \|\| order.status === 201` + trivially-true invariants; nothing pins the A2 arm. = VG gap #17. PATCH (deterministic arm) |
| 12 | blind | RLS tested read-side only; the `WITH CHECK` write arm is untested | low | Real: the whole create path relies on the write arm. One insert-probe arm through the scoped role. PATCH |
| 13 | blind | `OrderListQuery.cursor` has no length bound | low | Real: every other free-text input is capped; an arbitrary string reaches `decodeCursorSafe` (base64) before failing. PATCH |
| 14 | blind | `orders_tenant_created_at_id_idx` has no consumer | low | Real: no query reads orders tenant-wide without a warehouse scope; dead index on the hottest outbound write table. Direct deletion. PATCH |
| 15 | blind | `ORDER_BACKORDER_POLICY` exported const has no reader | low | Real: advertises configurability the code does not have (the doc comment carries the policy). Direct deletion. PATCH |
| 16 | blind | New files missing trailing newlines | low | Mechanical `\ No newline at end of file` churn. Direct fix. PATCH |
| 17 | vgap | (gap, pre-verified) A2 grant-vs-adjustment re-validation has no deterministic test — regression reintroduces oversell, caught only by timing luck | medium | Filed evidence: the repo's forcing technique exists (`reservations.spec.ts:813-857` RSV-CORRECT gate) and the two race tests pass under pre-A2 outcomes by design. PATCH |
| 18 | vgap | (gap, pre-verified) `listOrders`'s documented unknown-warehouse 404 is never asserted | low | Filed evidence: no request names a foreign/unknown warehouse on the list route; removing the assert yields 200-empty silently. One-line test. PATCH |
| 19 | vgap | Cancel tolerates a lost race against a *committing* consumer, then cancels anyway | medium | = #3 (carried). PATCH |
| 20 | edge | `reserveLine` final-attempt 409 loss + unreachable `return null` | medium | = #1 (carried). PATCH |
| 21 | edge | Frozen spec names `GET /tenants/{t}/orders/{orderId}`; as-built reads are `/outbound/orders/…` — deviation unlogged | low | Verified: every module namespaces routes under `:tenantId/<module>/…` (`receiving/qc-holds`, `inventory/adjustments`) — one unambiguous reading; the frozen URLs were illustrative. Recorded in the Spec Change Log; no code change, no loopback |
| 22 | edge | Release 409 catch cannot distinguish a committing consumer from a racing cancel/reaper | medium | = #3 (carried); the proposed guard (re-read the hold's state, continue only for released/expired) is the fix. PATCH |
| 23 | edge | Concurrent cancels: flip-loser still appends outbox + audit | medium | = #2 (carried). PATCH |
| 24 | edge | Channel fields on a manual source silently dropped | medium | = #8 (carried). PATCH |
| 25 | edge | `integrationId` not validated as a uuid at the command layer (DTO `@IsUUID` covers HTTP only) | low | Real for non-HTTP facade callers (the Epic 7 adapter path); reaches the uuid column as a raw 500. `UUID_RE` check, the `assertLines` skuId precedent. PATCH |
| 26 | edge | Line quantity unbounded above → int4 overflow 22003 raw 500 (after grants, released) | low | Real; the typed-error precedent is retro F15's int4 ceiling fix. `@Max` + an `assertLines` bound. PATCH |

**Grouping + routing:** no `intent_gap` / `bad_spec` entries → no loopback. Patch groups (by root cause): reserveLine final arm (#1/#20); cancel-vs-commit disambiguation (#3/#19/#22); flip-loser event suppression (#2/#23); A2 null-counter 503 (#5); A2 deterministic test (#11/#17); listOrders 404 test (#18); manual+channel-fields 400 (#8/#24); integrationId uuid check (#25); quantity upper bound (#26); cursor length bound (#13); drop speculative index (#14); drop unused policy const (#15); TS/CHECK parity test (#9); RLS WITH CHECK test (#12); trailing newlines (#16). Rejected: #4, #6, #7, #10. Deferred: none.

## Design Notes

**Why dedup is a unique index, not just an idempotency key.** Idempotency keys de-dupe transport retries; the (tenant, integration, external-event) partial unique index de-dupes *business* redelivery (the channel re-sending yesterday's payload), which is a different arrival with a different key. Same-payload replay returns the existing order; a divergent payload on the same ref is a data conflict, not a retry — hence 422, not silent reuse.

**Why the ceiling fix re-validates instead of trusting the counter.** The Valkey counter arbitrates grant-vs-grant only; stock can move underneath between the probe tx and the script. Taking `FOR UPDATE` on the ceiling-contributing stock rows inside the journal tx serializes grant-vs-adjustment through Postgres — the same row-lock discipline every other stock-mutation command uses — making the module-header "never oversells" claim true against both races.

## Verification

**Commands:**
- `cd workspace/core/backend/wms-be && bun run test` — all suites pass incl. new `test/orders.spec.ts`; the A8 rename updates any assertion on the old 503 code
- `cd workspace/core/backend/wms-be && bun run lint && bun run typecheck && bun run build && bun run db:migrate && bun run db:verify`
- `cd workspace/core/frontend/wms-fe && bun run test && bun run lint && bun run typecheck && bun run build` — untouched repo stays green after `api:generate`