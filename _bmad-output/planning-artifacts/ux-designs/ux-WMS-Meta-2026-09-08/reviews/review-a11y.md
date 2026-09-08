# Accessibility Review — WMS DESIGN.md + EXPERIENCE.md

- **Reviewer role:** Accessibility reviewer (UX design pair)
- **Date:** 2026-09-08
- **Scope:** `DESIGN.md` and `EXPERIENCE.md` in this design folder — audited against the spines' *own* claims: WCAG 2.2 AA (web), platform a11y APIs / VoiceOver–TalkBack announcements (mobile), dynamic type, Reduce Motion, ≥48dp targets, glove/one-handed use, screen-reader task-state announcements.
- **Method:** Spine text is quoted with line references; contrast ratios were computed (WCAG 2.x relative-luminance formula, verified by script). Each finding is severity-rated and, where the spines are silent, proposes concrete spine language.

## Verdict

**Conditional pass with mandatory revisions before Finalize.** The light-mode color pairs, the Reduce Motion and dynamic-type claims on the scan banner, and the screen-reader task-state examples are genuinely strong — better than most spines. But the floor has four structural holes: (1) the dark-mode banner token pairs fail AA catastrophically under the only mapping the spec implies; (2) the mobile task path is camera-scan-first with **no guaranteed non-visual input and no manual SKU/bin entry fallback anywhere** — the floor claims blind operability it cannot deliver; (3) HID-as-keyboard is asserted with zero focus-management behavior, which is where HID integrations actually break; (4) on-device "accepted" is announced (and shown) for scans that server replay may later reject, which is a state-truth failure for the exact operator population the a11y floor names.

Severity counts: **1 critical, 4 high, 7 medium, 3 low.**

---

## Computed contrast table (evidence for A-1, A-2)

All ratios per WCAG 2.x relative luminance. Thresholds: AA normal 4.5:1, AA large 3:1, non-text UI 3:1.

| Pair | Ratio | AA verdict |
|---|---|---|
| White on `#16794C` (green light, banner fill) | 5.42:1 | Pass normal + large |
| White on `#1E4E8C` (primary) | 8.32:1 | Pass AAA |
| White on `#B45309` (amber light) | 5.02:1 | Pass normal + large |
| `#16794C` text on white | 5.42:1 | Pass normal |
| `#B45309` text on white | 5.02:1 | Pass normal |
| **White on `#4CC38A` (green DARK banner)** | **2.22:1** | **Fail even large-text (needs 3:1)** |
| **White on `#F0A860` (amber DARK)** | **2.00:1** | **Fail even large-text** |
| **White on `#7FA7DB` (primary DARK)** | **2.48:1** | **Fail even large-text** |
| Near-black `#0B0B0D` on `#4CC38A` | 8.88:1 | Pass AAA |
| Near-black `#0B0B0D` on `#F0A860` | 9.81:1 | Pass AAA |
| `#1E4E8C` as focus ring on white | 8.32:1 | Pass non-text 3:1 |

Light-mode pairs are all sound. Every dark fill paired with the inherited white foreground fails at any text size.

---

## Findings

### A-1 · CRITICAL — Dark-mode scan banner token pairs are unspecified, and the implied mapping fails AA at 2.0–2.5:1

**Where:** `DESIGN.md:12-23` (`primary-dark #7FA7DB`, `accent-dark #4CC38A`, `warning-dark #F0A860`; `accent-foreground: '#FFFFFF'` listed once, light-only), `DESIGN.md:80` ("On mobile it is a full-screen banner fill, the loudest color in the product"), `DESIGN.md:110` scan banner, `EXPERIENCE.md:162` ("follows system dark mode"), `EXPERIENCE.md:107` (AA claim).

