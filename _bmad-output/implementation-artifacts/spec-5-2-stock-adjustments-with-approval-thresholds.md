---
title: 'Story 5-2 — Stock adjustments with approval thresholds'
type: 'feature'
created: '2026-09-28'
status: 'done'
review_loop_iteration: 1
route: 'dispatch'
baseline_commit: 'decc50e'
context:
  - '_bmad-output/implementation-artifacts/epic-5-context.md'
  - 'docs/design/SYSTEM-DESIGN.md'
  - 'docs/design/IMPLEMENTATION-GUIDE.md'
  - 'docs/design/modules/inventory.md'
  - 'docs/design/API-SURFACE.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** `stock.adjust` applies any correction instantly: the reason code is free-form 1–64 text, the command writes no audit row, and nothing bounds magnitude — a fat-fingered ±50,000-unit delta changes ATP unreviewed (FR-19).

**Approach:** Give adjustments a controlled reason vocabulary; add a per-tenant configurable |delta| threshold; over-threshold adjustments sit **pending** (no ledger event, no on-hand change) until a decision approves (applying the stored arms as ledger events) or rejects — the `over_receipts`/`decideOverReceipt` shape reused. Approver notified via outbox (functional entry; Epic 9 surfaces it). Every step audit-logged. Fold the known multi-serial snapshot mismatch fix (epic-2 retro A4) since this story owns the response contract.

## Boundaries & Constraints

**Always:**
- Command-skeleton order preserved. The threshold branch sits **behind the replay lookup and after the full guard set**, immediately before ledger writes — a committed adjustment replays its stored snapshot whatever today's threshold says, and a request failing a shape/stock guard answers its 4xx, never pends.
- A pending adjustment writes **no** ledger event, **no** on-hand/ATP change, **no** Valkey counter change.
- Approval-apply re-executes the stored arms through the same inventory internals (SKU row `.for('update')`, kit refusal, catch-weight refusals, serial locks, `appendMovement`), inheriting `stock.adjust`'s named-bypass posture for the placement gates — no new gate on this surface.
- Decisions are terminal: conditional UPDATE `.where(status = 'pending')`; second decision answers 409 `adjustment-pending-decided`. If the approval arm's re-execution fails any guard, the whole decide tx rolls back — pending stays pending, caller gets the guard's 4xx, Owner may then reject.
- New vocabularies as the three mirrored layers + e2e pin; new tables get CHECK + RLS hand-appended in migration 0044 (re-run guard, journal, snapshot); any new capability is mirrored into `wms-fe/src/lib/users.ts` **in this story** (CI mirror guard names the drift).

**Never:**
- No mobile surface. No notification delivery — outbox event only. No FE approval card (lands with the consolidated review-queue story) unless Open Question 4 says otherwise. No change to the five documented `stock.adjust` gate bypasses. No editing of the frozen 0013 over-receipts migration.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Under/at-threshold adjust | policy row absent or \|delta\| ≤ threshold | 201 `{event, onHand}` as today + audit row `stock_adjustment.recorded` | N/A |
| Over-threshold adjust | \|delta\| > policy threshold | 202 `{pendingAdjustment}` (id, status `pending`, threshold context incl. threshold-at-request); no ledger event; onHand unchanged | N/A |
| Replay of a pending creation | same idempotency key + payload | re-serves stored 202 snapshot; nothing below replay runs | 422 on key reuse w/ different payload (as today) |
| Approve | Owner-capability caller, pending row | ledger events apply (actor = approver, occurredAt = decision time); audit `stock_adjustment.approved`; outbox `stock_adjustment.approved` | 403 role-denied |
| Reject | decision caller, pending row | status → rejected; no stock write; audit + outbox `stock_adjustment.rejected` | 403 role-denied |
| Second decision | already approved/rejected row | deterministic 409 `adjustment-pending-decided` | 409 |
| Approval vs moved world | bin retired / insufficient-on-hand / HU left active since pend | whole decide tx rolls back; pending stays pending | guard's 400/409/422 verbatim |
| Over-threshold + bad shape | zero delta, serial-count mismatch, retired bin… | the guard's 400/404 — shape checks stay above the transaction | 400/404 |
| Policy write | PUT threshold < 0 or non-integer | 400 validation-failed | 400 |
| Serial-arm response snapshot | multi-serial adjustment (immediate or approved) | aggregate snapshot: `event.id/seq` null, `quantityDelta` aggregate (retro A4 fix); outbox payload same pairing | N/A |
| Pending queue read | GET pendings?status=pending | rows w/ reason, delta, threshold context, requester | N/A |

