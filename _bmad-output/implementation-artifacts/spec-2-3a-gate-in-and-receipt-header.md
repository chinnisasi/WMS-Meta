---
title: '2-3a gate-in and receipt header — the inbound vehicle visit, recorded at the gate and the dock'
type: 'feature'
created: '2026-10-21'
status: 'ready-for-dev'
baseline_commit: '89f85b66bf067e2ea0fdac931d0b9e6d12e39204'  # wms-be; wms-fe: b1c852dd11d8148a66481c0e01209082fbcfefdd; wms-mobile: 03ded78f5481ffd1583e06a5df74eb3f6c3a8cc9
route: 'dispatch'
review_loop_iteration: 0
context:
  - 'docs/initiatives/production-readiness.md'
  - 'docs/design/SYSTEM-DESIGN.md'
  - 'docs/design/IMPLEMENTATION-GUIDE.md'
  - 'docs/design/modules/inbound.md'
  - 'docs/design/modules/partners.md'
  - 'docs/design/modules/tenancy.md'
  - 'docs/design/frontend/SYSTEM-DESIGN.md'
  - 'docs/design/frontend/IMPLEMENTATION-GUIDE.md'
  - 'docs/design/mobile/SYSTEM-DESIGN.md'
  - 'docs/design/mobile/IMPLEMENTATION-GUIDE.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** Nothing records an inbound vehicle. The WMS cannot say:
- which truck delivered a receipt, under which LR and driver;
- against which supplier invoice, challan or bill of entry, and which inward e-way bill;
- whether the seal was intact;
- whether the packages counted matched those declared;
- how long the vehicle waited, unloaded and stayed.

A GRN is one receipt against one PO, one ASN or a blind reason, and nothing groups the receipts that came off one truck.

**Approach:** A **gate-in** is a new visit record, one per arrival.
- **At the gate (web):** the gate desk records the gate-in.
- **At the dock (handheld, offline-queued):** the dock records the unload start and end with the packages counted. The web can record them too.
- **Receipts** optionally link to it.
- **At departure:** the gate records the gate-out, which closes the visit.

Dock appointments are 2-3b.

## Boundaries & Constraints

**Decisions (2026-10-21, the user):**
1. **A gate-in is its own visit record.** GRNs link to it.
2. **The gate desk (web)** creates the gate-in and gates it out. **The dock handheld** records the unload start and end with the count, and links its receipts. The web may also record the unload.
3. **Several supplier documents per gate-in.** Each has:
   - a kind (`invoice | challan | bill_of_entry`);
   - a number;
   - a date;
   - an optional 12-digit inward e-way bill;
   - optionally the PO or ASN it covers.
4. **Transporter:** an active `transporter` partner, **or** a typed name. Exactly one of the two.
5. **The receipt link is optional.** A receipt without one books as today.
6. **The dock door is a typed code** (≤ 20). The dock-door master is 2-3b.
7. **Lifecycle:** `gated_in` → `unloading` → `unloaded` → `gated_out`. Gate-out closes the visit.
8. **Mismatches are flagged only.** A broken seal, or packages counted ≠ declared, is shown, never blocked.
9. **Inbound still opens on Purchase orders.** Gate-in is listed first, reached via `?tab=gate-ins`.
10. **Driver phone (DPDP):**
    - The list shows it masked (`98•••••345`).
    - The full number appears only in the detail, for `gate.manage` holders. The read DTO masks it for anyone else.
    - It is never copied into outbox events or audit snapshots.
11. **Packages declared is optional.** Blank means not declared, and no flag is shown.
12. **Container number:** optional, at most 11 characters, uppercase letters and digits. There is one seal field, and several seals are typed comma-separated. Returnable empties go to PENDING.
13. **No vehicle (hand delivery):**
    - A `handDelivery` flag makes the vehicle number optional. It is otherwise required.
    - Plates are normalised: uppercased, with spaces, dots and hyphens stripped, then matched against `^[A-Z0-9]{4,15}$`. BH-series and temporary registrations are accepted.
14. **`gatedInAt` is editable** through Edit while the status is `gated_in`. It must not be in the future, and the change is audited. The unload and gate-out times stay as recorded.
15. **The device offers only gate-ins** that are not `gated_out` and gated in within the last 7 days, at most 200, newest first. The web flags an open gate-in older than 7 days.

