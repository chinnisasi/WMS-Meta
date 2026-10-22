---
title: '3-5a blind counts and count admin — the handheld counts without seeing expected quantities; supervisors create, schedule and inspect counts on the web'
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
  - 'docs/design/modules/movements.md'
  - 'docs/design/frontend/SYSTEM-DESIGN.md'
  - 'docs/design/frontend/IMPLEMENTATION-GUIDE.md'
  - 'docs/design/mobile/SYSTEM-DESIGN.md'
  - 'docs/design/mobile/IMPLEMENTATION-GUIDE.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:**
- **Counts aren't blind.** The handheld shows the expected quantity beside every count line (`app/count.tsx:284-291, 403-406`), so operators confirm a number instead of counting. Expected quantities reach the device through the catalog snapshot (`transfer.facade.ts:821,836`) and the submit response (`SubmitCountResponse.variances[]`, also replayed from the idempotency store).
- **The device cannot record a SKU it finds that the task does not list.**
- **Count admin has no web surface** (PENDING): no task list, no task detail, no policy read, and no way to unschedule a class.

**Approach:**
- **Blind by construction.** No device-reachable payload carries an expected quantity, a delta or which SKUs differed. The device can **add a found SKU**.
- **A web Counts surface under Moves** (`/moves/counts`, EXPERIENCE.md places cycle counts under Moves):
  - a **Tasks** tab: list, detail, and on-demand create for bins or a zone;
  - a **Schedule** tab: the ABC policy per warehouse, with read, set and remove.

