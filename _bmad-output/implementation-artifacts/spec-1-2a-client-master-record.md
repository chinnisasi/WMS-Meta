---
title: '1.2a Client master record — contacts, registered and return addresses, offboarding (departed)'
type: 'feature'
created: '2026-10-18'
status: 'ready-for-dev'
route: 'dispatch'
review_loop_iteration: 0
context:
  - 'docs/initiatives/production-readiness.md'
  - 'docs/design/SYSTEM-DESIGN.md'
  - 'docs/design/IMPLEMENTATION-GUIDE.md'
  - 'docs/design/modules/clients.md'
  - 'docs/design/frontend/IMPLEMENTATION-GUIDE.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** A client brand today is a code, a name, a status, and its tax and billing details (21-5). A real 3PL also needs:
- contacts for operations, billing and returns;
- a registered address;
- a return-to address, which 4.7 returns disposition will consume;
- offboarding, so a brand that leaves stops taking work without losing its history. `departed` exists in the status CHECK (`0040:96-101`), but nothing can set it.

**Approach:**
- **Contacts:** each client gets a list of contacts with roles.
- **Addresses:** two address groups on the client row.
- **Departure:** the status command can depart a client, but only once it is wound down. Every work-creating path refuses a departed client. An owner can reactivate it.
- **Settings:** Settings → Clients gains the screens.
- **Unchanged:** the portal and the handheld. The handheld snapshot already marks a non-active client inactive (`clients.facade.ts:115`), and it settles refused receipt lines generically.

**Decisions (user, 2026-10-18):**
1. **Departure only once wound down.** While anything listed under "The wind-down check" remains, departure is refused, and the refusal lists every blocker.
2. **A departed client takes no new work, and an owner can reverse departure.**
   - Refused: new SKUs and catalog imports, POs, ASNs, orders (channel ingest included), RMAs, channel mappings, and stock-adding operations on its SKUs.
   - Portal access ends: its sessions are revoked.
   - Still readable: history, reports, metering and client invoices. Invoices can still be prepared for usage before departure.
   - An owner can reactivate a departed client; the change is audited.
