---
title: '1.4b SKU deactivation — an inactive SKU takes no new inbound, kits or listings, and sells down what is left'
type: 'feature'
created: '2026-10-20'
status: 'ready-for-dev'
baseline_commit: '25a3ba12c78bb1d70469a814f4c9e55187e5b296'  # wms-be; wms-fe: 1d5e6124e9ce048fc016e4c4dab386e1216168bc; wms-mobile: cdb97773e0a61a6c8a36bb38d72205019553e460
route: 'dispatch'
review_loop_iteration: 0
context:
  - 'docs/initiatives/production-readiness.md'
  - 'docs/design/SYSTEM-DESIGN.md'
  - 'docs/design/IMPLEMENTATION-GUIDE.md'
  - 'docs/design/modules/catalog.md'
  - 'docs/design/modules/partners.md'
  - 'docs/design/modules/outbound.md'
  - 'docs/design/modules/inbound.md'
  - 'docs/design/modules/channels.md'
  - 'docs/design/modules/replenishment.md'
  - 'docs/design/frontend/IMPLEMENTATION-GUIDE.md'
  - 'docs/design/mobile/IMPLEMENTATION-GUIDE.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** A client discontinues a product, and there is no way to say so. A SKU cannot be deleted (history), and nothing marks it retired. So it stays on every picker, new POs, ASNs and kits can name it, and marketplaces keep selling it. Roadmap rule: "master records deactivate, never delete".

**Approach:** `skus.status` (`active` | `inactive`) plus an optional reason, flipped by one status route on the web SKU table (the partners precedent).

An inactive SKU:
- **refuses** new inbound (PO, PO amend, ASN, ASN amend, portal ASN, ASN import), kit composition and new channel mappings;
- **sells down**: an order line for it is accepted only if stock covers it in full, with no backorder;
- **publishes zero** to every channel it is mapped to;
- **stays visible** on every existing document, list and stock read.

**Decisions (user, 2026-10-20):**
1. **Stop inbound, sell down.** Deactivation is allowed whatever stock or open work exists. An order (manual, ingested or channel) is accepted for an inactive SKU only when its whole line can be reserved. A shortfall refuses the order with 409 `sku-inactive` rather than backordering it. A kit line is short when its kit SKU or any component is inactive and the kit cannot be reserved in full.
2. **Dock scans are accepted and flagged.** Receiving against an existing PO/ASN line of an inactive SKU continues, unflagged. A blind-receipt line or an unmatched line of an inactive SKU is booked as today, and the receipt also raises one server-raised review row `grn.inactive-sku-received` listing those lines. That row's only decision is `discard`, which the web labels **Acknowledge**; it books nothing. The handheld warns at scan time.
3. **Channels publish zero.** The mapping is kept, and the sync publishes `0` for an inactive SKU without reading ATP. Reactivating resumes the real quantity on the next tick. A new mapping to an inactive SKU is refused.
4. **Returns are allowed.** RMA create, return receipts and their disposition ignore SKU status.

**Decisions (agent):**
5. **Allowed regardless of status:** stock moves (putaway, transfers, merge), counts, adjustments, picks and packs of existing orders, QC, product attach, client correction, SKU edit and packaging edit, reorder-policy edits, and **PO close with carried lines** (a carry continues inbound already ordered, as the vendor-snapshot carry does).
6. **Who:** `sku.edit` (owner, ops manager). No new capability.
7. **Replenishment:** the reorder sweep treats an inactive SKU like a departed client's: it recovers any open breach, raises nothing, and **dismisses the SKU's standing suggested-PO draft**. The expiry scan is unchanged, because the stock still exists.
8. **Existing kits:** deactivating a component does not change any kit. A kit PUT refuses only components the stored composition did not already hold. Orders of that kit fall under decision 1.
9. **"New" is judged by SKU against the document's stored state** (design review). On PO and ASN amend, a guarded SKU is any SKU in the request that is not on the document's existing lines; this also catches a kept line re-pointed to an inactive SKU. **Raising** the ordered or expected quantity of an existing inactive line is also refused, because it is new inbound; lowering it is allowed. On channel mappings, a guarded pair is any `(externalRef, skuId)` not in the stored set. On kit PUT, any component not in the stored composition is guarded.
10. **Web order entry keeps inactive SKUs**, labelled "{code} — inactive, sells existing stock only" (decision 1). Every other document picker drops them, except for SKUs already on the document.
11. **Channel buffers are untouched.** A standing buffer of an inactive SKU keeps holding its units, and reactivation restores everything as it was. The sell-down detail names the available quantity, which excludes buffered units. The deactivate panel says to clear the SKU's buffers so those units can sell by hand. Lines already backordered for the SKU are not re-planned (the deactivate panel says so, and a PENDING entry records it).
12. **A channel order refused for an inactive SKU is a validation failure, not a backorder refusal.** Ingest answers a typed 422 `sku-inactive` (metered `validation-failed`, as `client-departed` is), so it is not redelivered. It writes no `ingest_backorder_refusals` row and does not count toward the "prevented" KPI.
13. **Errors run in this order everywhere:** SKU 404 → client checks (`mixed-client`, `client-departed`) → `sku-inactive` → anything that comes later in the command (vendor, …). The lock order is client, then SKU. One test pins the order.
14. **Reason:** optional; trimmed in the command, and the trimmed value is what gets stored. Blank after trimming counts as absent. Its limit is 500 code points (400 above). A new reason on an inactive SKU replaces the old one; it cannot be cleared except by reactivating.

