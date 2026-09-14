---
title: 'Story 4.4: Short-pick re-planning'
type: 'feature'
created: '2026-09-14'
status: 'in-review'
route: 'dispatch'
review_loop_iteration: 0
baseline_commit: 'd04110f' # wms-be main
context:
  - '_bmad-output/implementation-artifacts/epic-4-context.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** A bin with less than the task quantity stalls the wave. The operator cannot report it — picks are whole-line only — so the line sits `planned` forever, the order waits, and nobody learns which bins keep coming up short.

**Approach:** Let the operator draw what is actually there, with a reason. The server settles what moved, frees the rest, and re-plans the remainder onto an alternate bin in the same picklist when the stock exists elsewhere. When it does not, the line stays short and the order is under-fulfilled honestly.

**Decided (2026-09-14, human):**
- **Release the whole hold and re-grant the remainder server-side.** Reservations are whole-quantity with no partial commit, and `grant` treats a different quantity on the same owner as a hard 409. So a short pick draws N through the ledger, releases the original M-unit hold, and grants a fresh hold for the remainder against the alternate bin. AD-14 forbids an **offline client** granting new ATP; this runs server-side at replay, which is by definition online. Epic 2's reservation machinery is not touched.
- **A re-plan is a new slice on the same picklist** — same `order_line_id`, the next unused `slice_seq`, the alternate bin, and a `walk_seq` that sorts after the stops already delivered. This is FR-15's "within the same Picklist" and UX-DR10's "new task cards linked to the original ref".
- **A zero-unit short pick is recorded on the line, not in `picks`.** Nothing moved, so there is no ledger event and no `picks` row; `picks` keeps meaning "units that actually moved" and both its CHECKs stand. The line carries the reason and the shortfall, which is what SM-3 needs.

**Decided (technical, from investigation):**
- The re-grant **failing is not an error** — it is the partial-order path. If ATP is gone there is nowhere to re-plan to, so the line stays short with its shortfall recorded and no new slice is created.
- **No order-level status changes.** `orders` has only `accepted|cancelled`, and the picking/packed/dispatched arms belong to 4.5/4.6. A partly-picked order stays `accepted`; its under-fulfilment is visible through its lines, not a new state machine.
- SM-3 needs a **queryable durable row**, not a surface. The dashboard is story 9.1 (backlog, Epic 9), and the repo precedent is story 3.5: record the row, ship the surface later.

## Boundaries & Constraints

**Always:**
- The draw, the hold release, the re-grant, the line flip and the new slice **commit in one transaction**. A short pick that half-lands would either free units that left the bin or hold units nobody will pick.
- **ATP is correct after every short pick.** Releasing M and drawing N must leave available-to-promise exactly as if the line had been planned for N all along, plus the re-granted remainder. This is the invariant to test, not the arithmetic to assume.
- `picklist_lines` gains a `short` status arm and a `reason_code`. `short` must stay **outside `'cancelled'`** or the one-open-slice partial unique index frees the order line while it is mid-pick. The slice-shape CHECK gains a third arm for it.
- The reason comes from a **fixed enum**, validated in the command with a 400 naming the whole set — the `PUTAWAY_MISMATCH_REASON_CODES` pattern. A reason is required on every short pick, including a zero-unit one.
- A re-planned slice is only created when the SKU genuinely has drawable stock in another pickable bin — the `planSlices` filter set (not blocked, not system-owned, not retired, batch drawable) applied through `InventoryFacade`. Never the short bin itself.
- The short-picked line is terminal at `short`: it is never re-picked. The remainder lives on the new slice, which is an ordinary `planned` line with its own id, reservation and walk position.
- The device keeps the 4.3b transport unchanged — a short pick is an ordinary queued op that replays idempotently, with the same epoch and classification behaviour as a full pick.

