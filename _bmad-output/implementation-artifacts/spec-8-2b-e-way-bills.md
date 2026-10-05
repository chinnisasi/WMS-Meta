---
title: 'E-way bills — queue, NIC bulk JSON, recorded numbers, behind the EwayGateway port'
type: 'feature'
created: '2026-10-04'
status: 'done'
route: 'dispatch'
baseline_commit: 'e4a66066ea6b7d96c2bfadd4c966fc720ae42aa8'
review_loop_iteration: 0
context:
  - '_bmad-output/implementation-artifacts/epic-8-context.md'
  - 'docs/design/SYSTEM-DESIGN.md'
  - 'docs/design/IMPLEMENTATION-GUIDE.md'
  - 'docs/design/modules/invoicing.md'
  - 'docs/design/modules/carriers.md'
  - 'docs/design/frontend/SYSTEM-DESIGN.md'
  - 'docs/design/frontend/IMPLEMENTATION-GUIDE.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** Consignments worth more than the e-way threshold need an e-way bill (EWB) before they move. Today nothing tells finance which issued invoices need one, and every invoice has to be re-keyed into the NIC portal.

**Approach:** When an invoice issues, versioned thresholds decide whether it needs an EWB. If it does, an `eway_bills` row is queued. On `/compliance` an owner, ops manager or accountant:
- adds transport details (Part B);
- downloads one NIC bulk-upload JSON per supplier GSTIN for any set of ready bills;
- uploads that file on the portal;
- records each returned EWB number.

The `EwayGateway` port ships now. It has a sandbox adapter for dev and test and an "unconfigured" adapter for production, so a live GSP or NIC adapter can plug in later without changing the core.

**Decisions (human, 2026-10-04):**
1. **OQ3 — port now, transport later.** No live adapter and no credentials. Production is unconfigured: the system never calls out, and bills go through the manual export.
2. **Part B is entered at e-way time** on a per-bill form. Dispatch is unchanged.
3. **Thresholds.** Only the verified ₹50,000 national rule (CGST Rule 138(1)) is seeded. Owners add versioned **intra-state** overrides per state, each with an amount (or "none required") and an effective-from date.
4. **Generation means export, then record.** Finance ticks bills, downloads the bulk JSON, uploads it, and enters each EWB number and date back. A recorded number is final.
5. **E-invoicing.** A per-GSTIN "e-invoicing applies" flag holds that GSTIN's B2B bills as `needs-irn`, a computed blocker. They are never exported, because NIC blocks them without an IRN (since 1 Mar 2024). B2C bills still export.
6. **Who acts.** `eway.manage` (Part B, export, record, dismiss, generate) goes to owner, ops_manager **and accountant**. This is the accountant's first write capability, a deliberate exception: e-way paperwork is finance work. `eway.configure` (thresholds and GSTIN flags) is owner-only.
7. **The gateway is on demand.** Queueing is automatic. Generating through the gateway is an explicit, audited "Generate" command on a ready bill, offered only when a gateway is configured.
8. **When bill-to and ship-to states differ, the bill is blocked.** This is the `pos-discrepancy` case. Finance generates it on the portal by hand and records the number. The system never exports `transType` 2–4.

## Boundaries & Constraints

**Always:**
- **Queueing.** Only on `invoice.issued`, and only for an invoice that is re-read as `issued` with an `issued_at`. Idempotent through `UNIQUE(invoice_id)`. It never blocks or rolls back dispatch or issuance.
- **Consignment value.** Σ (taxable + CGST + SGST + IGST) over lines with `gst_bps > 0`, in exact paise. A 0% line counts as exempt and is excluded (Rule 138 Explanation 2). The bill is needed when value > threshold.
- **Threshold.** The one in force on the invoice's IST issue date. An intra-state supply uses the bill-from state's (GSTIN prefix) newest override with `effective_from` on or before that date, falling back to national. An override with a null amount means none is required. An inter-state supply always uses national. The row stores the value, the threshold and the rule (`national` or `state:<code>`).
- **Append-only overrides.** Override rows are never updated or deleted by any command. A same-date correction is a new row; the newest `created_at` wins. Adding an override never re-evaluates bills already queued, nor invoices that were not queued.
- **One builder for the bill object.** One pure function builds it from the frozen invoice document, its lines and the bill's Part B. Both the export and the gateway use it.
- **Blockers** are computed at read time, never stored, and listed per bill. Export and generate enforce them; record and dismiss ignore them. Each is marked *terminal* (the invoice is frozen, so the bill must be generated on the portal) or *fixable*.

