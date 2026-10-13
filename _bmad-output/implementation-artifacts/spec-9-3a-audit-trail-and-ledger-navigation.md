---
title: 'Audit trail — every state change attributable and filterable by the Owner, and every ledger event two navigations from its document'
type: 'feature'
created: '2026-10-12'
status: 'done'
route: 'dispatch'
review_loop_iteration: 0
context:
  - '_bmad-output/implementation-artifacts/epic-9-context.md'
  - '_bmad-output/implementation-artifacts/spec-9-1b-dashboard-click-through.md'
  - 'docs/design/SYSTEM-DESIGN.md'
  - 'docs/design/IMPLEMENTATION-GUIDE.md'
  - 'docs/design/API-SURFACE.md'
  - 'docs/design/modules/reporting.md'
  - 'docs/design/modules/inventory.md'
  - 'docs/design/modules/tenancy.md'
  - 'docs/design/modules/movements.md'
  - 'docs/design/frontend/SYSTEM-DESIGN.md'
  - 'docs/design/frontend/IMPLEMENTATION-GUIDE.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** FR-28 has two requirements. Neither is met today.
- **The Owner sees every state-changing action**, with who, what, when and the reference document, and can filter them. Today `audit_events` has no read path, and about 20 mutating commands never write an audit row.
- **Every ledger event is reachable from its reference document in two navigations or fewer.** Today the ledger list cannot filter by GRN, PO, transfer, adjustment or count, and no document links to its events.

**Approach:**
- **Backend:**
  - fill the audit gaps, going forward only;
  - add an owner-only, cursor-paged audit read in reporting;
  - add document filters to the ledger events list;
  - record the resulting ledger event on adjustment approvals and count resolutions, so their documents can link.
- **Web:**
  - an Audit section on `/reports`;
  - "View ledger" links from each document surface that exists, landing on `/inventory/ledger` filtered to that document.

**Decisions (human, 2026-10-12):**
1. **The split.** 9-3 is split four ways. This story is the trail plus ≤2-navigation. The rest:
   - 9-3b: async export;
   - 9-3c: anchoring and chain alerts;
   - 9-3d: the retention lifecycle, deferred infrastructure.
2. **Where the audit read lives.** It is reporting's **third read-only exception** (IMPLEMENTATION-GUIDE §7a): it reads `audit_events` only, writes nothing, owns no table, and has its own guard block.
3. **Who sees it.** Owner only, through a new capability `audit.view`.
4. **The gaps.** Every keyed mutating command gets its audit row, going forward only.

## Boundaries & Constraints

**Always:**

- **The audit rule.** Every committed, non-replay execution of a command that writes `idempotency_keys` also writes at least one `audit_events` row in the same transaction, at step 10 of the skeleton. That row carries `reference` = the idempotency key.
  - New rows set `occurred_at` from the server (`nowIso()`).
  - The actor is the requesting user. The exceptions are in the table below.
  - Existing action strings are not renamed.
- **New audit rows**, one table (`AUDIT_NEW_ACTIONS`), each pinned by an assertion in its existing suite. Each assertion checks:
  - one row with the right action, target and actor;
  - no row on replay.

