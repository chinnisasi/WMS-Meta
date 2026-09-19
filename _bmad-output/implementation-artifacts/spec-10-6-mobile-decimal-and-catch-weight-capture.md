---
title: 'Story 10-6: Mobile decimal and catch-weight capture'
type: 'feature'
created: '2026-09-19'
status: 'done'
route: 'dispatch'
review_loop_iteration: 0
baseline_commit: '6b7af99'
context:
  - '_bmad-output/implementation-artifacts/epic-10-context.md'
  - 'docs/design/mobile/SYSTEM-DESIGN.md'
  - 'docs/design/mobile/IMPLEMENTATION-GUIDE.md'
  - 'docs/design/PENDING.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** The backend accepts fractional quantities (10-1/10-2) and catch-weight receipts carrying per-unit weights (10-3), but the device cannot produce either: every quantity path is integer-only (`parseInt`, `Math.floor`, digits-only regex, `Number.isInteger`), the cached `CatalogSku` lacks `uomPrecision` and `catchWeightTracked`, and there is no weight prompt. A 2.5 kg receive is impossible; a too-precise value would queue and die on replay; a catch-weight SKU cannot be received at all (its `weightsGrams` would be missing → server 400 → visible retraction). PENDING also holds a verified zero-scan-loss defect this story's paths touch: a scan enqueued during an in-flight replay is deleted unsent, silently.

**Approach:** Consume `uomPrecision` + `catchWeightTracked` off the catalog snapshot (additive-safe parse), make every quantity path precision-aware against the drafted line's SKU, mirror the server's precision refusal (Rejected banner, typed entry; scale readings round with both values shown), capture per-unit catch weights at receive — whole grams on the wire, kg at 3 dp on screen, distinct from quantity in the accessible name, surviving banner swaps and backgrounding — and fold in the replay single-flight fix. Mobile-only; the backend contract is finished and untouched.

## Boundaries & Constraints

**Always:**
- Never round a typed entry: finer than declared precision is refused inline, naming the unit and its precision, mirroring the server's message ("one story, not two" — mobile guide §6). Scale/meter readings round with both values shown.
- 0-dp units keep today's integer behavior exactly (stepper, `+1` scan-increment, integer clamps) — only measured units change.
- Catch-weight line: `qty` = number of physical units, `weightsGrams` = exactly that many whole-gram entries, always present in the payload; non-catch-weight lines omit `weightsGrams` entirely (absent, not null — null-vs-absent is load-bearing).
- Weights live in the line draft (same persistence as qty) so they survive banner swaps, suspension and backgrounding.
- Additive snapshot parsing: a snapshot without the new fields parses with defaults (`uomPrecision: 0`, `catchWeightTracked: false`).

