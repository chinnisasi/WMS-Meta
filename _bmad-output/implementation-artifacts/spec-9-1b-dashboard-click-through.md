---
title: 'Dashboard click-through — every Overview tile lands on a screen showing exactly its rows'
type: 'feature'
created: '2026-10-12'
status: 'done'
route: 'dispatch'
baseline_commit: 'b1fe9425e0538438d10103642e0d31ff72a075f4'
review_loop_iteration: 0
context:
  - '_bmad-output/implementation-artifacts/epic-9-context.md'
  - '_bmad-output/implementation-artifacts/spec-9-1-operational-dashboard.md'
  - 'docs/design/modules/reporting.md'
  - 'docs/design/frontend/SYSTEM-DESIGN.md'
  - 'docs/design/frontend/IMPLEMENTATION-GUIDE.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** 9-1 (decision 3) gave every Overview tile a `drill`: an API list route plus its exact query. Tile links carry the query in the `href` (`lib/drill-routes.ts`). But the click-through screens ignore it (PENDING `reporting` :295):
- No screen reads search params.
- `/inventory` is a placeholder, though four tiles link there.
- Several screens cannot send the drill's filters, and several force a filter of their own (outbound `statusFilter`; the e-way, over-receipt and batch-alert tabs).
- The putaway tile lands on `/inbound`, which has no putaway list.
- The link drops the drill's API path, so a path-scoped drill loses its warehouse. On `/compliance` and `/inbound`, different drills arrive with identical keys.

**Approach:** Frontend only; every backend route and filter already exists.
- **Tile links say exactly which list and warehouse they mean.**
- **Each target reads its drill and lists exactly those rows,** filtered server-side, under a banner with Clear.
- **New surfaces:** a Ledger page, and a putaway-tasks list.

**Decisions (human, 2026-10-12):**
1. **Banner + Clear.** A drilled screen lists exactly the tile's rows, under a read-only banner naming the filter. Clear returns to the normal view. There are no editable filter controls.
2. **The drill's warehouse, for that view only.** The active warehouse is not changed, and Clear returns to it.
3. **The Ledger at `/inventory/ledger`.** `/inventory` stays a placeholder with a link to it.
4. **A read-only "Awaiting putaway" list on `/inbound`** is the putaway tile's target.
5. **(review) No link for roles that can't see the target.** The GRN-variance tile's over-receipt drill shows no link for a role without `review.decide`.
6. **(review) The putaway list always shows** on `/inbound`, for the active warehouse, and the tile drills into it.
7. **(code review, 2026-10-12) Actions in drilled mode.** Per-row actions that apply to their row stay: approve/reject an over-receipt, confirm/cancel an order, resolve/dismiss an alert, e-way row actions on a pending bill. Bulk selection and downloads, and page-level create forms (create order, generate invoice), are hidden while drilled.

## Boundaries & Constraints

**Always:**
- **Links (`lib/drill-routes.ts`).** `drillHref` adds two keys to the drill's query:
  - **`list`:** a section discriminator, one of `ledger`, `orders`, `over-receipts`, `grns`, `putaway`, `batch-alerts`, `eway`, `invoices`. It is always present.
  - **`warehouseId`:** taken from the API path, for path-scoped drills (`warehouses/{w}/…`), unless the query already has one.

  `inventory/events` maps to `/inventory/ledger`. The three no-screen drills stay unlinked (C13). `drillLinkHref(drill, capabilities)` returns `null` for the over-receipt drill without `review.decide` (decision 5). The 9-1 tiles' hrefs change as a result; this supersedes 9-1's "links carry only the drill query".
- **Pattern** (the house rule; record it in FE IMPLEMENTATION-GUIDE §1):
  - **Parsing.** The route's server `page.tsx` awaits `searchParams` (a Promise in Next 16; each value `string | string[]`) and calls the pure `parseDrill(screen, params)` in `lib/drill.ts`. That returns a typed drill, `null` (no drill keys), or **unsupported**.
  - **Unsupported:**
    - an unknown key;
    - a repeated single-valued key;
    - a malformed value (UUID, instant, enum, boolean);
    - a `list` this screen does not serve.
  - **Lawful shapes:** `to` without `from` is lawful (live drills). `type` is a one-element list. Booleans parse from `'true'`/`'false'`.
  - **Render.** The page renders `<Screen key={drillKey(drill)} drill={drill} />`, where `drillKey` is a canonical string (`'none'` without a drill). Clear's soft navigation therefore **remounts** the screen, so no drilled cursor, cached result or `DataTable` stack survives.
  - **Router access.** `useRouter` and `usePathname` are used **only inside `DrillBanner`**, which renders only in drilled mode. Existing screen tests that import screens statically keep working.
