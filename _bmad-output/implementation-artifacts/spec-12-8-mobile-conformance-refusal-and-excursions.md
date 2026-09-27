---
story: 12-8-mobile-conformance-refusal-and-excursions
title: 'Story 12-8: Mobile conformance refusal + excursion capture (UX-DR29/30)'
status: done
review_loop_iteration: 1
epic: 12
context:
  - '_bmad-output/implementation-artifacts/epic-12-context.md'
  - 'docs/design/SYSTEM-DESIGN.md'
  - 'docs/design/IMPLEMENTATION-GUIDE.md'
  - 'docs/design/modules/catalog.md'
  - 'docs/design/modules/putaway.md'
  - 'docs/design/modules/compliance.md'
  - 'docs/design/mobile/SYSTEM-DESIGN.md'
  - 'docs/design/mobile/IMPLEMENTATION-GUIDE.md'
  - 'docs/design/API-SURFACE.md'
  - 'docs/design/PENDING.md'
---

<frozen-after-approval>

## Intent

Two epic-12 UX decisions, both about the cold chain the floor actually touches:

**UX-DR29 (conformance refusal).** A non-conforming putaway or pick rejects in **< 500 ms with the ✕ Rejected banner** (UX-DR4), names both parties and the rule, and offers the nearest conforming location. It evaluates **on-device where the storage class is in the cached snapshot**, so it works in a dead zone. Rejected scans never queue. Rationale: a conformance refusal the floor never sees is a cold-chain break the backend correctly prevented.

**UX-DR30 (excursion capture).** An operator records a temperature excursion against a location (the handling-unit arm is Epic 15) **from the task screen**; affected stock shows a quarantine badge everywhere it appears (web, 12-7); the excursion lands in the Conflicts & Reviews queue (UX-DR11) with the reading, affected units and ledger context.

The server stays the authority (AD-14/AD-18); the device is the fast mirror. Offline, a non-conforming placement is refused at the operator's hands instead of queueing into a replay-time 400 that drops from the outbox with only a summary line for a record. And an excursion captured in a dead zone still queues and lands in the web review queue on replay — capture must work offline, resolution stays web-side.

## Boundaries

**In scope:**
- **BE (additive, lands first):** the device catalog snapshot gains `storageClass` on the SKU arm and on the bin arm (the field already exists on both rows; only the snapshot DTO omits it). `POST /tenants/{t}/excursions` gains a device-session arm (badge-in) so the floor can record excursions — with the device row re-resolved so revocation bites. OpenAPI regenerated.
- **Mobile:** a pure conformance mirror module (`storageClassSatisfies`, `isBulkAssetType`); the snapshot parse grows the two nullable fields; the putaway draft's `evaluateBin`/`canConfirm` gains the storage-class refusal arm and the bulk-asset reason steering; the pick draft gains the draw-bin conformance refusal; a new `excursion.record` op type + a pure excursion draft + a capture sub-mode mounted from the putaway and pick task screens; the replay `settledNote` arm for a settled excursion.
- **Meta docs:** the three stale PENDING wms-mobile entries deleted (see Design Notes 8); the interface contracts updated.

**Out of scope (deferred, with reasons):**
- **Hazard co-location on-device** — needs the target bin's occupants, which the snapshot does not carry (`handlingUnits` is `{id, skuId}` only, no bin). Left to the server; a replay-time `400 bin-segregation-conflict` classifies as ordinary **rejected** (dropped, summary line) per the AD-14 taxonomy. This is deliberate: UX-DR29 says "where the storage class is in the cached snapshot" — hazard is not.
- **Handling-unit excursion arm** (Epic 15), excursion resolve on mobile (web-only, `review.decide`), threshold/auto-detection (AD-11: manual capture only).
- **PENDING finding 1** (a badge-in token satisfies `TenantSessionGuard`): not fixed here — but the device excursion arm must NOT ride that accident; it goes through proper device-session semantics (Design Note 4).
- **Connectivity detection, durable rejected-op inbox, hand-written api.ts → generated client, scan-budget measurement** — pre-existing PENDING items, untouched.
- **Web surfaces** — none; 12-7 already shipped the queue and the trace.

## Input–Output matrix

