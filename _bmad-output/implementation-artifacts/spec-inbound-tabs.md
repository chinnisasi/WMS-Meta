---
title: 'Inbound tabs — the five Inbound cards behind a tab bar, linkable and reload-safe'
type: 'feature'
created: '2026-10-17'
status: 'done'
route: 'oneshot'
review_loop_iteration: 1
context:
  - 'docs/design/frontend/SYSTEM-DESIGN.md'
  - 'docs/design/frontend/IMPLEMENTATION-GUIDE.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** The Inbound page stacks five cards on one long page: Purchase orders, Advance shipment notices, Goods receipt notes, Awaiting putaway, QC holds. The user asked (2026-10-17) for tabs inside Inbound, so each list is easy to consume.

**Approach:** A tab bar on `/inbound` (wms-fe only) shows one card at a time. It reuses the Conflicts tab pattern (`components/conflicts/queues.tsx`): `role="tablist"`, `aria-selected` buttons, same styling.
- **Tabs, in order:**
  - "Purchase orders" (`?tab=pos`);
  - "Advance shipment notices" (`asns`);
  - "Goods receipts" (`grns`);
  - "Awaiting putaway" (`putaway`);
  - "QC holds" (`qc-holds`).
- **Default:** Purchase orders.
- **Linkable and reload-safe:**
  - `?tab=<id>` selects the tab on load.
  - Clicking a tab updates the URL with `router.replace` (no scroll jump, no history spam).
  - An unknown `tab` value falls back to the default.
  - Parsing happens in a pure `parseInboundTab` in `lib/inbound-tabs.ts`, the `parseQueueParam` precedent.
- **Drills still work.** A 9-1b drill (`?list=grns` / `?list=putaway`) opens with its tab selected and its drill banner. The tab bar stays visible, and clicking another tab leaves the drill (`router.replace` to `?tab=<id>`), so the other lists stay one click away, as they were on the stacked page. Clear returns to the tabbed page.
  - `parseDrill` refuses unknown keys, so a drill URL never carries `tab`, and `tab` is never added to a drill.
  - The page key joins drill and tab, so following a different link remounts.
- **The active-warehouse behaviour is unchanged.** Every card reads the same warehouse as today.
- **Only the selected card mounts,** so only its list is fetched. Switching tabs re-reads that list, as navigating does today.
- **Notifications:** the `qc-hold` notification link (`lib/notifications.ts`) becomes `/inbound?tab=qc-holds`.
- **No server change, and no change to any card's contents.**

## I/O & Edge-Case Matrix

| Scenario | Input | Expected |
|---|---|---|
| Default | `/inbound` | Tab bar with Purchase orders selected; only the PO card shown |
| Linked tab | `/inbound?tab=putaway` | Awaiting putaway selected and shown |
| Click | Click "QC holds" | QC holds card shown; URL becomes `/inbound?tab=qc-holds`; reload keeps it |
| Unknown tab | `/inbound?tab=nope` | Falls back to Purchase orders |
| Drill | `/inbound?list=grns&…` / `?list=putaway&…` | That tab selected, with its drill banner; the tab bar visible; another tab leaves the drill; Clear → tabbed page |
| Notification | Click a QC-hold bell entry | Lands on `/inbound?tab=qc-holds` |
| Warehouse switch | Change the active warehouse on any tab | That tab's card re-reads for the new warehouse, as today |

</frozen-after-approval>

## Implementation Notes

