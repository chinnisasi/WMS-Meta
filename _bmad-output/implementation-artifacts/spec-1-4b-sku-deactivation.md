---
title: '1.4b SKU deactivation — an inactive SKU takes no new inbound, kits or listings, and sells down what is left'
type: 'feature'
created: '2026-10-20'
status: 'done'
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
- [x] `wms-be drizzle/0082_sku_status.sql` + schema + meta -- columns, CHECKs, assert, vocabulary pin -- decision source
- [x] `wms-be src/modules/catalog/{sku.command,catalog.controller,catalog.dto,catalog.facade,portal-skus}.ts` -- status route, response fields, list filter, `assertSkusTakeWorkInTx`, snapshot and portal `status` -- one guard everyone calls
- [x] `wms-be src/modules/inbound/{po,asn,asn-import}.command.ts`, `catalog/{kit,import}.command.ts`, `channels/{channels.command,channels.publish,channels.ingest.command,channels.errors}.ts` -- guard calls at the decision-13 position, decision-9 diffs against stored state, zero publish, ingest 422 arm -- decisions 1, 3, 8, 9, 12, 13
- [x] `wms-be src/modules/outbound/order.command.ts` -- phase-1 status read, phase-2.5 inactive-short arm, phase-3 `FOR KEY SHARE` re-check of status and kit-ness -- decision 1 + the PENDING kit race
- [x] `wms-be src/modules/inbound/receiving.command.ts`, `tenancy/{sync-report.command,client-wind-down}.ts`, `replenishment/replenishment.sweep.ts`, `openapi/openapi.json` -- `grn.inactive-sku-received` row; inactive sweep arm that dismisses the draft; OpenAPI export -- decisions 2, 7
- [x] `wms-be test/` -- every I/O row; architecture `SKU_TAKES_WORK_CALLERS`; audit pins; replay of a pre-1.4b SKU response; channel ingest refusal with no redelivery loop; the deactivate-vs-PO-create lock race (the partners race-test pattern) -- proof
- [x] `wms-fe` -- regenerate types; SKU table status column, filter, deactivate/reactivate; picker filtering with keep-sets; `sku-inactive` in each reason switch; review-queue Acknowledge; unit tests for the label helper, the picker filters and the reasons -- decisions 1–3
- [x] `wms-mobile` -- snapshot parse default, `CatalogSku.status`, receive-scan warning, tests (legacy snapshot, inactive blind and unmatched scans) -- decision 2
- [ ] meta `docs/design/modules/catalog.md`, `API-SURFACE.md`, `PENDING.md` (close 1.4b; narrow the kit-race entry; add "backorders of an inactive SKU are not re-planned"), `docs/repos/wms-{be,fe}/README.md` -- the design docs stay current -- CLAUDE.md

**Acceptance Criteria:**
- Given a SKU deactivated by the owner, when an ops manager opens the ASN create, kit compose or channel-mapping picker, then the SKU is absent from new rows; order entry lists it as "inactive, sells existing stock only"; the ledger, stock view and existing documents still show it by code and name.
- Given an inactive SKU with stock, when the channel sync ticks, then the outbox message carries 0 for that SKU at every warehouse; after reactivation, the next tick carries the real quantity.
- Given an inactive SKU, when a reviewer acknowledges its `grn.inactive-sku-received` row, then the row is resolved and no stock moves.
- Given a handheld holding a pre-1.4b snapshot, when it parses it, then every SKU reads as active.

## Implementation Notes

- One commit per repo plus review-round commits on `feat/1-4b-sku-deactivation`: wms-be `1b35771` (feature), `16e2281` (full mixed-receipt test), `27e8a93` (code-review tests); wms-fe `491c179` (feature), `c17f45d` (code-review tests + suggested-PO copy); wms-mobile `3d020c7`.
- Order phase 3 also refuses when a kit **component** has become a kit, not only a plain line's SKU (a stricter reading of the became-a-kit re-check).
- The status DTO caps `reason` at 2,000 UTF-16 units only to bound the body; the 500-code-point rule is the command's (decision 14).
- The order-entry label is "{code} {name} — inactive, sells existing stock only" (the existing option text, extended).
- The real-route lock-race test runs the PO create **after** the parked PATCH commits: a second `KEY SHARE` is compatible with the holder's, so a concurrent create cannot queue behind the parked `FOR UPDATE`. The test fails with `.for('update')` removed from `updateStatus`.

## Spec Change Log

## Review Triage Log

