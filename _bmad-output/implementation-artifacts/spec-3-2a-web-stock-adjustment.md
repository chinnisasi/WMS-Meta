---
title: '3-2a web stock adjustment — an Adjust tab and row action on Inventory, on the existing adjustment command, reasons and approval thresholds'
type: 'feature'
created: '2026-10-23'
baseline_commit: '02d4489e59511c931ec11dc233727a603e9c8785'  # wms-fe; wms-be and wms-mobile unchanged
status: 'done'
route: 'dispatch'
review_loop_iteration: 0
context:
  - 'docs/initiatives/production-readiness.md'
  - 'docs/design/SYSTEM-DESIGN.md'
  - 'docs/design/IMPLEMENTATION-GUIDE.md'
  - 'docs/design/API-SURFACE.md'
  - 'docs/design/PENDING.md'
  - 'docs/design/modules/inventory.md'
  - 'docs/design/frontend/SYSTEM-DESIGN.md'
  - 'docs/design/frontend/IMPLEMENTATION-GUIDE.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** The adjustment command, its reasons (`stock-count`, `damaged`, `expired`, `shrinkage`, `found`, `recall`, `system-correction`, `other`) and its owner approval threshold all exist, but no screen can use them. Only the 2-4a DAMAGED write-off reaches it. A supervisor who finds 3 extra units, or 2 crushed ones in a storage bin, has no way to record it.

**Approach:** A web-only story on the existing backend: `POST …/inventory/adjustments` (201 applied, 202 pended) plus the stock, batch and SKU reads.
- **Inventory → Adjust tab.** A form: bin, SKU, signed quantity (add or remove), reason, note, then batch or serials as the SKU needs.
- **Adjust action on every eligible Stock row.** It opens the same form pre-filled for that bin and SKU.

