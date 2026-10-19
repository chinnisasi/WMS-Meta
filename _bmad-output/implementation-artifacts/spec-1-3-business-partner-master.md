---
title: '1.3 Business partner master — vendors, consignees, transporters; client links; PO vendor must be linked'
type: 'feature'
created: '2026-10-19'
status: 'done'
baseline_commit: 'd3119bd9b54c5a84021792d60f9a16626237e62f'  # wms-be; wms-fe: 99579bf9fef9eefb3409e18c627358df2dbb387d; wms-mobile: df2ef8b66e73f1e5a4889b572131530857f78e1e (branches feat/1-3-business-partner-master)
route: 'dispatch'
review_loop_iteration: 0
context:
  - 'docs/initiatives/production-readiness.md'
  - 'docs/design/SYSTEM-DESIGN.md'
  - 'docs/design/IMPLEMENTATION-GUIDE.md'
  - 'docs/design/modules/inbound.md'
  - 'docs/design/modules/clients.md'
  - 'docs/design/modules/replenishment.md'
  - 'docs/design/frontend/IMPLEMENTATION-GUIDE.md'
  - 'docs/design/mobile/IMPLEMENTATION-GUIDE.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** Today a vendor is just `{code, name, isDefault}`:
- it can be created only through the API;
- it has no GSTIN, no address, no status and no client;
- a PO can name any vendor in the tenant, even one that has never supplied that PO's client;
- consignees and transporters are not records at all; they are free text typed onto each order or e-way bill.

A 3PL needs one master record per real company. Each client then chooses which of those companies it trades with.

**Approach:** The `vendors` table is renamed in place to `business_partners`, so every id survives and `purchase_orders.vendor_id` / `suggested_pos.vendor_id` stay valid.

**Partners**
- **One partner = one GST registration.** It carries the roles vendor / consignee / transporter, a code, a display name and legal name, a GSTIN and PAN, a registered address and a dispatch address, one contact, and a status (active / inactive, with a reason).

**Client links**
- `partner_client_links` covers vendors and consignees only. A link holds the client's own code for the partner, an active flag and an optional default-vendor flag.

**Purchase orders**
- **Vendor guard:** PO create and suggested-PO submit refuse a vendor that is not an active partner with an active vendor link to the PO's client.
- **Frozen snapshot:** a PO keeps the vendor's details as they were at creation.

**Screens**
- **Settings → Partners** on the web lists partners and lets the user add, edit, link and deactivate them.
- **Handheld:** the receive screen shows the PO's vendor name.

**Decisions (agent):**
1. **Status is `active | inactive` plus an optional reason.** D3's "blocked" means the same thing for new documents. Open POs keep receiving.
2. **The default vendor moves onto the link,** with at most one per client. The replenishment sweep picks the default for the SKU's client.
3. **One contact and two addresses sit on the partner row.** A list of contacts, and several ship-to addresses for a consignee, wait for roadmap 4.2.
4. **The capability is still `vendor.manage`.** Nothing displays a capability label, so only a code comment changes.
5. **A partner is one GST registration.** A company registered in two states is two partners. PAN is not unique.

**Decisions (user, 2026-10-19):**
6. **Consignees and transporters are master records only.** Orders, e-way bills and gate-in keep their free fields until roadmap 2.3 / 4.1 / 4.2 / 4.9 add pickers.
7. **Links come from history.** Migrated vendors are linked only where history exists (POs and open suggested-PO drafts). A vendor with no history migrates unlinked.
8. **No portal surface.** Links get client-scoped RLS, ready for later portal stories.
9. **The spec stays whole.** It runs well over the 1,600-token target.
10. **The old default stays default only where linked.** A client with no link to it gets drafts with no vendor until a person picks one or sets that client's default.

## Boundaries & Constraints

**Always**

