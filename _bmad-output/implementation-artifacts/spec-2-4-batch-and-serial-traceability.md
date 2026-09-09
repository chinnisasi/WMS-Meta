---
title: 'Batch and serial traceability'
type: 'feature'
created: '2026-09-09'
status: 'done'
route: 'dispatch'
review_loop_iteration: 1
baseline_commit: 'a9485678aca6d476afc8065afc0fcf4af2e06e42'
context: []
story_key: '2-4-batch-and-serial-traceability'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** The ledger's batch/serial arms exist but are sealed — `batchRef`/`serialRef` columns, canonical hash bytes, and the registry's `allowsBatchArm`/`allowsSerialArm` flags were reserved in 2.1 and reject non-null values today. No batch/serial identity, quantities, or history exist, so batch-tracked SKUs move as anonymous stock and a serial has no location or history.

**Approach:** Catalog gains minimal batch/serial *identity* (batches with mfg/expiry; serials registry) created idempotently through its facade (AD-6 ownership); the inventory ledger opens the batch/serial arms on `stock.adjusted` and becomes the *only* source of batch/serial location and quantity (AD-6/AD-11): a `batch_on_hand` projection folded in the append transaction (and by rebuild/reconcile), serial location derived from the serial's latest ledger event, duplicate-serial scans rejected at ledger-write time naming the conflicting location. The existing adjustment endpoint gains additive batch/serial fields — the only movement writer in Epic 2, so it exercises capture end to end.

## Boundaries & Constraints

**Always:**
- Catalog owns batch/serial identity; the ledger owns batch/serial location and quantity; serial-uniqueness-in-a-bin is enforced at ledger-write time by the inventory module (AD-6) — never by a catalog unique index on location.
- Batch/serial movement state is append-only-derived: batch on-hand is a projection folded in the same transaction as the event (and by `rebuildProjectionsInTx`); serial location is derived from the serial's latest event. Corrections are new events.
- Serial-tracked movements: exactly one ledger event per serial unit (qty ±1, one idempotency record per adjustment — N events in one tx).
- Batch-tracked intake records mfg/expiry per batch (expiry optional at intake; FEFO orders by expiry, null last, expired batches never default-drawn).
- New tables follow the 0008/0009 pattern: drizzle-generated base + hand-appended fail-closed RLS and CHECKs; migration 0010.
- All facade/module-direction pins hold: inventory imports nothing cross-module; batch-identity creation and FEFO expiry joins compose at the API layer (`src/api`).

**Never:**
- No batch/serial dimension on reservations or Valkey counters (2.3 documented decision — scope stays (tenant, warehouse, sku)).
- No pick flow, no QC-hold surfaces (Epic 3/4); FEFO *consumption* beyond what this story ships is Epic 4's.
- No batch/serial HTTP read routes if the reads question resolves to facade-only (2.5 is the surfaces story).
- No free-form event emission: the batch/serial arms open via the registry only (`stock.adjusted` flags + reference-doc arm fields), additive; grammar stays version 1.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Behavior | Error Handling |
|----------|--------------|-------------------|----------------|
| Batch intake | Positive adjustment, batch-tracked SKU, `batch {code, mfgDate?, expiryDate?}` | Batch identity ensured via catalog facade; event carries batchRef; `batch_on_hand` grows | Untracked SKU carrying batch/serial → 400 |
| Serial intake | Positive adjustment, serial-tracked SKU, `serials: [s1..sN]`, qty = N | N per-unit events (qty +1 each, serialRef = si) | Qty ≠ serial count → 400; duplicate serial already in another bin → 409 naming the location |
| Serial draw | Negative adjustment naming serials | Per-unit events; serial's current location must equal the fromBin | Serial elsewhere / unknown → 409/404 |
| Batch draw | Negative adjustment, batch-tracked SKU | batchRef required; `batch_on_hand` shrinks; over-draw beyond the batch's bin quantity → rejected | 422 insufficient-on-hand naming the batch |
| Duplicate scan | Serial already located in bin X, intake scanned for bin Y | Rejected naming bin X | 409 `duplicate-serial` |
| FEFO default vs override | Negative draw, batch-tracked SKU, batchRef omitted vs explicit | Default draw = FEFO-resolved batch (api layer joins catalog expiry + inventory batch on-hand); explicit batch on a default-eligible draw = override, requires a reason recorded in the ledger reference doc | Missing override reason → 400 |
| Rebuild parity | `rebuildProjectionsInTx` after events with batch/serial arms | `batch_on_hand` re-folded exactly from the ledger | N/A |
| Untracked passthrough | Adjustment on a flagless SKU, no batch/serial fields | Exactly today's behavior — no new validation, no new columns touched | N/A |

