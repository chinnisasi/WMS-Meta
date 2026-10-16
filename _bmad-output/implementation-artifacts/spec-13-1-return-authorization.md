---
title: 'Return authorization — an operator authorizes a dispatched order''s units for return (RMA), naming the expected units and a reason'
type: 'feature'
created: '2026-10-16'
status: 'done'
route: 'dispatch'
review_loop_iteration: 0
baseline_commit: 'wms-be 0312a8821893d96952c76d84d7b3a56a0cb0fe10; wms-fe 1b4c4c2184d63d2cbe47dc7409f42fc3d3d7a314'
context:
  - '_bmad-output/implementation-artifacts/epic-13-context.md'
  - 'docs/design/SYSTEM-DESIGN.md'
  - 'docs/design/IMPLEMENTATION-GUIDE.md'
  - 'docs/design/API-SURFACE.md'
  - 'docs/design/modules/outbound.md'
  - 'docs/design/modules/inbound.md'
  - 'docs/design/modules/catalog.md'
  - 'docs/design/modules/inventory.md'
  - 'docs/design/modules/clients.md'
  - 'docs/design/frontend/SYSTEM-DESIGN.md'
  - 'docs/design/frontend/IMPLEMENTATION-GUIDE.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** FR-46 requires that a dispatched order's units can be authorized for return (an RMA), with the authorization naming the expected units and the reason. Nothing returns-related exists yet. Each later Epic 13 story needs the authorization first:
- 13-2 receives returns against it;
- 13-3 dispositions them;
- 13-4 builds the web returns queue;
- 13-5 builds the mobile Return task.

**Approach:**
- **Backend:** a new `returns` module owns return authorizations. An operator command authorizes part of a dispatched order for return, bounded by what was dispatched minus what is already authorized. Each line names a quantity, its serial numbers for serial-tracked SKUs, and a reason. A second command cancels an authorization.
- **Web:** "Create return" on a dispatched order's detail panel, and a minimal Returns page listing authorizations with a Cancel action.
- **No ledger event:** an authorization moves no stock.

**Decisions (human, 2026-10-16):**
1. **Operators only.** A new capability, `returns.manage`, goes to the owner and the ops manager. Client-portal RMA requests are a later story.
2. **Backend plus a minimal web path in 13-1.** That is "Create return" from the order detail and a Returns page. 13-4 adds the returns queue and the disposition approval cards.
3. **Reason is a fixed list plus a note, per line:** `damaged`, `defective`, `wrong-item`, `not-as-described`, `changed-mind`, `other`. `other` requires a note.
4. **No return window in 13-1.** Any dispatched order can be authorized, and the authorization records when the order was dispatched.

## Boundaries & Constraints

**Always:**

- **Module.**
  - `src/modules/returns/` holds:
    - `returns.module.ts`;
    - `returns.facade.ts`, its only export;
    - `return-authorization.command.ts`;
    - `returns.dto.ts`;
    - `events.ts`.
  - Routes live in a new `api/returns.controller.ts`.
  - An ownership block in `test/architecture.spec.ts` pins that only `returns` writes `return_authorizations` and `return_authorization_lines`.
  - A read guard pins that `src/modules/returns` imports from the schema only its own two tables, `idempotencyKeys` and `auditEvents`, and that no raw `sql` names `orders`, `order_lines`, `picks`, `ledger_events`, `serials`, `skus` or `handling_units`. The guard includes the self-tests that prove each detector can fail.
  - Other modules are read only through `OutboundFacade`, `InventoryFacade` and `CatalogFacade`.
- **Migration 0072** (§3 checklist; the probe DO-block covers every new CHECK):
  - **`return_authorizations`:**
    - **Columns:**
      - `id`, `tenant_id`;
      - `client_id`: the order's client. This is consistent with §7b, because an order's client cannot drift from its SKUs' (`sku-client.command.ts:78-85`);
      - `warehouse_id`: the order's warehouse, where the return will be received;
      - `order_id`;
      - `order_reference`: a nullable snapshot of the order's `external_event_id`, taken at create;
      - `code`;
      - `external_reference`: nullable, 1–64 characters, trimmed; a channel's or customer's RMA number. It is deliberately not unique;
      - `status`;
      - `order_dispatched_at`;
      - `created_by`, `cancelled_by`, `cancelled_at`, `cancel_reason`;
      - `created_at`, `updated_at`.
    - **`status`:** CHECK `open|cancelled`. 13-2 and 13-3 widen it, a cheap drop-and-re-add (§3); no state is reserved before it is designed.
    - **Constraints:**
      - unique `(tenant_id, code)`;
      - index `(tenant_id, order_id)`;
      - index `(tenant_id, warehouse_id, created_at, id)` for the list;
      - shape CHECK: `status = 'cancelled'` ⇔ all three cancel columns are set.
  - **`return_authorization_lines`:**
    - **Columns:**
      - `id`, `tenant_id`, `rma_id`, `order_line_id`, `sku_id`;
      - `authorized_qty`: bigint milli-units, CHECK > 0;
      - `received_qty`: bigint, default 0; 13-2 writes it;
      - `reason_code`: CHECK, one of the six codes;
      - `reason_note`: nullable, 1–500 characters, trimmed; CHECK `reason_code <> 'other' OR reason_note IS NOT NULL`;
      - `serial_ids uuid[] NOT NULL DEFAULT '{}'`: catalog serial ids, the ledger's `serial_ref` form;
      - `created_at`.
    - Unique `(rma_id, order_line_id)`.
  - **RLS:** the client-scoped document pattern. `return_authorizations` takes the tenant + client policy from `advance_shipment_notices` (`0064:148-161`). `return_authorization_lines` takes the parent-EXISTS shape from `asn_lines` (`0064:163-180`). No FKs (§3).
