---
title: 'Portal ASN entry — a client user announces its own inbound shipment from the portal'
type: 'feature'
created: '2026-10-09'
status: 'done'
route: 'dispatch'
baseline_commit: 'b9c60d194af81b860138cb61618006b508e5e7ae'
review_loop_iteration: 0
context:
  - '_bmad-output/implementation-artifacts/epic-21-context.md'
  - '_bmad-output/specs/spec-3pl/SPEC.md'
  - '_bmad-output/specs/spec-3pl/architecture.md'
  - '_bmad-output/implementation-artifacts/spec-21-6-advance-shipment-notices.md'
  - '_bmad-output/implementation-artifacts/spec-21-7-client-portal.md'
  - 'docs/design/SYSTEM-DESIGN.md'
  - 'docs/design/IMPLEMENTATION-GUIDE.md'
  - 'docs/design/API-SURFACE.md'
  - 'docs/design/modules/inbound.md'
  - 'docs/design/modules/clients.md'
  - 'docs/design/modules/tenancy.md'
  - 'docs/design/modules/catalog.md'
  - 'docs/design/frontend/SYSTEM-DESIGN.md'
  - 'docs/design/frontend/IMPLEMENTATION-GUIDE.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** CAP-9 says "a client can announce an inbound shipment before it arrives", but the portal is read-only (21-7 decision 2). Today a brand emails the 3PL, who re-keys the ASN. Three things are missing:
- the ASN command refuses any user with a client (`asnPortalRefused`);
- the portal has no SKU list;
- the portal has no warehouse list.

**Approach:**
- **The portal's first write**, `POST portal/inbound/asns`. It is a separate portal command on 21-6's ASN tables.
  - The client comes from the session, never from the body.
  - It uses the 21-7 two layers: a client-stamped transaction plus an explicit client predicate.
- **Two new portal reads** feed the form.
- **An "Announce a shipment" form** on the portal Inbound page.
- **The result is an ordinary ASN.** Operators and the handheld see it and receive against it exactly as one an operator keyed.

**Decisions (human, 2026-10-09):**
1. **Warehouses:** a client may announce into **every warehouse of the tenant**.
2. **Announce only.** There is no portal amend, close or cancel. The 3PL cancels a mistaken ASN on request; portal cancel goes to PENDING.
3. **No origin marker.** The audit row's actor (the client user) is the only record that an ASN came from the portal. No route or screen reads it today. An operator-visible origin badge goes to PENDING. No migration.
4. **Keep the full spec:** endpoint, form reads and web form ship together.

## Boundaries & Constraints

**Always:**

- **Route.**
  - `POST /tenants/{t}/portal/inbound/asns` in `portal.controller.ts`.
  - It sits behind `PortalSessionGuard` and `assertOwnTenant`.
  - It requires an `Idempotency-Key`, parsed with `parseRequiredIdempotencyKey`.
  - **The 201 body is the bare `PortalAsnDetail`**, byte-identical in shape to `GET portal/inbound/asns/{id}`, not wrapped in `{asn}`.
- **Body** `PortalCreateAsnDto {warehouseId, asnCode, expectedAt?, lines[{skuId, announcedQty}]}`.
  - It has the same validators as `CreateAsnDto`.
  - Its line DTO has no `id`.
  - A body `clientId` or a line `id` is 400 `validation-failed` (the global `forbidNonWhitelisted`, `app.factory.ts:62`).
