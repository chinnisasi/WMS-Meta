---
title: 'PO create form — raise a purchase order on the web'
type: 'feature'
created: '2026-10-18'
status: 'done'  # SUPERSEDED, never implemented — replaced by spec-2-1-po-create-form.md (2026-10-21)
superseded_by: '_bmad-output/implementation-artifacts/spec-2-1-po-create-form.md'
baseline_commit: '41eb113152bafba1827af7efaacc4f7d5f2686cc'  # wms-be; wms-fe baseline: caf526919642948035a3082869dac6c1aec0317f
route: 'dispatch'
review_loop_iteration: 0
context:
  - 'docs/design/SYSTEM-DESIGN.md'
  - 'docs/design/IMPLEMENTATION-GUIDE.md'
  - 'docs/design/modules/inbound.md'
  - 'docs/design/frontend/SYSTEM-DESIGN.md'
  - 'docs/design/frontend/IMPLEMENTATION-GUIDE.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** The backend has had a purchase-order create since story 3-1 (`POST …/inbound/purchase-orders`, `po.manage`). The web has no way to call it: **Inbound → Purchase orders** is a read-only list. Today a PO exists only if it came through the API or the replenishment suggested-PO submit. The PO import (deferred, `deferred-work.md` 2026-10-18) builds on this form's rules.

**Approach:** Put a **Raise a purchase order** button on the Purchase orders tab for `po.manage` holders (owner and ops manager). It opens an inline form, the same shape as Announce a shipment:
- PO code;
- vendor;
- an optional expected date;
- lines, each with a SKU, an ordered quantity and a unit cost in rupees.

The form posts to the existing create route, in the selected warehouse. The backend gains one guard: kit SKUs are refused, as the ASN create already refuses them.

## Boundaries & Constraints

**Always:**
- **The request matches `CreatePurchaseOrderDto` exactly:**
  - `{warehouseId, vendorId, code, lines[{skuId, orderedQty, unitCostPaise, expectedDate?}]}`.
  - `orderedQty` is a base-unit decimal, parsed with `parseQuantityInput` at the SKU's precision and required to be > 0.
  - `unitCostPaise` is an integer ≥ 1, converted from a rupee input of at most 2 decimals without a float multiply.
  - There are 1–200 lines, and `code` is trimmed to 1–64 characters.
- **One expected date per PO.** The form has a single optional date, which is sent as every line's `expectedDate`. The per-line date stays API-only. A date-only value means midnight IST.
- **Idempotency:** the `ulid()` key is minted on the first submit and reused on a retry. It is cleared on success or on any edit. This is the Announce form's rule.
- **Lines:**
  - Kits are excluded from the SKU picker (`withoutKits`).
  - A SKU picked twice is refused client-side.
  - The client is never asked for: the server derives it from the SKUs.
- **Errors map to words** through a `poReason`, a sibling of `asnReason`:
  - `mixed-client`: "These SKUs belong to different clients — a purchase order holds one client's goods."
  - `conflict` (duplicate code): "PO code X is already used."
  - `kit-cannot-hold-stock`.
  - `validation-failed` (precision).
  - `not-found`.
  - `role-denied`.
  - Anything else falls back to the shared problem copy.
- **On success:**
  - The form closes and a banner names the PO code.
  - The list returns to page one.
  - `notifyInboundChanged()` fires.
  - `usePurchaseOrders` now also reloads on `INBOUND_CHANGED_EVENT`, as `use-asns` does, so the tab count and the list agree.
- **Backend kit guard:**
  - `PurchaseOrderCommand.create` (`createInTx`) and `amend` refuse kit SKUs with 409 `kit-cannot-hold-stock`.
  - The check runs after the single-client check and before `scaleLines`, the ASN's position.
  - It reuses `assertNoKitLinesInTx` (`asn.command.ts:483`) with the subject made a parameter: "Purchase order line" vs "Advance shipment notice line".
  - The 409 `@ApiResponse` text gains the arm, and OpenAPI is re-exported.
  - The replenishment suggested-PO submit inherits the guard through `createInTx`.

**Never:**
- No PO amend or close on the web: the routes exist, but they are a later story.
- No PO import.
- No schema change and no new route.
- No client-portal access.
- No fix for the same-key concurrent-create race (PENDING, idempotency section). The web key makes a double-click replay, which is enough here.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected | Error handling |
|---|---|---|---|
| Happy path | Code `PO-1001`, vendor V-KRISHNA, 2 lines, date 2026-10-25 | 201. The PO appears on page one with status open; the tab count goes up by 1 | — |
| Duplicate code | Code already used in the tenant | 409 `conflict`; the form stays open with its values | "PO code PO-1001 is already used." |
| Mixed client | SKUs from GlowCo and self | 409 `mixed-client` | Shown in the form |
| Kit via API | A kit `skuId` posted directly | 409 `kit-cannot-hold-stock` naming the kit code; nothing written | Backend test |
| Precision | `1.5` on an EA (precision 0) SKU | Refused client-side before the post; the server agrees with 400 | Line-level message |
| Unit cost | `12.345`, `0` or blank | Refused client-side | "Enter a unit cost of at least ₹0.01" |
| Retry | Network drop, then click Raise again | Same key → replay → one PO | — |
| No warehouse / no `po.manage` | Viewer role | The button is absent, not disabled | — |

</frozen-after-approval>

## Open Questions

