---
title: 'Page tabs — Outbound, Replenishment, Compliance and Settings behind tab bars, on one shared tab module'
type: 'feature'
created: '2026-10-17'
status: 'done'
baseline_commit: 'cf7dfbdf46423da9651fd8aa313888f7d28f46bd'
route: 'dispatch'
review_loop_iteration: 0
context:
  - 'docs/design/frontend/SYSTEM-DESIGN.md'
  - 'docs/design/frontend/IMPLEMENTATION-GUIDE.md'
  - '_bmad-output/implementation-artifacts/spec-inbound-tabs.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** After Inbound got tabs (spec-inbound-tabs), the user asked (2026-10-17) for the same on Outbound, Replenishment, Compliance and Settings. Today these pages stack 3, 4, 5 and 12 sections on one long page.

**Approach:** Lift Inbound's tab machinery into one shared module, then put each page's sections behind its own tab bar. Each page shows one section (Settings: one group) at a time. Inbound moves onto the shared module, with its counts unchanged. This is a wms-fe-only change.

The tabs, in order. The first tab of each page is its default and is the bare route.

| Page | Tabs (`?tab=` id) | Drill → tab |
|---|---|---|
| `/outbound` | Orders (`orders`) · Waves (`waves`) · Pack & Dispatch (`pack`) | `list=orders` → Orders |
| `/replenishment` | Reorder breaches (`breaches`) · Expiry & aging alerts (`batch-alerts`) · Suggested purchase orders (`suggested-pos`) · Reorder points (`policies`) | `list=batch-alerts` → alerts |
| `/compliance` | Invoices (`invoices`) · Client invoices (`client-invoices`) · E-way bills (`eway`) · HSN summary (`hsn`) · Cold-chain trace (`cold-chain`) | `list=invoices` / `list=eway` → that tab |
| `/settings` | Warehouses (`warehouses`: create form, warehouse list, zones & bins) · Catalog (`catalog`: import, products, SKUs, segregation matrix) · Clients (`clients`: clients, rate cards) · Team (`team`: users & roles) · Devices (`devices`: device enrollment) | none |

**Settings decision (user, 2026-10-17):** five grouped tabs, Warehouses the default; the setup checklist stays above the tab bar (header `SurfacePlaceholder` unchanged); its Continue links map step `warehouse`/`bins` → Warehouses, `catalog` → Catalog, `users` → Team.

## Boundaries & Constraints

**Always:**
- Every page behaves exactly as Inbound does:
  - Outside a drill, the tab is the live URL's `?tab=`, read through `useSearchParams`.
  - A click rewrites the URL in place with `history.replaceState`. The default tab writes the bare route, and clicking the open tab writes nothing.
  - An unknown `tab` falls back to the default.
  - A drill opens on its list's tab, with its banner. Another tab leaves the drill (`router.replace` to `?tab=`). The banner's Clear lands on the drilled list's tab (`clearHref`).
  - The page key is `drillKey|tab`.
  - The markup is `role="tablist"` / `tab` / `tabpanel` with `id`, `aria-controls` and `aria-labelledby`.
- Only the selected section mounts.
- The warehouse picker on Outbound and Replenishment stays above the tab bar, and stays hidden while drilled, as today.
- Tab labels equal their section's heading exactly ("Pack & Dispatch"). The section `<h2>` stays, and section contents don't change. New tests query inside the panel or by `data-tab`, never by bare text.
- Each page's tablist has its own `aria-label` ("Inbound lists" kept; "Outbound lists", "Replenishment lists", "Compliance lists", "Settings sections"). This keeps a section's own status tabs (Replenishment, E-way) distinguishable. Arrow-key roving focus is deferred for all page tabs, as for Inbound and Conflicts.
- The tab bar renders only past each screen's session gate. Outbound and Replenishment already gate before the bar. `compliance-tabs` and `settings-tabs` render nothing until the session is known (the `useSyncExternalStore(subscribeSession…)` pattern).
- One href rule everywhere: a tab's href is the bare route for the default tab, else `?tab=<id>`.
  - This changes Inbound in one place: a drilled click on Purchase orders now replaces to bare `/inbound`, not `/inbound?tab=pos`. This is deliberate: one URL per view.
  - `inboundTabHref` stays exported (`notifications.ts` uses it). Its `qc-holds` result is unchanged.
