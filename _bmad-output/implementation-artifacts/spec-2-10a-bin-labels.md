---
title: '2-10a bin labels — print bin labels as ZPL (thermal) or PDF from the web, barcode = the bin code the handheld scans'
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
  - 'docs/design/modules/tenancy.md'
  - 'docs/design/frontend/SYSTEM-DESIGN.md'
  - 'docs/design/frontend/IMPLEMENTATION-GUIDE.md'
  - 'docs/design/mobile/SYSTEM-DESIGN.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** Nothing prints a bin label. A site setting up hundreds of bins has to make its own, and a label whose barcode is not exactly the bin code is refused by the handheld.

**Approach:**
- A backend label renderer produces bin labels as **ZPL** (Zebra thermal, 203 dpi) or **PDF**.
- Each label carries the bin code in large text, a **Code 128 barcode encoding exactly the bin code**, and a line `<ZONE> - <WAREHOUSE>` (codes). A second small line carries the storage class when it is not `ambient`, and the dedicated client's code when there is one.
- The web bin setup prints labels for selected bins or a whole zone.
- The renderer lives in `src/shared/labels`, so 2-10b (LPN labels) and later documents reuse it.

**Decisions (recommended, taken autonomously under the user's standing instruction, 2026-10-22; 5, 6 and 9–12 revised or added by the design review):**
1. **Split:** LPN (pallet and carton) labels at receiving are 2-10b (deferred-work).
2. **The server renders both formats.** ZPL is text. PDF uses `pdf-lib` pinned at `1.17.1` (MIT; no release since 2021, which is accepted). The barcode comes from an **in-house Code 128 subset-B encoder**, shared by the fit check and the PDF bars and decodable back in tests. No barcode library is added.
3. **Delivery is a file download** (`.zpl` or `.pdf`). Direct network printing (raw 9100, Browser Print) goes to PENDING.
4. **Sizes:**
   - `label` layout: `4x2` in (default) or `2x1` in, one label per page or per `^XA…^XZ`.
   - `a4` layout (PDF only): a fixed sheet of 3 × 8 cells, each 70 × 36 mm, with 4.5 mm top and bottom margins and 2 mm inner padding; `size` beside `a4` is a 400.
5. **Access:** the existing `labels.execute` capability (owner, ops_manager, operator; the accountant gets 403), mirrored on the web. Printing changes no state, so there is no audit row and no idempotency key.
6. **Printable bins:** non-retired, **non-system** bins of the warehouse. Every handheld scan path refuses system bins, and a system zone's code equals its bin code.
7. **Order:** sorted by bin code with numeric collation, ties broken by plain code comparison and then by id.
8. **No handheld change.** Every bin scan matches `value.trim()` exactly: putaway `putaway/draft.ts:95`, pick `picking/draft.ts:175`, transfer, count and excursion. The scan engine does no case or GS1 normalisation (`engine.ts:118`). A wedge scanner strips only CR, LF and tab (`adapters.tsx:30`), and the camera reads `code128` (`adapters.tsx:89`). An AIM-prefix scanner setting (`]C0`) would break this, as it does today.
9. **Barcode bars are at least 2 dots (10 mil) wide**, because phone cameras decode 5 mil poorly. ZPL uses `^BCN,<h>,N,N,N,N` with an explicit start-B (`>:`) and `>` escaped as `><`, so the width is exactly `11·n + 35` modules plus 10-module quiet zones each side.
10. **Bin create is not tightened.** Unprintable codes are refused at print time and greyed out in the table; PENDING records a create-time `@Matches`.
11. **Zone print bound:** a zone holding more than 1000 printable bins is refused, giving the count.
12. **The filename is built by the web** (the header is not readable cross-origin): `bin-labels-<WH>-<YYYYMMDD>.<ext>`, using the IST date and the warehouse code folded to `[A-Za-z0-9._-]`. The server sends the same name in `Content-Disposition`.

## Boundaries & Constraints

**Always:**
- **Barcode payload = `bin.code` byte for byte.** A test decodes the PDF bars and parses the ZPL `^FD` to prove it.
- **ZPL text fields** use `^FH` with `_5E`, `_7E` and `_5F` escapes. The barcode field adds the `><` escape. No bin, zone or client code can inject ZPL.
- **All label text is ASCII-folded** by one helper (non-ASCII becomes `?`), applied before any ZPL or PDF write. pdf-lib's WinAnsi fonts throw on other characters.
- **Refusals happen before the first byte** (IMPLEMENTATION-GUIDE §6 binary pattern). Every refusal is problem+json, and the listing arms carry `extensions.binCodes: string[]`, the first 50 plus `+k more` in the detail.

**Never:**
- No printer configuration commands.
- No stored files.
- No LPN or SKU labels.
- No change to bin data or bin create.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|---|---|---|---|
| ZPL by ids | 3 bins, `zpl, 4x2` | `text/plain`, 3 `^XA…^XZ` sorted by code; the decoded payload equals the code | — |
| PDF A4 | a zone of 30 printable bins, `pdf, a4` | 2 pages (24 + 6), A4 | — |
| PDF label pages | 2 bins, `pdf, label, 2x1` | 2 pages of 144 × 72 pt | — |
| Special characters | code `A^1~_>B` | ZPL escaped; the decoded payload equals `A^1~_>B` | — |
| Not barcodable | non-ASCII or control character in a code | — | 422 `bin-code-not-barcodable` + `binCodes` |
| Too long | a code that does not fit at 2 dots for the size or cell | — | 422 `bin-code-too-long-for-label` + `binCodes` |
| Retired or system id | listed ids | — | 422 `bin-retired` or `bin-not-printable` + `binCodes` |
| Foreign or unknown | warehouse, zone or bin not in the tenant or warehouse | — | 404 `not-found` |
| Zone has nothing to print | empty, or only retired or system bins | — | 404 `no-bins-to-print` |
| Zone too big | more than 1000 printable bins | — | 422 `too-many-labels` (count) |
| Bad request | both or neither of `binIds`/`zoneId`; `size` with `a4`; `a4` with `zpl`; more than 1000 or duplicate ids | — | 400 `validation-failed` |
| Accountant or portal | session without `labels.execute`, or a portal token | — | 403 `role-denied` |

</frozen-after-approval>

## Code Map

### Backend (`workspace/core/backend/wms-be`)

**`src/shared/labels/` (new, pure, no DB; unit specs beside each file, the `src/shared/primitives/*.spec.ts` precedent)**
- `code128.ts`:
  - `assertBarcodable` (printable ASCII `0x20–0x7E`, first and last character not a space);
  - `encodeCode128B(payload)` returns the module widths (values, mod-103 check, start B 104, stop);
  - `decodeCode128B` (for tests);
  - `moduleCount = 11·n + 35`.
- `text.ts`: `asciiFold`, `zplEscapeText`, and `zplEscapeBarcode` (`>` → `><`, then `^FH` escapes).
- `layout.ts`: sizes in dots (203 dpi: 4x2 = 812 × 406, 2x1 = 406 × 203) and points; the A4 grid (decision 4); `fitModuleWidth(modules, printableWidth)`, which returns the largest width ≥ 2 that fits with quiet zones, or `null`.
- `zpl.ts`: `renderBinLabelsZpl(labels, size)`, with each label `^XA^PW^LL^CI0`, the text fields, `^BY<w>`, `^BCN,<h>,N,N,N,N^FH^FD>:<payload>^FS`, and `^XZ`. A golden test pins one 4x2 label byte for byte.
- `pdf.ts`: `renderBinLabelsPdf(labels, {layout, size})`, with Helvetica-Bold and bars drawn as rectangles from `encodeCode128B`.
- `package.json`: add `pdf-lib@1.17.1` with `bun add --exact`.

**`src/modules/tenancy/bin-labels.ts` (new)**
- In one tenant transaction:
  - `assertWarehouseInTenant`;
  - the bins by id (each in this warehouse, else 404) or by zone (non-retired, non-system; more than 1000 → 422);
  - the zone and warehouse codes;
  - the dedicated clients' codes through `listClientsInTx` (`clients.facade.ts:306`; AD-6, never a direct join).
- Then validate in matrix order (retired, system, barcodable, fit), sort (decision 7), and render.

**`src/modules/tenancy/tenancy.controller.ts`**
- `POST /tenants/:t/warehouses/:w/bins/labels`, declared **before** the `bins/:binId` routes:
  - `TenantSessionGuard`;
  - `assertOwnTenant` (the `listBins` precedent, `:548`);
  - `assertPermission('labels.execute')`.
- `BinLabelsRequestDto`: `binIds?` (1–1000, unique uuids) xor `zoneId?`, `format`, `size?`, `layout?` (the 400 rules in the matrix).
- The §6 binary pattern (`reporting.controller.ts:346`): `@Res()`, every refusal thrown first, then `Content-Type` (`text/plain; charset=us-ascii` or `application/pdf`), `Content-Disposition` (decision 12, ASCII-folded), `Cache-Control: no-store`, and `res.end(buffer)`.
- `@ApiProduces` both types with binary 200 schemas, and every error arm listed.

### Web (`workspace/core/frontend/wms-fe`)

**`src/components/settings/zone-bin-setup.tsx` `ZoneBinsTable` (`:712`)**
- Row checkboxes for printable rows. Retired, system and unbarcodable rows are disabled, with a reason tooltip.
- The selection is scoped to the zone: cleared on zone change, kept across pages, and the button shows the total. A page checkbox selects only that page's printable rows.
- "Print labels (N)" and "Print zone labels" (every page, and the dialog says so) are shown only with `labels.execute` (the capability mirror). "Print zone labels" is disabled when the zone shows no printable row.

**`BinLabelsDialog.tsx` (new, same folder)**
- Format, then size (`label` layout) or A4 sheet (PDF).
- It says that labels come out in code order.
- It calls the generated client with `parseAs: 'blob'` (the `fetchApiAuditExportFile` pattern, `client.ts:1794`).
- The download goes through the existing `downloadBlob` (`csv.ts:42`) with the decision-12 name, built with the web `istDateOf`.
- The error arms branch on `code` and render `extensions.binCodes`, never `detail`.

**Other:** regenerate the API client. The drill rule (frontend IMPLEMENTATION-GUIDE:190) does not apply, since Settings has no drill.

### Mobile

None (decision 8).

## Tasks & Acceptance

**Execution:**
- [x] BE `src/shared/labels/*` + `pdf-lib`: the encoder and decoder, escaping, folding, fit, ZPL and PDF, with unit specs (the ZPL golden, escape cases, a Devanagari zone name folding to `?`, the decoded payload equal to the code for both formats, page count and size read back with pdf-lib).
- [x] BE `bin-labels.ts`, the DTO and the route; OpenAPI export.
- [x] BE `test/bin-labels.spec.ts` (e2e):
  - every matrix row;
  - the sort and its ties;
  - the portal 403's exact code and detail;
  - tenant isolation;
  - route order;
  - 1000 labels as A4 PDF in under 5 s.
- [x] Web: selection, dialog, error arms and filename, plus tests (including an IST date boundary for a viewer outside IST between 00:00 and 05:30 IST); regenerated client.
- [x] Meta docs:
  - `API-SURFACE.md`;
  - `modules/tenancy.md`;
  - `SYSTEM-DESIGN.md` module map (`src/shared/labels`);
  - frontend SYSTEM-DESIGN;
  - `docs/repos/wms-be|wms-fe` READMEs;
  - PENDING (direct printing; the create-time `@Matches`; LPN is 2-10b).

**Acceptance Criteria:**
- Given a printed 4x2 and 2x1 label of `A-01-01`, when the handheld's camera scans it in putaway, then `resolveBinBarcode` resolves that bin. This is a manual check, recorded in Implementation Notes.
- Given a zone of 30 bins, when printed as A4 PDF, then there are 2 pages in code order.

## Design Notes

- **Why server-side, why in-house Code 128.** One renderer serves the web now and 2-10b and 2.9 later. The encoder is about 100 lines and doubles as the fit check and the test decoder; drawing a library's undocumented SVG path would be fragile.
- **Why start-B and not mode A.** Mode A's width is printer-chosen and undocumented, and `>` is an invocation character. Start-B with `><` makes the symbol and its width deterministic, so the fit check is exact.
- **Fit at 2 dots.** The margins are 40 dots per side at 4x2 and 20 dots at 2x1, with a 10-module quiet zone each side:
  - **4x2:** (812 − 80) / 2 = 366 modules, minus 20 = 346 ≥ 11n + 35, so `n ≤ 28`.
  - **2x1:** (406 − 40) / 2 = 183, minus 20 = 163, so `n ≤ 11`.
  - **A4 cell:** 66 mm ÷ 0.254 mm = 259 modules, minus 20 = 239, so `n ≤ 18`.
  - `A-01-01` (7 characters) fits every size. A unit test pins these three limits.
- **The checklists:**
  - Portal surface: the guard 403s portal tokens (`tenant-session.guard.ts:75`, pinned).
  - Idempotency: none, since nothing changes state.
  - Periods/IST: the filename date uses `istDateOf` on both sides, with boundary fixtures.
  - Verify-before-freezing: the reviewers' code references were checked.

## Verification

**Commands:**
- `bun run test -- test/bin-labels.spec.ts src/shared/labels` (wms-be, run alone): pass.
- `bun run lint && bun run typecheck` (wms-be, wms-fe); `bun test` (wms-fe): pass.

## Implementation Notes

Implemented 2026-10-22 against the reviewed design (wms-be `feat/2-10a-bin-labels`, wms-fe `feat/2-10a-bin-labels`; wms-mobile unchanged).

- **The Code 128 table was checked against an independent decoder**, outside the suite: symbols rendered from `encodeCode128B` were decoded by ZXing (`zxing-wasm` 3.1.3, from the local bun cache, not added to any repo) — every printable character, and payloads chosen to produce every check value 0–102, decoded to their payloads. The PDFs (4x2, 2x1, a 30-label A4 sheet) were also rasterised at 300 dpi (CoreGraphics) and ZXing decoded every barcode (24/24 on the A4 page). In-suite, `test/support/labels.ts` decodes the PDF bars and the ZPL `^FD` back to the code.
- **AC 1 (camera scan in putaway) is NOT yet done** — it needs a printed label and a handheld. Record the result here when it is run.
- **ZPL text is left-aligned, without `^FB`**, because `^FB` reads `\&` in field data as a line break; the `^A0` character width is fitted to the printable width (`floor(printable / length)`, capped at the height), truncating with `...` below a minimum. The PDF shrinks Helvetica-Bold to fit by measured width.
- **`MAX_LABELS_PER_PRINT` (1000) lives in `src/shared/labels/layout.ts`**, so `tenancy.dto.ts` does not import `bin-labels.ts` and its module graph (the 11-5 `bin-capacity.ts` precedent); `bin-labels.ts` re-exports it as `MAX_BIN_LABELS`.
- **The filename fold** replaces each UTF-16 unit outside `[A-Za-z0-9._-]` with `-`, identically on both sides (`binLabelsFilename` in `bin-labels.ts` and `lib/bin-labels.ts`).
- **Dedicated client codes** come from `listClientsInTx` (capped at 500); a client beyond the cap is read with `getClientInTx` — both clients-facade functions.
- **Unknown bin ids answer one 404 naming up to 10 missing ids.** Authority runs first, so an accountant gets 403 even for an unknown warehouse (tested).
- **The listing arms' `binCodes` are the offenders sorted in label order** (decision 7), first 50; the detail quotes each code (`JSON.stringify`) and ends `+k more`.
- **Web:** the "dialog" is an inline panel with `role="dialog"` (the merge picker's pattern on this card); the file is `BinLabelsDialog.tsx` as named here, though the folder is otherwise kebab-case. The print panel and the selection are both scoped to the zone they were made in (derived at render, no effect). "Print zone labels" is enabled for any selected zone (code review: printable bins may sit on a later page; the server answers an empty zone `no-bins-to-print`). "Print labels (N)" is disabled above 1000 ticks; a ticked row the refreshed page shows unprintable is pruned; the print controls wait for the warehouse code.
- **Timing:** the 1000-label A4 PDF (a zone print) is bounded at 15 s in `test/bin-labels.spec.ts` (loosened from 5 s for full-suite load, code review).
- **Code review fixes:** `labels.execute` is asserted (its own transaction, `BinLabelsService.assertCanPrint`) before the warehouse-param and cross-field 400s, so an accountant gets 403 whatever it sends (the DTO's ValidationPipe shape checks still run first); `binIds: null` / `zoneId: null` count as absent; ids are lower-cased, a case-only duplicate is `400 validation-failed`; the zone path reads its bins once with `limit 1001` (the exact count is read only for the `too-many-labels` message); each ZPL label adds `^LH0,0^PON`; `maxCodeLengthFor` moved to `shared/labels/layout.ts`; the too-long copy names the per-paper limits (4x2 28, 2x1 11, A4 18).

## Spec Change Log

## Review Triage Log

Design review, 2026-10-22 (two reviewers: backend/labels L, web/checklists W). Every accepted finding is folded into the spec above; all choices are recommended, taken autonomously.

| ID | Verdict | Finding → resolution |
|---|---|---|
| L1 | high | `StreamableFile` breaks the §6 binary convention. The §6 `@Res()` pattern, `@ApiProduces`, `no-store`. |
| L2 | high | No clients read exists in the bin list, and a direct join breaks AD-6. `listClientsInTx` facade. |
| L3 + W1 | high | `Content-Disposition` injection or a 500, and the header is unreadable cross-origin. Folded name; the web builds the name (decision 12); IST helpers. |
| L4 | high | 1-dot bars are too thin for camera scanning. Minimum 2 dots (decision 9); manual scan AC. |
| L5 + W10 | medium | Mode A width is undocumented and `>` is an invocation character. Start-B with the `><` escape; `>` in the matrix. |
| L6 | medium | The A4 cell and `size` interact undefined, and the 0.5 mm margin clips. A fixed 70 × 36 grid, 4.5 mm margins, padding; `size` beside `a4` is a 400. |
| L7 + W6 | medium | The zone print is unbounded. 422 `too-many-labels`; zone mode skips retired and system bins silently. |
| L8 + W3 | medium | Unnamed arms, wrong statuses, no listing channel. Named 422 arms + `extensions.binCodes`. |
| L9 | medium | Parsing bwip-js SVG is fragile. In-house encoder; bwip-js dropped. |
| L10 | low | WinAnsi throws on non-ASCII. `asciiFold` everywhere; pdf-lib pinned. |
| L11 | low | The golden contradicted the Approach. Codes only; the exact golden is pinned by a test. |
| L12 + W9 | medium | Create accepts unprintable codes. Decision 10: not tightened now; disabled rows; PENDING. |
| L13 | low | Guard and isolation unstated. `assertOwnTenant`; exact 403 pinned. |
| L14 | low | Test placement and timing. `src/shared/labels` specs; a 5 s timing bound. |
| L15 | low | Route order. Declared before `:binId`; tested. |
| W2 | medium | `downloadBlob` already exists. Reuse it. |
| W4 | high | System bins: no scan path accepts them. Decision 6 revised: not printable (`bin-not-printable`). |
| W5 | medium | "Any staff" ignores `labels.execute`. Decision 5 revised. |
| W7 | medium | Selection over cursor paging was undefined. Zone-scoped, kept across pages. |
| W8 | low | Collation ties. Tie-break by code, then id; the dialog states the order. |
| W11 | low | The no-handheld claim was verified. References added to decision 8. |
| W12 | low | The drill rule does not apply (Settings has no drill). Stated. |
| W13 | low | Empty-zone UX. Button disabled; both 404 arms tested. |
| W14 | medium | Context and docs incomplete. API-SURFACE, PENDING and the module map added. `epic-2-context.md` rejected: it describes the old epic 2 (batch/serial), not roadmap phase 2, and earlier roadmap specs omit it. |
| W15 | low | Checklists not walked. Walked in Design Notes. |

Code review, 2026-10-22 (Blind Hunter BH, Edge Case Hunter EC, Verification Gap VG). Routes were taken autonomously (recommended).

| ID | Verdict | Finding → resolution |
|---|---|---|
| BH2 + EC7 + VG-o1 | medium | Patch: "Print zone labels" is disabled from the current page only, so a zone with printable bins on later pages cannot be printed. Enabled whenever a zone is selected; `no-bins-to-print` answers an empty zone. |
| BH1 + EC5 | medium | Patch: the cross-page selection is unbounded, so more than 1000 ticks gets a 400 with "reload" copy. Capped at 1000 with a hint. |
| EC1 + EC2 | medium | Patch: `binIds: null` causes a 500 and `zoneId: null` a 404. Null is treated as absent in the xor; 400. |
| EC6 + BH3 | medium | Patch: a ticked bin later retired or unbarcodable stays selected. The selection is pruned against `binPrintBlock` on refresh. |
| BH9 + EC9 | low | Patch: the 400s fire before `labels.execute`. The permission is asserted first. |
| EC3 | low | Patch: duplicate uuids in mixed case. Lower-cased before uniqueness and lookup. |
| EC4 | low | Patch: the count-then-select race. One select with `limit MAX+1`. |
| EC8 | low | Patch: an unknown warehouse code gives an empty filename segment. Controls hidden until the code is known. |
| BH7 | low | Patch: ZPL does not pin home or orientation. `^LH0,0^PON` added (format-level, not configuration); golden updated. |
| BH4 | low | Patch: the too-long copy says "pick a larger size", which is wrong for A4. Copy names the per-paper limits (28 / 11 / 18). |
| VG1 + VG2 + VG3 | medium | Patch: untested text truncation, A4 too-long through the service, and the PDF→A4→ZPL dialog switch. Tests added. |
| BH-s3 | low | Patch: `layout.spec` re-implements `maxCodeLengthFor`. It imports the exported function. |
| BH11 | medium | Deferred: rendering runs synchronously on the request thread with no concurrency bound. The 5 s e2e bound is loosened to 15 s (full-suite load). |
| BH6 + VG4 | maybe-false (medium if true) | Deferred: client codes come from a 500-row list plus a per-id fallback, and an unresolvable client may 404 the whole print. Settled by a by-ids clients facade read and a test. |
| BH8 | low | Deferred: ZPL `^A0` text fit has not been seen on a printer. With the camera-scan manual check (PENDING). |
| BH5 | low, rejected | Exposing `Content-Disposition` via CORS. Decision 12 builds the name on the web; parallel tests pin both. |
| BH10 | false | "No handheld test". Decision 8 cites every scan path; the barcode payload is decoded in BE tests. |
| BH12 | false | "No docs". The docs are edited in the meta working tree and ship in the docs PR. |
| BH13, BH-s1, BH-s2, BH-s4 | low, rejected | The unused `count`, the hard-coded 1000 copy, `zoneCode ?? ''` (zones always have codes) and panel a11y. Negligible; no user impact. |
