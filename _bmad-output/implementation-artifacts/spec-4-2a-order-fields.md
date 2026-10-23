---
title: '4-2a order fields — order type (B2B/B2C), cash on delivery, priority and ship-by date, set at staff, portal and channel create, shown on every order surface and used by wave planning, pack and the carrier handover'
type: 'feature'
created: '2026-10-23'
baseline_commit: '2950e61efff2a8e07b2aed6901f6690e8160ab98'  # wms-be (feat/3-3a tip, stacked 5-1a→3-2b→2-8a→3-3a — 0089–0092); wms-fe: ce9f0ba890306f89bd0fdc2213100f825dcab449 (feat/3-3a tip); wms-mobile: 0221424dcf52edea6b07b978616c1c13d137a700 (feat/3-2b tip)
status: 'done'
route: 'dispatch'
review_loop_iteration: 0
context:
  - '_bmad-output/implementation-artifacts/epic-4-context.md'
  - 'docs/initiatives/production-readiness.md'
  - 'docs/design/SYSTEM-DESIGN.md'
  - 'docs/design/IMPLEMENTATION-GUIDE.md'
  - 'docs/design/modules/outbound.md'
  - 'docs/design/modules/channels.md'
  - 'docs/design/modules/carriers.md'
  - 'docs/design/modules/reporting.md'
  - 'docs/design/PENDING.md'
  - 'docs/design/API-SURFACE.md'
  - 'docs/design/frontend/SYSTEM-DESIGN.md'
  - 'docs/design/frontend/IMPLEMENTATION-GUIDE.md'
  - 'docs/design/mobile/SYSTEM-DESIGN.md'
  - 'docs/design/mobile/IMPLEMENTATION-GUIDE.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** An order has no type, no payment mode, no priority and no ship-by date (none exists anywhere on `orders` — `schema.ts:2903`). The warehouse therefore cannot tell a cash-on-delivery parcel from a prepaid one. A COD parcel booked as prepaid is cash the courier never collects. The floor also works strictly oldest first: `selectOrders` orders by `(created_at, id)`, `wave.command.ts:1099,1154`. An urgent order, or one due today, waits behind a week of routine work.

**Approach:**
- Add four order header fields: `orderType`, `codAmountPaise`, `priority` and `shipByDate`.
- They are captured at create:
  - on the staff create (`createOrder`, manual);
  - on the portal create (`placePortalOrder`);
  - on channel ingest, where the channel says so (Shopify COD).
- Every order surface shows them: web lists and detail, the portal, picklists, pack and dispatch, the handheld pick and pack screens, and the outbound register.
- They are used where they matter:
  - **Wave planning** orders its selection, its stock allocation and its picklists by urgency.
  - **The pack slip, dispatch, shipments and the manifest** carry the amount to collect.
  - **The carrier label and rate requests** carry the COD amount to the adapter.

