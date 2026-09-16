---
title: 'Story 4-2b: Outbound orders web surface'
type: 'feature'
created: '2026-09-16'
status: 'done'
route: 'dispatch'
review_loop_iteration: 1
baseline_commit: 'b8f0257' # wms-fe main
context:
  - '_bmad-output/implementation-artifacts/epic-4-context.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** `/outbound` is a 12-line `SurfacePlaceholder`. Six backend stories (4.1–4.6) shipped an entire order lifecycle with **no web consumer at all** — nobody can create, inspect or cancel an order from the browser. Meanwhile `wms-fe/src/lib/users.ts` — the UI capability mirror — has drifted to **eight** capabilities behind `wms-be/src/modules/tenancy/permissions.ts` (21 vs 13), so every surface that should gate on one cannot even name it.

**Approach:** The Outbound **orders** surface: a warehouse-scoped list whose rows expand into per-line detail, manual multi-line order creation, and cancel — with the capability mirror restored in full so this and later surfaces can gate correctly.

**Decided (2026-09-16, human):**
- **Orders only.** Waves/picklists (`4-2c`) and pack + dispatch (`4-2d`) are split out and recorded in `deferred-work.md`. The epic's "retryable inline label error" is **blocked, not deferred** — labels live in `4-6c`, which is backlog.
- **The status filter filters the LOADED PAGE and says so.** The list API has no status filter, no sort and no search — `cursor` + `limit` only, fixed newest-first. The control is labelled as page-scoped ("Filter this page", with an "N of M on this page" count) rather than implying a global search. One request, scales to any order volume, and never lies about what it searched. Walking all pages was rejected as O(all orders) on every load with a silent cliff at the walker's 20-hop cap.

**Decided (technical, from investigation):**
- **Components never import the generated SDK.** The house rule is hand-written `fetchApi*` wrappers in `src/lib/api/client.ts` (~40 of them); Outbound adds its wrappers there first, and they own the `Idempotency-Key` header.
- **Detail is an expanded row, not a route.** No `[id]` route exists anywhere in this app. The list row carries no quantities — `OrderEntryDto` is `OrderDto` minus `lines`, with no `lineCount` or `totalUnits` — so expanding a row fetches that order's detail once.
- **Cancel is offered only when `status === 'accepted'`.** Two of its three `409` causes (committed reservations, drawn pick lines) are invisible in every DTO field, so they cannot be predicted client-side: render the server's `title`/`detail` verbatim.
- **Over-ATP is a normal outcome, never an error.** Acceptance reserves `min(qty, atp)`; the order still returns `201 accepted` with `reservedQty < qty`, `shortfallQty > 0` and line `status: 'backordered'`. The create result must read as success-with-shortfall.
- **The mirror is restored in full (8 additions), not just the 5 outbound ones** — `po.manage`, `vendor.manage` and `stock.adjust` are equally missing. Inert today (TypeScript rejects gating on a capability absent from the union, so nothing can be gating on them), and leaving known-wrong entries in the file being edited invites the next drift.

## Boundaries & Constraints

**Always:**
- Follow the house patterns exactly: a thin server `page.tsx` exporting `metadata` that renders one `'use client'` component under `src/components/outbound/`; a bespoke hook (`useSyncExternalStore` for session + `useEffect` fetch + `revision` counter); a `src/lib/outbound.ts` change-event broadcaster; the shared `DataTable` with its keyset `nextCursor`/`onCursor` contract; `FeedbackBanner` for outcomes.
- **Pure logic is extracted into `src/lib/` so it can be tested.** This repo has **no component tests at all** — no jsdom, no testing-library, zero `.test.tsx`; all 77 tests live in `src/lib/`. The error mapper and any status/quantity formatting go in `src/lib/outbound*.ts`, the way `over-receipt.ts` was carved out of its queue component. New `fetchApi*` wrappers get stubbed-`fetch` tests in `src/lib/api/client.test.ts`.
- **Capability gating hides, never blocks.** Reads stay open to every role; only mutating affordances are gated on `orders.manage` (Owner + Ops Manager — **not** Operator). **The nav entry stays UNGATED** (amended 2026-09-16 — see the Spec Change Log), matching `inbound` and `inventory`; `conflicts` is gated only because it is a pure action queue.
- Every mutating call carries a fresh `ulid()` as its `Idempotency-Key`, generated per submit.
- The warehouse picker precedes the list — the list endpoint is warehouse-scoped.
- `ROLE_CAPABILITIES` mirrors `permissions.ts` grants exactly: Operator does **not** hold `orders.manage`; Accountant holds nothing.

