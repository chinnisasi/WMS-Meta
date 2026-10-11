---
title: 'Epic-21 frontend hardening — one charge-label source, honest failed warehouse reads, and a portal that imports no operator hook'
type: 'refactor'
created: '2026-10-12'
status: 'ready-for-dev'
route: 'dispatch'
review_loop_iteration: 0
context:
  - '_bmad-output/implementation-artifacts/epic-21-context.md'
  - '_bmad-output/implementation-artifacts/epic-21-retro-2026-10-10.md'
  - 'docs/design/frontend/SYSTEM-DESIGN.md'
  - 'docs/design/frontend/IMPLEMENTATION-GUIDE.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** The epic-21 retro found three frontend defects (F1, F2, F3; action items 89 and 90).
- **(F2) Charge labels drifted.** Invoices print storage as "per 1,000 units/day" (`client-invoices.ts:190-195`, operator and portal), while rate cards and usage print "per 1,000 units per day" (`rate-cards.ts:49-54`). The quantity labels are duplicated (`usage.ts:128-135`, `client-invoices.ts:177-184`).
- **(F3) A failed warehouse read looks like "no warehouses".** `useTenantWarehouses` (`use-tenant-warehouses.ts:28`) swallows errors and returns `null`. Its 9 consumers render a failure as empty, and the switcher even says "No warehouse yet — create one in Settings". `useOutboundWarehouses` (`use-outbound-orders.ts:219-271`) duplicates it with a proper failed arm. The portal service page ignores `usePortalWarehouses`'s `failed` arm too.
- **(F1) The portal reaches operator code.** `portal-inbound.tsx:36` imports `LineRows` from `inbound/asn-card.tsx`, which imports `useAsns`, `useClients` and `useSkuMap`. Portal pages import their primitives from `outbound/shell`. Shared types come from the `use-outbound-orders` hook module. Nothing pins `frontend/SYSTEM-DESIGN.md:75` ("no operator type or hook reaches the portal").

**Approach:**
- **Charge labels:** one label source in the rate-card vocabulary.
- **Warehouse reads:** one warehouses hook with a failed state, and one failed-read rendering everywhere warehouses are listed.
- **Portal boundary:** move the shared primitives to a neutral home, plus a transitive-import guard test that pins the portal boundary.

**Decisions (human, 2026-10-12):**
1. **The one storage label is "per 1,000 units per day"** (the rate-card wording). Invoices change to match. Stored invoice figures are untouched; only the displayed text changes.
2. **Fix failed warehouse reads on all screens,** not only the three the retro named.

## Boundaries & Constraints

**Always:**
- **(F2) Charge labels.**
  - **Rate label.** `lineRateLabel` (`client-invoices.ts:198`) uses `basisLabel(line.basis)`: the line's own stored basis (`ClientInvoiceLineDto.basis`), the way usage already does (`usage.ts:149-150`). Its `Pick` widens to include `basis`, and `RATE_UNITS` is deleted. The fixture at `client-invoices.test.ts:121` gains a `basis`, a fixture edit beyond a label pin.
  - **Quantity label.** One `chargeQuantityLabel(code, quantity, uom)` lives in **`usage.ts`** (beside `groupDecimal`, which it needs), holding the single `COUNT_NOUNS`. `usage.ts` already imports `rate-cards`, and `client-invoices.ts:87` already imports `usage`, so there is no cycle. `usageQuantityLabel` and `lineQuantityLabel` delegate to it (their names stay, for callers).
  - Usage's null rendering (`'—'`) and the invoice's `'Unpriced'` stay distinct (preview vs draft).
  - Flip the two `units/day` pins (`client-invoices.test.ts:125`, `client-invoices.test.tsx:288`).
  - **Consistency test:** add one test asserting the **rendered** rate text of a rate-card row, a usage row and an invoice line is identical for each charge code. Once all three go through `basisLabel`, a helper-level test would check nothing.
  - **Exports are unaffected:** no CSV export prints the rate (`invoice-records.ts:361-362` uses only the quantity label). `units/day` appears only at `client-invoices.ts:191,197` and the two pins.
