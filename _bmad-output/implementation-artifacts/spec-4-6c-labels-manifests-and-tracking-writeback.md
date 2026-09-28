---
title: 'Story 4.6c: Labels, manifests and tracking writeback'
type: 'feature'
created: '2026-09-28'
status: 'done'
route: 'dispatch'
review_loop_iteration: 0
baseline_commit: '62458e2' # wms-be main (wms-fe main: 1827b70)
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

**Problem:** FR-17's carrier arc shipped in three pieces — dispatch (4-6, with free-text `carrierName`/`trackingNumber` explicitly left as the migration target) and the carrier substrate (4-6b: adapter registry, credential vault, a facade whose `openCredentialForAdapterUse`/`resolveConnection` still have zero callers). Labels, manifests and tracking do not exist anywhere in the repo, and the epic's "retryable inline label error" UX state has been BLOCKED on 4-6c since 4-2d. A packed order cannot ship through a configured carrier.

**Approach:** The label → dispatch → manifest ship path: outbound module gains `shipments` and `manifests` (one labelled shipment per order; a manifest closes labelled shipments for one carrier connection), two new commands plus read-back routes, and `dispatch` auto-carries an existing shipment's adapter-issued tracking number. The carriers module grows the port's first real arm — `label()` behind `CarriersFacade` — with a deterministic in-process `sandbox` carrier so the whole path is exercisable; the three DIRECT carriers answer label requests with a typed, verbatim, retryable `carrier-transport-unconfigured` refusal until their real HTTP integrations land. The Outbound web surface gains the label step and manifest section, including the epic's retryable inline label-failure state. Tracking writeback is the outbox event the channel consumer (Epic 7) will subscribe to.

**Decided (technical, from investigation):**
- **Label generation is synchronous in the command** — the operator waits (p95 ≤ 5 s is NFR-6 for real integrations; the sandbox is instant). On adapter failure nothing is written and the order stays `ready_to_dispatch`; retry is a fresh submit. This is the UX-DR19 "retryable error inline; dispatch state unchanged" contract, not an outbox-async flow.
- **No new ledger event.** A label and a manifest are documents, not quantity movements — ledger discipline (AD-1) stays untouched; the shipment row, the outbox events (`shipment.label-created`, `manifest.created`) and audit rows are the records. Dispatch's per-line `dispatch.dispatched` events are unchanged.
- **`shipments.weight_grams`/`dimensions_mm` become durable columns**, taken from the label request (optional, same bounds as pack) — the pack measurements have lived only in `ledger_events.reference_doc` jsonb with no read path; the label is the first consumer that needs them on a row.
- **The tenant-predicate pin on `openCredentialForAdapterUse` lands BEFORE the label path uses it** (PENDING.md:87, carriers.md:122) — the e2e asserting a foreign tenant cannot open another tenant's credential through the label path ships in the same story as the first caller, not after.

**Decided (2026-09-28, human):**
- **The sandbox carrier stands in for the real transports.** A fourth registry entry `sandbox` with a deterministic in-process label arm makes the whole flow real end-to-end; the three DIRECT carriers grow the port arm but answer with a typed, verbatim `carrier-transport-unconfigured` refusal. The `envelope.ts`/`LoggingEventBus` stand-in precedent; real transports decide later with real API docs (with 4-6d or later).
- **Dispatch auto-stamps an existing labelled shipment's carrier/tracking** into its snapshot and reference docs when the caller sends no free text; free text still accepted (manual courier) and wins when given.
- **The label step and manifest section extend the Pack & Dispatch surface** — the label step rides the row expansion beside pack/dispatch, the manifest section below.
- **Keep the full spec** (~2,900 tokens vs the 1,600 guideline) — labels and manifests share the migration, the connection model and the surface; a split costs a second spec + review cycle for little isolation benefit.

## Boundaries & Constraints