**Design review, 2026-10-20.** Three reviewers: backend (B1–B11), edge cases (E1–E12), web and handheld (F1–F13). 36 raw findings, 24 after merging duplicates. All are patched above, and none needed a human decision; each follows from decisions 1–4 or a precedent. Re-checked by hand: there is no pre-existing order error for a SKU that became a kit (`order.command.ts:520-560`), and the sync polls a full snapshot every tick, so zero needs no trigger (`jobs.module.ts:665-690`). *(This log was missing from the design commit #182: the section heading had been omitted, so the insertion matched nothing. Restored here.)*

- D1 high (E3, F1): the order-entry picker contradicted sell-down. Decision 10 keeps inactive SKUs there with a label.
- D2 high (E1, F2, B1): the mapping PUT replaces the whole set, so the guard would lock the connection. Decision 9: only added pairs are guarded; the stored set is read under the lock.
- D3 high (E2, B2): amend can re-point a kept line. Decision 9 judges by SKU against stored lines; a raised quantity is refused.
- D4 high (E4, B3): the catalog import's `kit_components` pass was a missed caller. Added.
- D5 med (E5, B5): the backorder arm mislabelled the refusal, metered and counted it, and did not stop redelivery. Decision 12: a typed 422.
- D6 med (B6): phase 3 cannot use a throwing guard. Added `lockSkuStatusesInTx` in id order; the outer catch releases grants.
- D7 med (B7): the kit-race fix does not cover zero-grant lines. The PENDING entry is narrowed, not closed.
- D8 med (B8): kit shortfall numbers were misleading. The detail names codes only.
- D9 med (E6): existing backorders are stranded. Panel copy plus a PENDING entry (decision 11).
- D10 med (E7): buffers keep holding units. Decision 11: untouched, explained in the panel.
- D11 med (E8, B10): the review row's lines, id, payload, snapshot field and shelf-life re-run were unstated. Specified.
- D12 med (E9): a suggested-PO draft outlives deactivation. The sweep dismisses it (decision 7).
- D13 med (B4): PO close carry. Decision 5: allowed as a continuation.
- D14 med (F8): the review queue would render nothing, and its "refused / discarded" words were wrong. Summary arm, badge, guidance and words specified.
- D15 med (F9): the handheld warning had no place to surface and missed other-client accepts. Optional `warning` on the `'sku'` result.
- D16 med (F10): legacy-seal pins would break. Named.
- D17 med (F11, B10): OpenAPI export, the import-code enum and the op-type enum were missing. Added.
- D18 med (F4, F5, F3): wrong or missing reason switches (`skuMasterReason` → `skuStatusReason`; `setMappingsReason`; the suggested-PO 409 short-circuit; the wrong picker line). Fixed.
- D19 med (F6): the partners deactivate uses `DeactivatePanel`, not `ConfirmRow`. Fixed; added the wrapper and `notifyCatalogChanged`.
- D20 med (F7): the status filter needs cursor scoping. Added.
- D21 low (E10, B9): `sku.updated` would be a near-synonym of `sku.edited`; the route order and discriminator differed from the precedent. Fixed.
- D22 low (E11): reason trimming and clearing. Decision 14.
- D23 low (E12): error precedence differed between PO and order. Decision 13.
- D24 low (F12, F13, B11): portal filters on the server; inactive markers on surprising surfaces; kit PUT reads the full composition; the retry path is one change.

**Code review, 2026-10-20.** Three layers: blind hunter (H1–H11), edge-case hunter (C1–C6), verification gap (V1–V5). 22 findings: 5 patched, 2 deferred, 15 rejected. No loopback: no finding traced to the frozen intent or to a spec gap.

- V1 medium, patch: the lock-race test took `FOR UPDATE` by raw SQL, so removing `updateStatus`'s lock would pass. Re-driven through the real status route.
- V2 / H4 medium, patch: no test for suggested-PO submit refusal. Added.
- V4 medium, patch: only the PO-line arm proved "document line stays unflagged". ASN-line twin added.
- V5 medium, patch: web inactive behaviour tested only at helper level. Component cases added for ASN create/amend and the flagged review card.
- H3 low, patch (copy only): `submitSuggestedPoReason` said "dismiss it", but no draft-dismiss action exists. Reworded. The silent sweep dismissal itself is decision 7's design: a system action on machine-made drafts, with no actor or resolver columns on `suggested_pos`.
- V3 medium, defer: the `setChannelMappings` seed arm has no test. It is internal with no route (deferred-work).
- C3 medium, defer: a kit composition replaced (PUT) between order phase 1 and phase 3 commits holds on stale components. Pre-existing; 1-4b re-checks only became-a-kit (deferred-work).
- H1 low, reject: ASN import tags rows by code. Codes resolve within the group's client, and a mixed-client group already fails, so a collision only adds a label to a failed group.
- H2 low, reject: the seed arm's untrimmed key. Internal and test-only callers.
- H5 low, reject: device "on the document" vs server "unmatched". These diverge only when `resolveLineRefs` misses an open line (the existing PENDING gap). The duplicate `warning` field is harmless.
- H6 low, reject: no UI to change the reason. Decision 14 allows it through the API; deactivate/reactivate covers the user path.
- H7 low, reject: no PO-line marker. The spec named markers for mappings, suggested-PO cards and ASN detail only.
- H8 low, reject: kit PUT on an inactive kit SKU. Decisions 8–9 guard only new components; editing a kit is not new kit-ness.
- H9 low, reject: CHECKs added without `NOT VALID`. `skus` is small, and the `ADD COLUMN` already holds `ACCESS EXCLUSIVE` for the same moment.
- H10 low, reject: "extensions.skuCodes" wording. The wire spreads extensions top-level and the web's `problemExtensions` gathers them; it is the house OpenAPI phrasing.
- H11 false: the generic `catalog.sku_edited` event and tick-based pickup are the spec's design (outbox bullet, decision 3).
- C1 maybe-false (low if true), reject: an over-receipt pending on an inactive SKU. Over-receipts arise only on document lines, which are unflagged by decision 2.
- C2 low, reject: a draft whose SKU has reorder point 0 is never reached by the sweep. A draft exists only from a breach, which needs a point above 0.
- C4 false: `assertSkusTakeWorkInTx` throws only with at least one code, so the catch always tags a row.
- C5 low, reject: re-typing a stored inactive row's ref is a new pair, refused by decision 9 and reported by `setMappingsReason`.
- C6 low, reject: a reason over 2,000 UTF-16 units before trimming is refused at the edge. Negligible.

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