*Deactivation*
- Nothing is ever deleted. A link is switched off with `PATCH {active:false}`.
- An inactive partner, or an inactive link, cannot go on a new PO or a suggested-PO submit.
- A successor PO created at close copies its vendor and snapshot without re-checking.

*Partner fields and validation* — every check runs on the merged row, after the patch is applied:
- `code`: required, unique per tenant. A clash is a 409 `partner-code-taken`.
- `name`: required. This is the existing `vendors.name`.
- `legal_name`: optional.
- `gstin`: optional; it may be absent for unregistered suppliers.
  - It goes through `normalizeGstinInput`, `GSTIN_RE` and `gstinPrefixProblem`.
  - It is unique per tenant through a partial unique index `WHERE gstin IS NOT NULL`.
  - Create and update each pre-check with a `SELECT` and return 409 `partner-gstin-taken` naming the holder's code. A late 23505 maps to the same code without the name.
- `pan`: must match `/^[A-Z]{5}\d{4}[A-Z]$/`.
  - When it is absent and a GSTIN is present, it is derived from GSTIN characters 3–12.
  - A PAN that differs from the GSTIN's is a 400 `pan-gstin-mismatch`.
- Addresses:
  - The registered address uses the clients' registered shape: `line1, line2?, city, stateCode, pincode`.
  - The dispatch address uses the same shape.
  - Each group is all-or-none, enforced by a CHECK, using the `clients_registered_address_format` pattern.
  - A GSTIN prefix that differs from the registered `stateCode` is a 400 `gstin-state-mismatch`.
- Contact: `contact_name`, `contact_phone`, `contact_email`, all optional.
- `roles`: a non-empty `text[]` drawn from `PARTNER_ROLES`.
- **PATCH is tri-state:** an absent key means unchanged, and `null` clears the value. This applies to gstin, pan, legal name, contact and each address group.
- Status and reason are tied together:
  - The reason is null whenever the partner is active.
  - Reactivating clears the reason.

*Links*
- A link is unique on (partner, client, role), where role is vendor or consignee.
- Linking a transporter is a 400 `link-role-invalid`. Linking a role the partner lacks is the same error.
- A POST for a triple that already exists is a 409 `link-exists` naming the `linkId`.
- Creating or reactivating a link:
  - requires an active partner, otherwise 409 `partner-inactive`;
  - refuses a departed client with 409 `client-departed`.
- The `self` client can be linked; the screen shows it as "Your company".
- `client_code`:
  - It is trimmed, with case kept.
  - It is unique across all links, inactive ones included, on (tenant, client, role) `WHERE client_code IS NOT NULL`.
  - A clash is a 409 `link-client-code-taken`.

*Default vendor*
- Index: `(tenant_id, client_id) WHERE is_default`.
- A CHECK enforces that `is_default` implies role = vendor AND active.
- Deactivating a link clears `is_default`. Deactivating a partner clears `is_default` on all of its links. Reactivating never brings the default back.
- Setting a default requires an active link, an active partner and the vendor role, and clears the client's previous default in the same transaction. A leftover 23505 maps to 409 `default-vendor-conflict`.

*Roles*
- Removing a role while the partner still has active links in that role is a 409 `partner-role-in-use`.
- Removing the vendor role while the partner is on open POs is allowed. Those POs carry on.

*Locks* — the order is always client → partner → link:
- Partner status changes, and link updates that change `active` or `is_default`, take `SELECT … FOR UPDATE`.
- Every other edit takes `FOR NO KEY UPDATE`.
- Link create and update lock the partner row (`FOR NO KEY UPDATE`) before checking its roles. Role removal does the same, so it serialises with them.
- Setting a default first locks the client row (`FOR NO KEY UPDATE`).
- The PO guard takes `FOR KEY SHARE` on the partner and the link. That conflicts only with `FOR UPDATE`, so status and active flips serialise against PO create, while renames do not queue POs.

