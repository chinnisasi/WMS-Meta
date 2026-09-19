---
title: 'Product variants'
type: 'feature'
created: '2026-09-19'
status: 'done'
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
- [x] `wms-be/src/shared/db/schema.ts` + `drizzle/0032_product_variants.sql` -- products table + skus.productId/variantValues + row-local CHECK, `db:generate` + rename + snapshot -- the model's spine
- [x] `wms-be/src/modules/catalog/product.command.ts` (NEW) -- create/edit/list with replay machinery -- the product write boundary
- [x] `wms-be/src/modules/catalog/sku.command.ts` -- attach/detach + values validation behind replay -- the variant write boundary
- [x] `wms-be/src/modules/catalog/catalog.dto.ts` + `catalog.controller.ts` -- DTOs, three new routes, SKU list filter -- the wire contract
- [x] `wms-be/src/modules/catalog/import.command.ts` -- 2 new optional columns + parsers -- the closed-header contract grows again
- [x] `wms-be/test/products.spec.ts` (NEW) + `catalog.spec.ts` check -- I/O matrix incl. replay pin -- the proof
- [x] `wms-be` -- re-export `openapi.json` -- drift guard
- [x] `wms-fe/src/lib/api/generated/` -- `bun run api:generate` -- FE drift guard passes
- [x] meta `docs/` -- module doc, API surface, PENDING, repo contract -- keep the docs true

**Acceptance Criteria:**
- Given a product created with axes and two SKUs attached with distinct values, then the product list shows skuCount 2 and both SKU responses echo the attachment; a third SKU reusing values is refused 409.
- Given an edit or import row with mismatched variant values, then the API or import run refuses it by name, and nothing partial is written.
- Given an in-flight idempotency key minted before this story (SKU edit) or in this story (product create), then an identical call replays 200 with no duplicate event.
- Given the openapi export and the FE generated client, then both regenerate with zero drift-guard failures.

## Implementation Notes

**2026-09-19, implementation session** — wms-be b48e83d, wms-fe bdeeaa5, meta e0dda4f (diff verified line-by-line against this spec; my own full verification ran green).

- **All nine tasks landed as specced.** The one Code-Map addition: the migration also carries **RLS `products_tenant_isolation`** (hand-appended, the every-tenant-scoped-table convention — `products` is a new tenant-scoped table, so the fail-closed single-dimension policy is not optional) and the SKU list's optional `productId` filter was already in the Code Map. Both agent additions are pinned by tests (RLS probe, CHECK probes).
- **Gating rides `sku.edit` — the deliberate call, verified faithful:** `ProductCommand.create/edit` call `assertPermission(..., 'sku.edit')` inside the transaction (re-read from the DB each time), the controller OpenAPI docs say so, and no new capability exists in `permissions.ts`. Correct: the story ships no FE surface beyond the regenerated client, so a new capability would fail the FE capability-mirror guard; the frozen matrix never names a product capability.
- **The `postgres.js` discovery (real, pinned in-test):** a bare string parameter double-encodes into a jsonb STRING, so the raw-SQL CHECK probe uses `sql.json({size: 'M'})` — recorded as a comment at the probe site and worth remembering for any future raw jsonb write.
- **Value normalization is shared:** `assertVariantValues` + `normalizeVariantValues` (one validator, the `sku-attributes.ts` pattern) mean a stored `variantValues` is always the trimmed object; the edit path's SQL jsonb equality and the import path's sorted-keys fingerprint therefore agree (Postgres jsonb equality is key-order independent too).
- **Import enforcement detail:** the resolution pass runs BEFORE the duplicate loop; a row refused for a missing product frees its `sku_code` (a later row may claim it — correct first-commit semantics); duplicate variants are enforced both file-internally (naming the earlier row) and against the tenant's existing attached SKUs (naming the SKU's code), one query for the whole file.
- **Edge semantics beyond the matrix, deliberate:** a PATCH re-declaring the product's axes IDENTICALLY while attached is a 200 no-op (the element-wise comparison 409s only a changed declaration — reordered/respelled arrays are refused; a reordered array is pinned by test) — the 409 exists to prevent orphaning, and identical axes orphan nothing; a values-only PATCH re-values against the CURRENT attachment; `variantValues` riding a detach is refused 400, not silently dropped.
- **Verification gap to carry into review:** the products list test asserts page-1 shape and `skuCount` but does not drive keyset pagination past one page (the `nextCursor` mechanics are exercised only by code reuse of the sku.list pattern).