**Never:**
- No waves, picklists, pack or dispatch UI; no carrier or label anything.
- No new backend endpoint, no OpenAPI change, no `api:generate` — the generated client already carries every operation this needs.
- No `[id]` route, no data-fetching library, no schema-validation library, no component-test framework — four house conventions this story does not get to change.
- No action offered that the backend will refuse for a state the row already shows.
- No server-side filtering, sorting or searching invented client-side and presented as global.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| List orders | a warehouse selected | newest-first page: id, status, source, channel refs, timestamps; `nextCursor` drives Prev/Next | unreachable API → `FeedbackBanner` with the house fallback copy |
| Expand a row | a row toggled open | one detail fetch; per line the ordered / reserved / shortfall quantities and hold state | detail fetch fails → inline message on that row only, list unaffected |
| Filter the page | a status chosen | only matching rows of the **loaded page**, with an "N of M on this page" count | N/A |
| Create a fully-reservable order | 1+ lines within ATP | `201`; every line `open`, `shortfallQty` 0; list refreshes via the change event | N/A |
| Create an over-ATP order | a line above ATP | `201` reported as **accepted with a shortfall**, naming the backordered lines — not an error | N/A |
| Create with a bad body | 0 lines, or >200, or a non-positive quantity | nothing sent, or `400` surfaced | native form validation first; `validation-failed` rendered from the server otherwise |
| Cancel an accepted order | `status === 'accepted'` | confirmation, then `200`; the row reads `cancelled` | N/A |
| Cancel refused by state | committed reservations, or drawn pick lines | nothing changes | `409` — the server's `title` and `detail` rendered verbatim, since neither cause is visible client-side |
| Cancel not offered | `cancelled`, `ready_to_dispatch` or `dispatched` | no cancel affordance on the row at all | N/A |
| Role without `orders.manage` | Operator or Accountant session | list and detail fully readable; no create form, no cancel affordance | N/A |

</frozen-after-approval>

## Code Map