**Never:**
- No pack bench screen (deferred by decision 2026-09-19 — 10-6 ships decimal + catch-weight capture; the mobile pack surface gets its own sprint-status story, `10-7`), no new outbox task type, no backend changes, no `expo-haptics` dependency (announcements per existing a11y pattern only), no connectivity detection (separate PENDING item).

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Typed decimal, measured SKU | "2.5" on a 3-dp kg SKU | Accepted, queued with qty 2.5 | N/A |
| Typed too-precise | "2.5001" on a 3-dp SKU | Inline refusal naming "kilograms, 3 decimal places" (server's copy); nothing queued | Refusal announced same as state |
| Typed decimal on each-SKU | "2.5" on a 0-dp SKU | Inline refusal: whole units only; stepper/scan-increment unchanged | Same announcement rule |
| Scale reading finer than grams | 18456.7 g reading | Rounds to 18457 g; both shown: "Scale: 18.4567 → recorded 18.457 kg" | N/A |
| Catch-weight confirm incomplete | 3 units, 2 weights | Confirm blocked until weights count == qty | Progress copy names the gap |
| Weight over cap | 1,234,567 g | Refused inline (mirrors server MAX_HANDLING_UNIT_WEIGHT_GRAMS) | Announced |
| Order-of-magnitude weight | 180 g when first captured weight for the SKU is 18,000 g | Explicit confirm required before accept | Distinct press, not silent |
| Old snapshot | Payload lacks new fields | Parses with 0 / false defaults | N/A |
| Enqueue during replay | Scan arrives mid-`replay()` | Op appended after replay completes, replayed next pass — never deleted | N/A |

</frozen-after-approval>

## Code Map

- `app/receive.tsx` -- manual qty entry (parseInt :514), `setQty` clamp (Math.floor + MAX_LINE_QTY :234-240), `commitOpenLine` :222, `onConfirm` :247; the decimal + weight-capture surface
- `app/putaway.tsx` -- stepper :357-380, manual parseInt :395; precision-aware qty
- `app/pick.tsx` -- short-pick arm :543-594, digits-only sanitizer :303-307; precision-aware short qty
- `src/receiving/draft.ts` -- `applyScanToDraft` (qty+1 :128), `confirmPayload` :310-326; weights join the draft here
- `src/putaway/draft.ts` -- `setQty` Math.floor :135-138; `src/picking/draft.ts` -- `setShortQty` `Number.isInteger` :340-344
- `src/api.ts` -- `CatalogSku` :464-472 (+`uomPrecision`, `catchWeightTracked`), `GrnLineInput`/`GoodsReceiptPayload` :167-183 (+`weightsGrams`)
- `src/state/catalog-snapshot.ts` -- `parseCatalogSnapshot` :13-25; additive defaults
- `src/state/device-store.ts` -- `enqueueOp` :216-230, `replay` -- single-flight fix lives here
- `src/offline/engine.ts` -- `replayOutbox` :81; `src/state/op-dispatch.ts` -- `sendOp` :58-95 (touch only if dispatch must await replay)
- New `src/lib/quantity-input.ts` -- precision-aware parse + refusal copy (mirrors server), weight parse/round helpers
- Tests co-located `*.test.ts` (143 passing today); `docs/repos/wms-mobile/README.md` -- interface contract update

## Tasks & Acceptance

**Execution:**
- [x] `src/api.ts` + `src/state/catalog-snapshot.ts` -- add `uomPrecision`/`catchWeightTracked` to `CatalogSku` with additive parse defaults -- the device can only validate entry against data in the snapshot (guide §4)
- [x] `src/lib/quantity-input.ts` (new) -- precision-aware parse (0-dp digit grammar unchanged; >0-dp decimal grammar capped at declared dp) + refusal copy byte-mirroring the server's precision message + weight parse (whole grams, >0, ≤ cap) + scale-round helper -- one statement, unit-tested, like wms-fe's `format-quantity.ts`
- [x] `app/receive.tsx` + `src/receiving/draft.ts` -- measured SKUs render decimal entry (48dp keys, oversized `.` and `0`, real text input); `setQty` loses Math.floor for >0-dp units; catch-weight flow prompts weight after scan (accessible name "Catch weight, kilograms, three decimal places" distinct from quantity), weights persist in the draft, confirm gates on weights count == qty, payload carries `weightsGrams` (absent on non-catch-weight lines) -- the story's namesake
- [x] `app/putaway.tsx` + `src/putaway/draft.ts`, `app/pick.tsx` + `src/picking/draft.ts` -- precision-aware qty/short-qty parse and copy, driven by the line's SKU -- every quantity path honors precision (guide §6)
- [x] `src/state/device-store.ts` -- single-flight on `replay()` (concurrent calls await the same in-flight pass; `enqueueOp` during it appends after, never deleted) -- PENDING's verified zero-scan-loss defect, fix already diagnosed
- [x] Tests -- unit-test the matrix rows (precision refusals, weight cap, magnitude confirm, snapshot defaults, replay single-flight) and update existing draft tests
- [x] `docs/repos/wms-mobile/README.md` -- contract: snapshot carries `uomPrecision`/`catchWeightTracked`; `grn.submit` payload carries `weightsGrams`

**Acceptance Criteria:**
- Given a 3-dp kg SKU, when the operator types 2.5, the queued `grn.submit` carries 2.5 and the banner shows the accepted/queued state
- Given a catch-weight SKU, when the operator scans 3 units and captures 3 weights, the payload carries `qty: 3` and `weightsGrams: [g1, g2, g3]`; when a weight is 10× off the first captured weight, a confirm press is required first
- Given offline start with a pre-10-6 snapshot cached, when a SKU is scanned, entry behaves as whole-unit (defaults) without crashing
- Given an in-flight replay, when a scan is enqueued, it survives and replays

## Implementation Notes

- **Verification caveat:** `bun run lint` has no script in wms-mobile's `package.json` (scripts: start / android / ios / typecheck / test; `.github/workflows/ci.yml` runs test + typecheck only, no lint config in the repo). Reported honestly rather than claimed: typecheck and tests are the repo's only automated gates.
- **Draft-line `weightsGrams` is key-present-with-undefined on non-catch-weight lines in memory** (built as a spread with `undefined`); the load-bearing absence is on the WIRE — `confirmPayload` builds the payload line with a spread conditional, so the JSON never carries the key, asserted by `'weightsGrams' in line` === false and by `JSON.stringify(payload)` not containing the key. Draft-level tests assert `weightsGrams === undefined` instead of key absence (the draft is React state, never serialized).
- **The 10× guard's reference is the first captured weight for the SKU across the WHOLE receipt** (`firstCapturedWeightForSku` walks all draft lines of the same skuId), so batch-split lines of one SKU guard each other; a different SKU carries no reference and never fires the guard.
- **The vanish arm** (`Math.round(value * 1000) === 0` refusal) is unreachable via typed entry on a 3-dp unit (the precision arm catches 4-place values first); it guards coarser-declared units (e.g. a 5-dp unit taking 0.00004). Tested at precision 5.
- **Keypad scope:** the decimal keypad rides only the fields the spec names — receive quantity, catch weight, scale reading, plus putaway's Set field and pick's short-pick entry (precision-driven). Steppers stay ±1 integer everywhere; scan-increment stays +1 for all units.
- **Pick screen restore-on-reject** (`onShortQty` resetting the field from the draft on refusal) now formats through `formatQuantity` so the restored text matches the declared precision.
- Commits (local only, on `feat/10-6-mobile-decimal-and-catch-weight-capture`): 7698b51 (model + lib + tests), 23ef220 (replay single-flight), cdfda78 (screen surfaces). `bun test` 203 passing (baseline 143), `bunx tsc --noEmit` clean.

## Spec Change Log

- **Fix round (post-triage):** all 13 patch items landed as commit `f46787f` on wms-mobile — 10× confirm flow rebuilt (entry held until the model settles, confirm routes to the row that raised the hold via `pendingWeightSource`, hold survives an unrelated refusal, amber "Confirm the weight" banner instead of the rejected state), catch-weight lines refuse fractional quantities (`catchWeightQtyRefusal` + `withLineQty` backstop), the replay race fully closed (`registerAppend` — synchronous registration, pass drains pre-registered appends, mid-pass registrations chain behind the pass), snapshot pass-through pinned by equality, shared `catchWeightBlocker` copy, one shape-refusal wording, weight fields sanitized, structural timing assertion, three comment fixes. Post-patch: 207 pass / 0 fail, `tsc --noEmit` clean. Nothing routed to intent_gap or bad_spec — no loopback; defers recorded in deferred-work.md.

## Review Triage Log

## Review Triage Log

Verdicts rendered after all three layers (blind-hunter 18, edge-case-hunter 7, verification-gap 6) reported; every claim verified at its cited location. Cross-layer duplicates marked `carried` — same location and claim, verified once.

- B1 blind-hunter: legacy pre-10-6 draft restored post-upgrade takes the measured path (`uomPrecision === undefined`) — **false**. A receive draft is React state only; nothing persists it (no AsyncStorage/persist anywhere in `app/receive.tsx` / `src/receiving/draft.ts`), so a draft never crosses an app upgrade. The undefined-precision path is unreachable.
- B2 blind-hunter: fractional qty on a catch-weight line wedges the draft — **medium**. Server allows CW+measured SKUs (only serial+CW is refused at catalog entry) and refuses non-integer qty on a CW GRN line (`receiving.command.ts`), but the device admits 2.5 on a CW line and `catchWeightComplete` (weights == qty) can then never hold — confirm permanently disabled. → patch
- B3 blind-hunter: 10× confirm reachable only through the typed row's button — **medium**. Scale entry is cleared before the model decision, the scale button disables while empty, and `onPress={pending ? onConfirmPending : onRecordTyped}` is wired only to the typed row; the banner copy points at a dead button. → patch
- B4 blind-hunter: the confirm hold renders in the red rejected banner state — **low**. Real presentation mismatch; the copy and the button flip carry the meaning, the color contradicts it. → patch
- B5 blind-hunter: `confirmPendingWeight` leaves `weightKgEntry` stale — **low**. Real; a wedge/keystroke appends to the stale text. → patch
- B6 blind-hunter: weight entries cleared before the model decision — **medium**. A model refusal or confirm-hold erases what the operator typed, violating the screen's own no-clear-on-refuse contract stated one function over. → patch
- B7 blind-hunter: typed weight fields skip the as-typed sanitizer — **low**. Junk types freely and fails only at press. → patch
- B8 blind-hunter: task/PO quantities render raw in sentences that format the draw/received quantity — **low**. Mixed formatting in one sentence. → patch (grouped with E7)
- B9 blind-hunter: `uomDisplayName` omits 'pcs' — **false**. The server stores canonical units; 'pcs' is a catalog-entry alias resolved to 'each' (`wms-be uom.ts:449`), so a stored SKU's `uom` is always in the map and the raw-symbol fallback never fires on real catalog data.
- B10 blind-hunter: byte-mirror literals pinned device-side only; test comment claims "either side" — **low** (the comment overstates; fix is a reword) → patch; the missing cross-repo drift guard itself → defer
- B11 blind-hunter: `setShortQty` fractional arm omits the vanish arm — **false**. The vocabulary caps precision at 3 (10-2), so a 5-dp unit cannot exist; the precision arm already refuses every value the vanish arm would. The inconsistency is unreachable.
- B12 blind-hunter: single-flight wiring untested at store level — **defer** (same as V2).
- B13 blind-hunter: gate narrows but does not close the race — **medium**. Verified: between `settled()` resolving and `appendOp` committing, a new pass can start (gate open), `listOps` before the append commits, and `replaceOps(remaining)` erases the op. → patch
- B14 blind-hunter: concurrent replay callers share a rejecting promise → unhandled rejections — **false**. `replayOutbox` never rejects on op failures (every send result is classified into an outcome kind; it returns a summary), and storage-level rejections behaved the same per-caller before the gate.
- B15 blind-hunter: wall-clock timing assertion (<50ms) in replay-gate.test — **low**. Real, test-only flake risk. → patch
- B16 blind-hunter: `ReceiveDraftLine.qty` comment still says "(integer, base UoM)" — **low**. Stale doc contradicts measured lines. → patch
- B17 blind-hunter: `recordWeight` (grams wording) vs `parseWeightEntry` (kg wording) — two wordings for one refusal category — **low**. → patch
- B18 blind-hunter: `formatQuantity(2.5, 0)` silently rounds; toLocaleString on Hermes — **maybe-false → rejected**. The rounding arm is unreachable (every 0-precision write floors first); the Intl/Hermes concern, if true, is cosmetic grouping loss — low, not everyday, fix not a direct correction. Would settle with a device run on the app's RN runtime.
- E1 edge-case: a refused later weight erases the held pending weight (`setPendingWeightGrams(null)` unconditional in the rejected arm) — **medium**. Same clear-before-decision root as B6. → patch
- E2 edge-case: scale arm cannot confirm its own held weight — carried (same location and claim as B3; verified once).
- E3 edge-case: catch-weight SKU in a fractional unit wedges the device — carried (same claim as B2, adds the server-side citations).
- E4 edge-case: `confirmBlocker` missing surplus arm → closed confirm with empty why-text — **false**. Surplus weights (captured > qty) are unreachable through the model's flows: `recordWeight` refuses capture at capacity and `withLineQty` truncates on shrink; the surplus `canConfirm` test constructs the draft by hand. Code failing loudly on an unreachable state is correct.
- E5 edge-case: replay pass starting between `settled()` and append commit erases the op — carried (same claim as B13).
- E6 edge-case: queued banner reports the typed (pre-clamp) value while the draft holds the clamped one — **low**. Only when the int4 clamp engages. → patch
- E7 edge-case: pick banner/confirm labels render the task qty raw beside the formatted draw — carried (same claim as B8).
- V1 verification-gap (pre-verified): current-seal per-SKU `uomPrecision`/`catchWeightTracked` pass-through is unpinned — only the default arm is; mutation demonstrated (hardcode 0 → suite green). → patch
- V2 verification-gap (pre-verified): the single-flight wiring in `device-store.ts` has no test that would fail if dropped — the module is unreachable from the suite (expo-secure-store import); closing it means making the store testable first, its own change. → defer
- V3 verification-gap (pre-verified): server-mirrored literals observed by no mechanism in either repo; the test comment claims a guard that does not exist — comment fix → patch; the cross-repo drift guard → defer
- V4 verification-gap other: 10× confirm via wrong button — carried (same claim as B3).
- V5 verification-gap other: fractional CW wedge — carried (same claim as B2).
- V6 verification-gap other: the open-line commit gate re-states `confirmBlocker`'s copy byte-for-byte (receive.tsx vs draft.ts) — **low**. Developer-facing: a future wording change diverges unobserved. → patch
## Design Notes

- **Scan-increment stays +1 for all units** (one base unit per scan; the manual field carries fractions) — no behavior change on the scan path, decimals arrive only via entry.
- **Order-of-magnitude guard:** no nominal-weight field exists in the snapshot, so the 10× guard compares each weight against the first weight already captured for that SKU in the same receipt — self-consistency is the implementable stand-in; a 10× deviation needs an explicit confirm press.
- **Weight display:** kg at 3 dp on screen, whole grams on the wire — same convention as quantities (declared precision, never storage precision).
- **Cap constants** (`MAX_HANDLING_UNIT_WEIGHT_GRAMS` = 1,000,000) are mirrored device-side with comments naming the server constant — the device must refuse what the server would 400, offline, before it queues.

## Verification

**Commands:**
- `bun test` (in wms-mobile) -- expected: all green, new tests cover the matrix
- `bunx tsc --noEmit` -- expected: clean
- `bun run lint` -- expected: clean