**Decisions (recommended, taken autonomously under the user's standing instruction, 2026-10-23; revised by the design review):**
1. **Split.** Handheld adjustment is 3-2b (deferred-work). **No backend change, no migration.**
2. **Who.**
   - **Hidden by role.** The Adjust tab is in a **role-filtered** tab list, so the shared `PageTabBar` never renders it for a role without `stock.adjust`.
   - **Guard.** Opening `?tab=adjust` without it shows "Your role cannot adjust stock" and no form.
   - **Row action.** Gated the same way.
3. **Two entry points, no id deep link.**
   - **Row action.** On an eligible Stock row, **Adjust** opens an **inline panel** with the same form, pre-filled for that bin and SKU (the write-off precedent). Success calls `onDone`, then `stock.reload()`.
   - **Adjust tab.** Holds the blank form (bin, then SKU).
4. **Eligibility.** One pure `adjustOffered(bin, sku, kitIds)` drives both the row action and the form's pickers:
   - non-retired, non-system bins; DAMAGED only via the 2-4a write-off (unchanged);
   - **RECEIVING excluded** (Receiving stock belongs to putaway);
   - QC-HOLD, IN-TRANSIT and RETURNS never offered;
   - kits refused (from the kits read; nothing is sent until it is ready);
   - catch-weight refused, with the sentence "Catch-weight stock is adjusted by handling unit — not on this screen yet".
5. **Direction and quantity.** An explicit **Add / Remove** choice plus a positive quantity, at the SKU's `uomPrecision`, sent as a signed `quantityDelta`.
6. **Batch-tracked Remove follows FEFO exactly as the server does.**
   - **The rule.** `fefoBatch(rows, nowMs)`: candidates are batches with stock in the bin whose expiry is null or `Date.parse(expiry) >= now` (an instant compare); sorted by expiry ascending, nulls last. With `now` injected, it is tested one millisecond each side of expiry.
   - **Tie.** On equal expiry the preview names all the tied batches ("L1 or L2 — same expiry"), because the server's pick there is row order.
   - **Cap.** The cap is the **FEFO batch's** quantity ("FEFO takes L1 (3 here) — remove at most 3, or pick a batch").
   - **No candidate.** With no non-expired candidate, an explicit batch choice is required.
   - **Override.** Choosing a batch requires an override reason (the server rule).
7. **Batch-tracked Add.**
   - **Code.** A batch code is required.
   - **Existing code.** It shows that batch's stored mfg and expiry read-only and sends no dates (the server keeps the first dates).
   - **New code.** It takes optional IST dates. They are converted with **one FE helper equivalent to `istMidnightOf`** (IST date → the Z-suffixed UTC instant of IST midnight) and must satisfy expiry ≥ mfg. Boundary fixtures cover a viewer outside IST.
   - **Not mirrored.** The client expiry-required and minimum-shelf-life policy is not mirrored (PENDING).
8. **Serials.** A typed list, with duplicates refused and the count equal to the quantity. **A SKU both batch- and serial-tracked sends both arms**, with the batch chosen as in 6–7.
9. **Add SKU list.**
   - **Scope.** Active non-kit SKUs, filtered to the bin's `dedicatedClientId` when it is set (the `moveTargetBins` precedent).
   - **Labels and warnings.** Labelled with `skuDisplayLabel`. A non-blocking warning appears when `storageClassSatisfies` fails, because the server skips bin gates on adjustments (PENDING).
10. **Reasons.** `ADJUST_REASONS` is `as const satisfies readonly StockAdjustmentDto['reasonCode'][]` with a two-way type test. Each reason has a label, and `expired` and `recall` show the hint "FEFO skips expired batches — pick the batch".
11. **Outcome.**
    - **201:** "Adjusted — {SKU} {±qty} in {bin}", with a link to `/inventory/ledger?skuId&binId&type=stock.adjusted` (the ledger has no event-id filter).
    - **202:** "Pending approval — over the {threshold} threshold", using `pendingAdjustment.thresholdQuantityAtRequest` at the SKU's precision, plus the pendings-queue link.
    - **Errors:** a sentence for each code — `insufficient-on-hand`, `bin-retired`, `qc-bin-not-adjustable`, `returns-bin-not-adjustable`, `damaged-bin-write-off-only`, `kit-cannot-hold-stock`, `duplicate-serial`, `serial-elsewhere`, a batch `not-found` vs a bin or SKU `not-found`, `role-denied`, `permission-denied`, `validation-failed`, `idempotency-key-reuse`, `conflict`, and `request-failed`.
12. **Idempotency.** One key per draft: minted at submit, reused on retry, cleared on any edit and after success. An **`inFlight` ref** guards it (the move-form precedent); the write-off gains the same guard.
13. **The 2-4a write-off keeps its behaviour.** Its existing tests stay green unchanged, and it reuses the shared pieces only where they produce the same result.

## Boundaries & Constraints

**Always:**
- The shared rules live in `lib/adjust.ts`, which is pure and tested.
- IST through one helper per side.
- `frontend/SYSTEM-DESIGN.md:45` updated.
- §9 walked:
  - Periods/IST: the batch dates (decision 7).
  - Verify-before-freezing: the FEFO, date and batch rules were checked against `inventory.controller.ts:581-609`, `:1081-1095`, `catalog.facade.ts:1061-1079`.
  - The portal and idempotency surfaces are unchanged.

**Never:**
- No backend change.
- No handheld.
- No catch-weight.
- No policy-editing UI.
- No bin gates added on the server.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|---|---|---|---|
| Add untracked | bin A, SKU X, Add 3, `found`, note | `quantityDelta: 3`; 201 → "Adjusted"; the row refreshes | — |
| Remove, FEFO | L1 (3, exp 2027-01), L2 (5, exp 2027-06), Remove 2 | no `batch`; the preview names L1; cap 3 | Remove 4 with FEFO → blocked: "at most 3, or pick a batch" |
| FEFO, expired only | the only batch is expired | an explicit batch plus an override reason is required | — |
| Tie | L1 and L2 with the same expiry | the preview names both | — |
| Remove, override | L2 picked | `batch: {code: 'L2', overrideReason}` | no reason → blocked |
| Add, new batch | L9, expiry 2027-03-31 IST | `expiryDate` = `2027-03-30T18:30:00.000Z` | expiry < mfg → blocked |
| Add, existing batch | L1 | its dates shown read-only; none sent | — |
| Batch + serial SKU | Remove 2 | both `batch` (FEFO or override) and `serials` | count ≠ qty → blocked |
| Dedicated bin | bin dedicated to ACME | Add SKUs are ACME's only | — |
| Over threshold | \|delta\| > 10 | 202 → "Pending approval — over the 10 threshold" + link | — |
| Operator deep link | `?tab=adjust` as an operator | "Your role cannot adjust stock" | — |
| Catch-weight, kit, RECEIVING, system bin | — | not offered, or refused with its sentence | — |
| Retry or edit | drop then resubmit; edit then resubmit | same key; new key | — |

</frozen-after-approval>

## Code Map

### Web (`workspace/core/frontend/wms-fe`)

**The tab and the form**
- `src/lib/page-tabs.ts:139`: `INVENTORY_PAGE_TABS` gains `adjust`, and the screen passes a role-filtered tab list to `PageTabBar` (`components/shared/page-tabs.tsx:31-47`). Extend the shared bar with an optional `visibleTabs` if needed, a backward-compatible prop.
- `src/components/inventory/inventory-screen.tsx`:
  - the row action on rows passing `adjustOffered` (the `:405-441` inline-panel pattern; `onDone` → `stock.reload()`);
  - the Adjust tab panel with its role guard;
  - the Action column appears for `stock.adjust` holders.
- `src/components/inventory/adjust-form.tsx` (new):
  - The bin comes from `useWarehouseBins` (`adjustOffered`).
  - The SKU comes from the bin's stock rows for Remove (`useBinStock`, the move-form precedent), and from the SKU catalog for Add (`useSkuCatalog` plus `useKits`, the dedicated-client filter).
  - Then direction, quantity and reason (the reason vocabulary from the generated enum), note, and batch or serials.

**`src/lib/adjust.ts` (new, pure, with tests)**
- `parseAdjustment` (the full DTO), `fefoBatch` (the server's rule: oldest non-expired with stock, nulls last), `adjustReason` (every code: `insufficient-on-hand`, `bin-retired`, `qc-bin-not-adjustable`, `returns-bin-not-adjustable`, `damaged-bin-write-off-only`, `kit-cannot-hold-stock`, `duplicate-serial`, `serial-elsewhere`, `not-found`, `role-denied`, `validation-failed`, `idempotency-key-reuse`), and `adjustOutcome`.
- The write-off reuses the shared pieces.

**Other:** `fetchApiAdjustStock` (exists). No client regeneration is needed unless the reason enum is not exported (then use the generated `StockAdjustmentDto['reasonCode']`).

## Tasks & Acceptance

**Execution:**
- [x] Web: tab, form, row action, `lib/adjust.ts`, write-off reuse, plus tests (every matrix row, the FEFO preview matching the server rule's cases, the key lifetime, the gating).
- [x] Meta docs:
  - frontend SYSTEM-DESIGN (`/inventory` Adjust);
  - `inventory.md` (the web surface);
  - the wms-fe README;
  - PENDING: 3-2b handheld; catch-weight on the screen; a requester outcome notice (existing `:463`).

**Acceptance Criteria:**
- Given an ops manager on Inventory → Stock, when they choose Adjust on bin A / SKU X and remove 2 `damaged` units with a note, then the ledger shows a `stock.adjusted` −2, and the stock row reads 2 fewer.
- Given an owner-set threshold of 10, when an ops manager adds 25 `found` units, then the screen shows "Pending approval" with a link to the queue, and stock is unchanged.

## Design Notes

- **Any reason pairs with any direction — by intent.** The eight reasons are not split into "add" and "remove" sets: `stock-count` and `system-correction` go either way, and even `found` / `damaged` are left to the operator (a recount can reverse a `found`). The server's vocabulary is direction-free, and the form mirrors it; only the FEFO hint is direction-aware (a batch-tracked Remove).
- **Why the FEFO preview.** The server draws FEFO when no batch is named. Showing which batch that is lets the user accept it, or override it knowingly with a reason, instead of guessing.

## Verification

**Commands:**
- `bun test`, `bun run typecheck`, `bun run lint`, `bun run check:capability-mirror` (wms-fe): pass.

## Implementation Notes

Implemented 2026-10-23 on `feat/3-2a-web-stock-adjustment` (wms-fe, uncommitted for review). Choices the spec left open, taken here:

- **Field order.** Bin → Add/Remove → SKU, because the SKU source depends on the direction (decision 3 + Code Map: the bin's stock for Remove, the catalog for Add). The row panel shows Add/Remove only (bin and SKU fixed).
- **The ledger link needs `binId` in the ledger drill.** `parseDrill('ledger', …)` refused `binId` (unknown key → `unsupported`), so the link would have opened an "unsupported" banner. `lib/drill.ts` gains `binId: 'uuid'` on the ledger list (the route already took it, 5-4); the link is `/inventory/ledger?list=ledger&warehouseId&skuId&binId&type=stock.adjusted`. A frontend-only change; pinned in `drill.test.ts` (round trip) and `adjust.test.ts`.
- **Batch vs bin/SKU `not-found`.** Both are `code: 'not-found'`; the batch one comes from the controller with the fixed title `'Batch not found'` (`inventory.controller.ts`, the explicit-draw lookup). `adjustReason` compares that title only when the request named a batch on a draw — a title equality, never the detail. PENDING records the backend code that would retire it.
- **The FEFO tie's cap** is the smallest tied batch (the server picks by `batch_on_hand` row order, `batchId` ascending; the web names both).
- **With no unexpired candidate** the form forces "Pick a batch" (the FEFO radio is disabled).
- **Untracked Remove** is capped at the row's (or the bin read's) on-hand, the write-off's precedent; the server's `insufficient-on-hand` stays the authority.
- **Extra refusal arms** beyond the spec's list: `serial-unknown`, `client-departed` (a positive adjustment for a departed client, 1-2a), `unauthenticated`.
- **The write-off** reuses `parseAdjustQuantity` (identical words and precision refusal), `ADJUST_NOTE_MAX` and `ADJUSTMENT_PENDINGS_HREF` (re-exported under the old names), and gains the in-flight ref (new test). Its existing tests are unchanged and green.
- **Existing Stock tests changed** (not the write-off's): the owner now sees the Adjust tab (4 tabs) and an Action column with Adjust on storage-bin rows, so four expectations in `inventory-screen.test.tsx` and the tab list in `page-tabs.test.ts` were updated; the kits route was added to the test router.
- **The FEFO preview's clock** is the form's mount instant (React purity lint); the submit judges FEFO at its own instant.
- **Verification:** `bun test` 2483 pass, `bun run typecheck`, `bun run lint`, `bun run check:capability-mirror` (48 / 5), `bun run build` — all clean. Mutation checks: removing the in-flight guard (form and write-off), inverting the delta sign, and dropping the tab filter each fail a test.

## Spec Change Log

## Review Triage Log

Design review, 2026-10-23 (A). Every accepted finding is folded into the spec above; all choices are recommended, taken autonomously.

| ID | Verdict | Finding → resolution |
|---|---|---|
| A1 | high | No gated-tab pattern exists; operators reach `?tab=adjust`. A role-filtered tab list, a panel guard, a test. |
| A2 | high | The id deep link loses its params; no refresh path. The row action is an inline panel with `onDone` → reload; the tab holds the blank form. |
| A3 | high | FEFO draws one batch; the bin-total cap invites 422s. Cap is the FEFO batch; an explicit choice when none qualifies. |
| A4 | high | The expiry compare and the tie were unpinned. Instant compare with injected `now`; ties named. |
| A5 | high | No FE helper emits the DTO's Z date. One `istMidnightOf`-equivalent helper; expiry ≥ mfg. |
| A6 | medium | Existing codes silently keep their dates; the client policy is not mirrored. Read-only dates for an existing code; policy PENDING. |
| A7 | medium | Batch+serial SKUs need both arms. Decision 8; a matrix row. |
| A8 | medium | The eligibility contradiction; RECEIVING; the Action column. `adjustOffered`; RECEIVING excluded. |
| A9 | medium | The Add list ignores the dedicated client; kit read. Filter, `useKits`, class warning. |
| A10 | medium | The outcome fields were unverified. A ledger filter link; the threshold field named. |
| A11 | low | No reason enum or labels; errors incomplete. `ADJUST_REASONS` + labels; the full error list. |
| A12 | low | Context, inFlight credit, write-off pin, §9. Fixed. |


Code review, 2026-10-23 (Blind Hunter BH, Edge Case Hunter EC, Verification Gap VG). Routes taken autonomously (recommended).

| ID | Verdict | Finding → resolution |
|---|---|---|
| EC1 | medium | Patch: toggling a row action while its POST is in flight unmounts the form (lost outcome, possible double apply). Row actions are disabled while a row request is busy. |
| BH1 + EC10 | medium | Patch: the Add and Remove pickers don't use `adjustOffered` (catch-weight and kits are listed, then refused). Both are filtered by the one predicate; a test. |
| BH2 + EC2 | medium | Patch: the FEFO clock is frozen at mount. Refreshed on success and on each batch re-read. |
| BH3 + EC3 | medium | Patch: the server's "No batch to draw" is mapped to "try a smaller quantity". A title branch: "No unexpired batch holds stock here now — pick the batch, with a reason." |
| EC11 | medium | Patch: several codes return `error.detail`, against decision 11. Fixed sentences by code; `detail` never shown. |
| EC4 + EC5 + EC6 + BH11 + EC7 + EC8 | low | Patch: refusals don't re-read; a failed batch read reads "still reading"; no SKU-loading line; an unknown SKU option; a failed bins read hides actions silently; unreachable kit guidance. Each state is handled and worded. |
| EC9 | low | Patch: the row Add allows an inactive SKU the tab hides. The same status rule. |
| BH4 | low | Patch: the denied deep link leaves `aria-labelledby` dangling. The panel keeps a valid label. |
| BH5 | low | Patch: the kits read runs for every role. Only with `stock.adjust`. |
| BH6 | low | Patch: the ledger link can't single out the new event. `from` = submit time minus a minute. |
| BH8 | low | Patch: adding into an already-expired batch is silent. A non-blocking warning. |
| BH9 | low | Patch: the reason hint ignores the SKU and direction. Shown only for a batch-tracked Remove. Any reason with any direction is intended (stated in Design Notes). |
| BH10 | low | Patch: the batch code input has no `maxLength`. Applied. |
| BH12 + VG-o | low | Patch: the drill bin label is a raw last-8 fragment while the SKU uses first-8. The bin code is resolved from the bins read (fallback last-8); the SKU fragment is unchanged (pre-existing, PENDING). |
| VG1 + BH13 | medium | Patch: tab re-reads after a Remove, the tab success path, the storage warning, the FEFO tie UI, truncation and empty-bin notes are untested. Tests added. |
| VG2 + VG3 + VG4 + VG5 | low | Patch: the expired-only force-pick UI, the named-batch wording, the parser refusals (code over 64, override reason over 200, picked batch not in stock, invalid date, over 1000 serials), the drill bin label. Tests added. |
| BH7 | low, rejected | The pending outcome drops the pend id. The approval queue has no per-item deep link today; PENDING. |
