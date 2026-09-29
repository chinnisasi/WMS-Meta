---
title: '5-5 Conflicts & Reviews — the human review queue'
type: 'feature'
created: '2026-09-29'
status: 'in-review'
baseline_commit_fe: f7f29b3  # wms-fe HEAD (main) before implementation — FE-only story
route: 'dispatch'
review_loop_iteration: 0
context:
  - '_bmad-output/implementation-artifacts/epic-5-context.md'
  - 'docs/design/SYSTEM-DESIGN.md'
  - 'docs/design/IMPLEMENTATION-GUIDE.md'
  - 'docs/design/API-SURFACE.md'
  - 'docs/design/PENDING.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** The `/conflicts` surface carries only the over-receipt and excursion queues; the 5-4 variance-resolution queue and the 5-2 adjustment-pending approvals have no web consumer — a reviewer must reach them through raw API calls, so nothing needing human judgment is in one place.

**Approach:** Extend the existing `/conflicts` queue switcher with an escalated-variances tab (the 5-4 resolution spine: approve-adjust with the consulted ledger seqs, or recount) and an adjustment-pendings tab (the 5-2 approve/reject flow), regenerating the stale FE client against the already-merged backend. FE-only — every read and decision verb exists server-side; the capability mirror already holds `review.decide`, `adjustments.approve` and `variances.resolve`.

## Boundaries & Constraints

**Always:**
- Decision buttons carry a fresh `ulid()` Idempotency-Key per click and the same-tick in-flight guard the excursion queue established; a 409 always ends in a queue reload, never a stranded card.
- Per-tab capability gating hides (never blocks): a tab renders read-only to a role holding none of its decision capability, and the nav entry's surface gate stays `review.decide` (owner and ops_manager hold all three decision capabilities; the accountant/operator never sees the nav item).
- Variance approve-adjust consults the bin's ledger timeline first: the card renders the bin's ledger history (`GET .../warehouses/{w}/inventory/events?binId=` keyset walk) and the resolution sends the seq(s) the approver checked (≤ 200) — an unexplained correction is not buildable from the UI.

**Never:**
- No backend changes of any kind (no new migration, no BE route, no capability) — the backend PR for 5-4 already exposes everything; if an FE tab needs a verb the backend lacks, the gap is a deferred-work entry, not a drive-by BE edit.
- No quarantined-replay-conflict tab — that residents slice (AD-14 case 4 upload→table→resolve) is its own follow-up story (split decision, human-ratified 2026-09-29: mobile-rejected ops exist nowhere server-side today; see deferred-work.md).
- No decision-note field and no requester-notification on adjustment decisions — the 5-2 want stays deferred because both are BE changes and this story carries no backend edit.
- No new web admin surfaces (count on-demand create / policy PUT stay uncounted; the frozen boundary stands).
- No replace of the existing over-receipt/excursion queues — the switcher grows, nothing is rebuilt.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Variances tab loads | Member session, open variances exist | Keyset list newest-first (status `open` default tab; resolved tabs read `adjusted\|recounted`s history), cards carry expected/counted/delta, epochConflict + over-threshold badges, SKU/bin/task joins | List failure → `listReason` mapper, Retry re-walks |
| Approve-adjust resolve | Variance open, ledger panel walked, seq(s) selected, `variances.resolve` held | POST resolve `{decision:'approve_adjust', consideredEventSeqs}` with fresh ULID → snapshot lands, card leaves the queue, ledger correction is one `stock.adjusted` event | No seq selected → client-side refuse (the approve arm requires a non-empty statement); 409 `variance-basis-moved` → offer the recount arm on the same card |
| Over-threshold resolved below owner | ops_manager session, `\|delta\| > thresholdQuantity` | Resolve attempt answered by the owner guard | 403 `variance-owner-required` → card explains the owner-only gate; owner session resolves |
| Recount resolve | Variance open, epochConflict true or approve refused | POST resolve `{decision:'recount'}` (no seqs required) → `recountTaskId` returns, card moves to recounted history | 409 `count-task-open` → mapper names the open sibling task; card stays open |
| Concurrent resolve / stale queue | Two tabs, the variance already resolved | Second POST replays or 409s | `variance-resolved` → reload the queue (the 409-mapper pattern) |
| Adjustments tab | Pendings exist under a tenant threshold | Pending cards with arms, actor, threshold context inline; Approve/Reject per card | 409 on already-decided → reload; 422 reuse → fresh key re-click |
| Role without a tab's capability | Operator or accountant | Nav item hidden by role; direct URL shows the allowed tabs read-only | N/A — hide, never block (UX-DR20) |

