---
title: 'Story 4-2d: Outbound pack & dispatch web surface'
type: 'feature'
created: '2026-09-28'
status: 'done'
route: 'dispatch'
review_loop_iteration: 0
baseline_commit: '01dd314' # wms-fe main
context:
  - '_bmad-output/implementation-artifacts/epic-4-context.md'
  - 'docs/design/frontend/SYSTEM-DESIGN.md'
  - 'docs/design/frontend/IMPLEMENTATION-GUIDE.md'
  - 'docs/design/modules/outbound.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** Stories 4.5/4.6 shipped the pack and dispatch commands — scan-verified packing (422 `pack-mismatch` naming both quantities), optional weight/dims, a packing-slip response, and terminal dispatch that retires committed holds — and none of it has a web consumer. The Outbound page shows orders and waves, but the pipeline stops at the pick: an operator cannot pack an order to Ready-to-Dispatch, cannot see the packing slip, and cannot dispatch.

**Approach:** The Outbound **pack & dispatch pipeline** surface in `wms-fe`: warehouse-scoped view of packable/dispatchable orders, a pack panel that takes entered scanned quantities and shows the returned packing slip, a dispatch confirmation, and an amber-free honest error surface (every server arm rendered verbatim). Role-gated on `pack.execute` / `dispatch.execute`.

**Decided (technical, from investigation):**
- **The generated SDK is ready — nothing to regenerate.** `outboundControllerPackOrder` / `outboundControllerDispatchOrder` and every DTO/error arm already exist in `types.gen.ts`; only client wrappers are missing.
- **No web read exposes picked quantities** (order lines carry ordered/reserved/shortfall only). The bench shows ordered-vs-scanned; the server is the sole picked-vs-scanned authority — its 422/409 arms name the discrepancy and render verbatim. This is the epic's stated behavior, not a gap to paper over.
- **The packing slip is the 201 `PackResponse`** — rendered on success; a replay (same key, same payload) re-serves it byte-for-byte, so a retry just re-renders it.
- **Dispatch's `carrierName`/`trackingNumber` are optional free text** (the 4-6c migration target); an empty body is a complete dispatch. Label rating/generation is 4-6c and BLOCKED here — the epic's "retryable inline label error" is not in this story.
- **Pack precondition is status exactly `accepted` with every pick line picked** — there is no "picked" order status; pickedness is line-status based and server-checked.

**Decided (2026-09-28, human):**
- **The pipeline is a third surface** "Pack & Dispatch" mounted in `outbound.tsx` beside Orders and Waves — a dedicated pipeline view, page-scoped to packable/dispatchable statuses, a separate component per the 4-2c KEEP rule. The 4-2b Orders surface is untouched.
- **Scanned entries start from ordered qty**, packer edits down. Fast for the common full pack; a short-picked order gets the server's 422 naming both quantities and the packer corrects.
- **No handling-unit input on web** — a catch-weight SKU web-pack fails with the server's 422 naming the HU requirement, rendered verbatim; mobile (10.3/10.7) is the CW pack path.

## Boundaries & Constraints

**Always:**
- Reuse the 4-2b/4-2c machinery: `ResourceState<T>` + `readReason`, shell classes + `ReadFailure`, `DataTable` `renderExpanded` + expanded-row state, the `OUTBOUND_CHANGED` broadcaster (bump revision on pack/dispatch success), and the two ulid conventions (per-draft key reset on draft edit; per-confirm key minted when the confirm opens — both kept across retries).
- Gate pack/dispatch affordances on `roleHasCapability(role, 'pack.execute' | 'dispatch.execute')` — hidden, not disabled.
- Failed reads get an explicit failed arm (`ReadFailure` + Retry), never a blank list.
- Component tests written as the story goes: stubbed fetch router (mutations routed before reads), pinned `Date`, recorded idempotency keys asserted.
- Client wrappers live only in `src/lib/api/client.ts`; components never import the generated SDK.