- **Drilled mode, on every target:**
  - **Server-side only.** The list hook receives the whole drill filter and sends exactly its keys (minus `list`). It **ignores the screen's tab, status and kind state** (outbound `statusFilter`; the e-way tab; the over-receipt status tab; the batch-alert kind and status). Those controls, the outbound warehouse picker, and the e-way selection and bulk actions are hidden.
  - **Paging.** The cursor is passed back verbatim, on the screen's **existing** paging (`DataTable` Prev/Next, or the queues' Next-only). The putaway list is unpaged (its route returns `{items}`).
  - **Warehouse.** The drill's `warehouseId` goes into the path for path-scoped routes and the query otherwise. `lib/warehouses` is never written.
  - **One drilled section.** On a multi-section screen, only the section named by `list` is drilled; the others render normally. On `/conflicts`, a drill selects the over-receipts tab. If that tab is unavailable to the role, the screen shows "This list isn't available to you" (defensive; links are withheld by decision 5).
  - **The banner.** `DrillBanner({ description, onClear })` in `components/shared/`. The text comes from a pure `describeDrill(drill, warehouses)` in `lib/drill.ts`:
    - a label table for `type`, `status`, `kind`, `source`, `blind` and `backordered`;
    - dates shown in IST (`timeZone: 'Asia/Kolkata'`), display-only, so the sent instants are untouched;
    - "as of {to}" when `from` is absent;
    - the warehouse by name, or its short id when unknown.
  - **Unsupported drill:** the normal view, plus "This link's filter can't be shown here".
- **Fetch wrappers.** These gain optional params matching the backend DTOs, and nothing more:
  - `fetchApiListOrders`: status, source, backordered, from, to;
  - `fetchApiListOverReceipts`: warehouseId, from, to, with status optional;
  - `fetchApiListGoodsReceipts`: blind, from, to;
  - `fetchApiListBatchAlerts`: from, to, with kind and status optional;
  - the e-way list: warehouseId, source, from, to, with status optional;
  - `fetchApiListInvoices`: warehouseId, from, to;
  - `fetchApiListLedgerEvents`: type, from, to, skuId, orderId, shortPick.

  Plus a new `fetchApiListPutawayTasks(tenantId, warehouseId)`. Non-drilled callers are unchanged.
- **Ledger page** `app/(app)/inventory/ledger/page.tsx` → `components/inventory/ledger.tsx`:
  - **Source:** `GET warehouses/{w}/inventory/events`, newest first, `DataTable` Prev/Next. It shows the active warehouse without a drill, and the drill's warehouse and filter with one.
  - **Columns:**
    - recorded at, shown in IST;
    - type, using the label table;
    - SKU code, from `useSkuMap`;
    - quantity, signed via `quantityLabel`, as at `variance-queue.tsx:457-460`;
    - from bin → to bin, from `useBinCodeMap(<shown warehouse>)`;
    - batch/serial as a short raw id;
    - actor, from `useUserMap`;
    - reference: `kind` plus the typed `LedgerReferenceDocDto` fields that are present, with no untyped casts.
  - **No warehouses:** "Create a warehouse first".
- **Putaway section** on `/inbound`, "Awaiting putaway", always shown for the active warehouse (decision 6):
  - **Columns:** `grnCode`, `skuCode`, `batchCode`, quantity (`quantityLabel(qty, sku)`; `qty` = min(applied, Receiving on-hand)), and `suggestedBin.binCode` or "—".
  - **Behaviour:** read-only and unpaged; the drill scopes it to the drill's warehouse with the banner. A failed read uses the shared failure rendering; an empty list reads "Nothing awaiting putaway".
- **Tests:**
  - **`lib/drill.test.ts`:**
    - every linked drill shape from `drill-routes.test.ts`, including `to`-only and path-scoped: `drillHref` → `parseDrill` → the request the hook sends carries **exactly** the drill's keys and values (order-insensitive, `list` excluded) and the right path warehouse;
    - each unsupported rule;
    - a `describeDrill` table.
  - **`drill-routes.test.ts`:** `list` and path `warehouseId` added; the `/inventory/ledger` row; the decision-5 null link.
  - **Per screen** (`mock.module('next/navigation')` first, then a dynamic import, as in `portal.test.tsx:36-47`):
    - drilled mode sends the server filter, and **no** forced status, kind or tab;
    - the controls are hidden;
    - the banner names the filter and the warehouse;
    - drill → Next → Clear makes a first request with **no cursor** and no filter;
    - the active warehouse is unchanged.
  - **Ledger and putaway:**
    - the Ledger columns, plus paging with a verbatim cursor;
    - the putaway list renders always, scoped by a drill, and in its empty and failed states.
  - **Overview:** tile hrefs start `/inventory/ledger?…list=ledger`, and no over-receipt link appears without `review.decide`.
