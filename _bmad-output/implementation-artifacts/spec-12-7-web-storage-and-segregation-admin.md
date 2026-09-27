---
title: 'Story 12-7 — Web storage and segregation admin'
type: 'feature'
created: '2026-09-26'
status: 'done'
route: 'dispatch'
baseline_commit: 'wms-be@fe9013e / wms-fe@9c0d881'
review_loop_iteration: 1
context:
  - '_bmad-output/implementation-artifacts/epic-12-context.md'
  - 'docs/design/SYSTEM-DESIGN.md'
  - 'docs/design/IMPLEMENTATION-GUIDE.md'
  - 'docs/design/modules/compliance.md'
  - 'docs/design/modules/catalog.md'
  - 'docs/design/modules/tenancy.md'
  - 'docs/design/frontend/SYSTEM-DESIGN.md'
  - 'docs/design/frontend/IMPLEMENTATION-GUIDE.md'
  - 'docs/design/API-SURFACE.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** Epic 12's backend rules (stories 12-1…12-6) have no web admin surface. Storage and hazard classes are required on SKUs and bins but invisible in the FE table and absent from its edit forms (`sku-table.tsx`, `zone-bin-setup.tsx`); the segregation matrix is code-fixed in `hazard.ts` and unviewable; the 12-5 excursion queue has no review UI (`resolveExcursion` has zero web consumers); and the 12-6 FR-45 trace has no reader on any client (its frozen boundary deferred the trace UI to "12-7/12-8").

**Approach:** One tiny additive backend read + five FE surfaces riding established vocabulary — no new capability, no new table, no new interaction pattern (UX-DR8/11/14):

1. **BE:** `GET /tenants/{t}/catalog/segregation-matrix` — an ungated read that returns the matrix from `hazard.ts` as data, so the FE renders the server's truth instead of hardcoding a drift-prone copy.
2. **FE — SKU class admin:** storageClass + hazardClass columns on the SKU table; two pickers in `SkuEditForm`; the 12-1/12-2 refusal codes surfaced through a `src/lib` mapper.
3. **FE — location class admin:** a storageClass column and an Edit-class affordance on bins in `zone-bin-setup.tsx`, PATCHing the structure arm the 12-4 regen already carries.
4. **FE — segregation matrix card:** a read-only 7×7 grid in Settings rendered from the new endpoint.
5. **FE — excursion review queue on `/conflicts`:** a queue switcher (Over-receipts | Excursions) per UX-DR30 — the excursion lands in Conflicts & Reviews (UX-DR11) with the reading, affected units (holdIds joined to the existing qc-holds read) and resolve gated on `review.decide`.
6. **FE — `/compliance` activation:** the cold-chain trace viewer (warehouse picker + order lookup), rendering the 12-6 response's lines/scopes/chain timeline and correlated excursions — the ledger-timeline surface and the story 12-6 frozen boundary's rider.

## Boundaries & Constraints

**Always:**
- Backend first: the matrix endpoint lands (openapi.json exported, tests green) before any FE change that consumes it; FE client regen via `bun run api:generate` only — never hand-edit `src/lib/api/generated/`.
- Every consumed endpoint gets a `fetchApi*` wrapper in `client.ts` plus a `client.test.ts` case pinning path/query/body/Idempotency-Key (the four compliance endpoints and the matrix endpoint have none today; `fetchApiListQcHolds` already exists).
- New read hooks return `ResourceState<T> & Reloadable` (loading|ready|failed + `reload()`), failed reads render through `ReadFailure` — never the `Page | null` house-hook shape (`use-inbound.ts` is declared debt).
- Refusal mapping branches on problem `code` in new `src/lib` mappers with tests (`default` → `detail`, transport arm → the house copy). The codes this story surfaces: `storage-class-conflict`, `hazard-segregation-conflict` (both name the conflicting parties in `detail` — surface the detail verbatim), `bin-retired`, `excursion-resolved`, `order-not-dispatched`, `invalid-cursor`.
- Capability gating at affordance level only, role read via `useSyncExternalStore(subscribeSession, …)` (the `sku-table.tsx` pattern — NOT the five known-buggy Settings cards): SKU edit affordance on `sku.edit`; bin Edit-class affordance on `bin.create` (the BE's own gate for the structure arm); Resolve on `review.decide`. No nav change: `/conflicts` keeps its `review.decide` nav gate (a non-actor role with zero over-receipt rows would see an empty list — but the excursion list is open to any member, so the excursion queue renders read-only inside the component for non-`review.decide` roles, per the double-gating convention in `over-receipt-queue.tsx`'s header comment); `/compliance` stays ungated.
- Every mutation carries `ulid()` Idempotency-Key with per-click lifetime plus a synchronous re-entry ref guard (the `inbound-cards.tsx:299` pattern) checked in both arms.
- `hazardClass` is runtime-nullable even though the generated type drops `| null` (KNOWN-BAD, `catalog-kits.test.ts:61-67`) — the matrix view and SKU rendering must treat null as "no rule".
- Class badges/labels use existing tokens; never colour-only signalling (UX-DR22 floor), no new hex, no gradients.
- The matrix endpoint is an ungated read (`TenantSessionGuard` + `assertOwnTenantToken`, no capability, no idempotency) mirroring the guard pattern of `GET :tenantId/catalog/skus`; OpenAPI additive-only.

