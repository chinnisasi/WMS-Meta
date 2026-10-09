# Clients module

> The 3PL scoping dimension inside the tenant (AD-23): who owns the goods in the building — one system-owned `self` client per tenant for D2C, one row per external client brand from story 21-2b onward.

Paths are relative to `workspace/core/backend/wms-be`. Read [`../IMPLEMENTATION-GUIDE.md`](../IMPLEMENTATION-GUIDE.md) first — the command skeleton, migration checklist and vocabulary pattern below are assumed, not repeated.

Story 21-1 stood up the table and the `self` client; 21-2 added the `app.client_id` RLS clause; **21-2b gave it an admin surface and made attribution real**: owners register and rename client brands, a catalog import names the client its new SKUs belong to, and orders, purchase orders and every ledger movement take their client **from their SKUs**. Status transitions (suspend/depart) and deletion are still absent (PENDING). **21-7 adds the client portal**: a fifth role `client` paired with `users.client_id`, a portal session token carrying `client_id`, the operator fence, and `PortalSessionGuard` + ten read-only `portal/` routes — see *The client portal* below.

---

## Owns

| Table | Holds | Key invariants |
|---|---|---|
| `clients` (`src/shared/db/schema.ts`, the `clients` table) | One row per client of a tenant: `code`, `name`, `status`, `system_owned` | Exactly **one system-owned client per tenant** — partial unique `clients_tenant_system_owned_unique` (0040). `code` unique per tenant (`clients_tenant_id_code_unique`). `status` CHECK ∈ {`active`,`suspended`,`departed`}, `system_owned ⇒ NOT departed` (0040). **Since 0059:** `clients_code_format` — `code ~ '^[A-Z0-9][A-Z0-9-]{1,31}$' OR system_owned` (codes stored UPPERCASE, `self` exempt); `clients_self_code_reserved` — `code` is never `SELF`/`self` unless system-owned; `clients_name_length` — `char_length(btrim(name))` 1..200 (the tenant name's own cap, because `self` mirrors it). Vocabulary mirrored in `src/modules/clients/clients.schema.ts` (`CLIENT_STATUSES`, `CLIENT_CODE_RE`, `CLIENT_NAME_MAX`, `MAX_CLIENT_LIST`). **Since 0062 (21-5) — the tax details:** seven nullable columns `legal_name`, `gstin`, `billing_line1`, `billing_line2`, `billing_city`, `billing_state_code`, `billing_pincode`; CHECKs `clients_legal_name_format` (1..200, trimmed), `clients_gstin_format` (`^[0-9]{2}[A-Z0-9]{13}$`), `clients_billing_address_format` (the address ceilings, a 2-digit state code, a 6-digit pincode), `clients_gstin_matches_billing_state` (`left(gstin, 2) = billing_state_code` when both are set) |

`catalog_imports.client_id` (NOT NULL since 0059, backfilled to each tenant's `self`) is catalog-owned but is this module's concept: the client a run imported for.

RLS: `clients_tenant_isolation` carries the `app.client_id` clause on `id` (21-2, `drizzle/0041_client_isolation_rls.sql`), as do the four stamped tables' policies on `client_id`. The probe is `test/client-isolation.spec.ts` (pure SQL, `wms_rls_probe`).

## API (story 21-2b)

| Route | Capability | Arms |
|---|---|---|
| `GET /tenants/{t}/clients` | member-open | every client, any status, `system_owned` first then by code; unpaginated, bounded at 500 |
| `POST /tenants/{t}/clients` `{code, name}` | `clients.manage` (owner-only) | 201 `{client}`, code trimmed + uppercased, `active`; 400 `validation-failed` (shape, or the reserved `SELF`); 409 `duplicate-client-code` (sequential or concurrent — the unique index is the arbiter); 403 `role-denied`; 422 `idempotency-key-reuse` |
| `PATCH /tenants/{t}/clients/{clientId}` `{name}` | `clients.manage` | 200 `{client}` (an unchanged name writes and audits nothing); 400 for the `self` client (its name mirrors the tenant); 404 unknown/foreign id; 400 malformed id |
| `PATCH /tenants/{t}/clients/{clientId}/tax-details` (21-5) | **`billing.invoice`** (owner + accountant) | `{legalName?, gstin?, billingLine1?, billingLine2?, billingCity?, billingStateCode?, billingPincode?}` — absent = unchanged, `null` or blank = cleared → 200 `{client}` (every client read now carries `taxDetails`); 400 `validation-failed` for a malformed GSTIN or one whose prefix is not a registration code, a state code off `GSTIN_STATE_CODES`, a GSTIN in another state than the billing state (checked over the MERGED values), a bad pincode, an over-long field, or the `self` client (never invoiced); 404 unknown; an unchanged patch writes and audits nothing |
| `POST /tenants/{t}/catalog/skus/{skuId}/client` `{clientId}` | `clients.manage` | catalog-owned — see `catalog.md`: `200 {skus}` (every SKU moved — the group); 409 `sku-has-history` naming the member with history |

Commands: `ClientsCommand.create` / `.rename` / (21-5) `.updateTaxDetails` (`src/modules/clients/clients.command.ts`) follow the house skeleton — normalise + hash before the tx; authority → replay → shape validation → write → audit (`client.created` / `client.renamed` / `client.tax-details-updated`, target type `client`, reference = the Idempotency-Key) → key LAST. **No outbox event** — nothing consumes a client's existence yet.

## The seams

- `ensureSelfClientInTx(tx, tenantId, opts?)` (`ensure-self-client.ts`) — idempotent, identity `tenant_id + code='self' + system_owned`. Since 21-2b it is called by **registration** (`{selfClientName: tenant.name}`) and by the **catalog import** when the tenant has only its own client and none was named. **It is no longer how writers stamp `client_id`** — the "every writer calls `ensureSelfClientInTx`" rule of 21-1 is retired; see attribution below.
- `clients.facade.ts` — the read seam, file-level `…InTx` functions on the caller's transaction (the `ensureReceivingBinInTx` shape) plus the injectable `ClientsFacade.listClients`:
  - `assertClientInTenantInTx` → 404 `not-found`
  - `getClientsInTx` (bulk `{id, code, systemOwned}`), `getClientLabelsInTx` (bulk id → refusal label: a client's code, the tenant's own as "<tenant name> (your company)" — never `self`), `listClientsInTx`
  - `lockClientInTx` (21-3) — the client row `FOR UPDATE` plus its status, 404 when absent: billing's rate-card activate/cancel serialise every dated transition of one client on it (a lock, never a write); `getClientStatusInTx` is the unlocked read the draft create uses. 21-5's client-invoice prepare, refresh and issue lock it too (client row → invoice row)
  - `getClientInTx` (21-5) — one client's full snapshot including `taxDetails`, 404 when absent: the recipient a client invoice prints
  - `assertSingleClientInTx(tx, tenant, clientIds, subject)` — **the one attribution rule**: one distinct client or 409 `mixed-client` naming the codes (`mixedClient()`)

## The client portal (story 21-7)

A client brand's own user signs in and reads its stock, orders, inbound documents and invoices — read-only (decision 2; portal ASN entry is 21-7b), isolated by the database.

**The persona.** A fifth role, `client` (`ROLE_CAPABILITIES.client` = ∅), paired with `users.client_id` by the 0065 CHECK `("role"::text = 'client') = ("client_id" IS NOT NULL)`. Only an owner invites one: `POST /users {email, role: 'client', clientId}` — guard order authority → replay → client checks (the client read by tenant AND id → 404; the tenant's own `self` → 400; not `active` → 409 `client-not-active`); `clientId` without `role: client`, or the reverse, is 400 above the transaction. The invite fingerprint adds `clientId` only when present (the 8-1d conditional key, after `role`). A role change never assigns `client` (`ASSIGNABLE_ROLES`) and never changes a client user (400). The client user is refused at device badge-in (403 `role-denied`, after the PIN check, nothing bound).

**The session.** Sign-in of a client user checks its client is `active` AFTER the password (403 `client-suspended`; a wrong password stays 401) and mints a token carrying `client_id`; the body adds `user.clientId` and `client {id, code, name}`. The fence (`TenantSessionGuard`, `AnySessionGuard`'s web arm) refuses that token on every operator route — 403 `role-denied`, `This is an operator surface.` (`IMPLEMENTATION-GUIDE.md` §7e).

**`PortalSessionGuard`** (`portal-session.guard.ts`, provided + exported by `ClientsModule`; the api shell imports `SharedModule` so its `DATABASE` resolves) admits only a `client_id` token, and per request — in `withTenantTransaction(db, t, …, { clientId })`, never `AUTH_DATABASE` — re-reads the user (`getMemberPortalFactsIn`: missing / not active / another client → 401) and the client (`readSessionClientIn`: not active → 403 `client-suspended`), then parks `{userId, tenantId, clientId}` for `@CurrentPortalSession()`.

**The reads** (`src/api/portal.controller.ts`, all `GET /tenants/{t}/portal/…`, each its owning module's facade method taking `(tenantId, clientId, query)`):

| Route | Facade | Notes |
|---|---|---|
| `portal/me` | `ClientsFacade.portalMe` | `{user {id, email, role, status, clientId}, client {id, code, name}}` |
| `portal/stock` | `InventoryFacade.portalStock` (`inventory/portal-stock.ts`) | per (SKU, warehouse): `onHand` over every bin, `allocated` = held/committed order reservations; each side pre-aggregated then FULL-joined (no fan-out, allocated-only rows kept); keyset `(skuCode, warehouseId)`, its own codec |
| `portal/orders`, `/{id}` | `OutboundFacade.portalOrders` / `portalOrder` | `lineCount` counts top-level lines; detail nests kit components; `skus` LEFT-joined |
| `portal/inbound/asns`, `/{id}`; `portal/inbound/purchase-orders`, `/{id}` | `InboundFacade.portalAsns` / `portalAsn` / `portalPurchaseOrders` / `portalPurchaseOrder` | no vendor, cost or note |
| `portal/invoices`, `/{id}` | `BillingFacade.portalInvoices` / `portalInvoice` | non-draft only; no note, gaps, warnings, card or line ids; the party without `warehouseCode` / recipient `code` |

Two layers, both required and both proved: the transaction stamp (RLS — the `wms_rls_probe` arms in `test/client-isolation.spec.ts` Part 3, which run **copies** of the portal SQL with the client predicate removed — the stock read (on-hand and order reservations, through `skus`), the order, ASN and PO header lists, the order-line, ASN-line and PO-line reads (through their header), and the invoice header and invoice-line reads (drafts hidden by the policy alone)) and the explicit `client_id = $client` predicate (the HTTP tests in `test/portal.spec.ts`, whose suite is RLS-inert). `test/architecture.spec.ts` pins the stamp on every portal facade read, and that `users.client_id` is written only by the invite insert. Lists: `(created_at desc, id)` keysets over the full-precision instant, limit 1–100, `invalid-cursor` 400; a malformed order/ASN/PO id is 400 and a malformed invoice id 404 (each operator route's convention); an unknown or foreign id is 404.

## Attribution (story 21-2b) — derived, never chosen

The SKU is the source of truth. Everything else **derives** its client:

| Writer | Rule | Refusal |
|---|---|---|
| Catalog import (`catalog/import.command.ts`) | the run's client: the named `clientId` (404 behind the replay if unknown); a fix-mode re-run **inherits** its original run's client (naming another → 400); with >1 client and none named → 400 `client-required`; else `self` | per-row `mixed-client` in the product pass and the kit pass |
| SKU correction (`catalog/sku-client.command.ts`) | owner-only; moves the SKU's **whole group** (the closure over kit partners and product siblings) as one, **only while every member has no history** — ledger events, order / PO / transfer lines, pending adjustments, count task lines, batches, serials, reservations or channel mappings — checked under the product lock and the group's SKU row locks; a no-op writes nothing; one audit row per SKU, reference `from <client> → to <client> (key …)` | 409 `sku-has-history` naming the member; 409 `conflict` if the group changed under the locks |
| Order create (`outbound/order.command.ts`) | the lines' and kit components' SKUs, after the kit-component assertion and after the channel dedup pre-check | 409 `mixed-client`, before any grant |
| PO create / amend (`inbound/po.command.ts`) | create derives from the lines; the carried successor copies the original's; amend refuses another client's line | 409 `mixed-client` |
| Ledger append (`inventory/ledger.service.ts` `appendMovement`) | the SKU's `client_id`, read by tenant + id in the append's own transaction | a missing SKU throws a loud internal `Error` — **never falls back to `self`** |
| Kit API / SKU PATCH (`catalog/kit.command.ts`, `sku.command.ts`) | a kit and its components, and a product's variants, share one client | 409 `mixed-client` |
| Channel mappings PUT (`channels/channels.command.ts`) | a connection's mapping set is single-client | 409 `mixed-client` |
| Channel ingest (`channels/channels.ingest.command.ts`) | a FIRST delivery's mapped SKUs spanning clients is a mapping fault (a redelivery of an accepted order skips the pre-check and replays); the order command's kit-component `mixed-client` maps to the same refusal | 422 `ingest-config-invalid`, metered `validation-failed` |

`test/architecture.spec.ts` pins: only the clients module writes `clients`; `clients.command.ts` and the ensure really write it; the ledger reads `skus.clientId` and no longer calls `ensureSelfClientInTx`; **only `sku-client.command.ts` updates `skus.client_id`** (Drizzle `.update(skus).set({…clientId…})`, patch-object assignment, raw SQL).

**Tax details are `billing.invoice`'s, not `clients.manage`'s** (21-5 design review #7): the accountant who clears an invoice's recipient gaps must be able to fix them; the owner holds both. A client's tax details are live — an issued client invoice prints its frozen `party`, never these columns.

Invoicing: a client brand's order is **not GST-invoiced** (decision 5) — `orderInvoiceFactsInTx` carries `clientSystemOwned`; the generator refuses 409 `client-order-not-invoiced`, which the dispatch delivery handler acks with a log line. See `invoicing.md`.

## The stamping rule (AD-24 placement)

`client_id` is a **selective denormalisation** — explicit NOT NULL columns only where queries filter/aggregate without joining through the SKU: `skus`, `orders`, `purchase_orders`, `ledger_events` (billing aggregates over it constantly). Nullable by design: `bins.dedicated_client_id` (attribute, not scope) and `users.client_id` (null = tenant staff, set = portal user — since 21-7 set exactly when `role = 'client'`, the 0065 `users_client_role_pairing` CHECK, written only by the invite insert). Tables referencing a SKU — stock, reservations, picks, order lines, GRN lines — inherit and get **no column**; their client isolation rides on the join through `skus`. The first `client_id` index is 21-4's `ledger_events (tenant_id, client_id, warehouse_id, recorded_at)` (0061) for billing's fold and counts; the order/PO/SKU lists still have none (their client filters are PENDING).

## Gotchas (the ones that caused real defects, or nearly did)

- **`event_hash` does not include `clientId`** — the chain is unchanged by the client dimension (0040 byte-identity in `test/client-dimension.spec.ts`; ACME events recompute to their stored hash in `test/clients.spec.ts`). Adding it would rewrite every historical hash; don't.
- **The import fingerprint gains `clientId` only when present** (the 8-1d conditional-key exception, after `mode`) — an import without it hashes byte-for-byte as before; pinned by a golden test in `test/clients.spec.ts`.
- **Codes are uppercase, `self` is not.** A direct-SQL fixture inserting a lowercase non-system code now fails the 0059 CHECK (23514) — `test/client-isolation.spec.ts` seeds `BRAND-B`, `PROBE-*`.
- **SKU codes and barcodes stay unique across the tenant** (decision 2) — an existing code under any client is `duplicate-sku-code`, whose detail now names the owner client.
- **Residual race (PENDING):** the SKU correction locks the SKU row and re-checks history, but order/PO creation does not lock SKU rows; a correction committing between an order's preflight read and its write could leave that order on the SKU's old client.
- **The ledger backfill needed the append-only trigger dance** (0040) — any future migration that UPDATEs the ledger repeats it.
- **Nothing can suspend a client yet** — `suspended` is reachable only by SQL. Since 21-7 two paths DO branch on it: a client user's sign-in and every portal request (403 `client-suspended`), and the client-user invite (409 `client-not-active`) — PENDING: status transitions and departure.
- **`users.client_id` is immutable by construction (21-7)** — never add an `.update(users)` that touches it: the session token's `client_id` claim mirrors it for 15 minutes, and the architecture scan fails the build.
