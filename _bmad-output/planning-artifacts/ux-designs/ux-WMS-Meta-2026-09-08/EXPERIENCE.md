---
name: WMS UX Experience
status: final
created: '2026-09-08'
updated: '2026-09-17'
sources:
  - ../../prds/prd-WMS-Meta-2026-09-07/prd.md
  - ../../prds/prd-WMS-Meta-2026-09-07/addendum.md
  - ../../architecture/architecture-WMS-Meta-2026-09-08/ARCHITECTURE-SPINE.md
  - ../../../specs/spec-WMS-Meta/SPEC.md
---

# EXPERIENCE.md — WMS Web Dashboard + Mobile Scan Client

> Two surfaces, one experience contract. Visual identity lives in `DESIGN.md`; this spine owns information architecture, behavior, states, and journeys. Journeys mirror PRD UJ-1…4 verbatim (protagonists: Priya — ops head; Ramesh — floor operator; Ankit — founder).

## Foundation

- **Web dashboard** — responsive web (Next.js 16 + shadcn/ui), the surface for Owner, Ops Manager, Accountant. Mouse + keyboard data tool; desktop-first, usable on tablet.
- **Mobile scan client** — native (Expo/RN), the surface for Operators. Scan-first, offline-tolerant (AD-4): scan decisions run on-device; only ledger persistence waits for network. Camera scan + paired HID scanners.
- `DESIGN.md` is the visual identity reference; the spines win on conflict with any mock. Platform conventions own mobile navigation, gestures, and type rendering.

## Information Architecture

**Web** (sidebar nav; areas per spec CAP-1…12):

