---
name: WMS
description: Multi-tenant warehouse management SaaS — web dashboard for managers (shadcn/ui on Next.js) and mobile scan client for floor operators (Expo/RN); this DESIGN.md is the shared token layer plus the web brand delta.
status: final
created: '2026-09-08'
updated: '2026-09-08'
sources:
  - ../../prds/prd-WMS-Meta-2026-09-07/prd.md
  - ../../prds/prd-WMS-Meta-2026-09-07/addendum.md
  - ../../architecture/architecture-WMS-Meta-2026-09-08/ARCHITECTURE-SPINE.md
colors:
  # Web brand deltas on shadcn defaults — all unlisted tokens (background,
  # foreground, muted, border, input, ring, card, popover, destructive) inherit.
  primary: '#1E4E8C'
  primary-foreground: '#FFFFFF'
  accent: '#16794C'
  accent-foreground: '#FFFFFF'
  warning: '#B45309'
  warning-foreground: '#FFFFFF'
  # Mobile maps the same hues from its own theme layer; dark variants required there.
  primary-dark: '#7FA7DB'
  primary-foreground-dark: '#0A1A2A'
  accent-dark: '#4CC38A'
  accent-foreground-dark: '#07210F'
  warning-dark: '#F0A860'
  warning-foreground-dark: '#1F1002'
  # Banner states are never color-only: each carries a state glyph + word
  # (✓ Accepted / ↻ Queued / ✕ Rejected / ⚠ Held for review).
  scan-accepted: '{colors.accent}'
  scan-queued: '{colors.warning}'
  scan-rejected: '{colors.destructive}'
  scan-quarantined: '{colors.warning}'
typography:
  # Web inherits shadcn's sans ramp (Geist Sans). Only two overrides:
  kpi:
    fontFamily: 'Geist Sans'
    fontSize: 28px
    fontWeight: '600'
    fontVariantNumeric: tabular-nums
  data:
    fontFamily: 'Geist Sans'
    fontVariantNumeric: tabular-nums
  # Mobile: platform-native (note fields per the design.md spec).
  title:
    note: 'iOS Title 1 · Android Headline Small'
  body:
    note: 'iOS Body · Android Body Large'
  scan-result:
    note: 'iOS Title 1 semibold · Android Headline Small medium — the largest text on any task screen'
rounded:
  sm: 4px
  md: 6px
  lg: 8px
  full: 9999px
spacing:
  '1': 4px
  '2': 8px
  '3': 12px
  '4': 16px
  '5': 24px
  '6': 32px
  '7': 48px
components:
  button-primary:
    background: '{colors.primary}'
    foreground: '{colors.primary-foreground}'
    radius: '{rounded.md}'
  kpi-tile:
    valueTypography: '{typography.kpi}'
    radius: '{rounded.md}'
  data-table-row:
    valueTypography: '{typography.data}'
  scan-banner:
    radius: '{rounded.md}'
    minHeight: 96px
---

# DESIGN.md — WMS Web Dashboard + Mobile Scan Client

> `[ASSUMPTION]` No brand deck exists; the product name is the PRD's working title. This spine defines a working visual identity — replaceable wholesale when naming/branding work lands, without touching EXPERIENCE.md behavior.

## Brand & Style

WMS is an industrial-clarity tool: the system the floor trusts at 11:59 PM during a flash sale. The aesthetic posture is a calm data tool, not a consumer app — dense where the data is dense, silent where nothing needs saying, loud in exactly one place (the scan result). Two surfaces share one token layer: the **web dashboard** inherits shadcn/ui defaults wholesale and adds only the brand delta below; the **mobile scan client** inherits platform conventions and maps the same brand colors into its theme. India-first context is ambient (₹, dd/mm, IST), never decorative.

## Colors