**Never:**
- No partial commit, no new reservation state, no change to `grant`/`commit`/`release`/`expireDue` semantics.
- No order status arms, no `picked_qty`/`fulfilled_qty` column on `order_lines`, no partial-order state machine (4.5/4.6).
- No dashboard, report or aggregation surface (9.1) — this story records the row only.
- No re-planning across picklists or waves, and no second re-plan of an already re-planned slice that comes up short (it short-picks again like any other line).
- No web surface (`4-2b`).

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Short pick, stock elsewhere | line plans 5 at A, operator draws 3 with a reason | `201`; ledger draws 3, line `short` (shortfall 2, reason), original hold released, 2 re-granted, new slice at the alternate bin | N/A |
| Short pick, no stock elsewhere | line plans 5 at A, draws 3, SKU nowhere else pickable | `201`; line `short` (shortfall 2), hold released, **no new slice** — the partial-order path | N/A |
| Zero-unit short pick | bin empty, operator reports 0 with a reason | `201`; **no ledger event, no `picks` row**; line `short` (shortfall 5, reason), hold released, remainder re-planned if stock exists | N/A |
| Short pick equal to the plan | operator reports the full quantity as a "short" | treated as an ordinary full pick | N/A |
| Missing or unknown reason | short pick with no reason, or one outside the enum | nothing written | `400 validation-failed` naming the whole set |
| Short pick above the plan | drawn quantity exceeds the line's planned quantity | nothing written | `400 validation-failed` |
| Re-grant finds no ATP | remainder cannot be re-held | line still `short`, no slice, no hold — same as no-stock-elsewhere | never a 5xx |
| Replay of a short pick | same key, same payload | the stored snapshot re-serves; no second draw, no second slice | `422` on a changed payload |
| Stale short pick | bin drained further before replay | classified by 4.3b's taxonomy — `409 pick-bin-short`, re-plannable | nothing written |
| Wrong authority | non-operator, foreign tenant, bare device credential | nothing written | `403 role-denied` / `permission-denied` / `badge-in-required` |

</frozen-after-approval>

## Code Map