**Never:**
- live NIC or GSP calls, or credentials;
- e-invoicing or IRN;
- Part B update, extension or cancellation of a generated EWB;
- consolidated EWBs;
- `transType` other than 1;
- export, SEZ or other-territory EWBs;
- grouping items to get under 250;
- a backfill (but `invoice.issued` messages still in the outbox at deploy are consumed);
- capture at dispatch;
- floats in amounts.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected | Error |
|---|---|---|---|
| Over the national threshold | Inter-state, value ₹50,000.01 | `pending`, rule `national` | — |
| At the threshold | ₹50,000.00 | No row | — |
| Exempt lines | ₹40k at 0% + ₹20k at 5% | Value ₹21,000, no row | — |
| State override | Intra-state in 27, ₹1,00,000 from 2025-04-01, value ₹80k | No row | — |
| Override "none required" | Intra-state, null amount | No row | — |
| Override not yet effective | Issued the day before `effective_from` | National applies | — |
| Same-date correction | Two rows for one state and date | The newer `created_at` wins | — |
| Redelivery or bad payload | Replay; no `invoiceId`; invoice not issued | One row; acked, nothing written | — |
| B2B, e-invoicing on | The flag is on, consignee GSTIN set | Blocker `needs-irn` | Export 409 `eway-not-exportable` |
| No Part B and no transporter | — | Blocker `transport-incomplete` | Export 409 |
| Part A only | Transporter ID, no vehicle | Exported as `transMode` 1, `vehicleType` "R", `vehicleNo` "" | — |
| Bill-to ≠ ship-to | `pos-discrepancy` invoice | Blocker `ship-to-differs` (terminal) | Export 409 |
| Mixed GSTINs in one export | Bills from 27… and 29… | Whole request refused | 409, reason `mixed-gstin` |
| Record | 12-digit `ewbNo`, valid `generatedAt` | `generated`, source `manual` | Bad: 400; not pending or claimed: 409; number already used: 409 |
| Generate, sandbox | A ready bill | `generated`, source `gateway`, audited | Unconfigured: 501 `gateway-unconfigured`; refused: 422 `eway-gateway-refused` with `last_error` |

</frozen-after-approval>

## Code Map

- `wms-be/src/modules/invoicing/events.ts:12,24,46`: `invoice.issued` (`invoiceId`, `originGstin`, `invoiceNo`, …) is appended on first issuance. It has no consumer yet.
- `wms-be/src/modules/invoicing/delivery.ts:94-119`: the subscriber template. Malformed payloads and deterministic data faults are **acknowledged and logged**; only transient faults rethrow, because the bus stops at the first throw (`shared/events/event-bus.ts:54-57`) and 21-5 will subscribe here too. Payload fields beyond the id are not trusted. Event-driven writes are not audited (`command.ts:167-169`).
- `wms-be/src/modules/invoicing/generator.ts`:
  - `InvoiceDocument` (:100). Its `totals` hold only `subtotal`, `gst`, `total`, `roundOff` and `payable`; the per-tax split is summed from the lines.
  - `originAddress`/`consigneeAddress` are nullable (:110-111). `buyer.name` is nullable.
  - `GAP_KINDS` includes `pos-discrepancy` (:56-62).
  - `resolveStateCode` (:283) lets the GSTIN outrank the address text, so pass `gstin = null` to resolve **actual** states from the address.
  - `IST_OFFSET_MS`.