- **Command `AsnCommand.announce(command, key)`**, where `command` is `{tenantId, clientId, actorUserId, warehouseId, asnCode, expectedAt, lines}` and `clientId` comes from `PortalSession`.
  - It opens `withTenantTransaction(this.db, command.tenantId, fn, { clientId: command.clientId })` itself.
  - It does **not** call `assertAuthority`. The operator `create`, `amend` and `transition` keep their code unchanged.
  - Steps, in order:
    1. **Hash** (before the transaction).
    2. **Authority.**
       - `assertPermission(getMemberRoleIn(…), 'asn.announce')`.
       - Then one read of the member's `status` and `client_id`. Not `active` → 401 `unauthenticated`. `client_id ≠ command.clientId` → 403 `role-denied`.
       - Then `getClientStatusInTx`. Not `active` → 403 `client-suspended`.
       - These re-reads close the window between the guard's transaction and this one. That matters on a write.
    3. **Replay.**
    4. **Code and line shape** (the shared helpers).
    5. **Warehouse in tenant** (404).
    6. **SKUs**, read with `tenant_id = $t AND client_id = command.clientId AND id IN (…)`.
       - An unknown or foreign SKU is 404 `not-found`, detail `No SKU with id "<id>" exists for this client.`
       - Another client's SKU is never confirmed to exist.
    7. **Kits.** Kit SKUs (`catalog.getKitSkuIdsInTx`) → 409 `kit-cannot-hold-stock`, naming the codes. Receiving refuses kits (`receiving.command.ts:485-498`), so a kit line could never be received.
    8. **Scale.**
    9. **Insert** with `client_id = command.clientId`. A duplicate code is 409 `duplicate-asn-code`.
    10. **Finish**, all in the same transaction:
        - the outbox `asn.created` with `{asn: readAsnInTx(…)}` (the operator payload, unchanged);
        - the audit row, with actor = the client user;
        - the idempotency key, whose `response_snapshot` is the `PortalAsnDetail` from `portalAsnInTx` (rebuilt on the same transaction).
  - `mixed-client` and `sku-client-mismatch` are unreachable on this path by construction.
- **Hashes.**
  - **Portal hash:** `hashCommandPayload({surface: 'portal', tenantId, clientId, warehouseId, asnCode: trimmed, expectedAt: normalizedExpectedAt(x) ?? null, lines: lines.map(({skuId, announcedQty}) => ({skuId, announcedQty}))})`. The key order is exactly this.
  - **The operator create hash and response are unchanged.** Both are pinned by goldens read from `idempotency_keys.payload_hash` after a real POST (the `asn.spec.ts:869` pattern).
- **Capability `asn.announce`** joins `CAPABILITIES`.
  - BE: `ROLE_CAPABILITIES.client = {asn.announce}`. Owner holds it through `new Set(CAPABILITIES)`; this is harmless because the fence keeps owner tokens off portal routes, and the command's client re-check refuses an owner.
  - FE mirror: append it to `CAPABILITIES`, **add it to `OPS_EXCLUDED_CAPABILITIES`** (`src/lib/users.ts:213`; ops_manager is derived by exclusion), and set `client: ['asn.announce']`.
- **Portal reads**, following 21-7's facade-read pattern: stamped `{ clientId }`, the explicit predicate, and exact keys.
  - **`GET portal/skus?cursor&limit`**
    - Returns rows `{skuId, skuCode, skuName, baseUom, uomPrecision}` (portal vocabulary, as on `portal/stock`).
    - Includes every **non-kit** SKU of the client.
    - Keyset `(code, id)` with its own codec. `limit` is 1–100. A bad cursor is 400 `invalid-cursor`.
  - **`GET portal/warehouses`**
    - Returns `{warehouseId, warehouseName, city}`: every warehouse of the tenant, ordered by `(name, id)`.
    - `city` is `origin_city`, which may be null. It disambiguates equal names.
    - It is unpaginated, capped at `MAX_WAREHOUSE_PAGE_SIZE`, because a tenant has few warehouses.
    - It never returns a code, address line or GSTIN.
