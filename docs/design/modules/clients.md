# Clients module

> The 3PL scoping dimension inside the tenant (AD-23): who owns the goods in the building — one system-owned `self` client per tenant for D2C, one row per external client brand from story 21-2b onward.

Paths are relative to `workspace/core/backend/wms-be`. Read [`../IMPLEMENTATION-GUIDE.md`](../IMPLEMENTATION-GUIDE.md) first — the command skeleton, migration checklist and vocabulary pattern below are assumed, not repeated.

Story 21-1 stood up the table and the `self` client; 21-2 added the `app.client_id` RLS clause; **21-2b gave it an admin surface and made attribution real**: owners register and rename client brands, a catalog import names the client its new SKUs belong to, and orders, purchase orders and every ledger movement take their client **from their SKUs**. Status transitions (suspend/depart), deletion and portal users are still absent (21-7 and PENDING).

---

## Owns

| Table | Holds | Key invariants |
|---|---|---|
| `clients` (`src/shared/db/schema.ts`, the `clients` table) | One row per client of a tenant: `code`, `name`, `status`, `system_owned` | Exactly **one system-owned client per tenant** — partial unique `clients_tenant_system_owned_unique` (0040). `code` unique per tenant (`clients_tenant_id_code_unique`). `status` CHECK ∈ {`active`,`suspended`,`departed`}, `system_owned ⇒ NOT departed` (0040). **Since 0059:** `clients_code_format` — `code ~ '^[A-Z0-9][A-Z0-9-]{1,31}$' OR system_owned` (codes stored UPPERCASE, `self` exempt); `clients_self_code_reserved` — `code` is never `SELF`/`self` unless system-owned; `clients_name_length` — `char_length(btrim(name))` 1..200 (the tenant name's own cap, because `self` mirrors it). Vocabulary mirrored in `src/modules/clients/clients.schema.ts` (`CLIENT_STATUSES`, `CLIENT_CODE_RE`, `CLIENT_NAME_MAX`, `MAX_CLIENT_LIST`) |

`catalog_imports.client_id` (NOT NULL since 0059, backfilled to each tenant's `self`) is catalog-owned but is this module's concept: the client a run imported for.

RLS: `clients_tenant_isolation` carries the `app.client_id` clause on `id` (21-2, `drizzle/0041_client_isolation_rls.sql`), as do the four stamped tables' policies on `client_id`. The probe is `test/client-isolation.spec.ts` (pure SQL, `wms_rls_probe`).

## API (story 21-2b)

| Route | Capability | Arms |
|---|---|---|
| `GET /tenants/{t}/clients` | member-open | every client, any status, `system_owned` first then by code; unpaginated, bounded at 500 |
| `POST /tenants/{t}/clients` `{code, name}` | `clients.manage` (owner-only) | 201 `{client}`, code trimmed + uppercased, `active`; 400 `validation-failed` (shape, or the reserved `SELF`); 409 `duplicate-client-code` (sequential or concurrent — the unique index is the arbiter); 403 `role-denied`; 422 `idempotency-key-reuse` |
| `PATCH /tenants/{t}/clients/{clientId}` `{name}` | `clients.manage` | 200 `{client}` (an unchanged name writes and audits nothing); 400 for the `self` client (its name mirrors the tenant); 404 unknown/foreign id; 400 malformed id |
| `POST /tenants/{t}/catalog/skus/{skuId}/client` `{clientId}` | `clients.manage` | catalog-owned — see `catalog.md`: `200 {skus}` (every SKU moved — the group); 409 `sku-has-history` naming the member with history |

Commands: `ClientsCommand.create` / `.rename` (`src/modules/clients/clients.command.ts`) follow the house skeleton — normalise + hash before the tx; authority → replay → shape validation → write → audit (`client.created` / `client.renamed`, target type `client`, reference = the Idempotency-Key) → key LAST. **No outbox event** — nothing consumes a client's existence yet.

## The seams

- `ensureSelfClientInTx(tx, tenantId, opts?)` (`ensure-self-client.ts`) — idempotent, identity `tenant_id + code='self' + system_owned`. Since 21-2b it is called by **registration** (`{selfClientName: tenant.name}`) and by the **catalog import** when the tenant has only its own client and none was named. **It is no longer how writers stamp `client_id`** — the "every writer calls `ensureSelfClientInTx`" rule of 21-1 is retired; see attribution below.
- `clients.facade.ts` — the read seam, file-level `…InTx` functions on the caller's transaction (the `ensureReceivingBinInTx` shape) plus the injectable `ClientsFacade.listClients`:
  - `assertClientInTenantInTx` → 404 `not-found`
  - `getClientsInTx` (bulk `{id, code, systemOwned}`), `getClientLabelsInTx` (bulk id → refusal label: a client's code, the tenant's own as "<tenant name> (your company)" — never `self`), `listClientsInTx`
  - `lockClientInTx` (21-3) — the client row `FOR UPDATE` plus its status, 404 when absent: billing's rate-card activate/cancel serialise every dated transition of one client on it (a lock, never a write); `getClientStatusInTx` is the unlocked read the draft create uses
  - `assertSingleClientInTx(tx, tenant, clientIds, subject)` — **the one attribution rule**: one distinct client or 409 `mixed-client` naming the codes (`mixedClient()`)

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

Invoicing: a client brand's order is **not GST-invoiced** (decision 5) — `orderInvoiceFactsInTx` carries `clientSystemOwned`; the generator refuses 409 `client-order-not-invoiced`, which the dispatch delivery handler acks with a log line. See `invoicing.md`.

## The stamping rule (AD-24 placement)

`client_id` is a **selective denormalisation** — explicit NOT NULL columns only where queries filter/aggregate without joining through the SKU: `skus`, `orders`, `purchase_orders`, `ledger_events` (billing aggregates over it constantly). Nullable by design: `bins.dedicated_client_id` (attribute, not scope) and `users.client_id` (null = tenant staff, set = portal user — **inert until 21-7**). Tables referencing a SKU — stock, reservations, picks, order lines, GRN lines — inherit and get **no column**; their client isolation rides on the join through `skus`. **No `client_id` indexes yet** (21-4).

## Gotchas (the ones that caused real defects, or nearly did)

- **`event_hash` does not include `clientId`** — the chain is unchanged by the client dimension (0040 byte-identity in `test/client-dimension.spec.ts`; ACME events recompute to their stored hash in `test/clients.spec.ts`). Adding it would rewrite every historical hash; don't.
- **The import fingerprint gains `clientId` only when present** (the 8-1d conditional-key exception, after `mode`) — an import without it hashes byte-for-byte as before; pinned by a golden test in `test/clients.spec.ts`.
- **Codes are uppercase, `self` is not.** A direct-SQL fixture inserting a lowercase non-system code now fails the 0059 CHECK (23514) — `test/client-isolation.spec.ts` seeds `BRAND-B`, `PROBE-*`.
- **SKU codes and barcodes stay unique across the tenant** (decision 2) — an existing code under any client is `duplicate-sku-code`, whose detail now names the owner client.
- **Residual race (PENDING):** the SKU correction locks the SKU row and re-checks history, but order/PO creation does not lock SKU rows; a correction committing between an order's preflight read and its write could leave that order on the SKU's old client.
- **The ledger backfill needed the append-only trigger dance** (0040) — any future migration that UPDATEs the ledger repeats it.
- **Nothing can suspend a client yet** — `suspended` is reachable only by SQL; no command branches on status (PENDING: status transitions and departure).