- **Codes:** `RMA-0001`, server-generated, zero-padded to 4 digits, unique per tenant. They are allocated under `pg_advisory_xact_lock(hashtextextended(tenant || ':rma-seq', 0))` as the max numeric tail + 1, copying `allocateGrnCode` (`receiving.command.ts:1665-1677`) including its `[0-9]{1,9}` bound. Lock order is the order lock, then the sequence lock. No other path takes them.
- **Create: `POST /tenants/{t}/returns`.**
  - **Body:** `{orderId, externalReference?, lines: [{orderLineId, qty, reasonCode, reasonNote?, serialNumbers?}]}`, with `Idempotency-Key` required.
  - **Access:** `TenantSessionGuard`, `assertOwnTenantToken`, then `returns.manage`.
  - **Above the transaction** (shape; 400 `validation-failed`, naming the line):
    - 1–200 lines, with distinct `orderLineId`s;
    - `qty > 0`;
    - `reasonCode` in the list;
    - a non-blank `reasonNote` when the code is `other`;
    - `serialNumbers`, when present, distinct and non-blank, at most 500 per line and 500 per request, with a length equal to `qty`.

    Text is trimmed, and a blank value means absent.
  - **The hash:** `{arm: 'rma-create', tenantId, orderId, externalReference, lines}`, with lines in request order, `qty` canonicalised, and serial numbers sorted.
  - **In one transaction:**
    1. Permission.
    2. Replay.
    3. Take the order lock: `pg_advisory_xact_lock(hashtextextended(tenant || ':rma-order:' || orderId, 0))`. The key expression is exported for the race test.
    4. Replay again, under the lock.
    5. Read the order facts through `OutboundFacade.orderInvoiceFactsInTx` (status, `warehouseId`, `clientId`, `externalEventId`, and per line `parentLineId`, `skuId`, `uom` and `dispatchedQtyMilli`). An unknown order is 404 `not-found`; an order that is not `dispatched` is 409 `order-not-dispatched`.
    6. Read the SKU facts through a new `CatalogFacade.skuFactsInTx(tx, tenantId, skuIds)`: `serialTracked`, `catchWeightTracked`, `uomPrecision`.
    7. Read the ledger through `InventoryFacade.ledgerEventsByOrderRefInTx(tx, tenantId, warehouseId, orderId)`. It yields each line's dispatched `serialRef`s and the `dispatch.dispatched` events' `occurredAt`, the earliest of which becomes `order_dispatched_at`.
    8. Resolve serial numbers to ids through a new `CatalogFacade.serialIdentitiesInTx(tx, tenantId, skuId, {numbers | ids})`.
    9. Validate each line (below).
    10. Allocate the code.
    11. Insert the authorization and its lines.
    12. Append the outbox event `return_authorization.created` (`{rmaId, code, orderId, warehouseId, clientId}`).
    13. Write the audit row `return_authorization.created` (target `return_authorization`, actor the requester, `reference` = the key).
    14. Write the key last. Outbox before audit is the §1 order (steps 9 and 10).
  - **Answer:** 201 `ReturnAuthorizationDto`.
- **Returnable, per order line,** computed in `ReturnsFacade` from the facts above:
  - `dispatchedQty` is `dispatchedQtyMilli` (Σ `picks.qty`; dispatch is all-or-nothing and terminal, and picks are never reversed);
  - `authorizedQty` is Σ `authorized_qty` over this line on `open` authorizations;
  - `returnableQty` is `max(0, dispatched − authorized)`;
  - `returnableSerials` (serial-tracked lines only) is the dispatched serial ids minus those on `open` authorizations, each given as `{id, serialNumber}`.
