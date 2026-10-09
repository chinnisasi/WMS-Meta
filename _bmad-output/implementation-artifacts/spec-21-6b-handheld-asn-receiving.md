---
title: 'Handheld ASN receiving: the device receives against an advance shipment notice the way it receives against a PO'
type: 'feature'
created: '2026-10-09'
status: 'done'
route: 'dispatch'
baseline_commit: '7f8aa2dd532990dc43cfd2fac0a50c97ce495ca8'
review_loop_iteration: 0
context:
  - '_bmad-output/implementation-artifacts/epic-21-context.md'
  - '_bmad-output/specs/spec-3pl/SPEC.md'
  - '_bmad-output/specs/spec-3pl/schema.md'
  - '_bmad-output/implementation-artifacts/spec-21-6-advance-shipment-notices.md'
  - 'docs/design/SYSTEM-DESIGN.md'
  - 'docs/design/IMPLEMENTATION-GUIDE.md'
  - 'docs/design/modules/inbound.md'
  - 'docs/design/mobile/SYSTEM-DESIGN.md'
  - 'docs/design/mobile/IMPLEMENTATION-GUIDE.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** Since 21-6, the server takes a receipt against an ASN, and the catalog snapshot carries `openAsns[]`. The handheld ignores both, so an announced shipment can be received only through the raw device API. The web ASN card tells operators "Receiving against ASNs arrives with the next handheld update" (21-6 decision 1).

**Approach:** The work is in **wms-mobile**, plus one line of wms-fe copy that retires the notice. There is no backend change and no new op type. The receive draft gains a third context, an ASN, beside PO and blind.
- The device parses `openAsns[]` and lists open ASNs in the inbox Receive tab and in the receive screen's choose step.
- A scan resolves to the ASN line the same way it resolves to a PO line.
- Progress and excess use the same maths as for a PO.
- Confirm queues the existing `grn.submit` op carrying `asnId` and `asnLineId`.

## Boundaries & Constraints

**Always:**
- **Snapshot.** `CatalogSnapshot.openAsns: CatalogAsn[]`, typed `{id, code, clientId, warehouseId, expectedAt: string|null, lines[{id, skuId, announcedQty, receivedQty, openQty}]}`. Quantities are in base units, as the server sends them. `parseCatalogSnapshot` defaults `openAsns` to `?? []`, and the legacy-seal test pins it by equality.
- **Draft.**
  - `ReceiveDraft` gains `asnId: string | null`, and each line gains `asnLineId: string | null`.
  - A pure `draftContextSet(draft)` (PO, ASN or blind reason set) replaces the screen's `contextSet` (`receive.tsx:233,751`).
  - At most one context is set. `chooseAsn` clears `poId` and the blind reason, and `choosePo` and `chooseBlindReceive` clear `asnId`.
  - Every `choose*` **re-resolves each existing line's document reference** against the new context, so no stale line id survives a switch.
  - A scan resolves the line by the PO rule, generalised to the active document: same SKU, preferring a line with `openQty > 0`.
- **Payload: hash-safe and replay-safe.** `confirmPayload` builds each line's references **from the active context**, never by copying them from the line:
  - **ASN op:** `{warehouseId, poId: null, asnId, blindReasonCode: null, occurredAt, lines[{poLineId: null, asnLineId: <id|null>, skuId, batchCode, mfgDate, qty, weightsGrams?}]}`. Every line carries `asnLineId` explicitly. `poLineId: null` is required, because the server hashes `poLineId` exactly as sent.
  - **PO and blind ops** carry **no `asnId` key and no `asnLineId` key**. A blind line always sends `poLineId: null`. This keeps them byte-identical to the payload a pre-21-6b build seals, and a test pins a PO payload and a blind payload by `toEqual` and asserts the keys are absent.
  - Dropping the keys is a documented exception to the guide's "send null explicitly" rule. The server folds these two keys with `?? undefined`, so absent and null hash the same.