| Command (file:line) | Action | Target type → id | Actor |
|---|---|---|---|
| transfer create / confirm outbound / confirm inbound / cancel (`transfer.command.ts:429,779,1171,1577`) | `transfer.created` / `transfer.outbound_confirmed` / `transfer.inbound_confirmed` / `transfer.cancelled` | `transfer_order` → transfer | requester |
| PO create, incl. `createInTx` (`po.command.ts:193,225`) | `purchase_order.created` | `purchase_order` | requester (the replenishment submit's user, not the system; that submit then writes two rows) |
| PO amend / close (`:315,482`) | `purchase_order.amended` / `purchase_order.closed` | `purchase_order` | requester |
| vendor create (`vendors.command.ts:57`) | `vendor.created` | `vendor` | requester |
| SKU edit (`sku.command.ts:304`) | `sku.edited` | `sku` | requester |
| product create / edit (`product.command.ts:84,188`) | `product.created` / `product.edited` | `product` | requester |
| kit create / put (`kit.command.ts:110,177`) | `kit.created` / `kit.components_replaced` | `kit` | requester |
| catalog import execute (`import.command.ts:266`) | `catalog_import.executed` | `catalog_import` → the import row | requester |
| warehouse create (`warehouse.command.ts:76`) | `warehouse.created` | `warehouse` | requester |
| zone create (`zone.command.ts:56`) | `zone.created` | `zone` | requester |
| bin create / generate grid (`bin.command.ts:290,400`) | `bin.created` / `bin.grid_generated` | `bin` / `zone` → the zone gridded | requester |
| registration (`registration.command.ts:73`) | `tenant.registered` | `tenant` → the new tenant | the new owner |
| GRN submit (`receiving.command.ts:334`) | `goods_receipt.submitted` | `goods_receipt` | requester (on a replayed handheld op: the original operator) |
| count create / submit (`count.command.ts:417,656`) | `count.created` / `count.submitted` | `count_task` | requester (a submit applied from a rejected op: the original operator; `occurred_at` stays server time) |
| count-policy upsert (`:1496`) | `count_policy.updated` | `warehouse` → the policy's warehouse | requester |
| device enroll (`enrollment.command.ts:341`) | `device.enrolled` | `device` | the user who minted the code, read from that device's `device.enrollment_code_minted` row |

- **The guard has two layers.**
  - **Dynamic.** A test helper, `assertEveryKeyAudited(db)`, fails when any `idempotency_keys` row lacks an `audit_events` row with the same `(tenant_id, reference)`. The only exemptions are named endpoints, starting with `selfTestEcho`. The helper runs from the shared test teardown when one exists, and otherwise from every suite that drives mutating commands.
  - **Static.** A scan of **all** `src/modules/**/*.ts` fails on any file that writes `idempotencyKeys` but never references `auditEvents`. This catches `invoicing/command.ts` and `billing/client-invoices.ts`, which the dynamic layer may not exercise.
  - **Scope:** the rule covers keyed commands only. Unkeyed system writers are out of scope: sweeps, schedulers, sign-in, badge-in and push registration. The docs say so.
- **`AUDIT_TARGET_TYPES` is the vocabulary.** It holds every literal `targetType` written anywhere in `src`, including the new ones above. A static test pins it, the way §4 pins a vocabulary.
  - It is published as the `targetType` query enum in `openapi.json`, so the web select is generated, not hand-copied.
  - The dynamic writers (`pick.command.ts:1399`, `eway.command.ts:744`) are covered by listing their possible values.
- **The read route:** `GET /tenants/{t}/reporting/audit`. The segment is `reporting`, as in the existing two routes.
  - **Access:** `TenantSessionGuard` (client portal fenced) and `assertOwnTenantToken`, then a facade guard. That guard runs in its own transaction, on the `channels.facade.ts:159-174` pattern: `getMemberRoleIn` followed by `assertPermission(role, 'audit.view')`, which fails with 403 `role-denied`. The role read sits outside the audit read model, so the read model itself touches `audit_events` only.
  - **Filters** (all optional, combined with AND):
    - `actorUserId` (uuid);
    - `actionPrefix` (`^[a-z][a-z_.-]{0,63}$`), matched with `LIKE $p || '%' ESCAPE '\'` after escaping `\`, `_` and `%`;
    - `targetType` (the enum);
    - `targetId` (uuid);
    - `from`/`to` (instants).
  - **Ordering, paging and windows** all use **`created_at`**, the server commit stamp, never `occurred_at`. Some writers stamp `occurred_at` from command or device time: putaway, sync resolve, excursion.
    - Windows are half-open (§7a).
    - The cursor is `{createdAt: created_at::text, id}` (`inventory.facade.ts:487` precedent). The order is `created_at DESC, id DESC`.
    - `limit` defaults to 50, max 200.
  - **Rows:** `{id, recordedAt (created_at), occurredAt, actorUserId, actorKind: 'user'|'system', action, targetType, targetId}`. `reference` is not returned.
    - `actorKind` is `'system'` when the actor is `SYSTEM_ACTOR_ID`. That constant moves to `shared/` (re-export kept), so the web never hard-codes it.
  - **Statement timeout:** 5 s, after which the route answers 503 `report-unavailable` (the 21-8 pattern). The 503 is the expected answer for a broad filter over a very large history.
- **The third-exception guard** (in `architecture.spec.ts`). The audit read file must:
  - import only `auditEvents` from the schema;
  - name only `audit_events` in raw SQL;
  - contain no `join`.

  The new facade method must not appear in `PORTAL_READS` or the portal delegation list. Update the comment at `permissions.ts:4-8`.
- **Ledger document filters** on `GET …/warehouses/{w}/inventory/events`:
  - **The keys:** `grnId`, `poId`, `transferId`, `adjustmentPendingId` and `countVarianceId`, all uuids.
  - **Matching:** `reference_doc ->> '<key>' = lower($id)`, the same as `orderId`. Each key is served by a partial btree expression index `ON ledger_events (tenant_id, warehouse_id, (reference_doc ->> '<key>')) WHERE reference_doc ? '<key>'`, following migration 0039.
  - **What each key matches:** `grnId` matches both receipt and putaway events. `poId` matches receipt events only, because putaways don't carry `poId`; the PO link says "receipts".
- **New reference-doc keys:** `manual-adjustment` gains `adjustmentPendingId?` (set by approval) and `countVarianceId?` (set by count resolution).
  - **Hashing:** an absent key is omitted, never `null`, so old events keep their bytes. The rule is pinned by a test.
  - **Validation:** only the TypeScript union changes; there are no per-key validators.
  - **Byte identity:** the approval's "byte-identical to the immediate path" invariant deliberately no longer holds. Update the comments at `adjustment-approval.command.ts:476-478` and `inventory.command.ts:1139-1141`. `fingerprint` is unaffected.
- **Linking documents to events.** Two nullable columns record the posted event: `stock_adjustment_pendings.ledger_event_id` (set on approve) and `count_variances.ledger_event_id` (set on `adjusted`).
  - The DTOs expose `ledgerLinked: boolean`, which is true only when the column is set.
  - Rejected adjustments, recounted variances and anything decided before 9-3a stay `false`, and show no link.
- **Migration 0069 (§3 checklist; no CHECK to probe, so say so).** It adds:
  - the five partial ledger indexes;
  - audit indexes `(tenant_id, created_at DESC, id DESC)`, `(tenant_id, actor_user_id, created_at DESC)`, `(tenant_id, target_type, target_id)` and `(tenant_id, action text_pattern_ops, created_at DESC)`;
  - the two `ledger_event_id` columns.

  It drops the superseded `audit_events_tenant_id_occurred_at_idx`, which nothing will read. Index builds lock writes on `ledger_events` for their duration, because the migrator runs everything in one transaction, so `CONCURRENTLY` is impossible. The deploy note states this, with the current table size.
- **The web: the Audit section.** It sits after Client service on `/reports` and renders only with `audit.view`, which is added to the mirror the way existing owner-only capabilities are (`OWNER_ONLY_CAPABILITIES` and `OPS_EXCLUDED_CAPABILITIES`, `lib/users.ts:103,166`). It uses the shared `DataTable`.
  - **Columns:**
    - Recorded (IST), plus "happened HH:MM" when `occurredAt` differs by more than a minute;
    - Who: the email from `useUserMap`; "System" for `actorKind: 'system'`; a short id if the user is unknown;
    - Action;
    - Target: type plus short id, as plain text, with no links.
  - **Filters** are component state and are lost on reload:
    - actor: the members list plus "System". The list is capped at 1,000 members by `fetchAllPages`; when the list fails to load, an error shows;
    - action prefix;
    - target type: the generated enum;
    - from/to IST dates: `from = d + 'T00:00:00+05:30'`, `to = (d+1) + 'T00:00:00+05:30'`. The client refuses `from > to`.
  - **Paging.** The cursor is scoped to the filter tuple, and the table is keyed on it, so a filter change starts at page 1 (the `useQcHolds` pattern).
  - **Errors (`auditReason`):**
    - `role-denied` reads "Only the owner can read the audit trail";
    - `report-unavailable` reads "Narrow the filters or dates";
    - `validation-failed` shows the server's detail.
  - **Copy.** Reword the `/reports` header copy.
- **The web: the document drill.** The ledger drill gains two display-only keys, `doc` and `label`.
  - **What `parseDrill` accepts.** `doc` must be one of `grn|po|order|adjustment|variance`, and exactly its key must be present: `grnId`, `poId`, `orderId`, `adjustmentPendingId` or `countVarianceId` respectively. `warehouseId` is the only other key allowed. Any other combination returns `'unsupported'`.
  - **The request.** `fetchLedgerDrill` strips `doc` and `label` before sending.
  - **Wording.** The banner, the description and the empty state change for document drills, e.g. "Showing ledger events for GRN GRN-0042", with a Clear link. The dashboard wording is unchanged.
- **The web: "View ledger" links.** Each uses the document's own warehouse:
  - GRN card (its warehouse);
  - PO card ("Receipts in the ledger", linking the warehouse the PO receives into);
  - order detail (thread `warehouseId` down from `OrdersTable`);
  - an approved adjustment row with `ledgerLinked`;
  - an `adjusted` variance card with `ledgerLinked`.
- **The pin at `drill-routes.test.ts:39,43`** is unchanged: the audit route maps to no drill.

**Never:**
- **Out of this story:** backfill, export (9-3b), anchoring or verification (9-3c), and retention (9-3d).
- **No portal access to audit:** no portal audit read, and no audit `client_id`.
- **Audit history is not changed:** no renamed action strings.
- **The audit read stays narrow:** reporting does no writes and reads no table except `audit_events` in the read model.
- **No new navigation targets:** no audit Target deep links, and no transfer web surface. The `transferId` filter is API-only.

## I/O & Edge-Case Matrix

| Scenario | State | Expected |
|---|---|---|
| Owner opens Audit | 120 rows, many sharing a `created_at` | newest 50; Next pages with no dupes or gaps |
| ops_manager calls the route | — | 403 `role-denied`; web hides the section, and a demoted owner sees the role copy |
| Portal session | — | refused by the guard fence |
| `actionPrefix=stock_adjustment.` | a row `stockXadjustment.y` exists | not matched (`_` escaped) |
| `actionPrefix=a%` / `from ≥ to` | — | 400 |
| Broad slow query | > 5 s | 503 → "Narrow the filters or dates" |
| Filter change on page 3 | — | back to page 1; Prev disabled |
| IST day `2026-10-12` | a row at 23:59 IST and one at 00:00 IST the next day | first in, second out |
| Putaway with device time 2 h ago | — | ordered by `recordedAt`; "happened" shown |
| Transfer created, key K; replay K | — | one `transfer.created` row |
| Device enrolled from code minted by U | — | `device.enrolled`, actor U |
| `assertEveryKeyAudited` | a keyed command with no audit row | suite fails naming the key |
| GRN card → View ledger | 3 receipts + 3 putaways, GRN in WH-B, active WH-A | 6 events, from WH-B; banner names the GRN code |
| PO card → Receipts in the ledger | — | receipt events only |
| Adjustment rejected / recounted variance / decided before 9-3a | `ledgerLinked=false` | no link |
| `doc=grn&poId=X` | — | unsupported drill |
| Outgoing ledger request | from a doc drill | carries no `doc`/`label` |

</frozen-after-approval>

## Code Map

Paths are under BE `workspace/core/backend/wms-be/src` and FE `workspace/core/frontend/wms-fe/src`.

- **Audit:**
  - `shared/db/schema.ts:194-212`: `actor_user_id` is NOT NULL; `:209` is the index being dropped.
  - `replenishment.command.ts:48-54,880-884,936`.
  - `enrollment.command.ts:291-299` (the mint row), `:341-434,848-929`.
  - `sync-report.command.ts:1134-1139,1263-1273` (the rejected-op apply).
  - Writers whose time is not server time: `putaway.command.ts:767,909`, `excursion.command.ts:164-168,471`.
- **Reporting and permissions:**
  - `api/reporting.controller.ts:18-23,30,63-65,86`.
  - `reporting/service.ts:32,126-128`.
  - `channels.facade.ts:159-174` (the gated-read pattern).
  - `tenancy/permissions.ts:4-10,274,394-403`.
  - `test/architecture.spec.ts:1582-1642,2036-2048`.
  - The FE mirror: `lib/users.ts:15-189,232-234`.
- **Paging:** `shared/primitives/pagination.ts:13-51`; `instant-range.ts:23`; `inventory.facade.ts:487` (the `::text` cursor).
- **Ledger:**
  - `api/inventory.controller.ts:607-644`.
  - `inventory.dto.ts:241,294-298`.
  - `inventory.facade.ts:149-170,453,521-530`.
  - `ledger-registry.ts:20-60`.
  - `ledger.service.ts:189-257,456`.
  - `adjustment-approval.command.ts:455-498`.
  - `inventory.command.ts:1139-1163`.
  - `count.command.ts:1288-1309`.
  - Schema: `stock_adjustment_pendings` `:2980`, `count_variances` `:3228`.
  - Migration precedent: `drizzle/0039_*.sql` (`ledger_events_order_ref_idx`).
- **FE:**
  - Reports: `app/(app)/reports/page.tsx:5-21`; `components/data-table/data-table.tsx:57,116`.
  - Shared hooks and helpers: `lib/use-inbound.ts:511-536` (`useUserMap`) and the `useQcHolds` cursor scoping; `lib/fetch-all-pages.ts:17`.
  - Drill: `lib/drill.ts:124-133,218-247,300-355,421-449`; `lib/drill-fetch.ts:37-38`.
  - Banner and ledger: `components/shared/drill-banner.tsx:42`; `components/inventory/ledger.tsx:72-78,185`.
  - Inbound: `inbound-cards.tsx:147-220,272-313`.
  - Outbound: `outbound-orders.tsx:519,736,763-797`.
  - Conflicts: `adjustment-pendings-queue.tsx:222,325-340`; `variance-queue.tsx:343-372`.
  - Error-reason precedent: `lib/service-report.ts:107-125`.

## Tasks & Acceptance

**Execution:**
- [x] **BE audit writes:**
  - `SYSTEM_ACTOR_ID` moves to `shared/`;
  - every `AUDIT_NEW_ACTIONS` row is written;
  - `AUDIT_TARGET_TYPES` and its pin;
  - both guard layers;
  - per-method assertions.
- [x] **BE read:**
  - `audit.view`;
  - the facade guard;
  - the audit read model;
  - `GET …/reporting/audit` with DTOs and the enum;
  - the third-exception guard;
  - `openapi.json`.
- [x] **BE ledger:**
  - reference-doc keys, and the omit-not-null pin;
  - the `ledger_event_id` columns, set on approve and adjust, plus `ledgerLinked` in both DTOs;
  - the five filters;
  - migration 0069, with journal, snapshot and the deploy note;
  - updated comments.
- [x] **BE tests:** every backend matrix row.
- [x] **FE:**
  - `api:generate`;
  - the mirror;
  - the Audit section with hook, filters, `auditReason` and cursor scoping;
  - the document drill (`doc`/`label`), the strip, and the wording;
  - the five links;
  - tests for every FE matrix row.
- [x] **Meta docs:**
  - IMPLEMENTATION-GUIDE §7a (the third exception) and step 10 (the audit rule and its guard);
  - `reporting.md`, `inventory.md`, `movements.md`, `API-SURFACE.md`, `frontend/SYSTEM-DESIGN.md`, both repo contracts;
  - PENDING:
    - the transfer web surface;
    - audit Target deep links;
    - audit `client_id` and the portal;
    - inconsistent action naming;
    - no ledger links for qc-hold, bin-merge, excursion, or auto-applied adjustments;
    - unkeyed system writers are outside the audit rule;
    - documents decided before 9-3a have no link.

**Acceptance Criteria:**
- Given an owner who creates a transfer, when they open Audit with `actionPrefix=transfer.`, then the row shows their email, `transfer.created`, and target `transfer_order`.
- Given a GRN card in any warehouse, when "View ledger" is clicked, then `/inventory/ledger` lists exactly that GRN's receipt and putaway events for its warehouse.
- Given every backend suite, when it runs, then `assertEveryKeyAudited` passes.
- Given the full BE and FE suites, lint, typecheck, build and the capability-mirror check, when run, then they pass.

## Implementation Notes

Built on wms-be `feat/9-3a-audit-trail-and-ledger-navigation` (`bcca8ac..ec05698`: `22c8c30` the story, `ec05698` the code-review patch) and wms-fe on the same branch (`1273ed0..7b59270`: `c1c0911`, `7b59270`). Design as built: `docs/design/modules/reporting.md` §The audit trail, `inventory.md` §Document links, `IMPLEMENTATION-GUIDE.md` §1 (step 10 — the audit rule and its guard) and §7a (the third exception), `frontend/IMPLEMENTATION-GUIDE.md` §1.9–§1.11.

**As-built deviations from the spec** (the code is the reference):
- **The shared constant is `SYSTEM_ACTOR_ID`; the old name is the re-export.** The spec said "`SYSTEM_ACTOR_ID` moves to `shared/`", but the constant was `REPLENISHMENT_SCHEDULER_ACTOR_ID` in `replenishment.command.ts`. It now lives in `src/shared/primitives/audit.ts` as `SYSTEM_ACTOR_ID` (value unchanged) and `REPLENISHMENT_SCHEDULER_ACTOR_ID = SYSTEM_ACTOR_ID` is kept, so the sweep, the expiry scan and their tests are unchanged.
- **`systemActorId` in the response.** `AuditTrailResponse` carries `systemActorId`, published as a one-value enum, beside `items`/`nextCursor`. The web's "System" filter sends `SYSTEM_ACTOR_ID` typed as that generated literal (`lib/audit.ts`) — a constant, so the filter works before any read succeeds (code review FE1), and a backend change fails the web's compile. The spec's "the web never hard-codes it" holds in that form: the value is checked against the contract at build time.
- **Composite references, matched by containment only for named actions.** The spec's guard matched `(tenant_id, reference)` by equality, which three pre-9-3a writers could not meet: `sku.client-corrected` (`from <a> → to <b> (key K)`), the client-invoice transitions with a note (`note: … (key K)`), and an ingested order's `order.created`, whose reference was `{"channel": {…}}` with no key at all. The ingested reference **gains a `key` sibling** (`{"channel": {…}, "key": K}`, additive), and `COMPOSITE_REFERENCE_ACTIONS` (`sku.client-corrected`, `order.created`, `client_invoice.disputed|settled|voided`) are the only rows matched by `strpos`; every other row must equal the key (code review BE5). **`channels.disconnected` was written with no `reference`**; it now carries the key. No action string was renamed.
- **`AUDIT_NO_OP_ARMS`.** The spec's only exemption was named endpoints (`selfTestEcho`, kept as `AUDIT_EXEMPT_ENDPOINTS`, recognised by snapshot shape). Arms that store a key and change nothing write no audit row by design, so the guard names them (the story shipped the first two; code review BE2 added the other five): `clients.updateStatus:same-status`, `orders.createOrder:channel-redelivery`, `orders.createOrder:dedup-loser`, `orders.cancelOrder:already-cancelled`, **`waves.release:already-released`, `waves.cancel:already-cancelled`** (the wave re-release / re-cancel arms and their racing losers, found by code review BE2), `devices.revoke:already-revoked`. A declared arm is checked against the stored snapshot's shape, so a declaration over another command's key fails (BE3, BE4).
- **Test helpers the spec did not name** (`test/support/audit-guard.ts`): `noOpIdempotencyKey(tenantId, key, arm)`, `seededIdempotencyKey(tenantId, key)` (keys a suite inserts by hand — a legacy fingerprint, a foreign tenant's row, a held race probe), `declareChannelNoOps(tenantId, orderId, arm)` (a channel ingest mints its key inside the command, so a webhook test declares the order's unaudited keys after a known redelivery and asserts the count), and `expectAuditRow({…})` (the per-action pin: one row, the action, target and actor, `occurred_at` within a minute of `created_at`; called again after a replay). Every exemption is keyed `(tenant, key)` (BE4). `assertEveryKeyAudited` takes a database URL, not a handle.
- **Pin placement.** The dynamic guard runs inside `SuiteDatabase.drop()` (`test/support/suite-db.ts`) — every e2e suite's teardown — so no suite opts in. `test/architecture.spec.ts` holds four 9-3a blocks (the third exception; the static scan; `AUDIT_TARGET_TYPES`, plus a check that every `AUDIT_NEW_ACTIONS` entry has an `expectAuditRow` call; the cleanup-delete pin) and one portal-block test. The omit-not-null pin is in `test/adjustment-approval.spec.ts` (the immediate path's hash recomputes from the three pre-9-3a keys), not `test/ledger.spec.ts` as an early comment said (BE8).
- **The cleanup deletes are gone.** Spec files from the shared-database era deleted `idempotency_keys` and `audit_events` wholesale in their `afterAll` cleanup, which runs before `drop()` — the guard saw empty tables and was blind in ~25 suites (code review BE1, high). The deletes are removed from all 46 spec files that had them (the suite database is dropped whole) and `test/architecture.spec.ts` refuses any spec that deletes from either table, or lists either in a cleanup table list, except one named row (`… and key = …` / `… where id = …`).
- **Capability pins 41 → 42.** `audit.view` is the 42nd capability (`test/users.spec.ts`); the web mirror adds it to `CAPABILITIES` and `OWNER_ONLY_CAPABILITIES` only — `OPS_EXCLUDED_CAPABILITIES` spreads `OWNER_ONLY_CAPABILITIES`, so it is excluded there without a second entry.
- **The `?` predicate.** Each document filter is `(reference_doc ? '<key>' AND reference_doc ->> '<key>' = lower($id))`, not the equality alone: the 0069 indexes are partial, and the planner uses a partial index only when the query states its predicate. The 9-1 `orderId` filter (the spec's model) lacks it, so 0039's index is not used for it — PENDING.
- **`AdjustmentPendingEntryDto`.** `ledgerLinked` is not a field on `AdjustmentPendingDto`, which is also the 202's stored idempotency snapshot — a pre-9-3a key would replay without it. The queue's items are `AdjustmentPendingEntryDto extends AdjustmentPendingDto`; the 202 and the decision snapshot are unchanged. The count resolve's answer does carry `ledgerLinked`; a resolve snapshot stored before 9-3a is re-served with `ledgerLinked ?? false` (`movements.controller.ts`).
- **A missing mint row answers 400, not 500.** `device.enrolled` reads its actor from the device's `device.enrollment_code_minted` row. The story's first cut threw an untyped `Error` when none existed; enroll now refuses `400 enrollment-code-invalid` — the one indistinguishable 400 — and the rollback un-burns the code (code review BE7). Unreachable through the API; pinned by deleting the row by hand.
- **Id tails.** The spec said "a short id" for an unknown actor and the target. A UUIDv7's first 8 characters are its timestamp, alike across a day's rows, so 9-3a's surfaces show the random **tail** (`shortIdTail` = the last 8 characters): the Who and Target columns and a document drill with no `label` (code review FE2). The older head-based `Warehouse <short id>` is unchanged — PENDING.
- **Smaller gaps the spec left, filled:**
  - the static scan's detector is `.insert(idempotencyKeys` (40 files matched; the test asserts ≥ 35 plus invoicing's `command.ts` and billing's `client-invoices.ts` by name);
  - the third-exception guard also bans `getMemberRoleIn`, `assertPermission` and `users` from `audit.ts`, and pins the facade's guard line verbatim;
  - `auditRead` is a plain facade field so the 503 test forces a timeout without a second code path; the test also pins the armed 5 s `statement_timeout` (BE6);
  - the five ledger indexes are hand-amended into 0069 as `CREATE INDEX IF NOT EXISTS` (the 0039 precedent — not in `schema.ts` or the snapshot), so a hand-run `CONCURRENTLY` pre-build is skipped at deploy; the deploy note records 147 rows / 384 kB in dev;
  - the PO and GRN links sit in a new "Ledger" column of their tables; the order link's label is the order's `externalEventId`, else its id; a display `label` is capped at 120 characters;
  - the hook's `reload()` resets the cursor and bumps an `epoch` that keys the table, so Retry reads page 1 with an empty Prev/Next stack (FE3); the filter key includes `targetId` (FE4);
  - the PO drill's empty state reads "No receipt events for PO … yet." (FE6).

Deploy note: 0069's index builds lock `ledger_events` (and `audit_events`) writes for their duration — milliseconds at today's size; for a large live ledger, pre-build the five ledger indexes `CONCURRENTLY` (PENDING reporting runbook).

## Spec Change Log

## Review Triage Log

Design review (2026-10-12), two lenses: backend (K) and web/API/tests (W).

| # | Lens | Finding | Verdict | Disposition |
|---|---|---|---|---|
| 1 | K | A file-level guard already passes 4 gap files; the glob misses keyed non-`*.command.ts` files; the exemptions are inert; `selfTestEcho` is missing | high (verified: `count.command.ts:1396`, `bin.command.ts:1062`) | Fixed: a dynamic key↔audit check plus an all-files static scan; named exemptions |
| 2 | K | Device enroll has no requesting user | high (verified: `enrollment.command.ts:63-71`) | Fixed: actor = the code's minter |
| 3 | K | `occurred_at` is not always server time; the window and cursor broke §7a/§9 | high (verified: `putaway.command.ts:767`) | Fixed: order/filter/page on `created_at`; display both |
| 4 | W | A `doc` key would 400 at the BE or make the drill unsupported | high (verified: `drill.ts:316,347`, `app.factory.ts:61`) | Fixed: display-only `doc`/`label`, stripped |
| 5 | W | Audit Target links would land on lists in the wrong warehouse | high (verified: `outbound/page.tsx:17`) | Fixed: plain text; deep links → PENDING |
| 6 | W | The FE can't tell whether an adjustment or variance has linked events | high (verified: `types.gen.ts:1093,4183`) | Fixed: `ledger_event_id` columns + `ledgerLinked` |
| 7 | K | A GIN build locks writes on the whole ledger; the existing audit index is duplicated | medium | Fixed: partial btree per key (0039 precedent); old index dropped; deploy note |
| 8 | K | `actionPrefix` admits `_` unescaped; no `action` index | medium | Fixed: ESCAPE all three; a `text_pattern_ops` index |
| 9 | K | Registry "validators" don't exist; the omit rule; the byte-identical invariant breaks | medium (verified: `ledger.service.ts:456`) | Fixed |
| 10 | K | Role-check location unstated and contradicting "no other table"; "reads never gated" is wrong | medium (verified: `channels.facade.ts:159`) | Fixed: facade guard; concrete third-exception guard |
| 11 | K, W | No action/target vocabulary; no source for the web select | medium | Fixed: the `AUDIT_NEW_ACTIONS` table; `AUDIT_TARGET_TYPES` in openapi |
| 12 | W | Doc-drill key rules undefined | medium | Fixed: one required key per `doc` |
| 13 | W | Dashboard wording outside the banner; a uuid in the banner | medium (verified: `ledger.tsx:77,185`) | Fixed: three strings; `label` |
| 14 | W | Route segment `reports` vs `reporting` | medium (verified: `reporting.controller.ts:30`) | Fixed |
| 15 | W | No web error mapper | medium | Fixed: `auditReason` |
| 16 | W | Filter changes don't reset the cursor | medium (verified: `data-table.tsx:57`) | Fixed: cursor scoped by filters |
| 17 | W | No IST day-to-instant rule | medium (verified: `instant-range.ts:23`) | Fixed |
| 18 | W | The mirror grants ops_manager by default | low (verified: `users.ts:232`) | Fixed: `OWNER_ONLY_CAPABILITIES` |
| 19 | W | Members-list limits; no "System" option | low | Fixed |
| 20 | K | Replenishment `createInTx` actor and two rows | low | Fixed: stated |
| 21 | K, W | "System" is hard-coded on the web; PO link scope | low | Fixed: `actorKind`; "Receipts" |
| 22 | W | qc-hold, bin-merge, excursion and auto adjustments have no link | low | → PENDING |
| 23 | K | Verified: registration under the new tenant scope; the import row exists; `reference_doc` is jsonb; putaway keyed `grnId`; lowercase ids; owner holds every capability; portal emails resolvable | — | No change |


**Code review (2026-10-13)**, two lenses: backend (BE) and web (FE); 16 findings.

| # | Lens | Finding | Verdict | Disposition |
|---|---|---|---|---|
| BE1 | BE | `assertEveryKeyAudited` was blind in ~25 suites: their `afterAll` cleanup deleted `idempotency_keys` and `audit_events` before `drop()` ran the check | high | Fixed: the cleanup deletes are removed (the suite DB is dropped whole); an architecture pin forbids deleting either table except one named row |
| BE2 | BE | No-op arms that store a key and change nothing were missing from `AUDIT_NO_OP_ARMS` (it named two): the cancel of a cancelled order and its racing loser, the dedup loser, a device re-revoke, a wave re-release / re-cancel | medium | Fixed: five arms added and declared where the suites drive them |
| BE3 | BE | Unregistered exemptions: keys some suites seed by hand (sku-attributes, catch-weight) and channel redelivery keys the ingest mints itself were never declared — invisible only because of BE1 | medium | Fixed: the seeded keys registered with `seededIdempotencyKey`; ingest-minted keys declared through the new `declareChannelNoOps` |
| BE4 | BE | Exemptions were not tenant-scoped, and a declared arm was never checked against what the key stored | low | Fixed: keyed `(tenant, key)`; the teardown checks the stored snapshot has the declared arm's shape |
| BE5 | BE | The guard matched a reference by containment, so any row quoting a key satisfied it | low | Fixed: equality; containment only for the named `COMPOSITE_REFERENCE_ACTIONS` |
| BE6 | BE | The 503 test did not pin the deadline it relied on | low | Fixed: it asserts the armed 5 s `statement_timeout` |
| BE7 | BE | A device with no mint audit row made enroll throw an untyped 500 | low | Fixed: `400 enrollment-code-invalid`, rolled back (the code stays redeemable); tested |
| BE8 | BE | Stale comments (the omit-not-null pin's location, the teardown claim, "reads stay open" in `permissions.ts`) | low | Fixed |
| BE9 | BE | The putaway EXPLAIN test explains a hand-written query, not the facade's | low | Deferred: PENDING inventory, deferred-work |
| FE1 | FE | The "System" actor filter was unusable until a page had loaded (it read `systemActorId` from the response) | medium | Fixed: `SYSTEM_ACTOR_ID` typed as the generated `systemActorId` literal |
| FE2 | FE | Short ids took the UUIDv7 head — its timestamp, alike across a day's rows; the order's "View ledger" had no real label | medium | Fixed on 9-3a's surfaces (`shortIdTail`), and the order link labelled by its channel ref, else its id; the house-wide `Warehouse <short id>` convention deferred: PENDING wms-fe, deferred-work |
| FE3 | FE | Retry re-read the same cursor while the table kept its Prev/Next stack, so the two disagreed | low | Fixed: `reload()` resets the cursor and bumps an `epoch` that keys the table |
| FE4 | FE | The filter key omitted `targetId`, so a change to it kept the old cursor | low | Fixed |
| FE5 | FE | The PO drill test looped over its filtered reads, passing vacuously when they were empty | low | Fixed: it asserts the reads are non-empty |
| FE6 | FE | The PO drill's empty state did not say it lists receipts only | low | Fixed: "No receipt events for PO … yet."; a PO whose receipts were retargeted to its successor deferred: PENDING inbound, deferred-work |
| FE7 | FE | The members list behind the actor filter truncates silently at 1,000 | low | Deferred: PENDING wms-fe, deferred-work |

## Design Notes

- **Why the target, not `reference`, is the document:** `reference` holds idempotency keys, which mean nothing to an Owner.
- **Why `created_at`:** the trail must be ordered by when the server recorded the action. Device time can be hours old, and paging on it breaks cursors.
- **Why a recorded `ledger_event_id` rather than probing the ledger:** the document then knows its own link. Rejected, recounted and pre-9-3a cases fall out naturally as "no link", never as a wrong list.
- **Why no backfill:** past actions have no trustworthy actor to reconstruct. The trail is complete from the deploy onward, and the docs say so.

## Verification

**Commands:**
- `cd workspace/core/backend/wms-be && bun run test && bun run lint && bun run typecheck && bun run build`: all pass. Use jest, one invocation at a time.
- `cd workspace/core/backend/wms-be && bun run db:generate`: reports "No schema changes". A fresh migrate followed by `db:verify` also passes.
- `cd workspace/core/frontend/wms-fe && bun test && bun run lint && bun run typecheck && bun run build && bun run check:capability-mirror`: all pass.
