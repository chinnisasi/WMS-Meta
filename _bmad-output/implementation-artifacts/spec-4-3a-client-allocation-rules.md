---
title: '4-3a client allocation rules — FEFO or FIFO and a minimum remaining shelf life to the customer, on the client policy row, applied by wave planning, short-pick re-plan, the pick draw and ATP, and shown on the web and the handheld'
type: 'feature'
created: '2026-10-23'
status: 'ready-for-dev'
route: 'dispatch'
review_loop_iteration: 0
context:
  - '_bmad-output/implementation-artifacts/epic-4-context.md'
  - '_bmad-output/implementation-artifacts/spec-3-3a-batch-block-and-unpromisable-stock.md'
  - 'docs/initiatives/production-readiness.md'
  - 'docs/design/SYSTEM-DESIGN.md'
  - 'docs/design/IMPLEMENTATION-GUIDE.md'
  - 'docs/design/modules/outbound.md'
  - 'docs/design/modules/inventory.md'
  - 'docs/design/modules/clients.md'
  - 'docs/design/PENDING.md'
  - 'docs/design/API-SURFACE.md'
  - 'docs/design/frontend/SYSTEM-DESIGN.md'
  - 'docs/design/frontend/IMPLEMENTATION-GUIDE.md'
  - 'docs/design/mobile/SYSTEM-DESIGN.md'
  - 'docs/design/mobile/IMPLEMENTATION-GUIDE.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** Every client's stock is allocated the same way, and not by any rotation rule. The wave planner walks bins in code order and ranks FEFO only *inside* one bin (`replan.ts:80-160`, the sort at `:133`), so a batch expiring in 30 days in bin `B-01` waits behind a 200-day batch in `A-01`. There is no FIFO. And nothing stops a pharma or food client's 20-day-left stock being picked for a customer who will refuse it: 1-2b's minimum shelf life is receiving-only, and it deferred "FEFO/FIFO allocation and minimum life to the customer" here, as fields on the same client row (1-2b decision 1; `clients.md` §Receiving policy).

**Approach:** Two new fields on the client policy row, edited beside the receiving policy in Settings → Clients:
- **Allocation rule** — `fefo` (earliest expiry first; batches with no expiry oldest-received first) or `fifo` (oldest-received first).
- **Minimum remaining shelf life at dispatch** — in IST calendar days; a batch with less left is never allocated to that client's orders.

