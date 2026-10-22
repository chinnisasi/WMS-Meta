---
title: '4-1b client order number — a per-client order reference set at staff and portal create, shown and searchable wherever an order is named'
type: 'feature'
created: '2026-10-23'
status: 'ready-for-dev'
route: 'dispatch'
review_loop_iteration: 0
context:
  - 'docs/initiatives/production-readiness.md'
  - 'docs/design/SYSTEM-DESIGN.md'
  - 'docs/design/IMPLEMENTATION-GUIDE.md'
  - 'docs/design/API-SURFACE.md'
  - 'docs/design/PENDING.md'
  - 'docs/design/modules/outbound.md'
  - 'docs/design/modules/clients.md'
  - 'docs/design/frontend/SYSTEM-DESIGN.md'
  - 'docs/design/frontend/IMPLEMENTATION-GUIDE.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** Orders have no client-facing number (PENDING). A client says "where is order SO-1042?", and the warehouse sees only a ULID or, for channel orders, a marketplace id. Staff and portal orders carry nothing the client recognises, and no list can be searched by it.

**Approach:**
- A nullable `orders.client_order_ref`, **unique per client** (migration 0088), set optionally at **staff create** (`createOrder`, manual) and **portal create** (`placePortalOrder`).
- One label rule everywhere an order is named: **`client_order_ref` ?? channel `external_event_id` ?? short id**.
- An exact-match **search** on the staff and portal order lists.

