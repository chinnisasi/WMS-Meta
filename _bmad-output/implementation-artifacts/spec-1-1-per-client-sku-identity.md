---
title: '1.1 Per-client SKU identity — code and barcode unique per client, scans resolved through the work''s own SKUs and client'
type: 'feature'
created: '2026-10-18'
status: 'done'
baseline_commit: 'bf612c5cebfeb32e3f9a45c18d89995d1fbd8bc4'  # wms-be; wms-fe: 4238d8c850c1c37a590cb758da3b28b57b1fbbd8; wms-mobile: 29696491149d7dffb31fc736d068da6b746b5a57 (branches feat/1-1-per-client-sku-identity)
route: 'dispatch'
review_loop_iteration: 0
context:
  - 'docs/initiatives/production-readiness.md'
  - 'docs/design/SYSTEM-DESIGN.md'
  - 'docs/design/IMPLEMENTATION-GUIDE.md'
  - 'docs/design/modules/catalog.md'
  - 'docs/design/modules/clients.md'
  - 'docs/design/modules/inbound.md'
  - 'docs/design/frontend/IMPLEMENTATION-GUIDE.md'
  - 'docs/design/mobile/SYSTEM-DESIGN.md'
  - 'docs/design/mobile/IMPLEMENTATION-GUIDE.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** A SKU code and a barcode are unique across the whole tenant (`skus_tenant_id_code_unique`, `skus_tenant_id_barcode_unique`, `schema.ts:804-805`). A 3PL's brands cannot both own `TSHIRT-M`, and two brands cannot both sell a product with the same manufacturer barcode (GTIN). The first real multi-client tenant hits this on its second client's catalogue import (PENDING clients, 21-2b decision 2).

**Approach (D1, agreed 2026-10-18):** Code and barcode become unique per (tenant, client). A scan resolves first to the SKUs of the work in hand, then within the document's client. A blind receipt names its client.
- No server command takes a scanned code; every scan op already posts `skuId`. The barcode → SKU step is on the handheld, against a tenant-wide catalog snapshot that today carries no client.
- The work in hand means the task's SKU, the order's lines, or the PO, ASN or RMA lines.

**Decisions (user, 2026-10-18):**
1. **One client per blind receipt.** The operator picks the client before the first scan, and the GRN records it.
2. **Product names stay tenant-unique until 1.4.**
3. **One story**, over the 1,600-token guideline. The index swap cannot ship without per-client resolution.
4. **Story 21-6 stands** (design review). A SKU of another client may still be received on a PO or ASN as an unmatched line, booked to the SKU's own client's ledger (`test/asn.spec.ts:1086-1108`, `inbound.md:546`). The handheld asks for confirmation first. The server adds no refusal for PO and ASN receipts.
5. **The backfill takes the document's client first** (code review, user 2026-10-18).
   - Older PO and ASN receipts take their PO's or ASN's client, the same rule new receipts follow.
   - Only blind receipts are backfilled from their lines, and they stay null when the lines are mixed.
6. **A blind receipt whose every line is refused records no receipt** (code review, user 2026-10-18).
   - No GRN code is consumed and no empty receipt is created.
   - Every line goes to review as `sku-client-mismatch`, like a partial refusal.
7. **Queued blind receipts from older builds, which carry no `clientId`, settle as before 1-1** (code review, user 2026-10-18).
   - Every line books to its own SKU's client, and the receipt's client stays null when the lines are mixed (the single client otherwise). Nothing goes to review.
   - The one-client rule binds only builds that send `clientId`.

## Boundaries & Constraints

**Always:**

*Schema (migration 0076)*
- **Swap the unique indexes:**
  - `skus_tenant_id_code_unique` → `skus_tenant_client_code_unique (tenant_id, client_id, code)`.
  - `skus_tenant_id_barcode_unique` → `skus_tenant_client_barcode_unique (tenant_id, client_id, barcode)`.
  - Add a non-unique `skus_tenant_code_idx (tenant_id, code)` for the code lookups that run without a client (ASN import blank rows).
- **No SKU data changes.** Every row already satisfies the looser rule.
- **Cost and rollback, stated in the migration:**
  - The index builds take a SHARE lock on `skus` inside the migrator's single transaction, which is acceptable for a catalog-sized table.
  - Rolling back is impossible once any cross-client duplicate exists.
- **Probes** follow 0064 (made-up uuids, sentinel rollback):
  - two clients insert the same code and barcode;
  - one client's duplicate is refused under each new index name.
