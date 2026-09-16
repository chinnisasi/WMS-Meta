---
title: 'Story 4-2c: Outbound waves & picklists web surface'
type: 'feature'
created: '2026-09-16'
status: 'done'
route: 'dispatch'
review_loop_iteration: 1
baseline_commit: '5cf7617' # wms-fe main
context:
  - '_bmad-output/implementation-artifacts/epic-4-context.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** Story 4.2 shipped wave policies, wave generation, release, cancel and picklists — and none of it has a web consumer. An Ops Manager cannot configure a policy, turn accepted orders into a wave, release it to the floor, or see the stops a picker will walk. The epic also asks for carrier-cutoff pressure to be visible, and today nothing shows it: a release is simply refused once the cutoff has passed.

**Approach:** The Outbound **waves** surface: wave policies, a warehouse-scoped wave list whose rows expand into their picklists and stops, the generate / release / cancel actions, and an amber at-risk indicator with time remaining.

**Decided (2026-09-16, human):**
- **The at-risk indicator is derived in the browser with `Intl`, and the derivation is extracted and unit-tested.** The backend computes no at-risk flag and exposes no time-remaining field. The calculation takes an injected `now` and lives in `src/lib`, so it can be tested across timezones, DST and midnight rollover — this is logic that is wrong in ways nobody notices until a cutoff is missed.
- **Amber lights 60 minutes before cutoff**, held in one named exported constant beside the derivation with a test pinning the boundary, so retuning it is a one-line change rather than a magic number in a component.
- **Amber applies to `planned` waves only** — a released wave already made it — and it is **advisory, never preventive**. `cutoff-passed` is decided by the server's clock, so the UI must not pretend to gate on it.