- `wms-be/src/modules/invoicing/uqc.ts` `uqcFor`: all 25 codes are in NIC's `qtyUnit` master. `hsn-summary.ts`: `isValidHsn`, `assertGstinParam`.
- `wms-be/src/modules/carriers/carrier-label-port.ts:75-88`: the unconfigured (typed 501) and sandbox arm precedent.
- `wms-be/src/modules/tenancy/permissions.ts:5-8,183-213,267`: reads are never gated; the accountant has nothing today. `wms-fe/src/lib/users.ts` mirrors it: ops_manager = all minus `OWNER_ONLY_CAPABILITIES`. The pins are in `users.test.ts:40,130,210`.
- `docs/design/IMPLEMENTATION-GUIDE.md` §3 (**no FK constraints**), §4 (hash inputs). `wms-be/drizzle/0053` holds `gst_state_codes` (incl. 97/99), the GSTIN CHECK `^[0-9]{2}[A-Za-z0-9]{13}$` and the RLS shape. The next migration is **0056**.
- `wms-be/src/shared/primitives/address.ts:28-35`: line1/line2 are up to 200 characters and city up to 100. NIC allows 120 and 50.
- `wms-fe`: `components/compliance/invoices.tsx` `GenerateForOrder` (:196) is the mutation template. `components/outbound/pack-dispatch.tsx:1099-1162` is the multi-select template. `lib/csv.ts` `downloadText(name, text, 'application/json')`.
- NIC sources (copies in the session scratchpad; refetch from docs.ewaybillgst.gov.in/Documents/bulkewb/): `EWB_Attributes_new.xlsx` (Schema, Validations, Master Codes sheets) and `EWB_Preparation_Tool_17062021.xlsm`.

## Tasks & Acceptance

**Execution:**
- [x] `wms-be/drizzle/0056_eway_bills.sql` (+ journal/snapshot, schema.ts) -- three RLS tables and one global table, **no FKs**:
  - **`eway_national_thresholds`** (global, read-only): `effective_from date PK`, `threshold_paise`, `source`. Seed `('2018-04-01', 5000000, 'CGST Rule 138(1)')`.
  - **`eway_state_thresholds`**: `id uuid PK`, `tenant_id`, `state_code` (CHECK `^[0-9]{2}$`), `threshold_paise` (nullable, ≥ 0), `effective_from`, `created_by`, `created_at`. A `BEFORE UPDATE` trigger raises (append-only; deletes are tenant teardown only). Index `(tenant_id, state_code, effective_from desc, created_at desc)`.
  - **`eway_gstin_settings`**: `id uuid PK`, `tenant_id`, `gstin` (house CHECK), `e_invoice_applies`, `updated_by`, `updated_at`, `UNIQUE(tenant_id, gstin)`.
  - **`eway_bills`**:
    - identity: `id uuid PK`, `tenant_id`, `invoice_id` (UNIQUE), `origin_gstin`;
    - `status` ∈ `pending | generated | dismissed`;
    - NOT NULL `consignment_value_paise > threshold_paise`, and `threshold_rule ~ '^(national|state:[0-9]{2})$'`;
    - Part B: `trans_mode` 1–4, `vehicle_no`, `vehicle_type` R/O, `transporter_id`, `transporter_name`, `trans_doc_no`, `trans_doc_date`, `distance_km` 0–4000;
    - result: `ewb_no` (`^[0-9]{12}$`), `ewb_generated_at`, `ewb_valid_until` (≥ generated), `source` (`manual | gateway`);
    - tracking: `gateway_claimed_at`, `last_exported_at`, `last_exported_by`, `dismissed_reason`, `last_error`, timestamps.

    Two-way CHECKs: `generated` ⇔ number, date and source are set; `dismissed` ⇔ a reason is set. A partial `UNIQUE(tenant_id, ewb_no) WHERE ewb_no IS NOT NULL`. Index `(tenant_id, status, created_at, id)`.
