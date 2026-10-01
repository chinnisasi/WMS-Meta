# Pending and tracked items

**Everything known-but-not-done, grouped by the module that owns it.** Check your module's section before writing a story against it — several of these are already-diagnosed defects with the fix identified, and picking one up alongside related work is cheaper than a separate story.

Two sources, both authoritative:
- **`_bmad-output/implementation-artifacts/deferred-work.md`** — **117 entries.** Findings from story reviews that were real but out of that story's scope
- **`_bmad-output/implementation-artifacts/sprint-status.yaml` → `action_items`** — **33 open.** Epic retrospective commitments

---

## Cross-cutting — read these before any story

| Item | Why it matters | Source |
|---|---|---|
| **Keyset cursor truncates to milliseconds** against microsecond `created_at`, so same-millisecond rows at a page boundary are **silently skipped** | Affects every `buildPage(rows.map(toView))` site in the repo. A real correctness bug in pagination, not cosmetic. **5-2 repaired the two inventory cursors** (ledger timeline + pending queue) — they now encode from the raw `::text` instant via the shared primitive `fullPrecisionInstant` (`src/shared/primitives/time.ts`); every other `buildPage` site still truncates and can adopt the same primitive when next touched | epic-2 retro a1 |
| **`decodeCursorSafe`/clamp guards are copy-pasted**, not a shared primitive | Six copies of the same UUID regex; the next one to drift is a 500 instead of a 400 | epic-1 retro item 6 |
| **Idempotency scaffolding is duplicated verbatim across nine command files** | `writeIdempotencyKey` ×5, the replay block hand-inlined everywhere. A shared helper is its own change | 4-6 review, epic-3 retro a8 |
| **`unavailable` means two different things** — a real stockout and a fail-closed Valkey outage | ~~Epic 7's channel consumers will branch on it. Needs its own machine code before they do~~ **7-1 did the branching** (RN-3): the sync reads the codes by machine — 503 `reservation-store-unavailable` = fail-closed (the row degrades, nothing published), 409 `unavailable` = a real pool state (the clamped figure publishes); `channels.publish.ts`. The generic reaper/grant clients still branch the same way when next touched | epic-2 retro a8 (branched 7-1) |
| **Process: no real-HTTP smoke in step-05** | Live runs caught two behaviours a 212-test suite never observed | epic-1 item 8, epic-2 a9 |

---

## inventory

