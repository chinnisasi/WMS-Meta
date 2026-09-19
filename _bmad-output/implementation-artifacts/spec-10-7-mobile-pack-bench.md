---
title: 'Story 10-7: Mobile pack bench'
type: 'feature'
created: '2026-09-19'
status: 'ready-for-dev'
route: 'dispatch'
review_loop_iteration: 0
baseline_commit: '944f718 (wms-mobile) / 18a0c0b (wms-be)'
context:
  - '_bmad-output/implementation-artifacts/epic-10-context.md'
  - 'docs/design/SYSTEM-DESIGN.md'
  - 'docs/design/IMPLEMENTATION-GUIDE.md'
  - 'docs/design/modules/outbound.md'
  - 'docs/design/modules/inbound.md'
  - 'docs/design/mobile/SYSTEM-DESIGN.md'
  - 'docs/design/mobile/IMPLEMENTATION-GUIDE.md'
  - 'docs/design/API-SURFACE.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** Epic 10's backend pack flow is finished (`packOrder`, `pack.execute`) and 10-3 gave it the catch-weight arms (handling-unit ids per SKU), but the device cannot pack: the pack route is `TenantSessionGuard`-only, the sealed snapshot carries no pack tasks and no handling units, and the inbox has no Pack tab — an order that finished picking has no device path to `ready_to_dispatch`.

**Approach:** Backend-first additive work: a device-guarded pack route delegating to the same `packOrder` command, plus two additive snapshot arrays — `packTasks` (packable orders with per-SKU picked totals) and active `handlingUnits` (id + skuId) — so the bench pre-verifies offline exactly what the server will verify. Mobile: Pack tab in the inbox, a pack screen (scan-driven accumulation, catch-weight unit-label scanning, optional parcel weight), a `pack.execute` outbox op sent under the op's ULID idempotency key.

## Boundaries & Constraints

**Always:**
- The device pre-verifies offline what it has data for, before anything queues: scanned qty per SKU must equal the snapshot's picked qty exactly; a catch-weight line's scanned unit ids must be distinct, count == picked units, and every id must exist as an `active` unit of that SKU in the snapshot. The server stays authority — its 404/409/422 arms are unchanged and classify on replay as today.
- Quantities and refusals mirror the server byte-for-byte where the server words them (`pack-mismatch` category, catch-weight count copy), same convention as 10-6's precision mirror. Pack quantities are whole physical units at the bench (a picked count is an integer); precision surfaces only through formatting (`formatQuantity`).
- `handlingUnitIds` rides only catch-weight scan lines and `weightGrams` only when captured — key-absent, never null, on the wire (10-6's null-vs-absent rule; the server's non-CW pack hash must stay byte-identical to its pre-10.3 shape).
- Snapshot parsing is additive: a pre-10-7 seal parses with `packTasks: []` / `handlingUnits: []` — the inbox simply shows no pack work, nothing crashes.
- Backend first: the device route and snapshot fields land before any mobile consumption; CI drift guards will fail on FE-style ordering only if reversed.