**Decided (technical, from investigation):**
- **Picklists and their stops come free with the wave detail read.** There is no picklist endpoint; `WaveDto.picklists[].lines[]` carries bin code, sku, quantities, shortfall, reason code and walk order. The list row exposes only `picklistCount`, so expanding a row fetches the wave once — the 4-2b shape.
- **`release` and `cancel` take NO body**, unlike 4-2b's cancel-order which required `{}`. Both still require an `Idempotency-Key`.
- **Only two refusals are predictable from a visible row:** release on a `cancelled` wave, and the `waves.manage` role gate. Everything else — `cutoff-passed`, the open-wave claim on generate, `no-eligible-orders`, `wave-cap-exceeded` (the cap is a server default when the policy's is null, so it is unknowable client-side) and every concurrency 409 — is only knowable from the server's answer and renders its `title`/`detail` verbatim. **Cancel has no predictable refusal and is always offerable on a visible wave.**
- **Generate drives both selection paths from one call:** omit `orderIds` for the auto-sweep, pass them for explicit selection.
- **The cutoff is not the deferred timezone question.** Epic 4 defers a repo-wide "UTC day boundary vs Asia/Kolkata" item about *batch expiry* (`Date.parse('YYYY-MM-DD')`). A carrier cutoff is an explicit `HH:MM` with an explicit IANA zone attached — the shape that item wishes expiry had — so this story neither inherits nor resolves it.

## Boundaries & Constraints

**Always:**
- **Component tests are written as this story goes.** The infrastructure exists now (`bunfig.toml` → `happydom.ts`, `src/lib/test/render.ts`, `src/lib/test/globals.ts`, with `data-table.test.tsx` as the worked example). A test touching globals uses `stubGlobal`/`restoreGlobals`, never a bare assignment or `delete`.
- Reuse what 4-2b built rather than re-deriving it: `ResourceState<T>` (`loading | ready | failed`), `readReason`, `DataTable`'s `renderExpanded` + `expandedRowId`, `useOutboundWarehouses`, the `src/lib/outbound.ts` change-event broadcaster, `FeedbackBanner`, and `ulid()` per mutating submit.
- **A failed read is reported, never rendered as progress copy.** This was 4-2b's largest review finding; every read here gets an explicit `failed` arm with the house copy and a retry.
- Any status filter filters the **loaded page** and says so ("N of M on this page") — the list APIs offer `cursor` + `limit` only.
- Mutating affordances gate on `waves.manage` (Owner + Ops Manager — **not** Operator); reads stay open to every role. The outbound nav entry stays **ungated**.
- Components never import the generated SDK; new `fetchApi*` wrappers go in `src/lib/api/client.ts` and own the `Idempotency-Key` header.
- No action is offered that the backend will refuse for a state the row already shows.

**Never:**
- No pack or dispatch UI (`4-2d`); no carrier, label or manifest anything.
- No new backend endpoint, no OpenAPI change, no `api:generate` — the generated client already carries every operation.
- No `[id]` route, no data-fetching library, no schema-validation library, no date library — the cutoff math is `Intl` and arithmetic.
- No client-side gate on `cutoff-passed`, and no amber on a released or cancelled wave.
- No backfill of 4-2b's missing component tests — that is recorded separately.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| List waves | a warehouse selected | newest-first page: status, policy, order and picklist counts, created time; `nextCursor` drives Prev/Next | unreachable API → `FeedbackBanner`, house copy, retry |
| Expand a wave | a row toggled open | one detail fetch; its picklists and per-line stops — bin code, sku, qty, shortfall, walk order | detail fetch fails → inline message on that row only |
| At-risk wave | `planned`, policy cutoff within 60 minutes | amber with minutes remaining | N/A |
| Cutoff already passed | `planned`, cutoff passed in the policy's zone | shown as passed, release still offered — the server decides | release refused → `409 cutoff-passed`, server copy verbatim |
| No cutoff on the policy | `cutoffLocalTime` absent | no amber, no countdown — release is always allowed | N/A |
| Generate, auto-sweep | a policy chosen, no orders named | `201`; the new wave appears | `422 no-eligible-orders` / `wave-cap-exceeded` → server copy verbatim |
| Generate, explicit selection | specific order ids named | `201` | `409` open-wave claim naming the claiming wave → verbatim |
| Release a planned wave | `status === 'planned'` | `200`; the row reads `released` | `409 cutoff-passed` or conflict → verbatim |
| Release a cancelled wave | `status === 'cancelled'` | no release affordance offered at all | N/A |
| Cancel a wave | any visible wave | confirmation, then `200`; the row reads `cancelled` | concurrency `409` → verbatim |
| Create a wave policy | name, grouping, priority, optional cap and cutoff | `201`; the policy is selectable for generation | `400 validation-failed` (cutoff `00:00` is rejected) → server copy |
| Role without `waves.manage` | Operator or Accountant session | list and expanded detail fully readable; no policy form, no generate, release or cancel | N/A |

</frozen-after-approval>

## Code Map

- `workspace/core/frontend/wms-fe/src/components/outbound/outbound-orders.tsx` — **the closest precedent**, built last story: warehouse picker, page-scoped filter with its count, `DataTable` + expandable detail, gated create form, gated action with inline confirmation, `ReadFailure` + `Shell` so a failed read still renders a heading.
- `workspace/core/frontend/wms-fe/src/lib/use-outbound-orders.ts` — `ResourceState<T>` (`loading | ready | failed`), the `useSyncExternalStore` + `revision` hook shape, `useOutboundWarehouses`. Copy the shape; do **not** reuse `useTenantWarehouses`/`useSkuMap`, whose null-on-failure contract was the 4-2b bug.
- `workspace/core/frontend/wms-fe/src/lib/outbound-orders.ts` — `readReason(error, subject)`, the problem-code mappers, `filterPage`/`pageFilterCount`. New wave logic goes in a sibling `src/lib/outbound-waves.ts`.
- `workspace/core/frontend/wms-fe/src/lib/api/client.ts:816-910` — the four order wrappers to copy. **No wave or picklist wrapper exists yet**; all are new. Mutating wrappers take the idempotency key last and set the header. Note `release`/`cancel` send **no body**.
- `workspace/core/frontend/wms-fe/src/lib/api/generated/sdk.gen.ts:556, 569, 578, 591, 600, 622, 631` — create policy, list policies, generate, release, cancel, get wave, list waves.
- `workspace/core/frontend/wms-fe/src/lib/api/generated/types.gen.ts:1396` (`GenerateWaveDto` — `warehouseId`, `policyId`, optional `orderIds`), `:1465` (`PicklistDto` — `orderId`, `status`, `stopCount`, `lines`), `:1453` (`PicklistLineDto` — five status arms including `short` and `unfulfillable`), `:1491`/`:1681` (`WaveDto`/`WaveEntryDto`, status `planned | released | cancelled`), and the `WavePolicyDto` cutoff fields.
- `workspace/core/frontend/wms-fe/src/components/data-table/data-table.tsx` — `renderExpanded` and `expandedRowId`; `data-table.test.tsx` is the component-test worked example.
- `workspace/core/frontend/wms-fe/src/lib/test/render.ts` (`render`, `rerender`, `unmount`) and `src/lib/test/globals.ts` (`stubGlobal`, `restoreGlobals`) — the test helpers. `happydom.ts` sets `IS_REACT_ACT_ENVIRONMENT`.
- `workspace/core/frontend/wms-fe/src/lib/users.ts:56-59` — `roleHasCapability`; `waves.manage` is already in the mirror (Owner + Ops Manager). The CI drift guard (`scripts/check-capability-mirror.ts`) keeps it honest.
- `workspace/core/frontend/wms-fe/src/lib/outbound.ts` — the change-event broadcaster to reuse for refetches after a mutation.

## Tasks & Acceptance

**Execution:**
- [x] `wms-fe src/lib/api/client.ts` — `fetchApi` wrappers: list/create wave policies, list/get waves, generate, release, cancel
- [x] `wms-fe src/lib/api/client.test.ts` — stubbed-`fetch` tests, including that release and cancel send no body and both set `Idempotency-Key`
- [x] `wms-fe src/lib/outbound-waves.ts` — `cutoffStatus(policy, now)` with its named threshold constant, the problem-code mappers, status and quantity formatting
- [x] `wms-fe src/lib/outbound-waves.test.ts` — the cutoff derivation across zones, DST, midnight rollover, absent cutoff and the exact threshold boundary; the mappers
- [x] `wms-fe src/lib/use-outbound-waves.ts` — the wave list, wave detail and policy-list hooks, each with a `failed` arm
- [x] `wms-fe src/components/outbound/outbound-waves.tsx` — the surface: policy form, wave table with amber, expandable picklist/stops detail, generate / release / cancel
- [x] `wms-fe src/components/outbound/outbound-waves.test.tsx` — component tests: amber renders only for an at-risk planned wave, release is not offered on a cancelled wave, the gated affordances are absent without `waves.manage`
- [x] `wms-fe src/app/(app)/outbound/page.tsx` — compose the waves surface alongside the orders one

**Acceptance Criteria:**
- Given a planned wave whose policy cutoff is inside the threshold, when the list renders, then it shows amber with the minutes remaining; given the same wave already released, then no amber is shown
- Given a role without `waves.manage`, when the surface loads, then the wave list and expanded stops are fully readable and no policy form, generate, release or cancel affordance is rendered
- Given a cancelled wave, when its row renders, then no release affordance is offered for it
- Given a refusal the row could not predict — `cutoff-passed`, `no-eligible-orders`, `wave-cap-exceeded`, an open-wave claim — then the server's title and detail are shown verbatim and nothing changes

## Implementation Notes

**Landed (2026-09-16).** All eight execution items, in `wms-fe` on `main` (baseline `5cf7617`). `bun run test` (212 pass), `lint`, `typecheck`, `build` and `check:capability-mirror` are all clean.

**Four things the code decided that the spec left open:**

1. **The list row cannot show an order count.** The matrix asks for "order and picklist counts" on the row, but `WaveEntryDto` carries `picklistCount` and nothing else — and under a `batch` policy one picklist serves many orders, so `picklistCount` is not a stand-in. The row shows picklists; the EXPANDED panel shows `N orders` counted from the distinct `orderId`s on the pick lines (`waveTotals`), which is correct for both groupings. Adding an order count to the list DTO is the obvious next backend change, alongside the status filter this story already defers.

2. **Release is hidden on a `released` wave too, not only a `cancelled` one.** The spec names `cancelled` as the only predictable refusal, and that is still the rule the acceptance criterion pins. `released` is excluded for the softer reason that the endpoint replays it as a 200 no-op: the button would do nothing while implying otherwise. `canReleaseWave` consults the STATUS only and never the cutoff — the advisory/preventive line the spec drew is intact.

3. **`filterPage` was generalised rather than duplicated.** It was pinned to `OrderStatus`; it is now generic over the row's own status union, so waves filter their three arms through the same function. One annotation changed in `outbound-orders.test.ts` as a consequence (the literal-typed fixture rows now declare `OrderStatus`).

4. **A transport failure now reaches the surfaces as the Error it is.** Writing the "unreachable API → house copy" row of the matrix surfaced a live defect in the shared client: `@hey-api/client-fetch` hands a rejected `fetch` back as `error` rather than rejecting, so `unwrapError` was dressing it up as `ApiProblem('request-failed')` with `"TypeError: Failed to fetch"` as its `detail` — which every reason mapper renders in its default arm. The house "The API is unreachable — is wms-be running?" copy those mappers all carry was therefore unreachable in practice, on every surface in the app. `unwrapError` now returns a genuine `Error` unchanged (a non-problem JSON error BODY, which is still an answer from the server, is unaffected and stays an `ApiProblem`). Pinned by a new test in `client.test.ts`. This is a cross-surface fix, not a waves-only one.

**Component tests drive the real surface.** `outbound-waves.test.tsx` mounts `<OutboundWaves />` against a stubbed `fetch` router and a pinned `Date`, rather than mocking hooks — so the `waves.manage` gate, the amber rule and the release affordance being tested are the ones that ship. Thirteen tests cover the three acceptance claims plus the passed-cutoff, no-cutoff, no-policy and failed-read states.

**What is NOT here.** No pack or dispatch UI, no carrier/label/manifest anything, no `[id]` route, no new backend endpoint, no OpenAPI change, no `api:generate`, no new dependency — the cutoff math is `Intl` plus arithmetic. The 4-2b component-test gap is still recorded separately and was not backfilled.

## Spec Change Log

**2026-09-16 — a spec miss recorded, not looped back.**

The task line said "compose the waves surface alongside the orders one" and the frozen block said "a warehouse-scoped
wave list". Neither said the warehouse picker is **shared** with the orders surface, so the implementation gave each
surface its own — and `/outbound` shipped two pickers that can point at different warehouses, with the warehouse
cursor chain walked twice per load.

By the letter this is `bad_spec`: the spec should have been clear enough to prevent it. It is recorded here and
patched rather than looped back, because the fix is contained (lift the picker and warehouse resolution into one shell
the page owns) and a re-derivation would discard 3,300 lines that are otherwise correct.

**KEEP on any future re-derivation:** the surfaces stay separate components; only the shell, the picker and the
warehouse resolution are shared.

## Review Triage Log

**Loop 1 — three layers (blind hunter 14, edge-case 13, verification-gap 4). 31 findings grouped by shared root cause
into 19 entries: 16 patched, 2 deferred, 1 rejected. No `intent_gap`; one spec miss recorded below rather than looped
back, because the fix is contained and a loopback would discard 3,300 correct lines.**

| # | Entry (members merged by root cause) | Verdict | Evidence |
|---|---|---|---|
| 1 | **No test ever presses Release or Cancel** — the tests assert button *labels*; the client tests call the wrappers directly. Nothing connects the two. Also uncovered: the four outcome builders, and the `OUTBOUND_CHANGED_EVENT` refresh loop | **high — patch** | v-gap (pre-verified) + blind. Invert the verb ternary so Release calls `fetchApiCancelWave` and **every check still passes**: an Ops Manager presses Release, the wave is cancelled, CI green. The test router's catch-all would even answer a mutation POST `200`, so a future test could pass vacuously |
| 2 | **`cutoffLabel` reports "No cutoff" for a policy that has one** — an unparseable `HH:MM`, an unknown IANA zone, and a genuinely absent cutoff all collapse to one `none` kind | **high — patch** | blind + edge (claim). It tells the viewer release is always allowed while the server refuses at 18:01. The lib tests pin the derivation but never assert the copy, so the lie is green. Compounded: amber silently depends on a second policy read, and `fetchAllPages` truncates at 20 hops with no signal |
| 3 | **`/outbound` renders TWO warehouse pickers that can point at different warehouses** — orders and waves each own `useOutboundWarehouses()` and a `<select>` | **high — patch** | blind; I confirmed it in the page source. An operator can read orders for one warehouse and waves for another with nothing saying so, and the warehouse cursor chain is walked twice per load (neither hook caches). **Spec miss:** the task said "compose the waves surface alongside the orders one" and should have said the picker is shared — see the Spec Change Log |
| 4 | Outcome copy is written for the planned-wave case only — `releaseOutcome` calls every picklist ready when the backend cancels the unpickable ones first, and "No stock moved" is false when cancelling a *released* wave | **medium — patch** | blind. `releaseWave` flips picklists with no pickable line to `cancelled`, then the rest to `ready`; cancel deliberately does not free lines that drew units |
| 5 | The Cutoff column counts down on released and cancelled waves — only the amber *chip* is status-gated | **medium — patch** | blind. A cancelled wave shows a countdown to a deadline it cannot miss; the test asserts only the absence of "At risk", so it passes |
| 6 | A wave-detail 404 tells the viewer an **order** no longer exists | **medium — patch** | all three layers. `useWaveDetail` reuses `detailReason` from the orders module, whose copy names orders |
| 7 | Release and cancel mint a fresh `Idempotency-Key` per attempt, while the policy and generate forms hold one per draft | **medium — patch** | blind + edge. A retry after a lost response is a new command, not a replay — the same discipline 4-2b's review established, dropped in the row actions |
| 8 | A failed policy read renders as "no policies yet", telling an Ops Manager to create one that already exists | **medium — patch** | edge |
| 9 | An explicit order selection is not pruned when the order page refetches or pages — the counter can read "3 of 1 chosen" and stale ids are submitted | **medium — patch** | edge |
| 10 | The FE calls the whole cutoff minute `passed` while the backend, comparing `HH:MM` strings, still allows release at 18:00:30 | **medium — patch** | blind. Advisory only — the affordance is correctly left in place — but the label overstates certainty |
| 11 | Policy `name` has `@Length(1, 120)` server-side, mirrored neither in `parsePolicyDraft` nor as `maxLength` — under a test titled "the backend's own bounds are mirrored so a 400 is never earned" | **low — patch** | blind |
| 12 | Retry on a failed read appears inert — no transition back to `loading`, so a second identical failure is indistinguishable | **low — patch** | edge |
| 13 | `submit()` sets state after `await` with no mounted guard; switching warehouse mid-flight loses the outcome entirely | **low — patch** | edge |
| 14 | `waveTotalsLabel` can read "3 units uncovered across 0 lines with nothing to pick" | **low — patch** | edge |
| 15 | `releasedAt` / `cancelledAt` are fetched and never shown — the one question asked about a released wave | **low — patch** | blind |
| 16 | `useNow` ticks every 30s unconditionally — no cutoff on the page, no planned wave, tab hidden — re-rendering the table each time | **low — patch** | blind |
| 17 | A non-JSON error body (a proxy's HTML 502) is stringified into `detail` and rendered through every mapper | **low — patch** | edge |
| 18 | The countdown's 30-second refresh is pinned nowhere — delete the interval and the chip freezes at mount with nothing failing | **defer** | v-gap (pre-verified). The derivation itself is exhaustively tested; only the cadence is unverified, and closing it needs timer control the suite uses nowhere yet |
| 19 | `roleHasCapability` throws on a role string absent from `ROLE_CAPABILITIES`, crashing the whole surface | **defer** | edge; I confirmed it. `auth.ts` validates only `typeof role === 'string'`, so a fifth backend role or a stale session crashes the page. **Pre-existing (story 1.5), not caused by this change** — but crash-class with a one-token fix (`?? []`), so worth picking up immediately |
| 20 | `carrierRef` is accepted by the create DTO but has no field in the policy form | **low — rejected** | blind. Carrier concerns belong to `4-6b`/`4-6c`, which will also decide what a carrier reference *is*; adding a raw UUID box now would ship a field nobody can fill meaningfully. The frozen block excludes carrier work |
| 21 | `unwrapError` widened from `ApiProblem` to `Error` app-wide with one new test | **verified safe — no action** | blind raised it; v-gap independently traced all 9 consumers and found no site keyed on `request-failed` and none reading `.code`/`.status` without an `instanceof` guard. Pinned at the boundary and end-to-end. Recorded because the change is wider than the story's name suggests |

## Design Notes

**Why the cutoff derivation takes an injected `now`.** It is the only way to test "18:00 Asia/Kolkata" behaviour from a machine in any timezone, across a DST transition, and at the midnight rollover where minutes-remaining would otherwise go negative or wrap. A function reading `Date.now()` internally is untestable in exactly the cases that matter.

**Why amber cannot gate release.** The backend compares its own clock to the policy cutoff and answers `409 cutoff-passed`; it exposes no time-remaining field, so the browser's view is an estimate made from a different clock. Hiding the release button when the browser thinks the cutoff has passed would refuse an action the server might still accept. Amber warns; the server decides.

**What this leaves for later.** Wave and policy lists offer `cursor` + `limit` only, so the page-scoped filter has the same honest limitation orders has. Pushing a status filter into the backend would serve every Outbound screen and is the obvious next backend change, but it is not this story's.

## Verification

**Commands:**
- `cd workspace/core/frontend/wms-fe && bun run test && bun run lint && bun run typecheck && bun run build` — all clean. `check:capability-mirror` must stay green.
- Manual: with a policy whose cutoff is within the hour, confirm a planned wave shows amber with a falling count and a released one does not.

**Run 2026-09-16:** `bun run test` → 212 pass / 0 fail across 16 files (58 in `outbound-waves.test.ts`, 13 in `outbound-waves.test.tsx`, 28 in `client.test.ts`). `bun run lint`, `bun run typecheck`, `bun run build` and `bun run check:capability-mirror` ("21 capabilities across 4 roles") all clean. The manual amber check is still outstanding — it needs wms-be running with a policy whose cutoff is inside the hour.
