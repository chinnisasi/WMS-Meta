---
title: '2-1 PO create form — raise a purchase order on the web for one client'
type: 'feature'
created: '2026-10-20'
status: 'done'
baseline_commit: '88c563ba7c72223adc7bbd873930bc1761714695'  # wms-be; wms-fe: fd09b7940f2ab8fa46a8d8e227f23ab5aa03bff1; wms-mobile: 03ded78f5481ffd1583e06a5df74eb3f6c3a8cc9
route: 'dispatch'
review_loop_iteration: 0
context:
  - 'docs/initiatives/production-readiness.md'
  - 'docs/design/SYSTEM-DESIGN.md'
  - 'docs/design/IMPLEMENTATION-GUIDE.md'
  - 'docs/design/modules/inbound.md'
  - 'docs/design/modules/partners.md'
  - 'docs/design/modules/catalog.md'
  - 'docs/design/modules/replenishment.md'
  - 'docs/design/frontend/SYSTEM-DESIGN.md'
  - 'docs/design/frontend/IMPLEMENTATION-GUIDE.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:**
- The backend has had a PO create since 3-1 (`POST …/inbound/purchase-orders`, `po.manage`). Since 1-3 it also checks that the vendor is linked to the PO's client.
- The web cannot call it, because **Inbound → Purchase orders** is a read-only list.
- A kit SKU can still reach a PO line, through create, amend, a close carry-forward or a replenishment draft. Receiving refuses a kit (`receiving.command.ts:861-867`), so that line can never be received.

**Approach:**
- The **Raise a purchase order** button on the Purchase orders tab is for `po.manage` holders. It opens an inline form, filled in this order:
  1. the **client**;
  2. a **vendor linked to that client**;
  3. a typed PO code;
  4. one optional expected date;
  5. lines, each a SKU **of that client** (no kits, no inactive SKUs), an ordered quantity and a unit cost in rupees.
- The form posts to the existing create route for the selected warehouse.
- The backend refuses kit SKUs on PO create, amend and close carry-forward with 409 `kit-cannot-hold-stock`, as the ASN already does.
- The replenishment sweep dismisses a kit's draft suggested PO, as it does an inactive SKU's.

## Boundaries & Constraints

**Decisions (2026-10-20):**
1. **The PO code is typed** by the operator, as the DTO requires today. It is tenant-unique, and a duplicate answers 409. There is no suggestion and no server sequence.
2. **One optional expected date per PO**, sent as every line's `expectedDate`.
   - Wire form: `new Date(istDayStart(d)).toISOString()`, using `lib/audit.ts:145`. So `2026-10-25` becomes `2026-10-24T18:30:00.000Z`.
   - Past dates are allowed, as the API allows them, because they can backdate a paper PO.
   - Per-line dates stay API-only.
3. **The unit cost is required and at least ₹0.01**, as the DTO enforces today.

**Always:**
- **The body is the existing `CreatePurchaseOrderDto`:** `{warehouseId, vendorId, code, lines[{skuId, orderedQty, unitCostPaise, expectedDate?}]}`.
  - No `clientId`, no DTO change and no hash change. The server derives the client from the SKUs. The picker only scopes what the form offers.
- **Client picker:** the ASN form's (`asn-card.tsx:296-305,362-379`).
  - It is hidden for a tenant with only its own client.
  - It defaults to `defaultFormClientId(active, workingClients(clients), '')`, and a single working client becomes the default.
  - Changing the client clears the vendor and the lines.
  - With no client picked, the form says "Pick the client first" and shows no vendor or lines.
  - If the clients read fails, the form shows "Client list unavailable" and submit is disabled.