**Decisions (recommended, taken autonomously under the user's standing instruction, 2026-10-23; revised by the design review):**
1. **Split.** The CSV/Excel order import is 4-1c (deferred-work).
2. **Shape.**
   - Optional and trimmed. **Blank, or spaces only, reads as absent.**
   - The CHECK is `client_order_ref IS NULL OR client_order_ref ~ '^[!-~]([ -~]{0,62}[!-~])?$'`: 1–64 printable ASCII characters, with no space first or last.
   - Kept case-sensitive, and the search is case-sensitive too (accepted: client systems are case-exact).
   - The DTO is `@IsOptional @IsString` only; the shape check runs in the command behind the replay lookup (the 8-1d precedent).
3. **Uniqueness among live orders.**
   - Unique index on `(tenant_id, client_order_ref, client_id) WHERE client_order_ref IS NOT NULL AND status <> 'cancelled'`.
   - **A cancelled order frees its number.** Cancel-and-re-create is the only way to fix any order field.
   - A duplicate is 409 `duplicate-client-order-ref`. The check runs in phase 1 **after `client-departed` and before the licence checks**. A concurrent duplicate maps to the same 409 through `isUniqueViolationOn` on the insert, and its grants are released.
   - Accepted cost: two different keys racing on one ref both reserve until the loser's rollback.
4. **Channel orders do not set it.**
   - An `ingested` create carrying `clientOrderRef` is 400. It is refused next to the channel-refs refusal, `order.command.ts:391`.
   - The marketplace `orderRef` stays `external_event_id`, the label's second arm.
5. **Create-only.** No amend (no order edit command exists; PENDING).
6. **Hashing** (the 8-1d rule).
   - The normalised ref joins the staff payload hash and the portal hash only when present, right after the legal name. It is carried in `OrderHashStage` and threaded through `placePortalOrder`'s rebuilt command.
   - The existing goldens are unchanged; new goldens pin the ref.
   - Stored replay answers (`OrderDto`, `PackDto`, `DispatchDto`, the portal placed response) declare `clientOrderRef` as `required: false, nullable`. Older stored snapshots lack it, and readers treat an absent value as null.
7. **Label rule.** `clientOrderRef ?? externalEventId ?? shortOrderId`, where **`shortOrderId` = the last 8 characters of the id** in both repos (BE `right(id::text,8)`; FE `id.slice(-8)`, pinned against each other).
   - **The backend exposes the raw fields** (`clientOrderRef`, `externalEventId`) and the web composes the label:
     - staff order DTOs (list entry, detail, pack, dispatch);
     - the portal row and detail (a raw `clientOrderRef`; `externalRef` unchanged);
     - `PortalPlacedOrderResponse`;
     - invoice line records (the pick and order arms, through `pickRecordsInTx` and `orderRefsInTx`);
     - the outbound register (a new `client_order_ref` column right after `channel_order_ref`).
   - **The wind-down blocker label** becomes `coalesce(client_order_ref, external_event_id, right(id::text,8))`.
   - **New RMAs** store `order_reference = coalesce(client_order_ref, external_event_id)`, so it stays null otherwise. It comes through `OrderInvoiceFacts`; the preview and the insert change together, and the schema comment is updated.
   - **Not changed (PENDING):** carrier label `orderRef`, the tax invoice's order reference, handheld screens, picklists, manifests, and the wave-detail order list.
8. **Search.** One param, **`reference`**, on staff `GET …/outbound/orders` (an orders-only query DTO subclass, so manifests and waves don't advertise it) and on portal `GET portal/orders`.
   - **Match:** an exact match of `client_order_ref` OR `external_event_id`, trimmed, ≤ 64 characters (longer is 400). The short id is not searchable (PENDING).
   - **Scope:** the staff search is warehouse- and client-filter-scoped as the list is; the portal search is the session's client.
   - **Index:** 0088 also adds `(tenant_id, external_event_id, client_id) WHERE external_event_id IS NOT NULL`, so the channel arm doesn't scan, proved by an `EXPLAIN` in the test.
9. **Copy.**
   - Staff 409: "{ref} is already used by another live order of this client — find it with the search, or use a different number (a cancelled order frees its number)."
   - Portal 409: "Order number {ref} is already used by one of your open orders — use a different number." It echoes only the user's input.

## Boundaries & Constraints

**Always:**
- **Migration 0088** follows IMPLEMENTATION-GUIDE §3 (guard, CHECK, two partial indexes, probes for 64 accepted and 65, a control character and a leading space refused; journal and snapshot; `db:generate` clean). Both indexes are built non-concurrently (the 0081 precedent), with a CONCURRENTLY runbook in PENDING.
- **The portal never sees or finds another client's ref.**
- **The web validates the ref shape** before minting a key (a shared `parseClientOrderRef`), and blank sends no key.

**Never:**
- No backfill; no ref on ingested orders.
- No amend; no import (4-1c).
- No carrier, invoice, handheld, picklist or manifest label change.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|---|---|---|---|
| Staff create with ref | ACME, `clientOrderRef: "SO-1042"` | stored; list, detail, pack and register show `SO-1042` | — |
| Portal create with ref | ACME session, `" SO-7 "` | stored `SO-7`; the placed banner and list show `SO-7` | — |
| No ref, or spaces only | as today | label falls back; hashes byte-identical (goldens) | — |
| Duplicate live | ACME has an open `SO-1042` | — | 409 `duplicate-client-order-ref` |
| Re-use after cancel | ACME's `SO-1042` cancelled | the new order takes `SO-1042` | — |
| Same ref, other client | BETA `SO-1042` | accepted | — |
| Concurrent duplicate | two keys racing on one ref | exactly one order row; one 409; grants released | — |
| Bad shape | 65 characters; a control character | — | 400 `validation-failed` |
| Ingested with ref | `source: ingested` + `clientOrderRef` | — | 400 |
| Search | staff `?reference=SO-1042`; `?reference=AMZ-9` (channel); portal `?reference=SO-7` | each order found; BETA's never in ACME's portal | over 64 characters → 400 |
| Replay | same key and body; same key with a different ref | the cached result; 422 | — |

</frozen-after-approval>

## Code Map

### Backend (`workspace/core/backend/wms-be`)

**Schema and migration**
- `drizzle/0088_order_client_ref.sql` (new; the 0087 conventions): the column; `orders_client_order_ref_shape_check`; `orders_client_order_ref_live_unique` (partial, not cancelled); `orders_external_event_client_idx` (partial). `schema.ts` (`orders` ~:2903) gains them. `COUNT`-style probes as in 0087.

**`src/modules/outbound/order.command.ts`**
- **Commands:** `CreateOrderCommand` (~:175) and `PlacePortalOrderCommand` (:230) gain `clientOrderRef?`.
- **Shape and hashing:** normalisation and the shape check in the shared validation phase (behind the replay). Both hashes (`:448-468`, `:561-570`) spread it after the legal name, only when present.
- **Duplicate check:** an existence check in phase 1 (client-scoped, any status) → 409. The insert catch (~:1246) maps `orders_client_order_ref_unique` → the same 409 and releases grants (the dedup-loser release precedent).
- Ingest never passes it (assert).

**DTOs and controllers**
- `outbound.dto.ts`: `CreateOrderDto.clientOrderRef?` and `PortalCreateOrderDto` (`src/api/portal.dto.ts`) `clientOrderRef?`.
- The response DTOs listed in decision 7, optional and nullable.
- An orders-only list query subclass with `reference?`, plus `ListOrdersFilter.reference` (facade `:147`); `PortalOrdersQuery.reference?`.
- `OrderInvoiceFacts` (facade `:277`, `:573`) gains `clientOrderRef`; `pickRecordsInTx` (`:1338`) and `orderRefsInTx` (`:1360`) select it.

**Readers**
- `outbound.facade.ts` `listOrders` (:726-760) and the detail, pack and dispatch snapshots select it.
- `portal-orders.ts:62` adds `reference` (the label) and the `reference` filter.
- `client-wind-down.ts:26` label.
- `invoice-records.ts:379,404` + `client-invoices.dto.ts`.
- `return-authorization.command.ts:630,842` (`coalesce(client_order_ref, external_event_id)`, the preview and the insert together; schema comment at `:5678`).
- `outbound-register.ts:99` + `registers.ts`: the column after `channel_order_ref`; update the positional assertions in `test/registers.spec.ts` (`:588`, `:635`).

**Tests**
- `test/order-client-ref.spec.ts` (new): every matrix row, the race, portal isolation (BETA cannot find ACME's ref), the readers' labels, the CHECK and index probes.
- New goldens with a ref in `test/issuance-gate-parity.spec.ts` and `test/portal-orders-create.spec.ts`; the existing goldens unchanged.
- The registers header golden is updated.

### Web (`workspace/core/frontend/wms-fe`)

**Staff (`components/outbound/outbound-orders.tsx`)**
- **Create form:** a "Client order number (optional)" input between Client and Ship-to (an `edit*` wrapper clears the key; blank sends no key).
- **Orders table:** the "Order" column shows `orderLabel(order)` with the short id beneath.
- **Search:** an exact-match search box driving `clientOrderRef`.
- **Detail panel:** a header with the label.

**Portal (`components/portal/portal-orders.tsx`)**
- **Place order form:** a "Your order number (optional)" input.
- **Orders list:** the "Reference" column reads `reference`, and a search box drives `reference`.

**`src/lib/orders.ts` (new): `orderLabel`, `shortOrderId` (last 8) and `parseClientOrderRef`** — used:
- in the staff table, detail header, cancel confirm (`outbound-orders.tsx:734`), ledger link label (`:830`) and create banner (`createOutcome`);
- in the waves order picker (`outbound-waves.tsx:373, 553`);
- in the pack/dispatch list (`pack-dispatch.tsx:167`);
- in the portal list (`orderReference` → `clientOrderRef ?? externalRef ?? 'Manual'/'Channel'`) and the placed banner;
- in billing line-records (`invoice-records.ts:86`; the header and CSV column "Channel ref" are renamed "Order");
- in returns (`returnOrderLabel` falls back to `shortOrderId`);
- in the drill banner (`drill.ts:565`, moving to `shortOrderId`).

**The staff search box:** hidden while drilled; a change clears the cursor and enters the table key. An empty result names the warehouse and the active client, with a show-all-clients hint (the `hiddenByClientFilterNote` precedent). The page-scoped status select is unchanged.

**Mappers:** `duplicate-client-order-ref` copy in `lib/outbound-orders.ts` `createReason` and `lib/portal.ts` `portalOrderReason`.

**Other:** regenerate the client.

### Mobile

None (PENDING: handheld order labels).

## Tasks & Acceptance

**Execution:**
- [ ] BE: migration 0088 (probes), the command (both arms), the DTOs, the readers, the search filters; OpenAPI; tests.
- [ ] Web: staff form, table, search and detail; portal form, list and search; `orderLabel`; mappers, plus tests; regenerated client.
- [ ] Meta docs:
  - `API-SURFACE.md` (recount from openapi);
  - `outbound.md` (the ref, the label rule, the `orderRefsInTx` note `:579`);
  - `clients.md` (portal);
  - frontend SYSTEM-DESIGN;
  - READMEs;
  - PENDING: close "Orders have no client-facing number" (`:311`); add an amend, the carrier, handheld, picklist and manifest labels, and a CONCURRENTLY index runbook; 4-1c.

**Acceptance Criteria:**
- Given ACME places order `SO-1042` in the portal, when a staff user searches `SO-1042` on Outbound, then that order is found and labelled `SO-1042` in the list, its detail, the pack list, the billing records and the outbound register.
- Given ACME already has `SO-1042`, when anyone creates another ACME order with `SO-1042`, then it is refused 409 and nothing is reserved.

## Design Notes

- **Why not copy the channel ref.** `external_event_id` is the ingest dedup and writeback identity, unique per integration. A per-client uniqueness on it could fail an ingest on a cross-connection collision; the label rule shows it anyway.
- **Why the index puts the ref before the client.** One partial unique index serves both the per-client duplicate check and the warehouse-scoped staff search (the list is per warehouse; the client is a further filter).

## Verification

**Commands:**
- `bun run test -- test/order-client-ref.spec.ts test/issuance-gate-parity.spec.ts test/portal-orders-create.spec.ts test/orders.spec.ts test/registers.spec.ts test/invoice-records.spec.ts test/returns*.spec.ts` (wms-be, run alone): pass.
- `bun run db:generate` reports no changes; `bun run lint && bun run typecheck` (wms-be, wms-fe); `bun test` (wms-fe): pass.

## Implementation Notes

## Spec Change Log

## Review Triage Log

Design review, 2026-10-23 (backend B, web W). Every accepted finding is folded into the spec above; all choices are recommended, taken autonomously.

| ID | Verdict | Finding → resolution |
|---|---|---|
| B1 | high | A cancelled order burned its number, though cancel-and-re-create is the only fix path. The index excludes cancelled orders (decision 3). |
| W1 + B7 | high | Staff search missed channel orders; the portal channel arm had no index. One `reference` param matching both columns; a new partial index; `EXPLAIN`. |
| W2 | high | Search interplay with the client filter, drill and cursor was unspecified. Code Map: search box rules. |
| W3 | high | The portal `reference` showed an unseen short id. Raw `clientOrderRef`, composed on the web. |
| B2 | medium | Racing duplicates both reserve. Accepted cost; the test asserts one row and a 409. |
| B3 | medium | Guard order unstated. After `client-departed`, before the licence checks. |
| B4 | medium | Ingest assert location; hash-stage and portal threading. 400 at `:391`; `OrderHashStage`; the rebuilt command. |
| B5 | medium | Stored snapshots lack the field. Optional, nullable; absent reads as null. |
| B6 + W10 | medium | `OrderListQuery` is shared. Orders-only subclass. |
| B8 + W9 | medium | RMA label changed a stored column's meaning. `coalesce(client_order_ref, external_event_id)`, null otherwise; facts named. |
| W4 | medium | Partial labelling. Five more cheap screens added; the rest in PENDING. |
| W5 + B10 | medium | The short id was undefined, and the two repos disagree. Last 8 in both, pinned. |
| W6 | medium | "Channel ref" headers become wrong. Renamed "Order". |
| W7 | medium | No client-side validation. A shared `parseClientOrderRef`. |
| W8 | medium | Duplicate copy unwritten. Decision 9. |
| B9 | low | Invoice-record sources and the tax invoice reference. Named; the tax invoice is in PENDING. |
| B11 | low | Matrix vs decision 2; CHECK and search caps. Fixed. |
| B12 | low | Register column position. After `channel_order_ref`; assertions listed. |

