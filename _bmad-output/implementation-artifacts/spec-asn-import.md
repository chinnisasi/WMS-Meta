---
title: 'ASN import — announce many advance shipment notices from one CSV or Excel file'
type: 'feature'
created: '2026-10-17'
status: 'done'
baseline_commit: 'ae47700c321548d5252405ef2bbaee1f4efa7e32'  # wms-be; wms-fe baseline: 8f8dce628f3308dd52d65e99aefd2a941acd991b
route: 'dispatch'
review_loop_iteration: 0
context:
  - 'docs/design/SYSTEM-DESIGN.md'
  - 'docs/design/IMPLEMENTATION-GUIDE.md'
  - 'docs/design/modules/inbound.md'
  - 'docs/design/modules/catalog.md'
  - 'docs/design/frontend/SYSTEM-DESIGN.md'
  - 'docs/design/frontend/IMPLEMENTATION-GUIDE.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** An ASN is keyed line by line, either on the web's "Announce a shipment" form or from the client portal. A 3PL whose client sends its shipment list as a spreadsheet has to re-type every line. On 2026-10-17 the user asked to upload a CSV or Excel file instead.

**Approach:** On **Inbound → Advance shipment notices**, add an **Import from file** action. It takes a `.csv` or `.xlsx` file with one row per ASN line, groups rows by ASN code, and works in two steps:

1. **Check file** validates every row and shows what would be created, with nothing written.
2. **Import** creates every valid ASN. Each one is exactly what the Announce form would have made: same rules, same audit, same `asn.created` event, and handhelds pick it up the same way.

Refused rows come back in a downloadable error report. A downloadable template shows the columns. PDF is out of scope: a PDF has no fixed layout, so reading one would need extraction plus a human review step.

