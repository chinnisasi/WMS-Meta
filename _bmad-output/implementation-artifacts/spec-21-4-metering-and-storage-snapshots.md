---
title: 'Metering and storage snapshots — per-client billable usage from the ledger, priced by the rate card in force'
type: 'feature'
created: '2026-10-07'
status: 'done'
route: 'dispatch'
baseline_commit: '2b5a459e22fe3db1fb480412e93e67bff5e8b436'
review_loop_iteration: 0
context:
  - '_bmad-output/implementation-artifacts/epic-21-context.md'
  - '_bmad-output/specs/spec-3pl/SPEC.md'
  - '_bmad-output/specs/spec-3pl/schema.md'
  - '_bmad-output/specs/spec-3pl/billing-model.md'
  - '_bmad-output/specs/spec-3pl/architecture.md'
  - '_bmad-output/implementation-artifacts/spec-21-3-rate-cards.md'
  - 'docs/design/SYSTEM-DESIGN.md'
  - 'docs/design/IMPLEMENTATION-GUIDE.md'
  - 'docs/design/modules/billing.md'
  - 'docs/design/modules/inventory.md'
  - 'docs/design/modules/inbound.md'
  - 'docs/design/modules/outbound.md'
  - 'docs/design/frontend/SYSTEM-DESIGN.md'
  - 'docs/design/frontend/IMPLEMENTATION-GUIDE.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** Rate cards (21-3) say what a client pays per unit, but nothing yet measures how many units each client used. A 3PL bills for:
- how much stock a client stored, each day;
- how many receipt lines, picks and orders were handled for it.

These are FR-78, CAP-5 and CAP-6. Client invoices (21-5) need that usage, derived from the ledger and reproducible.

**Approach:** Billing gains **metering**:
- **Storage snapshots:** a daily job writes each client brand's on-hand base milli-units per warehouse and base unit, at the end of each IST day. This is a projection folded from the ledger, under a guarantee that every event stamped before the day ended has committed.
- **A metering read:** for a client and a period, it returns the billable quantity of each charge, split by the rate card in force (21-3 segments) and priced. 21-5 consumes this read.
- **A web usage preview:** shows the same figures as an estimate.

**Decisions (human, 2026-10-07):**
1. **Storage is counted separately per base unit.** Snapshots and storage lines are per (client, warehouse, day, **base UoM**). Each is priced at the card's storage rate.
2. **A day's storage is the stock in bins at the end of the IST day.** Stock **leaves storage when it is picked**: picking takes it out of its bin, while packing and dispatch move nothing in the ledger. So stock received on the 10th and picked on the 18th is stored on the 10th through the 17th.
3. **Web usage preview.** Pick a client and a period to see each charge's quantity per rate-card segment, with its rate and amount. Amounts are GST-exclusive and marked "estimate until invoiced".
4. **Only client brands are snapshotted, never `self`.** Tenants with no client brand run no snapshot work. For `self`, the preview shows handling counts with storage "not measured".

## Boundaries & Constraints

**Always:**
- **On-hand per (client, warehouse) at instant `T`** is the ledger fold over events with `recorded_at < T`. An event counts `+|δ|` when it has only a destination bin, `−|δ|` when it has only a source bin, and 0 otherwise.
  - This is the replay rule, and it holds for every registered event type: relocations, QC holds and same-warehouse transfers net to zero; picks draw; pack, dispatch and excursion events are 0.
  - On-hand is grouped by `ledger_events.client_id` and by the SKU's (immutable) `uom`.
- **Commit guarantee** (*renegotiated by the human, 2026-10-07, after implementation proved the snapshot-xmax proof unsound and the xid proof leaky*). Day `D` (`T` = the IST midnight ending `D`) is written only when both hold:
  - (a) `now ≥ T + 15 min` (margin for clock skew); and
  - (b) **no session in `pg_stat_activity` has an open transaction with `xact_start < T`**.

  Every ledger, GRN and pick stamp is taken inside a transaction that began no later than the stamp, so this also proves the handling counts complete up to `T`.

  If the job's database role cannot see the app's other sessions, it **refuses to write and logs an error**; it never guesses. A deploy must keep all app connections on one role or grant `pg_read_all_stats`.

  Snapshots are written once and never rewritten. A drift check (a window re-fold plus a genesis-sum check of the running total) runs once per IST day per scope and logs any mismatch.
