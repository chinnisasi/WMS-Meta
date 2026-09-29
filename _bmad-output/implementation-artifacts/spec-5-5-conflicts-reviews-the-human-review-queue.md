---
title: '5-5 Conflicts & Reviews — the human review queue'
type: 'feature'
created: '2026-09-29'
status: 'in-progress'
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