- [x] `wms-be/src/modules/invoicing/eway-threshold.ts` + test -- `consignmentValuePaise(lines)` and `thresholdFor(tx, tenant, {supplyType, billFromState, istDate})`.
- [x] `wms-be/src/modules/invoicing/eway-json.ts` + test -- pure functions: `NIC_BULK_VERSION = '1.0.0621'` (a schema version, not a regulatory value), `ewbBillObject`, `ewbBlockers` and `bulkFile`. The mapping table is below, and the golden test asserts every key **and** its `typeof`.
- [x] `wms-be/src/modules/invoicing/eway-gateway.ts` -- the port:
  - `EWAY_GATEWAY` token with `configuredFor(tenantId, gstin)` and `generate(tenantId, gstin, bill) → {ewbNo, generatedAt, validUntil|null}`;
  - typed errors `EwayGatewayRefusal` (business) and `EwayGatewayUnavailable` (transient);
  - **contract:** a live adapter must look up an existing EWB by (GSTIN, `INV`, docNo) before generating, so a retry never makes a duplicate.

  Adapters: `unconfiguredEwayGateway`, which is not configured and whose `generate` throws a 501 problem; and `sandboxEwayGateway`, which:
  - returns a deterministic 12-digit number from the bill id;
  - sets `validUntil` to `generatedAt` + ⌈max(distance, 1)/200⌉ days when a vehicle is present, otherwise null;
  - refuses when `transporterName` is `SANDBOX-REFUSE`.

  The `EWAY_GATEWAY` env value selects `sandbox` or `unconfigured` (default `unconfigured`). It is a mode, not a credential. The e2e suites default to `unconfigured`; the generate tests override the provider.
- [x] `wms-be/src/modules/invoicing/eway.delivery.ts` -- subscribe to `invoice.issued`. Decode `invoiceId` only. In a tenant tx: re-read the invoice (it must be `issued` with `issued_at`), compute the value and threshold, then `INSERT … ON CONFLICT (invoice_id) DO NOTHING`. Ack and log malformed or not-issued input; rethrow only transient faults. No audit.
- [x] `wms-be/src/modules/invoicing/eway.command.ts` + `facade.ts` -- full command skeleton (Idempotency-Key, audit row per bill, hash over the normalised body):
  - **`list`**: any member, `status` filter, cursor, at most 50 rows per page. Each row carries the invoice number, GSTIN, B2B flag, value, rule, Part B, `blockers[{code, terminal}]`, `gatewayAvailable` and `lastExportedAt`.
  - **`updateTransport`**: pending and not claimed. It **replaces** the whole Part B (null clears). Rules:
    - mode is required if any field is set;
    - Road: vehicle `^[A-Z0-9]{4,15}$` after uppercasing and removing spaces, and `vehicleType` R/O is required with a vehicle;
    - Rail, Air and Ship: `transDocNo` (≤ 15) and `transDocDate` are required, and the vehicle fields must be empty;
    - `transporterId` matches `^[0-9]{2}[A-Z0-9]{13}$`; `transporterName` ≤ 25;
    - `transDocDate` ≥ the invoice IST date;
    - distance 0–4000, and ≤ 100 when the two pincodes are equal.
  - **`record`**: pending and not claimed. `ewbNo` is 12 digits and unused in the tenant (409). `generatedAt` falls between `issued_at` and now + 5 min. `validUntil`, if given, is ≥ `generatedAt`.
  - **`dismiss`**: pending and not claimed; a reason of 1–200 characters.
  - **`export`** (`POST`, ids 1–100, unique). If any id is missing, not pending, claimed, blocked, or from a different GSTIN than the rest, the whole request is refused with 409 `eway-not-exportable` listing each `{id, reasons}`. Otherwise it stamps `last_exported_at`/`last_exported_by` and returns `{file}`.
  - **`generate`**:
    1. Lock the bill. Refuse with 409 if it is not pending, with 409 `eway-not-exportable` if it is blocked, with 501 if the gateway is unconfigured, and with 409 if a claim is under 2 minutes old.
    2. Set `gateway_claimed_at` and commit.
    3. Call the gateway outside the transaction.
    4. In a new transaction, `UPDATE … WHERE status = 'pending'` and clear the claim.
    5. A refusal writes `last_error`, clears the claim and returns 422. An `EwayGatewayUnavailable` keeps the claim (it expires) and returns 503.
  - **State thresholds**: list, and append. The state is checked against `gst_state_codes`, and 97 and 99 are refused (400).
  - **GSTIN settings**: list, and `PUT` (`assertGstinParam`; it must be the tenant's or one of its warehouses' GSTINs, otherwise 404).