- The Settings and Compliance pages `await searchParams`, which makes them dynamic like `/inbound`. The tab is never read only on the client, so no Suspense boundary is needed and `next build` stays clean.
- Every existing drill link, notification link and active-warehouse rule keeps working. Every section keeps its content and capability gating.

**Never:**
- No server or API change.
- No counts on the new tabs. They weren't asked for, and each count costs a read per visit.
- No change to any section's contents.
- `useRouter` is never called outside drilled mode (IMPLEMENTATION-GUIDE router rule).
- No `?tab=` on a drill URL. `parseDrill` refuses unknown keys, so a drill link never carries one.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|---|---|---|---|
| Default | `/outbound` | Orders selected; only the orders section mounted; picker above the tabs | N/A |
| Linked tab | `/compliance?tab=hsn` | HSN summary selected and shown | N/A |
| Click | Click "Reorder points" on `/replenishment` | Policies shown; URL `/replenishment?tab=policies`; reload keeps it; no router navigation | N/A |
| Unknown tab | `/settings?tab=nope` | Default tab | N/A |
| Drill | `/replenishment?list=batch-alerts&…` | Alerts tab selected with banner; picker hidden; another tab → `router.replace` to that tab's href (the bare `/replenishment` for Breaches); Clear → `/replenishment?tab=batch-alerts` | Unsupported drill → notice over the default tab, as today |
| Compliance drill | `/compliance?list=eway&…` | E-way bills tab, drilled; Clear → `/compliance?tab=eway` | N/A |
| Notification | Reorder-breach bell entry (`/replenishment`) / batch-alert entry (drill) | Breaches tab / drilled alerts tab | N/A |
| Checklist Continue | Settings checklist step `catalog` pending | Its Continue link opens the tab holding that card | Unknown step key → the server's `href` |
| Warehouse switch | Switch on any tab | That tab's section re-reads for the new warehouse | N/A |

</frozen-after-approval>

## Code Map

Every code path below is relative to `workspace/core/frontend/wms-fe`, on its current branch `feat/inbound-tabs`. Commit there locally when green. Do not push, open PRs or switch branches. Run wms-fe tests with `bun test`; never run two suites at once.


- `src/lib/inbound-tabs.ts`:
  - Today it holds the tab list, `parseInboundTab`, `inboundTabHref`, `initialInboundTab`, and the count helpers (`TabCount`, `tabCountLabel`, `sumTabCounts`).
  - Generalize into `src/lib/page-tabs.ts`. Add a `definePageTabs({ route, tabs, label })` definition with `parse(params)`, `href(tab)` (the default tab → bare route) and `initial(drill, tab, drillTabs)`.
  - `inbound-tabs.ts` keeps its Inbound definition and its count helpers.
- `src/components/inbound/inbound-cards.tsx:110-130,206-262`:
  - The tab state is `useSearchParams` with a local fallback, plus `selectTab` and `InboundTabBar` / `DrillInboundTabBar`.
  - Extract these into `src/components/shared/page-tabs.tsx`:
    - `usePageTab(def, initial, drilled)` returns `[tab, select]`.
    - `PageTabBar` takes `def`, `active`, `onSelect` and an optional `badge(tab) => ReactNode`. Inbound's count pills keep the `data-testid="inbound-tab-count-*"`.
    - `DrillPageTabBar` uses `router.replace`.
  - The ids become `${def.id}-tab-${id}` and `${def.id}-panel`, so Inbound keeps `inbound-tab-*` and `inbound-panel`.
- `src/components/outbound/outbound.tsx:128-170`: the three sections become tab panels under the picker. Thread `initialTab`.
- `src/app/(app)/outbound/page.tsx`: parse `tab` and key the screen on `drillKey|tab`. This applies to all four pages.
- `src/components/replenishment/replenishment-view.tsx:205-272`:
  - The four sections become tab panels.
  - `BatchAlertQueue` (DrillBanner at `:606`) gains a `clearHref` prop.
- `src/app/(app)/compliance/page.tsx`:
  - This is a server component that stacks five sections. Move them into a new client `src/components/compliance/compliance-tabs.tsx`.
  - The sections keep their existing keys (`invoices-${key}`, `eway-${key}`).
  - `EwayBills` (`eway-bills.tsx:308`) and `Invoices` (`invoices.tsx:166`) gain `clearHref`.
