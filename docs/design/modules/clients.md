# Clients module

> The 3PL scoping dimension inside the tenant (AD-23): who owns the goods in the building — one system-owned `self` client per tenant for D2C, one row per external client brand from story 21-2b onward.

Paths are relative to `workspace/core/backend/wms-be`. Read [`../IMPLEMENTATION-GUIDE.md`](../IMPLEMENTATION-GUIDE.md) first — the command skeleton, migration checklist and vocabulary pattern below are assumed, not repeated.

Story 21-1 stood up the table and the `self` client; 21-2 added the `app.client_id` RLS clause; **21-2b gave it an admin surface and made attribution real**: owners register and rename client brands, a catalog import names the client its new SKUs belong to, and orders, purchase orders and every ledger movement take their client **from their SKUs**. Deletion is still absent (AD-16); **21-10 adds suspend and reactivate** — see *Suspension* below; **1-2a adds the client master record** — contacts, the registered and return addresses, and **departure** (offboarding) with its wind-down check and the "no new work" gate — see *Contacts and addresses* and *Departure* below. **21-7 adds the client portal**: a fifth role `client` paired with `users.client_id`, a portal session token carrying `client_id`, the operator fence, and `PortalSessionGuard` + ten read-only `portal/` routes — see *The client portal* below. **21-7b makes it read-mostly plus ASN**: the portal's first write, `POST portal/inbound/asns`, and the two reads its form needs.

---

## Owns