</frozen-after-approval>

## Code Map

- `wms-fe/src/app/(app)/conflicts/page.tsx` + `src/components/conflicts/queues.tsx` — the shell; add two tab entries with per-tab capability lists.
- `wms-fe/src/components/conflicts/excursion-queue.tsx` — the template: status tabs, warehouse select, keyset Next, fresh-ulid submit + `resolveInFlight` same-tick guard, 409→reload outcome banner.
- `wms-fe/src/lib/use-excursions.ts` — the hook pattern to copy (`ResourceState` loading/failed/ready + Reloadable retry, cursor scoped per tab); the `Page | null` hooks in `use-inbound.ts` are declared debt — do not copy them into new files.
- `wms-fe/src/lib/api/` — `bun run api:generate` against `wms-be/openapi/openapi.json` (backend already merged) regenerates `sdk.gen.ts`/`types.gen.ts` with the 5-4 + 5-2 routes; then hand-wrap in `src/lib/api/client.ts` (`fetchApiListVariances`, `fetchApiResolveVariance`, `fetchApiListAdjustmentPendings`, `fetchApiApproveAdjustmentPending`, `fetchApiRejectAdjustmentPending` — the `fetchApiListExcursions`/`fetchApiResolveExcursion` wrappers at client.ts:1495-1541 are the shape).
- `wms-fe/src/lib/excursion.ts` — the reason-mapper pattern for new `src/lib/review-queue.ts` variance/adjustment mappers (branch on `ApiProblem.code`; `variance-owner-required`, `variance-basis-moved`, `variance-resolved`, `count-task-open`, `adjustment-*`, `role-denied`, `idempotency-key-reuse`, else `detail`).
- BE reference (no edits): `wms-be/src/modules/movements/count.command.ts` (resolve arms, `normalizeConsideredSeqs`), `wms-be/openapi/openapi.json` — the resolve request/response shapes incl. `consideredEventSeqs` ≤ 200.

## Tasks & Acceptance

**Execution:**
- [x] `src/lib/api/` -- regen (`bun run api:generate`) + wrappers -- the stale client predates 5-2/5-4; regen against merged BE is the cross-repo consumer step
- [x] `src/lib/review-queue.ts` -- listReason/resolveReason mappers for the variance and adjustment arms -- pure-function pattern, unit-testable
- [x] `src/lib/use-variance-queue.ts` + `src/lib/use-adjustment-pendings.ts` -- hooks on the excursion `ResourceState` pattern -- cursor scoped per (tenant, status), Reloadable retry
- [x] `src/components/conflicts/variance-queue.tsx` -- the tab: cards + ledger panel (binId keyset walk, cap the consulted-seq statement at 200) + approve_adjust/recount actions -- the AC's core
- [x] `src/components/conflicts/adjustment-pendings-queue.tsx` -- approve/reject cards with inline threshold context -- 5-2's queue want
- [x] `src/components/conflicts/queues.tsx` -- register both tabs with per-tab capability gates (variance decision = `variances.resolve`, pendings = `adjustments.approve`) -- hide, never block
- [x] `src/lib/*.test.ts` -- unit tests for the mappers and any extracted card/logic -- the repo's DOM-light precedent