The spines claim WCAG AA and dark mode both. DESIGN.md specifies dark fill variants but **no dark foregrounds** — the only foreground tokens in the file (`primary-foreground`, `accent-foreground`, `warning-foreground`) are all `#FFFFFF` and there is no `-dark` counterpart. The scan banner is a full-screen *fill* with text on it, and the mobile client "follows system dark mode," so a dark-mode operator's accept banner resolves to white on `#4CC38A` = **2.22:1**, attention to white on `#F0A860` = **2.00:1**, primary actions to white on `#7FA7DB` = **2.48:1**. All three fail WCAG 1.4.3 *even at the largest text size* (3:1 large-text minimum) — and the scan banner is the largest text on the screen by explicit design intent, so this is the shipped failure mode, not an edge case. The single most consequential surface in the product is non-conformant in a mode the system enters automatically.

**Fix (spine addition, DESIGN.md colors block):**

```
# Dark variants flip the foreground, not just the fill: light fills on dark
# ground take near-black text, never the light-mode white.
primary-foreground-dark: '#0B0B0D'    # on #7FA7DB → 8.5:1
accent-foreground-dark: '#0B0B0D'     # on #4CC38A → 8.9:1
warning-foreground-dark: '#0B0B0D'    # on #F0A860 → 9.8:1
```
Plus a DESIGN.md rule: "Banner fills use their light-mode foreground only when the fill is dark; dark-mode fills (lightened hues) always take `#0B0B0D` foreground. Contrast is verified per token pair, fill × foreground, not per hue."

---

### A-2 · HIGH — The task path is camera-scan-first; a blind operator has no guaranteed non-visual route, and there is no manual SKU/bin entry fallback anywhere

**Where:** `EXPERIENCE.md:103` ("scan is the verb — every task flow is scan → banner → next"), `EXPERIENCE.md:20` ("Camera scan + paired HID scanners"), `EXPERIENCE.md:49` (task flow: "camera overlay + HID"), `DESIGN.md:96` ("the scan camera overlay occupies the top half of a task screen").

The a11y floor (`EXPERIENCE.md:111`) claims "every task state announced" — which reads as blind operability. But the primary input is aiming a camera at a barcode, which is inherently visual: VoiceOver/TalkBack give a blind operator no viewfinder feedback. The spines *imply* HID is the non-visual path ("camera overlay + HID input are interchangeable at any scan step") but never state it as a guarantee, never state that a flow is **completable end-to-end without the camera**, and — the sharpest gap — **no flow specifies a manual SKU/bin/barcode entry fallback** for a damaged label, an unscannable code, a dead camera, or a non-visual operator without a paired HID. The only manual entry named in either spine is the qty stepper fallback (`EXPERIENCE.md:78`). "Interchangeable" is the load-bearing word and it carries no behavior.

This should not be silently papered over: barcode-camera scanning is a genuine floor-reality constraint, and the honest posture is to name it as a constraint while guaranteeing the non-visual path that exists.

**Fix (spine additions):**

- EXPERIENCE.md, Interaction Primitives: "Every scan step accepts three equivalent inputs: camera scan, paired HID scan, and manual entry (SKU/bin code via keypad with lookup confirm). Manual entry is first-class, not a hidden recovery path — it is how the flow stays operable for a damaged label, a dead camera, or an operator who cannot aim a camera. Non-visual operation (VoiceOver/TalkBack) requires a paired HID scanner or manual entry; camera aiming is not announced and this is stated as a known constraint of camera-based barcode capture, not silently unmet."
- EXPERIENCE.md, Accessibility Floor, new bullet: "**Non-visual task completion** — every task flow is fully completable with camera disabled, via HID and/or manual entry; this is a floor acceptance test, not an aspiration."

---

### A-3 · HIGH — HID-as-keyboard has no focus-management behavior specified; scan input arriving mid-typing is unnamed

**Where:** `EXPERIENCE.md:20`, `:103` ("HID scanners pair as keyboard input"), `:162`.

HID scanners are the spine's interchangeable input and (per A-2) the non-visual lifeline, yet zero behavior is specified. HID wedges fail in predictable, well-known ways and all of them are silent in this spine:

1. **Mid-typing interleave** — operator is typing a qty or reason code; a scan arrives; the wedge's keystrokes splice into the typed field and corrupt both. Nothing says scans are captured by a dedicated always-focused capture field rather than whatever holds focus.
2. **Focus retention across the banner** — the flow is scan → full-screen banner → next step. If focus is not programmatically returned to the capture field after each banner/step advance, the *next* scan is lost or lands on a random control. For a blind operator this is fatal: the scan goes nowhere and nothing announces why.
3. **Scan-vs-human disambiguation** — wedges terminate with a suffix keystroke (Enter/Tab); the spine never says the capture field consumes scans and routes them, or how a scan is distinguished from a human keystroke burst.
4. **Focus recovery after dialogs/Esc** — Esc closes the topmost layer (`EXPERIENCE.md:114`) but nothing says focus returns to the capture field, not to `<body>`.

**Fix (spine addition, EXPERIENCE.md Interaction Primitives → Mobile):**

> "HID capture: each task step exposes a single scan-capture field that holds focus for the step's duration; focus is programmatically restored to it after every banner, dialog close (Esc), and step advance — a scan can never be lost to focus drift. Scans are routed to the capture field, not the focused control: while a manual-entry field is focused, an incoming scan does not splice into typed text — the capture field receives it and the step resolves as a scan. Scans and typed keystrokes are disambiguated by wedge terminator + timing; a scan mid-typing never corrupts a manual entry. Capture-field state ('waiting for scan') is announced to VoiceOver/TalkBack on focus."

---

### A-4 · HIGH — Offline scans are shown and announced as "accepted" while server replay may later reject them

**Where:** `EXPERIENCE.md:89-90` (offline: "Work continues; queue chip shows count"; replay: "every replayed item is re-authorized server-side… rejections quarantine"), `EXPERIENCE.md:111` (announced states: "Bin accepted"), `DESIGN.md:80` (green = "the scan-accepted color"), `EXPERIENCE.md:74` ("rejected scans never queue").

This is a genuine state-truth conflict, not a styling nit. When offline, the on-device decision is local; replay re-authorizes server-side and can quarantine the op (`EXPERIENCE.md:90`, AD-14). But DESIGN.md paints green = "scan-accepted" and EXPERIENCE.md's canonical announcement example is literally **"Bin accepted."** A blind operator who hears "Bin accepted" for 14 queued scans — several of which later quarantine to Conflicts & Reviews — has been told something false by the screen reader. The visual banner has the same problem for low-vision sighted operators: green accept on a scan that was only *recorded*.

**Fix (spine changes):**

- DESIGN.md:80 → "Confirm Green — the scan-*accepted-or-recorded* color… When offline, the banner states the record is queued, not accepted."
- EXPERIENCE.md:111 → announcement vocabulary: "**accepted** (online, server-confirmed)", "**recorded — queued for sync** (offline; count follows)", "**rejected — reason + nearest correct bin**", "**quarantined — review pending**". Never announce "accepted" for an un-replayed op. Queue chip count changes are announced (see A-8), so the queued-vs-accepted distinction is audible.
- Sync summary (`EXPERIENCE.md:90`) must be reachable and announced from the operator's task surface, not only visible.

---

### A-5 · MEDIUM — Scan banner states are color-coded with no specified non-color differentiator (WCAG 1.4.1)

**Where:** `DESIGN.md:110` ("full-width, color-coded (green accept / red reject+reason / amber attention)"), `EXPERIENCE.md:74`.

Reject and attention banners carry a reason line, which partially disambiguates; but **accept** has no reason text, and nothing in either spine specifies an icon, glyph, or shape per state. For deuteranopic/protanopic operators (green↔red↔amber is the worst-case axis in the palette) and for the large low-vision population that is neither blind (SR) nor fully sighted, three full-screen fills that differ only in hue is a 1.4.1 failure risk on the product's most important screen. Note also the reject red is *unspecified* (shadcn destructive inherited, `DESIGN.md:82`) — so its contrast on a full-screen fill is undefined wherever the banner ships.