**Never:**
- No new capability and no `users.ts` grant changes — `review.decide`, `excursion.record`, `secure.move` are already mirrored (run `bun run check:capability-mirror` as proof); updating the stale "no web surface consumes it yet" comments in `users.ts` is cosmetic-only and in scope.
- No BE command-layer changes: the guards this story surfaces (409 `storage-class-conflict` on a stranding class change, `hazard-segregation-conflict`, `bin-segregation-conflict` on putaway/merge, `excursion-resolved`, `order-not-dispatched`) all exist; this story only renders them.
- No segregation-matrix *configuration* storage — the matrix is code in `src/shared/primitives/hazard.ts` ("widening happens in THIS file"); the view is read-only. The epic's "configuration" is satisfied by the class admin that feeds the predicate plus the view of the predicate itself.
- No threshold/sensor model, no PDF/export, no reporting-module activation, no mobile changes (12-8 owns the scan-path refusal and excursion capture).
- No bin dimension/maxWeight editing — the story is class admin; the structure arm is PATCHed with `storageClass` only.
- No new ledger events, no migrations, no grammar bump.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Matrix read | member session | `200` `{ classes: HazardClass[], incompatible: {a,b}[] }` — the FULLY EXPANDED incompatible unordered-pair set (explosive's universal rule enumerated as pairs, incl. `explosive|explosive`), so the FE renders `compatible(a,b) = !in.includes(pair)` with zero logic and zero null rule (null is not a class) | foreign session `403`; cross-checked in tests against `hazardClassesCompatible` over all 28 unordered pairs |
| SKU class edit | `sku.edit` holder sets storageClass / sets or clears hazardClass | PATCH carries only the changed fields (`storageClass?`, `hazardClass?: string|null`); table re-renders on success | `409 storage-class-conflict` / `409 hazard-segregation-conflict` → detail names bins/parties verbatim; form stays open, refusal mapped by code |
| SKU edit without role | operator session | Edit affordance hidden (affordance-level gate) | N/A |
| Bin class edit | `bin.create` holder sets storageClass on a live, non-system bin | PATCH structure arm `{storageClass}` only; column re-renders | `409 storage-class-conflict` (stranding stock — names the conflicting stock) / `409 bin-retired` / `400 validation-failed` mapped; system/retired bins: affordance inert (existing `inert` pattern) |
| Excursion queue read | any member, `/conflicts` → Excursions tab | `GET /excursions?warehouseId&status&cursor` through a ResourceState hook; cards show bin, reading °C, note, status, timestamps; holdIds joined to `GET /receiving/qc-holds` for affected units (sku × qty); holds no longer returned render as disposed | `400 invalid-cursor` → mapped; failed read → `ReadFailure` with reload |
| Resolve excursion | `review.decide` holder, open excursion | POST resolve with per-click Idempotency-Key + ref guard; card flips to resolved, status tabs update | `409 excursion-resolved` → mapped (row re-read); `403 role-denied` → mapped; non-holder: button hidden, card read-only |
| Trace read | any member, `/compliance`, warehouse picked + orderId pasted | `GET …/cold-chain/orders/{orderId}`; renders order header, bins dict with current classes, per-line scopes with chronological chain events (type, seq, occurredAt, from→to bin codes, qty, batch/serial ref, raw referenceDoc) and correlated excursions | `409 order-not-dispatched` → mapped copy; `404 not-found` → mapped copy; failed read → `ReadFailure` |
| Malformed orderId | non-ULID input | client-side shape check before fetch (the BE 400 names it, but no request is spent) | inline validation copy |

</frozen-after-approval>

## Code Map

**wms-be** (one additive read):
- `src/shared/primitives/hazard.ts:44-95` — `HAZARD_CLASSES`, `INCOMPATIBLE_PAIRS`, `hazardClassesCompatible` (the explosive universal rule + null-compatibility live in the predicate, not the set — the endpoint enumerates them)
- `src/modules/catalog/catalog.controller.ts:148,215` — `@Controller('tenants')`, the `GET :tenantId/catalog/skus` guard pattern to mirror
- `src/modules/catalog/catalog.facade.ts` — gains the matrix read (controller → facade, per AD-6)
- `src/api/…` — no new controller; the route joins `catalog.controller.ts` with `catalog.dto.ts` response types (`problemJsonResponse` convention)
- `openapi/openapi.json` — `bun run openapi:export`
- `test/catalog.spec.ts` (or a sibling suite) — endpoint e2e incl. the all-pairs cross-check

**wms-fe:**
- `src/lib/api/client.ts:483-505` — wrapper pattern (`fetchApiEditSku`); add `fetchApiGetSegregationMatrix`, `fetchApiListExcursions`, `fetchApiResolveExcursion`, `fetchApiGetOrderColdChainTrace` (+ client.test.ts cases); `fetchApiListQcHolds` (:890) and `fetchApiSetBinBlocked` (:378) already exist
- `src/lib/api/generated/` — regen after the BE PR merges (drift guard stays red until then — expected)
- `src/components/settings/sku-table.tsx:109-172` (columns), `:260-528` (SkuEditForm), `:535-554` (local rejectionReason — superseded by the new mapper for the new codes), `:99-104` (canEditSku — the gating pattern to copy)
- `src/components/settings/zone-bin-setup.tsx:38` (BIN_TYPES), `:485-595` (create forms), `:597-601` (binColumns), `:775-822` (row actions + `inert`), `:635,724,733,743` (mergeFetchSeq superseded-fetch guard), `:890-934` (local rejectionReason)
- `src/components/conflicts/over-receipt-queue.tsx:33-42` (status tabs), `:44-61` (session gate), `:70-75` (canDecide), `:178-254` (card pattern), `:232` (affordance gating) — the page gains a top-level queue switcher; the excursion queue is a NEW component (`src/components/conflicts/excursion-queue.tsx`) with its own hook, not a fork of `useOverReceipts`
- `src/app/(app)/compliance/page.tsx` — replace `SurfacePlaceholder` with the trace viewer component (`src/components/compliance/cold-chain-trace.tsx`)
- `src/lib/use-tenant-warehouses.ts:28` + `src/lib/warehouses.ts:21-50` — active-warehouse picker pattern
- `src/lib/users.ts:34,71,85,98-108` — capabilities already mirrored; refresh the two stale comments
- `src/lib/over-receipt.ts:18-70` — the mapper skeleton to imitate (new mappers: `src/lib/sku-admin.ts`, `src/lib/excursion.ts`, `src/lib/cold-chain.ts`)
- New hooks: `src/lib/use-excursions.ts`, `src/lib/use-cold-chain.ts`, `src/lib/use-segregation-matrix.ts` — `ResourceState<T> & Reloadable`, imitating `src/lib/use-outbound-waves.ts`
- Component tests to imitate: `src/components/settings/sku-table.test.tsx` (fixture factory + `writeSession`), `src/lib/catalog-kits.test.ts` (ApiProblem factory)

## Tasks & Acceptance

**Execution:**
- [ ] **BE** `catalog.controller.ts` + `catalog.dto.ts` + `catalog.facade.ts` — `GET :tenantId/catalog/segregation-matrix` (ungated read; guard pattern of GET skus; response `{classes, incompatible}` fully expanded from `hazard.ts`, explosive universal enumerated)
- [ ] **BE** `test/…spec.ts` — e2e: 200 with the exact 11-pair set (7 explosive pairs incl. self + the 4 `INCOMPATIBLE_PAIRS`), cross-check every unordered pair against `hazardClassesCompatible`; foreign-session 403; 401 unauthenticated
- [ ] **BE** `openapi/openapi.json` regen — additive only
- [ ] **FE** regen client after BE merges; add the four `fetchApi*` wrappers + client.test.ts pins
- [ ] **FE** `src/lib/sku-admin.ts` mapper (+ test): `storage-class-conflict`, `hazard-segregation-conflict` → detail verbatim; default arms
- [ ] **FE** `sku-table.tsx`: storageClass + hazardClass columns (hazard null → "—"); SkuEditForm gains the two pickers (hazard clearable to "No rule"); PATCH sends only changed fields; refusal via the mapper; affordance gated `sku.edit`
- [ ] **FE** `src/lib/excursion.ts` mapper (+ test) and `use-excursions.ts` hook (ResourceState & Reloadable, keyset cursor, status filter)
- [ ] **FE** `excursion-queue.tsx` + `/conflicts` queue switcher: cards (bin, reading, note, hold join, timestamps), Resolve gated `review.decide` + ref guard + per-click key, tabs open/resolved; `fetchApiListQcHolds` join for affected units
- [ ] **FE** `zone-bin-setup.tsx`: storageClass column; Edit-class affordance on live non-system bins gated `bin.create`; PATCH structure arm `{storageClass}`; `src/lib` mapper for `storage-class-conflict`/`bin-retired`
- [ ] **FE** matrix card in Settings: 7×7 read-only grid from the endpoint (null row/col = "no rule", always compatible)
- [ ] **FE** `src/lib/cold-chain.ts` mapper (+ test) + `use-cold-chain.ts` hook; `cold-chain-trace.tsx` replaces the `/compliance` placeholder: warehouse picker, orderId input with ULID shape check, order header, bins dict, per-line scope chains as a timeline, correlated excursions
- [ ] **FE** `users.ts` stale comments refreshed; `bun run check:capability-mirror` green
- [ ] **FE** component tests: sku-table (new columns + edit round-trip + refusal), excursion-queue (resolve happy + 409 + hidden button), zone-bin-setup (edit class + refusal), cold-chain-trace (render + 409/404), matrix card
- [ ] **BE+FE** meta docs: `docs/repos/wms-be/README.md` + `wms-fe/README.md` contract paragraphs; `API-SURFACE.md` matrix route row; module docs (`catalog.md`, `compliance.md`) if seams changed

**Acceptance Criteria:**
- Given an `ops_manager` session, when they set a SKU's hazardClass to `flammable` while it sits in a bin beside `oxidizer` stock, then the edit is refused and the refusal names both parties — and the same edit through the UI shows that refusal verbatim.
- Given any member on `/conflicts`, when the Excursions tab is open, then open excursions show their reading, bin, affected units (from the hold join) and resolve is offered exactly to `review.decide` holders.
- Given any member on `/compliance`, when they read a dispatched order's trace, then every chain hop shows with its bin's current class and the correlated excursions appear per line — and an undispatched order shows the mapped refusal, not a raw error.
- Given any member on Settings, when the matrix card renders, then the grid equals the server's matrix exactly (the endpoint is the only source; nothing hardcoded).

## Design Notes

- **Why an endpoint, not a FE constant.** `hazard.ts` states "widening happens in THIS file" — a hardcoded FE copy would drift on the first vocabulary change. The endpoint enumerates the predicate's universal rule (explosive) into data so the FE stays dumb; the all-pairs cross-check test pins the enumeration to the predicate itself, so the two cannot diverge silently.
- **Why the queue rides `/conflicts`, not `/compliance`.** UX-DR30 freezes the excursion's home as the Conflicts & Reviews queue (UX-DR11); UX-DR8 forbids a new interaction vocabulary. The switcher keeps each queue's own status tabs and decision flow. `/compliance` then activates as the trace viewer — the read the 12-6 frozen boundary explicitly deferred to "12-7/12-8", and the only surface that renders FR-45.
- **Why the bin edit gate is `bin.create`.** The BE already gates the structure arm on `bin.create` (OpenAPI 403 arm) — the FE mirrors the server's decision rather than inventing a different one.
- **Why hazardClass renders nullable.** The generated type drops `| null` (vendor bug, tracked in PENDING); runtime truth is "null carries no rule" (12-2). Rendering null as "—" and treating the clear verb as always-succeeding matches the BE contract, not the broken type.
- **Why a new excursion hook, not `useOverReceipts`.** The house `Page | null` hooks are declared debt (guide §1); every new hook since returns `ResourceState & Reloadable`. The queue component shares the page's session gate and card styling, not its data layer.
- **Quantity honesty:** dispatched quantities and hold quantities render at the UoM's declared precision; no client-side rounding (guide §6). °C renders at ≤2 dp as recorded.

## Review Triage Log

Three review layers ran over the implementation diffs (blind-hunter: 11 findings; edge-case-hunter: 4; verification-gap: 8). Every non-verification-gap finding was verified first-hand against source before acceptance. Consolidated log (BH = blind-hunter, EC = edge-case, VG = verification-gap; duplicates merged):

| # | Source | Finding | Verdict | Disposition |
|---|--------|---------|---------|-------------|
| 1 | BH1 + EC1 | **The trace viewer refuses every real order id.** The FE gates orderId on a 26-char Crockford ULID (`cold-chain.ts` `ULID_PATTERN`, `maxLength={26}`, ULID placeholder, refusal copy; the mapper's `validation-failed` copy also says "26-character ULID"), but every BE entity id is a dashed lowercase **UUIDv7** (`ids.ts` header: "Every entity id in the system is a UUIDv7… Idempotency keys are ULIDs"; `order.command.ts:543` mints `uuidv7()`; the trace route itself 400s non-`UUID_RE` ids). No real order id passes the gate; a hypothetical valid ULID would 400 at the BE anyway. The component tests enshrine the wrong shape (ULID fixture + "26-character" copy assertion) while `client.test.ts` uses the correct dashed shape. Verified first-hand in both repos. | high | **patch** — replace the ULID gate with a UUID shape check (accept dashed/lowercase, trim), fix `maxLength`, placeholder, refusal copy and mapper copy; rewrite the component tests to the UUIDv7 shape. This defect was introduced by the spec itself (frozen I/O row says "non-ULID input") — the spec's id vocabulary was wrong, not the implementer's reading of it. |
| 2 | BH4 + EC2 | One try/catch wraps the excursion list fetch AND the whole hold-join walk (`use-excursions.ts:90-152`): any qc-holds failure renders the entire queue `failed` although the excursion page fetched fine — and through `excursionListReason`'s wrong arms, since the error is a holds error. The join is enrichment; its failure kills the primary read. Verified first-hand. | medium | **patch** — give the hold walk its own catch: a join failure still renders the page with `joinFailed: true` on the holds envelope and cards show an explicit "affected units unavailable" line; `excursionListReason` only ever sees list errors. |
| 3 | EC3 | Invalid-cursor Retry dead-ends: `reload()` clears `result` and bumps `revision` but never resets `requested`, so Retry re-requests the same stale cursor forever, contradicting the copy's promise of a first-page restart. Verified first-hand in `use-excursions.ts:169-172`. | medium | **patch** — `reload()` also resets `requested` to null so Retry re-fires from the first page. |
| 4 | BH3 | Matrix-card test fixture emits cross pairs in orientations the endpoint never produces (the endpoint emits sorted keys — `{a:'flammable', b:'oxidizer'}`, `{a:'gas', b:'toxic'}`, `{a:'corrosive-acid', b:'oxidizer'}`; the fixture emits the reverses), while claiming to be "the server's fully expanded set". The card's symmetric membership masks it today; a directional future change would be verified against a lying fixture. Verified first-hand against the fixture and the BE e2e's sorted-key assertions. | medium | **patch** — fixture emits the endpoint's actual sorted-key orientations. |
| 5 | BH11 + EC4 | Bin Edit-class submit lacks the synchronous re-entry ref guard its sibling resolve flow documents as mandatory (`zone-bin-setup.tsx` `applyClassEdit` guards on rendered `busyBinId` only); a pre-render double-click sends two PATCHes with two fresh keys — two audit rows for one intent. Benign in effect (same-value write). Verified in my own diff read + both hunters independently. | low | **patch** — add the ref guard, both arms, mirroring `resolveInFlight`. |
| 6 | BH5 | The hold join re-walks the warehouse's entire hold chain on every page/tab/warehouse interaction, with no `cancelled` check inside the walk (mid-walk warehouse switch leaves up to 20 sequential requests running to be discarded). Verified first-hand. | medium-low | **patch (half)** — add `cancelled` checks inside the walk loop. **defer (half)** — memoizing the join per warehouse across pages/tabs is a real design change (cache ownership, invalidation); goes to PENDING. |
| 7 | BH6 | The resolve outcome banner persists across tab and warehouse switches (cleared only at the start of the next resolve), inviting the misread that the newly displayed entries were just resolved. Verified first-hand (`excursion-queue.tsx:94,108,220`). | low | **patch** — clear `outcome` on tab change and on warehouse change. |
| 8 | BH7 | Switching warehouse via the shell's global switcher re-fetches the loaded order in the new warehouse → false 404 "not-found" for an order that exists (the trace resets `orderId` only in its own select's onChange; the shell switcher writes the same store). Verified first-hand (`cold-chain-trace.tsx:99-102`). | low | **patch** — reset `orderId` whenever the derived `warehouseId` changes, not only via the local select. |
| 9 | BH8 | The trace's excursion line falls back to the raw bin uuid (`binById.get(…)?.code ?? excursion.binId`), contradicting the component's own doc contract ("a bin missing from it renders unknown") and the queue's `(unknown bin)` convention. Verified first-hand (`cold-chain-trace.tsx:198` vs the contract at :163). | low | **patch** — fall back to `(unknown bin)`. |
| 10 | BH10 + VG3 | The BE matrix e2e exercises only the owner session; the route's load-bearing "ungated, open to any member" claim is unpinned — a future capability check could land silently, hiding the card from operators/accountants. Verified first-hand (grep of the spec file: all 200s ride `ownerToken`). | low | **patch** — one member-session 200 test alongside the owner's. |
| 11 | BH9 | On queue mount, `warehouseId` is null until warehouses load → a transient tenant-wide excursion fetch + hold walk fires, then re-fires scoped; `useBinCodeMap(null)` renders `(unknown bin)` for existing bins during the flash. Self-corrects when warehouses arrive. Verified first-hand. | low | **defer** — fixing it properly needs a small hook skip-semantics decision (when may the hook fire with a null warehouse); not patch-round material. Goes to PENDING. |
| 12 | VG1 | Status tabs never exercised: the `status` query param, tab-scoped cursor isolation and resolved-chip rendering are unpinned. | low | **patch** — component-test pins (tab click → correct status param; cursor paged on one tab re-requests as first-page on the other; resolved tab renders resolved chips). |
| 13 | VG2 | The hold-join walk (multi-page, both statuses, truncation flag) is entirely unpinned. | low | **patch** — hook/component test with a multi-page holds stub incl. the truncation flag. |
| 14 | VG4 | Per-click Idempotency-Key uniqueness and the resolve re-entry guard are unpinned; cheap pin: two synchronous clicks → one POST. | low | **patch** — double-click test. |
| 15 | VG5 | Bin Edit-class operator gating (affordance hidden without `bin.create`) and the post-save reload are unpinned. | low | **patch** — component-test pins. |
| 16 | VG7 | Trace Retry never clicked; the missing-bin fallback is unpinned. | low | **patch** — pins alongside finding 9's fix. |
| 17 | VG6 | The bin saved-banner assertion runs against an echo stub, so client-draft and server response are indistinguishable. | low | **defer** — test-quality refinement; the value rendered is the response either way and the failure arm is separately tested. Goes to PENDING. |
| 18 | VG8 | Minors: `queues.tsx` switcher untested; a no-op `not.toContain(null)` assertion; the storage picker's clear verb unpinned; the `hazard-segregation-conflict` component-level refusal case unmapped. | low | **patch (three pins: clear-verb, component refusal case, replace the no-op assertion); defer (queues.tsx test — a trivial switcher).** |

**Loop outcome:** 1 high (finding 1 — blocks merge), 3 medium (findings 2, 3, 4), 1 medium-low split (finding 6), the rest low. Review-loop iteration 1: patch round dispatched to the implementation agent, covering findings 1–10, 12–16, 18 (patches + pins); defers recorded: finding 6 (join memoization), 11, 17, 18 (queues.tsx test).