**Acceptance Criteria:**
- Given an open variance (incl. an epochConflict one and an over-threshold one), when an owner resolves approve_adjust from the web queue with the consulted seqs selected, then the correction lands once (fresh ULID replay-safe), the card leaves the open tab, and the recounted/adjusted history is browsable.
- Given a pending adjustment, when the owner approves or rejects from the web queue, then the existing 5-2 decide contract holds (fresh key per click, 409 decided-then-reload).
- Given the accountant role, when the app loads, then the conflicts nav item is hidden and tabs are absent — read-only where policy allows, never a blocked screen.

## Design Notes

### Implementation Notes (step-03 verification, diff read first-hand)

Implementation commit `44e19ec` on `feat/5-5-conflicts-reviews-the-human-review-queue` (branch from FE `f7f29b3`; 15 files, +4230/−113 incl. regen `sdk`/`types`/`index`; locally only, never pushed). First-hand verification 2026-09-29: lint, typecheck, build, `api:generate` reproducible (tree stays clean), capability mirror 31×4, **542/542 tests across 36 files**. Deviations and notable facts, judged against the diff:

- **The spec's Always parenthetical was wrong about the mirror, and the implementation is right.** "Owner and ops_manager hold all three decision capabilities" contradicts the 5-2 merged reality: `adjustments.approve` is owner-only (segregation of duties — the role that raises an adjustment does not hold the approval pen). The implementation follows the actual mirror; `queues.test.tsx` pins it (ops_manager → three tabs, no pendings tab). The frozen matrix row 7's "direct URL shows the allowed tabs read-only" reads accordingly: accountant/operator hold no tab capability at all, so the direct URL renders the honest prose line ("No review queues are open to your role"), not a blocked screen — hide, never block, still honored. Carried to the step-04 triage as a bad-spec note, not a code defect.
- **Matrix row 1 claims "SKU/bin/**task** joins"; the impl joins SKU and bin** (via `useSkuMap`/`useBinCodeMaps`) but never renders the originating count `taskId` on a card — it surfaces only on recounted history (`recountTaskId`, sliced). Step-04 triage candidate: render the task id on the card (audit context, one line) or accept the narrowed reading.
- **The Always bullet "a 409 always ends in a queue reload" applies to the already-decided family** (`variance-resolved`, `adjustment-pending-decided`, `conflict` → reload). The `variance-basis-moved` 409 deliberately keeps the card and names the sibling recount arm — exactly what the frozen matrix row itself prescribes; the pendings' guard-class 409s (a moved world) leave the row pending with the server's words verbatim. The stricter bullet wording loses to the matrix's per-row semantics.
- `binCodeOf`/`binCodeLabel` is the same pure function three times (`adjustment-pendings-queue.tsx`, `variance-queue.tsx`, exported from `use-bin-code-maps.ts`) — dedupe candidate for step-04 triage.
- The generated client keeps the hey-api 0.99.0 dropped-`| null` family: `abcClass` regen as `'a'|'b'|'c'` though the BE marks it nullable; `catalog-kits.test.ts`'s fixture gained `abcClass: 'a'` to satisfy the type (same known-bad family as `hazardClass`). Step-05 duty: extend the PENDING hey-api nullable entry.
- `useBinCodeMaps` walks every page-distinct warehouse's zones + bin pages eagerly (enrichment, capped by `fetchAllPages`' hop cap; a failed zone leaves its bins "unknown" without failing the queue). Perf note for PENDING / step-04, not a defect.

## Design Notes: the ledger panel loads the bin's events (binId filter, full-precision keyset cursors already server-side), the approver ticks what they checked, and the resolve sends those seqs — the audit then answers "why is this number what it is" with the consulted events, matching the epic's ledger-context-click-through pattern. The statement is validated server-side (each seq must be a real seq of THAT bin's warehouse ledger) — client selection cannot fabricate history.
- Per-tab gating over the switcher: `queues.tsx` learns a `capability` list per tab and filters by the session role; the surface-level nav gate (`review.decide`) is untouched. Over-threshold variances are flagged on the card (badge "owner decision"), never hidden — an ops_manager sees the card and the 403 names the gate.