- `workspace/core/frontend/wms-fe/src/app/(app)/outbound/page.tsx` — the 12-line placeholder to replace. Keep the `metadata` export; render one client component. Template: `src/app/(app)/inbound/page.tsx:1-6`.
- `workspace/core/frontend/wms-fe/src/components/settings/zone-bin-setup.tsx` — **the richest reference surface** (884 lines): master picker → create forms → cursor-paginated table → row actions with inline confirmation → per-action capability gating (`:117-121` computing booleans, `:709-778` conditionally appending the `actions` column, `:783-827` the inline confirm panel). `src/components/inbound/inbound-cards.tsx` is the model for a multi-card surface.
- `workspace/core/frontend/wms-fe/src/lib/api/client.ts` — `ApiProblem` (`:133-144`), `unwrapError` (`:146-151`), the bearer interceptor (`:107-117`), and the ~40 `fetchApi*` wrappers (`:157-796`) whose shape the new Outbound wrappers copy. Mutating wrappers take the idempotency key as their last argument and set the header (`:173`).
- `workspace/core/frontend/wms-fe/src/lib/use-zone-bins.ts:24-105` — the canonical hook: `useSyncExternalStore(subscribeSession, …)`, `useEffect` fetch, `revision` counter, change-event subscription (`:54-58`), failures swallowed to `null`.
- `workspace/core/frontend/wms-fe/src/lib/zones.ts:10-14` — the three-line change-event module to copy as `src/lib/outbound.ts` (`OUTBOUND_CHANGED_EVENT = 'wms-outbound-changed'`).
- `workspace/core/frontend/wms-fe/src/components/data-table/data-table.tsx:11-99` — `DataTableColumn` (`key`, `header`, `numeric?`, `render?`), keyset pagination at `:36-40, :79-96`. **No loading or error state inside** — the surface owns those. Wiring example: `zone-bin-setup.tsx:828-834`.
- `workspace/core/frontend/wms-fe/src/lib/over-receipt.ts:18-38, :44-68` — the precedent for extracting an error mapper into `src/lib/` for testing; `over-receipt.test.ts` is its test. Shared problem codes every mapper handles: `idempotency-key-reuse`, `unauthenticated`, `validation-failed`, `role-denied`, `not-found`.
- `workspace/core/frontend/wms-fe/src/lib/users.ts:16-44` (`CAPABILITIES`), `:46-54` (`ROLE_CAPABILITIES`), `:56-59` (`roleHasCapability`) — the mirror. Eight additions; the authority is `wms-be/src/modules/tenancy/permissions.ts:93-119`.
- `workspace/core/frontend/wms-fe/src/lib/navigation.ts:30` — the `outbound` nav item, today with **no** `capabilities` key. `:41` `NAV_ITEM_COUNT = 12` is asserted by `navigation.test.ts`; `visibleNavItems` at `:48-54`.
- `workspace/core/frontend/wms-fe/src/lib/ulid.ts:28` — `ulid()`, already present; the idempotency key per submit.
- `workspace/core/frontend/wms-fe/src/lib/fetch-all-pages.ts:19-28` — the bounded (20-hop) page walker. Used **only** for the SKU picker, which has no server-side search; **not** for the order list.
- `workspace/core/frontend/wms-fe/src/lib/api/generated/sdk.gen.ts:486, :499, :538, :547` — create / cancel / get / list. `Idempotency-Key` is a **typed required header** on the Data type (`types.gen.ts:4153-4159, 4213-4219`); cancel's body is required and is `{}`.
- `workspace/core/frontend/wms-fe/src/lib/api/generated/types.gen.ts:1089-1118` (`OrderDto`, four-arm `status` at `:1096`), `:1306-1322` (`OrderEntryDto` — no `lines`), `:1055-1087` (`OrderLineDto` — `qty`/`reservedQty`/`shortfallQty`, `status: 'open'|'backordered'`, **no `skuCode`/`skuName`**), `:4441-4448` (list query: `cursor`/`limit` only).
- `workspace/core/frontend/wms-fe/src/lib/api/client.test.ts:27-45` — how a wrapper test shims `fetch` and `localStorage`. `src/lib/users.test.ts:14-27` shims `window` for the event broadcaster.

## Tasks & Acceptance

**Execution:**
- [x] `wms-fe src/lib/users.ts` — restore the mirror: 8 capabilities into `CAPABILITIES` and the matching `ROLE_CAPABILITIES` grants
- [x] `wms-fe src/lib/users.test.ts` — pin the mirror against the backend's grants (Operator lacks `orders.manage`; Accountant holds nothing)
- [x] `wms-fe src/lib/navigation.ts` — the `outbound` nav item (amended 2026-09-16: stays **ungated**; the test pins that it is visible to every role)
- [x] `wms-fe src/lib/outbound.ts` — the change-event broadcaster
- [x] `wms-fe src/lib/api/client.ts` — `fetchApi` wrappers for list / get / create / cancel orders, and the SKU list page walk
- [x] `wms-fe src/lib/api/client.test.ts` — stubbed-`fetch` tests for the new wrappers, including the `Idempotency-Key` header
- [x] `wms-fe src/lib/outbound-orders.ts` — the extracted pure logic: the problem-code → message mapper, and the derived line/shortfall formatting
- [x] `wms-fe src/lib/outbound-orders.test.ts` — its unit tests, `over-receipt.test.ts` style
- [x] `wms-fe src/lib/use-outbound-orders.ts` — the resource hook
- [x] `wms-fe src/components/outbound/outbound-orders.tsx` — the surface: warehouse picker, page filter, table with expandable detail, create form, cancel with confirmation
- [x] `wms-fe src/app/(app)/outbound/page.tsx` — replace the placeholder