**Code Map (wms-fe, `feat/inbound-tabs`):**
- `src/lib/inbound-tabs.ts`: holds the tab list, `parseInboundTab`, `inboundTabHref`, `initialInboundTab` (a drill's list wins), and the count helpers `tabCountLabel` and `sumTabCounts`.
- `src/components/inbound/inbound-cards.tsx`: holds `InboundTabBar` (normal) and `DrillInboundTabBar` (drilled). There is one tabpanel, and only the selected card is mounted.
- `src/app/(app)/inbound/page.tsx`: parses `tab`. The page key is `drillKey|tab`.
- `src/components/shared/drill-banner.tsx`: has an optional `clearHref`. On Inbound, Clear lands on the drilled list's tab.
- `src/lib/notifications.ts`: the QC hold link goes to `/inbound?tab=qc-holds`.
- `src/lib/use-inbound-tab-counts.ts` and `src/lib/api/client.ts`: the tab counts (see the addendum below).

**Deviation from the frozen Approach (recorded, not renegotiated).** A tab click outside a drill rewrites the URL with `window.history.replaceState`, not `router.replace`. The App Router syncs that write into `useSearchParams` without a server round trip or remount, and the tab is *derived* from `useSearchParams`. This keeps the selected tab always equal to the live URL. Using `router.replace` would re-render the dynamic page on every click.

Inside a drill, another tab still uses `router.replace` to `?tab=<id>` (leaving the drill needs the server render). The first tab writes the bare `/inbound`. Clicking the open tab writes nothing.

**Addendum: tab counts (user request, 2026-10-17, "show counts on the tabs").** Each tab except Goods receipts shows a count pill. Goods receipts is history and has nothing actionable to count. The counts are:
- open POs (`status=open`);
- ASNs still to receive (`announced` + `partially_received`, read separately and summed);
- tasks awaiting putaway (unpaged, so exact);
- open QC holds.

The lists are keyset-paged with no total, so each count reads one page at the route's ceiling (PO 200, ASN 100 per status, QC 200). A page with a `nextCursor` reads "N+", so a count is never misleadingly small.

A failed read leaves that tab without a pill, never a wrong "0". Counts load independently and never block the cards. They re-read when the warehouse changes and on `INBOUND_CHANGED_EVENT`, which QC place and release now also fire.

This adds up to 5 small reads per Inbound visit. No server change.

**Verification:**
- Full web suite passed 1561/0. Across 13 runs it failed once, on `ledger-integrity.test.tsx > the bell and the hash`. That test passed 15/15 alone, 6/6 in main's full suite, and 12/12 in later full runs on the branch. It is noted as an intermittent full-suite flake and was not reproduced.
- Typecheck and lint are clean.

## Review Triage

One blind-hunter pass over the implementation diff produced 10 findings, triaged in 9 rows (the docs and notification-test findings are merged).

| # | Finding | Disposition |
|---|---|---|
| 1 | Tab state goes stale: after a `replaceState` click, a sidebar `/inbound` link or a same-key bell link left the wrong tab showing | **Fixed.** The tab is now derived from `useSearchParams`. A test drives a bare `/inbound` and a `?tab=qc-holds` navigation after a switch |
| 2 | The `replaceState` deviation from the spec was not recorded | **Fixed.** Recorded above |
| 3 | The router mock folded `push` and `replace` together | **Fixed.** `replaces` is recorded separately. Tests assert Clear → `push` and a drilled tab → `replace` |
| 4 | An unsupported-drill notice outlives its URL after a tab click | **Deferred.** Cosmetic: the notice is about the link the user arrived on |
| 5 | Coverage gaps: the GRN card's read after leaving a putaway drill, and a warehouse switch on a non-default tab | **Deferred.** Both paths are unchanged card code, already covered per card |
| 6 | Partial tab a11y: no `aria-controls` or tabpanel, no roving tabIndex or arrow keys | **Partly fixed.** `id`, `aria-controls` and a `role="tabpanel"` with `aria-labelledby` were added. Arrow-key roving is deferred, matching the Conflicts tabs |
| 7 | The page key template is duplicated in the test helper | **Deferred.** It is test-only. The helper renders the real `page.tsx` for the inbound case |
| 8 | `selectTab` rewrote the URL even for the open tab, and wrote `?tab=pos` for the default | **Fixed.** The default tab writes the bare route, and clicking the open tab is a no-op |
| 9 | The frontend docs and the notification-link test were not updated | **Fixed.** The SYSTEM-DESIGN `/inbound` row, the notification links and the IMPLEMENTATION-GUIDE router rule are updated. The test asserts that a qc-hold link opens `qc-holds` |