- `workspace/core/backend/wms-be/src/modules/outbound/pick.command.ts:240` — `recordPick`. The full-quantity rule to replace is at **`:487-491`** (`command.qty !== line.qty` → 400). Everything above it is reused verbatim: device re-auth (`:265-278`), `picks.execute` (`:280`), idempotency replay (`:284-303`), terminal gates (`:310-420`), wrong-item (`:462`), bin lock + gates (`:495-536`), serial arm (`:553-586`), `lockWarehouseInTx` + epoch classification (`:600-634`), `deriveBatchArms` (`:967`), `binOnHandInTx` (`:1027`), settlement (`:855-915`), outbox (`:934`), `writeIdempotencyKey` last (`:957`).
- `workspace/core/backend/wms-be/src/modules/inventory/reservation.service.ts` — `grant` (`:269`; a different quantity on the same owner is a hard 409 at `:423-440`, so the release MUST precede the re-grant), `release` (`:537`, restores the whole `row.quantity` to the counter at `:943`), `commitInTx` (`:487`). The Valkey counter is per `(tenant, warehouse, sku)` — a scope total, not per reservation (`src/shared/valkey/reservation-keys.ts:21`).
- `workspace/core/backend/wms-be/src/modules/outbound/wave.command.ts:1061-1253` — `planSlices` is the existing "where is this SKU" query: pickable-bin filter (`:1076-1092`), `stockByBinsInTx` + `batchOnHandByBinsInTx` (`:1094`), the per-SKU pool in walk order × FEFO with `drawableBatch` and the per-bin budget (`:1108-1161`). It is `private` and consumes its pool destructively — extract the alternate-bin lookup rather than calling it. `PICKLIST_LINE_STATUSES` at `:53`; `sliceSeq` assignment at `:1179-1200`; `walkSeq` at `:555` after `sortWalk` (`:1440-1453`).
- `workspace/core/backend/wms-be/src/shared/db/schema.ts:1659-1719` — `picklist_lines`. The constraints a re-plan insert must satisfy: `picklist_lines_open_order_line_unique` (`:1704`, on `(tenant, order_line_id, slice_seq)` where `status <> 'cancelled'` — so a new slice needs an unused `slice_seq`) and `picklist_lines_slice_shape` (`drizzle/0018_narrow_lake.sql:137-140`, which currently forbids a binned line carrying a shortfall — the `short` arm needs a third branch).
- `workspace/core/backend/wms-be/src/shared/db/schema.ts:1744-1803` — `picks`. `picks_line_unique (tenant, picklist_line_id)` means one row per line, which the re-plan satisfies naturally because the new slice is a new line. `picks_qty_positive` is why a zero-unit short pick writes no row.
- `workspace/core/backend/wms-be/src/modules/putaway/putaway.command.ts:42-49` — `PUTAWAY_MISMATCH_REASON_CODES`: the reason-enum pattern (TS `as const`, command-layer 400 naming the set, nullable text column, echoed into the ledger `referenceDoc`). Its `suggestBinInTx` (`:689`) is **not** reusable — it ranks by free space and ignores the SKU.
- `workspace/core/backend/wms-be/src/modules/inventory/inventory.facade.ts:570` — `stockByBinsInTx`; `:655` `batchOnHandByBinsInTx`. These are the public primitives the alternate-bin lookup composes.
- `workspace/core/backend/wms-be/test/picking.spec.ts` — `drainStock`/`seedStock` helpers, the 4.3b taxonomy arms, and the RLS + CHECK probes to extend.
- `workspace/core/mobile/wms-mobile/src/picking/draft.ts:353-373` — `confirmPayload` (sends `qty: draft.task.qty` at `:368`); header comment at `:21` says short-picking is 4.4. `app/pick.tsx:277-316` `onConfirm` enqueues one `pick.record` op; the confirm button is at `:441-452` and the ghost-button slot directly below (`:459-470`) is where the mockup puts "Record a short-pick". There is no quantity stepper today.
- `_bmad-output/planning-artifacts/ux-designs/ux-WMS-Meta-2026-09-08/mockups/key-mobile-pick.html:181,195` — the amber "Bin short — record a short-pick" line and the ghost button. The mockup specifies **no reason-picker UI and no alternate-bin card**; those are this story's to design within the established banner/step patterns.
- `workspace/core/mobile/wms-mobile/src/state/replay-classification.ts:31-40` and `src/offline/engine.ts:135-180` — the 4.3b re-plannable transport already exists and is tested; a short pick rides it unchanged.

## Tasks & Acceptance

**Execution:**
- [ ] `wms-be drizzle/0022_*.sql` — `picklist_lines` gains `reason_code`, the `short` status arm, and the third slice-shape arm; RLS unchanged
- [ ] `wms-be src/shared/db/schema.ts` — the column and the widened status tuple
- [ ] `wms-be src/modules/outbound/pick.command.ts` — short-pick path: reason validation, the draw, release + re-grant, the line flip, the new slice
- [ ] `wms-be src/modules/outbound/replan.ts` (or equivalent) — the alternate-bin lookup extracted from `planSlices`' primitives
- [ ] `wms-be src/modules/outbound/outbound.dto.ts` + `src/api/outbound.controller.ts` — `qty` below the plan plus a required `reasonCode`; OpenAPI
- [ ] `wms-be test/picking.spec.ts` — the matrix e2e, including the ATP invariant, the zero-unit arm, the no-stock-elsewhere path, and the re-planned slice's walk position
- [ ] `wms-mobile src/picking/draft.ts` — a short-pick draft arm: quantity below the plan, the reason enum, `confirmPayload`
- [ ] `wms-mobile app/pick.tsx` — the "Record a short-pick" action, quantity entry and reason picker
- [ ] `wms-mobile src/picking/draft.test.ts` — the new arms
- [ ] `wms-be bun run openapi:export` + `wms-fe bun run api:generate`

