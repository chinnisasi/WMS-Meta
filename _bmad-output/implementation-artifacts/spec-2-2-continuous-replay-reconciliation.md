---
title: 'Continuous replay-reconciliation'
type: 'feature'
created: '2026-09-09'
status: 'done'
route: 'dispatch'
baseline_commit: 'ee543d9fd304bc032f390041c1d9ecfb021b2356'
review_loop_iteration: 0
context: []
story_key: '2-2-continuous-replay-reconciliation'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** Story 2.1 shipped the ledger as the only stock truth with `replay` as a read-only equivalence check, but nothing runs it continuously — a corrupted or stale `stock_on_hand` projection would go undetected forever, and IN-08's operational contract (consistent-snapshot reads, bounded windows, checkpoint validation, never silently repair) is unimplemented. The outbox substrate (alert delivery) and the jobs shell (worker pattern) landed in `outbox-relay`.

**Approach:** A sheddable `ReconciliationWorker` in the jobs shell (mirror of `OutboxRelayWorker`: env-gated off in tests, in-process shed, `unref`'d interval) drives per-(tenant, warehouse) cycles: validate the checkpoint, read the ledger head as watermark, replay-fold via the existing `replayInTx`, handle divergence per the human's Open Question answer (rebuild/quarantine/alert ordering), advance the checkpoint only on a clean pass. The rebuild lives in `ledger.service.ts` (the architecture test pins stock_on_hand writes there — no test amendment). Divergence alerts ride the transactional outbox (`OUTBOX_SINK.append` in a small tenant tx), naming the divergent scope and event range — rebuild and alert always travel together. Also folds in the deferred `verify-before-anchor` item: `anchorChain` runs `verifyChainInTx` over its range and refuses to commit an anchor over a broken chain.

## Boundaries & Constraints

**Always:**
- Reconciliation reads a consistent window: only events with `seq <= watermark` (the checkpoint-consistent head read at cycle start) are flagged — a movement committing mid-cycle is the next cycle's problem, never a false positive.
- Rebuild is derived-state repair: recomputing `stock_on_hand` from `ledger_events` for the divergent scope, under the same per-(tenant,warehouse) advisory xact lock `appendMovement` uses (so no concurrent increment is clobbered) — and **every rebuild emits the divergence alert** (alert + rebuild together; silence is never an outcome).
- Bounded windows: cycles are checkpointed per (tenant, warehouse) in a new `reconciliation_checkpoints` table (last_seq, consecutive validation failures); a checkpoint that fails validation twice is discarded (full replay from seq 1) and checkpoint corruption is itself an alert.
- Quarantine is a first-class durable scope state (`inventory_quarantines`: tenant, warehouse, sku/bin scope, divergent seq range, reason, status), consumed later by 2.3's reservation path; surfaced in this story's reads/tests only as data.
- The worker yields: sheddable (in-process `running` flag + env gate), bounded work per cycle (one warehouse partition per tick, oldest-checkpoint-first).
- RLS + `tenantTimestamps` + uuidv7 on both new tables (0008, hand-appended policies, 0007 pattern).

**Never:**
- No auto-heal without detection: the worker never rewrites a projection it has not proven divergent by replay.
- No new HTTP surface (reconciliation is background work; `InventoryFacade` may expose the service method for tests, but no HTTP route).
- No ATP/reservation enforcement of quarantine (2.3's job); no QC-held/buffer hooks.
- No event-registry changes — the divergence alert is an outbox event, not a ledger movement.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Healthy cycle | Checkpoint last_seq < head, replay matches projections | Checkpoint advances to the window head; no alert; zero projection writes | N/A |
| Divergence detected | Stored projection ≠ replayed quantity for (sku, bin) within window | Per the Open Question: rebuild projection(s) from the ledger + one `reconciliation.divergence` outbox alert naming warehouse, sku/bin, projected vs replayed, event range | N/A |
| Repeated divergence | Divergence re-detected after a rebuild within the checkpoint window | Scope quarantined (row in `inventory_quarantines`); alert re-emitted naming the repeat | N/A |
| Concurrent movement | `stock.adjustment` commits mid-cycle | Its seq > watermark; not folded, not flagged; next cycle reconciles it | N/A |
| Checkpoint invalid ×2 | Stored checkpoint disagrees with ledger (e.g. last_seq beyond head) | Checkpoint discarded, full replay from seq 1, `reconciliation.checkpoint_invalid` alert | N/A |
| Chain break in window | `verifyChainInTx` fails during verify-before-anchor (or reconcile's pre-check) | Anchor refused (no digest committed); existing SEVERITY-1 `ledger.chain_broken` path unchanged | N/A |
| Multi-warehouse fairness | One warehouse's ledger large, another small | One partition per tick, oldest-checkpoint-first; no partition starves | N/A |

</frozen-after-approval>

## Open Questions

*(none — all resolved at CHECKPOINT 1, 2026-09-09)*

- Divergence sequence: **RESOLVED (a) — IN-08 tiering.** First divergence: rebuild + alert. Repeated divergence within the window: quarantine + re-alert. The quarantine flag gates nothing in this story (2.3 enforces it against reservations). Human approved "Approve and continue" with the recommendation on the table.

## Code Map

- `wms-be/src/modules/inventory/ledger.service.ts` — reuse: `replayInTx` (L624, read-only fold + comparison), `verifyChainInTx` (L723, exported), `ReplayDivergence` (L58), `addToOnHand` (L373, the single sanctioned stock write), advisory lock key `tenantId||':'||warehouseId` (L263/L491 pattern). New: `rebuildProjections(tenant, warehouse, scope?)` here.
- `wms-be/src/modules/inventory/ledger.service.ts` `anchorChain` L482 — insert `verifyChainInTx(tx, …)` over the anchor range before `digestOverRange`; on break, refuse to anchor (report + existing chain_broken append).
- `wms-be/src/modules/inventory/inventory.facade.ts` — pass-through for `reconcile` (L169+ pattern); no HTTP route.
- `wms-be/src/jobs/jobs.module.ts` — `OutboxRelayWorker` (L40) is the worker template: env gate, shed, `unref`, shutdown. New `ReconciliationWorker`, env `OUTBOX_RECONCILE_POLL_MS`, same conventions.
- `wms-be/src/shared/events/outbox.ts` — alert emission: `OUTBOX_SINK.append(tx, {messageId, tenantId, type, payload, occurredAt})` in a small tenant tx (chain_broken precedent L459-472); event types `reconciliation.divergence`, `reconciliation.checkpoint_invalid`.
- `wms-be/src/shared/db/schema.ts` + `drizzle/0008_*.sql` — new `reconciliation_checkpoints` (unique (tenant, warehouse), last_seq, invalid_attempts, timestamps) + `inventory_quarantines` (scope, reason, from/to seq, status, timestamps); RLS hand-appended (0007 pattern). Next migration is 0008.
- `test/ledger.spec.ts` — replay/verify/tamper patterns, `session_replication_role = replica` cleanup (the divergence probe tampers `stock_on_hand` the same way); `test/outbox.spec.ts` — `RecordingEventBus` + direct `drain()`; `test/architecture.spec.ts` L106 — single quantity-mutation path (rebuild must live in ledger.service.ts; no amendment needed).

## Tasks & Acceptance

**Execution:**
- [x] `drizzle/0008_*.sql` + schema.ts — `reconciliation_checkpoints` + `inventory_quarantines` (columns per Boundaries; fail-closed RLS hand-appended; CHECK on quarantine status).
- [x] `ledger.service.ts` — `rebuildProjections(tenant, warehouse, scope?)`: advisory xact lock, fold `ledger_events` from seq 1 for the scope, upsert/delete `stock_on_hand` rows to the replayed quantities (the single sanctioned path).
- [x] `reconcile.ts` (inventory module) — `reconcile(tenant, warehouse)`: watermark read, checkpoint validation (invalid ×2 → discard + `checkpoint_invalid` alert + full replay), `replayInTx` to the watermark, divergence handling per Open Question answer, checkpoint advance on clean, outbox alerts via `OUTBOX_SINK`.
- [x] `jobs.module.ts` — `ReconciliationWorker` (env gate `OUTBOX_RECONCILE_POLL_MS`, shed, unref, shutdown; one oldest-checkpoint-first partition per tick).
- [x] `ledger.service.ts` `anchorChain` — verify-before-anchor: `verifyChainInTx` over the range inside the anchor transaction; break → refuse + report, anchor not committed.
- [x] `test/reconciliation.spec.ts` — matrix coverage: healthy advance, tamper → detect/rebuild/alert (fake bus observes `reconciliation.divergence`), repeat → quarantine, checkpoint discard ×2, mid-cycle movement beyond watermark not flagged, anchor refusal over a tampered range, worker env-gate/shed; cleanups delete the two new tables.

**Acceptance Criteria:**
- Given a warehouse whose projections match the ledger, when a reconcile cycle runs, then the checkpoint advances to the window head and no alert or projection write occurs.
- Given a tampered `stock_on_hand` row, when the cycle runs, then the divergence is detected past the watermark, the projection is rebuilt to the replayed quantity, and one `reconciliation.divergence` alert naming the scope and event range is published through the bus (via the relay in tests).
- Given divergence persists after a rebuild within the window, when the next cycle runs, then the scope is quarantined and the repeat is alerted — and no code path silently repairs without an alert.
- Given a corrupt checkpoint twice in a row, when the cycle runs, then the checkpoint is discarded, full replay runs from seq 1, and a `reconciliation.checkpoint_invalid` alert is emitted.
- Given a tampered ledger range, when `anchorChain` targets that range, then no anchor row is committed and the chain-broken alert path fires.

## Design Notes

Reconcile cycle shape (one shape, no alternatives): per partition — validate the checkpoint (last_seq ≤ head, else invalid++), read watermark = ledger head at cycle start, replay-fold events from seq 1 (quantities are absolute, so the fold must be whole) but **compare** only the (sku, bin) scopes touched by events in `(last_seq, watermark]` — that bounded compare window is what the checkpoint bounds (a pre-existing divergence on an untouched scope is caught by a later full pass or a rebuild, not this scan). The compare read takes no lock (MVCC + watermark keeps it consistent); rebuild writes hold the warehouse advisory lock. Clean pass → checkpoint.last_seq = watermark, invalid_attempts = 0. Alert payloads: `{warehouseId, divergences: [{skuId, binId, projected, replayed, fromSeq, toSeq}], watermark}`. Verify-before-anchor: on break, `anchorChain` returns the ChainBreakReport unchanged (no anchor row) — the severity-1 alert already fires in the existing path.

## Verification

- In `wms-be` (env vars as in spec-2-1): `bun run db:migrate && bun run test` — all suites green incl. new `test/reconciliation.spec.ts`
- `bun run db:generate && git diff --exit-code drizzle/` — no drift; `bun run lint && bun run typecheck` — clean; `bun run openapi:export && git diff --exit-code openapi/` — no diff (no HTTP surface)
- Manual: set `OUTBOX_RECONCILE_POLL_MS=2000`, adjust stock, watch the log — checkpoint advances; hand-corrupt a `stock_on_hand` row and watch the cycle detect, rebuild, and log the divergence alert with the outbox row drained.

## Review Triage Log

Review round 1 (2026-09-09): 29 findings — blind-hunter 14, edge-case-hunter 10, verification-gap 4 (3 pre-verified), step-03 audit 1. Each finding verified at its cited location before its verdict. Groups: 9 patch groups (re-engaged `recon-impl`), 0 defer, 13 reject, no loopbacks (review_loop_iteration stays 0).

| # | Source | Location | Finding | Verdict | Evidence / routing |
|---|--------|----------|---------|---------|--------------------|
| 1 | blind-hunter | schema.ts (quarantine comment) | No path ever sets a quarantine to `resolved`; state machine half-built | low → reject | True observation, but the story's boundary is explicit: quarantine gates nothing here and is consumed by 2.3; resolution belongs to the later quarantine-lifecycle work. The status CHECK admitting `resolved` is exactly what lets that story add it without a migration. |
| 2 | blind-hunter + edge-case | reconcile.ts `pickPartition` / worker catch | Persistently failing partition is retried every tick and starves all others (nothing stamps `updated_at` on failure) | medium → patch | Confirmed: the worker catch only logs; a throwing cycle writes nothing, so the partition stays oldest-first forever. Smallest fix: best-effort `updated_at` stamp on cycle failure in `reconcileNext` (re-queues behind others, no schema change). |
| 3 | blind-hunter + edge-case | reconcile.ts `detect` | Two concurrent cycles on one warehouse both classify the same scope first-offense (duplicate alerts) | low → reject | Unreachable in the shipped program: the worker is single-timer with an in-process shed and nothing else calls `reconcile` — the overlap needs a multi-process deployment shape that does not exist today (the relay's session-lock shed is the precedent to mirror when it does). |
| 4 | blind-hunter | reconcile.ts repair/alert | Alert payload carries detection-snapshot numbers while the rebuild re-folds fresh — numbers can diverge from what was written | low → reject | True as coded, but the payload honestly describes the divergence AT the detection watermark (its documented semantics); `ReconcileReport.repaired` already carries the fresh numbers. Deriving post-repair numbers adds machinery for an operator-facing cosmetic delta. |
| 5 | blind-hunter | reconcile.ts repair | No escalation/dedup beyond one repeated no-op quarantine + fresh alert every cycle | low → reject | Per the approved Open Question answer, re-alert on repeat IS the design; alert noise under a persistent corruption source needs an escalation policy that is a feature decision (2.3+), not a correction. |
| 6 | blind-hunter + verification-gap | ledger.service.ts `rebuildProjections` (manual path) | Manual `rebuildProjections`/facade entry entirely untested (scope filter, clean-scope no-op, `manual-rebuild` alert) | medium → patch | Pre-verified by the verification-gap layer (zero test references); also `grep -rn rebuildProjections test/` confirms zero. Patch: one e2e case driving the facade path. |
| 7 | blind-hunter | ledger.service.ts `foldLedgerInTx` | Bounded scans still fold the whole ledger every cycle — O(all events) per tick | low → reject | The whole fold is the frozen approach ("quantities are absolute, so the fold must be whole"); its fix would edit the frozen spec design. Near-term harm negligible at realistic ledger volumes; scaling work belongs to a later story if volumes demand it. |
| 8 | blind-hunter | ledger.service.ts `reconcileScanInTx` | Whole-`stock_on_hand` read filtered in memory instead of SQL-scoped to the window | low → reject | Real shape, per-warehouse stock_on_hand is small at this stage; the in-memory filter inside the one MVCC snapshot is the simpler correct read; SQL-scoping adds no correctness and marginal scale. |
| 9 | blind-hunter + edge-case | reconcile.ts `parseLastDivergences` | Corrupted `last_divergences` jsonb: a null/non-object entry throws (wedges the partition); a malformed entry is silently dropped (repeat downgraded to first offense, no log) | medium → patch | Confirmed: `entry['skuId']` on null throws; malformed entries drop with no log while the adjacent `last_seq` corruption alerts. Patch: skip non-object entries + warn when anything is dropped. |
| 10 | blind-hunter | reconcile.ts skip path | A skipped-checkpoint cycle bumps `updated_at`, delaying the ×2 discard | low → reject | True but bounded: the delay is proportional to partition count and the skip-stamp is what keeps a failing partition from starving the others (the fairness scheme working as designed). |
| 11 | blind-hunter | tenant-scope.ts + tests | Repeatable-read isolation is plumbed but never asserted by any test | medium → patch | Confirmed: no test pins the isolation level; the spec's consistency claim rests on it. Patch: one small test asserting the in-tx isolation. |
| 12 | blind-hunter | reconciliation.spec fairness test | `reconcileNext` can pick foreign partitions and write real rows into other suites' fixtures | low → reject | The test already filters foreign reports and budgets ticks; foreign writes are confined to checkpoint rows plus divergence-driven rebuilds of data that is only inconsistent while another suite holds a deliberate tamper mid-assertion (a millisecond-window race; no contained fix short of per-suite databases). |
| 13 | blind-hunter | ledger.service.ts `anchorChain` | Union return is a breaking type change for callers outside the diff | false | All callers are in-repo (facade passthrough + the two adapted test files); typecheck is green and grep finds no other consumer. |
| 14 | blind-hunter | jobs.module.ts | `ReconciliationWorker`/`parseReconcilePollMs` duplicate the relay worker nearly verbatim; new/edited files end without a trailing newline | low → reject (duplication) / patch (newline) | Duplication mirrors the relay worker by design (the mirror is the spec's own word); a shared-worker-helper refactor is a cleanup story, not this story's correction. The trailing-newline half is real churn (untouched `app.module.ts` ends with a newline; the new/edited files do not) — trivial append, folded into the patch round. |
| 15 | edge-case | reconcile.ts `parseLastDivergences` | Null/non-object jsonb entry throws TypeError; partition wedged | medium → patch | Same finding as #9 (same root cause, same fix) — grouped there. |
| 16 | edge-case | reconcile.ts `pickPartition` | Discovery excludes invalid-checkpoint partitions (`last_seq > head` fails `head_seq > coalesce(last_seq,0)`) — the ×2 discard path is unreachable via `reconcileNext` | medium → patch | Confirmed: a checkpoint with `last_seq=100, head=1` is never selected, so the designed discard+alert path is only reachable by calling `reconcile` directly. Patch: include `last_seq > head_seq` partitions in the where clause. |
| 17 | edge-case | reconcile.ts `pickPartition` | Failing partition starves others (no failure backoff) | medium → patch | Same finding as #2 — grouped there. |
| 18 | edge-case | reconcile.ts cycle | Two app instances racing one partition duplicate alerts / interleave checkpoint writes | low → reject | Same finding as #3 — grouped/rejected there (unreachable in the single-process deployment the code ships in). |
| 19 | edge-case | reconcile.ts validation | Negative `last_seq` passes validation silently despite the 0008 comment declaring it corruption | false | Migration 0008 carries `reconciliation_checkpoints_last_seq_nonnegative CHECK (last_seq >= 0)` — a negative `last_seq` cannot be stored at all (raw inserts included), so the validation branch is dead by DB enforcement. |
| 20 | edge-case | jobs.module.ts parser | Whitespace-only `OUTBOX_RECONCILE_POLL_MS=' '` parses to 0 (silently OFF) | low → reject | Confirmed as coded, but `parseReconcilePollMs` is byte-for-byte parity with the shipped `parseOutboxPollMs` (relay, reviewed and merged) — same `Number(' ')` semantics; fixing one without the other is the already-tracked shared-parser consolidation, and a whitespace env value is not everyday use. |
| 21 | edge-case | test/ledger.spec.ts restore | Tamper-restore `update … where tenant_id = $1 and seq = 1` has no warehouse filter | low → patch | Confirmed: a second event-bearing warehouse under the same tenant would have its seq-1 delta corrupted. Latent today (one warehouse per test tenant) but the fix is a one-line `and warehouse_id = $2`. |
| 22 | edge-case | reconcile.ts discard branch | Discard-clean path deletes the checkpoint and reports `advanced: true` without re-earning it | medium → patch | Confirmed: the discard branch returns `clean: report.matches` with no checkpoint write, so a clean discard reports `advanced: true` while the checkpoint stays deleted (next cycle re-plays fully). Patch: advance the checkpoint in the discard branch when the full replay is clean. |
| 23 | edge-case | reconcile.ts detect | Spec matrix claims a reconcile chain pre-check; none exists — a tampered ledger event is folded into a rebuild silently | false | The matrix row's Expected Output is "Anchor refused (no digest committed)" — implemented and tested; "(or reconcile's pre-check)" named an alternative site, and the frozen intent commits only to verify-before-anchor. (Residual idea — chain-verifying the window before trusting a fold — belongs to a later ledger story, not a deviation here.) |
| 24 | edge-case | schema.ts checkpoint comment | Comment says "the next cycle replays from seq 1" — the discarding cycle itself replays immediately | low → patch | Confirmed comment inaccuracy; trivial reword, folded into the patch round. |
| 25 | verification-gap | ledger.service.ts `rebuildProjectionsInTx` delete branch | The event-less-scope branch (deletes a fabricated `stock_on_hand` row) has no test anywhere | medium → patch | Pre-verified: no test creates an event-less projection row; every rebuild assertion hard-codes `deleted: false`. Patch: e2e case seeding an event-less row and asserting removal + `deleted: true`. |
| 26 | verification-gap | jobs.module.ts `tick()` | Worker failure/retry path never exercised — the "retried on the next tick" contract is unverified | medium → patch | Pre-verified: all worker tests drive a stub that only ever resolves; the catch branch is dead in CI. Patch: rejecting-stub unit test asserting the log + the next tick still driving `reconcileNext`. |
| 27 | verification-gap | reconciliation.spec.ts env clears | Only the new suite clears `OUTBOX_RECONCILE_POLL_MS`; sibling full-app suites would boot the reconciliation worker if a host exports the key | medium → patch | Verified: `test/outbox.spec.ts` clears only the relay key and the other AppModule suites clear neither; the hazard comment exists only in the new suite. Patch: add the matching `delete` next to each suite's existing relay delete. |
| 28 | verification-gap | ledger.service.ts `rebuildProjections` | Manual rebuild path entirely untested | medium → patch | Same finding as #6 — grouped there. |
| 29 | step-03 audit | test/reconciliation.spec.ts drain assertions | The two bus-observation/pending-count assertions are one-shot: `drain()` sheds (returns empty) when a concurrent suite's relay holds the `wms:outbox-relay` session lock, so rows stay pending or the publish is missed — 2 of 3 full-suite runs failed with exactly these two tests | medium → patch | Confirmed live: full-suite runs failed on `tampered projection` (empty `mine`) and `repeated divergence` (first alert still pending); isolation run 18/18; mechanism matches the relay's shed-on-lock semantics. Patch: bounded retry in `drainMyTenant` (+ a single re-trigger fallback if another suite's relay consumed the row). |

## Review Routing Summary

- **patch (9 groups, re-engaged `recon-impl`)**: #2/#17 failure backoff stamp; #6/#28 manual-rebuild test; #9/#15 `parseLastDivergences` hardening; #11 isolation test; #16 discovery includes invalid checkpoints; #21 restore warehouse filter; #22 discard-clean checkpoint re-earn; #24 comment reword (+#1 adjacent); #25 delete-branch test; #26 worker-catch test; #27 sibling env clears; #29 drain retry helper; #14 trailing newline.
- **Patch-round follow-through (verification failure, fixed directly)**: the two NEW patch tests asserted relative outbox row counts (`before + 1`) on the shared table — a concurrent suite's relay deleted pending rows between the count and the assert (2 failures in the post-patch full run, same steal mechanism as #29). Root-cause fix applied directly: `jest.config.js` now sets `maxWorkers: 1` — the e2e suites share one Postgres database, so suites running in parallel workers race each other's fixtures (this also closes the historical `catalog.spec` transient). Full suite re-run serial: 141/141 green twice.
- **defer**: none.
- **reject (13)**: #1, #3, #4, #5, #7, #8, #10, #12, #13, #18, #19, #20, #23 — refutations recorded per row above.
- **No intent_gap / bad_spec** — no loopback; `review_loop_iteration` remains 0.