- **Web.**
  - **The form.** Portal Inbound gains an "Announce a shipment" button and form:
    - a warehouse select (name, with the city when names repeat);
    - code and expected arrival;
    - line rows with a SKU select (UoM shown; the step comes from `uomPrecision`).
  - **Loading options.** The form drains `portal/skus` (limit 100), up to 20 pages. Beyond that it says the catalogue is too large for the form.
  - **Empty and failed states.**
    - No SKUs → the form is disabled with "No SKUs are set up for your company yet — ask the warehouse".
    - A failed read → `ReadFailure`.
    - Every portal call goes through `portalError`, so `client-suspended` fires the portal event.
  - **Parsing and keys.**
    - A new `parsePortalAsnCreate(draft, warehouseId)` builds the body `{warehouseId, asnCode, expectedAt?, lines[{skuId, announcedQty}]}`, with no `clientId` and no line `id`. It reuses `parseAsnLines` (ids stripped) and `parseExpectedAt`.
    - The per-draft ULID key and the in-flight ref follow `asn-card.tsx:302-336`.
  - **Line rows.** `LineRows` is exported and made generic over a minimal option `{id, code, name, uom, uomPrecision}`. The portal maps its DTO through an adapter in `lib/portal.ts`, so no operator type is imported into the portal.
  - **Error wording.** `portalAsnReason` sends the session codes (`client-suspended`, `role-denied`, `permission-denied`, `unauthenticated`) to `portalReadReason`. It gives portal wording for:
    - `not-found`: "A SKU or warehouse is no longer available";
    - `duplicate-asn-code`;
    - `kit-cannot-hold-stock`;
    - `validation-failed`;
    - `idempotency-key-reuse`;
    - `conflict`.
  - **On success** it shows a banner, resets the ASN list to its first page, and reloads.
  - **Operator surfaces.** No operator hook or route is used.

**Never:**
- portal amend, close or cancel (decision 2);
- an origin column or migration (decision 3);
- POs or orders from the portal;
- the client in the body;
- reusing the operator route, `AsnDto` or `assertAuthority` for the portal;
- changing the operator create hash or response;
- an RLS-only or predicate-only client check;
- `AUTH_DATABASE`;
- a portal write cap or rate limit (accepted risk, PENDING).

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected | Error |
|---|---|---|---|
| Announce | BRAND-A user, WH1, 2 A SKUs | 201 `PortalAsnDetail`, `announced`. Operator GET shows `clientId` A; it is in A's portal list, not B's; it is on the device snapshot; an outbox `asn.created`; the audit actor is the client user | — |
| Foreign or unknown SKU | a B SKU / a random id | — | 404 `not-found`, the "for this client" detail |
| Kit SKU | a line on an A kit | — | 409 `kit-cannot-hold-stock` |
| Bad body | `clientId` / a line `id` / 0 or 201 lines / a qty finer than its UoM / code of 65 characters | — | 400 `validation-failed` |
| Key | missing or malformed `Idempotency-Key` | — | 400 |
| Warehouse | unknown id | — | 404 |
| Same code | A then A `ASN-1` / A and B `ASN-1` | the second fails / both 201 | 409 `duplicate-asn-code` |
| Replay | same key and body / a changed body | the stored `PortalAsnDetail` / — | — / 422 `idempotency-key-reuse` |
| Cross-surface key | an operator create with key K, then a portal POST with the **identical** fields minus `clientId` and K (and the reverse, on a fresh key) | — | 422 `idempotency-key-reuse` |
| Suspended client / removed user | between the guard and the command (direct call) | — | 403 `client-suspended` / 401 |
| Wrong actor | direct `announce` with an owner, or with a B user and `clientId` A | — | 403 `role-denied` |
| Operator token | → `POST portal/inbound/asns` | — | 403, the portal detail |
| Portal token | → `POST inbound/asns` | — | 403, the operator-surface detail |
| Receive | a device `grn.submit` with `asnId` against the portal ASN | books; A's portal shows it `received` | — |

</frozen-after-approval>

## Code Map

All `wms-be` paths are relative to `workspace/core/backend/wms-be`; `wms-fe` paths to `workspace/core/frontend/wms-fe`.

- **Command:** `src/modules/inbound/asn.command.ts`.
  - The template is `create` `:420-500`. Mirror it and do not change it.
  - Reuse:
    - `readSkus` `:750` (add a client-filtered variant; keep the original);
    - `scaleLines`;
    - `replay` `:783`;
    - the insert and the `ASN_TENANT_CLIENT_CODE`/`duplicateAsnCode` catch `:470-486`;
    - `finish` `:702-733` (parameterised by the snapshot builder; the operator call must produce identical rows).
  - `assertAuthority` `:693-699` is not shared.
