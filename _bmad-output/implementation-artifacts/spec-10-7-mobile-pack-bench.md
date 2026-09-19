---
title: 'Story 10-7: Mobile pack bench'
type: 'feature'
created: '2026-09-19'
status: 'done'
route: 'dispatch'
review_loop_iteration: 1
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
- Quantities and refusals mirror the server byte-for-byte where the server words them (`pack-mismatch` category, catch-weight count copy), same convention as 10-6's precision mirror. **Pack quantities renegotiated (human decision 2026-09-19):** 0-dp SKUs are scan-counted (+1 per scan) exactly as before; catch-weight lines are label-counted exactly as before; a measured (precision > 0) non-catch-weight line is **typed** — precision-aware decimal entry capped at the SKU's `uomPrecision` (10-6's grammar), and the commit gate still demands the typed qty equal the snapshot's picked qty exactly. Scans refuse a measured non-CW line with copy saying it is counted by typed quantity (a +1 scan can never reach a fractional pick, e.g. 2.5 kg — the wedge this replaces). `formatQuantity` renders every quantity.
- `handlingUnitIds` rides only catch-weight scan lines and `weightGrams` only when captured — key-absent, never null, on the wire (10-6's null-vs-absent rule; the server's non-CW pack hash must stay byte-identical to its pre-10.3 shape).
- Snapshot parsing is additive: a pre-10-7 seal parses with `packTasks: []` / `handlingUnits: []` — the inbox simply shows no pack work, nothing crashes.
- Backend first: the device route and snapshot fields land before any mobile consumption; CI drift guards will fail on FE-style ordering only if reversed.

**Never:**
- No dimensions capture on the device (parcel `dimensionsMm` stays a web/4-2d concern; the field stays absent in the device payload), no label printing, no dispatch screen (`dispatch.execute` is 4-2d's), no carrier fields, no changes to the pack command's refusals or the tenant route, no re-weigh of catch-weight units (FR33: captured once at receipt, immutable), no scale-hardware integration beyond 10-6's manual/scale-typed entry pattern for parcel weight, no new task types in the inbox beyond Pack.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Full scan match | Every 0-dp SKU scanned to its picked qty (CW SKUs: N distinct unit labels; measured SKUs: typed qty equal to picked qty) | Commit enabled; op queued as `pack.execute`; banner queued state | N/A |
| Measured typed qty | Typed qty on a measured (precision > 0) non-CW SKU, equal to its picked qty (e.g. "2.5" against picked 2.5) | Accepted; commit gate satisfied for that line | N/A |
| Measured typed qty, wrong value | Typed qty ≠ picked qty, or finer than the SKU's `uomPrecision` | Inline refusal mirroring the server's precision copy (finer) / commit blocker (mismatch) | Announced |
| Scan on a measured line | A barcode scanned against a measured non-CW SKU | Inline refusal: this SKU is counted by typed quantity | Announced |
| Over-scan | A 0-dp SKU reaches its picked qty and is scanned again | Inline refusal naming the SKU and both quantities; nothing queued | Announced same as state |
| Under-scan commit | Commit pressed with a SKU short of its picked qty | Commit blocked; blocker copy names the gap per SKU | Announced |
| CW typed quantity | Typed qty on a catch-weight SKU | Inline refusal: units are counted by scanning their labels | Same announcement rule |
| Unknown unit id | A scanned/typed id absent from the snapshot's active units | Inline refusal before queueing (offline); server 404 arm unchanged as backstop | Announced |
| Duplicate unit id | Same id scanned twice on one line | Inline refusal naming the duplicate | Announced |
| Unit ids on non-CW SKU | A label scanned against a non-catch-weight SKU | Inline refusal: the SKU has no handling units (mirrors server) | Announced |
| Parcel weight over cap | Typed parcel weight > 1,000,000 g | Inline refusal mirroring the server bound (10-6's `parseWeightEntry` helpers) | Announced |
| Stale snapshot | Order packed/cancelled, or unit already packed since the seal | Op replays: server 409/422 → classified into the existing replay outcome buckets, named in the sync summary | Nothing re-packs (idempotency key) |
| Settled pack reaches the summary | A `pack.execute` op settles on replay | The summary entry names the packed order's receipt — lines (sku × qty), total units, optional parcel weight — from the pack response (not a bare settled count) | N/A |
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
- `src/packing/draft.ts` (new) -- the pack draft: scan-counted accumulations for 0-dp SKUs, unit ids per CW SKU, **typed precision-aware qty for measured non-CW lines** (10-6's `quantity-input.ts` grammar; scans refuse a measured line), parcel weight, exact-match blocker, `confirmPayload` (spread-conditional keys).
- `app/pack.tsx` (new) -- the bench screen; `app/inbox.tsx` -- Pack tab + task list + CTA (the placeholder arm at `:111` says "task types arrive with later epics" — Pack graduates from it).
- `src/lib/quantity-input.ts` -- reuse `parseWeightEntry`, `formatQuantity`, `uomDisplayName`; the measured-line typed entry rides 10-6's existing decimal grammar (no new grammar — the pack gate only demands exact equality with `pickedQty`).
- `src/state/replay-classification.ts` -- `settledNote` gains a `pack.execute` arm rendering the pack receipt (sku × qty lines, total units, optional weight) from the pack response; `src/offline/engine.ts` untouched (it already surfaces any settled op that carries a note).
- Tests co-located; `docs/repos/wms-mobile/README.md` -- contract: pack op + new snapshot fields.

## Tasks & Acceptance

**Execution:**
- [x] `wms-be` `outbound.facade.ts` + `receiving.dto.ts` + `receiving.controller.ts` -- derive and expose `packTasks` (packable orders: `accepted`, at least one pick, zero outstanding picklist lines, sum picked > 0; per-SKU `pickedQty` from the same grouped-`picks` query the command verifies against) and `handlingUnits` (`active` only, `id` + `skuId`) additively -- the device can only pre-verify against data in the snapshot
- [x] `wms-be` `outbound.controller.ts` + `outbound.dto.ts` -- add the device-guarded pack route (badge-in session, `Idempotency-Key`, `PackOrderDto` + `orderId` in body) delegating to the same command with the same error arms -- the device cannot call the tenant route
- [x] `wms-mobile` `src/api.ts` + `src/state/catalog-snapshot.ts` -- new types + additive parse -- a pre-10-7 seal degrades to today's behavior
- [x] `wms-mobile` `src/packing/draft.ts` (new) -- the draft model with exact-match pre-verification and the null-vs-absent payload rule -- one statement, unit-tested
- [x] `wms-mobile` `src/offline/types.ts` + `op-dispatch.ts` + `device-store.ts` -- the `pack.execute` op type and its sender -- offline replay with the op ULID as key
- [x] `wms-mobile` `app/inbox.tsx` + `app/pack.tsx` (new) -- Pack tab, task cards, the bench screen (scan-driven, CW unit labels, optional parcel weight in kg → whole grams) -- the story's namesake
- [x] `wms-mobile` `src/packing/draft.ts` + `app/pack.tsx` -- measured (precision > 0) non-CW lines carry a typed precision-aware qty (10-6's grammar; scans refuse a measured line with copy saying it is typed); commit gate unchanged (exact equality with `pickedQty`) -- the renegotiated wedge fix (review W1)
- [x] `wms-mobile` `src/state/replay-classification.ts` -- `settledNote` gains a `pack.execute` arm rendering the pack receipt from the response (sku × qty, total units, optional weight) so a settled pack appears in the sync summary -- review W2 (bad_spec: AC-1's receipt was never wired)
- [x] `wms-mobile` `app/pack.tsx` -- scan handling reads the draft from a functional update so two scans in one render frame cannot lose a count -- review W4
- [x] `wms-be` `outbound.controller.ts` + `outbound.dto.ts` -- normalize `handlingUnitIds` with `!= null` (explicit `null` currently throws a 500) and strip `dimensionsMm` from `DevicePackDto` (inherited field is silently dropped today) -- reviews W5, W6
- [x] `wms-mobile` `app/pack.tsx` -- `autoCapitalize="none"` on the manual-entry and HID inputs (typed lowercase labels/barcodes must resolve); weight-entry refusals announce (complete invalid entries are silent today) -- reviews W7, W13
- [x] `wms-be` `outbound.facade.ts` + `test/pick-truncation.spec.ts` pattern -- extract the pack truncation into a named function parameterized by group key and unit-test it (at-ceiling unchanged, straddling dropped whole, exact-ceiling kept, single-giant truncated-not-empty), and fix the "returned as it is" comment -- reviews W8, W9
- [x] `wms-mobile` `app/inbox.tsx` -- the Pack tab applies the same consumed filter the bench screen uses (a queued order must not stay tappable) -- review W10
- [x] `wms-be` `test/pack-bench.spec.ts` -- pin the device route's authority arms (missing/malformed Idempotency-Key 400, foreign-tenant 403, `weightGrams: null` normalization) and reword the contradictory "still bench work" comment -- reviews W11, W14
- [x] `wms-mobile` `src/packing/draft.ts` -- define the parcel-weight constant against the server's `MAX_WEIGHT_GRAMS` (pack.command.ts:70), not the handling-unit bound -- review W12
- [x] EOF newlines -- `test/pack-bench.spec.ts` + `receiving.dto.ts` (wms-be), `draft.ts` + `draft.test.ts` + `pack.tsx` (wms-mobile) -- review W15
- [x] Tests -- unit-test the matrix rows (match, over/under, CW arms, measured typed qty, dup/unknown ids, weight cap, snapshot defaults) and the replay classification of the pack error arms, plus the settledNote receipt arm
- [x] `docs/repos/wms-mobile/README.md` -- contract: `pack.execute` op; snapshot carries `packTasks`/`handlingUnits`

**Acceptance Criteria:**
- Given a fully-picked order in the snapshot, when the operator counts every SKU to its picked qty (0-dp SKUs by scan, CW SKUs by unit label, measured SKUs by typed qty), the queued `pack.execute` carries `scanned` with per-SKU quantities, `handlingUnitIds` only on CW lines, and settles to `ready_to_dispatch` with the pack receipt named in the sync summary
- Given an offline start with a pre-10-7 snapshot, the app opens with no Pack work shown and no crash; refreshing while online fills the Pack tab
- Given a second op for the same order (or a replay), the idempotency key re-serves the stored pack — nothing re-packs, and the summary names the outcome

## Review Triage Log

Verdicts rendered after all three layers (blind-hunter 15, edge-case-hunter 6, verification-gap 1 pre-verified + 2 observations) reported; every claim verified at its cited location. Carried duplicates noted.

- W1 blind-hunter B2 + B3 + verification-gap fractional + held from step-03: a fractional picked total wedges the bench — **high**. Verified: `outbound.facade.ts:567` rolls `pickedQty` up as `fromMilli(sum(picks.qty))` — base units, fractional for a measured SKU; `order.command.ts:312` accepts fractional line quantities and `pick.command.ts:768` allows a fractional pick on a non-CW measured SKU (CW SKUs are refused fractional picks, so only non-CW measured lines wedge); the bench counts by +1 scans (`draft.ts:188`) and `canCommit`'s exact match (`draft.ts:342-347`) can never hold against 2.5 — the order is permanently unpumpable from the device (the web pack DTO accepts fractional qty, so the wedge is device-only). The frozen block's assertion "a picked count is an integer" is factually wrong for measured SKUs. → **intent_gap** (root cause inside the frozen block; human renegotiates).
- W2 edge-case-hunter E6: the pack receipt never reaches the sync summary — **medium**. Verified: `settledNote` (`replay-classification.ts:56-57`) returns undefined for every op.type but `pick.record`; `engine.ts:99-110` pushes a settled summary entry only when the note is defined ("a clean settle says nothing beyond the count"); `PackRecordResponse` is consumed nowhere (`api.ts:500` is the only reference). AC-1's "settles to ready_to_dispatch with the pack receipt in the sync summary" is unmet — a packed order appears only as +1 in a settled count. Spec never specified the receipt's wiring. → **bad_spec**.
- W3 blind-hunter B7: pack cards carry no human-readable order identifier — **medium**. Verified: `CatalogPackTaskDto` carries only the orderId UUID, and the `orders` table itself has no code/number column (`schema.ts:1518`) — every surface shows UUIDs. Real everyday harm (two packable orders indistinguishable), but the gap is pre-existing table design, not this story's change; a code column is a schema addition this story does not own. → **defer**.
- W4 edge-case-hunter E5: two scans in one render frame compute from the same stale draft — **medium**. Verified: `onScanEvent` (`pack.tsx:114-156`) reads `draft` from the closure and `setDraft(decision.draft)` from that snapshot; a second scan before re-render overwrites the first — a lost count, caught only later by the commit blocker. → **patch**.
- W5 edge-case-hunter E1: explicit `null` `handlingUnitIds` → unhandled 500 — **medium**. Verified: `@IsOptional()` skips validation for null; the controller normalization (`outbound.controller.ts:646-648`) tests `!== undefined` then reads `.length` — `null.length` throws. → **patch** (`!= null`).
- W6 blind-hunter B1 (carries edge-case-hunter E2, whose quoted "controller throws packValidation(...)" does not exist in the handler — the silent-drop version is the true one): `DevicePackDto` inherits `dimensionsMm`, the OpenAPI advertises it, the controller silently drops it — **medium**. Verified: no refusal exists in `packOrderFromDevice`; a client sending dimensions gets a successful pack with the measurement discarded. → **patch** (strip the field from the device DTO).
- W7 blind-hunter B13: `autoCapitalize="characters"` on the manual-entry (and HID) inputs uppercases typed lowercase labels/barcodes so they can never resolve — **medium**. Verified at `pack.tsx:334,352`; manual entry is the fallback for a failed scan and fails 100% on lowercase ids (the seed data's own shape). → **patch** (`autoCapitalize="none"`; resolution stays exact).
- W8 verification-gap (pre-verified; carries blind-hunter B11): the pack-arm truncation ships with no test — **medium**. Filed with traced evidence: `MAX_SNAPSHOT_PACK_TASKS` referenced by no test, the boundary unreachable from every e2e suite, the pick sibling got a dedicated unit test for exactly this reason (`pick-truncation.spec.ts:5-10`), and a regression delivers a half-order the exact-match gate can never satisfy. → **patch** (extract, parameterize, unit-test the straddle/exact-ceiling/single-giant cases).
- W9 edge-case-hunter E4: "a single giant order is returned as it is" is false — **low**. Verified: `whole.length === 0 ? kept : whole` returns the first 500 rows — truncated, exactly the tested pick precedent ("truncated rather than empty", `pick-truncation.spec.ts:48`). The behavior is precedented; the comment misstates it. → **patch** (reword; fold into W8's extraction).
- W10 blind-hunter B6: the inbox Pack tab renders `catalog.packTasks` with no consumed filter — **low**. Verified (`inbox.tsx:495`): an order this device already queued stays tappable and dead-ends into the bench's no-work placeholder. → **patch** (apply the same consumed filter the pack screen uses).
- W11 blind-hunter B10: the device pack route's authority arms (malformed/missing Idempotency-Key 400, foreign-tenant 403, role-denied 403, `weightGrams: null` normalization) are exercised by no test — **low**. Verified by the verification-gap layer's tracing; the sibling pick route pins exactly these arms. → **patch** (add the arm tests).
- W12 blind-hunter B12: the parcel-weight cap mirrors `MAX_HANDLING_UNIT_WEIGHT_GRAMS` while the server's device-payload bound is the distinct `MAX_WEIGHT_GRAMS` (`pack.command.ts:70`) — **low**. Verified: two constants, equal value today, different meaning. → **patch** (device-side constant naming the server's parcel bound).
- W13 blind-hunter B14: weight-entry refusals give no feedback — **low**. Verified (`pack.tsx:181`): `if (parsed.kind === 'rejected') return;` — half-entries stay put by design, but a complete invalid entry ("0", over-cap) is silent, breaking the screen's announce-everything contract. → **patch** (announce complete-entry refusals).
- W14 blind-hunter B9: contradictory test comment/assertion — **low**. Verified (`pack-bench.spec.ts:578-580`): "still bench work" directly above `toHaveLength(0)`. → **patch** (reword).
- W15 blind-hunter B15: missing EOF newlines — **low**. Verified: `test/pack-bench.spec.ts`, `receiving.dto.ts` (wms-be), `draft.ts`, `draft.test.ts`, `pack.tsx` (wms-mobile) all end without a newline. → **patch**.
- R1 blind-hunter B4: "ONE tenant transaction" doc claim contradicts the shell's three sequential reads — **false**. The sentence sits on `getPackTasksInTx` (`outbound.facade.ts:501`) and scopes to that facade's own two reads; the controller comment documents the sequential composition explicitly, and pick tasks have composed this way since 4.3.
- R2 blind-hunter B5: `handlingUnits` uncapped — **low, rejected**. The uncapped choice is explicit, recorded with its rationale (a cap would refuse a real case label offline as unknown), and active-only self-prunes; a cap is the known-worse alternative the design already considered.
- R3 blind-hunter B8: `tenantId ?? ''` enqueues an op against `/tenants//…` — **false**. Confirm renders only when snapshot and draft both exist, both derive from the same cached snapshot, and `device-store` has no clear path (the cache is only ever replaced) — the fallback is unreachable.
- R4 edge-case-hunter E3: an order ending exactly on the ceiling is dropped — **false**. The straddle check compares row `MAX` against row `MAX-1`; a different order at `MAX` returns `kept` intact, which is exactly what happens.


### Round 2

Verdicts rendered after all three layers (blind-hunter 20, edge-case-hunter 10, verification-gap 3 pre-verified + 1 other) reported; every claim verified at its cited location. Round-1 rows checked first: four round-2 findings were carries of round-1 rows. No intent_gap or bad_spec — no loopback; patch round below.

- R2-1 blind-hunter + edge-case-hunter E9 (carried pair): `DevicePackDto`'s comment says a body carrying `dimensionsMm` "is stripped rather than silently accepted" while the whitelist pipe 400s it (pinned by e2e) — **low**. Comment contradicts the verified behavior. → patch (reword).
- R2-2 blind-hunter: `createOrder`'s comment claims the helper exists "so the authority arm can demote explicitly" — no demote test exists — **low**. Verified stale comment (`pack-bench.spec.ts:270-273`). → patch (reword).
- R2-3 blind-hunter: route arms 404 unknown orderId, role-denied 403, device-revoked 403, non-positive-weight 400, non-CW-unit-id 422 untested at the device route — **low**. Round-1 W11 pinned key/tenant/weightGrams-null; these remain. → patch (extend the arm test).
- R2-4 blind-hunter + verification-gap other (carried pair): a single order with >500 SKU rows is truncated by the ceiling, the bench commits the listed subset, and the server 422s the omitted SKUs — **low, rejected**. >500 distinct SKUs on one order is extraordinary; the failure is visible at replay (rejected, op dropped), and changing the tested pick-precedent contract (truncated-not-empty) is not a direct correction.
- R2-5 blind-hunter: the `skus` join is not tenant-scoped — **false**. The id-join is the repo precedent (`pick.command.ts:1622` joins skus by id only); the orders join carries the tenant filter because the query filters on orders' columns, and `skus.id` is a global PK.
- R2-6 blind-hunter: uncapped `handlingUnits` needs monitoring/telemetry — **carried, rejected** (round-1 R2: the uncapped choice is explicit and recorded).
- R2-7 blind-hunter: cross-arm point-in-time inconsistency deserves documentation — **carried, false** (round-1 R1: the sequential composition is documented at the composition site; the server re-verifies at replay).
- R2-8 blind-hunter + edge-case-hunter E10 (carried pair): `test/pack-truncation.spec.ts` ships without an EOF newline — **low**. → patch.
- R2-9 blind-hunter: `PackTaskList` reimplements `packOrderIdsOf` inline; the orderId unpack is duplicated across five sites — **low**. Verified (`inbox.tsx:525-529`). → patch (reuse the tested helper).
- R2-10 blind-hunter: the queued banner is set immediately before `router.back()` — never renders — **low**. Verified (`pack.tsx:368-370`). → patch (drop it; the inbox card carries the signal).
- R2-11 blind-hunter + edge-case-hunter E2 (carried pair): W4's functional-update fix covers only the scan path; `onMeasuredEntry`/`onWeightEntry` still build from the closure draft — **low**. Verified (`pack.tsx:231-250, 260-283`). → patch (route both through functional updates).
- R2-12 blind-hunter: an emptied measured box is coalesced to `'0'`, bypassing the model's `''` refusal a test pins — **low**. Verified (`pack.tsx:237`). → patch (pass `''` through; box restored from the draft).
- R2-13 blind-hunter: `-1` is a complete entry but the grammar classifies it half-typed → silent — **low**. Verified (`draft.ts:385-391`). → patch (admit an optional leading `-` and refuse it as complete).
- R2-14 blind-hunter: the settledNote fixture's `totalUnits: 3` contradicts its own lines (3 + 2.5); the server computes `totalUnits` as the sum of `packedQty` (`pack.command.ts:560`) — **low**. → patch (consistent fixture).
- R2-15 blind-hunter: zero screen-level tests — **low, rejected**. Repo-wide convention: no surface has screen tests (receive/putaway/pick likewise); adding RN component-testing infrastructure is not a direct correction.
- R2-16 blind-hunter + edge-case-hunter E6 (carried pair): a scan before a draft exists early-returns silently — **low**. Verified (`pack.tsx:169`). → patch (announce).
- R2-17 blind-hunter + edge-case-hunter E4 (carried pair): `tenantId ?? ''` — **carried, false** (round-1 R3: unreachable).
- R2-18 blind-hunter: the card's mixed-UoM "X units" headline (and a11y label) states a quantity no unit means — **low**. Verified (`inbox.tsx:561-568`); the comment concedes it. → patch (size-of-work phrasing).
- R2-19 blind-hunter: `MAX_PARCEL_WEIGHT_GRAMS`'s doc cites `pack.command.ts:70` — a line number that rots — **low**. → patch (cite the constant's name).
- R2-20 edge-case-hunter E1: `packReceiptNote` dereferences `pack.lines` unguarded — **low**. Verified: the guard checks `pack` but not `lines`/`totalUnits`; a malformed response throws inside the settle path. Server responses are typed, so everyday reachability is low. → patch (guard, say nothing).
- R2-21 edge-case-hunter E3: `enqueueOp` succeeding but `refreshConsumed` throwing renders "Queuing failed — try again" while the op IS queued; the retry queues a duplicate (new ULID → 409 at replay) — **medium**. Verified (`pack.tsx:359-364`): both awaits share one try. → patch (enqueue commits in its own step; a post-enqueue failure must not read as not-queued).
- R2-22 edge-case-hunter E5: abandoning and reopening shows a stale weight in the box — **false**. Both exits reset the state: the explicit button clears it (`pack.tsx:566-575`) and every other exit (`router.back()`, commit) unmounts the screen, so the next entry mounts fresh.
- R2-23 edge-case-hunter E7: a consumed-set load failure renders queued orders tappable until the next tab switch — **low**. Verified: the loader is `.catch(() => undefined)` with no retry (the reviewer's quoted retry guard does not exist); `catalogChecked` gates the tab but the consumed set does not gate the list. → patch (gate the list on the consumed set loading, like `catalogChecked` already does).
- R2-24 edge-case-hunter E8: `Promise.all` composition claim — **carried, false** (the quoted guard is fabricated; the actual composition is sequential, verified in round 1).
- R2-25 verification-gap (pre-verified): the per-SKU picked roll-up is tested only for single-order-line whole-qty orders; adding `orderLineId`/`batchId` to the groupBy would silently split a multi-line same-SKU order into two rows the bench can never reconcile — **medium**. Filed with traced evidence (the command's own query groups by `(orderLineId, skuId, batchId)`; the CW-SPLIT shape exists in exactly one test that never reads the snapshot). → patch (e2e: seed the two-order-line same-SKU shape, assert ONE consolidated row, pack through the device route).
- R2-26 verification-gap (pre-verified): `fetchApiPackOrder` is never executed by any test — the wire request (URL, method, headers, body) is verified against nothing — **low**. Filed with traced evidence (the sender is faked at the `OpSenders` seam; no test imports any real sender — repo-wide). → patch (fetch-stub unit test for this sender).
- R2-27 verification-gap (pre-verified): the parcel-bound mirror is pinned to nothing outside itself — no mechanism compares `MAX_PARCEL_WEIGHT_GRAMS` to the server's advertised bound — **defer** (filed disposition; same root cause as 10-6's deferred cross-repo drift guard).

**Patch round:** R2-1, R2-2, R2-3, R2-8, R2-9, R2-10, R2-11, R2-12, R2-13, R2-14, R2-16, R2-18, R2-19, R2-20, R2-21, R2-23, R2-25, R2-26.

## Design Notes

- **Why two additive snapshot arrays:** pack verification compares scans to *picked* quantities — the one dataset no device surface has today. Reusing the snapshot seal (AD-4) keeps the bench offline-capable like receive/putaway/pick, and `handlingUnits` (active-only, id + skuId) closes the 404/422 queue-and-die holes the same way `bins` closed the wrong-bin-scan hole. Active-only self-prunes: units flip to `packed` at pack, so the array is bounded by received-not-yet-packed stock.
- **The device route mirrors `picks`, not the tenant route:** `POST :tenantId/outbound/packs` with `DeviceSessionGuard`, orderId in the body — the tenant route keeps serving 4-2d's web surface later; both delegate to `PackCommandService.packOrder`, whose contract does not move.
- **The bench counts, it does not choose** — with the renegotiated exception (human decision 2026-09-19): 0-dp SKUs are scan-counted, CW SKUs label-counted, and measured non-CW lines carry a typed precision-aware qty. The typed arm is not "choosing" — the gate still demands exact equality with the snapshot's picked qty; only the input mode changes, because a +1 scan can never reach a fractional pick (the W1 wedge). The commit gate is exact-match everywhere. Partial packs are impossible server-side (the command is all-or-nothing), so the device must never queue a partial count.

## Spec Change Log

- **Patch round (post-triage, review round 2):** commits wms-be `3b27e74` + `76dd848`, wms-mobile `b9e0272` + `259cd78`. All 18 routed patch findings landed. Two went beyond their smallest ask and were verified by me: (1) pinning the documented `403 device-revoked` arm exposed a real fail-open — the pack command never re-authorized the device row (the guard verified the JWT only), so `packOrder` gained an optional `deviceId` re-authorization in-tx, verbatim the pick command's precedent (`pick.command.ts:391`); the tenant route omits it and its behavior is unchanged — the Code Map's "READ ONLY" for `pack.command.ts` is hereby amended by this entry. (2) The route's 422 annotation claimed the non-CW handling-unit arm, but `packValidation` throws 400 `validation-failed` for it — the device route's arm texts were corrected (422 text → 400 text) and openapi.json regenerated; the tenant route's annotations are untouched (frozen scope). Post-patch verification (mine): mobile `bun test` 257 pass / 0 fail (768 expects) + `bunx tsc --noEmit` clean; backend jest 34 suites / 604 tests green + tsc + eslint clean. Defers recorded in deferred-work.md (order-code column, cross-repo parcel-bound drift guard).
- **Loopback 1 (review W1, intent_gap; human decision 2026-09-19):** the frozen block's "a picked count is an integer" was false for measured SKUs (a 3-dp kg SKU picked 2.5 made the bench's exact-match gate unreachable — permanently unpumpable order). The human chose **typed entry for measured lines**: the frozen Always bullet and I/O Matrix now carry the typed-entry rule for measured non-CW SKUs (0-dp scan-counting and CW label-counting unchanged); the wedge row and measured-typed rows were added to the matrix; the measured-entry task was added. KEEP from round 1 (archive branches `archive/10-7-round1` in both repos — wms-be 13a6ada, wms-mobile b102e8f): the device route shape (badge-in, key, body-orderId, normalization spellings), the two additive snapshot arrays and their predicate/roll-up, the pack.execute op type and sender, the bench screen structure, the draft/payload null-vs-absent rule, and the round-1 test suite — all re-derived on top of these. Known-bad state avoided: shipping a bench whose commit gate is unreachable for any order containing a measured SKU. The bad_spec item (W2, receipt-in-summary) and the eleven verified patch findings are folded into the task list above so the re-derivation lands them.

## Verification

**Commands:**
- `bun test` (in wms-be and wms-mobile) -- expected: all green; new snapshot/pack-route tests in wms-be, draft/dispatch/snapshot tests in wms-mobile
- `bunx tsc --noEmit` (in wms-mobile) -- expected: clean
- CI on both PRs -- expected: green (wms-be drift guards run before the wms-mobile PR merges)
## Implementation Notes (round 2)

- Commits (local only): wms-be `507a23d`, wms-mobile `078d60c` on `feat/10-7-mobile-pack-bench`. Verification (mine, post-report): mobile `bun test` 256 pass / 0 fail (758 expects) + `bunx tsc --noEmit` clean; backend jest 34 suites / 602 tests green + `npx tsc --noEmit` + eslint clean.
- The `truncateToWholeGroups` extraction is a pure refactor — with the over-read at `MAX + 1`, the old inline `rows[rows.length - 1]` was already the row just past the ceiling; the subagent's "real defect fixed" claim was wrong, semantics unchanged (tests pin the same contract).
- `dimensionsMm` in a device body is now a 400 (`forbidNonWhitelisted`), not a silent drop — a wire tightening only the FE/4-2d surface could notice; the mobile client never sends it.
- Measured mismatch is accepted into the draft and named by the commit blocker (the gate, not the entry, refuses) — the matrix row was written to match.
