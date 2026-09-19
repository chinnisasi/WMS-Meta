---
title: 'Product variants'
type: 'feature'
created: '2026-09-19'
status: 'ready-for-dev'
route: 'dispatch'
review_loop_iteration: 0
baseline_commit: 'wms-be 126b592 / wms-fe 3dd9c96'
context:
  - '_bmad-output/implementation-artifacts/epic-11-context.md'
  - 'docs/design/SYSTEM-DESIGN.md'
  - 'docs/design/IMPLEMENTATION-GUIDE.md'
  - 'docs/design/modules/catalog.md'
  - 'docs/design/frontend/SYSTEM-DESIGN.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** SKUs are a flat list — a size×colour range renders as N unrelated rows, Epic 7's Shopify mapping is lossy by construction, and 11-6/11-7 have nothing to render or announce (FR-37; AD-19).

**Approach:** A `products` table above `skus` (grouping identity only: name + declared axes); `skus` gains a nullable `product_id` and a `variant_values` object keyed by the product's axes. Products get a create/list/edit API; SKUs attach to a product (and carry their axis values) through the existing SKU edit PATCH; import gains optional `product` / `variant_values` columns that reference an existing product. The ledger, reservations and every table below the catalog are untouched.

### Decisions (human-readable record of calls taken in planning)

- **AD-19 held exactly:** `products` carries identity only — no UoM, no tracking flags, no stock concept (a SKU remains every ledger event's unit). `product_id` is a bare uuid column with no FK, validated in the command transaction (the repo's no-FK convention).
- **Axes are declared on the product** (`axes`: 1–3 short axis names, e.g. `["size","colour"]`); each attached SKU's `variantValues` must cover **exactly** those keys, one value per axis (values ≤ 64 chars, non-empty). JSONB object with `$type<>` — the `responseSnapshot`/`referenceDoc` precedent; axes are presentation, and a normalized axis table buys nothing no consumer needs.
- **Product `name` is unique per tenant** (the `skus.code` precedent — import and the UI need an honest handle); duplicate → 409.
- **`axes` are immutable while the product has variants attached** (409 `product-has-variants`); renaming an axis would silently orphan every attached SKU's values. `name` always editable. No delete commands (append-only philosophy).
- **SKU attach rides the existing edit PATCH** (`productId` + `variantValues` optional on `PatchSkuDto`, the `hsn` template: absent = unchanged, `null` = detach and clear values) — no second write path. The spread hash means **pre-11.3 edit keys still replay 200** (same reasoning as 11-2, pinned by test).
- **Duplicate variants are refused:** two SKUs in one product carrying identical `variantValues` → 409 `duplicate-variant-values` (checked in the command transaction).
- **Import references, never creates products:** optional `product` column = an existing product's name (missing → per-row error, the uom-vocabulary precedent); optional `variant_values` cell with the `box:12` cell-grammar precedent (`size=M; colour=Red`), validated against the referenced product's axes. Import stays the only SKU creator and stays out of the product-creation business.
- **FE ships the regenerated client only** — the product/variant matrix is 11-6's deliverable (UX-DR28), the mobile announcement is 11-7's, and `SkuSummary`/the device snapshot are untouched (the 11-2 precedent).
- **Events:** `catalog.product_created`, `catalog.product_edited` — module-qualified past tense, appended in-transaction, never on replay.

## Boundaries & Constraints

**Always:**
- `variantValues` must exactly cover the referenced product's declared axes — missing key, unknown key, or empty value → 400 `validation-failed` naming `variantValues` and the offending axis.
- Product create/edit commands run the same replay machinery as `edit` (`hashCommandPayload` + `replay`, the `createOrder` convention); a matching hash replays the snapshot with no event.
- Everything tenant-scoped via `withTenantTransaction`, uuid-v7 PKs, `tenantTimestamps`, unique/index naming `<table>_<cols>_unique|idx` — the catalog module's standing conventions.