| Table | Holds | Key invariants |
|---|---|---|
| `clients` (`src/shared/db/schema.ts`, the `clients` table) | One row per client of a tenant: `code`, `name`, `status`, `system_owned` | Exactly **one system-owned client per tenant** — partial unique `clients_tenant_system_owned_unique` (0040). `code` unique per tenant (`clients_tenant_id_code_unique`). `status` CHECK ∈ {`active`,`suspended`,`departed`}, `system_owned ⇒ NOT departed` (0040). **Since 0059:** `clients_code_format` — `code ~ '^[A-Z0-9][A-Z0-9-]{1,31}$' OR system_owned` (codes stored UPPERCASE, `self` exempt); `clients_self_code_reserved` — `code` is never `SELF`/`self` unless system-owned; `clients_name_length` — `char_length(btrim(name))` 1..200 (the tenant name's own cap, because `self` mirrors it). Vocabulary mirrored in `src/modules/clients/clients.schema.ts` (`CLIENT_STATUSES`, `CLIENT_CODE_RE`, `CLIENT_NAME_MAX`, `MAX_CLIENT_LIST`). **Since 0062 (21-5) — the tax details:** seven nullable columns `legal_name`, `gstin`, `billing_line1`, `billing_line2`, `billing_city`, `billing_state_code`, `billing_pincode`; CHECKs `clients_legal_name_format` (1..200, trimmed), `clients_gstin_format` (`^[0-9]{2}[A-Z0-9]{13}$`), `clients_billing_address_format` (the address ceilings, a 2-digit state code, a 6-digit pincode), `clients_gstin_matches_billing_state` (`left(gstin, 2) = billing_state_code` when both are set) |

| `client_contacts` (1-2a, `drizzle/0077_client_master_record.sql`) | A client's contacts: `name`, `email`, `phone`, `roles text[]`, `is_primary` | `email = lower(btrim(email))`, unique `(client_id, email)`; `roles` ⊆ {`operations`,`billing`,`returns`} with no duplicates (empty = a general contact; `CLIENT_CONTACT_ROLES`); name 1..120 trimmed; phone ≤ 20; **exactly one primary while any exist** — the partial unique `client_contacts_one_primary_unique (client_id) WHERE is_primary` (non-deferrable: the command moves the primary in two statements). At most 20 per client (the command's 409 `contact-limit`). RLS: the tenant arm **plus the 0041 `app.client_id` clause on `client_id`** (a portal-stamped transaction reads only its own client's — no portal route reads contacts; defence in depth) |

**Since 0078 (1-2b) — the receiving policy on `clients`:** `receiving_tolerance_bps` (integer NOT NULL default 0, CHECK 0–10000 — `clients_receiving_tolerance_range`), `qc_on_receipt` and `expiry_required` (boolean NOT NULL default false), `min_shelf_life_days` (integer NULL, CHECK 1–3650 — `clients_min_shelf_life_range` — and only beside `expiry_required` — `clients_min_shelf_life_needs_expiry`). The defaults reproduce the pre-1-2b receipt exactly; every client carries one, `self` included. Ranges mirrored in `clients.schema.ts` (`RECEIVING_TOLERANCE_BPS_MAX`, `MIN_SHELF_LIFE_DAYS_MIN/MAX`). See *Receiving policy* below.

**Since 0077 (1-2a) — the two address groups on `clients`:** `registered_line1/line2/city/state_code/pincode` (the 21-5 billing shapes: a two-digit GST registration state code, a six-digit pincode) and `return_contact_name/phone/line1/line2/city/state/pincode` (the shipment shape, `AddressInput`). Each group is all-or-none with `line2` optional — `clients_registered_address_format`, `clients_return_address_format`. The migration also re-adds `sessions_revoked_reason_check` with `client-departed`, and probes every new CHECK and index.

`catalog_imports.client_id` (NOT NULL since 0059, backfilled to each tenant's `self`) is catalog-owned but is this module's concept: the client a run imported for.

RLS: `clients_tenant_isolation` carries the `app.client_id` clause on `id` (21-2, `drizzle/0041_client_isolation_rls.sql`), as do the four stamped tables' policies on `client_id`. The probe is `test/client-isolation.spec.ts` (pure SQL, `wms_rls_probe`).

## API (story 21-2b)

| Route | Capability | Arms |
|---|---|---|
| `GET /tenants/{t}/clients` | member-open | every client, any status, `system_owned` first then by code; unpaginated, bounded at 500 |
| `POST /tenants/{t}/clients` `{code, name}` | `clients.manage` (owner-only) | 201 `{client}`, code trimmed + uppercased, `active`; 400 `validation-failed` (shape, or the reserved `SELF`); 409 `duplicate-client-code` (sequential or concurrent — the unique index is the arbiter); 403 `role-denied`; 422 `idempotency-key-reuse` |
| `PATCH /tenants/{t}/clients/{clientId}` `{name}` | `clients.manage` | 200 `{client}` (an unchanged name writes and audits nothing); 400 for the `self` client (its name mirrors the tenant); 404 unknown/foreign id; 400 malformed id |
| `PATCH /tenants/{t}/clients/{clientId}/tax-details` (21-5) | **`billing.invoice`** (owner + accountant) | `{legalName?, gstin?, billingLine1?, billingLine2?, billingCity?, billingStateCode?, billingPincode?}` — absent = unchanged, `null` or blank = cleared → 200 `{client}` (every client read now carries `taxDetails`); 400 `validation-failed` for a malformed GSTIN or one whose prefix is not a registration code, a state code off `GSTIN_STATE_CODES`, a GSTIN in another state than the billing state (checked over the MERGED values), a bad pincode, an over-long field, or the `self` client (never invoiced); 404 unknown; an unchanged patch writes and audits nothing |
| `PATCH /tenants/{t}/clients/{clientId}/status` (21-10; 1-2a) | `clients.manage` | `{status: active\|suspended\|departed}` → 200 `{client}`; 400 `validation-failed` (any other status, a malformed id, or the `self` client); 409 `client-not-active` (departed → suspended: a departed client can only be reactivated); **409 `client-not-wound-down`** with `blockers: [{kind, count, codes?}]` (a departure while work remains — see *Departure*); 404 unknown/foreign; 422 key reuse. A same-status request writes and audits nothing but **stores the key**; a refused departure stores none |
| `PATCH /tenants/{t}/clients/{clientId}/addresses` (1-2a) | `clients.manage` | `{registered?, return?}` — a group absent is unchanged, `null` clears it, a value replaces it whole → 200 `{client}`; 400 `validation-failed` naming the field (`registeredAddress.stateCode` off the registration list, a pincode, a missing field, a ceiling); 404. An unchanged patch is a no-op that **stores the key** (`clients.addresses:unchanged`). Allowed on the self client and on a departed one |
| `GET /tenants/{t}/clients/{clientId}/receiving-policy` (1-2b) | any staff session — never the portal | `{clientId, receivingToleranceBps, qcOnReceipt, expiryRequired, minShelfLifeDays, untrackedSkuCount}` (the count composed in the api shell through `CatalogFacade.countUntrackedSkus` — clients never imports catalog); 404 |
| `PUT /tenants/{t}/clients/{clientId}/receiving-policy` (1-2b) | `clients.manage` | a FULL replace of the four fields → 200 `{client}`; 400 `validation-failed` naming the field; 404; 422. An unchanged policy is a no-op that **stores the key** (`clients.receivingPolicy:unchanged`). Allowed on the self client and on a departed one |
| `GET /tenants/{t}/clients/{clientId}/contacts` (1-2a) | any staff session (decision 6) — never the portal | `{items}` — the primary first, then by name, then by id (≤ 20); 404 unknown/foreign. Contacts are **not** on the clients list payload |
| `POST /tenants/{t}/clients/{clientId}/contacts` (1-2a) | `clients.manage` | `{name, email, phone?, roles?}` → 201 `{contact}` (the first contact becomes primary); 400 `validation-failed` naming the field (email by the shared `isEmailAddress`, phone by `assertPhone`, a role off the list or repeated); 409 `contact-limit` (a 21st), `duplicate-contact-email` (another case of the same email included) |
| `PATCH /tenants/{t}/clients/{clientId}/contacts/{contactId}` (1-2a) | `clients.manage` | `{name?, email?, phone?, roles?, isPrimary?}` — absent unchanged, `phone: null` clears; `isPrimary: true` moves the primary (clear the old, then set — two statements, one transaction); `isPrimary: false` is 400; 409 `duplicate-contact-email`; 404. An unchanged edit is a no-op that **stores the key** (`clients.contactEdit:unchanged`) |
| `DELETE /tenants/{t}/clients/{clientId}/contacts/{contactId}` (1-2a) | `clients.manage` | 200 `{contact}` (the removed one); 409 `primary-contact-required` (the primary while others remain — the last contact can go); 404 |
| `POST /tenants/{t}/catalog/skus/{skuId}/client` `{clientId}` | `clients.manage` | catalog-owned — see `catalog.md`: `200 {skus}` (every SKU moved — the group); 409 `sku-has-history` naming the member with history |

Commands: `ClientsCommand.create` / `.rename` / (21-5) `.updateTaxDetails` / (21-10) `.updateStatus` (`src/modules/clients/clients.command.ts`) follow the house skeleton — normalise + hash before the tx; authority → replay → shape validation → write. **`create` takes no row lock and replays once** (a concurrent duplicate code is settled by the unique index). **`rename`, `updateTaxDetails` and `updateStatus` lock the client row `FOR UPDATE` after the first replay and replay again under the lock** before any guard (rename since 21-11a — there only for the skeleton's sake: its no-op arm already answered a parked same-key duplicate identically). Writes → audit (`client.created` / `client.renamed` / `client.tax-details-updated` / `client.suspended` / `client.reactivated`; since 1-2a `client.departed`, `client.addresses_updated`, `client.contact_added` / `contact_edited` / `contact_removed`; since 1-2b `client.receiving_policy_updated` — every one targets the client; target type `client`, reference = the Idempotency-Key) → key LAST. **No outbox event** — nothing consumes a client's existence yet.

**Lock modes (1-2a).** The status command keeps the client row **`FOR UPDATE`**. Every other client writer — rename, tax details, contacts, addresses, and billing's `lockClientInTx` (rate-card activate/cancel, client-invoice prepare/refresh/issue) — takes **`FOR NO KEY UPDATE`**, and the "no new work" gate takes **`FOR KEY SHARE`**. So a long invoice prepare never queues a client's order creates (KEY SHARE does not conflict with NO KEY UPDATE), while a departure (UPDATE) serialises against every in-flight creation (it conflicts with KEY SHARE). Pinned by `test/client-master.spec.ts` ("lock modes").

## The seams

- `ensureSelfClientInTx(tx, tenantId, opts?)` (`ensure-self-client.ts`) — idempotent, identity `tenant_id + code='self' + system_owned`. Since 21-2b it is called by **registration** (`{selfClientName: tenant.name}`) and by the **catalog import** when the tenant has only its own client and none was named. **It is no longer how writers stamp `client_id`** — the "every writer calls `ensureSelfClientInTx`" rule of 21-1 is retired; see attribution below.
- `clients.facade.ts` — the read seam, file-level `…InTx` functions on the caller's transaction (the `ensureReceivingBinInTx` shape) plus the injectable `ClientsFacade.listClients`:
  - `assertClientInTenantInTx` → 404 `not-found`
  - `getClientsInTx` (bulk `{id, code, systemOwned}`), `getClientLabelsInTx` (bulk id → refusal label: a client's code, the tenant's own as "<tenant name> (your company)" — never `self`), `listClientsInTx`
  - `lockClientInTx` (21-3) — the client row `FOR UPDATE` plus its status, 404 when absent: billing's rate-card activate/cancel serialise every dated transition of one client on it (a lock, never a write). Since 21-10 the draft create reads status through `shareLockClientInTx` (below); the old unlocked status read (`getClientStatusInTx`) was deleted in 21-11a, so no create-gate can reach for it. 21-5's client-invoice prepare, refresh and issue lock it too (client row → invoice row)
  - `shareLockClientInTx` (21-10) — the same facts under `FOR SHARE`, 404 when absent: the gates that CREATE something under a client and refuse a non-active one (the rate-card draft, the portal announce, the portal-user invite) read status through it, so a suspend (`FOR UPDATE`) cannot commit between their read and their insert. Lock order: the client first, then documents — nothing locks a card or an ASN before its client. There is no unlocked status read on the seam any more (`getClientStatusInTx` was removed in 21-11a)
  - `getClientInTx` (21-5) — one client's full snapshot including `taxDetails`, 404 when absent: the recipient a client invoice prints
  - `assertSingleClientInTx(tx, tenant, clientIds, subject)` — **the one attribution rule**: one distinct client or 409 `mixed-client` naming the codes (`mixedClient()`)
  - `assertClientTakesWorkInTx(tx, tenant, clientId)` (1-2a) — **the "no new work" gate**: the client row `FOR KEY SHARE`, 404 when absent, **409 `client-departed`** when departed. A suspended client still takes work (decision 5). Run first in the transaction, before any document or advisory lock (see *Departure* for its callers)
  - `departedClientsInTx(tx, tenant, clientIds)` (1-2a) — the departed ones among `clientIds` (id → label), under the same `FOR KEY SHARE`: the receipt's per-line refusal
  - `departedClientIdsInTx(tx, tenant)` (1-2a) — every departed client, unlocked: the replenishment sweep and the expiry scan skip their SKUs
  - `clientInactive(status)` (1-2a) — the portal's refusal for a non-active client: 403 `client-departed` ("Your company's account with the warehouse has ended") for a departed one, 403 `client-suspended` otherwise — sign-in, `PortalSessionGuard`, portal `me` and the portal announce use it
  - `ClientsFacade.listClientContacts(tenant, client)` (1-2a) — the contacts read (staff only)

## The client portal (story 21-7)

A client brand's own user signs in and reads its stock, orders, inbound documents and invoices, isolated by the database — read-only in 21-7 (decision 2), and since 21-7b **read-mostly plus ASN**: it may announce its own inbound shipment (see *Portal ASN entry* below).

**The persona.** A fifth role, `client` (`ROLE_CAPABILITIES.client` = ∅ in 21-7, `{asn.announce}` since 21-7b), paired with `users.client_id` by the 0065 CHECK `("role"::text = 'client') = ("client_id" IS NOT NULL)`. Only an owner invites one: `POST /users {email, role: 'client', clientId}` — guard order authority → replay → client checks (the client read by tenant AND id → 404; the tenant's own `self` → 400; not `active` → 409 `client-not-active`); `clientId` without `role: client`, or the reverse, is 400 above the transaction. The invite fingerprint adds `clientId` only when present (the 8-1d conditional key, after `role`). A role change never assigns `client` (`ASSIGNABLE_ROLES`) and never changes a client user (400). The client user is refused at device badge-in (403 `role-denied`, after the PIN check, nothing bound).

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

Two layers, both required and both proved: the transaction stamp (RLS — the `wms_rls_probe` arms in `test/client-isolation.spec.ts` Part 3, which run **copies** of the portal SQL with the client predicate removed — the stock read (on-hand and order reservations, through `skus`), the order, ASN and PO header lists, the order-line, ASN-line and PO-line reads (through their header), and the invoice header and invoice-line reads (drafts hidden by the policy alone)) and the explicit `client_id = $client` predicate (the HTTP tests in `test/portal.spec.ts`, whose suite is RLS-inert). `test/architecture.spec.ts` pins the stamp on every portal facade read, and that `users.client_id` is written only by the invite insert. **Since 21-11a it also scans `portal.controller.ts` itself**: the injected fields are pinned (field → facade class), every `this.<field>.<method>(` call — multi-line and optional calls included — must be a `PORTAL_READS` method of that field's class or a declared delegation (`clients.portalMe → portalMeIn`, `inbound.announceAsn → AsnCommand.announce`, each asserted to be a single `return <target>(…);`), and every `this.<field>` must be called on the spot (no alias, destructure or pass-through). A new portal route therefore cannot call an unstamped operator read and pass the build. Lists: `(created_at desc, id)` keysets over the full-precision instant, limit 1–100, `invalid-cursor` 400; a malformed order/ASN/PO id is 400 and a malformed invoice id 404 (each operator route's convention); an unknown or foreign id is 404.

**Portal ASN entry (story 21-7b).** Three routes join the ten:

| Route | Owner | Notes |
|---|---|---|
| `POST portal/inbound/asns` | `InboundFacade.announceAsn` → `AsnCommand.announce` | the portal's ONLY write (an exact allowlist in `test/portal.spec.ts`'s guard-coverage test). Body `{warehouseId, asnCode, expectedAt?, lines[{skuId, announcedQty}]}` — a `clientId` or a line `id` is 400 (`forbidNonWhitelisted`). The client is the session's. `Idempotency-Key` required. 201 is the bare `PortalAsnDetail` (the `portal/inbound/asns/{id}` shape, not `{asn}`). Capability `asn.announce`; the command re-reads the user and the client in its own client-stamped transaction (401 / 403 `role-denied` / 403 `client-suspended`) — `IMPLEMENTATION-GUIDE.md` §7e. 404 for an unknown warehouse or a SKU that is unknown or another client's (the same detail — never confirming the other's), 409 `kit-cannot-hold-stock` / `duplicate-asn-code` / `conflict`, 422 `idempotency-key-reuse` (including an operator create's key — the portal fingerprint carries `surface: 'portal'`) |
| `portal/skus` | `CatalogFacade.portalSkus` | every non-kit SKU of the client `{skuId, skuCode, skuName, baseUom, uomPrecision}`, keyset `(code, id)`, limit 1–100 |
| `portal/warehouses` | `TenancyService.portalWarehouses` | every warehouse of the tenant (decision 1) `{warehouseId, warehouseName, city}` by `(name, id)`, unpaginated (≤ 200) |

Decisions (2026-10-09): any warehouse of the tenant; announce only — no portal amend, close or cancel (the 3PL cancels a mistaken notice; portal cancel is PENDING); no origin marker — the `asn.created` audit row's actor (the client user) is the only record that an ASN came from the portal (an operator badge is PENDING); no portal write cap (accepted risk, PENDING). The result is an ordinary ASN: operators, the device snapshot and receiving treat it exactly as one an operator keyed. The whole announce write set (header, line, key, audit, outbox, read-back) is proved admitted under a client stamp as `wms_rls_probe` (`test/client-isolation.spec.ts`, 21-7b block, with a 42501 positive control), and `test/architecture.spec.ts` pins the command's `{ clientId: command.clientId }` stamp.

## Suspension (story 21-10)

An owner moves a client brand between `active` and `suspended` — `PATCH clients/{c}/status`, `ClientsCommand.updateStatus`, and the Settings row actions Suspend / Reactivate. Since 1-2a the same command departs a client (see *Departure*): `CLIENT_STATUS_TARGETS = ['active', 'suspended', 'departed']`, one tuple for the DTO `@IsIn`, its OpenAPI enum and the command's own shape check.

**Order:** status shape (400, above the tx) → hash `{arm: 'status', tenantId, clientId, status}` (pinned by a golden; unchanged by 1-2a) → `clients.manage` → replay → id shape → lock the client `FOR UPDATE` (404) → replay again under the lock → `self` (400) → departed → suspended (409 `client-not-active`) → same status: a no-op that **writes the key** → (departure only) the wind-down check (409 `client-not-wound-down`) → update `status`, `updatedAt` → the portal sessions end (suspend: `client-suspended`; depart: `client-departed`) → audit → key. No outbox event.

**Why the no-op stores its key, unlike rename:** a status is not idempotent in value. After someone else reactivates, a late retry of a stored no-op "suspend" must replay the stored answer — never suspend again.

**What it stops** — exactly the gates that already read status, per request (the portal token carries only `client_id`, §7e), so it bites on the next call and reactivation restores access at once:

| Gate | Answer while suspended |
|---|---|
| `PortalSessionGuard` — every portal call, incl. invoices and the service report | 403 `client-suspended` (the web portal signs out to `/login?portal=suspended`) |
| Portal sign-in, portal `me` | 403 `client-suspended` |
| Portal ASN announce | 403 `client-suspended` (re-read in its own transaction, under `FOR SHARE`) |
| Portal-user invite | 409 `client-not-active` (under `FOR SHARE`) |
| Rate-card draft (under `FOR SHARE`) and activation (under the client lock — `FOR NO KEY UPDATE` since 1-2a) | 409 `client-not-active` |

**What it does not stop** (decision 1, reaffirmed by 1-2a decision 5 — a suspended client still ships): operator work — orders, receipts, picks, dispatch — and billing behave as for an active client; the web order form offers a suspended client again. Open ASNs stay open (decision 2); an operator can still cancel any. Since 6-1a the suspension ends the client's portal sessions at once (`client-suspended`); a reactivation restores none. No per-user status.

## Contacts and addresses (story 1-2a)

**Contacts** are a list with roles (decision 3): each has a name, an email (stored trimmed and lower-cased; one shared `isEmailAddress`, the class-validator rule, in the DTO and the command), an optional phone (`assertPhone`, extracted from `assertAddress`: trimmed, ≤ 20) and any of `operations` / `billing` / `returns` (none = a general contact). Exactly one is primary while any exist: the first contact becomes primary, `PATCH {isPrimary: true}` moves it (clear the old, then set — the partial unique index is not deferrable), and the primary cannot be removed while others remain. The primary is listed first and is the default recipient of 5.2's client notifications. **All staff read** the list (decision 6) — never the portal, and never on the clients list payload; **owners write** (`clients.manage`). The self client may have contacts. Every write: keyed (`arm: contact-add` / `contact-edit` / `contact-remove`), locks the client `FOR NO KEY UPDATE` and replays again under it, audited against the client.

**Addresses** are two groups on the client row: the **registered** address (the billing shapes) and the **return** address (the shipment shape; 4.7's returns disposition consumes it). `PATCH …/addresses {registered?, return?}` (`arm: 'addresses'`, absent groups omitted from the hash — the conditional-key shape). `ClientDto` carries both, **required and nullable**; a stored snapshot from before 1-2a replays null-filled (the `taxDetails ?? {…nulls}` precedent, `clients.controller.ts`).

## Receiving policy (story 1-2b)

**What it is.** How the 3PL receives a brand's goods: an over-receipt **tolerance** in basis points (the API speaks bps; the web converts a percent by decimal string arithmetic, so `1.005` is a field error, never 100), **QC on receipt**, **expiry required** on batch-tracked SKUs and a **minimum remaining shelf life** in IST calendar days. Receiving side only: FEFO/FIFO allocation and minimum life to the customer are roadmap 4.3 (decision 1). The receipt rules themselves live in `inbound.md` §The client receiving policy.

**The write** — `ClientsCommand.updateReceivingPolicy`, the `updateAddresses` skeleton: hash `{arm: 'receiving-policy', tenantId, clientId, receivingToleranceBps, qcOnReceipt, expiryRequired, minShelfLifeDays}` → `clients.manage` → replay → `lockClientForEdit` (`FOR NO KEY UPDATE`, 404) → replay again → `assertReceivingPolicy` (400 naming the field) → unchanged: store the key, write nothing → update → audit `client.receiving_policy_updated` (target the client) → key. A full replace (a new DTO — never the addresses DTO's "omitted = unchanged").

**The reads.** `ClientSnapshot.receivingPolicy` (OPTIONAL on the type and `ClientDto` — a `ClientMutationSnapshot` stored before 1-2b replays without it; every fresh read carries it), `ClientsFacade.getReceivingPolicy`, the device snapshot's `clients[].receivingPolicy` (`snapshotClients` — absent on an older server: the handheld warns about nothing), and `receivingPoliciesInTx(tx, tenant, clientIds)` — the receipt's one read, beside `departedClientsInTx`, unlocked (read committed: no serialisation against an edit), before any document lock. `DEFAULT_RECEIVING_POLICY` is the policy of an id the read does not find.

## Departure (story 1-2a)

**The lifecycle:** active → departed and suspended → departed (once wound down); departed → active (reactivation, audited `client.reactivated`); departed → suspended refused 409 `client-not-active`; the self client never departs (400, with the 0040 `system_owned ⇒ NOT departed` CHECK as the second line). History, reports, metering and client invoices stay readable; invoices can still be prepared for usage before departure. No deletion (AD-16).

**The wind-down check** runs on departure only, under the row's `FOR UPDATE` and after the replay under it. Each module that owns a blocker exports a file-level `clientWindDownBlockersInTx(tx, tenantId, clientId)` in its own `client-wind-down.ts` (inventory, inbound, outbound, returns, tenancy, billing, channels), importing only `drizzle-orm` and `shared/` — never `modules/clients` — so the status command composes them with no import cycle (`clientWindDownBlockersInTx` in `clients.command.ts`; the type is `shared/primitives/wind-down.ts`; `test/architecture.spec.ts` pins the imports, and the five facade-only guards admit exactly `client-wind-down` as a declared seam). A blocker answers `409 client-not-wound-down` with `blockers: [{kind, count, codes?: string[] (≤ 5)}]`, in this order:

| Kind | Counts | Codes |
|---|---|---|
| `stock` | the client's SKUs with a non-zero `stock_on_hand` in ANY bin (Receiving, QC-HOLD, IN-TRANSIT and RETURNS included) | SKU codes |
| `open-purchase-orders` | POs `open` | PO codes |
| `open-asns` | ASNs `announced` / `partially_received` | ASN codes |
| `pending-over-receipts` | over-receipts `pending` on its SKUs, any document | GRN codes |
| `open-orders` | orders `accepted` / `ready_to_dispatch` | channel ref, else the id's last 8 |
| `open-rmas` | RMAs `open` / `partially_received` (`RECEIVABLE_RMA_STATUSES`) | RMA codes |
| `pending-adjustments` | stock adjustments `pending` on its SKUs (NOT the whole `ADJUSTMENT_PENDING_STATUSES` vocabulary, which also lists the decided states) | — |
| `open-counts` | count tasks `pending` counting its SKUs + count variances `open` on its SKUs | — |
| `open-review-items` | review-queue rows `open` of the SKU-naming op types whose payload names one of its SKUs — through each type's own JSON path (`skuId`, `lines[*].skuId`, `scanned[*].skuId`, `entries[*].skuId`), joined to `skus` by primary key (bounded: no payload text scan) | — |
| `unsettled-invoices` | client invoices `draft`, `issued` or `disputed` — only `settled` and `void` clear (decision 8) | number, else `YYYY-MM` |
| `channel-mappings` | channel mappings of its SKUs on any connection — the owner unmaps first (decision 9) | external refs |

Each status list is pinned against its owner's vocabulary by `test/client-master.spec.ts`. **A refused departure rolls back and stores no key**, so a retry after winding down re-runs the check.

**On departure:** the client's portal sessions end (`client-departed` — `SESSION_REVOKE_REASONS`, its CHECK, `SESSION_END_DETAIL`), audit `client.departed`. Portal sign-in, the portal guard, portal `me` and the announce answer **403 `client-departed`**; a suspended client keeps `client-suspended`.

**"No new work"** (decisions 2 and 7) — `assertClientTakesWorkInTx`, 409 `client-departed`:

The gate runs anywhere in the transaction **before its first write**. Its position relative to the caller's other locks is free: a departure locks only the client row and the wind-down reads take no row locks, so no caller lock can be waited on by a departure (callers take it after SKU, product, connection or advisory locks today).

| Path | Where |
|---|---|
| PO create | `inbound/po.command.ts` (after the client is derived, before the insert; the replenishment submit rides it) |
| ASN create (amend stays unguarded — an open ASN already blocks departure) | `inbound/asn.command.ts` |
| Staff ASN import — both client branches | `inbound/asn-import.command.ts`, a row error `client-departed` |
| Order create — phase 1 (an early exit) **and the top of the phase-3 write transaction** (the guard: phase 1 commits before phase 3 writes; a refusal there releases the grants through `releaseAll`) | `outbound/order.command.ts` |
| Channel ingest — a pre-check beside the mixed-client one, and a `mapIngestRejection` arm: 422 `validation-failed`, metered `validation-failed`, never a transient retry | `channels/channels.ingest.command.ts` |
| Channel mappings — the PUT (`channels.command.ts`) and the seed arm (`channels.publish.ts`) | channels |
| Catalog import — after the run's client is settled (named, fix-mode inheritance, or the `self` default) | `catalog/import.command.ts` |
| SKU client correction (the target), kit compose (POST/PUT), variant attach | `catalog/sku-client.command.ts`, `kit.command.ts`, `sku.command.ts` |
| RMA create — the order's client, before the per-order advisory lock | `returns/return-authorization.command.ts` |
| A positive adjustment, a pending adjustment's approval and a count variance's gain (decision 7) — the shared `assertAdjustableInTx` guard set, `quantityDelta > 0` | `inventory/inventory.command.ts` |

**Receipts.** A blind receipt NAMING a client is accepted whatever its status (code review): a suspended client receives (decision 5), and a departed one's lines are refused per line like any other (decision 7). Any receipt line whose SKU's client has departed — PO, ASN or blind, `clientId` sent or not — is refused **per line** `client-departed` (`REJECTED_GRN_LINE_CODES`), read under `FOR KEY SHARE` (`departedClientsInTx`), and goes to the `grn.lines-refused` review row (Discard only; problem code `client-departed` when any line is a departure). A receipt whose every line is refused takes the 1-1 `goodsReceipt: null` arm (`refusedReceipt.clientId` = the named client, else the first refused line's). The handheld names the line ("TSHIRT-M (Brand B): client has departed — not booked"), and a wholly refused receipt's note names its document — PO, ASN or blind (decision 10, `replay-classification.ts`).

**Replenishment:** the breach sweep never opens a breach (or draft PO) for a departed client's SKU, and **recovers a breach left open at departure** on its next pass; the expiry/aging scan raises no alert for one (its open alerts still resolve when their scope empties).

**Not guarded:** billing reads, metering, storage snapshots, client-invoice prepare and issue, reports, the ledger and audit. Rate-card draft and activation already refuse a non-active client.

**Accepted edges:** existing rate-card drafts can still be edited or discarded while suspended (those paths read no status) — harmless, because activation re-checks under its own lock (21-10 design review #14). An invite issued before the suspension can still be accepted, but that user cannot sign in until the client is reactivated (#16).

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

`client_id` is a **selective denormalisation** — explicit NOT NULL columns only where queries filter/aggregate without joining through the SKU: `skus`, `orders`, `purchase_orders`, `ledger_events` (billing aggregates over it constantly). Nullable by design: `bins.dedicated_client_id` (attribute, not scope) and `users.client_id` (null = tenant staff, set = portal user — since 21-7 set exactly when `role = 'client'`, the 0065 `users_client_role_pairing` CHECK, written only by the invite insert). Tables referencing a SKU — stock, reservations, picks, order lines, GRN lines — inherit and get **no column**; their client isolation rides on the join through `skus`. The first `client_id` index is 21-4's `ledger_events (tenant_id, client_id, warehouse_id, recorded_at)` (0061) for billing's fold and counts; **1-5a's 0081** adds `(tenant_id, client_id, warehouse_id, created_at, id)` on `purchase_orders`, `orders`, `goods_receipt_notes`, `return_authorizations` and `ledger_events` (each list's `(created_at, id)` keyset) plus `(tenant_id, client_id, created_at, id)` on `goods_receipt_notes` (the tenant-wide GRN list), `return_authorizations` (`GET /returns` without a warehouse), `skus` and `products` (the catalog lists; kits page over kit SKUs). **The GRN legacy arm is a separate branch:** a GRN matches by its own `client_id` OR (null `client_id` AND a line of the client's SKU); a single `OR … EXISTS` defeated the index, so the own and legacy arms are each keyset-ordered and limited to page + 1, and the page reads `id = any(array(own union all legacy))` — one InitPlan, the 0081 index on the own arm (proved by `EXPLAIN` in `test/client-filter.spec.ts`).

## The staff client filter (story 1-5a)

Every staff list and the stock and ledger reads take an optional `?clientId=` — the route list and the per-list matching rule are in `API-SURFACE.md` (conventions). Owned by each list's module; the shared predicates are `src/shared/db/client-filter.ts` (`skuOfClient`, `orderOfClient`, `anyOrderOfClient` — a `sku_id IN (the client's SKUs)` / order-id probe, **tenant-qualified** inside the subquery). Absent → the list's SQL is unchanged (`and(...)` drops `undefined`).

- **Server-side, before the limit, composable** (decision 5) — a client whose rows are all older than page 1 still fills page 1. Never a browser filter over a loaded page.
- **Unknown / other tenant → empty page, never 404; malformed → 400** (decision 6, the ASN precedent). A departed client stays filterable (decision 7).
- **Mixed rows match any client they touch** (decision 4): a wave, manifest, transfer or legacy null-client GRN appears under each of its clients; a wave with no lines matches none.
- **Partners, batches, write-side and lookup reads are never filtered** (decisions 10, 12, 13); wave-policies has its own DTO so `clientId` there is a `400` (`forbidNonWhitelisted`).
- **Putaway tasks** are derived and unpaged: `getPutawayTasks` (the HTTP wrapper) filters after derivation; the InTx callers (device snapshot, KPIs) are unchanged.
- **The web** holds the pick in one shell switcher, per tenant and user, outside the URL (`../frontend/SYSTEM-DESIGN.md`); drills, write-side screens and lookups ignore it.
- Proof: `test/client-filter.spec.ts` — a canonical route table (each route's filtered page equals exactly the client's rows of the unfiltered page, for two clients; unknown/foreign/malformed per route), the matrix rows, an `EXPLAIN` of the real orders, ledger, PO, GRN (warehouse and tenant-wide) and RMA SQL showing a 0081 index, and `limit=1` beyond-page-1 walks for one list per predicate shape (orders, variances, waves, invoices, backorder refusals, the legacy GRN arm).

## Gotchas (the ones that caused real defects, or nearly did)

- **`event_hash` does not include `clientId`** — the chain is unchanged by the client dimension (0040 byte-identity in `test/client-dimension.spec.ts`; ACME events recompute to their stored hash in `test/clients.spec.ts`). Adding it would rewrite every historical hash; don't.
- **The import fingerprint gains `clientId` only when present** (the 8-1d conditional-key exception, after `mode`) — an import without it hashes byte-for-byte as before; pinned by a golden test in `test/clients.spec.ts`.
- **Codes are uppercase, `self` is not.** A direct-SQL fixture inserting a lowercase non-system code now fails the 0059 CHECK (23514) — `test/client-isolation.spec.ts` seeds `BRAND-B`, `PROBE-*`.
- ~~**SKU codes and barcodes stay unique across the tenant** (decision 2)~~ — **since 1-1 they are unique per (tenant, client)** (0076; `catalog.md` §Per-client SKU identity). Product names stay tenant-unique until 1.4. A SKU code alone no longer names one SKU: read by id, or within a client.
- **The device snapshot's `clients` list** (1-1) is read through `ClientsFacade.snapshotClients` — `{id, code, name, active}` of every client a SKU or an open document of the snapshot references; inbound never reads the table.
- **Residual race (PENDING):** the SKU correction locks the SKU row and re-checks history, but order/PO creation does not lock SKU rows; a correction committing between an order's preflight read and its write could leave that order on the SKU's old client.
- **The ledger backfill needed the append-only trigger dance** (0040) — any future migration that UPDATEs the ledger repeats it.
- **Suspension since 21-10, departure since 1-2a** — an owner suspends, departs and reactivates through the one status command. A gate that refuses a non-ACTIVE client while creating something under it (the portal's gates) reads status through `shareLockClientInTx`; a gate that refuses only a DEPARTED client (operator work) uses `assertClientTakesWorkInTx`. Never an unlocked read (the old `getClientStatusInTx`, removed in 21-11a), which lets a status change commit between the read and the insert (21-10 design review #2).
- **The receiving policy is read, never locked (1-2b).** A receipt in flight while an owner edits the policy uses whichever version committed first; the over-receipt approve arm reads the policy current at approval. Decided, not a defect.
- **A new work-creating path must call `assertClientTakesWorkInTx`** — `test/architecture.spec.ts` lists the callers; a path left off it lets a departed client take new work silently. A new open-document vocabulary needs a wind-down blocker in its owner's `client-wind-down.ts`, or departure can strand it.
- **`users.client_id` is immutable by construction (21-7)** — never add an `.update(users)` that touches it: the session token's `client_id` claim mirrors it for 15 minutes, and the architecture scan fails the build.