- RESOLVED at CHECKPOINT 1 (2026-09-09, human approved): **FEFO default draw in Epic 2 = adjustment stand-in** — negative adjustments on batch-tracked SKUs default to the FEFO batch (resolved at the API layer: oldest non-expired batch with stock in the bin, expiry ASC nulls-last); an explicit batchRef on a default-eligible draw is an override and requires a reason, recorded in the ledger reference doc (the hash-chained ledger is the audit log). The epic's FEFO/override ACs are real now; Epic 4's pick engine consumes the same composition.
- RESOLVED at CHECKPOINT 1 (2026-09-09, human approved): **Traceability reads are facade-only** — batch on-hand/pick-order data, serial history/location, and batch history land as facade methods; HTTP surfaces in story 2.5. The openapi diff stays request-body-additive only.

</frozen-after-approval>

## Code Map

- `src/modules/inventory/ledger-registry.ts` — the grammar: `LedgerReferenceDoc` union (single `manual-adjustment` arm, :17-26), `allowsBatchArm`/`allowsSerialArm` (:37-40, explicitly reserved for 2.4), registration at :61-74. Open the flags here; extend the reference arm additively.
- `src/modules/inventory/ledger.service.ts` — `LedgerMovement.batchRef/serialRef` (:25-43, already flows into canonical bytes + `verifyChainInTx`); `appendMovement` (:273-394, advisory lock → seq → insert → fold); `addToOnHand` (:408-460, THE only stock write — batch fold must live beside it, same file); `rebuildProjectionsInTx` (:985) and `reconcileScanInTx` (:929) must learn the batch fold; `foldLedgerInTx` (:779) folds (sku,bin) only.
- `src/modules/inventory/inventory.command.ts` — `StockAdjustmentCommand.adjust()` (:85-210): capability gate before replay lookup (:128-131), `hashCommandPayload` field set MUST gain the new fields; `adjustToSnapshot` hardcodes `batchRef: null, serialRef: null` (:297-298).
- `src/api/inventory.controller.ts` — `POST /tenants/:tenantId/inventory/adjustments` (:46); the api-layer composition point (catalog facade ensure + FEFO resolve → inventory facade adjust).
- `src/modules/catalog/` — facade + command patterns for `ensureBatches`/`ensureSerials`; flags read from `skus.batch_tracked/serial_tracked` (schema.ts:268-269).
- `src/shared/db/schema.ts` — new `batches`/`serials` (catalog-owned, beside `skus` :256-281) + `batchOnHand` (inventory-owned, beside `stockOnHand` :472-500); `ledgerEvents.batchRef/serialRef` :422-423; reservations scope note :709.
- `drizzle/` — migration 0010: drizzle-generated base + hand-appended RLS/CHECKs (copy the 0009 tail pattern verbatim). **Drizzle-generated files have NO trailing newline — never append one** (2.3 H6 lesson).
- `src/modules/inventory/inventory.facade.ts` — pass-through surface for the new reads/writes (:114-296 shape).
- `test/architecture.spec.ts` — `STOCK_TABLES` :25, single-projection-path regex :106-127 (batch fold must stay in ledger.service.ts), sibling-import pin :132-138.
- `test/ledger.spec.ts` — fixture style (inline supertest: tenant → user → warehouse → zone → bins → SKUs, `facade.adjustStock`), jest `maxWorkers: 1`, DDL-probe advisory lock :52-70.
- `src/modules/inventory/reservation.service.ts` — untouched; `committedOnHand`/quarantine exclusion (:856) unaffected by the new projection. `requireUuid` (:143-152) is the validation helper precedent.