## Spec Change Log

## Review Triage Log

**Review of the implemented diff (step-04, iteration 0) — three layers: blind-hunter (15), edge-case-hunter (5), verification-gap (4 headline + an artifact note). 24 findings, verdicts rendered after verification at cited locations.**

| # | Finding | Verdict | Evidence / route |
|---|---------|---------|------------------|
| 1 | `countAttachedSkus`/`import.command.ts` have unbalanced parens (cannot compile) | false | `od` byte-dumps: line 576 ends `productId)));`, import line 291 ends `id))];` — both balanced. The rendered diff drops a paren in long lines (the verification-gap layer independently flagged the same transcription artifact). tsc 0, 651/651 tests green |
| 2 | `drizzle/meta/0032_snapshot.json` missing from the diff | false | File committed (152,832 bytes); excluded from the review diff as generated. `db:verify` round-trip green proves schema↔migrations match |
| 3 | `ProductCommand.edit`'s UPDATE has no unique-violation backstop — a concurrent rename losing `products_tenant_id_name_unique` is a raw 500, create maps it | low | Confirmed: edit's catch wraps only the key insert. → **patch** (wrap like create, map to `duplicateProductName`) |
| 4 | SKU attach/re-value + import resolution plain-SELECT the product — concurrent axes edit can orphan coverage; concurrent identical attaches both pass the duplicate check | medium | Confirmed: `ProductCommand.edit` takes `for('update')` but the three other product reads take no lock; read-committed allows the interleaving. One `.for('update')` per site serializes every product-row writer (closes all three windows). → **patch** |
| 5 | POST `/catalog/products` answers 201 but declares `@ApiOkResponse` — openapi + FE client carry only 200 | low | Confirmed: controller:227 `ApiOkResponse` with `@HttpCode(CREATED)`; the import route (:156) declares `status: CREATED` — mixed precedent, this route should follow it. → **patch** |
| 6 | `GET …/catalog/skus?productId=` ships untested | low | Confirmed (verification-gap headline 1): no request in any suite carries the param; a filter regression leaves all list tests green. → **patch** (test) |
| 7 | `catalog.sku_edited` payload unchanged on attach/detach | false | The frozen matrix pins `catalog.sku_edited` **as before**; the deferred consumers are recorded in PENDING.md. A payload change would contradict the spec |
| 8 | 0032 header comment: "needs no fail-fast re-run guard: CREATE TABLE and ADD COLUMN cannot be applied twice" is wrong for the appended ADD CONSTRAINT/POLICY | low | Confirmed: those statements are not re-runnable; the journal is the actual guard (the 0028/0031 pattern). Comment reword. → **patch** (docs) |
| 9 | `variant_values` cell grammar has no `;`/`=` escaping | low | Rejected: the `uom_conversions` cell grammar (`box:12;case:144`) carries the identical limitation, equally undocumented — consistent grammar; everyday variant values (`M`, `Red`) rarely contain separators; a fix adds escaping machinery |
| 10 | Unknown-key error message reads inverted ("has no axis") | false | "variantValues has no axis \"fit\" on this product" states the correct fact — the product does not declare `fit` — and reads differently from the missing-key arm ("is missing the axis \"colour\"") |
| 11 | `validateRow` comment: a product cell without values "fails the coverage check … naming the missing axis" | low | Confirmed wrong: the null branch throws "variantValues must be an object…", naming no axis; the test asserts only `variantValues`. → **patch** (comment) |
| 12 | PENDING.md: channel-mapping tables "still 11-4's deliverable" | low | Confirmed wrong: epics.md — Epic 11 "Gates **Epic 7's** channel mapping"; 11-4 is kits/bundles. → **patch** (docs) |
| 13 | README's documented import header omits the 11.2 columns | low | Pre-existing: the line is unchanged by this diff (stale since 11-2's columns). Not caused by this story. → **defer** |
| 14 | `decodeCursorSafe`/axes-decorator duplication instead of reuse | false | 12 per-file `decodeCursorSafe` copies repo-wide — per-command self-containment is the established pattern; the shared-validator rule applied to `assertVariantValues` because two callers enforce ONE rule |
| 15 | `ProductSnapshot.createdAt` Date/string duality; create route's 400 text names `empty-product-edit` | low | createdAt: false by precedent — `sku.command.ts:82/658` types it identically and populates from the row; wire JSON is identical. The 400-text half is real (only the PATCH can produce it). → **patch** (docs, folded with #8/#11) |
| 16 | verification-gap: `productId` filter untested | low | Pre-verified by the layer's filed evidence. → **patch** (test) |
| 17 | verification-gap: products keyset pagination never driven past page 1 | low | Pre-verified (also acknowledged in Implementation Notes). → **patch** (test) |
| 18 | verification-gap: `ne(skus.id, …)` self-exclusion untested on both branches | low | Pre-verified: no test re-submits a SKU's own current values; dropping the clause would 409 legitimate retries with CI green. → **patch** (test) |
| 19 | verification-gap: empty-patch message pin does not adopt `productId`/`variantValues` | low | Pre-verified: the `sku-attributes.spec.ts:293` loop asserts only the five 11-2 names. → **patch** (test) |
| 20 | edge-case: edit unique-violation → 500 on rename race | low | Same defect as #3 — one root cause, grouped |
| 21 | edge-case: attach commits after the axes edit's empty-attach check → values orphaned by construction | medium | Same defect as #4 — one root cause, grouped |
| 22 | edge-case: two concurrent attaches with identical values both pass the command-side check — duplicate variants land | medium | Same root cause as #4: the `for('update')` lock serializes every product-row writer, so the second attach re-reads committed state and refuses. Grouped |
| 23 | edge-case: contract/FE client carry no 201 shape for POST products | low | Same defect as #5 — grouped |
| 24 | edge-case: malformed (non-uuid) `productId` path param → Postgres 22P02 → 500 instead of 404 | low | Confirmed: `ProductCommand.edit` runs `eq(products.id, …)` with no shape guard, while the attach path in this same diff added exactly that guard. → **patch** |


**Patch round (iteration 0 → patch, no loopback):** all nine groups landed in wms-be e8140db + meta f2de0f2 (+ FE regen 23711ad, mine). **The new keyset test found a real defect beyond the review findings:** `ProductCommand.list` handed `buildPage` the pre-sliced `pageRows` instead of the full `limit+1` batch, so `nextCursor` was always null and every product list collapsed to one page — fixed to the `sku.list` shape (the full batch decides the cursor) and pinned by the walk-to-exhaustion test. Deferred #13 (README header staleness) remains recorded in deferred-work.md below this story's lifetime — pre-existing, untouched.

**Routing:** no intent_gap, no bad_spec. Nine patch groups: product-row locking (#4/#21/#22 — the one `.for('update')` fix, medium); edit unique-violation backstop (#3/#20); openapi 201 declaration (#5/#23, FE regen with it); malformed-productId guard (#24); test gaps (#6/#16 filter, #17 keyset, #18 self-exclusion, #19 empty-patch message); docs+comments (#8, #11, #12, #15's 400-text). One defer: #13 (README header staleness, pre-existing). Rejected: #1, #2, #7, #9, #10, #14, and #15's createdAt half.

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