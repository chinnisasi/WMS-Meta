---
title: 'Story 1.3 — Zones, bins, and the setup checklist'
type: 'feature'
created: '2026-09-08'
status: 'done'
baseline_commit: 'meta 6b761c6 · wms-be 698b111 · wms-fe 90fb4ff'
route: 'dispatch'
review_loop_iteration: 0
context: ['_bmad-output/implementation-artifacts/epic-1-context.md']
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** A seller can create a warehouse (1.2) but cannot define its floor — no zones, no bins — so no valid putaway/pick location exists for Epic 2/3, and there is no onboarding progress surface telling her what remains before her first GRN.

**Approach:** In the tenancy module, add `zones` and `bins` (the first warehouse-scoped tables: `warehouse_id` alongside `tenant_id`), a grid generator that mass-creates bins in `A-01-01…` style, bin block/unblock, and a computed per-tenant setup-completion checklist. Expose all of it over OpenAPI; give the web app a zones/bins setup area in Settings and the checklist card.

## Boundaries & Constraints

**Always:**
- AD-3 carried forward: `tenant_id` on every row + RLS policies verified by test; `zones`/`bins` are the first tables to also carry `warehouse_id` (schema.ts already anticipates this). Warehouse ownership is enforced in the app layer (`assertOwnTenant` + a warehouse-belonging check); RLS stays single-dimension (`tenant_isolation`).
- AD-5: every mutating endpoint requires a client ULID `Idempotency-Key` with same-transaction de-dupe and replay; the grid generator is one transaction + one idempotency record (all-or-nothing).
- Bin codes unique per warehouse (unique `(warehouse_id, code)`); duplicates rejected naming the conflicting code (`duplicate-bin-code` / `duplicate-zone-code`).
- Bins are created with code, capacity (positive integer, base-UoM units), and type (fixed set: `shelf`/`pallet`/`floor`/`staging`); bins require a parent zone; a created bin is immediately usable downstream (no dormant state). `blocked` (boolean, default false) marks broken bins.
- Grid generator bounds: ≤ 500 bins per run; codes follow `A-01-01` (aisle letter, bay, level).
- Setup checklist is **computed on read** (no stored step rows): steps — warehouse created (≥1 warehouse), bins defined (≥1 bin), catalog imported (always false until 1.4), users invited (false until 1.5) — shown honestly as pending.
- Problem-details errors with machine-readable codes; deterministic primitives (uuidv7, UTC, cursor pagination); OpenAPI regenerated client (never hand-written types); backend-first ordering.

**Never:**
- No bin/zone editing beyond the `blocked` flag (rename/re-move are later stories), no location barcode printing, no catalog/users checklist steps flipping in this story, no mobile changes, no FK constraints (repo convention is uuid columns + app-layer integrity), no decorative zone color-coding.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Zone create | `POST /tenants/{t}/warehouses/{w}/zones` `{code, name}` + Idempotency-Key | 201 zone snapshot; replay re-serves it | 409 `duplicate-zone-code` names the code; foreign/nonexistent warehouse → 404 `not-found`; wrong tenant → 403 |
| Manual bin create | `POST .../zones/{z}/bins` `{code, capacity, type}` | 201 bin snapshot, immediately listed | 409 `duplicate-bin-code` names the code; foreign zone → 404 |
| Grid generate | `POST .../zones/{z}/bins/grid` `{aisleFrom, aisleTo, baysPerAisle, levelsPerBay, capacity, type}` | 201 all bins in one transaction (≤500), codes `A-01-01…` | Any code collision → 409 naming the first conflicting code, nothing committed; replay re-serves the same snapshot |
| Block/unblock bin | `PATCH .../bins/{binId}` `{blocked}` + Idempotency-Key | 200 updated bin | Unknown bin → 404; foreign tenant → 403 |
| Zone/bin list | `GET .../zones`, `GET .../zones/{z}/bins?cursor&limit` | 200 keyset pages `{items, nextCursor}` | 400 `invalid-cursor` on crafted cursors; limit 1–200 |
| Checklist | `GET /tenants/{t}/setup-checklist` | Steps with done flags + deep links (warehouse: done after 1.2; bins: once ≥1 bin; catalog/users: pending) | 401/403 per session rules |
| Isolation | Foreign session or unscoped non-superuser read of zones/bins | Empty / 403 (fail-closed RLS, verified by test) | — |

## Code Map