**Acceptance Criteria:**
- Given a role without `orders.manage`, when the Outbound surface loads, then the list and expanded detail are fully readable and no create form or cancel affordance is rendered
- Given an order whose status is not `accepted`, when its row renders, then no cancel affordance is offered for it
- Given a cancel the backend refuses for committed reservations or drawn pick lines, when it returns `409`, then the server's title and detail are shown verbatim and no row changes
- Given a created order that exceeded ATP, when the result renders, then it reads as accepted with a named shortfall rather than as a failure

## Implementation Notes

All eleven execution tasks landed in `wms-fe` on `feat/4-2b-outbound-orders-surface`; `bun run test && lint && typecheck && build` are clean (77 → 114 tests).

Three decisions the spec left open, and what was chosen:

1. **`ApiProblem` now carries `title`.** AC 3 requires the 409 cancel refusal to render the server's `title` *and* `detail` verbatim, but `unwrapError` was dropping `title` on the floor — every surface to date branched on `code` alone. The field is optional and additive (`client.ts` `ApiProblem` / `unwrapError` / `isProblemDetails`); no existing caller changes. `cancelReason` renders `title — detail` for any 409 and falls back to whichever half the server sent.

2. **`DataTable` gained an opt-in `renderExpanded?: (row) => ReactNode`.** The table had no expansion slot and the spec forbids an `[id]` route, so the alternative was faking detail inside a narrow cell or hanging a panel below the table (which is not "on that row"). The prop renders one extra full-width `<tr>` beneath the row; omitting it leaves every other surface byte-identical. The owning surface still decides which row is open and does the fetching.

3. **The nav item stays ungated.** First implemented as `capabilities: ['orders.manage']` per the original frozen Boundaries; flagging the consequence — Operator and Accountant would lose the *nav entry* while the I/O matrix row promises them a readable list — surfaced the contradiction, and the frozen block was amended (see the Spec Change Log). `outbound` now carries no `capabilities` key, matching `inbound` and `inventory`. Two tests hold the line: one pins the entry visible to all four roles *and* to an unknown role, so a later story cannot quietly re-gate it; the other pins that gating never moves `NAV_ITEM_COUNT` (still 12). The per-action gating on `orders.manage` inside the component is unchanged.

Reuse rather than new code: the SKU picker and the line SKU codes both come from the existing `useSkuMap` in `src/lib/use-inbound.ts`, which already walks the full keyset chain via `fetchAllPages` — so no new SKU wrapper or page walker was written. (An outbound component importing from `use-inbound` is a naming wart; the hook is catalog-wide, not inbound-specific, and moving it is a refactor this story did not take.)

Not done here, deliberately: the meta-repo interface contracts (`docs/repos/wms-fe/README.md`) — meta docs land last, in their own PR, per the cross-repo ordering rule.

## Spec Change Log

**2026-09-16 — frozen-block amendment during implementation (renegotiated with Sasidhar).**

The frozen Boundaries contradicted itself: it required that "reads stay open to every role" *and* that the nav entry be
capability-gated. With the entry gated on `orders.manage`, the I/O matrix row asserting an Operator or Accountant can
read the list and detail was reachable only by typing a URL — true on paper, false as a user path. The implementation
agent implemented the explicit instruction and flagged the consequence rather than silently resolving it, which is the
right call and is what surfaced the conflict.

**Resolved:** the nav entry stays ungated. This matches the two comparable read-open surfaces (`inbound`, `inventory`);
`conflicts` is gated only because there is nothing to read in an action queue you cannot act on. It also survives the
follow-on stories with no edit — Operators hold `pack.execute` and `dispatch.execute` and will need this route when
`4-2d` lands, whereas a gate on `orders.manage` would have had to be widened then.

**KEEP on any re-derivation:** the mutating affordances stay gated on `orders.manage`, Operator still does not hold it,
and the list plus expanded detail stay readable by every role including Accountant.

