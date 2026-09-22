# Pending and tracked items

**Everything known-but-not-done, grouped by the module that owns it.** Check your module's section before writing a story against it — several of these are already-diagnosed defects with the fix identified, and picking one up alongside related work is cheaper than a separate story.

Two sources, both authoritative:
- **`_bmad-output/implementation-artifacts/deferred-work.md`** — **65 entries.** Findings from story reviews that were real but out of that story's scope
- **`_bmad-output/implementation-artifacts/sprint-status.yaml` → `action_items`** — **33 open.** Epic retrospective commitments

---

## Cross-cutting — read these before any story

| Item | Why it matters | Source |
|---|---|---|
| **Keyset cursor truncates to milliseconds** against microsecond `created_at`, so same-millisecond rows at a page boundary are **silently skipped** | Affects every `buildPage(rows.map(toView))` site in the repo. A real correctness bug in pagination, not cosmetic | epic-2 retro a1 |
| **`decodeCursorSafe`/clamp guards are copy-pasted**, not a shared primitive | Six copies of the same UUID regex; the next one to drift is a 500 instead of a 400 | epic-1 retro item 6 |
| **Idempotency scaffolding is duplicated verbatim across nine command files** | `writeIdempotencyKey` ×5, the replay block hand-inlined everywhere. A shared helper is its own change | 4-6 review, epic-3 retro a8 |
| **`unavailable` means two different things** — a real stockout and a fail-closed Valkey outage | Epic 7's channel consumers will branch on it. Needs its own machine code before they do | epic-2 retro a8 |
| **Process: no real-HTTP smoke in step-05** | Live runs caught two behaviours a 212-test suite never observed | epic-1 item 8, epic-2 a9 |

---

## inventory

- **Grant ceiling vs concurrent adjustment race** — the module header claims "never oversells"; the actual guarantee is narrower. Either re-validate committed on-hand after the Valkey win, or weaken the claim *(epic-2 retro a2)*
- **Reconciliation starvation** — never-checkpointed partitions are not re-queued on failure, and no periodic full pass exists, so the bounded-scan escape hatch is unreachable *(epic-2 retro a6)*
- **Multi-serial adjustment response snapshot mismatch** — the last per-unit event id/seq is paired with the aggregate delta, in both the response and the outbox payload *(epic-2 retro a4)*
- **Verification gaps**: `exportDigest`'s three refusal arms, `anchorChain`'s empty-ledger arm and concurrent-anchor case, outbox ack-delete failure injection, the reconcile failure stamp, `parseLastDivergences` malformed entries *(epic-2 retro a7)*
- **Blocked batch status is unenforced on the draw side** — the FEFO draw does not consult batch status *(epic-2 retro a13)*
- **Typed-error hardening**: `ttlSeconds: 0` should be a 400; `verifyChain` range input is unvalidated; the int4 ceiling overflow should be a typed 422 *(epic-2 retro a14)*
- **Shared test bootstrap + lock-key registry** — the nine-suite deployment-parity block wants extracting; advisory keys want one registry *(epic-2 retro a10)*
- **Pre-migration ledger hashes no longer verify** — migration 0026 rewrote `quantity_delta` without rehashing and cannot honestly do otherwise. `verifyChain` reports **severity-1 on every pre-migration event, by design**; a test pins it as expected. Nothing schedules `verifyChain` today *(story 10.1)*

## outbound

- **A packed-but-abandoned order understates ATP indefinitely** — `expireDue` sweeps `held` only, cancel refuses a packed order, and dispatch is the sole `committed → released` writer *(4-6 review)*
- **No read-back for a dispatch record** — carrier, tracking and dispatch time live only in `ledger_events.reference_doc`. "What is the tracking number for order X" needs a raw jsonb scan *(4-6 review)*
- **A short shipment leaves no queryable trace** and schedules no backorder follow-on *(4-6 review)*
- **Terminal pick classification is a hand-maintained list** — the next status arm silently becomes retryable again. This is exactly the defect 4.6 fixed, with nothing preventing its recurrence *(4-6 review)*
- **`orders` list has no status filter** — `OrderListQuery` carries only `cursor`/`limit`, so the FE's status filter is page-scoped *(4-2b)*

## inbound

