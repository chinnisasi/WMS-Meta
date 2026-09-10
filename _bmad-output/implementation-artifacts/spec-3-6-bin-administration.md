---
title: 'Story 3.6: Bin administration'
type: 'feature'
created: '2026-09-10'
status: 'done'
route: 'dispatch'
baseline_commit: 'dd6c2d1' # wms-be main
baseline_commit_fe: '51553ea' # wms-fe main
baseline_commit_mob: 'e9e85a4' # wms-mobile main
context:
  - '_bmad-output/implementation-artifacts/epic-3-context.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** Bins are immutable master data — there is no way to block a bin out of operations (the existing toggle lives in the wrong module and can even block system bins), consolidate two bins' stock, or retire an empty bin. The warehouse's bin list only grows.

**Approach:** Bin administration completes the bin lifecycle: **block/unblock** (re-homed into the `putaway` module, which owns bin operational state — blocked bins drop out of putaway suggestions immediately and reject placements/scans), **merge** (all on-hand stock of a source bin moves to a target bin through real per-arm ledger movements, then the source retires), and **retire-after-empty** (a bin with any on-hand stock cannot be retired — the rejection names the SKUs/quantities blocking it; system bins never merge or retire). Web admin surface in the existing zone/bins setup; mobile untouched — the sealed snapshot keeps shipping blocked bins (the device needs them to reject scans) but excludes retired ones, and the server re-gate is the staleness backstop.

**Decided (2026-09-10, human):**
- Merge rejects on target overflow — all-or-nothing (`400 bin-full` naming target capacity/occupancy); capacity stays a hard invariant in every operation.
- Merge auto-retires the source bin in the same commit — merge = consolidate + retire, one op.
- Merge and retire are gated by a new `bin.retire` capability — Owner + Ops Manager only.

## Boundaries & Constraints