- **Docs:**
  - `frontend/SYSTEM-DESIGN.md`: the route map (`/inventory/ledger`, the `/inbound` putaway section, the `/conflicts` drilled tab) and `:44`;
  - `frontend/IMPLEMENTATION-GUIDE.md` §1: the drill pattern, including the remount key, router-in-banner-only, and server-only filtering;
  - `modules/reporting.md`: click-through done; links carry `list` and the warehouse;
  - `PENDING.md`: close `:295`;
  - `docs/repos/wms-fe/README.md`.

**Never:**
- a backend change;
- editable filter controls;
- writing the active warehouse;
- client-side filtering in drilled mode;
- decoding or rebuilding a cursor;
- re-formatting sent instants;
- links for the three no-screen drills;
- a new nav entry.

## I/O & Edge-Case Matrix

| Scenario | Input | Expected | Error |
|---|---|---|---|
| Tile click | Any linked tile | The target section lists exactly the drill's rows (server-filtered), under a banner | — |
| Same keys | E-way, invoices or manual-pricing share | `list` picks the section | — |
| Path warehouse | An outbound or ledger drill | The drill's warehouse in the path, named in the banner | — |
| Live drill | `to` only | Accepted; the banner reads "as of …" | — |
| Paging | Rows span pages | Next sends the opaque cursor | — |
| Clear | Banner Clear after Next | Remount; first request has no cursor or filter; active warehouse | — |
| Forced tabs | Over-receipt, batch-alert or e-way drill with no status | No status or kind sent; the controls hidden | — |
| Role | No `review.decide` | No over-receipt link on the tile | — |
| Unsupported | Unknown key, repeat, malformed value, wrong `list` | Normal view + "can't be shown here" | — |
| No drill | A plain visit | Unchanged, except the always-on putaway section | — |
| Ledger | `/inventory/ledger` | The active warehouse's recent events | — |
| Putaway | `/inbound` | "Awaiting putaway" for the active warehouse; the tile drills it | — |

</frozen-after-approval>

## Code Map

Paths are relative to `workspace/core/frontend/wms-fe/src`; backend references are relative to `workspace/core/backend/wms-be/src`.

- **Drills:**
  - `lib/drill-routes.ts:18-50`, `lib/drill-routes.test.ts:9-62`;
  - BE `modules/reporting/kpis.ts` (drill builders `:258-290`; drills `:318,402-433,477-490,547-563,625-632,698-705,800,867-872,926-944`; `Drill.query: Record<string,string>` `:55`);
  - `components/overview/overview-dashboard.tsx` and its test `:51`.
- **Screens and hooks:**
  - **Outbound:** `components/outbound/outbound.tsx:122` (the picker writes the active warehouse), `outbound-orders.tsx:512,536`, `lib/use-outbound-orders.ts:40,55-58`, `client.ts:1822`; BE `api/outbound.controller.ts:452-489`.
  - **Over-receipts:** `components/conflicts/queues.tsx:43-44,76-77`, `over-receipt-queue.tsx:77-78,179-188`, `lib/use-inbound.ts:275`, `client.ts:1667`; BE `api/receiving.controller.ts:255-283`.
  - **Goods receipts:** `components/inbound/inbound-cards.tsx:236`, `lib/use-inbound.ts:160,663` (`useBinCodeMap`), `client.ts:1645`; BE `api/receiving.controller.ts:209-253`.
  - **Putaway:** BE `api/putaway.controller.ts:112-140`, `modules/putaway/putaway.dto.ts:231-240`; generated types `types.gen.ts:3120-3143`.
  - **Batch alerts:** `components/replenishment/replenishment-view.tsx:504-506,634`, `lib/use-replenishment.ts:391`, `client.ts:3060`; BE `api/replenishment.controller.ts:384-410`.
  - **E-way:** `components/compliance/eway-bills.tsx:109-118`, `lib/use-eway.ts:95-123`, `client.ts:2422`; BE `api/eway.dto.ts:28-71`.
  - **Invoices:** `components/compliance/invoices.tsx:85`, `client.ts:2331`; BE `api/invoicing.controller.ts:103-128`.
  - **Ledger:** `client.ts:2789-2810`, `lib/use-variance-queue.ts:146`, `components/conflicts/variance-queue.tsx:405-460` (the signed-quantity and user-map models); BE `api/inventory.controller.ts:607-645`, `modules/inventory/inventory.dto.ts:241-320`; `LedgerEventDto` `types.gen.ts:1248-1277`, `LedgerReferenceDocDto` `:1208-1245`.