**Acceptance Criteria:**
- Given a bin holding less than the task quantity, when the operator short-picks with a reason and the SKU exists in another pickable bin, then a new slice for the remainder appears on the same picklist at that bin
- Given the same short pick when the SKU exists nowhere else, then the line is recorded short with its shortfall and no new slice is created
- Given any short pick, then ATP afterwards equals what it would have been had the line been planned for the drawn quantity, plus any re-granted remainder
- Given an empty bin, when the operator reports zero with a reason, then no ledger event and no `picks` row are written and the line still carries the reason and the full shortfall

## Implementation Notes

**A short pick may create MORE than one re-planned slice.** The spec's I/O matrix says "a new slice" (singular), which is what happens whenever one alternate bin covers the whole shortfall — the ordinary case. When none does, `findReplanSlices` walks the SKU's remaining pickable bins in walk order, FEFO within each, and emits one slice per (bin, batch) it draws from, exactly as `planSlices` would have done had the wave been planned against today's stock. Anything still uncovered stays as the short line's recorded `shortfall_qty` — the partial-order path, per slice rather than all-or-nothing. This is a superset of the specified behaviour, not a deviation from it: the alternative (re-plan only when a single bin covers the whole remainder) would drop a line onto the partial-order path while the units it needs are sitting on two shelves.

**What "the remainder" means on a multi-slice order line.** Nothing ever shrinks `reservations.quantity` — a hold is a whole-quantity row whose only mutation is `state` — so after a sibling slice is picked in full the hold still reads the order line's original total. The re-grant therefore nets out the units every TERMINAL sibling already drew (`picked` → its whole `qty`, `short` → `qty - shortfall_qty`) before subtracting this command's own draw. On such a line the short pick's net counter restore legitimately EXCEEDS its own draw: those earlier units left the building under a hold that went on counting them, and the release/re-grant pair is the first moment the journal can say so.

**`grantReservationInTx` is the one grant in the system that does not run the Valkey script.** It re-grants no more than a hold the same transaction just released for the same owner scope, so the scope's journal-reserved total can never rise across the commit and no ATP is created — which is why grant-vs-grant arbitration is not needed here and why the ceiling re-read is only asking "has the stock vanished underneath". The precondition rides the signature (the released snapshot is a required argument and is validated; a violation throws rather than returning the partial-order `null`), and the caller must hold the per-warehouse advisory xact lock. Used to mint a NEW hold, or without that lock, it would be a second unarbitrated grant path and could oversell — see the comment on `ReservationService.grantInTx`.

**Both cancel paths key on one predicate, `picklistLineDrewUnits()`.** A `short` line that actually drew units is not freed by a wave cancel and refuses an order cancel; a ZERO-unit report drew nothing and does neither. Keying either path on `status = 'short'` alone would strand the order line inside `picklist_lines_open_order_line_unique` forever, unwaveable even after stock arrived.

## Spec Change Log

- **2026-09-15 — "a new slice" is one OR MORE.** The I/O matrix's singular wording is kept; the implementation emits several re-planned slices when no single alternate bin covers the shortfall (see Implementation Notes). Recorded rather than changed: it is a superset of the specified behaviour, reached through the same pool the wave planner uses.

## Review Triage Log

_Three layers (blind hunter, edge cases, verification gaps) — 2026-09-14. Verification-gap findings arrive pre-verified; every other claim was re-checked against the source before grading._