## Boundaries & Constraints

**Always:**
- **Migration 0082 (`skus` status):**
  - New columns: `status text NOT NULL DEFAULT 'active'` and `inactive_reason text`.
  - CHECKs:
    - `status IN ('active','inactive')`;
    - the reason is NULL unless the status is inactive;
    - `char_length(inactive_reason) BETWEEN 1 AND 500`.
  - Trimming happens in the command (decision 14), not in a CHECK.
  - Then an assert step and the vocabulary pin (`SKU_STATUSES`, guide §4).
  - Commit `meta/0082_snapshot.json` and its journal entry; `db:generate` must report no changes.
- **Status route:** `PATCH /tenants/:t/catalog/skus/:skuId/status` with body `{status, reason?}`, needing `sku.edit`.
  - It runs in the partners `updateStatus` order: hash (discriminator `command: 'sku.status'`) → replay → shape checks → SKU `FOR UPDATE` → replay again → apply.
  - `reason` sent with `active` is 400 `validation-failed`.
  - Reactivating clears the reason.
  - No-op: the same status, with the same reason or no reason. It stores the key under arm `skus.status:unchanged` (add to `AUDIT_NO_OP_ARMS`) and writes no outbox message.
  - Audit actions: `sku.deactivated`, `sku.reactivated`, and `sku.edited` (existing) for a new reason. The first two join `AUDIT_NEW_ACTIONS`, each with an `expectAuditRow` pin.
  - Outbox: `catalog.sku_edited`.
  - Response: `{ sku: SkuResponse }`.