**Never:**
- No carrier rating, labels, manifests or tracking UI (4-6c); no "retryable inline label error".
- No backend changes, no SDK regeneration, no new order states, no device-twin work.
- No server-side status filter assumption — the order list is `cursor`+`limit` only; status filtering is page-scoped client-side.
- No ledger timeline surface.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Pack happy | accepted, fully picked; scanned entries match picked | 201 `PackResponse`; row becomes `ready_to_dispatch`; slip rendered (per-line ordered/packed/shortfall, weight/dims when given, packedBy/At) | N/A |
| Pack mismatch | scanned ≠ picked on any SKU | `422 pack-mismatch` naming both quantities, verbatim; nothing recorded | rendered verbatim in the panel |
| Pack not fully picked | any pick line still `planned` | `409` naming outstanding lines, verbatim | rendered verbatim |
| Pack already packed | order `ready_to_dispatch`, new key | `409` "once" message, verbatim | rendered verbatim |
| Pack replay | same key + same payload after success | snapshot re-served; slip unchanged | N/A |
| Partial weight/dims | only some dimension sides | submit blocked client-side (all-or-nothing) | N/A |
| Dispatch happy | `ready_to_dispatch`, optional carrier fields | 201 `DispatchDto`; terminal; retired-reservation count shown; row reflects `dispatched` | N/A |
| Dispatch wrong state | `accepted` or `dispatched` order | `409` naming the status, verbatim | rendered verbatim |
| Role denied | role lacks either capability | affordance not rendered | N/A |
| Read failure | network / 4xx on detail | failed arm + Retry, never a blank list | `ReadFailure` |

</frozen-after-approval>

## Code Map

- `src/lib/api/generated/sdk.gen.ts:771,788` -- pack/dispatch operations, ready to call; no regen.
- `src/lib/api/generated/types.gen.ts:1432-1572` -- `PackOrderDto`/`PackScanLineDto`/`PackDto`/`DispatchOrderDto`/`DispatchDto`; error arms `:5318-5345` (pack) / `:5375-5402` (dispatch).
- `src/lib/api/client.ts:1044-1088` -- `fetchApiGetOrder`/`fetchApiCreateOrder`/`fetchApiCancelOrder` precedents; add `fetchApiPackOrder`/`fetchApiDispatchOrder` (`unwrapError`, caller-supplied `Idempotency-Key`).
- `src/lib/use-outbound-orders.ts:30-38,409-420` -- `ResourceState`/`readReason`/`filterPage` precedent for the new lib.
- `src/lib/outbound.ts:14-16` -- `OUTBOUND_CHANGED` broadcaster; new mutations call `notifyOutboundChanged()`, hooks refetch on revision bump.
- `src/components/outbound/outbound.tsx:111-148` -- shell owner (warehouse picker, role, surface mount, `OutboundSurfaceProps`).
- `src/components/outbound/shell.tsx` -- shared classes, `Section`, `ReadFailure`; reuse, do not grow it beyond what a third surface forces.
- `src/components/data-table/data-table.tsx:44` -- `renderExpanded` for detail panels.
- `src/components/outbound/outbound-waves.tsx:171-207,825-919,933-949` -- per-draft/per-confirm ulid conventions and expansion pattern to copy.
- `src/lib/users.ts:61,65,119` -- `pack.execute`/`dispatch.execute` + `roleHasCapability`; no mirror change needed.
- `src/components/outbound/outbound-waves.test.tsx:161-246` -- `stubRouter`/`pinnedDate` test pattern.
- `workspace/core/backend/wms-be` `outbound.controller.ts:163-277`, `pack.command.ts`, `dispatch.command.ts` -- read-only reference for error arms; do not change.

## Tasks & Acceptance

**Execution:**
- [x] `src/lib/api/client.ts` -- add `fetchApiPackOrder` / `fetchApiDispatchOrder` wrappers -- the only bridge to the generated SDK.
- [x] `src/lib/use-outbound-pack-dispatch.ts` (new) -- packable-order read hook + pack/dispatch mutations with reason maps and broadcaster bumps -- mirrors `use-outbound-waves.ts`.
- [x] `src/components/outbound/pack-dispatch.tsx` (new) -- the surface: page-scoped status filter, row expansion into the pack panel (scanned entry, optional weight/dims, slip display) and the dispatch confirm -- per the answered Open Questions.
- [x] `src/components/outbound/outbound.tsx` -- mount the surface (only if Open Question 1 = (a)).
- [x] `src/components/outbound/pack-dispatch.test.tsx` (new) -- I/O matrix rows + idempotency-key conventions asserted.

**Acceptance Criteria:**
- Given a fully-picked accepted order and matching scanned entries, when pack submits, then the slip renders and the row reads `ready_to_dispatch` without a full reload (broadcaster).
- Given a scan mismatch, when pack submits, then the 422 names both quantities verbatim and no optimistic state change happened.
- Given a dispatched order, when any pack/dispatch affordance is offered, then it reflects the terminal state (dispatched rows offer nothing).
- Given a role without a capability, when the surface renders, then its affordances are absent from the DOM.
- Given a mutating submit that fails, when the user retries without editing, then the same idempotency key is sent.