*PO create guards*
- The order becomes: permission → replay → warehouse → SKUs → single client → client takes work → **vendor**.
- The vendor check moved later on purpose: with both an unknown vendor and an unknown SKU, the SKU error now wins.
- Vendor refusals:

  | Case | Response |
  |---|---|
  | Unknown vendor | 404 |
  | Partner without the vendor role | 409 `partner-not-vendor` |
  | Inactive partner | 409 `vendor-inactive` |
  | No active link to the PO's client | 409 `vendor-not-linked`, naming the client code |

- Suggested-PO submit gets the same checks through `createInTx`.

*Vendor snapshot*
- `purchase_orders.vendor_snapshot jsonb` is nullable in the schema.
- Shape v1: `{v:1, code, name, legalName, gstin, stateCode, registeredAddress, dispatchAddress}`, with every key always present and null where empty.
- It is written at create and copied at close-successor.
- It is optional or nullable in `PurchaseOrderSnapshot`, `PurchaseOrderDto` and the stored replies, because they predate it.
- The catalog snapshot's `openPurchaseOrders[]` gains `vendorName`: required on the backend, optional on the device.

*The sweep*
- The default vendor is picked per SKU client: an active partner with an active default vendor link.
- A client with no default gets drafts with `vendorId` null.
- `SuggestedPoDto` gains `clientId`.

*Listing*
- `GET /partners?role&clientId&status&q` returns a keyset page of `PartnerDto`, each including its links as `[{id, clientId, role, active, isDefault, clientCode}]`.
- `clientId` filters with an `EXISTS` over active links in the given role.
- `q` is an escaped `ILIKE` over code, name, legal name and GSTIN.

*Idempotency and audit*
- **Hashes:** every command is keyed, and its hash carries an `arm:` discriminator.
- **Locks and replay:** lock-taking commands replay again under the lock.
- **No-ops:** an unchanged partner PATCH, link PATCH or status flip stores the key, writes no audit row and goes into `AUDIT_NO_OP_ARMS`.
- **Audit actions:** `partner.created`, `partner.updated`, `partner.deactivated`, `partner.reactivated`, `partner.linked`, `partner.link_updated` (code or default changed), `partner.link_deactivated`, `partner.link_reactivated`.
- **Audit targets:** `partner` and `partner_link`.
- **The old vendor vocabulary:**
  - `vendor.created` and the target `vendor` leave the write registry.
  - The audit-read `targetType` filter still accepts `vendor` for historical rows.
  - The `vendor.created` **outbox** event stays: it is emitted when a partner is created with the vendor role, not when a role is added later.

*Portal*
- `partner_client_links` gets the tenant + `app.client_id` RLS clause from 0041.
- The portal gets no partner route.
- Portal PO reads stay vendor-free.

**Never**
- No foreign keys, and no hard delete.
- No consignee or transporter pickers on orders, e-way bills or gate-in.
- No portal screens.
- No vendor import.
- No lead time on links.
- No GSTIN checksum check.
- No `/vendors` alias.
- No capability rename.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected | Error |
|---|---|---|---|
| Create vendor | `{code,name,roles:['vendor'],gstin}` | 201, PAN derived, `vendor.created` outbox | N/A |
| GSTIN collides on edit | P-2 created without a GSTIN, then PATCHed to P-1's | unchanged | 409 `partner-gstin-taken` naming P-1 |
| Clear GSTIN | PATCH `{gstin:null}` | GSTIN cleared; PAN kept | N/A |
| Link | vendor P → client C, `clientCode:'SUP-9'` | link active | 409 `link-exists` / 409 `client-departed` |
| Unlinked PO | client C's SKUs, P not linked to C | no PO | 409 `vendor-not-linked` |
| Deactivate vs PO create | concurrent | serialised: the PO commits first, or it is refused | N/A |
| Two set-defaults for C | concurrent | one default | 409 `default-vendor-conflict` at worst |
| Deactivate the default partner | P is C's default | default cleared; next sweep drafts `vendorId:null` | N/A |
| Stale draft | draft's vendor link deactivated | picker shows "(not linked / inactive)"; submit refused | 409 `vendor-not-linked` |
| Migration: defaults | V1 and V2 both `is_default`, both with POs for C | C's default = the lower `(created_at,id)` | N/A |
| Migration: links | V has POs for C1, a draft for client C2's SKU | V same id; active links V–C1, V–C2; full v1 snapshot on every PO | aborts naming the PO if a `vendor_id` resolves to nothing |