- **(F3) Warehouse reads.**
  - `useTenantWarehouses` returns `ResourceState<TenantWarehouses> & Reloadable`, following §1.1 and the `useOutboundWarehouses` cursor walk at `use-outbound-orders.ts:225-271`.
  - `useOutboundWarehouses` becomes a thin alias, or its callers move; one implementation either way.
  - **Loading adapter.** Consumers that destructure `tenantId` (`zone-bin-setup.tsx:90,113`, `inbound-cards.tsx:71`, `excursion-queue.tsx:66`, `cold-chain-trace.tsx:48`, `warehouse-switcher.tsx:46,76`) use `ready ? data : {tenantId: null, items: []}` while loading. The precedent is `outbound.tsx:59-60`; the rendering is unchanged.
  - **Refetch after `WAREHOUSES_CHANGED`.** A failed refetch keeps the last-good list (today's behaviour, `use-tenant-warehouses.ts:57-60`). The state goes to `failed` only when there is no data yet.
  - **A shared `WarehousesFailure({ state })`** renders `<ReadFailure word="Warehouses not loaded" reason=… onRetry={state.reload} />`.
    - Its prop type is `{ state: 'failed'; reason: string } & Reloadable`, imported only from `lib/resource-state`, so it never pulls in an operator module.
    - **Where it renders:**
      - On the report pages (`client-service`, `portal-service`) it takes the warehouse **picker's slot**; the report still renders for "All warehouses".
      - In the switcher, which sits in the narrow sidebar and the mobile menu, it uses a compact variant: one line plus Retry.
    - Every warehouse-listing consumer renders it on `failed`:
    - `shell/warehouse-switcher.tsx` (instead of the "No warehouse yet" text, which stays only for a real empty `ready`);
    - `settings/zone-bin-setup.tsx`;
    - `settings/warehouse-create-form.tsx`;
    - `inbound/inbound-cards.tsx`;
    - `conflicts/excursion-queue.tsx`;
    - `compliance/cold-chain-trace.tsx`;
    - `reports/client-service.tsx`;
    - `portal/portal-service.tsx` (through `usePortalWarehouses`);
    - and the four `useOutboundWarehouses` consumers: `outbound.tsx:58,85`, `overview-dashboard.tsx:99`, `replenishment-view.tsx:170`, `channels-view.tsx:146`.
  - **Copy unification (decided here; no test pins the old words):** "Warehouses unavailable" (outbound, overview, replenishment) and "Context unavailable" (channels) become "Warehouses not loaded".
  - **Label-only lookups** (`conflicts/variance-queue.tsx:82`, `adjustment-pendings-queue.tsx:86`) degrade to the warehouse id with no banner.
  - **Loading** renders as today (no flash of the failure).
- **(F1) Portal boundary.**
  - **Move to `src/components/shared/`:**
    - `LineRows` → `shared/line-rows.tsx`, with **private** `lineInputClass`/`lineButtonClass` constants. `asn-card.tsx` keeps its own `inputClass`/`buttonClass` (used throughout, e.g. `:139,369,386,407`) and imports `LineRows` from `shared/`.
    - The `outbound/shell.tsx` primitives (`Section`, `ReadFailure`, the `*Class` constants) → `shared/surface.tsx`. `outbound/shell.tsx` re-exports them, so its 25 operator importers are unchanged; the portal files import from `shared/surface`.
  - **Move the types `ResourceState` and `Reloadable`** to `src/lib/resource-state.ts`. `use-outbound-orders` re-exports them; `use-portal.ts` and `reports/service-tiles.tsx` import from the new file. `service-tiles.tsx` takes `ReadFailure` from `shared/surface`.
  - `WarehousesFailure` lives in `shared/`.
  - **Guard test `src/lib/portal-boundary.test.ts`.**
    - It walks the portal entry files: `src/components/portal/**`, `src/app/(portal)/**`, `src/lib/portal.ts`, `src/lib/use-portal.ts`. **Test files (`*.test.*`, `lib/test/**`) are excluded** from the entries and the walk; `portal.test.tsx:47` imports the operator shell on purpose.
    - It resolves `@/…` and relative imports (`.ts`, `.tsx`, `index`) **transitively**. It counts **`import type`** (today's `use-portal.ts:36` and `service-tiles.tsx:6` offenders are type imports) and **follows `export … from`** (so the `outbound/shell` and `use-outbound-orders` re-exports are caught). It fails on any reached module that is:
      - a `src/lib/use-*.ts` other than `use-portal.ts`;
      - a `src/components/*` outside `{portal, shared, data-table, feedback, auth/sign-out, kpi-tile, reports/service-tiles}`.
    - It prints the import chain that reached the offender.
    - A detector case proves it flags the old `asn-card` route, using a fixture or a temporary path list.
    - Today's closure from the non-test entries (verified in design review): `inbound/asn-card`, `outbound/shell` (via 5 portal files), `use-asns`/`use-clients`/`use-inbound` (via asn-card) and `use-outbound-orders` (via `use-portal`, `service-tiles`). All of them are removed by the moves above, and nothing else in the allowlist is violated.
  - Pure `src/lib/*` helpers (non-hook) stay allowed. They are shared by design (`frontend/SYSTEM-DESIGN.md:75` endorses `LineOption`).
  - Operator code may import from `lib/portal.ts` (pure); that direction is not guarded.
- **Tests:**
  - **Existing:** `inbound/asn-card.test.tsx`, `portal.test.tsx` and the rate-cards, usage and invoice tests stay green, with only label pins and import lines updated.
  - **New failure cases:**
    - `portal-service` warehouses 503 → `ReadFailure` with Retry, and Retry refetches;
    - `client-service` warehouses 503 → the same;
    - the switcher failure → "Warehouses not loaded" with Retry, not "No warehouse yet";
    - one representative operator picker (`inbound-cards`).
  - The boundary guard and the basis-text consistency test.
- **Docs:**
  - `frontend/SYSTEM-DESIGN.md:75` (the boundary is enforced by `portal-boundary.test.ts`; `components/shared/` exists), `:166`, `:248` (the `outbound/shell.tsx` inventory) and `:303`;
  - `frontend/IMPLEMENTATION-GUIDE.md:83,87` (the `ResourceState` / `ReadFailure` homes move);
  - `frontend/IMPLEMENTATION-GUIDE.md`:
    - §1.1: `useTenantWarehouses` is the one warehouses hook and `WarehousesFailure` the one rendering;
    - the mapper table: the charge-label source;
  - `docs/repos/wms-fe/README.md`;
  - `_bmad-output/implementation-artifacts/deferred-work.md:685`: close the 21-11b entry. Retro item-89 and item-90 are offered after merge.

**Never:**
- changing stored invoice data or any backend;
- a new dependency (no ESLint plugin; the guard is a bun test);
- renaming the operator-facing exports of `outbound/shell.tsx` (it re-exports);
- moving pure `lib/*` helpers just for location;
- a loading-state change.

## I/O & Edge-Case Matrix

| Scenario | State | Expected | Error |
|---|---|---|---|
| Invoice storage line | Any client invoice, operator or portal | "per 1,000 units per day" | — |
| Labels agree | Rate card, usage and invoice for each code | The same basis text | — |
| Warehouse read fails | Any warehouse-listing screen | "Warehouses not loaded" + Retry; Retry refetches | — |
| Switcher fails | The tenant warehouses read is 503 | Failure + Retry, never "No warehouse yet" | — |
| Truly empty | `ready` with no warehouses | Today's empty message | — |
| Label-only lookup fails | Variance or adjustment queue | Shows the warehouse id; no banner | — |
| Portal imports an operator hook | Any transitive path from a portal file | The guard test fails and names the chain | — |

</frozen-after-approval>

## Code Map

Paths are relative to `workspace/core/frontend/wms-fe/src`.

- **Labels:**
  - `lib/rate-cards.ts:49-60` (`BASIS_LABELS`, `basisLabel`; add `chargeQuantityLabel`), `:247`;
  - `lib/usage.ts:128-150`;
  - `lib/client-invoices.ts:177-198`;
  - `lib/invoice-records.ts:105-106,126-127,361-362`, `components/compliance/line-records.tsx:74` (they use `lineQuantityLabel`);
  - `components/compliance/client-invoices.tsx:649`; `components/portal/portal-invoices.tsx:114`.
  - Do not touch the unrelated `lineQuantityLabel` at `outbound-orders.ts:140` / `invoices.ts:403`.
- **Warehouses:**
  - `lib/use-tenant-warehouses.ts:28`; `lib/use-outbound-orders.ts:30-38,219-271`; `lib/use-portal.ts:237`.
  - Consumers:
    - `shell/warehouse-switcher.tsx:46,78-84`;
    - `settings/zone-bin-setup.tsx:90`;
    - `settings/warehouse-create-form.tsx:303-305`;
    - `inbound/inbound-cards.tsx:71`;
    - `conflicts/excursion-queue.tsx:66`;
    - `compliance/cold-chain-trace.tsx:48`;
    - `conflicts/variance-queue.tsx:82`;
    - `conflicts/adjustment-pendings-queue.tsx:86`;
    - `reports/client-service.tsx:33,48`;
    - `portal/portal-service.tsx:33-35`;
    - `portal/portal-inbound.tsx:169,231-232`;
    - the `useOutboundWarehouses` callers (`outbound.tsx:83` and others).
- **Portal boundary:**
  - `components/inbound/asn-card.tsx:10,31,35-37,62,65,218`;
  - `components/outbound/shell.tsx:57` (`ReadFailure`);
  - `components/portal/*`; `components/reports/service-tiles.tsx`;
  - `lib/portal.ts:20-29`; `lib/use-portal.ts:35-36`.
  - Precedent for a source-reading test: `brand-tokens.test.ts`.
- **Tests:**
  - `components/portal/portal.test.tsx:47-53,431,651,795`;
  - `components/reports/client-service.test.tsx:88`;
  - `lib/usage.test.ts:11,21-22,67-84`;
  - `lib/client-invoices.test.ts:20-22,124-130`;
  - `lib/rate-cards.test.ts:15,68,196`;
  - `components/compliance/client-invoices.test.tsx:287-288`;
  - `components/settings/rate-cards-card.test.tsx:284-308,430-433`;
  - `lib/invoice-records.test.ts`, `components/compliance/line-records.test.tsx:244`.

## Tasks & Acceptance

**Execution:**
- [ ] `lib/rate-cards.ts`, `lib/usage.ts`, `lib/client-invoices.ts` -- one label source -- F2, decision 1.
- [ ] `lib/use-tenant-warehouses.ts` (+ `use-outbound-orders.ts`), `components/shared/warehouses-failure.tsx`, every consumer -- the failed state -- F3, decision 2.
- [ ] `components/shared/line-rows.tsx`, `components/shared/surface.tsx`, `lib/resource-state.ts`; re-point the portal and `service-tiles` imports; `outbound/shell.tsx` re-exports -- F1.
- [ ] `lib/portal-boundary.test.ts` -- the transitive guard and its detector -- F1.
- [ ] Tests: label pins, the consistency test, the failure cases; existing suites green.
- [ ] Meta docs: as listed in Boundaries.

**Acceptance Criteria:**
- Given a client invoice, when viewed by an operator or in the portal, then its storage line reads "per 1,000 units per day", the same as the rate card and usage.
- Given the warehouses read fails, when any warehouse-listing screen loads, then it shows "Warehouses not loaded" with Retry, never an empty or "no warehouse" state.
- Given the full FE suite, typecheck, lint and the capability mirror, when run, then they pass.

## Implementation Notes

## Spec Change Log

## Review Triage Log

Design review (2026-10-12), one lens: claims, coverage and testability.

| # | Finding | Verdict | Disposition |
|---|---|---|---|
| 1 | The guard would fail on day one: `portal.test.tsx:47` imports the operator shell | high — verified by a closure script | Fixed: test files excluded |
| 2 | `chargeQuantityLabel` in `rate-cards.ts` would create an import cycle (it needs `groupDecimal` from `usage.ts`) | high | Fixed: it lives in `usage.ts` |
| 3 | Invoice lines already carry their own `basis` | medium | Fixed: `basisLabel(line.basis)`; consistency test on rendered text |
| 4 | `tenantId` during loading was unspecified for 5 consumers | medium | Fixed: the loading adapter |
| 5 | Report pages: does a failure replace the whole report? | medium | Fixed: it takes the picker's slot |
| 6 | Copy changes on four screens were not recorded | medium | Fixed: listed and decided |
| 7 | `WarehousesFailure`'s prop type could reopen the boundary | medium | Fixed: a minimal type from `lib/resource-state` |
| 8 | The guard's handling of type imports and re-exports was undecided | medium | Fixed: it counts and follows both; today's closure listed |
| 9 | `LineRows` constants collide with asn-card's own | low | Fixed: private constants |
| 10 | The switcher's fit and behaviour on refetch failure | low | Fixed: compact variant; last-good kept |
| 11 | The docs list missed stale refs and named the wrong file for the deferred entry | medium | Fixed |
| 12 | Count is 25 not 30; CSV is unaffected | low | Fixed |

## Design Notes

- **Why the guard is transitive.** The leak is indirect: the portal imports `LineRows`, whose module imports operator hooks. An ESLint `no-restricted-imports` rule sees only direct imports and would miss it.
- **Why `outbound/shell` re-exports instead of re-pointing 30 files.** It keeps the diff to the boundary that matters, the portal, without churning operator code.
- **Why fold `useOutboundWarehouses`.** It exists only because `useTenantWarehouses` had no failed arm (its own comment, `:219-224`). One hook means one behaviour.