**Always:**
- Merge is a real ledger movement per on-hand arm: one `bin.merged` event per (sku, batch) arm (fromBinId = source, toBinId = target, batchRef carried), per-serial units for serial-tracked stock (one two-arm event per serial, the putaway convention) — never a direct `stock_on_hand` write; both bin rows are locked `.for('update')` (id-sorted, deadlock-safe) before the arms are read; the whole merge (movements + source retirement + audit + outbox + idempotency) is one transaction.
- Retire is one-way and idempotent-keyed: `retired_at/retired_by` (the devices-`revoked_at` pattern) set only when the bin's total on-hand is 0 (`400 bin-not-empty` naming the blocking (sku, batch, qty) rows otherwise); a retired bin is operationally gone — excluded from suggestions, the device snapshot, adjustments' target choice, and merge targets — referenced as a source/target it returns `400 bin-retired`.
- System bins (`systemOwned`) can never be blocked, merged (as source or target), or retired → `400 validation-failed` naming the bin (closing today's gap where the toggle can block the Receiving/QC-hold bins).
- A bin with an open QC hold can neither be a merge source nor a merge target → `409 bin-merge-hold-open` naming the hold (releases already reject a vanished origin bin — the hold must keep its bin).
- All three mutations are idempotent commands (required `Idempotency-Key`, payload hash, replay re-serves the snapshot, mismatch `422`), capability-gated: block → `bin.block` (existing), merge/retire → `bin.retire` (new; Owner + Ops Manager only — Accountant/Operator none); audit row + outbox event in the same tx (the 3.4/3.5 convention), outbox before the idempotency key.

**Never:**
- No bin deletion anywhere — retire is terminal and keeps the row (the `(warehouse_id, code)` unique key keeps retired codes reserved; re-creating a retired code → `409 duplicate-bin-code`).
- No cross-warehouse merge (source and target must share the warehouse — `404`/`400 validation-failed` otherwise).
- No partial merge (all arms move or nothing does), no un-retire.
- No picking-side consumption in this story (no picking exists — Epic 4 consumes the block/retired state); no velocity/zone-affinity suggestion changes (deferred with the report).
- No mobile changes: the sealed-snapshot shape is unchanged; a merged/retired bin lingers in a stale device cache until refresh and the server re-gate rejects it — the established staleness model, no new machinery.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Block / unblock | bin (re-homed command, same `PATCH .../bins/{binId}` URL) | blocked flips; suggestions drop it on the next derivation; outbox `bin.blocked` + audit row | unknown → `404`; system bin → `400 validation-failed`; replay re-serves |
| Retire empty | bin with on-hand 0, not system | `200` `{bin}` with `retiredBy/retiredAt`; outbox `bin.retired`; excluded from suggestions/snapshot/zone list filters | unknown → `404`; stock present → `400 bin-not-empty` naming (skuCode, batchCode?, qty); already retired (different key) → `409 bin-retired`; system bin → `400 validation-failed` |
| Merge happy path | source bin on-hand arms → target bin | one `bin.merged` event per (sku, batch) arm (per serial unit for serial-tracked); target occupancy + moved qty; source retired in the same commit; outbox `bin.merged` + audit | `200` `{source, target, moved {skus, units}}` |
| Merge guards | target blocked → `400 bin-blocked`; target would overflow → `400 bin-full` naming target capacity/occupancy, nothing written (all-or-nothing); source = target or system bin → `400 validation-failed`; unknown bin → `404` | | |
| Merge with open QC hold | source or target bin holds an open hold | nothing written | `409 bin-merge-hold-open` naming the bin + hold |
| Merge with serials | serial-tracked stock in source | one two-arm event per serial unit (batchRef carried) | `400` shape arms mirror stock.adjustment |
| Retired bin reused | retire again (different key) / place into it / adjust into it / merge into it | nothing written | `409 bin-retired` (re-retire) / `400 bin-retired` (target use) |
| Wrong authority | accountant role, foreign tenant, bare/web session on block | nothing written | `403 role-denied` / `permission-denied`, `401 unauthenticated` |

</frozen-after-approval>

## Code Map

- `wms-be/src/modules/tenancy/bin.command.ts` — `setBlocked` (:354, capability `bin.block`, outbox `bin.blocked`, idempotency) — **re-homes**: the command logic moves to the `putaway` module (the architecture's ownership split), the controller URL and FE contract stay; gains a system-bin guard (`400 validation-failed` naming the bin) and an audit row (3.4/3.5 convention).
- `wms-be/src/modules/tenancy/bin.command.ts` — grows `mergeBin` + `retireBin` (capability `bin.retire`; `Idempotency-Key`; ledger movements through `InventoryFacade`/`LedgerService.appendLedgerEventInTx`, the receiving-command pattern); new Problem codes `bin-not-empty`, `bin-retired`, `bin-merge-hold-open` in the shared problem factory.
- `wms-be/src/modules/inventory/ledger-registry.ts` — register `bin.merged` (sinceVersion 1, reference arm `{kind: 'bin-merge', mergeId}`; batch+serial arms open).
- `wms-be/src/shared/db/schema.ts` + `drizzle/0016_*.sql` — `bins` gains nullable `retired_at`, `retired_by` + hand-appended CHECK (retired pairing: `retired_at IS NULL ↔ retired_by IS NULL`, the 0014 release-pairing pattern); no RLS change (existing bins RLS covers).
- `wms-be/src/modules/putaway/putaway.command.ts` — `binCandidatesInTx` (:718) gains `retired_at IS NULL`; placement target guard gains the retired check (`400 bin-retired`); `binOccupancyInTx` reused for the retire/merge guards; `receivingBinOnHandInTx` pattern reused for per-(sku, batch) on-hand reads.
- `wms-be/src/modules/tenancy/tenancy.controller.ts` — the `PATCH .../bins/:binId` route keeps its URL and delegates block to the re-homed command; new `POST .../bins/:binId/merge` `{targetBinId}` and `POST .../bins/:binId/retire` (empty body); new `GET .../bins/:binId/on-hand`? **no** — retire rejections name the blockers in the problem detail; no new read.
- `wms-be/src/modules/inbound/receiving.facade.ts` (`getBinSummaries` :334) — excludes retired bins from the device snapshot (blocked bins keep shipping, deliberately).
- `wms-be/src/modules/tenancy/tenancy.service.ts` (:301 zone bin list) — keeps listing retired bins (web needs them visible with `retiredAt`), flagged in the list item.
- `wms-fe/src/components/settings/zone-bin-setup.tsx` (:582-628 block toggle) — Merge action (target picker from the warehouse's live bins, `bin.retire`-gated) and Retire action (enabled always; the `bin-not-empty` problem detail renders the blocking SKUs/quantities); `src/lib/users.ts` + `users.test.ts` — `bin.retire` mirror, matrix pin updated.
- `wms-be/test/bin-admin.spec.ts` (new) — e2e per the matrix; bootstrap mirrors `tenancy.spec.ts` fixtures (HTTP grid + direct SQL bins insert at :1199); block-toggle arms migrate conceptually (existing `tenancy.spec.ts:975` arms keep passing on the same URL).
- `wms-mobile` — **untouched** (snapshot shape unchanged; `parseCatalogSnapshot` already tolerates shape drift server-side filters retired).

## Tasks & Acceptance

**Execution:**
- [x] `wms-be drizzle/0016_*.sql` — `retired_at/retired_by` + retired-pairing CHECK
- [x] `wms-be ledger-registry` — register `bin.merged` — the merge ledger truth
- [x] `wms-be` — re-home `setBlocked` into the putaway module (same URL, + system-bin guard, + audit) — the ownership split
- [x] `wms-be` — `mergeBin` + `retireBin` commands (guards per matrix, per-arm ledger movements, outbox + audit, idempotent) + retired-bin exclusion in suggestions/snapshot/placements/adjustments
- [x] `wms-be test/bin-admin.spec.ts` — e2e per the matrix incl. serial merge, QC-hold guard, RLS, 0016 round-trip
- [x] `wms-fe` — Merge + Retire actions in zone-bin-setup + `bin.retire` mirror + test pin
- [x] `wms-be bun run openapi:export` + `wms-fe bun run api:generate` — additive contract

**Acceptance Criteria:**
- Given a blocked bin, when suggestions or placements derive, then the bin is absent/rejected (`bin-blocked`) immediately, on device and server (FR-11)
- Given a bin with stock, when retired, then the rejection names the SKUs/quantities; an empty bin retires terminal and disappears from every operational surface
- Given a merge, when committed, then every on-hand arm moves as a real `bin.merged` ledger movement and the source retires empty in the same transaction
- Given a system bin, when blocked/merged/retired, then the command refuses naming the bin

## Design Notes

**Why the block command re-homes but the URL stays.** The architecture split (tenancy = master data, putaway = operational state) is about who owns the *command logic*, not the URL: the FE already consumes `PATCH .../bins/{binId}`, so the controller keeps the route and injects the putaway-owned command — no FE breaking change, the module boundary is real in the code.

**Why merge is ledger movements, not a projection edit.** Every bin's on-hand is a derived projection of the ledger; "consolidating" by editing projections would fork the truth. One `bin.merged` event per arm (both bin arms on one event, the putaway.placed convention) folds both bins in one commit — replay, reconciliation, and the audit trail all see real movements.

**Retire is master-data, merge is stock + master-data.** Retire writes only columns (no stock, so no ledger); merge writes movements AND retires the source — that's why merge lives with the ledger-writing commands and the retired-state filters live next to each reader.

## Verification

**Commands:**
- `cd workspace/core/backend/wms-be && bun run test` — all suites pass incl. `test/bin-admin.spec.ts`
- `cd workspace/core/backend/wms-be && bun run lint && bun run typecheck && bun run build && bun run db:migrate && bun run db:verify`
- `cd workspace/core/frontend/wms-fe && bun run test && bun run lint && bun run typecheck && bun run build`
- `cd workspace/core/mobile/wms-mobile && bun run typecheck && bun run test` — unchanged suites stay green

## Spec Change Log

<!-- Append-only. Populated by step-04 during review loops. Do not modify or delete existing entries.
     Each entry records: what finding triggered the change, what was amended, what known-bad state
     the amendment avoids, and any KEEP instructions (what worked well and must survive re-derivation).
     Empty until the first bad_spec loopback. -->

## Review Triage Log

<!-- Append-only. Populated by step-04 on every review pass: one row per reviewer finding —
     verdict (high/medium/low/false/maybe-false) with its evidence: the refutation for
     false, what would settle it for maybe-false. Empty until the first review pass. -->

### Pass 1 (2026-09-10) — 22 blind + 5 verification-gap + 11 edge-case findings

| # | Layer | Finding | Verdict | Evidence |
|---|-------|---------|---------|----------|
| 1 | blind | QC-release retired-origin arm (`qc-hold-origin-bin-gone`) has no test | medium | = VG gap #1, verified with searches; `qc-holds.spec.ts:631` comment even promises the 3.6 arm. PATCH |
| 2 | blind | retireBin never cross-checks ledger serials (asymmetric vs merge) | maybe-false | Drift-only: every shipped path folds ledger + projection in one tx; no reachable divergence shown. Settle: prove no path writes a serial-locating event without matching projection delta. DEFER (with #31) |
| 3 | blind | Merge-from-blocked-source unguarded/undocumented | low | Real (as-built: allowed, the unblock path). Smallest fix = doc line in command + openapi note. PATCH |
| 4 | blind | setBlocked UPDATEs before the system/retired guards | low | Real (correct only via rollback). Reorder to guards-then-write, mergeBin's order. PATCH |
| 5 | blind | binRetired409/binNotFound/IDEMPOTENCY_TENANT_KEY duplicated across bin-state.command + bin.command | low | Real, verbatim copies. Extract shared. PATCH |
| 6 | blind | binRetiredAsTarget reused for merge SOURCE — "placements" wording on a merge rejection | low | Real (`bin.command.ts` source.retiredAt → binRetiredAsTarget). Dedicated message. PATCH |
| 7 | blind | `bin-retired` dual status (409/400) undocumented | false | The frozen matrix assigns it explicitly: re-operating → 409, source/target use → 400; the code comment on each arm restates it |
| 8 | blind | No index on retired_at for the isNull filters | false | bins is bounded (≤500 grid cap/warehouse + manual); seq scan beats index maintenance at this cardinality |
| 9 | blind | retired_by bare uuid, no FK | false | Repo convention is zero FKs (`grep references( schema.ts` → 0); devices.revoked_by is the bare-uuid precedent |
| 10 | blind | Serial-arm batchRef trusted from latest event, not cross-checked vs batch_on_hand | maybe-false | Drift-only scenario; intake/adjustment arms carry batch refs consistently. Settle: same as #30. DEFER (with #30/#33) |
| 11 | blind | serialsLocatedInBinInTx raw SQL + N+1 + tenant-wide window | low | Reject: N+1 is per serial-tracked SKU-row in one bin (a handful); raw SQL is the qcHeldArmsInTx precedent; fix = complexity at negligible scale |
| 12 | blind | TOCTOU: concurrent placeHold can commit alongside merge (placeHold locks no bin row) | medium | Verified: qc.command placeHold selects the bins row with no `.for('update')` (only release locks a row, the hold row). Race strands a hold on a retired/emptied bin. PATCH (with #28/#29) |
| 13 | blind | serialsLocatedInBinInTx raw SQL — schema drift risk | false | The qcHeldArmsInTx precedent is the same raw-SQL-over-ledger_events shape, cited in the new code's own comment |
| 14 | blind | MergeBinDto.targetBinId @IsString vs format uuid → 404 not 400 | low | Real, diverges from repo DTO convention (open action item a3). @IsUUID. PATCH |
| 15 | blind | "one-way, no back-edges" DI cycle claim unproven | false | Build + 302 tests boot the composed app; module imports are one-way (tenancy → putaway/inventory); the putaway-file → tenancy-helper imports are value imports, not Nest module edges |
| 16 | blind | confirmMerge success never resets busyBinId | low | Real (catch-only reset). Cosmetic on a now-retired row, but the finally is one line. PATCH |
| 17 | blind | Retire is single-click, no confirm dialog | low | Reject: fix is new UI machinery; intent asked for an enabled action; the merge picker is incidental, not a confirm pattern |
| 18 | blind | openMergePicker stale-response race + silent empty catch | low | Real. Seq guard + error surface is a small direct fix. PATCH |
| 19 | blind | rejectionReason `bin-retired` discards error.detail (siblings surface it) | low | Real, lossier than siblings. One-line fix. PATCH |
| 20 | blind | Merge audit row names only the source bin | low | Reject: one-audit-row-per-command is the 3.4/3.5 convention (target = the administered bin); the outbox payload + every ledger event carry both bins |
| 21 | blind | Serial-disagreement guard arm untested | medium | = VG gap #24 (carried). PATCH |
| 22 | blind | Contract docs (meta) not updated in diff | false | Step-05 does the meta docs PR (backend-first, meta-last ordering); not part of the code diff |
| 23 | vgap | (gap, pre-verified) QC-release retired-origin arm untested | medium | Filed evidence: only the missing-bin arm is covered (`qc-holds.spec.ts:619-643`); no test retires an origin then releases. PATCH (with #1) |
| 24 | vgap | (gap, pre-verified) Serial-disagreement guard untested | medium | Filed evidence: only the agreeing direction runs; a bump-out-of-band merge would pass every suite. PATCH |
| 25 | vgap | (gap, pre-verified) Legacy idempotency-snapshot replay never exercises normalizeBin | medium | Filed evidence: every replay key is same-run; the `??` fallbacks are dead in the suite. PATCH (test arm) |
| 26 | vgap | retireBin with an open hold strands the hold forever (empty gate passes; release then 409s the retired origin; no resolution path) | medium | Reachable via shipped commands (hold relocates stock; origin bin is empty; retire passes). PATCH (with #29 — retire gains the hold gate) |
| 27 | vgap | binRetiredAsTarget wording on merge source | low | = #6 (carried). PATCH |
| 28 | edge | Merge TOCTOU vs hold placement (re-check after appends or lock) | medium | = #12's race; verification chose the root fix: placeHold locks the scoped bin row. PATCH (grouped) |
| 29 | edge | retireBin has no open-QC-hold gate | medium | = #26. PATCH (grouped) |
| 30 | edge | Batch-arm enumeration: batch_on_hand sum vs stock_on_hand unchecked | maybe-false | Same fold-in-one-tx reasoning as #2; a sum-equality check is defensive. Settle: prove a reachable divergence (invariant/DB-constraint test). DEFER (with #10/#33) |
| 31 | edge | Serials ledger-located with a zero on-hand row neither enumerated nor cross-checked (merge + retire) | maybe-false | Enumeration keys off positive stock_on_hand rows; a serial's latest locating event contributes +1, so disagreement needs drift. DEFER (with #2) |
| 32 | edge | Capacity gate check-then-act vs concurrent adjustStock (adjust locks no bin row, checks no capacity) | low → defer | Real race, but adjustStock enforces no capacity at all today (verified: zero capacity refs in inventory.command.ts) — adjustment-driven overflow is pre-existing semantics; merge's gate is policy for merge, not a global invariant. DEFER (pre-existing) |
| 33 | edge | batch+serial SKU with a batchRef-null serial event moves the serial but strands the batch arm | maybe-false | Reachable only via drift: intake/adjustment arms carry batch refs for batch-tracked SKUs. Settle: same invariant evidence as #30. DEFER (grouped) |
| 34 | edge | normalizeBin defaults legacy system-bin replay's systemOwned to false | low | Reject: the additive-nullable default is the documented legacy-replay contract; pre-3.6 clients never saw the field; replay-only, rare |
| 35 | edge | MergeBinDto @IsString | low | = #14 (carried). PATCH |
| 36 | edge | openMergePicker race/silent catch | low | = #18 (carried). PATCH |
| 37 | edge | confirmMerge busyBinId leak | low | = #16 (carried). PATCH |
| 38 | edge | BinMergeResponse.moved generated as `{[key: string]: unknown}` — typed shape lost | low | Real (types.gen.ts). @ApiProperty nested shape + regenerate. PATCH |