</frozen-after-approval>

## Code Map

**Backend (`wms-be`)**
- `src/shared/db/schema.ts`
  - :1932 `vendors` → `businessPartners`.
  - Rename the index constants.
  - Add the new columns and `partnerClientLinks`.
  - `purchaseOrders` (~:1984) gains `vendorSnapshot`.
- `drizzle/0079_business_partners.sql` (hand-written; the drizzle snapshot and journal are edited so that `db:generate` reports "No schema changes"). In order:
  1. `ALTER TABLE vendors RENAME TO business_partners`, renaming its index and policy.
  2. Add the columns, CHECKs and partial indexes.
  3. Create the links table, with RLS copied from `0041_client_isolation_rls.sql`.
  4. Backfill links from `DISTINCT (vendor_id, client_id)` over `purchase_orders` ∪ (`suggested_pos` drafts ⋈ `skus.client_id`).
  5. Backfill the default: per client, the linked `is_default` vendor with the lowest `(created_at, id)`.
  6. Backfill `vendor_snapshot` in the full v1 shape.
  7. Run a DO-block probe that raises if any PO has a null snapshot or an unresolved vendor.
  8. Drop `is_default`.
- `src/modules/partners/` (new): `partners.command.ts`, `partners.facade.ts`, `partners.dto.ts`, `partners.module.ts`.
  - The facade provides `assertVendorLinkedInTx(tx, tenantId, vendorId, clientId)`, which returns the v1 snapshot, plus `findDefaultVendorForClientInTx`, `list` and `get`.
  - Add the module to `app.module.ts` and import it into the inbound and replenishment modules.
  - Add an architecture ownership guard: only `partners/` writes `business_partners` and the links table.
- `src/api/partners.controller.ts` (new) — routes:
  - `GET/POST /tenants/:t/partners`
  - `PATCH /partners/:id`
  - `PATCH /partners/:id/status`
  - `POST /partners/:id/links`
  - `PATCH /partners/:id/links/:linkId`
  - Writes need `vendor.manage`.
- `src/api/inbound.controller.ts:74,113` — remove the vendor routes.
- `src/modules/inbound/inbound.dto.ts` — remove `CreateVendorDto`, `VendorDto` and `VendorListQuery`; `PurchaseOrderDto` (:305-345) gains `vendorSnapshot?`.
- `inbound.module.ts` — remove the provider.
- Delete `vendors.command.ts`.
- `inbound.facade.ts` — remove `createVendor` (:329), `findDefaultVendorInTx` (:374) and `listVendors` (:405-440). The PO list (:461) and detail (:523) map `vendorSnapshot`.
- `src/modules/inbound/po.command.ts`
  - Delete the vendor check at :250, and the `assertVendorInTenant` method at :755-770.
  - Call `assertVendorLinkedInTx` after :256-270.
  - Write the snapshot at :286.
  - Copy it to the successor at :595.
  - Add it to the `lockPo` select and `snapshotOf` (:875).
  - `PurchaseOrderSnapshot` gains an optional `vendorSnapshot`.
- `src/modules/replenishment/replenishment.sweep.ts:83-125,301,315`
  - `EffectiveCandidate` gains `clientId`.
  - The default is cached per client.
  - `replenishment.dto.ts:222-252` `SuggestedPoDto` gains `clientId`.