- **Progress.** One document-generic path, `documentProgress`, returns `{kind:'po'|'asn', code, …}` and serves both documents.
  - **Clamping:** every cached `openQty` is clamped to `≥ 0` before any maths. This applies per line in `openQtyProgress` and in the header, whose open quantity is Σ over lines of `max(0, openQty)`. An approved over-receipt makes `openQty` negative (21-6). The clamp fixes the PO arm too.
  - **Unmatched lines** (those with no document reference) count neither as excess nor as progress, and are reported as `unmatchedQty`.
  - **The header string** is a pure helper, pinned by tests, and the same for both documents: `Scanned {matched} of {open} open.` followed by `{short} short — record a partial.` and `Over by {excess} — the excess needs approval.` when they apply. Every number goes through `formatQuantity`.
  - **The confirm label** comes from a pure `confirmLabel(progress)`: "Record partial GRN" when short, else "Confirm GRN".
- **Unmatched advisory.** When a scanned SKU is not on the active PO or ASN, the line's entry label shows `Not on {code} — will be booked; no {PO|ASN} line credited`.
  - It is shown on the line, so the next banner cannot overwrite it.
  - It is advisory only, with no refusal: the server's unmatched arm applies the line in full.
  - It appears on PO receipts as well (new behaviour).
  - Its text comes from a pure, tested helper.
- **Cards and copy are pure helpers, tested byte for byte.**
  - The ASN card reads `{code}` · `{n} lines · {k} open` · `expected {date}`, where the date is formatted `YYYY-MM-DD` in UTC and the part is omitted when the date is null. The card shows line counts only, never summed quantities.
  - The accessibility label is `Receive against {code}, {n} lines, {k} open`.
  - Choose step title: "Pick a purchase order or an ASN".
  - Blind-step title: "Why is there no purchase order or ASN".
  - Default banner and blocker: "Pick a purchase order or an ASN, or start a blind receive".
  - Refresh banner: "… open POs, … open ASNs".
  - Empty list: "No open purchase orders or ASNs in the cache".
- **Route.** The precedence is `asnId`, then `poId`, then `blind`, and only a cached document id preselects. The route param type gains `asnId`.
- **Replay fates.** Explicit branches in `classifyReplayFailure` return `rejected` for `asn-not-open` and `document-warehouse-mismatch` (the 5-6 "by name" precedent), each with a test. Their fate is unchanged.
- **Settled note.** `settledNote` gains a `grn.submit` arm. **It returns a note only when the receipt has unmatched lines, rejected lines, or a line with `excessQty > 0`.** A clean receipt has no note, as today.
  - The note reads `{grnCode} recorded against {asnCode | "the purchase order"}`, followed by:
    - `{n} line(s) booked without crediting the {ASN|PO}`
    - `{n} line(s) refused ({codes, deduplicated}) — not booked`
    - `{n} line(s) held for approval`
  - Every count is a line count. A malformed response yields no note.
- **Types.** On `GoodsReceiptResponse.goodsReceipt`, the receipt gains `asnId?`, `asnCode?` and `unmatchedLines?: {index, reason}[]`, and `rejectedLines` becomes optional. `GrnLineResponse` and `GrnRejectedLine` each gain `asnLineId?`.
- **wms-fe.** Remove `ASN_HANDHELD_NOTICE` (`src/lib/asns.ts:35`) and its render, and update the two tests that pin it. This is merged **after** the mobile PR.

**Never:**
- backend changes;
- showing the client on the floor (it stays client-agnostic);
- scanning an ASN code;
- linking an ASN to a PO;
- a new op type or endpoint;
- changing the hash of PO or blind ops;
- an on-device refusal of an unmatched scan;
- passing the snapshot into `settledNote`.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected | Error |
|---|---|---|---|
| Inbox | 1 PO and 2 ASNs cached | Receive and All tabs show PO cards, then ASN cards, then Blind | — |
| Route in | `/receive?asnId=X` | X cached: draft on ASN X at the scan step; otherwise the choose step | — |
| Partial and excess | ASN line 100 announced, 40 received; scan 70 | "Scanned 70 of 60 open. Over by 10 — the excess needs approval." | — |
| Approved over | Line A `openQty` −5, line B 10; scan 4 of B | Open 10, 6 short, "Record partial GRN" (PO likewise) | — |
| Unlisted SKU | Scan a SKU not on the ASN | `asnLineId: null`, label `Not on ASN-001 — …`, not excess | — |
| Switch context | Lines scanned against a PO, then `chooseAsn` | Line references re-resolved; payload carries no `poLineId` | — |
| Old seal | No `openAsns` | No ASN cards, no crash | — |
| PO and blind ops | Confirm | No ASN keys; equal to the pre-21-6b shape | — |
| Closed while queued | 409 `asn-not-open` | `rejected`: dropped and listed in the sync report | — |
| Settles clean | No unmatched, rejected or excess lines | No note | — |
| Settles mixed | 1 unmatched, 1 excess | "GRN-… recorded against ASN-001 — 1 line(s) booked without crediting the ASN; 1 line(s) held for approval" | — |

