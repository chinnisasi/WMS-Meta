# API surface

Every route the backend exposes, grouped by the module that owns it. **100 routes across 12 controllers.**

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
| POST | `.../zones/{zoneId}/bins` | `bin.create` | Bin codes unique per **warehouse**, not per zone. Optional physical capacity (11-5): `lengthMm`/`widthMm`/`heightMm`/`maxWeightGrams`, positive whole ≤ cap, absent/null = unconstrained. Optional `storageClass` (12-1): the FR-40 vocabulary, omit = `ambient`. `type` is the 12-4 eight-value `LocationType` vocabulary (CHECK-backstopped): a bulk asset (`tank`/`silo`) REQUIRES `maxWeightGrams` → else `400 validation-failed` |
| POST | `.../zones/{zoneId}/bins/grid` | `bin.create` | ≤ 500 bins → `422 grid-too-large`; any collision aborts the whole grid. Same optional capacity attributes (11-5) and optional `storageClass` (12-1). The `type` enum narrowed to the six grid-able types (12-4) — a bulk asset is never gridded → `400 validation-failed` |
| GET | `.../zones/{zoneId}/bins` | — | Keyset |
| PATCH | `/tenants/{t}/warehouses/{w}/bins/{binId}` | `bin.block` / `bin.create` | Per-body dispatch: `blocked` → block/unblock toggle (`bin.block`); structure attributes `lengthMm`/`widthMm`/`heightMm`/`maxWeightGrams`/`storageClass` → the structure arm (`bin.create`; 11-5 capacity, 12-1 class); both or neither → `400 validation-failed`; an explicit `storageClass: null` → `400 validation-failed` (the column is NOT NULL — omit it to leave the class unchanged). The class arm re-checks the vocabulary and **refuses a change that would strand existing stock non-conforming → `409 storage-class-conflict`** (12-1 — names the SKUs holding stock that would no longer fit; relocate or release first). On a bulk asset (`tank`/`silo`, 12-4): `maxWeightGrams` cannot be cleared (`400 validation-failed`), and a re-value below the mass the asset already holds → `400 bin-overweight` |
| POST | `.../bins/{binId}/merge` | `bin.retire` | Moves stock, emits ledger events. 11-5 gates on the target's physical capacity: `bin-overweight` / `bin-volume-exceeded` / `bin-item-oversize` → `400`; 12-1 merge-class gate `bin-storage-mismatch` → `400` — the target bin cannot satisfy a source SKU's class (names the offending SKUs); 12-2 merge-hazard gate `bin-segregation-conflict` → `400` — a moved SKU's hazard class co-locates with an incompatible occupant of the target (names both parties and both classes; moved-vs-moved is not re-checked — the source already co-locates them); 12-3 authority gate → `403 role-denied` naming `secure.move` when the **source or target** is secure-class and the actor lacks `secure.move` (FR-42 — byte-identical for holders; dead code by matrix today, the users.spec invariant keeps it enforced). 12-4 bulk-asset occupancy gate `bin-occupancy-conflict` → `400` — the target is a `tank`/`silo` and the moved SKUs would give it a second SKU (the ONE predicate; runs BEFORE the hazard and capacity gates — an incompatible-hazard different-SKU merge answers the occupancy code). The merge retires the source bin on success, so a retired source is refused (`binRetiredAsSource` → `400`) |
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
| POST | `/tenants/{t}/devices/sync-reports` | **badge-in credential** | **5-6** (AD-14): the device's retained-report upload — rows are the dropped terminal ops (`rejected`/`quarantined` fates), each row carrying its op ULID, its sealed payload, the refusal verbatim and its own badge-in attribution. Per-row dedupe on (tenant, op_id) makes a re-post a no-op ack (at-least-once upload). `self-test.echo` is refused (not reviewable — a device diagnostic); a malformed row → 400 naming the row; bare enrollment token → 401; revoked device → 403 `device-revoked`. The 200-row cap is the report ceiling, but the **effective bound is the body limit** (~100 kB Express default; the per-row payload cap is 32 kB) — an oversized body → 413 before any row can be named, which is why the uploader slices at 50 rows and halves on 413. Audit-only (`device.sync_report.recorded`) |
| GET | `/tenants/{t}/rejected-ops` | — | **5-6:** the Conflicts & Reviews queue's keyset read, `?status=open\|applied\|recounted\|discarded` |
| POST | `/tenants/{t}/rejected-ops/{rejectedOpId}/resolve` | `review.decide` | **5-6:** the three arms. **apply** re-executes the stored payload through the op's own command path under the op's attributed operator with `binStateEpoch` stripped (the human judgment replaces that observation) — every guard live; any guard refusal surfaces verbatim and the row stays open. **recount** mints through the movement recount core on the payload-named bin — a pick's `binId` or a placement's `toBinId` (both served; no other field) — `409 count-task-open` on a bin with an open task; a bin-less payload → 400 backstop (the arm is hidden client-side for binId-less op types); unknown bin → 404. **discard** is audit-only (no stock write). Unknown id → 404; already resolved → 409 `rejected-op-resolved`. `Idempotency-Key`; replay re-serves the stored outcome. Apply rides the owning command facades (their own transactions — a post-commit failure self-heals on the op ULID's idempotency key) |

## catalog — `catalog.controller.ts`

| Method | Path | Capability | Notes |
|---|---|---|---|
| POST | `/tenants/{t}/catalog/imports` | `catalog.import` | **multipart.** A `201` can carry per-row failures — partial commit is the design. Row codes: `validation-failed`, `duplicate-sku-code`, `duplicate-barcode`, `duplicate-variant-values` (11.3). `mode=fix` reprocesses only the prior run's failures. Optional `product` (an existing product's **name**) and `variant_values` cells (`size=M; colour=Red`) attach a row as a variant; an unknown product or a values/axes mismatch is a row error. **11.6:** the optional `kit_components` cell (`pad:2;tape:1`) composes the row as a kit, resolved after all SKU rows commit — row codes `kit-component-not-found`, `kit-self-reference`, `kit-component-is-kit`, `kit-already-composed`, `kit-sku-holds-stock`, `duplicate-kit-component`, `empty-kit-composition`; **a refused kit cell keeps its SKU** (the SKU is in both committedRows and failedRows), and fix mode cannot retry it — only the PUT kit route can |
| GET | `/tenants/{t}/catalog/skus` | — | Keyset. Optional `productId` filter — the variants of ONE product (11.3) |
| GET | `/tenants/{t}/catalog/segregation-matrix` | — | **12-7.** Ungated read (the "reads are never capability-gated" convention; e2e pins an operator-session 200 alongside the owner's) — the 12-1/12-2 hazard matrix as data: `{classes: HazardClass[], incompatible: {a,b}[]}`, the FULLY EXPANDED incompatible unordered-pair set (explosive's universal rule enumerated incl. the self-pair; every pair emitted under sorted keys — `hazardClassesCompatible` sorts). Read straight from `hazard.ts` via the facade (no tx); the FE matrix card renders it as the endpoint's only source. e2e cross-checks all 28 unordered pairs against the predicate itself. Foreign session → `403` |
| PATCH | `/tenants/{t}/catalog/skus/{skuId}` | `sku.edit` | `code` and `uom` are **immutable**. Barcode collision → `409 duplicate-barcode`. The five physical attributes (11.2: `weightGrams` ≤ 1,000,000 g, `lengthMm`/`widthMm`/`heightMm` ≤ 10,000 mm, `countryOfOrigin` ISO alpha-2) are optional — absent = unchanged, `null` = cleared; badly-shaped values → `400 validation-failed` naming the field. The variant fields (11.3: `productId` + `variantValues`) follow the same template — attach requires values that cover the product's axes exactly (`400 validation-failed` naming `variantValues` + the axis), `productId: null` detaches and clears, a duplicate variant → `409 duplicate-variant-values`, an unknown product → `404`. 12-1: `storageClass` is optional WYSIWYG (absent = unchanged, the column is NOT NULL — an explicit `null` → `400 validation-failed`; `@IsIn` + the shared `assertStorageClass` for the vocabulary); a class change that would strand existing stock → **`409 storage-class-conflict`** (names the bins whose stock would no longer fit). 12-2: `hazardClass` is optional WYSIWYG too, and NULLABLE — absent = unchanged, `null` = **clears** the class (no explicit-null 400; the 11.2 template governs, `@IsIn` + the shared `assertHazardClass`); a class change that would co-locate the SKU's stock or its open QC holds' release bins with an incompatible occupant → **`409 hazard-segregation-conflict`** (names the bin, the party SKU and its class; clearing ALWAYS succeeds — a null class carries no rule) |
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
| POST | `/tenants/{t}/inventory/adjustments` | `stock.adjust` | The first ledger-movement producer. Serial-tracked SKUs need one serial per unit. A kit SKU is refused sign-agnostically → `409 kit-cannot-hold-stock` (11.4). **5-2:** over a tenant approval threshold the same request answers **202** with the pend snapshot (no ledger event, no on-hand change) — the status is dynamic (201/202) |
| PUT | `/tenants/{t}/inventory/adjustment-policies` | `adjustments.approve` | **5-2.** Sets the tenant's threshold (FR-19); |delta| strictly exceeding it pends. `Idempotency-Key`; concurrent first-time PUTs → one 200, loser `409 conflict`; threshold > int4 → 400 (`@Max`). Owner-only — the write rides the decisions' capability |
| GET | `/tenants/{t}/inventory/adjustment-policies` | — | **5-2.** The policy row; **404 `not-found`** when none exists — the flow is disabled and every adjustment applies immediately |
| GET | `/tenants/{t}/inventory/adjustment-pendings` | — | **5-2.** The approval queue — keyset cursor pagination, newest first, `?status=pending\|approved\|rejected`; a read, never capability-gated |
| POST | `.../inventory/adjustment-pendings/{pendingId}/approve` | `adjustments.approve` | **5-2.** Owner-only decision. Re-executes the stored arms through the full guard set; a moved world (bin retired, on-hand starved, HU moved) rolls back the whole tx → the guard's 400/409/422 verbatim, row stays `pending`. Unknown → `404`; already decided → `409`; non-owner → `403 role-denied`. `Idempotency-Key`; replay re-serves the stored decision |
| POST | `.../inventory/adjustment-pendings/{pendingId}/reject` | `adjustments.approve` | **5-2.** The same contract, reject arm — status flip only, `events: []`, no stock write |
| GET | `/tenants/{t}/warehouses/{w}/inventory/events` | — | The ledger timeline, keyset. **5-4:** optional `binId` query narrows to events touching the bin (source OR destination — `(from_bin = bin) OR (to_bin = bin)`; malformed id → `400 validation-failed`) |
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
| GET | `/tenants/{t}/devices/catalog-snapshot` | **device** | **The offline brain.** SKUs (+ uom, uomPrecision (10.2), catchWeightTracked (10.3/10.6), variantValues + axes (11.7) — null when unattached, storageClass (12.8)), bins (+ storageClass, 12.8), putawayTasks, pickTasks (+ kitParentSkuCode, 11.7 — display-only, null off-kit), packTasks (+ handlingUnits, 10.7), open POs, **transferTasks (5-1** — in-transit transfers to this warehouse, per line with the planned dest bin's `binStateEpoch` quote**)**, **countTasks (5-3** — STORED pending count tasks for this warehouse, expectations frozen at task start; the first stored task feed, additive with the seal-defaulting pattern**)**. Composed at the api shell across modules |
| GET | `/tenants/{t}/receiving/goods-receipts` | — | Keyset |
| GET | `/tenants/{t}/receiving/over-receipts` | — | The review queue |
| POST | `.../over-receipts/{id}/approve` | `review.decide` | Bumps the PO line ceiling. A SKU that became a kit since the GRN → `409 kit-cannot-hold-stock` (11.4); the row stays `pending` for a reject |
| POST | `.../over-receipts/{id}/reject` | `review.decide` | |
| POST | `/tenants/{t}/receiving/qc-holds` | `qc.manage` | Quarantines a (sku, bin) scope — **excluded from ATP**. 12-3 authority gate → `403 role-denied` naming `secure.move` when the origin bin is secure-class and the actor lacks `secure.move` (FR-42; dead code by matrix today — every `qc.manage` holder holds `secure.move`) |
| POST | `.../qc-holds/{holdId}/release` | `qc.manage` | 12-3 authority gate → `403 role-denied` naming `secure.move` when the origin-return bin is secure-class and the actor lacks `secure.move` (FR-42) |
| GET | `/tenants/{t}/receiving/qc-holds` | — | open/released tabs |

## putaway — `putaway.controller.ts`

| Method | Path | Capability | Notes |
|---|---|---|---|
| POST | `/tenants/{t}/putaway/placements` | `putaway.execute` | **device.** Records suggestion-vs-actual. `bin-full`/`bin-blocked` → `400`; 11-5 physical gates `bin-overweight`/`bin-volume-exceeded`/`bin-item-oversize` → `400`; 12-1 conformance gate `bin-storage-mismatch` → `400` (FR-40 — the bin's class must satisfy the SKU's, the temperature hierarchy colder-bin-over-warmer-SKU, non-temperature classes exact-match); 12-2 co-location gate `bin-segregation-conflict` → `400` (FR-41 — the target bin's occupants' hazard classes must be compatible with the SKU's; names both SKUs and both classes; a null class carries no rule in either direction); 12-3 authority gate → `403 role-denied` naming `secure.move` when the target bin is secure-class and the actor lacks `secure.move` (FR-42 — operator is refused; the suggestion stays role-blind, advisory suggestion / binding gate); 12-4 bulk-asset rules: `bin-occupancy-conflict` → `400` (a `tank`/`silo` holds exactly ONE SKU — names the holding SKU; runs before the hazard and capacity arms); every bulk placement REQUIRES reason `bulk-asset` → else `400 validation-failed` (the bulk arm answers before the generic six-code mismatch message), and `bulk-asset` on an ordinary bin → `400 validation-failed` (the signal stays queryable by placement class); `insufficient-on-hand` → `422` (retryable, key unconsumed) |
| GET | `/tenants/{t}/putaway/tasks` | — | Remaining work in the receiving bin |
| GET | `/tenants/{t}/putaway/placements` | — | Keyset |

## outbound — `outbound.controller.ts`

| Method | Path | Capability | Notes |
|---|---|---|---|
| POST | `/tenants/{t}/outbound/orders` | `orders.manage` | Body carries the required `destination` address (story 11-1); over-ATP is **accepted and backordered**, never refused |
| POST | `.../orders/{orderId}/cancel` | `orders.manage` | Releases holds atomically. Only from `accepted` |
| POST | `.../orders/{orderId}/pack` | `pack.execute` | Scan mismatch → `422 pack-mismatch` naming **both** quantities |
| POST | `.../orders/{orderId}/dispatch` | `dispatch.execute` | **Terminal.** Retires committed holds — the transition that corrects ATP. Auto-stamps the labelled shipment's `carrierCode`/`trackingNumber` (4.6c) |
| POST | `.../orders/{orderId}/label` | `labels.execute` | **One label per order** (4.6c): connection resolved + credential opened in-tx, the label arm synchronous. DIRECT carriers → verbatim `501 carrier-transport-unconfigured`; deployment key faults → `503 carrier-encryption-unavailable` / `carrier-credential-unreadable` |
| GET | `.../orders/{orderId}/shipment` | — | The order's label (4.6c); 404 = "no label yet" |
| GET | `.../orders/{orderId}/rates` | — | **The rate-shopping READ (4.6d)** — one quoted-or-refused item per live carrier connection, sorted by carrierCode; no Idempotency-Key, nothing stored. `409 missing-sku-weight` names the unweighted SKUs (cap 20) / `conflict` the not-ratable state or an over-2^53-gram aggregate; `503` credential arms — never an item |
| POST | `/tenants/{t}/outbound/manifests` | `labels.execute` | **All-or-nothing** (4.6c): ≤ 500 shipments, one connection, one tx |
| GET | `/tenants/{t}/warehouses/{w}/outbound/manifests` | — | Keyset, newest first |
| GET | `.../orders/{orderId}` | — | Echoes the `destination` (story 11-1); null on pre-11.1 rows |
| GET | `/tenants/{t}/warehouses/{w}/outbound/orders` | — | Keyset; `cursor`+`limit` only, so status filtering is page-scoped |
| POST | `/tenants/{t}/outbound/wave-policies` | `waves.manage` | A policy **is** the wave rule |
| GET | `/tenants/{t}/warehouses/{w}/outbound/wave-policies` | — | Keyset |
| POST | `/tenants/{t}/outbound/waves` | `waves.manage` | Omitted `orderIds` sweeps eligible orders oldest-first |
| POST | `.../waves/{waveId}/release` | `waves.manage` | Cutoff passed → `409 cutoff-passed`, **wave stays planned** |
| POST | `.../waves/{waveId}/cancel` | `waves.manage` | Frees orders to be re-waved |
| POST | `/tenants/{t}/outbound/picks` | `picks.execute` | **device.** The conflict taxonomy lives here: `pick-bin-short` 409 = re-plannable, `pick-unresolvable` 409 = terminal/quarantine, `insufficient-on-hand` 422 = retryable; 12-1 conformance gate `bin-storage-mismatch` → `400` when the drawn bin's class cannot satisfy the SKU's (defensive — the draw only walks bins the placement and merge gates already admitted); 12-3 authority gate → `403 role-denied` naming `secure.move` when the drawn bin is secure-class and the actor lacks `secure.move` (FR-42 — operator is refused; the wave pool stays role-blind, advisory suggestion / binding gate) |
| POST | `/tenants/{t}/outbound/packs` | `pack.execute` | **device** (10.7). Same `packOrder` command as the tenant pack route (which re-authorizes the device in-tx via `deviceId`), orderId in the body; no `dimensionsMm` on the device payload (`forbidNonWhitelisted` → 400). Scan mismatch → `422 pack-mismatch` naming **both** quantities; a revoked device → `403 device-revoked` |
| GET | `.../waves/{waveId}` | — | With picklists in walk order |
| GET | `/tenants/{t}/warehouses/{w}/outbound/waves` | — | Keyset |

## movements — `movements.controller.ts`

| Method | Path | Capability | Notes |
|---|---|---|---|
| POST | `/tenants/{t}/movements/transfers` | `transfers.manage` | **5-1.** Creates the draft two-leg plan. Refusals: `400 validation-failed` (catch-weight SKU fail-closed; batch- AND serial-tracked SKU; a serial-tracked line with fractional or >200-unit quantity — scannability guards; system bin on either end; sub-precision quantity), `409 kit-cannot-hold-stock`, `404` foreign ids. `Idempotency-Key` required |
| POST | `.../transfers/{transferId}/outbound-confirm` | `transfers.manage` | **5-1.** Per line-arm `transfer.outbound` events on the SOURCE chain (source bin → source IN-TRANSIT bin); status → `in_transit`; serials locked + moved. Source short → `409 transfer-source-short` (order stays draft). Optional per-line serial scans |
| POST | `.../transfers/{transferId}/inbound-confirm` | `transfers.execute` **(device)** | **5-1.** Accepts EITHER session family on the one route — `AnySessionGuard` branches on the `device_id` claim (badge-in required on the device arm; a bare enrollment credential → `401 unauthenticated`). Lands every line whole (no partial arm) in one tx: same-warehouse = relocation IN-TRANSIT→dest bin on one chain; cross-warehouse = drain (toBinId null) on the source chain + intake on the dest chain, ONE transaction. Runs the destination placement gates (`bin-blocked`/`bin-retired`/`bin-storage-mismatch`/`bin-segregation-conflict`/`bin-occupancy-conflict`/load gates → **409** with the gate's own code, order stays in_transit — unlike putaway's 400s, these are a conflict-class answer on a different surface); secure dest bin without `secure.move` → `403 role-denied`. Op payload's `binStateEpoch` compared under the locks → `409 transfer-bin-changed` (mobile classifies re-plannable). Epoch mismatch is the only staleness arm; a re-planned dest bin (scanned authoritative, epoch omitted) is a match |
| POST | `.../transfers/{transferId}/cancel` | `transfers.manage` | **5-1. Draft-only** — non-draft → `409 transfer-wrong-state`; no stock effect |
| GET | `/tenants/{t}/movements/transfers` | — | **5-1.** Keyset on `(createdAt, id)`; `status` + warehouse filters |
| GET | `/tenants/{t}/movements/transfers/{transferId}` | — | **5-1.** Both legs' ledger events in `(warehouseId uuid, seq)` order, each carrying `referenceDoc {kind:'transfer', transferId, lineId?}` |
| POST | `/tenants/{t}/movements/counts` | `counts.manage` | **5-3.** On-demand create — one stored task per bin, per-SKU expected quantities + `binStateEpoch` captured in-tx under locks; outbox `count.created`. Refusals: `404` unknown bin, `400 validation-failed` system bin (Receiving/QC-hold/In-Transit — counts target storage bins only), `409 count-task-open` on a bin with a pending task. `Idempotency-Key` required |
| POST | `.../counts/{taskId}/submit` | `counts.execute` **(device)** | **5-3.** Accepts EITHER session family (`AnySessionGuard`, badge-in required on the device arm). Every task line counted (0 valid only explicitly entered) → else `400 count-incomplete`; unknown/foreign skuId → `404`; the same SKU on two lines → `400 validation-failed`; already completed → `409 count-task-completed`. A counted skuId beyond the task lines appends a line with expected 0. Variance rows (`status open`) per differing SKU — counts NEVER write stock/ledger. The task's frozen epoch is compared for EQUALITY against the live epoch under the locks (`null` matches): mismatch flags the variance rows `epochConflict` AND auto-creates a fresh recount task for the bin in the same tx (OQ-2) — surfaced, never silently applied. `Idempotency-Key` required, hash mismatch → `422 idempotency-key-reuse` |
| PUT | `.../count-policies` | `counts.manage` | **5-3.** Upsert one row per (tenant, warehouse, class) — a class written twice in one body is upsert semantics (last interval wins, no 409). Takes the same tenant-scoped warehouse advisory lock the count commands take, so a policy write serializes against in-flight ticks. `400 validation`, `409` unique-violation race loser, `422 idempotency-key-reuse` on hash mismatch. `Idempotency-Key` required |
| PUT | `.../variance-policies` | `variances.resolve` | **5-4.** The per-tenant variance-threshold policy (one row per tenant, `unique(tenant_id)`; RLS `count_variance_policies_tenant_isolation`) — `quantityThreshold` nullable (**null = the flow is disabled**, the 5-2 GET-404 convention is NOT used here: the row upserts to null), BASE-units int4-ceilinged (`@IsInt @Max(2_147_483)`; fractional input refused at the wire). The threshold is FROZEN onto every variance row that submits under it (the `threshold_quantity_at_request` precedent); a later PUT cannot re-write history. Fingerprint hashing normalizes `?? null` — absent and explicit-null PUTs hash the same. The pen is the resolver set's (`variances.resolve`, CHECKPOINT 1), not `counts.manage`. `Idempotency-Key`; concurrent first-time PUTs → one 200, loser `409 conflict`; audit `count.variance_policy_updated` |
| GET | `.../variance-policies` | — | **5-4.** The policy row; unset → `404 not-found`. A read, never capability-gated |
| GET | `.../variances` | — | **5-4.** The resolution queue (5-5's surface) — keyset cursor pagination on `(created_at, id)` newest first, `?status=open\|adjusted\|recounted` + `warehouseId` filters; a read, never capability-gated (the resolving MUTATION is `variances.resolve`) |
| POST | `.../variances/{varianceId}/resolve` | `variances.resolve` | **5-4.** Two arms off the submit-frozen threshold stamp: `approve_adjust` — an explicit stock correction through `assertAdjustableInTx`/`applyAdjustmentInTx` (`reasonCode 'stock-count'`, ONE `stock.adjusted` event; guard-set refusals — retired bin, batch/serial/kit SKU — answer verbatim 400/409/422 with full rollback, the 5-2 re-execution discipline) whose owner-only gate applies only when `|delta| > threshold` (STRICTLY greater — at-threshold resolves by manager too and notifies no one); `recount` — opens the fresh count task as the new basis (`409 count-task-open` on a bin with a pending task, approve-arm only). Over-threshold variance → `403 variance-owner-required` below owner. Guards: 404 → 409 `variance-resolved` → `variance-owner-required` → 400 stale-seqs (each seq must hold in the variance's OWN warehouse's ledger, probed before any write) → `variance-basis-moved` 409 on the approve arm (`task.binStateEpoch` equality, the epoch guard) — recount is the stated remedy. `consideredEventSeqs` (≤ 200 ledger seqs; required non-empty on approve-adjust) is stored on the row and audited; outbox echo `count.variance.resolved` carries it (null when none stated). Batch/serial-tracked or kit SKUs refuse approve-adjust entirely — the correction always lands as exactly one `stock.adjusted` event. `Idempotency-Key`; the fingerprint hashes `normalizeConsideredSeqs` (deduped, ascending) so a reordered+duped retry replays 200; replay re-serves the stored snapshot |

## carriers — `carriers.controller.ts`

| Method | Path | Capability | Notes |
|---|---|---|---|
| GET | `/tenants/{t}/carriers` | — | The registry catalogue: code, display name, required credential fields |
| GET | `/tenants/{t}/carriers/connections` | — | **Public face only** — never the secret or the sealed blob |
| POST | `/tenants/{t}/carriers/connections` | `carrier.manage` | Already connected → `409 carrier-already-connected` |
| POST | `.../connections/{id}/rotate` | `carrier.manage` | Replaces material **in place**; the row id is the stable handle |
| POST | `.../connections/{id}/disconnect` | `carrier.manage` | **Hard delete.** Audit row survives |

## compliance — `compliance.controller.ts`

| Method | Path | Capability | Notes |
|---|---|---|---|
| POST | `/tenants/{t}/excursions` | `excursion.record` | Records a temperature excursion against a bin (FR-44, 12-5; **device arm 12-8**: accepts EITHER session family on the one route — `AnySessionGuard` branches on the `device_id` claim's presence; the device arm is badge-in required, and `RecordExcursionCommand` re-resolves the device row in-tx (`403 device-revoked`), its `deviceId` excluded from the payload hash): sweeps the bin's on-hand, quarantines every affected (sku, bin) scope through the ONE hold core (`holdScopeInTx` — ordinary QC holds, ATP exclusion falls out of `qcHeldUnits`), one zero-delta `excursion.recorded` ledger event per **affected** scope (including scopes already under an open hold — skipped for quarantine, still ledger-visible). All-or-nothing: any serial-tracked or catch-weight SKU refuses the whole excursion → `400 validation-failed` naming every offender and why; empty or system-owned bin → `400`; bin 404. `Idempotency-Key` required; same-key replay → same snapshot, different payload → `422 idempotency-key-reuse`. Secure-class bin + actor without `secure.move` → `403 role-denied` (the hold core's FR-42 gate) |
| POST | `.../excursions/{excursionId}/resolve` | `review.decide` | The review-status flip only (FR-44) — status → `resolved`, `resolvedBy/At` stamped, outbox `excursion.resolved` + audit. **Releases nothing**: stock disposition stays `qc.manage` release / `stock.adjust`. Unknown id → `404`; already resolved → `409 excursion-resolved`; `Idempotency-Key`; replay re-serves the snapshot |
| GET | `/tenants/{t}/excursions` | — | The review-queue read (12-7's Conflicts & Reviews), open to any member. Keyset on `(createdAt, id)`, `warehouseId` filter (foreign → `404`), `status=open|resolved` filter; malformed cursor → `400 invalid-cursor` |
| GET | `/tenants/{t}/warehouses/{w}/cold-chain/orders/{orderId}` | — | The FR-45 cold-chain trace (12-6), read-only from `ledger_events` alone — never projections, never the excursion rows. Per order line: one chain per picked batch/serial scope (each event annotated with the bins' CURRENT storage class — sound because the 12-1 class-edit guards refuse class changes that strand stock; the caveat is stated in the OpenAPI description), plus the excursions whose reading fell inside a scope's dwell window (`[first arrival, last departure]`, open-ended) at a chain bin, deduped per line. No pagination (bounded single-order read). Malformed ids → `400`; foreign tenant session → `403`; missing/foreign order or warehouse → `404 not-found` (an order of another warehouse in the same tenant is as invisible as a missing one); order with no dispatch events → `409 order-not-dispatched` |

## replenishment — `replenishment.controller.ts`

| Method | Path | Capability | Notes |
|---|---|---|---|
| PUT | `/tenants/{t}/replenishment/policies` | `replenishment.manage` | Upserts one per-warehouse reorder-point override — last-write-wins on (warehouse, sku). Non-positive / non-integer point or qty → `400 validation-failed` naming the field; unknown/foreign warehouse or sku → `404`; concurrent upsert → `409 conflict`. `Idempotency-Key` required; replay re-serves the snapshot, different payload → `422 idempotency-key-reuse` |
| DELETE | `.../policies/{policyId}` | `replenishment.manage` | Deletes the override — the SKU-column default resumes on the next sweep. Unknown id → `404`. `Idempotency-Key`; replay snapshot, conflict → `409`, `422` |
| GET | `/tenants/{t}/replenishment/policies` | — | The override table read, open to any member. Keyset on (warehouseId, skuId), `warehouseId`/`skuId` filters (foreign → `404`), malformed cursor / out-of-range limit → `400 invalid-cursor / validation-failed` |
| GET | `/tenants/{t}/replenishment/breaches` | — | The alert-queue read (open/recovered/actioned/dismissed, `status`/`warehouseId` filters). Keyset on (warehouseId, skuId) over one scope's frozen point+ATP rows. Malformed status/cursor → `400` |
| POST | `.../breaches/{breachId}/dismiss` | `replenishment.manage` | Dismisses an OPEN breach — its suggested-PO draft stays a draft (a planner may still submit it). Not open → `409 breach-not-open` naming the status; unknown id → `404`. `Idempotency-Key` |
| GET | `/tenants/{t}/replenishment/suggested-pos` | — | The draft-queue read, `status`/`warehouseId` filters, keyset. Malformed status/cursor → `400` |
| POST | `.../suggested-pos/{draftId}/submit` | `replenishment.manage` | Submits a DRAFT suggested PO as a REAL purchase order — the mint re-executes under `po.manage` on the SAME transaction (a holder of `replenishment.manage` without `po.manage` cannot exist by construction; the inner assert is the proof). Vendor/quantity edits optional (`quantityMilli` in milli-units, whole base units only — fractional → `400 validation-failed` naming the unit's precision); a vendor-less draft with no `vendorId` edit → `400 suggested-po-vendor-required`. Returns the FLAT PO snapshot — `body.purchaseOrder` IS the minted PO (`{id, code, status, vendorId, warehouseId, lines…}`), no wrapping carrier. Draft not a draft → `409 suggested-po-submitted`; PO code already in use → `409 conflict`; unknown id → `404`. `Idempotency-Key` |
| PUT | `/tenants/{t}/replenishment/expiry-policies` | `replenishment.manage` | Upserts the tenant-wide expiry/aging alert config (story 6-2, FR-23) — last-write-wins on the per-tenant unique; `{expiryLeadDays, agingThresholdDays}`, whole-day integers ≥ 0 (either may be 0 — no per-field disable; the ABSENT ROW is the disable mechanism). Negative/non-integer → `400 validation-failed` naming the field. `Idempotency-Key`; replay re-serves the snapshot, different payload → `422` |
| GET | `/tenants/{t}/replenishment/expiry-policies` | — | The config read-back, open to any member. **Absent row → `404 not-found`** — the 404 IS the "alerts are off" answer (the adjustment-policy precedent), not an error state. No row can exist for another tenant |
| GET | `/tenants/{t}/replenishment/batch-alerts` | — | The batch-alert queue read (story 6-2), open to any member: `expiry_upcoming|aged` kinds over the open/resolved/dismissed lifecycle, `kind`/`status`/`warehouseId` filters, keyset on (warehouseId, skuId, batchId, kind). Each row carries its LIVE `onHandMilli` (re-read at read time, never stored) and the `aged` rows' frozen `ageDays`. Malformed status/kind/cursor/out-of-range limit → `400` naming the query; foreign warehouse filter → `404` |
| POST | `.../batch-alerts/{alertId}/dismiss` | `replenishment.manage` | Dismisses an OPEN batch alert — bookkeeping on an evidence row, NO stock-side effect; while the batch still trips the tenant's thresholds with stock on hand the scan RAISES A FRESH alert on a later tick (the partial unique covers open rows only). Not open → `409 batch-alert-not-open` naming the current status; unknown/malformed id → `404`. `Idempotency-Key`; replay re-serves the snapshot, different payload → `422` |

## Infrastructure

| Method | Path | Notes |
|---|---|---|
| GET | `/api/v1/health` | anonymous |
| POST | `/api/v1/echo` | anonymous |
| GET | `/api/v1/openapi.json` | The contract. Swagger UI at `/api/docs` |
| ALL | `/api/v1/{*path}` | `NotFoundController` catch-all — **must map last**, which is why `ApiModule` registers after the spine modules |

---

## Capabilities

Thirty-two, in `tenancy/permissions.ts`, mirrored in `wms-fe/src/lib/users.ts` and checked by `check:capability-mirror` in CI. The 24th is `excursion.record` (12-5, FR-44): owner, Ops Manager and Operator — recording what the floor observes is a floor verb (`putaway.execute`'s rationale); it does **not** gate a resolve (`review.decide`'s). The 25th is `labels.execute` (4.6c): Owner, Ops Manager and Operator — label and manifest are floor verbs beside `pack.execute`/`dispatch.execute`. The 26th and 27th are 5-1's: `transfers.manage` (Owner, Ops Manager — planning the two-leg order, confirming outbound, cancelling) and `transfers.execute` (Owner, Ops Manager, Operator — the inbound confirm is the floor verb beside `putaway.execute`/`picks.execute`). The 28th is `adjustments.approve` (5-2): Owner and Ops Manager — deciding a pending stock adjustment is a manager verb, not a floor verb. The 29th and 30th are 5-3's: `counts.manage` (Owner, Ops Manager — on-demand count creation and the ABC policy surface) and `counts.execute` (Owner, Ops Manager, Operator — the floor verb beside `transfers.execute`; a device badge-in session is the submit actor). The 31st is `variances.resolve` (5-4): Owner and Ops Manager only — ratified at CHECKPOINT 1 (2026-09-29): resolving is one step above the floor that counts. Two role surfaces ride the capability: the policy pen (both roles) and the resolution gate (both roles) with the over-threshold owner-only carve-out (a command check on the submit-frozen threshold, not a capability split). The 32nd is `replenishment.manage` (6-1): Owner and Ops Manager — the planning set, the stock-intelligence surface's operator (reorder-policy writes, breach dismissal, suggested-PO submit; 6-2 extends the surface: the expiry/aging config PUT and batch-alert dismissal are the SAME capability — an aging threshold is inventory planning, the spec's rationale); the floor never acts on replenishment drafts, and the list reads are deliberately ungated (reads are never gated). The submit arm re-executes PO creation under `po.manage` on the same transaction, so a holder without `po.manage` cannot exist by construction — pinned by a holder-set test in `test/users.spec.ts`.

| Role | Holds |
|---|---|
| **Owner** | everything |
| **Ops Manager** | everything except `users.invite`, `users.role_change` |
| **Operator** | `putaway.execute`, `picks.execute`, `pack.execute`, `dispatch.execute`, `excursion.record`, `labels.execute`, `transfers.execute`, `counts.execute` — the floor verbs only |
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
