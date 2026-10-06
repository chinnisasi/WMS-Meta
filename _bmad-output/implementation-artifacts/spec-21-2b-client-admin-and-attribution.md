---
title: 'Client admin and attribution — create clients, SKUs carry their client, orders and POs inherit it'
type: 'feature'
created: '2026-10-06'
status: 'ready-for-dev'
route: 'dispatch'
review_loop_iteration: 0
context:
  - '_bmad-output/implementation-artifacts/epic-21-context.md'
  - '_bmad-output/specs/spec-3pl/SPEC.md'
  - '_bmad-output/specs/spec-3pl/schema.md'
  - '_bmad-output/specs/spec-3pl/billing-model.md'
  - '_bmad-output/specs/spec-3pl/architecture.md'
  - '_bmad-output/implementation-artifacts/spec-21-1-client-dimension-migration.md'
  - '_bmad-output/implementation-artifacts/spec-21-2-client-isolation-rls.md'
  - 'docs/design/SYSTEM-DESIGN.md'
  - 'docs/design/IMPLEMENTATION-GUIDE.md'
  - 'docs/design/modules/clients.md'
  - 'docs/design/modules/catalog.md'
  - 'docs/design/modules/outbound.md'
  - 'docs/design/modules/inbound.md'
  - 'docs/design/modules/inventory.md'
  - 'docs/design/modules/invoicing.md'
  - 'docs/design/modules/channels.md'
  - 'docs/design/frontend/SYSTEM-DESIGN.md'
  - 'docs/design/frontend/IMPLEMENTATION-GUIDE.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** 21-1 gave every SKU, order, purchase order and ledger event a `client_id`, but nothing can create a client. Every writer stamps the tenant's `self` client, and the ledger append ignores the SKU's client too. A 3PL therefore cannot register a brand, and 21-3 (rate cards) and 21-4 (metering) would have nothing real to price or meter.

**Approach:**
- Owners register and rename client brands.
- A catalog import names the client its new SKUs belong to.
- Orders, purchase orders and every ledger movement take their client from their SKUs, and a document mixing clients is refused.
- Client orders are not GST-invoiced by the 3PL.
- Everything existing stays `self`.

**Decisions (human, 2026-10-06):**
1. **A new story, 21-2b, before 21-3.**
2. **SKU codes and barcodes stay unique across the tenant.** Per-client codes go to PENDING.
3. **A SKU's client is fixed once it has history.**
   - It is set at creation.
   - An owner may correct it **only while the SKU has no ledger event, order line or PO line**. After that it never changes.
   - Mistakes are also prevented up front:
     - when more than one client exists, the import has **no default** client, so the operator must pick one;
     - a fix-mode re-run inherits its original run's client.
4. **One client per catalog import.** The import form picks the client. The CSV format is unchanged.
5. **Client orders are not GST-invoiced.** The invoicing handler skips any order whose client is not the tenant's own (`system_owned`): no tax invoice and no e-way bill. "Issuing documents on a client's behalf" goes to PENDING.

## Boundaries & Constraints

**Always:**
- **The client is derived from the SKU:**
  - an order's client comes from its lines and kit components;
  - a PO's client comes from its lines;
  - a ledger event's client is its SKU's `client_id`, read in the append transaction. If no SKU row is found, the append throws a loud internal `Error` and never falls back to `self`.
- **Mixed clients are refused.** Each of these is refused with 409 `mixed-client` (state-dependent, like `kit-sku-holds-stock`), naming the client codes:
  - an order, including via channel ingest;
  - a PO create or amend;
  - a kit and its components;
  - a product whose variants would span clients, whether by SKU PATCH or by the import's product pass.
- **The `self` client is reserved.**
  - It is never created by code. A database CHECK enforces `code <> 'SELF' OR system_owned`.
  - Its name is not editable here, because it mirrors the tenant name: renaming it returns 400.
  - It may be chosen explicitly.
  - It is the default only while it is the tenant's only client.
- **Existing rows are untouched** (they are `self`). There is no backfill.
- **The ledger `event_hash` excludes `client_id`**, as now.
- **Fingerprints don't change for clientless requests.** `clientId` joins the import fingerprint only when present, so imports without it fingerprint as before.