- `src/modules/inbound/receiving.facade.ts:533` and `receiving.dto.ts:830` (`CatalogSnapshotPoDto`) gain `vendorName`.
- `src/shared/primitives/audit.ts:97,119` — swap in the partner actions and targets; no-op arms go in `test/support/audit-guard.ts:61` `AUDIT_NO_OP_ARMS`. The audit-read target enum is in `reporting/reporting.dto.ts:488`.
- `permissions.ts:30` — comment only.
- Tests:
  - New `test/support/linked-vendor.ts` with `createLinkedVendor(app, tenant, clientId)`.
  - Update the ~20 suites that POST `/vendors` or raw-insert/clean `vendors`: `inbound`, `receiving`, `kits`, `adjustment-approval`, `catch-weight`, `client-isolation` (:133, :555, :630; policy count :969 115 → 116), `client-dimension`, `replenishment`, and others found by grep.
  - `architecture.spec.ts:1186,2859`.
  - New `test/business-partners.spec.ts`, covering the matrix, the race tests and `expectAuditRow`.
  - New `test/business-partners-migration.spec.ts`: a populated database, following the `reporting-migration.spec.ts` pattern.
  - `scripts/seed-demo.ts:579-614` — partners with GSTINs, links and a default.

**Web (`wms-fe`)**
- `src/lib/api/client.ts` — replace `fetchApiListVendors` (:62, :393, :2060) with partner wrappers.
- New `src/lib/partners.ts` — validation that mirrors the server: reuse `parseGstinField` (`lib/gstin.ts:38`), add a PAN helper, and send `null` to clear.
- Settings tab (placed after Clients):
  - `src/lib/page-tabs.ts:146`, `page-tabs.test.ts`;
  - `settings-tabs.tsx:51-73`;
  - `settings/page.tsx:28` description.
  - No setup-checklist step.
- New `src/components/settings/partners-card.tsx`, built on the `clients-card.tsx` pattern (Panel / DataTable / ConfirmRow / dirty guard). Panels: edit, links (client select, code, default, active), status. Read-only without `vendor.manage`.
- `src/lib/use-inbound.ts:435` `useVendorMap` → reads `?role=vendor`.
- `src/components/inbound/inbound-cards.tsx:235,258-262` — the vendor column shows `po.vendorSnapshot?.name ?? '—'`, without using `useVendorMap`.
- `replenishment-view.tsx:1054-1097` — show active vendors linked to `draft.clientId`, with a fallback option whenever the draft's vendor isn't in the list.
- `src/lib/audit.ts:23,71` — partner labels; keep `vendor`.
- Update the mocks: `replenishment-view.test.tsx:234`, `over-receipt-queue.test.tsx:117`, `drill-screens.test.tsx:648`.

**Handheld (`wms-mobile`)**
- `src/api.ts:1249` — `vendorName?: string`. No parser change and no default.
- `src/receiving/draft.ts` — new `poCardDetail(po)` and `poCardAccessibilityLabel(po)`, on the `asnCardDetail` precedent at :1424.
- Use them in `app/receive.tsx:1095` `PoCard` and `app/inbox.tsx:459` `ReceiveTaskCard`.
- `device-store.test.ts:22` — assert that a legacy seal still reads.

## Tasks & Acceptance

**Execution**
- [x] `wms-be` schema + 0079 + migration test: rename in place, links, backfills, probe, RLS, CHECKs. Existing references must not break.
- [x] `wms-be` partners module + controller + audit/arch wiring: the commands, locks and routes above.
- [x] `wms-be` po.command / inbound facade + DTOs / sweep / receiving snapshot: the guard, snapshot, per-client default and `vendorName`.
- [x] `wms-be` tests + helper + seed: the matrix, a same-key race per lock-taking command, deactivate-vs-PO and set-default races, `expectAuditRow` for every action.
- [x] `wms-fe` client wrappers, Partners tab, picker, PO column, audit labels + tests.
- [x] `wms-mobile` api, draft helpers, two cards + tests.
- [x] Meta docs (landing last):
  - new `docs/design/modules/partners.md`;
  - `inbound.md` (vendors section, guard order at :327);
  - `replenishment.md:231`;
  - `API-SURFACE.md:115-116`;
  - `docs/repos/{wms-be,wms-fe,wms-mobile}/README.md`;
  - PENDING.