- **Line validation** (behind the lock), in this order, each refusal naming the line:
  1. The order line must belong to the order: 400 `line-not-of-order` (the existing code, `invoicing/generator.ts:358`).
  2. A kit parent (a line with child lines) is 400 `kit-parent-not-returnable`. Its component lines are returnable on their own.
  3. The quantity must sit at the SKU's UoM precision (the Epic 10 rule): 400 `validation-failed`.
  4. The quantity must be ≤ `returnableQty`: 409 `exceeds-returnable`, naming the returnable quantity.
  5. **Serial-tracked SKU:**
     - `serialNumbers` is required, at unit precision;
     - each number must resolve to a serial that is among `returnableSerials`. A number not dispatched on this line is 409 `serial-not-dispatched`; one already authorized is 409 `serial-already-authorized`.
  6. **Any other SKU:** `serialNumbers` must be absent (400).
  7. **Catch-weight SKUs:** quantity only. 13-2 binds the physical cases at receipt.
  8. **Batch-tracked SKUs:** no batch at authorization. 13-2 binds the batch at the scan and checks it against the line's picked batches.
- **Cancel: `POST /tenants/{t}/returns/{rmaId}/cancel`.**
  - **Body:** `{reason}`, 1–500 characters after trimming. `Idempotency-Key` is required.
  - **The hash:** `{arm: 'rma-cancel', tenantId, rmaId, reason}`.
  - **Order:**
    1. `TenantSessionGuard`;
    2. permission `returns.manage`;
    3. replay;
    4. lock the authorization `FOR UPDATE`; the helper checks existence only (404 `not-found`), never status (§1, the `loadOpenPo` lesson);
    5. replay again, under the lock;
    6. the status guard: only `open` with every line at `received_qty = 0`, else 409 `rma-transition-invalid`.
  - **Writes:** set `cancelled` and its columns; append the outbox event `return_authorization.cancelled`; write the audit row `return_authorization.cancelled`; write the key.
  - **Answer:** 200 DTO.
  - **Effect:** the authorization's quantity and serials become returnable again.
- **Reads** are member-open, like every read. Each route carries `TenantSessionGuard`. Declare the literal `returnable` route before `:rmaId` and pin that order (§6).
  - **`GET /tenants/{t}/returns/returnable?orderId=`:**
    - The answer: `{orderId, status, warehouseId, orderReference, dispatchedAt, lines: [{orderLineId, parentLineId, skuId, kitParent, dispatchedQty, authorizedQty, returnableQty, serialTracked, returnableSerials}]}`.
    - A non-dispatched order answers with its status and `returnableQty: 0` everywhere, rather than a refusal.
  - **`GET /tenants/{t}/returns?warehouseId&status&orderId&cursor&limit`:**
    - cursor-paged on `(created_at, id)` DESC with the full-precision `::text` cursor (`fullPrecisionInstant`, `pagination.ts`);
    - `limit` 1–100, default 50;
    - 400 `invalid-cursor` for a bad cursor;
    - `warehouseId` is optional, so the list is tenant-wide when it is absent.
  - **`GET /tenants/{t}/returns/{rmaId}`:** the DTO, or 404 `not-found`.
  - **The DTO:** `{id, code, status, orderId, orderReference, warehouseId, clientId, externalReference, orderDispatchedAt, createdAt, createdBy, cancelledAt, cancelledBy, cancelReason, lines: [{id, orderLineId, skuId, authorizedQty, receivedQty, reasonCode, reasonNote, serials: [{id, serialNumber}]}]}`. Quantities are JSON numbers in base units, the ASN and order convention.
- **Error table.** Each code, its status, and the web's `returnReason` text:

  | Code | Status | `returnReason` text |
  |---|---|---|
  | `role-denied` | 403 | "You can't manage returns" |
  | `not-found` | 404 | "Order or return not found" |
  | `order-not-dispatched` | 409 | "Only a dispatched order can be returned" |
  | `line-not-of-order` | 400 | "That line isn't on this order" |
  | `kit-parent-not-returnable` | 400 | "Return the kit's components" |
  | `exceeds-returnable` | 409 | "More than can be returned — N left" |
  | `serial-not-dispatched` | 409 | "Serial X wasn't dispatched on this line" |
  | `serial-already-authorized` | 409 | "Serial X is already on a return" |
  | `rma-transition-invalid` | 409 | "This return can no longer be cancelled" |
  | `validation-failed` | 400 | the server's detail |
  | `invalid-cursor` | 400 | — |
  | `idempotency-key-reuse` | 422 | — |
- **Vocabulary:**
  - **Capability:** `returns.manage` is the 44th, held by the owner (automatically) and the ops manager. On the web it goes in `CAPABILITIES` only; ops is derived. The pins move 43 → 44.
  - **Audit:** `return_authorization` joins `AUDIT_TARGET_TYPES` and the web's `AUDIT_TARGET_LABEL` ("Return"). Both actions join `AUDIT_NEW_ACTIONS`, each pinned with `expectAuditRow`.
  - **Outbox events:** `return_authorization.created` and `.cancelled`, exported from `returns/events.ts`.
  - **Suspended clients:** a client's suspension does not block an authorization, under the 21-10 "operator work unaffected" rule (`clients.md:95`).