- `src/app/(app)/settings/page.tsx`:
  - Today it takes no searchParams. It now parses `tab`.
  - A new client component `src/components/settings/settings-tabs.tsx` holds the groups. `SurfacePlaceholder` and `SetupChecklistCard` stay above the tab bar.
- `src/components/settings/setup-checklist-card.tsx:70`:
  - Continue uses `step.href`. The backend (`wms-be tenancy.service.ts:1001-1026`) sends `/settings` for steps `warehouse`, `bins`, `catalog` and `users`.
  - Map the step key to its tab href on the web. An unknown key falls back to `step.href`.
- `src/components/drill/drill-screens.test.tsx`:
  - `CASES` (outbound, replenishment, compliance) and `PAGE_CASES` need `clearTo` for batch-alerts and eway.
  - `'compliance: list picks the keyed section — the other renders normally'` (`:1152`) asserts that both sections render. Rewrite it: the other tab is unmounted, and selecting it reads normally.
  - `page()` (`:326`) parses `tab` for Inbound only. Give it a `screen → tab definition` map so every tabbed screen gets `initialTab`.
  - The E-way and Invoices CASES (`:483`, `:497`) render `EwayBills` and `Invoices` bare. Switch both to `ComplianceTabs`, so Clear's `clearHref` is the real one, and keep their `controls` and `normal` checks working.
  - `'the normal view still has its controls'` (`:699`) mounts with `{}`. Each case mounts with `{ tab: <its list's tab> }` instead (a new per-case `normalParams`).
  - The PAGE_CASES unsupported-link test (`:1132`) loops over `reads(list)`, which is empty on a non-default tab. Assert the default tab's own read instead.
  - The drill CASE's sibling-warehouse check (`:555-566`, "waves reads orders too") becomes vacuous once Waves is unmounted. Delete the branch and say so in a comment.
- `src/components/replenishment/replenishment-view.test.tsx` (22 tests, `mount` at `:380`) mounts the whole view and drives every section.
  - `mount(session, tab)` renders `<ReplenishmentView initialTab={tab} />` and never clicks. A click would first mount Breaches and pollute the "mounting sends reads only" tests (`:423`, `:603`).
  - One separate test covers the click.
- `src/components/outbound/outbound.test.tsx:214`, "all three surfaces render…", asserts that Waves and Pack render together on the default mount.
  - Rewrite it: the default mount shows Orders only, and the Pack tab (`initialTab='pack'`) remounts on a warehouse switch. Use panel-scoped text.
- `src/components/shared/drill-banner.tsx:27-33`: the comment names Inbound's drilled tab bar as the only other router user. Change it to the shared `DrillPageTabBar`.
- Do not touch: the section components' internals beyond the `clearHref` prop; `lib/drill.ts`; `notifications.ts`. Its links already land correctly: bare `/replenishment` lands on breaches, and the batch-alert drill lands on alerts.

## Tasks & Acceptance