| Surface | Reached from | Purpose |
|---|---|---|
| Overview | App open | Today's KPIs per warehouse: dock-to-stock, pick rate, short-picks, GRN variances, expiry alerts, sync health, dispatch pipeline (FR-27) |
| Inventory | Sidebar | Stock by bin/SKU, batch/serial detail, ledger viewer (AD-1 projections) |
| Inbound | Sidebar | POs (open quantities), GRNs, blind-GRN flags, QC holds |
| Outbound | Sidebar | Orders, waves, picklists, pack/dispatch pipeline; carrier-cutoff pressure visible (amber at-risk waves) (FR-13) |
| Moves | Sidebar | Transfers (in-transit), adjustments + approvals, cycle counts + variances |
| Conflicts & Reviews | Sidebar | The human-review queue: quarantined replay conflicts (AD-14 case 4), over-receipt approvals, escalated variances — one place, never buried in a module |
| Notifications | Bell (web) / system push (mobile) | Single notification panel: task assignments, approvals awaiting, reorder alerts within 5 min of breach (FR-22's only specified latency); expiry (FR-23) and QC alerts surface per their FRs with no latency spec. Amber-treatment entries, no badge-count spam |
| Replenishment | Sidebar | Reorder points, suggested POs (draft, editable), expiry dashboard |
| Channels | Sidebar | Connections, per-channel buffers, backorder policy, sync health |
| Compliance | Sidebar | Invoices, e-way bill batches, HSN summary; **customs/excise/controlled status views and statutory registers with async export** (Epics 16-18) |
| Reports / Audit | Sidebar | Audit trail with filters, async exports (FR-28) |
| Returns | Sidebar | Return authorizations, the returns queue, and the disposition decision (restock / quarantine / scrap) as an approval card (Epic 13) |
| Recall | Inventory → action | Trace a lot or serial to every location, order and customer **and quarantine what remains in one action**; the trace renders as the ledger timeline (Epic 14) |
| Containers | Sidebar | Returnable-container fleet, per-customer custody, deposit balances, overdue view (Epic 15) |
| Settings | Sidebar | Warehouses/zones/bins, catalog import, users/roles, thresholds, floor-device enrollment/revocation (AD-4), setup checklist; **storage and hazard class admin, the segregation matrix, shelf-life policy, licence records** (Epics 12, 14, 18) |

**Mobile** (badge-in is the root; the inbox's task-type switcher is in-surface, not app-level tabs — a **horizontally scrollable chip row with All pinned first**, which scales past six types without becoming app-level navigation):

| Surface | Reached from | Purpose |
|---|---|---|
| Device enrollment | First run (once) | Bind device to tenant/operator; revocable and wipe-flagged from web Settings (AD-4) |
| Badge-in | App open (enrolled) | Scan operator badge; assigns session to operator. **Offline:** the device restores the last operator session from its bound cache — first-ever badge-in requires connectivity, every shift after that starts in a dead zone |
| Sync summary | Badge-in / replay end | Post-replay screen: settled / rejected / quarantined counts per task, tap-through to review items — the operator's single view of what the server decided about queued work (AD-4) |
| Task inbox | Badge-in | Chips: All / Pick / Putaway / Count / Transfer / **Return** — assigned + pickable tasks in suggested order (FR-29). The row scrolls; All never scrolls away |
| Task flow | Inbox item | One linear flow per task type (receive, putaway, pick, count, transfer-confirm, pack-assist, **return-receipt**); camera overlay + HID. The return flow reuses the receiving flow's shape rather than inventing a second one |
| Queue state | Persistent header | Queued-op count while offline; never an error (FR-14) |

→ Composition reference: [`mockups/key-mobile-pick.html`](mockups/key-mobile-pick.html) · [`mockups/key-mobile-receive.html`](mockups/key-mobile-receive.html) · [`mockups/key-web-overview.html`](mockups/key-web-overview.html). Spine wins on conflict.

## Voice and Tone

Microcopy. Brand posture lives in `DESIGN.md`.

| Do | Don't |
|---|---|
| "3 POs awaiting receipt." | "Great news! You have orders 🎉" |
| "Bin A-03-12 is blocked — pick from B-01-04 instead." | "Invalid bin." |
| "Scanned 1,980 of 2,000. 20 short — record a partial." | "Discrepancy detected." |
| "Queued 14 — will sync when Wi-Fi returns." | "Network error. Retrying…" |
| Numbers and verbs. No exclamation marks. | Surveillance phrasing ("You ranked #4 today"). |

## Component Patterns

Behavioral; visual specs in `DESIGN.md.Components`.

| Component | Use | Behavioral rules |
|---|---|---|
| KPI tile | Overview | Click-through to the underlying ledger-filtered list; reconciles to ledger, so no "estimated" state exists |
| Data table | All list surfaces | Cursor pagination, sticky header, column filter presets; async export for big pulls (FR-28) |
| Scan banner | Every mobile task step | Full-screen result ≤ 1.5 s with state glyph + word. Four states, honestly named: **Accepted** (server-confirmed, online), **Recorded · queued** (on-device decision passed, persistence pending — AD-4; never shows green "accepted" while queued), **Rejected** (≤ 500 ms on-device, reason + nearest correct bin offered; rejected scans never queue), **Held for review** (server quarantined a replayed op; links to sync summary). A queued op the server later rejects is shown as a **retraction** in the sync summary, never silently corrected (AD-14) |
| Manual entry | Every scan step | First-class one-tap fallback (SKU code / bin code / qty) for every scan step — the non-visual path (a11y floor), the damaged-label path, and the HID-less path |
| Task card | Mobile inbox | Type icon, order/PO ref, item count, claimed-by state; claim is optimistic, disappears for others within one refresh cycle (FR-29). Re-planned tasks (short-pick alternates, FR-15) arrive as new cards linked to the original task ref |
| Review queue item | Conflicts & Reviews | The quarantined event with its on-device snapshot, server state, and ledger context side by side; resolve (apply / recount / discard-to-audit) writes to the audit trail; batch-resolve for similar conflicts |
| Notification panel | Bell / push | Newest-first, amber treatment, click-through to source; mobile pushes restricted to task assignment + approval-needed + at-risk cutoff; reorder/expiry/breach alerts are panel entries only (FR-22 ≤ 5 min) |
| Qty stepper | Mobile receive/count | Large +/-, gloves-friendly; scan increments where applicable; manual entry is a deliberate fallback tap |
| Ledger timeline | Inventory, approvals | Every row links to its reference document (≤ 2 navigations, FR-28) |
| Approval card | Moves, Inbound, Counts, Conflicts & Reviews | Threshold context inline; approve / reject / recount actions (FR-21); over-receipt approvals land here mid-receive (FR-8); writes to audit trail; over-threshold routes to Owner (FR-19) |
| Quantity field | Every quantity input | **Dual mode by UoM** — each-counted keeps the +/− stepper, measured gets a decimal keypad with an oversized decimal key and the unit beside the field. Display is at the UoM's **declared** precision (`18.4 kg`, never `18.400000`); a value finer than the declared precision is refused inline naming the precision, never silently rounded (Epic 10) |
| Catch-weight capture | Mobile receive, pack | Prompts for the handling unit's **actual weight** after the item scan; a connected scale or meter reading is treated as a scan event, with manual entry as UX-DR9's named fallback. Quantity and weight are visibly distinct — never "enter 18.4 pieces" (Epic 10) |
| Variant matrix | Catalog, pick surfaces | One product row expanding to its variant grid via the `DataTable` expanded-row slot — a size run is one row, not N. On the mobile pick path the **variant is the largest distinguishing text after the scan result**, because picking the wrong size is the dominant apparel error (Epic 11) |
| Status badge | Anywhere stock appears | Quarantine, excursion, customs, excise and controlled states as pills on existing amber + glyph + word. No new hue, never colour-alone (Epics 12, 16-18) |
| Witness capture | Mobile, controlled movements only | Second-identity badge scan inside the operator's session; both identities shown before commit and recorded on the event. **Online-only** — see State Patterns (Epic 18) |
| Container scan step | Mobile receive, dispatch | Returnable containers scan in and out as a step **distinct from their contents**; a pallet or handling unit moves as one unit while its contents stay individually traceable (Epic 15) |
| Import wizard | Settings → Catalog | Upload → progress → row-level error report download → fix-mode re-import (FR-2); partial commit shown honestly; barcode field included at import — a duplicate barcode→two-SKU value is a rejected row with the conflicting SKU named (FR-30) |

## State Patterns

| State | Surface | Treatment |
|---|---|---|
| Cold load | Any web surface | Skeleton rows matching layout; resolves on data |
| Empty | Any list | One sentence + single primary action ("No POs yet — create the first one.") |
| Offline (mobile) | Task flow | Work continues; queue chip shows count; **no error styling** (FR-14). On-device decisions display as **Recorded · queued**, not green-accepted — the banner never promises server truth it doesn't have (AD-4) |
| Claim lost (mobile) | Task card | Card flips to "Claimed by {other} while offline"; the operator's queued lines for that task list inside it, disposition shown; physical picks aren't lost — quarantined lines feed review/recount (AD-14), never silent write-off |
| Device revoked mid-shift (mobile) | Any | Explicit full-screen "Device revoked by {admin}" — never a silent mass quarantine. Queued ops transfer to quarantine with session attribution preserved; the operator's completed work remains auditable (AD-4) |
| Replay (mobile) | Header | Subtle "Syncing…" chip during replay with settled count; every replayed item is re-authorized against the badge-in session that created it (shared devices never launder authorization across badge-ins), rejections quarantine to Conflicts & Reviews and surface in the sync summary — never blocking further work (AD-14) |
| Device revoked (offline) | Any | Server flags the device; on next connection it wipes its cache and shows the revoked state. A revoked device that never reconnects holds only its encrypted cache (AD-4) |
| Live KPI tiles | Overview | Streamed best-effort; under peak they may lag by design (AD-17 sheds background work before scanning). The stale-data banner is the governing pattern; lists never auto-refresh |
| Carrier cutoff pressure | Outbound | Waves at risk of missing a configured cutoff show amber with time remaining (FR-13) |
| Sync failure | Web → Channels | Surfaced on Channel detail with last-sync time + retry; never a global modal |
| Permission denied | Any | Surface hidden; no "blocked" screen |
| Permission changed mid-session | Any | Enforced on next action (FR-3, AD-10): web — the next save fails with the role reason; mobile — the operator's next scan/claim after a downgrade re-evaluates; in-progress scan state is preserved until the action lands, then the surface re-resolves. No surprise mid-keystroke lockouts |
| Stale data | Web lists | Inline refresh banner when background refresh detects change; manual refresh, no auto |
| Label/API failure | Pack/Dispatch | Retryable error inline; dispatch state unchanged (FR-17) |
| Conformance refusal (mobile) | Putaway, pick | A non-conforming placement — frozen SKU into an ambient bin, incompatible hazard classes co-located — rides the existing **Rejected** banner state: ≤ 500 ms, on-device, names **both parties and the rule**, and offers the nearest **conforming** location. Works in a dead zone because storage class ships in the cached catalog snapshot (the `pickTasks` precedent). The banner vocabulary stays at four states (Epic 12) |
| Quarantined stock | Anywhere it appears | Excursion- or recall-quarantined units carry the status badge everywhere they render, and the Conflicts & Reviews queue gains an excursion item with the reading, affected units and ledger context (Epics 12, 14) |
| Shelf-life refusal | Allocation, pick | Stock too close to expiry is refused with the Rejected banner naming **the policy and the batch** — not a generic "unavailable" (Epic 14) |
| Controlled movement, offline (mobile) | Any controlled task | **Blocked, deliberately.** Controlled-goods movements are excluded from the ≥ 30-minute offline tolerance: without a witness badge scan the movement cannot commit, and an unwitnessed controlled movement **must never queue**. The operator is told connectivity is required and why — a named carve-out from AD-4/AD-14, not a failure state (Epic 18) |

## Interaction Primitives

**Web:** ⌘K command palette (navigate + actions); hover reveals row actions on desktop, tap reveals on touch; inline-editable cells where editable (reorder points, thresholds); Esc closes any dialog; Enter commits.

**Mobile:** scan is the verb — every task flow is scan → banner → next; scan camera overlay + HID input are interchangeable at any scan step, and **manual entry is the named fallback at every scan step**. HID behaves as a keyboard but with real focus management: the scan capture field keeps focus across banner swaps (a next scan is never silently lost), scan input never splices into mid-typed manual entry (scan keystroke bursts are captured in capture mode only), and focus returns to the capture field after Esc or dialog close. Buttons are ≥ 48dp and glove-usable (bare-finger precision is not assumed). Swipe never destroys work. **Receive budget:** a single-SKU single-lot GRN is ≤ 4 scans + 1 confirm (FR-8) — the receive flow's design ceiling; blind receive adds one deliberate reason-code step; over-receipt submits for approval and the task continues, it never hard-blocks mid-flow.

**Measured goods:** decimal entry replaces the stepper on measured UoMs only; a connected scale or meter is a **scan-equivalent input** at any capture step, with manual entry as the named fallback (UX-DR9 holds). Catch weight is captured as its own field, never folded into quantity.

**Controlled goods:** a witness badge scan is a second identity inside one session, and the only interaction in the product that **requires connectivity** — stated to the operator up front rather than discovered at commit.

**Banned everywhere:** infinite scroll (cursor pagination only), hover-only affordances on touch surfaces, modal stacks > 1 deep, celebratory animations, badge-count notification spam, hover-only row actions on `sm` viewports.

## Accessibility Floor

Behavioral; visual contrast in `DESIGN.md`.

- WCAG 2.2 AA on web; platform accessibility APIs (VoiceOver/TalkBack) on mobile — every task state announced ("Bin accepted", "Wrong item — expected SKU 8452").
- Dynamic type honored; scan banner legible at largest setting without truncation.
- Reduce Motion: banner swap is instant, no fades.
- Focus traversal matches reading order; Esc closes the topmost layer on web.
- Scan targets ≥ 48dp; the floor client is glove- and one-handed-usable by design.
- **Decimal keypad keys are ≥ 48dp including the decimal key**, which is oversized — a mis-hit decimal on a measured quantity is a 10× or 100× error, not a typo (Epic 10).
- **Every new status is glyph + word, never colour alone** — quarantine, excursion, customs, excise and controlled states all share one amber, so the glyph carries the distinction (WCAG 1.4.1, the scan-banner precedent).
- Conformance and shelf-life refusals are **announced with their reason**, not just "rejected" — a screen-reader operator hears which rule fired and what the alternative is.
- Witness capture announces both identities before commit, so the confirmation is not visual-only.

## Key Flows

### Flow 1 — Onboard and receive (Priya, ops head, first day on the system — UJ-1)

1. Priya signs in; setup checklist shows the remaining steps (catalog, bins, users, enroll a floor device, first PO) — the critical path to SM-1's first GRN inside one business day.
2. Catalog import wizard: uploads the CSV; 30 bad rows flagged; she fixes them in a sheet, re-imports in fix mode.
3. Grid editor: bins A-01-01…Z-12-10 generated; she blocks two broken bins.
4. She enrolls the floor tablet and assigns Ramesh; creates a PO for 200 units across 4 SKUs; hands the PO number to the floor.
5. **Climax:** Ramesh scans the delivery against the PO on mobile; Priya watches received-vs-ordered fill in live on Overview (streamed KPI tiles, best-effort per AD-17), dock-to-stock clocking automatically — the spreadsheet is now the backup, not the source.

Failure: delivery short 20 units → partial GRN flow keeps the PO line open with correct remaining qty; the open quantity stays visible until closed.

### Flow 2 — Pick through a dead zone (Ramesh, floor operator — UJ-2)

1. Ramesh badges in; inbox shows his picklist of 12 orders.
2. Directed pick path; he scans bin, scans item; banner ticks green per line.
3. Wi-Fi drops in aisle C: queue chip appears (14 queued); he keeps scanning — no error, no wait.
4. Connectivity returns; queue replays in order — each item re-authorized server-side (AD-4); settled count ticks up on the sync chip, anything rejected quarantines to Conflicts & Reviews without stopping his next task.
5. **Climax:** all 12 orders picked with zero scan errors and zero "wait for network" moments — his shift pick rate records itself.

Failure: wrong item scan → red banner ≤ 500 ms with reason + nearest correct bin offered; his next scan is what counts, not a dialog.

### Flow 3 — Survive the flash sale (Priya, live sale synced to Shopify + Amazon.in — UJ-3)

1. Sale opens; ATP pool drains; buffers go to zero in order.
2. One channel's buffer exhausts → its listing shows reduced quantity before the pool empties (AD-13 standing reservations).
3. Two channels race for the last unit; one reservation wins deterministically; the loser follows the configured backorder policy — no cancel-and-apologize.
4. **Climax:** zero oversells at 15× order volume; post-sale report shows per-channel reservations, buffer events, backorders taken.

Failure: a marketplace API degrades mid-sale → Channels sync-health tile goes amber with lag + retry queue; acceptance and reservations continue server-side — oversell protection never depends on a channel API's availability (AD-7 retries, AD-13 buffers).

### Flow 4 — Close the month (Ankit, founder, GST week — UJ-4)

1. Scheduled cycle count due on the fastest ABC class; assigned to Ramesh's mobile, no ops freeze.
2. One SKU varies; Ankit opens the variance from the dashboard → ledger timeline one tap away — every receipt, pick, adjustment attributed.
3. He approves the adjustment with a reason code (or triggers a recount — the recount replaces the variance's expected basis, FR-21); threshold logic escalates if over his own approval ceiling.
4. **Climax:** e-way bills batch-generate for the day's dispatches without touching the GST portal by hand; the month closes from the audit trail, not an hour of guesswork.

Failure: variance exceeds threshold → sits pending with Ankit notified; ATP is untouched until approval (FR-19).

[NOTE FOR UX] **Three journeys are missing and are not invented here.** The multi-domain expansion adds flows this spine cannot author without you narrating them, because the protagonists do not exist yet in the source material: (a) a **returns** session — who inspects, what they decide, where the judgement call sits; (b) a **cold-chain** session where a conformance refusal or an excursion interrupts a normal putaway; (c) a **controlled-goods** movement with a witness, including what the operator does when there is no second person available. Flows 1–5 follow PRD UJ-1…4 verbatim; these three need equivalent journeys in the rewritten PRD before they can be structured here.

### Flow 5 — Morning replenishment check (Priya, start of day)

1. Priya opens the bell panel: 2 reorder breaches overnight + 1 batch approaching expiry.
2. She taps through to Replenishment: reorder dashboard shows the two SKUs below point with suggested POs pre-drafted.
3. She edits the drafted PO's quantities, then submits (system never auto-submits, FR-22); the expiry batch is flagged FEFO-priority.
4. **Climax:** both breach alerts resolve on the panel before the floor's first pick — the 5-minute alert latency did its job overnight; nothing reaches a stockout.

## Responsive & Platform

| Surface | Behavior |
|---|---|
| Web ≥ 1024px | Full sidebar + data tables; dense is default |
| Web 768–1023px | Sidebar collapses to icons |
| Web < 768px | Read + simple actions; heavy data work moves to desktop |
| Mobile | iOS + Android parity; follows system dark mode; HID scanners pair as keyboard input |

Web is responsive, not a native mobile experience: Priya reviews on her phone, but the dashboard's primary surface is desktop.