**Always — backend:**
- **Migration `0086_gate_ins.sql`:**
  - **`gate_ins`:**
    - Identity: `id`, `tenant_id`, `warehouse_id`, and `code` (`GI-nnnn`, unique per tenant, under advisory key `':gate-in-seq'`, regex `^GI-([0-9]{1,9})$`, copying `allocateGrnCode`).
    - Status: `status`, with a CHECK.
    - Vehicle: `hand_delivery` (bool), `vehicle_no?` (CHECK `hand_delivery OR vehicle_no IS NOT NULL`, plus the regex CHECK) and `container_no?` (`^[A-Z0-9]{1,11}$`).
    - Transporter:
      - `transporter_partner_id?`, `transporter_snapshot jsonb?` (frozen by `vendorSnapshotOf`'s pattern) and `transporter_name?` (≤ 80).
      - CHECK `num_nonnulls(transporter_partner_id, transporter_name) = 1` AND `(transporter_partner_id IS NULL) = (transporter_snapshot IS NULL)`.
    - Paperwork and driver: `lr_number?` (≤ 30), `driver_name?` (≤ 80), `driver_phone?` (`^\+?[0-9]{7,15}$`, stored normalised).
    - Seal: `seal_status` (`intact | broken | none`) and `seal_number?` (≤ 120, required unless `none`, null when `none`).
    - Packages: `packages_declared?` and `packages_counted?`, each an int from 0 to 1,000,000.
    - Dock: `dock_door?`.
    - Times and actors: `gated_in_at`, `unload_started_at?`, `unload_ended_at?`, `gated_out_at?`, `recorded_by`, and `unload_started_by?`, `unload_ended_by?`, `gated_out_by?`.
    - Status CHECKs: `unloading ⇒ unload_started_at IS NOT NULL`; `unloaded ⇒` the start, the end and the count are all not null; `gated_out ⇒` `gated_out_at` and `gated_out_by` are not null.
    - Deliberately **no** time-ordering CHECK, because device times are taken as sent.
  - **`gate_in_documents`:**
    - `id`, `tenant_id`, `gate_in_id` and `position`, unique on `(tenant_id, gate_in_id, position)`;
    - `kind` (CHECK), `number` (≤ 40), `document_date date` and `eway_bill_no?` (12 digits);
    - `po_id?` and `asn_id?`, with `num_nonnulls(po_id, asn_id) <= 1`.
    - A duplicate `(kind, number)` within one gate-in is refused (400).
  - **`goods_receipt_notes.gate_in_id`** uuid, nullable, with an index on `(tenant_id, gate_in_id)`.
  - Indexes: the unique code, and `(tenant_id, warehouse_id, status, gated_in_at DESC)`.
  - RLS, no FKs, nullable `IN` written `IS NOT NULL AND …`. Each CHECK is probed with a refused and an accepted insert (guide §3).
- **Primitives (in `shared/primitives`):**
  - `normalizeVehicleNo` and `VEHICLE_NO_RE` (lifted from `invoicing/eway-json.ts:51`, behaviour there unchanged);
  - `EWB_NO_RE` (lifted from `invoicing/eway.command.ts:78`);
  - `normalizePhone`.
- **Commands** (new `inbound/gate-in.command.ts`, `GateInCommand`). Each follows the guide §1 skeleton.
  - **Hashing:** times are hashed **as received** (absent stays absent) and defaulted to now only after the replay lookup.
  - **Future bound:** every web-supplied time is refused more than 5 minutes ahead (400 `time-in-future`).
  - **Create** (`POST …/receiving/gate-ins`, web):
    1. `gate.manage`.
    2. Replay.
    3. Shape (normalise, regexes, seal rules, the duplicate-document check).
    4. Warehouse.
    5. `assertTransporterInTx`, a new partners-facade function (`FOR KEY SHARE`; 404 / 409 `partner-not-transporter` / `transporter-inactive`) that returns the snapshot.
    6. Each document's PO or ASN must exist in this warehouse, in any status and of any client (plain read; 404 / 409 `document-warehouse-mismatch`).
    7. Insert, outbox, audit, key.
  - **Amend** (`PATCH …/gate-ins/:id`, web): a **full replacement** of the header (a blank optional becomes null) and of the document set.
    - Guard order: lock `FOR UPDATE` → replay again → not `gated_out` (409 `gate-in-closed`).
    - `gatedInAt` is accepted only while the status is `gated_in` (else 409 `gate-in-time-locked`).
    - The transporter is re-asserted and re-frozen only when it changes.
    - Two desks editing at once is last write wins (stated).
  - **Unload** (`POST …/gate-ins/:id/unload`, `{phase, occurredAt, packagesCounted?}`): one command behind two controller entries.
    - Authority:
      - **Device:** `DeviceSessionGuard`, then `assertDeviceOperatorInTx` before the replay, then `gate.manage`. Modelled on `excursion.command.ts:197-214`.
      - **Web:** `gate.manage`.
    - Hash: `{surface: 'web' | 'device', actor, deviceId?, gateInId, phase, occurredAt, packagesCounted?}`.
    - **Column-level first-writer-wins:**
      - **`start`** fills `unload_started_at` / `_by` when null.
      - **`end`** fills `unload_ended_at` / `_by` and `packages_counted` when null. An end with no start also stamps the start with the same time and actor, and audits only `unload_ended`.
      - **In any status, `gated_out` included.** The status moves only forward (`gated_in` → `unloading` → `unloaded`), never out of `gated_out`.
    - When nothing is filled: 200 `applied: false` with the current gate-in. The key and snapshot are stored, there is no audit and no outbox, and the arm is listed in `AUDIT_NO_OP_ARMS`. A replay re-serves the stored body.
    - Web times must not precede `gated_in_at` or the start (400 `time-out-of-order`). Device times are not checked, and the web clamps a negative dwell to 0.
    - The route never answers `gate-in-closed`.
  - **Gate-out** (`POST …/gate-ins/:id/gate-out`, `{gatedOutAt?}`, web):
    - Allowed from any state other than `gated_out` (else 409 `gate-in-closed`).
    - The time must not precede `gated_in_at`.
    - It locks the row, as amend and unload do.
  - **Lock order:** the device row, then the gate-in `FOR UPDATE`. Create's and amend's document checks are plain reads.
- **Reads** (tenant session, any staff role):
  - `GET …/receiving/gate-ins` (warehouse, `status` taking several values, keyset on `gated_in_at`). The filters run on the user-entered `gated_in_at`, as decision 14 allows.
    - Each entry carries the header and `transporterLabel` (`snapshot.name ?? transporter_name`).
    - `documentCount`.
    - `receiptCount`: GRNs with `gate_in_id` set to this visit, any client, including receipts linked after the gate-out.
    - `packagesFlag` (`short | excess | matches | null`, with the difference).
    - `staleOpen`: not gated out and gated in more than 7 days ago.
    - `driverPhone` masked.
  - `GET …/gate-ins/:id` adds the documents (with `poCode` / `asnCode`) and the receipts `{id, code, clientId, document}`. The full phone goes only to a `gate.manage` holder.
- **Audit:**
  - Target type `gate_in`, added to `AUDIT_TARGET_TYPES` and the FE `AUDIT_TARGET_LABEL`.
  - Actions `gate_in.recorded | amended | unload_started | unload_ended | gated_out`, added to `AUDIT_NEW_ACTIONS` and each pinned.
  - **Outbox:** `gate_in.recorded | amended | unloaded | gated_out` with the gate-in, **without `driver_phone`**.
- **Capability `gate.manage`:** owner, ops_manager and operator. The capability count goes from 45 to 46 in both BE and FE pins.
- **The GRN link:**
  - `SubmitGoodsReceiptDto.gateInId?` (uuid).
  - Hash `gateInId: command.gateInId ?? undefined` right after `clientId`. The existing goldens stay byte-identical, and a new golden is added.
  - Normalised `?? null`.
  - **Resolution:** a plain read before the PO/ASN lock. It never refuses: an id that is unknown, not a uuid, or in another warehouse books the receipt unlinked with `gateInLink: {status: 'not-linked', reason: 'unknown' | 'other-warehouse'}`, a closed vocabulary. A `gated_out` gate-in links.
  - The snapshot and `GoodsReceiptResponse` gain `gateInId?`, `gateInCode?` and `gateInLink?`. The all-refused arm carries `gateInLink` only.
  - **Review re-runs:** `gateInId` (present only when set) rides the `grn.submit`, `grn.shelf-life-refused` and `grn.licence-refused` row payloads, their `PAYLOAD_FIELDS` entries (`'uuid-or-null'`) and their apply arms, so an accepted re-run links too.
  - The GRN list entry gains `gateInId?`, `gateInCode?` and `vehicleNo?`.
- **The review vocabulary for the new op `gate-in.unload`:**
  - `RejectedOpType` and `REJECTED_OP_TYPES`;
  - `REJECTED_OP_DECISIONS_BY_TYPE` set to `['discard']`;
  - a `PAYLOAD_FIELDS` entry;
  - excluded from `ApplicableOpType`;
  - the `@IsIn` enum, so the FE union regenerates;
  - FE `lib/review-queue.ts` summary and guidance.

  `client-wind-down.ts` is untouched, because its list holds only SKU-bearing types.
- **Catalog snapshot:** `openGateIns[]`, per decision 15, as `{id, code, vehicleNo, handDelivery, transporterLabel, dockDoor, status, sealStatus, packagesDeclared, unloadStartedAt, documents[{kind, number}]}`. It is an `…InTx` passthrough on the caller's tx (gotcha 2).

**Always — handheld:**
- **Op `gate-in.unload`:** the guide §1 edits plus:
  - `fetchApi…` passes `opOperator`;
  - `occurredAt` and `id: ulid()` are minted at the press;
  - the mobile `SyncReportRowPayload.opType` gains it, with an uploader test.
- **Fates, one test each:**

  | Server answer | Fate | Device shows |
  |---|---|---|
  | 200 `applied: true` | `settled` | — |
  | 200 `applied: false` | `settled` | "GI-x unload {phase} already recorded" — and for an end, "your count of N was not recorded" |
  | 401 | `unreachable` | kept |
  | 403 `device-revoked` | `revoked` | with the tail |
  | 409 `operator-mismatch` | `quarantined` | — |
  | Any other 4xx (404, 400, 403 `role-denied`) | `rejected` | review row, Discard only |

  `GateInUnloadResponse` mirrors `{applied, gateIn}` field for field.
- **Entry points:**
  - Gate-in cards go in the inbox **Receive** tab and the `All` arm. A gate-in is not a task type, so there is no new tab.
  - They deep-link to `app/gate-in.tsx?gateInId=`. That screen shows the header and documents, Start unload, End unload (with a packages-counted entry), and **Receive against this gate-in**.
  - The latter does `router.replace({pathname:'/receive', params:{gateInId}})`. `initialDraftFromRoute` accepts it only when the id is in `snapshot.openGateIns`, and composes it with `poId` / `asnId`.
- **Draft:**
  - `ReceiveDraft.gateInId: string | null`, `null` in `createDraft`.
  - It survives `choosePo`, `chooseAsn`, `chooseBlindReceive` and "Back to documents", and is cleared only by an explicit Clear.
  - `draftContextSet` ignores it.
  - The receive header shows "Against GI-x · vehicle", with Clear.
  - `confirmPayload` spreads it only when set. A test asserts `!('gateInId' in payload)` for the PO, ASN and blind shapes, plus one linked pin per shape.
  - **An older server:** the device sends `gateInId` only when it came from `openGateIns`, which an older server never serves. The deploy order is backend first.
- **Pending phases:**
  - Derived purely in `src/receiving/gate-in.ts`, as `queuedGateInPhases(ops)` over the durable outbox (the `queuedReturnWork` precedent).
  - A settled op stales the snapshot. `settledOpStalesOpenGateIns` is added to the device-store refresh (`device-store.ts:544`).
  - **The blocker:** Start is refused while a start or end is queued, or once the snapshot is past `gated_in`. End is refused while an end is queued.
  - **The count:** a dedicated `parsePackagesCounted` (`^[0-9]+$`, 0 to 1,000,000), with End blocked until it parses.
- **Settled note:** `goodsReceiptNote`'s early return also checks `gateInLink`. The note reads "{GRN} booked — not linked to the gate-in: {words for unknown | other-warehouse}", naming the code only when the response carries it.

**Always — web:**
- **The Gate-in tab:**
  - It is first in `INBOUND_TABS`. The default stays `pos` (decision 9), and the existing pins are unchanged.
  - Writes are gated on `gate.manage`. An accountant sees no Record button and no row actions (tested).
  - It reuses `AllClientsNote` (`inbound-cards.tsx:534`): "Gate-ins show every client — a truck can carry several."
- **The list:**
  - Columns: code, vehicle (or "Hand delivery") with the container, transporter, status, gated-in time (IST via `istDateTimeLabel`), dock, packages as "N short" / "N excess" / "Matches" in words, a "Seal broken" badge, receipts, the masked phone, and a "Open > 7 days" flag.
  - An expanded row fetches `GET :id` on expand, with its own loading and failed states, to show the documents and the receipts with their client.
  - A Refresh button: device unloads appear on reload, which is stated.
- **The tab count:** gate-ins not gated out, from one multi-status read. It takes no `clientId` and renders even while the client filter is pending. It is excluded from `CountedInboundTab`'s client assumptions (`inbound-tabs.ts:60`). Every mutation fires `notifyInboundChanged()`.
- **The Record / Edit form**, modelled on `po-create-form.tsx`:
  - mounted with `key={warehouseId}`;
  - one idempotency key per draft, cleared on edit, plus an in-flight ref;
  - `noValidate`, and one form-level problem naming the field or row.
  - **Transporter:** active `transporter` partners read with `fetchAllPages`.
    - It has loading, failed (Retry) and empty states. The empty one says "No transporters in the master — type the name".
    - A "Not listed — type the name" switch.
    - It re-reads on `PARTNERS_CHANGED_EVENT` and after a `transporter-*` / `partner-not-transporter` refusal.
  - **Document rows:** 0 to 20, with Add disabled at 20.
    - Each row has a kind, a number, a date (`YYYY-MM-DD` as typed, validated with `isRealDate`, refused when after today in IST) and an EWB (spaces stripped, 12 digits).
    - The PO/ASN link is one select over the warehouse's open POs and announced or partially received ASNs, across all clients. Each option is labelled "PO-1001 · vendor · client".
    - A saved link that is not among the options still renders from the detail and is kept.
  - **Times:** `datetime-local` read as IST through `istLocalToIso`, prefilled by new `istLocalNow()` / `isoToIstLocal()` in `lib/gate-ins.ts`. These are tested in a non-IST browser between 00:00 and 05:30 IST.
- **Row actions** (Start unload, End unload with the count, Gate out):
  - Each is a per-confirmation `ConfirmRow`, mounted keyed `action|gateInId` per warehouse.
  - The time (default now, IST) and the count are frozen in the confirmation. The key is cleared on any edit, with the synchronous ref guard (FE guide §2.1).
  - Gate out confirms: "Closes GI-x; no further edits."
  - Actions follow the state:
    - Start only on `gated_in`;
    - End on `gated_in` or `unloading`;
    - Edit and Gate out on anything not `gated_out`.
  - `applied: false` says "Already recorded at {time} IST", never a success.
- **Errors:** `gateInReason` maps every code above, with house copy for the shared arms. Vehicle copy reads "4–15 letters and digits; spaces, dots and hyphens are ignored".
- **`GoodsReceiptsCard`** gains a Gate-in column, `GI-x · vehicle`.

**Never:**
- No dock appointments and no dock-door master (2-3b).
- No GRN document or print, and no portal (2.9).
- No damage or short handling and no photos (2.4 / 2.5).
- No yard or vehicle master.
- No government e-way bill verification.
- No gate-in create, amend or gate-out on the handheld.
- No required link: nothing is refused for a missing or bad one.
- No change to an existing receipt hash.
- No structured multiple seals and no returnable empties (PENDING).

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected | Error handling |
|---|---|---|---|
| Gate-in | `ka-01.ab 1234`, TR-VRL, seal intact `S-991, C-12`, container `MSKU1234567`, 12 declared, an invoice (EWB `1234 5678 9012`, PO-1001 of GlowCo) and a bill of entry, dock `D3` | 201 `GI-0001`, `gated_in`, vehicle `KA01AB1234`, EWB `123456789012` | — |
| BH and temporary plates | `22 BH 1234 AA`, `T0822KA1234Z` | Accepted | — |
| Hand delivery | `handDelivery: true`, no vehicle | 201; the list shows "Hand delivery" | — |
| Typed / both / neither transporter | Name only; both; neither | 201; 400; 400 | Named |
| Not a transporter | A vendor-only partner | 409 `partner-not-transporter` | Mapped copy |
| Bad fields | EWB of 11 digits, phone `abc`, seal intact without a number, a duplicate invoice number, a document dated tomorrow | 400 naming each | — |
| Another warehouse's PO | A WH2 PO on a WH1 gate-in | 409 `document-warehouse-mismatch` | — |
| Same-key retry with no time | Create retried, no `gatedInAt` | Replays (no 422) | — |
| Offline unload end | Queued end, 10 counted, 12 declared | `unloaded`; the web shows "2 short" | — |
| Late duplicate | The web recorded the end; the device's start replays | 200 `applied: false`, settled with a note | — |
| Gated out before the dock syncs | Gate-out, then the device's queued end | The count and end are filled, the status stays `gated_out`, `applied: true` | — |
| Unknown gate-in on unload | Device op | 404 → review row, Discard | — |
| Receipt linked | GRN with `gateInId` | Stored; the list shows `GI-0001 · KA01AB1234` | — |
| Bad link | Unknown, non-uuid or another warehouse's | 201 unlinked, `gateInLink.not-linked`; the device note | — |
| Short-dated re-run | A `grn.shelf-life-refused` row Applied | The re-run receipt links to the same gate-in | — |
| Old build | No `gateInId` | Goldens byte-identical | — |
| Amend | Edit the time while `unloading` | 409 `gate-in-time-locked`; other fields amend | — |
| Gate-out twice / amend after | — | 409 `gate-in-closed` | Mapped copy |
| Phone privacy | Accountant reads the list and the detail | Masked in both; absent from outbox payloads | — |
| Undeclared | No packages declared, 10 counted | No flag | — |
| Device list bound | A gate-in that gated in 8 days ago and is still open | Not on the device; the web flags "Open > 7 days" | — |

</frozen-after-approval>

## Code Map

**wms-be**
- `drizzle/0086_gate_ins.sql` + journal + snapshot; `src/shared/db/schema.ts` (the GRN table `:2359-2420`).
- `src/shared/primitives/`: the vehicle, EWB and phone primitives. Re-export them from `invoicing/eway-json.ts:51` and `invoicing/eway.command.ts:78`.
- New `src/modules/inbound/gate-in.command.ts`, `gate-in.dto.ts` and `gate-in.read.ts`.
  - Code allocation: copy `allocateGrnCode` (`receiving.command.ts:516,2922-2932`).
  - Authority: model it on `excursion.command.ts:197-214`.
- `src/modules/partners/partners.facade.ts`: `assertTransporterInTx`, modelled on `:208`, with the snapshot built as `vendorSnapshotOf` (`:271`).
- New `src/api/gate-in.controller.ts`: the web entries, plus a device unload entry under `DeviceSessionGuard`, as `receiving.controller.ts:81` uses.
- `src/modules/tenancy/permissions.ts`: `gate.manage`.
- `src/shared/audit/audit.ts:44`: the target type and the new actions.
- `src/modules/inbound/receiving.command.ts`:
  - the command type (`:126-178`);
  - the hash after `clientId` (`:614`);
  - normalisation (`:665-676`);
  - the link read before the PO/ASN lock (`~:765`, `:1078`);
  - the header insert (`:1224-1242`);
  - the snapshot (`:360-425`);
  - the shelf-life and licence row payloads (`:2824-2845,2881-2900`);
  - the all-refused arm (`:999-1050`).
- `receiving.dto.ts:147-215,503`; `receiving.facade.ts`: the list join and `openGateIns` (beside `:163,618`).
- `src/modules/tenancy/sync-report.command.ts`:
  - the type and decisions (`:83-193`);
  - `PAYLOAD_FIELDS` (`:310-385`);
  - the apply arms (`:1417-1490`).
- `src/api/rejected-ops.dto.ts:37`.
- Tests:
  - new `test/gate-ins.spec.ts`, one case per backend matrix row;
  - CHECK probes;
  - the goldens in `test/per-client-sku.spec.ts:533-560` (unchanged, plus a new one);
  - the re-run link in the client-receiving-policy and licence-enforcement specs;
  - `test/support/audit-guard.ts:61` `AUDIT_NO_OP_ARMS`;
  - `test/users.spec.ts:901` (46);
  - `test/return-receipts.spec.ts:908`;
  - `architecture.spec.ts`.

**wms-mobile**
- `src/offline/types.ts:40`.
- `src/api.ts`:
  - the payload, response and `fetchApi…`;
  - `GoodsReceiptPayload` (`:358`) and `GoodsReceiptResponse` (`:476`);
  - `SyncReportRowPayload` (`:268-280`);
  - `CatalogSnapshot` (`:1580`).
- `src/state/op-dispatch.ts:134,219`; `replay-classification.ts:555`; `catalog-snapshot.ts:56`; `device-store.ts:544`; `sync-report-uploader.ts:149`.
- New `src/receiving/gate-in.ts`.
- `src/receiving/draft.ts`: `:138,156,165,215-258,301,1615`.
- `app/receive.tsx`: `:139,173-188,1081` and the header.
- `app/inbox.tsx`: the Receive tab and the `All` arm (`:96-104,331,471,492`).
- New `app/gate-in.tsx`, registered in `app/_layout.tsx`.
- Tests:
  - `gate-in.test.ts`, `draft.test.ts`, `op-dispatch.test.ts`, `replay-classification.test.ts`;
  - `device-store.test.ts` (legacy seal);
  - `engine.test.ts` FIFO;
  - the uploader.

**wms-fe**
- `src/lib/inbound-tabs.ts:11-27,60`; `use-inbound-tab-counts.ts:49,76-83`.
- `inbound-cards.tsx:183-216,446-536,534`.
- New `components/inbound/gate-ins-card.tsx` and `gate-in-form.tsx`.
- New `lib/gate-ins.ts`, with tests.
- `lib/api/client.ts` (wrappers); `lib/audit.ts` (`AUDIT_TARGET_LABEL`); `lib/review-queue.ts`.
- `lib/users.ts` and `users.test.ts:60`: the owner pin goes to 46, plus the ops_manager and operator pins.

**meta (last):**
- module docs: `inbound.md` (a Gate-in section with flow, commands and gotchas), `partners.md` (close PENDING `:143`) and `tenancy.md`;
- `API-SURFACE.md`;
- the frontend and mobile SYSTEM-DESIGN and IMPLEMENTATION-GUIDE;
- the three interface contracts;
- PENDING: returnable empties, structured seals, the GRN card's browser-local time, and the stale-open gate-ins.

## Tasks & Acceptance

**Execution:**
- [ ] `wms-be`: the migration, the primitives, `GateInCommand` with its four commands and two reads, the partners transporter assert, the controller, the capability and audit vocabulary, the GRN link with its re-run carriage, the review vocabulary, `openGateIns`, and the OpenAPI export.
- [ ] `wms-be` tests: every backend matrix row, the CHECK probes, the goldens, the audit and no-op pins, and the capability count.
- [ ] `wms-mobile`: the op end to end, the fate table, the inbox cards and the gate-in screen, the draft link, the pending phases, the settled notes and the snapshot default, with tests per the Code Map.
- [ ] `wms-fe`: regenerate the client, then the Gate-in tab (list, expanded row, count, form, actions), the GRN column, the review-queue copy, the audit label and the capability mirror, with tests per web matrix row.
- [ ] Meta docs, last.

**Acceptance Criteria:**
- Given a truck at the Bengaluru DC gate, when:
  1. the gate desk records `GI-0001`;
  2. the dock handheld (offline) starts the unload, receives PO-1001 and PO-1002 against it, and ends the unload with 10 of 12 packages;
  3. the handheld syncs;

  then the web shows `GI-0001` `unloaded`, "2 short", with 2 receipts, and both GRNs show `GI-0001 · KA01AB1234`.
- Given an app build without this story, when it submits a receipt, then the server accepts it exactly as before.

## Design Notes

**Why the link never refuses.** A queued receipt's 4xx is `rejected`: it is dropped and sent to review (mobile guide §3). A physically real receipt must not be lost over a wrong visit id.

**Why first-writer-wins by column.** The web and the device can both record the unload, and a device can replay a shift later, even after the gate-out. A state 409 would send something that has already happened to review. Filling empty columns keeps the first truth and loses no count.

**Lock order.** The device row, then the gate-in. The GRN reads the gate-in unlocked before its PO/ASN lock, so no cycle is possible.

## Verification

**Commands:**
- `cd wms-be && bun run test -- test/gate-ins.spec.ts`, then the golden and re-run specs, one at a time. Then `bun run test`, `bun run lint`, `bun run typecheck`, `bun run db:generate` ("No schema changes"), and `bun run openapi:export`.
- `cd wms-mobile && bun test && bun run typecheck`.
- `cd wms-fe && bun run api:generate && bun test && bun run typecheck && bun run lint && bun run check:capability-mirror && bun run build`. The drift guard fails until the BE PR merges.

**Manual checks:**
- On localhost:3001: record a gate-in, link a device receipt, record the unload and the gate-out, and check the flags, the masking and the GRN column.

## Implementation Notes

## Spec Change Log

## Review Triage Log

**Design review, 2026-10-21.** Three reviewers: backend (B1–B15), handheld (M1–M12), and web with edge cases (W1–W21). That is 48 findings. Seven intent gaps were put to the user and became decisions 9–15 (W9, W12, W13, W14, W15, W16, B15). Every other finding has a fix grounded in existing code. Re-checked by hand:
- `FLOOR_ROLES` (`permissions.ts:423`);
- `AUDIT_NO_OP_ARMS` (`audit-guard.ts:61`);
- that the hash is a plain `JSON.stringify`, so an `undefined` key leaves the goldens intact.

The findings:
- D1 high (B1): the shelf-life and licence re-runs dropped the link. Fix: `gateInId` rides those rows, their fields and their apply arms; matrix row.
- D2 high (B2, M5): a gate-out, or a web end, before the device synced discarded the count. Fix: first-writer-wins by column in any status; an `applied: false` note on the device.
- D3 high (B3): there was no column for the frozen name, and the CHECK collided. Fix: `transporter_snapshot jsonb` with paired CHECKs.
- D4 high (M1, M2): "Receive against this gate-in" could not reach the draft, and the inbox deep links skip the choose step. Fix: a route param through `initialDraftFromRoute`; inbox cards; the receive header.
- D5 high (M4): the not-linked note never rendered on a clean receipt. Fix: the early-return guard; a closed reason vocabulary; response fields.
- D6 high (W1): the list DTO was undefined. Fix: the entry fields and `receiptCount` semantics; the expanded row fetches the detail.
- D7 high (W2): a document date sent as an IST instant would store D-1. Fix: `YYYY-MM-DD` as typed; future dates refused.
- D8 high (W3, B4): defaulted times broke retries. Fix: hash as received and default after the replay; per-confirmation keys with frozen times.
- D9 high (W4): PATCH could not clear an optional. Fix: full-replacement semantics; re-freeze on a transporter change; last write wins stated.
- D10 high (W5): codes were missing. Fix: `time-in-future`, `time-out-of-order`, `gate-in-time-locked`; the `applied: false` web copy.
- D11 med (B5, M9, W21): the fingerprint and authority for the two unload surfaces. Fix: `surface`, actor and device in the hash; the excursion authority pattern.
- D12 med (B6): the audit rules for the no-op arm. Fix: the key stored, no audit, `AUDIT_NO_OP_ARMS`.
- D13 med (B7, W18): the audit target, the actions and the capability pins. Fix: named.
- D14 med (B8, M7): the review vocabulary for the new op was incomplete. Fix: every table named; the mobile union and uploader test.
- D15 med (B9): lock order. Fix: stated.
- D16 med (B10): a bad stored id could 500. Fix: `?? null`, a uuid test, `'uuid-or-null'`.
- D17 med (B11): indexes and CHECKs were missing. Fix: listed and probed.
- D18 med (M3): the link's lifetime in the draft was undecided. Fix: null by default, survives "Back", cleared explicitly, ignored by the step machine.
- D19 med (M6): the pending phase had no home. Fix: derived from the outbox, plus a stale-snapshot refresh.
- D20 med (M8): no fate table. Fix: the table, one test per arm.
- D21 med (W6): the edit picker dropped a closed document link. Fix: open docs offered, a saved link kept.
- D22 med (W7): transporter picker states. Fix: three states and the re-reads.
- D23 med (W8): the tab count was multi-status and client-keyed. Fix: one multi-status read, no client, Refresh.
- D24 med (W10): no IST helpers for prefill. Fix: `istLocalNow` / `isoToIstLocal` with a non-IST test.
- D25 med (W11): warehouse switch. Fix: form and actions keyed by warehouse.
- D26 med (W12): plate normalisation. Fix: dots and hyphens stripped; BH and temporary plates pinned; hand delivery (decision 13).
- D27 med (W13): driver phone privacy. Fix: decision 10.
- D28 med (W14): the declared count was required. Fix: decision 11.
- D29 med (W15): paperwork realism. Fix: decision 12; duplicate-document refusal; EWB spaces stripped.
- D30 med (W16): the time could not be corrected. Fix: decision 14; filters on `gated_in_at` stated.
- D31 low (B12): time rules. Fix: the future bound on every web time; ordering stated; dwell clamped.
- D32 low (B13): an end without a start. Fix: stated.
- D33 low (B14): an amend stuck on an inactive partner. Fix: re-assert only on change; documents of any status or client.
- D34 low (B15): the device list was unbounded. Fix: decision 15; `staleOpen`.
- D35 low (M10): count parsing. Fix: a dedicated parser with a ceiling.
- D36 low (M11): key-absence pins. Fix: `!('gateInId' in payload)`.
- D37 low (M12): older server and time capture. Fix: stated.
- D38 low (W17, W19, W20): action gating, the client note, document-row UX. Fix: stated and tested.
- D39 info (W9): the default tab. Fix: decision 9.