**Acceptance Criteria**
- Given a populated database, when 0079 runs, then:
  - every PO's `vendor_id` resolves to a partner with the same id;
  - every historical (vendor, client) pair has an active link;
  - every PO has a full v1 `vendor_snapshot`;
  - each client has at most one default.
  
  The migration test asserts all four.
- Given an Ops Manager in Settings → Partners, when they add a partner, link it to client C as a vendor and later deactivate it, then the replenishment picker offers it for C's SKUs only while it is active and linked.
- Given a Warehouse Operator, when they open Partners, then they see it read-only.
- Given a handheld with a cached snapshot from before this change, when a PO card renders, then it renders without a vendor name. A fresh snapshot shows the name, and the screen reader reads it out.

## Implementation Notes

- **Commits (branch `feat/1-3-business-partner-master`):**
  - wms-be: `c9c8045` (feature), `2c9d346` (sweep test from the matrix audit), `4f241ac` (review fixes)
  - wms-fe: `3ada953`, `d30e9d9`
  - wms-mobile: `8d589fe`
- **Beyond the Code Map:**
  - The registered-address rule moved to `src/shared/primitives/registered-address.ts`, shared by clients and partners. The clients' 400 title is unchanged.
  - `lockClientInTx` gained an optional lock-mode argument. Its default keeps every existing caller's behaviour.
  - The inbox card's spoken label now matches the receive card's ("Receive against …").
- **Matrix audit:** one row, "Deactivate the default partner", was covered only indirectly. A direct test was added in `test/replenishment.spec.ts` (`2c9d346`).
- **Final verification after the review fixes:**
  - wms-be: lint, typecheck and build pass; all 97 suites (2,337 tests) pass. On a fresh database the migrations apply and the schema round-trip check passes, and `db:generate` reports "No schema changes".
  - wms-fe: `api:generate`, lint, typecheck, the capability mirror check and build pass; 1,864 tests pass.
  - wms-mobile: 672 tests pass; typecheck passes.
- **Not done:** the demo seed was updated but not run, and the local `wms` dev database is still at 0078.

## Spec Change Log

## Review Triage Log

**Design review, 2026-10-19.** Three reviewers: backend claims (B), edge cases (E) and clients/contract (F). There were 52 raw findings, about 35 after merging duplicates. Every confirmed one is patched into the spec above.