**Design-review decisions (2026-10-17), shown to the user at the checkpoint:** the import targets the selected warehouse (a different `warehouse` value refuses that row's ASN with `wrong-warehouse`). A blank `client` derives from the SKUs. Extra columns (notes, descriptions) are ignored, not refused. Row numbers in the error report are spreadsheet row numbers, with the header as row 1.

**Decisions (user, 2026-10-17):**
1. **Valid ASNs are created, the rest are reported.** An ASN with any bad row is refused whole, and every other ASN in the file is created. Check file shows this outcome first.
2. **Staff only.** `asn.manage` on the web (owner, ops manager). The portal keeps its one-at-a-time Announce.
3. **ASNs only.** Purchase-order import (with a PO create form) is its own later story.

**File shape (one row per ASN line; header row required; column names case-insensitive, in any order):**

| Column | Required | Meaning |
|---|---|---|
| `asn_code` | yes | Rows with the same code (and client) form one ASN |
| `client` | no | Client code (e.g. `GLOWCO`), matched case-insensitively. **Blank = the client the row's SKUs belong to**, so a single-brand tenant (whose own client is `self`) never has to type it. `self` is accepted for the tenant's own goods. |
| `warehouse` | no | Must equal the warehouse the ASN card is showing (`BLR-DC`, case-insensitive), or be blank. The import goes into **the selected warehouse**, like the Announce form. |
| `expected_at` | no | `YYYY-MM-DD`, `YYYY-MM-DD HH:mm` (read as IST), or ISO-8601 with an offset; an Excel date cell is accepted |
| `sku` | yes | SKU code |
| `quantity` | yes | In the SKU's base unit, at most its declared precision |

## Boundaries & Constraints

**Always:**
- **Who can import:** `asn.manage` only (owner and ops manager). The portal is refused, both at the operator fence and by the command.
- **One ASN, one set of rules.** Each group passes exactly the checks the operator `create` applies. That means the command's checks plus the ones that live in its DTO today (`inbound.dto.ts:394,410,429`): quantity **> 0** and ≤ `MAX_QUANTITY_BASE`, and the code trimmed. Quantities are parsed from the cell's text through the catalog's import-edge `validateRecordableQuantity` with sign `positive`, never through a JS float. An xlsx numeric cell is read as its shortest decimal string, and anything finer than the SKU's precision is refused. The checks are:
  - code shape 1–64;
  - 1–200 lines;
  - warehouse, client and SKUs belong to the tenant;
  - every SKU belongs to the named client (`sku-client-mismatch`; `mixed-client`);
  - quantity > 0 at the SKU's precision;
  - `expected_at` well-formed;
  - the code is not already used by that client (`duplicate-asn-code`, scope `(tenant, client, asn_code)`).
- **Extra checks, file only:** every row of one group must agree on `client`, `warehouse` and `expected_at`. A SKU repeated inside one group is refused, not summed.
- **Kits are refused** (`kit-cannot-hold-stock`). The same check is added to the operator `create` **and `amend`**, placed after the client checks and before `scaleLines` (the portal's position, `asn.command.ts:624-635`). This closes the whole PENDING entry. `kit-cannot-hold-stock` is added to both routes' 409 `@ApiResponse` text, with cases in `asn.spec.ts`.
- **Caps:** the file ≤ 5 MB, ≤ 5,000 data rows, ≤ 500 ASNs. These bound one request's transaction (about 6 statements per ASN) and its response. They do **not** bound the device snapshot: repeated imports can still grow it, and that residual risk is recorded in PENDING beside the portal write-cap entry. A timing test runs at the cap.
- **Idempotency:**
  - Import takes one `Idempotency-Key`. Its fingerprint is `{fileSha256, warehouseId}`, and exactly one `idempotency_keys` row is written per import.
  - The web mints the key **once per checked file** and reuses it until a different file is picked. Clicking Import again after a timeout therefore replays the stored answer, instead of reporting every ASN as `duplicate-asn-code`.
  - Check file (`dryRun=true`) takes no key, runs no replay lookup, and writes nothing.
- **What each created ASN writes:** its own `asn.created` outbox event and audit row, the same as a single create, with the audit `reference` = the bare key (the existing convention).
  - This needs a refactor: `finish` (`asn.command.ts:885-914`) writes the key on every call, so it is split into `emitAsnCreated(tx, asn, actor, reference)` (read-back, outbox, audit), and the key write moves to the callers.
  - The import mints an `importId` and writes one `asn_import.executed` audit row: target type **`asn_import`** (added to `AUDIT_TARGET_TYPES` and the web's audit label map), target id = `importId`, with the counts and the file's SHA-256. The response returns `importId`.
- **A race with a manual create:** each group's insert runs in a **savepoint**. A concurrent create of the same code raises a 23505, which aborts only that group's savepoint, and the ASN is refused as `duplicate-asn-code`. The rest of the run carries on.
- **Row error codes** form a closed enum `AsnImportRowErrorCode`, declared in the response DTO so the web client is typed, with a web copy map:
  - lookups: `unknown-client`, `unknown-warehouse`, `wrong-warehouse`, `unknown-sku`;
  - client attribution: `sku-client-mismatch`, `mixed-client`;
  - the ASN's own rules: `kit-cannot-hold-stock`, `duplicate-asn-code`, `invalid-asn-code`, `too-many-lines`;
  - file consistency: `asn-rows-disagree`, `duplicate-sku-in-asn`;
  - cell values: `invalid-quantity`, `invalid-expected-at`, `missing-value`.
- **File-level failures:** 415 `unsupported-file-type`; 400 `file-unreadable`; 400 `missing-columns` (naming them); 422 `import-too-large`. The catalog's factories and `CatalogUploadFilter` move to `shared` so both imports use one copy.
- **The sheet reader** (CSV via `csv-parse`, xlsx via `exceljs`, the single-worksheet rule) is **extracted** from `catalog/import.command.ts` into `shared`, unchanged for the catalog (its tests pass unedited). It gains an option to ignore unknown columns, which the ASN import uses, and it reports spreadsheet row numbers.
- **Output:** the response lists the created ASNs and each refused row: row number, ASN code, reason code, detail. The web builds the CSV error report the same way the catalog import does.

**Never:**
- No partial ASN: a group with any bad row is refused whole (all-or-nothing within an ASN).
- No amend, close or cancel through import, and no PO import (decision 3).
- No PDF.
- No new table or migration: the import is a request, not a stored entity (see Design Notes).

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|---|---|---|---|
| Happy path | 3 ASNs, 10 valid rows | Check file: "3 ASNs, 10 lines ready". Import: 3 ASNs `announced`, listed with links | N/A |
| Bad row | One ASN has an unknown SKU | That ASN is refused whole; the other ASNs are created | Error row: `row 7 · GLOW-ASN-9 · unknown-sku · "No SKU with code X"` |
| Other client's SKU | `sku` belongs to another client | Its ASN refused | `sku-client-mismatch` |
| Kit SKU | A kit code on a line | Its ASN refused | `kit-cannot-hold-stock` |
| Disagreeing header fields | Two rows of one `asn_code` name different warehouses | Its ASN refused | `asn-rows-disagree` naming the column |
| Repeated SKU | One ASN lists a SKU twice | Its ASN refused | `duplicate-sku-in-asn` |
| Code already used | `asn_code` exists for that client | Its ASN refused | `duplicate-asn-code` |
| Same code, two clients | `ASN-1` for GLOWCO and `ASN-1` for ACME | Two separate ASNs (the grouping key is client + code) | N/A |
| Precision | `1.5` on a whole-unit SKU | Its ASN refused | `quantity-precision` |
| Dates | `2026-10-20` / `2026-10-20 14:30` / an Excel date cell | IST midnight / 14:30 IST / the cell's wall-clock fields read as IST (a `Date` cell is handled **before** any `toISOString()`) | A numeric serial, `20/10/2026` or `10/20/2026` → `invalid-expected-at`. Rows of one ASN are compared after normalising; a blank cell and a filled one disagree → `asn-rows-disagree` |
| Unknown client or warehouse code | `client` = `ACMEE` | Its ASN refused | `unknown-client` / `wrong-warehouse` |
| Extra columns | A `notes` column | Ignored | N/A |
| Bad file | Wrong type, empty, header missing a required column, > 5 MB, > 5,000 rows, > 500 ASNs | Nothing created | 400/422 with one file-level reason |
| Retry | Import repeated with the same key | The same answer replays; nothing created twice | Same key with a different file → 422 `idempotency-key-reuse` |
| Role | Operator / accountant / portal session | No Import action on the web | 403 `role-denied` at the API |

</frozen-after-approval>

## Code Map

**Repos and branches.** Backend paths are under `workspace/core/backend/wms-be` and frontend paths under `workspace/core/frontend/wms-fe`. Both are on branch `feat/asn-import`, cut from `main`.
- Do the backend first and commit it there. Then export the OpenAPI spec (`bun run openapi:export`, committed), then run `bun run api:generate` in wms-fe.
- Meta docs go on the meta repo's `docs/asn-import`.
- Commit locally in each repo. Do not push, open PRs or switch branches.
- **Backend tests** use jest: `bun run test -- <file>`. Never bare `bun test`, and never two jest runs at once.
- **Frontend tests** use `bun test`.


- **Backend precedent (catalog import):**
  - `wms-be src/modules/catalog/import.command.ts`: server-side parsing (`exceljs` `parseXlsxSheet` `:1079`, `csv-parse/sync` `:1015`, type pick `:1003-1013`), caps (`MAX_IMPORT_ROWS` `:66`, `MAX_IMPORT_BYTES` `:67`), file-sha fingerprint (`:281`), and the response stored as the idempotency snapshot (`:880`).
  - Route: `catalog.controller.ts:167-224` (`FileInterceptor('file')`, `CatalogUploadFilter` for oversize → 422).
  - Known flaw not to copy: it parses before the permission check (`PENDING.md:447`). The ASN import checks the capability first.
- **ASN rules to reuse:**
  - `wms-be src/modules/inbound/asn.command.ts`: `create` (`:475`) with its guard order (`:869`, `:933`, `:506`), `MAX_ASN_LINES` (`:93`), code shape (`:428`), `expectedAt` rule (`:406`), `scaleLines` precision (`:1050`), `insertAsn` (`:983`), and `finish` (`:885`: outbox `asn.created`, audit, key).
  - The kit check exists only in `announce` (`:630`).
  - A 23505 on `advance_shipment_notices_tenant_client_code_unique` aborts the transaction (`:1006-1008`). The import must pre-check codes inside its transaction and treat a concurrent-insert 23505 as a whole-run 409 `conflict` (retryable).
- **Code lookups:**
  - There is no by-code facade read for clients or warehouses. Add bulk `…ByCodesInTx` reads: clients in `clients.facade.ts` (codes stored uppercase, so match uppercased); warehouses in tenancy.
  - Add a bulk SKU-by-code read (id, client, kit flag, uom precision) in `catalog.facade.ts`, beside `getSkuHsnByCodesInTx` (`:533`).
- **New route:** `POST :tenantId/inbound/asn-imports` (multipart `file`, `warehouseId`, `dryRun`), in `api/inbound.controller.ts` beside `:348`. `asn.manage`; refuses portal sessions. Parsing goes in a pure `inbound/asn-import.parse.ts` (header map, IST dates, grouping), unit-tested without a database.
- **Frontend:**
  - `wms-fe src/components/inbound/asn-card.tsx`: gated on `asn.manage` at `:87`. The Announce form (`AsnCreateForm`, `:210`) is the sibling the import sits next to.
  - Reuse `lib/csv.ts` (`csvField`, `downloadText`) for the error report and the template, and follow the catalog card's file input and result table (`components/settings/import-catalog.tsx:145,211,302`).
  - Fire `notifyInboundChanged()` after an import, so the list and the tab counts refresh.
  - There is no file-parse library on the web, and none is needed (the server parses).
- **Downstream:** the device catalog snapshot (`receiving.facade.ts:124,466-524`) includes every open ASN with no limit. That is the reason for the 500-ASN cap.

## Tasks & Acceptance

**Execution:**
- [ ] BE `inbound/asn-import.parse.ts` + spec: header mapping, required columns, IST date parsing (strings and Excel date cells), grouping by (client, code), per-group consistency, and the row and ASN caps.
- [ ] BE facades: clients, warehouses and SKUs by code (bulk, tenant-scoped).
- [ ] BE `inbound/asn-import.command.ts`:
  - capability → replay → parse → resolve → validate each group with the shared ASN checks (extracted from `create`, not copied) → dry-run returns;
  - otherwise insert each valid group through `insertAsn` + the `finish` tail, then the `asn_import.executed` audit, then the key. Each group runs in a savepoint (`tx.transaction`).
- [ ] BE `asn.command.ts`: split `finish` into `emitAsnCreated` + the caller's key write; the kit check in operator `create` and `amend`.
- [ ] BE `shared/`: extract the sheet reader, the file-level error factories and the upload filter from catalog (the catalog tests pass unedited); add `asn_import` to `AUDIT_TARGET_TYPES`.
- [ ] BE route + DTOs + `openapi:export` (committed).
- [ ] BE tests `test/asn-import.spec.ts`: every matrix row, plus a concurrent manual create racing the import (409 `conflict`), a dry run writing nothing (no ASN, no key, no audit), and the portal 403.
- [ ] FE `api:generate` (after the BE merge); `fetchApiImportAsns` wrapper + `client.test.ts` pin.
- [ ] FE `components/inbound/asn-import.tsx`: file pick (`.csv,.xlsx`), Check file, Import, the result (created list with codes; refused rows table, first 100, plus "Download error report"), and "Download template". Mounted in the ASN card for `asn.manage`.
- [ ] FE tests `asn-import.test.tsx`: the role gate, the dry run then the import, the error report contents, the template header, a 422 file error, and that Import reuses one key per checked file (and mints a new one when the file changes); the `asn_import` audit label.
- [ ] Meta docs: `modules/inbound.md` (the import flow, as a sequence diagram), API-SURFACE, frontend SYSTEM-DESIGN `/inbound`, PENDING (PDF import; portal import; PO import with a PO form; the kit gap closed).

**Acceptance Criteria:**
- Given a file of 3 valid ASNs, when imported, then 3 ASNs exist exactly as if announced on the form (same lines, statuses, audit and `asn.created`), and the handheld snapshot lists them.
- Given Check file on any input, then no ASN, idempotency key or audit row is written.
- Given an import retried with the same key and file, then the stored answer replays and nothing new is created.

## Implementation Notes

Implemented 2026-10-17 on `feat/asn-import` (wms-be, wms-fe) and `docs/asn-import` (meta). Where the spec left a choice open, or two of its sections disagreed:

- **The concurrent-create race.** The Code Map and the test task say a racing 23505 is a whole-run 409 `conflict`; the Always list and triage #10 say each ASN runs in a savepoint and only the raced ASN is refused `duplicate-asn-code`. The frozen Always list won: savepoint per ASN (`tx.transaction`), the run carries on. `test/asn-import.spec.ts` parks the import behind an uncommitted manual insert, commits it, and asserts the other ASNs are created; removing the savepoint turns it into a 500 (mutation-checked).
- **`quantity-precision` is in the enum.** The I/O matrix names it ("1.5 on a whole-unit SKU"); the Always list's enum did not. The enum has 16 codes, `quantity-precision` among them, rather than folding precision into `invalid-quantity`.
- **The audit row cannot carry the counts and the SHA-256.** `audit_events` has no payload column and `reference` must stay the bare key (the guard matches by equality). The `asn_import.executed` row carries `importId` and the key; the counts and `fileSha256` are in the response stored under that key.
- **`finish` split.** The read-back/outbox/audit half is `emitAsnEvent(tx, outbox, {tenantId, actorUserId, asnId, type, reference})` (it serves all four ASN events, so it is not named `emitAsnCreated`); the key write is `writeAsnKeyInTx` in each caller.
- **Warehouse codes.** A non-blank `warehouse` other than the target's is `wrong-warehouse` when it names another warehouse of the tenant, `unknown-warehouse` otherwise.
- **Blank client grouping.** Rows group by (`asn_code`, client cell). A blank-client group whose SKUs name exactly one client merges with the explicit group of that client and code (its rows then disagree on `client`); a blank-client group over two clients' SKUs is `mixed-client`, never split.
- **Where errors land.** Cell and lookup refusals are per row (first failure wins per row); group-level ones (`invalid-asn-code`, `too-many-lines`, `mixed-client`, `duplicate-asn-code`) on the ASN's first row; `sku-client-mismatch` on each row of the other client; `asn-rows-disagree` on the first disagreeing row per column; `duplicate-sku-in-asn` on the repeat. The clean rows of a refused ASN are not listed.
- **Status codes.** Check file answers 200, Import 201 (one route). An `Idempotency-Key` sent with a dry run is ignored.
- **Web.** Import is enabled only after a Check file that found something to create; the created ASNs are listed by code (the ASN list returns to page one and refetches — there is no per-ASN route to link to).

## Spec Change Log

## Review Triage Log

Design review: one pass, 13 findings. These were checked against the code: `finish` writes the key (`asn.command.ts:914`); `SELF_CLIENT_CODE = 'self'` (`schema.ts:141`); `cellText` does `toISOString()` on a `Date` (`import.command.ts:1156`); `audit_events.target_id` is NOT NULL (`schema.ts:204`); the ASN card holds one `warehouseId` (`asn-card.tsx:66-72`).

| # | Finding | Verdict | Disposition |
|---|---|---|---|
| 1 | `finish` writes the key per call, so it can't be reused per ASN | high | Always: split into `emitAsnCreated`; one key row per import; a task |
| 2 | The DTO-level checks (positive, ceiling, trim) would be skipped | high | Always: listed; `validateRecordableQuantity` positive; xlsx numbers via the decimal string |
| 3 | The new refusal codes are undeclared and inconsistent | medium | Always: a closed `AsnImportRowErrorCode` enum in the DTO + a web copy map, covering every arm |
| 4 | Uppercase matching can't name the `self` client; the case rules unstated | high | File shape: `client` case-insensitive, blank = the SKUs' client, `self` accepted |
| 5 | Excel `Date` cells arrive as UTC ISO, so they skip the IST rule | high | Matrix: `Date` handled first; serials and dd/mm refused; normalised comparison |
| 6 | The `warehouse` column vs the one-warehouse card | medium | Decision: import into the selected warehouse; a different value → `wrong-warehouse` |
| 7 | The audit row has no target id; unregistered target type; reference format change | high | Always: `importId`, `asn_import` target type (BE + web), bare-key reference kept |
| 8 | Kit fix misses `amend`; its position unstated | medium | Always: create and amend, after the client checks; ApiResponse text; tests |
| 9 | The 500 cap doesn't bound the snapshot | low | Always: justified as a request bound; residual → PENDING; timing test at the cap |
| 10 | One concurrent 23505 rolls back the whole run | medium | Always: a savepoint per group → that ASN `duplicate-asn-code` |
| 11 | A key per click defeats the replay | medium | Always: a key per checked file; a test |
| 12 | Dry-run keys and the file-level codes underspecified; catalog factories cross a module boundary | medium | Always: dry run takes no key and runs no replay; exact statuses; factories and filter → `shared` |
| 13 | Reusing the catalog parser brings unstated rules | medium | Always: the reader extracted to `shared` unchanged for the catalog; ignore-unknown-columns option; spreadsheet row numbers |

## Design Notes

**Why server-side parsing.** The catalog import already parses on the server with `exceljs` and `csv-parse`, and the web has no spreadsheet library. Parsing in one place also means the dry run and the import read the file identically.

**Why no import table.** The catalog keeps `catalog_imports` and `catalog_import_errors` because its fix-mode re-run needs the last run's failures. An ASN import has no re-run mode: you fix the file and upload it again, and the codes that already went in are refused as `duplicate-asn-code`. The idempotency snapshot keeps the response for replay, and the audit row keeps who imported what. Skipping the table avoids a migration.

**Dates and IST (§9 periods/IST checklist).** A naive date or date-time is IST, because the warehouses are in India and a person typing "2026-10-20" means the IST day. An explicit offset is honoured, and the result is stored as the UTC instant the existing `expectedAt` takes. Excel stores dates without a zone, so a date cell is read as an IST wall-clock time, consistent with the text forms.

## Verification

**Commands:**
- `bun run test -- test/asn-import.spec.ts test/asn.spec.ts` (wms-be, jest; never two runs at once) -- expected: green
- `bun run lint` / `bun run typecheck` (wms-be) -- expected: clean
- `bun run typecheck` / `bun run lint` / `bun test` / `bun run build` (wms-fe) -- expected: clean, 0 fail

**Manual checks:**
- On localhost:3001 (demo tenant): download the template, add two GLOWCO ASNs (one with a typo SKU), then run Check file, then Import. One ASN is created and one is refused, with an error report. The new ASN appears in the list and on the handheld snapshot.

Code review: one pass over wms-be `ae47700..adc977b` and wms-fe `8f8dce6..a00caa9`, with three layers (blind hunter 16, edge-case hunter 8, verification gap 2 + 2 other). The patch round landed in wms-be `65d3d50` and wms-fe `48997bc`, then was re-verified: BE 89 suites / 2095 tests, lint and typecheck clean; FE 1667/0, typecheck, lint and build clean.

| # | Finding | Verdict | Disposition |
|---|---|---|---|
| C1 | A blank-client row beside the same client explicitly is refused; two groups of one (client, code) could both reach the insert, so a dry run said "ready" and the import half-created (VG + edge + VG other) | high | **patch.** `resolveAsnGroups` groups by (resolved client, code); blank agrees when the derived client matches; e2e `MIX-t` / `DIS2-t` |
| C2 | A keyless dry run (what the web sends) is untested on the backend (VG) | medium | **patch.** e2e: 200, `importId: null`, counts unchanged; plus same-key concurrency (201 + 409) and a portal dry run (403) |
| C3 | CSV row numbers drift after a quoted multi-line cell (blind + edge + VG other) | false | **reject.** Excel shows a quoted multi-line cell as ONE row, so record index + 2 IS the row the user sees; `info.lines` would number every later row too high. Pinned by a test |
| C4 | CSV extra cells refused while XLSX ignores them (edge) | medium | **patch.** Extras dropped under `unknownColumns: 'ignore'`; test |
| C5 | A time-only Excel cell becomes an ASN expected in 1899 (edge) | medium | **patch.** Rendered as `HH:mm` text → `invalid-expected-at`; test |
| C6 | Formula floats (0.30000000000000004) refused though Excel shows 0.3 (blind + edge) | medium | **patch.** `numberCells: 'excel-display'` (15 significant digits) for the ASN import only; catalog unchanged |
| C7 | A blank-client group's `clientCode` falls back to a uuid (blind + edge) | low | **patch.** Code resolved by id; test |
| C8 | Re-picking the same fixed file fires no change (blind + edge) | medium | **patch.** Input cleared after a pick; the file read before send, a read failure has its own wording |
| C9 | Misplaced JSDoc in clients.facade / tenancy.service; two warehouse lookups | low | **patch.** Moved; `assertWarehouseInTenant` calls `getWarehouseCodeInTx` |
| C10 | One row can report several errors; the banner counts errors as rows | low | **patch.** Distinct rows counted ("2 rows with problems") |
| C11 | Refusals hidden (green banner) when only blank-`asn_code` rows are bad | medium | **patch.** Refused rows named whenever errors exist; test |
| C12 | Open ASNs that already hold a kit line can no longer be amended | low | **reject.** Pre-live; handling an unchanged legacy kit line adds a branch for data that is unlikely to exist. Recorded here. The amend picker still shows a kit already on the ASN |
| C13 | The operator form lacks `kit-cannot-hold-stock` wording; its picker offers kits | medium | **patch.** `asnReason` arm; kits left out of the create/amend pickers (`withoutKits`); test proved to fail without the filter |
| C14 | The error report can't identify the line (no sku/quantity) | medium | **patch.** `sku` and `quantity` on each error (DTO + openapi + CSV columns) |
| C15 | Case rules and accepted date forms undocumented in the help | low | **patch.** Help text: ISO with an offset accepted, a naive `T` time refused, `asn_code`/`sku` case-sensitive |
| C16 | The sheet-reader comment miscounts its options | low | **patch** |
| C17 | The new `'positive'` quantity arm is only tested indirectly | low | **patch.** Direct unit test |
| C18 | The spec's Tasks line still says a race is a whole-run 409 (edge) | low | **reject.** A fix would edit this spec; the frozen Always (a savepoint per group → `duplicate-asn-code`) is what was built and is recorded in Implementation Notes |