- **Day pricing.** Day `D`'s storage is priced by the card in force at the **start** of `D` (`istMidnightOf(D)`).
- **Storage completeness.** A period's storage covers only days up to `storageCompleteThrough`, which is the minimum watermark across the client's scopes. A scope with events but no progress counts as "the day before its first event". `self` gives `null` ("not measured").
- **Counting units**, each with its stated instant:
  - **Receipt lines:** every GRN line of the client's SKUs, including lines later rejected as over-receipt, because unloading happened. Counted by the GRN's `recorded_at`.
  - **Picks:** `picks` rows (one per picklist line), counted by `created_at`.
  - **Orders:** distinct `orderId` of `dispatch.dispatched` events, counted by `recorded_at` and by the event's `client_id`. Orders never mix clients (21-2b).
  - Transfers create no picks and are not billed handling.
- **Pricing.**
  - A line is one (segment, charge, uom) summed across warehouses.
  - Its amount is computed in **BigInt and rounded once, half-up**. Storage is `Σ(daily milli) × rate ÷ 1,000,000`; the others are `count × rate`.
  - A charge with no card line, or a stretch with no card, has a quantity but a null rate and amount.
  - Quantities larger than 2⁵³ travel as decimal strings.
- **Data access through facades only** (AD-6). Billing reads:
  - inventory for the fold, the scopes and the dispatched-order counts;
  - inbound for receipt lines;
  - outbound for picks.

  Billing writes only its own tables.
- **Reads are member-open,** as rate cards are. The 21-7 portal must not reuse this route.

**Never:**
- invoices, GST, issuing, or freezing a period (21-5 must meter only after the period end plus the commit guarantee, and store its own output);
- pallet or bin storage, minimums or proration;
- per-warehouse rates;
- portal visibility;
- mutating the ledger;
- intraday storage;
- a dispute drill-down to individual events (21-5, PENDING);
- billing transfer handling.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected | Error |
|---|---|---|---|
| Daily snapshot | `ACME` holds 120 kg and 300 each in WH1 at end of `D` | Rows `(ACME, WH1, D, kg, 120000)` and `(…, each, 300000)` | — |
| Received 10th, picked 18th, dispatched 20th | — | Stored days 10th–17th | — |
| Relocation, QC hold or bin merge | — | On-hand unchanged | — |
| Cross-warehouse transfer across midnight | Outbound leg on `D`, inbound leg on `D+1` (one stamp per transaction) | Source holds it at end of `D`; destination from `D+1` | — |
| A transaction open across midnight | Stamped before `T`, commits after `T` | Day `D` waits until it has committed, then includes it | — |
| Grace | Job at 00:05 IST | `D` not written | — |
| Re-run, crash or two instances | — | Same rows; the watermark never moves back | — |
| Rebuild (dry run) | Re-fold from genesis | Same `(scope, day, uom, on_hand_milli)` set; drift reported if any | — |
| Zero stock | — | No row; the watermark advances | — |
| `self` client | — | No snapshots; preview storage "not measured" | — |
| Card boundary | Card A to 10-15, card B from 10-15 | Storage day 10-14 → A, 10-15 → B; counts split at the same IST midnight | — |
| No card for a stretch | — | Quantity shown; rate and amount `null` | — |
| Rounding | 1,234,567 milli-unit-days × 330 ÷ 1,000,000 | 407.407… → 407 | — |
| Period past the storage watermark | `to` = today | Storage through `storageCompleteThrough`; counts to now, labelled "in progress" | — |
| Bad request | `from > to`; more than 366 days; malformed date or client uuid; unknown client | — | 400; 400; 400; 404 |

