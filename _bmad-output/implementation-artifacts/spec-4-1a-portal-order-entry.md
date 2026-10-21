---
title: '4-1a portal order entry — a client user places an outbound order in the portal, for their own SKUs, through a portal command sharing the order pipeline'
type: 'feature'
created: '2026-10-22'
baseline_commit: 'e1771c7fc88b060ac998c0bf2c113058b9859c1d'  # wms-be; wms-fe: 3a5a14ff1150780d13bb002d05800a63b7e3dd3b; wms-mobile: unchanged
status: 'done'
route: 'dispatch'
review_loop_iteration: 0
context:
  - 'docs/initiatives/production-readiness.md'
  - 'docs/design/SYSTEM-DESIGN.md'
  - 'docs/design/IMPLEMENTATION-GUIDE.md'
  - 'docs/design/API-SURFACE.md'
  - 'docs/design/PENDING.md'
  - 'docs/design/modules/outbound.md'
  - 'docs/design/modules/clients.md'
  - 'docs/design/frontend/SYSTEM-DESIGN.md'
  - 'docs/design/frontend/IMPLEMENTATION-GUIDE.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** A 3PL client can see its orders in the portal but cannot place one. Every order has to be sent to the warehouse and typed in by staff.

**Approach:**
- The portal gains a **Place an order** form: warehouse, a ship-to address, optional consignee GSTIN and legal name, and lines of the client's own active SKUs with quantities.
- It posts to `POST portal/orders`. That route calls a **separate portal command `OrderCommand.placePortalOrder`** (IMPLEMENTATION-GUIDE §7e: a portal write is its own command, never a flag). The command shares the order pipeline with `createOrder` through private phase helpers: validation, licence, reservations, write, outbox.