**Always:**
- **Outbound imports `CarriersFacade` and nothing else from carriers** (carriers.md:304) — the facade-only import the architecture guard already allows; no credential plaintext, no sealed blob, no registry internals may cross into outbound.
- New commands follow the landmark order (permission → replay → row lock → guards → writes → outbox → audit → key), carry `Idempotency-Key` with payload-hash replay, re-read the member role at entry, and run in one `withTenantTransaction`.
- Every order-status guard stays an allow-list; the label command accepts exactly `ready_to_dispatch` and dispatch keeps its existing guards.
- Label failure arms render verbatim in the web surface (`carrier-transport-unconfigured`, key-unavailable 503); 409 state refusals verbatim.
- Migration 0042 follows the hand-written conventions: journal entry + snapshot, RLS + CHECKs in migration SQL only, no FKs, keyset indexes, partial unique index for one-labelled-shipment-per-order.
- The new `labels.execute` capability (Owner + Ops Manager + Operator, mirroring `pack.execute`) gates label and manifest commands; the FE capability mirror gains it.
- The web surface reuses the 4-2b/4-2c/4-2d machinery (`ResourceState`, shell classes, `ReadFailure`, `OUTBOUND_CHANGED`, verbatim-refusal mappers, idempotency-key conventions) and gates affordances on `roleHasCapability` — hidden, not disabled.