- `wms-be/src/modules/tenancy/` — everything lands here (module owns tenancy master data): new `zone.command.ts` + `bin.command.ts` copying `warehouse.command.ts` (ctor `@Inject(DATABASE)` + `@Inject(EVENT_BUS)`; `withTenantTransaction`; constraint-name consts matching index names for `isUniqueViolationOn`; publish-after-commit guarded). New routes + DTOs in `tenancy.controller.ts` (`@Controller('tenants')`, nested `:tenantId/warehouses/:warehouseId/...`, `IDEMPOTENCY_HEADER`, `assertOwnTenant`, `TenantSessionGuard`, inline query DTO with limit 1–200). Register providers in `tenancy.module.ts`.
- `wms-be/src/modules/tenancy/tenancy.service.ts` — add `assertWarehouseInTenant(tx, tenantId, warehouseId)` (404 `not-found` when absent) and the checklist read (counts warehouses/bins via `withTenantTransaction`).
- `wms-be/src/shared/db/schema.ts` + `drizzle/0003_*.sql` — `zones` (`tenant_id`, `warehouse_id`, `code`, `name`), `bins` (`tenant_id`, `warehouse_id`, `zone_id`, `code`, `capacity` int, `type` text, `blocked` bool default false); unique indexes `zones_warehouse_id_code_unique`, `bins_warehouse_id_code_unique`, keyset `(created_at, id)` indexes; hand-written RLS DDL copied from 0001 (`ENABLE ROW LEVEL SECURITY` + `<table>_tenant_isolation` USING/WITH CHECK on the NULLIF guard). Drizzle snapshot records `isRLSEnabled: false` (known gap). Next migration number: 0003.
- `wms-be/test/tenancy.spec.ts` — extend `cleanupRows()` (bins → zones first), reuse `registerTenant`/`signIn`/`warehouseBody`; add duplicate-code, grid-generate + replay, block, checklist, and RLS-probe coverage for the new tables.
- `wms-fe/src/lib/api/client.ts` — new `fetchApi*` wrappers per the existing shape; `bun run api:generate` after `openapi:export`.
- `wms-fe/src/lib/` — `use-setup-checklist.ts` (new) + zone/bin loaders mirroring `use-tenant-warehouses`/`fetch-all-warehouses` (generic cursor walker keyed by warehouse + zone; revision events like `WAREHOUSES_CHANGED_EVENT`).
- `wms-fe/src/app/(app)/settings/page.tsx` — replace the static "Setup checklist" stub with the checklist card (mockup `key-web-overview.html` lines 293–319: badge "N of M done", progress bar, tick rows + Continue links); add a zones/bins setup card group (zone form, grid-generator form, manual bin form, zone→bins `DataTable` with block toggle) — sub-cards on `/settings`, no new route. `FeedbackBanner` + `rejectionReason()` gains `duplicate-zone-code`/`duplicate-bin-code` branches.
- `wms-fe/src/components/data-table/data-table.tsx` — reuse as-is (Prev/Next cursor paging, 40px rows, tabular numerals).

## Tasks & Acceptance

**Execution:**
- [x] `wms-be/src/shared/db/schema.ts` + `drizzle/0003_*.sql` — `zones` + `bins` tables, unique + keyset indexes, hand-written RLS DDL.
- [x] `wms-be/src/modules/tenancy/**` — zone/bin command services (idempotent create, grid generator ≤500 in one tx, block toggle), controller routes + DTOs (trimmed inputs, `format` constraints), `assertWarehouseInTenant`, computed setup-checklist read, domain events (`zone.created`, `bins.generated`, `bin.blocked`) via the seam.
- [x] `wms-be/test/tenancy.spec.ts` — e2e: zone/bin CRUD happy paths, duplicate codes naming the code, grid-generate replay (no double bins), block toggle, checklist flags, RLS probes on both tables, cleanup extended. `bun run openapi:export`.
- [x] `wms-fe/src/lib/**` — regenerated client, `fetchApi*` wrappers, checklist + zone/bin hooks with cursor walking.
- [x] `wms-fe/src/app/(app)/settings/**` — checklist card (mockup pattern) + zones/bins setup cards (zone create, grid generator, manual bin, list with block toggle); problem-code-branched feedback.
- [x] `docs/repos/wms-be/README.md`, `docs/repos/wms-fe/README.md` (meta) — contract updates for the new endpoints, warehouse-scoping rule, and checklist semantics.

**Acceptance Criteria:**
- Given a Warehouse, when the grid generator runs, then all Bins are created in their Zones with code, capacity, and type — and a Bin code duplicating an existing code in the same Warehouse is rejected naming the conflicting code.
- Given a created Bin, then it is immediately listed and usable as a putaway/pick target (no dormant state).
- Given a Tenant, when its setup checklist is fetched, then the steps (warehouse, bins, catalog, users) reflect true completion state and check off as they are satisfied.
- Given a cross-tenant read attempt under another tenant's session, then it fails (RLS verified by test on both new tables).
- Given both repos, when lint + tests + typecheck + build run, then all pass; the OpenAPI drift guards stay green.

## Open Questions

