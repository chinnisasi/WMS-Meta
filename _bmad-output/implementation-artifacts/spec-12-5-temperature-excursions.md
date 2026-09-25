---
title: 'Story 12-5 — Temperature excursions: ledger event + quarantine'
type: 'feature'
created: '2026-09-25'
status: 'done'
baseline_commit: 'wms-be@1c1ad80 / wms-fe@8d334be'
route: 'dispatch'
review_loop_iteration: 0
context:
  - '_bmad-output/implementation-artifacts/epic-12-context.md'
  - 'docs/design/SYSTEM-DESIGN.md'
  - 'docs/design/IMPLEMENTATION-GUIDE.md'
  - 'docs/design/modules/inventory.md'
  - 'docs/design/modules/inbound.md'
  - 'docs/design/API-SURFACE.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** FR-44 has no backend at all — a cold-chain operator cannot record a temperature excursion, affected stock is never quarantined, and the reading exists nowhere the ledger (FR-45's reconstruction source) can see. Verified: zero excursion code in any repo; the only temperature notion is the rank hierarchy in `storage-class.ts`.

**Approach:** Activate the empty **compliance** spine module. An excursion targets a bin with a °C reading; the command records a **zero-quantity `excursion.recorded` ledger event per affected (sku, bin) scope** (AD-11 registration) and quarantines the affected units by creating **ordinary QC holds** through the existing hold semantics — so ATP exclusion, the release path, the merge/SKU-class guards and the ledger timeline all work unchanged. Excursions list via a new route for the 12-7 review queue; `resolve` is a review-status flip.

## Boundaries & Constraints