## Tasks & Acceptance

**Execution:**
- [x] `src/shared/db/schema.ts` + `drizzle/0010_*.sql` — `batches` (tenant, sku, code unique per tenant+sku, mfg/expiry dates, status), `serials` (tenant, sku, serial_number, status), `batch_on_hand` (5-col unique scope, non-negative CHECK); hand-appended RLS + CHECKs; `batch_on_hand` added to the architecture pin.
- [x] `src/modules/catalog/` — `ensureBatches` / `ensureSerials` facade methods (idempotent per (tenant, sku, code/serial); batch+serial-tracked SKU may carry both arms).
- [x] `src/modules/inventory/ledger-registry.ts` — open `allowsBatchArm`/`allowsSerialArm` on `stock.adjusted`; extend the `manual-adjustment` reference arm with the optional override-reason field (additive).
- [x] `src/modules/inventory/ledger.service.ts` — batch fold beside `addToOnHand` (same tx), serial-location derivation queries, duplicate-serial/serial-location guards at append time, `rebuildProjectionsInTx` + `reconcileScanInTx` learn `batch_on_hand`.
- [x] `src/modules/inventory/inventory.command.ts` + `inventory.dto.ts` + `src/api/inventory.controller.ts` — additive batch/serial request fields, validation (tracked-SKU requirements, qty = serial count), api-layer composition (ensure identity → FEFO resolve if applicable → adjust), idempotency payload-hash extension. **Review-loop-1 pins (all acceptance-tested):**
  - **Replay must precede composition.** The idempotency replay decision must be reached BEFORE (or independently of) the api-layer composition: a retry of a succeeded FEFO default draw MUST return the stored snapshot even when the FEFO batch has since been exhausted or the bin's batch state changed. The composition (identity ensure, validation 400s, FEFO resolution) must never prevent a replay or make its outcome depend on current bin state. Implementation shape is the re-deriver's — e.g. a replay pre-check at the api layer that yields the stored snapshot, with composition reserved for the non-replay path — but the payload-hash comparison stays command-owned and the module-direction pin holds.
  - **Arms are normalized before identity AND fingerprint.** Null batch/serials behave as absent (400 on a tracked SKU that requires them, never a 500); serials are trimmed, empty-after-trim rejected (400), duplicates within one request rejected (400), and an empty array treated as absent — and the normalized values feed BOTH `ensureSerials` and the idempotency fingerprint. Legacy fieldless fingerprints stay byte-identical (undefined dropped by `JSON.stringify`).
  - **Permission before validation.** The `stock.adjust` assert at the api layer runs before ANY tracked-SKU validation 400 (a caller without the capability gets 403, not a validation detail), and before any identity creation.
  - **Serial guards serialize tenant-wide.** The serial-arm guards take a tenant-scoped advisory lock keyed on the serial identity (deterministic acquisition order across a multi-serial adjustment) in addition to the per-warehouse lock — a serial's location can cross warehouses, so per-warehouse locking alone does not enforce one-location.
- [x] `src/modules/inventory/inventory.facade.ts` — pass-throughs: batch on-hand/pick-order data, serial history/location, batch history (one query per serial/batch from `ledger_events` indexes).
- [x] Indexes: `ledger_events (tenant_id, serial_ref, seq)` and `(tenant_id, batch_ref, seq)` for one-query traceability.
- [x] `test/batch-serial.spec.ts` — the I/O matrix: intake/draw per tracked type, duplicate scan names the location, qty≠serial-count, FEFO default vs override reason, untracked passthrough unchanged, rebuild parity, one-query history, RLS/CHECK probes on 0010. **Review-loop-1 test pins:** (a) same-key retry with a different `batch.code` or `serials` array → 422 `idempotency-key-reuse`; (b) a batch-tracked same-key replay returns the snapshot with no second event; (c) reconcile-**scan** (bounded window) detects a tampered `batch_on_hand` row and the divergence carries `batchRef`; (d) a denied-role member's batch-armed adjustment → 403 AND zero `batches`/`serials` rows for the tenant; (e) RLS cross-tenant probe (tenant A's scoped session sees zero of tenant B's rows) on all three 0010 tables; (f) `cleanupRows` also deletes `reconciliation_checkpoints`.