- **The web:**
  - **Order detail.** `OrderDetailPanel` (`outbound-orders.tsx:764`) receives `canManageReturns`, threaded down from `OutboundOrders`. For a `dispatched` order with the capability, "Create return" opens an inline form, never a modal.
    - **Loading:** the form fetches the returnable read **only when opened**. It never fetches on expand, so the existing tests' URL-keyed fetch stubs (`outbound-orders.test.tsx:94-150`) keep working.
    - **Line rows:** lines are grouped with `parentLineId`. Kit parents read "Return the components below". Each line shows its SKU code, dispatched, already authorized and returnable quantities, a quantity input (step from `uomPrecision`, via `useOutboundSkus`), a reason select and a note.
    - **Serial lines** show the `returnableSerials` with a filter box and "Select all". The quantity is the count checked, capped at 500 per line.
    - There is an optional external reference.
    - **Submit** sends only lines above zero, with a key per draft (`asn-card.tsx:234-273`).
    - **On success** it shows "Return RMA-0007 created" with a link to `/returns`, and fires `RETURNS_CHANGED_EVENT`.
    - **A 409** `exceeds-returnable` or a serial 409 reloads the returnable read and clears the key.
  - **The Returns page** (`app/(app)/returns/page.tsx`):
    - **Navigation:** an ungated "Returns" entry after Reports and before Settings (EXPERIENCE.md:40), with a new unique monogram. `NAV_ITEM_COUNT` and its pins move 12 → 13, and the route-map row and the "N of twelve" copy change with them.
    - **The list:** a `DataTable` over the active warehouse (the shared picker, as other warehouse lists do), with a server-side `status` filter that remounts the table. Columns:
      - code;
      - order: `orderReference`, else the order id as the Outbound list shows it;
      - status pill: `RETURN_STATUS_LABEL`, a `Record` over the generated union, word-first;
      - lines summary (SKU count, units);
      - external reference;
      - created (IST).
    - **The expanded row** (`renderExpanded`) shows the lines, their reasons and their serial numbers.
    - **Cancel** shows only with `returns.manage`. It is an inline confirmation with the reason field, the order-cancel pattern at `outbound-orders.tsx:704-722`, with a key per click. A 409 shows its reason and reloads.
    - **Refresh:** the page listens to `RETURNS_CHANGED_EVENT`. There is no polling. The empty state reads "No returns yet".
  - **Where the code lives:**
    - `lib/returns.ts`: words, parsers, `returnReason` and `RETURNS_CHANGED_EVENT`;
    - `lib/use-returns.ts`;
    - `components/returns/*`.
- **"At next touch" claims** (Epic 9 retro action item 4):
  - **Outbound PENDING, "No read-back for a dispatch record":** partly served, because the returnable read exposes dispatched quantity and dispatch time. Recorded, not closed.
  - **The duplication item (`epic-21-retro-item-94`):** declined. This story uses the existing `pagination.ts`, `hashCommandPayload` and `parseIdempotencyKey`, and the extraction itself is retro action item 3's story.

**Never:**
- **Stock:** no ledger event, no stock movement and no ATP change.
- **Access:** no portal access and no client-held capability.
- **Lifecycle:** no return window, no amend and no close. Close belongs to 13-3, after receipt.
- **Money:** no refund, credit or billing charge.
- **Later stories:** no receipt, inspection or disposition (13-2, 13-3).
- **Other surfaces:** no mobile change, no `openReturns` in the snapshot (13-2/13-5), and no notification source.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Happy path | Dispatched order; 2 of 3 dispatched units of line A, `damaged` | 201 `RMA-0001`, `open`, `orderReference` and `order_dispatched_at` set; returnable for A drops to 1; one audit row; one outbox event | — |
| Serial line | 2 of 3 returnable serial numbers named | 201; the DTO lists `{id, serialNumber}`; those leave `returnableSerials` | Undispatched number → 409 `serial-not-dispatched`; already authorized → 409 `serial-already-authorized`; count ≠ qty or more than 500 → 400 |
| Over-authorize | qty above returnable, including after an earlier RMA | — | 409 `exceeds-returnable` naming N |
| Not dispatched | Order `accepted`, `ready_to_dispatch` or `cancelled` | Returnable read answers `returnableQty: 0` | Create → 409 `order-not-dispatched`; unknown order → 404 `not-found` |
| Kit parent | A line for the kit parent | Components are returnable | 400 `kit-parent-not-returnable` |
| Concurrent RMAs | Two different-key creates on one order, each within the bound alone but over it together | One 201; the other 409 `exceeds-returnable` | — |
| Same-key race | Two parked same-key creates (held on the advisory lock; `audit-export.spec.ts:476-517` pattern) | One RMA; the loser replays the 201 | — |
| Replay | Same key and body / different body | Same 201 / 422 `idempotency-key-reuse` | — |
| Shape | `other` without a note; duplicate `orderLineId`; serials on a non-serial line | — | 400 `validation-failed`, never a replay |
| Cancel | Open RMA | 200 `cancelled`; its quantity and serials returnable again; audited | Second cancel → 409 `rma-transition-invalid`; replay → same 200 |
| Not permitted | Operator or accountant creates or cancels | — | 403 `role-denied`; nothing written |
| Codes | Third RMA, and two concurrent creates on different orders | `RMA-0003`; distinct codes | — |
| RLS | Client B's portal-scoped session reads client A's RMA and lines | Not visible | — |
| Web | Create shown only for a dispatched order with the capability, fetched on open; kit grouping; serial filter and select-all; key per draft; success link and change event; 409 reloads; nav entry (13); Returns list per warehouse; status filter; expand; Cancel inline with reason; empty state | As specified | — |