**Fix:** DESIGN.md:110 → "…color-coded **and glyph-coded**: ✓ check (accept), ✕ cross (reject), ⚠ triangle (attention), ≥ 40px, foreground-colored — states are distinguishable without hue (WCAG 1.4.1). Reject red is pinned per platform with the same fill/foreground contrast rule as green and amber (≥ 4.5:1 text on fill in light, ≥ 4.5:1 with `#0B0B0D` in dark)."

---

### A-6 · MEDIUM — ⌘K command palette: no result announcements, no semantics, no discoverable entry point

**Where:** `EXPERIENCE.md:101`, `:114`.

⌘K is claimed as a core navigation primitive with nothing about its a11y contract: no combobox/listbox pattern (aria-expanded, aria-activedescendant), no `aria-live`/announcement of result count as the query narrows, no focus restore to the invoking element on close, no visible entry point for a keyboard user who doesn't know the shortcut (WCAG 2.1.1 is satisfied by ⌘K itself, but discoverability isn't), and `⌘` is macOS-only — the spine never names the Windows/Linux binding.

**Fix (spine addition, Interaction Primitives → Web):** "⌘K palette implements the ARIA combobox pattern; result count is announced as results change (polite); opening focus is trapped in the palette, Esc closes and restores focus to the invoker. A visible palette button sits in the app header (same behavior), and Ctrl+K is the cross-platform binding with ⌘K on macOS."

---

### A-7 · MEDIUM — Dense 40px rows + hover-revealed row actions: keyboard focus doesn't reveal, tablet touch is underspecified

**Where:** `DESIGN.md:96` ("dense table rows at ~40px"), `DESIGN.md:109` ("row actions on hover (desktop) / tap (touch)"), `EXPERIENCE.md:105` (bans hover-only affordances on touch and on `sm` viewports — **desktop keyboard is the gap**).

The ban on hover-only affordances covers touch surfaces and `sm` viewports, but a desktop **keyboard** user hovering nothing: actions revealed on hover must also be revealed on row focus (`focus-within`) or they are unreachable without a pointer. Secondary gaps in the same surface: (a) ~40px rows with multiple inline actions on a *tablet* — a stated surface (`EXPERIENCE.md:19`) — leaves sub-target spacing and a two-step reveal unmeasured against WCAG 2.5.8 (24px minimum, 2.2 AA); (b) sticky header must not obscure keyboard focus (WCAG 2.4.11) when tabbing down a dense table; (c) inline-editable cells (`EXPERIENCE.md:101`) have no keyboard entry, edit-commit/cancel, or SR announcement ("editable, quantity, 120, editing") specified; (d) nothing states tables are semantic `<table>` with header `<th>`s and named pagination controls.

**Fix:** add to the data-table row in `DESIGN.md.Components` or `EXPERIENCE.md` Component Patterns: "Row actions appear on hover **or keyboard focus** of the row. Tablet/touch: actions are ≥ 44px targets with ≥ 8px separation; 40px rows keep ≥ 24px effective targets (WCAG 2.5.8). Sticky headers never obscure focus (scroll-into-view). Editable cells: Enter to edit, Esc cancels, commit announced ('Quantity updated to 120'). Tables are semantic tables; header cells are th-scoped; pagination and export controls are named buttons."

---

### A-8 · MEDIUM — Qty stepper: accessible name, role, and value-announcement unspecified; "glove-tolerant" and "≥48dp" never reconciled

**Where:** `EXPERIENCE.md:78` ("Large +/-, gloves-friendly; … manual entry is a deliberate fallback tap"), `:115` ("Scan targets ≥ 48dp; … glove- and one-handed-usable").