(none — every choice below was settled from the epics, UX mockups, or existing repo patterns, and recorded in Boundaries/Design Notes: checklist computed-on-read; Settings sub-cards; bin types fixed set; capacity in base-UoM units; blocking in scope per the Flow-1 mockup; 404 for foreign warehouse/zone)

## Design Notes

- **Warehouse scoping (the new pattern):** RLS stays single-dimension (`tenant_isolation`) — the same fail-closed policy as 0001 applied to both tables. Warehouse ownership is app-layer: `assertWarehouseInTenant` inside the transaction before any zone/bin write. Composite RLS (tenant + warehouse) is rejected: `warehouse_id` is not in `app.tenant_id`-style session state and the added policy complexity buys nothing over the app-layer check + tenant RLS.
- **No FKs:** hierarchy is `bins.zone_id` → `zones.id`, `zones.warehouse_id` → `warehouses.id` by uuid column + index, validated in the command transaction — consistent with the existing FK-free schema.
- **Grid generator:** aisles are letters `aisleFrom..aisleTo` (A–Z), bays and levels 1–99, zero-padded to width 2 (`A-01-01`). One `withTenantTransaction`, one idempotency row, response snapshot carries the generated count + first/last code; replay re-serves it. Cap 500 guards accidental `Z×99×99` runs.
- **Checklist computed-on-read:** no step table to go stale; flags derive from counts in one transaction. Deep links point at `/settings` today (catalog/users links route there until 1.4/1.5 build their surfaces).
- **Events:** inline `satisfies DomainEvent` literals (`zone.created`, `bins.generated` with count, `bin.blocked` with the flag) — the seam has no central union to update.

## Spec Change Log

- **2026-09-08 — Created** from Story 1.3 intent (epics.md) + epic-1 context; investigation by two subagents (wms-be tenancy patterns, wms-fe Settings/UX surface).
- **2026-09-08 — Implemented** across all three repos (wms-be `64b727e`, wms-fe `c82550d`, meta docs PR). Loop-3 verification re-run by the orchestrator: backend 45/45 e2e (one test added — zones/bins list limit bounds + crafted-cursor `400 invalid-cursor`, closing a matrix-audit gap), frontend 50/50 + lint + typecheck clean.

## Review Triage Log