**Execution:**
- [x] `src/lib/page-tabs.ts` + `page-tabs.test.ts`: add the definition type and `parse`/`href`/`initial`, with pure tests (default → bare route, unknown → default, drill wins). Move Inbound onto it.
- [x] `src/components/shared/page-tabs.tsx`: add `usePageTab`, `PageTabBar` and `DrillPageTabBar`. Refactor `inbound-cards.tsx` onto them. The Inbound tests stay green unchanged, apart from helper renames.
- [x] `outbound.tsx` + its page: tabs; Clear on an orders drill → bare `/outbound`, since orders is the default tab.
- [x] `replenishment-view.tsx` + its page: tabs; `BatchAlertQueue` `clearHref`.
- [x] `compliance-tabs.tsx` + its page: tabs; `Invoices` and `EwayBills` `clearHref`.
- [x] `settings-tabs.tsx` + its page + `setup-checklist-card.tsx`: tabs per the decided grouping; Continue → the tab of each step.
- [x] Tests: drill-screens (`clearTo`, the compliance rewrite, a per-page tabs block mirroring Inbound's), the replenishment-view mount, a settings tabs test, and a checklist link test.
- [x] Meta docs: the frontend SYSTEM-DESIGN rows for the four routes, and the IMPLEMENTATION-GUIDE router rule naming the shared `DrillPageTabBar`.

**Acceptance Criteria:**
- Given any of the four pages, when it loads with no `tab`, then the default tab is selected and only its section's reads are sent.
- Given a drill on Outbound, Replenishment or Compliance, when Clear is clicked, then the router pushes that list's tab href, and no other section's drill state survives.
- Given an unchanged Inbound, when its existing tests run, then they pass, counts included.

## Implementation Notes

wms-fe `feat/inbound-tabs`, commit `90196e6` (amended after review; local, not pushed).

- `definePageTabs` keeps `drillTabs` on the definition, and `initial(drill, tab)` reads it. The review dropped the spec's third override parameter, because nothing in production called it. The four page definitions and `setupStepHref` live in `lib/page-tabs.ts` beside the generic part. The element-id prefix comes from the route (`/inbound` → `inbound`), so Inbound keeps `inbound-tab-*` / `inbound-panel`.
- `components/shared/page-tabs.tsx` adds two helpers beyond the spec's three: `PageTabStrip` (picks the normal or drilled bar) and `PageTabPanel` (the one tabpanel).
- Outbound's orders section takes no `clearHref`: its drill tab is the default, and `DrillBanner`'s fallback is the bare pathname, which is the same URL.
- Settings: the Settings page's key is the tab alone (`tab ?? 'default'`), because Settings takes no drill.
- Tests: `page-tabs.test.ts` (pure); `drill-screens.test.tsx` (a `SCREEN_TABS` map in `page()`; `clearTo`/`normalParams` per case; E-way and Invoices cases mount `ComplianceTabs`; the compliance rewrite; the unsupported-link test asserts the default tab's read; the sibling branch is deleted with a comment; and a per-page tabs block over Outbound, Replenishment and Compliance, which checks every label against its panel's `<h2>`); `replenishment-view.test.tsx` (`mount(session, tab)`, the operator test walks each tab's panel, plus one click test); `outbound.test.tsx` (split into a default-mount test and a Pack-tab warehouse-switch test); and the new `settings-tabs.test.tsx` (tabs, the session gate via `renderToString`, and the checklist links).
- Verification: typecheck and lint are clean. `bun test` gives 1598 pass / 0 fail. `bun run build` succeeds. `/settings` is now `ƒ`. `/compliance` was already `ƒ` before this change, because it awaited `searchParams` for 9-1b; the spec's "static to dynamic" is true of `/settings` only.

## Spec Change Log

## Review Triage Log

Design review: one pass, 12 findings. The evidence was spot-checked against the code: `page()` at `drill-screens.test.tsx:326`, the controls block at `:699`, `outbound.test.tsx:214`, and the sibling check at `:555`.

| # | Finding | Verdict | Disposition |
|---|---|---|---|
| 1 | `page()` passes a tab for Inbound only | high | Code Map: a screen → tab definition map |
| 2 | The "normal view has its controls" block mounts the default tab | high | Code Map: per-case `normalParams` |
| 3 | The E-way CASE renders `EwayBills` bare, so `clearTo` can't pass | high | Code Map: the CASE switches to `ComplianceTabs` |
| 4 | The unsupported-link loop and the outbound sibling check go vacuous | medium | Code Map: assert the default tab's read; delete the sibling branch |
| 5 | `outbound.test.tsx` "all three surfaces render" breaks | high | Code Map: rewrite with panel-scoped text |
| 6 | "Pack & dispatch" label vs "Pack & Dispatch" heading; text matches doubled | medium | Always: labels equal headings; `<h2>` kept; panel-scoped queries |
| 7 | Inbound's href rule changes: drilled Purchase orders → bare route | medium | Always: explicit and deliberate; `inboundTabHref` stays exported; matrix corrected |
| 8 | Settings becomes dynamic; the Suspense rule; build not in Verification | medium | Always + Design Notes; `bun run build` added |
| 9 | The Compliance/Settings tab bar renders before any session gate | medium | Always: the wrappers gate on the session |
| 10 | The Replenishment test `mount` clicking pollutes reads and the URL | medium | Code Map: `initialTab` prop; one click test |
| 11 | drill-banner router comment; stale `:1170` | low | Code Map fixed |
| 12 | Nested tablists unlabelled; no arrow keys | low | Always: per-page `aria-label`; arrow keys deferred |

Code review: one pass over `cf7dfbd..90196e6`, with three layers (blind hunter 14 findings, edge-case hunter 3, verification gap 1). The patch round was applied by the implementer and re-verified: typecheck, lint, `bun test` 1603/0 and `bun run build` are clean.

| # | Finding | Verdict | Disposition |
|---|---|---|---|
| C1 | VG: the `drilled ||` guard in `usePageTab` is never hit with live search params; dropping it would send every drill to the default tab and all tests would still pass | medium | **patch.** The drill tests now set the drill's own URL before mounting. Removing the guard now fails 3 tests (Outbound can't catch it: its drill tab is its default) |
| C2 | Unsaved form input and cursors are lost on a tab switch | low | **reject.** Frozen intent: "Only the selected section mounts" (same as Inbound). Changing it would edit the spec |
| C3 | The Settings page comment gives the wrong reason for no Suspense | low | **patch.** The comment now says the `await` is load-bearing |
| C4 | `/settings` (operator home) is no longer prerendered | low | **reject.** Decided in the spec (Always + Design Notes) |
| C5 | The user-chosen Settings grouping is untested | medium | **patch.** A per-tab, panel-scoped card-heading test |
| C6 | The signed-out test name over-promises | low | **patch.** It now also asserts a card's signed-out copy |
| C7 | The outbound sibling-read check was removed (Waves/Pack after leaving a drill) | false | **reject.** Waves and Pack only ever receive the active `warehouseId` (`outbound.tsx`), never the drill's, and leaving the drill remounts with no drill |
| C8 | Settings is absent from TAB_PAGES (live-URL, open-tab no-op) | low | **reject.** Same `usePageTab`/`PageTabBar` code, covered on four pages. Settings has its own click and `?tab=` tests |
| C9 | `SETUP_STEP_TAB` typed `Record<string,…>` despite the generated closed union | low | **patch.** Typed on `SetupChecklistStepResponse['key']`, with the unknown-key fallback kept |
| C10 | A tab click drops other query params and the hash (blind + edge-case) | low | **reject.** One URL per view is the spec's rule (as on Inbound). No tabbed page uses a hash or other non-drill params, and preserving them adds branches |
| C11 | Arrow-key roving and `tabIndex` deferred across five pages | low | **defer.** `deferred-work.md` entry; the spec already deferred it explicitly |
| C12 | `initial`'s third `drillTabs` parameter has no caller | low | **patch.** Deleted |
| C13 | `definePageTabs` doesn't validate duplicate ids / bad `drillTabs` / `?` in route | low | **reject.** Five static literal definitions, all exercised by tests; guards add surface for a mistake nobody makes at runtime |
| C14 | `TAB_PAGES`/`PAGE_CASES` index `CASES[n]` | low | **reject.** A pre-existing pattern (PAGE_CASES did this before the story) |
| C15 | Leftover Inbound wrappers; stale `pressExpand` comment; redundant selector | low | **patch** (comment and selector). The wrappers are kept: `inboundTabHref` is the notification link's public name |
| C16 | Edge-case: a repeated `?tab=` makes the client take the last value while the server reads null | low | **patch.** `getAll('tab')`; anything but one value is null on both paths, with a test |
| C17 | Edge-case: the `parse` comment overclaims "repeated → null on every path" | low | **patch** (with C16) |

## Design Notes

**Why one module.** Inbound's rules took a review round to get right: a stale tab after `replaceState`, the default tab as the bare route, and no write when the open tab is clicked. Five pages each re-deriving those rules is exactly the drift the design docs exist to stop.

**Settings becomes dynamic.** Today `/settings` is prerendered, so its static shell is served from the build. Reading `searchParams` makes it render per request, like `/inbound`. A client-only `useSearchParams` in a prerendered route would need a `<Suspense>` boundary or `next build` fails, so `bun run build` is in Verification.

**Checklist wording.** The backend's step detail says "create one below" and "import your catalog below". This is still roughly true with the checklist above the tabs, because Continue opens the right tab. Rewording it is a backend change and is out of scope here.

## Verification

**Commands:**
- `bun run typecheck` -- expected: clean
- `bun run lint` -- expected: clean
- `bun run build` -- expected: success (`/settings` and `/compliance` change from static to dynamic routes)
- `bun test` (wms-fe) -- expected: 0 fail. Re-run alone any `ledger-integrity` flake.

**Manual checks:**
- On http://localhost:3001: click through all four pages, reload on a non-default tab, open an Overview tile drill into Outbound, Replenishment and Compliance, and click Clear.