One shared ranking and one shared allocatability predicate drive the wave planner, the short-pick re-plan and the pick-time batch re-derivation. Picklist lines **freeze** the rule and minimum they were planned under. ATP stops promising stock below the minimum (through 3-3a's unpromisable hook). The web wave detail and the handheld pick screen say which batch was chosen and why.

**Decisions (recommended, taken autonomously under the user's standing instruction, 2026-10-23):**
1. **Single goal; one adjacent goal deferred.** 4-3a ships the client-level rule. **4-3b** (deferred-work) covers customer-specific shelf life (a consignee or order demanding more than the client minimum) and a percentage-of-total-shelf-life form. A per-customer rule cannot be expressed by ATP, which is per (warehouse, SKU).
2. **Fields on `clients`** (migration, below): `allocation_rule` (`fefo|fifo`, NOT NULL, default `fefo`) and `min_outbound_shelf_life_days` (NULL or 1–3650). **No pairing with `expiry_required`.** The minimum limits dated batches only, and a batch with no expiry is never limited by it. This matches the draw side's existing rule that a null expiry never expires (`replan.ts:91-99`). The web panel says so and suggests turning on "Expiry required".
3. **Default `fefo` for every client, existing ones included.** This is a deliberate behaviour change at deploy. Batch-tracked SKUs move from "bin code first, FEFO inside the bin" to **warehouse-wide FEFO**, and undated batches move to oldest-received first. This is what the product already claims ("FEFO picking", the initiative's line 11; `outbound.md` calls it FEFO). The release note says so. Untracked SKUs do not change.
4. **The ranking** (`rankSlots`, one pure function shared by all three users). The units are per-bin slots, after the per-bin budget (unchanged, `replan.ts:142-160`):
   - **`fefo`:** dated batch slots by expiry ascending → then undated batch slots by batch receipt (`batches.created_at`) ascending → then batch-less (uncovered) slots. Ties go to bin walk rank, then batch id.
   - **`fifo`:** batch slots by receipt ascending → then batch-less slots. Ties go to walk rank, then batch id.
   - **Receipt** means `batches.created_at`: when the lot first appeared in the tenant. This is the 6.2 aging anchor (`catalog.facade.ts:761-770`). It is tenant-wide, so a transferred lot keeps its original age.
   - **Untracked SKUs** (no batch rows) rank by walk order exactly as today. FIFO is unknowable without lot identity (PENDING).
   - **The walk is unchanged.** `sortWalk` still orders picklist stops by bin code. The rule decides *which* stock is drawn; the walk decides the order the stops are visited.
5. **Allocatable** (`isBatchAllocatableAt(batch, atMs, minDays)`, in `src/shared/primitives/batch-allocation.ts`). A batch is allocatable when **all** of these hold:
   - its status is `active`;
   - it is not expired by 3-3a's `isBatchExpiredAt(expiry, at)`;
   - either `minDays` is null, or its expiry is null, or `istDaysBetween(istDateOf(at), istDateOf(expiry)) ≥ minDays`.

   `istDaysBetween` moves from `receiving.command.ts:3255` to `shared/primitives/time.ts`, and receiving imports it (it does not throw, so no wrapper is needed). With a minimum of 90 and an expiry of 31 Mar, the batch is allocatable through 1 Jan (IST) and refused from 2 Jan.
6. **When it is judged.**
   - The wave plan judges at the wave clock (`WAVE_CLOCK`).
   - The re-plan and the pick draw judge at the op's `occurredAt` (the existing expiry precedent, `pick.command.ts:1548`).
   - ATP judges at its injectable clock (3-3a A3).
   - The rule is "remaining life on the day it is picked"; dispatch is the same or the next day (PENDING: a dispatch-date judgement).
7. **Picklist lines freeze what they print.** `picklist_lines` gains `allocation_rule` and `min_outbound_shelf_life_days`, both nullable.
   - `generateWave` stamps the SKU's client's values on every slice. `unfulfillable` slices carry them too.
   - The re-plan copies the short line's values onto the new slices and plans with them.
   - `recordPick` re-derives the in-bin batch arms with the **line's** values, not the live policy.
   - A pre-4-3a line (both null) derives as `fefo` with no minimum, which is exactly today's in-bin FEFO draw.
   - **A policy edit applies to waves generated after it.** To apply it to an open planned wave, cancel and regenerate it (the web panel says so).
8. **ATP: stock below the minimum is unpromisable.** 3-3a's `unpromisableBatchUnits` hook uses `!isBatchAllocatableAt(…, sku's client's minimum)` in place of its expiry-only test. Then order create, channel publish, replenishment and the pick regrant stop promising units that can never be allocated.
   - The client minimum is read lazily, only when the hook found a dated active batch row. The SKU's `client_id` comes from `skus` (inventory already reads it, `inventory.facade.ts:5`), and the minimum from `allocationPoliciesInTx` (clients facade, new).
   - The allocation *rule* never affects ATP.
   - **Prerequisite:** 3-3a's backend has merged (it ships `isBatchExpiredAt` and the hook). 4-3a's backend branch is cut from a `main` that has it.
9. **Granted reservations are not re-planned** when a minimum is raised. This is 3-3a decision 8's posture: ATP clamps at 0, and such a line plans `unfulfillable` at the wave or shorts at the pick (PENDING).
10. **API.** One write: `PUT /tenants/{t}/clients/{clientId}/allocation-policy` `{allocationRule, minOutboundShelfLifeDays}`.
    - **Shape.** A full replace, `clients.manage`, the `updateReceivingPolicy` skeleton (`clients.command.ts:695-748`). The hash is `{arm: 'allocation-policy', tenantId, clientId, allocationRule, minOutboundShelfLifeDays}`.
    - **Unchanged** is a no-op that stores the key (`clients.allocationPolicy:unchanged`).
    - **Audit:** `client.allocation_policy_updated`, target the client.
    - **Allowed** on the self client and on a departed one.
    - **No GET route.** `ClientDto.allocationPolicy` (OPTIONAL: a stored `ClientMutationSnapshot` predates it) carries the two fields on every fresh client read.
    - **The receiving PUT, its hash and its DTO are byte-identical.**
11. **Handheld.**
    - **The task.** `PickTask` (and `PickTaskDto`) gain four optional, nullable keys: `batchExpiryDate` (IST date), `batchReceivedOn` (IST date), `allocationRule` and `minOutboundShelfLifeDays` (the line's frozen values). An older server omits them, and the device then shows today's text.
    - **The display.** The pick header and task card read e.g. "batch L1 · exp 31 Mar 2027 · earliest expiry first · needs ≥ 90 days", or "batch L7 · received 03 Jan 2026 · oldest first".
    - **No device-side decision.** The server re-derives the batch.
12. **Web.**
    - **Settings → Clients** gets an "Outbound allocation" panel (a new `panel.kind`, beside Receiving policy). It holds a rule radio with one-line explanations, an optional minimum (days), and notes for:
      - untracked SKUs, with the count from the existing receiving-policy read;
      - undated batches;
      - "applies to waves generated after saving";
      - a **warning** when the outbound minimum exceeds the receiving minimum: goods may be accepted that can never ship.
    - **The wave detail's picklist rows** show the batch code, its expiry and the frozen rule as text. `PicklistLineDto` gains optional nullable `batchCode`, `batchExpiryDate`, `batchReceivedOn`, `allocationRule` and `minOutboundShelfLifeDays`: it is part of the stored `WaveSnapshot`.
13. **The pick refusal names the minimum.** Today a scanned bin whose only stock is below the line's minimum refuses as the existing `insufficient-on-hand` / `pick-bin-short`, with "holds N drawable unit(s)". The refusal stays the same. Its detail gains a suffix: "— M more are below client X's minimum remaining shelf life of D days." The code and the routing are unchanged.
14. **Composition with 4-2a** (open PR #221). 4-2a changes **which order line draws first** (urgency order of the lines `planSlices` consumes, `wave.command.ts:527`). 4-3a changes **which stock is first** in each SKU's pool. The two are orthogonal, and whichever merges second rebases:
    - the urgent order takes the earliest-expiry allocatable batch warehouse-wide;
    - a matrix row pins it once both are on `main`.
15. **Out of scope** (PENDING):
    - the portal view of the policy;
    - the stock-adjustment FEFO default draw, transfers and returns, which are not customer shipments;
    - re-plan on a policy change;
    - a short-life crossing between plan and pick, which refuses like an expiry crossing today rather than re-planning;
    - per-SKU rule overrides.

## Boundaries & Constraints

**Always:**
- **Migration** `drizzle/NNNN_client_allocation_policy.sql`, numbered **next free at code time**. Main is at 0088; open PRs take 0089 and 0090, and 3-3a and 4-2a take later ones. It follows IMPLEMENTATION-GUIDE §3:
  - **Fail-fast guard:** a `DO` block raises if `clients.allocation_rule` exists.
  - **`clients`:**
    - `ADD COLUMN allocation_rule text NOT NULL DEFAULT 'fefo'` (a constant default, so no rewrite; existing rows read `fefo`);
    - `ADD COLUMN min_outbound_shelf_life_days integer` (NULL; existing rows null);
    - `clients_allocation_rule_check CHECK (allocation_rule IN ('fefo','fifo'))`;
    - `clients_min_outbound_shelf_life_range CHECK (min_outbound_shelf_life_days IS NULL OR min_outbound_shelf_life_days BETWEEN 1 AND 3650)`.
    - Both are validated at once: `clients` has one row per brand, so the scan is trivial.
  - **`picklist_lines`** (large):
    - `ADD COLUMN allocation_rule text`;
    - `ADD COLUMN min_outbound_shelf_life_days integer` (both NULL, no default, metadata-only);
    - `picklist_lines_allocation_rule_check CHECK (allocation_rule IS NULL OR allocation_rule IN ('fefo','fifo')) NOT VALID`;
    - `picklist_lines_min_outbound_shelf_life_range CHECK (min_outbound_shelf_life_days IS NULL OR min_outbound_shelf_life_days BETWEEN 1 AND 3650) NOT VALID`.
    - Existing rows are null by construction. A later `VALIDATE` is recorded in PENDING (deploy).
  - **No backfill and no index.** Nothing named INDEX appears in any `DO` block.
  - **The post-migration probe** follows the 0088 model:
    - every existing client reads `fefo`/null;
    - refused: `'lifo'`, `0` and `3651` on each table, each refused by its named constraint;
    - accepted: `fifo`/`1`/`3650`, rolled back by a sentinel;
    - the `picklist_lines` arms run as a full valid row in the sentinel block.
  - Plus the journal entry and the snapshot; `db:generate` must be clean.
- **The vocabulary keeps its three mirrored layers.** `ALLOCATION_RULES = ['fefo','fifo']` lives in `clients.schema.ts`, along with `MIN_OUTBOUND_SHELF_LIFE_DAYS_MIN/MAX`. They are mirrored in the CHECKs and `@IsIn` / `@ApiProperty({enum})`, and an e2e test pins the tuple against both CHECKs.
- **The command re-checks every value** behind the replay lookup (400 `validation-failed` naming the field).
- **Chunk the `picklist_lines` insert** in `generateWave` (`wave.command.ts:621`, currently one unchunked statement) into ≤ 1,000-row statements in the same transaction. Each chunk keeps the `OPEN_ORDER_LINE_UNIQUE` → `WaveClaimLostError` mapping. Adding two columns lowers the 65,535-parameter ceiling (§3), and a 500-order batch wave can already approach it.
- **One ranking and one predicate.** `buildStockPool` (wave + re-plan) and `deriveBatchArms` (pick) both call `rankSlots` / `isBatchAllocatableAt`. No inline copy survives (grep pin in `test/architecture.spec.ts`: no `expiryDate) >=` outside the shared primitive).
- **The pool callers read batch facts** through `CatalogFacade.getBatchIntakesForSkusInTx` (`catalog.facade.ts:771`, which already carries `createdAt`), replacing `getBatchesForSkusInTx` at `wave.command.ts:1250`, `replan.ts:254` and `pick.command.ts:1545`. The policy is read through `allocationPoliciesInTx(tx, tenant, clientIds)` (`clients.facade.ts`, the `receivingPoliciesInTx` shape, `:469`; unlocked; an absent id → `DEFAULT_ALLOCATION_POLICY = {fefo, null}`) over `CatalogFacade.skuClientIdsInTx` (`:518`).

**Never:**
- No change to the walk order, the per-bin budget, reservations, the ledger, or any idempotency hash other than the new PUT's.
- No change to the receiving policy's route, hash, DTO or rules.
- No customer-level or percentage shelf life (4-3b), and no portal surface.
- No automatic re-plan or cancel of granted reservations.
- Never judge allocatability against the replay instant (business time only).

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|---|---|---|---|
| FEFO across bins | `fefo`; `A-01` holds L2 (exp +200d, 10); `B-01` holds L1 (exp +30d, 10); order 5 | slice `B-01`/L1 (today: `A-01`/L2) | — |
| FEFO, undated | `fefo`; two undated batches; the older-received one sits in `B-01` | `B-01` first | — |
| FIFO | `fifo`; `A-01` L-new (received today, exp +30d); `B-01` L-old (received −60d, exp +300d) | `B-01`/L-old | — |
| Spans batches | `fefo`; need 15 across L1 (10, `B-01`), L2 (10, `A-01`) | slices L1 10 + L2 5; walk visits `A-01` then `B-01` | — |
| Minimum | min 90; L1 exp +60d (10); L2 exp +200d (10); order 5 | L2; ATP reads 10 (an order for 15 backorders 5 per the ATP policy) | — |
| Minimum boundary | min 90; at IST date E−90 / E−89 | allocatable / not (plan, pick and ATP agree) | — |
| Undated under a minimum | min 90; batch with null expiry | allocatable, ranked per rule | — |
| Untracked SKU | either rule | walk order, unchanged; line frozen with the client's values | — |
| Pick in bin | line frozen `fefo`/min 90; scanned bin holds L1 (60d) + L2 (200d) | draws L2 | — |
| Pick, only short-life | scanned bin holds only L1 (60d), epoch unmoved / moved | 422 `insufficient-on-hand` / 409 `pick-bin-short`, detail names the minimum | nothing recorded |
| Policy edited mid-wave | wave planned `fefo`; then set `fifo`/min 90 | open lines draw with frozen `fefo`/null; the next wave uses `fifo`/90 | — |
| Legacy line | pre-4-3a line (nulls) | in-bin FEFO, no minimum — today's draw | — |
| Re-plan | short pick on a frozen `fifo`/90 line | new slices ranked `fifo`, short-life excluded, columns copied | — |
| Policy PUT | `{allocationRule:'fifo', minOutboundShelfLifeDays: 90}` by owner | 200 `{client}` with `allocationPolicy`; audited | — |
| Unchanged PUT | same values | 200, key stored, no audit | — |
| Bad PUT | `'lifo'`, `0`, `3651`, `1.5`, missing field | — | 400 `validation-failed` naming the field |
| Authority / scope | ops_manager; unknown client; same key with another body | — | 403 `role-denied`; 404; 422 `idempotency-key-reuse` |
| Handheld | task on a frozen `fefo`/90 line, batch L1 | "batch L1 · exp 31 Mar 2027 · earliest expiry first · needs ≥ 90 days" | an older server: today's text |

</frozen-after-approval>

## Design Review Amendments

The design review (2026-10-23) ran a claims check (K1–K17, against origin/main `9a246e7`) and a blind review (B1–B18). Every finding was accepted; the triage is in the Review Triage Log. The amendments are recommended and were taken autonomously.

**Where they bind.** They bind over the frozen block. Where one says "supersedes decision N", that decision reads as amended. The frozen Boundaries and Matrix stand as written; **Amended Boundaries** and **Amended matrix rows** at the end of this section win where they differ.

### Ranking, drawing and the walk

**A1 — Re-planned stops keep walk order** (K1).
- **The defect.** `insertReplanSlices` (`pick.command.ts:1457-1520`) assigns `walkSeq` in candidate order. Candidates now arrive in **rank** order, not bin order, so a re-plan across `B-01` (earlier expiry) and `A-01` would walk `B-01` first.
- **The fix.** Sort the candidates by `(binCode, binId, rank index)` before `walkSeq` is assigned. `sliceSeq` follows the same sorted order.

**A2 — The pick draws the slice's named batch first** (B2; supersedes decision 7's "re-derives … with the line's values" in part).
- `deriveBatchArms` takes the line's `batchId` first, when that batch is in the scanned bin and allocatable at the judgement date (A3).
- Only for what that batch cannot cover, or when it is not allocatable, does it fall back to `rankSlots` over the bin's other allocatable batches.
- So the batch the handheld named is the batch drawn, even when the bin has since received an earlier-expiry lot. The plan already made the rotation decision; the pick does not re-make it mid-walk.
- A line with no named batch (an untracked SKU, or a batch-less slot) ranks the bin as before.

**A3 — The minimum is judged with a one-day grace** (B5; supersedes decision 6 for the pick and the re-plan; tightened at triage).
- At pick and re-plan, the **minimum** is judged on `judgementDate = max(planIstDate, addIsoDays(pickIstDate, −1))`, where:
  - `planIstDate = istDateOf(picklists.created_at)`, the IST date the line's wave was planned. There is no new column: the line read at `pick.command.ts:488-503` already joins `picklists`, and it adds `picklists.createdAt` to its select;
  - `pickIstDate = istDateOf(occurredAt)`.
- **Expiry itself** is still judged at the op's `occurredAt`. An expired batch is never drawn.
- **What it absorbs.** A wave planned at 23:50 and picked at 00:10 is judged on the plan date, so it does not lose a day.
- **What it caps.** A wave planned on Monday and picked on Thursday is judged on Wednesday. A batch with exactly the minimum on Monday is refused at the pick. The minimum is a promise to the customer, so the slip is at most one day: the one-day grace.
- **The wave plan** still judges at `WAVE_CLOCK`, and ATP at its own clock.

**A4 — What changes at deploy, from the code** (K8, B3; extends decision 3).
- **Today's order** (`replan.ts:80-160`):
  - bins in code order;
  - inside a bin, drawable batches by expiry ascending, nulls last, ties by batch id (`:131-140`);
  - then that bin's batch-less ("uncovered") slot (`:157-159`);
  - then the next bin.
- **Under `fefo` (the default), three things change:**
  1. ordering is warehouse-wide, not per bin;
  2. batch-less slots of a batch-tracked SKU move to the end of the SKU's pool (today they follow their own bin's batches);
  3. undated batches tie-break on `batches.created_at`, not batch id.
- **A legacy line** (`allocation_rule IS NULL`) draws today's draw at pick, except for the undated tie-break (change 3). `deriveBatchArms` never handles batch-less units, so change 2 does not reach it.
- **A re-plan of a legacy line** stamps the client's **current** policy on its new slices (supersedes decision 7's "copies the short line's values" for legacy lines only). They are new slices, planned now. A re-plan of a stamped line copies its values, as decision 7 says.

**A5 — FIFO anchors on "lot first received"** (K15, B7).
- `batches.created_at` is when the lot first appeared in the tenant: a lot received again later keeps its first date. The handheld and web label read **"lot first received DD Mon YYYY"**, never "received".
- PENDING:
  - receipt-level FIFO (per-receipt layers);
  - the adjustment route's batch creation: `inventory.controller.ts:497` calls `catalogFacade.ensureBatches` in its own transaction, before the adjustment command, so a refused adjustment can still create a lot and date it;
  - ties among an opening balance seeded at one instant, which break on walk rank and then batch id.

**A6 — One ranking, pinned by imports** (K12, B15; replaces the frozen Boundaries' grep pin).
- `test/architecture.spec.ts` asserts that `replan.ts` and `pick.command.ts` import `rankSlots` and `isBatchAllocatableAt` from `shared/primitives/batch-allocation`.
- It also asserts that neither file contains its own sort over `expiryDate` or `createdAt`, and no `Date.parse(…expiryDate…)` comparison.

**A7 — The picklist-line insert chunks by the real arithmetic** (K14, B17; restates the frozen Boundaries' chunk line).
- **Today's bound.** `generateWave` binds **16** columns per row (`wave.command.ts:600-618`): `id, tenantId, picklistId, waveId, orderId, orderLineId, skuId, binId, binCode, batchId, reservationId, qty, shortfallQty, sliceSeq, walkSeq, status`. One statement fits 4,095 rows. With the two new columns it is 18, so 3,640 rows.
- **Why it matters.** The order cap does not bound the row count. `policy.maxOrders ?? DEFAULT_WAVE_MAX_ORDERS` (`:1092`; 200, at most 500) bounds orders, but lines per order and slices per line are unbounded.
- **The chunk size** is `Math.floor(65_535 / columnCount)`, with `columnCount` taken from the row object's keys. A unit test pins it at 3,640.
- **The proof.** A test makes chunk 2 fail. Its `OPEN_ORDER_LINE_UNIQUE` violation must still become `WaveClaimLostError`, and no lines may persist: the whole transaction rolls back.

**A8 — Where the policy applies** (B8, verified on origin/main).
- Only `wave.command.ts` and `pick.command.ts` insert `picklist_lines`. Transfers (movements) and returns plan no picklist lines, so they are unaffected.
- The rule and the minimum apply to every **customer order** that reaches a wave: manual, portal and channel-ingested, and kit components (a kit reserves through its component lines).

**A9 — Item types** (B9). One line each:
- **Kits:** planned through component lines; each component's SKU client supplies the policy.
- **Serial-only SKUs:** no batch rows, so walk order as today. A batch-and-serial SKU is still refused at pick (`pick.command.ts:796`).
- **Catch-weight / fractional:** quantities are milli-units through the pool, so a fractional need spans batches like any other. Catch-weight draws whole units (`:803-809`), which is unchanged.
- **QC-held:** the stock sits in the system QC-HOLD bin, which `pickableBinsInTx` excludes, so an earliest-expiry batch on hold is skipped.
- **Blocked batches** (3-3a): not allocatable.
- **Blocked bins:** excluded by the bin filter (`replan.ts:171-188`). 3-3b's location reasons compose there and through the per-bin budget, with no ranking change.

**A10 — The policy is read once per plan and once per ATP read** (B10).
- `planSlices` reads every distinct client's policy in **one** `allocationPoliciesInTx` call at its start and passes the map down.
- The ATP hook reads the SKU's minimum once per `atp()` / `committedCeiling` evaluation.
- A test spies on `allocationPoliciesInTx` and asserts one call for a wave spanning two clients' SKUs, and that every line of that wave carries the values from that one read.

### The policy write and its read

**A11 — Both PUT keys are required** (K3; refines decision 10).
- `allocationRule` and `minOutboundShelfLifeDays` are both required. `null` is the explicit "no minimum", and a **missing** key is 400. The DTO uses the receiving precedent `@ValidateIf((_, v) => v !== null) @IsInt()` (`clients.dto.ts:417-420`), which refuses `undefined`.
- The hash is over the raw body values: no `?? null`.
- **Departed and self clients are allowed.** This follows the receiving PUT: `lockClientForEdit` (`clients.command.ts:1006-1025`) checks no status, because a policy is not work. Matrix row: the self client behaves like any other.

**A12 — A read for the panel: `GET …/clients/{clientId}/allocation-policy`** (B13; supersedes decision 10's "No GET route").
- **Who:** any staff session, never the portal.
- **Body:** `{clientId, allocationRule, minOutboundShelfLifeDays, untrackedSkuCount, undatedBatchesOnHand}`.
  - `untrackedSkuCount` comes from `CatalogFacade.countUntrackedSkus` (the receiving read's composition).
  - `undatedBatchesOnHand` comes from a new `InventoryFacade.undatedBatchesOnHandOfClientInTx`: distinct active batches with null expiry and positive `batch_on_hand`, of the client's SKUs, across warehouses. It uses the same read-only `batches` allowance 3-3a adds for its hook.
- **The panel** shows a prominent **warning, not a block**, when a minimum is set, `expiryRequired` is false and `undatedBatchesOnHand > 0`: "N batches on hand have no expiry date — the minimum cannot limit them."
- `ClientDto.allocationPolicy` stays.

**A13 — The panel states both halves of a save** (K5, B12).
- "Promises change now: stock below the minimum stops being promised to new orders and channels. Open planned waves keep the rule they were planned under — cancel and regenerate one to apply the change."
- When the outbound minimum exceeds the receiving minimum, the warning adds: "stock received below it stays on hand and is never shipped."
- Release-note line (A20). PENDING: an "on hand below a client's outbound minimum" view.

**A14 — The receiving PUT, restated** (K16). Its route, request DTO and hash are unchanged. Its `ClientDto` response gains the optional `allocationPolicy`, like every client read.

### ATP and refusals

**A15 — The 3-3a strings name the minimum** (K4). Where 3-3a writes "blocked/expired", the text reads **"blocked, expired or below the client's minimum remaining shelf life"**:
- the 409 grant-refusal detail ("of which N in …");
- `bufferOverCeiling`;
- the `unpromisableBatch` field descriptions on `AtpSnapshot` and `ChannelVisibleSnapshot`;
- the `inventory.md` formula text.

The 409 detail is pinned in `test/allocation-rules.spec.ts`.

**A16 — The pick refusal suffix** (K13; refines decision 13).
- **Signature.** `binCannotCover(epochMoved, binCode, drawable, requested, shelfLife?: {excludedMilli, minDays, clientLabel})`. `insufficientOnHand` and `pickBinShort` take the same optional argument.
- **The label** comes from `getClientLabelsInTx`, read only on the refusal path, so a successful pick pays nothing.
- **Code, status and routing** are unchanged.
- **PENDING.** A shelf-life shortfall in a bin whose epoch moved is a 409 `pick-bin-short`, which the device keeps and retries. It can never succeed, which is the same as an expiry shortfall today.

### Device

**A17 — The mobile type and the replay fate** (K11, B5, B11).
- The device type is **`CatalogPickTask`** (`wms-mobile/src/api.ts:1689`), not `PickTask`.
- **A shelf-life refusal of a queued offline pick** lands where an expiry shortfall lands today:
  - `insufficient-on-hand` (422) is classified **rejected**: shown as a retraction in the sync summary;
  - `pick-bin-short` (409) is **re-plannable**: kept and retried.
  - The classifier is `src/state/replay-classification.ts`, which branches on the code. No device change.
- **Tasks refresh** after a server re-plan on the device's next catalog snapshot refresh: the new slices are new pick tasks (`app/pick.tsx:61-66`). No new mechanism.

### Migration

**A18 — Migration additions** (K7, B4, B16; extends the frozen Boundaries' migration).
- **A pairing CHECK.** `picklist_lines_allocation_pairing CHECK (allocation_rule IS NOT NULL OR min_outbound_shelf_life_days IS NULL) NOT VALID`. A line is legacy exactly when `allocation_rule IS NULL`.
- **The probe** asserts `pg_constraint.convalidated = false` for the three `picklist_lines` CHECKs. It probes the pairing CHECK with a refused shape (`null` rule with a minimum) and an accepted one.
- **The tuple ↔ CHECK pins** compare against `pg_get_constraintdef` with a trailing ` NOT VALID` tolerated.
- **Locks.**
  - Each `ALTER TABLE` waits at most `MIGRATE_LOCK_TIMEOUT_MS`, which is 5 s (`DEFAULT_LOCK_TIMEOUT_MS = 5_000`, `migrate-deploy.ts:68`; `DEPLOY.md` §2). While one waits, later traffic on `picklist_lines` queues behind it.
  - On a timeout, the migrator's one transaction rolls back whole. The remedy is to **re-run the deploy**, at a quieter moment if it recurs.
  - Found in passing: the header comment at `migrate-deploy.ts:48-50` says "default 15 s" and is stale. Recorded in PENDING (deploy).
- **Rolling deploy.** An old api task that picks a new `fifo` line ignores the columns and draws in-bin FEFO. This is accepted: the window is one deploy, and the draw is still rotation-safe.

### Payloads, snapshots, composition and docs

**A19 — Snapshot plumbing and payload growth** (K9, K10).
- **Plumbing.** `snapshotOf` (`wave.command.ts:1432`) reads `batchFacts: ReadonlyMap<string, BatchFacts>` once through `catalog.batchFactsByIdsInTx` and passes it to `picklistSnapshot(row, lines, batchFacts)`, which passes it to `lineSnapshot(row, batchFacts)`.
- **Rebase with 4-2a.** 4-2a's A1 threads urgency through the same two functions. Whichever merges second rebases them.
- **Payload growth.** `wave.generated`, `wave.released` and `wave.cancelled` carry the wave snapshot, so they grow by five keys per line. `push.enqueue.ts:168-171` reads only `payload.wave.warehouseId`, so it ignores unknown keys.

**A20 — The release note** (B6, K5, K8).
- **Where and for whom.** `docs/releases/4-3a-allocation-rules.md`, for ops leads and client success. It is written in the meta docs PR, after the code merges: the "meta repo last" rule.
- **It says:**
  - the three deploy-time changes (A4);
  - promises dropping when a minimum is set (A13);
  - the rollback lever: setting a client to `fifo` does **not** restore bin-first. There is no `bin_order` arm, by decision.
- **The pre-deploy query.** Per client, the SKUs whose dated batches span more than one storage bin in a warehouse:
  ```sql
  select c.code as client, s.code as sku, w.code as warehouse,
         count(distinct boh.bin_id) as bins, count(distinct boh.batch_id) as batches
  from batch_on_hand boh
  join batches b on b.id = boh.batch_id and b.tenant_id = boh.tenant_id
  join skus s on s.id = boh.sku_id
  join clients c on c.id = s.client_id
  join bins bn on bn.id = boh.bin_id and bn.system_owned = false
  join warehouses w on w.id = boh.warehouse_id
  where boh.quantity > 0 and b.expiry_date is not null and boh.tenant_id = $1
  group by c.code, s.code, w.code
  having count(distinct boh.bin_id) > 1
  order by 1, 2, 3;
  ```

**A21 — `istDaysBetween` has one home** (K6).
- It moves to `shared/primitives/time.ts`.
- `receiving.command.ts:3255` re-exports it, because `test/client-receiving-policy.spec.ts:8-18` imports it from there.
- `invoicing/eway-json.ts:226` imports it and re-exports its name; it does not throw, so no wrapper is needed.
- `reporting/registers.ts:99`'s local function, which takes **instants**, is renamed `istDaysBetweenInstants`, so no two functions share the name with different argument types.

**A22 — Decision 5's example, corrected** (K2, B1). With a minimum of 90 and an expiry of **31 Mar 2027**, the batch is allocatable through **31 Dec 2026** and refused from **1 Jan 2027** (Jan 31 + Feb 28 + Mar 31 = 90 days). In a leap year (31 Mar 2028) the boundary moves one day, to 1 Jan 2028 and 2 Jan 2028. Fixtures cover both years.

**A23 — The 4-2a composition row has an owner** (K17; refines decision 14).
- **Who writes it.** Whichever of 4-2a and 4-3a merges **second** adds the row, as a task in its own spec, with this fixture:
  - an urgent and a normal order for the same SKU;
  - the earlier-expiry batch sits in the later bin;
  - the urgent order's slice takes it.
- **Also on that spec.** It rewords 4-2a's matrix row "two orders contend for one bin's first-FEFO batch" to "the warehouse-wide first-ranked batch".

**A24 — Docs named, initiative row updated** (K16, B15).
- The meta docs PR updates:
  - `docs/design/modules/clients.md`, `outbound.md` and `inventory.md`;
  - `docs/design/API-SURFACE.md`;
  - `docs/design/frontend/SYSTEM-DESIGN.md` and `docs/design/mobile/SYSTEM-DESIGN.md`;
  - `docs/repos/wms-be/README.md` and `docs/repos/wms-fe/README.md`;
  - `docs/design/PENDING.md`;
  - the release note (A20);
  - row 4.3 of `docs/initiatives/production-readiness.md`: shipped as 4-3a, with customer-specific and percentage rules in 4-3b.

### Amended Boundaries

- **Migration:** the frozen list, plus A18's pairing CHECK, the `convalidated` probe, the lock note and the rolling-deploy note.
- **The insert:** chunked per A7, not "≤ 1,000-row statements".
- **The pin:** A6's import-boundary pin replaces the grep pin.
- **The PUT** requires both keys (A11). A GET exists (A12).
- **The pick draw:** the named batch first (A2). The minimum is judged on `max(plan date, pick date − 1)` (A3).

### Amended matrix rows

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|---|---|---|---|
| Re-plan walk order | re-plan finds L1 in `B-01` (earlier expiry) and L2 in `A-01` | new slices L1 + L2; `walkSeq` puts `A-01` before `B-01` | — |
| Named batch first | slice names L1 in `A-01`; `A-01` has since received L0 (earlier expiry) | the pick draws L1 | — |
| Midnight grace | min 90; wave planned 23:50 IST on D, where D is the last allocatable day; picked 00:10 on D+1 | allocatable: judged on D = max(D, D+1−1) | — |
| Grace capped | min 90; planned Monday with exactly 90 days left; picked Thursday | refused at the pick, judged on Wednesday (88 days left) | 422 `insufficient-on-hand` / 409 `pick-bin-short`, with the A16 suffix |
| Expiry still at the op | the same wave; the batch expires at 00:00 on D+1 | not drawn | 422/409 as an expiry today |
| Leap year | min 90, exp 31 Mar 2027 / 31 Mar 2028 | allocatable through 31 Dec 2026 / 1 Jan 2028 | — |
| Raise the minimum | min set from null to 90 with only 60-day stock | the next order backorders per the ATP policy; the channel quantity drops on the next sync | — |
| Legacy line re-plan | short pick on a pre-4-3a line; client now `fifo`/90 | new slices stamped `fifo`/90 and ranked so | — |
| Re-received lot | lot L first received −100d, received again today; `fifo` | L ranks at −100d | — |
| PUT missing key | `{allocationRule:'fefo'}` | — | 400 `validation-failed` naming `minOutboundShelfLifeDays` |
| Self client | PUT on the self client | 200, like any other client | — |
| Undated warning | min 90, `expiryRequired` false, 3 undated batches on hand | GET reads `undatedBatchesOnHand: 3`; the panel warns, and the save is allowed | — |
| Order types | portal and channel-ingested orders of the client | planned with the rule and the minimum | — |
| Transfer / return | a transfer order and a return receipt | unaffected (no picklist lines) | — |
| Fractional across batches | `kg` SKU, need 2.5 over L1 1.2 + L2 5 | slices 1.2 L1 + 1.3 L2 (`fefo`) | — |
| QC-held | the earliest-expiry batch is on a QC hold | skipped; the next allocatable batch is used | — |
| Chunk 2 fails | a wave whose lines exceed one chunk; a claim collides in chunk 2 | — | 409 via `WaveClaimLostError`; no lines persisted |
| One policy read | a wave over two clients' SKUs | one `allocationPoliciesInTx` call; every line carries its read | — |

## Code Map

### Backend (`workspace/core/backend/wms-be`, read on origin/main `9a246e7`; branch cut after 3-3a's backend merges)

**Policy (clients)**
- `src/shared/db/schema.ts`:
  - `:302` `clients` (the 1-2b columns at `:368-379`): add the two columns;
  - `:3242` `picklistLines`: add the two frozen columns. The CHECKs live in the migration only (§3).
- `drizzle/NNNN_client_allocation_policy.sql` + the journal + the snapshot: the frozen list plus A18.
- `src/modules/clients/clients.schema.ts`: `ALLOCATION_RULES` and the day bounds.
- `clients.facade.ts`:
  - `ClientAllocationPolicy`, `DEFAULT_ALLOCATION_POLICY`, `allocationPolicyOf`;
  - `allocationPoliciesInTx`, the `receivingPoliciesInTx` shape (`:469-490`);
  - `toClientSnapshot` (`:153`) gains `allocationPolicy`.
- `clients.command.ts`:
  - `updateAllocationPolicy`: the `updateReceivingPolicy` skeleton (`:695-748`), with `lockClientForEdit` (`:1006-1025`, no status check, A11);
  - `assertAllocationPolicy`, beside `assertReceivingPolicy` (`:1302`).
- `src/api/clients.controller.ts:307-370`: the GET (A12) and the PUT, beside the receiving pair. The GET composes `CatalogFacade.countUntrackedSkus` and `InventoryFacade.undatedBatchesOnHandOfClientInTx`.
- `src/api/clients.dto.ts`:
  - `ClientAllocationPolicyDto` and `ClientAllocationPolicyResponse`;
  - `UpdateClientAllocationPolicyDto`, both keys required (the `:399-421` precedent);
  - `ClientDto` (`:438`) gains an optional `allocationPolicy` (the `:487` precedent).
- `test/support/audit-guard.ts:85`: `clients.allocationPolicy:unchanged`. `client.allocation_policy_updated` goes in `AUDIT_NEW_ACTIONS`.

**Allocation (shared + outbound)**
- `src/shared/primitives/time.ts`: `istDaysBetween`, moved (A21), with its re-exports and the `registers.ts` rename.
- `src/shared/primitives/batch-allocation.ts` (new): `rankSlots`, `isBatchAllocatableAt(batch, opAtMs, minDays, minJudgedOn?)`, and `minimumJudgementDate(planIstDate, pickIstDate)` = `max(plan, pick − 1 day)`. The minimum is judged on `minJudgedOn` (an IST date) when it is given, else on the op's own date (A3). Also the `AllocationRule` type.
- `src/modules/outbound/replan.ts`:
  - `PoolBatchIdentity` (`:43-47`) gains `createdAt`;
  - `StockPoolInput` (`:49-74`) gains `policyOf(skuId)` and an optional `minJudgedOn`;
  - `buildStockPool` (`:80-160`) keeps the per-bin budget (`:142-160`), replaces `drawableBatch` (`:91-99`) and the in-bin sort (`:131-140`) with the shared functions, and ranks each SKU's slots globally;
  - `findReplanSlices` (`:228`) takes `{allocationRule, minDays, minJudgedOn}` in `scope` and returns the slices in rank order with their rank index. The claim-spend loop (`:279-290`) is unchanged.
- `src/modules/outbound/wave.command.ts`:
  - `planSlices` (`:1229-1329`): one `skuClientIdsInTx` + one `allocationPoliciesInTx` read at the start (A10); stamp both values on every `PlannedSlice`; switch to `getBatchIntakesForSkusInTx` (`:1250`);
  - the line insert (`:600-630`): the new columns, chunked per A7, with the claim mapping per chunk;
  - `PicklistLineSnapshot` (`:199`), `snapshotOf` (`:1432`), `picklistSnapshot` (`:1493`) and `lineSnapshot` (`:1518`): the `batchFacts` thread (A19).
- `src/modules/outbound/pick.command.ts`:
  - the line read (`:488-503`) adds `picklists.createdAt`;
  - `deriveBatchArms` (`:1527-1585`): the named batch first, then `rankSlots` (A2); the minimum on `minimumJudgementDate(plan, pick)` and expiry at `occurredAt` (A3); it reports the units excluded for shelf life;
  - `binCannotCover` / `insufficientOnHand` / `pickBinShort` (`:1887`, `:2018`): the optional `shelfLife` argument and `getClientLabelsInTx` on the refusal path (A16);
  - the `findReplanSlices` call (`:1226`): the line's values, or the client's current ones for a legacy line (A4);
  - `insertReplanSlices` (`:1457-1520`): the A1 sort before `walkSeq`, and the stamped columns;
  - `getPickTasksInTx` (`:1642-1740`): the batch read (`:1691`) adds `expiry_date` and `created_at`, and the task gains the four keys;
  - `getBatchesForSkusInTx` (`:1545`) → `getBatchIntakesForSkusInTx`.
- `src/modules/outbound/outbound.dto.ts`: `PicklistLineDto` (`:618`) and `PickTaskDto` (`:1041`) gain the optional nullable keys. `ALLOCATION_RULES` is their enum, and the nullable ones list `null` (§4).

**ATP (inventory, on top of 3-3a)**
- `src/modules/inventory/reservation.service.ts`:
  - 3-3a's `unpromisableBatchUnits` uses `!isBatchAllocatableAt(…, minDays)`, with `minDays` read once per evaluation (A10) and lazily (`skus.client_id` → `allocationPoliciesInTx`);
  - the A15 strings and the formula docstring.
- `src/modules/inventory/inventory.facade.ts`: `undatedBatchesOnHandOfClientInTx` (A12), added to 3-3a's `batches` read allowance in `test/architecture.spec.ts`.

**Tests**
- **`test/allocation-rules.spec.ts` (new)** covers every frozen and amended matrix row through HTTP: wave generate, pick, and ATP via order create and the channel-visible figure. It also covers:
  - the CHECK and vocabulary pins (tolerating ` NOT VALID`) and the `convalidated` probe;
  - `expectAuditRow` and the no-op key;
  - a parked-waiter same-key race on the PUT (§1);
  - pre-4-3a stored `ClientMutationSnapshot` and `WaveSnapshot` replayed unchanged;
  - a legacy-line pick and a legacy-line re-plan;
  - the E−90 and E−89 boundaries in leap and non-leap years, with the clocks assigned (§7c);
  - the plan-date row;
  - the A15 409 detail and the A16 suffixes.
- **Unit tests** beside the primitives: `rankSlots`, `isBatchAllocatableAt`, the chunk-size arithmetic (A7) and `istDaysBetween`.
- **`test/architecture.spec.ts`:** the A6 import pin and the A12 allowance.
- **`test/waves.spec.ts:841`** still passes; it is a single bin. Any test asserting bin-first order across bins, batch-less-after-batches within a bin, or a batch-id tie-break between undated batches is **re-established** to the new rule with a comment saying why (§4), never silently retargeted.
- The OpenAPI is regenerated, with its path-list assertion gaining the GET and the PUT.

### Web (`workspace/core/frontend/wms-fe`)
- `src/components/settings/client-allocation-policy.tsx` (new). It is modelled on `client-receiving-policy.tsx` and mounted in `clients-card.tsx` (`:309-318`) as `panel.kind === 'allocation'`, with a row action next to "Receiving policy".
  - It reads the A12 GET and holds the rule radio and the minimum.
  - It carries the A13 copy and the A12 and A13 warnings.
  - The key is minted per draft and cleared on edit. `clients.manage` gates the save.
- `src/lib/allocation-policy.ts` (new): parse the draft (whole days 1–3650; blank sends `null` explicitly; the parse runs before a key is minted), the rule labels, the "lot first received" wording and the `allocationReason` mapper.
- `src/components/outbound/outbound-waves.tsx` `PicklistPanel` (`:1061-1110`): per row, the batch code, expiry (`formatIstDate`, `lib/rate-cards.ts:96`) and the rule text. An absent key renders nothing.
- Regenerate the client. Tests for the parser, the panel (both warnings and both halves of the copy) and the wave rows.

### Mobile (`workspace/core/mobile/wms-mobile`)
- `src/api.ts` `CatalogPickTask` (`:1689`): four optional keys.
- `src/picking/allocation-hint.ts` (new) + its test: one pure formatter (the A5 wording).
- `app/pick.tsx:490-493` (header) and `:817-820` (task card): append the hint.
- No change to `src/state/replay-classification.ts` (A17).

## Tasks & Acceptance

**Execution:**
- [ ] BE, on a `main` that has 3-3a's backend:
  - migration + schema (A18);
  - `istDaysBetween` move (A21) and the shared primitive;
  - clients command, GET/PUT, DTOs, facade;
  - pool, plan, re-plan and pick (A1–A4, A10);
  - the snapshot thread and the task keys;
  - the chunked insert (A7);
  - the ATP hook and its strings (A15);
  - the refusal suffix (A16);
  - tests; OpenAPI.
- [ ] Web: the panel with its GET, warnings and copy; the lib; the wave rows; the regenerated client; tests.
- [ ] Mobile: the `CatalogPickTask` keys, the hint, the two screens; tests.
- [ ] The 4-2a composition row (A23), **if 4-3a merges after 4-2a**.
- [ ] Meta docs PR, last: the A24 list, the release note (A20), and PENDING:
  - close the 1-2b item's "FEFO/FIFO … stay in 4.3";
  - add decision 15's items;
  - add A3's one-day grace as a documented rule (not a gap), A5's three FIFO items, A13's below-minimum view, A16's endless retry, the `picklist_lines` CHECK `VALIDATE`, and A18's stale comment.

**Acceptance Criteria:**
- **Backend.** Given a `fefo` client whose 30-day batch sits in a later bin than its 200-day batch, when a wave is generated through HTTP and the line is picked, then the slice names the 30-day batch and the pick draws it.
- **Mobile.** Given a `CatalogPickTask` with batch L1, expiry 2027-03-31, rule `fefo` and minimum 90, when the hint is formatted, then it reads "batch L1 · exp 31 Mar 2027 · earliest expiry first · needs ≥ 90 days". With the four keys absent, it reads exactly today's text.
- **FIFO.** Given a `fifo` client with a newer, sooner-expiring lot and an older lot, when a wave is generated, then the lot first received earlier is suggested.
- **Raised minimum.** Given a reservation granted before the minimum was raised to 90, with only 60-day stock left, when a wave plans, then that line is `unfulfillable`.
- **Boundary.** Given a minimum of 90, when the plan date is E−90 and then E−89, then the batch is allocated, then not, and ATP agrees on each date.
- **Grace.** Given a wave planned with exactly the minimum left, when it is picked three days later, then the pick refuses the batch. When it is picked at 00:10 the next day, the pick draws it.
- **Refusal text.** Given a scanned bin holding only stock below the line's minimum, when the pick is recorded, then the 422 (unmoved epoch) or 409 (moved epoch) detail names the excluded units, the client and the minimum.
- **Frozen lines.** Given a planned wave, when the owner changes the policy, then that wave's lines keep their frozen values and the next wave uses the new ones.

## Design Notes

- **Why warehouse-wide FEFO.** Putaway spreads a SKU across bins, so expiry loss happens across bins. The walk stays bin-ordered (and so does a re-plan's, A1), so a picker still visits each bin once. The cost is occasionally more bins per line, accepted for the clients the rule exists for. There is no `bin_order` arm: a 3PL that needs one asks for it explicitly (A20).
- **Why freeze, and why the named batch first.** A picklist is a document. Freezing the rule, judging the minimum with a one-day grace, `max(plan date, pick date − 1)` (A3) and drawing the named batch first (A2) make the plan, the handheld text and the draw agree. Only a batch that has since become unallocatable makes the pick re-rank.
- **Why the minimum fits ATP.** A SKU belongs to one client (AD-23), so a client minimum is a property of (batch, date), like expiry. A per-customer minimum is not, which is why it is 4-3b.
- **Composition.**
  - **3-3a:** `isBatchAllocatableAt` contains `isBatchExpiredAt`, so the hook change is one call plus the A15 strings.
  - **4-2a:** decides line order; 4-3a decides stock order. Each sees the other only through the shared snapshot functions (A19) and the A23 row.

## Verification

**Commands:**
- `cd workspace/core/backend/wms-be && bun run test -- test/allocation-rules.spec.ts test/waves.spec.ts test/picking.spec.ts test/client-receiving-policy.spec.ts test/architecture.spec.ts`: one jest run at a time; the targeted suites pass.
- Then, in the same repo:
  - the full `bun run test`;
  - `bun run lint && bun run typecheck && bun run build`;
  - `bun run db:migrate && bun run db:verify` against a freshly reset DB;
  - `bun run db:generate`, which must report "No schema changes";
  - `git status --short`, which must show no untracked files.
  - Expected: all pass.
- `cd workspace/core/frontend/wms-fe && bun run api:generate && bun run test && bun run lint && bun run typecheck && bun run build`. Expected: all pass.
- `cd workspace/core/mobile/wms-mobile && bun test && bun run typecheck`. Expected: all pass.

**Manual checks:**
- Mutation-check A1 (drop the sort) and A2 (drop the named-batch-first step): the matching matrix test must fail.

## Implementation Notes

## Spec Change Log

## Review Triage Log

Design review, 2026-10-23. Claims check K1–K17 against origin/main `9a246e7`; blind review B1–B18. All triaged by the coordinator's recommended decisions, taken autonomously. Every finding was accepted.

**Tightening at triage:** A3 was tightened from "judged at the plan date" to a one-day grace, `max(plan date, pick date − 1)`. The minimum is a promise to the customer, so a stale planned wave must not ship below it by more than the midnight crossing.

| ID | Verdict | Finding | Disposition |
|---|---|---|---|
| K1 | high | Re-planned slices took `walkSeq` in rank order, walking a later bin first | A1 |
| K2 | medium | Decision 5's example was off by a day for a non-leap year | A22 |
| K3 | medium | PUT key presence, `null` versus missing, and departed/self handling were unstated | A11 (receiving precedent verified: `lockClientForEdit` checks no status) |
| K4 | medium | 3-3a's refusal and field texts would say "blocked/expired" only | A15 |
| K5 | medium | The panel implied a save only affects future waves; promises change at once | A13, A20 |
| K6 | low | `istDaysBetween` has three copies (receiving, e-way, registers), and registers' takes instants | A21 |
| K7 | medium | NOT VALID enforcement unproven; lock-timeout remedy unstated; no rule/minimum pairing | A18 (the timeout is 5 s in code; the header comment's 15 s is stale) |
| K8 | high | Two further deploy-time order changes, and legacy-line re-plan stamping, unstated | A4 |
| K9 | low | Outbox payload growth unstated | A19 (`push.enqueue.ts:168-171` reads only `warehouseId`) |
| K10 | low | How batch facts reach `lineSnapshot` was unnamed; 4-2a edits the same functions | A19 |
| K11 | low | The mobile type is `CatalogPickTask` | A17 |
| K12 | medium | A grep pin is easy to evade | A6 |
| K13 | low | The suffix's label source and the signature change were unstated; a moved-epoch retry can never succeed | A16 |
| K14 | medium | The chunk arithmetic was not derived from the real column count | A7 (verified 16 bound columns; `maxOrders` null means the 200 default with a 500 maximum, so orders are bounded but rows are not) |
| K15 | medium | "Received" overstates `batches.created_at` | A5 |
| K16 | low | The initiative row was stale; "receiving PUT byte-identical" was overstated | A14, A24 |
| K17 | low | The 4-2a composition row had no owner | A23 |
| B1 | medium | The leap-year boundary moves (as K2) | A22 |
| B2 | high | Re-ranking at pick can draw a batch other than the one named | A2 |
| B3 | high | Deploy behaviour changes beyond cross-bin FEFO (as K8) | A4, A20 |
| B4 | medium | Rolling deploy: an old pod ignores the new columns | A18 |
| B5 | high | Judging the minimum at pick time loses a day across IST midnight; offline replay fate unstated | A3 (one-day grace: `max(plan date, pick date − 1)`), A17 |
| B6 | medium | No release note path, audience, query or rollback lever | A20 |
| B7 | medium | FIFO's anchor semantics (as K15) | A5 |
| B8 | medium | Which flows the policy applies to was unverified | A8 (only wave and pick insert `picklist_lines`) |
| B9 | medium | Kits, serial-only, catch-weight, QC-held and blocked behaviour unstated | A9 |
| B10 | medium | Policy reads per SKU could straddle a concurrent PUT | A10 |
| B11 | low | Device task refresh after a re-plan unstated | A17 (the next snapshot refresh, `app/pick.tsx:61-66`) |
| B12 | low | Stock below the minimum stays on hand with no view | A13, PENDING |
| B13 | medium | A minimum without `expiryRequired` silently limits nothing for undated stock | A12 (GET + warning; supersedes decision 10's "No GET") |
| B14 | medium | AC1 mixed layers; AC2 was untestable as written; missing ACs | Tasks & Acceptance rewritten |
| B15 | low | Doc paths not named; a grep pin (as K12) | A6, A24 |
| B16 | low | Tuple ↔ CHECK pins break on ` NOT VALID` | A18 |
| B17 | medium | Chunk failure atomicity untested | A7 |
| B18 | low | Example date (as K2) | A22 |
