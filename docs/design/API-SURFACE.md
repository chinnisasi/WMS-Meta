# API surface

Every route the backend exposes, grouped by the module that owns it. **66 routes across 11 controllers.**

Base path `/api/v1`. Full request/response/error contract is in [`../repos/wms-be/README.md`](../repos/wms-be/README.md); this is the inventory — what exists, who owns it, what gates it.

**Conventions that hold everywhere:**
- `{t}` = `:tenantId`, `{w}` = `:warehouseId`. The path `tenantId` must match the session's, or `403 permission-denied`.
- Every **mutating** route requires an `Idempotency-Key` header (26-char ULID). Missing/malformed → `400`; same key + different payload → `422 idempotency-key-reuse`; concurrent same key → `409 conflict`.
- **Reads are never capability-gated** — any tenant member may read. Only mutations carry a capability (`permissions.ts:4-7`).
- Lists are cursor-paginated, `limit` 1–200. Offset pagination is banned.
- Errors are RFC 9457 problem details; **clients branch on `code`, never on prose**.

---

## tenancy — `tenancy.controller.ts`, `users.controller.ts`, `devices.controller.ts`

| Method | Path | Capability | Notes |
|---|---|---|---|
| POST | `/tenants` | — | Register tenant + owner. Global email uniqueness → `409 duplicate-email` |
| POST | `/tenants/sign-in` | — | 15-min HS256 JWT. Unknown email and wrong password are indistinguishable → `401` |
| POST | `/tenants/{t}/warehouses` | `warehouse.create` | Duplicate code → `409 duplicate-warehouse-code` |
| GET | `/tenants/{t}/warehouses` | — | Keyset |
| POST | `/tenants/{t}/warehouses/{w}/zones` | `zone.create` | Foreign warehouse → `404` |
| GET | `/tenants/{t}/warehouses/{w}/zones` | — | Keyset |
| POST | `.../zones/{zoneId}/bins` | `bin.create` | Bin codes unique per **warehouse**, not per zone |
| POST | `.../zones/{zoneId}/bins/grid` | `bin.create` | ≤ 500 bins → `422 grid-too-large`; any collision aborts the whole grid |
| GET | `.../zones/{zoneId}/bins` | — | Keyset |
| PATCH | `/tenants/{t}/warehouses/{w}/bins/{binId}` | `bin.block` | Block/unblock toggle |
| POST | `.../bins/{binId}/merge` | `bin.retire` | Moves stock, emits ledger events |
| POST | `.../bins/{binId}/retire` | `bin.retire` | **Terminal.** Bin must be empty |
| GET | `/tenants/{t}/setup-checklist` | — | Computed on read |
| POST | `/tenants/{t}/users` | `users.invite` | Returns a one-time invite token; 7-day TTL |
| GET | `/tenants/{t}/users` | — | Keyset |
| PATCH | `/tenants/{t}/users/{userId}` | `users.role_change` | Demoting the last owner → `409 last-owner` |
| POST | `/tenants/{t}/accept-invite` | **unauthenticated** | Token valid only on the inviting tenant's URL |
| GET | `/tenants/{t}/me` | — | App-mount bootstrap; role changes surface without re-login |
| POST | `/tenants/{t}/devices/enrollment-codes` | `device.manage` | One-time code, hashed at rest |
| POST | `/tenants/{t}/devices/enroll` | **device credential** | Returns the sealed offline-store key **once** |
| POST | `/tenants/{t}/devices/badge-in` | **device credential** | Opens the operator session every op re-authorises against |
| GET | `/tenants/{t}/devices` | — | Keyset |
| POST | `/tenants/{t}/devices/{deviceId}/revoke` | `device.manage` | Status flip + wipe flag; idempotent |
| POST | `/tenants/{t}/devices/self-test/echo` | **device credential** | Connectivity probe |

## catalog — `catalog.controller.ts`

| Method | Path | Capability | Notes |
|---|---|---|---|
| POST | `/tenants/{t}/catalog/imports` | `catalog.import` | **multipart.** A `201` can carry per-row failures — partial commit is the design. Row codes: `validation-failed`, `duplicate-sku-code`, `duplicate-barcode`. `mode=fix` reprocesses only the prior run's failures |
| GET | `/tenants/{t}/catalog/skus` | — | Keyset |
| PATCH | `/tenants/{t}/catalog/skus/{skuId}` | `sku.edit` | `code` and `uom` are **immutable**. Barcode collision → `409 duplicate-barcode` |

**The only creator of SKUs is the CSV import.** There is no `POST /skus`.

## inventory — `inventory.controller.ts`

| Method | Path | Capability | Notes |
|---|---|---|---|
| POST | `/tenants/{t}/inventory/adjustments` | `stock.adjust` | The first ledger-movement producer. Serial-tracked SKUs need one serial per unit |
| GET | `/tenants/{t}/warehouses/{w}/inventory/events` | — | The ledger timeline, keyset |
| GET | `.../inventory/stock` | — | Derived on-hand by bin/SKU |
| GET | `.../inventory/batches` | — | Batch balances |
| GET | `/tenants/{t}/inventory/batches/{batchId}` | — | Batch detail + movement history |
| GET | `/tenants/{t}/inventory/serials/{serialId}` | — | One-query movement history (FR-6) |

## inbound — `inbound.controller.ts`, `receiving.controller.ts`