- **Shared:**
  - `components/data-table/data-table.tsx:57`;
  - `components/shared/surface.tsx`, `shared/warehouses-failure.tsx`;
  - `lib/warehouses.ts:21-36`;
  - `lib/invoices.ts:146` (the IST formatter);
  - `app/(auth)/login/page.tsx:10-14` (the async `searchParams` prop);
  - `navigation.ts:41` (`review.decide`).
- **Tests:** `components/portal/portal.test.tsx:36-47` (`mock.module` then a dynamic import); `components/settings/rate-cards-card.test.tsx:147` (request capture); happy-dom is preloaded through bunfig.

## Tasks & Acceptance

**Execution:**
- [x] `lib/drill-routes.ts` (+ test) -- `list` + path `warehouseId`; `/inventory/ledger`; capability-aware link.
- [x] `lib/drill.ts` (+ test) -- `parseDrill`, `drillKey`, `describeDrill`, the unsupported rules.
- [x] `components/shared/drill-banner.tsx` -- the banner (the only router user).
- [x] `lib/api/client.ts` -- the wrapper params + `fetchApiListPutawayTasks`.
- [x] Hooks and screens -- outbound, conflicts/over-receipts, inbound (goods receipts + the putaway section), replenishment batch alerts, compliance e-way + invoices: drilled mode, hidden controls, remount key from each `page.tsx`.
- [x] Ledger page + component + hook; the `/inventory` placeholder link.
- [x] Overview -- capability-aware links.
- [x] Tests and meta docs per Boundaries.

**Acceptance Criteria:**
- Given an Overview tile whose drill reconciles, when it is clicked, then the target section paged to the end lists exactly the figure's rows, under a banner naming the filter and warehouse.
- Given the full FE suite, typecheck, lint and the capability mirror, when run, then they pass.

## Implementation Notes

Baseline: wms-fe `b1fe9425e0538438d10103642e0d31ff72a075f4` (`baseline_commit`). Frontend only.
- Work on `feat/9-1b-dashboard-click-through` in wms-fe (already checked out). Leave everything uncommitted: no commit, push or PR.
- In wms-fe, `bun test`, `bun run typecheck`, `bun run lint`, `bun run check:capability-mirror` and `bun run build` are the checks.
- Edit meta docs in `/Users/sasidhar/Documents/WMS-Meta` (uncommitted, on the current branch).
- Do not touch wms-be or wms-mobile.

## Spec Change Log

## Review Triage Log

Design review (2026-10-12), two lenses: drill mapping (D) and screens and tests (S).

| # | Lens | Finding | Verdict | Disposition |
|---|---|---|---|---|
| 1 | D, S | `/compliance` drills (e-way, invoices, manual-pricing share) share identical keys; `/inbound` putaway is a subset of goods receipts | high — verified, `kpis.ts:926,943,944,410,484` | Fixed: a `list` discriminator in the link |
| 2 | D | Path-scoped drills (outbound, ledger) lose their warehouse: `drillHref` drops `apiPath` | high | Fixed: the link carries `warehouseId` |
| 3 | D, S | The over-receipt and batch-alert queues force a status/kind too; their hooks require them | high | Fixed: drilled hooks take the whole filter; tabs ignored and hidden |
| 4 | S | Clear's soft navigation keeps the drilled cursor, cache and `DataTable` stack | high | Fixed: a remount key; a Next → Clear test |
| 5 | S | Existing screen tests break if screens call `useRouter` | high | Fixed: the router only in `DrillBanner` |
| 6 | D, S | The putaway list has no wrapper and is unpaged; field names | medium | Fixed: the wrapper; unpaged; exact fields |
| 7 | D, S | Ledger column sources unspecified; `referenceDoc` partly typed | medium | Fixed: sources named; typed fields only |
| 8 | D, S | Over-receipt tab gated by `review.decide`; the Overview is open to all | medium | **Human decision 5** (no link); a defensive notice |
| 9 | S | The putaway section's no-drill behaviour undefined | medium | **Human decision 6** (always shown) |
| 10 | S | No banner copy rules | medium | Fixed: `describeDrill` + table tests |
| 11 | S | The outbound picker writes the active warehouse | medium | Fixed: hidden in drilled mode |
| 12 | S | Not every target uses `DataTable` paging | medium | Fixed: "the existing paging" |
| 13 | D | `to` without `from` is lawful (live drills) | low | Fixed |
| 14 | D, S | "Repeated `type`" is unreachable; value parsing rules missing | low | Fixed: one-element type; repeats unsupported; booleans parsed |
| 15 | S | E-way bulk selection in drilled mode | low | Fixed: hidden |
| 16 | D | Code Map path for the inventory DTO | low | Fixed |
| 17 | S | Overview test and docs gaps | low | Fixed |