- **DTOs:** `src/modules/inbound/inbound.dto.ts:373-439` (`AsnLineInputDto`, `CreateAsnDto`).
- **Idempotency:** `src/modules/tenancy/idempotency-guard.ts` (`IdempotencyKey`, `parseRequiredIdempotencyKey`, `hashCommandPayload` `:55`). The operator route `inbound.controller.ts:348-389` shows how it is wired.
- **Facades:**
  - `inbound.facade.ts:159-202`. Add `announceAsn` (**not** `portal`-prefixed), a one-line delegation like `createAsn`. Portal SQL lives in `portal-inbound.ts` (`portalAsnInTx`).
  - `src/modules/catalog/catalog.facade.ts`: add `portalSkus`. `getKitSkuIdsInTx` is the kit lookup; the operator list is `catalog.controller.ts:230`.
  - `src/modules/tenancy/tenancy.service.ts`: add `portalWarehouses`, beside `listWarehouses` `:479`.
  - Reused reads: `getMemberRoleIn` `:163` (does **not** read status); `clients.facade.ts` `getClientStatusInTx`.
- **Portal:** `src/api/portal.controller.ts` (`PORTAL_401/403` `:33-36`, `assertOwnTenant` `:282`, `notFound` `:304`) and `portal.dto.ts` (allowlist header `:11-17`, `PortalPageQuery`). The guard is `clients/portal-session.guard.ts`.
- **Authority:** `src/modules/tenancy/permissions.ts` (`CAPABILITIES` `:10`, `asn.manage` `:246`, `client` `:357`).
- **RLS:** `0064:148-183`.
  - The header WITH CHECK requires `client_id = app.client_id` when stamped; lines go through their header.
  - `skus` (`0041:81`) filters by client.
  - `warehouses`, `users`, `idempotency_keys`, `audit_events` and `outbox_messages` are tenant-only.
  - Header and line WITH CHECK are **already probed** at `client-isolation.spec.ts:540,616,666`.
- **Tests that change:**
  - `portal.spec.ts:686`: the "portal write" offender becomes an exact allowlist, `POST …/portal/inbound/asns`.
  - `portal.spec.ts:692`: the count goes from 10 to 13.
  - `portal.spec.ts:465`: the empty-set test becomes `['asn.announce']`.
  - `users.spec.ts:879`: 40 → 41, plus the narrative and the `asn.announce` holders `['owner','client']`.
  - `architecture.spec.ts:1743-1782`: `PORTAL_READS` gains `catalog.facade.ts: portalSkus` and `tenancy.service.ts: portalWarehouses`, and the equality list gains both. **A new `PORTAL_WRITES` arm** scans `asn.command.ts: announce` for `withTenantTransaction(` plus `{ clientId: command.clientId }`, with its meaningful companion.
  - wms-fe `src/lib/users.test.ts:448` ("client holds no capability").
- **Fixtures:** `portal.spec.ts` `portalUser(clientId)` `:360`; `asn.spec.ts` `createAsn` `:212`, receive golden `:869`.
- **Web:**
  - Portal surface:
    - `src/components/portal/portal-inbound.tsx` (`AsnsSection` l.53, the header comment l.18-22);
    - `src/lib/use-portal.ts` (`usePortalList` l.52, cursor and `reload` l.93-98);
    - `src/lib/portal.ts` (`portalReadReason` l.92, `isClientSuspended`).
  - API client: `src/lib/api/client.ts` (portal wrappers l.3297-3416, `portalError` l.3305; `fetchApiCreateAsn` l.1510 is the template).
  - Operator ASN pieces:
    - `src/components/inbound/asn-card.tsx` (`LineRows` l.211-275, the key pattern l.302-336);
    - `src/lib/asns.ts` (`parseAsnLines` l.75, `parseExpectedAt` l.103, `parseAsnCreate` l.121, `asnReason` l.205);
    - `format-quantity.ts:100`.
  - The mirror: `src/lib/users.ts:205-230` and `scripts/check-capability-mirror.ts`.
  - Tests: `portal.test.tsx` (stub l.87-102 records the method and path only, so add body and header capture) and `asns.test.ts`.

## Tasks & Acceptance