- **`SkuResponse` gains** required `status` and `inactiveReason`. `normalizeStoredSku` serves `?? 'active'` and `?? null` on every stored snapshot.
- **`GET …/catalog/skus`** gains an optional `status` filter. When it is absent, every SKU is listed (display lookups depend on that).
- **The guard:** `assertSkusTakeWorkInTx(tx, tenantId, skuIds)` in the catalog facade.
  - It locks `FOR KEY SHARE` in id order and throws 409 `sku-inactive`, with `extensions.skuCodes`.
  - It runs after replay and dedup, at the decision-13 position.
  - **Callers:**
    - PO `createInTx` (covers suggested-PO submit);
    - PO amend and ASN amend (decision 9);
    - ASN `create` and the portal `announce`;
    - ASN import: a row error. `sku-inactive` is added to `ASN_IMPORT_ROW_ERROR_CODES` and the DTO enum, and every matching row of a group gets it (the `client-departed` precedent at `asn-import.command.ts:349`);
    - kit create (kit SKU and every component) and kit PUT (decision 9; read the **full** stored composition, not today's `.limit(1)` probe);
    - **the catalog import's `kit_components` pass:** a row error `sku-inactive`; its rows are already locked `FOR UPDATE` (`import.command.ts:731`);
    - channel mappings: `setConnectionMappings` and `setChannelMappings`. Read the stored set under the connection lock before the delete; only added pairs are guarded (decision 9).
  - Every caller file joins a new architecture list, `SKU_TAKES_WORK_CALLERS`.
- **Order create** (`order.command.ts createOrder`):
  - **Phase 1:** the loader (`assertSkuIdsInTenant`, `:1505`) returns `code` and `status`.
  - **Phase 2.5:** a short inactive line refuses the order, whatever the policy, after releasing every grant. Short lines are found with the `policyShortLines` logic.
    - For a kit, `skuCodes` names the inactive kit SKU and components, and the detail says "the kit could not be reserved in full", with no per-component quantity. A failed kit releases its holds, so per-child numbers would be wrong.
    - Manual orders get 409 `sku-inactive` with `skuCodes` and the available quantity.
    - Ingest gets decision 12's 422, through a new `mapIngestRejection` arm.
  - **Phase 3**, after `assertClientTakesWorkInTx`, uses a second facade function, `lockSkuStatusesInTx(tx, t, ids)`.
    - It takes `FOR KEY SHARE` in id order (kit create locks `FOR UPDATE` in id order, so the same order avoids deadlock) and returns status and kit-ness.
    - A short inactive line is refused as in phase 2.5.
    - A plain line whose SKU gained a kit composition is refused with a new 409 `order-catalog-changed` ("the catalog changed while the order was placed — retry"). Ingest lets it surface, so the delivery retries.
    - The outer catch (`:903`) releases the grants on both refusals; today it handles `DedupLostError` only.
    - `order.command.ts` is pinned to call it.
  - A fully reserved inactive line is accepted, with nothing marked.
- **Kit race (PENDING catalog):** phase 3 closes the in-flight race. The **narrowed** entry stays open: a zero-grant (backordered) order line holds nothing, so a later kit create passes `assertKitSkuHoldsNoStock`.
- **Channel publish:** `computePublishedScopes` reads the statuses of the mapped SKUs in one batched read, and publishes `visibleMilli: 0` for an inactive SKU at every warehouse with no ATP read. The retry path goes through it via `preparePublication`, so this is one change.
- **Receiving** (`receiving.command.ts`):
  - **Which lines:** blind and unmatched lines whose SKU is inactive that were **booked**. A line refused as client-mismatched or short-dated is not listed again.
  - One `grn.inactive-sku-received` row per receipt, in the same transaction. Its id comes from its own function, `inactiveSkuGrnLinesOpId` (the `refusedGrnLinesOpId` pattern).
  - Payload: `{grnId, grnCode, lines:[{skuId, skuCode, qty, uom}]}`. The wind-down matcher reads `lines[*].skuId`.
  - The GRN snapshot gains optional `inactiveSkuReviewOpId`, present only when a row was raised, so older snapshots stay byte-identical.
  - The shelf-life Apply re-run raises its own row for the inactive lines it books.
  - In `sync-report.command.ts`, the type is added to `REJECTED_OP_TYPES`, `SERVER_RAISED_ONLY_OP_TYPES`, `REJECTED_OP_DECISIONS_BY_TYPE` (`['discard']`), the `ApplicableOpType` exclusion, and `SKU_NAMING_OP_TYPES`. The rejected-op `opType` DTO enum is widened.
- **Reorder sweep** (`replenishment.sweep.ts`): an inactive arm beside the departed arm (decision 7).
- **Device snapshot:** `CatalogSnapshotSkuDto` and `SkuSummary` gain `status`. **Portal:** `portal/skus` excludes inactive SKUs on the server (as it does kits), and `PortalSkuDto` is unchanged.
- **OpenAPI:** run `bun run openapi:export` and commit `openapi/openapi.json`.
- **Web:**
  - **SKU table:**
    - A Status column ("Active", "Inactive", "Inactive — {reason}").
    - Deactivate copies the partners `DeactivatePanel` (reason ≤ 500, `parseReason`, stable `keyRef ??= ulid()`). Its copy covers decisions 1, 3 and 11: new POs, ASNs and kits refuse the SKU; orders sell down stock only; channels show 0; clear buffers to sell buffered units; backorders will not fill.
    - Reactivate uses `ConfirmRow`. Both are behind `sku.edit`.
    - A new `fetchApiUpdateSkuStatus` wrapper, a `skuStatusReason(error, action)` helper, and `notifyCatalogChanged()` after a change.
    - A status filter (All / Active / Inactive). `fetchApiListSkus` and `useSkus` gain `status`, which goes into the `requested` cursor scope and the DataTable `key`.
    - The Kit (create) button is hidden on an inactive row.
  - **Pickers:**
    - Order entry follows decision 10.
    - Staff ASN create drops inactive SKUs. ASN amend keeps SKUs already on the ASN (`withoutKits` keep-set).
    - Kit compose drops inactive SKUs, and kit PUT keeps the stored components.
    - `MappingEditor` (`channels-view.tsx:1334`) drops inactive SKUs from new rows. A stored inactive row is kept and marked "Inactive — publishes 0".
  - **Markers:** one `skuInactiveMarker` helper, used in mapping rows, `SuggestedPoCard` and ASN detail lines.
  - **Reason helpers:** add `sku-inactive` to `asnReason`, `portalAsnReason`, `kitReason`, `createReason` (plus `order-catalog-changed`), `setMappingsReason` (`src/lib/channels.ts:432`), the catalog import's reason, and the `ASN_IMPORT_REASON_LABEL` record. `submitSuggestedPoReason` gets its arm **ahead of** its verbatim-409 branch.
  - **Review queue:**
    - a `rejectedOpSummary` arm for the new type;
    - a "flagged" badge instead of "refused";
    - guidance text: "Booked — {code} is inactive; check why it arrived";
    - the discard button labelled **Acknowledge** for this type, with outcome words "Acknowledged" / "Not acknowledged".
- **Mobile:**
  - `parseCatalogSnapshot` defaults `status` to `'active'`, and an unknown value also becomes `'active'`. `CatalogSku.status` is required.
  - The legacy-seal pins at `device-store.test.ts:222` and `:291` gain `status: 'active'`, with the explicit comment discipline.
  - The receive `'sku'` result gains an optional `warning`. `applyResolvedSku` sets it for any inactive SKU that is not on the document, including those accepted through `confirm-other-client` and `choose-client`, and appends it to the banner: "{code} is inactive — received and flagged for review".
  - No replay fate change.

**Never:**
- No deleting a SKU.
- No automatic unmapping or buffer release.
- No re-planning of existing backorders.
- No refusing picks, packs, moves, counts, adjustments, QC, PO carry or returns of an inactive SKU.
- No status filter on display lookups or stock reads.
- No scheduled or bulk status change.
- No portal deactivation.
- No new capability.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected | Error |
|---|---|---|---|
| Deactivate | active SKU, 40 on hand, open PO, `{status:'inactive', reason:'discontinued'}` | status inactive, audit `sku.deactivated`; PO keeps receiving | N/A |
| No-op | inactive with reason X, `{status:'inactive'}` | 200, key stored, no audit row | N/A |
| Reason on active | `{status:'active', reason:'x'}` | unchanged | 400 `validation-failed` |
| New PO / ASN / portal ASN | line names an inactive SKU | nothing written | 409 `sku-inactive` `{skuCodes}` |
| ASN amend | keep an inactive line, add an active one | 200 | N/A |
| Amend re-point / raise | kept line's SKU changed to an inactive one, or an inactive line's qty raised | unchanged | 409 `sku-inactive` |
| Mapping re-PUT | set re-sent with a stored inactive pair kept, one active pair added | 200 | N/A |
| Precedence | departed client + inactive SKU on a PO | nothing written | 409 `client-departed` |
| Order sells down | inactive, ATP 40, order qty 30 | accepted, line `open` | N/A |
| Order short | inactive, ATP 20, qty 30 (any backorder policy) | grants released, no order | 409 `sku-inactive` (manual); 422 `sku-inactive`, no refusal fact (channel) |
| Race | deactivated between phase 1 and phase 3, line short | rolled back, grants released | 409 `sku-inactive` |
| Kit | new kit with an inactive component | nothing written | 409 `sku-inactive` |
| Channel | inactive mapped SKU, 40 on hand | publishes 0 at every warehouse | N/A |
| Blind receipt | inactive SKU scanned, 12 units | booked; one `grn.inactive-sku-received` row | N/A |
| Mixed receipt | blind: inactive line + another-client line + short-dated line | inactive booked and flagged; the others go to their own rows; no line listed twice | N/A |
| PO-line receipt | inactive SKU on the PO line | booked, no review row | N/A |
| RMA | old order line of an inactive SKU | RMA created | N/A |

</frozen-after-approval>

## Code Map

All backend paths are under `workspace/core/backend/wms-be/`.

- **Precedents**
  - `src/modules/partners/partners.command.ts:548 updateStatus` — the status route to copy, with its no-op arm and audit actions.
  - `src/api/partners.controller.ts:141` — the controller shape.
  - `src/modules/clients/clients.facade.ts:417 assertClientTakesWorkInTx` — the guard shape (`FOR KEY SHARE`).
  - `test/architecture.spec.ts:999 TAKES_WORK_CALLERS` — the list to clone.
- **Catalog**
  - `src/shared/db/schema.ts:773` — the `skus` table; partner status columns at `:2039` and `PARTNER_STATUSES` at `:2063`.
  - `drizzle/0079_business_partners.sql` — the status CHECK precedent. The next migration is 0082.
  - `src/modules/catalog/catalog.controller.ts:227` (list; `SkuListQuery` at `:67`).
  - `src/modules/catalog/catalog.dto.ts:166` (`SkuResponse`).
  - `src/modules/catalog/sku.command.ts:384` (list); `toSnapshot`; `normalizeStoredSku`.
  - `catalog.facade.ts:518 getSkuSummariesInTx`; `:729 getSkusByCodesInTx`; `:819 skuFactsInTx`.
  - `src/modules/catalog/portal-skus.ts:67`.
  - `src/modules/catalog/kit.command.ts:111` create, `:190` put, `:365 lockSkus` (already `FOR UPDATE`).
- **Inbound**
  - `src/modules/inbound/po.command.ts:233 createInTx` (SKU loader `:779`); amend at `:339`, its loader at `:399`.
  - `src/modules/inbound/asn.command.ts:681` create, `:774` announce, `:872` amend; `readSkus` `:1129`, `readClientSkus` `:1155`.
  - `src/modules/inbound/asn-import.command.ts:193`.
  - `src/modules/inbound/receiving.command.ts`: `UNMATCHED_LINE_REASONS` at `:302`; the `grn.shelf-life-refused` raise at `:2572` is the review-row precedent.
- **Outbound and channels**
  - `src/modules/outbound/order.command.ts`: phase 1 at `:400` (SKU loader `assertSkuIdsInTenant` at `:1505`, called at `:496` and `:548`); phase 2.5 reject at `:715–734` (`policyShortLines`); phase 3 guard at `:750`.
  - `src/modules/channels/channels.ingest.command.ts:118–227` (no change beyond what order create's arm gives it).
  - `src/modules/channels/channels.publish.ts:108 computePublishedScopes`, `:714 setChannelMappings`.
  - `src/modules/channels/channels.command.ts:1076` (retry), `:1155 setConnectionMappings`.
- **Review queue and replenishment**
  - `src/modules/tenancy/sync-report.command.ts:95–175` (type lists and decisions by type), `:1367` (the apply switch).
  - `src/modules/tenancy/client-wind-down.ts:25`.
  - `src/modules/replenishment/replenishment.sweep.ts:143` (departed arm), `:179`.
- **Test pins**
  - `src/shared/primitives/audit.ts:130 AUDIT_NEW_ACTIONS`.
  - `test/support/audit-guard.ts:61 AUDIT_NO_OP_ARMS`.
  - `test/architecture.spec.ts:2975`.
- **Web** (`workspace/core/frontend/wms-fe/`)
  - SKU table: `src/components/settings/sku-table.tsx` (`useSkus` at `:128`, gates at `:153`, actions at `:207–260`, kit compose at `:1057–1100`).
  - Partners UX to copy: `src/components/settings/partners-card.tsx:153–286, 521`; `src/lib/partners.ts:325 partnerStatusLabel`; `confirm-row.tsx`.
  - Pickers: `outbound-orders.tsx:230` (`orderSkuOptions`); `asn-card.tsx:313/555` (`src/lib/asns.ts:216 withoutKits` keep-set); `portal-inbound.tsx:169` (`src/lib/portal.ts:268`); `channels-view.tsx:1039`.
  - API client: `src/lib/api/client.ts:951 fetchApiListSkus`. Generated types are regenerated with `api:generate`.
  - Reason switches: listed under the Always web bullet.
  - The review queue's type and decision labels.
- **Mobile** (`workspace/core/mobile/wms-mobile/`)
  - `src/state/catalog-snapshot.ts:30`.
  - `src/api.ts:1150 CatalogSku` (hand-written; `CatalogClient.active` is the precedent).
  - `src/receiving/draft.ts:398 resolveReceiveScan`.

## Tasks & Acceptance

**Execution:**
- [ ] `wms-be drizzle/0082_sku_status.sql` + schema + meta -- columns, CHECKs, assert, vocabulary pin -- decision source
- [ ] `wms-be src/modules/catalog/{sku.command,catalog.controller,catalog.dto,catalog.facade,portal-skus}.ts` -- status route, response fields, list filter, `assertSkusTakeWorkInTx`, snapshot and portal `status` -- one guard everyone calls
- [ ] `wms-be src/modules/inbound/{po,asn,asn-import}.command.ts`, `catalog/{kit,import}.command.ts`, `channels/{channels.command,channels.publish,channels.ingest.command,channels.errors}.ts` -- guard calls at the decision-13 position, decision-9 diffs against stored state, zero publish, ingest 422 arm -- decisions 1, 3, 8, 9, 12, 13
- [ ] `wms-be src/modules/outbound/order.command.ts` -- phase-1 status read, phase-2.5 inactive-short arm, phase-3 `FOR KEY SHARE` re-check of status and kit-ness -- decision 1 + the PENDING kit race
- [ ] `wms-be src/modules/inbound/receiving.command.ts`, `tenancy/{sync-report.command,client-wind-down}.ts`, `replenishment/replenishment.sweep.ts`, `openapi/openapi.json` -- `grn.inactive-sku-received` row; inactive sweep arm that dismisses the draft; OpenAPI export -- decisions 2, 7
- [ ] `wms-be test/` -- every I/O row; architecture `SKU_TAKES_WORK_CALLERS`; audit pins; replay of a pre-1.4b SKU response; channel ingest refusal with no redelivery loop; the deactivate-vs-PO-create lock race (the partners race-test pattern) -- proof
- [ ] `wms-fe` -- regenerate types; SKU table status column, filter, deactivate/reactivate; picker filtering with keep-sets; `sku-inactive` in each reason switch; review-queue Acknowledge; unit tests for the label helper, the picker filters and the reasons -- decisions 1–3
- [ ] `wms-mobile` -- snapshot parse default, `CatalogSku.status`, receive-scan warning, tests (legacy snapshot, inactive blind and unmatched scans) -- decision 2
- [ ] meta `docs/design/modules/catalog.md`, `API-SURFACE.md`, `PENDING.md` (close 1.4b; narrow the kit-race entry; add "backorders of an inactive SKU are not re-planned"), `docs/repos/wms-{be,fe}/README.md` -- the design docs stay current -- CLAUDE.md

**Acceptance Criteria:**
- Given a SKU deactivated by the owner, when an ops manager opens the ASN create, kit compose or channel-mapping picker, then the SKU is absent from new rows; order entry lists it as "inactive, sells existing stock only"; the ledger, stock view and existing documents still show it by code and name.
- Given an inactive SKU with stock, when the channel sync ticks, then the outbox message carries 0 for that SKU at every warehouse; after reactivation, the next tick carries the real quantity.
- Given an inactive SKU, when a reviewer acknowledges its `grn.inactive-sku-received` row, then the row is resolved and no stock moves.
- Given a handheld holding a pre-1.4b snapshot, when it parses it, then every SKU reads as active.

## Design Notes

- **Why sell-down refuses instead of backordering.** A backorder waits for inbound, and an inactive SKU takes none, so it would wait forever. Phase 2.5 reuses only the short-line detection. The refusal is its own code, because the backorder-policy arm's wording ("configured to REJECT backorders"), metering and KPI would be wrong here.
- **Why "new" is judged against the stored state.** Every write path here is a replacement (amend lines, mapping set, kit composition). A guard over the whole request would lock users out of editing anything that keeps an inactive SKU. A guard over request lines without an id would miss a re-pointed line.
- **Why `FOR KEY SHARE`.** A plain `UPDATE` of `status` takes `NO KEY UPDATE`, which does not conflict with `FOR KEY SHARE`. The status command must therefore lock `FOR UPDATE` explicitly (partners gotcha). Kit create already locks `FOR UPDATE`, so order phase 3's `KEY SHARE` also serialises with it. That is why the kit-race fold-in costs only the re-read.
- **Why zero, not unmap.** Unmapping leaves the last published number live on the marketplace (the channels module never invents zero), so an unmapped discontinued SKU keeps selling.

## Verification

**Commands:**
- `cd workspace/core/backend/wms-be && bun run db:generate` -- expected: no changes
- `bun run lint && bun run typecheck && bun run test` (wms-be, one jest run at a time) -- expected: green
- `cd workspace/core/frontend/wms-fe && bun run api:generate && bun run lint && bun run typecheck && bun run test` -- expected: green; the generated diff covers only the new fields and route
- `cd workspace/core/mobile/wms-mobile && bun run typecheck && bun run test` -- expected: green