**Acceptance Criteria:**
- Given a batch-tracked SKU, when stock is adjusted in, then the batch's mfg/expiry are recorded and its `batch_on_hand` reflects the movement.
- Given a serial-tracked SKU, when a serial is scanned into a bin where it already lives, then the rejection names the conflicting location; a serial's full movement history and current location return in one query each.
- Given any rebuild/reconcile, then `batch_on_hand` re-derives exactly from the ledger.
- Given an untracked-SKU adjustment without the new fields, then behavior and API shape are byte-identical to today.

## Implementation Notes

### KEEP (review loop 1 — what worked and must survive re-derivation)

- **The overall shape is sound — re-derive it, don't redesign it.** The prior implementation (preserved as reference at `/tmp/spec-2-4-diff.patch`, diff vs baseline `a9485678aca6d476afc8065afc0fcf4af2e06e42`) got the architecture right: api-layer composition (`composeBatchSerialArms` in `src/api/inventory.controller.ts`) with catalog `ensureBatches`/`ensureSerials` + FEFO expiry join; the `batch_on_hand` fold beside `addToOnHand` in `ledger.service.ts` (same tx, plus `rebuildProjectionsInTx`/`reconcileScanInTx`/`replayInTx` parity via `foldLedgerInTx` batch buckets keyed `sku:bin:batch`); `assertSerialArmLegal` guards derived from the serial's latest event; registry arms opened additively with the `overrideReason` reference-doc field; migration 0010 on the 0008/0009 pattern (hand-appended fail-closed RLS + CHECKs, drizzle canonical no-trailing-newline); the `AdjustStockBatch` + `serials` request fields with per-serial-unit events in `adjustToSnapshot`; the payload-hash extension over the raw batch/serial arms; the facade read surface (`batchOnHand`, `serialHistory`, `serialLocation`, `batchHistory`); and the 18-test e2e suite structure (advisory-locked DDL probes, replication-role cleanup, one-query readbacks, FEFO ordering + expiry + exhausted-bin, rebuild tamper, idempotent replay).
- **Bug the prior round's own tests caught** — keep the fix: a tracked SKU without its arm must 400; only the truly flagless+fieldless request takes the passthrough.
- **Deliberate designs the review confirmed** (do not "fix"): catalog identity rows persisting when a movement later fails (idempotent master data; cross-module atomicity would violate the module-direction pin); multi-unit FEFO draws not spanning batches (Epic 4 owns FEFO consumption); `status` without a blocking write path (QC is Epic 3/4); Nest module import dedup.
- The triage-rejected findings (rows 3, 4, 5, 9, 10, 11, 14, 15, 18, 22 of `## Review Triage Log`) record why these are correct — consult before re-litigating.

## Spec Change Log

- **Review loop 1 (2026-09-09, bad_spec loopback).** Triggering finding: the FEFO default draw breaks idempotent replay — the api-layer composition (identity ensure, validation, FEFO resolve) runs *before* the command's idempotency replay lookup, so a retry of a succeeded FEFO draw whose batch has since been exhausted throws 422 "No batch to draw" instead of returning the stored snapshot. Root cause: the spec never specified the ordering of composition vs replay. Amended the non-frozen Tasks & Acceptance and Design Notes with (a) the composition-must-not-prevent-replay requirement, (b) input-normalization pins (null arms, whitespace/dedupe/empty-array serials), (c) the permission-assert ordering pin, (d) the tenant-wide serial-lock pin, and (e) the verification pins the review layers proved missing (idempotency-conflict arms, reconcile-scan batch parity, denied-role no-catalog-rows, RLS cross-tenant, cleanup table). Known-bad state avoided: re-deriving with the same composition-before-replay shape. KEEP instructions under `## Implementation Notes`. Code reverted to baseline `a9485678aca6d476afc8065afc0fcf4af2e06e42`; the prior implementation is preserved as reference at `/tmp/spec-2-4-diff.patch`.