- D1 high (B1, E2): several `is_default` vendors would break the one-default index. The backfill now picks the lowest `(created_at, id)`.
- D2 high (B2): the migration dropped `vendors` before the backfills read it. Fixed by renaming in place (B12) and ordering the steps.
- D3 high (B3, F6): retiring `vendor.created` broke the architecture equality test and historical audit filtering. The vocabulary is now explicit, the read enum keeps `vendor`, and web labels are added.
- D4 high (B4, E3): migrated drafts and defaults would fail at submit. Links are now also backfilled from drafts, and the user decided default-where-linked (decision 10).
- D5 high (E1, B5): `FOR KEY SHARE` does not conflict with plain UPDATEs. The spec now names a lock per command, with `FOR UPDATE` on status, active and default flips.
- D6 high (E4, B7): the default's predicate and lifecycle were undefined. The index, CHECK, clearing on deactivation and the sweep filter are now defined.
- D7 high (E5): concurrent set-default calls raced. Set-default now locks the client row, and 409 `default-vendor-conflict` was added.
- D8 high (E6): a 23505 cannot name the existing holder. A pre-check `SELECT` was added, and it runs on update as well.
- D9 high (F1): the PO reads that carry the snapshot were unnamed. Now named: list, detail and mutation; optional for older replies.
- D10 high (F2): the picker could not filter by client. Added `SuggestedPoDto.clientId`, links inline on `PartnerDto`, and defined the `clientId` filter.
- D11 high (F3): the picker could submit a vendor it was not showing. Added a fallback option and an I/O row.
- D12 med (E7, B18): GST registration vs company was ambiguous. Decision 5: a partner is one registration, and PAN is not unique.
- D13 med (E8, E9, F10): validation is now run on the merged row, PATCH is tri-state with `null`, PAN is derived, and the GSTIN/state check was added.
- D14 med (E10, E11, B10, B11): the columns, address shapes and the full v1 snapshot shape are defined. The snapshot is nullable in the schema, and the migration probe aborts on any orphan.
- D15 med (E12, B6): there was no lock order. It is now client → partner → link, and role checks run under the partner lock.
- D16 med (E13, B14): the link lifecycle was inconsistent. Unlink is replaced by PATCH active, `link-exists` was added, and the audit names were fixed.
- D17 med (E14, F9): rules for departed clients and the `self` client are now stated.
- D18 med (E15, B8): added `partner-not-vendor`, and stated that the guard-order change is deliberate.
- D19 med (E16): `client_code` normalisation and uniqueness, including inactive links, are defined.
- D20 med (E17): the list uses `EXISTS`, the `ILIKE` is escaped, and indexes are listed.
- D21 med (B9, E19): the successor `lockPo` and `snapshotOf` are wired, and the field is optional in stored snapshots.
- D22 med (B12): rename in place with a hand-written migration; `db:generate` must come back clean.
- D23 med (B13, F14): the test fallout is enumerated, and a shared `createLinkedVendor` helper was added.
- D24 med (B15): `arm:` discriminators, no-op arms and race tests per lock-taking command.
- D25 med (F4, F5, F7): the PO column file is corrected, the web breakage is listed, and the wrappers go in `client.ts`. The tab work is listed in full.
- D26 med (F8, B16): decision 5's label did not exist. The capability is unchanged and only a comment changes.
- D27 low (F11, F12): handheld — no parser change, testable card helpers, and a legacy-seal assertion.
- D28 low (F13): added a meta docs task, including a new `modules/partners.md`.
- D29 low (B16, B17): line references corrected; the module wiring and the `EffectiveCandidate.clientId` change are listed.
- D30 low (E18): `created_at` is preserved by the rename in place, and the status/reason CHECK was added.
- D31 low (E20): `vendor.created` is emitted only when a partner is created with the vendor role; adding the role later does not emit it.
- Rejected: none.

**Code review, 2026-10-19.** Three layers: blind (B1–B15), edge-case (E1–E9), verification-gap (V1–V4 plus one other finding).

