---
reviewer: rubric-walker
reviewed:
  - ../DESIGN.md
  - ../EXPERIENCE.md
context:
  - ../../../prds/prd-WMS-Meta-2026-09-07/prd.md
  - ../../../prds/prd-WMS-Meta-2026-09-07/addendum.md
  - ../../../architecture/architecture-WMS-Meta-2026-09-08/ARCHITECTURE-SPINE.md
  - ../../../specs/spec-WMS-Meta/SPEC.md
status: draft
created: '2026-09-08'
---

# Rubric Review — UX Spines (DESIGN.md + EXPERIENCE.md)

**Verdict: PASS WITH REVISIONS.** No critical findings. Four medium findings (one missing failure path, one broken source path, one over-claimed citation, two surfaces without a landing journey) and five low. All are local fixes; nothing requires structural rework.

---

## Checklist

### 1. IA closure — PASS (with medium finding)

**Stated needs → surfaces.** All 30 FRs and CAP-1…13 trace to a surface:

| Need | Surface | Evidence |
|---|---|---|
| FR-1 / CAP-1 | Settings (warehouses/zones/bins, setup checklist) | IA table; Flow 1 steps 1, 3 |
| FR-2 | Import wizard (Settings → Catalog) | Component Patterns; Flow 1 step 2 |
| FR-3 | Settings users/roles + "Permission changed mid-session" state | State Patterns row cites FR-3, AD-10 |
| FR-4 / CAP-2 | Inventory ledger viewer, Ledger timeline | IA; Components |
| FR-5 | Channels (buffers, backorder policy); Flow 3 | IA; Flow 3 |
| FR-6 | Inventory batch/serial detail | IA |
| FR-7 | Inbound POs ("open quantities") | IA |
| FR-8 | Inbound GRNs + mobile receive flow (≤ 4 scans + 1 confirm) | Interaction Primitives |
| FR-9 | Inbound QC holds | IA |
| FR-10 | Mobile putaway task flow | Mobile IA |
| FR-11 | Settings bin admin; blocking in Flow 1 step 3 | IA; Flow 1 |
| FR-12 | Outbound Orders | IA |
| FR-13 | Outbound waves + cutoff-pressure state | IA; State Patterns |
| FR-14 / CAP-13 | Mobile queue state, offline row, Flow 2 | State Patterns; Flow 2 |
| FR-15 | Task card "re-planned tasks… linked to the original task ref" | Components |
| FR-16 | Outbound pack pipeline + mobile pack-assist | IA |
| FR-17 | Pack/Dispatch + "Label/API failure" state | State Patterns |
| FR-18 | Moves transfers (in-transit) + mobile transfer-confirm | IA |
| FR-19 | Moves adjustments + approvals, Approval card, Flow 4 | IA; Flow 4 |
| FR-20 | Moves cycle counts + mobile count | IA |
| FR-21 | Conflicts & Reviews, Approval card (approve/reject/recount) | Components; Flow 4 step 3 |
| FR-22 / FR-23 | Replenishment (reorder points, suggested POs, expiry dashboard) + Notifications | IA |
| FR-24 / FR-25 | Channels (connections, buffers, sync health, writeback) | IA; Flow 3 |
| FR-26 | Compliance (invoices, e-way batches, HSN summary); Flow 4 climax | IA; Flow 4 |
| FR-27 | Overview KPIs | IA |
| FR-28 | Reports/Audit + Ledger timeline ≤ 2 navigations | IA; Components |
| FR-29 | Mobile task inbox with All/Pick/Putaway/Count/Transfer | Mobile IA |
| FR-30 | Interaction primitives (camera overlay + HID) + import-wizard duplicate-barcode rejection | Components (FR-30) |

**Surfaces → journeys/flows.** Flows 1–4 land: Settings (F1), Inbound (F1), Mobile receive (F1), Mobile pick/queue/replay (F2), Channels (F3), Moves + Conflicts + Compliance + Audit (F4), Inventory (F4 via ledger timeline), Outbound implicitly.