## Verification

**Commands:**
- `cd workspace/core/frontend/wms-fe && bun run api:generate && bun run lint` -- expected: regen matches `wms-be/openapi/openapi.json` (BE main already carries 5-4), lint clean
- `bun run test` -- expected: all suites green (new mapper tests included; `users.test.ts` mirror untouched at 31)
- `bun run build` -- expected: the `/conflicts` route builds with the two new tabs

## Review Triage Log

Findings from the three step-04 layers (blind-hunter, edge-case-hunter, verification-gap), each verified first-hand before verdict; cross-layer duplicates share one row with their layers named. review_loop_iteration stays 0 — no loopback (no intent_gap/bad_spec entries).

- **[BH1+EC1+EC6+VG-O1] `useBinLedgerEvents` Retry is dead after a first-page failure** — **medium** — verified: `reload()` resets `requested`/`result` only (use-variance-queue.ts) with no `revision` bump; on a first-page failure every fetch effect dep is unchanged, so the refetch never runs and the panel stays behind ReadFailure indefinitely. Collapse/re-expand or a tab switch still recovers, but the Retry affordance itself is dead. → **patch E1**.
- **[BH3,BH4,BH8,BH13+VG1,VG2,VG-O2] No component-level coverage for either new queue; the coverage claims in the comments are false** — **medium** — pre-verified by the gap layer and re-checked: `queues.test.tsx`'s swap test never renders a row; dropping the re-entry guard, the 409-reload branches, or the seq normalization breaks no test; the header comment's "component-level assertions in the wrapper pins" names verification that does not exist (wrapper pins observe fetches only). Also uncovered: the ledger-panel checkbox→body path and the zero-coverage `useBinCodeMaps`. → **patch E2**.
- **[BH2+VG3] `binCodeLabel` exported dead; the join exists in three copies** — **low** — verified: zero importers outside the export; both components carry private `binCodeOf` clones that can drift from the hook's rule. → **patch E3**.
- **[BH5] A single `decidingId`/`resolvingId` cannot represent two concurrent in-flight rows** — **low** — verified: with decide(A) in flight, decide(B) overwrites the slot, card A's buttons re-enable while its request is outstanding, and its re-click is silently swallowed by the guard; in the variance card the same slot also lights the recount button and the ledger panel's approve button together. → **patch E4**.
- **[BH6] `review-queue.ts` comment claims a duplicate check that does not exist** — **low** — verified: `resolveDraftProblem` checks emptiness and the cap only; dedupe happens at send. → **patch E5**.
- **[BH9] The QUEUES re-shape dropped the `Record<Queue,string>` compile guarantee** — **low** — verified (the panel's silent `else → ExcursionQueue`; the union not derived from the array) — **rejected**: developer-only, realized only by future edits to this exact file, and the total fix restructures the switch — unlikely everyday, fix more than a direct correction.
- **[BH10] 404 copy names the wrong entity on both new list mappers** — **low** — verified against BE: the events route's 404 arm is "Warehouse does not exist in this tenant" (inventory.controller.ts:619) while `ledgerListReason`'s not-found copy names the bin (a query param); the variances list route has no 404 arm at all while `varianceListReason` names a warehouse. → **patch E6**.
- **[BH11] Ledger-panel rows omit which SKU an event moved** — **medium** — verified: rows render the event's quantity at its own SKU's precision but never SKU identity; multi-SKU bins are everyday, and the consulted-seqs audit a reviewer signs cannot be read (seqs 12 and 14 moved *what*?). The panel already holds the sku map. → **patch E7**.
- **[BH12+EC4] The outcome banner is keyed by tab, so it outlives the entries it spoke about** — **low** — verified: keyed state (`outcomeFor.tab`) survives Next-paging and a later return to the tab; after a success-reload it also briefly covers rows that did not participate. **Rejected** (lifecycle part): it matches the excursion-queue template's own keyed-by-tab banner lifecycle, the harm is a stale one-line banner, and the settling fix keys on entry ids; the `'Pend approved'` fallback word rides the E7 cosmetic round.
- **[BH13] folded into the E2 row above (pendings wire read unasserted).**
- **[BH14] Zero-delta sign renders differently on the two cards (+0 vs 0)** — **low** — verified from the two delta expressions. → **patch E7**.
- **[BH15] Eight new/edited files lack a trailing newline at EOF** — **low** — verified in the diff (lint passes because nothing enforces it; repo files otherwise newline-terminated). → **patch E7**.
- **[BH16] queues.test.tsx relative imports** — **false** — refuted: excursion-queue.test.tsx, the identical sibling in the same directory, imports with the same relative spelling; the component-test house pattern is relative.
- **[BH7] Dead `warehouseId`/`signal` options on the new wrappers** — **false** — refuted: `fetchApiListExcursions` — the wrapper this pair is shaped on — carries the identical unused `warehouseId` + `signal` option set; exposing the route's full filter surface is the house wrapper contract.
- **[EC2] A pendings 409 `conflict` renders reload-claiming copy but does not reload** — **low** — verified: the BE's shared `writeIdempotencyKey` throws 409 `conflict` ("Concurrent idempotent request", adjustment-approval.command.ts:582) and the mapper maps that code to "the queue has refreshed" while `decide()` reloads only on `adjustment-pending-decided`; from this UI the same-key race is rare (fresh ULID per click) but the code path is real. → **patch E8**.
- **[EC5] A decide click after the session cleared between render and click is a silent no-op** — **low** — verified (the `session === null` early return) — **rejected**: the excursion-queue template behaves identically, the window is a cleared session against an already-rendered card (rare), and the fix adds a banner branch for a state the component's sessioned gate normally resolves.

### Routed entries (cascading order — no intent_gap, no bad_spec; all patch)

- **E1 (patch)** — add the `revision` counter to `useBinLedgerEvents`'s reload + effect deps, matching `useVarianceQueue`/`useAdjustmentPendings`.
- **E2 (patch)** — add `variance-queue.test.tsx` and `adjustment-pendings-queue.test.tsx` in the `excursion-queue.test.tsx` shape: resolve/decide POST with a fresh `Idempotency-Key`, the already-decided 409s each re-read the queue, the double-click single-POST pin, the ledger-panel checkbox selection reaching the approve body, a capability-less role rendering read-only, and the pendings wire read (`/inventory/adjustment-pendings?status=pending`).
- **E3 (patch)** — have both components import `binCodeLabel` from `use-bin-code-maps.ts` and delete their private `binCodeOf` copies.
- **E4 (patch)** — replace the single deciding/resolving slot with a per-entry Set in state, so concurrent in-flight rows each render their own state and the variance card's recount/approve arms stop sharing.
- **E5 (patch)** — align the comments: `review-queue.ts`'s client-side refusal wording (duplicates are normalized at send, not refused), `queues.test.tsx`'s coverage claim, and the guard comments' "checked in both arms" (true only after E2).
- **E6 (patch)** — correct the two 404 copies to what the routes can actually 404 on (ledger → warehouse; variances list → drop its unreachable not-found arm).
- **E7 (patch)** — cosmetic round: align the zero-delta sign rendering, append the missing EOF newlines, pick a real fallback word for the pendings success banner.
- **E8 (patch)** — widen the pendings decide's reload condition to include the 409 `conflict` code its own copy promises.

No deferred entries (nothing routed to defer; nothing carried unverified).