- **Vendor and SKU options are read per picked client from the server**, not from the tenant-wide maps, which stop at 1,000 rows (`fetch-all-pages.ts:17`):
  - Vendors: `fetchApiListPartners({role:'vendor', clientId, status:'active'})`, walked with `fetchAllPages`, then filtered through `vendorsLinkedTo` and sorted by code.
  - SKUs: `fetchApiListSkus({clientId, status:'active', limit:200})`, walked the same way. Kits are removed with `withoutKits` (`useKits`). These options double as the precision source.
  - Both are re-read on client change and on `PARTNERS_CHANGED_EVENT` / `CATALOG_CHANGED_EVENT`. The vendors are also re-read after a `vendor-*` refusal.
  - While loading, the form says "Loading vendors…". A loaded empty list says "No vendor is linked to {client} yet — link one under Settings → Partners." Submit is disabled until a vendor is chosen.
- **Lines** use a PO-local `PoLineRows` with SKU, quantity and unit cost. The shared `LineRows` is not touched, because the portal shares it.
  - The draft line type is `{skuId, qty, unitCost}`.
  - `parsePoCreate(draft, warehouseId, skuOptions)` refuses each of these, in one form-level problem that names the line number:
    - no client, no vendor, an empty code;
    - 0 or more than 200 lines;
    - a duplicate SKU;
    - a quantity that does not parse, or is ≤ 0;
    - a cost that `parseRupees` refuses, or one below 1 paise.
  - **Precision and the quantity ceiling are left to the server** (`validation-failed`, whose detail names the unit). That is guide §7 and the ASN parser (`asns.ts:104-105`).
- **Idempotency** follows the ASN form. A `ulid()` key is minted on the first submit and reused on a retry. Any edit clears it, and an in-flight ref blocks a double submit.
- **Warehouse switch:** the open state is keyed by `warehouseId`, as the banner is (`asn-card.tsx:113-115`), and the form mounts with `key={warehouseId}`. A switch therefore closes the form and drops its draft and key.
- **`poReason` lives in a new `lib/purchase-orders.ts`.** It maps:
  - `conflict` to the server's `detail` as sent. The detail names the code for a duplicate and says "retry" for a same-key race (`po.command.ts:753-759,988-995`).
  - `kit-cannot-hold-stock` to "{codes} is a kit — order its component SKUs instead."
  - `sku-inactive` through `skuInactiveSentence`.
  - `client-departed` through `CLIENT_DEPARTED_REASON`.
  - `mixed-client`, `vendor-not-linked`, `vendor-inactive`, `partner-not-vendor`, `not-found` and `validation-failed` to the server's detail.
  - `role-denied` and `permission-denied`, `idempotency-key-reuse`, and `unauthenticated` to the house copy (guide §3).
  - Network failure to `UNREACHABLE_REASON`.
- **On success:**
  - The form closes, and a banner names the PO code plus `hiddenByClientFilterNote`.
  - The page resets with `pos?.onCursor(null)` and a `pageEpoch` bump. The `DataTable` key becomes `${pageEpoch}|${clientFilterKey}`.
  - `notifyInboundChanged()` fires.
  - `usePurchaseOrders` gains the `INBOUND_CHANGED_EVENT` listener. This is load-bearing: `onCursor(null)` from page one does not refetch.
- **The backend kit guard:**
  - It reuses `assertNoKitLinesInTx` (`asn.command.ts:484`). Its label becomes a `kind` parameter, and an exported `ASN_LINE_KIND` / `PO_LINE_KIND` pair is shared with `asn-import.command.ts:286`.
  - The PO's `assertSkuIdsInTenant` (`po.command.ts:797-823`) also selects `skus.code`, which is what `codeOf` reads.
  - **Create** checks every line. The check runs after `assertSkusTakeWorkInTx` (`:284`) and before `assertVendorLinkedInTx` (`:290`).
  - **Amend** checks exactly the `skusGainingInbound(...)` set that `assertSkusTakeWorkInTx` locked (`:428-435`), computed once into one variable, and runs before `scaleLines`. A stale kit line can be resent unchanged or lowered. Raising it, or adding a second line of that SKU, is refused.
  - **Close** refuses a `carried` line whose SKU is a kit (409, before the successor insert, `:597-613`). Close is total, so the operator marks that line `cancelled` instead.
  - The 409 `@ApiResponse` text gains the arm on create, amend, close and the replenishment submit (`replenishment.controller.ts:285`, "the draft stays a draft"). OpenAPI is re-exported.
