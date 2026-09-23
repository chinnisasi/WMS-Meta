# API surface

Every route the backend exposes, grouped by the module that owns it. **69 routes across 11 controllers.**

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
| POST | `/tenants/{t}/warehouses` | `warehouse.create` | Body carries the required `origin` address (story 11-1); duplicate code → `409 duplicate-warehouse-code` |
| GET | `/tenants/{t}/warehouses` | — | Keyset |
| POST | `/tenants/{t}/warehouses/{w}/zones` | `zone.create` | Foreign warehouse → `404` |
| GET | `/tenants/{t}/warehouses/{w}/zones` | — | Keyset |
| POST | `.../zones/{zoneId}/bins` | `bin.create` | Bin codes unique per **warehouse**, not per zone. Optional physical capacity (11-5): `lengthMm`/`widthMm`/`heightMm`/`maxWeightGrams`, positive whole ≤ cap, absent/null = unconstrained. Optional `storageClass` (12-1): the FR-40 vocabulary, omit = `ambient` |
| POST | `.../zones/{zoneId}/bins/grid` | `bin.create` | ≤ 500 bins → `422 grid-too-large`; any collision aborts the whole grid. Same optional capacity attributes (11-5) and optional `storageClass` (12-1) |
| GET | `.../zones/{zoneId}/bins` | — | Keyset |
| PATCH | `/tenants/{t}/warehouses/{w}/bins/{binId}` | `bin.block` / `bin.create` | Per-body dispatch: `blocked` → block/unblock toggle (`bin.block`); structure attributes `lengthMm`/`widthMm`/`heightMm`/`maxWeightGrams`/`storageClass` → the structure arm (`bin.create`; 11-5 capacity, 12-1 class); both or neither → `400 validation-failed`; an explicit `storageClass: null` → `400 validation-failed` (the column is NOT NULL — omit it to leave the class unchanged). The class arm re-checks the vocabulary and **refuses a change that would strand existing stock non-conforming → `409 storage-class-conflict`** (12-1 — names the SKUs holding stock that would no longer fit; relocate or release first) |
| POST | `.../bins/{binId}/merge` | `bin.retire` | Moves stock, emits ledger events. 11-5 gates on the target's physical capacity: `bin-overweight` / `bin-volume-exceeded` / `bin-item-oversize` → `400`; 12-1 merge-class gate `bin-storage-mismatch` → `400` — the target bin cannot satisfy a source SKU's class (names the offending SKUs) |
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
| POST | `/tenants/{t}/catalog/imports` | `catalog.import` | **multipart.** A `201` can carry per-row failures — partial commit is the design. Row codes: `validation-failed`, `duplicate-sku-code`, `duplicate-barcode`, `duplicate-variant-values` (11.3). `mode=fix` reprocesses only the prior run's failures. Optional `product` (an existing product's **name**) and `variant_values` cells (`size=M; colour=Red`) attach a row as a variant; an unknown product or a values/axes mismatch is a row error. **11.6:** the optional `kit_components` cell (`pad:2;tape:1`) composes the row as a kit, resolved after all SKU rows commit — row codes `kit-component-not-found`, `kit-self-reference`, `kit-component-is-kit`, `kit-already-composed`, `kit-sku-holds-stock`, `duplicate-kit-component`, `empty-kit-composition`; **a refused kit cell keeps its SKU** (the SKU is in both committedRows and failedRows), and fix mode cannot retry it — only the PUT kit route can |
| GET | `/tenants/{t}/catalog/skus` | — | Keyset. Optional `productId` filter — the variants of ONE product (11.3) |
| PATCH | `/tenants/{t}/catalog/skus/{skuId}` | `sku.edit` | `code` and `uom` are **immutable**. Barcode collision → `409 duplicate-barcode`. The five physical attributes (11.2: `weightGrams` ≤ 1,000,000 g, `lengthMm`/`widthMm`/`heightMm` ≤ 10,000 mm, `countryOfOrigin` ISO alpha-2) are optional — absent = unchanged, `null` = cleared; badly-shaped values → `400 validation-failed` naming the field. The variant fields (11.3: `productId` + `variantValues`) follow the same template — attach requires values that cover the product's axes exactly (`400 validation-failed` naming `variantValues` + the axis), `productId: null` detaches and clears, a duplicate variant → `409 duplicate-variant-values`, an unknown product → `404`. 12-1: `storageClass` is optional WYSIWYG (absent = unchanged, the column is NOT NULL — an explicit `null` → `400 validation-failed`; `@IsIn` + the shared `assertStorageClass` for the vocabulary); a class change that would strand existing stock → **`409 storage-class-conflict`** (names the bins whose stock would no longer fit) |
| POST | `/tenants/{t}/catalog/products` | `sku.edit` | **11.3.** Identity only: `name` + `axes` (1–3). Duplicate name → `409 duplicate-product-name` |
| GET | `/tenants/{t}/catalog/products` | — | **11.3.** Keyset; items carry the derived `skuCount` |
| PATCH | `/tenants/{t}/catalog/products/{productId}` | `sku.edit` | **11.3.** Name always editable; `axes` immutable while variants are attached → `409 product-has-variants`. Empty body → `400 empty-product-edit` |
| POST | `/tenants/{t}/catalog/skus/{skuId}/kit` | `sku.edit` | **11.4.** Attaches a composition to an existing imported SKU — the only interactive door into kit-ness (the import's `kit_components` cell is the second, 11.6). 409 `kit-already-composed`; 400 `kit-self-reference`; 409 `kit-component-is-kit` (flat BOM); 409 `duplicate-kit-component`; 400 `empty-kit-composition` (the command owns the empty-array answer, not the DTO); **409 `kit-sku-holds-stock`** — a SKU carrying on-hand stock or a live reservation cannot become a kit |
| PUT | `.../catalog/skus/{skuId}/kit` | `sku.edit` | **11.4.** Full replacement — DELETE + re-INSERT in one tx. PUT on a **non-kit** SKU → `404` (replace never creates kit-ness). No delete command exists |
| GET | `/tenants/{t}/catalog/kits` | — | **11.4.** Keyset; kit SKUs with their compositions |

**The only creator of SKUs is the CSV import.** There is no `POST /skus`.

## inventory — `inventory.controller.ts`

| Method | Path | Capability | Notes |
|---|---|---|---|
| POST | `/tenants/{t}/inventory/adjustments` | `stock.adjust` | The first ledger-movement producer. Serial-tracked SKUs need one serial per unit. A kit SKU is refused sign-agnostically → `409 kit-cannot-hold-stock` (11.4) |
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
| GET | `/tenants/{t}/devices/catalog-snapshot` | **device** | **The offline brain.** SKUs (+ uom, uomPrecision (10.2), catchWeightTracked (10.3/10.6), variantValues + axes (11.7) — null when unattached), bins, putawayTasks, pickTasks (+ kitParentSkuCode, 11.7 — display-only, null off-kit), packTasks (+ handlingUnits, 10.7), open POs. Composed at the api shell across modules |
| GET | `/tenants/{t}/receiving/goods-receipts` | — | Keyset |
| GET | `/tenants/{t}/receiving/over-receipts` | — | The review queue |
| POST | `.../over-receipts/{id}/approve` | `review.decide` | Bumps the PO line ceiling. A SKU that became a kit since the GRN → `409 kit-cannot-hold-stock` (11.4); the row stays `pending` for a reject |
| POST | `.../over-receipts/{id}/reject` | `review.decide` | |
| POST | `/tenants/{t}/receiving/qc-holds` | `qc.manage` | Quarantines a (sku, bin) scope — **excluded from ATP** |
| POST | `.../qc-holds/{holdId}/release` | `qc.manage` | |
| GET | `/tenants/{t}/receiving/qc-holds` | — | open/released tabs |

## putaway — `putaway.controller.ts`

| Method | Path | Capability | Notes |
|---|---|---|---|
| POST | `/tenants/{t}/putaway/placements` | `putaway.execute` | **device.** Records suggestion-vs-actual. `bin-full`/`bin-blocked` → `400`; 11-5 physical gates `bin-overweight`/`bin-volume-exceeded`/`bin-item-oversize` → `400`; 12-1 conformance gate `bin-storage-mismatch` → `400` (FR-40 — the bin's class must satisfy the SKU's, the temperature hierarchy colder-bin-over-warmer-SKU, non-temperature classes exact-match); `insufficient-on-hand` → `422` (retryable, key unconsumed) |
| GET | `/tenants/{t}/putaway/tasks` | — | Remaining work in the receiving bin |
| GET | `/tenants/{t}/putaway/placements` | — | Keyset |

## outbound — `outbound.controller.ts`

| Method | Path | Capability | Notes |
|---|---|---|---|
| POST | `/tenants/{t}/outbound/orders` | `orders.manage` | Body carries the required `destination` address (story 11-1); over-ATP is **accepted and backordered**, never refused |
| POST | `.../orders/{orderId}/cancel` | `orders.manage` | Releases holds atomically. Only from `accepted` |
| POST | `.../orders/{orderId}/pack` | `pack.execute` | Scan mismatch → `422 pack-mismatch` naming **both** quantities |
| POST | `.../orders/{orderId}/dispatch` | `dispatch.execute` | **Terminal.** Retires committed holds — the transition that corrects ATP |
| GET | `.../orders/{orderId}` | — | Echoes the `destination` (story 11-1); null on pre-11.1 rows |
| GET | `/tenants/{t}/warehouses/{w}/outbound/orders` | — | Keyset; `cursor`+`limit` only, so status filtering is page-scoped |
| POST | `/tenants/{t}/outbound/wave-policies` | `waves.manage` | A policy **is** the wave rule |
| GET | `/tenants/{t}/warehouses/{w}/outbound/wave-policies` | — | Keyset |
| POST | `/tenants/{t}/outbound/waves` | `waves.manage` | Omitted `orderIds` sweeps eligible orders oldest-first |
| POST | `.../waves/{waveId}/release` | `waves.manage` | Cutoff passed → `409 cutoff-passed`, **wave stays planned** |
| POST | `.../waves/{waveId}/cancel` | `waves.manage` | Frees orders to be re-waved |
| POST | `/tenants/{t}/outbound/picks` | `picks.execute` | **device.** The conflict taxonomy lives here: `pick-bin-short` 409 = re-plannable, `pick-unresolvable` 409 = terminal/quarantine, `insufficient-on-hand` 422 = retryable; 12-1 conformance gate `bin-storage-mismatch` → `400` when the drawn bin's class cannot satisfy the SKU's (defensive — the draw only walks bins the placement and merge gates already admitted) |
| POST | `/tenants/{t}/outbound/packs` | `pack.execute` | **device** (10.7). Same `packOrder` command as the tenant pack route (which re-authorizes the device in-tx via `deviceId`), orderId in the body; no `dimensionsMm` on the device payload (`forbidNonWhitelisted` → 400). Scan mismatch → `422 pack-mismatch` naming **both** quantities; a revoked device → `403 device-revoked` |
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

**Seven** routes sit outside the ordinary user session — and they are not one uniform class. Read the guard on the route, never this table alone:

| Route | Actual guard |
|---|---|
| `POST .../devices/enroll` | **None.** `devices.controller.ts:96` carries no `@UseGuards` — the enrollment code in the body *is* the credential. Unauthenticated by design; the code is the only thing standing in front of it |
| `POST .../devices/badge-in` | device credential — issues the operator session |
| `POST .../devices/self-test/echo` | device credential |
| `GET .../devices/catalog-snapshot` | device session |
| `POST .../receiving/goods-receipts` | device session |
| `POST .../putaway/placements` | device session |
| `POST .../outbound/picks` | device session |
| `POST .../outbound/packs` | device session (10.7) |

The four device-session routes re-authorise on replay against **the badge-in session that created the op** — shared devices never launder authority across badge-ins.

**A badge-in device token also satisfies `TenantSessionGuard`.** Both JWT families are HS256 under one `JWT_SECRET`, and `verifyTenantSession` (`jwt-session.ts:64`) checks only `sub`, `tenant_id` and `exp` — it never rejects the `device_id` claim a badge-in token carries. The claim-shape exclusivity its docstring asserts holds **one direction only**. Verified; tracked in `PENDING.md`.