- **Renames:** every reference to the old names is renamed: `sku.command.ts:55,984`, `import.command.ts:180-181,612`, `test/catalog.spec.ts:871`.
- **`goods_receipt_notes.client_id`:**
  - A new nullable column.
  - **New rows:** every new GRN stamps it: the PO's or ASN's client, or the blind receipt's chosen or derived client.
  - **Backfill:** older rows are backfilled from their lines' SKUs where those lines name exactly one client. Mixed or line-less older rows stay null and are listed by the migration's notice.
  - **No CHECK.** The command enforces it, pinned by a test, because old mixed history cannot satisfy one.
  - **Stored snapshots:** `GoodsReceiptSnapshot.clientId` is **optional** (§9: stored snapshots replay without it).

*The handheld resolves the work's own SKUs first (wms-mobile)*
- **Order of resolution for a scan, or a typed value:**
  1. The SKUs of the work in hand, by barcode then by code.
  2. The document's client in the snapshot, by barcode then by code.
  3. Other clients.
- **Steps 1 and 2 work on a stale snapshot,** because the work's SKU ids and barcodes are already on the device.
- **Per flow:**
  - **Putaway, pick:** step 1 is the task's SKU (`src/putaway/draft.ts:121`, `src/picking/draft.ts:293`). Anything else answers "Not this task's item".
  - **Pack** (`src/packing/draft.ts:171-213`): step 1 is the pack task's line SKUs; the pack task carries no client. Anything else answers "Not on this order".
  - **Returns** (`src/returns/draft.ts:249-255`): step 1 is the RMA's line SKUs, then the RMA's client, by barcode then by code. The cross-client `.find` goes. An exact code held only by another client answers "This code is <client>'s — not on this return".
  - **Receive on a PO or ASN:** step 1 is the document's line SKUs, then the document's client.
    - A match only in **one** other client asks "This is <client>'s <code> — receive it as unmatched on this receipt?". Yes adds the line (21-6 path), no discards the scan.
    - A match in several other clients asks which client. Nothing is booked without an answer.
  - **Receive, blind:** within the chosen client. Another client's match answers "This is <client>'s — not this receipt's client".
- **Receive manual entry** (`app/receive.tsx:576`) accepts a barcode **or a SKU code**, through the same order. Placeholder: "Type the barcode or SKU code".
- **The blind client:**
  - `ReceiveDraft` gains `clientId`.
  - `chooseBlindReceive` (`src/receiving/draft.ts:129-147`) takes it, and its picker sits in the blind-reason step (`app/receive.tsx:481-529`).
  - With one client in the snapshot, it is preselected and nothing is shown.
  - `choosePo`, `chooseAsn` and `chooseBlindReceive` refuse a client change while the draft has lines.
  - Losing the draft on restart is unchanged (the draft is React state; the op is durable from enqueue).
- **Legacy mode.** A stored snapshot with no `clients` field (an older server, or not refreshed since the update):
  - hides the picker;
  - sends no `clientId`;
  - resolves tenant-wide as today, apart from the step-1 order, which needs no client.
  - An absent `sku.clientId` is never treated as a non-match.
  - The tolerant parse is `src/state/catalog-snapshot.ts:51-75`, and the legacy-seal test pins it by equality.
- **The GRN payload** (`src/receiving/draft.ts:803-845`):
  - `clientId` is set **only on a blind receipt, and only when the snapshot carries `clients`**. A new app on an old server would otherwise fail the server's `forbidNonWhitelisted` (`app.factory.ts:63-64`) with a 400 and the op would be dropped.
  - PO and ASN payloads never carry the key, so they stay byte-identical.
- **The per-line refusal** `sku-client-mismatch` in `rejectedLines` (below) gets device words, so the operator sees which line went to review.

*The server's receipt rules*
- **`SubmitGoodsReceiptDto`** (`receiving.dto.ts:132`) and the submit route (`receiving.controller.ts:98-130`) accept an optional `clientId`. `validateDocumentPairing` checks the pairing:
  - `clientId` with a `poId` or `asnId` → 400;
  - a client not in the tenant → 404.