</frozen-after-approval>

## Code Map

The mobile references are to `7f8aa2dd`.
- **`src/api.ts`**:
  - `GrnLineInput` `:213`, `GoodsReceiptPayload` `:232`, `GrnLineResponse` `:242`, `GrnRejectedLine` `:252` and `GoodsReceiptResponse` `:261`;
  - `CatalogPoLine` and `CatalogPurchaseOrder` `:851-866` (add `CatalogAsnLine` and `CatalogAsn` after them);
  - `CatalogSnapshot` `:1054`.
- **`src/state/catalog-snapshot.ts:15`** gets the `openAsns` default. The legacy-seal arms are in `src/state/device-store.test.ts:22-80`.
- **`src/receiving/draft.ts`**:
  - `ReceiveDraft`, `createDraft`, `choosePo` and `chooseBlindReceive` `:72-92`;
  - `canConfirm` `:105` and `confirmBlocker` `:394`;
  - `applyScanToDraft` `:161` (the increment keeps `line.poLineId ?? …` at `:174`; generalise it) and `resolvePoLineId` `:219`;
  - `openQtyProgress` `:428`, `poProgress` and `progressCopy` `:477-503`, and `findPo` `:505`;
  - `confirmPayload` `:527`.
  - Tests: `draft.test.ts`.
- **`app/receive.tsx`**:
  - the route param type `:74`, init `:101-124`, and the refresh banner `:139`;
  - `onScanEvent` `:150`, `contextSet` and `step` `:233-240`, and the open-line document lookup `:246-249`;
  - the default banner `:436`, the header `:441-457`, the choose step `:458-484`, the blind title `:488`, the line label `:590`, and the confirm label and blocker `:751-766`;
  - `PoCard` `:810`.
- **`app/inbox.tsx`**: the empty-cache copy `:366`, `ReceiveTaskList` `:378-397` and `ReceiveTaskCard` `:401`. Add `AsnTaskCard`.
- **`src/state/replay-classification.ts`**: the named rejected arms go beside `kit-cannot-hold-stock` `:55`, and `settledNote` is at `:136` (called from `device-store.ts:346`). Tests: `replay-classification.test.ts:413`.
- **`src/lib/quantity-input.ts`**: `formatQuantity` and `decimalPlaces`.
- **wms-fe**: `src/lib/asns.ts:35` and its render site, `asns.test.ts:38`, `asn-card.test.tsx:205`.
- **Server facts (verified, read-only):**
  - The hash folds `asnId` and `asnLineId` with `?? undefined` and hashes `poLineId` raw (`receiving.command.ts:341,346`).
  - The controller maps absent to null (`:115,120`), and the DTO validates both keys as `@IsOptional() @IsUUID()`.
  - A non-null `poLineId` on an ASN receipt answers 400 (`:459-472`).
  - The line arms are at `:687-714`, the ceiling is `max(0, min(qty, remaining))` at `:730`, and empty `rejectedLines` and `unmatchedLines` are omitted.
  - The snapshot carries only `announced` and `partially_received` ASNs, in base units.
  - The sync-report rebuild passes `asnId` and the raw lines (`sync-report.command.ts:1136`).

## Tasks & Acceptance

**Execution:**
- [x] `wms-mobile src/api.ts` -- the types per Boundaries.
- [x] `wms-mobile src/state/catalog-snapshot.ts` and `device-store.test.ts` -- the `openAsns` default and the legacy-seal pin.
- [x] `wms-mobile src/receiving/draft.ts` and `draft.test.ts` -- covers:
  - `chooseAsn`, `draftContextSet`, re-resolution on switching, and generic line resolution;
  - `documentProgress` with the clamps and `unmatchedQty`, the header and `confirmLabel` helpers, and the unmatched-label helper;
  - card and copy helpers, and payload building from the context;
  - tests for every matrix row at the pure layer.