- **Over-receipt approve does not re-validate PO/line status** — a close-then-approve sequence bumps a closed line's ceiling. Needs a lock before the bump *(epic-3 retro a1)*
- **`releaseHold` lacks `.for('update')` on the origin read**, and release-into-a-blocked-bin behaviour is unpinned *(epic-3 retro a3)*
- **PO amend has no received-line guard** — delete or SKU rewrite should be refused when `receivedQty > 0` *(epic-3 retro a5)*
- **Catalog-snapshot composition is not single-tx** and its fan-out is unbounded *(epic-3 retro a13)*
- **GRN sequence exhaustion** should be a typed 409; `occurredAt` drift needs a bound decision *(epic-3 retro a14)*

## putaway

- **`retireBin` has no serial-arm empty gate** *(epic-3 retro a4, 3-6 review deferrals #2/#31)*
- **System-bin identity is unprotected** — no `systemOwned` filter in `ensureReceivingBinInTx`, and `RECEIVING`/`QC-HOLD` codes are not reserved, so an operator can create a bin that collides with a system one *(epic-3 retro a2)*
- **Stock adjustments bypass ALL bin capacity gates** — no bin-row lock, no unit/weight/volume check, so any bin can be parked over every limit by an adjustment, after which every placement/merge into it refuses *(11-5 review, deferred-work)*
- **A concurrent adjustment races a placement past a stale load** — the bin-row `.for('update')` serializes only gate-compliant writers; adjust takes no bin-row lock (pre-existing for the unit gate; 11-5 widens the currency, not the mechanism) *(11-5 review, deferred-work)*

## tenancy

- **badge-in hardening**: no PIN attempt lockout, no role gate on binding *(epic-3 retro a6)*. **Corrected 2026-09-18:** the same retro item also claimed the enroll replay lookup lacked a `tenantId` predicate — it does not; the code carries it and `test/devices.spec.ts:703` pins it. That arm is closed
- **Migration 0005 owner-backfill** needs verification before any production deploy *(epic-1 retro item 5)*
- **`roleHasCapability` throws on an unknown role** — `ROLE_CAPABILITIES[role].includes(...)` with no fallback, and stored sessions validate role only as `typeof === 'string'`. **Crash-class**, one-token fix, pre-existing since 1.5 *(4-2c review, wms-fe)*
- **Architecture guard decision**: the vacuous facade-guard test is fix-or-delete, and AD-6's read policy needs settling *(epic-3 retro a7)*
- **`setBlocked`'s bin lock omits the `tenantId` predicate** — unlike `editBinCapacity`'s identical lookup; RLS-covered today, an inconsistency rather than a defect *(11-5 review, deferred-work)*
- **`normalizeBin`'s pre-11.5 idempotency-snapshot fallback is untested** — no test replays a snapshot stored without the four capacity fields; same additive-nullable pattern as the retirement pair, so low risk *(11-5 review, deferred-work)*
- **Migration 0005 owner-backfill** needs verification before any production deploy *(epic-1 retro item 5)*
- **`roleHasCapability` throws on an unknown role** — `ROLE_CAPABILITIES[role].includes(...)` with no fallback, and stored sessions validate role only as `typeof === 'string'`. **Crash-class**, one-token fix, pre-existing since 1.5 *(4-2c review, wms-fe)*
- **Architecture guard decision**: the vacuous facade-guard test is fix-or-delete, and AD-6's read policy needs settling *(epic-3 retro a7)*

## catalog

- **`uom_conversions.factor` is an integer nothing applies** — stored at import, echoed back, never used in arithmetic. Fractional conversions (kg↔lb) wait for the story that first applies one *(story 10.2)*
- **Imperial units are deliberately absent** from the vocabulary — useful only alongside conversions, so they land together *(story 10.2)*
- ~~**Products/variants have no consumers yet** *(story 11-3)*~~ **Closed 2026-09-22 by story 11-6** — the web Products card (`products-card.tsx`) now reads the grouping (expandable variant matrices, attach/detach through the SKU PATCH, product create/edit). Epic 7's Shopify mapping note still stands: a Shopify product maps to a `products` row and its options/variants map to `axes`/`variantValues`; the channel-mapping tables are Epic 7's own deliverable — Epic 11 only gates them
- ~~**Kits are API-only** *(story 11-4)*~~ **Closed 2026-09-22 by story 11-6** — the web SKU table gains the composition editor (create/PUT kit routes), the order detail renders parent/child exploded lines, and the import gains the `kit_components` column with the same guards and `catalog.kit_created` event parity. ~~The mobile announcement is still 11-7's~~ **Closed 2026-09-22 by story 11-7** — the mobile pick path now carries the variant arm offline: the snapshot's SKUs gain `variantValues`/`axes` and its pick tasks `kitParentSkuCode` (display-only), the post-scan announcement leads with the variant label, the task header shows label + `from kit {code}`, and a wrong-item rejection names both sides' variants (`src/picking/variant.ts`, pinned verbatim)
- **An axis name containing a comma round-trips corruptly through the product edit form** — `parseProductAxes` splits on commas only and the backend's `assertAxes` has no character restriction, so an axis stored as `a, b` (reachable only via a non-FE client) prefills `"a, b, c"`-style and an untouched save silently rewrites the axes. The symmetric victim of the deliberate entry-vs-display grammar split (fix A1); a PENDING note, not a patch — reachability requires a non-FE writer *(fix-a1 review)*
- **The kit guard's reservation half is not serialized against order-create** — `assertKitSkuHoldsNoStock` refuses a SKU with live reservations, but order-create reads kit-ness with no SKU-row lock (`order.command.ts:381`), so a concurrent kit create and order create can both commit — an order line reserving what is now a kit SKU, never exploding, never pickable. Pre-existing (fix A2's scope was the +stock writers, now all three locked); needs the same `.for('update')` SKU lock in the order-create path, or an explicit decision that the window is acceptable *(fix-a2 review, deferred-work)*