- **The replenishment sweep** treats a kit candidate like `inactive` (`replenishment.sweep.ts:149-171`): it recovers the breach and dismisses the standing draft. A draft for a SKU that became a kit later is therefore never stuck.

**Never:**
- No PO amend or close on the web, and no PO import (that is 2.2).
- No schema change, no migration, no new route, no DTO field and no new problem code.
- No portal access and no handheld change. The handheld already lists every open PO of its warehouse.
- No licence check at PO create. 1-6d enforces licences at receipt and order only, and the coverage-gaps read counts open PO lines.
- No kit guard on the reorder-policy upsert. The sweep's dismissal covers it.
- No fix for the same-key concurrent-create race (PENDING, idempotency section).

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected | Error handling |
|---|---|---|---|
| Happy path | GlowCo, V-KRISHNA (linked), `PO-1001`, 2 lines, date 2026-10-25 | 201. With the filter on All or GlowCo, the PO is on page one, `open`, and the tab count (below its 200 cap) goes up by 1 | — |
| Other client than the filter | Filter GlowCo, PO raised for BrandX | 201. The banner adds the hidden-by-filter note, and the count is unchanged | — |
| No client / no vendor link | "All" filter with several clients, or a client with no link | "Pick the client first", or the Settings hint; submit is disabled | — |
| Duplicate code | Code used anywhere in the tenant | 409 `conflict`; the values are kept | The server's detail, naming the code |
| Stale option | A link switched off, or a SKU deactivated or made a kit in another tab | 409 `vendor-not-linked` / `sku-inactive` / `kit-cannot-hold-stock`; the values are kept, and the vendors are re-read | Mapped copy naming the code |
| Kit via API | A kit `skuId` posted to create | 409 naming the kit code; no PO, no outbox row | Backend test |
| Kit on amend | Add a kit; raise a stale kit line; add a 2nd line of it | 409 each. Resent unchanged or lowered → 200 | Backend test |
| Kit carried at close | A `carried` disposition on a kit line | 409, nothing written; `cancelled` → 200 | Backend test |
| Kit draft | A suggested-PO draft whose SKU became a kit | The next sweep dismisses it and recovers the breach; a submit before the sweep → 409, and the draft stays | Backend test |
| Precision | `1.5` on an `each` SKU | 400 `validation-failed` from the server | The server's detail |
| Unit cost | `12.345`, `0` or blank | Refused client-side | `parseRupees` copy / "Enter a unit cost of at least ₹0.01" |
| Retry | Network drop, then Raise again | The same key replays, so one PO | — |
| Warehouse switch | The form is open with a draft | The form closes; the draft and the key are dropped | — |
| No `po.manage` / no warehouse | Viewer role | The button is absent | — |

</frozen-after-approval>

## Code Map

**wms-be**
- `src/modules/inbound/po.command.ts`:
  - Inject `CatalogFacade` in the constructor (`:183-186`). It is safe to inject: `inbound.module.ts:52` imports `CatalogModule` via `forwardRef`, and `AsnCommand:678` already injects it.
  - Add the `code` select to `assertSkuIdsInTenant` (`:797-823`).
  - Create the guard at `:284/:290`, amend at `:428-438`, and close at `:597-613`, so that it runs before the successor insert (`:615-651`).
- `src/modules/inbound/asn.command.ts:484`: add the `kind` parameter and the exported constants. The callers are `:725`, `:844` and `:956`, plus `asn-import.command.ts:286`.
- `src/modules/replenishment/replenishment.sweep.ts`: add an `isKit` candidate fact, read with `catalog.getKitSkuIdsInTx`, beside `inactive` (`:239`). Its arm runs at `:149-171`.
- `src/api/inbound.controller.ts` (`:89`, `:200-210`, the close route) and `src/api/replenishment.controller.ts:285`: the 409 text. Then run `bun run openapi:export`.
- Tests:
  - Add to `test/inbound.spec.ts` (the PO describe is at `:26`), using its own local `expectProblem`.
  - Copy the kit setup from `test/kits.spec.ts:918`.
  - Add the sweep and submit cases to the replenishment spec.
  - Put the ASN label pin in `test/asn.spec.ts`.