- **Hashing** follows the `?? undefined` pattern (`receiving.command.ts:356-366`): hashed only when present, so a queued older blind op replays byte-identically. A literal golden hash for an older blind op pins this.
- **Blind receipt:** the client is `command.clientId`, or the first line's SKU's client when it is absent (an older build).
  - A line whose SKU belongs to another client is refused **per line**: a `rejectedLines` entry with code `sku-client-mismatch`, the §7g partial-settlement pattern (`receiving.command.ts:770-781,1080`).
  - The rest settles, and the GRN stamps the client.
- **Guard order:** document lock → warehouse → status → client resolution and per-line check → `ensureBatchIdentity` (`:647`) → GRN insert (`:653`).
  - `kit-cannot-hold-stock` (`:483-495`) keeps its place and precedence.
- **PO and ASN receipts:** unchanged (decision 4). The GRN stamps the document's client.
- **Return receipts:** unchanged. `classifyReturnEntry` (`return-receipt.command.ts:782-783`) already refuses any entry whose SKU is not its RMA line's, entry by entry.
- **Sync-report re-apply** (`tenancy/sync-report.command.ts:1241-1259`) carries `clientId` through. The review-queue decision for a rejected `sku-client-mismatch` line is **Discard only** (re-receive on the right client), declared in `REJECTED_OP_DECISIONS_BY_TYPE`.

*Snapshot (additive)*
- **New fields:**
  - `CatalogSnapshotSkuDto` (`receiving.dto.ts:569-640`) and the facade type (`receiving.facade.ts:84`) gain `clientId`;
  - `CatalogPurchaseOrder` and the open returns gain `clientId`; the ASN already has it (`:685`);
  - the snapshot gains `clients: { id, code, name, active }[]`.
- **The `clients` list** covers every client referenced by a SKU or an open document, read through `ClientsFacade`; inbound does not own that table.
- **Size growth** (about 50 B per SKU) is noted in the mobile design doc. Scoping the snapshot to a warehouse goes to PENDING.

*Catalog lookups by code*
- **Catalog import** (`import.command.ts:318-382,510-529,651-658,718-733,957,964`):
  - `duplicate-sku-code` and `duplicate-barcode` are checked against the run's client.
  - The message (`:524`) says "already exists in this client's catalog".
  - Kit components resolve within the run's client first. A code missing there but held by another client keeps `mixed-client`, so `test/clients.spec.ts:705-707` is unchanged.
  - `skuRowByCode` (`:658`) is keyed within the run's client.
  - Fix mode's "latest run" is the latest run **of the same client**.
- **SKU edit:** the barcode check (`sku.command.ts:892`) is per client.
- **SKU client correction** (`sku-client.command.ts:84-93,210-232`):
  - Every member of the moved group (kit partners, product siblings) is checked against the target client's codes and barcodes, under the locks.
  - Order: re-derive the group → no-op → history → collision (409 `duplicate-sku-code` / `duplicate-barcode`) → update.
  - A 23505 on the new index names maps to the same 409s.
- **ASN import** (`asn-import.command.ts:187-209,307`, `asn-import.parse.ts:51,325-370`, `catalog.facade.ts:567-579`):
  - `getSkusByCodesInTx` returns **every** SKU per code (`code → SkuByCode[]`).
  - A row resolves within its group's client, the client a blank row inherits from the group.
  - `client-required` (new, added to the parse vocabulary, the DTO enum and the web label map) is raised only when the group's client cannot be settled because its codes are held by several clients.
- **HSN hint:**
  - Today it is looked up by code (`hsn-summary.ts:433-446`, `catalog.facade.ts:543-554`). It becomes by SKU, through facades: an `OutboundFacade` in-transaction read from `order_line_id` (`schema.ts:4409`) to `sku_id`, then a catalog read by id.
  - The callback at `invoicing/facade.ts:273` changes accordingly.
- **Messages that list codes** label each one `code (client)`: bin merge (`tenancy/bin.command.ts:811-812`), putaway occupancy (`putaway.command.ts:603`) and inventory (`inventory.facade.ts:2355`). Their checks are already by id.

*Web (wms-fe)*
- **`skuDisplayLabel(sku, clients)`** (`lib/clients.ts`) appends ` · <client>` when the tenant has more than one client. It is used by every picker and list named here.
- **Inventory search** (`lib/inventory.ts:100-127`, `inventory-screen.tsx:280-291,341,479,509-522`):
  - A new `{ kind: 'choice', matches }` arm covers several exact or case-insensitive matches. It renders one button per match, labelled `CODE · Client`, which applies that SKU id.
  - `searchSummary` names the client.
  - The Batches search uses the same chooser, and its datalist options read `name · client`.
  - With one client, nothing changes.