</frozen-after-approval>

## Code Map

- **The fold:** `ledger.service.ts:566-604` (append) and `:1200-1236` (replay). Arms by type, from `ledger-registry.ts`:
  - `stock.adjusted` has one arm, by the delta's sign (`inventory.command.ts:1176-1177`); counts and variance resolutions use it;
  - `grn.received` writes to the Receiving bin;
  - relocations have both arms;
  - `pick.picked` is a draw (:373);
  - `pack.packed` (:397), `dispatch.dispatched` (:422) and `excursion.recorded` have no arms;
  - a cross-warehouse inbound transfer is two events (:476-499).

  `recorded_at` is the app clock, stamped before the per-warehouse advisory lock (`ledger.service.ts:143`). `ledger_events.client_id` is stamped from the SKU without a row lock (`:493-504`); 21-2b's correction race is already in PENDING.
- **Transfer stamps:** `transfer.command.ts:1445,1481` call `nowIso()` separately for the two cross-warehouse legs. Stamp once per transaction.
- **Indexes:** only `(tenant, warehouse, type, recorded_at)` exists, and there are no `client_id` indexes.
- **Counts:**
  - receipt lines: `goods_receipt_lines` (`schema.ts:1680`) joined to `goods_receipt_notes.recorded_at` (`:1645`) and to `skus` for the client;
  - picks: `picks` (`schema.ts:2294`), with `created_at` as the transaction-start time, indexed `(tenant, warehouse, created_at, id)`; no picks rows are written for zero-unit shorts or for transfers;
  - dispatched orders: the `dispatch.dispatched` events (template `reporting/kpis.ts:615-635`). This count lives on `InventoryFacade`, because outbound reads no ledger.
- **Billing:**
  - `rateCardSegmentsInTx` (`billing.facade.ts:222-260`) returns clipped `[from, to)` instants, and throws a plain `Error` on `from ≥ to`, so callers must guard first;
  - `BASIS_COUNTING_UNIT` (`rate-cards.ts:34-64`);
  - `test/architecture.spec.ts:1513-1595` (`BILLING_TABLES`);
  - `divideRoundHalfUp` is private in `invoicing/arith.ts:229` and moves to `shared/primitives/money.ts`.
- **Jobs:** `src/jobs/jobs.module.ts`. Follow `ReplenishmentSchedulerWorker` (:466-651): env-gated, a public `tick()`, single-flight, and a `rotatingWindow` (:575-585) so failing scopes can't starve the rest. The cross-instance precedent is the advisory lock in `shared/events/outbox.ts:112-128`.
- **Clients:** `ClientsFacade` (list; non-`self`).
- **Time:** `shared/primitives/time.ts` (`istDateOf`, `istMidnightOf`, `addIsoDays`, `isIsoDate`, `assertUtcIso`).
- **Next migration:** **0061**.
- **Web:**
  - `components/settings/rate-cards-card.tsx`: the client picker at :96-142, the per-client subtree `ClientRateCards` at :151, and `notifyRateCardsChanged`;
  - the period precedent `lib/hsn-summary.ts:164-245`;
  - `pricedClients` excludes `self` (`lib/rate-cards.ts:74`).

## Tasks & Acceptance

**Execution:**
- [x] `wms-be/drizzle/0061_storage_snapshots.sql` (+ journal, snapshot, schema.ts) -- guarded; RLS with a tenant policy plus the AD-24 read-only client clause; no FKs.
  - **`storage_snapshots`:** `id`, `tenant_id`, `client_id`, `warehouse_id`, `snapshot_date date`, `uom`, `on_hand_milli bigint > 0`, `created_at`; `UNIQUE (tenant_id, client_id, warehouse_id, snapshot_date, uom)`.
  - **`storage_snapshot_progress`:** `tenant_id`, `client_id`, `warehouse_id`, `last_day date`, `running jsonb` (uom → milli), `pending_xmax text NULL`, `pending_day date NULL`, `updated_at`; `PK (tenant_id, client_id, warehouse_id)`.
  - **Index** `ledger_events (tenant_id, client_id, warehouse_id, recorded_at)`, a plain build.
