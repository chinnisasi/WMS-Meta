# Validation Report — WMS-Meta UX spines

- **DESIGN.md:** `DESIGN.md`
- **EXPERIENCE.md:** `EXPERIENCE.md`
- **Run at:** 2026-09-17 (multi-domain expansion, epics 10–20)
- **Lenses run:** accessibility · offline floor seam. *(Rubric walker not run — this was a surgical update to a contract that already passed it, not a fresh authoring pass.)*

## Overall verdict

The pre-expansion contract held up; the expansion did not, and both lenses converged on the same root cause from different angles. The 2026-09-17 material introduced four new *decisions* — storage conformance, shelf life, catch-weight tolerance, witness validity — without extending the two things that made the original contract honest: **a defined on-device knowledge base**, and **a banner vocabulary that matches where each decision is actually made**. Every critical traced to one of those two omissions, or to the same pattern in the accessibility layer: new states asserted to be distinguishable without the mechanism of distinction ever being specified.

All 7 critical and 13 major findings are resolved in the spines. Three required product decisions rather than spec fixes and were taken by the human.

## Findings by severity

### Critical (7) — all resolved

**[a11y C1]** Status-badge glyph set never enumerated while invoking "the scan-banner precedent", and **⚠ was already bound** to the banner's Held-for-review state.
*Fix applied:* glyphs enumerated (`⏸ ❅ ⛨ ₹ ⚿ ↩`), ⚠ reserved to the banner, **word made the primary channel**, pill treatment added as the second non-colour channel, silhouette-distinct at 16dp required.

**[a11y C2]** Badge word truncates at largest dynamic type, collapsing to glyph-only — a 1.4.1 failure *created by the accessibility setting itself*.
*Fix applied:* no-truncation guarantee extended to the badge; grows and wraps, never ellipsizes; may never degrade to glyph-only; collapses to a neutral count that discloses full words.

**[a11y C3]** Refusal-announcement rule was an allowlist of two; four more refusals uncovered, and **witness-scan failure and container refusal had no state at all**.
*Fix applied:* blanket rule — every refusal announces rule and alternative in the same announcement; disabled controls carry the reason in the accessible name; missing states added.

**[offline C1]** The cached catalog snapshot had **no freshness model** though four refusals depend on it; false rejects left no trace, false accepts put frozen goods in ambient bins.
*Fix applied:* `Catalog snapshot` state pattern naming required fields and max age; snapshot age in refusal microcopy; past max age degrades to amber warn-and-confirm; refusals queue an **audit** event so stale-rule blocking is visible.

**[offline C2]** The four-state vocabulary had **no slot for a synchronous server-side refusal** — an invalid witness badge was not Accepted, not on-device Rejected, not queued, not Held.
*Fix applied:* Rejected split into two provenances (on-device / server-online) rendering identically; a server refusal while online is Rejected, never Held.

**[offline C3]** Excursion **capture** entirely unspecified, and an on-device quarantine badge was a fifth state by the back door.
*Fix applied:* capture row added; quarantine optimistic but labelled `Quarantine · queued` and device-local; a server rejection **never auto-releases** — human-release review item only.

**[offline C4]** The online-only controlled carve-out was asserted "up front" with **no surface delivering it**, and every mid-flow connectivity drop was undefined.
*Fix applied:* controlled marker on task card and inbox chip, disabled offline with reason inline; claim auto-release pattern; witness attestation **voided** on drop; ordering rule witness → commit → move.

### Major (13) — all resolved

**[a11y M1/M2]** Oversizing only the decimal key targeted the wrong half of the confusable pair (`0` is adjacent to `.`); custom keypad silently forfeited platform keyboard accessibility. → both keys oversized, ≥8dp gutter, magnitude-deviation confirm, field stays a real text input for HID/dictation/AT.
**[a11y M3]** Two guarantees written as visual-only. → accessible names carry role + unit + precision; variant **first announced**, not merely largest.
**[a11y M4]** Variant expanded-row semantics undefined; nested grid-in-a-row is an AT trap. → `treegrid` or labelled region, expansion announced, keyboard-reachable row actions on every viewport.
**[a11y M5]** Colour as a *product attribute* (apparel) was unguarded. → colour name beside any swatch and in its accessible name.
**[a11y M6]** Witness confirmation was an ephemeral announcement the witness could not perceive. → focused, persistent confirmation step; commit attributable to the witness.
**[a11y M7]** No stacking rule for co-occurring statuses. → max 3 per slot, severity order, overflow affordance.
**[offline M1]** Conformance false-accept had only a ledger-shaped retraction. → **physical retraction** generating an interrupting remediation task.
**[offline M2]** FEFO/shelf-life contradicted between the two files. → **amber override-with-reason** (policy) vs conformance hard refusal (safety); offline override re-authorizes on replay.
**[offline M3]** Container and contents settled independently. → one replay group, nested outcomes, container holds queued-quarantine until all resolve.
**[offline M4]** Returns reused receiving's shape but not its decision basis; interim state unnamed. → divergence stated on the task screen; `Received, awaiting disposition` badge excluded from ATP.
**[offline M5]** Queued and Held-for-review shared one colour token. → structural separation (bordered fill + mandatory action on Held).
**[offline M6]** Scale readings violating declared precision had no path. → rounded with both values shown; inline refusal reserved for typed entry; catch-weight tolerance added to the snapshot.

### Minor (8) — all resolved

Reduce Motion extended to variant expand and chip row · chip row glove/AT rules · atomic refusal announcement that a next scan queues behind · manual entry refused identically on conformance · queue chip shows elapsed offline time past the tolerance window · witness online-only constraint added to `DESIGN.md` · decimal keypad focus preservation · return replay dedupe anchor named.

## Held up (deliberately unchanged)

The four-state banner definition · retraction-not-silent-correction · per-badge-in re-authorization on replay · the two device-revocation patterns · `Claim lost` refusing to write off physical picks · offline badge-in restore · the `[NOTE FOR UX]` refusing to invent three missing journeys.

## Reviewer files

- `reviews/review-accessibility-2026-09-17.md`
- `reviews/review-offline-seam-2026-09-17.md`

## Open

Three journeys remain un-authorable until the PRD rewrite supplies protagonists: returns, a cold-chain interruption, and a controlled movement with no second person available. The offline lens notes that its C4 and M4 are the component-level consequences of those gaps and should be revisited alongside them.