**Never:**
- No change to any of the 18 tables that reference `skus`, to the ledger, or to any command below the catalog (AD-19).
- No device catalog snapshot change, no mobile change, no channel-mapping tables (Epic 7), no kit/BOM modeling (11-4).
- No product deletion, no SKU create command, no rate/label behavior.
- No per-axis CSV columns (the closed-header contract would break); variant values enter import through the single `variant_values` cell or not at all.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Create product | `POST …/catalog/products {name: "Oversized Tee", axes: ["size","colour"]}` | 201; echoed; `catalog.product_created` emitted | duplicate name → 409 `duplicate-product-name` |
| Product list | `GET …/catalog/products` | keyset-paged `{items, nextCursor}`; items carry id, name, axes, skuCount, createdAt | N/A |
| Attach variant via SKU PATCH | `PATCH …/catalog/skus/:id {productId, variantValues: {size: "M", colour: "Red"}}` | 200; SKU edit + list responses echo `productId` + `variantValues`; `catalog.sku_edited` as before | N/A |
| Variant values mismatch | values missing an axis, unknown key, or blank value | 400 `validation-failed` naming `variantValues` + the axis | edit command, 400 |
| Duplicate variant | second SKU in one product with identical values | 409 `duplicate-variant-values`, nothing written | edit command, 409 |
| Detach | `PATCH …/catalog/skus/:id {productId: null}` | variantValues cleared with it; both read back `null` | N/A |
| Pre-11.3 replay | edit key minted before this story, same body | **200 replay** (absent keys drop from the hash) | N/A |
| Import with product columns | `product=Oversized Tee`, `variant_values=size=M; colour=Red` | SKU created attached; blank cells → no product / no values | row error if product missing or values mismatch axes |
| Import, unknown column | CSV header outside the closed set | 400 file-unreadable — closed contract unchanged | 400 |
| Axes edit, product attached | `PATCH …/products/:id {axes: [...]}` with skuCount > 0 | 409 `product-has-variants` | edit command, 409 |
| Axes edit, no variants | product with skuCount 0 | 200; new axes apply to future attachments | N/A |

</frozen-after-approval>

## Code Map

- `wms-be/src/shared/db/schema.ts` -- NEW `products` table after `skus` (id, tenantId, name, `axes: jsonb().$type<string[]>().notNull()`, tenantTimestamps; unique `(tenantId, name)`; `products_tenant_id_idx`, `products_created_at_id_idx`) + `skus` gains `productId: uuid('product_id')` (nullable) and `variantValues: jsonb('variant_values').$type<Record<string, string>>()` (nullable)
- `wms-be/drizzle/0032_product_variants.sql` + `meta/_journal.json` + snapshot -- CREATE TABLE products + 2 ADD COLUMNs + a row-local CHECK (the 0031 pattern, migration-SQL-only): `variant_values` is an object iff `product_id` is set
- `wms-be/src/modules/catalog/product.command.ts` (NEW) -- `ProductCommand.create/edit/list` with the `createOrder` replay convention (`hashCommandPayload`, `replay`, snapshot + outbox in-transaction); create/edit keyed by idempotency-key header; list keyset-paged (`created_at, id`), items carry `skuCount`
- `wms-be/src/modules/catalog/sku.command.ts` -- `EditSkuCommand` gains optional `productId`/`variantValues`; validation behind the replay lookup: product exists (404), values exactly cover its axes (400), duplicate-variant check in-transaction (409); response echo
- `wms-be/src/modules/catalog/catalog.dto.ts` -- `CreateProductDto`/`PatchProductDto`/`ProductResponse`/`ProductListResponse`; `PatchSkuDto`/`SkuResponse` gain `productId`/`variantValues`; new error codes `duplicate-product-name`, `duplicate-variant-values`, `product-has-variants`, `empty-product-edit`
- `wms-be/src/modules/catalog/catalog.controller.ts` -- `POST/GET /tenants/:t/catalog/products`, `PATCH /tenants/:t/catalog/products/:productId`; `GET …/catalog/skus` gains an optional `productId` filter; openapi re-export
- `wms-be/src/modules/catalog/import.command.ts` -- OPTIONAL_COLUMNS + `product`, `variant_values`; product name resolves like `uom` (row error when unknown); variant-values cell parser (split `;`, each `axis=value`, trimmed) validated via the same command-side rules
- `wms-be/test/products.spec.ts` (NEW) -- the I/O matrix incl. the pre-11.3 replay pin and raw-SQL CHECK probes
- `wms-fe/src/lib/api/generated/` -- `bun run api:generate` only (drift guard); no UI — the matrix is 11-6
- meta `docs/` -- `docs/design/modules/catalog.md` (products entity, seam table, flows), `API-SURFACE.md` rows, `docs/repos/wms-be/README.md`, `PENDING.md` (Epic 7 mapping note)