**Decisions (recommended, taken autonomously under the user's standing instruction, 2026-10-22; revised by the design review):**
1. **Split.** The full stock take with freeze is 3-5b. **Cancelling a count task is deferred**: it needs migration 0088, which cannot be generated correctly until 0087 (WMS-BE #116) merges. It also needs its own decisions on an orphaned recount variance, scheduler re-creation and queued submits. Recorded in deferred-work.
2. **Blind is unconditional.**
   - **Snapshot:** count lines become `{skuId, skuCode, skuName}` (the stale `binStateEpoch` "quoted back" description is fixed: submit already reads the epoch from the task row).
   - **`SubmitCountResponse`:** `variances` is always `[]`, with no count field. The epoch conflict stays on `countTask.epochConflict`, and `recountTaskId` stays.
   - **Replay:** the response is re-projected wherever a stored response is returned (the replay read and the controller spread, `movements.controller.ts:470`), so a pre-3-5a stored response never leaks.
   - **The device's settled note** says "Count recorded" (plus the recount sentence on a conflict).
3. **Rollout order: mobile first.** An older app build crashes when `expectedQuantity` is absent (`formatQuantity(undefined)` at `count.tsx:289,404`), and there is no minimum-version gate. The WMS-Mobile PR merges and the handheld fleet updates **before** the backend deploys. Stated in every PR.
4. **The web surface is `/moves/counts`.** A new route file under the Moves surface; nav stays 13, the Moves item stays active for `/moves/*`. It does not touch WMS-FE #103's `moves/page.tsx`; a link from the Moves page is a follow-up once #103 merges (PENDING).
   - The list is readable by any staff role and is **exempt from the client filter** (bins may be shared), showing `AllClientsNote`.
   - Writes are gated on `counts.manage`.
5. **On-demand create takes many bins.** `binIds` (1–500, unique) or `zoneId` (non-system, non-retired bins), beside the existing single `binId`.
   - **Single mode is unchanged** (response, refusals and fingerprint byte-identical, golden-pinned).
   - **Bulk mode** skips bins with an open task (and listed system or retired bins) and returns `{created: [...], skipped: [{binId, binCode, reason}]}`.
   - **Bulk-created tasks are not pushed** (the scheduled-count precedent). Their outbox payload carries `bulk: true` and push enqueue skips it. A summary push is PENDING.
6. **Remove a policy class.** `DELETE …/movements/warehouses/{w}/count-policies/{abcClass}` (`counts.manage`, keyed) unschedules it; an absent class is 404.
7. **Found SKUs on the handheld.**
   - **Scan routing:** once the bin is verified, a scan goes to `addFoundSku`, resolved with `workSkuIds` = the task's SKUs so a listed SKU wins. A listed SKU's scan adds 1 (or its pack factor) to that line; a found SKU's scan adds a line.
   - **Pack barcodes** follow `packScanRefusal`.
   - **Refused** (device and server, 400 on the server for a found line only): a kit, or a **batch-tracked, serial-tracked or catch-weight** found SKU. Their variance could never be resolved, since approve-adjust refuses them and a recount lists on-hand only.
   - **Another client's SKU** (`other-clients` scope) is **recorded** with an amber note, because a count is an observation and a mis-slotted item is the finding. An inactive SKU is recorded.

## Boundaries & Constraints

**Always:**
- **No device-reachable payload carries an expected quantity, a delta or the differing SKU ids.** That covers the snapshot, the submit response (fresh and replayed) and push. A test walks every key of both JSON bodies.
- **The task-detail route** (`TenantSessionGuard`) is the only place showing expected and counted. A device token gets 401 `unauthenticated` and a portal token gets 403 `role-denied`.
- **Bulk create:**
  - **Hash:** the existing single-bin fingerprint is unchanged; the bulk arm adds `mode: 'bulk'` and sorted `binIds` (or `zoneId`).
  - **Locks:** bin rows `FOR UPDATE` in sorted id order, then the warehouse advisory lock (the scheduler's order), then a **replay under the lock**.
  - **Audit:** one `count.created` (`count_task`) row per created task, sharing the key. An all-skipped request is an `AUDIT_NO_OP_ARMS` entry.
- **Policy delete audit:** `count_policy.removed` with target `warehouse`.

**Never:**
- No cancel, no migration, no freeze.
- No change to variance resolution.
- No per-tenant blind toggle.
- No count submit from the web.
- No new nav surface.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|---|---|---|---|
| Blind snapshot | a pending task with 2 lines | lines `{skuId, skuCode, skuName}` only | — |
| Found SKU | operator scans X (not listed), counts 3 | the submit carries X; the server records a variance expected 0, counted 3 | — |
| Found refused | X is a kit, or batch-, serial- or catch-weight-tracked | device refuses (pinned copy) | server 400 for that found line |
| Other client | X belongs to another client than the dedicated bin's | recorded, with an amber note | — |
| Submit response | 1 SKU differs | `{countTask, variances: [], recountTaskId}` | — |
| Replay of an old stored response | key stored before 3-5a with quantities | re-projected: `variances: []` | — |
| Bulk create | zone of 12, 2 with open tasks | 10 created (not pushed), 2 skipped `count-task-open` | > 500 bins → 422 `too-many-bins` |
| Single create | `binId` as today | byte-identical response and refusals | — |
| Policy remove | DELETE class `b` | row removed; the scheduler stops `b` | absent → 404 |
| Task detail | web staff session | lines with expected and counted, variances, the recount task when a variance names one | device → 401; portal → 403 |

</frozen-after-approval>

## Code Map

### Backend (`workspace/core/backend/wms-be`)

**Snapshot blindness**
- `src/modules/movements/transfer.facade.ts:770-849` `getCountTasks`: drop `expectedQuantity`.
- `src/modules/inbound/receiving.dto.ts:1165-1197`: drop the DTO field; fix the `binStateEpoch` description.

**`src/modules/movements/count.command.ts`**
- **Submit:** project the response through one `blindSubmitResponse(...)` used on write, on replay (`:732-741`) and by the controller (`movements.controller.ts:470`). `count.dto.ts:224-253` changes to match.
- **Found lines** (`:817-881`): the SKU read adds `kind`/kit, batch, serial and catch-weight flags. A found line (not in the task) of a kit or of a tracked or catch-weight SKU is 400 `count-found-sku-not-countable`. This sits behind the replay, since it tightens a rule.
- **Bulk create** (`createFingerprint :414-421`; locks `:465-477`; the scheduler's lock order `:1696-1699, 1829`): as in Boundaries. The outbox `count.created` gains `bulk: true` on that arm only.
- **`deleteCountPolicy`:** keyed; the warehouse advisory lock; outbox `count.policy_updated`; audit `count_policy.removed`.
- **Reads:**
  - `listCountTasksInTx` (warehouse, status, origin, binId, keyset `(created_at desc, id)`, limit ≤ 200).
  - `countTaskDetailInTx` (lines expected and counted; variances with status and delta; `recountTaskId` from the variance rows).
  - `getCountPoliciesInTx`.
- **Already true, no change:** the scheduler counts only `completed` tasks (`:1783, 1852`); submit reads the epoch from the database (`:812`).

**`src/api/movements.controller.ts`**
- `GET :t/movements/counts` and `GET :t/movements/counts/:taskId` (`TenantSessionGuard`, any staff).
- `GET` and `DELETE :t/movements/warehouses/:w/count-policies[/:abcClass]` (the existing PUT prefix, `:475`).
- Bulk create on the existing POST.

**Push, audit and tests**
- `src/modules/notifications/push.enqueue.ts:87-89, 170-173`: skip `count.created` with `bulk: true`. Pin it in `test/push.spec.ts`.
- `src/shared/primitives/audit.ts`: `count_policy.removed` in `AUDIT_NEW_ACTIONS`; the bulk all-skipped arm in `AUDIT_NO_OP_ARMS`.
- Existing count suites are updated for the blind response.

### Mobile (`workspace/core/mobile/wms-mobile`)

- **`app/count.tsx`:** remove both expected displays and their comments (`:36, :180-183, :284-291, :403-406`). After the bin is verified, scans route to `addFoundSku` (`onScanEvent :105-118`), and `countScanAccepts` is re-pinned by state.
- **`src/counts/draft.ts`:**
  - `addFoundSku(draft, snapshot, scan)`: `resolveSku` with the task's SKUs as `workSkuIds` and `clientId` = the bin's dedicated client. A listed SKU adds its quantity or factor; a new SKU adds a line; `packScanRefusal` applies; kit and tracked or catch-weight found SKUs are refused; ambiguous means typing the SKU code; `other-clients` is recorded with the amber note.
  - Every string is pinned.
  - `submitPayload` includes found lines.
- **`src/api.ts:1776-1800`:** `CatalogCountTaskLine` without `expectedQuantity`; `CountSubmitResponse` with `variances: []`.
- **`src/state/catalog-snapshot.ts:149`:** map each count line to `{skuId, skuCode, skuName}`. The legacy seal (still carrying `expectedQuantity`) is pinned by equality with the key absent.
- **`src/state/replay-classification.ts:912-926`:** `countReceiptNote` gives "Count recorded" plus the conflict sentence. `count-found-sku-not-countable` is rejected. Re-pin the tests (`:390-410`).

### Web (`workspace/core/frontend/wms-fe`)

**`src/app/(app)/moves/counts/page.tsx` (new)** and **`src/components/counts/counts-screen.tsx`:** the sessioned pattern, plus `definePageTabs` Tasks / Schedule in `src/lib/page-tabs.ts`. Navigation keeps Moves active for `/moves/*` (check `navigation.ts` matching).

**`count-tasks.tsx`**
- **List:** status and origin filters, Load more, times through the ledger IST formatter (`ledger.ts:15`), and `AllClientsNote`.
- **Row expand → detail:** lines expected vs counted, variances, and the recount task. The link to `/conflicts?queue=variances` appears only with `variances.resolve`, and says it opens the whole queue.
- **New count:**
  - a zone picker (non-system zones) or a bin multi-select from `useWarehouseBins` (filter out system and retired bins), capped at 500 on the client;
  - a per-draft key cleared on any selection change;
  - the result shows created and skipped.

**`count-schedule.tsx`:** the policies, a set (PUT; a key per save) and a remove (DELETE; a key per removal), all `counts.manage`.

**`src/lib/counts.ts`:** mappers and labels, with tests.

**Other**
- `src/lib/api/client.ts`: wrappers.
- `src/lib/users.ts:107-115`: the comment updated, since counts now have a web surface.
- Regenerate the client.

## Tasks & Acceptance

**Execution:**
- [ ] BE: blind snapshot and response (write, replay, controller), found-line guard, bulk create, policy delete, reads, routes, push skip, audit; OpenAPI.
- [ ] BE `test/counts-admin.spec.ts`:
  - every matrix row;
  - the no-leak key walk (fresh and a replayed pre-3-5a stored response);
  - the single-create fingerprint golden;
  - bulk lock order and the replay under the lock;
  - bulk not pushed;
  - detail returns 401 for a device and 403 for a portal session;
  - existing count suites updated.
- [ ] Mobile: blind screen, scan routing, found SKUs, note, classification, plus tests (all pinned copy, payload with found lines, legacy seal).
- [ ] Web: route, tabs, list and detail, create, schedule, mappers, plus tests; regenerated client.
- [ ] Meta docs:
  - `API-SURFACE.md`;
  - `movements.md`;
  - frontend SYSTEM-DESIGN (route map, including `/moves/counts`; fix the stale `/moves` row `:49`);
  - EXPERIENCE.md if it lists routes;
  - mobile SYSTEM-DESIGN (count is blind; a `countTasks[]` snapshot row; fix `:53`);
  - mobile IMPLEMENTATION-GUIDE fate table;
  - READMEs, with the **mobile-first rollout** stated;
  - PENDING: close "Count admin has no web surface" and "no policy delete"; add cancel, the bulk summary push and the Moves-page link.

**Acceptance Criteria:**
- Given any count on the handheld, when the operator opens, counts and submits it, then no expected quantity, delta or variance indication is visible, including after sync.
- Given a supervisor on `/moves/counts`, when they create counts for a zone, then each eligible bin gets one task (not pushed), and bins with an open task are listed as skipped.

## Design Notes

- **Why the response is blind for every caller.** The submit route is shared, and its stored response is replayed to whoever retries. No web surface submits counts; the variance queue has its own read.
- **Why other-client found SKUs are recorded.** A count records what is in the bin; refusing a mis-slotted item hides the discrepancy the count exists to find. Batch, serial and catch-weight SKUs are refused instead because their variance would have no resolution path today.

## Verification

**Commands:**
- `bun run test -- test/counts-admin.spec.ts test/push.spec.ts test/architecture.spec.ts` plus the existing count and variance suites (wms-be, run alone): pass.
- `bun run lint && bun run typecheck` (wms-be, wms-fe); `bun test` + typecheck (wms-mobile, wms-fe): pass.

## Implementation Notes

## Spec Change Log

## Review Triage Log

Design review, 2026-10-22 (backend B, clients C). Every accepted finding is folded into the spec above; all choices are recommended, taken autonomously.

| ID | Verdict | Finding → resolution |
|---|---|---|
| B1 | high | Submit accepts found kits, inactive and foreign SKUs unchecked. Kit and tracked/catch-weight found lines refused server-side; foreign and inactive recorded (C4). |
| B2 | high | Tracked or catch-weight found SKUs make unresolvable variances. Refused (decision 7). |
| B3, B5 (part), B12, B13, B14 (migration) | high | Cancel orphans recount variances, is re-created by the scheduler, has no device refresh and dead-ends queued submits; 0088 cannot be generated before 0087 merges. Cancel deferred; no migration (decision 1). |
| B4 | medium | No `recount_of` column. Dropped; the detail shows the variance → recount link only. |
| B5 | medium | Scheduler and epoch claims were already true. Recorded as "no change". |
| B6 | medium | Policy route prefix wrong. Uses `movements/warehouses/...`. |
| B7 | medium | A device token on the detail route gets 401, not 403. Matrix fixed. |
| B8 | medium | Bulk fingerprint, shape, locks and replay unspecified. Boundaries. |
| B9 + B10 | medium | Audit "?" and an all-skipped request with no row; vocabulary names. Per-task `count.created`; no-op arm; `count_policy.removed`. |
| B11 + C7 | medium | Bulk create floods pushes. `bulk: true` skipped by push; summary push PENDING. |
| B14 (replay) | medium | Replay returns the stored snapshot raw. One projector on write, replay and controller. |
| C1 | high | Old app builds crash without `expectedQuantity`. Mobile-first rollout (decision 3). |
| C2 | high | No scan routing to Add item. State-based routing; listed SKUs win. |
| C3 | high | Pack-scan rule contradicted the helper. `packScanRefusal` applies. |
| C4 | high | Another client's found SKU undecided. Recorded with an amber note. |
| C5 | medium | Variance ids and count still leaked. `variances: []`, no count. |
| C6 | medium | Legacy seals keep expected quantities on the device. Parse maps lines; pinned. |
| C8 | medium | A new page breaks the IA (counts sit under Moves; 13 surfaces). `/moves/counts`; nav unchanged. |
| C9 | medium | Wrong deep-link parameter and an ungated link. `?queue=variances`, gated on `variances.resolve`. |
| C10 | medium | Client filter and IST helper undecided. Exempt, with `AllClientsNote`; the ledger formatter. |
| C11 | low | Key lifetimes, system zones and the cap. Stated. |
| C12 | low | Missing docs. Listed. |
