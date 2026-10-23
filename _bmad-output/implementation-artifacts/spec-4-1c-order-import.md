---
title: '4-1c order import — staff and client-portal CSV/XLSX order import: Check file, then Import, one order per client order number, each created through the existing order pipeline under its own derived key'
type: 'feature'
created: '2026-10-24'
baseline_commit: '809fdb6'  # wms-be origin/main (4-2a merged, migrations to 0093); wms-fe origin/main a6fec02; wms-mobile origin/main (untouched)
status: 'ready-for-dev'
route: 'dispatch'
review_loop_iteration: 0
context:
  - '_bmad-output/implementation-artifacts/epic-4-context.md'
  - 'docs/initiatives/production-readiness.md'
  - 'docs/design/SYSTEM-DESIGN.md'
  - 'docs/design/IMPLEMENTATION-GUIDE.md'
  - 'docs/design/modules/outbound.md'
  - 'docs/design/modules/inbound.md'
  - 'docs/design/modules/clients.md'
  - 'docs/design/PENDING.md'
  - 'docs/design/API-SURFACE.md'
  - 'docs/design/frontend/SYSTEM-DESIGN.md'
  - 'docs/design/frontend/IMPLEMENTATION-GUIDE.md'
  - '_bmad-output/implementation-artifacts/spec-asn-import.md'
  - '_bmad-output/implementation-artifacts/spec-4-1a-portal-order-entry.md'
  - '_bmad-output/implementation-artifacts/spec-4-1b-client-order-number.md'
  - '_bmad-output/implementation-artifacts/spec-4-2a-order-fields.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** A client's orders reach the warehouse one at a time: a staff member keys each into the Outbound create form, or the client keys each into the portal's Place order. A B2B client sending a day's 80 store replenishments, or a brand without a connected channel sending its weekend's orders, has no bulk path. Roadmap 4.1 ("CSV/Excel order import") is the last open part of order intake; 4-1a (portal entry) and 4-1b (the client order number) shipped, and 4-1b's deferred entry names this story (`deferred-work.md`, "4-1c staff CSV/Excel order import").

**Approach:**
- One file, one row per order line, grouped into orders by the **client order number** (`order_ref`, 4-1b's per-client live-unique number).
- The ASN import's two steps on one route: **Check file** (`dryRun`, writes nothing, takes no key) and **Import**.
- Two surfaces, two routes, two commands sharing one parser:
  - **staff** — `POST /tenants/{t}/outbound/order-imports` (`orders.manage`), on the web's Outbound → Orders;
  - **client portal** — `POST /tenants/{t}/portal/order-imports` (`orders.place`), on the portal's Orders page.
- Each order is created **exactly as the one-at-a-time create would**: the staff import calls `createOrder`, the portal import calls `placePortalOrder`, each under a key **derived** from the import's key. Every order rule (authority, address, GSTIN, client number, 4-2a fields, licences, kits, inactive SKUs, reservations, backorders or the portal's shortage refusal) is the existing command's, not a copy.