- [x] `wms-mobile app/receive.tsx` -- wire the helpers. The screen composes no copy itself.
- [x] `wms-mobile app/inbox.tsx` -- `AsnTaskCard` and the copy.
- [x] `wms-mobile src/state/replay-classification.ts` and its test -- the named arms, the settled note's arms (including "clean receipt gives no note"), and a malformed response.
- [x] `wms-fe` -- remove the notice and update its two tests. Separate branch and PR, merged after mobile.
- [x] Meta docs:
  - `mobile/SYSTEM-DESIGN.md`: the `/receive` row, the `openAsns` row `:176` (now parsed), and the fate block;
  - `mobile/IMPLEMENTATION-GUIDE.md`: the absent-key exception, and the snapshot-growth count at `:142`;
  - `API-SURFACE.md:104`;
  - `docs/repos/wms-mobile/README.md` and `docs/repos/wms-fe/README.md`;
  - `PENDING.md`: close inbound :52, and add:
    - mixed-unit sums on the PO header and cards;
    - a refused line of a settled GRN reaches no review queue;
    - a fully `received` ASN is off the snapshot, so a late carton goes blind or unmatched on the handheld;
  - the 21-6b entry in `deferred-work.md` marked done, and sprint-status `21-6b` set to done.

**Acceptance Criteria:**
- Given a snapshot with an ASN line of 100 announced and 40 received, when the draft chooses that ASN, scans 60 and confirms, then the pure layer yields exactly one `grn.submit` payload with `asnId`, that line's `asnLineId`, `poLineId: null` and no blind reason.
- Given a local backend, when a handheld receives 60 against a 100-unit ASN, then the ASN reads `partially_received` (manual check).
- Given `bun run typecheck && bun test` (wms-mobile) and the wms-fe suite, when run, then they pass.

## Implementation Notes

Baselines: wms-mobile `7f8aa2dd532990dc43cfd2fac0a50c97ce495ca8` (`baseline_commit`), wms-fe `b92a42095c1f74c3b4ce721bfa848e329e0fc1c1`. Work on `feat/21-6b-handheld-asn-receiving`, already checked out in both repos, and leave everything uncommitted: no commit, push or PR. Edit meta docs in `/Users/sasidhar/Documents/WMS-Meta` (leave the meta git state alone). Do not touch wms-be. Use bun only. Do not touch `/tmp` outside your own scratch files.

## Spec Change Log

## Review Triage Log

*Design review, 2026-10-09: two code-verified reviewers (correctness of offline, replay and payload; fit, UX, tests and docs). 25 findings, merged into 17. All were settled by the agent and folded in; none went to the human.*

| # | Sev | Finding | Disposition |
|---|---|---|---|
| D1 | high | `contextSet` and `step` (`receive.tsx:233`) ignore an ASN, so the screen stays on the choose step | Pure `draftContextSet`; Code Map names it |
| D2 | high | The settled note cannot know the PO code: no snapshot, and the response has none | Generic "the purchase order"; snapshot not passed |
| D3 | med | Stale or mismatched line references can reach the payload, and a 400 then drops the whole GRN | References built from the context; `choose*` re-resolves; switch test |
| D4 | med | Header open quantity is Σordered − Σreceived, unclamped, so a short is hidden behind an over | Per-line clamp in the header; `confirmLabel` helper |
| D5 | med | Header counts unmatched units as excess, contradicting the advisory | Unmatched lines are excluded and reported as `unmatchedQty` |
| D6 | med | The matrix's header string contradicted `progressCopy` | Exact string specified and pinned |
| D7 | med | Fractional ASN quantities would show float dust and mixed-unit sums | Line counts on cards; `formatQuantity` for numbers; PENDING |
| D8 | med | Screen-only strings would go untested (no render harness) | Every string becomes a pure helper, pinned byte for byte |
| D9 | med | The advisory claimed "is booked" before settlement, and the next banner overwrote it | "will be booked", shown on the line label |
| D10 | med | Whether a clean receipt gets a note was implicit (a side effect on PO receipts) | Note only when lines are unmatched, refused or in excess |
| D11 | med | The acceptance criterion "server books it" is untestable in wms-mobile | Pure-layer criterion plus a manual check |
| D12 | med | The web notice goes false once this ships | wms-fe removal in scope, merged after mobile |
| D13 | med | The docs list was incomplete (API-SURFACE, sprint-status, deferred-work, guide count, stale row) | Added |
| D14 | low | Response fields sat on the wrong object; `GrnLineResponse.asnLineId` was missing | Types restated on `goodsReceipt` |
| D15 | low | A fully received ASN can't be chosen, but the server accepts late receipts | PENDING entry (would need a server snapshot change) |
| D16 | low | Route-param precedence was unstated | ASN, then PO, then blind; only cached ids |
| D17 | low | Two Code Map line references were wrong | Corrected |