## Tasks & Acceptance

**Execution:**
- [ ] `wms-be/src/shared/db/schema.ts` + `drizzle/0032_product_variants.sql` -- products table + skus.productId/variantValues + row-local CHECK, `db:generate` + rename + snapshot -- the model's spine
- [ ] `wms-be/src/modules/catalog/product.command.ts` (NEW) -- create/edit/list with replay machinery -- the product write boundary
- [ ] `wms-be/src/modules/catalog/sku.command.ts` -- attach/detach + values validation behind replay -- the variant write boundary
- [ ] `wms-be/src/modules/catalog/catalog.dto.ts` + `catalog.controller.ts` -- DTOs, three new routes, SKU list filter -- the wire contract
- [ ] `wms-be/src/modules/catalog/import.command.ts` -- 2 new optional columns + parsers -- the closed-header contract grows again
- [ ] `wms-be/test/products.spec.ts` (NEW) + `catalog.spec.ts` check -- I/O matrix incl. replay pin -- the proof
- [ ] `wms-be` -- re-export `openapi.json` -- drift guard
- [ ] `wms-fe/src/lib/api/generated/` -- `bun run api:generate` -- FE drift guard passes
- [ ] meta `docs/` -- module doc, API surface, PENDING, repo contract -- keep the docs true

**Acceptance Criteria:**
- Given a product created with axes and two SKUs attached with distinct values, then the product list shows skuCount 2 and both SKU responses echo the attachment; a third SKU reusing values is refused 409.
- Given an edit or import row with mismatched variant values, then the API or import run refuses it by name, and nothing partial is written.
- Given an in-flight idempotency key minted before this story (SKU edit) or in this story (product create), then an identical call replays 200 with no duplicate event.
- Given the openapi export and the FE generated client, then both regenerate with zero drift-guard failures.

## Implementation Notes

## Spec Change Log

## Review Triage Log

## Design Notes

- **Why jsonb values, not a normalized axis-value table:** the values are an identity/presentation blob consumed by three future surfaces (11-6 matrix, 11-7 announcement, Epic 7 mapping) — all read the whole object. A normalized table would add a join per surface and change nothing for AD-19's isolation, since `skus` already owns the row.
- **Why the import references instead of creating:** import-created products would have no axes, and variant values must be validated against declared axes — auto-declaring axes from the first CSV row's keys makes the product's axes an implicit side effect. A per-row error naming the missing product is honest and matches the uom-vocabulary refusal.
- **Why the duplicate-variant check is command-side:** the repo's no-FK convention; a partial unique index over a jsonb expression would work but the command transaction already resolves the product, so the check costs one indexed query there.

## Verification

**Commands:**
- `wms-be`: `bun run db:migrate && bun run db:verify` -- expected: migrations apply, round-trip proves schema↔migrations match
- `wms-be`: `npx jest` -- expected: all suites green incl. the new `products` suite
- `wms-be`: `npx tsc --noEmit && npx eslint .` -- expected: clean
- `wms-be`: `bun run openapi:export && git diff --exit-code openapi/` -- expected: only the intended contract additions
- `wms-fe`: `bun run api:generate && git diff --exit-code src/lib/api/generated && bun run test && bun run typecheck && bun run lint && bun run build` -- expected: green

**Manual checks (if no CLI):**
- None beyond the CLI — no FE surface in this story.