The manual-entry fallback existing is good — but it is a *tap target* with no specified form behavior: numeric keypad, labeled field ("Counted quantity"), value announced on commit. And the stepper's own a11y is silent: a bare "+" fails WCAG 4.1.2 name; the count changing is exactly the state a blind counting operator needs announced (`role="spinbutton"` / `aria-live` or platform equivalent — and on the web dashboard side too). Separately, "≥ 48dp" and "glove-tolerant" are asserted side by side with no reconciliation: a gloved finger is a fat, low-precision pointer; 48dp minimums with dense spacing are the *floor*, not glove-tolerant. Industry floor practice is ≥ 56dp for gloved primary targets plus increased inter-target spacing.

**Fix:** EXPERIENCE.md:78 → "Large +/-, ≥ 56dp each with ≥ 12dp separation (glove tolerance exceeds the 48dp floor — 48dp is the minimum for any target, primary gloved targets are ≥ 56dp); buttons carry accessible names ('Increase counted quantity' / 'Decrease…'); the value is announced on every change. Manual entry opens a labeled numeric field, announces its value on commit." And in the a11y floor, split the claims: "≥ 48dp everywhere (exceeds WCAG 2.5.8); **gloved-primary targets ≥ 56dp with ≥ 12dp spacing**."

---

### A-9 · MEDIUM — Offline queue chip: no announcement behavior, no large-type truncation rule

**Where:** `EXPERIENCE.md:50`, `:89-90`, `DESIGN.md:111`.

The chip is the operator's only view of sync risk during the dead-zone flow (Flow 2) and nothing says how a screen reader encounters it: not marked as a status region, no polite live-region on count changes (14 → 15 → 15 → settled tick-up), and the "Queued 14 — will sync when Wi-Fi returns" microcopy (`EXPERIENCE.md:63`) is only guaranteed if the chip is an announced control. Dynamic type is claimed for the scan banner only (`EXPERIENCE.md:112`) — a header chip at accessibility largest sizes is a classic truncation casualty.

**Fix:** EXPERIENCE.md:50 → "Queue state | Persistent header | Queued-op count while offline; **role=status, announced politely on every count change** ('Queued 14, will sync when Wi-Fi returns'); carries a sync/offline glyph + text, never color alone; remains legible at largest dynamic-type setting (wraps to the label, never truncates the count)."

---

### A-10 · MEDIUM — "Every task state announced" lacks the reject-detail and quarantine vocabulary, and no announcement timing/urgency rule

**Where:** `EXPERIENCE.md:111`.

The floor gives two example strings and stops. Missing: (a) the reject announcement must include the **reason and the offered nearest correct bin** (`EXPERIENCE.md:74`, `:137`) — "Wrong item — expected SKU 8452, nearest correct bin B-01-04" — otherwise the offered recovery path is visual-only; (b) the banner is the *only* outcome surface and auto-advances the flow, so accept announcements should be assertive and rejects assertive with the reason, not swallowed by a busy SR mid-scan-rhythm; (c) announced vocabulary must match A-4 (accepted / recorded-queued / rejected / quarantined). Also: rapid scanning produces rapid full-screen banner swaps — no flash/photosensitivity statement (WCAG 2.3.1) and no statement that banners never auto-dismiss before the announcement completes.

**Fix (spine addition, a11y floor):** "Reject and attention announcements include the reason and the offered next action. Banner announcements are assertive; the banner never auto-dismisses before its announcement is delivered. Rapid-scan banner swaps stay within flash-safety limits (no full-screen transitions faster than 3/s)."

---

### A-11 · MEDIUM — Dynamic type honored for the scan banner only; task cards, steppers, inbox, and queue chip have no largest-setting rule

**Where:** `EXPERIENCE.md:112` ("Dynamic type honored; scan banner legible at largest setting without truncation").