## I/O note — threshold semantics

Approval is required when `|quantityDelta| > threshold` (strictly greater; at-threshold applies immediately). With **no policy row the approval flow is disabled** (config-not-code: tenants opt in; default-on would 202 every existing adjustment).

**Decisions (human-approved 2026-09-28):** (1) threshold is **quantity-only** — the value half is deferred to PENDING.md until cost data exists; (2) decisions gate on a new **owner-only `adjustments.approve`** capability (count 27→28; the policy write rides the same capability); (3) the reason code becomes the **closed enum** `stock-count, damaged, expired, shrinkage, found, recall, system-correction, other` (`other` requires the note; historical referenceDoc rows unaffected); (4) **backend-only** this story — the UX-DR15 approval card lands with the 5-4/5-5 consolidated review queue (wms-fe changes here: capability mirror only).

</frozen-after-approval>

## Code Map

(wms-be unless noted)
- `src/modules/inventory/inventory.command.ts` — `adjust` :259 (guards :267-452, ledger write :454-500); `adjustToSnapshot` :776-797 (a4 defect: `appended` reassigned in serial loop); audit rows added here
- `src/api/inventory.controller.ts` — adjust route :74-165 (arm resolution :172+, `ensureSerials`/FEFO)
- `src/modules/inventory/inventory.dto.ts` — `StockAdjustmentDto` :107+, `reasonCode` free-form :138-142
- `src/modules/putaway/mismatch-reason.ts:22` — vocabulary pattern (tuple + `@IsIn` mirror)
- `src/modules/inbound/receiving.command.ts:838-1070` — `decideOverReceipt`: THE pending→decide shape to copy (assert-before-replay carve-out, row `.for('update')`, conditional terminal UPDATE, audit + decisionEvent outbox)
- `src/shared/db/schema.ts` — `wave_policies` :1949-1989 (config-row precedent); new tables appended
- `drizzle/` — next migration **0044**; hand-append CHECK/RLS + re-run guard per 0043/0013
- `src/modules/tenancy/permissions.ts` — CAPABILITIES (27) + ROLE_CAPABILITIES
- `wms-fe/src/lib/users.ts` — capability mirror (CI guard `check:capability-mirror`)
- `test/users.spec.ts:843` (capabilities 27), `test/client-isolation.spec.ts:623` (RLS 48→50) — pinned counts

## Tasks & Acceptance