## Implementation Notes

- Commits: `434bfbb` (feature) + `ef3dd2b` (pack-replay matrix test) + `4aa49d2` (review patches: stale-broadcast on unmounted mutations, membership-derived pipeline scope, `MAX_QUANTITY_BASE` mirror, cancelled arm, denominator, `ReadFailure` in panel, unit-aware dispatch headline, hook re-export cleanup, EOF newlines, four added tests, new page-level `outbound.test.tsx`) on `feat/4-2d-outbound-pack-and-dispatch-surface` over baseline `01dd314`. Files: the five task files plus `src/lib/outbound-pack-dispatch.ts` (pure derivation: scope, drafts, outcomes, labels, refusal mappers) and its `src/lib/outbound-pack-dispatch.test.ts` (29 lib tests); 5 new `client.test.ts` wrapper cases. No product code beyond the five tasks.
- The read hook is a distinct **instance** of the canonical `useOutboundOrders` (the list endpoint is the only order read there is; the pipeline's statuses are page-scoped client-side), not a second fetch implementation — documented in `use-outbound-pack-dispatch.ts`. Mutations live in the component per the 4-2b/4-2c precedent, with the refusal mappers in the pure lib, tested.
- Deviation (reviewer flag, judged sound): the 422 `idempotency-key-reuse` arm gets fixed house copy ("already processed with a different parcel" for pack / "already processed" for dispatch) instead of verbatim — its cause is fully visible client-side (an edited draft replaying an old key). Only 409 and `pack-mismatch` render verbatim, per the spec's verbatim rule for arms naming server-side-only truth.
- Client-side bounds mirror the backend decorators with comments naming each (`MAX_WEIGHT_GRAMS`, `MAX_DIMENSION_MM`, `MIN_SCAN_QTY`); over-precise scan values are never clamped — the backend's precision refusal is the authority.
- Verified first-hand post-patch: full suite 466/466 across 34 files; typecheck, lint, `check:capability-mirror` clean; wms-be untouched; tree clean, nothing pushed. The `MAX_QUANTITY_BASE` mirror verified byte-equal to wms-be's (`quantity.ts:57`, `QUANTITY_SCALE` = 10³); the carrier-length constants verified to live at `dispatch.command.ts:42-43` as the fixed comment now cites.

## Spec Change Log

## Review Triage Log

<!-- Three-layer review, 2026-09-28: blind-hunter (17), edge-case-hunter (6), verification-gap (3+1). Every claim verified first-hand before verdicts. -->

| # | Layer | Finding | Verdict | Evidence |
|---|---|---|---|---|
| 1 | EC | Pack POST settles after bench unmounts → `if (!mounted.current) return;` skips `notifyOutboundChanged()` — sibling lists stay stale after a committed pack | **medium** | Confirmed in `pack-dispatch.tsx` success path; row collapse / warehouse switch mid-flight is reachable. Fix: notify regardless of mounted. |
| 2 | EC | Same for dispatch POST (`DispatchSection` unmount) — terminal dispatch, lists never refetch | **medium** | Same code shape, confirmed. Same root cause as #1. |
| 3 | EC | `isPipelineStatus` is `status !== 'cancelled'` — a fifth OrderStatus arm auto-appears on the pipeline, contradicting the pinned test's "a new arm must opt in" | **low** | Confirmed; membership check is the one-line fix the test comment already describes. |
| 4 | EC | Detail read returns `cancelled` in the race window → panel renders bare lines, no note, no affordance | **low** | Confirmed: the panel has no `cancelled` arm. One-line note arm. |
| 5 | EC | Spec task wording puts mutations in the hook file; they live in the component | **low** (reject) | The fix is a spec edit; the implemented shape matches the cited precedent (`use-outbound-waves.ts` keeps mutations in the component) and is documented in Implementation Notes. |
| 6 | EC | FE does not mirror the backend's `@Max(MAX_QUANTITY_BASE)` on a scanned line (outbound.dto.ts:978) — a huge scanned value 400s instead of being refused client-side | **low** | Confirmed: backend decorator exists, FE `parsePackDraft` checks only `MIN_SCAN_QTY`. |
| 7 | BH | Same as #3 | **low** | Duplicate of #3. |
| 8 | BH | Catch-weight refusal "falls into the generic default arm" | **false** | CW refusals throw code `pack-mismatch` (pack.command.ts:842) → rendered verbatim by `packReason`. The no-HU-input scope is the frozen human decision. |
| 9 | BH | Same as #6 | **low** | Duplicate of #6. |
| 10 | BH | All-entries-cleared draft submits `{scanned:[]}`, contradicting "nothing 400-bound is sent" | **false** | Empty scanned is not a 400: the server reads absent SKUs as scanned 0 → 422 `pack-mismatch` naming both quantities — the decided server-authority behavior, rendered verbatim. |
| 11 | BH | `setProblem(parsed.problem ?? '')` — `?? ''` is dead | **low** | Confirmed: `body === null` only when `problem` is non-null. Direct deletion. |
| 12 | BH | Filter count denominator is all loaded orders incl. cancelled — "3 of 4 on this page" names an order that can never appear | **low** | Confirmed: `pageFilterCount(rows.length, loaded.length)`; should count against the pipeline-filtered set. |
| 13 | BH | Two read-failure presentations: list uses `ReadFailure`, detail panel hand-rolls an alert div | **low** | Confirmed; direct swap to `ReadFailure` in the panel. |
| 14 | BH | `dispatchOutcome` is unit-agnostic ("7 units shipped") on an otherwise unit-aware surface | **low** | Confirmed; `packOutcome` uses `sharedQuantityUom` — align dispatch. |
| 15 | BH | Dispatch back-out ("Keep it as it is") untested despite test-header claim 4 | **low** | Confirmed; one test pins the key invalidation. |
| 16 | BH | SKU-map-unavailable fallback never runs in a surface test | **low** | Confirmed; lib-level fallback is pinned, surface wiring is not. |
| 17 | BH | Cursor pagination wired but never exercised | **low** | Confirmed; stub always answers `nextCursor: null`. |
| 18 | BH | `permission-denied` arm has no lib test | **low** | Confirmed. |
| 19 | BH | `warehouseLabel === null` intro arm untested | **false** | Arm is unreachable: `outbound.tsx` early-returns before mounting any surface when `warehouseId === null`, and `warehouseLabel` derives from the same items list, so it cannot be null when a surface mounts. |
| 20 | BH | Five new files end without a trailing newline | **low** | Confirmed (`tail -c 1` → `}`); repo files end with newline. |
| 21 | BH | `use-outbound-pack-dispatch.ts` re-exports types no consumer uses | **low** | Confirmed: consumers import from `use-outbound-orders` directly. Direct deletion. |
| 22 | BH | `client.test.ts` test name claims blank-dropping the wrapper does not do | **low** | Confirmed: the test passes non-blank fields; dropping lives in `parseDispatchDraft`. Rename. |
| 23 | BH | Bound comments cite drifted line numbers | **low** (partial) | `pack.command.ts:72/74` are accurate (refuted for weight/dims); `dispatch.command.ts:42-43` IS drifted — decorators live in `outbound.dto.ts:1159-1167`. Cite by constant name. |
| 24 | VG | Page-level wiring (`outbound.tsx` mount + `pack-${warehouseId}` key) never executes under test — deleting the surface or the key ships green | **medium** | VG pre-verified with searches; no test renders `Outbound`. One page-level test: three surfaces render, warehouse switch remounts. |
| 25 | VG | Pipeline list pagination untested — dropped `onCursor` disables the pager silently | **low** | VG pre-verified; duplicate root with #17. |
| 26 | VG | FE bound constants mirror backend decorators with no drift check | **defer** | Cross-repo convention question — this repo has no mechanism to test against backend source; values verified equal today. |
| 27 | VG | Slip/record state keyed to nothing — correctness depends on the untested remount | **low** | No reachable path found by the reviewer; subsumed by #24's page-level remount test. |


## Design Notes

- The server owns picked-vs-scanned truth because picked totals exist nowhere in a web read — pre-verifying client-side would mean re-deriving pick state the API does not expose. The UI's job is honest input + verbatim refusals.
- Dispatch is terminal ("no un-dispatch"): the confirm must say so; after success the row offers nothing.
- `carrierName`/`trackingNumber` are labeled free-text; 4-6c structures them — no client-side vocabulary invented here.

## Verification

**Commands:**
- `bun run test -- src/components/outbound/pack-dispatch.test.tsx` -- expected: all pass.
- `bun run typecheck` && `bun run lint` -- expected: clean.
- `bun run check:capability-mirror` -- expected: unchanged mirror passes.

**Manual checks (if no CLI):**
- `git -C workspace/core/backend/wms-be status` -- expected: untouched.