**Decisions (recommended, taken autonomously under the user's standing instruction, 2026-10-22; revised by the design review):**
1. **Split.** The **client order number** and the **staff CSV/Excel order import** are 4-1b (deferred-work). The number needs a migration that is blocked until 0087 (WMS-BE #116) merges.
2. **No migration.**
   - A portal order is `source: 'manual'`, which means "not a channel order", not "staff-entered".
   - Its portal origin is the audit actor (the client user), the 21-7b precedent. A staff-side badge is PENDING.
3. **Authority.** A new capability `orders.place`, added to the `client` set (`permissions.ts:429` → `['asn.announce','orders.place']`, pinned in `test/portal.spec.ts:472`). The owner holds every capability but is kept off portal routes (the `asn.announce` precedent). The web mirror adds it to `OPS_EXCLUDED_CAPABILITIES`.
4. **The portal command** (`placePortalOrder`, in `PORTAL_WRITES` and the architecture pins):
   - **Phase 1:** the actor re-read (401/403) and `shareLockClientInTx` with status; departed or suspended is **403** (`clientInactive`). The stamp is `{clientId}`. The SKU read is client-filtered and **active non-kit only**, so anything else is 404 `not-found`, and `mixed-client` can never name another client.
   - **Phase 3:** the write transaction, stamped. The actor re-read and the client lock and status are **repeated** at its start, so a suspension or deactivation between the phases cannot commit an order.
   - **Grants and releases** stay operator-stamped (reservation counters are tenant data). Stated and RLS-probed.
5. **Licence check through a documented unstamped seam.** Site licences are hidden from a client-stamped session by RLS (`0084`). The client gets a generic refusal ("a licence for one of these products is not on file with the warehouse"), never the site's gaps. The matrix pins a site-covered drug SKU → 201.
6. **Portal orders refuse shortages** (`backorderPolicy: 'reject'`): the whole order is refused, listing the short SKUs. This keeps a client from parking unbounded backorders and tells them at once. Staff manual orders are unchanged.
7. **Responses are portal-shaped.** The stored idempotency snapshot and the response are `{orderId, warehouseName, lineCount, placedAt}`, built in the write transaction (the announce precedent, `asn.command.ts:880`). A replay never returns the operator snapshot. A same-key race loser gets 409 `conflict` (mapped).
8. **Scope of SKUs.** Active non-kit SKUs, exactly what `portal/skus` lists. Kits and inactive sell-down from the portal are PENDING.
9. **Warehouses.** Any warehouse of the tenant. Each line shows a non-blocking "available here: N" hint from `portal/stock` for the chosen warehouse.

## Boundaries & Constraints

**Always:**
- **The staff `createOrder` is byte-identical:** its behaviour, codes and fingerprint (a golden in `test/issuance-gate-parity.spec.ts` or equivalent). The phase helpers are a refactor under it.
- **Portal hash**, a golden pinning the key order: `surface: 'portal'`, tenantId, clientId, warehouseId, destination, consigneeGstin, the legal-name fingerprint (present only when given, the 8-1d rule), and lines in base units. The portal has its **own line DTO without `ratePaise`**.
- **The RLS probe** (`wms_rls_probe`) covers the portal write set: orders, order_lines, outbox, audit_events, idempotency_keys, plus the reads it stamps.
- **No leak of internal state.** The response, the replay and the refusal details never expose reservations, rates, the phone, other clients or site licence gaps.

**Never:**
- No client order number; no import (4-1b).
- No portal cancel or edit; no kits or inactive sell-down from the portal.
- No rate from the portal.
- No partner or consignee picker.
- No change to staff orders.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|---|---|---|---|
| Place order | ACME session, 2 active ACME SKUs in stock, full address | 201 `{orderId, warehouseName, lineCount: 2, placedAt}`; `manual` order of ACME; portal list and staff list show it; audit actor = the client user | — |
| Short | one line exceeds available stock | — | 409, the policy refusal listing the short SKUs; nothing written |
| Foreign, kit or inactive SKU | a BETA SKU, an ACME kit, an inactive ACME SKU | — | 404 `not-found` |
| Departed or suspended client | — | — | 403 (`clientInactive`) |
| Suspended mid-order | suspended after phase 1 | — | 403 at phase 3; grants released |
| Staff token | operator session on `POST portal/orders` | — | 403 `role-denied` |
| Rate sent | `ratePaise` on a line | — | 400 |
| Incomplete address | missing pincode | — | 400 `validation-failed` |
| Licence | an uncovered drug SKU; a drug SKU covered by a site + client licence | 409 generic; 201 | — |
| Replay or race | same key and body; different body; concurrent same key | the cached portal shape; 422 `idempotency-key-reuse`; loser 409 `conflict` | — |

</frozen-after-approval>

## Code Map

### Backend (`workspace/core/backend/wms-be`)

**`src/modules/outbound/order.command.ts`**
- Extract the phase-1 preflight, the grant phase and the phase-3 write of `createOrder` (`:327-980`) into private helpers that take an authority gate and a transaction opener. `createOrder` keeps its exact behaviour.
- Add `placePortalOrder(command: {tenantId, clientId, actorUserId, warehouseId, lines, destination, consigneeGstin?, consigneeLegalName?, idempotencyKey})`:
  - the client-stamped transactions;
  - the actor re-read (`getMemberPortalFactsIn`) and `shareLockClientInTx` + status in phases 1 and 3 (`asn.command.ts:789` announce pattern, `clients.facade.ts:724-750` codes);
  - a client-filtered active non-kit SKU read;
  - `backorderPolicy: 'reject'`;
  - the licence check through the unstamped seam (documented carve-out, generic detail);
  - the portal snapshot;
  - the race outcome as stated.
- `src/modules/outbound/outbound.facade.ts`: a one-line delegation.

**`src/api/portal.controller.ts`**
- `POST portal/orders` (`PortalSessionGuard`, `Idempotency-Key`).
- `PortalCreateOrderDto` with its own `PortalOrderLineDto {skuId, quantity}`.
- Update the controller's field-to-class pin map.

**`src/modules/tenancy/permissions.ts`:** `orders.place`. **`test/portal.spec.ts:472`**, **`test/users.spec.ts`**, and the architecture `PORTAL_WRITES` (`test/architecture.spec.ts:2336`).

**Tests:** `test/portal-orders-create.spec.ts` covers every matrix row, the two goldens, the RLS probe arm, isolation (BETA cannot see ACME's order), and the grants released on a phase-3 refusal.

### Web (`workspace/core/frontend/wms-fe`)

**Shared ship-to fieldset**
- Move `StateSelect` into `components/shared/state-select.tsx`, with a re-export from `components/address/`.
- Extract `components/shared/ship-to-fieldset.tsx` (contact, phone, line 1/2, city, state, pincode, GSTIN with the mismatch warning, legal name).
- The staff `OrderCreateForm` (`outbound-orders.tsx:68, 513`) consumes it, unchanged in behaviour.
- `portal-boundary.test.ts:37` stays green.

**`src/components/portal/portal-orders.tsx`**
- A **Place an order** `Section` action button (the `portal-inbound.tsx:98-127` pattern): closed by default, Discard drops the draft and its key, success resets the list to page one via `pageEpoch` and shows "Order placed — N lines to {warehouse} ({placedAt IST})".
- `LineRows` with `usePortalSkuOptions` and an order-specific cap message, plus the "available here" hint from `portal/stock`.
- Shown only when the portal session holds `orders.place`.

**`src/lib/portal.ts`:** `parsePortalOrderCreate`, and `portalOrderReason` with a fixed sentence per code: every matrix code, the reject-policy shortage (listing SKUs), `licence-not-covered` (generic), `order-catalog-changed`, `reservation-store-unavailable`, `conflict` and the house set. Never `detail`.

**`src/lib/users.ts`:** `orders.place` in `CAPABILITIES`, the `client` set and `OPS_EXCLUDED_CAPABILITIES` (`:263-278`).

**Other:** `src/lib/api/client.ts` `fetchApiPortalPlaceOrder`; regenerate the client.

**Tests:** `describe('Place an order (4-1a)')` in `portal.test.tsx` (the `:507` pattern):
- the form is hidden without the capability;
- the key is reused on retry and cleared on edit;
- the body carries no `clientId` or `ratePaise`;
- the success banner;
- the refusal copy.

### Mobile

None.

## Tasks & Acceptance

**Execution:**
- [x] BE: the phase-helper refactor (staff golden green first), `placePortalOrder`, the route and DTOs, the capability, the pins, the RLS probe; OpenAPI; tests.
- [x] Web: the shared fieldset and state select, the form, the hints, parsers and mappers, the mirror, plus tests; regenerated client.
- [x] Meta docs:
  - `API-SURFACE.md`;
  - `outbound.md` (the portal command, the reject policy, the licence seam);
  - `clients.md` (portal capabilities);
  - frontend SYSTEM-DESIGN (portal Place an order, the shared ship-to fieldset);
  - READMEs;
  - PENDING: the origin badge; the portal write cap extended to orders; kits and sell-down from the portal; a ship-to address book; a client cancel request; 4-1b.

**Acceptance Criteria:**
- Given an ACME client user, when they place an order for two ACME SKUs in stock, then it appears in their portal Orders list and in the staff Outbound list as an ACME manual order, and the audit actor is that user.
- Given a drug SKU covered by the site's and ACME's licences, when ACME places an order for it, then it is accepted (the site licence is read despite the portal stamp).

## Design Notes

- **Why a separate command over shared helpers.** The guide requires portal writes to be their own stamped command; sharing phase helpers keeps one set of order rules for both surfaces.
- **Why reject shortages on the portal.** A client cannot see the staff backorder views. A refused order with the short SKUs listed is actionable; a silent backorder holds stock for 7 days and creates work nobody asked for.

## Verification

**Commands:**
- `bun run test -- test/portal-orders-create.spec.ts test/portal.spec.ts test/users.spec.ts test/architecture.spec.ts test/issuance-gate-parity.spec.ts` plus the existing order-create suites (wms-be, run alone): pass.
- `bun run lint && bun run typecheck` (wms-be, wms-fe); `bun test`, including `portal-boundary.test.ts`, and `bun run check:capability-mirror` (wms-fe): pass.

## Implementation Notes

Implemented 2026-10-22 against this spec (wms-be and wms-fe on `feat/4-1a-portal-order-entry`, uncommitted; meta docs uncommitted).

- **Phase helpers.** `createOrder`'s body became `preflightPhase` / `grantPhase` / `writePhase` plus `placeOrder` (phase 2.5), parameterised by a private `OrderSurface<R>` (transaction opener, `authorize`, `reauthorize`, `loadLineSkus`, `prefetchLicences`, `assertLicences`, `backorderRefusal`, `respond`). The staff surface is the old code path statement for statement; the existing goldens (`test/issuance-gate-parity.spec.ts`) and every order suite pass unchanged, plus a staff hash + response-key golden in the new suite.
- **The licence seam** is `portalLicenceSnapshot` (an operator-shape transaction reading only `licenceEnforcedInTx` + the new `activeLicenceFactsInTx`), run before each stamped phase transaction; the stamped phase judges with the new pure `licenceCoverageOf` (compliance's `licenceCoverageInTx` is now that pair — same result, same "no needs → no read"). Generic refusal `portalLicenceNotCovered` (`licence-not-covered`, no `skuCodes`).
- **Shortage refusal** reuses the reject-policy code `order-backorder-rejected` with a portal detail and top-level `skuCodes` (`portalStockShort`); staff `BackorderRejectedError` unchanged.
- **Phase-3 gate** repeats the full phase-1 gate (capability, actor, client `FOR SHARE` + status); a refusal throws into the existing catch, which releases every grant (proved by a grant-time interposition that suspends the client, and one that deactivates the user).
- **Race:** the same-key loser fails on `idempotency_keys`' unique index → `409 conflict` (the existing `writeIdempotencyKey`), proved deterministically with a barrier on `grantReservation` (both requests past their phase-1 replay before either writes).
- **New helper** `getWarehouseNameInTx` (tenancy) for the response's `warehouseName`.
- **Pins:** `PORTAL_WRITES` + `PORTAL_DELEGATIONS` (architecture), a scan that every `withTenantTransaction` in `placePortalOrder` is stamped, the phase helpers open none, and the seam reads exactly its two functions; `test/portal.spec.ts` (client capabilities, the portal write allowlist, 15 portal routes); `test/users.spec.ts` (47 capabilities, `orders.place` = owner + client); RLS probe arm in `test/client-isolation.spec.ts` (the whole write set under the stamp with a 42501 control, and the site licence invisible stamped / visible unstamped).
- **Web:** `StateSelect` moved to `components/shared/` (re-exported from `components/address/`); `ShipToFieldset` extracted (markup unchanged; the staff form draws it); `LineRows` gained an optional `hint` slot; `usePortalStockRows` drains `portal/stock` for the "available here" hint (on hand − allocated at the chosen warehouse).
- **Verification:** wms-be `bun run test` (110 suites, 2798 tests), lint, typecheck, build, `openapi:export`; wms-fe `bun run test` (2305), lint, typecheck, build, `check:capability-mirror` (47), `api:generate`. Mutation checks: removing the phase-3 `reauthorize` fails the two between-phases tests; removing the key clear on edit fails the web retry test.

## Spec Change Log

## Review Triage Log

Design review, 2026-10-22 (backend B, web W). Every accepted finding is folded into the spec above; all choices are recommended, taken autonomously.

| ID | Verdict | Finding → resolution |
|---|---|---|
| B1 | high | A portal flag on `createOrder` breaks §7e. A separate `placePortalOrder` over shared phase helpers; architecture pins. |
| B2 | high | The client lock and status from phase 1 don't cover the write. Repeated at the start of phase 3. |
| B3 | high | The portal stamp hides site licences, so covered orders are refused falsely and site gaps leak. An unstamped seam, a generic detail, a matrix row. |
| B4 | high | The operator snapshot is stored and replayed. Portal-shaped snapshot and response. |
| B5 | high | Departed and suspended are 403 on the portal, not 409. Matrix fixed. |
| B6 | medium | RLS probe, stamping and grants unaddressed. Probe arm; grants operator-stamped, stated. |
| B7 + W1 | high | The portal SKU list excludes kits and inactive SKUs. Scope narrowed to active non-kit (decision 8); PENDING. |
| B8 + W3 | medium | Owner and ops capability claims; missing pins. Decision 3; `portal.spec`; `OPS_EXCLUDED_CAPABILITIES`. |
| B9 | medium | Race outcome unstated. 409 `conflict`, mapped. |
| B10 | medium | No write cap; unbounded backorders. Reject policy (decision 6); PENDING cap. |
| B11 | low | Hash and DTO pinning. Golden; own line DTO. |
| B12 | low | "manual" read as staff-entered. Decision 2 wording. |
| W2 | high | An address fieldset cannot cross the portal boundary. Shared `StateSelect` and ship-to fieldset, consumed by both forms. |
| W4 | medium | A custom-role row is impossible. Replaced by staff-token 403 and a hidden-button test. |
| W5 | medium | The client cannot identify the placed order. Response fields and banner; reject policy makes shortage explicit. |
| W6 | medium | Error map incomplete. Full fixed-sentence map. |
| W7 | medium | Warehouse choice implicit. "Available here" hint (decision 9). |
| W8 | low | Wrong cap copy. Order-specific message. |
| W9 | low | Form placement. Section action button pattern. |
| W10 | low | Omissions without PENDING. Address book and cancel request in PENDING; test plan. |

Code review, 2026-10-22 (Blind Hunter BH, Edge Case Hunter EC, Verification Gap VG). Routes taken autonomously (recommended).

| ID | Verdict | Finding → resolution |
|---|---|---|
| BH7 + EC8 + EC9 | medium | Patch: a SKU deactivated between phases is placed (sell-down) from the portal, against decision 8. The portal surface refuses any inactive SKU at phase 3; OpenAPI text fixed. |
| BH5 | medium | Patch: the portal licence assert returns on a null prefetch (fail-open), and SKUs hidden by RLS drop out of the re-check. Throws on null; a locked-SKU count below the line count refuses. |
| BH6 | low, accepted | The portal's phase-3 licence facts are read just before the write transaction, not inside it. A narrow window, recorded with the existing licence-withdrawal race in PENDING. |
| EC7 | low | Patch: the unstamped licence read runs before the authority check and on every replay. Moved after authorize and the replay miss. |
| BH1 | low | Patch: the hint is `onHand − allocated`, not ATP. Relabelled "on hand, not yet allocated". |
| BH2 + EC1 + EC2 | medium | Patch: a truncated stock read shows real stock as "0". No hint when truncated and no row. |
| BH3 + EC3 | low | Patch: hints stay stale after a shortage refusal. Stock reloaded on `order-backorder-rejected`. |
| EC4 + EC5 + EC6 | low | Patch: zero warehouses, a null session on submit and a failed stock read give no feedback. Status, the unauthenticated sentence, ReadFailure with retry. |
| BH8 | medium | Patch: the site-seam test passes without the seam. Control: client licence only, refused. |
| BH9 | low | Patch: the portal staying off the dedup and backorder-record paths is unpinned. Asserted (null channel refs) with a test. |
| BH10 | medium | Patch: the "deactivated" test sets `invited`. Uses `deactivated`. |
| BH11 + VG1 + VG2 | medium | Patch: untested arms (the phase-3 licence re-check, enforcement off, the inactive race, a GSTIN state mismatch). Tests added. |
| BH12 | low | Patch: no client-side precision check. Per-line check naming the line. |
| BH13 | low | Patch: the 200-line ceiling is duplicated as literals. BE derives it from the staff constant; FE pins it equal in a test. |
| BH14 | low | Patch: `consigneeLegalName` is unbounded in the DTO. `@MaxLength(100)`. |
| VG3 | medium | Patch: the in-flight lock is untested. Held-POST test. |
| VG4 | low | Patch: the truncated catalogue and single-warehouse auto-pick are untested on the order form. Tests copied. |
| BH4 | low | Patch (docs): the 2,000-SKU portal cap now blocks orders too. The PENDING typeahead entry is extended to the order form. |
| VG5 | medium | Deferred: no runtime test that the portal command's transactions carry the client stamp. The repo's portal-write pattern (21-7b) relies on the source scan plus the probe; a non-superuser harness is cross-cutting. |
| VG-other | low, rejected | `resolveDedupLoser` appears reachable on the portal. Unreachable (null channel refs), now pinned (BH9). |
| BH14 (follow-up) | low | The `@MaxLength(100)` added for BH14 broke the IMPLEMENTATION-GUIDE §4 rule (8-1d): the cap is counted in code points after the trim, by the command, behind the replay. A UTF-16 DTO cap would refuse names the command accepts. Reverted; the DTO description says the command enforces it. |
