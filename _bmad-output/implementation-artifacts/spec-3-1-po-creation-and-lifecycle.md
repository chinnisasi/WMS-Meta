---
title: 'Story 3.1: PO creation and lifecycle'
type: 'feature'
created: '2026-09-09'
status: 'done'
baseline_commit: 'd75f45f150f2d849c23bf1b5a247f8eca73d6303' # wms-be HEAD
route: 'dispatch'
review_loop_iteration: 0
context:
  - '_bmad-output/implementation-artifacts/epic-3-context.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** Receiving (story 3.3) has no basis — there is no purchase-order entity, no vendor, and no ordered/received/open quantity tracking anywhere in wms-be; the `inbound` module is an empty stub.

**Approach:** Build the PO lifecycle in the `inbound` module, backend-only per the Epic 2 precedent: a `vendors` entity, `purchase_orders` + `purchase_order_lines` tables (migration 0011), command services (create / amend / close) following the established command pattern (role re-eval → idempotency → asserts → write → outbox), additive HTTP surfaces (vendor create/list, PO create/amend/close/list/detail), and keyset-paginated reads that expose ordered / received-to-date / open per line at all times. No ledger events and no GRN/receipt path — this story is pure upstream; receipts arrive in 3.3 and fill `receivedQty` (which ships defaulting to 0).

## Boundaries & Constraints

**Always:**
- Follow the established command invariant order inside `withTenantTransaction`: `assertPermission` (fresh DB role read) → idempotency replay lookup → master-data asserts → write → in-tx outbox append → idempotency-key insert with payload hash + response snapshot (replay returns the stored snapshot with `replayed: true`; hash mismatch → 422 `idempotency-key-reuse`; concurrent insert → 409 `conflict`).
- New capability strings in `permissions.ts` gate every PO/vendor mutation; owner and ops_manager hold them, operator/accountant do not.
- Quantities are positive integers in base UoM; money (`cost`) is paise integers via the `Paise` primitive (AD-9). All timestamps UTC; IDs UUIDv7. Vendors are a real entity: `vendors` table (unique per-tenant code, name, `is_default` flag) with create + list surfaces — Epic 6's suggested-PO drafts will read default vendors (human decision 2026-09-09).
- POs are warehouse-scoped: `warehouseId` required, validated with `assertWarehouseInTenant` (404) — receiving and open-quantity tracking are per-warehouse, and this avoids a later re-scoping migration.
- PO code is client-supplied, unique per tenant (409 on duplicate, naming the conflicting code) — mirrors the catalog SKU-code convention.
- PO line always exposes `orderedQty`, `receivedQty` (0 until 3.3 receipts land), and `openQty = orderedQty − receivedQty` (≥ 0, CHECK-enforced once receipts exist).
- Amend is permitted only while PO status is `open`. Close takes a per-line disposition (`cancelled` or `carried`); received quantities are never touched by close. **Carried = successor PO (human decision 2026-09-09):** the close command auto-creates one successor open PO (same vendor/warehouse, unique code derived from the original, `carriedFromPoId` reference) holding the carried open quantities; original lines are marked `cancelled`/`carried` and the closed PO stays queryable with its dispositions.
- Every state change appends an in-tx outbox event (`vendor.created`, `po.created`, `po.amended`, `po.closed`); no ledger writes.
- RLS fail-closed tenant-isolation policy + status/non-negative CHECKs are hand-appended to the migration SQL (the 0005→0010 pattern), never declared in schema.ts.
- Retro A3 rides this story (it is the next backend story): consolidate the six file-local `UUID_RE` copies onto one shared constant and apply one guard mechanism to the new inbound routes' uuid path params (400, not 500).