**wms-fe**
- `src/components/inbound/inbound-cards.tsx:234-351` (`PurchaseOrdersCard`): it receives only `active`, `warehouseId` and `warehouseLabel`. Add:
  - the role, read through `useSyncExternalStore(subscribeSession)`;
  - the `po.manage` gate, from `asn-card.tsx:103-108,183-193`;
  - the warehouse-keyed open state;
  - `pageEpoch`;
  - the banner (`asn-card.tsx:214-235,262-267`);
  - the `DataTable` key change (`:337`).
- New `src/components/inbound/po-create-form.tsx`: model it on `AsnCreateForm` (`asn-card.tsx:272-421`), with a local `PoLineRows`. Use `lineInputClass` and `lineButtonClass` from `components/shared/line-rows.tsx`. Imports:
  - `showClients` and `skusOfClient` from `lib/clients.ts`;
  - `defaultFormClientId` and `hiddenByClientFilterNote` from `lib/active-client.ts`;
  - `vendorsLinkedTo` and `unlinkedVendorLabel` from `lib/partners.ts:350,360`;
  - `withoutKits` from `lib/asns.ts:217`, and `useKits`;
  - `fetchAllPages`.
- New `src/lib/purchase-orders.ts`: `parsePoCreate`, `poExpectedDate` and `poReason`. Use `parseRupees` from `lib/rupees.ts`, `istDayStart` from `lib/audit.ts`, and `isRealDate` (move it to a shared spot if it is private).
- `src/lib/use-inbound.ts:71`: add the listener, following `use-asns.ts:61`.
- `src/lib/api/client.ts`: add `fetchApiCreatePurchaseOrder`, following `fetchApiCreateAsn` (`:2450-2464`), around `inboundControllerCreatePurchaseOrder` (`sdk.gen.ts:1110`). Run `bun run api:generate` first.
- Tests:
  - `po-create-form.test.tsx`, in the style of `asn-card.test.tsx:288-338`;
  - `lib/purchase-orders.test.ts`;
  - a body pin in `lib/api/client.test.ts`;
  - the reload test in `inbound-cards.test.tsx`.

**meta (last)**
- `docs/design/modules/inbound.md`: the PO create, amend and close guards.
- `docs/design/modules/replenishment.md`: the sweep's kit arm.
- `docs/design/API-SURFACE.md:132`.
- `docs/design/frontend/SYSTEM-DESIGN.md:47`, and guide §3 (`poReason`).
- `docs/repos/wms-fe/README.md` and `docs/repos/wms-be/README.md:27`.
- `docs/design/PENDING.md`:
  - shrink `:122` to the import only;
  - add: the ASN amend checks every line for kits (the PO amend checks only what gains inbound);
  - add: the PO code is tenant-unique, not per client;
  - add: the staff PO list shows no expected date;
  - add: the catch-weight PO price basis is per base unit;
  - add: the vendor and SKU pickers stop at 4,000 rows per client.

## Tasks & Acceptance

**Execution:**
- [x] `wms-be`:
  - the `kind` constants;
  - the PO code select;
  - the create, amend and close kit guards;
  - the sweep's kit arm;
  - the four 409 texts;
  - the OpenAPI export.
- [x] `wms-be` tests, one for each backend row of the matrix:
  - create (no PO, no outbox row);
  - the three amend arms and unchanged/lowered → 200;
  - close carried → 409 and cancelled → 200;
  - the sweep dismisses a kit draft;
  - submit before the sweep → 409 with the draft kept;
  - the ASN and ASN-import labels unchanged.