## Review Triage Log

| # | Layer | Finding | Verdict | Evidence / Route |
|---|-------|---------|---------|------------------|
| 1 | blind | FEFO replay breaks idempotency: composition (incl. FEFO resolve) precedes the command's replay lookup, so a retry of a succeeded FEFO draw whose batch is now exhausted 422s instead of replaying | **medium** | Verified: `inventory.controller.ts:88` composes before `facade.adjustStock`; `resolveFefoBatch` throws 422 when no non-expired batch has stock — reachable by the documented retry flow. Route: **bad_spec → loopback 1** |
| 2 | edge | Same claim as #1 (FEFO re-resolution on retry) | carried | Same location, same claim as row 1 — carried |
| 3 | blind | Multi-unit FEFO draw cannot span batches (draw > one batch's stock 422s despite other stock) | low | Outcome real, but the frozen boundary assigns FEFO *consumption* beyond this story's adjustment stand-in to Epic 4 — the intent itself excludes it. Route: rejected (out of scope) |
| 4 | blind | `status` ('blocked') is dead schema — nothing reads or writes it; a blocked batch would be drawable | low | Real but no write path for 'blocked' exists anywhere; blocking/QC is Epic 3/4 scope; the spec mandates the column only. Route: rejected (out of scope) |
| 5 | edge | Batch status 'blocked' still ensured/drawn/FEFO-selected | low | Same location and claim as row 4 — carried, rejected with it |
| 6 | blind | Whitespace fingerprint mismatch: serials trimmed for identity but raw array hashed → whitespace-differing retry 422s | low | Verified: controller trims at :132 for `ensureSerials` but passes raw `dto.serials` (:101) into the command hashed at `inventory.command.ts:178`. Route: **patch group G1** |
| 7 | blind | Whitespace-only serial (`" "`) passes DTO `Length(1,64)` pre-trim, trims to `''`, creates an empty identity row | low | Verified: DTO validates the raw element; trim at controller :132 yields `''`; `ensureSerials` has no format guard. Route: **patch group G1** |
| 8 | edge | Same claim as #7 (whitespace-only serial) | carried | Same location and claim as row 7 — carried |
| 9 | blind | Duplicate serials in one request surface as 409 `duplicate-serial` mid-transaction instead of a 400 | false | `ensureSerials` dedupes via `[...new Set(serialNumbers)]` (`catalog.facade.ts:212`) → serialRefs.length=1 → the command's count backstop (`inventory.command.ts:145`) throws 400 before any ledger write. The claimed 409 cannot occur |
| 10 | blind | Catalog identity rows persist when the movement later fails (ensure runs outside the movement tx) | low | Real but deliberate: identity is idempotent master data; a failed movement leaves a valid, reusable batch/serial row. Cross-module atomic tx would violate the module-direction pin. Route: rejected (design-settled) |
| 11 | edge | Both-tracked SKU: batch ensured, then serials-required 400 aborts — rows persist | low | Same location and root as row 10 — carried, rejected with it |
| 12 | blind | Docblock says the flagless passthrough "never touches catalog" but `findSku` runs unconditionally | low | Verified: `inventory.controller.ts:134` runs before the passthrough return; the docblock (:111-112) contradicts the code (the inline comment at :136-137 already tells the truth). Route: **patch group G4** |
| 13 | edge | Same claim as #12 (docblock claim) | carried | Same location and claim as row 12 — carried |
| 14 | blind | ApiModule comment's "no new module instances" rationale is wrong (Nest would create duplicates) | false | Nest instantiates a module class once per application regardless of how many modules import it — the comment's rationale holds as written |
| 15 | blind | `latest.fromBinId!` in `assertSerialArmLegal` could render `bin "undefined"` on a both-bins-null event | false | The only writer of serialRef events sets exactly one bin per event by delta sign (zero deltas are rejected upstream); a draw-latest event always carries `from_bin_id` — the null case is unreachable |
| 16 | blind | OpenAPI under-documents the failure surface (400/404/409 `serial-elsewhere`/422 descriptions; BatchInputDto constraints) | low | Real. Error-response doc additions exceed the frozen CHECKPOINT-1 decision ("openapi diff stays request-body-additive only") → defer that half to 2.5; the request-body constraint half folds into re-derivation (G1) |
| 17 | edge | 409/404 `@ApiResponse` descriptions name only duplicate-serial | low | Same location and root as row 16 — carried with it |
| 18 | blind | Missing meta-repo interface-contract docs update | false | The contract update is the story's planned closing sequence (meta PR after code lands) — not part of this diff |
| 19 | blind | RLS probe is one-sided: no cross-tenant assertion, only `batches` scoped | low | Verified: `batch-serial.spec.ts` RLS test checks un-scoped zero + one scoped session on `batches` only. Route: **patch group G5** |
| 20 | blind | "Denied request leaves no catalog rows" is untested | low | Verified by the verification-gap layer's evidence rules (row 27). Route: **patch group G5** |
| 21 | blind | Suite order-coupled; `cleanupRows` misses `reconciliation_checkpoints` | low | Missing cleanup table: real, trivial addition (G5). Order-coupling is the repo's sibling-suite e2e style — not this story's problem |
| 22 | blind | Snapshot/DDL divergence unrecorded in schema.ts comments; missing terminal newlines | false | schema.ts comments already state RLS/CHECKs live only in the migration DDL (0006-0009 pattern); drizzle-generated files must have NO trailing newline (CI drift guard); lint passes, so no eol rule is violated on .ts files |
| 23 | edge | `batch: null` → `hasBatch` true → `dto.batch!.code` TypeError → 500 | low | Verified: controller :131 uses `!== undefined` (null passes `IsOptional`), :168 dereferences on a tracked SKU. Route: **patch group G1** |
| 24 | edge | `serials: null` on the flagless passthrough → `[...null]` in `hashCommandPayload` → 500 | low | Verified: controller passes raw `dto.serials` (:101); `inventory.command.ts:178` spreads without a null guard (`=== undefined` only). Route: **patch group G1** |
| 25 | edge | Cross-warehouse concurrent intake of the same serial: warehouse-scoped lock does not serialize the tenant-wide guard → serial located in two warehouses | **medium** | Verified: `appendMovement` takes only `warehouseAdvisoryLock`; `assertSerialArmLegal`'s latest-event read is tenant-wide. Two appends in different warehouses can both pass. Route: **patch group G3** |
| 26 | edge | Tracked-SKU-no-arm request returns 400 without the permission assert ever running (400-before-403) | low | Verified: `assertPermission` (:146) runs only when arms are present; the no-arm tracked path 400s at :229-246 without it. Route: **patch group G2** |
| 27 | edge | `serials: []` vs omitted field fingerprint differently → semantically identical retry 422s | low | Verified: empty array passes composition as `hasSerials=false` but hashes as `[]` vs absent. Route: **patch group G1** |
| 28 | vgap | Batch/serial arms of the idempotency payload hash are unverified — no same-key/different-arms test (pre-verified) | low | Filed evidence: every existing idempotency test is armless or same-payload; dropping the arms from the hash passes all tests. Route: **patch group G5** |
| 29 | vgap | `reconcileScanInTx`'s batch_on_hand comparison is unverified — no scan-path test carries batch data (pre-verified) | low | Filed evidence: the batch tamper test exercises full replay only; every scan-path test uses a flagless SKU. Route: **patch group G5** |
| 30 | vgap | The assert-before-identity-creation invariant is untested — no denied-role armed request (pre-verified) | low | Filed evidence: no denied-role test carries the arms. Route: **patch group G5** |
| 31 | blind (r2) | `status` write-only; a blocked batch would be drawable | carried | Row 4/5 — same location, code unchanged. Carried, rejected with it (Epic 3/4 scope) |
| 32 | blind (r2) | `batch.overrideReason` accepted and silently recorded on intakes (positive deltas) | low | Verified: `normalizeArms` copies `overrideReason`; the intake branch of `composeBatchSerialArms` never rejects it; `adjustToSnapshot` spreads it into the reference doc. Route: **patch group G6** |
| 33 | blind (r2) | Lock-ordering inversion between `lockSerialsInTx` (serials→warehouse) and `appendMovement` (warehouse→serial) can deadlock | **false** | `appendMovement`'s only callers are the two appends in `adjustToSnapshot` (`inventory.command.ts:430,446`), which pre-lock the serial set via `lockSerialsInTx` whenever `serialRefs.length > 0` — single-serial movements included. The serial acquisition inside `appendMovement` (`ledger.service.ts:447`) is always a re-acquire of an already-held lock; rebuild/anchor take the warehouse lock but no serial locks. Global order is serials→warehouse for every serial movement — no inversion exists |
| 34 | blind (r2) | Identity ensure not atomic with the movement; the 409-after-ensure orphan case untested/undocumented | carried | Row 10/11 — same claim, code unchanged. Carried, rejected with it (deliberate idempotent master data) |
| 35 | blind (r2) | `rows.find(...)!` / `ensured!.id` — a missed re-select surfaces as 500 | low | Rejected: the re-select after `onConflictDoNothing` can only miss if an identity row is concurrently deleted — no deletion path exists anywhere in the codebase |
| 36 | blind (r2) | `toBinId: delta >= 0` → `delta > 0` is a silent uncommented operator edit | low | Real doc gap: equivalent only because zero deltas are rejected upstream. Route: **patch group G6** (comment) |
| 37 | blind (r2) | `assertBatchInstant`'s validated return is discarded at both call sites | low | Real style hazard (invites assuming it normalizes). Route: **patch group G6** (discard explicitly) |
| 38 | blind (r2) | OpenAPI: `BatchInputDto` lacks length facets; `serials` lacks `maxItems: 1000` | low | Verified: exported `BatchInputDto` carries no minLength/maxLength; `serials` has no maxItems. Round-1 row 16 routed the request-body constraint half into the re-derivation — it was dropped. Route: **patch group G6** (new schemas only; stays request-body-additive) |
| 39 | blind (r2) | Idempotent-intake test assertion cannot fail (`getTime() < Date.now()`) | low | Verified: `toBeLessThan(Date.now())` passes for any past timestamp. Route: **patch group G6** (assert equality with the first intake's dates) |
| 40 | blind (r2) | Unknown-SKU-with-arm 404 branch untested | low | Verified via the vgap layer's evidence. Route: **patch group G6** |
| 41 | blind (r2) | No concurrency test exercises the tenant-wide serial locks | low | Verified: no test runs concurrent same-serial adjustments. Route: **patch group G6** |
| 42 | blind (r2) | FEFO expiry boundary (`>= Date.now()`, server clock) unspecified/untested | low | Rejected: CHECKPOINT 1 (frozen) defines FEFO as "oldest non-expired"; the server clock is the natural reading, and an exact-boundary tie is not meaningfully testable |
| 43 | blind (r2) | Flagless passthrough is no longer cost-identical (`findSku` runs first) | low | Rejected: `findSku` is required to detect the tracked-SKU-fieldless arms path (`touchesArms`); one indexed read |
| 44 | blind (r2) | 1000-serial adjustment issues 1000 sequential appends | low | Rejected: one ledger event per serial unit is the frozen architecture decision; the DTO cap bounds it |
| 45 | blind (r2) | `serialLocation` returns no in-stock flag | low | Rejected: reads are facade-only (frozen CHECKPOINT 1); 2.5 owns the HTTP surface and its shapes |
| 46 | blind (r2) | No both-arms negative-delta test (serials + explicit batch override) | low | Verified: the suite covers both-arms intake and batch-only override, never the combined draw. Route: **patch group G6** |
| 47 | blind (r2) | Meta-repo interface-contract docs not updated | carried | Row 18 — same claim. Carried, false with it (story closing sequence) |
| 48 | blind (r2) | New files lack trailing newlines | carried | Row 22 — same claim. Carried, false with it (drizzle canonical no-newline; lint clean) |
| 49 | edge (r2) | Override reason recorded verbatim on non-override intake events | carried | Row 32 — same location and claim. Carried with it, **patch group G6** |
| 50 | edge (r2) | Inverted-dated batch (expiry < mfg) is stored and FEFO-drawn first | low | Verified: no ordering guard exists in the composition. Route: **patch group G6** (400 when both dates present and expiry < mfg) |
| 51 | edge (r2) | int4 overflow on `batch_on_hand` fold aborts as unhandled 500 | **false** | No overflow guard exists in EITHER fold — `addToBatchOnHand` is at exact parity with the pre-existing `addToOnHand`; and the trigger needs ~2³¹ units of one batch in one bin |
| 52 | edge (r2) | `serialHistory`/`batchHistory` are unbounded SELECTs | low | Rejected: reads are facade-only (frozen CHECKPOINT 1); pagination is 2.5's HTTP concern |
| 53 | edge (r2) | Orphan identity on failed adjustment (composition commits, command rejects) | carried | Row 10/11/34 — same claim. Carried, rejected with it |
| 54 | vgap (r2) | The ledger's `insufficientBatchOnHand` guard is never executed by any test — the FEFO over-draw path's 422 contract ships unprotected | low | Filed evidence: every batch over-draw test hits the controller's `assertBatchCoversDraw` (explicit draws) or `resolveFefoBatch` (empty candidates), never the fold guard. Route: **patch group G6** (FEFO draw exceeding the chosen batch's holding → 422) |
| 55 | vgap (r2) | Unknown-SKU-with-arms 404 branch untested | carried | Row 40 — same location and claim. Carried with it, **patch group G6** |
| 56 | vgap (r2) | FEFO resolution has no fallthrough to the next-oldest batch | carried | Row 3 — same claim. Carried, rejected with it (frozen boundary; Epic 4) |
| 57 | vgap (r2) | `insufficientBatchOnHand` names the batchRef uuid while the api pre-check names the code | low | Rejected: already documented in the `addToBatchOnHand` docblock (`ledger.service.ts:661-663`); the ledger cannot see catalog codes (module-direction pin) |

## Design Notes

- **Serial location = derived, not projected.** The serial's current bin is the from/to bin of its latest event (`ledger_events (tenant_id, serial_ref, seq DESC) LIMIT 1`) — the ledger is the only source (AD-6), nothing new to reconcile, and history is the same index. Batch quantities, unlike serial locations, are aggregated (FEFO reads many batches at once), so they earn a projection.
- **FEFO is a cross-facade join.** Inventory owns per-batch quantity; catalog owns expiry. The API layer composes: catalog batch metadata + inventory batch on-hand → order by `expiryDate ASC NULLS LAST`, skip expired for default draws, filter quantity > 0 for the target bin. Epic 4's pick engine consumes the same composition.
- **Opening the arms is additive.** Old events (arms null) verify identically — canonical bytes are computed from stored columns at write time and re-hashed from the same columns at verify time; the registry flags gate *new* writes only.
- **Replay beats composition (review loop 1).** The idempotency replay is keyed on (tenant, key) and compared by a payload hash over the RAW request body — the FEFO-resolved `batchRef` is deliberately NOT in the hash, so a replay is fully determined before any composition runs. The composition must respect that: on a replay, no identity ensure, no validation 400, no FEFO resolution may run (or their outcomes must not matter) — the stored snapshot is the answer. First-attempt semantics are unchanged.
- **Serial locks are tenant-wide (review loop 1).** The per-warehouse advisory lock serializes same-warehouse appends, but a serial's location can cross warehouses — the serial-arm guards additionally serialize on the serial identity tenant-wide, so two concurrent intakes of one serial into different warehouses cannot both pass.

## Verification

**Commands:**
- In `wms-be`: `bun run db:migrate && bun run test` — all green incl. the new `test/batch-serial.spec.ts`.
- `bun run db:generate && git diff --exit-code drizzle/` — no drift; `bun run lint && bun run typecheck` — clean.
- `bun run openapi:export && git diff --exit-code openapi/` — expected to DIFF (additive request fields only); verify the diff touches only the adjustment request schema.

**Manual checks:**
- Adjust a serial-tracked SKU twice with the same serial into different bins → second call 409 naming the first bin; serial history readback shows both events.