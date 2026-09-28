# Clients module

> The 3PL scoping dimension inside the tenant (AD-23): who owns the goods in the building — one system-owned `self` client per tenant for D2C, one row per external client from Epic 21 Phase 0 onward.

Paths are relative to `workspace/core/backend/wms-be`. Read [`../IMPLEMENTATION-GUIDE.md`](../IMPLEMENTATION-GUIDE.md) first — the command skeleton, migration checklist and vocabulary pattern below are assumed, not repeated.

This module is deliberately minimal (story 21-1): it owns the `clients` table and the one seam every other module touches — `ensureSelfClientInTx`. There is **no API surface, no CRUD, and no status-transition command yet**; the client *admin* and *portal* consumers arrive with 21-7, billing with 21-3…21-5.

---

## Owns

| Table | Holds | Key invariants |
|---|---|---|
| `clients` (`src/shared/db/schema.ts:127`) | One row per client of a tenant: `code`, `name`, `status`, `system_owned` | Exactly **one system-owned client per tenant** — partial unique index `clients_tenant_system_owned_unique` (`(tenant_id) WHERE system_owned`, `drizzle/0040_client_dimension.sql`). `code` unique per tenant (`clients_tenant_id_code_unique`). `status` CHECK ∈ {`active`,`suspended`,`departed`} and `system_owned ⇒ NOT departed` (`clients_status_check` / `clients_system_owned_not_departed`) — CHECKs only in migration SQL, vocabulary mirrored in `CLIENT_STATUSES` (`src/modules/clients/clients.schema.ts`) |

Every table in the repo carries `tenant_id` with a fail-closed `tenant_isolation` RLS policy declared **only** in migration SQL. Since story 21-2 (`drizzle/0041_client_isolation_rls.sql`) five policies carry the second fail-closed session variable `app.client_id` — the four stamped tables (binding on `client_id`) plus `clients` itself (binding on `id`), all null-tolerant: an unset variable is the OPERATOR shape (whole tenant, cross-client waves untouched); a set-but-wrong id binds to nothing; `''` reads as unset (the NULLIF idiom). The stamping primitive is `setClientScope` + the optional `clientId` option on `withTenantTransaction` (`src/shared/db/tenant-scope.ts`) — transaction-local, rejected on the empty string. The DB-level probe is `test/client-isolation.spec.ts` (`wms_rls_probe`); **21-7's portal is the first consumer** and must route inherited-table reads (stock/batch — no client_id column, tenant-only policies) through the stamped tables' join (deferred-work constraint).

## The seam

`ensureSelfClientInTx(tx, tenantId, opts?)` (`src/modules/clients/ensure-self-client.ts`) — idempotent, identity `tenant_id + code='self' + system_owned`:

- early-returns the existing self client; inserts with `onConflictDoNothing({ target: [tenantId, code] })` then re-selects
- throws `self client missing for tenant (no name to create it with)` when no tenant name exists to seed it, `self client missing after ensure` when the re-select finds nothing
- called **inside the caller's tenant-scoped transaction** — registration (`registration.command.ts`, with `{ selfClientName: tenant.name }`) and every client-stamping writer: catalog import, ledger append, PO create + carried successor, order create

## The stamping rule (AD-24 placement)

`client_id` is a **selective denormalisation** — explicit NOT NULL columns only where queries filter/aggregate without joining through the SKU: `skus`, `orders`, `purchase_orders`, `ledger_events` (billing aggregates over it constantly). Nullable by design: `bins.dedicated_client_id` (attribute, not scope) and `users.client_id` (null = tenant staff, set = portal user — **inert until 21-7**). Tables referencing a SKU — stock, reservations, picks, order lines, GRN lines — inherit and get **no column**; their client isolation rides on the join through `skus`, which 21-2's policies filter.

## Gotchas (the ones that caused real defects)

- **`event_hash` does not include `clientId`** — the ledger's hash identity is unchanged by the client dimension (verified byte-identical across the 0040 backfill in `test/client-dimension.spec.ts` Part A). Adding it to the hash inputs would re-write every historical hash; don't.
- **The ledger backfill needed the append-only trigger dance** — 0040's UPDATE on `ledger_events` fires the 0006 `ledger_events_append_only` trigger, so the migration disables it, backfills, and re-enables it inside its own transaction (a failure rolls the disable back too). Any future migration that UPDATEs the ledger repeats the dance.
- **`onConflictDoNothing` targets `(tenant_id, code)` only** — a conflict on the partial `system_owned` index (a rogue system-owned non-self client) would surface as a loud 23505, which is the correct outcome, not silent adoption.
- **Migration 0040 is in-place pre-launch** (Epic 10-1's "last in-place migration" licence is spent): backfilling a NEW column changes no representation — every pre-existing column, `event_hash` included, is byte-identical before/after. A future client-column change is add-column + backfill, never a representation rewrite.
- **Nothing can suspend a client today** — no CRUD path exists; the `suspended`/`departed` vocabulary is frozen at birth because CHECK widening needs DROP/re-ADD (0023/0024 precedent). The semantics of a suspended `self` client are decided by the story that makes the state reachable.