| Method | Path | Capability | Notes |
|---|---|---|---|
| POST | `/tenants/{t}/vendors` | `vendor.manage` | |
| GET | `/tenants/{t}/vendors` | — | Keyset |
| POST | `/tenants/{t}/inbound/purchase-orders` | `po.manage` | |
| GET | `/tenants/{t}/warehouses/{w}/inbound/purchase-orders` | — | Headers only — lines come from the detail read |
| GET | `/tenants/{t}/inbound/purchase-orders/{poId}` | — | With lines |
| PATCH | `.../purchase-orders/{poId}` | `po.manage` | Amend |
| POST | `.../purchase-orders/{poId}/close` | `po.manage` | Carries open quantity to a successor |
| POST | `/tenants/{t}/receiving/goods-receipts` | **device** | Partial, blind and over-receipt in one flow. Budget: ≤ 4 scans + 1 confirm for a single-SKU single-lot GRN |
| GET | `/tenants/{t}/devices/catalog-snapshot` | **device** | **The offline brain.** SKUs (+ uom, uomPrecision), bins, putawayTasks, pickTasks, open POs. Composed at the api shell across modules |
| GET | `/tenants/{t}/receiving/goods-receipts` | — | Keyset |
| GET | `/tenants/{t}/receiving/over-receipts` | — | The review queue |
| POST | `.../over-receipts/{id}/approve` | `review.decide` | Bumps the PO line ceiling |
| POST | `.../over-receipts/{id}/reject` | `review.decide` | |
| POST | `/tenants/{t}/receiving/qc-holds` | `qc.manage` | Quarantines a (sku, bin) scope — **excluded from ATP** |
| POST | `.../qc-holds/{holdId}/release` | `qc.manage` | |
| GET | `/tenants/{t}/receiving/qc-holds` | — | open/released tabs |

## putaway — `putaway.controller.ts`

| Method | Path | Capability | Notes |
|---|---|---|---|
| POST | `/tenants/{t}/putaway/placements` | `putaway.execute` | **device.** Records suggestion-vs-actual. `bin-full`/`bin-blocked` → `400`; `insufficient-on-hand` → `422` (retryable, key unconsumed) |
| GET | `/tenants/{t}/putaway/tasks` | — | Remaining work in the receiving bin |
| GET | `/tenants/{t}/putaway/placements` | — | Keyset |

## outbound — `outbound.controller.ts`

| Method | Path | Capability | Notes |
|---|---|---|---|
| POST | `/tenants/{t}/outbound/orders` | `orders.manage` | Over-ATP is **accepted and backordered**, never refused |
| POST | `.../orders/{orderId}/cancel` | `orders.manage` | Releases holds atomically. Only from `accepted` |
| POST | `.../orders/{orderId}/pack` | `pack.execute` | Scan mismatch → `422 pack-mismatch` naming **both** quantities |
| POST | `.../orders/{orderId}/dispatch` | `dispatch.execute` | **Terminal.** Retires committed holds — the transition that corrects ATP |
| GET | `.../orders/{orderId}` | — | |
| GET | `/tenants/{t}/warehouses/{w}/outbound/orders` | — | Keyset; `cursor`+`limit` only, so status filtering is page-scoped |
| POST | `/tenants/{t}/outbound/wave-policies` | `waves.manage` | A policy **is** the wave rule |
| GET | `/tenants/{t}/warehouses/{w}/outbound/wave-policies` | — | Keyset |
| POST | `/tenants/{t}/outbound/waves` | `waves.manage` | Omitted `orderIds` sweeps eligible orders oldest-first |
| POST | `.../waves/{waveId}/release` | `waves.manage` | Cutoff passed → `409 cutoff-passed`, **wave stays planned** |
| POST | `.../waves/{waveId}/cancel` | `waves.manage` | Frees orders to be re-waved |
| POST | `/tenants/{t}/outbound/picks` | `picks.execute` | **device.** The conflict taxonomy lives here: `pick-bin-short` 409 = re-plannable, `pick-unresolvable` 409 = terminal/quarantine, `insufficient-on-hand` 422 = retryable |
| GET | `.../waves/{waveId}` | — | With picklists in walk order |
| GET | `/tenants/{t}/warehouses/{w}/outbound/waves` | — | Keyset |

## carriers — `carriers.controller.ts`

| Method | Path | Capability | Notes |
|---|---|---|---|
| GET | `/tenants/{t}/carriers` | — | The registry catalogue: code, display name, required credential fields |
| GET | `/tenants/{t}/carriers/connections` | — | **Public face only** — never the secret or the sealed blob |
| POST | `/tenants/{t}/carriers/connections` | `carrier.manage` | Already connected → `409 carrier-already-connected` |
| POST | `.../connections/{id}/rotate` | `carrier.manage` | Replaces material **in place**; the row id is the stable handle |
| POST | `.../connections/{id}/disconnect` | `carrier.manage` | **Hard delete.** Audit row survives |

## Infrastructure

| Method | Path | Notes |
|---|---|---|
| GET | `/api/v1/health` | anonymous |
| POST | `/api/v1/echo` | anonymous |
| GET | `/api/v1/openapi.json` | The contract. Swagger UI at `/api/docs` |
| ALL | `/api/v1/{*path}` | `NotFoundController` catch-all — **must map last**, which is why `ApiModule` registers after the spine modules |

---

## Capabilities

Twenty-two, in `tenancy/permissions.ts`, mirrored in `wms-fe/src/lib/users.ts` and checked by `check:capability-mirror` in CI.

| Role | Holds |
|---|---|
| **Owner** | everything |
| **Ops Manager** | everything except `users.invite`, `users.role_change` |
| **Operator** | `putaway.execute`, `picks.execute`, `pack.execute`, `dispatch.execute` — the floor verbs only |
| **Accountant** | nothing (read-only) |

## Device-authenticated routes

Six routes take a **device credential** rather than a user session: enroll, badge-in, self-test echo, catalog snapshot, goods-receipts, putaway placements, picks. Every one re-authorises on replay against **the badge-in session that created the op** — shared devices never launder authority across badge-ins.