**Code review (2026-10-12)** — Blind Hunter (B), Edge Case Hunter (E), Verification Gap (V); 31 raw findings, 21 distinct.

| # | Layer | Finding | Verdict | Route |
|---|---|---|---|---|
| C1 | B, E | A query `warehouseId` on a path-scoped drill overrides the path's, moving the request off the figure's warehouse; a test locks it in | high — verified, `drill-routes.ts` | patch: the path wins; a conflicting pair gets no link |
| C2 | B | Write actions in drilled mode are inconsistent across screens; no rule | medium | **human decision 7**; patch |
| C3 | V, B | No test runs a real `page.tsx`; the screen tests rebuild the key and parse themselves; `UnsupportedDrillNotice` is never rendered | high — pre-verified gap | patch: `pages.test.tsx` |
| C4 | E | The drilled GRN list says "No receipts match this figure" while loading or after a failed read (a false zero) | high — the hook swallows errors | patch: loading text + a failed arm with Retry |
| C5 | B, E | Conflicts' queue tabs stay clickable while drilled, so the drill persists off-screen with no banner; the replenishment picker stays | medium | patch: hidden while drilled |
| C6 | E | An unrelated param (`utm_source`) on a target route makes a plain visit "Link not applied" | medium | patch: with no `list`, unknown keys are ignored |
| C7 | B, E | The Ledger shows "Create a warehouse first" or a warehouse failure for a valid drill | medium | patch: the drilled branch is independent of the active warehouse |
| C8 | V | The drilled e-way test has no rows, so the hidden selection and row actions are never observed | medium — pre-verified | patch: one non-pending bill |
| C9 | B, E | Four warehouse-label formatters disagree; an unknown drill warehouse shows "Pick a warehouse" | low | patch: one shared label helper |
| C10 | B, E | "Awaiting putaway" never refreshes after a change on `/inbound` | low | patch: subscribe to the inbound-changed event |
| C11 | B, E | The instant check accepts impossible days | low | patch: round-trip check |
| C12 | B | Drilled lists spanning statuses don't say so | low | patch: "all statuses" in the banner |
| C13 | B | `DrillBanner` vs `DrilledBanner` across two folders; a dead `onClear` | low | patch: consolidate |
| C14 | B | The tests' `DRILL_ONLY_KEYS` omit ledger keys; no ledger shape uses `skuId`/`orderId`/`shortPick` | low | patch |
| C15 | B | The outbound picker test doesn't assert the picker in the normal view | low | patch |
| C16 | B | The ledger `type` union is hand-copied in `client.ts` | low | patch: the generated type |
| C17 | E | Effects depend on the drill object, so they refetch on every server refresh | low | patch: depend on `drillKey` |
| C18 | B | Doc gaps: the dynamic render, and the "Adding a drill target" checklist | low | patch |
| C19 | V | The frontend drill shapes are a hand copy of the backend's `kpis.ts`; a new backend key breaks a tile silently | medium — a cross-repo contract | defer |
| C20 | B | The Channels link has no `list` | low — nothing to filter; it links to the bare route | reject (recorded) |
| C21 | B | The banner re-fetches the warehouse list | low — cached by the hook | reject |

## Design Notes

- **Why the link carries `list` and the warehouse.** `drillHref` drops the API path, which was the only thing distinguishing three `/compliance` drills and the only carrier of the warehouse for path-scoped drills. Putting both in the URL keeps the link self-describing: shareable, and immune to the active warehouse.
- **Why a remount key.** Soft navigation keeps client state. Without the key, Clear would page the unfiltered list with a cursor minted by the filtered query.
- **Why an unknown key makes the whole drill unsupported.** A partially applied filter shows rows that are not the figure's. The normal view plus a notice is honest.
- **Why server-side only.** `reporting.spec.ts` proves the backend drill, paged to exhaustion, equals the figure. Any client-side narrowing breaks that.