**Never:**
- No dimensions capture on the device (parcel `dimensionsMm` stays a web/4-2d concern; the field stays absent in the device payload), no label printing, no dispatch screen (`dispatch.execute` is 4-2d's), no carrier fields, no changes to the pack command's refusals or the tenant route, no re-weigh of catch-weight units (FR33: captured once at receipt, immutable), no scale-hardware integration beyond 10-6's manual/scale-typed entry pattern for parcel weight, no new task types in the inbox beyond Pack.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Full scan match | Every SKU scanned to its picked qty (CW SKUs: N distinct unit labels) | Commit enabled; op queued as `pack.execute`; banner queued state | N/A |
| Over-scan | A SKU reaches its picked qty and is scanned again | Inline refusal naming the SKU and both quantities; nothing queued | Announced same as state |
| Under-scan commit | Commit pressed with a SKU short of its picked qty | Commit blocked; blocker copy names the gap per SKU | Announced |
| CW typed quantity | Typed qty on a catch-weight SKU | Inline refusal: units are counted by scanning their labels | Same announcement rule |
| Unknown unit id | A scanned/typed id absent from the snapshot's active units | Inline refusal before queueing (offline); server 404 arm unchanged as backstop | Announced |
| Duplicate unit id | Same id scanned twice on one line | Inline refusal naming the duplicate | Announced |
| Unit ids on non-CW SKU | A label scanned against a non-catch-weight SKU | Inline refusal: the SKU has no handling units (mirrors server) | Announced |
| Parcel weight over cap | Typed parcel weight > 1,000,000 g | Inline refusal mirroring the server bound (10-6's `parseWeightEntry` helpers) | Announced |
| Stale snapshot | Order packed/cancelled, or unit already packed since the seal | Op replays: server 409/422 → classified into the existing replay outcome buckets, named in the sync summary | Nothing re-packs (idempotency key) |
| Pre-10-7 snapshot | Seal lacks `packTasks`/`handlingUnits` | Parses with empty defaults; Pack tab shows the no-cache/no-tasks copy | N/A |

</frozen-after-approval>

## Code Map

**Backend (wms-be, additive only — no command/schema/migration changes):**
- `src/modules/outbound/pack.command.ts` -- the command the device route delegates to; READ ONLY. Note its verification query (`picks` grouped by `(order_line, sku)`, `:341-352`) and the catch-weight count rule (`:782-819`) — the snapshot derivation and device pre-verification must mirror both.
- `src/api/outbound.controller.ts:156` -- the tenant pack route (untouched); the new device route sits beside `recordPick` (`:522`), same guard/headers pattern.
- `src/modules/outbound/outbound.dto.ts:963-1001` -- `PackOrderDto` (`scanned[]` with `skuId`/`qty`/`handlingUnitIds?`, `weightGrams?`, `dimensionsMm?`); the device DTO reuses it plus `orderId`.
- `src/modules/outbound/outbound.facade.ts:402-419` -- the snapshot facade pattern (`getPickTasksInTx`); a `getPackTasksInTx` sibling derives packable orders + per-SKU picked totals + active units.
- `src/modules/inbound/receiving.dto.ts:505-526` -- `CatalogSnapshotResponse`; add `packTasks`/`handlingUnits` (new arrays, additive).
- `src/api/receiving.controller.ts:142-143` -- the snapshot endpoint the device seals.

**Mobile (wms-mobile):**
- `src/api.ts` -- `CatalogPackTask`, `CatalogHandlingUnit`, snapshot fields; `PackPayload`; `fetchApiPackOrder` (device token + Idempotency-Key).
- `src/state/catalog-snapshot.ts` -- additive parse defaults for the two new arrays.
- `src/offline/types.ts` + `src/state/op-dispatch.ts` + `src/state/device-store.ts` -- `OpType` gains `'pack.execute'`; the exhaustive sender mapping forces the wiring.
- `src/packing/draft.ts` (new) -- the pack draft: scanned accumulations per SKU, unit ids per CW SKU, parcel weight, exact-match blocker, `confirmPayload` (spread-conditional keys).
- `app/pack.tsx` (new) -- the bench screen; `app/inbox.tsx` -- Pack tab + task list + CTA (the placeholder arm at `:111` says "task types arrive with later epics" — Pack graduates from it).
- `src/lib/quantity-input.ts` -- reuse `parseWeightEntry`, `formatQuantity`, `uomDisplayName`; no new precision grammar (pack counts are integers).
- Tests co-located; `docs/repos/wms-mobile/README.md` -- contract: pack op + new snapshot fields.

## Tasks & Acceptance

**Execution:**
- [ ] `wms-be` `outbound.facade.ts` + `receiving.dto.ts` + `receiving.controller.ts` -- derive and expose `packTasks` (packable orders: `accepted`, at least one pick, zero outstanding picklist lines, sum picked > 0; per-SKU `pickedQty` from the same grouped-`picks` query the command verifies against) and `handlingUnits` (`active` only, `id` + `skuId`) additively -- the device can only pre-verify against data in the snapshot
- [ ] `wms-be` `outbound.controller.ts` + `outbound.dto.ts` -- add the device-guarded pack route (badge-in session, `Idempotency-Key`, `PackOrderDto` + `orderId` in body) delegating to the same command with the same error arms -- the device cannot call the tenant route
- [ ] `wms-mobile` `src/api.ts` + `src/state/catalog-snapshot.ts` -- new types + additive parse -- a pre-10-7 seal degrades to today's behavior
- [ ] `wms-mobile` `src/packing/draft.ts` (new) -- the draft model with exact-match pre-verification and the null-vs-absent payload rule -- one statement, unit-tested
- [ ] `wms-mobile` `src/offline/types.ts` + `op-dispatch.ts` + `device-store.ts` -- the `pack.execute` op type and its sender -- offline replay with the op ULID as key
- [ ] `wms-mobile` `app/inbox.tsx` + `app/pack.tsx` (new) -- Pack tab, task cards, the bench screen (scan-driven, CW unit labels, optional parcel weight in kg → whole grams) -- the story's namesake
- [ ] Tests -- unit-test the matrix rows (match, over/under, CW arms, dup/unknown ids, weight cap, snapshot defaults) and the replay classification of the pack error arms
- [ ] `docs/repos/wms-mobile/README.md` -- contract: `pack.execute` op; snapshot carries `packTasks`/`handlingUnits`

**Acceptance Criteria:**
- Given a fully-picked order in the snapshot, when the operator scans every SKU to its picked qty (CW SKUs by unit label), the queued `pack.execute` carries `scanned` with per-SKU quantities, `handlingUnitIds` only on CW lines, and settles to `ready_to_dispatch` with the pack receipt in the sync summary
- Given an offline start with a pre-10-7 snapshot, the app opens with no Pack work shown and no crash; refreshing while online fills the Pack tab
- Given a second op for the same order (or a replay), the idempotency key re-serves the stored pack — nothing re-packs, and the summary names the outcome

## Design Notes

- **Why two additive snapshot arrays:** pack verification compares scans to *picked* quantities — the one dataset no device surface has today. Reusing the snapshot seal (AD-4) keeps the bench offline-capable like receive/putaway/pick, and `handlingUnits` (active-only, id + skuId) closes the 404/422 queue-and-die holes the same way `bins` closed the wrong-bin-scan hole. Active-only self-prunes: units flip to `packed` at pack, so the array is bounded by received-not-yet-packed stock.
- **The device route mirrors `picks`, not the tenant route:** `POST :tenantId/outbound/packs` with `DeviceSessionGuard`, orderId in the body — the tenant route keeps serving 4-2d's web surface later; both delegate to `PackCommandService.packOrder`, whose contract does not move.
- **The bench counts, it does not choose:** the operator scans until each SKU's count equals the snapshot's picked qty; the commit gate is exact-match. Partial packs are impossible server-side (the command is all-or-nothing), so the device must never queue a partial scan.

## Verification

**Commands:**
- `bun test` (in wms-be and wms-mobile) -- expected: all green; new snapshot/pack-route tests in wms-be, draft/dispatch/snapshot tests in wms-mobile
- `bunx tsc --noEmit` (in wms-mobile) -- expected: clean
- CI on both PRs -- expected: green (wms-be drift guards run before the wms-mobile PR merges)