## carriers

- **`openCredentialForAdapterUse` has no caller and no test** — the module's only envelope-opening read. Deleting its `tenantId` predicate would let any tenant open any other tenant's credential **with the full suite still green**. 4-6c brings the first caller; **pin the tenant predicate first** *(4-6b review)*
- **Rotating `CARRIER_ENCRYPTION_KEY` is unsupported** — every stored blob becomes unopenable and idempotent replay breaks. Needs a key id in the blob and a re-seal path *(4-6b review)*

## wms-mobile

- **`uomPrecision` ships unconsumed.** The catalog snapshot carries it so the device can refuse a too-precise scan **offline, before queueing**. Until story 10-6 builds that, a too-precise dead-zone scan queues and is refused on replay — the exact behaviour the field exists to prevent. **A live gap, not a deferred nicety** *(story 10.2)*
- **A scan enqueued during an in-flight replay is deleted unsent — silently.** `replayOutbox` snapshots the queue with `listOps()` (`engine.ts:89`), works from that copy, and ends with `store.replaceOps(remaining)` (`:227`), which is `DELETE FROM outbox` + re-insert (`outbox-store.ts:149-151`). `deviceStore.replay()` (`device-store.ts:305`) has **no in-flight guard** — grep finds no single-flight anywhere in `src/` — and `app/putaway.tsx:216`, `app/receive.tsx:264` and `app/pick.tsx:407` all fire `void deviceStore.replay()` un-awaited immediately after confirm. So an op appended while a replay is mid-flight is absent from `remaining` and destroyed by the rewrite. The window is one network round-trip **per queued op**, and a fast operator scanning the next item lands inside it. **This is zero-scan-loss, the client's founding constraint, failing.** `appendOp`-during-replay is the fix boundary: either a single-flight promise on `replay()`, or `replaceOps` diffing against live rows instead of truncating. **Verified 2026-09-18** *(mobile design pass)*
- **No connectivity detection exists.** `offline` is a manual switch; nothing observes the network, so there is no drain-on-reconnect and no background sync. A queue only moves when the operator confirms something or taps sync. `decideScan`'s "no task types are live yet" rejection prose is also stale *(mobile design pass)*
- **`uomPrecision` is absent from the mobile types entirely** — `CatalogSku` (`src/api.ts:464-472`) declares only `uom`, and every quantity path is `parseInt`/`Math.floor`/`Number.isInteger`. Sharpens the entry above: the backend sends the field, the client cannot see it *(mobile design pass)*
- **Hardening batch**: batchCode-null confirm, wrong-shape seal, undecryptable row, refresh single-flight, stale retired-bin, reset confirm *(epic-3 retro a9)*
- **Hand-written `api.ts` types** instead of the generated client, against AD-8 *(epic-1 retro item 7)*
- **Scan budgets unmeasured** — 1.5 s / 500 ms have never been measured on a real mid-range Android *(epic-3 retro a12)*

## wms-fe

