---
title: 'Story 4.6d: Carrier rate shopping'
type: 'feature'
created: '2026-09-28'
status: 'ready-for-dev'
route: 'dispatch'
review_loop_iteration: 0
baseline_commit: '88b6f35' # wms-be main (wms-fe main: b2919a7)
context:
  - '_bmad-output/implementation-artifacts/epic-4-context.md'
  - 'docs/design/SYSTEM-DESIGN.md'
  - 'docs/design/IMPLEMENTATION-GUIDE.md'
  - 'docs/design/modules/outbound.md'
  - 'docs/design/modules/carriers.md'
  - 'docs/design/frontend/SYSTEM-DESIGN.md'
  - 'docs/design/frontend/IMPLEMENTATION-GUIDE.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** FR-17's rating surface is the last unshipped piece of the carrier arc's first slice — 4-6b built the registry and credential vault, 4-6c grew the port's `label()` arm; `rate()` is deliberately undeclared ("the port grows those arms in the story that consumes them" — carriers.md:7) and no code can price a shipment. An operator choosing a carrier at the label station rates blind.

**Approach:** The adapter port grows a `rate()` arm beside `label()` — the sandbox carrier rates deterministically in-process, the three DIRECT carriers answer the same typed verbatim 501 `carrier-transport-unconfigured` refusal. Outbound gains one read route that aggregates the order's shippable weight from its order lines × the SKU catalog's physical attributes and quotes every live carrier connection: one list of quoted or refused items. The Pack & Dispatch surface's label station gains a rates strip beside the connection picker.

**Decided (technical, from investigation):**
- **Rating is a read.** No state change — no `Idempotency-Key`, no outbox event, no ledger event, no audit row, no new capability (reads are never capability-gated — API-SURFACE.md:8-12); the FE strip lives inside the already-`canLabel`-gated label form.
- **Quotes are per live connection.** The tenant's carrier connections are the configured carriers; a not-connected carrier has no credential to rate through and is not listed. A DIRECT-carrier connection yields a refused item (verbatim 501); the sandbox yields a deterministic quote.
- **Weight comes from the order itself:** Σ(qty_milli ÷ 1000 × sku.weight_grams) over the order's lines, kit component lines counted and kit parent lines excluded (physical goods live on components — AD-19). Dimensions do not feed v1 quotes (dimensional-weight math is carrier-specific; it arrives with the real carriers).
- **The read runs in one `withTenantTransaction` without row locks** (read-only; the InTx credential passthroughs need the tx handle). The real-transport carries — timeout guard, adapter call out of the held tx — ride the 4-6c defer unchanged.

**Decided (2026-09-28, human):**
- **Missing weights refuse the whole quote (409 naming the SKUs).** A quote without weight is a lie; the operator fixes the catalog and retries. Matching the manifest's offender-enumeration precedent.
- **Keep the full spec** (~2,300 tokens vs the 1,600 guideline) — one cohesive cross-layer change; a split costs a second spec + review cycle for little isolation benefit.

## Boundaries & Constraints