3. **Contacts are a list with roles.** Each has a name, email and phone, and may be tagged operations, billing or returns. Exactly one is primary while any exist.
4. **Split from roadmap 1.2.** The per-client operating policy is 1.2b.
5. **A suspended client still ships** (design review). Suspension only cuts the portal (21-10's meaning). The web order form, which refuses suspended clients today (`lib/clients.ts:294-300`), offers them again. Only departed clients are hidden from pickers that start new work.
6. **All staff can read contacts; owners edit them** (design review). Reading the contacts list needs any staff web session, never the portal. Writes need `clients.manage`. Contacts are not on the clients list payload.
7. **Stock that turns up after departure is refused until an owner reactivates the client** (design review).
   - Positive adjustments and count resolutions for a departed client's SKUs are refused.
   - Receipt lines carrying its SKUs are refused per line and go to the review queue.

## Boundaries & Constraints

**Always:**

*Contacts (migration 0077)*
- **The `client_contacts` table:**
  - Columns: `id`, `tenant_id`, `client_id`, `name` (trimmed, 1–120), `email` (≤254), `phone` (nullable, ≤20), `roles text[]`, `is_primary bool`, plus the tenant timestamps.
  - CHECKs:
    - `email = lower(btrim(email))`;
    - `roles <@ ARRAY['operations','billing','returns']`, with no duplicates. An empty array is allowed, for a general contact.
  - Unique `(client_id, email)`, and a partial unique `(client_id) WHERE is_primary`.
  - RLS on `tenant_id`, plus the 0041 `app.client_id` clause on `client_id`, so a portal-stamped transaction cannot read another client's contacts.
  - A `wms_rls_probe` arm.
- **At most 20 contacts per client.** A 21st is refused with 409 `contact-limit`.
- **Routes** (`tenants/{t}/clients/{c}/contacts`):
  - `GET` needs any staff web session (decision 6).
    - Ordered primary first, then by name, then by id.
  - `POST`, `PATCH …/{id}` and `DELETE …/{id}` need `clients.manage`.
  - The first contact becomes primary automatically.
  - `PATCH { isPrimary: true }` moves the primary in two statements in one transaction: clear the old one, then set the new one. A one-statement swap trips the non-deferrable partial index. `isPrimary: false` is a 400.
  - Deleting the primary while others remain is refused with 409 `primary-contact-required`.
  - A duplicate email is refused with 409 `duplicate-contact-email`.
- **Every write:**
  - is idempotency-keyed (`arm: contact-add` / `contact-edit` / `contact-remove`);
  - locks the client row `FOR NO KEY UPDATE` and replays under the lock;
  - is audited `client.contact_added` / `client.contact_edited` / `client.contact_removed`, against the client.
  - An unchanged edit is a declared no-op that stores the key.
- **Validation:**
  - **Email:** one shared `isEmailAddress` helper (the class-validator `isEmail` rule) used by both the DTO and the command.
  - **Phone:** trimmed, ≤20. This is the shipment-address rule from `assertAddress` (`address.ts:136`), extracted as `assertPhone`.
  - Failures answer 400 `validation-failed` naming the field.
- **Primary's purpose today:** listed first, and the default recipient for 5.2's client notifications.
- **The self client** may have contacts.

*Addresses (0077, columns on `clients`)*
- **Registered address:** `registered_line1/line2/city/state_code/pincode`.
  - Same shapes as the 21-5 billing columns (`0062:129-146`, `isGstinStateCode` `gstin.ts:50`).
  - All-or-none CHECK; line2 is optional.
- **Return address:** `return_contact_name/phone/line1/line2/city/state/pincode`, in the shipment shape (`AddressInput` / `assertAddress`, story 11-1).
  - All-or-none CHECK; line2 is optional.
- **`PATCH tenants/{t}/clients/{c}/addresses { registered?, return? }`:**
  - Omitted leaves a group unchanged; null clears it.
  - `clients.manage`, keyed (`arm: 'addresses'`), audited `client.addresses_updated`. A no-op stores the key.
  - The self client may have addresses. Allowed on a departed client.
- **`ClientDto`** gains `registeredAddress` and `returnAddress`.
  - Both are required and nullable.
  - A stored snapshot without them replays null-filled, following the `taxDetails ?? {…nulls}` precedent (`clients.controller.ts:251`).

*Departure (the status command, `clients.command.ts:392-470`)*
- **Targets and transitions.** `CLIENT_STATUS_TARGETS` (`:41`, also the `@IsIn` in `src/api/clients.dto.ts:59`) gains `departed`.
  - Allowed: active → departed, suspended → departed, departed → active.
  - Departed → suspended is refused with 409 `client-not-active` ("A departed client can only be reactivated").
  - The `:437` blanket refusal goes.
  - The self client stays a 400, with the DB CHECK as the second line.
- **Idempotency is unchanged.**
  - The hash arm stays `status`.
  - A refused departure rolls back and stores no key, so a retry after winding down re-runs the check.
- **The wind-down check** runs on departure only, after the row lock and the replay under it.
  - It answers 409 `client-not-wound-down` with `extensions.blockers: [{ kind, count, codes?: string[] (≤5) }]`.
  - Each module that owns a blocker exports a file-level `clientWindDownBlockersInTx(tx, tenantId, clientId)`. These files import nothing from `modules/clients` (an architecture pin), so there are no import cycles.
  - The blocker kinds:

    | Kind | What counts |
    |---|---|
    | `stock` | A new aggregate inventory read: the SKUs with a non-zero balance anywhere, receiving, QC and in-transit included. `count` is the number of those SKUs. |
    | `open-purchase-orders` | `open` |
    | `open-asns` | `announced` or `partially_received` |
    | `pending-over-receipts` | Any document |
    | `open-orders` | `accepted` or `ready_to_dispatch` |
    | `open-rmas` | `RECEIVABLE_RMA_STATUSES` = `open` or `partially_received` (`return-receipt.command.ts:96`) |
    | `pending-adjustments` | `ADJUSTMENT_PENDING_STATUSES` |
    | `open-counts` | Count tasks and variances not resolved |
    | `open-review-items` | Unresolved rejected-op rows naming its SKUs |
    | `unsettled-invoices` | Client invoices `draft` or `disputed` |

- **On departure:**
  - Revoke the client's portal sessions with the new reason `client-departed`. It goes into `SESSION_REVOKE_REASONS`, its CHECK (re-adding it takes an ACCESS EXCLUSIVE lock on `sessions`; noted, as in 0075), `SESSION_END_DETAIL` and the web notice.
  - Audit `client.departed`.
- **On reactivation:** audit `client.reactivated`. Sessions are not restored.
- **Sign-in and the portal guard** (`sign-in.command.ts:240-241`, `portal-session.guard.ts:69`): for a departed client, answer 403 `client-departed` ("Your company's account with the warehouse has ended"). A suspended client keeps `client-suspended`.

*Locking*
- **`assertClientTakesWorkInTx`** takes `FOR KEY SHARE` on the client row.
- **The non-status client writers** take `FOR NO KEY UPDATE`, so they do not queue every order create behind them. These are invoice prepare (`client-invoices.ts:907`), contacts, addresses, rename and tax details.
- **The status command keeps `FOR UPDATE`.** It conflicts with `FOR KEY SHARE`, so departure serialises against every in-flight work creation.
- **Test:** a long-held prepare does not block an order create.

*"No new work": `assertClientTakesWorkInTx(tx, tenantId, clientId)` → 409 `client-departed`*
- **Lock order:** the helper runs first in each transaction, before any document or advisory lock.
- **Where it runs:**
  - **PO create** (`po.command.ts:261`).
  - **ASN create** (`asn.command.ts:705`). Amend stays unguarded, because an open document already blocks departure.
  - **Staff ASN import:** both branches (`asn-import.command.ts:323-329`). It is a row error `client-departed` (the parse vocabulary, the DTO enum and the web labels).
  - **Order create:** both phase 1 (`order.command.ts:614`, an early exit) **and the top of the phase-3 write transaction** (`:735`), which is the real guard. A refusal there releases the grants through the existing `releaseAll` path.
  - **Channel ingest:**
    - A pre-check beside the mixed-client pre-check (`channels.ingest.command.ts` around `:186`).
    - A `mapIngestRejection` arm (`:334-381`) that maps `client-departed` to a typed 422, metered `validation-failed`, following the `mixed-client` arm. Never a transient retry.
  - **Channel mapping writers:** `channels.command.ts:1225,1253` and `channels.publish.ts:749`.
  - **Catalog import:** after the run's client is resolved (`import.command.ts:359-372`), covering fix-mode inheritance and the `self` default.
  - **SKU client correction target** (`sku-client.command.ts:144`), **kit attach** (`kit.command.ts:742`), **variant attach** (`sku.command.ts:730`).
  - **RMA create:** the order's client (returns module), before its order advisory lock (`return-authorization.command.ts` about `:789`).
  - **Positive adjustments** (`inventory.command.ts:343`) and **count resolution that adds stock** (`count.command.ts:1113`) for a departed client's SKU (decision 7).
- **Receipts:**
  - **Blind receipt naming a departed client:** 409 `client-not-active`, unchanged from 1-1.
  - **Any receipt line whose SKU's client is departed**, whatever document it arrives on and whether or not `clientId` is sent, is refused **per line** with code `client-departed`.
  - This extends the 1-1 per-line split from blind receipts to PO and ASN receipts (`receiving.command.ts:553-560,705`).
  - Adds `client-departed` to `REJECTED_GRN_LINE_CODES` (`:171`).
  - The review row is `grn.lines-refused` (Discard only: re-receive after reactivation).
  - A receipt whose every line is refused takes the 1-1 `goodsReceipt: null` arm.
  - The handheld shows its generic refused-line words. This is no handheld change; the code review verifies that the generic path exists (`device-store.ts:523` special-cases only `sku-client-mismatch`).
- **Replenishment:** the sweep and the expiry scan (`replenishment.sweep.ts`) skip a departed client's SKUs.
- **Not guarded:**
  - billing reads, metering, storage snapshots and client invoice prepare and issue;
  - reports, the ledger and audit.
  - Rate-card draft and activation already refuse a non-active client (`rate-card.command.ts:522`).

*Audit*
- `client.departed`, `client.contact_added/edited/removed` and `client.addresses_updated` go into `AUDIT_NEW_ACTIONS` (`audit.ts:111`), each pinned by `expectAuditRow`.
- Two no-op arms go into `AUDIT_NO_OP_ARMS`, with snapshot shapes the guard accepts: `clients.contactEdit:unchanged` and `clients.addresses:unchanged`.

*Web (wms-fe)*
- **`clientTakesWork(client)`** (status ≠ `departed`, in `lib/clients.ts`) and a SKU filter built on it.
  - They drive every picker that starts new work: the order form (`orderableClients` → `clientTakesWork`, decision 5), the ASN card, catalog import, SKU client correction (`sku-table.tsx:345`), kit components (`:952-961`), product variants (`products-card.tsx:460-464`), channel mapping selects (`channels-view.tsx:1237,1557`), and the rate-card draft picker (`rate-cards-card.tsx:140-142`).
  - "Create return" (`return-create-form.tsx:100`) is hidden for a departed client's orders, with "Client departed — reactivate to accept returns".
  - **Single-client gates count all clients and filter only the options.** That covers `importClientChoice` (`lib/clients.ts:115`) and the ASN card's `soleClient` (`asn-card.tsx:270`). A self client plus one departed client still shows a picker, never a forced 400.
  - History lists, reports, client invoices and usage still show departed clients.
- **Status actions** (`lib/clients.ts:357-398`, `clients-card.tsx:149,230,247`):
  - `ClientStatusAction` gains `depart`, and `clientStatusAction` returns a list:
    - active → Suspend, Depart;
    - suspended → Reactivate, Depart;
    - departed → Reactivate.
  - The depart question says what stops, that history stays, and that portal users are signed out now.
  - Success words per target.
- **Blockers:**
  - A pure `departureBlockers(problem)` reads `extensions.blockers`.
  - Words per kind ("Stock on hand in 4 SKUs", "2 open orders: SO-104, SO-109 and 1 more"). An unknown kind reads "N other open items (kind)".
  - Rendered as a `<ul>` in a `role="alert"` region under the confirm, which stays open for a retry. Pinned in `clients.test.ts`.
- **Clients card** (`clients-card.tsx:55-58,128-153`):
  - Row actions wrap, or collapse into a "Manage" disclosure at narrow widths.
  - The self row shows Contacts and Addresses only.
  - A departed row shows Reactivate, Rename, Tax details (gated on `canInvoice`), Contacts and Addresses.
  - **Contacts** is one panel kind with its own internal state: list, add, edit, remove confirm, make primary.
    - Roles are checkboxes in a `fieldset`/`legend`.
    - Opening another panel over a dirty draft asks first.
    - Focus moves to the panel's heading, and `aria-labelledby` names the client code.
  - **Addresses:**
    - Registered uses the tax form's state-code select.
    - Return reuses `StateSelect` (`components/address/state-select.tsx`) and `parseDestinationFields` (`lib/outbound-orders.ts:616`, a new `'return address'` label).
    - Each group has Clear with a confirm.
  - `contactEmailProblem` (trim, lower-case, a dot in the domain, ≤254) mirrors the server rule. The server's `validation-failed` detail is the fallback.
- **Copy:**
  - `client-departed` is mapped in every surface's reason function: `clientReason`, `correctClientReason`, and the ASN, order, kit, product, channel, return and import reasons.
  - Also new copy for `client-not-wound-down`, `primary-contact-required`, `duplicate-contact-email` and `contact-limit`.
  - The `client-not-active` words change.
  - `SESSION_ENDED_NOTICE` (`lib/portal.ts:84`) gains `client-departed`: "Your company's account with the warehouse has ended."
  - The sign-in refusal maps `client-departed` the same way.

**Never:**
- No deletion of a client or its history (AD-16).
- No portal editing or viewing of contacts.
- No change to what `suspended` blocks on the server.
- No operating policy (1.2b).
- No handheld code change.

## I/O & Edge-Case Matrix

| Scenario | State | Expected |
|---|---|---|
| Add the first contact | None | Primary; audited |
| Make B primary | A primary | A cleared, B set, one transaction |
| Remove the primary with others | — | 409 `primary-contact-required` |
| Same email, other case | — | 409 `duplicate-contact-email` |
| 21st contact | 20 | 409 `contact-limit` |
| Operator reads contacts | Staff session | 200 |
| Portal user reads contacts | — | Refused (no route) |
| Registered state `99` | — | 400 naming the field |
| Depart with stock, 2 open orders, a pending adjustment | — | 409 listing `stock`, `open-orders` (codes), `pending-adjustments` |
| Depart with a partially received RMA | — | Blocked (`open-rmas`) |
| Depart a wound-down client | Portal user signed in | Departed; the session ends (`client-departed`); the portal sign-in answers `client-departed` |
| Order create racing the departure | — | Either the order commits first (departure blocked by `open-orders`), or the order is refused at phase 3 with grants released |
| Order, PO, ASN, RMA, SKU, import or mapping for a departed client | — | 409 `client-departed` (row error on imports) |
| Channel order for a departed client's SKUs | — | 422 `validation-failed`, metered, not retried |
| Its SKU arrives on another client's PO, or a blind receipt from an older build | — | That line refused per line (`client-departed`); the rest settles |
| Found-stock adjustment or count gain on its SKU | Departed | 409 `client-departed` |
| Replenishment sweep | Departed SKUs with policies | Skipped |
| Prepare a client invoice | Departed | Allowed |
| Long invoice prepare on client A | — | A's order creates do not wait on it |
| Reactivate | Departed | Active; audited; portal after a fresh sign-in |
| Suspended client on the web order form | — | Offered (decision 5) |
| Depart the self client, or suspend a departed one | — | 400; 409 `client-not-active` |

</frozen-after-approval>

## Code Map

**wms-be**
- `src/shared/db/schema.ts:296-344`, the new `clientContacts`; `drizzle/0077_client_master_record.sql`:
  - generated, then the CHECKs, RLS (0041 client clause) and the `sessions` revoke-reason CHECK below the marker;
  - a probe per CHECK (both address groups' all-or-none, roles, email case, primary uniqueness).
- `src/modules/clients/clients.command.ts:41,392-470` (status, wind-down orchestration); the contact and address commands (follow `:315`); `src/api/clients.dto.ts:59`; `src/api/clients.controller.ts` (`:56` list, `:146,:203`, `:250-251` the DTO mapping).
- `src/modules/clients/clients.facade.ts:49,115,139,217,340,416` (`assertClientTakesWorkInTx` beside them).
- Wind-down files, one per owner, none importing `modules/clients`:
  - inventory: the aggregate stock read, pending adjustments, counts;
  - inbound: POs, ASNs, over-receipts;
  - outbound: orders;
  - returns: RMAs;
  - tenancy: review items;
  - billing: invoices.
  - `test/architecture.spec.ts` pins the no-import rule.
- Callers:
  - `po.command.ts:261`;
  - `asn.command.ts:705`; `asn-import.command.ts:323-329`;
  - `order.command.ts:401,614,735` (`releaseAll`);
  - `channels.ingest.command.ts:186,209,334-381`; `channels.command.ts:1225,1253`; `channels.publish.ts:749`;
  - `import.command.ts:359-372`; `sku-client.command.ts:144`; `kit.command.ts:742`; `sku.command.ts:730`;
  - `return-authorization.command.ts` (~`:789`);
  - `inventory.command.ts:343`; `count.command.ts:1113`;
  - `receiving.command.ts:171,553-560,705`; `replenishment.sweep.ts`.
- Lock-mode changes in `client-invoices.ts:907` and the rename and tax-details commands.
- `sign-in.command.ts:240-241`, `portal-session.guard.ts:69`; `sessions.ts:27`, `session-cookie.ts` (`SESSION_END_DETAIL`); `audit.ts:111`; `test/support/audit-guard.ts`.
- `address.ts:136` (extract `assertPhone`), `gstin.ts:50`; a shared `isEmailAddress`.
- Fix the stale `clients.md:94`.
- Tests: `test/clients.spec.ts` (transitions), and a new `test/client-master.spec.ts` covering every matrix row, the RLS probe, the migration probes, the order-create race, the lock-mode test, and the make-primary race.

**wms-fe**
- `src/lib/clients.ts:33,115,294-300,343,357-398` (`clientTakesWork`, actions, `departureBlockers`, `contactEmailProblem`, reasons).
- `src/components/settings/clients-card.tsx:55-58,104,128-153,198-258`, new `client-contacts.tsx` and `client-addresses.tsx`; `confirm-row.tsx:30`.
- `asn-card.tsx:270,342`, `import-catalog.tsx:361`, `sku-table.tsx:345,952-961`, `products-card.tsx:460-464`, `channels-view.tsx:1237,1557`, `rate-cards-card.tsx:140-142`, `return-create-form.tsx:100`, `outbound-orders.tsx:166`.
- `components/address/state-select.tsx`, `lib/outbound-orders.ts:616`; `lib/portal.ts:84`, `auth-forms.tsx:434`.
- Tests: `clients-card.test.tsx`, `lib/clients.test.ts`, panel tests, a picker-exclusion test per surface.

**meta:**
- `clients.md`: contacts, addresses, the departure lifecycle and blockers, the no-new-work rule and its callers, and the lock modes.
- `API-SURFACE.md`.
- PENDING clients: close "Client departure", record decisions 5–7.
- The repo contracts.

## Tasks & Acceptance

**Execution:**
- [ ] wms-be, in order:
  1. 0077 and the schema.
  2. The helpers: email, `assertPhone`.
  3. Contacts.
  4. Addresses.
  5. The status command and the wind-down files with their pin.
  6. Lock modes.
  7. `assertClientTakesWorkInTx` and every caller (order phase 3, ingest arms).
  8. The receipt per-line extension.
  9. Replenishment.
  10. Sign-in and the portal guard.
  11. Vocabularies and audit.
  12. Tests.
  13. The OpenAPI export.
- [ ] wms-fe, in order:
  1. Regenerate the client.
  2. `clientTakesWork` and the pickers.
  3. Status actions and blockers.
  4. The contacts panel.
  5. The addresses panel.
  6. Copy.
  7. Tests.
- [ ] meta: the docs above.

**Acceptance Criteria:**
- Given a departed client, when any path in the "No new work" list runs for it, then it is refused (`client-departed`, or per line or per row), and every read of its history still answers.
- Given any blocker present, then departure is refused and that blocker is listed.
- Given a departure racing an order create, then never both: the order committed and the client departed with the order open.

## Design Notes

**Why departure reuses the status command.** It already has the lock, replay and audit skeleton (21-10). The wind-down check runs under the client row's `FOR UPDATE`. Every work creator takes `FOR KEY SHARE` through the helper, so a departure and a creation serialise. The order create needs the check again in its write transaction, because its phase 1 commits before phase 3 writes.

**Why a separate helper from the `active` allowlists.** The portal, invite and rate-card gates refuse anything not `active`. Operator work must keep running for a suspended client (decision 5), so only departure stops it.

**Why file-level wind-down reads.** `clients` is imported by every module that owns a blocker. Each owner exports a function that imports nothing from `clients`, and the status command composes them. That keeps the dependency one-way, pinned by an architecture test.

## Verification

**Commands:**
- wms-be: `bun run test -- test/client-master.spec.ts test/clients.spec.ts`, then the full `bun run test`, `bun run lint`, `bun run typecheck`, and `bun run openapi:export` with its drift check.
- wms-fe: `bun test && bun run typecheck && bun run lint && bun run build`.

**Manual checks:**
- Settings → Clients:
  - Contacts: add, make one primary, remove.
  - Set both addresses.
  - Depart a client with stock: see the blockers.
  - Wind it down, then depart it.
  - Try an order for it.
  - Reactivate it.
- A suspended client appears on the order form.

## Spec Change Log

## Review Triage Log

### Design review — 2026-10-18 (2 reviewers: backend/data 15, web/product 12; 27 raw → 24 after dedup)

| # | Finding (reviewers) | Verdict | Disposition |
|---|---|---|---|
| R1 | Order create's client check commits before the order is written (phase 1 vs phase 3) (backend) | high — verified at `order.command.ts:401,735` | Re-check at the top of phase 3; grants released |
| R2 | `return_receipts` has no status; `open-rmas` misses `partially_received` (both) | high — verified at `return-receipt.command.ts:96` | `open-rmas` = `RECEIVABLE_RMA_STATUSES`; `open-return-receipts` dropped |
| R3 | Wind-down misses pending over-receipts, adjustments, counts and review items; positive adjustments and counts are ungated after departure; the stock read is portal-only (backend) | medium-high | Four blockers added; an aggregate stock read; **user decision 7** gates late stock |
| R4 | Channel ingest refusal falls through to a transient failure; mapping writers mis-cited (backend) | medium-high | `mapIngestRejection` arm → 422 metered; pre-check; mapping writers listed |
| R5 | Wind-down reads create module import cycles (backend) | medium | File-level reads per owner; architecture pin |
| R6 | Catalog import check at the wrong line (fix mode, self default) (backend) | medium | After client resolution |
| R7 | A blind receipt without `clientId` still books a departed client's SKUs; the PO/ASN per-line refusal is new code, not the 1-1 pattern (backend) | medium | Per-line `client-departed` on any receipt; `REJECTED_GRN_LINE_CODES`; generic device words |
| R8 | `FOR SHARE` in hot paths queues behind invoice prepare's `FOR UPDATE` (backend) | medium | `FOR KEY SHARE` vs `FOR NO KEY UPDATE`; test |
| R9 | `ClientDto` would leak contact details to every role; `primaryContact` forces a join (backend, web) | medium | **User decision 6:** contacts readable by staff, not on the list DTO; addresses required and null-filled |
| R10 | ASN import blank-client branch missed (backend) | low-medium | Both branches; vocabulary |
| R11 | Replenishment sweep has no client awareness (backend) | low-medium | Skip departed SKUs |
| R12 | Sign-in and the portal guard say "suspended" for departed (both) | low | 403 `client-departed`; copy |
| R13 | Migration details: primary swap, email uniqueness, roles CHECK, 0041 client RLS, lock note, probes, `isPrimary:false` (backend) | low | All specified |
| R14 | Code Map references off (`clients.dto.ts` path, `tenancy.dto.ts:58`, no phone helper, ASN create `:705`, RMA lock order, audit lists, no-op shapes) (backend) | low | Corrected |
| R15 | Depart reuses suspend/reactivate copy: "is active again" (web) | high | `depart` action arms; a list of actions |
| R16 | The blocker list cannot render through `ConfirmRow`'s string reason (web) | high | `extensions.blockers` shape; `departureBlockers`; alert list; unknown-kind fallback |
| R17 | Hiding departed clients breaks `importClientChoice` and `soleClient` (forced 400) (web) | high | Gates count all clients; options filtered |
| R18 | Kit, product, channel, rate-card and return pickers still offer departed clients' SKUs; reasons per surface (web) | medium | `clientTakesWork` everywhere; every reason map |
| R19 | `orderableClients` excludes suspended, contradicting the spec (web) | medium | **User decision 5:** suspended still ships |
| R20 | The self row cannot reach Contacts or Addresses (web) | medium | Self row shows those two |
| R21 | Departed rows lose Tax details needed for the final invoice (web) | medium | Kept (`canInvoice`), and Rename |
| R22 | Nested contact editing in the one-panel model; mobile width; focus; role chips (web) | medium | Single panel kind, dirty confirm, wrap or Manage, focus, checkboxes |
| R23 | Two state models; reuse `StateSelect` and the destination parser (web) | low | Specified |
| R24 | Email parity on the web (web) | medium | `contactEmailProblem` |