- [x] `wms-be/src/modules/tenancy/permissions.ts` -- add `eway.manage` (owner, ops_manager, accountant) and `eway.configure` (owner). Update the accountant comment.
- [x] `wms-be/src/api/eway.controller.ts` + dto -- routes under `/tenants/{t}/eway`. Literal routes come before `:id`.
  - `GET bills`; `POST bills/export`;
  - `PATCH bills/:id/transport`; `POST bills/:id/record`, `bills/:id/dismiss`, `bills/:id/generate`;
  - `GET|POST state-thresholds`; `GET gstin-settings`; `PUT gstin-settings/:gstin`.

  Re-export `openapi.json`.
- [x] `wms-be/test/eway.spec.ts` + an 0056 block in a migration spec -- every matrix row, plus:
  - a golden bill built from a real issued invoice, asserting keys and types;
  - an integer reconciliation: `totalValue + cgst + sgst + igst + OthValue = totInvValue = payable`;
  - each blocker;
  - the generate claim race (record during a claim gives 409);
  - the CHECKs and the append-only trigger;
  - RLS.
- [x] `wms-fe`:
  - client wrappers and tests;
  - `lib/eway.ts` + test: reason mappers including the per-id 409 list, and the blocker copy;
  - `use-eway.ts`, which refetches on `EWAY_CHANGED_EVENT` and `INVOICES_CHANGED_EVENT`;
  - a `components/compliance/eway-bills.tsx` section placed between Invoices and the HSN summary, + test:
    - **Pending tab:** a GSTIN filter; checkboxes limited to one GSTIN; "Download NIC JSON (n)" over the ready selected bills, saying "k skipped (blocked)" for the rest; per-row blocker badges, with terminal ones telling the user to generate on the portal and record here;
    - **row actions:** the Part B form, the record form, dismiss, and Generate (only when `gatewayAvailable`);
    - a Refresh button, and the copy "new bills appear shortly after an invoice issues; a Part-A-only bill lapses after 15 days without Part B";
    - Generated and Dismissed tabs;
    - an owner-only settings panel: the override history plus an add form (the copy says it does not re-evaluate bills already queued), and an e-invoicing toggle per GSTIN.
  - Capability mirror: add `eway.configure` to `OWNER_ONLY_CAPABILITIES`; the pins move to owner 36, ops_manager +1 and accountant 1.
- [x] Meta docs -- `invoicing.md` (the e-way section and flow), `API-SURFACE.md`, `PENDING.md` and both contracts. PENDING gets entries for:
  - a live adapter (sealed per-GSTIN credentials, metering, the API key renames);
  - e-invoicing and IRN;
  - Part B update and the 15-day lapse of Part-A-only bills;
  - extension and cancellation;
  - `transType` 2–4;
  - exports, SEZ (undetectable) and 97/99;
  - grouping above 250 lines;
  - zero-rated exports counted as exempt;
  - document numbers starting with `0`, unverified at NIC;
  - the rate allow-list going stale.

**NIC bill-object mapping** (bulk keys; amounts are numbers rounded to 0.01 from integer paise; text has characters outside `A-Za-z0-9 @#-/,&.` removed and is then truncated):