"Dynamic type honored" is one clause covering five surfaces with no testable rule anywhere except the banner. Task cards (inbox — the operator's home screen), qty steppers, reason-code pickers, and the queue chip all carry floor-critical text and none has a truncation/wrap contract at the largest accessibility size. The scan-banner guarantee is also stated only as "legible… without truncation" — it should also guarantee the banner grows (min-height 96px is a floor, `DESIGN.md:66`, not a cap) so enlarged text never reflows into a second unlabeled region.

**Fix:** "Dynamic type honored on every mobile surface: text scales to the OS largest accessibility size with no truncation and no fixed-height container clipping — banners grow (`minHeight` 96px is a minimum, never a cap), task cards reflow to two lines of meta before truncating, and the queue chip wraps rather than clipping the count."

---

### A-12 · LOW — Reduce Motion covers the banner swap only; skeleton shimmer and sync ticks are unspecified

**Where:** `EXPERIENCE.md:113`, `:87` (skeleton rows), `:90` ("settled count ticks up").

Banner-swap-instant is right. But cold-load skeletons almost always ship with a shimmer animation (shadcn default) and the sync chip "ticks" — both are motion a vestibular-sensitive operator meets on every session start. One clause fixes it: "Reduce Motion disables skeleton shimmer (static blocks) and count-tick transitions (instant value change) in addition to the instant banner swap."

### A-13 · LOW — Focus-visible indicator styling and focus-not-obscured are claimed only as "focus indicators use primary blue"

**Where:** `DESIGN.md:79` ("focus indicators" among primary-blue uses), `EXPERIENCE.md:114`.

`#1E4E8C` on white is 8.32:1 (passes 1.4.11 non-text), so the token is safe — but the floor never states the indicator itself: visible on *all* components including dense table rows and dark mode (shadcn ring), ≥ 3:1 against adjacent colors, never removed (`outline: none` without replacement), and keyboard focus never sits beneath the sticky header. Worth one bullet so an implementation can't inherit shadcn's thin default ring and call it done.

### A-14 · LOW — "Permission denied: surface hidden" has no screen-reader navigation consequence stated

**Where:** `EXPERIENCE.md:94`.

Hiding the surface is defensible, but nothing says the sidebar link is removed from the accessibility tree too (a present-but-dead link announced to SR users is worse than absence) and that in-page entry points to a hidden area are likewise removed. One clause: "Hidden surfaces are removed from the tree entirely — nav entry, links, and search results — so no unreachable target is ever announced."

---

## What the spines already get right (keep, don't regress)

- **Light-mode pairs all pass AA at 4.5:1+** — computed above; `#1E4E8C`/white at 8.32:1 is comfortable for primary buttons and links.
- Screen-reader task-state examples are concrete and operator-voiced (`EXPERIENCE.md:111`), not generic "announcements occur."
- Reduce Motion is named with the right artifact (banner swap) — most spines forget motion entirely.
- "Rejected scans never queue" (`EXPERIENCE.md:74`) and "no surprise mid-keystroke lockouts" (`EXPERIENCE.md:95`) are genuinely protective behavioral rules.
- The banned list (`EXPERIENCE.md:105`) kills hover-only touch affordances and swipe-to-delete — two of the most common mobile a11y failures.
- 48dp exceeds the WCAG 2.2 AA 24px minimum (the gap is glove reality, not the floor — A-8).
- Amber-as-attention (never error, never decoration) gives the color semantics a legible grammar — once A-1 and A-5 land, the palette is sound.

## Priority order for spine edits

1. **A-1** (critical) — add the three dark foreground tokens; blocks Finalize.
2. **A-2** — name the non-visual constraint + manual-entry fallback (changes flow specs, so it must precede mockups).
3. **A-3** — HID focus contract (blocks any task-flow spec that touches scan steps).
4. **A-4** — accepted/queued announcement vocabulary (one-token change in DESIGN.md, one row in the a11y floor).
5. **A-5, A-6, A-7, A-8, A-9, A-10, A-11** — concrete additions above; all are spine-text sized.
6. **A-12…A-14** — single-clause additions, batch into the a11y floor section.