- **Grant ceiling vs concurrent adjustment race** — the module header claims "never oversells"; the actual guarantee is narrower. Either re-validate committed on-hand after the Valkey win, or weaken the claim *(epic-2 retro a2)*
- **Reconciliation starvation** — never-checkpointed partitions are not re-queued on failure, and no periodic full pass exists, so the bounded-scan escape hatch is unreachable *(epic-2 retro a6)*
- **Verification gaps**: `exportDigest`'s three refusal arms, `anchorChain`'s empty-ledger arm and concurrent-anchor case, outbox ack-delete failure injection, the reconcile failure stamp, `parseLastDivergences` malformed entries *(epic-2 retro a7)*
- **No withdraw/cancel verb or TTL for abandoned adjustment pends** — a pend raised in error lives until an owner rejects it; the frozen 5-2 intent settles the flow as pending→decide with exactly two outcomes *(5-2 review, deferred-work)*
- **A pend whose FEFO-resolved batch is consumed before approval always 422s** — reject-and-re-raise is the only recourse; re-request/re-resolve belongs to the 5-4/5-5 consolidated review-queue UX *(5-2 review, deferred-work)*
- **The approval-threshold flow cannot be disabled via the API** — PUT requires a non-null threshold and no DELETE/nulling verb exists, so disable is SQL-only; the absent row is the disable mechanism *(5-2 review, deferred-work)*
- **Approve/reject carries no decision note, and the requester is never notified of the outcome** — the decide command records status/decider stamps only, and the outbox notifies the owner at pend creation but nothing answers the requester; both are 5-4/5-5 queue-UX wants *(5-2 review, deferred-work)*
- **`fullPrecisionInstant` discards non-UTC offsets** — it matches and then drops any non-UTC offset in the raw instant, emitting Z; harmless while deployments run UTC session TZ (none pin it in config), a cursor-ordering hazard if one ever doesn't *(5-2 review, deferred-work)*
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
- **Stock adjustments bypass the storage-class gate too** *(12-1)* — the conformance predicate runs in the placement/pick/merge/allocation commands only; `stock.adjust` checks no class, so non-conforming stock can be parked in any bin by an adjustment (the same pre-existing currency as the capacity gap above, on the 12-1 gate). Every downstream gate then refuses it, which is the intended containment for now
- **Stock adjustments bypass the hazard segregation gate too** *(12-2)* — the co-location predicate runs in the placement/merge/suggestion gates and the SKU hazard-edit guard only; `stock.adjust` checks no hazard class, so incompatible stock can be parked beside a binmate by an adjustment — the same pre-existing currency as the two gaps above, now on the 12-2 gate. The downstream gates (the next placement/merge into the bin, and the binmates' hazard edits) refuse the co-location afterwards, which is the intended containment for now
- **Stock adjustments bypass the secure-bin authority gate too** *(12-3)* — `stock.adjust` is capability-gated (`stock.adjust`: owner/ops_manager) but class-blind, so non-secure-role stock seeding into a secure bin happens through the named bypass (every 12-1/12-2/12-3 e2e fixture does exactly this). The placement/pick/merge/hold/release gates then refuse any *subsequent* movement of that stock by a floor actor, which is the intended containment — the same shape as the two gaps above
- **Stock adjustments bypass the bulk-asset occupancy gate too** *(12-4)* — `bulkAssetOccupancyHolds` runs in the placement/merge/suggestion arms; `stock.adjust` is type-blind, so a second SKU can be parked in a holding tank by an adjustment — the same pre-existing currency as the four gaps above, now on the 12-4 gate. The next gated movement refuses it, which is the intended containment for now
- **The bulk re-value guard counts on-hand load only** *(12-4 review 2)* — `qc_holds` carries no quantity, so held mass attributed to an origin bin is not computable from the hold rows; a release returning held units into a bulk asset re-valued below (on-hand + held) mass would over-fill it. The guard deliberately guards the computable half and documents the gap rather than half-guarding it
- **A concurrent adjustment races a placement past a stale load** — the bin-row `.for('update')` serializes only gate-compliant writers; adjust takes no bin-row lock (pre-existing for the unit gate; 11-5 widens the currency, not the mechanism) *(11-5 review, deferred-work)*
- **The class gates read the SKU unlocked** *(12-1 deferred)* — the placement, pick draw and wave/allocation pool read the SKU's `storageClass` unlocked, and the SKU class edit locks only the SKU row, so a class edit can commit between a placement/pick's SKU read and its bin write. The window is the single-transaction pair (bin locked, SKU read inside it), and the failure mode is one placement that the post-edit SKU row would refuse — the same shape the 11-5 bin-load race takes. Recorded as accepted currency beside the adjustment bypass, not as a defect. *(12-2)* The 12-2 placement gate widens the currency: the placement SKU read now carries `hazardClass` too, unlocked by the same shape — a hazard edit could commit inside the same window (and the hazard-edit guard locks only the SKU row, like the class edit)
- **The suggestion walk, task derivation and wave pool are role-blind** *(12-3, decided 2026-09-24)* — a secure bin can be *suggested* to an operator, whose command then 403s `role-denied` naming `secure.move` with nothing written: advisory suggestion, binding gate. The rejected alternative — threading `secureCapable` through `candidateFitsSku`/`buildStockPool` — would make suggestions role-aware while task derivation stays warehouse-level, so the two paths would disagree. 12-7/12-8 refine the surfaces; until then the accepted interim is exactly this asymmetry

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

## compliance

*(12-5 built the temperature-excursion module; entries below are its known-not-done, grouped by what defers them.)*

- **Serial-tracked and catch-weight SKUs refuse the whole excursion** (all-or-nothing, naming offenders) — per-unit / handling-unit quarantine is Epic 15's arm, not this module's
- **The 12-7 review queue is unread by any UI** — `listExcursions` (keyset, `warehouseId`/`status` filters) is the backend read; the web review-queue surface, and the mobile capture UX-DR30, are 12-7 and 12-8 *(12-7 landed the web queue — the mobile capture UX-DR30 remains 12-8)*
- **The excursion queue's hold join re-walks the warehouse's full hold chain on every page/tab interaction** *(12-7 triage defer)* — each cursor page and tab switch re-issues up to MAX_PAGE_HOPS (20) sequential qc-holds GETs the previous run already walked. A `cancelled` check keeps superseded walks from landing, but the join is not memoized per warehouse: a large hold history makes the queue cost ~21 requests per interaction. Memoizing the join (cache owner, invalidation on hold create/release) is a small design decision, not a drive-by
- **The excursion queue fires a transient tenant-wide fetch on mount** *(12-7 triage defer)* — `warehouseId` is null until the warehouses list loads, so the hook fires a tenant-wide excursion fetch + hold walk (and the bin labels flash `(unknown bin)`) before re-firing scoped. Self-corrects on load; a proper fix needs a hook skip-semantics decision (when may the hook fire with a null warehouse)
- **No threshold model, no sensor ingestion, no auto-detection** — by design (UX-DR30): manual capture only, an operator-captured reading against a bin. Any threshold/alert work is future scope, not a gap
- **The excursion↔hold linkage lives only in `temperature_excursions.hold_ids`** — ledger `qc.held` events carry reference kind `qc-hold` (holdId + fromBinId) with no excursion id, so a ledger-only reconstruction correlates excursions to holds by bin + timestamp, not by id. 12-6's cold-chain reporting consumes the excursion events (its own reference kind), which is unambiguous; if a later story needs hold-level attribution, the column is the join
- **CI's migration drift guard does not pin `temperature_excursions_status_check`** — `verify.ts` round-trips only app_metadata (tenancy) fields; the status CHECK and RLS live in hand-appended SQL only, so a regenerated migration could silently drop them *(12-5 defer, deferred-work.md)*. The same guard cannot see hand-emitted expression indexes: 0039's `ledger_events_order_ref_idx` is in the live DB but in no drizzle snapshot, so a future hand-edited migration could drop or reshape it with nothing failing *(12-6 defer, same entry family)*

## replenishment

*(6-1 populated the spine module and 6-2 extended it (expiry/aging batch alerts); entries below are its known-not-done, grouped by what defers them.)*

- **Cold-scope bootstrap gap** — a brand-new tenant's warehouses get no breach detection until their first reservation activity wakes the ATP readiness machinery (the sweep's ATP read is fail-closed and the ready marker self-heals only via the startup rebuild's reservation/stock owners and the not-ready grant repair); set by an eager readiness rebuild on warehouse creation, or worker-side not-ready-vs-down logging — recorded in `deferred-work.md` *(6-1 triage defer)*
- **No notification delivery** — `replenishment.breach_detected`, `replenishment.suggested_po_submitted` and `replenishment.batch_alert_raised` carry a `notifyRole` hint whose only consumer today is the relay's log line; the alert panel/bell is Epic 9's surface (the events are audit-adjacent, not delivery — by design; 6-2's batch alerts click through to the batch record from the Replenishment surface, the bell-panel click-through lands there too)
- **No seasonality / temporal reorder model** — by design (the epic's amendment note); the policy schema deliberately does not preclude one but nothing seasonal ships
- **`counts`-style policy admin gap: no per-warehouse defaults editor, no breach-bulk-dismiss** — deliberate scope cuts of 6-1: the SKU-table's tenant-wide editors are the only default surfaces, and dismissal is one breach at a time; neither was specced past the matrix
- **The sweep's ATP freshness is accepted as of phase 2** — a stock movement between the ATP reads and the transitions tx is not re-read before opening (the fresh re-read covers POINT edits only). A tighter window would want the ATP read or the breach open inside one consistent view, which the fail-closed phase rule deliberately forbids; re-reading ATP in phase 3 is the candidate fix if a false-open ever surfaces in practice *(6-1 review)*
- **No batch `block` verb** — `batches.status='blocked'` is unreachable vocabulary (6-2's scan reads it and raises NO NEW alert for a blocked batch, but nothing SETS it); blocking is a future catalog batch-verb story *(6-2 ratification)*
- **No FE editor for the expiry alert config** — the panel reads `GET .../expiry-policies` (absent row → "alerts are OFF") but no surface edits `PUT .../expiry-policies` yet; the route is live and capability-gated, only the web consumer is missing — natural home alongside the suggested-PO/policy admin gap above *(6-2 scope cut)*
- **Dismissed batch alerts re-raise while conditions persist** — recorded BY DESIGN, not as a defect: the open-only partial unique means a fresh alert row opens on the next conditioned scan after any dismissal (matching 6-1's re-breach past dismissal). If tenants report alert fatigue, the candidate fix is an explicit suppression state on the row (its own lifecycle arms), not a unique re-key — see the module doc's gotcha *(6-2)*

## channels

*(7-1 built the module: connection vault + registry + standing buffers + availability sync; entries below are its known-not-done, grouped by what defers them.)*

- **No real marketplace HTTP adapter** — the port's availability and revoke arms answer a typed, verbatim `501 channel-transport-unconfigured` for all three providers, so every connection's health reads degraded-from-transport while the machinery runs. Real transport lands with the launch story that has live credentials (spec 7-1's boundary); 7-2's ingestion/webhooks are separate
- **No mapping-write route** — `ChannelsFacade.setChannelMappings`/`listChannelMappings` is facade-only (7-2's config path + the e2e seeder are the callers). Until a story adds the config surface, a fresh connection publishes nothing (zero mappings appends nothing by design — RN-6's "only mapped scopes")
- **Rotating `CHANNEL_ENCRYPTION_KEY` is unsupported** — the same 4-6b carrier-vault gap: every stored blob becomes unopenable (`503 channel-credential-unreadable`, the rotation path is the written recovery) and idempotent replay breaks. Needs a key id in the blob and a re-seal path, together across the two vaults
- **The breaker threshold is a frozen const** (`BREAKER_FAILURE_THRESHOLD = 5`) and the 60s sync SLO likewise — no per-tenant config exists; the epic-9 KPI read consumes what the const computes
- **No mobile surface for channels** (the epic-7 decision) — the four-state banner and the scan path stay wms-fe-only; the mobile offline engine has no channel integration
## movements

- **No FE `/moves` surface** — transfer orders are creatable/confirmable via HTTP only; the planner verbs (create / cancel / outbound confirm) have no web consumer, and the FE capability mirror must grow `transfers.manage` / `transfers.execute` in that story. Deferred by Decision 1 of spec-5-1; the FE drift guard stays red against this backend until it lands *(5-1)*
- **No in-transit cancellation** — cancel is draft-only (`409 transfer-wrong-state` otherwise). Reversing an in-transit transfer wants a compensating-order design, not a state flip *(5-1, Decision 3)*
- **Snapshot truncation signal computed then dropped** — `getTransferTasksInTx` over-reads `MAX_SNAPSHOT_TRANSFER_TASKS + 1` to learn truncation, then slices without surfacing it; the same shape as pick's `MAX_SNAPSHOT_PICK_TASKS`. Both want a truncation marker on `CatalogSnapshotResponse` when a consumer exists *(5-1)*
- **Expression index candidate on `ledger_events.reference_doc->>'transferId'`** — the transfer correlation reads (detail assembly, the per-line inbound serial-arm derivation) ride the existing `reference_doc` GIN/index posture; revisit if detail-read latency shows up *(5-1)*
- **The mobile placement-gate re-plannable set mirrors the server's throw sites by hand** — `TRANSFER_PLACEMENT_GATE_CODES` (`replay-classification.ts`) duplicates the gate machine codes; a gate code added server-side classifies `rejected` (op dropped from the durable outbox) until the mirror grows. Same hand-mirror class as the FE capability mirror *(5-1)*
- **No count policy delete/unschedule verb** — `PUT .../count-policies` is upsert-only (the frozen row-10 semantics), so a class cannot be unscheduled through the API once its row exists; an ops-grade delete verb belongs to the count-admin surface (5-5 queue-UX scope) *(5-3 review, deferred-work)*
- **~~No indexes for the per-class scheduler scan or the variance-by-task read~~** — **LANDED in 5-4**: migration 0046 carries both (`skus_tenant_id_abc_class_idx`, `count_variances_task_id_idx`) *(5-3 review → closed by 5-4)*
- **`COUNT_SCHEDULER_POLL_MS` appears in no deployment env documentation** — the worker's parse gate follows the `OUTBOX_RECONCILE_POLL_MS` conventions (unset/0 = OFF, invalid value boots loud); when the deployment env table is next touched, list it beside the other poll gates *(5-3)*
- **Count admin still has no web surface** — on-demand create (`POST .../movements/counts`) and the policy PUT/GET have no consumer outside e2e tests; the mobile copy points supervisors at the on-demand verb only. 5-5 delivered the review QUEUE (variances tab + pendings tab + per-tab gating, consuming the variance/policy reads); the count-ADMIN pieces (on-demand create, count-policy PUT) remain unconsumed (the frozen boundary: no web admin) *(5-3, extended by 5-4; narrowed by 5-5)*
- **~~5-3 counts never resolve variances and `open` is the whole variance vocabulary~~** — **RESOLVED by 5-4** (the resolution spine: per-tenant threshold policy, approve-adjust / recount arms, `variances.resolve`); review assignment and notification delivery remain Epic 9 / 5-5 scope *(5-3, Decision — resolved by 5-4)*
- **The ledger's `binId` filter has no supporting index** *(5-4 review pass 1, rejected-low → tracked)* — the 0046-backed `GET .../inventory/events?binId=` filters on `(from_bin_id = bin) OR (to_bin_id = bin)`, which no index serves (the btree per-arm indexes only help one OR side efficiently). No consumer outside e2e today and 5-5's queue may choose variance rows over the ledger arm for its read pattern — weigh the 2-index migration against 5-5's actual read shape *(deferred-work.md)*
- **Empty-string `@Type(() => Number)` coercion into a valid 0** *(5-4 review pass 1, defer)* — `SetVariancePolicyDto.quantityThreshold` rejects fractional input (`@IsInt`) but `?quantityThreshold=` coerces to 0; the same hole exists in 5-2's `AdjustmentPolicyDto`. A house-wide validation-convention fix, not a 5-4 patch *(deferred-work.md)*
- **FE generated SDK is stale for the `binId` query param** *(5-4 review pass 1, defer)* — **RESOLVED by 5-5**: `bun run api:generate` regen'd the client against merged BE and `fetchApiListLedgerEvents` (`GET .../warehouses/{w}/inventory/events?binId&cursor`) is the variance-review ledger panel's read, wrapper-pinned in `client.test.ts` *(5-4 review → closed by 5-5)*
- **`@hey-api/openapi-ts` 0.99.0 drops `| null` on enum+nullable fields** — same generator-bug family as `hazardClass` (deferred-work): 5-5's regen shows `SkuResponse.abcClass` as `'a'|'b'|'c'` hard-required though the BE marks it nullable ("or null when it is not yet classified"); `catalog-kits.test.ts`'s fixture satisfies the false type. Fix once with the generator upgrade/DTO reshape and both fields go honest *(5-5 step-03)*
- **The variance queue's ledger-panel selection is per-page** — a seq checked on ledger page 1 while viewing page 2 is counted and sent but invisible (paging back unticks it); the settling fix would render removable off-page chips. Cosmetic; a bin timeline rarely paginates *(5-5 review, rejected-low → tracked)*

## wms-mobile

- **No connectivity detection exists.** `offline` is a manual switch; nothing observes the network, so there is no drain-on-reconnect and no background sync. A queue only moves when the operator confirms something or taps sync — an op enqueued while a replay pass is in flight waits for the operator's next action to send (12-8 re-confirmed this for `excursion.record`; nothing is lost, the single-flight gate protects the append) *(mobile design pass; 12-8)*
- **Hardening batch**: batchCode-null confirm, wrong-shape seal, undecryptable row, refresh single-flight, stale retired-bin, reset confirm *(epic-3 retro a9)*
- **Hand-written `api.ts` types** instead of the generated client, against AD-8 *(epic-1 retro item 7)* — 12-8 sharpened the cost: a shape drift between the BE snapshot DTO and the mobile parse fails nothing on either side; the FE generated client is the only automated cross-repo pin *(12-8)*
- **Scan budgets unmeasured** — 1.5 s / 500 ms have never been measured on a real mid-range Android *(epic-3 retro a12)*
- **No component/screen test convention.** Every rule is pushed into pure modules and the screens go unrendered by tests, so screen-level wiring is verified only by code review — 12-8's tripwire: the `skuClass` resolution had to be extracted into a tested pure helper (`skuClassForTask`) because nothing else could pin the call site. The capture component's enqueue, the `occurredAt` confirm-stamp and the settled-note rendering rest on the pure-layer tests alone. A lightweight render harness (the happy-dom precedent exists in wms-fe) would close this class *(12-8)*
- **Excursion-capture prefill biases toward the empty-bin refusal** *(12-8)* — the putaway screen pre-fills the capture with the putaway TARGET bin, which typically has no on-hand stock; the server refuses an empty bin at replay (op dropped, summary line). The useful prefill (the putaway source / Receiving bin) is not in the snapshot; the field is re-scannable, so the operator can correct it
- **A system-owned prefill bin is dropped silently in excursion capture** — the fresh-draft fallback shows an empty bin field with no explanation *(12-8, cosmetic)*
- **No device-arm e2e for a secure-class bin or a badged accountant on `POST /excursions`** — the arms run session-agnostic code and the web suite covers them; only the device path's in-tx role read is exercised (via the operator badge-in) *(12-8)*

Closed by 12-8: the `uomPrecision` gap (stale since 10-6 — the field ships and is consumed end to end; both PENDING entries predated it), the replay scan-loss entry (stale — `replay-gate.ts` landed in 10.6), and the device putaway pre-check's missing bulk-asset arm (12-4 defer — the steering arm is in, both directions).

## wms-fe

- **No component tests for story 4-2b's own screen.** The infrastructure now exists (happy-dom + a hand-rolled render helper); 4-2b predates it, so its screen is a backfill *(4-2b/4-2c)*
- **The at-risk countdown's 30-second refresh is pinned by no test** — delete the interval and the amber chip freezes, with nothing failing. Needs timer control the suite uses nowhere yet *(4-2c review)*
- **Capability mirror is hand-maintained** — the CI guard catches drift between the lists, but not a role outside them *(epic-1 item 4, epic-2 a12)*
- **The location-type mirror is hand-kept with local pins only** *(12-4)* — `BIN_TYPES`/`BULK_ASSET_TYPES`/`GRID_TYPES` and `MAX_BIN_WEIGHT_GRAMS` in `zone-bin-setup.tsx` mirror the BE vocabulary and cap by hand; a BE-side change fails only at runtime. Each mirror carries its own local pin (the component test), but no cross-repo parity checker exists — deferred beside the five-place reason-enum parity (see wms-mobile's mirrors; 12-7's admin surface reshapes this file anyway)
- **The bin saved-banner component test asserts against an echo stub** *(12-7 triage defer)* — the PATCH stub echoes the request, so the test cannot distinguish the client's draft from the server's response as the source of the re-rendered value. Test-quality refinement, not a behavioural gap (the refusal arm is separately pinned)
- **The `/conflicts` queue-switcher component has no test** *(12-7 triage defer)* — a trivial switcher between two fully-tested queues; pinned only transitively

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
| **Real carrier transports** (labels, rates, tracking) | The sandbox and the typed DIRECT 501 stand in for all three adapter arms (4-6c/4-6d); real carriers need the timeout guard and the adapter call pulled out of the held transaction (the 4-6c defers), carrier error shaping (the uncapped refusal-detail defer), and credential/address validation per carrier. Tracked in `deferred-work.md` |
| **Retryable inline label error** (Outbound surface) | ~~Labels live in 4-6c, which is backlog~~ **labels shipped in 4-6c** — the strip's failed-read arms carry Retry (4-6c/4-6d); what remains is the real-transport retry semantics, not the UI |
| **Subscription billing** | No epic covers it, and PRD open question 4 on the pricing axis is unresolved. **The product cannot charge anyone for itself** |
| **Production operations** | The architecture spine defers IaC, CI/CD shape, dashboards and on-call. Not a feature gap — a can't-run-a-SaaS gap |
| **Customer data onboarding** | Catalog import exists; opening stock balances and migration off an incumbent system appear nowhere |

---

## How to use this

1. **Before speccing a story**, read your module's section. A listed item with the fix already diagnosed is usually cheaper to fold in than to schedule separately.
2. **When a review defers something**, it lands in `deferred-work.md`, which is the authority. This file is a **hand-written digest** of it — no generator exists. When the two disagree, `deferred-work.md` wins; fix this file rather than the other way round.
3. **Epic retrospectives** are where open action items get claimed into a story or explicitly closed. *"Every open retro item claimed into a story spec or explicitly closed at the next epic boundary"* is itself an open process commitment *(epic-3 retro a11)*.