**Execution:**
- [x] `wms-be` tenancy: `asn.announce` and the `client` grant (amend the 21-7 comment); `TenancyService.portalWarehouses`.
- [x] `wms-be` catalog: `CatalogFacade.portalSkus` (kits excluded).
- [x] `wms-be` inbound: `AsnCommand.announce`, the client-filtered SKU read and the parameterised `finish`; `InboundFacade.announceAsn`.
- [x] `wms-be` api: the route plus 2 reads, `PortalCreateAsnDto`/`PortalAsnLineInputDto`, `PortalSkuDto` and `PortalWarehouseDto`, and `@ApiResponse` for every matrix arm; re-export `openapi.json`.
- [x] `wms-be/test/portal-asn.spec.ts`:
  - every matrix row;
  - a deep exact-key `toEqual` on the 201, the replay and both reads;
  - the `portal/skus` second page, a bad cursor and the limit bounds;
  - a kit is absent from `portal/skus`;
  - the portal-hash and operator-create-hash goldens read from `idempotency_keys`;
  - direct-call `announce` arms (wrong actor, suspended, removed user) via `app.get(AsnCommand)`.
- [x] `wms-be/test/client-isolation.spec.ts`: one `wms_rls_probe` arm that runs the **whole announce write set** under A's stamp: the header, a line, `idempotency_keys`, `audit_events` and `outbox_messages` inserts, plus the `portalAsnInTx` read-back. All succeed, with a positive control, and are rolled back. Plus the `portal/skus` shape returning A's SKUs only with the predicate removed.
- [x] `wms-be` tests listed under "Tests that change".
- [x] `wms-fe`:
  - `bun run api:generate`;
  - the wrappers and hooks;
  - `parsePortalAsnCreate`, the generic `LineRows` and the adapter, `portalAsnReason`;
  - the form in `portal-inbound.tsx` (update l.18-22);
  - the mirror and `users.test.ts`.
  - Tests:
    - the captured POST body keys equal exactly `['asnCode','expectedAt','lines','warehouseId']` (or without `expectedAt`), and `Idempotency-Key` is sent;
    - the key is reused on retry and fresh after an edit;
    - a page-2 SKU appears as an option;
    - the empty and failed states;
    - success returns the list to page 1;
    - each `portalAsnReason` arm;
    - `client-suspended` fires the event;
    - the request list contains only `/portal/*`.
- [x] Meta docs:
  - `inbound.md`, `clients.md`, `catalog.md`, `tenancy.md`;
  - `API-SURFACE.md`;
  - 3PL `architecture.md` (the portal is read-mostly plus ASN);
  - `IMPLEMENTATION-GUIDE.md` §7e: a portal write re-reads the user and client in its own transaction;
  - `frontend/SYSTEM-DESIGN.md`;
  - both repo contracts;
  - `PENDING.md`:
    - close :107;
    - amend :109 (a warehouse list now exists; the read filters stay open);
    - add portal cancel and amend;
    - add the origin badge;
    - add a portal write cap or rate limit;
    - add that **operator ASN create also accepts kit SKUs** (pre-existing; out of scope here, since the operator path is unchanged).

**Acceptance Criteria:**
- Given BRAND-A and BRAND-B portal users, when A announces an ASN on the web and a device `grn.submit` books against it, then B's portal never lists it, and A's Inbound page shows it `received`.
- Given the full BE and FE suites, lint, typecheck and the capability mirror, when run, then they pass.

## Implementation Notes