**Decisions (recommended, taken autonomously under the user's standing instruction, 2026-10-23):**
1. **Split.** Roadmap 4.2's other goals are deferred (deferred-work): **4-2b** cancel/unpack a packed order and **4-2c** backorder follow-on.
2. **Vocabularies and shapes.**
   - **Order type.** `ORDER_TYPES = ['b2b','b2c']`.
   - **Priority.** `ORDER_PRIORITIES = ['normal','high','urgent']`, ranked urgent 0, high 1, normal 2 (`ORDER_PRIORITY_RANK`, with one SQL twin `orderPriorityRankSql`).
   - **Ship-by date.** `shipByDate` is an IST calendar date `YYYY-MM-DD` ("ship by the end of that IST day").
   - **COD amount.** `codAmountPaise` is an integer in paise, 1 to `MAX_COD_AMOUNT_PAISE = 1_000_000_000` (₹1 crore).
   - **COD means the amount is non-null.** There is no separate payment-mode column, so the two can never disagree. Null means prepaid: nothing to collect.
3. **Defaults; existing rows are not backfilled.**
   - **Order type.** When omitted, it is **derived** at create: `b2b` when a consignee GSTIN is given, else `b2c`. Every new order stores one. Orders created before 4-2a read `orderType: null`, and every surface shows "—".
   - **Priority.** When omitted, it is `normal`. That is the column default, so existing rows read `normal` too, which is true: they had none.
   - **Ship-by date and COD.** When omitted, they are null.
4. **The type and the GSTIN.**
   - An explicit `b2c` together with a consignee GSTIN is **400 `validation-failed`**: a GST-registered buyer is a business.
   - `b2b` without a GSTIN is allowed: an unregistered business buyer.
   - The type is operational only. Tax treatment stays GSTIN-driven (8-1), and invoicing and e-way bills are untouched.
5. **Ship-by bounds (manual orders only).**
   - On the staff and portal create, the date must fall from **today (IST) to today + 365 days**. Otherwise it is 400.
   - The check runs **behind the replay lookup**, against the one IST date the create already captures (`licenceToday()`, `order.command.ts:436,633`). A replay tomorrow of today's order replays; it is not refused.
   - An ingested order's date is not bounded: a channel order may already be late.
6. **Who sets what.**
   - Staff and portal set all four. The portal may set `priority`: the client knows which of its orders are urgent, and charging for that is a billing matter (PENDING).
   - Channel ingest sets COD only (decision 8).
   - The fields are **create-only.** There is no amend, because no order edit command exists (PENDING, beside 4-1b's amend).
7. **Hashing (the 8-1d conditional-key rule, IMPLEMENTATION-GUIDE §4).**
   - Each field is normalised first. Strings are trimmed and blank means absent.
   - Each field joins the staff `payloadHash` and the portal hash **only when sent** (as sent, never the derived default). They take fixed positions right after `clientOrderRef`, in the order `orderType`, `priority`, `shipByDate`, `codAmountPaise`.
   - They are **not** in the channel `sourcePayloadHash`, for two reasons:
     - A redelivery spanning the deploy must still resolve to its order rather than answer `order-source-conflict`.
     - The dedup fingerprint pins the stock-bearing shape.
   - The accepted cost is twofold:
     - A COD order ingested before the deploy stays prepaid. No backfill is possible, and the release note says so.
     - Two divergent deliveries of one channel ref resolve to the first order's COD.
   - The existing goldens stay byte-identical. New goldens pin each field.
8. **Shopify COD** (`shopifyParseOrder`).
   - **When it is COD.** The order is COD when both hold:
     - `payment_gateway_names` (an array of strings) has an entry matching `/cash on delivery|\bcod\b/i`;
     - `financial_status` is `pending` or `partially_paid`.
   - **The amount.** `codAmountPaise` comes from `total_outstanding`: a decimal string `^\d{1,8}(\.\d{1,2})?$`, converted to paise with integer arithmetic. It must fall between 1 and the cap.
   - **Fail closed.** A COD body whose amount fails is **unmappable**. The parse returns null, which is the existing metered 400, and that is never a prepaid order.
   - **What stays unmapped.** No channel maps type, priority or ship-by in this story. Shopify has no ship-by, and Amazon's `LatestShipDate` lands with its transport (PENDING).
9. **Wave urgency order.**
   - Both selection paths of `generateWave` return orders by **priority rank, then `ship_by_date` ascending with nulls last, then `(created_at, id)`**.
   - The order lines are planned in that order. `planSlices` consumes the stock pool destructively, so the urgent order draws the first-FEFO stock.
   - Picklists are created in that order. Their uuidv7 ids order the device snapshot and its whole-picklist truncation.
   - **The row locks keep `(created_at, id)` order.** That order is the deadlock-avoidance contract with `cancelOrder`, `wave.command.ts:1081-1085`.
     - The sweep becomes two statements: an unlocked candidate read, ordered by urgency with `LIMIT cap`, then `FOR UPDATE` over those ids in `(created_at, id)` order, re-stating the same eligibility predicate. The result is sorted in JS.
     - A candidate claimed in between is skipped, so the wave may be smaller than the cap.
   - The policy's own `priority` stays display-only (`schema.ts` comment, "never a scheduler").
10. **Handheld.**
    - **The pick walk stays in bin order.** Re-sorting it would break the walk. Each stop shows its order's priority chip and ship-by.
    - **The Pack list** is sorted by urgency (rank, ship-by, then today's order). Each card shows its chips and "COD ₹x".
    - **The bench** shows a "Cash on delivery — collect ₹x" banner.
    - The snapshot keys are optional on the device: an older seal lacks them, the 11.7 precedent.
11. **Documents and the carrier.** Order fields never change (decision 6), so reading them through is the same as freezing them. A later amend must refuse once an order is labelled (PENDING).
    - **The packing slip** (`PackDto`), **`DispatchDto`** and **`ShipmentDto`** carry `codAmountPaise`, and the slip also carries `orderType`.
    - **The manifest snapshot** carries `codShipmentCount` and `codTotalPaise`, computed in its create transaction (the courier's cash hand-over figure).
    - **`CarrierLabelRequest` and `CarrierRateRequest`** gain `codAmountPaise: number | null`. The sandbox arms ignore it; real adapters (4-6d) must send it.
    - **Not changed:** the tax invoice and the e-way bill (PENDING).
12. **Display rule.**
    - **The priority chip** appears for `high` and `urgent` only. It is always text, never colour alone.
    - **Ship-by** shows as `DD Mon`. It adds **"Overdue"** when the date is before today (IST) and **"Due today"** when it equals today, both only while the order is `accepted` or `ready_to_dispatch`.
    - **Money** uses `formatInrPaise` on the web (ICU-free). The mobile copy is byte-identical and pinned by test.
13. **The outbound register** appends `order_type`, `priority`, `ship_by_date` and `cod_amount_paise`, in that order, after `client_order_ref`.
14. **No list sort or filter by these fields in this story.** The staff list stays on its keyset, and urgency is visible by chip (PENDING).

## Boundaries & Constraints

**Always:**
- **Migration** (numbered next free at code time; main is at 0088, WMS-BE #125 adds 0089 and 3-2b takes 0090, so 0091 or later) follows IMPLEMENTATION-GUIDE §3:
  - **Fail-fast guard:** `orders.priority` must not already exist.
  - **Columns on `orders`:**
    - `order_type text NULL`;
    - `priority text NOT NULL DEFAULT 'normal'` (a constant default, so no rewrite);
    - `ship_by_date date NULL`;
    - `cod_amount_paise bigint NULL`.
  - **CHECKs:**
    - `orders_order_type_check`: `order_type IS NULL OR order_type IN ('b2b','b2c')`;
    - `orders_priority_check`: `priority IN ('normal','high','urgent')`;
    - `orders_cod_amount_paise_check`: `cod_amount_paise IS NULL OR (cod_amount_paise > 0 AND cod_amount_paise <= 1000000000)`.
  - **All three CHECKs are `NOT VALID`.** Existing rows carry NULL or `'normal'` by construction, and NOT VALID still enforces every new write. This avoids the ACCESS EXCLUSIVE scan on a large `orders` table (§3).
  - **No index and no backfill.**
  - **The post-migration probe** follows 0088's model:
    - accepted shapes, rolled back by a sentinel;
    - refused shapes, each refused by its named constraint: type `'b2x'`, priority `'low'`, COD `0`, `-1` and `1000000001`.
  - Plus the journal entry and the snapshot. `db:generate` must be clean.
- **Each vocabulary keeps its three mirrored layers** (TS tuple, CHECK, `@IsIn` + `@ApiProperty({enum})`). The nullable `orderType` lists `null`: `enum: [...ORDER_TYPES, null]`. An e2e test pins each tuple against its CHECK.
- **The command re-checks every field.** Non-HTTP callers (ingest) bypass the DTO.
- **The portal stays inside its fences:** portal responses are an exact key allowlist with the four keys added; the portal reaches no operator component.
- **The web parses before it mints a key**, and every new input's edit wrapper clears the idempotency key.

**Never:**
- No amend; no list sort or filter.
- No change to tax invoice, e-way bill, ledger events or reservation logic.
- No change to the pick walk order or to the wave row-lock order.
- No new fields in `sourcePayloadHash`.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|---|---|---|---|
| Staff full | `orderType:'b2c'`, `priority:'urgent'`, `shipByDate`: today IST, `codAmountPaise:149900` | stored; list shows Urgent, "Due today", COD ₹1,499.00; register row carries all four | — |
| Defaults | none of the four; GSTIN given / not | `b2b` / `b2c`, `normal`, nulls; hash byte-identical to pre-4-2a (goldens) | — |
| Contradiction | `b2c` + GSTIN | — | 400 `validation-failed` |
| Bad values | type `'b2x'`; priority `'low'`; COD `0`, `1.5`, `1000000001`; date `'2026-02-30'`, yesterday, today + 366 | — | 400 `validation-failed` |
| Replay across midnight | same key and body, date = yesterday's "today" | the cached order | — |
| Portal | ACME places with all four | stored; ACME's row and detail show them; BETA sees nothing | — |
| Shopify COD | gateway "Cash on Delivery (COD)", `pending`, `total_outstanding:"1499.00"` | `codAmountPaise:149900`, `b2c`, `normal` | — |
| Shopify COD, bad amount | COD + `total_outstanding:"abc"`, missing, or `"0.00"` | — | parse null → metered 400; no order |
| Shopify prepaid | `financial_status:'paid'` | `codAmountPaise:null` | — |
| Redelivery across deploy | pre-4-2a ingested COD order redelivered | resolves to the existing order (prepaid) | — |
| Wave sweep | cap 1; older `normal` and newer `urgent` accepted | the wave holds the urgent order | — |
| Wave allocation | two orders contend for one bin's first-FEFO batch; the newer is `high` | the `high` order's slice takes it | — |
| Ship-by tie-break | same priority; ship-by tomorrow vs null vs today | today, tomorrow, null | — |
| Pack/dispatch/manifest | COD order packed, labelled, manifested | slip, dispatch, shipment show COD; manifest `codShipmentCount:1`, `codTotalPaise`; label request carries it | — |

</frozen-after-approval>

## Design Review Amendments

The design review (2026-10-23) ran a claims check (K1–K17, against origin/main `9a246e7`) and a blind review (B1–B23). It was triaged in the Review Triage Log below. The amendments are recommended and were taken autonomously.

**Where they bind.** They bind over the frozen block. Where an amendment says "supersedes decision N", the decision reads as amended. The frozen Boundaries and Matrix are left as written; **Amended Boundaries** and **Amended matrix rows** at the end of this section win where they differ.

### Snapshots, ordering and ids

**A1 — Every new key on a stored response is optional and read `?? null`** (K1, K2, K7). These stored responses gain the keys as `required: false`, nullable:
- `OrderDto`, `PackDto`, `DispatchDto`, `ManifestDto`;
- **`ShipmentDto`**, a stored label answer (this changes the Code Map's "required");
- **`PicklistDto`**, part of the stored `WaveSnapshot` (generate and release replays);
- **`PortalPlacedOrderResponse`** (`src/api/portal.dto.ts:452`), which gains the four keys.

How they are filled:
- Every reader and the web treat an absent key as null.
- `PicklistDto.priority` and `.shipByDate` are threaded through `WaveCommand.snapshotOf` (`wave.command.ts:1432`) and `picklistSnapshot` (`:1493`). They fold over the picklist's **non-cancelled** lines' orders only: the most urgent rank, and the earliest date.
- Each stored response has a test that replays a pre-4-2a stored snapshot byte-unchanged.

**A2 — Monotonic ids; an explicit device pick order** (K3, B11).
- **The bug.** `uuidv7` (`src/shared/primitives/ids.ts:13-20`) bumps `now` when the 12-bit sequence wraps but never stores it in `lastMs`. The next id in the same millisecond goes back in time. Fix: carry the bump into `lastMs`, so ids are monotonic within a process. Add a unit test in `src/shared/primitives/ids.spec.ts` that forces a wrap.
- **The device pick read.** It no longer relies on id order. `getPickTasksInTx` (`pick.command.ts:1683`) orders by:
  1. the picklist's urgency key (A8; a lateral read of the most urgent order among the picklist's `planned` lines);
  2. `picklists.created_at`;
  3. `picklist_id`;
  4. `walk_seq`;
  5. the line id.
- `truncateToWholePicklists` follows that order, so an urgent picklist is never the one cut.

**A3 — Ingested orders refuse the three manual fields** (K4; supersedes decision 5's ingested clause and the channel half of decision 6).
- `createOrder` with `source: 'ingested'` that carries `orderType`, `priority` or `shipByDate` (non-blank) → **400 `validation-failed`**. This sits beside the 4-1b refusal at `order.command.ts:449`. COD stays allowed: it is Shopify's.
- So an ingested order never carries a ship-by date in this story, and decision 5's "not bounded" arm is moot.

### Channel ingest

**A4 — Shopify COD fails closed** (K5, B4; supersedes decision 8). The parse reads three things:
- **Gateway.** Each `payment_gateway_names` entry is normalised first: `[_-]` becomes a space and the case is folded. It is then matched against `/cash on delivery|\bcod\b/`.
- **Status.** With a COD gateway, `financial_status` is an allow-list:
  - `pending` or `partially_paid` → COD;
  - `paid`, `refunded` or `partially_refunded` → prepaid (null);
  - **anything else → unmappable.**
- **Currency.** `currency` (the shop currency, which `total_outstanding` is stated in, never `presentment_currency`) **must be `INR`**, else unmappable.

The amount rule is unchanged: `total_outstanding`, `^\d{1,8}(\.\d{1,2})?$`, converted to integer paise, from 1 to the cap. Without a COD gateway, the order is prepaid whatever the status.

**A5 — A distinct refusal reason** (B5).
- The parse arm may answer `{ refused: 'cod-amount-unmappable' }` (a new `ParsedChannelRefusal` beside `ParsedChannelOrder | null`, `channel-registry.ts:131`).
- `webhooks.controller.ts:105-108` passes it to `recordIngestParseRefused(tenantId, connectionId, reason?)` (`channels.facade.ts:212`). That writes `error: 'cod-amount-unmappable — the COD amount to collect could not be read (currency, status or total_outstanding)'` under the same `validation-failed` meter status.
- The HTTP answer is unchanged: the existing 400. The channel's own retry policy re-delivers, and each delivery re-refuses.
- The manual repair path (staff enter the order by hand, with COD) is PENDING.

**A6 — COD drift on redelivery** (B3).
- A delivery whose order ref resolves to an existing order (`prior`, `channels.ingest.command.ts:168`) with a **different** `codAmountPaise` still resolves to the original order. It logs a `warn` naming the connection, the order id and both amounts (never the payload).
- `findOrderByChannelRef` (`outbound.facade.ts:514`) returns `codAmountPaise` for this check.
- Consuming `orders/updated` is PENDING.

**A7 — The derivation on ingest** (B18).
- `ParsedChannelOrder` carries no GSTIN, so an ingested order always derives `b2c`. This includes a Shopify B2B order (a non-null `company`); mapping it is PENDING.
- The `b2c` + GSTIN refusal (decision 4) applies **only to an explicitly sent `b2c`.** A derived type never refuses.

### Wave planning

**A8 — The urgency key and wave concurrency** (B9, K6, B10; supersedes decision 9's key).

*The key.* One key orders everything urgent:
1. **due first**: `ship_by_date IS NOT NULL AND ship_by_date <= today_IST` (overdue or due today);
2. the priority rank;
3. `ship_by_date` ascending, nulls last;
4. `created_at`;
5. `id`.

It applies to the wave selection, the device pick and pack snapshots (A2, A16) and the web and mobile sorts. There is one SQL helper, `orderUrgencyOrderBy(todayIst)`, and one TS comparator, `compareOrderUrgency(a, b, todayIst)`, both in the new `src/modules/outbound/order-urgency.ts`. The wave's today is `istDateOf(WAVE_CLOCK.now())` (`wave.clock.ts:13`).

*The sweep.*
- **Candidates.** An unlocked read by the key, `LIMIT cap * 2`.
- **Lock.** A locked re-read of those ids, in the existing `(created_at, id)` order, re-stating the eligibility predicate.
- **Keep.** The first `cap` rows still eligible, in key order.
- **None survived.** When candidates were found but the locked re-read kept none, the candidate read runs once more. If that is still empty, the command throws `WaveClaimLostError(candidateIds)`, which resolves through `claimConflict` (`wave.command.ts:1187`) to 409 `conflict`, titled "Order is already on an open wave" and naming the winner (`openWaveConflict`, `:1608`), or the generic 409 `conflict` (retry). **Never the 422 no-eligible.** No candidate at all stays the existing 422.

*The explicit path* keeps its locked read and sorts in JS.

*Concurrency, both outcomes stated:*
- (a) **Two concurrent sweeps** lock overlapping rows in the same `(created_at, id)` order. One waits on the other's commit, then sees those orders claimed and takes the next eligible ones, or answers as above.
- (b) **A sweep against `cancelOrder`** queues as today. A cancelled candidate fails the re-stated predicate and is skipped.

*The deadlock test.* Two connections:
- connection A: `BEGIN`, then lock order X, which is older than order Y;
- connection B: a sweep whose urgency key puts Y first;
- then A tries to lock Y.

Assert that no `40P01` is raised and both settle.

*AC2 scope.* AC2's ordering claim is scoped to **one sweep with no concurrent writers.**

**A9 — The planning-order side effect** (K14).
- Selection order replaces `orderId` order (`wave.command.ts:527`) as the order `planSlices` consumes the stock pool in. That is intended: the urgent order draws first.
- `test/waves.spec.ts:804` ("oldest first") is re-pinned as "urgency, then oldest". Its all-normal, no-ship-by fixture gives the same result, and a comment says why.
- Any slice-allocation assertion that assumed `orderId` order is re-checked.

**A10 — `ORDER_PRIORITY_RANK` ↔ `orderPriorityRankSql` pin** (K15). A test evaluates the SQL CASE in Postgres for each priority and compares it with the TS rank.

### Validation and hashing

**A11 — Value checks live in the command; the DTO checks types only** (K8, B6, B7, B20; supersedes the Code Map's `@IsIn` / `@Min` / `@Max` and the frozen Boundaries' "`@IsIn`" layer).

*The DTOs.* `CreateOrderDto` and `PortalCreateOrderDto`:
- `orderType`, `priority`: `@IsOptional @IsString` + `@ApiProperty({ enum: [...] })` (orderType `[...ORDER_TYPES, null]`);
- `shipByDate`: `@IsOptional @IsString`;
- `codAmountPaise`: `@IsOptional` + `@ApiProperty({ type: 'integer' })`.

This is the 4-1b / 8-1d precedent. The global pipe has no implicit conversion (`app.factory.ts:71-75`), so a string stays a string.

*The command, behind the replay.* For all four, absent means `undefined`, `null` or `''`/whitespace.
- **Vocabularies:** an allow-list check.
- **`shipByDate`:**
  - must match `^\d{4}-\d{2}-\d{2}$` and be a real calendar date (`isIsoDate`, `shared/primitives/time.ts:49`);
  - a datetime string → 400;
  - **the trimmed string is what is hashed.**
- **`codAmountPaise`:** must be `typeof number` and `Number.isSafeInteger` in 1..cap. A string (`"149900"`), a fraction or a non-number → 400.

*Values sent are hashed as sent.* An explicit `priority: 'normal'` hashes differently from an omitted one; a golden pins it and API-SURFACE says so.

*What is allowed.* COD on `b2b` is allowed. COD above the goods value is allowed: it may include shipping and charges, and the web shows no comparison.

**A12 — The portal may set `normal` or `high` only** (B8; supersedes decision 6's priority part).
- Portal `urgent` → 400 `validation-failed`: "Urgent priority is set by the warehouse — choose Normal or High."
- `urgent` is staff-only. The portal form offers two options.

**A13 — Clocks** (K17, B21).
- **Ship-by bounds.** The create's bound uses `licenceToday()`, which is `licenceClock` (`compliance/licence-enforcement.ts:43-47`). Tests move `licenceClock.now` to 18:29:59Z and 18:30:00Z (the IST midnight) for the yesterday / today / +365 / +366 fixtures.
- **Web.** It uses `istDateOf(Date.now())` (`lib/rate-cards.ts:84`). A test fixes the clock at 19:00Z (00:30 IST the next day) under a non-IST `TZ` and asserts "Due today" and the date input's `min`.
- **Mobile.** It computes Due-today and Overdue from the **snapshot's server IST date**, `istDateOf(snapshot.generatedAt)` (`CatalogSnapshotResponse.generatedAt`, `receiving.dto.ts:1401`), never the device clock. The chip is therefore "as of the last refresh".

### Display

**A14 — The display rule** (B1, B12).
- **Overdue and Due today.**
  - These chips show while the order is `accepted` or `ready_to_dispatch`. Those are all the statuses before dispatch: `ORDER_STATUSES` has no `picking` arm, and an order on a released wave is still `accepted`.
  - They never show for `dispatched` or `cancelled`.
- **The payment line,** one rule on every surface (web staff, portal, mobile, packing slip, dispatch):
  - "COD ₹x" when `codAmountPaise` is non-null;
  - else "Prepaid" when `orderType` is non-null;
  - else "—".
- **Legacy orders.** A legacy order packed after the deploy shows "—", and so does a legacy stored `PackDto` replayed.

**A15 — A new import-free web module** (K12).
- `wms-fe/src/lib/order-fields.ts` holds all the order-field helpers, with no imports, so `lib/orders.ts` keeps its no-imports contract (`lib/orders.ts:1-4`):
  - the labels, `compareOrderUrgency`, `shipByStatus`, `paymentLine`;
  - `parseShipByDate(text, todayIst)` and `codAmountProblem(paise)`.
- `todayIst` is always passed in.
- `formatInrPaise` moves here from `lib/outbound-pack-dispatch.ts:662`, which re-exports it so its callers are unchanged.
- The rupee parse stays `parseRupees` (`lib/rupees.ts:14`), called from `lib/outbound-orders.ts` and `lib/portal.ts` (pure `lib/*` helpers are portal-allowed, `lib/portal-boundary.test.ts:31`).

**A16 — Handheld ordering** (K13).
- **The Pick inbox** (`app/inbox.tsx:577`) groups stops by picklist and orders the groups by the picklist's most urgent task (A8's key, through `compareOrderUrgency`), then `picklistId`. Within a group the walk stays `walkSeq`.
- **The pack snapshot** (`getPackTasksInTx`, `outbound.facade.ts:1261`) orders by the urgency key, then `orders.created_at, orders.id, skus.code, picks.sku_id`. That keeps each order contiguous for `truncateToWholeGroups` (`:1267`), so `MAX_SNAPSHOT_PACK_TASKS` (`:302`) never cuts an urgent order before a routine one.
- The urgency key's date is the IST date of the snapshot's `generatedAt`, passed into `getPickTasks` and `getPackTasks` from `receiving.controller.ts:214`.

### Carrier, manifest and register

**A17 — COD on shipments and the manifest** (B2, B13).
- **One shipment per order.** Today an order has at most one shipment for its whole life: the label command refuses any existing shipment, any status (`shipment.command.ts:199-213`). So COD rides exactly one label, and the manifest counts COD by order.
- **No void and no manifest mutation.** No void arm exists (`SHIPMENT_STATUSES = ['labelled','manifested']`, `:39`), and `createManifest` is the only manifest command (`manifest.command.ts:101`). So the frozen figure is never recomputed.
- **The figure.** `codTotalPaise = Number(coalesce(sum(o.cod_amount_paise), 0)::bigint)` and `codShipmentCount = count(o.cod_amount_paise)`, both over the member shipments' orders in the create transaction. They are **frozen in the manifest snapshot.** The list read (`outbound.facade.ts:1054`) computes the same, because order COD is immutable.
- **Rows:** a manifest with no COD reads 0/0.
- **Handoffs:**
  - When multi-carton shipments land (roadmap 4.5), COD rides the first carton's label only (PENDING).
  - 4-2c's follow-on order must not carry the original's COD again (deferred-work 4-2c entry amended).

**A18 — Carrier COD capability** (B14).
- **The flag.** `CarrierAdapter` (`carrier-registry.ts:52`) gains `readonly supportsCod: boolean`:
  - `sandbox` declares `true`;
  - `delhivery`, `blue_dart` and `ecom_express` declare `false` until their real transports land (their arms are the 501 today). Each transport story declares it.
- **Labels.** `createShipmentLabel` refuses a COD order on a connection whose carrier declares `false` with **409 `carrier-cod-unsupported`**, before any adapter call.
- **Rates.** The rate read marks such a carrier's item as a refusal with the same code.
- **No cache to change.** The rate read is live per request, with no cache or fingerprint (`rate.service.ts:238-260`), so nothing else changes. The request carries `codAmountPaise`.
- **Test.** A test registers a stub adapter through `registerCarrierAdapter` (`:80`).

**A19 — The sandbox tracking number is unchanged** (K16). COD never joins `sandboxLabelArm`'s canonical string (`carrier-label-port.ts:89-96`), so the label goldens stay unchanged.

**A20 — Register columns** (K9, B15; supersedes decision 13's position).
- The four columns are **appended at the end of the row**: `order_type`, `priority`, `ship_by_date`, `cod_amount_paise`. Today the last column is `client_order_ref`.
- `cod_amount_paise` is an **order-level value repeated on every line** of a multi-line order. The column doc in `registers.ts` and `reporting.md` say so, and a two-line row pin expects `149900` on both lines.
- The expected values are in paise.

### Migration and docs

**A21 — The migration** (K10, B17).
- **The re-run guard** raises when **any** of the four columns exists.
- **The probe:**
  - `pg_constraint.convalidated = false` for all three CHECKs;
  - an insert that omits `priority` reads back `'normal'`;
  - the refused and accepted shapes as frozen.
- **The DO blocks never contain the word `INDEX`.** `migrate-deploy.ts:339` treats such a DO block as "unparsed, review".
- **The tuple ↔ CHECK pins** (`test/orders.spec.ts:925` style) parse the quoted literals, which tolerates the ` NOT VALID` suffix, and assert `convalidated = false`.
- **Lock timeout.** The deploy migrator sets `lock_timeout` on every connection (`MIGRATE_LOCK_TIMEOUT_MS`, `DEFAULT_LOCK_TIMEOUT_MS = 5_000`, `migrate-deploy.ts:68,756`). An `ALTER TABLE orders` that cannot take its lock fails the deploy cleanly; the remedy is to re-run the deploy (DEPLOY.md §5 gains the line).
- **Rolling deploy.** Orders created by old pods during the deploy have `order_type` null and `priority` `'normal'`. The UI shows "—", which is the legacy arm.
- **No VALIDATE in this story.** VALIDATE would run in the migrator's single transaction under the ADD COLUMN's ACCESS EXCLUSIVE lock. It stays a PENDING entry instead.

**A22 — PENDING edits** (K11, B23).
- **Re-point the partners entry** (PENDING `:163`, pickers "until roadmap 4.1/4.2"). Neither row owns them:
  - the transporter picker → roadmap 4.9;
  - the consignee picker and several ship-to addresses → **unowned (no roadmap row)**, flagged for planning.
- **Billing:** add "COD handling charge" and "portal priority (high) charge".
- **The amend entry** reads: "amend order fields — refuse an amend once packed (the slip is printed)".

**A23 — Reservations versus slice order** (B19). The Never clause "No change to … reservation logic" reads: **"No change to how reservations are made at accept. The wave's slice order changes by urgency (A9)."** Under contention:
- the urgent order is fully planned;
- the normal order takes the shortfall as an `unfulfillable` slice with `shortfall_qty` (`planSlices`' `need > 0` arm, `wave.command.ts:1300`, existing behaviour), reported as today.

**A24 — Acceptance criteria per stage** (B16). Replaced in Tasks & Acceptance.

**A25 — Every file named; the checklist per repo and per file** (B22). Replaced in Code Map, Tasks and Verification.

### Amended Boundaries

These supersede the frozen ones where they differ.

**Always:**
- **The migration is A21 plus the frozen column and CHECK list.**
- **The vocabularies' three layers** are the TS tuple, the CHECK (NOT VALID) and the API layer's `@ApiProperty({ enum })`. The command holds the value check (A11). Pinned by e2e tests.
- **Every new key on a stored response is optional, nullable and read `?? null`** (A1).
- **The portal's fences hold:**
  - an exact key allowlist;
  - portal `urgent` refused;
  - `lib/order-fields.ts` import-free.
- **The web parses before minting a key.** Every new input's edit wrapper clears the key.

**Never:**
- No amend; no list sort or filter.
- No change to the tax invoice, the e-way bill or ledger events.
- **No change to how reservations are made at accept** (the slice order changes, A23).
- **No change to the wave row-lock order.**
- No new field in `sourcePayloadHash`.
- No VALIDATE of the new CHECKs.

### Amended matrix rows

They add to, or supersede, the frozen matrix.

| Scenario | Input / State | Expected | Error |
|---|---|---|---|
| Ingested manual fields (A3) | `source:'ingested'` + `priority:'high'` / `orderType` / `shipByDate` | — | 400 |
| Bad types (A11) | `codAmountPaise:"149900"`; `1.5`; `shipByDate:"2026-10-24T00:00:00Z"`; `"2026-2-4"` | — | 400 |
| Blank = absent (A11) | `orderType:"  "`, `shipByDate:""`, `codAmountPaise:""` | as omitted; hash byte-identical to omitted | — |
| Explicit default (A11) | `priority:'normal'` sent | stored `normal`; hash ≠ the omitted hash (golden) | — |
| COD on B2B; COD > goods (A11) | `b2b` + COD ₹50,000 on a ₹1,000 order | accepted | — |
| Bounds (A13) | `licenceClock` at 18:29:59Z / 18:30:00Z; date = IST today, +365 / +366, yesterday | today and +365 accepted; +366 and yesterday 400 | — |
| Portal urgent (A12) | portal `priority:'urgent'` | — | 400 |
| Portal isolation | ACME's order with fields; BETA lists and searches | BETA sees nothing | 404 on the id |
| Shopify non-INR (A4) | COD gateway, `currency:'USD'` | — | unmappable → 400, metered `cod-amount-unmappable` |
| Shopify status arms (A4) | COD gateway + `paid`, `refunded`, `partially_refunded` / `authorized`, `voided` | prepaid / unmappable | — / 400 |
| Shopify gateway spelling (A4) | `"cash_on_delivery"`, `"COD-India"` | COD | — |
| Shopify B2B (A7) | `company:{…}`, no COD | `b2c` (PENDING) | — |
| COD drift (A6) | redelivery of an ingested order with a different `total_outstanding` | resolves to the original; warn logged | — |
| Overdue in progress (A14) | `accepted` order on a released wave, ship-by yesterday | "Overdue" on web, picker and handheld | — |
| Wave key (A8) | normal due yesterday vs high due next week | the overdue normal first | — |
| Sweep lost all (A8) | every candidate claimed between read and lock, twice | — | 409 `conflict` (winner named, or retry), never 422 |
| Shortfall (A23) | urgent and normal contend for 5 units, 3 on hand in pickable bins | urgent planned 3; normal `unfulfillable` with its shortfall | — |
| Payment line (A14) | legacy order packed after deploy; legacy stored `PackDto` replayed | "—" | — |
| Manifest no COD (A17) | prepaid orders only | `codShipmentCount:0`, `codTotalPaise:0` | — |
| Carrier no COD (A18) | COD order on a carrier declaring `supportsCod:false` | — | 409 `carrier-cod-unsupported`; rate item refused |
| uuidv7 wrap (A2) | 4097 ids in one fixed millisecond | strictly increasing | — |

## Code Map

### Backend (`workspace/core/backend/wms-be`, origin/main `9a246e7`)

**Schema and migration**
- `drizzle/NNNN_order_fields.sql` (new; next free at code time, likely 0091+), plus `drizzle/meta/_journal.json` and `drizzle/meta/NNNN_snapshot.json`: frozen columns, NOT VALID CHECKs, A21.
- `src/shared/db/schema.ts:2903` `orders`: `orderType`, `priority` (`.notNull().default('normal')`), `shipByDate` (`date(…, { mode: 'string' })`, as `:3151`), `codAmountPaise` (`bigint(…, { mode: 'number' })`, as `:3050`).

**Primitives**
- `src/shared/primitives/ids.ts:13-20`: the wrap fix (A2).
- `src/shared/primitives/ids.spec.ts`: the wrap test.

**Outbound**
- `src/modules/outbound/order-urgency.ts` (new):
  - `ORDER_TYPES`, `ORDER_PRIORITIES`, `ORDER_PRIORITY_RANK`, `orderPriorityRankSql`, `MAX_COD_AMOUNT_PAISE`;
  - `orderUrgencyOrderBy(todayIst)` and `compareOrderUrgency`.
- `src/modules/outbound/order.command.ts`:
  - commands: `:209`, `:266`;
  - the ingested refusal: beside `:449` (A3);
  - hashes: `:507-536`, `:645-655`; `sourcePayloadHash` `:515` unchanged;
  - `OrderHashStage`: `:2287`;
  - checks: in `preflightPhase` after `:964`, with the `licenceDate` threaded in; portal `urgent` refused (A12);
  - insert: `:1328`;
  - `snapshotOf`: `:2052`.
- `src/modules/outbound/wave.command.ts`:
  - `selectOrders`: `:1086-1160` (A8);
  - the `pickable` sort before `:568` (A9);
  - `snapshotOf` `:1432` and `picklistSnapshot` `:1493` (A1).
- `src/modules/outbound/pick.command.ts:1642-1690`: task fields and the A2 order.
- `src/modules/outbound/outbound.facade.ts`:
  - `listOrders` `:751`;
  - `findOrderByChannelRef` `:514` (A6);
  - `getPickTasks` / `getPackTasks` `:1171-1306`, with `todayIst` (A16);
  - manifest list `:1054` (A17).
- `src/modules/outbound/pack.command.ts`, `dispatch.command.ts`: snapshot fields.
- `src/modules/outbound/shipment.command.ts:161-300`: `ShipmentDto` fields, the A18 refusal, the label request `:244`.
- `src/modules/outbound/rate.service.ts:247`: the request field and the A18 item refusal.
- `src/modules/outbound/manifest.command.ts:51,101`: the A17 totals.
- `src/modules/outbound/portal-orders.ts:18,100,125`: the four keys.
- `src/modules/outbound/outbound.dto.ts`:
  - `CreateOrderDto` `:97` (A11);
  - `OrderDto` `:231`, `OrderEntryDto` `:399`, `PicklistDto` `:680`, `PickTaskDto` `:1041`;
  - `PackDto` `:1250`, `DispatchDto` `:1395`, `ShipmentDto` `:1505`, `ManifestDto` `:1579`.

**Elsewhere**
- `src/modules/inbound/receiving.dto.ts:1186`: `CatalogPackTaskDto` gains `orderPriority`, `orderShipByDate` and `codAmountPaise`.
- `src/api/receiving.controller.ts:214`: passes the snapshot's IST date.
- `src/api/portal.dto.ts`: `:164` (row and detail), `:393` (create, A11), `:452` (placed, A1).
- `src/api/webhooks.controller.ts:105-108`: the A5 reason.
- **Channels:**
  - `src/modules/channels/channel-registry.ts:102,131`: `codAmountPaise?` and `ParsedChannelRefusal`;
  - `channel-shopify-port.ts:469`: A4;
  - `channels.ingest.command.ts:168,210-222`: A6, pass COD;
  - `channels.facade.ts:212`: reason.
- **Carriers:**
  - `src/modules/carriers/carrier-registry.ts:52,110,131,158,189`: `supportsCod`;
  - `carrier-label-port.ts:39,116`: `codAmountPaise`.
- **Register:**
  - `src/modules/reporting/registers.ts:251-274`: four columns appended;
  - `src/modules/outbound/outbound-register.ts:75`: selects them.

**Tests (wms-be)**
- `test/order-fields.spec.ts` (new):
  - all matrix rows;
  - the tuple/CHECK pins and `convalidated`;
  - the A10 rank pin;
  - snapshot replays (A1);
  - the A8 deadlock test;
  - manifest, carrier and register COD.
- `test/issuance-gate-parity.spec.ts`, `test/portal-orders-create.spec.ts`: new goldens, old ones unchanged; the A11 explicit-default golden.
- `test/portal.spec.ts`: the row shape pin, extended deliberately.
- `test/orders.spec.ts:925`: the parity pin gains the new tuples.
- `test/waves.spec.ts:804`: re-pin (A9).
- `test/packing.spec.ts`, `test/pack-bench.spec.ts`, `test/pack-truncation.spec.ts`: the slip and snapshot order.
- `test/dispatch.spec.ts`, `test/label.spec.ts` (A18, A19), `test/rate.spec.ts`.
- `test/registers.spec.ts:539,686-699` (A20).
- `test/channel-transports.spec.ts` (A4 parse arms), `test/channel-webhooks.spec.ts` (A5, A6).
- `test/migrate-deploy.spec.ts`: the new file lints clean.
- `src/modules/carriers/carrier-registry.spec.ts`: `supportsCod` declared by every adapter.
- `src/shared/primitives/ids.spec.ts`.

### Web (`workspace/core/frontend/wms-fe`)

**Shared helpers**
- `src/lib/order-fields.ts` (new, import-free) and `src/lib/order-fields.test.ts`: A15, the A13 clock test.
- `src/lib/outbound-pack-dispatch.ts:662`: re-exports `formatInrPaise`.
- `src/lib/outbound-orders.ts`: the create-body fields and the COD parse via `parseRupees`; `createReason` (`:341`) keeps details verbatim.
- `src/lib/portal.ts`: `parsePortalOrderCreate` fields (portal priority Normal/High); `portalOrderReason` (`:521`).

**Staff screens**
- `src/components/outbound/outbound-orders.tsx`: form `:420-560`, wrappers `:267-299`, table `:690-760`, detail `:941`.
- `src/components/outbound/outbound-waves.tsx`: picker `:541-560` (sorted, chips); `PicklistPanel` `:1061-1074`.
- `src/components/outbound/pack-dispatch.tsx`: table `:168-203`, panel `:294`, slip `:342`, dispatch confirmation, manifest COD line.

**Portal screen**
- `src/components/portal/portal-orders.tsx`: form `:171-330`, list `:69-87`, expanded row `:154`.

**Tests and client**
- Tests: `outbound-orders.test.tsx`, `outbound-waves.test.tsx`, `pack-dispatch.test.tsx`, `portal-orders.test.tsx` (beside each component), `src/lib/portal-boundary.test.ts` (must stay green).
- `src/lib/api/generated/*`: `bun run api:generate`.

### Mobile (`workspace/core/mobile/wms-mobile`)

- `src/api.ts:1689,1738`: optional `orderPriority?`, `orderShipByDate?`, `codAmountPaise?` (pack).
- `src/lib/order-fields.ts` (new, pure) and `src/lib/order-fields.test.ts`:
  - `formatInrPaise` (byte-identical to the web's), labels, `paymentLine`;
  - `shipByStatus(date, todayIst)` and `compareOrderUrgency`;
  - `todayIst` = `istDateOf(snapshot.generatedAt)` (`src/lib/ist-date.ts:17`).
- `app/inbox.tsx`: pick grouping and sort `:577` (A16); `PickTaskCard` `:598`; `PackOrderCard` `:754`; the pack list sort `:729`.
- `src/packing/draft.ts`: `packOrderIdsOf` stays as is; the sort is applied in the inbox.
- `app/pick.tsx:473`: the chips.
- `app/pack.tsx:450`: the COD banner and the chips.

## Tasks & Acceptance

**Execution — wms-be:**
- [x] `drizzle/NNNN_order_fields.sql`, journal and snapshot, `schema.ts`: A21 → matrix "Bad values", AC1.
- [x] `ids.ts`, `ids.spec.ts`: A2 → row "uuidv7 wrap".
- [x] `order-urgency.ts`: A8, A10 → AC2.
- [x] `order.command.ts`, `outbound.dto.ts` (`CreateOrderDto`, the read DTOs), `portal.dto.ts`: decisions 2–7, A1, A3, A11, A12, A13 → rows "Staff full", "Defaults", "Contradiction", "Bad types", "Blank", "Explicit default", "Bounds", "Portal urgent", "Ingested manual fields"; AC1.
- [x] `wave.command.ts`: A1, A8, A9, A23 → rows "Wave sweep", "Wave allocation", "Wave key", "Sweep lost all", "Shortfall"; AC2.
- [x] `pick.command.ts`, `outbound.facade.ts`, `receiving.dto.ts`, `receiving.controller.ts`: A2, A16 → AC3.
- [x] `pack.command.ts`, `dispatch.command.ts`, `shipment.command.ts`, `manifest.command.ts`, `rate.service.ts`, `carrier-registry.ts`, `carrier-label-port.ts`: A17, A18, A19 → rows "Pack/dispatch/manifest", "Manifest no COD", "Carrier no COD"; AC4, AC5.
- [x] `portal-orders.ts`: the four keys → row "Portal isolation".
- [x] `channel-registry.ts`, `channel-shopify-port.ts`, `channels.ingest.command.ts`, `channels.facade.ts`, `webhooks.controller.ts`: A4–A7 → the Shopify rows, "COD drift".
- [x] `registers.ts`, `outbound-register.ts`: A20 → AC1.
- [x] Tests as in the Code Map; OpenAPI regenerated.

**Execution — wms-fe:**
- [x] `lib/order-fields.ts` and its test: A13, A14, A15.
- [x] `lib/outbound-pack-dispatch.ts`: the re-export.
- [x] `lib/outbound-orders.ts`, `outbound-orders.tsx` and its test: the staff form, table and detail → AC1.
- [x] `outbound-waves.tsx` and its test: the picker and picklists → AC1, AC2.
- [x] `pack-dispatch.tsx` and its test: slip, dispatch, manifest → AC4, AC5.
- [x] `lib/portal.ts`, `portal-orders.tsx` and its test: A12 → AC1.
- [x] Generated client.

**Execution — wms-mobile:**
- [x] `src/api.ts`, `src/lib/order-fields.ts` and its test: A13, A14 → AC3.
- [x] `app/inbox.tsx`, `app/pick.tsx`, `app/pack.tsx`: A16 → AC3.

**Execution — meta (last):**
- [x] `docs/design/modules/outbound.md`:
  - the schema rows;
  - the urgency key, the sweep concurrency and the lock note;
  - the hash positions and the explicit-default rule;
  - the payment line;
  - the manifest COD.
- [x] `docs/design/modules/channels.md` (A4–A7), `carriers.md` (`supportsCod`, the request field), `reporting.md` (A20 columns, COD repeated per line).
- [x] `docs/design/API-SURFACE.md`, recounted, including the explicit-default hash note; `docs/design/frontend/SYSTEM-DESIGN.md`; `docs/design/mobile/SYSTEM-DESIGN.md` (the snapshot keys and the date source); `docs/repos/wms-be/README.md`, `wms-fe/README.md`, `wms-mobile/README.md`.
- [x] `docs/design/IMPLEMENTATION-GUIDE.md` §3: a NOT VALID CHECK on a just-added column needs no VALIDATE scan, and a DO block must not say `INDEX`.
- [x] `docs/design/PENDING.md` (A22 plus):
  - the amend entry (refused once packed);
  - list sort/filter;
  - channel priority, ship-by and B2B (`company`) mapping;
  - consuming `orders/updated` for COD drift;
  - the manual repair for a refused COD webhook;
  - per-carrier `supportsCod` when transports land;
  - COD on the tax invoice;
  - COD remittance reconciliation;
  - COD on the first carton only (roadmap 4.5);
  - billing for COD handling and portal high priority;
  - VALIDATE the three CHECKs;
  - the partners re-point.
- [x] DEPLOY.md §5: the lock-timeout retry line (A21).

**Acceptance Criteria** (A24):
- **AC1, at create.** Given ACME places a portal order with COD ₹1,499, priority high and ship-by today, when staff open Outbound, then the list, the detail and the wave picker read High · Due today · COD ₹1,499.00. The outbound register's row carries `b2c`, `high`, the date and `149900`. The portal list and detail show the same.
- **AC2, waving.** Given one sweep with no concurrent writers and more than `cap` accepted orders, when a wave is generated, then the selection follows A8's key exactly, and the slices are planned in that order.
- **AC3, after pick.** Given the order is fully picked and the device refreshes its snapshot, then its pack card sits above routine orders and shows the chips and "COD ₹1,499.00", and the bench shows "Cash on delivery — collect ₹1,499.00".
- **AC4, after pack.** Given the order is packed, then the packing slip carries `codAmountPaise: 149900` and the payment line. A replay of a pre-4-2a stored slip still parses and shows "—".
- **AC5, after label, manifest and dispatch.**
  - The label request carries `codAmountPaise`.
  - A carrier declaring `supportsCod: false` is refused 409.
  - The manifest reports `codShipmentCount: 1` and `codTotalPaise: 149900`.
  - The dispatch confirmation shows "COD ₹1,499.00".

## Design Notes

- **Why the type is derived, not required.** A required field would make every existing caller and the channel ingest 400, or force an always-present hash key, which is the replay break §4 warns against. The GSTIN already decides the tax treatment, so deriving the type from it stores a truthful default.
- **Why the lock order is not touched.** The current sweep locks the rows it returns, in its `ORDER BY`. Ordering that statement by urgency would make two concurrent waves lock rows in an order that differs from `cancelOrder`'s. Splitting the read from the lock (A8) costs one statement and keeps the existing contract.
- **Why due-first leads the key** (A8). A normal order due today misses its promise if a week of `high` orders with later dates is waved first. Priority orders the work within the same deadline class.
- **Golden sketch:** `{…, consigneeGstin, clientOrderRef:"SO-7", orderType:"b2c", priority:"urgent", shipByDate:"2026-10-24", codAmountPaise:149900, lines:[…]}`. Each key is absent when not sent, and present when sent, even with the default value.

## Verification

**Commands:**
- `bun run test -- test/order-fields.spec.ts test/issuance-gate-parity.spec.ts test/portal-orders-create.spec.ts test/portal.spec.ts test/orders.spec.ts test/waves.spec.ts test/packing.spec.ts test/pack-bench.spec.ts test/pack-truncation.spec.ts test/dispatch.spec.ts test/label.spec.ts test/rate.spec.ts test/registers.spec.ts test/channel-transports.spec.ts test/channel-webhooks.spec.ts test/migrate-deploy.spec.ts src/shared/primitives/ids.spec.ts src/modules/carriers/carrier-registry.spec.ts` (wms-be; run alone, never beside another jest) — expected: pass.
- `bun run db:generate` (wms-be) — expected: "No schema changes"; `git status --short` shows no untracked files.
- `bun run lint && bun run typecheck` (wms-be, wms-fe) — expected: pass.
- `bun test` (wms-fe; includes `lib/order-fields.test.ts` and `lib/portal-boundary.test.ts`) — expected: pass.
- `bun test && bun run typecheck` (wms-mobile) — expected: pass.

**Manual checks:**
- In a real HTTP smoke, place a portal COD order, wave it, pick and pack it on the handheld, label it with the sandbox carrier, manifest it and dispatch it. Every stage in AC1–AC5 should show the figures.

## Implementation Notes

- **Commits.** wms-be `0013c6a` (migration **0093**); wms-fe `63f8101`, plus `718530c` (the wave picker and picklist chip tests, added at the step-03 audit); wms-mobile `3a4becb`. Meta: the docs listed under Execution — meta.
- **Deviations from the Code Map.**
  - `orderUrgencyOrderBy(todayIst, columns)` takes the caller's column fragments, so the same key serves the wave sweep, the pack read and the pick lateral read.
  - `MAX_COD_AMOUNT_PAISE` and `decimalRupeesToPaise` live in `shared/primitives/money.ts`, because channels may not import outbound; `order-urgency.ts` re-exports the cap.
  - The web form parse is the new `lib/order-fields-form.ts`, shared by the staff create and `lib/portal.ts`, instead of `lib/outbound-orders.ts`.
  - The sweep's locked re-read also re-reads open claims in a fresh statement. Under READ COMMITTED, the row lock re-checks only the row's own predicate, not the `not exists` subquery.
- **Verification (2026-10-24).**
  - wms-be: the listed jest set passed, 18 suites and 371 tests. Lint and typecheck are clean, and `db:generate` reports no schema changes.
  - wms-fe: lint, typecheck and `bun test` (2592) pass.
  - wms-mobile: `bun test` (901) and typecheck pass.
  - The manual HTTP smoke has not been run.
- **Code review (2026-10-24):** C1–C20; 9 patched, 1 deferred (C10), 10 rejected (see the Review Triage Log). After the patch round:
  - wms-be: the full suite passed, 3365/3365; the drift guard was re-exported after the DTO edits.
  - wms-fe: 2627 tests pass; wms-mobile: 901.
- **PRs:** WMS-BE #130 → WMS-Mobile #34 → WMS-FE #115 → this meta PR. They are stacked on 2-8a (BE #128, FE #113) and 3-3a (BE #129, FE #114).

## Spec Change Log

## Review Triage Log

Design review, 2026-10-23. K = claims check against origin/main; B = blind review. Verdicts: high / medium / low / false / rejected.

| ID | Verdict | Finding → resolution |
|---|---|---|
| K1 | high | `ShipmentDto` is a stored label answer; the spec made its new key required → A1 |
| K2 | medium | `PicklistDto` rides the stored wave snapshot; the fold source and the cancelled lines were unstated → A1 |
| K3 | high | `uuidv7` sequence wrap leaves `lastMs` stale (`ids.ts:15-19`), so ids can run backwards and the snapshot's id order is not trustworthy → A2 |
| K4 | medium | Nothing stopped an ingested order from carrying type, priority or ship-by → A3 |
| K5 | high | Shopify COD rule: no currency check, no status allow-list → A4 |
| K6 | high | The sweep's split read/lock had no stated outcome when candidates are lost → A8 |
| K7 | medium | `PortalPlacedOrderResponse` lacked the fields; stored-snapshot replay unpinned → A1 |
| K8 | medium | `@IsIn` / `@Min` in the DTO refuse before the replay and diverge from the 4-1b/8-1d precedent → A11 |
| K9 | medium | The register columns "after client_order_ref" must be at the end of the row → A20 |
| K10 | high | Migration: NOT VALID breaks naive pins; a DO block saying INDEX is refused by the deploy lint; the guard covered one column → A21 |
| K11 | low | PENDING `:163` says pickers wait for 4.1/4.2 — neither owns them → A22 |
| K12 | medium | `lib/orders.ts` is import-free by contract; helpers wrapping `parseRupees` would break it → A15 |
| K13 | medium | The handheld still orders picklists by id, and the pack snapshot truncates oldest-first → A16 |
| K14 | medium | The planning order changes from `orderId` to selection order — unstated; `waves.spec.ts:804` pins oldest-first → A9 |
| K15 | low | The TS rank and SQL CASE could drift → A10 |
| K16 | low | Adding COD to the sandbox canonical would change label goldens → A19 |
| K17 | medium | The ship-by clock was unnamed; no IST-midnight fixtures → A13 |
| B1 | medium | Overdue chip statuses unclear; a "picking" order row was asked for → A14. **Corrected:** no `picking` status exists, so the row is an `accepted` order on a released wave |
| B2 | medium | COD could ride several labels → A17. Verified: one shipment per order for life (`shipment.command.ts:199-213`); the 4.5 and 4-2c handoffs were added |
| B3 | medium | A channel COD change on redelivery was silent → A6 |
| B4 | high | Gateway-name spelling variants (`cash_on_delivery`) were missed → A4 |
| B5 | medium | A COD parse refusal was indistinguishable in metering → A5 |
| B6 | medium | `shipByDate` shape too loose (datetimes) → A11 |
| B7 | low | Explicit default values hash as sent — undocumented → A11 |
| B8 | medium | Portal clients could mark everything urgent → A12 |
| B9 | high | Priority-first lets a later high order starve an overdue normal one → A8 |
| B10 | medium | No deadlock test for the split sweep → A8 |
| B11 | medium | Device order relied on uuid order → A2 |
| B12 | medium | "Prepaid" vs "—" rule inconsistent across surfaces → A14 |
| B13 | medium | Manifest COD total null-sum, frozen or not, mutations → A17. **Partly rejected:** the "voided shipment" row is not applicable (no void arm exists, `shipment.command.ts:39`), and no manifest mutation exists |
| B14 | high | A COD order could be labelled with a carrier that cannot collect → A18 (the rate read has no cache, stated) |
| B15 | low | The register's COD repeats per line — undocumented → A20 |
| B16 | medium | AC1 bundled every stage → A24 |
| B17 | medium | Migration lock timeout, rolling deploy, probes → A21. **Rejected in part:** "VALIDATE in the same story" — the migrator applies the pending set in ONE transaction, so VALIDATE would scan `orders` under the ADD COLUMN's ACCESS EXCLUSIVE lock; NOT VALID + PENDING kept |
| B18 | medium | The ingest derivation's GSTIN source was unstated → A7 |
| B19 | medium | The Never clause "no reservation logic change" contradicts the slice reorder → A23 |
| B20 | medium | Missing rows: COD on B2B, COD above the goods value, string COD, portal isolation, +365/+366 → A11, A13, amended matrix |
| B21 | medium | The mobile due-date chip used the device clock → A13 |
| B22 | medium | Files unnamed in tasks; tests in Verification missing from the Code Map → A25 |
| B23 | low | The amend PENDING wording was weak → A22 |

Code review, 2026-10-24. Layers: BH = Blind Hunter, EC = Edge Case Hunter, VG = Verification Gap. Verdicts: high / medium / low / false; route patch / defer / reject.

| ID | Verdict | Finding → resolution |
|---|---|---|
| C1 | medium (patch) | BH1, EC3, EC10. The COD parse refusal answered 400 before the known-order lookup, so a redelivery of an order already held (its body now `voided`/`authorized`, or a pre-4-2a order) was refused on every retry. This broke decision 7: a redelivery always resolves. → `ParsedChannelRefusal` carries the order without its COD, and the ingest refuses only a FIRST delivery (after `findOrderByChannelRef`); a known order resolves, with the drift warn. New e2e test. |
| C2 | low (patch) | BH2. The refusal meter did not name the order, so an operator could not find the Shopify order. → The meter sentence and the 400 detail now name the channel order ref. |
| C3 | medium (patch) | BH4, EC1. `uuidv7`: after a backward clock reading, every id until the clock caught up took a random sequence, so ids in one millisecond were not monotonic. The wrap test left the module in 2099, which disabled the property for the rest of the file. → A reading before the last one restarts the sequence at that reading (the pre-4-2a behaviour); a step-back test was added. |
| C4 | medium (patch) | BH5, EC8. The pick snapshot's lateral urgency subquery ran once per task row. → It is now one `distinct on (picklist_id)` derived table over the warehouse's ready picklists, joined once. |
| C5 | low (patch) | BH9. The portal priority allow-list was hard-coded in the DTO enum and the command. → `PORTAL_ORDER_PRIORITIES` in `order-urgency.ts`, used by both. |
| C6 | low (patch) | BH11. The `pickTasks` description still said "in walk order". `OrderEntryDto.priority` was declared nullable though a live read always has one. There was also an import order nit and a double blank line. → All fixed. |
| C7 | low (patch) | EC5, EC11. A picklist with nothing left to pick (or cancelled) still showed Overdue / Due today. → `ShipByChip` gains `open`, and the picklist passes `status ≠ cancelled ∧ a planned line`; test added. |
| C8 | medium (patch) | VG1. No snapshot test had "due" beat a higher priority, so dropping the due key or passing a wrong date passed. → Two e2e tests: an overdue normal order ahead of an older non-due high one, in pick and in pack. |
| C9 | medium (patch) | VG3. These were never rendered by a component test: the staff list and detail, the portal list, `dispatch-payment`, `manifest-cod`, and the status pass-through that hides Overdue. → Tests in `outbound-orders.test.tsx`, `pack-dispatch.test.tsx` and `portal.test.tsx`. |
| C10 | medium (defer) | VG2. No test checks that a picklist's urgency counts only planned lines (a batch picklist with its urgent order already picked). → deferred-work. |
| C11 | rejected | BH3. `pending` with `total_outstanding "0.00"` is refused rather than treated as prepaid. The frozen matrix names `"0.00"` as unmappable (fail closed). |
| C12 | rejected | BH6. Two definitions of a picklist's urgency (web: non-cancelled lines; device: planned lines). A1 and A2 define them deliberately. |
| C13 | rejected | BH7, EC7. The handheld breaks picklist ties by id, not by the server's order. A16 specifies `picklistId`. |
| C14 | rejected | BH8, EC6. The wave picker sorts the loaded page only. Decision 14 rules out list sort and filter (PENDING). |
| C15 | rejected | BH10, EC4. `codAmountPaise` has no type decorator, and `""` reads as absent. A11 and the "Blank = absent" matrix row specify both. |
| C16 | rejected | BH12. COD drift is only logged. A6 specifies a warn; `orders/updated` is PENDING. |
| C17 | rejected | BH13. The register's COD is in paise. A20 specifies paise. |
| C18 | rejected | BH14 (partly). There are no render tests of the mobile screens; the house pattern pins the pure helpers (mobile guide §8). The other gaps are folded into C1, C3, C8 and C9. |
| C19 | rejected | EC2. The sweep locks up to `cap*2` candidates. A8 specifies the locked re-read of every candidate; the extra rows are held only for the wave transaction. |
| C20 | rejected | EC9. Browser clock skew against the server's IST date. The server is the authority, and the web only pre-checks. |