**Execution:**
- [x] `src/shared/db/schema.ts` + `drizzle/0044_adjustment_approval.sql` (+ journal + snapshot) — `stock_adjustment_policies` (tenantId unique, `quantityThreshold` nullable, timestamps) and `stock_adjustment_pendings` (arms: `quantityDelta`, `reasonCode`, `note`, **`batch_override_reason` nullable** — the override draw's mandatory FEFO-override reason, restored into the approved event's referenceDoc, resolved `batchId?`/`serialIds`/`handlingUnitIds` jsonb, `occurredAt`, `requestedBy/At`, `status` default `pending`, `decidedBy/At`, `thresholdQuantityAtRequest`; index `(tenantId,status,createdAt,id)`) — CHECKs, RLS + policies, re-run guard; the fail-fast canary checks **both** tables (pendings is created first — canary it too, the 0040/0043 way) and its comment describes the correct position
- [x] `src/modules/tenancy/permissions.ts` + `wms-fe/src/lib/users.ts` — capability per Open Question 2, mirrored same-story (**FE mirror already stands as FE commit `8c1bfc7` on `feat/5-2-…` — do not re-create it; BE-side only here**)
- [x] `src/modules/inventory/inventory.dto.ts` — `@IsIn` reason vocabulary (Q3), policy DTO with **`@Max(2147483647)`** on `quantityThreshold` (the column is `integer`; an oversized threshold must be a 400, never a Postgres-range 500), pending snapshot DTO
- [x] `src/api/inventory.controller.ts` — `PUT/GET :tenantId/inventory/adjustment-policies`; `GET :tenantId/inventory/adjustment-pendings`; `POST …/adjustment-pendings/:pendingId/approve` and `/reject` — OpenAPI arms documented (the PUT 400 arm names negative / non-integer / **over-int4-max**)
- [x] `src/modules/inventory/inventory.command.ts` — threshold branch (after full guard set, before ledger writes) creating the pending row (**storing `batch.overrideReason` when the request is an override draw**) + outbox `stock_adjustment.pending_approval` (payload carries `notifyRole:'owner'`) + audit row; audit row on the immediate path
- [x] `src/modules/inventory/adjustment-approval.command.ts` (new) — decide commands copying `decideOverReceipt`'s order: capability assert → replay → row lock → terminal-409 guard → approve (re-execute stored arms through `adjust` internals, threshold gate skipped, **`batch.overrideReason` restored from the pend row so the approved event's referenceDoc is byte-identical to what the same request would produce immediately**) / reject; both arms audit + outbox
- [x] `src/modules/inventory/inventory.command.ts` — `assertAdjustableInTx` additionally carries the **arm-required parity checks mirrored from the controller's `composeBatchSerialArms`**: serial-tracked SKU ⇒ serials required with `|delta| = count`; batch-tracked SKU ⇒ `batchRef` required — behind the replay lookup, tighten-only (the immediate path always satisfies them; the checks exist so the approval path inherits the full guard set against a SKU flagged batch/serial-tracked after the pend was raised)
- [x] `src/modules/inventory/inventory.command.ts` `adjustToSnapshot` — retro A4 fix scoped to the frozen matrix row: **multi-serial only** (`serialRefs.length > 1`) — snapshot + outbox payload carry `event.id/seq = null` with the aggregate delta; a **single-serial** adjustment keeps its exact `id/seq` pairing (pre-story behavior); consistency assertion added to `test/ledger.spec.ts` (multi-serial arm)
- [x] `test/adjustment-approval.spec.ts` (new) — I/O matrix arms + RLS probe + OpenAPI path assertions; bump `users.spec.ts:843` and `client-isolation.spec.ts:623`; **plus the coverage the first pass lacked: keyset pagination (two pages via `nextCursor`, no repeats across pages, invalid-cursor 400), a batch-tracked pend→approve (approved event's `batch_ref` = the pend's stored batch), a catch-weight pend→approve (named HUs leave active), a moved-world HU arm and a kit-since-pend arm on approve, policy PUT replay (same key → replayed 200; same key + different threshold → 422), a concurrent double-decide race (Promise.all → one decision wins, other 409), the `stock_adjustment.policy_updated` audit-row assertion, and `onHandFor` keyed by (bin, sku)**

**Acceptance Criteria:**
- Given a policy threshold, when an over-threshold adjustment commits, then no ledger event and no on-hand change exist for it until approve, and the approver-capability caller can approve/reject exactly once (second call 409)
- Given approval, when it applies, then the ledger events carry actor/approver and the original reason/reference context, and `stock.adjusted` timelines show them exactly like immediate adjustments
- Given no policy row, every adjustment applies immediately (202 never fires)
- Given a cross-tenant pending id, the RLS probe reads zero rows

## Implementation Notes

## Spec Change Log