Baselines: wms-be `b9c60d194af81b860138cb61618006b508e5e7ae` (`baseline_commit`), wms-fe `77c7d38c81fc0d0a4b9bbd2c57b5478548ed140e`.
- Work on `feat/21-7b-portal-asn-entry` in both repos (already checked out). Leave everything uncommitted: no commit, push or PR.
- In wms-be, run `bun run test -- <file>`; never bare `bun test`, and never two jest invocations at once (globalSetup sweeps kill the other run's DBs). The ledger idempotency-race test can flake under full-suite load only; rerun it alone before blaming the story.
- Edit meta docs in `/Users/sasidhar/Documents/WMS-Meta` (on `main`, uncommitted).
- Do not touch `wms-mobile`.

## Spec Change Log

## Review Triage Log

Design review, 2026-10-09: three lenses (adversarial 17, edge-case 15, verification-gap 9) consolidated into 25 rows. Load-bearing claims were re-checked at the cited code before triage.

| # | Finding (lenses) | Verdict and evidence | Action |
|---|---|---|---|
| D1 | The stamp scan targets the facade, but the stamp lives in the command; a delegating `portal*` facade fails the scan, or a facade-level transaction gives a false green (A1, E8, V1) | TRUE: `architecture.spec.ts:1760-1781`; `createAsn` delegates at `inbound.facade.ts:200` | patch: the facade is `announceAsn` (not `portal*`); a new `PORTAL_WRITES` arm scans `asn.command.ts: announce` |
| D2 | The planned probe arms duplicate existing ones; the real write set under a stamp is never run (V2, A10) | TRUE: `client-isolation.spec.ts:540,616,666` | patch: one whole-write-set arm with a positive control |
| D3 | `parseAsnCreate` requires and emits `clientId`; the FE stub cannot see bodies (E1, V3, A4) | TRUE: `asns.ts:121-152`; `app.factory.ts:62`; `portal.test.tsx:87-102` | patch: `parsePortalAsnCreate`; a body-capture test |
| D4 | `LineRows` is typed on the operator `SkuResponse` (E2, A5) | TRUE: `asn-card.tsx:211-260` | patch: a generic minimal option plus a portal adapter; `baseUom` kept (portal vocabulary, `portal/stock`) |
| D5 | The SKU select is fed from a paged read; only page 1 loads (E3, V4, A6) | TRUE: `use-portal.ts:52` | patch: drain up to 20×100 with a notice; a page-2 test |
| D6 | Warehouse names are not unique; there is no tiebreak and no bound (E4, E5, A15) | TRUE: unique only on `(tenant_id, code)`, `schema.ts:253` | patch: `(name, id)`, a `city` disambiguator, the 200 cap |
| D7 | Kit SKUs can be announced but never received (E6) | TRUE: `receiving.command.ts:485-498`; `readSkus` has no kit check | patch: excluded from `portal/skus`, refused 409 at announce; the operator gap goes to PENDING |
| D8 | Suspension or removal between the guard and the command still writes; `getMemberRoleIn` ignores status (E7, A9) | TRUE: `tenancy.service.ts:163-183` | patch: in-transaction user and client status re-reads |
| D9 | `users.spec.ts:879` count and the `asn.announce` holders are unlisted or unpinned (E9, V8, A2) | TRUE | patch |
| D10 | The FE ops_manager set is derived by exclusion, so `asn.announce` would leak to ops_manager in the mirror; `users.test.ts:448` unlisted (A3) | TRUE: `users.ts:213-225` | patch |
| D11 | Portal hash normalisation and key order are unstated; only the operator hash is pinned, by a helper literal (E10, A8, V6) | TRUE: `idempotency-guard.ts:55` is `JSON.stringify` | patch: exact object; both hashes pinned by `idempotency_keys` goldens |
| D12 | The cross-surface 422 proves `surface` only on identical fields (V5) | TRUE by construction | patch: matrix row specifies identical fields, both directions |
| D13 | The command's own client re-check is unreachable over HTTP (V7) | TRUE: the guard refuses first | patch: direct-call arms |
| D14 | `asnPortalRefused` is masked by `asn.manage` for a client user; a refactor could drop it silently (V9) | TRUE: `asn.command.ts:695`; the 0065 CHECK means a client always lacks `asn.manage` | patch: `announce` does not share `assertAuthority`; operator authority code untouched (defence in depth, not separately observable) |
| D15 | The 201 envelope (bare vs `{asn}`) and the snapshot shape are ambiguous (A7) | TRUE: operator `{asn}`, portal GET bare | patch: bare `PortalAsnDetail`; the snapshot is the same JSON |
| D16 | The matrix omits the 400, 404, 409 `conflict` and key arms (A11) | TRUE | patch: rows added |
| D17 | `asnReason` wording is operator-facing, and the SKU 404 detail says "in this tenant" (E15, A12) | TRUE: `asns.ts:205-240`, `asn.command.ts:762` | patch: `portalAsnReason`; the "for this client" detail |
| D18 | Reload keeps a page-2 cursor, so the new ASN is not shown (E13) | TRUE: `use-portal.ts:93-98` | patch: reset to page 1 |
| D19 | The form's empty and failed states are unspecified (E14) | Design gap | patch |
| D20 | The origin audit row has no read path (E12) | TRUE | patch: decision 3 wording says so; the badge goes to PENDING |
| D21 | Portal writes are unbounded and ride every device snapshot (E11, A14) | TRUE: `receiving.facade.ts:463-480` | defer: accepted risk under authenticated, suspendable clients; PENDING (rate limit or open-ASN cap) |
| D22 | PENDING :109 is made stale by `portal/warehouses` (A13) | TRUE | patch |
| D23 | Code Map anchors are wrong (idempotency helpers, DTO path) (A16) | TRUE | patch |
| D24 | The AC requires a real handheld receipt that nothing verifies (A17) | TRUE | patch: the AC uses a device `grn.submit` via the API |
| D25 | The test plan cannot catch a wrong client on insert (V, "also noted") | TRUE | patch: Announce row asserts the operator `clientId`, both portal lists and the outbox row |

Code review, 2026-10-09: three layers (blind-hunter 15, edge-case 9, verification-gap 3), 27 rows. Each claim checked at the cited code: 9 patch (in 5 fixes), 1 defer, 17 reject. No loopback.

| # | Verdict | Finding (layer) | Evidence | Route |
|---|---|---|---|---|
| C1 | low | Form inputs stay live during the POST; an edit clears the key mid-flight, so a timed-out-but-committed submit retries under a new key (EC-7) | TRUE: `portal-inbound.tsx` only the Announce button is `disabled={busy}` | patch: the form is disabled while busy |
| C2 | low | Discard during flight still announces, then shows the banner (EC-6) | TRUE, same root cause as C1 | patch (with C1) |
| C3 | low | `portalAsnReason` `validation-failed` passes the raw server detail, which is not portal wording (BH-5) | TRUE: `portal.ts:310-311`; the spec requires portal wording | patch: fixed sentence |
| C4 | medium | Malformed `expectedAt` on the portal route is untested (VG-1, BH-10a) | Pre-verified; `normalizedExpectedAt` `asn.command.ts:395-404` is the only guard | patch (test) |
| C5 | medium | The "catalogue too large" form branch never renders in a test (VG-2) | Pre-verified | patch (test) |
| C6 | low | Single-warehouse auto-select untested (VG-3, BH-11c) | Pre-verified | patch (test) |
| C7 | low | `docs/repos/wms-fe/README.md:155` still says `client: []`, 40 capabilities (BH-15) | TRUE | patch (docs) |
| C8 | low | A catalogue over 2,000 SKUs disables the form, with no PENDING entry (BH-8) | TRUE by construction (`drainPortalSkus`) | patch (PENDING) |
| C9 | medium (unverified scale) | A SKU that becomes a kit after its ASN was announced can never be received (BH-13) | TRUE by construction; pre-existing for operator ASNs and POs | defer |
| C10 | low | Unlocked client status read lets a concurrent suspend miss the commit (EC-1) | No command suspends a client (21-7 C26); SQL-only | reject |
| C11 | low | A malformed `expectedAt` is 400 before authority (EC-2) | It mirrors operator `create` (`:422`), leaks nothing, and the hash needs the normalised value | reject |
| C12 | low | More than 200 warehouses are silently cut (EC-3, BH-9) | Spec-mandated cap with a recorded rationale | reject |
| C13 | low | Zero warehouses leaves an unsubmittable form (EC-4) | A tenant with client SKUs and no warehouse is not a real 3PL state | reject |
| C14 | low | Equal name plus equal or null city still collide (EC-5) | Needs duplicate-named warehouses in one city; unlikely | reject |
| C15 | low | `readSession()` null at submit is silent (EC-8) | The shell redirects on session loss; unreachable in practice | reject |
| C16 | low | The SKU drain is not abortable (EC-9, BH-7) | Results are dropped by `usePortalDetail`'s `cancelled` flag (`use-portal.ts:125-135`); only wasted fetches; the fix needs signal plumbing | reject |
| C17 | low | `actor === null` is dead; a deleted user is 403, not 401 (BH-1) | TRUE but nothing deletes users; the implementer flagged it; the docs describe status, not deletion | reject |
| C18 | low | The write-stamp scan can be fooled by a stamped inner call (BH-2) | The same heuristic as 21-7's read scan; the RLS probe is the second layer | reject |
| C19 | false | The RLS probe overclaims the "whole write set" (BH-3) | Docs say "write set (every insert, plus the read-back)", which the arm runs; the skipped reads hit tenant-only tables (`kit_compositions` policy `0033:64`) or deliberately client-filtered ones | reject |
| C20 | low | Post-write views show only `warehouseName`, not the city (BH-4) | Needs duplicate warehouse names; the 21-7 read DTOs are out of this story | reject |
| C21 | low | A Discard after a timeout loses the key, so a re-entry gets a misleading 409 (BH-6) | Rare; the 409 is about the user's own notice, which is true | reject |
| C22 | low | Untested `conflict` race, duplicate-SKU lines, foreign-kit ordering, replay after suspend (BH-10b-e) | Duplicate lines are pre-existing operator behaviour; the ordering is correct by reading (`readClientSkus` precedes the kit check); authority precedes replay by construction | reject |
| C23 | low | Untested capability-hidden button, double-submit, warehouse-only failure (BH-11a,b,d) | Only client sessions reach the portal; the in-flight ref plus C1's disabled form | reject |
| C24 | low | Line order in the hash is unstated (BH-12) | Operator parity; FE builds lines deterministically from rows | reject |
| C25 | false | The spec is absent from the review diff (BH-14) | By design: the spec is the claims file, given to the edge-case layer only | reject |
| C26 | low | `PortalAsnRow` lacks city disambiguation in the banner (BH-4, dup) | See C20 | reject |
| C27 | low | Drain races a later reload (BH-7, dup) | See C16 | reject |

## Design Notes

- **Why a separate command, not a flag on `create`.** The two paths differ at every step:
  - **Client:** the operator path takes it from the body and checks it against the SKUs; the portal takes it from the session and filters the SKUs by it.
  - **Snapshot:** the portal stores a different shape.
  - A flag would branch the hash, authority, SKU read and snapshot. Sharing the private helpers keeps one insert path, and keeps the operator code byte-identical.
- **Why 404, not 409, for a foreign SKU.** Under the stamp, RLS hides B's SKU anyway, so production says 404. The explicit predicate makes the superuser jest suite agree. A 409 naming another client's SKU would confirm that it exists.
- **Why the `surface` hash key.** `idempotency_keys` is unique on `(tenant_id, key)` and shared by both surfaces. Without the key, an identical payload re-serves the other surface's snapshot. `AsnDto` leaks `clientId`, `warehouseId` and `statusNote`.
- **Why a capability, not `role === 'client'`.** Authority stays a per-command DB role read through the one primitive (§7e), it is an allowlist by construction, and the mirror stays honest.
- **Why re-read statuses in the command.** On a read, the guard-to-query window is harmless. On a write, a suspended brand's in-flight request would commit. The same transaction now decides.
- **Accepted risk (D21).** A client can raise many ASNs into any warehouse, and open ASNs ride that warehouse's device snapshot. The actor is authenticated and suspendable, and the operator can cancel. A cap or rate limit is PENDING.

## Verification

**Commands:**
- `cd workspace/core/backend/wms-be && bun run test -- test/portal-asn.spec.ts` -- expected: pass (never two jest runs at once)
- `cd workspace/core/backend/wms-be && bun run test -- test/client-isolation.spec.ts` -- expected: pass, including the write-set arm
- `cd workspace/core/backend/wms-be && bun run test && bun run lint && bun run typecheck` -- expected: the full suite passes
- `cd workspace/core/frontend/wms-fe && bun run api:generate && bun test && bun run typecheck && bun run lint && bun run check:capability-mirror` -- expected: pass (the mirror and generated guards fail in CI until the backend merges)

**Manual checks:**
- Real-HTTP smoke:
  - sign in as a BRAND-A portal user;
  - list SKUs and warehouses;
  - announce, then replay the key with the same body;
  - try a B SKU (404) and an operator token on the route (403).
- The handheld leg is optional: receive the portal ASN on the device.
