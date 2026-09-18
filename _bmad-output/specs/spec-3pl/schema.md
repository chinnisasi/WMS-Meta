# Schema — low-level design

Companion to `SPEC.md`. Repo conventions apply throughout: `uuid` primary keys stamped `uuidv7()` in the app, `tenant_id` on every table, **no FK constraints** (uuid column + index, validated in the command transaction), RLS policies and CHECK constraints **only in migration SQL, never in `schema.ts`**, money in integer paise, quantities in milli-units (AD-9 as amended).

## Where `client_id` goes — and where it deliberately does not

The SKU is the source of truth for ownership. Everything that references a SKU inherits the client for free. An explicit column is added **only** where a query filters or aggregates *without* joining through the SKU.

| Table | Column | Why |
|---|---|---|
| `skus` | `client_id` NOT NULL | **Source of truth.** A SKU belongs to exactly one client |
| `orders` | `client_id` NOT NULL | The portal lists a client's orders; joining every line to its SKU to filter an order list is wrong, and an order is for one client by definition |
| `purchase_orders` | `client_id` NOT NULL | Same, and an inbound document is authored for one client |
| `ledger_events` | `client_id` NOT NULL | **Billing aggregates over this table constantly.** Joining to `skus` on every metering pass is the one denormalisation worth its cost |
| `bins` | `dedicated_client_id` NULL | Commingled by default; a dedicated bin names its client. **Nullable on purpose** — this is an attribute, not a scoping column |
| `users` | `client_id` NULL | Null means 3PL staff; set means a client-portal user |

**Not added, by design:** `stock_on_hand`, `batch_on_hand`, `reservations`, `picklists`, `picklist_lines`, `picks`, `goods_receipt_lines`, `putaway_placements`, `order_lines`. All reference a SKU; all inherit. Adding a column to each would be four more places for the value to disagree with itself.

## New tables

### `clients`

```
id                uuid pk            -- uuidv7
tenant_id         uuid not null
code              text not null      -- operator-facing short code
name              text not null
status            text not null      -- 'active' | 'suspended' | 'departed'
system_owned      boolean not null default false   -- the tenant's own `self` client
created_at, updated_at
```
- `unique (tenant_id, code)`; `unique (tenant_id) where system_owned` — **exactly one self client per tenant**.
- CHECK on `status`; CHECK that a `system_owned` row cannot be `departed`.
- Precedent for `system_owned`: `bins.system_owned`, which already protects the receiving and QC-hold bins from operator edits.

### `rate_cards` / `rate_card_lines`

```
rate_cards
  id, tenant_id, client_id not null
  effective_from   timestamptz not null
  effective_to     timestamptz            -- null = open-ended
  status           text not null          -- 'draft' | 'active' | 'superseded'

rate_card_lines
  id, tenant_id, rate_card_id not null
  charge_code      text not null          -- closed vocabulary, see billing-model.md
  basis            text not null          -- 'per_unit_per_day' | 'per_receipt_line' | 'per_pick' | 'per_order'
  amount_paise     bigint not null        -- integer paise, AD-9
```
- **Versioned by effective date, never edited in place.** A rate change writes a new card and closes the old one, so an issued invoice stays reproducible (CAP-4).
- `charge_code` and `basis` are closed vocabularies enforced by CHECK — the same TS-tuple-plus-migration-CHECK pattern the repo uses for its other ten enums.

### `storage_snapshots`

```
id, tenant_id, client_id not null, warehouse_id not null
snapshot_date    date not null
billable_units   bigint not null     -- milli-units, or handling units once 10-3 lands
created_at
```
- `unique (tenant_id, client_id, warehouse_id, snapshot_date)`.
- **A projection, not a book** (AD-25). Written by a daily job, rebuildable from the ledger, and a rebuild must reproduce it exactly.

### `client_invoices` / `client_invoice_lines`

```
client_invoices
  id, tenant_id, client_id not null
  period_start, period_end   date not null
  status           text not null     -- 'draft' | 'issued' | 'disputed' | 'settled' | 'void'
  issued_at        timestamptz
  subtotal_paise, tax_paise, total_paise   bigint not null
  rate_card_id     uuid not null     -- the card in force, recorded not referenced live

client_invoice_lines
  id, tenant_id, invoice_id not null
  charge_code      text not null
  basis            text not null
  quantity         bigint not null   -- events counted, or unit-days
  unit_amount_paise, amount_paise    bigint not null
  sac_code         text              -- SERVICES, not HSN: a 3PL bills a service
```
- **Immutable once issued** (CAP-7): the status CHECK permits no transition out of `issued` except to `disputed`, `settled` or `void`, and no edit of amounts after `issued_at` is set. A correction is a new document.
- `rate_card_id` is **recorded on the invoice**, so re-rendering it later uses the card that actually applied.

### `advance_shipment_notices` / `asn_lines`

```
advance_shipment_notices
  id, tenant_id, client_id not null, warehouse_id not null
  asn_code         text not null
  status           text not null     -- 'announced' | 'partially_received' | 'received' | 'cancelled'
  expected_at      timestamptz
  created_at, updated_at

asn_lines
  id, tenant_id, asn_id not null, sku_id not null
  announced_qty    bigint not null   -- milli-units
  received_qty     bigint not null default 0
```
- `unique (tenant_id, asn_code)`.
- Mirrors `purchase_orders` / `purchase_order_lines` deliberately, so **receiving books against either** with one flow (CAP-9). The GRN's reference document becomes "a PO or an ASN", not a second path.

## Migrations

**Two, in order.** Splitting them keeps the risky one small.

**A — the client dimension.** Create `clients`; insert one `system_owned` self client per existing tenant; add `client_id` to `skus`, `orders`, `purchase_orders`, `ledger_events` and backfill every row to that self client; add `bins.dedicated_client_id` and `users.client_id` as nullable; set `NOT NULL` on the four; extend every RLS policy on those tables with the AD-24 client clause. Pre-launch, so a straight in-place migration — the same licence story 10.1 used, and the same expiry: it ends with the first real tenant.

**B — billing, ASN and portal tables.** Purely additive. No existing table changes.

**Guard both** the way 10.1's migration is guarded: a fail-fast `RAISE` if already applied, a pre-flight listing anything unmappable, and a post-migration assertion that every row carries a client.

## What the tests have to pin

The 10.1 and 10.2 reviews both found the same class of gap — a migration whose data statements nothing executed — so this is written down before the fact:

- **Migration A applied to pre-client data**, on the 10.1 harness: real migrations folder trimmed to the prior index, seeded rows in every affected table, then assert each carries the self client and `NOT NULL` holds.
- **A database-level client-isolation probe**, in the shape of the existing `wms_rls_probe` tests: connect as a non-superuser with `app.client_id` set and assert **zero rows** for another client's SKUs, orders, batches and ledger events. CAP-2 says "proven by a database-level probe, not only an API test" precisely because an API test only proves the API.
- **A cross-client wave**, proving isolation did not cost the efficiency it exists to protect.
- **Recompute equality:** delete a period's charges, recompute, assert byte-identical (CAP-5).
- **Rate-change immutability:** issue an invoice, change the rate, re-render, assert unchanged (CAP-4).
- **Storage snapshot rebuild** reproduces the same billable units from the ledger (AD-25).
- **The TS vocabulary and the DB CHECK pinned together** for `charge_code`, `basis` and both status sets, as `orders.spec.ts` pins `ORDER_STATUSES`.