- **Order entry** (`outbound-orders.tsx:413-440`):
  - A required Client select comes first, hidden and preselected when the tenant has one client.
  - Every row offers `skusOfClient(client)`, replacing `skusForOrderClient`. The placeholder is "Pick a client first".
  - Changing the client clears rows of the old client, after a confirm row.
  - No `clientId` is sent; the server derives it, so the hash is unchanged.
- **Pickers narrowed to one client and labelled:**
  - the channel **mapping** rows (`channels-view.tsx:1509-1519`, narrowed to the first row's client; sort ties broken by client);
  - the channel buffers select (`:1214-1224`), labelled;
  - the kit component `pickerOptions` (`sku-table.tsx:948`, the kit's `clientId`);
  - the product variant attach (`products-card.tsx:443-451`, the client of the product's existing variants; all SKUs when it has none).
- **Lists show `skuDisplayLabel`:**
  - replenishment (`replenishment-view.tsx:485,754,1055,1259-1265`);
  - putaway tasks (`inbound-cards.tsx:464`);
  - the rejected-ops, excursion, variance and adjustment queues;
  - cold-chain trace (`cold-chain-trace.tsx:184`);
  - notifications (`lib/notifications.ts:106`).
- **GRN list:** `GoodsReceiptEntryDto` gains an optional `clientId`. The list shows a Client column when the tenant has more than one client (`inbound-cards.tsx:346-360`). `RETURN`/GRN refusal labels gain `sku-client-mismatch`, and `rejectedOpSummary` (`lib/review-queue.ts:397-401`) names the line's client.
- **Invoice detail** (`invoices.tsx:312,407,608-640`): the line → SKU match goes through `orderLineId → skuId` from the order read that `useOrderLineLabels` already makes. The code is a fallback for old frozen documents.
- **Copy:**
  - The SKU client correction: `correctClientReason` (`lib/clients.ts:298-320`) gains `duplicate-sku-code` and `duplicate-barcode`, and the `sku-table.tsx:760` copy says "for this client".
  - The catalog import help (`import-catalog.tsx:124-134`) says codes and barcodes are per client, and kit cells name this client's SKUs.
  - The ASN import help (`asn-import.tsx:122-125`) and its labels (`lib/asn-import.ts:45-49`) gain `client-required`.

**Never:**
- No change to product names (decision 2), to channel mappings (`external_ref → sku_id`), or to the portal (client-scoped reads: `portal-skus.ts:78`).
- No client column on waves, picklists, counts, transfers or adjustments; they carry SKU ids.
- No server-side barcode resolution endpoint.
- No refusal of a cross-client unmatched line on a PO or ASN receipt (decision 4).
- No new op-level 409; the only new refusal is per line.

## I/O & Edge-Case Matrix

| Scenario | State | Expected |
|---|---|---|
| Brands A and B both import `TSHIRT-M` and GTIN 890…1 | Two clients | Both succeed; one client importing either twice → its duplicate code |
| Client A picks or putaways its SKU after B imports the same GTIN | **Stale snapshot / older build** | Resolves (the task's own SKU first); no new refusal |
| Receive A's PO and scan the shared GTIN | — | A's SKU (a PO line SKU) |
| Scan a barcode only B holds on A's PO | — | "This is B's … — receive it as unmatched?" → yes: an unmatched line on B's ledger (21-6) |
| A barcode held by B and C, not A, on A's ASN | — | Asks which client; nothing booked without an answer |
| Blind receipt, two-client tenant | — | Client picker first; the GRN stamps it; another client's scan is refused on the device |
| A blind op (any build) with a line of another client | — | That line in `rejectedLines` `sku-client-mismatch`; the rest settles; review: Discard only |
| An older build's blind op, no `clientId`, one client | — | Accepted, byte-identical; the GRN stamps the derived client |
| New app on an old server, blind receipt | Snapshot has no `clients` | No picker, no `clientId` sent; works as today |
| Returns: scanned code held by A and B on A's RMA | — | A's SKU (an RMA line) |
| Moving a SKU (with kit partners) to a client that holds a partner's code | — | 409 `duplicate-sku-code` |
| ASN import: blank-client rows in a group whose other rows name A | Code held by A and B | Resolves to A |
| ASN import: a group with no named client, codes held by A and B | — | `client-required` |
| Web inventory search for a code held by A and B | — | Two choices labelled with the client; picking one shows that SKU's stock |
| HSN summary when two clients share a code | — | Each line's hint comes from its own SKU |

</frozen-after-approval>

## Code Map

**wms-be**
- `src/shared/db/schema.ts`: `:668-672` comment, `:804-805` indexes, `:2047` GRN `client_id`. `drizzle/0076_per_client_sku_identity.sql`: generated, then the backfill, notice and probes below the marker, following 0064 and 0074.
- `catalog/import.command.ts` (lines as above), `sku.command.ts:55,892,984`, `sku-client.command.ts:84-93,210-232`, `catalog.facade.ts:400-424,543-554,567-579`.
- `inbound/asn-import.command.ts:187-209,307`, `asn-import.parse.ts:51,325-370`.
- `inbound/receiving.command.ts`:
  - `:356-366` hash;
  - `:437`, `validateDocumentPairing` (`:1565-1580`);
  - `:478-505,561-647,653,770-781,1080`;
  - `GoodsReceiptSnapshot` (`:195-210`);
  - `receiving.dto.ts:132,569-640,685,698-720`;
  - `receiving.controller.ts:98-130` (submit), `:155-215` (snapshot);
  - `receiving.facade.ts:84,425-440`.
- `tenancy/sync-report.command.ts:1241-1259`; `REJECTED_OP_DECISIONS_BY_TYPE`.
- `clients` facade: a client list read for the snapshot.
- `invoicing/hsn-summary.ts:433-446`, `invoicing/facade.ts:273`, an `OutboundFacade` order-line → SKU read.
- `tenancy/bin.command.ts:811-812`, `putaway.command.ts:603`, `inventory.facade.ts:2355`.
- Tests:
  - re-scope `test/catalog.spec.ts:176,271,300,584,863,871`, `test/clients.spec.ts:600,705-707`, `test/asn-import.spec.ts`;
  - keep `test/asn.spec.ts:1086-1108` green (decision 4);
  - new `test/per-client-sku.spec.ts`: every matrix row, the migration probes and the backfill, the golden hash, and the sync-report re-apply.

**wms-mobile**
- `src/api.ts`: `:346` (`clientId?`), `:376-384` (`rejectedLines` reason), `:1048-1090`, `:1101`, `:1126-1132`, `:1229-1236`, `:1347`, `:1398`.
- `src/state/catalog-snapshot.ts:15,51-75`; `src/state/device-store.ts:430-437,477`.
- `src/receiving/draft.ts`: `:96-147` (`ReceiveDraft.clientId`, `choose*`), `:207-221` (resolution), `:803-845` (payload).
- `app/receive.tsx`: `:481-529` (picker), `:576` (manual entry); the confirm prompt.
- `app/putaway.tsx:114`, `app/pick.tsx:209,566`, `src/packing/draft.ts:171-213`, `src/returns/draft.ts:249-255`.
- Tests: the draft tests per flow (stale snapshot, legacy mode), and the `device-store.test.ts` legacy seal.

**wms-fe**
- `lib/clients.ts` (`skuDisplayLabel`, `correctClientReason`), `lib/inventory.ts:100-127`, `inventory-screen.tsx:280-291,341,479,509-522`.
- `outbound-orders.tsx:413-440`, `channels-view.tsx:1058,1214-1224,1373,1509-1519`, `sku-table.tsx:760,948`, `products-card.tsx:443-451`.
- The lists named above; `inbound-cards.tsx:346-360,464`; `lib/review-queue.ts:397-401`.
- `invoices.tsx:312,407,608-640`; `import-catalog.tsx:124-134`; `asn-import.tsx:122-125`; `lib/asn-import.ts:45-49`.
- Tests beside each.

**meta:**
- `catalog.md` (uniqueness, resolution), `inbound.md` (`:546` stays; the GRN client, the blind rule), and the mobile design (resolution order, legacy mode, snapshot size).
- `API-SURFACE.md`.
- PENDING: close the clients-section per-client SKU entry; add warehouse-scoped snapshots and products to 1.4.
- The repo contracts.

## Tasks & Acceptance

**Execution:**
- [x] wms-be:
  1. 0076: indexes, the GRN column, backfill, probes.
  2. Renames.
  3. Catalog import, SKU edit, client correction.
  4. ASN import.
  5. HSN by SKU.
  6. Messages.
  7. GRN client: DTO, pairing, hash, blind per-line rule, stamp, snapshot field, sync-report re-apply, review decision.
  8. Snapshot fields and `clients`.
  9. Tests.
  10. OpenAPI export.
- [x] wms-mobile:
  1. Types and tolerant parse.
  2. Resolution order per flow.
  3. Receive confirm prompt and manual code entry.
  4. Blind client in the draft and payload.
  5. `rejectedLines` words.
  6. Tests.
- [x] wms-fe:
  1. Regenerate the client.
  2. `skuDisplayLabel`.
  3. Inventory chooser.
  4. Order entry.
  5. Pickers.
  6. Lists.
  7. GRN list.
  8. Invoice detail.
  9. Copy.
  10. Tests.
- [x] meta: the docs above.

**Acceptance Criteria:**
- Given two clients sharing a code and a barcode, when any receive, putaway, pick, pack or return flow scans it against either client's work, then it resolves to that work's SKU and never the other client's, including on a stale snapshot.
- Given a queued op from an older handheld build, then it replays byte-identically or settles with per-line refusals, and is never dropped.
- Given the full backend suite, then `test/asn.spec.ts:1086-1108` passes unchanged.

## Design Notes

**Why the device resolves the work's SKUs first.** Every scan op already posts `skuId`, so the server never sees a barcode. Resolution is offline by design. A pick or putaway task already knows its SKU, and a PO, ASN, RMA or pack task its lines. Matching those first means a barcode that a second client also uses keeps working for the first client on a device whose snapshot predates the second client's import, and on older builds' task flows. Only the open-ended cases need the client: a receipt's unmatched lines, a blind receipt, a return's code fallback.

**Why there is no server refusal on PO and ASN receipts (decision 4).** 21-6 deliberately books another client's SKU arriving on a document as an unmatched line on **that SKU's** client's ledger. The owner is right, and the billing drill joins on it (`inbound.facade.ts:584-588`). The risk introduced by shared barcodes is the device choosing the wrong SKU, not the ledger choosing the wrong owner. The device-side order and the confirm prompt address it.

**Why blind is per line, not a whole-receipt 409.** One stray scan must not hold back a truck (§7g). The GRN already settles per line through `rejectedLines`.

**Why no CHECK on `goods_receipt_notes.client_id`.** Older blind receipts could mix clients, so a validated CHECK cannot hold for history. `NOT VALID` has no precedent here and can never be validated. The command stamps every new row, and a test pins it.

## Verification

**Commands:**
- wms-be: `bun run test -- test/per-client-sku.spec.ts`, then the full `bun run test`, `bun run lint`, `bun run typecheck`, and `bun run openapi:export` with its drift check.
- wms-mobile: `bun test && bun run typecheck && bun run lint`.
- wms-fe: `bun test && bun run typecheck && bun run lint && bun run build` (drift fails until the backend merges).

**Manual checks:**
- Seed two clients with the same code and GTIN.
- On the handheld: receive a PO for each, scanning the GTIN, and a mis-shipped unit (confirm prompt). Do a blind receipt with the picker. Pick an order of each.
- On the web: search the code in inventory, and create an order with the client first.

## Implementation Notes

**Branches:** `feat/1-1-per-client-sku-identity`.

| Repo | Build | Code-review fixes |
|---|---|---|
| wms-be | `751bda4` | `2424ded` |
| wms-mobile | `d64ca61` | `8c66d90` |
| wms-fe | `14891c8` | `0bc5806`, plus `5ef279c` (client regenerated) |

**Verified 2026-10-18:**

| Repo | Result |
|---|---|
| wms-be | 92/92 suites, 2,209 tests; lint and typecheck |
| wms-mobile | 609 tests; typecheck (the repo has no lint script) |
| wms-fe | 1,771 tests; typecheck, lint, build |

**Decisions taken in implementation:**
- **Review type.** A new server-raised review type, `grn.lines-refused`, which can only be discarded. `grn.submit` rows need Apply, so they could not hold it.
- **Client labels.** `CODE (client)` labels appear only in multi-client tenants.
- **Fix mode.** When fix mode names a client, it fixes that client's latest run.
- **Every line refused** (decision 6). The answer is 201 `{goodsReceipt: null, refusedReceipt}`. The audit row targets the review row. The handheld settles it as a retraction with a note per line.
- **Inactive client.** A blind receipt naming a suspended or departed client is refused with 409 `client-not-active`, read under `shareLockClientInTx`.
- **Snapshot clients.** The client list is read by id through `ClientsFacade.snapshotClients`.
- **Device guard.** The guard refuses a switch to another document while the draft holds a confirmed other-client line. This is stricter than strictly needed, which is accepted.

**Not verified:** the device screens (confirm prompt, blind picker) and the browser flows. Only their logic is tested; recorded in PENDING.

**Local dev databases** that applied the first version of 0076 keep the old GRN backfill; re-seed to get decision 5.

## Spec Change Log

### 2026-10-18 — code review: decisions 5–7 (user)
- **Trigger:** the code review's blind-hunter B1, B2 and B6 findings, plus the edge-case hunter's E1.
  - The backfill ignored the document's client.
  - A fully refused blind receipt left a zero-line GRN.
  - Older builds' mixed blind ops were attributed to their first line, sending received units to a Discard-only review.
- **Amended:** decisions 5–7 in the frozen block, with the user's answers. The blind rule ("the first line's SKU's client when it is absent") is superseded by decision 7.
- **KEEP:** everything else in the implementation (the resolver order, the snapshot fields, the import and client-correction re-scope, the web).

## Review Triage Log

### Design review — 2026-10-18 (3 reviewers: data/migration 15, handheld/offline 12, web/cross-client 12; 39 raw → 26 after dedup)

| # | Finding (reviewers) | Verdict | Disposition |
|---|---|---|---|
| R1 | A shared GTIN stops resolving for the existing client on stale snapshots and older builds; receive has no code entry (handheld) | high | Resolution order: the work's own SKUs first; receive manual entry accepts a code; Design Notes corrected |
| R2 | The return backstop is unnecessary: `classifyReturnEntry` already refuses a foreign SKU per entry; the spec cited the wrong line (all 3) | high — verified at `return-receipt.command.ts:782-783` | Dropped; Design Notes claim removed |
| R3 | A whole-receipt 409 on PO/ASN receipts reverses 21-6 (`test/asn.spec.ts:1086-1108`, billing drill joins) (data) | high — verified | **User decision 4:** keep 21-6, confirm on the device |
| R4 | A whole-op refusal breaks partial settlement (§7g); `rejectedLines` exists (all 3) | high — verified at `receiving.command.ts:208,1080` | Blind cross-client lines refused per line |
| R5 | An older-build blind op must store a derived client, or the CHECK 500s → dropped (data, handheld) | high | Derived from the first line; no CHECK (backfill and test instead) |
| R6 | A new app on an old server: `forbidNonWhitelisted` 400s an extra `clientId` → dropped (handheld) | high | `clientId` sent only when the snapshot carries `clients` |
| R7 | The sync-report re-apply rebuilds the GRN command field by field and would drop `clientId`; the submit DTO and route are missing (data) | high | Added to the rules and the Code Map |
| R8 | Stale snapshot default `clients: []` blocks blind receipts (handheld) | medium | Absent `clients` = legacy mode; pinned by the legacy-seal test |
| R9 | Fate claims wrong ("retained" = `quarantined`; older builds drop new codes) (handheld, data) | medium | Moot: no new op-level code; a per-line reason only; review decision Discard only |
| R10 | Where the blind client lives; switching document with lines (handheld) | medium | `ReceiveDraft.clientId`; `choose*` refuse a client change with lines |
| R11 | Pack and pick tasks carry no client (handheld, data) | medium | Resolve within the task's SKUs; no client needed |
| R12 | The guard placement "beside the SKU reads" is impossible: the client is known after the document lock (data) | medium | Order stated; `kit-cannot-hold-stock` precedence kept; pairing 400 / 404 |
| R13 | Import kit pass would turn `mixed-client` into `kit-component-not-found`; `skuRowByCode` collapses shared codes (data) | medium | Run client first, then `mixed-client`; keyed within the client |
| R14 | ASN import grouping: `skuClientOf` is ambiguous; `getSkusByCodesInTx` cannot take one client (data, web) | medium | Facade returns every SKU per code; resolve within the group's client; `client-required` only when unsettled |
| R15 | Client correction moves a whole group; 23505 → 500; FE reason arms and copy (data, web) | medium | Every member checked under the locks; 23505 mapped; FE arms and copy |
| R16 | Inventory search silently picks the first exact match; Batches missed (web) | high | `choice` arm and buttons; Batches chooser |
| R17 | Invoice detail has no SKU id to key on (web) | medium | `orderLineId → skuId` via the existing order read; code fallback |
| R18 | Channel mapping picker mislocated; should narrow (web) | medium | Narrowed to the first row's client; correct lines |
| R19 | Order entry client-first underspecified (web) | medium | Placement, one-client hide, clearing, `skusOfClient`, no `clientId` sent |
| R20 | Many tenant-wide lists show a bare code (web) | medium | `skuDisplayLabel` helper across the named lists |
| R21 | The GRN client is invisible on the web; review labels missing (web) | medium | Optional `clientId` on the GRN list DTO + column; labels |
| R22 | Variant and kit pickers should narrow; line refs off (web) | low | Narrowed; refs corrected |
| R23 | Catalog import fix mode's "latest run" is tenant-wide; help text (web) | low | Latest run per client; help copy |
| R24 | Occupancy messages dedup by code (`putaway.command.ts:603`, `inventory.facade.ts:2355`); bin merge is message-only (web, data) | low | Messages label `code (client)` |
| R25 | HSN needs facade reads, not a join (data) | low | `OutboundFacade` read + catalog by id |
| R26 | Migration: `(tenant, code)` lookups lose their index; lock cost; irreversibility; probe mechanics (data) | low | `skus_tenant_code_idx`; stated; 0064-style probes |
| — | The snapshot's `clients` must come through `ClientsFacade`; include clients of open documents; size growth (data, handheld) | low | Stated; warehouse scoping → PENDING |
| — | Returns typed-code collision with a barcode (handheld) | low | RMA line SKUs → barcode → code order |

### Code review — 2026-10-18 (blind hunter 12, edge-case hunter 11, verification-gap 4 + 1; 28 raw)

| # | Finding (layer) | Verdict | Route / disposition |
|---|---|---|---|
| C1 | Kit, catch-weight and precision checks run on a client-refused line before the per-line client split, so the whole blind op fails (edge ×2) | high — `receiving.command.ts:554,576` precede `:705` | patch: those checks and `ensureBatchIdentity` run on receivable lines only |
| C2 | Backfill ignores the document's client (blind) | medium | user decision 5 → patch |
| C3 | A fully refused blind receipt records a zero-line GRN (blind, edge) | medium | user decision 6 → patch |
| C4 | An older build's mixed blind op is attributed to its first line (blind) | medium | user decision 7 → patch |
| C5 | A blind receipt may name a suspended or departed client (blind, edge) | medium | patch: refused 409 `client-not-active` |
| C6 | `snapshotClients` reads the capped (500) client list and filters in memory (blind) | medium | patch: direct `inArray(id)` read |
| C7 | An ASN import `clientRequired` group still validates rows against `holders[0]` (blind, edge) | low | patch: skip row validation and report only `client-required` |
| C8 | Device `clientChangeRefusal` misses carried other-client unmatched lines and legacy null clients (edge ×2) | medium | patch: refuse when any held line's SKU client differs from the next client |
| C9 | `pendingOther` survives a context or snapshot change (edge) | low | patch: cleared on draft-context or snapshot change |
| C10 | Channel mapping keeps other-client rows after row 0 changes client (edge) | low | patch: flag and clear foreign rows before save |
| C11 | Order form lists inactive clients (edge) | low | patch: active only |
| C12 | Dead fix-mode 400 branch and stale comment (edge) | low | patch: delete |
| C13 | Device mismatch note drops the client (blind) | low | patch: "CODE (client)" |
| C14 | Catalog-import kit pass locks other clients' same-coded SKUs (blind) | medium | patch: lock only the run client's rows; unlocked probe for `mixed-client` |
| C15 | "Not in the catalog — type the SKU code instead" differs across flows (blind) | low | patch: one wording |
| C16 | `chooseBlindReceive`'s `= null` default can silently drop the picked client (gap) | gap | patch: required parameter |
| V1 | No test for a kit component code shared by two clients (gap) | gap | patch: test |
| V2 | No test for a refused batch-tracked blind line (gap) | gap | patch: test (no batch row, 201) |
| C17 | Client-move race (23505 → 409) untested; barcode holder null (blind) | low | patch: race test; holder named |
| V3 | Occupancy messages never tested in a multi-client tenant (gap) | low | defer: message-only; helper tested directly |
| B7 | `grn.lines-refused` review has no link to the corrective re-receipt (blind) | medium | defer: needs a dock-stock reconciliation story |
| B5 | Fix mode naming another client skips silently (blind) | low | reject: the row count reports it; no harm |