**Never:**
- client status changes (suspend or depart) or deletion;
- portal users (21-7);
- dedicated bins;
- per-client SKU codes, barcodes or product names;
- moving a SKU that has history, or moving orders, POs or events between clients;
- rate cards or billing;
- client filters on lists;
- `client_id` indexes (21-4);
- invoicing on a client's behalf.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected | Error |
|---|---|---|---|
| Create client | Owner, `{code: "acme", name: "Acme Foods"}` | 201, code stored `ACME`, active | — |
| Duplicate, reserved or bad code | `ACME` again, including concurrently; `self`; `AC ME` | — | 409 `duplicate-client-code`; 400 `validation-failed` |
| Non-owner creates | Ops manager | — | 403 `role-denied` |
| Rename | Owner, `{name}` | 200 | `self` → 400; unknown or foreign id → 404 |
| List | Any member | All clients with status, `system_owned` first, then by code | — |
| Import, two clients exist, no client chosen | `clientId` absent | — | 400 `client-required` |
| Import for a client | `clientId = ACME` | New SKUs `client_id = ACME`; run records `ACME` | Non-uuid → 400; unknown → 404 (behind replay) |
| Fix-mode re-run | Original run was `ACME`; re-run names `self` or none | Inherits `ACME` | A different `clientId` → 400 |
| Existing code in import | Code exists under any client | `duplicate-sku-code`, as today; the detail names the owner client | Row error |
| Correct a SKU's client | Owner, SKU with no history | 200 | Has history → 409 `sku-has-history` |
| Order, one client | Lines all `ACME` | `orders.client_id = ACME`; at dispatch **no invoice** | — |
| Order mixed (or kit components differ) | — | — | 409 `mixed-client` |
| Channel order, mixed | Mapped SKUs from two clients | Refused at the ingest mapping check; metered as `validation-failed` | 422 `config-invalid` |
| PO create or amend | Amend adds a line of another client | — | 409 `mixed-client` |
| Movements | Receive, put away, transfer, adjust, count, pick, pack, dispatch an `ACME` SKU | Every ledger row `client_id = ACME` | — |
| Product variants | Import or PATCH attaches an `ACME` SKU to a `self` product | — | 409 / row error `mixed-client` |
| Registration | Tenant name of 200 characters | Self client created (name ≤ 200) | — |

</frozen-after-approval>

## Code Map