| # | Finding | Verdict | Evidence | Route |
|---|---------|---------|----------|-------|
| 1 | The re-granted remainder double-counts units already drawn by sibling slices | high | All three layers, independently. `remainder = released.quantity - command.qty`, but nothing shrinks `reservations.quantity` as slices are picked — only `state` is ever mutated. An 8-unit line with slice A picked whole (4) then slice B short-picked at 1 re-grants 7 when 3 are owed: 4 phantom reserved units understating ATP, or an over-ask that fails the ceiling and silently drops a re-plannable line onto the partial-order path. **My own ATP verification could not catch this** — `counterRestoreUnits` derives from the same inflated remainder, so counter and journal stay consistent while both are wrong | patch |
| 2 | `grantInTx` bypasses the Valkey arbitration every other grant uses | high | Confirmed at `reservation.service.ts:1318-1324`: it reads `committedCeiling` and `journalReservedSumInTx` from Postgres, checks, and inserts. `runGrantScript` and the counter never appear. This is a second grant path without grant-vs-grant arbitration, contradicting the spec's "Epic 2's reservation machinery is not touched". It runs under the warehouse advisory lock, which may serialize it in practice — but that is a different guarantee, and nothing says so | patch |
| 3 | `findReplanSlices` allocates nothing, so it can plan the same units twice | high | It excludes only the short bin and never subtracts units other open `planned` lines already plan to draw — the reason `planSlices` consumes its pool destructively. The new split test plans 7 units out of a bin holding 4 and passes only because it never draws the re-planned slice | patch |
| 4 | Wave cancel spares a zero-unit `short` line, stranding the order line forever | high | `not in ('picked','short')` is justified by "its drawn units have left the bin" — false when nothing was drawn. The line keeps its claim in the one-open-slice index, so the order can never be re-waved even after stock arrives. `order.command.ts` gets the same distinction right with `shortfall_qty < qty` | patch |
| 5 | Both halves of the new order-cancel predicate are untested | high | Pre-verified: reverting to `status = 'picked'` leaves the suite green — an order carrying a short line that drew units would cancel, freeing a hold for stock that has left the bin. Dropping the `shortfall_qty < qty` qualifier wedges cancellable orders, also silently | patch |
| 6 | The wave-cancel `short` exclusion is unexercised | high | Pre-verified: restoring `<> 'picked'` fails nothing; the short line flips `cancelled`, erasing the shortfall and reason the code calls the SM-3 signal | patch |
| 7 | The short-pick facts on the ledger `reference_doc` are never read back | high | Pre-verified: `ledgerFor` does not select `reference_doc`, so deleting the spread makes short draws indistinguishable from whole ones in the permanent record, with every test green. Putaway's equivalent IS asserted (`putaway.spec.ts:687`) | patch |
| 8 | The ledger grammar was not extended for the new reference-doc fields | medium | The `kind: 'pick'` arm still declares only the 4.3 fields; `referenceDoc` is assigned to a `const` first so excess-property checking never fires. The ledger persists fields the declared grammar does not name — and putaway's precedent, which this cites, does declare its `reasonCode` | patch |
| 9 | The serial-tracked zero-quantity branch has no test | high | Pre-verified: removing the `command.qty > 0 &&` guard makes a serial-tracked empty-bin report 400, the precise case the comment says must stay reportable, with the suite green. No fixture combines serial tracking with a short or zero pick | patch |
| 10 | The pre-4.4 stored-snapshot replay fallbacks are unexercised | medium | Pre-verified: the replay test writes its snapshot through the 4.4 path, so none of the five `??` arms fires. Deleting them fails nothing, and a key written before the deploy replays a `PickDto` missing non-optional fields. The repo has the precedent at `bin-admin.spec.ts:828` | patch |
| 11 | Migration 0022 leaves the short-pick invariant unenforced | medium | Nothing ties `reason_code` to `status = 'short'`, nothing requires a shortfall on a short line, and the new third slice-shape arm carries no status predicate — so a still-`planned` slice can record a shortfall it never experienced. The suite asserts a reason-less short line **succeeds**, demonstrating the gap | patch |
| 12 | `pendingCounterRestore` is staged inside the transaction callback and read after it | medium | If `withTenantTransaction` ever retries the callback, a value staged by a failed attempt survives into a successful attempt that stages nothing, decrementing the counter for a transaction that never committed — the overselling direction the surrounding comments guard against | patch |
| 13 | Typing a quantity and tapping Confirm without blurring queues the PREVIOUS quantity | high | `onEndEditing` is the only path into the model, so the op carries a number the operator never sees. A data-integrity bug on the device, not a UI nit | patch |
| 14 | An empty or non-numeric quantity yields `NaN`, which the model rejects while the field keeps the bad text | medium | The box then shows something other than what confirm will queue; the `−`/`+` steppers also lack a disabled state, so tapping `−` at zero raises a rejection banner instead of being inert | patch |
| 15 | The short-pick arm is reachable before a bin is scanned, then silently discarded | medium | `beginShortPick` requires only a task; `chooseBin` resets `short: null` with no banner. The model's own comment ("the short report is about a BIN") is the argument for gating it | patch |
| 16 | The DTO advertises a closed enum it does not validate | medium | `reasonCode` is documented `enum: [...SHORT_PICK_REASON_CODES]` but validated `@IsString() @Length(1,64)`, so generated clients get a closed type while the pipe accepts any string | patch |
| 17 | `PickDto.id` became nullable — a breaking response-contract change with no contract-doc update | medium | Widens the type for every existing consumer, and `PICKLIST_LINE_STATUSES` gained an arm, with no update to `docs/repos/*/README.md` as CLAUDE.md requires for a cross-repo change | patch |
| 18 | Concurrent short picks on one picklist mint the same `walk_seq` | low | The `max(walk_seq)` read is unlocked and cross-order-line, contradicting the method's own comment that the order-line `FOR UPDATE` covers sequencing. Harmless today (non-unique index, ties break on id) | patch |
| 19 | `insertReplanSlices` selects every `walk_seq` into memory to take a max | low | A `max()` in SQL would do; the read is also the one racing in #18 | patch |
| 20 | `journalReservedSumInTx` duplicates `journalReservedSums` | low | Near-verbatim copy differing only in opening its own transaction; the existing helper could take an optional `tx` | patch |
| 21 | The 409 title still reads "Order has picked lines" after the detail was reworded | low | Confirmed | patch |
| 22 | Multiple re-planned slices where the spec says "a new slice" | low | Real superset, not a deviation — if no single bin covers the shortfall, several slices are created greedily. Worth recording in the Spec Change Log rather than changing code | patch |
| 23 | `confirmBlocker`'s `qty >= task.qty` branch is unreachable through the exported API | low | `beginShortPick` seeds `task.qty - 1` and `setShortQty` rejects anything higher — defensive, not a coverage gap | rejected |