**Always:**
- Ride the ledger: `excursion.recorded` registers in `ledger-registry.ts` (`sinceVersion: 1`, zero-delta non-movement like `pack.packed`; batch/serial arms closed) and a new additive `LedgerReferenceDoc` arm `{kind: 'excursion', excursionId, binId, readingC}` carries enough for FR-45 reconstruction from the ledger alone. Zero-quantity events keep both `fromBinId`/`toBinId` null (envelope rule); `skuId` is never null — hence one event per affected scope.
- Quarantine reuses ONE implementation of hold semantics: extract the movement+row-write core of `QcCommand.placeHold` into an in-tx helper (validation, per-batch `qc.held` arms into the QC-HOLD bin, hold row, outbox, audit), keep authority/idempotency in `placeHold`, expose the helper via `QcFacade`; the excursion command calls it per scope. ATP exclusion falls out of `qcHeldUnits` — `reservation.service.ts` is untouched.
- Affected = every distinct SKU with on-hand quantity > 0 in the target bin. **All-or-nothing**: any serial-tracked or catch-weight SKU in the bin refuses the entire excursion (400 naming them) — FR-44 never leaves units in ATP; per-unit quarantine stays Epic 15's (the `placeHold` rationale transfers verbatim).
- A target bin is refused when system-owned (the QC-HOLD bin itself) or empty (400; FR-44 is against affected stock). A scope already under an open hold is **skipped** (already out of ATP), not a 409.
- New capability `excursion.record` — Owner + Ops Manager + Operator (the floor records what it observes, `putaway.execute`'s rationale); Accountant read-only. `resolve` gates on the existing `review.decide`.
- Recording follows the command skeleton: fresh role read, replay lookup, 400/404/409 before any write, in-tx outbox (`excursion.recorded`) + audit row + idempotency key.

**Never:**
- No threshold model, sensor ingestion or auto-detection — operator-captured readings only (UX-DR30 is manual; no FR defines thresholds).
- No handling-unit arm (Epic 15), no unit conversion (°C only), no measured fill/level (Epic 20), no grammar-version bump.
- `resolve` does **not** release holds: it flips the excursion's review status; stock disposition stays the existing `qc.manage` release / `stock.adjust` verbs.
- No FE/mobile surfaces — FE here is only client regen + the capability mirror; UX-DR30 capture is 12-8's, the queue/badge is 12-7's.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Happy: mixed bin | Bin holds 2 SKUs, one batch-tracked with 3 batches | 1 excursion row (open), 2 hold rows, 2 `excursion.recorded` + 4 `qc.held` movements; ATP drops for both scopes | N/A |
| Unquarantinable | Bin also holds a serial-tracked or catch-weight SKU | Nothing written | 400 naming the offending SKUs |
| Empty / system bin | Bin empty, or `systemOwned` | Nothing written | 400 |
| Scope already held | One (sku,bin) has an open hold | That scope skipped; rest quarantined; holdIds omits it | N/A |
| Replay | Same idempotency key + payload | Same snapshot returned | 422 `idempotency-key-reuse` on payload mismatch |
| Resolve | Open excursion, `review.decide` holder | status → resolved, resolvedBy/At set, outbox `excursion.resolved`; holds untouched | 404 unknown id; 409 already resolved |
| Capability | Accountant records; Operator records | 403 `role-denied` / accepted | — |

</frozen-after-approval>

## Code Map

- `src/modules/inventory/ledger-registry.ts` -- register `excursion.recorded` + additive `LedgerReferenceDoc` arm; all types register `sinceVersion: 1` (verified — no grammar bump)
- `src/modules/inbound/qc.command.ts` -- extract the movement+row-write core of `placeHold` into an in-tx helper (authority/idempotency stay behind)
- `src/modules/inbound/qc.facade.ts` -- passthrough for the in-tx helper (`qc_holds` stays inbound-exclusive)
- `src/modules/tenancy/permissions.ts` -- `excursion.record` capability + matrix entries; FE mirror is `wms-fe/src/lib/users.ts`
- `src/shared/db/schema.ts` -- `temperature_excursions` table (see Design Notes); RLS + status CHECK go ONLY in migration SQL (the 0008 pattern)
- `drizzle/` -- `0038_temperature_excursions.sql` + `_journal.json` + `meta/0038_snapshot.json`; no data statements (new table)
- `src/modules/compliance/` -- activate the placeholder: `excursion.command.ts`, `excursion.facade.ts`, DTO, module wiring (imports InventoryModule facade + InboundModule qc facade)
- `src/api/compliance.controller.ts` -- `POST/GET /tenants/{t}/excursions`, `POST /tenants/{t}/excursions/{id}/resolve` (idempotency key on POST record, the receiving.controller pattern)
- `test/excursions.spec.ts` -- matrix rows + capability + ledger-shape pins
- `openapi/openapi.json` -- `bun run openapi:export`
- `wms-fe/src/lib/api/generated/` -- `bun run api:generate` (never hand-edit)
- `wms-fe/src/lib/users.ts` -- capability mirror

## Tasks & Acceptance

**Execution:**
- [x] `src/shared/db/schema.ts` -- add `temperature_excursions` (columns per Design Notes, partial-unique-free: one row per excursion, no scope uniqueness) -- the review queue's data
- [x] `drizzle/0038_temperature_excursions.sql` (+ journal + snapshot) -- drizzle-kit generate, then hand-append RLS policy + status CHECK (SQL only, 0008 pattern) -- migration checklist
- [x] `src/modules/inventory/ledger-registry.ts` -- `excursion` reference-doc arm + `excursion.recorded` registration (`allowsBatchArm: false, allowsSerialArm: false`, `referenceKinds: ['excursion']`) -- AD-11
- [x] `src/modules/tenancy/permissions.ts` -- `excursion.record` (owner, ops_manager, operator) -- the recording verb
- [x] `src/modules/inbound/qc.command.ts` + `qc.facade.ts` -- extract `holdScopeInTx` (validation + arms + row + outbox + audit), facade passthrough; `placeHold` behavior byte-identical -- one hold implementation
- [x] `src/modules/compliance/` -- `recordExcursion` (sweep → per-scope hold + zero-delta event → excursion row), `listExcursions`, `resolveExcursion`; facade; module imports -- the story's home
- [x] `src/api/compliance.controller.ts` + `compliance.dto.ts` -- three routes; reading bounds -100..200 °C -- API surface
- [x] `test/excursions.spec.ts` -- every matrix row, plus: ledger events shape (zero-delta, refs null, `referenceDoc.excursionId`), holdIds round-trip, `placeHold` regression -- the contract
- [x] `openapi/openapi.json` + FE regen + `wms-fe/src/lib/users.ts` mirror (+ its test) -- cross-repo mirror

**Acceptance Criteria:**
- Given a recorded excursion on bin B, when ATP is read for any affected scope, then held units are excluded (no `reservation.service.ts` change — `qcHeldUnits` sees the QC-bin stock).
- Given the ledger alone (FR-45), the excursion is reconstructible: per-scope `excursion.recorded` events carry `referenceDoc {excursionId, binId, readingC}`.
- Given the same idempotency key replayed, no duplicate excursion/holds/movements exist.

## Implementation Notes

## Spec Change Log

- **2026-09-25 (step-03 matrix audit, human-ratified):** matrix Replay row's mismatch cell corrected 409 → 422 `idempotency-key-reuse`. The original 409 was a spec-writing error against the repo-wide idempotency contract every sibling command follows; the implementation and its test were correct as built. Amended with the user's explicit approval ("Correct spec to 422").

## Review Triage Log

Iteration 0 — three layers (blind-hunter 20, edge-case-hunter 8, verification-gap 3+3) triaged 2026-09-25. No prior rows.

| # | Finding | Verdict | Evidence |
|---|---------|---------|----------|
| 1 | All-scopes-skipped excursion commits ledger-invisible; skipped scopes get no `excursion.recorded` event (blind B1/E2, edge claims-check) | **medium — patch** | Verified: no guard at the skip filter; the excursion row inserts with `holdIds: []` and zero events. The frozen Always bullet says one event per **affected** scope (affected = every on-hand SKU), which includes skipped scopes; the all-skipped case contradicts AD-11. Fix: emit the event for every affected scope; outbox `affectedSkus` covers all affected; update skip-test expectations; add an all-skipped test. |
| 2 | Record snapshot `createdAt` = business `occurredAt`, disagrees with the row's `created_at` that list/resolve report (blind B2, edge E5, verification O1) | **medium — patch** | Verified `excursion.command.ts:385` (`createdAt: occurredAt`) vs facade/resolve reading `canonicalInstant(row.createdAt)`; the happy path itself supplies a past `occurredAt`, so the disagreement is reachable on every client-timestamped record. Cursor field, too. |
| 3 | New read/commands' error arms and flows shipped untested: keyset pagination + `warehouseId` filter, malformed `occurredAt`, resolve replay, secure-bin 12-3 interplay, resolve role-denial, malformed Idempotency-Key, 404 unknown warehouse, note bounds (blind B14–B17, verification G1–G3) | **medium — patch** | Verification-gap findings arrive pre-verified (searches cited: no cursor/limit/warehouseId use in the suite; no malformed `occurredAt`; every resolve call uses a fresh key). Secure-bin and resolve-role gaps confirmed against the diff's test list. Patch: add the missing arms per the qc-holds/ledger spec precedents. |
| 4 | Empty/whitespace note refused with self-contradictory message (blind B6, edge E1, verification O2) | **low — patch** | Verified `excursion.command.ts:141`: `trim() === ''` throws while the DTO's `@Length(0,200)` allows it and the message offers "empty" as valid. Fix: treat empty/whitespace-only as absent (null). |
| 5 | `readingC` documented "at most two decimal places" but not enforced — 8.999 accepted, silently normalized (blind B5, edge E7) | **low — patch** | Verified DTO: `@IsNumber()` only. Fix: `maxDecimalPlaces: 2` (the command's 2dp normalization stays as backstop). |
| 6 | All-or-nothing refusal's `why` chosen by `.some(serialTracked)` — a bin with both classes justifies only the serial case (blind B7) | **low — patch** | Verified in the pre-flight. Direct correction: compose the reason from both applicable classes. |
| 7 | Hold reason silently truncates the note at 200 chars, no marker (blind B8) | **low — patch** | Direct correction: append an ellipsis when the slice cut. Note survives intact on the excursion row either way. |
| 8 | Record route's 403 arm omits the secure-bin `secure.move` refusal path (blind B13) | **low — patch** | The operator-on-secure-bin 403 is reachable and load-bearing (the 12-3 interplay); extend the OpenAPI 403 description. |
| 9 | Outbox payload `affectedSkus` carries only quarantined scopes (blind B12) | **low — folded into #1** | Renaming or widening is subsumed by the event-per-affected-scope fix: payload covers all affected skuIds, matching the events and the name. |
| 10 | FR-45 ledger-only reconstruction cannot explicitly link the excursion to its holds (qc.held refDoc lacks excursionId; `excursion.recorded` lacks holdIds) (blind B3) | **low — rejected** | Stock-state reconstruction is complete: the `qc.held` movements are themselves in the ledger. The explicit excursion→holds link lives in `temperature_excursions.hold_ids` per the frozen referenceDoc shape; making it ledger-explicit means changing the shared hold core's refDoc (placeHold has no excursionId) — a design change beyond a direct correction. |
| 11 | Resolve leaves no ledger trace (blind B4) | **false** | The frozen matrix routes resolve's trace through outbox `excursion.resolved` + audit + status flip; resolve is a review decision, not a stock movement, and the spec never claimed it as a ledger event. |
| 12 | Origin bin row locked twice in one tx (blind B11) | **low — rejected** | The second `.for('update')` on the same row in the same tx is a no-op re-lock; no semantics or measurable cost; removing it adds parameter plumbing to the shared core. |
| 13 | Controller helpers are local forks (blind B9) | **false** | Verified precedent: identical file-local `assertUuidParam`/`assertOwnTenantToken` exist in receiving/inbound/outbound/devices/carriers/putaway controllers — compliance follows the established idiom. |
| 14 | `writeIdempotencyKey` duplicated verbatim with qc.command (blind B10) | **false** | Verified precedent: the same self-contained helper exists in 10 command files across six modules — the type-boundary discipline keeps commands self-contained; extraction is a cross-cutting refactor, not this story. |
| 15 | Unrelated 12-4 generated-client doc drift rides in the FE diff (blind B19) | **false** | Regen is required to mirror the current BE openapi; the comment-only drift is 12-4's final BE export reaching the FE client late. Splitting generated drift out of the story's regen commit would be artificial. |
| 16 | New files lack trailing newlines (blind B20) | **false** | The repo's existing files (receiving.controller.ts, qc.command.ts, ledger-registry.ts, qc-holds.spec.ts) also lack them — the new files match the convention. |
| 17 | Unknown SKU in bin → 404 mid-loop, undocumented arm (edge E3) | **false** | The SKU pre-flight loads `skuRows` before any write and refuses the excursion with 400 validation-failed before the loop; the hold core's own sku read is defence in depth that cannot fire on a verified-present SKU. |
| 18 | Duplicate (sku,bin) rows → duplicate scopes → 409 (edge E4) | **false** | `stock_on_hand_scope_unique` uniqueIndex on the (sku, bin) scope makes duplicate rows impossible. |
| 19 | CI drift guard doesn't pin the 0038 status CHECK (verification O3) | **defer** | Pre-existing infra limitation: `verify.ts` round-trips only `app_metadata` — not changed by this story, and nothing in the code path can violate the CHECK (command writes only 'open'/'resolved'). Recorded in deferred-work.md. |

Patched groups (cascade: no intent_gap / bad_spec → all four patch groups proceed): #1 (skip-arm ledger semantics, medium), #2 (createdAt snapshot, medium), #3 (verification gaps, medium), #4–#8 (low corrections). One deferral (#19).

## Design Notes

**Why compliance module + reuse, not a side book:** AD-6/AD-11 name the ledger the single excursion record; the epic pins quarantine to "the existing QC-hold/quarantine semantics". A `temperature_excursions`-only design would fork hold semantics and strand release/ATP/merge-guards; extending `inventory_quarantines` would conflate a projection-divergence mechanism with a quality one. The extracted `holdScopeInTx` keeps one implementation — `placeHold` must remain behavior-identical (its suite pins it).

**Table shape:** `id, tenant_id, warehouse_id, bin_id (origin), reading_c numeric(6,2), note text null, hold_ids uuid[] not null, status text ('open'|'resolved'), recorded_by uuid, occurred_at timestamptz, resolved_by uuid null, resolved_at timestamptz null, tenantTimestamps`. `hold_ids` links the queue item to its holds without touching `qc_holds` (compliance never writes another module's table).

**Event shape (per affected scope):** `type 'excursion.recorded'`, `quantityDelta: 0`, `fromBinId/toBinId: null`, `batchRef: null`, `skuId: <scope SKU>`, `referenceDoc {kind:'excursion', excursionId, binId, readingC}`.

**Resolve-without-release rationale:** the review decision (was this excursion real, what is the disposition) is `review.decide`'s; releasing stock is `qc.manage`'s and already exists. Equal role sets today, but the verbs stay separate so a future matrix change answers each question in the open.

## Verification

**Commands:**
- `cd workspace/core/backend/wms-be && bun test` -- expected: all pass, including the new spec and the untouched `qc` suite
- `bunx tsc --noEmit && bun run lint` -- expected: clean
- `bun run openapi:export` -- expected: 3 new routes present, diff limited to 12-5 surface
- `cd ../frontend/wms-fe && bun run api:generate && bun run test && bunx tsc --noEmit` -- expected: regen clean, mirror test green
- `cd workspace/core/backend/wms-be && bun run db:migrate` -- expected: 0038 applies cleanly (the CI migrations job's round-trip drift guard is the real check)