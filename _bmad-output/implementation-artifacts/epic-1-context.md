# Epic 1 Context: Foundation — Tenant Onboarding & Team

<!-- Compiled from planning artifacts. Edit freely. Regenerate with compile-epic-context if planning docs change. -->

## Goal

A new seller (Priya) can sign up, get an isolated tenant, configure her warehouse floor (zones and bins via grid generator or manual entry), import her catalog from CSV/XLSX with fix-mode so errors are corrected without starting over, and invite her team with role-gated permissions. This epic is the onboarding funnel — the conversion surface — and it establishes the monorepo scaffold and design-system shell that every subsequent story and epic builds on instead of re-deciding structure.

## Stories

- Story 1.1: Monorepo scaffold and design system shell
- Story 1.2: Tenant registration and warehouse creation
- Story 1.3: Zones, bins, and the setup checklist
- Story 1.4: Catalog import with partial commit and fix mode
- Story 1.5: Users, roles, and permission gating

## Requirements & Constraints

- A Tenant with zero Warehouses cannot create stock records — no orphan inventory. Bin codes are unique per Warehouse; duplicates are rejected naming the conflicting code. A created Bin is immediately usable as a putaway/pick target in later epics — no dormant state.
- A setup-completion checklist is emitted and tracked per Tenant; its steps (bins defined, catalog imported, users invited, …) check off as satisfied.
- Catalog import (CSV/XLSX) carries SKU, name, UoM, UoM conversions, GST rate, HSN, batch/serial flags, and reorder defaults. A 5,000-row import with 30 bad rows commits 4,970 and produces a downloadable row-level error report naming each bad row and reason. Fix-mode re-import processes only previously failed rows. Duplicate SKU codes are rejected, never silently merged. A barcode value resolving to two SKUs in the tenant is rejected naming the conflict. SKU barcode values are generated at catalog entry; SKUs are individually editable afterward.
- Four roles — Owner, Ops Manager, Operator, Accountant — with permission sets gating every capability. An Operator cannot approve over-threshold adjustments or change Channel settings. Role changes take effect on the user's next action, not next login; the next denied action fails naming the role reason, never a mid-keystroke lockout. Every role change is audit-logged with actor, time, and reference.
- Multi-tenant isolation is severity-1: every table carries `tenant_id` (plus `warehouse_id` where operationally scoped); scoping applies on every access path including background jobs and exports; Postgres RLS backs the app layer as defense-in-depth and must be verified by test.
- Success measure: median time from tenant signup to first GRN ≤ 1 business day — onboarding must be fast and honest, not a demo.

## Technical Decisions

- Story 1.1 establishes the scaffold per the architecture spine: NestJS 12 api, Next.js 16 web, Expo 57 mobile (own repo), Drizzle (≥0.45.2) migrations on Postgres, and an OpenAPI pipeline generating typed clients for web/mobile (openapi-typescript / @hey-api/openapi-ts) — no hand-written API types on the consuming side.
- Backend is an event-sourced modular monolith: 13 NestJS modules plus `api/` and `jobs/` shells. This epic works in the **tenancy** module (tenants, users, roles, warehouses, zones, bin master data) and **catalog** module (SKUs, UoM, import). Modules own their tables exclusively and communicate only through interfaces and domain events — never each other's tables.
- Deterministic primitives from day one: UUIDv7 IDs, ISO-8601 UTC timestamps, integer quantities in base UoM, integer paise, GST rates as basis points, cursor pagination, RFC 9457 problem-details errors with machine-readable `code`. Regulatory constants live as versioned config, never code literals.
- All state mutation enters through one command layer; authorization is re-evaluated at command-service entry against the current role epoch — short-lived JWT + refresh are transport, not authority.
- Every mutating endpoint carries a client-generated ULID idempotency key, de-duped tenant-scoped in the same transaction as the write.
- Repo passes lint + tests in CI with the cross-repo pre-commit workspace guard intact; backend changes land before the frontend changes that consume them.

## UX & Interaction Patterns

- Implement the shared token layer: web inherits shadcn/ui defaults plus the brand delta — primary `#1E4E8C`, accent/scan-accepted green `#16794C`, warning amber `#B45309` (with their dark-mode foreground pairs; white on dark fills fails AA and is forbidden). No second brand hue, no gradients, no decorative color coding. Expo app maps the same hues in its platform theme.
- Typography and shape: 28px semibold tabular-nums `kpi` style for KPI tile values; tabular numerals on every aligned numeric column; 4px inputs/table cells, 6px buttons/cards/banners, 8px dialogs; pills only on status badges.
- Web shell carries the sidebar IA skeleton (Overview, Inventory, Inbound, Outbound, Moves, Conflicts & Reviews, Notifications, Replenishment, Channels, Compliance, Reports/Audit, Settings — Settings includes device enrollment and the setup checklist) and the interaction primitives: ⌘K command palette (navigate + actions), Esc closes the topmost layer, Enter commits. Permissions hide surfaces rather than showing "blocked" screens.
- Catalog import follows the import-wizard pattern: upload → progress → row-level error report download → fix-mode re-import, with partial commit shown honestly.
- Data tables: dense ~40px rows, cursor pagination (infinite scroll banned), sticky header, tabular numerals, filter presets.
- Responsive contract: ≥1024px full sidebar + tables; 768–1023px sidebar collapses to icons; <768px read + simple actions. Web contrast at WCAG 2.2 AA.
- Banned patterns (enforced in review/lint conventions): infinite scroll, hover-only touch affordances, modal stacks > 1 deep, celebratory animation, badge-count notification spam.

## Cross-Story Dependencies

- Story 1.1 is the substrate — build it first; 1.2–1.5 (and every later epic) depend on the scaffold, migrations, OpenAPI pipeline, and token layer.
- 1.2 precedes 1.3: zones/bins require a Warehouse to exist. The setup checklist (1.3) aggregates completion state across 1.2, 1.3, 1.4, and 1.5.
- 1.5's permission gating applies to the surfaces built in 1.2–1.4; roles must exist before gating is meaningful.
- Downstream: Epic 2 (ledger) builds on this scaffold and tenant scoping; the Bins created here become putaway/pick targets in Epic 3; catalog GST/HSN data and batch/serial flags feed Epics 2 and 8. No later epic may function without this one.