- **Primary Blue (`#1E4E8C` light / `#7FA7DB` dark)** — brand color: primary buttons, active nav, links, focus indicators. Replaces shadcn's `primary`.
- **Confirm Green (`#16794C` light / `#4CC38A` dark)** — the *scan-accepted* color and success states. On mobile it is a full-screen banner fill, the loudest color in the product. Never decorative; never used for chrome. Dark-mode banner fills always pair with their dark-foreground tokens (`accent-foreground-dark` etc.) — white on dark fills fails AA and is forbidden.
- **Attention Amber (`#B45309` / `#F0A860` dark)** — QC holds, expiry alerts, FEFO-override prompts, variance warnings, and the offline queue chip. Means "look, then decide" — distinct from errors.
- **All other web tokens** inherit shadcn defaults; if the brand can't justify an override, it doesn't. Error/destructive stays shadcn's.
- Avoid: gradients, celebratory color, color-coded data categories, a second brand hue. Two colors + amber + shadcn defaults, and stop.

## Typography

Web inherits shadcn's Geist Sans ramp. Two brand rules:

- **`kpi` (28px semibold, tabular numerals)** — every KPI tile value on the dashboard. Tabular-nums everywhere numbers align in columns (`data` role): bin codes, quantities, money, timestamps. A dashboard whose digits jitter between frames reads broken.
- **Mobile scan-result** — platform Title-1-class semibold; the largest text on any task screen, because it is the answer to "did that scan work?"

No display serif, no all-caps labels, no decorative type. Numbers are the brand.

## Layout & Spacing

Tailwind 4-based scale (4/8/12/16/24/32/48). Web: fixed left sidebar nav, content max-width unconstrained for data tables (tables are the product), dense table rows at ~40px. Mobile: single column, 16dp margins, thumb-reachable primary actions bottom-of-screen; the scan camera overlay occupies the top half of a task screen while active.

## Elevation & Depth

Inherited from shadcn (subtle shadows on interactive floating layers only). Mobile follows platform conventions (Material/HIG). No elevation as hierarchy; hierarchy is layout + type weight.

## Shapes

Tighter than defaults — `{rounded.sm}` (4px) inputs and table cells, `{rounded.md}` (6px) buttons/cards/banners, `{rounded.lg}` (8px) dialogs. Crisp corners read "instrument." Pills (`{rounded.full}`) only on status badges.

## Components

- **KPI tile** — `{typography.kpi}` value, muted label, delta caption; reconciles to ledger (AD-1), so no secondary "estimated" state exists.
- **Data table** — shadcn Table + dense rows, tabular numerals, cursor pagination, sticky header; row actions on hover (desktop) / tap (touch).
- **Scan banner** (mobile) — full-width, state-coded by fill + glyph + word (`scan-accepted` ✓ / `scan-queued` ↻ / `scan-rejected` ✕ / `scan-quarantined` ⚠), `{typography.scan-result}`, one line of reason text below. Never color-only — color-blind operators read the glyph (WCAG 1.4.1). Appears within 1.5 s of scan (NFR-6).
- **Queue indicator** (mobile) — persistent header chip showing queued-op count while offline; amber only, never red — offline is a state, not an error (FR-14).
- **Ledger timeline** — vertical event list from the inventory ledger; each row: event type, signed qty, actor, time, reference doc link (≤ 2 navigations, FR-28).
- **Approval card** — pending adjustment/variance with reason code, ledger-history link, approve/reject + threshold context.

## Do's and Don'ts

| Do | Don't |
|---|---|
| Reserve green for scan-accepted / success; amber for attention | Color-code SKUs, zones, or clients decoratively |
| Tabular numerals on every aligned numeric column | Proportional digits in KPIs or tables (digits jitter) |
| Dense data tables — density is the feature | Card-per-row layouts for list data |
| One loud element per mobile screen (the scan banner) | Animations, confetti, or haptics celebrating throughput |
| ₹, dd/mm, IST consistently via shared formatters | Locale-by-screen inconsistency (₹ vs ₹, mm/dd vs dd/mm) |
| Inherit shadcn/platform defaults everywhere else | Restyle inherited components "to feel branded" |