- [x] `wms-be/src/shared/primitives/money.ts` -- `divideRoundHalfUp` (BigInt), re-exported by invoicing unchanged.
- [x] `wms-be` inventory -- stamp one `recordedAt` per cross-warehouse transfer transaction. Add `InventoryFacade` reads:
  - `clientOnHandFoldByDayInTx(tx, scope, fromInstant, toInstant)`: one grouped query bucketed by IST date and `uom`, applying the fold rule;
  - `clientWarehousesWithEventsInTx(tx, tenant, clientIds)`: an EXISTS probe on the new index;
  - `firstEventInstantInTx(tx, scope)`;
  - `countDispatchedOrdersInTx(tx, scope, from, to)`.
- [x] `wms-be` inbound/outbound -- `InboundFacade.countReceiptLinesInTx` and `OutboundFacade.countPicksInTx`. Each `(tx, scope, from, to)` read is backed by one shared predicate function that 21-5's drill-down will reuse.
- [x] `wms-be/src/modules/billing/storage-snapshot.ts` -- `snapshotScopeInTx(tx, tenant, client, warehouse, now)`:
  1. Take a per-scope `pg_advisory_xact_lock`.
  2. Read the progress row.
  3. Apply the commit guarantee: record `pending_xmax` and `pending_day` at the first tick at or after `T`, and write only when the current xmin is ≥ the recorded xmax.
  4. Fold from the watermark day by day, up to **31 days per call**, carrying `running` forward.
  5. Insert the rows where the value is > 0, with `ON CONFLICT DO NOTHING`.
  6. Advance the watermark with `GREATEST`.
  7. Run the drift check over the last 7 days, logging any drift as an error.

  Also add `verifySnapshotsInTx` (a dry-run re-fold and diff) and `rebuildScopeInTx` (for tests and the script).
- [x] `wms-be/src/modules/billing/metering.ts` -- `meterPeriodInTx(tx, tenant, client, fromDate, toDate)` (IST dates, inclusive). Guard `from ≤ to` and at most 366 days before calling segments. Return `{segments: [{rateCardId | null, fromDate, toDate, lines: [{chargeCode, basis, uom | null, quantity: string, ratePaise | null, amountPaise | null}]}], storageCompleteThrough: string | null, totals: {billedPaise, unbilledLines}}`. No-card stretches appear as `rateCardId: null` segments.
- [x] `wms-be/src/jobs/jobs.module.ts` -- **`StorageSnapshotWorker`**, enabled by `STORAGE_SNAPSHOT_POLL_MS` (unset or 0 means off; add it to `.env.example`). Each tick:
  - discovers tenants cross-tenant;
  - per tenant, lists non-`self` clients × warehouses with events, through the facades;
  - uses a rotating window over scopes, with a bounded number per tick and a per-scope try/catch;
  - runs single-flight.
- [x] `wms-be/scripts/rebuild-storage-snapshots.ts` -- takes tenant, client and warehouse arguments. **Dry-run (verify) by default**; `--write` rebuilds under the scope lock.
- [x] `wms-be/src/api/billing-usage.controller.ts` + DTO -- `GET /tenants/{t}/clients/{c}/usage?from=&to=`, member-open, with the matrix error arms. Re-export `openapi.json`.
- [x] `wms-be` architecture and isolation -- add the new tables to `BILLING_TABLES`. Add a guard that billing imports no `ledgerEvents`, `picks` or `goodsReceipt*`. Add both tables to the client-isolation probe (the policy count moves).
- [x] `wms-be/test/metering.spec.ts` -- cover:
  - every matrix row;
  - every event type's fold arm;
  - the commit guarantee, via a held-open transaction stamped before `T`;
  - the drift check;
  - the rebuild/verify set equality;
  - day pricing at the card boundary;
  - BigInt rounding;
  - worker `tick()` idempotency, a two-instance race (GREATEST), and the rotating window;
  - `self` skipped;
  - the 0061 migration.