- **2026-09-28 — round-2 re-derivation disclosed fix, accepted into scope (documented post-hoc).** The re-derivation added `fullPrecisionInstant` to `src/shared/primitives/time.ts` and switched the ledger-timeline and pending-queue keyset cursors to encode from the raw `::text` instant instead of `canonicalInstant`. Root cause: Postgres holds timestamptz to microseconds while `canonicalInstant` truncates to milliseconds via JS `Date`, and rows appended in ONE transaction share one `now()` (a multi-serial adjustment appends its per-serial events in a single transaction) — a truncated cursor's strict `<` keyset predicate skipped the whole tail of the tie group on the next page. The pendings-list cursor is story scope (the pagination task), so the fix was required; the ledger-timeline half repairs a pre-existing latent defect on the same primitive. Cursor stays opaque; `decodeCursorSafe`'s regex already admits any fractional digits; responses still surface `canonicalInstant` (ms) — only the cursor encoding changed. Verified first-hand in the round-2 diff (`time.ts`, `inventory.facade.ts:376-419`, `adjustment-approval.command.ts`). Logged here because it sits outside the task list as originally written; reviewers should treat it as in-scope.
- **2026-09-28 — review loop 1 bad_spec loopback (findings EC3/EC7/EC5, verified high×2 + low).** Triggering findings: (1) an approved override draw loses `batch.overrideReason` from its ledger referenceDoc — the immediate path carries it (400-required), the pend row never stored it, and `decide`'s `applyCommand` has no `batch` object, violating acceptance criterion 2 ("timelines show them exactly like immediate adjustments"); (2) the arm-required parity checks (serials required + parity, batchRef required) live only in the controller's `composeBatchSerialArms`, so an approval re-executing a pend whose SKU was flagged batch/serial-tracked after the raise writes un-serialized / batch-less stock; (3) the retro-A4 withholding fires for every serial arm while the frozen matrix row scopes it to multi-serial (single-serial responses regressed from exact pairing to null). **Amended (non-frozen only):** pend column list gains `batch_override_reason`; `assertAdjustableInTx` gains the mirrored arm-required parity checks; retro-A4 scope restated as multi-serial-only; policy DTO gains `@Max(2147483647)`; migration canary covers both tables; task/test list gains the first-pass coverage gaps. **Known-bad state avoided:** approved ledger events that the immediate path would refuse to produce without the override reason; un-serialized stock on a flipped serial-tracked SKU. **KEEP (what worked and must survive re-derivation):** the `assertAdjustableInTx`/`applyAdjustmentInTx` extraction and the threshold branch position (behind replay, after full guard set, before ledger writes); `decide` copying `decideOverReceipt`'s order incl. assert-before-replay carve-out, row `.for('update')`, conditional terminal UPDATE, rollback-leaves-pending, idempotency key last; the audit-row set and outbox payloads incl. `notifyRole:'owner'`; the migration's CHECK/RLS/journal/snapshot shape and the 8-value reason CHECK + TS/CHECK parity test; the 17-test suite's covered arms and its RLS/OpenAPI probes; the legacy reason-code migration in ~20 suites and the multi-serial timeline-query retooling; the FE mirror commit `8c1bfc7` (already stands, do not re-create); the eslint value-import disable pattern for DTO query classes.

## Review Triage Log