1. **The web cannot add a vendor, and a PO needs one.** Vendors exist only through the API (the demo seed adds V-KRISHNA and V-VISTARA). A new tenant would find an empty vendor picker. Options:
   - **(A) Add vendor inline:** a small "New vendor" (code + name) beside the picker, posting to the existing `POST /vendors` (`vendor.manage`, the same holders as `po.manage`). The new vendor is selected straight away. This adds about one component and one client wrapper.
   - **(B) Vendors list on Settings:** a read-and-add Vendors tab, with the PO form linking to it when the picker is empty. This is a bigger story and gives vendors a home.
   - **(C) Out of scope:** an empty picker shows "No vendors yet — add one through the API", and vendors become their own story.

## Code Map

**wms-be**
- `src/modules/inbound/po.command.ts`:
  - `createInTx` `:226-318`: the guard order is permission → replay → warehouse → vendor → SKUs → `assertSingleClientInTx` `:261` → `scaleLines` `:270`. Insert the kit check before `:270`.
  - `amend` `:315+`: the same position.
  - The constructor `:175` does not inject `CatalogFacade` today. The ASN command does, and so does the module.
  - `duplicatePoCode` `:960` answers `conflict` 409.
- `src/modules/inbound/asn.command.ts:478-494`: `assertNoKitLinesInTx`, with its subject hardcoded. Add a `subject` parameter and update its existing callers (create `:714`, amend, announce, `asn-import.command.ts`).
- `src/api/inbound.controller.ts:135-182` (create) and the amend route: the 409 text.
- `test/inbound.spec.ts`: PO create and amend cases, using the existing `expectProblem` pattern.

**wms-fe**
- `src/components/inbound/inbound-cards.tsx:202-313`: `PurchaseOrdersCard` (private). Add the button, the form mount, the banner and the page reset. Gate it as `asn-card.tsx:96-101,173` does (`roleHasCapability(role, 'po.manage')`).
- New file `src/components/inbound/po-create-form.tsx`. Model it on `AsnCreateForm` (`asn-card.tsx:252-386`). Reuse:
  - `LineRows` and `lineInputClass` (`components/shared/line-rows`);
  - `withoutKits` (`lib/asns.ts:215`), `useKits` and `useSkuMap`;
  - `useVendorMap` (`lib/use-inbound.ts:435`) as the picker source;
  - `ulid` and `FeedbackBanner`.
- New file `src/lib/purchase-orders.ts`: `parsePoLines`, `rupeesToPaise`, `poExpectedDate` and `poReason`.
- `src/lib/use-inbound.ts:68`: make `usePurchaseOrders` listen for `INBOUND_CHANGED_EVENT`.
- `src/lib/api/client.ts`: add `fetchApiCreatePurchaseOrder`, following `fetchApiCreateAsn` `:1779`, around the generated `inboundControllerCreatePurchaseOrder`.
- Tests: the new `po-create-form.test.tsx` and `lib/purchase-orders.test.ts`. Use the style of `asn-card.test.tsx:113-139`: `stubGlobal('fetch')` routing on path, and `writeSession(session(role))`.

## Tasks & Acceptance

**Execution:**
- [ ] `wms-be po.command.ts`, `asn.command.ts` and the controller: kit guard on PO create and amend, with the subject as a parameter. Tests for create (kit refused, nothing written), amend (kit refused) and suggested-PO submit (kit → 409). Re-export OpenAPI.
- [ ] `wms-fe client.ts`: regenerate the client and add `fetchApiCreatePurchaseOrder`.
- [ ] `wms-fe lib/purchase-orders.ts` and its test: line parsing (precision, > 0, duplicate SKU, 200 cap), rupees → paise (string arithmetic: `"12.5"` → 1250, `"0.01"` → 1, `"12.345"` refused), a date-only value as midnight IST in UTC, and the `poReason` copy.
- [ ] `wms-fe po-create-form.tsx` and `inbound-cards.tsx`: the form, the gate and the success path. A component test for each matrix row the web owns.
- [ ] `wms-fe use-inbound.ts`: the reload on `INBOUND_CHANGED_EVENT`.

**Acceptance Criteria:**
- Given an ops manager on Bengaluru DC, when they raise `PO-1001` with two lines, then the handheld's Receive list shows `PO-1001` after the next catalog sync. Nothing changes on the device side.
- Given the PO tab count showed 3, when a PO is raised, then it shows 4 without a page reload.

## Design Notes

**Why the kit guard lands now.** A kit has no stock of its own. Receiving refuses to put stock on a kit (the +stock guards). So a kit PO line could never be received and would sit open forever, and it would carry forward again at close. The ASN closed the same hole in WMS-BE #99. Two things must be verified at the design review:
- whether a replenishment reorder policy can target a kit (if it can, its suggested PO now fails submit with a clear 409, which is the right answer);
- whether any existing open PO in the demo seed carries a kit.

**One date, not per line.** A PO that arrives in several dated tranches is rare for this tenant. A per-line date would double the form's width for a field most people leave blank.

## Verification

**Commands:**
- `cd wms-be && bun run test -- test/inbound.spec.ts`: expected to pass. Then the full `bun run test`, `bun run lint`, `bun run typecheck`, and the OpenAPI export plus drift check.
- `cd wms-fe && bun test && bun run typecheck && bun run lint && bun run build`: expected to pass.

**Manual checks:**
- Live: on localhost:3001, raise a PO in the demo tenant. Confirm it appears in the list and through `GET …/inbound/purchase-orders/{id}`.

## Implementation Notes

## Spec Change Log

## Review Triage Log