- [x] `wms-fe` -- a **Usage** section inside the per-client subtree of the Rate cards card:
  - **Period picker:** months from the client's creation to the current month (labelled "in progress"), defaulting to last month, plus a custom range of at most 366 days.
  - **Segment table:** charge, base unit, quantity (storage shown as unit-days), rate, and amount or "Not billed", with segment totals and an overall billed total.
  - **Notices:** "Estimate until invoiced · GST-exclusive"; "Storage through <date>"; and "Storage not measured yet" when that date is `null`.
  - **Data:** `useClientUsage` refreshes on `notifyRateCardsChanged`. Add the mappers and tests. `self` stays API-only.
- [x] Meta docs:
  - `billing.md`: metering, snapshots, the fold rule, the commit guarantee, drift, the runbook (enabling the worker, backfill pace, the rebuild script) and the facade reads;
  - `inventory.md`, `inbound.md` and `outbound.md`: the new reads and the transfer stamp;
  - amend `_bmad-output/specs/spec-3pl/schema.md`: snapshot columns and key per uom; `uom` on `client_invoice_lines`;
  - amend `billing-model.md`: the metered-from mapping and pick-ends-storage;
  - `API-SURFACE.md` and both contracts;
  - `PENDING.md`: close :99, :106 and :108 plus `clients.md:62`; add the 21-5 drill-down; add "transfer handling not billed"; add "21-5 must meter a period only after its end plus the commit guarantee".

**Acceptance Criteria:**
- Given `ACME` stock received on the 10th, picked on the 18th and dispatched on the 20th, under a card in force, when the month's snapshots are written and `meterPeriodInTx` runs, then:
  - storage counts the 10th–17th per base unit;
  - the receipt, pick and order quantities match the activity;
  - amounts are BigInt, rounded half-up once per line;
  - a verify re-fold reports no drift and a rebuild yields the same set.
- Given the full BE and FE suites, when run, then they pass.

## Implementation Notes

- Baselines: wms-be `2b5a459e22fe3db1fb480412e93e67bff5e8b436` (frontmatter `baseline_commit`); wms-fe `91a3769537d47c6b641f8e63dc3c4f2dfc53e2d1`. Work happens on `feat/21-4-metering-and-storage-snapshots` in both repos. Leave changes uncommitted; do not commit, push, or open PRs. In wms-be run jest via `bun run test -- <file>` (bare `bun test` hangs) and never two jest invocations concurrently. Meta doc edits go in /Users/sasidhar/Documents/WMS-Meta (docs/ and _bmad-output/specs/spec-3pl/; you may edit existing files there). Do not touch anything under /tmp outside your own scratch files.

## Spec Change Log

- **2026-10-07 (human, code review):** the commit guarantee changed from a snapshot-xmax proof to a `pg_stat_activity` check that no transaction which started before `T` is still open. The xmax proof failed a held-open test. The xid proof the agent substituted left a gap (a stamp taken before the transaction had an xid) and did not cover the counts. The new check covers storage and counts with no gap, at the cost of needing session visibility (it refuses when it cannot see other sessions). KEEP: the 15-minute skew margin, write-once rows, and the drift check.