## Design Notes

**Why release-then-re-grant rather than partial commit.** A partial commit would need either a `committed_qty` column and a non-terminal arm — which breaks AD-12's "exactly one terminal transition wins", the conditional-UPDATE invariant every reservation transition relies on — or a split that mutates `reservations.quantity`, which nothing does today and which `grant`'s idempotency treats as a conflict signal. Both also force `rebuildCounters` and `parityPass` to learn a new shape or loop forever. Release-then-re-grant reaches the same end state using only transitions that already exist, and the re-grant failing is not a defect: it is exactly the condition FR-15 calls the partial-order path.

**Why the re-planned slice is a new line rather than a mutated one.** `picks_line_unique` allows one pick row per picklist line, and the short-picked line already has one. A new line gives the remainder its own identity, its own reservation, its own walk position and its own pick row — and leaves the short-picked line as an honest terminal record of what happened at that bin, which is the SM-3 signal.

## Verification

**Commands:**
- `cd workspace/core/backend/wms-be && bun run test && bun run lint && bun run typecheck && bun run build && bun run db:migrate && bun run db:verify` — run the full suite against a **freshly reset** database (drop the `public` and `drizzle` schemas, `FLUSHALL` Valkey, migrate) — a suite verified warm has twice hidden a failure here
- `cd workspace/core/mobile/wms-mobile && bun run test && bun run typecheck`
- `cd workspace/core/frontend/wms-fe && bun run test && bun run lint && bun run typecheck && bun run build`