| Key | Value |
|---|---|
| `userGstin`, `fromGstin` | origin GSTIN |
| `supplyType` / `subSupplyType` / `subSupplyDesc` / `docType` / `transType` | `"O"` / `1` / `""` / `"INV"` / `1` |
| `docNo`, `docDate` | invoice number; IST `dd/mm/yyyy` |
| `fromTrdName` | seller name (100) |
| `fromAddr1`, `fromAddr2`, `fromPlace` | origin address line1, line2 (120), city (50) |
| `fromPincode` | integer |
| `fromStateCode` | integer from the GSTIN prefix |
| `actualFromStateCode` | integer from the origin address state (`gstin = null`) |
| `toGstin`, `toTrdName` | consignee GSTIN or `"URP"`; buyer name (100) |
| `toAddr*`, `toPlace`, `toPincode` | from the consignee address (same limits and types) |
| `toStateCode` | place of supply (integer) |
| `actualToStateCode` | from the consignee address state (integer) |
| `totalValue` | Σ taxable |
| `cgstValue`, `sgstValue`, `igstValue` | Σ per line |
| `cessValue`, `TotNonAdvolVal` | `0` |
| `OthValue` | `roundOff` |
| `totInvValue` | `payable` |
| `transMode`, `transDistance` | integer; distance, with 0 → `1` when both pincodes are equal |
| `transporterId`, `transporterName`, `transDocNo`, `transDocDate` | as entered, or `""` |
| `vehicleNo`, `vehicleType` | Road: as entered; Rail/Air/Ship: `""` / `"R"`; Part A: `transMode` 1, `""` / `"R"` |
| `mainHsnCode` | the first line's HSN (string) |
| `itemList[]` | `itemNo`, `productName` (100), `productDesc` `""`, `hsnCode` (string), `quantity` (`qtyMilli/1000`), `qtyUnit` (`uqcFor`), `taxableAmount`, `cgstRate`/`sgstRate`/`igstRate` (percent), `cessRate` `0`, `cessNonAdvol` `0` |

**Blockers**:

| Blocker | Kind | Condition |
|---|---|---|
| `hsn-issue` | terminal | Any line's HSN is invalid |
| `doc-too-old` | terminal | The IST issue date is more than 180 IST calendar days before today |
| `too-many-lines` | terminal | More than 250 lines |
| `address-incomplete` | terminal | Either address is null, a pincode is missing, or the buyer name is null |
| `state-unresolved` | terminal | An actual state does not resolve |
| `ship-to-differs` | terminal | `actualToStateCode` ≠ place of supply, or `actualFromStateCode` ≠ the GSTIN state |
| `unsupported-supply` | terminal | Place of supply is 97 or 99 |
| `rate-not-standard` | terminal | A line's `gst_bps` is outside NIC's IGST rate table: {0, 10, 25, 300, 500, 1200, 1800, 2800} (Validations, Table 1), plus 4000 for GST 2.0's 40% rate (22 Sep 2025; not in the 1.0.0621 workbook) |
| `needs-irn` | fixable | B2B, and the GSTIN flag is on |
| `transport-incomplete` | fixable | Part B is invalid, or there is neither Part B nor a transporter ID (Part A only needs one) |

**Acceptance Criteria:**
- Given an issued inter-state invoice valued above ₹50,000, when `invoice.issued` is delivered twice, then exactly one `pending` bill exists, and its exported amounts reconcile to the stored invoice in integer paise.
- Given three ready bills from one GSTIN, when finance exports them and records three numbers, then all three are `generated` with source `manual`, each has an audit row, and re-exporting any of them is refused.
- Given the full BE and FE suites, when run, then they pass.

## Implementation Notes

- Baselines: wms-be `e4a66066ea6b7d96c2bfadd4c966fc720ae42aa8` (frontmatter `baseline_commit`); wms-fe `667874bf836a596f7004fa01e20a2fd3700eadd6`. Work happens on `feat/8-2b-e-way-bills` in both repos. Leave changes uncommitted; do not commit, push, or open PRs. Never run two jest invocations concurrently in wms-be (`bun run test -- <file>`; bare `bun test` hangs). NIC source copies: `/private/tmp/claude-502/-Users-sasidhar-Documents-WMS-Meta/cce72c77-089a-4cee-bfc4-8a5a14be09e3/scratchpad/attrs.xlsx`, `tool.xlsm`.
- Shipped: WMS-BE #73 (`f0423a3`), WMS-FE #58 (`698a237`); design PR WMS-Meta #86.

## Spec Change Log

## Review Triage Log