| # | Layer | Finding | Verdict | Evidence | Route |
|---|---|---|---|---|---|
| 1 | edge | Approved override draw loses `batch.overrideReason` from referenceDoc (`inventory.command.ts:1015-1017`; pend row has no override field) | high | Verified: referenceDoc composed solely from `command.batch?.overrideReason`; pend stores only `batchRef`; acceptance criterion 2 violated for override draws — the immediate path 400-requires it | bad_spec |
| 2 | edge | Arm-required parity checks live only in `composeBatchSerialArms` (`inventory.controller.ts:454,515,525`); approve path runs `assertAdjustableInTx` which lacks them | high | Verified: flags mutable via PATCH; a SKU flagged serial/batch-tracked after the raise approves with no serial events / null `batchRef` — un-serialized stock on a tracked SKU | bad_spec |
| 3 | edge | Retro-A4 withholding fires for ALL serial arms; frozen matrix row scopes it to multi-serial (`inventory.command.ts:1072`) | low | Verified: `serialArm = serialRefs.length > 0`; pre-fix single-serial responses carried exact pairing — an unmandated contract change | bad_spec |
| 4 | blind+edge | Policy PUT threshold lacks `@Max`; ≥2³¹ passes DTO, dies as Postgres-range 500 (`inventory.dto.ts:656+`) | medium | Verified: DTO has `@IsInt @Min(0)` only; column is `integer`; PUT 400 arm doesn't name it | patch |
| 5 | blind+edge | 0044 fail-fast canary checks `stock_adjustment_policies` but pendings is created first (`drizzle/0044:19,24`) | low | Verified: partial hand-apply passes the guard, re-run dies on a raw duplicate-table error instead of the named exception | patch |
| 6 | blind | 0044 guard comment says "CREATE TABLEs above" but tables sit below (`drizzle/0044:15-16`) | low | Verified: comment describes the wrong position | patch |
| 7 | blind+edge | `adjustment-reason.ts` header claims a command-layer guard for `other`-requires-note that doesn't exist (also: claims command-layer consumption of the constant — `inventory.command.ts` imports neither) | low | Verified: DTO requires non-empty note on every adjustment; command validates nothing; comment overstates the mirror | patch |
| 8 | blind+edge(vg) | Pendings keyset pagination untested — no `cursor`/`limit` call anywhere; predicate only activates past page 1 | patch-grade | Pre-verified by verification-gap layer: inverting the tuple predicate at `adjustment-approval.command.ts:257` keeps every existing assertion green; 21 `nextCursor` assertions exist on sibling list reads | patch |
| 9 | blind+edge(vg) | Batch-tracked and catch-weight arm classes never exercised through pend→approve — only `ADJ-PLAIN`/`ADJ-SERIAL` in the suite | patch-grade | Pre-verified: a dropped `handlingUnitIds` round-trip 400-rolls back every catch-weight approval forever; a dropped `batchRef` silently mis-attributes the draw | patch |
| 10 | blind | Moved-world approve arms HU-unknown/foreign/active and kit-since-pend untested (only bin-retired + insufficient-on-hand covered) | low | Verified by suite read: those arms exist in `assertAdjustableInTx`/`applyAdjustmentInTx` but no test drives them | patch |
| 11 | blind | Policy PUT idempotency untested (replay 200 / key-reuse 422) | low | Verified: `writeIdempotencyKey` at `adjustment-approval.command.ts:206` implements both arms; no test pins them | patch |
| 12 | blind | Concurrent double-decide race untested — only sequential 409s | low | Verified: the conditional terminal UPDATE is the backstop; no Promise.all test (repo has race-test precedent in kits/orders) | patch |
| 13 | blind+edge(vg) | `stock_adjustment.policy_updated` audit row never asserted | low | Verified: spec asserts audit rows for request/approve/reject but not the policy write | patch |
| 14 | blind | `onHandFor` keyed by bin only; serial-arm test puts a second SKU in `binA` (`adjustment-approval.spec.ts:200-206`) | low | Verified: helper correctness depends on test ordering; key it by (bin, sku) | patch |
| 15 | blind | No withdraw/cancel verb or TTL for abandoned pends | low | Real operational edge, but the frozen intent settles the flow as pending→decide with exactly two outcomes | defer |
| 16 | blind | FEFO-resolved batch consumed before approve → approval systematically 422s; only recourse is reject | low | Verified as designed: rollback-leaves-pending is the frozen boundary; the re-request/re-resolve flow is a genuine operational gap worth a PENDING entry for the 5-4/5-5 queue UX | defer |
| 17 | blind | Replay of a pend-creation key after the decision serves stale `status:'pending'` | false | The frozen matrix row 3 mandates replay re-serves the stored 202 snapshot unconditionally ("nothing below replay runs"); over-receipts have no equivalent replay to diverge from | reject |
| 18 | blind | `writeIdempotencyKey` + constant duplicated between the two command files | false | The per-command convention: 26 command files declare the constant, 15 carry their own `writeIdempotencyKey` — this story followed it exactly | reject |
| 19 | blind | FE consumes nothing of the 202 shape / nullable `event.id` — contract changed under it | false | Verification-gap layer traced: no FE or mobile surface sends stock adjustments (frozen decision 4: backend-only); capability mirror is the only FE touch and it's covered | reject |
| 20 | edge | Non-array jsonb `serial_ids` flows into `appendMovement` as a 500 | false | No reachable program path produces one — the typed commands are the only writers; hand-corrupted rows are outside the contract | reject |
| 21 | blind | `note` typed `string` on the 202 snapshot vs `string \| null` on the DTO/queue | low | Verified cosmetic: `pendAdjustment` always writes the required non-empty note, so both typings are locally truthful; no runtime divergence | reject |
| 22 | blind | Pend-request audit reuses action `stock_adjustment.recorded` (only `targetType` distinguishes) | low | Verified: `targetType stock_adjustment_pending` self-describes the row; a rename ripples the new tests and any action-filtering consumer for no demonstrated harm | reject |
| 23 | blind | Flow cannot be disabled via the API — PUT requires a non-null threshold; no DELETE/nulling verb | low | Verified: the column and CHECK admit null, but the PUT DTO requires non-null and no other write path exists; disable today = SQL. The frozen I/O note names the ABSENT row as the disable mechanism | defer |
| 24 | blind | Approve/reject carries no decision note | low | Verified: the decide command records status/decided_by/decided_at only; the frozen decision contract is exactly two outcomes with no note channel | defer |
| 25 | blind | The requester is never notified of the decision outcome | low | Verified: `stock_adjustment.pending_approval` (notifyRole owner) fires at pend creation; the decide path writes audit + terminal status, no outcome outbox row | defer |
| 26 | blind | `AdjustmentDecisionResponse` doc comment contradicts the implementation | false | Verified by DTO read: the comment describes the events array ("one per serial unit on a serial arm; the aggregate multi-serial snapshot carries id/seq = null") — exactly what the implementation returns | reject |
| 27 | blind | 202 pend snapshot omits `createdAt` while the queue's `AdjustmentPendingEntry` carries it | low | Verified: entry maps createdAt (adjustment-approval.command.ts:95,173); the 202 body is the replay acknowledgment, the queue is the read surface; adding the field would change the frozen replay snapshot shape for no matrix row | reject |
| 28 | blind | `ADJUSTMENT_PENDING_STATUSES` unused; the status union re-declared three times | low | Verified: the constant has no consumer outside schema.ts; the union lives in the query @IsIn, the DB CHECK, and the TS type | patch |
| 29 | blind | Non-null assertions (`quantityThreshold!`) on a nullable column | false | Verified: both sites are locally truthful — PUT's DTO requires non-null and no write path stores null (that absence is #23's finding), so every stored row carries a non-null threshold; row-21 precedent | reject |
| 30 | blind | Row-8 pin missing: over-threshold + bad shape never driven to assert the guard's 400/404 over a 202 | low | Verified by suite read: no test raises an over-threshold request that also fails a shape guard | patch |
| 31 | blind | Flag-flip scenario untested (SKU patched to tracked between raise and decide) | low | Verified: the tightened parity guards have no flag-flip test | patch (shared root cause with #39) |
| 32 | blind | Retro-A4: consumers of the changed serial-arm payload unaudited | false | Verified: the consuming suites were retooled in this story (ledger.spec multi-serial aggregate + single-serial pairing tests); no Epic 9 outbox subscriber exists to consume the old payload shape | reject |
| 33 | blind | Pend audit `targetId` moved from last event to first | false | Verified: pre-story `adjust` wrote zero audit rows (`git show 22ec29a:…inventory.command.ts` → no auditEvents) — the audit row is new in this story; nothing moved | reject |
| 34 | blind | Cursor encoding's extra double-pass is unneeded complexity | low | Verified: the `createdAtText` double-pass is how drizzle serves a raw expression next to the typed mapping; exercised by the pagination walk (ledger.spec:622-658) | reject |
| 35 | blind | Diff carries no docs updates | false | Verified: docs are the step-05 duty in the meta repo (repo-last cross-repo ordering) | reject |
| 36 | blind | No single-pend GET endpoint | low | Verified: the list endpoint with status filter covers every queue read; no consumer exists (frozen decision 4: backend-only) | reject |
| 37 | blind | Test-suite helpers hard-coupled across spec files | low | Verified: helpers are co-located with their suite per repo test convention; no concrete defect named | reject |
| 38 | blind | Files lack trailing newlines — gates will flag | false | Verified: the named files do lack trailing newlines, but the consequence is refuted — lint passed on the re-derivation tree; the repo enforces no eol rule | reject |
| 39 | vg | The new parity guards are exercised by no test (deleting inventory.command.ts:772-786 keeps every suite green) | medium | Pre-verified by the verification-gap layer | patch (shared root cause with #31) |
| 40 | vg | Owner-only gate on approve/reject never exercised (only the policy-PUT deny test exists) | medium | Pre-verified by the verification-gap layer | patch |
| 41 | vg | Retro-A4 outbox payload pairing asserted only where old/new agree | low | Pre-verified by the verification-gap layer | patch |
| 42 | vg | Concurrent first-time policy PUT 409 untested | low | Pre-verified by the verification-gap layer | patch |
| 43 | vg | Multi-serial adjust audit row targetId unasserted | low | Pre-verified by the verification-gap layer | patch |
| 44 | vg | Flow-disable unreachable (same surface as #23) | low | Pre-verified by the verification-gap layer; same evidence as #23 | defer |
| 45 | vg | RLS fail-closed probe covers only ledger_events/stock_on_hand/ledger_anchors — misses the two new tables | low | Pre-verified by the verification-gap layer (probe at client-isolation.spec.ts:660) | patch |
| 46 | edge | Over-threshold draw exceeding on-hand answers 202 where the same at-threshold request answers the fold's 422 | medium | Verified first-hand: `assertAdjustableInTx` carries no on-hand check; the controller's `assertBatchCoversDraw` covers only explicit-batchRef draws; a plain/FEFO over-draw crosses the branch and pends — the write-side fold refusal runs below it | reject (designed boundary — see #52; residue = the overstated comment, patched) |
| 47 | edge | Serial-elsewhere draw pends where at-threshold answers the write's 409 | low | Verified: the serial-location refusal lives in the write, below the branch | reject (same root cause as #46) |
| 48 | edge | HU-not-active draw pends where at-threshold answers the write's 409 | low | Verified: the 409 rides the write, not the guard (`assertHandlingUnitsAdjustableInTx` split, documented in-code) | reject (same root cause as #46) |
| 49 | edge | `fullPrecisionInstant` discards non-UTC offsets (emits Z regardless) | maybe-false | Verified: the regex matches and discards any non-UTC offset; no timezone pinning found in the db config — harm requires a deployment running a non-UTC session TZ, unconfirmed | defer |
| 50 | edge | Policy row not locked (`.for('update')`) during the adjust threshold read | low | Verified: the threshold read takes no lock — real; but a concurrent policy flip only moves the pend-vs-apply line between two correct outcomes (both replay/decide paths are frozen-safe), and locking the hot-path read buys nothing | reject |
| 51 | edge | Client-supplied `occurredAt` stamps the pend audit + outbox rows | low | Verified by repo-wide survey: movement-side audit rows stamp business time everywhere (putaway `placedAt`, bin `at`, qc `heldAt`/`releasedAt`, receiving `decidedAt`) and receiving's outbox row stamps `decidedAt` — the pend rows follow the exact sibling convention; no new client power | reject |
| 52 | edge(claim) | "Spec Intent Always: stock-guard failures never pend — code inserts the pend before on-hand/serial-location/HU-active checks" | medium | Verified: the triggers are real (#46-#48), but the frozen clause's "shape/stock guard" is defined by the spec's own Code Map as the `assertAdjustableInTx` set (the fold/serial/HU refusals live in the WRITE), matrix row 7 anticipates decide-time fold refusals (rollback-leaves-pending), and round-1 row 16 accepted apply-refuses-stays-pending as the frozen boundary. The fix sought would reword the frozen clause — rejected per the build rules; the residue (the overstated "only an adjustment that would have applied can pend" comment) is patched via #46 | reject |
| 53 | edge(claim) | Spec task's parity promise includes \|delta\| = serial count; `assertAdjustableInTx` checks presence only | low | Verified: presence-only, and the in-code justification ("parity is the above-the-transaction shape check") does not hold on the approval path where that check never runs; re-asserting parity in the guard is a 3-line tighten-only check the immediate path always satisfies | patch |
| 54 | edge | The disable flow is unreachable via the API (same surface as #23/#44) | low | Verified: same evidence as #23 — PUT requires non-null, no delete/nulling verb | defer |

## Design Notes

- Baselines: meta `decc50e`, BE `22ec29a`, FE `fb9caf9`, mobile `f821745`.
- **Threshold branch position is load-bearing:** after the guard set (only executable adjustments pend), behind replay (replays re-serve), before ledger writes (pend ≠ stock change). Pending row stores the **resolved** arms (batchId resolved at request; serial identities ensured at request — a rejected pend leaves ensured-but-inert serials, the same currency as any refused adjustment today).
- Approval apply runs at decision time (occurredAt = decision time; the pending row preserves the requested occurredAt). Negative-delta pends re-check `insufficient-on-hand` at apply — rollback-leaves-pending handles a concurrent pick starving the approval.
- Pending-queue read is a plain read (reads are never capability-gated).
- The a4 fix changes only the **multi-serial** response/outbox pairing (the frozen matrix row's scope); single-serial snapshots keep their exact `id/seq` pairing, and non-serial snapshots are byte-identical; old stored idempotency snapshots replay as stored.
- An override draw's `batch.overrideReason` is part of the "original reason/reference context" the acceptance criteria promise: the immediate path carries it in the ledger referenceDoc (required at 400-level by the controller), so the approved path must restore it from the pend row — the approved referenceDoc must be byte-identical to what the same request would have produced immediately.
- The arm-required parity checks (serials required + parity; batchRef required) mirror the controller's `composeBatchSerialArms` into `assertAdjustableInTx` so the approval path inherits adjust's full guard set even when the SKU's tracking flags were patched after the pend was raised. Behind the replay lookup, tighten-only: the immediate path always satisfies them.
- Keyset cursors (ledger timeline + pending queue) encode from the full-precision `::text` instant (`fullPrecisionInstant`, shared/primitives/time.ts): same-transaction appends share one `now()` to the microsecond, and a ms-truncated cursor's strict `<` would skip the tie group's tail. Response bodies still surface the ms-canonical instant — only cursor encoding changed.

## Verification

**Commands:**
- `bun run test -- test/adjustment-approval.spec.ts test/users.spec.ts test/client-isolation.spec.ts test/ledger.spec.ts` (jest; never bare `bun test`) — expected: green, including new arms
- `bun run test && bun run lint && bun run typecheck && bun run build` — expected: full gauntlet green
- `bun run db:migrate && bun run db:verify && bun run db:generate` — expected: migrate/verify clean; generate reports "No schema changes"
- `git status --short` — expected: no untracked files
- FE: `bun run check:capability-mirror` — expected: no drift named