- [x] `wms-fe client.ts`: regenerate the client, then add the wrapper and its body test.
- [x] `wms-fe lib/purchase-orders.ts` and its test:
  - each `parsePoCreate` refusal;
  - rupees → paise: `"12.5"` → 1250, `"0.01"` → 1, while `"0"` and `"12.345"` are refused;
  - `2026-10-25` → `2026-10-24T18:30:00.000Z`;
  - each `poReason` arm.
- [x] `wms-fe po-create-form.tsx` and `inbound-cards.tsx`, with a component test for each web matrix row:
  - the options come from the client-scoped reads and exclude kits;
  - changing the client clears the vendor and the lines;
  - the loading, empty and failed states;
  - the exact POST body and key, and the key reused on a retry;
  - the warehouse switch;
  - the banner.
- [x] `wms-fe use-inbound.ts`: the reload listener and its test.
- [x] Meta docs, last, as listed in the Code Map.

**Acceptance Criteria:**
- Given an ops manager on Bengaluru DC with GlowCo selected in the switcher, when they open the form, then the client defaults to GlowCo, and only GlowCo's actively linked vendors and active non-kit SKUs are offered.
- Given a raised PO, when the handheld next syncs its catalog, then the PO is in its Receive list with no device change.

## Design Notes

**Why no `clientId` on the DTO.** The SKUs already fix the client: `assertSingleClientInTx` refuses a mix, and `assertVendorLinkedInTx` checks the vendor against that derived client. A client field would be a second source of truth that could disagree with the lines. It would also change the idempotency hash, and the replenishment caller would have to supply it.

**Why amend checks only the SKUs gaining inbound.** Kit composition does not refuse a SKU that sits on an open PO (`test/kits.spec.ts:918` makes one). If amend checked every line, a PO holding such a line could never be amended, and a line that has received anything cannot be removed (`po-line-received`). Checking the gaining SKUs is the 1-4b `sku-inactive` rule. Close is different: a carry-forward *creates* a line, so it is refused, and `cancelled` is always available.

**Lock reliance (do not reorder).** The kit read takes no lock. It is race-safe only because it runs after `assertSkusTakeWorkInTx`'s `FOR KEY SHARE` on the same SKU set (`sku-status.ts:57`), which conflicts with kit create's `FOR UPDATE` (`kit.command.ts:376-391`) under read committed. Moving the check earlier "for precedence", or checking a different set in amend, reopens the race. No race test is added; this note pins the order.

**The duplicate-SKU refusal is web-only.** The API and replenishment accept repeated SKUs on create. The form refuses them because a repeated SKU on one PO is almost always a slip.

**Catch-weight SKUs** can be put on a PO. `orderedQty` is in the base unit and weights are captured at receipt, so the per-unit cost misprices per-kg goods. This is recorded in PENDING, not fixed.

**Seed check:** no demo PO carries a kit line (`scripts/seed-demo.ts:634-666`). `HAMPER-FESTIVE` has no reorder point.

## Verification

**Commands:**
- `cd wms-be && bun run test -- test/inbound.spec.ts` (and the replenishment and ASN specs, run one at a time): expected to pass. Then `bun run test`, `bun run lint`, `bun run typecheck`, and `bun run openapi:export` with a clean diff.
- `cd wms-fe && bun run api:generate && bun test && bun run typecheck && bun run lint && bun run build`: expected to pass. The FE drift guard fails until the BE PR merges (the 409 descriptions reach `types.gen.ts`); that is expected.

**Manual checks:**
- On localhost:3001 in the demo tenant: raise a PO for GlowCo. Confirm it lists on page one and reads back through `GET …/inbound/purchase-orders/{id}` with the `vendorSnapshot`.

## Implementation Notes

Implemented 2026-10-21 against this spec; nothing was committed or pushed.