| Repo | Inputs (files the agent loads via `context:`) | Outputs |
| --- | --- | --- |
| wms-be | BE IMPLEMENTATION-GUIDE, putaway.md, compliance.md, catalog.md | `src/modules/catalog/catalog.facade.ts` (SkuSummary + select), `src/modules/inbound/receiving.dto.ts` (CatalogSnapshotSkuDto), `src/modules/putaway/putaway.facade.ts` (PutawayBinSummary + select), `src/modules/putaway/putaway.dto.ts` (PutawayBinDto), `src/api/compliance.controller.ts` (+ a device-session acceptance mechanism), `src/modules/compliance/excursion.command.ts` (+ `deviceId` + in-tx device re-auth), `openapi/openapi.json` regenerated, new tests |
| wms-fe | the regenerated OpenAPI client (additive, after the BE merge) | regenerated client files only (the CI drift guard fails until this lands) |
| wms-mobile | mobile HLD + LLD (§1 seven edits, §3 replay, §4 snapshot growth, §9 checklist) | `src/lib/conformance.ts` + test, `src/api.ts` (+2 fields, +1 fetch, +2 interfaces), `src/state/catalog-snapshot.ts` (defaults + legacy-seal arm), `src/putaway/draft.ts` + test, `src/picking/draft.ts` + test, `src/compliance/draft.ts` + test (new), `src/components/excursion-capture.tsx` (new), `src/offline/types.ts`, `src/state/op-dispatch.ts`, `src/state/replay-classification.ts`, `app/putaway.tsx`, `app/pick.tsx`, `src/scanning/engine.ts` (stale prose) |
| wms-meta | this spec, PENDING, module docs | spec + triage log, `docs/repos/wms-be/README.md`, `docs/repos/wms-mobile/README.md`, `docs/design/API-SURFACE.md`, `docs/design/PENDING.md` (3 stale entries), module docs if seams moved |

## Code Map

### BE — snapshot growth (purely additive)

The snapshot's two arms select the storage classes beside the fields 12-8's on-device gate reads them beside:

1. **SKU arm** — `getSkuSummariesInTx` (`catalog.facade.ts:257-282`) selects `storageClass` beside `variantValues`; `SkuSummary` (`catalog.facade.ts:116-156`) and `CatalogSnapshotSkuDto` (`receiving.dto.ts:449-503`) carry it. The column exists (`schema.ts:426`).
2. **Bin arm** — `getBinSummariesInTx` (`putaway.facade.ts:391-401`) selects `storageClass` beside `type`; `PutawayBinSummary` (`putaway.facade.ts:84-93`) and `PutawayBinDto` (`putaway.dto.ts:242-266`) carry it. The column exists (`schema.ts:264`).

No consumer of the snapshot breaks: the response only grows. The mobile side treats absence as "older seal" (below).

### BE — excursion record device arm

`POST /tenants/{t}/excursions` (`compliance.controller.ts:50-93`) today guards with `TenantSessionGuard` only — a web JWT. UX-DR30 needs the floor to record. **Mechanism:** the route accepts **either** session family on the one route (never a second alias route). The branch key is **frozen**: the guard branches on the **presence of the `device_id` claim** — a badge-in token verifies under the tenant-JWT verifier too (`verifyTenantSession` ignores `device_id` entirely, the PENDING-1 accident), so a composite that tries the tenant family first silently routes every device token down the web arm and revocation never bites, with every typed-token test staying green. Device-claim-present → device semantics; absent → web semantics. OpenAPI documents both schemes on the route.

