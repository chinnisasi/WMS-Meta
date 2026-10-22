---
title: '2-10a bin labels — print bin labels as ZPL (thermal) or PDF from the web, barcode = the bin code the handheld scans'
type: 'feature'
created: '2026-10-22'
status: 'ready-for-dev'
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
- [ ] BE `src/shared/labels/*` + `pdf-lib`: the encoder and decoder, escaping, folding, fit, ZPL and PDF, with unit specs (the ZPL golden, escape cases, a Devanagari zone name folding to `?`, the decoded payload equal to the code for both formats, page count and size read back with pdf-lib).
- [ ] BE `bin-labels.ts`, the DTO and the route; OpenAPI export.
- [ ] BE `test/bin-labels.spec.ts` (e2e):
  - every matrix row;
  - the sort and its ties;
  - the portal 403's exact code and detail;
  - tenant isolation;
  - route order;
  - 1000 labels as A4 PDF in under 5 s.
- [ ] Web: selection, dialog, error arms and filename, plus tests (including an IST date boundary for a viewer outside IST between 00:00 and 05:30 IST); regenerated client.
- [ ] Meta docs:
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