- **2026-10-07, implementation — the commit proof's xmax.** The design said "record `pg_current_snapshot()` xmax … write when the current xmin ≥ it". Verified against Postgres 18: the snapshot's xmax is `latestCompletedXid + 1`, and a transaction still running with a newer xid is at or above it and unlisted — the held-open test passed straight through it. Implemented instead: the recorder's **own** `pg_current_xact_id() + 1` (the first unassigned xid) as `pending_xmax`, satisfied by a LATER tick's xmin (Boundaries (b)'s intent, unchanged: "no transaction that started before `T` is still open"). Consequence: a proof never completes in the tick that records it, so a quiet scope writes on its second tick. Residual (a transaction that had stamped but taken no xid when the proof was recorded) recorded in PENDING; the pattern in IMPLEMENTATION-GUIDE §7d. **Superseded by the human renegotiation above** — implemented as the `pg_stat_activity` check; the xid proof and its `pending_xmax`/`pending_day` columns are gone.

## Review Triage Log

*Design review, 2026-10-07: two code-verified reviewers (data correctness; 3PL fit, API, FE). 29 findings merged into 21; two went to the human (decisions 2 and 4), the rest are folded in.*

| # | Severity | Finding | Disposition |
|---|---|---|---|
| 1 | high | Storage stops at pick, not dispatch (the ledger fold) | Decision 2 reworded; AC and matrix updated |
| 2 | high | The 15-minute grace is not a guarantee, since transactions are unbounded | Snapshot-xmin commit guarantee, with 15 min as skew margin |
| 3 | high | "Never rewritten" vs "rebuild reproduces": an undefined failure path | Guarantee plus a drift check (logged) plus a verify/rebuild script; frozen rows |
| 4 | high | Which card prices a storage day is undefined | The card in force at the start of `D`; a matrix row |
| 5 | medium-high | The DTO lacks the rate, card id, no-card shape and quantity units; the docs were not amended | The DTO specified; schema.md and billing-model.md amended |
| 6 | medium-high | The job cost is unbounded (genesis fold per call, per-day queries, full-table discovery) | Running totals in progress; one grouped query; 31 days per call; facade EXISTS discovery |
| 7 | medium | Whether `self` is metered was undecided | Decision 4 |
| 8 | medium | The rotating window and two-instance safety were missing | `rotatingWindow`; scope advisory lock; `GREATEST` watermark |
| 9 | medium | The dispatched-order count can't live on outbound (no ledger access) | Moved to `InventoryFacade` |
| 10 | medium | `storageCompleteThrough` undefined; zero days are indistinguishable | Minimum watermark; first-event rule; `null` for self |
| 11 | medium | The dispute drill-down is not designed | Shared predicate functions now; drill-down deferred to 21-5 (PENDING) |
| 12 | medium | API date semantics, the 366 bound, `from ≥ to` and the uuid arm | Specified; guarded before segments |
| 13 | medium | Operational picture with the worker off; the backfill; the runbook | A "not measured yet" state; 31-day chunks; a runbook in billing.md |
| 14 | low-medium | Cross-warehouse transfer legs are stamped separately across midnight | One stamp per transaction |
| 15 | low-medium | The grouping column (event vs SKU client) was ambiguous | `ledger_events.client_id`; the SKU only for uom |
| 16 | low-medium | Byte-identical rows are impossible (uuid, `created_at`) | Set equality on key plus value |
| 17 | low-medium | FE: the month range, in-progress label, self, refresh on card change, rate column | Specified |
| 18 | low | Counting instants and rules (GRN `recorded_at`, rejected over-receipts, transfers) | Stated |
| 19 | low | Milli-unit-days can pass 2⁵³; the line grain | Decimal strings; one line per (segment, charge, uom) |
| 20 | low | Member-open commercial reads were implicit | Stated; the portal must not reuse it |
| 21 | low | Doc closures were incomplete | Added |

*Code review, 2026-10-07: three layers (blind, edge-case, verification-gap); 31 findings merged into 20, each verified against the code.*

| # | Verdict | Finding | Evidence | Route |
|---|---|---|---|---|
| C1 | high | The commit guarantee leaks: the xid proof misses a stamp taken before the xid exists, the drift check can't see a wrong baseline outside its window, and the counts (GRN, picks) are not covered at all | `storage-snapshot.ts` proof; drift-check baseline | human decision: the `pg_stat_activity` `xact_start < T` check (spec change log); a genesis-sum drift check; counts covered |
| C2 | high | An order dispatched across a card boundary or period end is counted in both, double-billing outbound handling | `countDispatchedOrdersInTx` uses distinct per window | patch: attribute each order to its **first** dispatch event's `recorded_at`, in both the count and the predicate |
| C3 | high | A late event stamped before a scope's first visible event loses its days permanently (the watermark is persisted before any proof) | `snapshotScopeInTx` "born" watermark | patch: the first watermark is persisted only when the first day is written under the guarantee; the start is computed at write time |
| C4 | high | Pick and order counts are never tested against other clients' activity (dropping the client filter passes every test) | `picksPredicate`, `dispatchedOrderEventsPredicate` | patch: tests with other clients' picks and dispatches, and with a pack-only `orderId` |
| C5 | medium | Storage days past the watermark are reported as billed ₹0 | `metering.ts:1081-1090` | patch: each segment and line carries `storageMeasuredThrough`; an unmeasured stretch has `amountPaise` null and is excluded from the billed total |
| C6 | medium | The rotating window advances one scope per tick and starves the tail | `jobs.module.ts:674-684` | patch: advance by the number processed |
| C7 | medium | The route doesn't refuse client-scoped (portal) sessions, despite "the portal must not reuse it" | controller | patch: refuse a session with `users.client_id`, plus a test |
| C8 | medium | `storageCompleteThrough` DTO text says null when no snapshot has run; the code returns first-day minus one | DTO vs `storageCompleteThroughInTx` | patch: the DTO matches the code; the self case is null |
| C9 | medium | `verifySnapshotsInTx` runs without the scope lock (false drift) | `storage-snapshot.ts:1437-1448` | patch: take the scope lock |
| C10 | medium | The rebuild's reset of `running` is untested; `--write` prints the pre-rebuild drift as the result | rebuild and script | patch: test `running` after the rebuild; print before and after clearly |
| C11 | medium | Index claims are wrong: the order count and the per-client snapshot sums aren't served | 0061 | patch: add `ledger_events (tenant_id, client_id, type, recorded_at)` and `storage_snapshots (tenant_id, client_id, snapshot_date)`; fix the comments |
| C12 | medium | The drift check runs every tick for unchanged scopes | worker | patch: once per IST day per scope, or when the watermark advances |
| C13 | low | Stale comments still describe the rejected snapshot-xmax proof | schema.ts, 0061 header, `storage-snapshot.ts` | patch |
| C14 | low | A uuid array built by string concatenation | `clientWarehousesWithEventsInTx` | patch: bind an array parameter |
| C15 | low | An amount past 2⁵³ throws an untyped Error (a 500) | `metering.ts:952-957` | patch: a typed refusal |
| C16 | low | The genesis-baseline branch is untested | `fromGenesis` | patch: a test (a late earlier event) |
| C17 | low | The one-stamp transfer test can pass when both stamps land in the same millisecond | `transfer.spec.ts` | rejected: several round-trips separate the legs; documented |

## Design Notes

- **Why the fold rule.** Relocations carry a positive delta with both bin arms set, so a plain Σδ would double-count every putaway and hold. The ledger's own replay defines on-hand, and metering uses exactly that.
- **Why the snapshot-xmin guarantee.** `recorded_at` is stamped before the commit lock, and nothing bounds how long a transaction can take, so a fixed wait cannot prove completeness. Comparing a snapshot recorded after `T` with a later xmin proves that every transaction that could have stamped before `T` has finished.
- **Why stop at pick.** The ledger takes picked stock out of storage. Counting it until dispatch would need a second fold over picks and dispatches and would be harder to defend on a disputed invoice.

## Verification

**Commands:**
- `bun run test` (wms-be) -- green, plus `typecheck`, `lint`, `build`; `db:generate` reports "No schema changes".
- `bun run lint && bun run test && bun run typecheck && bun run build && bun run check:capability-mirror` (wms-fe) -- green.