**M-1 (medium): Replenishment and Notifications have no landing journey or flow.** No step of Flows 1–4 visits the Replenishment surface (reorder points, suggested POs, expiry dashboard), and the notification panel appears only obliquely ("Ankit notified", Flow 4 failure) without the panel itself being traversed. Every other surface is landed. Fix: add a beat (e.g., Flow 1 resolution — reorder thresholds set from import defaults, which the PRD's UJ-1 resolution already supports, or Flow 4 opening — expiry dashboard prompting the count class), and one explicit notification-panel beat.

Note (low): the web IA header says "areas per spec CAP-1…12" — accurate for web; CAP-13 is covered by the mobile IA table. Not a gap, but the asymmetry is easy to misread as an omission.

### 2. Component patterns behavioral — PASS

All 11 rows in EXPERIENCE.md Component Patterns are behavioral (claim, claim-reveal, queueing, resolution routing, scan budgets) and carry FR citations. Visual specs are consistently delegated: the table's preamble says "Behavioral; visual specs in `DESIGN.md.Components`", and DESIGN.md's Components section carries the visual half (KPI tile typography, scan-banner color coding/min-height, queue-indicator color rule). No row leaks visual decisions except defensible micro-choices ("Type icon" on the task card — icon semantics, not styling). Rows are buildable: Import wizard specifies the full loop (upload → progress → row-level error report → fix-mode re-import → partial commit honesty → duplicate-barcode rejection naming the conflicting SKU, FR-2/FR-30).

### 3. State coverage — PASS (with low findings)

State Patterns covers all load-bearing states named in the rubric: offline (queue chip, no error styling, FR-14), replay (settle count, server-side re-authorization AD-4, quarantine to Conflicts & Reviews AD-14 case 4), conflicts (dedicated Conflicts & Reviews surface + review queue item), permission change mid-session (next-action enforcement, both surfaces, FR-3/AD-10), cutoff pressure (amber + time remaining, FR-13), and failures (label/API retryable inline FR-17, sync failure on Channel detail, cold load, empty, stale data).

No contradictions found across the table:
- "Queue chip amber only, never red" (DESIGN.md Queue indicator) ↔ "Offline… no error styling" (EXPERIENCE.md) — consistent.
- "Permission denied: surface hidden" ↔ "Permission changed mid-session: next save fails with the role reason" — different situations, no clash.
- "Live KPI tiles… may lag by design" ↔ "Lists never auto-refresh" / "stale-data banner is the governing pattern" — one governing rule, stated once and referenced.

**L-1 (low):** the Replay state's "appear in the operator's next sync summary" references a surface/concept defined nowhere — not in the IA tables, not in Components. Either define it (mobile badge-out / sync-summary card) or point rejections at the existing Conflicts & Reviews + notification panel.

**L-2 (low):** the accessibility announcement "Wrong item — expected SKU 8452" states what happened but not what to do, against the spine's own error rule (the full banner does offer the nearest bin; the announcement example is the abbreviated form). Make the announcement carry the action too.

### 4. Journeys — FAIL on one flow (medium finding)

Flows 1, 2, 4: named protagonist (Priya / Ramesh / Ankit), bolded climax beat, and an explicit `Failure:` line (partial GRN; wrong-item red banner; over-threshold variance pending). Flow 3 (Priya, flash sale) has a climax ("zero oversells at 15× order volume") but **no failure path** — the only flow of the four without one. This matters because Flow 3 is the oversell-protection showcase; its failure case (e.g., a channel backorder policy misconfigured, or buffer exhaustion surfacing to the operator) is exactly the state a builder needs.

**M-2 (medium): Flow 3 lacks a Failure line.** Add one consistent with the others.

### 5. Voice rules — PASS

Grep confirms the only exclamation mark in either spine is inside the Don't-column negative example ("Great news! You have orders 🎉"). All affirmative microcopy follows numbers + verbs and states-what-happened + what-to-do: "3 POs awaiting receipt." / "Bin A-03-12 is blocked — pick from B-01-04 instead." / "Scanned 1,980 of 2,000. 20 short — record a partial." / "Queued 14 — will sync when Wi-Fi returns." / "No POs yet — create the first one." Consistent across the voice table, state patterns (empty-state copy), components (scan banner reason line), flows (banner behaviors), and accessibility announcements (modulo L-2). Queue-count copy is numerically consistent between the voice table (14) and Flow 2 (14).

### 6. Token discipline — PASS (with low finding)

Frontmatter tokens used in body copy all resolve: `{colors.primary}`, `{colors.primary-foreground}`, `{typography.kpi}`, `{typography.data}`, `{typography.scan-result}`, `{rounded.sm}`, `{rounded.md}`, `{rounded.full}` — each defined in the frontmatter. Every color state named in the flows (green accept, red reject, amber attention/queue/cutoff) maps to a defined token (`accent`, shadcn `destructive` — explicitly declared inherited in the frontmatter comment, `warning`). Typography roles map: KPI tiles, data tables, scan-result. Spacing/rounded values in the Shapes/Layout sections stay on the declared scale.

**L-3 (low):** DESIGN.md Shapes section writes `{rounded/lg}` (slash) for the 8px dialog radius — the token is `{rounded.md}`-style dotted; typo breaks the cross-reference syntax. Should be `{rounded.lg}`.

### 7. No invented content — PASS (with medium finding)

Spot-checked claims against sources: Next.js 16 (architecture stack says 16.3 ✓), Tailwind 4 scale (design decision, consistent with shadcn), "≤ 4 scans + 1 confirm" (FR-8 ✓), 500 ms wrong-item rejection (FR-14 ✓), 1.5 s scan decision (NFR-6 ✓), 30 bad rows / 4,970 commit (FR-2 ✓), 15× volume (NFR-2 ✓), AD-4/AD-10/AD-13/AD-14 case 4/AD-17 characterizations all match the architecture spine verbatim in substance, Flow 3's deterministic-race and backorder-policy beats match UJ-3 verbatim, recount-replaces-basis matches FR-21. The `[ASSUMPTION]` blockquote in DESIGN.md (no brand deck; working title) correctly mirrors PRD §9 ("Product name 'WMS' is a working title") and correctly scopes itself as replaceable. The enumerated setup-checklist steps in Flow 1 step 1 are a design instantiation of FR-1's "setup-completion checklist" — legitimate design territory, not invention.

**M-3 (medium): the Notifications IA row over-claims under a citation.** "reorder/expiry/QC alerts within 5 min of breach (FR-22)" — FR-22's ≤ 5-minute latency covers reorder-point breach only. Expiry alerts are FR-23 (no latency spec) and QC holds are FR-9 (no alert latency at all). The blanket "within 5 min" attributed to FR-22 is an untagged extension of the source. Either scope the 5-minute claim to reorder alerts and leave the others uncited, or tag it `[ASSUMPTION]`.

Minor (low): Flow 3 step 1's "buffers go to zero in order" adds an ordering the sources don't state (PRD/AD-13 say buffers exhaust as availability drops, not "in order"). Drop "in order" or justify it.

### 8. Lean prose — PASS

Both spines are tight: tables carry the content, prose sections are short and rationale-bearing ("A dashboard whose digits jitter between frames reads broken" justifies tabular-nums; "offline is a state, not an error" justifies the amber-only rule). No throat-clearing, no hedges, no restating the PRD. The one sentence that borders on decoration is DESIGN.md's opening "the system the floor trusts at 11:59 PM during a flash sale" — it is a direct, deliberate echo of the PRD's own positioning line and earns its place as brand posture. No action needed.

### 9. Frontmatter integrity — FAIL on one path (medium finding)

- Sources listed in both: yes.
- Status `draft` in both: yes. `created`/`updated` dates present and consistent.
- Spine-to-spine cross-references: correct. EXPERIENCE.md points at `DESIGN.md` (identity, brand posture) and `DESIGN.md.Components` (a real section); DESIGN.md's assumption note points back at EXPERIENCE.md. Both agree "the spines win on conflict with any mock."
- Source paths resolve: DESIGN.md's three (`../../prds/…/prd.md`, `../../prds/…/addendum.md`, `../../architecture/…/ARCHITECTURE-SPINE.md`) all resolve. **EXPERIENCE.md's fourth does not.**

**M-4 (medium):** EXPERIENCE.md lists `../../specs/spec-WMS-Meta/SPEC.md`, which resolves to `planning-artifacts/specs/spec-WMS-Meta/SPEC.md` — that directory does not exist. The actual canonical contract is at `_bmad-output/specs/spec-WMS-Meta/SPEC.md`, i.e. three levels up (`../../../specs/…`). Broken traceability to the document the IA header itself cites ("areas per spec CAP-1…12").

**L-4 (low):** the IA's closing pointer "Composition reference: `mockups/` (key screens at Finalize)" names a directory that does not exist yet. Fine for a draft, but mark it as forward-looking or drop it until the directory lands.

---

## Findings index

| # | Severity | Finding | Where | Fix |
|---|---|---|---|---|
| M-1 | medium | Replenishment and Notifications surfaces have no landing journey/flow | EXPERIENCE.md Key Flows | Add a beat for each; Replenishment is already supported by UJ-1's resolution |
| M-2 | medium | Flow 3 is the only flow with no Failure line | EXPERIENCE.md Flow 3 | Add a failure path |
| M-3 | medium | "reorder/expiry/QC alerts within 5 min (FR-22)" over-extends FR-22's latency to FR-9/FR-23 needs | EXPERIENCE.md IA, Notifications row | Scope the claim or tag `[ASSUMPTION]` |
| M-4 | medium | Broken frontmatter source path `../../specs/…` (needs `../../../specs/…`) | EXPERIENCE.md frontmatter | Fix the relative path |
| L-1 | low | "next sync summary" referenced but undefined anywhere | EXPERIENCE.md State Patterns, Replay row | Define it or point at Conflicts & Reviews |
| L-2 | low | Announcement example states what happened but not what to do | EXPERIENCE.md Accessibility Floor | Include the action in the announcement |
| L-3 | low | Token typo `{rounded/lg}` | DESIGN.md Shapes | `{rounded.lg}` |
| L-4 | low | Forward reference to non-existent `mockups/` | EXPERIENCE.md IA footer | Mark as pending or drop |
| L-5 | low | "buffers go to zero in order" — ordering not in sources | EXPERIENCE.md Flow 3 step 1 | Drop "in order" |

## Checklist scoreboard

| # | Item | Result |
|---|---|---|
| 1 | IA closure | PASS (M-1) |
| 2 | Component patterns behavioral | PASS |
| 3 | State coverage, no contradictions | PASS (L-1) |
| 4 | Named-protagonist journeys, climax, failure paths | FAIL (M-2) |
| 5 | Voice consistency | PASS (L-2) |
| 6 | Token discipline, cross-references resolve | PASS (L-3) |
| 7 | No invented content | PASS (M-3, L-5) |
| 8 | Lean prose | PASS |
| 9 | Frontmatter integrity | FAIL (M-4) |

Both failures are single-line fixes; no item fails on substance.