</frozen-after-approval>

## Code Map

Paths are under BE `workspace/core/backend/wms-be/src` and FE `workspace/core/frontend/wms-fe/src`.

- **Order facts:**
  - `modules/outbound/outbound.facade.ts:522-628` `orderInvoiceFactsInTx`: status, `warehouseId`, `clientId`, per-line `parentLineId`, `skuId`, `uom`, and `dispatchedQtyMilli` via a Σ `picks.qty` left join. Reuse it; add `externalEventId` if it is missing. Do not write a third dispatched-quantity query.
  - `:516` notes that the architecture guard binds writes only.
- **Dispatch and pick:**
  - `dispatch.command.ts:293-312` (all-or-nothing, terminal), `:325-331` (Σ `picks.qty`), `:343-399` (`dispatch.dispatched` events);
  - `pick.command.ts:846-849,993,1017-1028` (one `pick.picked` per serial unit, `serialRef` = `serials.id`, `orderLineId` in its reference doc), `:1825-1856` `resolveSerialRefsInTx`;
  - `order.command.ts:1030-1033` (an order with picks cannot be cancelled).
- **Ledger read:** `modules/inventory/inventory.facade.ts:1223-1248` `ledgerEventsByOrderRefInTx` (it needs `warehouseId`).
- **Catalog:** `catalog.facade.ts:564` `findSerial` (single id, its own transaction; not enough). Add `serialIdentitiesInTx` and `skuFactsInTx`. `serials` is catalog-owned (`architecture.spec.ts:408,418`).
- **Catch-weight and batch:** `schema.ts:898-913` (`handling_units.packed_order_line_id`, `weight_grams`); `dispatch.command.ts:316-320` (multi-batch slices).
- **Templates:**
  - `modules/inbound/asn.command.ts:454` (guard-order doc), `:475` `create`, `:918` `lockAsn`, `:1044` `replay`, `:197,280` (`not-found`, the 400 `validation-failed`);
  - `receiving.command.ts:274,1665-1677` (`grnCode`, `allocateGrnCode`);
  - `drizzle/0064_advance_shipment_notices.sql:146-180` (RLS shapes);
  - `api/inbound.controller.ts:348-527`;
  - advisory-lock race test: `test/audit-export.spec.ts:476-517`;
  - dispatched-order seeding: `test/cold-chain.spec.ts:386-474` (`createOrder`, `releasedWave`, `pickAllLines`, `packAndDispatch`). Extract these to `test/support/dispatched-order.ts` and import them from both suites.
- **Shared:**
  - `shared/primitives/pagination.ts`, `time.ts` (`fullPrecisionInstant`);
  - `modules/tenancy/idempotency-guard.ts:55` `hashCommandPayload`;
  - `shared/idempotency/idempotency.seam.ts`;
  - `OUTBOX_SINK`;
  - `shared/primitives/audit.ts:44,103`;
  - `test/support/audit-guard.ts`.