**Never:**
- **No real carrier HTTP calls.** No HTTP client dependency, no timeout/retry/circuit-breaker policy, no network in tests. Real Delhivery/Blue Dart/Ecom label transports are a later decision (with 4-6d's rating or later); their refusal is a first-class rendered arm, not an error swallowed.
- No carrier-side tracking-event polling, no carrier webhook receiver, no channel sync — the outbox event is the writeback; its consumer is Epic 7 (no channels module exists).
- No rating (4-6d), no change to dispatch's free-text carrier fields beyond auto-stamping, no new order status, no change to pack/pick.
- No un-manifest, no label regeneration once labelled (409), no ledger schema change.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Label happy | `ready_to_dispatch` order, sandbox connection | `201`; shipment row `labelled` with adapter tracking + doc ref; outbox `shipment.label-created`; audit | N/A |
| Label unconfigured carrier | `ready_to_dispatch` order, DIRECT carrier connection | nothing written, order stays `ready_to_dispatch` | `501 carrier-transport-unconfigured`, verbatim, retryable inline |
| Label wrong state | order `accepted`/`dispatched`/`cancelled` | nothing written | `409` naming the status, verbatim |
| Label already labelled | order has a `labelled` shipment | nothing written | `409`, verbatim |
| Label replay | same key after success | snapshot re-served byte-for-byte | changed body, same key → `422 idempotency-key-reuse` |
| Manifest happy | ≥1 labelled shipment, one connection | `201`; manifest row; shipments → `manifested` | N/A |
| Manifest mixed carriers / foreign shipment / already manifested | body names shipments not in that state | nothing written | `409` naming the offender, verbatim |
| Dispatch auto-stamp | labelled shipment exists, no free text | `201`; snapshot + reference docs carry shipment's tracking/carrier | N/A |
| Dispatch free-text override | free text given alongside a shipment | free text used as-is; shipment untouched | N/A |
| Key unavailable | `CARRIER_ENCRYPTION_KEY` unset at label | nothing written | `503 carrier-encryption-unavailable` |
| Role denied | role lacks `labels.execute` | affordance absent (web) / `403` (API) | N/A |
| Read failure | shipment/manifest read fails | failed arm + Retry, never blank | `ReadFailure` |

</frozen-after-approval>

## Code Map

- `workspace/core/backend/wms-be/src/modules/outbound/dispatch.command.ts:42-60,178-181` -- the free-text carrier fields (`MAX_*_LENGTH=200`, `assertText`, blank→null normalization) and the reference-doc home (`:329-355`) the auto-stamp extends; guards order `:205-262`.
- `workspace/core/backend/wms-be/src/modules/carriers/carriers.facade.ts:134-236` -- `listConnections`/`resolveConnection`/`openCredentialForAdapterUse` — the seam the label path grows from; `withCarrierKey` 503 remapping precedent inside.
- `workspace/core/backend/wms-be/src/modules/carriers/carrier-registry.ts:30-135` -- `CarrierAdapter` shape, `registerCarrierAdapter`, the three DIRECT registrations; the port arm grows here.
- `workspace/core/backend/wms-be/src/modules/carriers/carrier-credentials.ts` -- sole envelope/key owner; `validateCredential` bounds (`MAX_CREDENTIAL_VALUE_LENGTH=512`).
- `workspace/core/backend/wms-be/src/shared/events/outbox.ts:20-32` -- backoff constants; event names to add beside `carrier.connected` arms (`carrier.command.ts:472-490` audit shape).
- `workspace/core/backend/wms-be/src/modules/tenancy/permissions.ts:10,124-157` -- `CAPABILITIES` + `ROLE_CAPABILITIES`; `labels.execute` mirrors `pack.execute` grants.
- `workspace/core/backend/wms-be/src/api/outbound.controller.ts:163-313` -- route + decorator-stack precedent (`assertOwnTenant` → `assertUuidParam` → key → command → DTO); DTO home `outbound.dto.ts` (`DispatchOrderDto` `:1155-1179`).
- `workspace/core/backend/wms-be/src/shared/db/schema.ts:1828-2041,2294-2326` -- outbound table shapes + `carrier_connections`; migration `drizzle/` latest is **0041** → next **0042** (journal + hand-written snapshot per 0025's precedent).
- `workspace/core/backend/wms-be/test/architecture.spec.ts:583-630` -- the carriers facade-only import guard (comment already names 4-6c as first consumer); `:567-581` table-ownership scans a new label-table writer must satisfy.
- `workspace/core/backend/wms-be/test/dispatch.spec.ts:540-568` -- the drift-guard pattern (literal tuples, `pg_get_constraintdef`, capability membership) to extend.
- `workspace/core/frontend/wms-fe/src/lib/outbound-pack-dispatch.ts:37-54,238-256,424` -- pipeline scope, `parseDispatchDraft`, `DISPATCH_TERMINAL_WARNING`, `dispatchReason` — the lib a label step extends.
- `workspace/core/frontend/wms-fe/src/components/outbound/pack-dispatch.tsx:601-720` -- `DispatchSection` (per-confirmation ulid key, field-edit reset `:635`) and the `:601-609` "4-6c structures them" comment — the surface the label step rides.
- `workspace/core/frontend/wms-fe/src/lib/api/client.ts:259-349` -- wrapper + `Idempotency-Key` header precedent for `fetchApiLabelOrder`/`fetchApiCreateManifest`.
- `workspace/core/frontend/wms-fe/src/lib/users.ts:15,74-80` -- capability mirror; `carrier.manage` comment names the pattern.
- Read-only: `docs/design/modules/carriers.md:7,122,148,304` (port-growth + tenant-predicate obligations); `PENDING.md:37,87,145-146`.

## Tasks & Acceptance

**Execution:**
- [x] `wms-be drizzle/0042_shipments_manifests.sql` + `_journal.json` + `0042_snapshot.json` -- `shipments` (unique labelled-shipment-per-order, keyset, CHECK `status ∈ {labelled, manifested}`, RLS) and `manifests` (keyset, RLS)
- [x] `wms-be src/shared/db/schema.ts` -- the two tables + `$inferSelect`, doc-commented
- [x] `wms-be src/modules/carriers/carrier-registry.ts` + new label-port file -- the port's `label` arm (credential + request → tracking + doc ref), the `sandbox` adapter's deterministic implementation, the DIRECT carriers' typed unconfigured refusal
- [x] `wms-be src/modules/carriers/carriers.facade.ts` -- `label(tenantId, connectionId, req)`: resolve connection → open credential (tenant-predicate e2e pinned first) → adapter arm → result; never persist or log the credential
- [x] `wms-be src/modules/outbound/shipment.command.ts` -- `createShipmentLabel` command (guards, adapter call via facade, shipment row, outbox, audit, key) + `manifest.command.ts` -- `createManifest` (validates the shipment set, manifest row, shipment flips)
- [x] `wms-be src/modules/outbound/dispatch.command.ts` -- auto-stamp the order's labelled shipment carrier/tracking when free text absent
- [x] `wms-be src/modules/tenancy/permissions.ts` -- `labels.execute`
- [x] `wms-be src/api/outbound.controller.ts` + `outbound.dto.ts` -- `POST .../orders/{orderId}/label`, `POST .../warehouses/{wid}/outbound/manifests`, `GET .../orders/{orderId}/shipment`, `GET .../warehouses/{wid}/outbound/manifests`; OpenAPI arms
- [x] `wms-be test/label.spec.ts` -- the matrix e2e: sandbox happy path, unconfigured verbatim refusal, state guards, replay, tenant-predicate probe, RLS, drift guard
- [x] `wms-be test/dispatch.spec.ts` + `test/architecture.spec.ts` -- auto-stamp assertions; the outbound→carriers facade-only import now exercised by real code
- [x] `wms-be bun run openapi:export` + `wms-fe bun run api:generate` + `wms-fe src/lib/users.ts` mirror
- [x] `wms-fe src/lib/api/client.ts` -- `fetchApiLabelOrder` / `fetchApiCreateManifest` / shipment + manifest read wrappers
- [x] `wms-fe src/lib/outbound-pack-dispatch.ts` -- label/manifest draft parsing, outcome + reason mappers (verbatim arms), tracking labels
- [x] `wms-fe src/components/outbound/pack-dispatch.tsx` -- the label step in the row expansion + manifest section, retryable inline label-failure state, per the answered Open Question 3
- [x] `wms-fe` component/lib tests -- matrix rows, idempotency conventions, retryable-failure rendering

**Acceptance Criteria:**
- Given a `ready_to_dispatch` order on a sandbox connection, when label generates, then a `labelled` shipment with the adapter tracking number exists and no order status changed.
- Given the same order on a DIRECT carrier connection, when label generates, then the refusal names `carrier-transport-unconfigured` verbatim, nothing is written, and the retry affordance remains.
- Given a labelled order, when it dispatches without free text, then the dispatch snapshot and its reference docs carry the shipment's carrier/tracking.
- Given a foreign tenant's connection id, when any label path resolves the credential, then the read yields nothing (`404`-shaped), asserted by the RLS/tenant probe.
- Given a role without `labels.execute`, when the surface renders, then label and manifest affordances are absent from the DOM.

## Implementation Notes

## Spec Change Log

## Review Triage Log

**Loop 1 — three layers (blind hunter 14, edge-case 10, verification-gap 5 + 3). 32 findings, each verified first-hand at its
cited location before a verdict: 10 distinct fixes (13 rows) patched, 9 distinct hardening items (12 rows) deferred, 7 refuted.
No `intent_gap` and no `bad_spec` — no loopback.**

| # | Finding | Layer | Verdict | Evidence |
|---|---------|-------|---------|----------|
| 1 | The 0042 shipments dimension CHECK bound (1000000) contradicts the migration's own comment and pack's MAX_DIMENSION_MM (100_000), so the DB backstop is 10× looser than the command gate it claims to mirror | blind | **low — patch** | Confirmed: `drizzle/0042_shipments_manifests.sql:67-72` comment says 100_000, CHECK enforces `<= 1000000`; `pack.command.ts:72-74` gates at 100_000. Commands are the only writers today, so no bad row is reachable — but the backstop's stated purpose is to survive a non-command write. Edit the unshipped migration in place |
| 2 | The sandbox adapter registers unconditionally, so every tenant sees "Sandbox Express" in the carriers catalogue and connection picker with no flag distinguishing hash-issued tracking from a real carrier's | blind | **maybe-false — defer** | Verified at `carrier-registry.ts:174` — but the frozen spec's Design Notes deliberately choose the sandbox as the documented stand-in class ("the same class of documented stand-in as envelope.ts"). Whether it is env-gated for production is a product decision for 4-6d's design, where real credentials arrive |
| 3 | The adapter label call sits inside the held transaction while the order row is locked | blind | **maybe-false — defer** | Verified at `shipment.command.ts:248`. Safe for the in-process sandbox arm (no I/O); real HTTP transports in 4-6d must not inherit a network round-trip inside a lock-holding transaction — the exact hazard the pool-nesting comments name. Carried into 4-6d's design |
| 4 | `CarriersFacade.label()` and its resolve/open-credential chain are dead code, and the standalone method is precisely the "facade method that opens its own transaction" the module comments warn never to call inside a held one | blind | **low — patch** | Confirmed: `carriers.facade.ts:249` has no callers in the tree; the command uses the InTx passthroughs (`shipment.command.ts:218,233`). Delete the dead method, fix the comment that claims the label command uses it |
| 5 | The manifest command never checks the shipment's order status — a `labelled` shipment of a dispatched order still closes onto a manifest, and the FE-narrower divergence is unacknowledged | blind | **false** | The frozen matrix's manifest guard list is exactly the four shipped arms (foreign tenant, another warehouse, not labelled, span connections) — the implementation matches the contract. The cancelled half is unreachable: cancel is refused beyond `accepted` (pre-pick), so an order with a packed shipment cannot be cancelled. The dispatch-then-manifest ordering is covered by the frozen dispatch matrix |
| 6 | Auto-stamp silently disappears after manifesting — dispatch reads only `status = 'labelled'`, so a manifested shipment's carrier/tracking is not stamped on a later dispatch | blind | **false** | Matches the frozen spec's literal wording: line 35 says "auto-stamps an existing **labelled** shipment's carrier/tracking", and the matrix arm (line 67) fires on "labelled shipment exists, no free text". Once the shipment is manifested, that arm's premise is false — no stamp is the specified behavior, and #28 pins it with a test so the decision is visible |
| 7 | `createdBy`/`labelledBy` render as raw uuids ("by/labelled by"); the FE fixtures hide it by using email-like strings | blind | **low — defer** | Confirmed: both are bare uuid columns with no user join in the BE, and real renders will show uuid strings. But this is the same already-shipped 4-2d pattern (dispatch/pack actor fields render the same way); user-name resolution is a system-wide concern, not this story's scope |
| 8 | No manifest detail read exists — `shipments_manifest_id_idx` was built for a detail read that never shipped, so an operator cannot verify what a hand-over document contains | blind | **false** | The spec's Boundaries deliberately scope exactly four new routes and state the list-shipments route is not in scope; the index was spec'd with the table to serve the future detail read. Not an implementation defect |
| 9 | `useLabelledShipments` issues one GET per `ready_to_dispatch` order per render (25+ at default page size), ungated by `canLabel`, refiring on every `OUTBOUND_CHANGED_EVENT` | blind | **low — defer** | Verified. Correctness holds (`Promise.allSettled` absorbs failures; reads are cheap point lookups), and the per-order-read choice is the spec's stated rationale for not shipping a list-shipments route. Batch route/gating is follow-up work |
| 10 | The POST-manifest 201 body carries `shipmentIds` (controller spread) while `ManifestDto` does not declare it — POST and GET list shapes disagree for the same entity | blind | **low — patch** | Confirmed at `outbound.controller.ts:479` (`{ manifest: { ...snapshot.manifest } }`); the snapshot legitimately carries the closed set for replay. Add `shipmentIds` to ManifestDto so the declared face matches |
| 11 | No API-surface / module-doc / interface-contract updates accompany the change | blind | **false** | The four routes and contracts are described in the frozen spec; the meta-repo docs (API-SURFACE.md, module docs, interface contracts) are step-05 duties of this workflow and were never tasks on the branch — they land in the meta commit |
| 12 | The story key promises "tracking writeback" but the diff ships label + manifest + auto-stamp only | blind | **false** | The frozen spec defines writeback as the carrier→system direction deferred to Epic 7's outbox consumer; the diff ships the system→ledger half (outbox events `shipment.label-created`/`manifest.created` + audit rows), which is what the spec's Intent and Boundaries state |
| 13 | The label audit event names the order (`targetType: 'order'`) while the manifest command audits its own created entity | blind | **false** | `targetType: 'order'` with `targetId: order.id` is the pack (`pack.command.ts:701`) and dispatch (`dispatch.command.ts:482`) precedent for order-scoped actions; the manifest audits `manifest` because the manifest is the batch document. Consistent with the module's own precedent |
| 14 | The manifests pager is one-way: no UI path back to the newest page once a viewer pages older, and `OUTBOUND_CHANGED` refetches re-run against the stale active cursor so a new manifest is invisible | blind | **low — defer** | Verified at `use-outbound-labels.ts:207-259`. Real UX gap for an operator who pages deep; the list is page-scoped and short in practice. Head-reset on refetch is a UX hardening change, not this story's contract |
| 15 | Auto-stamped carrier/tracking bypass the MAX_*_LENGTH `assertText` checks free text is subject to | edge | **maybe-false — defer** | Verified: stamped values are consumed at `dispatch.command.ts:368-369/:460-461` with no length check, while free text is checked at `:178-182`. Unreachable today (the sandbox adapter issues bounded deterministic values) but a real-carrier adapter in 4-6d could emit an over-long tracking — clamp at stamp time then |
| 16 | Shipment is `manifested`: the `status='labelled'` filter skips it, so dispatch records neither arm | edge | **false — dup of 6** | Same code point (`dispatch.command.ts:284`); same refutation — the frozen spec's arm premise is "labelled shipment exists" |
| 17 | The auto-stamp shipment read is unlocked; a concurrent manifest can flip it to `manifested` between read and ledger append, double-recording the hand-over | edge | **maybe-false — defer** | Verified shape: `dispatch.command.ts:275-288` reads unlocked. Real race, but narrow (dispatch and manifest on the same order concurrently, different capabilities) and harmless-today with the sandbox. Lock the read (`for('update')`) in 4-6d when real transports land |
| 18 | The adapter arm hangs while the transaction holds the order lock and pool connection | edge | **maybe-false — defer** | Duplicate of #3's transaction shape; the timeout guard (`Promise.race` with a reject-after) is the 4-6d design item |
| 19 | Same Idempotency-Key replayed with a body that fails `normalizeShipmentIds` 400s instead of replaying, unlike shipment.command's deliberate validation-after-replay | edge | **maybe-false — defer** | Confirmed: `manifest.command.ts:111` normalizes before the tx/replay, while `shipment.command.ts:177-180` validates after replay ("validation-after-replay position"). Structurally required today — the sorted collapsed set IS the payload-hash input, unlike label's raw measurements. Harm needs a direct API caller retrying a committed manifest with a malformed body; the FE reuses its key only with the unchanged body. Document or align in a consistency pass |
| 20 | Duplicate of #1 (same CHECK hunk, edge lens) | edge | **low — patch (dup)** | Same root cause, same fix |
| 21 | `parseManifestDraft([...selected])` POSTs the whole selection including ids outside the visible group after a background refetch removes them | edge | **low — patch** | Verified at `pack-dispatch.tsx:1111`: the body is built from `selected` while the visible list is `group`; a stale id POSTs and the backend's deterministic 409 names an id the user cannot untick. Build the body from the visible filtered selection |
| 22 | `shipment = labelled ?? read` prefers the stale local labelled snapshot over a fresher read-back reporting the shipment manifested — the panel renders "Dispatch stamps this carrier" for a closed shipment | edge | **low — patch** | Verified at `pack-dispatch.tsx:271-273`. One-line precedence swap; the read-back fallback keeps current behavior when the read fails |
| 23 | `useCarrierConnections` walks keyset pages in an unbounded `for(;;)` — a server that keeps returning a non-null cursor hangs the picker indefinitely | edge | **maybe-false — defer** | Verified at `use-outbound-labels.ts:74-86`. Backend keyset cursors terminate by construction (bounded table, monotonic key), so the loop is unreachable today; a page cap is defensive hardening, pre-existing in shape across the repo's walkers |
| 24 | Duplicate of #9 (the fan-out, edge lens) | edge | **low — defer (dup)** | Same root cause |
| 25 | The manifest "shipments in another warehouse" 409 arm has no test — deleting the `foreignWarehouse` filter passes the whole suite | v-gap | **medium — patch** | Pre-verified by mutation: the foreign-TENANT fixture reads as missing through RLS and exercises the missing arm, so the wrong-warehouse enumeration is the only untested all-or-nothing arm. Add a second-warehouse fixture and one refusal assertion |
| 26 | The label route's 503 `carrier-credential-unreadable` arm is untested on its only live path | v-gap | **medium — patch** | Pre-verified: `label.spec.ts:782-800` covers only `carrier-encryption-unavailable`; no test drives an unopenable blob through the label command. An operator whose key was rotated after sealing gets a raw 500 instead of the documented "rotate the connection" 503 |
| 27 | The manifest over-500 cap is asserted nowhere (`MAX_MANIFEST_SHIPMENTS` has no test hits) | v-gap | **low — patch** | Pre-verified: the malformed-set test covers empty/non-uuid only; removing both caps lets a 501-element set proceed. One-array extension of the existing test |
| 28 | Dispatch auto-stamp's exclusion of manifested shipments is untested | v-gap | **medium — patch** | Pre-verified: both auto-stamp tests label-then-dispatch, so the filter is never observed from the other side. Pinning the exclusion makes #6's specified decision visible in the suite |
| 29 | The FE manifests pagination path never renders in any test (every stub answers `nextCursor: null`) | v-gap | **medium — patch** | Pre-verified: breaking `onCursor` or inverting the staleness compare fails nothing. Mirror the existing orders pager test |
| 30 | `CarriersFacade.label()` dead (v-gap lens) | v-gap | **low — patch (dup)** | Same root cause as #4 |
| 31 | Unbounded keyset walk in `useCarrierConnections` (v-gap lens) | v-gap | **maybe-false — defer (dup)** | Same root cause as #23 |
| 32 | The manifest section's client-side `mixed` guard is dead code (`group` is pre-filtered to one connection, so its `Set.size > 1` check can never fire) | v-gap | **low — patch** | Verified at `pack-dispatch.tsx:1104-1109`; folds into #21's change (the body comes from the filtered selection, the dead guard goes away) |

**Routes.** `patch` — 10 distinct fixes via the implementation agent (rows 1, 4, 10, 21 + 32, 22, 25, 26, 27, 28, 29, 30). `defer` — 9
distinct items appended to `deferred-work.md` (rows 2, 3, 7, 9, 14, 15, 17, 18, 19, 23 + 31): five are 4-6d design carries (sandbox
gate, held-tx adapter call, label-arm timeout, stamped-value length checks, auto-stamp lock), four are pre-existing-shape
hardening (uuid rendering, N+1 fan-out, pager reset, page-cap walks) plus the normalize/replay consistency note (row 19).

## Design Notes

**Why synchronous, and why the sandbox is the stand-in.** The label is a wait-for-it station action, not an integration effect: the operator needs the tracking number before dispatch, and UX-DR19's inline retryable error only makes sense if the failure answers the same request. AD-7's outbox still applies to what the label *emits* (the channel writeback event rides `shipment.label-created`). The sandbox carrier is the same class of documented stand-in as `envelope.ts` (KMS) and `LoggingEventBus` (real bus): the domain, state machine, retry and surfaces are fully real; the transport is pluggable and its real implementations arrive with real API credentials.

**Why the tracking lands on dispatch's reference docs.** The dispatch ledger event is the durable shipment record this system already has (4-6's Design Notes); leaving the adapter tracking only on `shipments` would split "what shipped" across two homes and re-create the "no read-back" gap one table over. Auto-stamping keeps free text working for manual couriers — the 4-2d surface needs no migration.

## Verification

**Commands:**
- `cd workspace/core/backend/wms-be && bun run test && bun run lint && bun run typecheck && bun run build && bun run db:migrate && bun run db:verify` -- full suite on a freshly reset DB (this story adds a module boundary crossing; `architecture.spec.ts` is the guard)
- `cd workspace/core/backend/wms-be && bun run db:generate` -- expected: no new migration emitted
- `cd workspace/core/frontend/wms-fe && bun run check:capability-mirror && bun run test && bun run lint && bun run typecheck && bun run build` -- mirror + suite green after regen