- **No component tests for story 4-2b's own screen.** The infrastructure now exists (happy-dom + a hand-rolled render helper); 4-2b predates it, so its screen is a backfill *(4-2b/4-2c)*
- **The at-risk countdown's 30-second refresh is pinned by no test** — delete the interval and the amber chip freezes, with nothing failing. Needs timer control the suite uses nowhere yet *(4-2c review)*
- **Capability mirror is hand-maintained** — the CI guard catches drift between the lists, but not a role outside them *(epic-1 item 4, epic-2 a12)*

---

## Found while writing the module designs (2026-09-18)

Not from a story review — surfaced by reading each module end to end. **Verified where marked; the rest say so.**

| # | Finding | Module | Status |
|---|---|---|---|
| 1 | **A badge-in device token satisfies `TenantSessionGuard`.** Both JWT families are HS256 under the same `JWT_SECRET`, and `verifyTenantSession` (`jwt-session.ts:64`) validates only `sub`, `tenant_id` and `exp` — it never rejects a `device_id` claim, all three of which a badge-in token carries. The docstring at `:178-181` claims the families are "mutually exclusive by claim shape"; that holds **one way only**. Effect: a 30-day floor credential opens the web surface for its own tenant, and on endpoints that never re-resolve the device row **revocation does not bite**. Not cross-tenant, not privilege escalation — `sub` is the operator, so capabilities are the operator's | tenancy | **verified** |
| 2 | **The catalog import parses the file before checking `catalog.import`** (`import.command.ts:152-155` vs `:170`), inverting the authority-before-validation rule the guide states. An unauthorised caller can drive a 5 MB parse and learn parse outcomes | catalog | **verified** |
| 3 | **`bins` has no architecture-test coverage.** It is the one table deliberately shared by column — tenancy owns structure and `retired_at`, putaway owns `blocked` — and `test/architecture.spec.ts` enumerates only the stock/ledger, order/wave/pick and carrier table sets. The shared-ownership case is the one with no automated guard | tenancy + putaway | **verified** |
| 4 | `pick-unresolvable`'s `title` may never reach the wire | outbound | **unverified** |
| 5 | `cancelOrder` may not reset `order_lines.status` | outbound | **unverified** |
| 6 | A wholly-`unfulfillable` order may pack to an empty parcel. The code comments the *adjacent* all-`cancelled` case at length and says nothing about this one — the shape of an overlooked case rather than a deliberate one | outbound | **unverified** |

Items 4–6 need checking before they are either fixed or dismissed; they are recorded as suspicions, not defects.

## Blocked, not merely deferred

| Item | Blocked on |
|---|---|
| **Story 4-6d — rate shopping** | ~~There is no address model anywhere~~ **resolved by story 11-1** (`0030_shipment_addresses.sql`): `orders` carries the `destination_*` columns, `warehouses` the `origin_*` columns — both required at create, pincode TEXT. ~~SKUs carry no weight or dimensions~~ **resolved by story 11-2** (`0031_sku_physical_attributes.sql`): `skus` carries nullable `weight_grams` (≤ 1,000,000), `length_mm`/`width_mm`/`height_mm` (≤ 10,000) and `country_of_origin` (ISO alpha-2) — the static catalog attributes carriers rate from, settable via the SKU edit PATCH and the import's five new optional columns. The remaining work is the carrier surface itself (rating, labels, manifest) |
| **Retryable inline label error** (Outbound surface) | Labels live in 4-6c, which is backlog |
| **Subscription billing** | No epic covers it, and PRD open question 4 on the pricing axis is unresolved. **The product cannot charge anyone for itself** |
| **Production operations** | The architecture spine defers IaC, CI/CD shape, dashboards and on-call. Not a feature gap — a can't-run-a-SaaS gap |
| **Customer data onboarding** | Catalog import exists; opening stock balances and migration off an incumbent system appear nowhere |

---

## How to use this

1. **Before speccing a story**, read your module's section. A listed item with the fix already diagnosed is usually cheaper to fold in than to schedule separately.
2. **When a review defers something**, it lands in `deferred-work.md`, which is the authority. This file is a **hand-written digest** of it — no generator exists. When the two disagree, `deferred-work.md` wins; fix this file rather than the other way round.
3. **Epic retrospectives** are where open action items get claimed into a story or explicitly closed. *"Every open retro item claimed into a story spec or explicitly closed at the next epic boundary"* is itself an open process commitment *(epic-3 retro a11)*.