- **Permissions:** `modules/tenancy/permissions.ts:14,297-299`; `test/users.spec.ts:887`; FE `lib/users.ts`, `lib/users.test.ts:58`, `scripts/check-capability-mirror.ts`.
- **Architecture:** `test/architecture.spec.ts:200-250` (the order-aggregate block, writes only), `:941-1000` (transfer). The new read guard is this story's own.
- **Migration:** `0072`.
- **Web:**
  - `components/outbound/outbound-orders.tsx`: `:540-551` (the `OUTBOUND_CHANGED_EVENT` reset; don't reuse it), `:586-631` (order id and channel references), `:704-722` (inline cancel), `:764-802` (`OrderDetailPanel`, `groupKitLines`);
  - `outbound-orders.test.tsx:94-150` (URL-keyed fetch stubs);
  - `useOutboundSkus` (`serialTracked`, `uomPrecision`);
  - `components/inbound/asn-card.tsx:234-273` (key per draft);
  - `lib/asns.ts:22` (change-event pattern);
  - `lib/navigation.ts:23-30,69`, `navigation.test.ts:8,28,72`;
  - `components/data-table/data-table.tsx` (`renderExpanded`);
  - `lib/audit.ts:23,96` (`AUDIT_TARGET_LABEL`, `shortIdTail`);
  - `lib/users.ts:284`.

## Tasks & Acceptance

**Execution:**
- [x] **BE migration 0072** (§3): the tables, RLS, CHECKs and indexes; journal, snapshot and probe.
- [x] **BE catalog:** `skuFactsInTx` and `serialIdentitiesInTx`.
- [x] **BE outbound:** confirm or extend `orderInvoiceFactsInTx` (`externalEventId`).
- [x] **BE returns module:**
  - the facade and the command: create and cancel, the guard orders, code allocation, the exported lock key;
  - the returnable read, list and get;
  - the events;
  - the ownership and read guards.
- [x] **BE vocabulary:** `returns.manage` (44) and its pins; the audit target and actions.
- [x] **BE api:** `api/returns.controller.ts`, its route order pinned; the DTOs; `openapi.json`.
- [x] **BE tests:**
  - every backend matrix row, in `test/returns.spec.ts`;
  - `test/support/dispatched-order.ts`, extracted from `cold-chain.spec.ts` and adopted there.
- [x] **FE:**
  - `api:generate` and the capability mirror (44);
  - `lib/returns.ts`, `lib/use-returns.ts`, `components/returns/*`;
  - the order-detail Create form;
  - the `/returns` page and navigation (13);
  - `AUDIT_TARGET_LABEL`;
  - tests for every web item.
- [x] **Meta docs:**
  - `docs/design/modules/returns.md` (new);
  - `outbound.md` and `catalog.md` (the new facade reads);
  - API-SURFACE (routes, the 44th capability, codes);
  - SYSTEM-DESIGN (module map and counts);
  - `frontend/SYSTEM-DESIGN.md` (route map, Returns, nav 13);
  - both repo contracts;
  - PENDING: a returns section covering no window, no portal, no amend, catch-weight and batch bound at 13-2, the 500-serial cap, and the tenant-wide list; plus the outbound read-back note.

**Acceptance Criteria:**
- Given a dispatched order, when an ops manager authorizes part of it on the web, then `RMA-NNNN` appears on `/returns` with its lines, and the order's returnable quantities drop accordingly.
- Given every backend suite, when it runs, then `assertEveryKeyAudited` passes.
- Given the full BE and FE suites, lint, typecheck, build and the capability-mirror check, when run, then they pass.

## Implementation Notes

Built on wms-be `feat/13-1-return-authorization` (`0312a88..60ad8d7`) and wms-fe on the same branch (`1b4c4c2..ca0c54b`), each one commit with its code-review patch. Re-verified 2026-10-16: BE 85 suites / 2009 tests, lint, typecheck; FE 1537 tests, lint, typecheck, capability mirror (44), `next build`.

Implemented 2026-10-16 on `feat/13-1-return-authorization` in wms-be and wms-fe (uncommitted at hand-off).

- **Problem extension members are top-level on the wire.** `ProblemDetailsFilter` spreads `extensions` beside the standard members, so `exceeds-returnable` carries `orderLineId` + `returnableQty` and the serial codes carry `orderLineId` + `serialNumber` at the top level; the web reads them as `ApiProblem.extensions` (what makes "N left" and "Serial X" renderable without parsing prose).
- **`OrderInvoiceFacts` gained `clientId` as well as `externalEventId`.** The spec named only `externalEventId`, but the facts carried `clientSystemOwned`, not the client id the RMA must store. Both additive; invoicing reads fields by name, so nothing it stores changes.
- **The returnable computation lives in `return-authorization.command.ts`** (`returnableFactsInTx` / `readReturnableInTx`) and the facade calls it — the command needs it under the order lock and the facade wraps the command, so a facade-owned function would have been a circular import. Same rule, one definition.
- **A kit parent's `dispatchedQty` reads 0** (its components carry the picks); a non-dispatched order reads 0 dispatched on every line, whatever it picked.
- **The web quantity input has no `max`**: native constraint validation would block a submit the server must be allowed to refuse (the on-screen returnable may be stale). Caught by the component test.
- **Cancel takes no order lock** — a create racing a cancel refuses conservatively (PENDING).
- Verification: `test/returns.spec.ts` (23 tests, every backend matrix row; the same-key race mutation-checked by deleting the replay under the lock), `architecture.spec.ts` (new returns block with detector self-tests), `client-isolation.spec.ts` (policy count 107 → 109), `users.spec.ts` (44); FE `returns.test.ts`, `components/returns/returns.test.tsx` (mutation-checked: the status gate, the key clear on a 409), `client.test.ts`, `navigation.test.ts`, `users.test.ts`, `audit.test.ts`.

## Spec Change Log

## Review Triage Log

Design review (2026-10-16), two lenses: backend (K) and web/API/tests (W). 30 findings, merged into 22 rows below.

| # | Lens | Finding | Verdict | Disposition |
|---|---|---|---|---|
| 1 | K | "Serials" was ambiguous. The ledger's `serialRef` is `serials.id`; no batch id↔number seam exists | high (verified: `pick.command.ts:846-849`, `catalog.facade.ts:564`) | Fixed: the request carries numbers; the store holds `serial_ids`; `serialIdentitiesInTx`; the DTO gives `{id, serialNumber}` |
| 2 | K, W | `orderReference` didn't exist | high (verified: `schema.ts:2247-2300`) | Fixed: snapshot `order_reference` = `external_event_id`; a web fallback rule |
| 3 | W | The routes used a non-existent `/orders` root | high (verified: `outbound.controller.ts:75-418`) | Fixed: every route under `/returns`; `returnable?orderId=`; the route order pinned |
| 4 | K, W | `validation-failed` is a 400 here, and the shape checks sat behind the replay | high (verified: about 210 sites at 400) | Fixed: 400; shape checks above the transaction; an error table |
| 5 | W | Serial arrays had no upper limit (a 5,000-unit line) | high | Fixed: 500 per line and per request; `returnableSerials` only; filter and select-all |
| 6 | K | The module needs seams the spec didn't name; a third dispatched-quantity query | high (verified: `outbound.facade.ts:522-628`) | Fixed: reuse `orderInvoiceFactsInTx`; `CatalogFacade.skuFactsInTx` |
| 7 | K, W | No source named for the dispatch instant | medium (verified: no column) | Fixed: the earliest `dispatch.dispatched` `occurredAt` |
| 8 | K, W | The kit parent arm contradicted itself; the read had no `parentLineId` | medium | Fixed: a 400 `kit-parent-not-returnable` before the bound; `parentLineId` in the read |
| 9 | W | Error codes departed from existing ones (`not-found`, `line-not-of-order`, transition-invalid) | medium (verified) | Fixed: existing codes reused |
| 10 | K | Catch-weight cases unaddressed | medium (verified: `schema.ts:898-913`) | Fixed: quantity only; 13-2 binds the cases (PENDING) |
| 11 | K | Batch identity deferred implicitly | medium | Fixed: stated; 13-2 binds the batch at the scan |
| 12 | K | The ownership block claimed a read guard that doesn't exist | medium (verified: `architecture.spec.ts:233-250`) | Fixed: a new read guard with detector self-tests |
| 13 | W | No change event; reusing `OUTBOUND_CHANGED_EVENT` would reset the orders table | medium (verified: `:540-551`) | Fixed: `RETURNS_CHANGED_EVENT`; a 409 reloads |
| 14 | W | The panel had no capability, and a fetch on expand would break the existing stubs | medium (verified: `:764-772`, test `:94-150`) | Fixed: `canManageReturns` threaded down; fetch on open |
| 15 | W | Navigation count, position and monogram unspecified | medium (verified: `navigation.ts:69`) | Fixed: 13; after Reports; a unique monogram; ungated |
| 16 | W | The Returns list had no warehouse scope | medium | Fixed: an optional `warehouseId` filter; the web uses the active warehouse |
| 17 | K | Reserving `partially_received\|received\|closed` froze 13-2/13-3 vocabulary | low | Fixed: `open\|cancelled` only; later stories widen it |
| 18 | K | Cancel hash and guard order unstated; the lock helper must not check status | low | Fixed |
| 19 | K | Text normalisation, `externalReference` uniqueness, serial order in the hash | low | Fixed: trimmed; blank = absent; not unique (deliberate); serials sorted |
| 20 | K | No index for the list | low | Fixed: `(tenant, warehouse, created_at, id)` |
| 21 | K | Outbox event names broke the `<doc>.<verb>` pattern | low | Fixed: `return_authorization.created/.cancelled` |
| 22 | W | Race-test template wrong; seeding helpers buried in one suite; audit vs outbox order; Cancel shape; quantity type; `AUDIT_TARGET_LABEL`; the guard on every route | low | Fixed: advisory-lock template, exported key; seeding extracted; §1 order; inline cancel; JSON numbers; the label; every route guarded |

Code review (2026-10-16), three layers: blind hunter (B), edge-case hunter (E), verification gap (V). About 30 findings; the same claim from several layers shares one row.

| # | Layer | Finding | Verdict | Disposition |
|---|---|---|---|---|
| 1 | E | UUID case is not normalised. An uppercase `orderId` takes a different advisory lock from the lowercase form, so concurrent creates can over-authorize. It also misses the ledger text filter (500 at `dispatchedAt`). Uppercase `orderLineId`s fail the line map and slip past the duplicate check | high (verified: the lock key and the ledger filter compare strings) | Patch: lowercase `orderId`, `orderLineId` and `rmaId` at the DTO edge (`@Transform`) and again in the command |
| 2 | B, E, V | Lines are ordered by `(created_at, id)`, which relies on `uuidv7()` being monotonic, and it is not across a sequence wrap | medium (verified: `ids.ts:15-21` bumps `now` but not `lastMs`) | Patch: a `line_no` column in 0072, ordered by it. The primitive's bug is deferred (`deferred-work.md`) |
| 3 | B | Catch-weight lines are not held to whole cases (`catchWeightTracked` is read but unused); the pick path refuses fractions | medium (verified: `pick.command.ts:809`) | Patch: 400 `validation-failed` for a fractional catch-weight quantity; a test |
| 4 | B, E | The web keeps refused serials and stale quantities in the draft after a 409 reload, so the same 409 repeats with no way to uncheck | medium | Patch: after a reload, prune the draft to `returnableSerials` and drop lines whose `returnableQty` is 0 |
| 5 | B, E | A cancel mints a new key per click, so a lost response followed by a retry reports "Not cancelled" for a committed cancel | medium | Patch: a key per confirmation, reused on retry until success |
| 6 | V | No route is tested against a foreign tenant's token (the only ownership check on the reads) | medium (test gap) | Patch: a foreign-tenant sweep of all five routes, expecting 403 `permission-denied` (`receiving.spec.ts:1595`) |
| 7 | V | Cancel key reuse with a different body is never tested for 422 | medium (test gap) | Patch: different `rmaId` and different reason, each expecting 422 |
| 8 | V | The list's cursor test can't see microsecond loss (no same-millisecond rows) | medium (test gap) | Patch: a same-millisecond tie case (`portal.spec.ts:892`) |
| 9 | V | The `returns.manage` threading into `OutboundOrders` and `ReturnsSessioned` is untested; a dropped prop silently hides Create for every role | medium (test gap) | Patch: render with the role, expand, assert the button (ops_manager present, operator absent); Cancel by role |
| 10 | E | `serialNumbers: []` on a non-serial line is refused | low | Patch: empty means absent |
| 11 | B, E | A serial id the catalog can't resolve is shown as its UUID | low | Patch: throw a data fault, like every other impossible case |
| 12 | B, E | The 500-serials-per-request cap isn't mirrored on the web | low | Patch: mirror it in `parseReturnDraft` |
| 13 | B | No index for the tenant-wide list | low | Patch: `(tenant_id, created_at, id)` in 0072 |
| 14 | B | The returnable read runs one serial query per line | low | Patch: batch by SKU, as `rmaDetailsInTx` does |
| 15 | B | `returnLinesSummary` adds quantities across different UoMs ("5.5 units") | low | Patch: show the line count and the SKU count, never summed units |
| 16 | E | The cancel confirmation hides silently when its row leaves the page | low | Patch: clear the confirm state when its target disappears |
| 17 | B | The portal-token and conflict arms, and cancel-then-re-authorize of one serial, are untested | low | Patch: cancel-then-re-authorize one serial. The portal fence is covered by `portal.spec.ts`'s route reflection (verified by V) |
| 18 | B | A serial's current status (since restocked, or re-dispatched elsewhere) is not checked | low | Rejected: 13-1 authorizes against this order's dispatch history; 13-2 checks the physical unit at receipt. Noted in PENDING |
| 19 | B | A line that became serial-tracked after dispatch would be stuck (no dispatched serials) | maybe-false, would be low (the catalog likely forbids changing serial tracking on a SKU with history; settle by checking `sku.command.ts`) | Rejected (low) |
| 20 | B | The order detail doesn't list existing RMAs; no deep link to the new RMA | low | Rejected: 13-4's returns queue |
| 21 | B | No return-window decision recorded | false: human decision 4 (no window in 13-1); `order_dispatched_at` is kept for a later window | Rejected |

## Design Notes

**Why returnable is computed, not stored.** Dispatched quantity already has one definition, Σ `picks.qty`, and it is reused here, not copied. Already-authorized quantity is a sum over this module's own rows. A stored "returnable" column would be a second source of truth, free to drift. The per-order advisory lock makes the computed bound safe under concurrency.

**Why an order-scoped lock.** A create has no existing row to lock. ASN and PO creates lose same-key races to a 409 for exactly that reason (PENDING cross-cutting). The advisory lock serialises both over-authorization and same-key creates, and the replay under it turns the loser into a replay.

**Why serial numbers in, serial ids stored.** People and scanners speak serial numbers. The ledger speaks `serials.id` (`serial_ref`). Storing the ids keeps 13-2's scan check and 13-3's restock on the ledger's own key. Resolving through `CatalogFacade` keeps the `serials` table catalog's.

## Verification

**Commands** (BE runs one jest invocation at a time):
- `cd workspace/core/backend/wms-be && bun run test -- test/returns.spec.ts` -- expected: all pass.
- `cd workspace/core/backend/wms-be && bun run test && bun run lint && bun run typecheck` -- expected: green.
- `cd workspace/core/frontend/wms-fe && bun test && bun run lint && bun run typecheck && bun run check:capability-mirror && bun run build` -- expected: green.