**Decisions (recommended, taken autonomously under the user's standing instruction, 2026-10-24):**
1. **Per order, never all-or-nothing.** An order with any bad row is refused whole; every other order is created. All-or-nothing is not possible here: an order's create is three transactions and a reservation grant per line (`order.command.ts:432-439`, `placeOrder` `:918`), so one transaction cannot hold a file of them. It is also the wrong outcome for the user: one mistyped pincode must not hold back 79 good orders. This is the ASN import's granularity (an ASN with any bad row refused whole, `asn-import.command.ts:404-415`).
2. **Orders are created in file order, one after another** — the order of each order's first row. The first order in the file reserves first. No parallelism: two orders of one file contending for the last units must resolve the same way on every run.
3. **Idempotency, per file and per order.**
   - **The file.** Import requires an `Idempotency-Key`. The file fingerprint is `{surface, [clientId,] warehouseId, fileSha256}` — the bytes and the target, never the parsed rows (the ASN/catalog convention, `asn-import.command.ts:157-159`), with a `surface` discriminator because the key table is unique per tenant across every route (`schema.ts:755`; IMPLEMENTATION-GUIDE §9). The import's key is written LAST, with the response as its snapshot; a replay re-serves it before the file is even read.
   - **Each order.** Each order's create runs under a **derived key**: the import key's 10-character time prefix plus 16 characters of `sha256(importKey : 'order-import' : surface : fileSha256 : warehouseId : clientId : order_ref)`, in the ULID alphabet (the `refusedGrnLinesOpId` shape, `receiving.command.ts:3175-3183`), never equal to the import key. So a retry of the same import with the same file — after a timeout, a crash or a 503 halfway — replays every order already created (the create's own replay, `order.command.ts:999`) and creates only the rest. Nothing is created twice.
   - **Across files.** A second upload of the same orders under a new key is refused order by order by the client number's live uniqueness: `duplicate-client-order-ref`, naming the order that holds it (staff, `order.command.ts:627-637`) or the portal's own sentence (`:793-796`). That is why `order_ref` is required on every row.
4. **The settle-once rule.** Two runs of the same import can overlap (a user re-clicks Import while a slow first request is still running). Their derived keys are equal, so one order's two creates race: the loser answers `409 conflict` (the key's unique index, `order.command.ts:2126-2152`) or `409 duplicate-client-order-ref` (the ref's partial unique index, `:1603-1614`), with its grants released either way. On either 409 the import calls the same create **once more with the same derived key**: when the twin committed, that call replays the twin's snapshot and the order counts as created; otherwise the refusal stands and is reported.
5. **What aborts the whole import** (no import key written, no file audit row; created orders stay and replay on retry): any non-`ProblemException`, any 5xx (`503 reservation-store-unavailable`), any 401/403 (the session or the client changed mid-run), and `409 conflict` on the import's own key. The 503's detail says how many orders were created and that Import again with the same file finishes the rest without duplicates. Every other 4xx from an order's create is that order's refusal, reported as a row error on its first row.
6. **Caps** (all `422 import-too-large`): **5 MB** (the shared `MAX_SHEET_UPLOAD_BYTES`), **2,000 data rows**, **200 orders**, and **200 lines per order** (`MAX_ORDER_LINES`, `outbound.dto.ts:114`, enforced by the import because the command checks only "at least one line", `order.command.ts:2329-2347`). The row and order caps are lower than the ASN import's (5,000 / 500) because each order is several transactions and a grant per line, all inside one HTTP request, and the ALB cuts a connection idle for 60 s (DEPLOY.md §8.8). The worst case (200 orders, 2,000 lines) must finish in under 30 s on a local stack, measured by a test; if it does not, the caps are lowered, never the 30 s.
7. **The columns** (header required, case-insensitive, any order, unknown columns ignored — the ASN reader options, `asn-import.command.ts:175-184`):
   - per line: `sku`*, `quantity`* (in the SKU's base unit; the ASN quantity text rule), `rate` (staff only: rupees `^\d{1,8}(\.\d{1,2})?$` → `ratePaise`);
   - per order: `order_ref`*, `client` (staff only — blank = the client the SKUs belong to; the tenant's own is `self`), `warehouse` (blank, or the chosen warehouse's code), `ship_to_name`*, `ship_to_phone`*, `ship_to_line1`*, `ship_to_line2`, `ship_to_city`*, `ship_to_state`*, `ship_to_pincode`*, `consignee_gstin`, `consignee_legal_name`, `order_type` (`b2b`/`b2c`, any case), `priority` (`normal`/`high`/`urgent`, any case), `ship_by` (`YYYY-MM-DD`, or an Excel date cell with no time), `cod_amount` (rupees, as `rate` → `codAmountPaise`).
   - `*` = the header must carry it (`400 missing-columns`, naming each).
   - On the portal, `client` and `rate` are not columns (ignored like any unknown column): the client is the session's, and the portal line has no rate (`portal.dto.ts`, 4-1a).
8. **Per-order cells.** An order's rows may repeat its per-order cells or leave them blank after the first: the order's value for each per-order column is its one non-blank value. Two different non-blank values are refused `order-rows-disagree` on the later row. A required per-order value blank on every row is `missing-value` on the order's first row, naming the column. (The ASN import treats blank-vs-filled as a disagreement for `expected_at`; with sixteen per-order columns that would force every row to repeat the whole address, so the order import is deliberately more lenient.)
9. **Grouping and the client (staff).** Rows group by (`client` cell, case-insensitive; `order_ref`, exact). A blank-client order's client is the one client holding every one of its SKU codes (`client-required` when several do, `mixed-client` when none does); a named client must hold each code (`sku-client-mismatch`). Unlike the ASN import, blank-client rows never merge into a named group: when a blank group and a named group settle on the same (client, `order_ref`), both are refused `duplicate-order-in-file`. A SKU listed twice in one order is refused `duplicate-sku-in-order` (never summed). On the portal the client is the session's and the SKU codes resolve only among its own **active non-kit** SKUs — `portal/skus`' population — so another client's code, a kit, an inactive SKU and an unknown code are the same `unknown-sku` row error.
10. **Check file runs the real rules, minus stock.** A dry run validates each order through the create's own phase 1 — a new `checkOrder` / `checkPortalOrder` on `OrderCommandService` that runs `preflightPhase` with no key (no replay, nothing written) on the same surface `createOrder` / `placePortalOrder` builds. So the Check reports an already-used client number, a departed client, a licence gap, a bad address or an out-of-range ship-by exactly as Import would. It reserves nothing and so cannot promise stock: a staff order may still backorder, and a portal order may still be refused for a shortage at Import. The result says so.
11. **The report.** Both steps answer `{importId, dryRun, warehouseId, fileSha256, rowCount, orderCount, acceptedCount, refusedCount, orders[], errors[]}`:
    - `orders[]` — each order created (dry run: ready): `{orderId (null on a dry run), clientOrderRef, lineCount, firstRow}`, plus on the staff surface `clientId`, `clientLabel` and `backorderedLineCount` (null on a dry run).
    - `errors[]` — every refused row in sheet order: `{rowNumber (spreadsheet row, header = 1), orderRef | null, sku | null, quantity | null, code, detail}`; an order's refusal from the command sits on its first row, with the command's own detail.
    - `code` is a closed enum (`ORDER_IMPORT_ROW_ERROR_CODES`), published in the DTO so the web's labels are a `Record` over it. A command refusal whose code is not on the list is reported as `order-refused` with the code in its detail, so the enum stays closed.
    - The web renders the first 100 errors and downloads every one as a CSV report (the ASN import's pattern).
12. **Audit.** Each created order writes its own `order.created` outbox event and audit row (the create's, `order.command.ts:1561-1590`, reference = its derived key). The import adds one `order_import.executed` row (target `order_import` → `importId`, reference = the import key, actor = the importing user — a client user on the portal), beside the import key, even when every order was refused (the ASN precedent, `asn-import.command.ts:492-505`). No migration.
13. **The portal import is a separate command** (IMPLEMENTATION-GUIDE §7e): its own transactions stamped `{ clientId: command.clientId }`, the portal gate (`orders.place` → the member re-read → `shareLockClientInTx`) before its replay and again before writing its key, the client from `PortalSession` only, an exact-key response with no client labels, and a fingerprint starting `surface: 'portal'`.
14. **Full stack.** Backend and web. **Mobile is untouched:** the import is desk work, and an imported order is an ordinary `manual` order the existing waves, pick, pack and dispatch already serve.

## Boundaries & Constraints

**Always:**
- Each order is created only through `createOrder` (staff) or `placePortalOrder` (portal), with source `manual`. No order row, line, reservation, event or audit is written by the import itself.
- `createOrder` and `placePortalOrder` keep their hashes, responses and behaviour byte-identical: the existing goldens (`test/issuance-gate-parity.spec.ts`, `test/portal-orders-create.spec.ts`) pass unedited.
- Authority first: the staff import asserts `orders.manage`, the portal import runs the portal gate, before the import key's replay and before the file is read.
- The import's own transactions are short (one before the orders, one after); no transaction is held open across the orders.
- The web never reads the file; it uploads it. The Import key is minted when a file is checked and reused until another file is picked.

**Never:**
- No new table, migration or background job; no async import.
- No change to the ASN import's behaviour or response.
- No stock preview, no ATP read in Check file.
- No order edit, no upsert: a client number already live is refused, never updated.
- No channel or marketplace export format (Shopify CSV, Amazon reports) — the documented columns only.
- No mobile change.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|---|---|---|---|
| Staff happy | 3 orders, 7 rows, ACME SKUs, client blank | Check: 3 ready; Import: 3 orders, each with its derived key, one `order_import.executed` row | — |
| Mixed file | 3 orders; one row of SO-2 has pincode `56001` | SO-1, SO-3 created; SO-2 refused on its first row (`validation-failed`, the create's address detail) | — |
| Retry after timeout | same key, same file, after all 3 created | the stored response, nothing re-run | — |
| Resume after 503 | 503 after SO-1; Import again, same key | SO-1 replays (counts as created), SO-2 and SO-3 created | first call 503, detail "1 order was created…" |
| Re-upload | same file, new key | every order refused `duplicate-client-order-ref` | — |
| Key reuse | same key, another file | — | 422 `idempotency-key-reuse` |
| Overlapping runs | two same-key Imports in flight | each order created once; one run answers the response, the other its replay or 409 `conflict` | settle-once (decision 4) |
| Backorder (staff) | SO-1 asks 10, ATP 4 | created; `backorderedLineCount: 1` | — |
| Shortage (portal) | SO-1 asks 10, ATP 4 | SO-1 refused `order-backorder-rejected`; others created | — |
| Portal other client | ACME's file names BETA's SKU code | — | `unknown-sku` row error |
| Portal urgent | `priority: Urgent` | that order refused `validation-failed` (portal urgent) | — |
| Rows disagree | SO-1 rows: city `Pune`, then `Mumbai` | SO-1 refused `order-rows-disagree` on the later row | — |
| Blank after first | SO-1 row 2 leaves every ship-to cell blank | the first row's address | — |
| Caps | 2,001 rows / 201 orders / 201 lines in one order / 6 MB | — | 422 `import-too-large` (an order over 200 lines is `too-many-lines`, a row error) |
| Header | no `ship_to_pincode` column | — | 400 `missing-columns` |
| XLSX cells | `ship_by` date cell 2026-10-30; `ship_to_pincode` number 560001 | `2026-10-30`; `"560001"` | — |
| Dry run | any file | nothing written; no key needed | — |

</frozen-after-approval>

## Design Review Amendments

The design review (2026-10-24) ran a claims check (K1–K9, against origin/main wms-be `809fdb6`, wms-fe `a6fec02`) and a blind review (B1–B12), triaged in the Review Triage Log below. The amendments are recommended and were taken autonomously. **They bind over the frozen block**; where one says "supersedes decision N", that decision reads as amended.

### Runs, retries and time

**A1 — One run per import key at a time (B1, K3; supersedes decision 4's settle-once as the overlap defence).** Before Transaction A, the Import (never a dry run) takes a **lease** in Valkey: `SET order-import:{tenantId}:{importKey} <token> NX PX 60000`, released at the end by a compare-and-delete on the token (a Lua script, the reservation scripts' style), in a `finally`.
- A second run finding the lease answers **409 `import-in-progress`** at once: "This import is still running — wait a moment, then Import again to read its result." Nothing is read or written.
- The lease is new methods on `ValkeyClient` (`acquireLease(key, token, ttlMs)`, `releaseLease(key, token)`); its header comment ("ONLY atomic-decision state") widens to "atomic-decision state and short import leases". Valkey unreachable → 503 `reservation-store-unavailable` (the import cannot grant without it anyway).
- 60 s outlives the 15 s budget (A3) with margin; a run whose process died frees the key after 60 s at most.
- Why not Postgres: a session advisory lock holds a pool connection for the whole run while every order takes others (the pool-deadlock gotcha, §7e); an `xact` lock cannot span the run.
- **Settle-once stays** as a second line (lease expiry, a manual create racing the same ref), widened by K3: on **any** 4xx from an order's create, the import probes that order's derived key once (a replay call) before reporting the refusal; a committed key counts the order created.
- **Residual (PENDING):** if a lease expires under a still-running run, a staff order can still commit with a spurious backorder (both runs granted before either inserted).

**A2 — Committed orders are settled before any rule runs (B2).** In Transaction A, right after the pure parse and grouping and **before** any lookup or row rule, the import computes every group's derived key and reads the committed ones in one query (`idempotency_keys where tenant_id = $t and key = any($keys)`). Each committed group is reported **created** from its stored snapshot (staff `OrderSnapshot`: id, `clientOrderRef`, `clientId`, top-level line count and backordered count; portal `PortalPlacedOrder`: `orderId`, `lineCount`, `clientOrderRef`) and skips every rule and every call. A resume after a SKU was deactivated, a client added a shared code, or IST midnight passed re-serves what committed, as §1 requires one level up.
- So the derived key cannot depend on a lookup: its parts are `surface`, `fileSha256`, `warehouseId`, the **`client` cell as written** (trimmed, upper-cased; `''` when blank; the portal uses the session's client id) and the **normalised** `order_ref` (A4). Supersedes decision 3's `clientId` part.
- Transaction B re-reads the same keys in bulk and marks any order whose key committed as created, whatever its call answered (the B1 belt-and-braces).

**A3 — A server-side time budget (B3, K4; amends decision 6).** The import starts no new order once **15 s** have passed since the request began (`ORDER_IMPORT_TIME_BUDGET_MS = 15_000`, an injectable clock). Orders not started are reported in `notAttemptedCount` with `complete: false`; **no import key and no `order_import.executed` row are written** for an incomplete run (each created order already has its own key and audit row), and the response is **200**, not 201. The web says "{n} of {m} orders processed — Import again with the same file to finish." Import again resumes for free (A2). Why 15 s: it sits inside the API's 20 s SIGTERM drain (DEPLOY.md §71-73) and far inside the ALB's 60 s idle cut. The caps (2,000 rows, 200 orders) stay. Decision 6's "under 30 s" test becomes: the worst-case file, with an injected 2 ms latency per database query, ends either complete or `complete: false` within 17 s (budget + one order), and a second Import completes it. A dry run uses the same budget.

### Parsing and grouping

**A4 — `order_ref` is normalised before grouping and keying (B6).** `normalizeClientOrderRef` (trim; blank = absent) runs on the cell; `SO-1` and `SO-1 ` are one order. A row whose ref is blank after the trim is `missing-value`. The shape check stays the command's.

**A5 — `order_type` and `priority` are lower-cased by the parser (K2).** Trim, lower-case, then pass to the command; a value outside the vocabulary passes through (lower-cased) for the command to refuse with its own detail (`assertOrderFields`, `order.command.ts:2661-2677`). So `B2B` is accepted and portal `Urgent` gets the portal-urgent sentence.

**A6 — The row-error vocabulary, listed (B5).** `ORDER_IMPORT_ROW_ERROR_CODES`:
- the file's: `missing-value`, `unknown-client`, `unknown-warehouse`, `wrong-warehouse`, `unknown-sku`, `sku-client-mismatch`, `mixed-client`, `client-required`, `invalid-quantity`, `quantity-precision`, `invalid-rate`, `invalid-cod-amount`, `invalid-ship-by`, `order-rows-disagree`, `duplicate-sku-in-order`, `duplicate-order-in-file`, `too-many-lines`;
- the create's, passed through with its detail: `validation-failed`, `not-found`, `duplicate-client-order-ref`, `client-departed`, `client-suspended`, `sku-inactive`, `licence-not-covered`, `order-catalog-changed`, `order-backorder-rejected`;
- `order-changed-since-first-run` — a derived key answering 422 `idempotency-key-reuse` (K9): "This order was created by an earlier run of this import, and its SKUs or client now resolve differently — find it by order number {ref}." (A2 makes this unreachable for committed keys; it remains for a key written between Transaction A and the call);
- `order-refused` — any other 4xx code, with the code in the detail.
- **An order over 200 lines is the row error `too-many-lines`** on its first row; the 422 `import-too-large` caps are the file's bytes, rows and orders only (resolves the matrix vs decision 6). **The 200-order cap counts every group, refused ones included** (the ASN rule, `asn-import.parse.ts:405-410`), after A2's settled groups are counted too.

**A7 — Dates (B7).** `ship_by` accepts `YYYY-MM-DD` and an XLSX date cell whose time is 00:00; anything else is `invalid-ship-by` with "ship_by must be YYYY-MM-DD (e.g. 2026-10-30) or an Excel date cell — 30/10/2026 and 10/30/2026 are refused because they are ambiguous." **Each order is judged on the IST date its own create captures** (`licenceToday()`, `order.command.ts:476`): orders either side of IST midnight in one run are judged on different days, and a Check at 23:59 can pass an order the Import at 00:01 refuses (`validation-failed`, ship-by before today). A resume replays committed orders without re-judging them (A2). Tests: ship-by = today checked, then imported after midnight (refused); a resume on the next day (replayed).

**A8 — XLSX numbers (K9).** With `numberCells: 'excel-display'`, a numeric cell keeps at most 15 significant digits and no leading zero. The template and the panel help say: type `order_ref`, `ship_to_phone` and `ship_to_pincode` as text in Excel. A pincode is six digits and never starts with 0, so a numeric pincode cell is safe; a phone or ref with a leading 0 is not.

### The portal surface

**A9 — The portal gate is one exported function (K5).** The `gate` closure in `placePortalOrder` (`order.command.ts:734-760`) moves to an exported `assertPortalOrderGateInTx(tx, { tenantId, clientId, actorUserId })`, used by `portalOrderPlan` and by both of the portal import's transactions. Behaviour and wording unchanged.

**A10 — Two layers on the portal SKU read (B4, K7).** A new `getClientSkusByCodesInTx(tx, tenantId, clientId, codes)` in the catalog facade adds `client_id = $client` to the query; the portal import runs it in its stamped transaction, then keeps only `status = 'active' and !isKit`. The staff import keeps `getSkusByCodesInTx`. `SkuByCode.status` is still added (both need it). A `wms_rls_probe` arm runs the portal import's own write set (`audit_events`, `idempotency_keys`) and its reads (`idempotency_keys`, `skus`, `warehouses`) under the client stamp, with a positive control (§7e).

**A11 — The architecture tests, exactly (K1, K6).**
- `PORTAL_DELEGATIONS` (`test/architecture.spec.ts:2514-2537`) gains the facade's `importPortalOrders` with its one pinned statement; the controller passes `session.clientId` on one line.
- `PORTAL_WRITES` (`:2362`) gains `order-import.command.ts` → `importPortalOrders`, and its `placePortalOrder` entry is retargeted to `portalOrderPlan`; the 4-1a scan (`:2385-2420`) likewise, asserting `placePortalOrder` and `checkPortalOrder` open no transaction themselves.
- `bodyOf` (`:2310`) and `memberBody` (`:2394`) do not match a non-async `private` member: extend `memberBody` to `(?:private |public )?(?:async )?` and use it for `portalOrderPlan`; a detector-bites case covers the sync form.

### Report, web and odds and ends

**A12 — The response, completed (B9, K9).** `importId` is null on a dry run and on an incomplete run (A3). New keys: `complete: boolean`, `notAttemptedCount: number`, and per order `replayed: boolean` (settled by A2 or a probe). `backorderedLineCount` counts **top-level** lines with status `backordered` (a kit parent and its children each carry one). Every key added to these DTOs in a later story must be optional: stored import keys replay without it (§9).

**A13 — The web keeps the key for the same file (B8, partial).** The Import key is reused while the picked file has the same `name`, `size` and `lastModified` as the checked one (re-picking the same file after a timeout keeps the key), and dropped for any other file. Rejected: guessing "already imported" from a matching ship-to — the staff `duplicate-client-order-ref` detail already names the warehouse and the order id (`order.command.ts:627-637`); its label reads "Order number already used — imported before?".

**A14 — The CSV report is formula-safe (B10).** Every cell goes through `csvField` (`lib/csv`, as `lib/asn-import.ts` does); a test pins a `detail` starting `=`, `+`, `-` and `@`.

**A15 — Citations corrected (K8).** The ref's unique-index catch is `order.command.ts:1468-1475` (re-thrown after rollback at `:1603-1614`); the channel-dedup key write is `:1164-1196` (`:1188`).

**A16 — Tests added (B12).** A deterministic overlap: the import command takes an injectable per-order hook; the test parks run 1 after its first order, fires run 2 (expects 409 `import-in-progress`), then releases run 1. A resume after a SKU deactivation and after IST midnight (A2, A7). The budget arm (A3). A portal 403 mid-run (suspended between orders): the run aborts, orders already created stay and replay on the next Import after reactivation. A staff file mixing a blank client and `self`. Goldens for both import fingerprints and for the derived key.

**Rejected:** B11's one-import-per-tenant-and-warehouse lock — it would make one client's import wait for another's on a multi-client site; the portal write cap note in PENDING gains the import instead.

### Amended Boundaries

**Always (added):** the lease (A1); committed orders settle before rules (A2); the 15 s budget (A3); the gate is one function (A9); two layers on the portal SKU read (A10).

**Never (added):** no per-tenant or per-warehouse import lock; no `DD/MM/YYYY` date parsing.

### Amended matrix rows

| Scenario | Input / State | Expected | Error |
|---|---|---|---|
| Overlap (A1) | run 2 with the same key while run 1 runs | run 1 completes; run 2 nothing | 409 `import-in-progress` |
| Resume after change (A2) | SO-1 created; its SKU deactivated; Import again, same key | SO-1 `replayed: true`, the rest processed | — |
| Over budget (A3) | 200 orders, 2 ms per query | 200, `complete: false`, `notAttemptedCount` > 0, no import key; Import again completes | — |
| Ref spacing (A4) | `SO-1` and `SO-1 ` rows | one order | — |
| Case (A5) | `order_type: B2B`, staff `priority: Urgent` | `b2b`, `urgent` | — |
| Lines (A6) | one order with 201 lines | that order `too-many-lines`; others created | — |
| Midnight (A7) | ship-by today, Check 23:59, Import 00:01 | — | that order `validation-failed` |
| Date format (A7) | `ship_by: 30/10/2026` | — | `invalid-ship-by` |
| Formula (A14) | `sku: =HYPERLINK(…)` | the report cell is neutralised | — |

## Code Map

### Backend (`workspace/core/backend/wms-be`, origin/main `809fdb6`)

**Reuse, do not copy**
- `src/shared/import/sheet-reader.ts` — `readSheet` (`:123`), `MAX_SHEET_UPLOAD_BYTES` (`:39`), `importTooLarge` (`:82`); the ASN options exactly (`asn-import.command.ts:175-184`).
- `src/shared/import/upload-filter.ts` — `SheetUploadFilter` (`:17`) on both routes.
- `src/modules/inbound/asn-import.parse.ts` — `isQuantityText` (`:167`) and `quantityToMilli` (`:179`) MOVE to a new `src/shared/import/quantity-cell.ts` (outbound may not import inbound); `asn-import.parse.ts` re-exports them unchanged, and its spec passes unedited.
- `src/shared/primitives/money.ts` — `decimalRupeesToPaise` for `rate` and `cod_amount`.
- `src/modules/catalog/catalog.facade.ts:914` — `getSkusByCodesInTx` (exact, case-sensitive codes; every holder). The portal resolution needs each SKU's status: add `status` to `SkuByCode` (additive; the ASN import ignores it).
- `src/modules/clients/clients.facade.ts` — `getClientsByCodesInTx` (`:571`), `getClientLabelsInTx` (`:598`).
- `src/modules/tenancy/tenancy.service.ts` — `assertWarehouseInTenant`, `getWarehouseCodeInTx`.

**Outbound**
- `src/modules/outbound/order-import.parse.ts` (new, pure) — the column contract (`ORDER_IMPORT_COLUMNS`, per surface), required columns, caps (`MAX_ORDER_IMPORT_ROWS = 2_000`, `MAX_ORDER_IMPORT_ORDERS = 200`), `ORDER_IMPORT_ROW_ERROR_CODES`, row reading and cell refusals, grouping (decision 9), per-order cell merge (decision 8), `ship_by` grammar, the derived-key function `orderImportOrderKey(importKey, parts)`.
- `src/modules/outbound/order-import.command.ts` (new) — `OrderImportCommand.importOrders` (staff) and `.importPortalOrders` (portal): the flow in Design Notes.
- `src/modules/outbound/order.command.ts`:
  - `preflightPhase` (`:988`) takes `idempotencyKey: string | null`; null skips the replay (`:999`) and is legal only with `source: 'manual'` (the channel-dedup branch writes a key, `:1180-1194`).
  - Extract the staff surface and hash stage built inline in `createOrder` (`:474-660`) into a private `staffOrderPlan(command)`, and the portal's (`:706-845`) into `portalOrderPlan(command)`; `createOrder`/`placePortalOrder` become plan + `placeOrder`, unchanged in effect.
  - New `checkOrder(command)` / `checkPortalOrder(command)`: plan + `preflightPhase(…, null, …)`; return `{clientId, lineCount}`; the portal one also runs its licence seam (already inside `preflightPhase`, `:1260-1270`).
- `src/modules/outbound/outbound.facade.ts` — `importOrders`, `importPortalOrders` (one-line delegations, the `createOrder` style, `:518-529`).
- `src/modules/outbound/outbound.dto.ts` — `ImportOrdersDto` (`warehouseId`, `dryRun`), `OrderImportResponseDto`, `OrderImportOrderDto`, `OrderImportRowErrorDto` (`code` enum = the tuple).
- `src/api/portal.dto.ts` — `PortalImportOrdersDto`, `PortalOrderImportResponseDto` (exact keys, no `clientId`/`clientLabel`/`backorderedLineCount`).
- `src/api/outbound.controller.ts` — `POST :tenantId/outbound/order-imports` (`TenantSessionGuard`), modelled on `importAsns` (`inbound.controller.ts:342-420`): `FileInterceptor` with the size limit, `SheetUploadFilter`, dry run 200 / Import 201.
- `src/api/portal.controller.ts` — `POST :tenantId/portal/order-imports` (`PortalSessionGuard`), client from the session.
- `src/shared/valkey/valkey.client.ts` — `acquireLease` / `releaseLease` (A1).
- `src/modules/catalog/catalog.facade.ts` — `getClientSkusByCodesInTx` (A10).
- `src/modules/outbound/order.command.ts` — `assertPortalOrderGateInTx` exported (A9).
- `src/shared/primitives/audit.ts` — `order_import` in `AUDIT_TARGET_TYPES` (`:48` beside `asn_import`), `{ action: 'order_import.executed', targetType: 'order_import' }` (`:191`).

**Tests**
- `src/modules/outbound/order-import.parse.spec.ts` (unit): columns, cells, grouping, merge, derived key (deterministic, ≠ import key, differs per surface/file/client/ref).
- `test/order-import.spec.ts` (e2e, staff): every matrix row; the settle-once race (two same-key imports, `raceTwice`-style); the 503 resume (a store fault injected after the first order); `expectAuditRow` for `order_import.executed`; the 30 s worst-case timing (decision 6).
- `test/portal-order-import.spec.ts` (e2e, portal): isolation (BETA's codes), urgent, shortage, the gate (suspended mid-run → 403 abort), a staff key replayed on the portal route → 422.
- `test/architecture.spec.ts`: `PORTAL_WRITES` (`:2362`) gains `order-import.command.ts` → `importPortalOrders`; the 4-1a scan (`:2385-2420`) retargets `portalOrderPlan` for the stamp and asserts `placePortalOrder` / `checkPortalOrder` open no transaction themselves; `AUDIT_NEW_ACTIONS`.
- `test/issuance-gate-parity.spec.ts`, `test/portal-orders-create.spec.ts`: unedited, must pass (the extraction's proof).

### Web (`workspace/core/frontend/wms-fe`, origin/main `a6fec02`)
- `src/lib/order-import.ts` (new, pure — the `lib/asn-import.ts` shape): caps, columns per surface, templates, `ORDER_IMPORT_REASON_LABEL: Record<code, string>`, outcome sentences (decision 10's stock caveat; staff backorders named), the CSV error report.
- `src/components/shared/order-import.tsx` (new) — the two-step panel (`components/inbound/asn-import.tsx` behaviour: key per checked file, in-flight guard, 100 rendered errors, report download), taking `surface` and a `run(step)` prop so it imports no operator hook or component (`lib/portal-boundary.test.ts`).
- `src/lib/api/client.ts` — `fetchApiImportOrders`, `fetchApiPortalImportOrders` (the `fetchApiImportAsns` shape, `:2627`).
- `src/components/outbound/outbound-orders.tsx` — "Import from file" beside Create order (`:137`, `orders.manage`, not while drilled), keyed by warehouse; the list refreshes after an Import.
- `src/components/portal/portal-orders.tsx` — "Import from file" beside Place order (`orders.place`), with the place form's warehouse select (`usePortalWarehouses`, one warehouse needs no pick).
- `src/lib/audit.ts` — `AUDIT_TARGET_LABEL.order_import`.
- Generated client regenerated.

### Mobile
- No change (decision 14).

## Tasks & Acceptance

**Execution — wms-be:**
- [ ] `shared/import/quantity-cell.ts`, `asn-import.parse.ts` re-export — the move.
- [ ] `catalog.facade.ts` — `SkuByCode.status`, `getClientSkusByCodesInTx` (A10).
- [ ] `valkey.client.ts` — the lease and `test/order-import-lease.spec.ts` (A1; real Valkey, acquire / refuse / expire / token-checked release).
- [ ] `order.command.ts` — the plan extraction, nullable-key preflight, `checkOrder`, `checkPortalOrder`, `assertPortalOrderGateInTx` (A9).
- [ ] `order-import.parse.ts`, `order-import.command.ts`, facade, DTOs, both routes, `audit.ts`.
- [ ] Tests as in the Code Map; OpenAPI exported.

**Execution — wms-fe:**
- [ ] `lib/order-import.ts` and its test; `components/shared/order-import.tsx` and its test; `client.ts`; the two mounts and their tests; `lib/audit.ts`; generated client.

**Execution — meta (last):**
- [ ] `docs/design/modules/outbound.md` — "The order import (4-1c)": the flow, the derived key, settle-once, the abort rule, the caps and why.
- [ ] `docs/design/API-SURFACE.md` — both routes; recount.
- [ ] `docs/design/IMPLEMENTATION-GUIDE.md` — a new §7j "A batch over a multi-transaction command": derived per-item keys from the batch key, the batch key last, settle-once, abort vs per-item refusal.
- [ ] `docs/design/frontend/SYSTEM-DESIGN.md` — the two import panels.
- [ ] `docs/design/PENDING.md` — outbound: an async import for files over the caps; a stock preview in Check file; a channel export format; the lease-expiry spurious-backorder residual (A1); clients: the portal write cap now also covers 200 orders per import, and no fairness between concurrent imports (B11); inbound: the ASN and order imports' client-grouping rules differ (decision 9) — unify or keep.
- [ ] `docs/design/DEPLOY.md` §8.8 — the import's 15 s budget sits inside the 20 s drain (A3).
- [ ] `docs/design/modules/inventory.md` §Valkey — the import lease beside the reservation counters (A1).
- [ ] `docs/repos/wms-be/README.md`, `docs/repos/wms-fe/README.md`.
- [ ] `deferred-work.md` — the 4-1c entry marked done by this spec.

**Acceptance Criteria:**
- **AC1 (staff).** Given ACME's file of three orders, when staff Check then Import it on Outbound → Orders, then three ordinary manual orders exist under ACME with their client numbers, ship-to and 4-2a fields, the list shows them, and the audit trail shows three `order.created` and one `order_import.executed`.
- **AC2 (portal).** Given an ACME portal user's file, when they Check then Import it on the portal's Orders page, then the orders appear in ACME's portal list and in the staff list, and BETA sees none of them.
- **AC3 (report).** Given a file with refused rows, then the panel names each refused row's reason in words, and the downloaded CSV lists every refused row with its row number, order number, SKU, quantity, code and detail.
- **AC4 (retry).** Given an Import that failed halfway or timed out, when the user presses Import again on the same file, then no order exists twice and the result lists every order.

## Design Notes

**The flow (both surfaces; the portal's transactions stamped and gated):**
1. Above any transaction: `fileSha256`; the file fingerprint (decision 3).
2. **Transaction A** — authority (staff `orders.manage`; portal gate) → (Import) the import key's replay → the size cap → `readSheet` → the warehouse (404) and its code → resolve client and SKU codes in bulk → read rows, group, merge, cell and file rules → the order cap. Closes.
3. **Per order, in file order** — build the `CreateOrderCommand` / `PlacePortalOrderCommand` from the merged cells (SKU ids, base-unit quantities as numbers after the text rule, the address verbatim, the fields verbatim — the command normalises and refuses). Dry run: `checkOrder` / `checkPortalOrder`. Import: `createOrder` / `placePortalOrder` under the derived key, with settle-once (decision 4). A `ProblemException` 4xx → a row error; anything else → abort (decision 5).
4. Dry run returns.
5. **Transaction B** — authority again (staff re-assert; portal gate) → `order_import.executed` → the import key with the response (409 `conflict` on a concurrent winner).

**Why derived keys, not one transaction with savepoints (the ASN import's way).** An ASN insert is one statement set inside one transaction; an order's acceptance is a probe transaction, a Valkey script and a journal transaction per line, then a write transaction (`order.command.ts:432-439`). It cannot nest in a caller's transaction. Deriving each order's key from the import's makes the batch resumable for free, because the create already replays a committed key before validating.

**Why `order_ref` is required.** It is the only thing that makes a second upload of the same orders safe without a new table: the client number is unique among the client's live orders (0088), so a re-upload is refused order by order, naming the existing order.

## Verification

**Commands:**
- `bun run test -- test/order-import-lease.spec.ts src/modules/outbound/order-import.parse.spec.ts test/order-import.spec.ts test/portal-order-import.spec.ts test/architecture.spec.ts test/issuance-gate-parity.spec.ts test/portal-orders-create.spec.ts test/asn-import.spec.ts src/modules/inbound/asn-import.parse.spec.ts` (wms-be; alone, never beside another jest) — expected: pass, the budget arm within 17 s (A3).
- `bun run lint && bun run typecheck` (wms-be, wms-fe) — expected: pass.
- `bun test` (wms-fe; includes `lib/order-import.test.ts`, `lib/portal-boundary.test.ts`) — expected: pass.

**Manual checks:**
- A real HTTP smoke on the local stack: import the template's two orders on Outbound, then from the portal; wave and pick one.

## Implementation Notes

## Spec Change Log

## Review Triage Log

Design review, 2026-10-24. K = claims check against origin/main; B = blind review. Verdicts: high / medium / low / false / rejected.

| ID | Verdict | Finding → resolution |
|---|---|---|
| K1 | high | The controller-call scan allows only `PORTAL_READS` and pinned `PORTAL_DELEGATIONS` (`architecture.spec.ts:2514-2537, 2702-2710`); the spec named only `PORTAL_WRITES` → A11 |
| K2 | high | "Any case" vs "verbatim": `assertOrderFields` is case-sensitive (`order.command.ts:2665-2677`) → A5 |
| K3 | medium | Overlapping same-key runs both grant before either inserts; a portal loser is refused `order-backorder-rejected`, outside settle-once → A1 (lease), settle-once widened to any 4xx, residual in PENDING |
| K4 | medium | A 30 s request exceeds the 20 s drain (DEPLOY.md:71-73) → A3 (15 s budget) |
| K5 | medium | The portal gate is a closure inside `placePortalOrder` (`:734-760`) → A9 |
| K6 | medium | `bodyOf`/`memberBody` miss a sync `private` member; the `PORTAL_WRITES` `placePortalOrder` entry also fails after the extraction → A11 |
| K7 | low | `getSkusByCodesInTx` has no client predicate → A10 (merged with B4) |
| K8 | low | Three citations off → A15 |
| K9 | low | `backorderedLineCount` on kits; XLSX 15-digit numbers; derived-key 422 wording; re-upload costs two phase-1 runs per order (accepted, stated here) → A6, A8, A12 |
| B1 | high | Overlapping runs: spurious backorders and a stored report contradicting the orders → A1, A2 (Transaction B bulk re-read) |
| B2 | high | A resume re-runs the row rules before the derived-key replay → A2 (settle committed groups first; key from the client cell, not the resolved id) |
| B3 | high | A local 30 s budget does not protect the 60 s ALB cut → A3 (server-side 15 s budget, incomplete run, injected-latency test) |
| B4 | medium | Portal SKU read relies on RLS alone; no RLS probe arm → A10 |
| B5 | medium | The enum was unlisted; the matrix contradicted decision 6 on 201 lines; the order cap's counting unstated → A6 |
| B6 | medium | Grouping on the raw ref vs the create's trim → A4 |
| B7 | medium | Per-order IST day implicit; `DD/MM/YYYY` → A7 (refused with a named message, not parsed) |
| B8 | medium | Re-picking the same file minted a new key → A13 (partial: the ship-to heuristic rejected) |
| B9 | low | Dry-run `importId`; future DTO fields on a stored snapshot → A12 |
| B10 | low | Formula injection in the CSV report → A14 |
| B11 | rejected | A per-tenant/warehouse import lock would serialise unrelated clients on a multi-client site; noted in PENDING instead |
| B12 | medium | Missing tests (overlap hook, resume after change, budget, 403 mid-run, blank + `self`, goldens) → A16 |