## Review Triage Log

**Loop 1 — three layers (blind hunter 13, edge-case 11, verification-gap 3 + 4). 31 findings, grouped by shared root
cause into 21 entries: 19 patched, 1 deferred, 1 rejected. No `intent_gap`, no `bad_spec` — no loopback.**

*The nav-gating contradiction was caught and resolved DURING implementation, before review; see the Spec Change Log.*

| # | Entry (members merged by root cause) | Verdict | Evidence |
|---|---|---|---|
| 1 | **Failures are swallowed into `null`, and `null` renders as a permanent loading state** — the order list ("Loading orders…" forever), the SKU list ("Loading SKUs…"), and the warehouse list (a completely blank surface with no heading) | **high — patch** | All 3 layers; I confirmed the list arm myself at `use-outbound-orders.ts:76-81`. One pattern, not three bugs — and `useOrderDetail` in the same file already shows the right shape with an explicit `failed` arm. Directly contradicts the I/O matrix row "unreachable API → `FeedbackBanner` with the house fallback copy" |
| 2 | The comment at `use-outbound-orders.ts:79` vouches for a guarantee held nowhere — "the surface reports the unreachable API itself" | **high — patch** | Same root cause as #1; a comment asserting behaviour that does not exist is worse than none |
| 3 | **The session role is read unsubscribed** (`readSession()` at render), so a role change mid-visit never re-renders the create form or the Cancel column | **high — patch** | All 3 layers. Every sibling gated surface subscribes and says why in a comment (`over-receipt-queue.tsx:69-74`, `inbound-cards.tsx:291`, `sku-table.tsx:66`). `AppShell` fires `refreshSessionUser()` on mount, so the stale-affordance window is every visit after a role change |
| 4 | The `Idempotency-Key` is minted per ATTEMPT, so a retry after a timeout raises a second order — and the comment claims the opposite ("a double click replays the original response") | **medium — patch** | blind + edge. The fresh-key-per-submit matches house convention, so behaviour is defensible, but the stated reasoning is backwards and it hides a real gap: a create that times out after the server committed cannot be safely retried |
| 5 | `parseDraftLines` accepts values `type="number"` cannot produce and the backend refuses — `1e3` → 1000, `0x10` → 16, and anything above `@Max(2147483647)` | **medium — patch** | blind + edge, same function. It is documented as the guard that stops a body the backend would only 400 |
| 6 | **The order-totals sentence — the story's whole shortfall claim — lives in JSX and is unpinned** | **medium — patch** | v-gap, pre-verified by mutation: delete the shortfall clause, or swap `reservedQty` for `qty`, and all 114 tests still pass while the panel claims an over-ATP order is fully reserved. Every other copy decision was extracted to `src/lib/`; this one was not |
| 7 | **The capability mirror gained 8 entries with nothing preventing the next drift** | **medium — patch** | v-gap + blind. `users.test.ts` only restates the file under test. Not hypothetical: `stock.adjust`, `vendor.manage` and `po.manage` were missing since epics 2–3 and nothing caught it. The `generated-client` CI job already checks out `wms-be` — the guard belongs there |
| 8 | Table state leaks across warehouses — `OrdersTable` is not keyed, so cursor, filter, expanded row and pending confirm all persist | **medium — patch** | edge; Prev stays enabled on what is now page one |
| 9 | Creating or cancelling while paged past page one refetches the current page, so the banner reports acceptance the list cannot show | **medium — patch** | edge |
| 10 | Two cancels can be in flight — the busy guard is per-row, but `busyId` and the outcome banner are single | **low — patch** | edge |
| 11 | Draft rows keyed by array index while any row can be removed, so React reuses the wrong DOM nodes | **low — patch** | blind; focus, IME composition and validation bubbles follow the index |
| 12 | Exhaustiveness gaps: `ORDER_STATUSES` is hand-duplicated and unguarded, `ORDER_SOURCE_LABEL` is not `Record`-typed | **low — patch** | blind + edge, one root cause. `ORDER_STATUS_LABEL` directly above already has the protection both lack |
| 13 | `holdStateLabel` mixes house copy with raw enum values — "Held" but "Hold: committed" | **low — patch** | blind; the test pinned the inconsistency rather than catching it |
| 14 | `detailReason` has no `permission-denied` arm, so a documented refusal falls through to raw server prose in a `role="alert"`; four `createReason` arms untested | **low — patch** | blind; the backend genuinely raises `order-source-conflict` and `conflict` |
| 15 | The expanded row is not associated with its toggle (`aria-expanded` with no `aria-controls`, no `id` on the injected row); Remove buttons announce bare "Remove" | **low — patch** | blind; one attribute each |
| 16 | `createOutcome` enumerates every short line into one banner — a paragraph at the 200-line maximum | **low — patch** | blind; same cap-and-count fix 4.6 applied |
| 17 | `useOutboundOrders` exposes a `reload` nobody calls | **low — patch** | blind; every sibling hook's `reload` is invoked |
| 18 | The `ops_manager` grant is hand-copied under a comment stating it is derivable, and the test only checks its LENGTH | **low — patch** | blind; a list of the right length with a wrong member passes today |
| 19 | The 409 test fixture is not the shape `wms-be` sends, and the title-only branch it pins cannot occur | **low — patch** | v-gap; I verified: `ProblemException` sets `message: detail ?? title` and the filter renders `title` from `exception.message`, so `title === detail` on every cancel refusal. `verbatim()` handles the equality correctly, so rendered copy is right — but `ApiProblem.title` is INERT for these, not load-bearing as I claimed when approving it. Keep the field (RFC 9457 hygiene); fix the fixture to match reality |
| 20 | The list cursor is scoped by `warehouseId` alone where siblings scope by tenant + warehouse | **low — patch** | v-gap; the render-time guard prevents stale display, so the effect is one replayed request after a tenant switch |
| 21 | **The `DataTable` expanded-row branch ships with no test of any kind** | **defer** | v-gap, pre-verified: render the detail row unconditionally or hard-code `colSpan={1}` and all 114 tests pass, injecting a stray row into six unrelated surfaces. Closing it needs DOM test infrastructure this repo has never had — which the frozen block explicitly forbids this story from introducing. Recorded in `deferred-work.md` as the first test that infrastructure should carry |
| 22 | Claim check: the spec's task line promised a "SKU list page walk" in `client.ts` that the diff never adds | **low — rejected** | edge (low confidence, correctly). The agent reused the existing `useSkuMap`/`fetchAllPages` walker instead, which satisfies the intent better than a duplicate. The task text over-promised, not the code, and the fix would edit this build's spec |