*Code review, 2026-10-09: three layers (blind, edge-case, verification-gap). 23 findings, each verified against the code. 8 patch groups; 1 deferred; the rest rejected.*

| # | Verdict | Finding | Evidence | Route |
|---|---|---|---|---|
| C1 | medium | Deleting the `document-warehouse-mismatch` branch keeps its test green (no `detail` in the fixture) | `replay-classification.test.ts:493` | patch: a distinct detail, asserted |
| C2 | low | The settled note can render "refused () — not booked" | `goodsReceiptNote` code filter | patch |
| C3 | low | `asnId?: string \| null` admits `asnId: null` on PO/blind payloads | `api.ts` | patch: `asnId?: string` |
| C4 | low | "1 lines", "1 open POs" | `asnCardDetail`, `catalogCachedDetail` | patch: singular at 1 |
| C5 | low | The screen still composes document copy (back label, over-receipt banner), against "the screen composes no copy" | `receive.tsx` | patch: helpers |
| C6 | low | Untested: `blind: 'true'`, `open 0` label, the blind-receipt note branch | draft/replay tests | patch: tests |
| C7 | low | The wms-fe negative assertion passes on an empty render | `asn-card.test.tsx` | patch: positive assertion |
| C8 | low | Docs: test counts, `/inbox` row, the over-receipt banner missing from the mixed-unit PENDING entry | mobile SYSTEM-DESIGN, PENDING | patch |
| C9 | low | Same SKU on two document lines: every scan resolves to the first open line, so its overflow pends while the second line stays open | `resolveLineRefs`, identical to the pre-21-6b `resolvePoLineId` | defer (pre-existing PO behaviour) |
| R1 | false | A mid-draft catalog refresh leaves a stale `asnId`/`asnLineId` (also: missing-line progress, null active document, stale refs at confirm) | `refreshCatalog` is reachable only from the choose step and the no-catalog screen (`receive.tsx:228,486`); the screen loads its snapshot once | rejected |
| R2 | false | A blind receipt's note says "without crediting the PO" | The server's blind arm settles before the unmatched arm, so a blind receipt never carries `unmatchedLines` | rejected |
| R3 | low | `asn-not-open` drops the whole GRN | Decided in 21-6 (the fate table); the op reaches the web review queue through the sync report | rejected |
| R4 | low | No UI for switching documents; re-resolution is defensive only | The choose step comes before any scan; a control would add surface | rejected |
| R5 | low | The ASN expected date shows in UTC | A spec decision (Boundaries: `YYYY-MM-DD` in UTC) | rejected |
| R6 | low | The note does not name the unmatched reason | The spec chose line counts; the reason is in the response | rejected |

## Design Notes

- **Why the PO code, not a parallel ASN arm.** 21-6 made receiving "PO or ASN or blind" in one command. The device mirrors that with one draft, one resolver and one progress path, keyed by the active document, so the two arms cannot drift.
- **Why absent keys on PO and blind ops.** Stored payloads replay verbatim through the sync report. Ops in the old shape stay byte-identical, so pre-21-6b and post-21-6b queues are indistinguishable for those receipts.
- **Why references are built from the context.** One stale `poLineId` on an ASN receipt makes the server answer 400 for the whole GRN. That drops the op, which is scan loss for every line. Rebuilding at confirm makes that state unrepresentable in the payload.
- **Why a settled note at all.** Partial outcomes (unmatched, refused or over lines) were invisible on the handheld. A refused line is the worst case: its units reach no ledger and no queue. The note is its only record until PENDING's queue entry lands.

## Verification

**Commands:**
- `bun run typecheck && bun test` (wms-mobile) -- expected: green.
- `bun run lint && bun run test && bun run typecheck && bun run build` (wms-fe) -- expected: green.