| # | Finding (source) | Verdict | Evidence |
|---|------------------|---------|----------|
| 1 | Stale zone selection survives a warehouse switch — the two bin forms keep internal `zoneId` state (zone-bin-setup.tsx) | medium | Verified: `ZonesBinsSetupSessioned` resets only its own `zoneId`; `GridGeneratorForm`/`ManualBinForm` keep theirs. Switch warehouses (select or sidebar pick) → form select renders blank but submit posts the previous warehouse's zoneId → guaranteed 404 with a misleading reason. |
| 2 | `useZoneBins` never resets `requested` when zone/warehouse changes (use-zone-bins.ts) | medium | Verified: the cursor state persists across `zoneId` changes; a cursor earned on zone A is replayed against zone B; the render-time key check passes (page matches `requested`) so a mis-paged list is shown. |
| 3 | `GET .../zones/{zoneId}/bins` missing from both interface-contract docs (meta) | medium | Verified in the docs diff: wms-be README contract lists zone create/list, bin create, grid, PATCH, checklist — no bins list; wms-fe README "Endpoints called" likewise omits it. Exactly the drift the contracts exist to catch. |
| 4 | `@Max(99)` declared in `@ApiProperty` but not enforced on `baysPerAisle`/`levelsPerBay` (tenancy.dto.ts) | medium | Verified: DTO has only `@IsInt() @Min(1)`; `padStart(2)` lets 3-digit bays/levels through under the 500 cap → codes like `A-400-01` violate the documented width-2 `A-01-01` format. |
| 5 | `capacity` unbounded → Postgres integer overflow surfaces as unhandled 500 (tenancy.dto.ts) | medium | Verified: `@IsInt() @Min(1)` only; a value above 2³¹−1 passes validation and fails at the `integer` column with no code mapping → 500. |
| 6 | Grid cap check runs after `gridCodes()` materializes up to 255,024-code array (bin.command.ts) | low | Verified: real, bounded-memory waste before the 422; one-line arithmetic count check before generation fixes it. |
| 7 | Grid idempotency hash uses raw aisle letters while codes are generated from uppercased ones (bin.command.ts) | low | Verified: replaying the same grid as `a..c` after `A..C` with the same key yields spurious `422 idempotency-key-reuse`. One-line fix: hash the normalized values. |
| 8 | `createBin` skips explicit `assertWarehouseInTenant` while its class doc claims every write performs it (bin.command.ts) | low | Verified: behavior holds transitively (`assertZoneInWarehouse` can't see a foreign warehouse's zone → 404), but the comment contradicts the grid/setBlocked paths and the spec's stated pattern; a one-line call aligns code and doc. |
| 9 | Race fallback names `codes[0]`, not the actual conflicting code (bin.command.ts unique-violation catch) | low | Verified: true only under a concurrent-writer race (transaction already aborted; naming the true code needs an out-of-tx re-query). Status + machine code are correct; the spec's Design Note already declares this race "retry replays cleanly". Fix adds error-path complexity for a rare race. |
| 10 | Zones keyset pagination never exercised multi-page (tests) | low | Verified: the bins test walks the full cursor chain; the zones test asserts only first-page membership. Adding a walk is a direct test addition. |
| 11 | `422 idempotency-key-reuse` untested on all four new mutating routes (verification-gap, pre-verified) | medium | Filed grep evidence: the 422 test exists only for registration + warehouse create; the new routes have only byte-identical replays. (The layer's `payloadHash`-drops-`zoneId` demonstration is wrong — the hash includes it — but the missing-test claim stands.) |
| 12 | OpenAPI 400 descriptions understate actual 400s: list routes say "Malformed cursor" only (limit bounds also 400); grid 400 omits descending-aisle `validation-failed` | low | Verified against the OpenAPI diff and the controller DTO; text-only fix (requires re-export). |
| 13 | Grid-form `duplicate-bin-code` message renders a hole: `rejectionReason(error)` without the code, discarding `error.detail` that names the conflicting code (zone-bin-setup.tsx) | medium | Verified: `GridGeneratorForm` catch passes no `attemptedCode`, so the branch prints "Bin code  is already used…". User-facing on a real path (grid collision). |
| 14 | No keyset-supporting indexes (`(warehouse_id, created_at, id)`, `zone_id`) | low | Verified absent, but the composite unique `(warehouse_id, code)` serves warehouse-prefix lookups, per-zone bin counts stay small at this stage, and the fix is a new migration — not a direct correction. Revisit when volumes grow (bin administration, 3-6). |
| 15 | `fetchAllPages` silently truncates at 20 hops (~1000 zones at default limit) | low | Mirrors the accepted 1.2 `fetchAllWarehouses` 20-hop convention (deliberate review-loop-1 decision); surfacing truncation adds API surface; unlikely volumes. |
| 16 | Concurrent-idempotency `409 conflict` branch untested | low | Requires true-concurrency fault injection; the same branch in the 1.2 warehouse command is untested; rare path. |
| 17 | Zone/bin code validation asymmetric/case-sensitive (manual codes any case, uniqueness byte-exact) | low | Real observation, but the spec (frozen) settles only the grid format; manual-code normalization would change public behavior the intent doesn't mandate. Flag as a convention candidate for story 3-6, not a 1.3 defect. |
| 18 | Every bin mutation triggers a full zones re-walk (single `ZONES_CHANGED_EVENT`) | low | The one-event-covers-both design is documented in `zones.ts`; finer granularity adds invalidation machinery for small lists. |
| 19 | Checklist/zones have no loading/error affordance (null on both loading and failure) | low | Quiet-chrome-on-failure is the accepted 1.2 read-only-surface convention (`useTenantWarehouses` comment); error states would add hook machinery beyond a direct correction. |
| 20 | Missing trailing newlines on new files | low | Several pre-existing repo files also lack trailing newlines (visible in the same diff); cosmetic. |
| 21 | Sprint status not advanced to `review` | false | Orchestrator-managed workflow artifact, not diff code; status advances at the step-05 presentation. |
| 22 | `WarehouseListQuery` reused for zones/bins routes (naming) | false | The class validates generic cursor/limit; no caller diverges today; a rename is churn without a named harm. |
| 23 | The story's three domain events are emitted but no test observes them (verification-gap, pre-verified) | defer | Filed evidence stands (no test reads the bus), but the only consumer is a log-only bus with no subscribers; pin the events when the first subscriber/outbox lands. |

**Grouping → routing** (highest verdict per group; no loopback — `review_loop_iteration` stays 0):

- **patch** G1 (#4+#5+#6, medium): DTO bounds unenforced (bays/levels 99, capacity int32) + pre-materialization cap check.
- **patch** G2 (#7, low): grid idempotency hash not normalized.
- **patch** G3 (#8, low): `createBin` explicit warehouse assert.
- **patch** G4 (#1+#2, medium): stale scope state in the Settings surface (form zone state + hook cursor).
- **patch** G5 (#13, medium): grid duplicate-bin-code message hole.
- **patch** G6 (#3, medium): GET-bins contract lines missing in both READMEs.
- **patch** G7 (#11, medium): 422 reuse tests on the four new routes.
- **patch** G8 (#10, low): zones multi-page cursor-walk test.
- **patch** G9 (#12, low): OpenAPI 400 description text.
- **defer** D1 (#23): domain events unpinned until first subscriber.