**Never:**
- No GRN, receipt, over-receipt, QC-hold, or putaway logic (stories 3.3–3.5).
- No ledger event types, no `LedgerService` changes, no stock-table writes (the architecture test pins the single-projection owner; a PO is not stock).
- No FE work: wms-fe stays untouched (Epic 2 precedent — HTTP surface additive only; the Inbound web page is a later story; FE re-runs `api:generate` after merge).
- No received-quantity write path, no receiving-side guard on PO state beyond the 3.1 close rule.
- No wave/picklist, no Epic 4 order machinery, no approval workflow (over-receipt approval is 3.3's).

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Create PO | Ops Manager, idempotency key, code unique in tenant, ≥1 line with known SKU | 201 PO `{status: 'open', lines[]}` with ordered/received/open per line; `po.created` outbox row | Unknown vendor/SKU/warehouse → 404 `not-found`; duplicate code → 409 `conflict` naming code; non-positive qty/cost → 400 `validation-failed` |
| Amend open PO | Change line qty/cost/expected date, add/remove lines | 200 updated PO; `po.amended` outbox row; open recomputed | Status ≠ open → 409 `po-not-open` naming status; unknown line id → 404 |
| Close PO | Per-line disposition `cancelled` or `carried`; ≥1 carried line → auto-created successor open PO (`carriedFromPoId`, derived unique code) | 200 closed PO + successor PO; `po.closed` outbox; original lines show dispositions, successor holds carried quantities | Already closed → 409 `po-not-open` (idempotent replay re-serves snapshot); unknown PO → 404 |
| Receipt against closed PO (contract surface only) | Detail read of closed PO | Line shows `openQty` after disposition (cancelled → 0, carried → visible on the successor PO); status `closed` | (3.3 will reject receiving naming PO state — this story only guarantees the state + quantities are queryable) |
| Replay any mutation | Same idempotency key + same payload | Stored response snapshot, `replayed: true`, no second outbox row | Role no longer authorizes → 403 `role-denied` before replay (fail-closed carve-out) |
| List/detail reads | Keyset cursor, optional status filter | Paginated POs / one PO with lines; opaque cursor | Malformed cursor → 400 `invalid-cursor` (`decodeCursorSafe`; amended from `validation-failed` per human decision 2026-09-09 — the repo-wide read pattern's code); non-uuid path param → 400 |

</frozen-after-approval>

## Code Map

- `src/modules/inbound/inbound.module.ts` -- empty stub; becomes the module (providers: vendor + PO commands, `InboundFacade`; exports facade only, matching `inventory.module.ts`).
- `src/shared/db/schema.ts` -- single-file schema (884 lines); add `vendors`, `purchaseOrders`, `purchaseOrderLines` following table conventions (uuidv7 id, tenantId, createdAt/updatedAt, `(created_at, id)` keyset index, per-tenant unique indexes, no FKs — integrity asserted in-command). Latest migration is `drizzle/0010_sharp_hardball.sql` → this story generates 0011 and hand-appends RLS policy + CHECKs.
- `src/modules/tenancy/permissions.ts` -- `CAPABILITIES` tuple + `ROLE_CAPABILITIES` map; add PO/vendor capabilities (owner/ops_manager only).
- `src/modules/tenancy/zone.command.ts` -- the simplest full command exemplar: withTenantTransaction order, `assertPermission`, idempotency trio (`hashCommandPayload` / `idempotencyKeyReuse` / `parseRequiredIdempotencyKey`), `OUTBOX_SINK.append`, `isUniqueViolationOn`.
- `src/modules/tenancy/idempotency-guard.ts` -- `hashCommandPayload` (fixed key order is load-bearing), `parseRequiredIdempotencyKey`; reuse, don't copy.
- `src/modules/tenancy/tenancy.service.ts` -- `requireActiveWarehouse` (422 `no-active-warehouse`), `assertWarehouseInTenant` (module-level fn, 404), `getMemberRoleIn`; also `decodeCursorSafe` (line ~410) — the pattern the inbound list read copies.
- `src/modules/inventory/inventory.facade.ts` -- read-facade exemplar (keyset list via `buildPage` + `decodeCursorSafe`, existence checks before detail queries → 404); mirror its shape for `InboundFacade.listPurchaseOrders`/`getPurchaseOrder`.
- `src/api/inventory.controller.ts` -- controller-in-shell exemplar (DTOs stay in module; `assertOwnTenant` per file; `@CurrentSession()` + `TenantSessionGuard`; problem-details errors); mirror for `src/api/inbound.controller.ts`.
- `src/api/api.module.ts` -- registers controllers; add InboundController here (module stubs register none).
- `src/shared/problem-details/problem.exception.ts` -- `ProblemException(code, status, title, detail)` + `httpCodeToProblemCode`; all new error codes go through this.
- `src/shared/primitives/money.ts` -- `Paise` branded integer; unused so far — first consumer.
- `src/shared/primitives/pagination.ts` -- `encodeCursor`/`decodeCursor`/`buildPage`; `src/shared/primitives/ids.ts` -- `isUuid`/uuidv7; A3's shared `UUID_RE` lands next to these.
- `src/shared/events/outbox.ts` + `outbox.seam.ts` -- `OUTBOX_SINK.append(tx, …)`; event-type strings are inline literals per command (no registry to extend for outbox).
- `src/api/export-openapi.ts` + `openapi/openapi.json` -- `bun run openapi:export`; CI drift-guards the diff.
- `test/tenancy.spec.ts` (beforeAll/afterAll), `test/inventory-surfaces.spec.ts` -- the e2e suite template: deployment-parity bootstrap block (BYPAASSRLS probe role under advisory lock 742105), supertest against real app, problem+json assertions, child-before-parent cleanup. New: `test/inbound.spec.ts` (same shape; no new advisory lock keys needed).
- `test/architecture.spec.ts` -- boundary scanner: sibling modules may import only `inventory.facade|inventory.module|inventory.dto`; inbound must not touch ledger internals.
- `.github/workflows/ci.yml` -- three jobs (lint-and-test, migrations+db:verify, openapi drift); nothing to change, everything must pass.

## Tasks & Acceptance

**Execution:**
- [x] `src/shared/db/schema.ts` + `drizzle/0011_*.sql` -- add `vendors` (unique `(tenant, code)`, name, `is_default`), `purchase_orders` (unique `(tenant, code)`, vendor_id, warehouse_id, status text default 'open'), `purchase_order_lines` (po_id, sku_id, ordered_qty, received_qty default 0, unit_cost_paise, expected_date, line status default 'open'); `bun run db:generate`, hand-append tenant-isolation RLS + status/non-negative CHECKs per the 0010 pattern
- [x] `src/modules/tenancy/permissions.ts` -- add `po.manage` + `vendor.manage` capabilities to owner/ops_manager
- [x] `src/modules/inbound/vendors.command.ts` + `src/modules/inbound/po.command.ts` -- create/amend/close commands in the zone.command invariant order; outbox events in-tx
- [x] `src/modules/inbound/inbound.facade.ts` + `inbound.dto.ts` -- keyset list (status filter), PO detail with per-line ordered/received/open; DTOs with class-validator
- [x] `src/api/inbound.controller.ts` + `src/api/api.module.ts` -- vendor create/list, PO create/amend/close/list/detail routes with `@ApiBearerAuth`, `assertOwnTenant`, documented problem+json failure surface in OpenAPI (the 2-4 deferral lesson)
- [x] `src/shared/primitives/ids.ts` + 6 consumer files -- export shared `UUID_RE`, replace the file-local copies (retro A3); inbound routes validate uuid path params → 400
- [x] `test/inbound.spec.ts` -- full I/O matrix: create/amend/close happy paths, every error arm, replay behavior, keyset paging, RLS cross-tenant probe
- [x] `openapi/openapi.json` via `bun run openapi:export` -- additive contract for wms-fe

**Acceptance Criteria:**
- Given a tenant with vendor + SKUs, when an Ops Manager creates a PO with two lines, then GET detail shows each line's ordered / received-to-date (0) / open quantities and the PO appears in the keyset list with a working cursor
- Given an open PO, when a line is amended and another added, then ordered/open recompute and `receivedQty` is untouched
- Given a PO with one line cancelled and one carried at close, then a successor open PO is created holding the carried quantity (`carriedFromPoId` set, derived unique code), the original lines show their dispositions, the closed PO's quantities remain queryable exactly as at close, and any later mutation (amend/re-close/receive-basis use) against the original is rejected naming the PO state
- Given the same create request replayed with the same idempotency key, then the stored snapshot returns with no second outbox row; with a different payload → 422; with a demoted actor role → 403 before replay
- Given a cross-tenant session, then PO/vendor reads and writes fail (RLS + tenant asserts verified by test)

## Implementation Notes

<!-- Append-only during implementation. -->

- Implemented on `wms-be` (baseline `d75f45f`): migration `drizzle/0011_tiresome_wraith.sql` (three tables + hand-appended RLS/CHECKs, `received_qty <= ordered_qty` deliberately deferred to 3.3 per the over-receipt-approval decision), `src/shared/db/schema.ts` (table declarations, indexes only — no RLS/policy/CHECK), `src/shared/primitives/ids.ts` (shared `UUID_RE`, retro A3), `src/modules/tenancy/permissions.ts` (`vendor.manage` + `po.manage`, owner/ops_manager), and the new `src/modules/inbound/` module (`inbound.dto.ts`, `vendors.command.ts`, `po.command.ts`, `inbound.facade.ts`, `inbound.module.ts`) wired through `src/api/inbound.controller.ts` + `src/api/api.module.ts`.
- Retro A3 applied: the six file-local `UUID_RE` copies (`inventory.controller`, `tenancy.service`, `users.command`, `sku.command`, `inventory.facade`, `reservation.service`) now import the one shared constant from `src/shared/primitives/ids.ts`; zero local copies remain.
- Amend is full-line-set semantics: lines with an `id` update in place, lines without one are added, lines absent from the request are removed; `received_qty` is never in the update set. Mutation paths lock the PO row `FOR UPDATE` (concurrent amend/close serialize; the loser sees `po-not-open`).
- Close is total (one disposition per line: duplicate → 400, unknown → 404, missing → 400); `carried` moves `ordered − received` to ONE successor open PO (same vendor/warehouse, code `${original}-C{n}` first free n, `carriedFromPoId` set) with `received_qty` restarting at 0. A carried line with nothing left (unreachable via the 3.1 API since received ships at 0 — tested by seeding `received_qty = ordered_qty` directly) is 400 `validation-failed`.
- Duplicate PO/vendor code surfaces as 409 `conflict` naming the code (per the I/O matrix, not a bespoke code); a non-uuid `poId` path param is 400 `validation-failed` (inbound rule, overriding the inventory detail 404 precedent).
- Known gaps, deliberate: snapshot records still say `isRLSEnabled: false` for the three new tables (pre-existing drizzle-introspection gap); the manual real-HTTP smoke of the Verification section was covered by the supertest suite instead (same HTTP surface); FE api re-generation is a later story (no FE work in 3.1).

## Spec Change Log

<!-- Append-only; populated by step-04. -->

## Review Triage Log

<!-- Append-only; populated by step-04. -->

| # | Source | Finding | Verdict | Evidence | Route |
|---|--------|---------|---------|----------|-------|
| 1 | blind | `warehouseId` path param on the PO-list route is not uuid-guarded → non-uuid reaches the `::uuid` comparison as a 500, not a 400 | **medium** | Confirmed: `assertUuidParam` guards only `poId` (`inbound.controller.ts:329`); frozen intent requires 400 on *all* new inbound uuid path params | patch |
| 2 | edge | Amend accepts `lines: []` → PO stripped to zero lines, breaking the ≥1-line invariant create enforces | **medium** | Confirmed: `AmendPurchaseOrderDto` has `@ArrayMaxSize(200)` but no `@ArrayMinSize(1)`; no command-side length guard | patch |
| 3 | edge | Duplicate line ids in an amend request apply last-wins silently; close rejects duplicates, amend doesn't | **low** | Confirmed: amend loops updates per entry with no duplicate check (`po.command.ts:300`) | patch |
| 4 | blind | `updatedAt` never advances on amend/close — list/detail expose a stale instant | **medium** | Confirmed: `tenantTimestamps` has no `$onUpdate`; amend touches only lines, close's update sets `status` only | patch |
| 5 | blind | Cursor instant regex accepts impossible calendar values (e.g. month 99) → `::timestamptz` cast → 500 | **medium** | Confirmed: `CURSOR_INSTANT_RE` is shape-only; the repo pattern (`tenancy.service.ts` `decodeCursorSafe`) additionally `Date.parse`-checks and would 400 | patch |
| 6 | blind | Successor-PO insert unique violation escapes as 500 on a concurrent close race (two distinct originals sharing a 60-char truncated base) | **low** | Confirmed: same-original closes serialize via `FOR UPDATE`; only the cross-original race reaches the bare insert — narrow but a 500 | patch |
| 7 | blind | PO-list read lacks a warehouse-prefixed index — filters tenant+warehouse over a `(tenant_id, created_at, id)` index | **low** | Confirmed in `0011` DDL; 0011 is uncommitted so the fix is a direct DDL addition | patch |
| 8 | v-gap | The five 0011 CHECK constraints have no deployment probe (cf. `batch-serial.spec.ts:758` pattern) | **medium** | Pre-verified by the verification-gap layer | patch |
| 9 | v-gap | Vendor-create and PO-close idempotent replay arms untested (create/close never re-sent with the same key) | **medium** | Pre-verified by the verification-gap layer | patch |
| 10 | v-gap | `vendor.created` and `po.closed` outbox rows/payloads never asserted (only `po.created`/`po.amended` are) | **medium** | Pre-verified by the verification-gap layer | patch |
| 11 | edge | Omitting `expectedDate` on an amend-update clears it silently | **false** | Documented full-line-set semantics ("The complete new line set", dto + Implementation Notes) — omitted means null | reject |
| 12 | blind | Create accepts and discards per-line `id`s | **low** | Confirmed (shared line DTO), but unlikely in everyday use (ids mean "update"; docs say "amend only") and the fix adds a second DTO class — more than a direct correction | reject |
| 13 | edge | Multiple `is_default` vendors possible | **false** | The human decision requires only the flag; spec reads "default vendor**s**" (plural) — single-default exclusivity is Epic 6's call | reject |
| 14 | blind | OpenAPI pins `openQty minimum: 0`, which 3.3 over-receipt may need to relax — additive-only contract makes that a breaking change | **low** | Real tension, but 3.3's problem and not fixable without deciding over-receipt semantics now | defer |
| 15 | blind | `decodeCursorSafe`/`canonicalInstant` now duplicated in 4th/5th places | **low** | True, but the fix is a shared-primitive refactor across modules — consolidation debt, not a direct correction (A3-style item) | defer |
| 16 | v-gap | `vendor.manage`/`po.manage` widen the unguarded wms-fe capability mirror | **medium** | Matches open retro item A12 (epic-1 item 4); the fix edits agent-context files — deferred there | defer |
| 17 | blind | No meta-repo docs/contract update in the diff | **false** | By design — CLAUDE.md: code ships first, meta docs land after merge | reject |
| 18 | blind | Idempotency keys are not operation-scoped | **false** | Repo-wide pattern: tenant-scoped keys + payload-hash mismatch → 422; consistent with every existing command | reject |
| 19 | blind | Close writes no `audit_events` | **false** | The repo's record of state change is the outbox (`po.closed` carries the full snapshot); no `audit_events` consumer exists | reject |
| 20 | blind | `deriveSuccessorCode` 60-char truncation can collide across distinct originals | **false** | First-free `-C{n}` search resolves collisions; exhaustion after 99 falls back to 409, not a 500 | reject |

**Routing summary:** No intent_gap / bad_spec entries — the frozen intent held; all surviving defects are implementation misses. Seven patch entries (1–7 auto-fixed by the reviewer; 8–10 filed pre-verified), three defers (14, 15, 16 → `deferred-work.md`), seven rejects. The implementation subagent was no longer continuable, so patches were applied directly.

## Design Notes

- Status lifecycle is deliberately two-valued (`open` → `closed`) with close as an explicit command: amend-before-receipt and rejected-receipt-after-close are the only states 3.3 needs; a `draft` state would add a transition nothing consumes. Status lives as text + hand-appended CHECK (repo convention, no pgEnum).
- `receivedQty` is a stored column on `po_lines` (default 0), updated transactionally by 3.3's GRN commands — not derived from the ledger. Receipts in 3.3 will carry the PO/line as `referenceDoc`, giving the ≤2-navigations path from PO → ledger events; 3.1 ships the column and the read path only.
- Outbox event payloads carry the full post-mutation PO/line snapshot (like `zone.created`), so the FE and later stories never need a read-after-write.
- Unit cost is per-line (`unit_cost_paise`), not per-PO: FR-26 invoices price from dispatched qty × rate later, and PO lines are the natural price carrier.

## Verification

**Commands:**
- `bun run test` (from `workspace/core/backend/wms-be`) -- expected: all suites green incl. new `test/inbound.spec.ts`
- `bun run lint && bun run typecheck && bun run build` -- expected: clean
- `bun run db:migrate && bun run db:verify` -- expected: 0011 applies; round-trip row check passes
- `bun run openapi:export` -- expected: diff contains only additive inbound paths/schemas; CI drift job passes

**Manual checks:**
- Real-HTTP smoke (the step-05 ritual): boot `bun run dev`, mint a session JWT, create vendor → PO → amend → close; assert the problem+json error arms for duplicate code and closed-PO mutation.