## Design Notes

**Why the filter is page-scoped and labelled.** The API offers `cursor` + `limit` and nothing else. A control that says "Filter" while searching only what happens to be loaded is the kind of thing that quietly misleads for months. Naming the scope in the control costs one word and makes the constraint visible to whoever eventually decides whether to push the filter into the backend — which is where it belongs, and where `4-2c` or a later story can put it.

**Why detail is an expanded row.** Not a preference — no `[id]` route exists in this app, and the list row genuinely cannot carry quantities: `OrderEntryDto` omits `lines` and offers no `lineCount` or `totalUnits`. Expanding fetches once, which is the same shape the inbound cards already use.

**What this story cannot verify.** There is no component-test infrastructure here at all, so the screen itself is unverified by construction — the tests pin the wrappers, the mapper and the mirror. Introducing jsdom + testing-library would be a real improvement and a separate change; doing it inside this story would make a frontend surface story also a test-infrastructure story.

## Verification

**Commands:**
- `cd workspace/core/frontend/wms-fe && bun run test && bun run lint && bun run typecheck && bun run build` — all clean. Note `navigation.test.ts` asserts `NAV_ITEM_COUNT`; gating the nav item must not change the count.
- Manual: sign in as Owner, Ops Manager, Operator and Accountant in turn and confirm the create form and cancel affordance appear only for the first two, while the list and expanded detail read for all four.