- **`kit-cannot-hold-stock` codes on the web.** The server's kit problem has no `extensions`, and parsing the codes out of `detail` would be prose parsing. So after the refusal the form re-reads the kits (`fetchAllPages(fetchApiListKits)`, the house kit-editor recovery, guide §1.4) and names the draft's SKUs that the fresh read marks as kits: `poReason(error, kitCodes)`. If that re-read fails, the copy has no codes ("A SKU on this purchase order is a kit — …"). It then reloads `useKits` and the SKU options.
- **`noValidate` on the form.** The quantity input's `step` follows the SKU's precision, and native validation would block a `1.5` on an `each` SKU before the server could refuse it. That contradicts the Precision row of the matrix. The parser is the only gate.
- **The warehouse switch.** The open state is keyed by warehouse, as specified. A render-phase "adjust state on change" also forgets it, so switching back never re-opens a form for the first warehouse. This is React's sanctioned pattern, not an effect.
- **Option hooks.** `usePoVendorOptions` / `usePoSkuOptions` (`ResourceState`) live in `lib/use-inbound.ts`. `fetchApiListSkus` gained an optional `limit`. `isRealDate` is now exported from `lib/audit.ts`.
- **One extra client-side refusal.** `parsePoCreate` also refuses a line whose SKU is no longer offered (it dropped out of a re-read, e.g. it became a kit) and names the line. A dropped vendor stays named in the picker through `unlinkedVendorLabel`, cannot be chosen, and Raise waits for a fresh pick.
- **Close's kit read.** It reads the carried lines' SKU codes through `assertSkuIdsInTenant` and runs after the "nothing left to carry" 400. Close takes no SKU lock (it has no `assertSkusTakeWorkInTx`), so the lock reliance in the Design Notes covers create and amend only.
- **Manual check not run.** The on-localhost check (raise a GlowCo PO in the demo tenant) was not run; the e2e and component suites cover the matrix.

## Spec Change Log

## Review Triage Log

**Design review, 2026-10-20.** Three reviewers: backend (B1–B9), edge cases and operations (E1–E13), and web and contracts (F1–F12). That is 34 raw findings, 24 after merging duplicates. None needed the user, because every fix has a code precedent. Re-checked by hand:
- the two `conflict` details (`po.command.ts:753-759,988-995`);
- the sweep's inactive arm (`replenishment.sweep.ts:149-171`);
- the SKU and partner list `@Max(200)`;
- the 20-hop `fetchAllPages`;
- `istDayStart`'s `+05:30` form.

The findings:
- D1 high (B1): a kit's suggested-PO draft is stuck, because a submit 409 keeps it a draft and nothing dismisses it. Fix: the sweep treats a kit as inactive.
- D2 high (B2): close carry-forward copies a kit line onto the successor. Fix: a carried kit line is refused with 409; `cancelled` is the way out.
- D3 high (E1): the tenant-wide SKU and vendor maps stop at 1,000 rows. Fix: per-client server reads at a limit of 200, plus a PENDING note for the 4,000-row cap.
- D4 high (F1, E2): `LineRows` has no cost column and is shared with the portal. Fix: a PO-local `PoLineRows`.
- D5 high (F2): `conflict` means both a duplicate code and a same-key race. Fix: `poReason` shows the server's detail, which tells them apart. No new code.
- D6 med (B3, E5): there was no SKU code for `codeOf`. Fix: select `skus.code`.
- D7 med (B4): the replenishment submit's 409 text was missing. Fix: added.
- D8 med (B5): raising a stale kit line was unstated. Fix: matrix row and tests.
- D9 med (F3, E3): client-side precision does not exist, and guide §7 says to let the server refuse. Fix: left to the server; matrix row changed.
- D10 med (F4): there was no per-line error UI. Fix: a form-level problem naming the line.
- D11 med (F5): loading and failed vendor states. Fix: the three states.
- D12 med (F6, E10): `istDayStart` gives `+05:30`, but the API wants `Z`. Fix: `toISOString`, a pinned example, past dates allowed (decision 2).
- D13 med (F7, B9): the docs were missing from the tasks. Fix: a meta task and a PENDING list.
- D14 med (E4): a warehouse switch re-targeted the draft and its key. Fix: warehouse-keyed open state and form key.
- D15 med (E6, F12): the tab-count criterion depends on the filter and the cap. Fix: matrix rows reworded and added.
- D16 med (E7): stale options. Fix: a matrix row and a vendor re-read after `vendor-*`.
- D17 med (E8): with no client picked, the hint read "linked to  yet". Fix: "Pick the client first", and the `''` third argument.
- D18 low (B6, E12): the lock reliance was undocumented. Fix: a Design Note and a single SKU set.
- D19 low (B7): the kit detail advises moving stock. Fix: PO copy in `poReason`.
- D20 low (B8): the ASN import hard-codes the label. Fix: shared constants.
- D21 low (F8, F9): card wiring and reference drift. Fix: Code Map corrected.
- D22 low (F10): the duplicate-SKU refusal is web-only. Fix: recorded in Design Notes.
- D23 low (F11, E11): the reason set and the client edge states. Fix: the full house set, reused copy, two states.
- D24 low/info (E9, E13): PO code uniqueness, catch-weight pricing, the stale PENDING line. Fix: PENDING entries; the coverage-gaps and handheld claims are verified correct.

