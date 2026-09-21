---
title: 'Kits and bundles (FR-38, AD-19)'
type: 'feature'
created: '2026-09-19'
status: 'in-progress'
baseline_commit: '58d0596' # wms-be main HEAD when implementation began
route: 'dispatch'
review_loop_iteration: 0
context:
  - '_bmad-output/implementation-artifacts/epic-11-context.md'
  - 'docs/design/SYSTEM-DESIGN.md'
  - 'docs/design/IMPLEMENTATION-GUIDE.md'
  - 'docs/design/modules/catalog.md'
  - 'docs/design/modules/outbound.md'
  - 'docs/design/modules/inventory.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** A tenant cannot sell a composition — a kit/bundle of several SKUs (a first-aid kit, a laptop + bag + mouse). FR-38: stock is held on components only; the kit allocates by exploding its BOM at order acceptance and is never independent stock. Today no kit modeling exists anywhere (verified: zero kit/BOM language in wms-be and the design docs), and nothing stops a kit SKU from receiving stock.

**Approach:** A kit **is** a SKU (AD-19 holds — the SKU stays the ledger's orderable unit). Catalog gains a `kit_compositions` table (kit sku → component sku × milli-qty, flat one level, kit-ness = presence of rows) with create/replace/list commands that attach a composition to an existing imported SKU. Outbound's `createOrder` explodes each kit line into **child order lines** (one per component, `parent_line_id` link) and reserves the components through the existing grant machinery — waves, picklists, picks, pack and dispatch then work on child lines unchanged.

**Decisions (2026-09-19):** flat BOM in v1 (no kit-of-kit nesting); kit compositions stay API-only — CSV import support deferred to 11-6; all-or-nothing per kit at acceptance (any component short → the whole kit line backorders, a kit never ships half its contents).

## Boundaries & Constraints

**Always:**
- Stock is held on components only — the kit SKU itself never reserves, receives or adjusts stock; component holds are real `reservations` rows owned by the child lines.
- Explosion is **point-in-time**: component sku ids and quantities are copied into child lines at acceptance; later composition edits never re-explode an accepted order.
- BOM is **flat** — a component SKU cannot itself be a kit (409 `kit-component-is-kit`). One SELECT resolves any composition; no recursion.
- Component lines backorder **all-or-nothing per kit**: if any component cannot fully reserve, the whole kit line backorders (no partial kit holds). Component lines that do reserve are independent afterwards.
- Both create and replace take `.for('update')` on the kit SKU row and every component SKU row, ordered by id — closing the concurrent mutual-composition cycle.
- Milli-unit convention throughout: component quantity is per ONE kit, in the component's base UoM milli-units; child line qty = kit line qty (milli, base) × per-kit component qty (milli).

**Never:**
- No kit-level ledger events, no kit stock table, no parallel reservation book — `order.created` carries the exploded child lines; no new outbound event.
- No kit-of-kit nesting, no production-kit concepts (Epic 19's FR-70 extends this model later — shape for extension, don't build it).
- No delete command for a composition (append-only philosophy); no changes to `skus`/`products` columns, the reservation table, Valkey scripts, or any ledger path.
- No CSV import changes (deferred to 11-6) and no FE UI — the kit surfaces (composition editor, order display of children) are 11-6/11-7.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Create composition | POST on an existing non-kit SKU with ≥1 unique component (each qty > 0) | 201, composition stored, `catalog.kit_created` | 404 unknown kit/component sku; 409 `kit-already-composed`; 400 `kit-self-reference` (component = kit sku); 409 `kit-component-is-kit` (component already a kit); 409 `duplicate-kit-component` |
| Replace composition | PUT with the full non-empty component array | 200, rows replaced, `catalog.kit_edited` | Same arms as create minus already-composed; 400 `empty-kit-composition` |
| Kit list | GET kits, keyset-paged | Kit SKUs with their compositions | N/A |
| Order with kit line | createOrder, line qty Q of kit K (ATP covers all components) | Parent line reservedQty 0; child lines per component with parentLineId, reserved holds owned by child line ids; `order.created` carries children | N/A |
| Kit partially short | A component's ATP < required | Whole kit line + children backordered, no holds for that kit | N/A |
| Mixed order | Kit line + ordinary SKU line | Ordinary line reserves exactly as before; explosion changes nothing for it | N/A |
| Receive a kit SKU | GRN against a kit SKU | Refused — `kit-cannot-hold-stock` (409) | Same guard on stock.adjust |
| Replay | Same idempotency key, same payload | First order's snapshot, no double explosion | Divergent payload → 422 |
| Composition edited later | Accepted kit order vs new composition | Accepted order unaffected (point-in-time children); new orders use new composition | N/A |

</frozen-after-approval>

## Code Map

- `wms-be/src/shared/db/schema.ts` -- NEW `kitCompositions` table beside the catalog tables: id, tenantId, `kitSkuId`, `componentSkuId` (bare uuids, no FK), `qty` bigint milli; unique `(tenantId, kitSkuId, componentSkuId)`; indexes `<table>_tenant_id_idx`, `<table>_kit_sku_id_idx`. `orderLines` gains nullable `parentLineId: uuid('parent_line_id')` + `order_lines_parent_line_idx`
- `wms-be/drizzle/0033_kit_compositions.sql` + `meta/_journal.json` + `meta/0033_snapshot.json` -- CREATE TABLE + ADD COLUMN, the 0032 pattern: RLS `kit_compositions_tenant_isolation` and CHECKs (`kit_compositions_qty_positive`, `kit_compositions_no_self` row-local `kit_sku_id <> component_sku_id`) migration-SQL-only; commit the snapshot
- `wms-be/src/modules/catalog/kit.command.ts` (NEW) -- `KitCommand.create/edit/list` mirroring `product.command.ts`: `hashCommandPayload`/`idempotencyKeys` replay, snapshot + in-tx outbox (`catalog.kit_created`/`catalog.kit_edited`), keyset-paged list via `buildPage` with the full `limit+1` batch; create/edit lock kit+component SKU rows `.for('update')` ordered by id, then enforce the composition guards
- `wms-be/src/modules/catalog/catalog.facade.ts` -- `getKitCompositionInTx(tenantId, kitSkuId)` (rows: componentSkuId + qty) — the seam outbound consumes; same tx, no nested `withTenantTransaction`
- `wms-be/src/modules/catalog/catalog.dto.ts` + `catalog.controller.ts` -- `CreateKitDto`/`PutKitDto`/`KitResponse`/`KitListResponse`; routes `POST/PUT /tenants/:t/catalog/skus/:skuId/kit`, `GET /tenants/:t/catalog/kits`; new error codes `kit-already-composed`, `kit-self-reference`, `kit-component-is-kit`, `kit-component-not-found`, `duplicate-kit-component`, `empty-kit-composition`, `kit-cannot-hold-stock`; openapi re-export
- `wms-be/src/modules/inbound/receiving.command.ts` + `wms-be/src/modules/inventory/inventory.command.ts` -- the two +stock writers refuse a kit SKU (`kit-cannot-hold-stock`) — FR-38's "never independent stock" made real
- `wms-be/src/modules/outbound/order.command.ts` -- `createOrder` phase 1: resolve compositions for kit lines via `getKitCompositionInTx`; phase 3: insert child lines (`parentLineId` set, own reservationId/reservedQty/status from the grants); phase 2: grant components (ownerType 'order', ownerId = child line id), all-or-nothing per kit; `releaseAll` covers child grants; both manual and ingested paths ride this one command
- order snapshot DTO (wherever `OrderSnapshot` lines are declared) -- lines gain `parentLineId`
- No changes: `wave.command.ts`, `pick.command.ts`, `pack.command.ts`, `dispatch.command.ts`, `reservation.service.ts` — they read order lines/holds by id and see only child rows
- `wms-fe/src/lib/api/generated/` -- `bun run api:generate` only; no UI (11-6)
- meta `docs/` -- `docs/design/modules/catalog.md` (kit entity, commands, invariants) + `docs/design/modules/outbound.md` (explosion flow), `API-SURFACE.md`, `docs/repos/wms-be/README.md`, `PENDING.md`

## Tasks & Acceptance

**Execution:**
- [x] `wms-be/drizzle/0033_kit_compositions.sql` + journal + snapshot -- migration -- table, RLS, CHECKs, `parent_line_id`
- [x] `wms-be/src/shared/db/schema.ts` -- declarations -- `kitCompositions` + `orderLines.parentLineId`
- [x] `wms-be/src/modules/catalog/kit.command.ts` (NEW) -- commands -- create/replace/list with replay, locks, guards, events
- [x] `wms-be/src/modules/catalog/catalog.dto.ts` + `catalog.controller.ts` + `catalog.module.ts` + `catalog.facade.ts` -- surface -- routes, DTOs, error codes, `getKitCompositionInTx`
- [x] `wms-be/src/modules/inbound/receiving.command.ts`, `wms-be/src/modules/inventory/inventory.command.ts` -- kit-stock guards -- the never-independent-stock invariant
- [x] `wms-be/src/modules/outbound/order.command.ts` + order snapshot DTO -- explosion -- phase-1 resolve, phase-2 grants, phase-3 child lines
- [x] `wms-be/test/kits.spec.ts` (NEW) -- I/O matrix incl. replay pins, the concurrent mutual-composition probe, raw-SQL CHECK probes
- [x] kit-order e2e suite -- explode, all-or-nothing backorder, mixed order, wave→pick→pack→dispatch on a kit order, cancel releases child holds, accepted-order-immune-to-composition-edit
- [x] `wms-fe/src/lib/api/generated/` -- regen only -- drift guard
- [x] meta `docs/` -- design docs current -- catalog.md, outbound.md, API-SURFACE.md, README, PENDING

**Acceptance Criteria:**
- Given a kit SKU with a composition, when an order is created (manual or ingested) with a line for it, then child component lines exist with `parentLineId`, hold their own reservations, and appear in waves/picklists; the parent line holds nothing.
- Given any component of a kit is short at acceptance, then the kit line and its children are backordered with no holds.
- Given a kit SKU id, when receiving or stock-adjusting it, then 409 `kit-cannot-hold-stock` and nothing is written.
- Given concurrent create of A∋B and B∋A, then exactly one succeeds.

## Implementation Notes

## Spec Change Log

## Review Triage Log

**Round 1 (step-04, design/code review of commit 65c7da2 — two reviewers).** Zero frozen-spec violations; every finding below was triaged and actioned in the same review round.

| # | Source | Severity | Finding | Triage |
|---|--------|----------|---------|--------|
| 1 | defect hunt | **Major** | The over-receipt **approve** arm (`decideOverReceipt`) is a third +stock writer: a pending excess applies as a fresh `grn.received` delta at *decision* time, days after the GRN's own kit check ran — a SKU that became a kit in between would receive independent kit stock. | **Fixed.** The approve arm now runs the same `kit-cannot-hold-stock` guard before the ledger append; the route's 409 arm documents it; the over-receipt row stays pending for a human reject. Pinned by the e2e test "over-receipt approval on a SKU that became a kit after the GRN". |
| 2 | defect hunt | **Major** | A SKU carrying on-hand stock or a live reservation could become a kit — every stock writer then refuses it (GRN, adjust, and no order line can reserve a kit), stranding the stock and its ATP forever with no write-off path. Two doors: direct create, and a race (a GRN that passed its kit check commits stock after a concurrent kit-create commits). | **Fixed, both doors.** `create` now refuses 409 `kit-sku-holds-stock` when the kit SKU has `stock_on_hand > 0` or a live (`held`/`committed`) reservation, decided against the locked kit row. The race is closed by `receiving.loadSkus` taking `.for('update')` in id order — the same sku-row locks the kit command takes — so the GRN serializes against kit-creation and the guard decides against committed state. Two e2e tests pin both arms. |
| 3 | defect hunt | **Major** | The explosion validated milli-expressibility but not the component unit's **declared precision**: a kit in kg with an `each` component could accept 0.5 kg → a 0.5-each child line that `assertRecordableQuantity` refuses at pick time — a permanently unpickable line holding stock until TTL. | **Fixed.** `explodeKitLine` now requires the child milli quantity to satisfy the component's own precision (`child % 10^(3−precision) ≠ 0 → 400`); the check subsumes the old sub-milli remainder test and runs in phase 1, before any grant moves. Pinned: 0.5 kg of a kg-kit-of-each → 400, 2 kg → 201 with a 2-each child. |
| 4 | spec compliance | **Major** | The two guarded routes' 409 `@ApiResponse` arms (GRN submit, stock.adjust) did not name `kit-cannot-hold-stock` — the OpenAPI contract undersold the refusals. | **Fixed.** Both arms now name it; the over-receipt approve route's 409 arm was added too (finding 1); `bun run openapi:export` re-run (the only diff is the four intended arm texts). |
| 5 | both | Minor | `kitSkuIdsInTx` in kit.command.ts duplicated `getKitSkuIdsInTx` in kit.store.ts (the store file's own comment preaches "one implementation"). | **Fixed.** Duplicate deleted; `assertComponentsAreNotKits` imports the store's function. |
| 6 | spec compliance | Minor | `empty-kit-composition` was a dead arm at the HTTP edge: `PutKitDto`'s `@ArrayMinSize(1)` ate the empty array with a generic validation-failed before the command's named 400 could answer. | **Fixed.** The DTO validator removed (with a comment saying why); create and PUT with an empty array now answer the named 400 `empty-kit-composition`; both pinned. |
| 7 | spec compliance | Minor | `test/architecture.spec.ts`'s catalog write-guard did not list `kitCompositions` — a forged kit-ness write outside catalog would have walked through a guard whose name says it cannot. | **Fixed.** `kitCompositions`/`kit_compositions` added to the Drizzle + raw-SQL table lists. |
| 8 | spec compliance | Minor | Code Map naming drift: it names `CreateKitDto`/`PutKitDto` and method `edit`, but the shipped surface shares one body DTO (`PutKitDto`, also on the POST route) and the method is `put`. | **Recorded, no code change.** One body DTO for both routes is intentional (identical shape); renaming the OpenAPI schema or adding an alias would churn the contract for no behavioral gain. The Code Map text stays as written (historical intent); the shipped names are PutKitDto/`put`. |
| 9 | spec compliance | Minor | **FROZEN-spec sentence flagged, not self-fixed:** "child line qty = kit line qty (milli, base) × per-kit component qty (milli)" is wrong as written — the code (and Design Notes below) divides by the milli scale (1000) to land on the component's milli-units. The frozen block is human-owned; flagged for renegotiation, not edited here. | **Flagged to the human.** Code and tests implement the correct arithmetic (× per-kit qty ÷ 1000). |
| 10 | spec compliance | Nit | `decodeCursorSafe` re-implements the sku.list cursor validation; receiving's kit guard mixes facade (`this.catalog`) and store-level access; `list` slices manually instead of `buildPage().items`. | **Declined.** Each is a 2-line locality trade already consistent with its neighbors; not worth the churn in this story. |
| 11 | defect hunt | Doc | `outbound.md`'s "reservation_id null on a fully-backordered line" sentence does not anticipate kit parent lines (open or backordered, `reservation_id` always null). | **Deferred to the meta docs PR** (step-05): outbound.md gets the explosion flow + the kit-parent reading; catalog.md gets the kit entity + the `assertComponentsAreNotKits` components-only gotcha. |

**New error code this round:** `kit-sku-holds-stock` (409, kit create only) — a kit must never be created ON stock; it is the create-side twin of `kit-cannot-hold-stock`. Contract arms updated accordingly.

**Verification after the patches:** 686/686 jest (38 suites, 4 new pins), `tsc --noEmit` clean, `eslint .` clean, `openapi:export` diff limited to the four intended arm texts.

## Design Notes

- **Kit-ness = presence of composition rows, not a flag.** A `skus.is_kit` boolean is a second source of truth that can drift from the rows; the 11-3 relational-identity precedent (variant identity is `product_id`+`variant_values`, never a flag) applies. Every "is this a kit" check is one indexed lookup on `kit_compositions`.
- **Why child order lines, not an order_line_components table:** `order_lines.reservationId`/`reservedQty` are single-hold single-SKU, and waves/picklists/picks/pack/dispatch all read order lines. A parallel components table would need every downstream reader to learn kit-awareness; child lines make the existing machinery work unchanged (the wave `planSlices` precedent already expands one line into N rows).
- **The cycle race is real and locked:** two concurrent creates (A∋B, B∋A) both see the other component as not-yet-a-kit under read committed. `.for('update')` on both SKU rows in id order serializes them; the loser re-reads committed state and refuses with `kit-component-is-kit`.
- **Kit UoM:** 1 kit = 1 base-UoM unit of the kit SKU. The kit's own `uom_conversions` play no part in explosion; component quantities are milli-units of each component's base UoM. (`'bundle'` in the UoM vocabulary is an unrelated unit name — do not conflate.)
- **Pack needs no changes:** completeness is picklist-line-status based and verification compares picked vs scanned **per SKU** — a kit parent line contributes no picklist rows or picks, and the bench scans components. Verified in `pack.command.ts:342-410,732-770`.
- **Implementation findings (caught by `test/kits.spec.ts`, both fixed in the same commit):**
  - `assertComponentsAreNotKits` probed `componentById.keys()`, which carries the KIT SKU alongside the components — on PUT the kit is by definition already a kit, so every edit 409'd `kit-component-is-kit`. The guard now probes only the command's component ids.
  - `reserveLine` grants `min(qty, ATP)` (the plain line's partial grant), but the kit loop treated only a `null` (zero ATP) as a shortfall — a component with partial ATP (5 of 30) returned a hold and the kit was accepted HALF-HELD, violating the frozen all-or-nothing decision. The loop now compares the granted quantity against the component's full exploded quantity, and pushes the hold before the shortfall check so a partial hold releases with its siblings instead of orphaning.

## Verification

**Commands:**
- `wms-be`: `bun run db:migrate && bun run db:verify` -- expected: migrations apply, round-trip green
- `wms-be`: `npx jest` -- expected: all suites green incl. the new kits suite and kit-order e2e
- `wms-be`: `npx tsc --noEmit && npx eslint .` -- expected: clean
- `wms-be`: `bun run openapi:export && git diff --exit-code openapi/` -- expected: only intended contract additions
- `wms-fe`: `bun run api:generate && git diff --exit-code src/lib/api/generated && bun run test && bun run typecheck && bun run lint && bun run build` -- expected: green

**Manual checks (if no CLI):**
- None beyond the CLI — no FE surface in this story.