- **The table** is `clients` (`schema.ts:136-160`; 0040), with `CLIENT_STATUSES`, `SELF_CLIENT_CODE='self'`, unique `(tenant_id, code)`, and a partial unique on `system_owned`. RLS comes from 0041, which already scopes `clients` for a portal session. The `self` client's name is the tenant name (`registration.command.ts:124`); tenant names are up to 200 characters (`tenancy.dto.ts:50-54`).
- **The only writers of `client_id`** (verified):
  - `catalog/import.command.ts:507`;
  - `inbound/po.command.ts:259` (create, which replenishment's PO submit reuses) and `:501` (the successor copy);
  - `outbound/order.command.ts:717`;
  - `inventory/ledger.service.ts:528` (`appendMovement` :452).

  Every ledger event has a NOT NULL `sku_id`. Reconcile and rebuild don't touch `client_id`. `eventHashOf` (:507-525) excludes it.
- **Import:**
  - It never updates existing SKUs: any existing code is `duplicate-sku-code` (`:419-427`, `findTenantConflicts` :841-865).
  - Fix mode retries the tenant's latest run (`:294-324`); `catalog_imports` has no client column (`:706`).
  - The product pass attaches SKUs (`:332-412`; product rows locked at :351; attached SKUs read at :361).
  - The kit pass is at :530+.
- **Kits:** `kit.command.ts` `lockSkus` (:327-357). **SKU PATCH:** `sku.command.ts:905` (attaches a `product_id`). There is no SKU delete route.
- **Orders:**
  - `assertSkuIdsInTenant` (:1465), called at :488 for lines and :539 for kit components.
  - The channel dedup pre-check is at :563. The mixed-client check goes **after** both.
- **POs:** a private `assertSkuIdsInTenant` (`po.command.ts:659`), called at :242 (create) and :351 (amend).
- **Channel ingest:**
  - `channels.ingest.command.ts:140-153` (the `findSku` loop) is the config-error point.
  - `mapIngestRejection` (:315-341) maps unknown codes to `failed`.
  - `CatalogSkuIdentity` (`catalog.facade.ts:57`) gains `clientId`.
- **Invoicing:** the subscriber `invoicing/delivery.ts` on `order.dispatched` (it acks data faults). The order facts come via `OutboundFacade.orderInvoiceFactsInTx`.
- **Audit:** `audit_events` has no payload column (`schema.ts:169-185`).
- **Architecture tests:** `test/architecture.spec.ts:860` (the clients module owns its write) and `:873-875` (pins `ensureSelfClientInTx` in `ledger.service.ts`, which must be re-pinned).
- **The RLS test:** `test/client-isolation.spec.ts` is pure SQL and stays so; only its stale comment at :45-46 is fixed.
- **No API response carries `clientId` today.** The next migration is **0059**.
- **Web:**
  - The Settings card order is at `app/(app)/settings/page.tsx:18-30`.
  - Copy the gating from `sku-table.tsx`, **not** `users-card.tsx`, which the guide lists among the stale cards.
  - The mirror is `lib/users.ts:15` (`CAPABILITIES`) and :165 (`OWNER_ONLY_CAPABILITIES`), with pins at `users.test.ts:41,133,183,218`.
  - `import-catalog.tsx` (:78, :101-103, :265) and `fetchApiImportCatalog` (`lib/api/client.ts:597`).
  - The order form is `outbound-orders.tsx:121,395`.
  - Orders and PO lists and detail: `components/outbound/*`, `components/inbound/inbound-cards.tsx`.

## Tasks & Acceptance

**Execution:**
- [ ] `wms-be/drizzle/0059_client_admin.sql` (+ journal, snapshot, schema.ts) -- guarded. The pre-flight **RAISEs**, listing every offender at once.
  - Normalise existing non-system codes to uppercase.
  - CHECKs:
    - `code ~ '^[A-Z0-9][A-Z0-9-]{1,31}$' OR system_owned` (`self` stays lowercase);
    - `code <> 'SELF' AND code <> 'self' OR system_owned`;
    - `char_length(btrim(name))` between 1 and 200.
  - Add `catalog_imports.client_id uuid NULL`, backfilled with each tenant's self client, then NOT NULL.
- [ ] `wms-be/src/modules/clients/` -- the module:
  - **`clients.command.ts`:**
    - `create`: code trimmed and uppercased; a 23505 on `(tenant, code)` → 409 `duplicate-client-code`.
    - `rename`: `self` → 400; unknown → 404.
    - Both follow the house skeleton: Idempotency-Key, `idempotency-key-reuse` 422, and audit actions `client.created` / `client.renamed` with target type `client`. No outbox event.
  - **`clients.facade.ts`:** `listClients` (all clients, `system_owned` desc then code; bounded at 500, documented), `assertClientInTenantInTx`, and the bulk `getClientCodesInTx`.
  - A Nest module.
  - `permissions.ts` gains `clients.manage` (owner-only).
- [ ] `wms-be/src/api/clients.controller.ts` + DTO -- `GET /tenants/{t}/clients` (member-open), `POST /tenants/{t}/clients`, `PATCH /tenants/{t}/clients/{clientId}`. Name is 1–200 characters.
- [ ] `wms-be` catalog:
  - **Import:**
    - an optional multipart `clientId`, uuid-checked at the controller (400), with the 404 behind the replay lookup;
    - `client-required` (400) when there is more than one client and none is given;
    - the run records `client_id`;
    - fix mode inherits it, and a different `clientId` → 400;
    - `duplicate-sku-code` gains the owner client's code in its detail;
    - the product pass refuses `mixed-client` per row;
    - the kit pass refuses mixed components per row;
    - the fingerprint is unchanged when `clientId` is absent.
  - **Kit API:** components must share the kit's client. **SKU PATCH:** attaching to a product whose SKUs belong to another client → 409.
  - **New `POST /catalog/skus/{skuId}/client`** (`{clientId}`, owner, `clients.manage`): allowed only when the SKU has no ledger event, order line or PO line, else 409 `sku-has-history`; the check runs under a lock on the SKU row; audited `sku.client-corrected`.
  - `CatalogSkuIdentity` and `SkuResponse` gain `clientId`.
- [ ] `wms-be` outbound and inbound:
  - Both `assertSkuIdsInTenant` return each SKU's client.
  - Order create derives the client and refuses `mixed-client` after the kit-component assertion and after the dedup pre-check.
  - PO create derives the client; amend refuses another client's line.
  - The order and PO snapshots and list rows gain `clientId`, optional and nullable, because replays of pre-21-2b snapshots lack it.
- [ ] `wms-be` channels -- the ingest's `findSku` loop refuses mapped SKUs that span clients as `config-invalid` (422). `mapIngestRejection` maps `mixed-client` to `validation-failed`.
- [ ] `wms-be` invoicing -- the delivery handler (and the manual generate command) skip an order whose client is not `system_owned`: they ack and log, with no invoice and no outbox event. The order invoice facts gain `clientSystemOwned`.
- [ ] `wms-be/src/modules/inventory/ledger.service.ts` -- `appendMovement` reads the SKU's `client_id` by tenant and id, and throws an internal `Error` when the SKU is missing. Re-pin the architecture tests (`:873-875`), pin `clients.command.ts` as a client writer, and add a guard that only the correction command updates `skus.client_id`.
- [ ] `wms-be` tests:
  - every matrix row, in a new `test/clients.spec.ts`;
  - a movement sweep across all ledger types;
  - the invoicing skip (an `ACME` order dispatched → no invoice, no e-way);
  - hash stability;
  - an 0059 migration block (the pre-flight, uppercasing, CHECKs, the `catalog_imports` backfill);
  - `client-isolation.spec.ts`: correct the comment only.
  - Re-export `openapi.json`.
- [ ] `wms-fe`:
  - **Data:** `useClients` (house loader) plus `CLIENTS_CHANGED_EVENT`; reason mappers in `src/lib/` (clients card, order create, import including `not-found`/`client-required`, kit and PATCH), tested.
  - **Settings:**
    - a `ClientsCard` (gated like `sku-table.tsx`) before Import: a list with status, plus create and rename for owners, and `self` shown as the tenant's own company;
    - the Settings description mentions clients.
  - **Import:**
    - the client picker is required with no default when there is more than one client, and locked in fix mode;
    - with a single client, it shows a hint line: "Importing for <tenant name>. Add clients in Settings to import for a brand."
  - **Showing the client** (when more than one exists):
    - a client column on the SKU table, the orders list and the PO list and detail;
    - the order form's SKU options are restricted to the first line's client;
    - an owner "Correct client" action on SKUs with no history.
  - **Capabilities:** add `clients.manage` to `CAPABILITIES` and `OWNER_ONLY_CAPABILITIES`; the owner pin becomes 37.
  - Tests.
- [ ] Meta docs:
  - `clients.md`: the API and attribution rules; "every writer calls `ensureSelfClientInTx`" is no longer true; the stale cite fixed;
  - the catalog, outbound, inbound, inventory, invoicing and channels module notes;
  - `API-SURFACE.md` and both contracts;
  - `PENDING.md`:
    - per-client SKU codes, barcodes and product names;
    - status transitions and departure;
    - dedicated bins;
    - invoicing on a client's behalf;
    - 21-5 adding the client's GSTIN, legal name and billing address as nullable columns (the 8-1d validate-and-warn pattern);
    - a client may hold stock in several warehouses tenant-wide, which closes the SPEC open question;
  - `sprint-status.yaml`: add `21-2b-client-admin-and-attribution`.

**Acceptance Criteria:**
- Given an owner creates client `ACME` and imports three SKUs for it, when an order and a PO for them are created and the goods are received, put away, picked and dispatched, then the order, the PO and every resulting ledger event carry `ACME`, no invoice or e-way bill is created for that order, and all pre-existing rows still carry `self`.
- Given an order or PO mixing `ACME` and `self` SKUs, when submitted, then it is refused with `mixed-client` and nothing is written.
- Given the full BE and FE suites, when run, then they pass.

## Implementation Notes

## Spec Change Log

## Review Triage Log

*Design review, 2026-10-06: two code-verified reviewers (backend; 3PL fit/API/FE). 28 findings merged into 22. Two went to the human (decisions 3 and 5); the rest are folded in.*

| # | Severity | Finding | Disposition |
|---|---|---|---|
| 1 | high | Client orders would be GST-invoiced under the 3PL's series, with an e-way bill queued | Decision 5: skip, plus PENDING |
| 2 | high | "Recreate the SKU" is impossible (unique codes, no delete); fix mode would land rows under `self` | Decision 3: required choice, fix-mode inheritance, a correction while there is no history; `catalog_imports.client_id` |
| 3 | high | The name cap of 120 is below tenant names of 200, which breaks registration | Cap 200; the pre-flight RAISEs |
| 4 | high | No API response carries `clientId` | Added to the SKU, order and PO responses (nullable for old replays) |
| 5 | high | The import can attach a SKU to another client's product | Product-pass `mixed-client` row error |
| 6 | high | The "SKU belongs to client" row error never fires (an existing code is already a duplicate) | Dropped; the owner client is added to `duplicate-sku-code` detail |
| 7 | medium | A mixed channel order would be metered as a transient `failed` | Refused at the mapping check (`config-invalid`); mapped to `validation-failed` |
| 8 | medium | The ledger re-pin and the SKU-client immutability guard were missing | Architecture pins re-done; a guard limits updates to the correction command |
| 9 | medium | `appendMovement` had no stated failure for a missing SKU | Throws an internal error; never falls back |
| 10 | medium | `self` rename and choice contradictory | Rename 400; explicit choice allowed; default only when it is the sole client |
| 11 | medium | Client API error arms incomplete (404, reuse, concurrent 23505, typed codes) | All specified |
| 12 | medium | The import `clientId` validation was under-specified | uuid 400 at the boundary; 404 behind replay |
| 13 | medium | 21-5's invoice inputs (GSTIN, address) undecided; multi-warehouse clients implicit | PENDING note (additive later); recorded |
| 14 | medium | FE gating copied a stale card; mirror and loader under-specified | `sku-table.tsx` pattern; `CAPABILITIES` too; `useClients` and the event |
| 15 | medium | Attribution invisible on the orders and PO screens; the order form lets users build a mixed order | Client columns; options restricted to the first line's client |
| 16 | medium | 400 vs 409 for `mixed-client` undecided | 409 (state-dependent) |
| 17 | low | The order check's position vs the dedup pre-check; a bulk code lookup is needed | After the kit assertion and the dedup pre-check; `getClientCodesInTx` |
| 18 | low | "Seed client-isolation via the API" is a rewrite | Comment fix only; a new `clients.spec.ts` |
| 19 | low | `self` reserved only in the command | A database CHECK |
| 20 | low | The list filtered to active, with order and bound unstated | All statuses; ordered; bounded |
| 21 | low | Code case vs warehouse codes; audit names | Uppercase (like warehouse codes), `self` exempt; actions named |
| 22 | low | Discoverability (import hint, Settings copy, the "self" label) | Hint line; description; the label shows the tenant name |

## Design Notes

- **Why derive, not choose.** The SKU is what a client owns. Choosing the client on a document would let the document disagree with its goods, so deriving it keeps ownership answerable from the ledger (AD-1, AD-23).
- **The ledger stamp is the load-bearing change.** After this story, metering (21-4) can aggregate by `ledger_events.client_id` directly.
- **Why skip invoicing.** A 3PL holds a brand's goods. The brand sells them and invoices its own customer, while the 3PL bills the brand for services (21-5, SAC codes). Issuing the brand's tax invoice is a different feature.

## Verification

**Commands:**
- `bun run test` (wms-be) -- green, plus `typecheck`, `lint`, `build`; `db:generate` reports "No schema changes".
- `bun run lint && bun run test && bun run typecheck && bun run build && bun run check:capability-mirror` (wms-fe) -- green.