*Design review, 2026-10-04: two code- and source-verified reviewers (backend/migration; NIC fidelity/FE). 38 findings merged into 22. Three went to the human as decisions 6–8; the rest are folded into the spec.*

| # | Severity | Finding | Disposition |
|---|---|---|---|
| 1 | high | The gateway was called at issuance, when Part B never exists, so it could only make useless Part-A bills | Decision 7: on-demand Generate command |
| 2 | high | A retry or a concurrent record after the call could create a second EWB | Claim column + conditional write; record/dismiss refuse while claimed; port contract says look up before generating |
| 3 | high | Rethrowing deterministic failures starves later `invoice.issued` subscribers and quarantines | Handler acks malformed/not-issued; only transient faults rethrow; the gateway left the handler |
| 4 | high | The sandbox `FAIL` invoice-number trigger is unreachable | Refuses on a `SANDBOX-REFUSE` transporter name; tests override the provider |
| 5 | high | The accountant is read-only house-wide | Decision 6 |
| 6 | high | Part A with no transporter is rejected by NIC (tool G71) | `transport-incomplete` requires a transporter ID for Part A; representation pinned |
| 7 | high | Actual states copied the GSTIN state; bill-to/ship-to lost | Resolve from address text; decision 8 blocks a mismatch |
| 8 | high | `userGstin` unmapped; one export could mix GSTINs | `userGstin` = origin; `mixed-gstin` refusal; FE limits selection to one GSTIN |
| 9 | high | Null addresses or buyer name not blocked | `address-incomplete` |
| 10 | medium | Per-tax amounts are not in `document.totals` | Summed from lines; integer reconciliation test |
| 11 | medium | FKs break the house rule | Dropped; validated in the transaction; state CHECK |
| 12 | medium | No uuid identity for bills or settings (audit target) | `id uuid` on every tenant table |
| 13 | medium | Gateway write unaudited | Generate is a command, so it is audited; handler writes are not, per precedent |
| 14 | medium | Exports, SEZ and 97/99 exported as domestic | `unsupported-supply`; PENDING |
| 15 | medium | Export was a gated GET with no trace; duplicate uploads possible | `POST`, audited, stamps `last_exported_at`, shown in the UI |
| 16 | medium | Append-only unenforced; same-date typo uncorrectable | Trigger; a same-date row supersedes by `created_at`; no re-evaluation, stated in the copy |
| 17 | medium | One-way CHECKs; one EWB number on two bills | Two-way CHECKs, value > threshold, partial unique on `ewb_no` |
| 18 | medium | Bulk JSON types unpinned; field and address limits unmapped | Mapping table with types and limits; golden test asserts `typeof` |
| 19 | medium | Distance 0 fails for equal pincodes; non-NIC rates rejected | Send 1, max 100; `rate-not-standard` over NIC's table |
| 20 | medium | Terminal blockers can never clear; Part B rules incomplete | Terminal vs fixable; record/dismiss ignore blockers; NIC Part B rules listed |
| 21 | medium | FE: refetch on the invoices event misses async rows; the mirror edit is understated | `EWAY_CHANGED_EVENT`, Refresh button, copy; `OWNER_ONLY_CAPABILITIES` and every pin named |
| 22 | low | `mainHsnCode`, the 180-day boundary, PATCH semantics, GSTIN validation, export error arms, page size | All specified above |

*Code review, 2026-10-05: three layers (blind, edge-case, verification-gap); 27 findings merged into 20, each verified against the code.*