- C1 medium (E1, B9): `updateLink` keys the departed-client check on the request flags, not on the real transition. Setting a default on a departed client's active link skips the check, so the departed client gets a default. Sending `active:true` to an already-active link is wrongly refused. **Patch:** decide "reactivating or setting default" after the lock, and refuse a departed client on those transitions only.
- C2 medium (E5): the Links panel resolves its partner from the current list page. After a change the list resets to page one, so a partner on a later page keeps showing its old links. **Patch:** the panel takes the PartnerDto the mutation returns.
- C3 medium (E3): PATCHing a GSTIN without a PAN, when the stored PAN was derived from the old GSTIN, returns 400 `pan-gstin-mismatch`. This contradicts "derived when absent". **Patch:** re-derive the PAN when it was the old GSTIN's.
- C4 low (E2): re-deactivating with no reason silently clears the stored reason and audits `partner.updated`. **Patch:** a missing reason on the same status keeps the stored one.
- C5 low (B8): `updateStatus` validates after taking the FOR UPDATE lock, so a malformed request holds up PO creates, and an unknown partner with a bad body answers 404 instead of 400. **Patch:** validate before the lock.
- C6 low (E8, B7, V-other): moving `assertRegisteredAddress` changed the clients' 400 title from "Invalid registered address" to "Invalid address". **Patch:** keep the clients' title.
- C7 low (E7): the facade comment says a partner edit never queues behind a PO's KEY SHARE, but a code rename updates a unique-key column and does queue. **Patch:** correct the comment.
- C8 low (E6): a failed code-parse alert stays up after later successful link changes. **Patch:** clear it on the next action.
- C9 low (B1): `PartnersFacade.get()` has no caller and no route. **Patch:** delete it.
- C10 false (B14): the seed already links Vistara to GLOWCO as GLOWCO's default (`scripts/seed-demo.ts:1082`, the step "GlowCo trades with Vistara"). No change made.
- C11 medium (V1): no test where create-with-default replaces an existing default. **Patch:** add the test.
- C12 medium (V2): no test that the audit filter still accepts the retired `vendor` target. **Patch:** add trail and export cases.
- C13 medium (V3): the web PO vendor column (the frozen name, or "—") has no assertion. **Patch:** add one.
- C14 medium (V4): no test for 409 `partner-inactive` on set-default or reactivate of an inactive partner's link. **Patch:** add one.
- C15 medium (B15): no test that one client's set-default leaves another client's default on the same partner alone. **Patch:** add one.
- R1 low, rejected (E4, B5): the `?? ''` fallbacks for `clientId` and `vendorName`. Neither case is reachable: SKUs are never deleted, and the migration probe guarantees every PO has a snapshot. Making the DTO nullable would widen the contract.
- R2 low, rejected (E9, B13): the inbox card's spoken label now matches the receive screen's. This was deliberate, keeps one label helper, and nothing depends on the old wording.
- R3 low, rejected (B2): replacing a default writes one audit row, on the link that became default, not one per link touched. Per-link rows would add complexity, and the actor and time are already recorded.
- R4 rejected (B3): a migration notice for dropped defaults. Decision 10 accepted this behaviour.
- R5 rejected (B4): `vendor_snapshot` NOT NULL. The spec makes it nullable on purpose (D14); the fix would be a spec edit.
- R6 low, rejected (B6): the `vendor.created` outbox payload lost `isDefault`. Nothing in the code consumes that event.
- R7 rejected (B10): departure leaves links untouched, by design (D17). A departed client cannot take new POs anyway.
- R8 low, rejected (B12): `role=transporter&clientId=` returns empty, which is correct, harmless, and would need extra validation to refuse.

## Design Notes

**Why rename in place.** Two tables hold `vendor_id` with no foreign key. `ALTER TABLE … RENAME` keeps the ids and `created_at`, so the keyset order holds, with no copy and nothing to prove by row count. The probe only has to prove that the backfills are complete.

**Why the default moved onto the link.** Once vendors are shared across clients, a tenant-wide default could hand client B's draft to a vendor that only client A uses. That draft would then fail the link check when submitted.

**Why the v1 snapshot always carries every key.** The snapshot is what later documents print: the 2.9 GRN header, the inward e-way bill and return-to-vendor. A single, fully keyed shape, with a version marker, means none of those readers has to handle a second shape left behind by the backfill.

## Verification

**Commands:**
- `bun run lint && bun run typecheck && bun run build && bun run test` in `wms-be` — expected: all pass.
- `bun run db:migrate` + `bun run db:verify` on a fresh database, then `bun run db:generate` — expected: "No schema changes".
- `bun run api:generate && bun run lint && bun run typecheck && bun run test && bun run build && bun run check:capability-mirror` in `wms-fe` — expected: all pass.
- `bun run test && bun run typecheck` in `wms-mobile` — expected: all pass.