**The device re-authorization lives in the command, mirroring the house pattern** (`putaway.command.ts:255-266`, the grn.submit mirror): `RecordExcursionCommand` gains `deviceId: string | null` (the web path sends null and skips the arm), and the in-tx device re-auth arm — `tx.select().from(devices).where(...).for('update')`, non-active or unbadged → `403 device-revoked` — runs when `deviceId !== null`. The guard deliberately cannot do this (`device-session.guard.ts:33-36`: resolution happens in the command's tenant transaction). A bare (unbadged) enrollment credential carries `userId: null`, which `actorUserId: string` cannot take — the device arm is **badge-in required**, refused like every other device route. The rest of the command is unchanged: payload hash, replay, in-tx role re-read + `assertPermission('excursion.record')` (operator/ops_manager/owner; accountant empty — pinned at `users.spec.ts:845`), warehouse/bin reads, sweep, pre-flight, holds, row, ledger events are all session-agnostic.

Errors: the existing arms plus the device arms — `400 validation-failed` (bounds/precision/note, system-owned bin, empty bin, serial/catch-weight offenders named) · `401 unauthenticated` (bare credential) · `403 role-denied` (`excursion.record`, or `secure.move` on a secure-class bin) / `device-revoked` / `permission-denied` · `404 not-found` · `409 conflict` · `422 idempotency-key-reuse`. There is **no 409 for already-held scopes** — they are skipped for quarantine, not refused.

### Mobile — the mirror and the gates

**`src/lib/conformance.ts` (new, pure, dependency-free).** Mirrors the shared primitives, in the same order as the server's suggestion filter:

- `STORAGE_CLASSES = ['ambient','chilled','frozen','controlled','hazardous','secure']` and `TEMPERATURE_RANK = { ambient: 1, chilled: 2, frozen: 3 }` — parity-tested against the server vocabulary.
- `storageClassSatisfies(skuClass, binClass)` — exact `true` when equal; temperature classes: a **colder bin over a warmer SKU** satisfies (`binRank > skuRank`); `controlled`/`hazardous`/`secure` exact-match only (rank 0 deliberately unused — the server's comment at `storage-class.ts:54-59` is mirrored).
- `BULK_ASSET_TYPES = ['tank','silo']` + `isBulkAssetType(type)` — mirrors `location-type.ts:75,90-115`.

Refusal copy follows the server factory's **semantics, not its bytes**: `binStorageMismatch` (`storage-class.ts:114-126`) renders bin-first with the hierarchy's actual rule (a colder bin satisfies a warmer SKU; frozen stock is frozen-only). The device banner states the same facts in scan-order, verbatim in the spec so T5's test pins the exact string: `SKU {skuCode} ({skuClass}) needs {skuClass} storage — bin {binCode} is {binClass} — the scan is not recorded` (putaway; the pick screen says "bin {binCode} you drew from is {binClass}" instead of "bin … is" and offers no suggestion), plus, when the task carries a suggestion: `Suggested: {suggestedBinCode}`. The suggestion **is** the nearest conforming location — the server's `candidateFitsSku` (`putaway.command.ts:1091-1140`) pre-filters suggestions by storage class first, bulk-asset never suggested, hazard second; so the directed-putaway suggestion is conforming w.r.t. everything the device can check, and UX-DR29's "offers the nearest conforming location" is satisfied by pointing at it.

**Snapshot parse (`catalog-snapshot.ts`).** `CatalogSku.storageClass?: string | null` and `CatalogBin.storageClass?: string | null`; defaults `?? null` in `parseCatalogSnapshot` beside the 10-6 SKU defaults — the **10-6 precedent (added keys with defaults), not the 11-7 one** — with the comment naming the rule: **absent = an older seal — the device cannot verify, so it stays silent and the server still gates** (fail-open, never a false refusal that blocks a conforming floor). A `null` after the default means "the server answered no class" — same treatment. Because the defaults add keys, the 11-7 exact-equality legacy-seal assertion (`device-store.test.ts:130-141`) gains `storageClass: null` in its expected SKU and bin objects — an explicit, pinned update, never a silent widening.

**Putaway (`src/putaway/draft.ts`).** The decision is frozen: `evaluateBin`'s signature grows to take the caller-resolved SKU class — `evaluateBin(draft, bin, skuClass: string | null)` — because the draft has no snapshot access and `CatalogPutawayTask` carries no class; the screen (`app/putaway.tsx`, which holds the snapshot) resolves `snapshot.skus` by `draft.task.skuId` and passes it. The arm runs **after** the existing `systemOwned`/`blocked` checks and **before** the mismatch computation: when `skuClass` and the scanned bin's class are both non-null and `!storageClassSatisfies(skuClass, binClass)` → `{ kind: 'rejected', detail }` (the ✕ banner; nothing queues). `canConfirm` (:190-195) gains the bulk-asset steering: when the target bin's `type` is a bulk asset, confirm requires `reasonCode === 'bulk-asset'`; choosing `bulk-asset` on an ordinary bin is refused at choose-time (banner: the reason applies only to a tank or silo). This closes the PENDING 12-4 defer: the operator steering stock into a tank is steered on-device, not at a replay-time 400. The screen renders the refusal through the existing `ScanBanner` rejected state (putaway.tsx:137-155 pattern), microcopy ending "— the scan is not recorded".

**Pick (`src/picking/draft.ts`).** `evaluateBin` (:201) gains the same storage-class arm for the draw bin vs the task's SKU (no suggestion offer — the plan owns the bin; a non-conforming plan bin is a re-planning conversation, not a location the device picks). Also surfaced in `confirmBlocker` (:601) so a confirm with a null-class-skipped gate still passes through the server's own 12-1 gate unchanged.

**Excursion capture.** Seven-edit recipe, minus the edits that don't apply (no new screen, no inbox tab — it is a sub-mode, not a task type):

1. `src/offline/types.ts:31-37` — `OpType` gains `'excursion.record'`, with the block comment extended: it is an operator-recorded compliance fact, not a task type; `pick.task` remains the exhaustiveness proof.
2. `src/api.ts` — `ExcursionRecordPayload` mirrors `RecordExcursionDto` field for field (`warehouseId, binId, readingC, note: string | null, occurredAt`) and `ExcursionRecordResponse` mirrors `ExcursionSnapshot`'s wrapper field for field: `{ excursion: { id, tenantId, warehouseId, binId, readingC, note: string | null, holdIds: string[], status: 'open' | 'resolved', recordedBy, occurredAt, resolvedBy: string | null, resolvedAt: string | null, createdAt } }`; one `fetchApi…` POST `/tenants/{t}/excursions` (device token, idempotency key = the op's ULID).
3. `src/state/op-dispatch.ts` — `OpSenders` + `defaultOpSenders` + `sendOp` branch (the `never` at :112 fails the build until added — the compile gate).
4. `src/compliance/draft.ts` (new, pure, sync — same constitution as the other drafts): state machine `bin → reading → note → confirm`; validation mirrors the DTO exactly — reading within −100..200 at ≤ 2 decimals (reusing `src/lib/quantity-input.ts`'s parse helpers), note ≤ 200 (whitespace-only → null before the payload, mirroring the server's pre-hash normalization), `occurredAt` **stamped at capture**, never at replay. Pre-checks from the snapshot: bin known, not `systemOwned`. **Not pre-checked on-device** (no bin occupancy in the snapshot): empty bin, serial/catch-weight offenders, secure-class `secure.move` authority — those are server arms; their replay-time 400/403 classifies as ordinary **rejected** (dropped from the outbox, summary line only) per the AD-14 taxonomy, and that is correct: a refused excursion created no holds, so nothing belongs in the web queue — the operator reads the ✕ summary and re-records.
5. `src/state/replay-classification.ts` — `settledNote` (:66-86) gains an `excursion.record` arm rendering from the response's `holdIds` — the holds **created this call**, one per (sku, bin) scope, which can be **empty on a successful record** (scopes already under an open hold are skipped, not refused): non-empty → `Excursion recorded — N hold(s) created`; empty → `Excursion recorded — no new holds; affected scopes were already held`. Never "unit(s)": a scope can cover many units, and the hold count is what the response actually carries. No new fate branches: every excursion failure code falls into the existing catch-all deliberately.
6. `src/components/excursion-capture.tsx` (new shared component) + entry points: a ghost button **"Record an excursion"** in the putaway entry-step block and the pick confirm block (the short-pick ghost-button pattern, `pick.tsx:677-687`), flipping the screen into a capture sub-mode. The bin is pre-filled from the current context (the putaway draft's bin; the pick task's bin) and re-scannable; reading is a precision-aware numeric field; note is optional. Confirm enqueues `excursion.record` (banner: ↻ queued) and returns to the task step. Works fully offline — the op queues and replays like any other.
7. `src/scanning/engine.ts:101-103` — the stale "no task types are live yet" rejection prose is rewritten to name the actual substrate contract (the PENDING-diagnosed staleness, one comment).

## Tasks & Acceptance

**T1 — BE snapshot growth.** `storageClass` selected and typed on both snapshot arms (Code Map §BE-1), OpenAPI regenerated. Acceptance: the snapshot route's response carries the classes for seeded data; a test pins the SKU arm and the bin arm values against the seeded classes; BE typecheck/lint/tests pass.

**T2 — BE excursion device arm.** The guard branches on the `device_id` claim (the frozen mechanism above); `RecordExcursionCommand` gains `deviceId: string | null` with the in-tx device re-auth arm (the putaway mirror); badge-in required on the device path. Acceptance: a badge-in → record e2e (badge-in → POST excursion → 201, QC holds + zero-delta `excursion.recorded` events committed) passes; revoked device → `403 device-revoked`; bare (unbadged) credential → refused (the badge-in-required arm, explicitly asserted); accountant session → `403 role-denied`; web-JWT path unchanged (existing excursion suite passes untouched); the web-queue/trace reads are untouched.

**T2b — FE client regeneration.** After the BE merge, regenerate the wms-fe generated client from the new `openapi.json` (additive-only diff) in a small wms-fe commit. Acceptance: the FE `generated-client` CI job passes; no hand-edits to generated files.

**T3 — Mobile conformance mirror.** `src/lib/conformance.ts` + `conformance.test.ts` pinning the `STORAGE_CLASSES` order, the `TEMPERATURE_RANK` truth table (all 36 class pairs), and `BULK_ASSET_TYPES`, each with a comment naming the server file it mirrors. Acceptance: the mirror's truth table includes the asymmetric temperature arms (colder bin over warmer SKU satisfies; warmer bin over colder SKU refuses) and the exact-match-only trio.

**T4 — Mobile snapshot growth.** The two optional fields + parse defaults (`?? null`, the 10-6 precedent) + legacy-seal arm, **including the explicit update to the 11-7 exact-equality expectation** (`device-store.test.ts:130-141` gains `storageClass: null`). Acceptance: an older seal parses with classes `null` (the updated equality pin); a new seal parses with classes populated; device-store tests pass.

**T5 — Putaway refusal + bulk-asset steering.** `evaluateBin(draft, bin, skuClass)` storage-class arm (the caller-resolved parameter decided above), `canConfirm`/`chooseReason` bulk-asset steering, banner copy verbatim per the Code Map. Acceptance: draft tests pin — conforming placement accepted; class-mismatched scan rejected with the exact spec'd copy (both parties + both classes + the rule) plus the suggestion line, and nothing enqueued; null-class (old seal) falls through open; tank/silo bin without reason `bulk-asset` cannot confirm and with it can; `bulk-asset` on an ordinary bin is refused at choose-time; the reason mirror parity test still passes.

**T6 — Pick refusal.** `evaluateBin` + `confirmBlocker` arms in the picking draft. Acceptance: draft tests pin the class-mismatched draw bin refusal (both parties + the rule, no suggestion) and the null-class fall-through.

**T7 — Excursion op plumbing.** OpType + api.ts + op-dispatch + replay-classification settledNote. Acceptance: `sendOp` compiles (the exhaustiveness gate); an engine-level cross-type replay test sends `excursion.record` and settles it; a classification test pins the 400/403 excursion failures to `rejected` (dropped, summary only).

**T8 — Excursion capture sub-mode.** The pure draft + shared component + the two screen entry points. Acceptance: draft tests pin the full state machine — bin pre-fill and re-scan, reading bounds (−100.00 / 200.00 edge values accepted; 200.01, −100.01, 3-decimal refused), whitespace-note normalization to null, `occurredAt` captured at confirm time; a screen-level flow puts an excursion op in the outbox from the putaway screen offline (banner ↻), matching the manual-switch offline test convention.

**T9 — Stale prose.** `engine.ts:101-103` rewritten. Acceptance: no test reads the prose; the comment no longer claims task types are unimplemented.

**T10 — Meta docs.** Contracts + API-SURFACE rows + PENDING cleanup (the three stale uomPrecision/scan-loss entries deleted; the bulk-asset pre-check entry closed as done-by-12-8; the excursion device arm recorded). Acceptance: `docs/repos/wms-mobile/README.md` and `docs/repos/wms-be/README.md` state the new snapshot fields and the device arm; API-SURFACE's excursion record row documents the device session.

## Acceptance

- AC1: A putaway scan of a class-mismatched bin is refused on-device in the ✕ Rejected banner — both parties, both classes, the rule, and the suggested bin — and **nothing is enqueued** (the outbox shows no op), in a test that runs the draft with no awaits (the budget is structural).
- AC2: A pick of a class-mismatched draw bin is refused the same way (no suggestion offer), before anything queues.
- AC3: The bulk-asset reason is steered on-device both ways (required on tank/silo, refused elsewhere), closing the PENDING 12-4 pre-check gap.
- AC4: An older seal (no classes) keeps today's behavior exactly — the gates stay silent and the server remains the only gate; pinned by the legacy-seal equality test.
- AC5: An excursion recorded from a task screen in a dead zone queues as `excursion.record` with `occurredAt` at capture; on replay it settles with holds + ledger events and the sync summary renders the quarantine note; the excursion and its holds appear in the web Conflicts & Reviews queue.
- AC6: A device-revoked replay flips the phase to revoked (the existing arm, unchanged); a refused excursion (400/403/404) drops from the outbox per the taxonomy with the summary line as the only record.
- AC7: The server's own gates (12-1 class, 12-2 hazard, 12-3 secure, 12-4 bulk) are untouched — the device mirror adds no authority and removes none.

## Design Notes

1. **The decidability boundary is static-data-driven.** UX-DR29's "where the storage class is in the cached snapshot" is implemented literally: storage-class conformance needs only (SKU class, bin class) — both static snapshot rows — so it is decidable in a pure synchronous helper. Hazard co-location needs the bin's occupants; `handlingUnits` is `{id, skuId}` with no bin, so it is **not** in the snapshot and stays server-side. This is the LLD §4 rule applied honestly: anything the device must refuse in < 500 ms is IN the snapshot; everything else queues-and-finds-out — and the taxonomy catches it.
2. **"Nearest conforming location" = the directed-putaway suggestion, not a new search.** The server's `candidateFitsSku` already orders candidate filters storage-class-first, bulk-asset-never, hazard-second, then capacity/weight/volume/dim — so `suggestedBin` is conforming **as of the seal**. Offering a different "nearest" bin would mean a second suggestion engine on the device that would drift from the server's; pointing at the suggestion is exact and free. One staleness caveat, stated so the AC1 test does not over-promise: a SKU's class edited after sealing makes the device-offered suggestion non-conforming until the next snapshot refresh — the server re-gates, so nothing unsafe ships, and the banner copy asserts the rule, never a unconditional guarantee about the suggestion. The pick refusal offers no location because the operator cannot choose pick bins — the plan does.
3. **Fail-open on an older seal.** Classes default to `null`, and every gate runs only when both sides are non-null. A false on-device refusal blocks a conforming floor in a dead zone — worse than the queue-and-find-out it replaces — so absence of data must never produce a refusal. The server gates everything regardless, so fail-open loses nothing but latency.
4. **The device excursion arm goes through device-session semantics, not the TenantSessionGuard accident.** PENDING finding 1 (verified): a badge-in token shape-passes `verifyTenantSession` because the JWT families share the secret and the validator never rejects `device_id`. Building 12-8's device arm on that would inherit the defect's blast radius — revocation does not bite on endpoints that never re-resolve the device row. The composite acceptance keeps the device path on `DeviceSessionGuard` semantics (row re-resolution → revocation works), which also narrows finding 1's practical reach: after 12-8, the floor's excursion path is revocation-safe regardless of when finding 1 itself gets fixed.
5. **A refused excursion is absent from the web queue, and that is correct.** The Conflicts & Reviews queue lists excursions the server accepted (the row + its holds). A replay-time refusal means the server never recorded it — no holds, no ledger events, nothing to review. The device's summary line is the operator's feedback, matching the existing rejected-op UX. No new device-side durable record is introduced for refusals.
6. **`occurredAt` is business time at capture.** The command hashes `occurredAt` as sent; a device that stamps at replay would falsify the reading's instant and the cold-chain trace's dwell-window correlation (12-6). Stamping at capture keeps the ledger's business time honest in a dead zone.
7. **The uomPrecision rider is dead, and that is a PENDING correction, not a scope cut.** The mobile recon found — and I verified first-hand — that 10-6 already ships `uomPrecision` end to end on-device (`api.ts:572`, parse defaults at `catalog-snapshot.ts:24-30`, consumed in receiving/putaway/pick/pack with the precision-aware parse). LLD §6 and two PENDING entries predate it. Deleting stale PENDING entries is part of T10; the LLD §6 text gets a one-line staleness note in the same commit.
8. **The replay scan-loss PENDING entry is also stale.** It demands "a single-flight promise on `replay()`" — `src/state/replay-gate.ts` (10.6) is exactly that, and `deviceStore.replay()`/`enqueueOp` route through it. Deleted in T10 with the others.
9. **Ordering.** BE first (T1-T2), FE client regeneration second (T2b — the CI drift guard fails until it lands; this is the known cross-repo pattern, expected every story), mobile third (T3-T9), meta last (T10) — the snapshot fields must exist for the mobile gates to have data, and the mobile contract update cites the BE DTO.

</frozen-after-approval>

## Design Review Triage Log

One design-review pass over the frozen spec (reviewer verified every load-bearing claim against the code; 14 claims verified clean, including the storage-class predicate, the suggestion filter order, the DTO gaps, the replay taxonomy fall-through, the outbox's unconstrained `type` column, the synchronous scan-refuse path in both screens, and the seven-edit completeness for a sub-mode). Findings, all verified first-hand by the orchestrator where marked (✓):

| # | Sev | Finding | Verdict | Disposition |
| --- | --- | --- | --- | --- |
| 1 | high | The device-row re-resolution has no home: `RecordExcursionCommand` has no `deviceId`, and the house pattern re-resolves in-tx **inside the command** (`putaway.command.ts:255-266`); the guard deliberately cannot (device-session.guard.ts:33-36) | ✓ confirmed | Spec amended: command gains `deviceId: string | null` + the in-tx re-auth arm (web path sends null, skips the arm); I/O matrix gains `excursion.command.ts` |
| 2 | high | A composite guard trying the tenant family first routes every device token down the web arm (`verifyTenantSession` ignores `device_id`) — the PENDING-1 accident one naive implementation away, with typed-token tests staying green | ✓ confirmed (PENDING finding 1, previously verified) | Mechanism frozen in the spec: branch on the `device_id` claim; T2 acceptance requires a badge-in e2e asserting device semantics incl. revocation |
| 3 | high | Settled-note copy wrong twice: `holdIds` counts scopes, not units; and it can be **empty on success** (all scopes already held → skip arm, row still commits) | ✓ confirmed (compliance.md skip arm + `holdIds` = holds created) | Copy reworded to hold/scope semantics with an explicit empty arm |
| 4 | medium | Bare-credential arm omitted: an unbadged enrollment token carries `userId: null`, which `actorUserId: string` refuses | ✓ plausible (matches the other device routes' badge-in-required pattern) | Badge-in-required arm added to the contract and T2's acceptance |
| 5 | medium | Legacy-seal wording conflated the 10-6 (keys added with defaults) and 11-7 (parse untouched) precedents; a `?? null` default breaks the 11-7 exact-equality pin at `device-store.test.ts:130-141` | ✓ confirmed (read the pin — it asserts exact SKU equality) | Precedent frozen to 10-6 (`?? null`); the 11-7 expectation update made explicit in the spec and T4 |
| 6 | medium | wms-fe's `generated-client` CI job fails on OpenAPI drift; T1 regenerates the BE spec but no task regenerated the FE client (wms-fe absent from the I/O matrix) | ✓ confirmed (known pattern — the FE drift guard fails until BE merges, per this project's standing memory, and the FE regen must follow) | T2b added; wms-fe row added to the I/O matrix; ordering note updated |
| 7 | medium | Putaway `evaluateBin(draft, bin)` has no snapshot access, so the spec'd arm is not expressible as written — an implicit decision left untaken | ✓ confirmed (picking side is fine — its resolvers take the snapshot) | Decision frozen: the signature grows to `evaluateBin(draft, bin, skuClass)`, caller-resolved in the screen |
| 8 | low | "Byte-matches the factory" was false — the factory renders bin-first with different rule wording | confirmed | Reworded to "semantics, not bytes"; the device copy is now quoted verbatim for T5's test |
| 9 | low | Stale line refs (the `never` is at `op-dispatch.ts:112`; the union at `types.ts:31-37`); `ExcursionRecordResponse` mirror was ellipsized | confirmed | Refs refreshed; the mirror spelled out field for field |
| 10 | low | Design Note 2's "exact and free" ignored seal-time staleness (a class edited after sealing makes the offered suggestion non-conforming until refresh) | confirmed | Caveat sentence added; the banner asserts the rule, never an unconditional guarantee about the suggestion |

All 10 findings applied to the spec before the design commit; nothing deferred.

## Code Review Triage Log

Three review layers ran synchronously over the implemented diffs (blind-hunter, edge-case-hunter, verification-gap). 23 raw findings consolidated into 20 rows. The non-verification-gap findings were verified first-hand by the orchestrator before triage (✓). The three layers independently converged on the two mediums below, which is itself evidence.

| # | Sev | Finding (source) | Verdict | Disposition |
| --- | --- | --- | --- | --- |
| 1 | high | The reading field's `keyboardType="decimal-pad"` cannot type a minus — a −18.5 °C freezer reading, the story's core case, is unreachable on the on-screen keyboard (edge) | ✓ confirmed | P1 — keyboardType change + comma-decimal normalization in the draft's sanitize |
| 2 | medium | Refusal suffix double-appended: `pick.tsx:179` appends unconditionally over a self-suffixed draft copy; `putaway.tsx`'s `endsWith` guard misses the Suggested arm (the string ends with the suggestion line, not the suffix) (edge + blind, independently) | ✓ confirmed both sites | P2 — contains-based guard in both screens; frozen draft copy unchanged |
| 3 | medium | Bulk-asset steering bypassable: reason chosen on a tank survives a re-scan onto an ordinary mismatched bin (`chooseBin` keeps it), `canConfirm` falls through to `reasonCode !== null`, the op queues a guaranteed replay-time 400 (edge + blind, independently) | ✓ confirmed | P3 — the symmetric arm in `canConfirm` + test |
| 4 | high | T8's screen-level flow acceptance has no test and cannot have one: the repo has zero component/screen test convention; the capture component's enqueue path is unverified (verification-gap + blind) | ✓ confirmed (repo convention) | T8's acceptance recorded as satisfied at the engine+draft level per repo convention; component-test infrastructure deferred to PENDING |
| 5 | high | AC1/AC2's "nothing is enqueued" unasserted and the caller-resolved `skuClass` wiring untested — a screen passing null unconditionally would pass all 316 tests (verification-gap) | ✓ confirmed | P4a — the resolution extracted into a tested pure helper (`skuClassForTask`) used by the screen; the screen-render remainder defers with row 4 |
| 6 | high | T4's bin-arm legacy `?? null` default unpinned — the 11-7 fixture has `bins: []`, so the bin default could regress to passthrough silently (verification-gap) | ✓ confirmed (read the fixture) | P4b — legacy-seal test with a class-less bin row, asserted by equality |
| 7 | medium | The badge-in e2e's title claims `recordedBy the badged operator` but never asserts it (verification-gap + blind) | ✓ confirmed | P6 — assertion added |
| 8 | medium | AC5's "appears in the web Conflicts & Reviews queue" untested for the device path (verification-gap) | ✓ confirmed | P7 — listExcursions read after the badge-in record |
| 9 | medium | No op-dispatch routing test for `excursion.record` — every sibling type has one; the idempotency-key-is-op-id test omits it (verification-gap) | ✓ confirmed | P5 |
| 10 | medium | Cross-repo shape drift (BE snapshot ↔ mobile hand-written `api.ts`) fails nothing on either side (verification-gap) | ✓ confirmed (pre-existing debt) | Deferred — the existing PENDING hand-written-api.ts entry covers it |
| 11 | medium | The snapshot SKU arm is pinned only at `'ambient'` via `arrayContaining` — a facade hardcoding 'ambient' would pass; the bin arm pins a real chilled value (verification-gap) | ✓ confirmed | P8 — a non-ambient SKU pinned by value |
| 12 | low | Contradictory comment in `receiving.facade.ts` ("null when unset" vs "Never null on the wire") (blind) | ✓ confirmed | P9 — comment fixed |
| 13 | low | 409 `conflict` for `excursion.record` classifies rejected/dropped but is effectively unreachable from the device (single-flight + fresh ULIDs); nothing is lost (edge) | ✓ confirmed clean | No action; noted |
| 14 | low | Putaway-target prefill biases excursion capture toward the empty-bin 400 (the target bin rarely has stock) (edge) | ✓ plausible | Deferred to PENDING (the source bin isn't in the snapshot) |
| 15 | low | A system-owned prefill bin is dropped silently with no banner (edge) | ✓ confirmed (cosmetic) | Deferred to PENDING |
| 16 | low | An excursion enqueued mid-replay waits for the operator's next action to send (no connectivity trigger anywhere) (edge) | ✓ confirmed (pre-existing for every op type) | Deferred — the existing PENDING connectivity entry covers it |
| 17 | low | No device-arm e2e for a secure-class bin or a badged accountant (the arms run family-agnostic code) (verification-gap) | ✓ confirmed | Deferred to PENDING |
| 18 | low | The component's `occurredAt` confirm-stamp rests on code review of an untested component (verification-gap) | ✓ confirmed | Deferred with row 4 |
| 19 | low | The settled-note empty arm is pinned at unit level only, never rendered (verification-gap) | ✓ confirmed | Deferred with row 4 |
| 20 | low | The parity pins are literals — drift is caught only when a human updates the pin (verification-gap) | ✓ confirmed (mechanism note, not a defect) | No action — the correct mechanism absent a cross-repo checker |

Clean-verdict highlights from the blind layer: the guard has no bypass (claim-injection fails closed to `device-revoked`; the web path is byte-identical in semantics); the device arm sits exactly on the putaway skeleton (a revoked replay gets 403, the house semantics); `deviceId` is excluded from the payload hash correctly (pre-12-8 keys replay); the mirror is semantically identical to the server predicate with the 9-pair conforming set pinned; the excursion plumbing, null arms, and the 36-pair table all verify.

Patches P1-P9 were dispatched to the implementation agent as patch round 1; re-verification follows its report. Defers (rows 4 remainder, 10, 14, 15, 16, 17) land in `docs/design/PENDING.md` at step-05.