| # | Verdict | Finding | Evidence | Route |
|---|---|---|---|---|
| C1 | high | A transporter-ID-only Part A can never be saved, against the frozen matrix row "Part A only" | `partBProblems` (`eway-json.ts:295`) requires a mode when any field is set; the builder's `transMode ?? 1` is unreachable | patch: a transporter ID or name without a mode is valid Part A |
| C2 | high | A gateway-issued EWB number can be lost: settle fails (claim expired, then recorded/dismissed; number taken), an unknown error releases the claim, or a malformed `validUntil` gives a 500 | `generate` settle path and `releaseClaim` | patch: persist and log the orphaned number in `last_error`; keep the claim on unknown errors (503); validate `validUntil` |
| C3 | medium | Switching Part B from Road to Rail/Air/Ship still sends the hidden vehicle fields, giving a 400 the user can't clear | `parseTransportDraft` | patch |
| C4 | medium | Export with uppercase UUIDs misses existing bills; a lowercase GSTIN filter or PUT matches nothing | `IsUUID`/`UUID_RE` are case-insensitive; stored values are lowercase uuids and uppercase GSTINs | patch: normalise case |
| C5 | medium | `address-incomplete` checks the raw values, not the NIC-cleaned ones (a name or address that is entirely non-ASCII exports empty) | `ewbBlockers` vs `nicText` | patch |
| C6 | medium | A missing or non-issued (future void) invoice is reported as `address-incomplete`, and some routes answer 404 for an existing bill | `invoiceFacts` returns null | patch: an `invoice-unavailable` terminal blocker; 409 instead of 404 |
| C7 | medium | Test gaps: list status/GSTIN filters, page overlap, export refused while claimed, turning the e-invoicing flag off, the handler's ack and rethrow branches | Greps show no coverage; each mutation passes | patch: tests |
| C8 | low | The sandbox gives no validity to Rail/Air/Ship bills with a transport document, and ignores the ODC rate | `eway-gateway.ts:105` | patch |
| C9 | low | The FE copy hard-codes "₹50,000" | `EwaySettings` empty state | patch: generic copy |
| C10 | low | Data faults ack silently, so the consignment gets no bill and appears nowhere | `eway.delivery.ts` | patch (docs): a PENDING entry, mirroring the invoice one |
| C11 | low | `configuredFor` runs inside transactions; the port never says it must be local | `viewContextInTx` | patch (doc comment on the port) |
| C12 | low | Services-only (SAC) invoices are not excluded | No SAC handling | patch (docs): PENDING |
| C13 | low | Generate's malformed-result and taken-number arms are untested | The sandbox can't produce them | defer: test them with the live adapter |
| C14 | low | The 409 `bills[]` extension is not in the OpenAPI schema | `problemJsonResponse` | rejected: documented in prose; a typed schema needs new shared surface |
| C15 | low | An export replay returns the stale file | House idempotency semantics: a replay returns the original response | rejected: by design |
| C16 | low | No index serves the unfiltered list; no DB CHECK for state 97/99 | The FE always filters by status; the command validates 97/99 | rejected |

## Design Notes

- **Queue at issuance.** The invoice issues at dispatch, when value, parties and HSN are frozen. The EWB is needed before the vehicle leaves, so the row appears as soon as dispatch records.
- **Bulk keys are not API keys** (`transType`/`transactionType`, `actualFromStateCode`/`actFromStateCode`, `OthValue`/`otherValue`, `TotNonAdvolVal`/`cessNonAdvolValue`). The builder emits bulk keys; a live adapter renames them, as India Compliance does, and owns auth and encryption.
- **Why the claim.** NIC refuses a second EWB for a document, but a crash after a successful call would otherwise leave the bill pending. The claim stops a manual record racing the call, and the contract's lookup makes retries safe.
- **The rate table is dated** ("as on 1st October", workbook 1.0.0621). 4000 bps is added for GST 2.0; PENDING tracks keeping it current.
- **Sources:**
  - NIC `EWB_Attributes_new.xlsx` (Schema, Validations rules 1–32 and Table 1, Master Codes);
  - NIC bulk tool sheets (Part A requires a transporter ID);
  - NIC 2025 advisory (180 days);
  - NIC 05-01-2024 advisory (IRN);
  - CGST Rule 138;
  - India Compliance `e_waybill.py`/`transaction_data.py` for the Part-A form and distance 1.

## Verification

**Commands:**
- `bun run test` (wms-be) -- green, plus `typecheck`, `lint`, `build`; `db:generate` reports "No schema changes".
- `bun run lint && bun run test && bun run typecheck && bun run build` (wms-fe) -- green.
