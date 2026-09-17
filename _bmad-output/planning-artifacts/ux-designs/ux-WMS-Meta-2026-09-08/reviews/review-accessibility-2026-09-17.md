# Accessibility Review — multi-domain additions (2026-09-17)

Scope: the 2026-09-17 material only (quantity field dual mode, catch-weight capture, status badge, variant matrix, witness capture, container scan step, conformance refusal, new Accessibility Floor bullets). UX-DR1..25 out of scope.

Contrast checked and **not** a finding: `warning #B45309` on `#FFFFFF` = 5.0:1; `warning-dark #F0A860` on `#1F1002` = 9.2:1. Both pass AA and 1.4.11.

## Critical

**C1 — The badge glyph set is never specified, and one glyph is already taken.**
`DESIGN.md` › Components › Status badge invokes "the scan-banner precedent" but does not follow it: the banner enumerates `✓ / ↻ / ✕ / ⚠` exactly; the badge enumerates nothing. Five statuses are asserted distinguishable by an unnamed glyph set. **⚠ is already bound to the banner's Held-for-review state**, so a quarantine badge using it is pixel-identical to a different component's state. Glyph-only differentiation degrades sharply past 3–4 in one visual slot at 16dp, gloved distance, poor light. *Fix:* enumerate the glyphs; require pairwise-distinct silhouettes at 16dp and in 1-bit; reserve ⚠ to the banner; invert the Floor's claim so the **word** is primary and the glyph reinforces; differentiate pill treatment (solid / outline / double-stroke) as the second non-colour channel.

**C2 — At largest dynamic type the badge word truncates, collapsing to glyph-only.**
The no-truncation guarantee is scoped to the scan banner only. `rounded-full` is the least reflow-tolerant shape in the system and "quarantine"/"controlled" are long. Truncation drops the word, leaving glyph-only — a **1.4.1 failure created by the accessibility setting itself**. *Fix:* extend the guarantee to the status badge; pill grows and wraps, never ellipsizes; a badge may never degrade to glyph-only — collapse to a neutral count affordance instead.

**C3 — Four new refusal/blocked states have no announcement requirement; two have no surface at all.**
The Floor bullet is an allowlist of two (conformance, shelf-life). Uncovered: declared-precision refusal ("refused inline" with no programmatic association = silent inline error, 3.3.1/4.1.3); controlled-movement-offline ("told" is undefined — as a disabled card, RN/iOS announces "dimmed" with the reason nowhere in the accessible name); **witness scan failure — no state, no vocabulary, nothing**; **container scan refusal — no refusal state exists**. *Fix:* replace the allowlist with a blanket rule — every refusal announces its rule and its alternative in the same announcement; add the missing states.

## Major

**M1 — Oversizing only the decimal key does not make a keypad glove-safe.** 48dp is a bare-finger floor. The interaction changed from two enormous targets to twelve small ones. `0` is adjacent to `.` on every layout and produces the same magnitude error class, so the oversizing targets the wrong half of the confusable pair. No gutter spec (need ≥8dp), no magnitude guard, no dynamic-type behaviour, no key feedback (DESIGN.md's haptics don't-list reads broadly enough that implementers will skip it). *Fix:* add all four, and require an explicit confirm when entered weight deviates from nominal by an order of magnitude — the only fix that addresses the stated risk.

**M2 — An oversized decimal key forces a custom keypad, forfeiting platform keyboard accessibility.** Bypasses Braille Screen Input, dictation, Voice Control, Switch Control and external keyboards — and this product already assumes hardware keyboards (HID scanners). *Fix:* custom keypad is default, but the field stays a real text input accepting HID/dictation/AT entry; accessible name per key ("decimal point", not ".").

**M3 — Two new guarantees are written as visual-only guarantees.** "Quantity and weight are *visibly* distinct" and "the variant is the *largest distinguishing text*" both encode safety in a channel a screen-reader user lacks; font size is not reading order. *Fix:* accessible names carry role + unit + declared precision; restate the variant rule as **first announced after the scan result**, and largest.

**M4 — Variant matrix expanded-row semantics are undefined; nested grid-in-a-row is a known AT trap.** No `aria-expanded`, no expansion announcement, no exposure model. A table inside a `<td>` breaks screen-reader table navigation. Row actions remain hover/tap with no keyboard path stated (2.1.1), and the variant matrix multiplies hover-gated actions per screen. *Fix:* `treegrid` with `aria-level`/`aria-posinset` or a labelled independent region; announce expansion; require keyboard-reachable row actions on all viewports.

**M5 — Apparel variants will encode colour as data, and swatch-only is not forbidden.** The contract bans *decorative* colour-coding but is silent on colour as a product attribute. Navy/Black, Red/Crimson/Maroon are exactly the confusions that matter on a pick. *Fix:* where colour is a product attribute, the colour name renders adjacent to any swatch and is part of the accessible name; a swatch is never the sole identifier.

**M6 — Witness confirmation is an ephemeral announcement, and the witness cannot perceive it.** AT announcements are droppable and unre-readable — wrong mechanism for an attested step. And **the witness is a different person**: the announcement plays on operator 1's device, likely through their headset. *Fix:* a focused, persistent confirmation step carrying both identities in its accessible name, not a live region; the commit action attributable to the witness.

**M7 — Multiple statuses on one unit have no stacking rule.** A bonded, controlled, excursioned batch carries three at once in a ~40px row. No cap, no priority order, no overflow behaviour. *Fix:* max badge count per slot, deterministic severity order, keyboard/AT-reachable overflow affordance that discloses the full list with words intact.

## Minor

**m1** Reduce Motion covers only the banner swap — not variant expand/collapse or chip-row momentum.
**m2** The scrollable chip row is a drag gesture, unreliable with cold-store gloves; needs ≥48dp chips, auto-scroll on AT focus, a more-exists affordance, and a non-drag path to the last chip.
**m3** The conformance-refusal announcement can be truncated by the next scan, since the capture field deliberately keeps focus; make state + rule + alternative one atomic string and queue a subsequent scan behind it.
**m4** Whether manual entry can pass a conformance refusal is unspecified; a stale cache then hard-blocks with no path, breaking the manual-entry floor promise.