**Always:**
- The carriers module grows only: the `rate` arm type beside `CarrierLabelArm` in `carrier-label-port.ts`, one `sandboxRateArm`/`unconfiguredRateArm` pair, rate-arm wiring in the four `registerCarrierAdapter` entries, and one free-function glue (`rateThroughAdapter`) beside `labelThroughAdapter` in `carriers.facade.ts`. The adapter descriptor stays declarative ("Nothing else" — carriers.md:170).
- Outbound imports `CarriersFacade` + the rate glue from `carriers.facade` and nothing else; the architecture guard's allowed-import list keeps its exact shape.
- The order-status guard is an allow-list: exactly `ready_to_dispatch` (mirroring the label command).
- Money follows AD-9: integer paise. The quote shape is `{ amountPaise: number }`.
- The FE reuses the 4-2d/4-6c machinery (`ResourceState`, verbatim-refusal mappers, `OUTBOUND_CHANGED` refetch, `bun run api:generate` against the backend's exported openapi) and gates nothing new.

**Never:**
- No real carrier HTTP calls — no HTTP client, no timeout/retry/circuit-breaker policy, no network in tests; the DIRECT refusal is a first-class rendered arm.
- No rating persistence (no quote table, no rate history, no rate log) — quotes are recomputed per request.
- No rating of not-connected carriers, no catalog-wide rate matrix, no rate-comparison endpoint beyond the one order.
- No tracking writeback, no webhook receiver, no channel sync (Epic 7); no change to label, pack or dispatch.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Rate happy | `ready_to_dispatch` order, live sandbox connection, every line's SKU weighted | `200`; one item per live connection — sandbox items carry the deterministic `{amountPaise}`, DIRECT items carry the verbatim 501 refusal; items sorted by carrierCode | N/A |
| Missing weight | ≥ 1 order line whose SKU has no `weight_grams` | `409` naming the unweighted SKUs (capped sample, the `namedSample` rule); nothing quoted | deterministic; retryable after weights are set |
| Order not ratable | order in any state other than `ready_to_dispatch`, or nonexistent, or another tenant's | `409` / `404` verbatim | refusal rendered verbatim in FE |
| No connections | tenant has zero live carrier connections | `200` with an empty rates list | N/A |

</frozen-after-approval>

## Code Map

- `wms-be src/modules/carriers/carrier-label-port.ts` — declares `CarrierLabelArm` + request/result shapes and both arms (`sandboxLabelArm` :79-94, `unconfiguredLabelArm` :66-70); the rate arm type + arms land here beside them.
- `wms-be src/modules/carriers/carrier-registry.ts` — import-time registry, four entries (:98, :118, :144, :174); rate-arm wiring rides the existing `registerCarrierAdapter` calls; Shiprocket exclusion note :90-96.
- `wms-be src/modules/carriers/carriers.facade.ts` — `labelThroughAdapter` free function (:53-63) is the glue pattern for `rateThroughAdapter`; the InTx passthroughs (:196, :214) are the credential seam the rate read reuses.
- `wms-be src/modules/outbound/shipment.command.ts:161+` — the label command is the closest precedent for a per-order carrier interaction (capability gating shape, facade imports at :16-17, validation-after-replay note :177-180).
- `wms-be src/modules/outbound/order.command.ts:568` + `schema.ts:1850-1856` — the destination address columns (pincode `/^\d{6}$/`), point-in-time at create; origin on `warehouses` :203-209.
- `wms-be schema.ts:456-462` (skus weight/dims/country, `MAX_SKU_*` in catalog/sku-attributes.ts), `schema.ts:1895-1928` (order_lines: `skuId`, `qty` in milli-units, `parentLineId` for kit components) — the aggregation inputs. Kit parent exclusion: verify the kit marker on order_lines and its read shape before writing the aggregate.
- `wms-be src/api/outbound.controller.ts:278+` — the label route is the route-shape precedent; rates ride beside it (read, `assertOwnTenant`, no capability).
- `wms-be src/api/carriers.controller.ts` + `outbound.facade.ts` — where the facade method lands (`outbound.facade` delegates to the rate service).
- `wms-be test/label.spec.ts` — fixtures to reuse: `testAddress()`, `connectSandbox()` (:524), the delhivery connection (:536), packed-order helper (:549); CARRIER_ENCRYPTION_KEY env pattern (:28).
- `wms-fe src/components/outbound/pack-dispatch.tsx:800-1041` — `LabelSection`; the rates strip sits between the connection select (:933-948) and the measurements fieldset.
- `wms-fe src/lib/use-outbound-labels.ts` — hook pattern (`useCarrierConnections` :41 keyset walk, `useOrderShipment` :107 404→null); `useOrderRates` lands beside them.
- `wms-fe src/lib/outbound-pack-dispatch.ts:597` — `labelReason` verbatim-mapper pattern for a `ratesReason`.
- `wms-fe src/lib/api/client.ts` + `src/lib/api/generated/` — wire function + regen (`bun run api:generate`).
- `wms-fe scripts/check-capability-mirror.ts` — must stay green (no capability change expected; re-run after regen).

## Tasks & Acceptance

**Execution:**
- [ ] `wms-be src/modules/carriers/carrier-label-port.ts` -- declare `CarrierRateArm` + `CarrierRateRequest {orderRef, originPincode, destinationPincode, weightGrams|null}` + `CarrierRateResult {amountPaise}`; implement `sandboxRateArm` (deterministic formula in Design Notes) and `unconfiguredRateArm` (the same typed 501) -- the port grows its second arm in the story that consumes it.
- [ ] `wms-be src/modules/carriers/carrier-registry.ts` -- wire the rate arm into all four `registerCarrierAdapter` entries -- every carrier answers rate requests, quoted or refused.
- [ ] `wms-be src/modules/carriers/carriers.facade.ts` -- add `rateThroughAdapter(carrierCode, credential, request)` beside `labelThroughAdapter` -- outbound's single glue seam, no registry internals.
- [ ] `wms-be src/modules/outbound/rate.service.ts` (new) -- the rate-shopping read: order + destination pincode, warehouse origin pincode, line×SKU weight aggregate (kit components counted, kit parents excluded), then per live connection: open credential in-tx and call the glue; DIRECT refusals and sandbox quotes each land as their item -- the module owns the order-side aggregation; carriers stays order-blind.
- [ ] `wms-be src/modules/outbound/outbound.facade.ts` + `src/api/outbound.controller.ts` + `outbound.dto.ts` -- `GET :tenantId/outbound/orders/:orderId/rates` read route + `OrderRatesDto`/`RateItemDto` (connectionId, carrierCode, carrierName, quote|refusal), `bun run openapi:export` -- the route is a read: `assertOwnTenant`, no Idempotency-Key, no capability.
- [ ] `wms-be test/rate.spec.ts` -- e2e per the matrix: deterministic sandbox quote from seeded weighted SKUs, DIRECT 501 item, missing-weight 409 naming SKUs, not-ready 409, no-connections 200-empty, foreign-tenant 404 -- every refused-closure arm pinned.
- [ ] `wms-fe src/lib/api/client.ts` (+ regen via `bun run api:generate`) -- `fetchApiGetOrderRates` -- typed wire function.
- [ ] `wms-fe src/lib/use-outbound-labels.ts` -- `useOrderRates(orderId)`: ResourceState read, OUTBOUND_CHANGED refetch, 404→null (no order) -- the read hook beside its siblings.
- [ ] `wms-fe src/lib/outbound-pack-dispatch.ts` -- `ratesReason` verbatim mapper (409/404 arms) -- refusal parity with label/manifest.
- [ ] `wms-fe src/components/outbound/pack-dispatch.tsx` -- rates strip inside `LabelSection` between the picker and the measurements fieldset: quoted items show the INR-formatted amount, DIRECT items show the verbatim refusal chip; read failure shows the `ReadFailure` retry arm -- the operator picks a carrier with prices in view.
- [ ] `wms-fe pack-dispatch.test.tsx` -- strip renders quotes + refusal + read-failure retry; hidden when `canLabel` is false -- matrix coverage.

**Acceptance Criteria:**
- Given a ready_to_dispatch order whose lines' SKUs all carry weights and one live sandbox connection, when the rates are read, then exactly one quoted item answers with the formula's deterministic amount in paise.
- Given the same order against a live delhivery connection, when the rates are read, then the item is the verbatim 501 `carrier-transport-unconfigured` refusal and nothing else about the order changes.
- Given any order whose SKU catalog rows lack `weight_grams`, when the rates are read, then a 409 names the unweighted SKUs and no quote is returned (per the Open Question answer).
- Given the same request twice, when compared, then the amounts are byte-identical (determinism) and no ledger, outbox, audit or idempotency row is written.

## Implementation Notes

## Spec Change Log

## Review Triage Log

## Design Notes

**Why the sandbox formula is a formula, not a hash.** A quote that operators compare must respond sensibly to its inputs — heavier must cost more — while staying deterministic. The sandbox arm:

```
digest = sha256(`sandbox-rate|{origin}|{destination}`)[0..4]
amountPaise = 2500 + 500 × ceil(weightGrams / 1000) + (digest as uint32 % 1500)
```

Base + per-kg + a pincode-pair jitter band, all integer paise, reproducible in tests by recomputation (the label arm's recompute-the-expected precedent, `label.spec.ts:655-667`).

**Why weight-only.** Dimensional weight divides length×width×height by a carrier-specific divisor — inventing a divisor before real carriers share theirs is the "shipped interface to unpick" mistake carriers.md:7 names. The rate request carries weight; dimensions ride the existing shipment columns when real carriers land.

## Verification

**Commands:**
- `cd workspace/core/backend/wms-be && bun run test && bun run lint && bun run typecheck && bun run build && bun run db:migrate && bun run db:verify` -- expected: suite green (no migration in this story; `db:verify` confirms the schema is untouched)
- `cd workspace/core/backend/wms-be && bun run openapi:export` -- expected: the rates route exported; `bun run db:generate` emits nothing
- `cd workspace/core/frontend/wms-fe && bun run check:capability-mirror && bun run api:generate && bun run test && bun run lint && bun run typecheck && bun run build` -- mirror green, suite green after regen