**Code review, 2026-10-21.** Three layers: the blind hunter (H1–H14), the edge-case hunter (C1–C7) and the verification gap (V1–V3). There were 24 findings. 13 are patched, 3 deferred and 8 rejected. There was no loopback, because none needed a spec or intent change.

- H1 low (C2 the same): close's kit read takes no `FOR KEY SHARE`, so a kit create that commits concurrently with a close could carry a kit line. Real but narrow, and the fix adds a lock. Rejected under the rule for a low finding with a complex fix; recorded in PENDING beside the Design Notes' create/amend-only lock reliance.
- H2 medium → defer: close carries an inactive SKU onto the successor without a check. This predates 2-1, since close never ran `assertSkusTakeWorkInTx`.
- H3 false: close's new `assertSkuIdsInTenant` cannot 404 in practice, because master records deactivate and are never deleted. The `?? skuId` fallback is dead code but harmless.
- H4 low → patch: the close-refusal test now also asserts no `po.closed` / `po.created` outbox rows.
- H5 medium → patch (C5 the same): `isVendorRefusal` missed `partner-not-vendor`.
- H6 medium → patch (C6 the same): after `client-departed` the departed client stayed picked. Now the client resets and the clients read reloads.
- H7 low, rejected: the kit list is read twice after a kit refusal. That happens only on the error path.
- H8 low, rejected: `useKits` is tenant-wide and stops at 1,000 kits (`fetchAllPages`, 20 hops). The server's 409 still guards it; recorded in PENDING.
- H9 medium → defer: kit composition does not refuse a SKU on an open PO or draft, and nothing finds existing kit lines. This predates 2-1.
- H10 low, rejected: the banner sits below the table and survives a reopen. This matches the ASN form's banner.
- H11 low, rejected: Discard and a client change ask for no confirmation. This matches the ASN form.
- H12 low → patch: "Add line" is now disabled at 200 lines.
- H13 medium → patch: tests for the `sku-inactive` re-read, `client-departed` and the SKU read failure.
- H14 low, rejected: where `sortedByCode` lives and the `UNREACHABLE_REASON` import. `UNREACHABLE_REASON` is the house location the spec named.
- C1 false: splitting a stale kit line into two lines with the same total adds no inbound, so `skusGainingInbound` is right to admit it. The matrix's "a second line" row is pinned with a raised total.
- C3 medium → patch: while kits were loading or had failed, kit SKUs were offered. The SKU rows now wait for the kit read.
- C4 medium → patch: an edit made while a create was in flight cleared the key. The inputs are now disabled while busy.
- C7 medium → patch (web) and defer (backend): a unit cost above int4 paise overflows the column, so the web now refuses it. The DTO's missing `@Max` predates 2-1.
- V1 → patch: test that the draft keeps its client after a switcher change.
- V2 → patch: test that a create from page two returns the list to page one.
- V3 → patch: the portal announce test checks the exact kit label.
