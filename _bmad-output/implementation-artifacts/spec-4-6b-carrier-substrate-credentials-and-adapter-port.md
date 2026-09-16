---
title: 'Story 4.6b: Carrier substrate — the adapter registry and the tenant credential vault'
type: 'feature'
created: '2026-09-16'
status: 'done'
route: 'dispatch'
review_loop_iteration: 0
baseline_commit: '14ca18003358db4c655af9a758ca327c0cc95900' # wms-be main
context:
  - '_bmad-output/implementation-artifacts/epic-4-context.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** `src/modules/carriers/carriers.module.ts` is still the 15-line story-1.1 spine placeholder with zero providers — the AD-6 boundary is declared and nothing implements it. So there is no answer to "which carriers can this tenant ship with" and nowhere to put a carrier API key: AD-15 requires tenant-scoped credentials under envelope encryption, referenced by id, rotation first-class, disconnect deletes, and the repo has none of it. Meanwhile `wave_policies.carrier_ref` has been an unvalidated uuid since 4.2 ("no carriers table until 4.6"), and 4.6 shipped dispatch with `carrierName`/`trackingNumber` as free text explicitly labelled the carrier arc's migration target.

**Approach:** Stand up the `carriers` module as two halves that need each other: a compile-time **adapter registry** naming the supported carriers and, per carrier, the credential fields it requires; and a **credential vault** — one tenant-scoped `carrier_connections` row per configured carrier account, its secret material sealed with `envelope.ts` and never readable back over the wire. Connect, rotate and disconnect are commands in the module's own command service, behind an owner/ops-manager capability, with the module's facade as the seam that rating (deferred) and labels (`4-6c`) will consume.

**Decided (2026-09-16, human):**
- **The registry names three DIRECT carriers: Delhivery, Blue Dart, Ecom Express.** This closes OQ1, open since the 4.6 gate. Shiprocket — the fourth epic candidate — is deliberately excluded: it is an *aggregator* fronting other carriers, so its credential shape and its eventual rate/label shape differ in kind from a direct carrier, and absorbing that difference into the port before any consumer exists is the guessing OQ1 was held open to avoid. The registry is additive (a new carrier is one `registerCarrierAdapter` call and no migration), so aggregator support is a later decision, not a foreclosed one.
- **This story makes no network calls.** Adapters are declarative descriptors — carrier code, display name, the credential fields that carrier requires, and validation of supplied material. `rate()`, `label()` and `track()` are not declared at all: nothing calls them today (rating is deferred, labels are `4-6c`), and a method signature guessed before its first caller is a shipped interface to unpick. The port grows those arms in the story that consumes them.
- **Carrier credentials are sealed under a separate `CARRIER_ENCRYPTION_KEY`**, not `DEVICE_ENCRYPTION_KEY`. Carrier secrets and device offline-store keys then have independent blast radii and rotate independently, at the cost of one new required env var. `envelope.ts` remains the documented KMS stand-in — the real-KMS swap is still its own decision, and **losing this key makes every stored credential unrecoverable**, which the `.env.example` entry must say.

**Decided (technical, from investigation):**
- **Rotation replaces material in place, keeping the row id.** The connection id is the stable handle AD-15 means by "referenced by id" and is what `4-6c` and rating will store; a rotation that minted a new id would orphan every reference. `credential_version` increments and `rotated_at`/`rotated_by` stamp the row.
- **Disconnect is a hard `DELETE`, modelled as `POST .../disconnect`.** AD-15 says disconnect deletes, and a status flip would leave sealed secret material at rest after the operator asked for it to be gone. The repo has no `@Delete` route anywhere — every destructive verb is a `POST` sub-resource carrying an `Idempotency-Key` — so the verb shape follows `devices/:id/revoke` while the effect follows `po.command.ts:313`'s hard delete.
- **The registry follows `ledger-registry.ts`, not a DI token.** Every existing port seam (`LEDGER_ANCHOR_STORE`, `WaveClock`, the outbox seams) has exactly one production implementation, so none of them is a precedent for N providers selected by name. An import-time `Map` populated by `registerCarrierAdapter`, throwing on a duplicate code, is the repo's own pattern for a registry of named arms.

## Boundaries & Constraints

**Always:**
- **Secret material leaves the system exactly never.** No response DTO, no list row, no outbox payload, no audit row, no ledger reference doc, and no log line may carry the plaintext or the sealed blob. This is the one invariant the story exists to hold.
- **The idempotency snapshot must not carry the credential.** Story 3.2 stored a device credential *and* its sealed offline-store key in `idempotency_keys.response_snapshot` (`enrollment.command.ts:79-84`, confirmed by `devices.spec.ts:705`); that jsonb column is durable, tenant-readable on replay, and copying the precedent here would defeat the whole story. The snapshot carries the connection's public face only.
- **The payload hash must not be a hash of the raw secret.** `hashCommandPayload` is sha256 over `JSON.stringify` and lands in `idempotency_keys.payload_hash`; feeding it a caller's API key stores a crackable digest of that key. The credential participates in the hash as an HMAC keyed by the master key, so reuse detection survives and the stored digest does not.
- `connect` refuses a `carrier_code` the registry does not know, and refuses credential material missing any field that carrier declares required — both `400 validation-failed` naming the offender.
- The capability is **`carrier.manage`**, Owner + Ops Manager only, mirroring `device.manage` / `vendor.manage` — a settings capability, absent from `operator` and `accountant`. The routes are `GET /tenants/:tenantId/carriers` (the registry catalogue: code, display name, required credential fields — how any future surface learns what to ask for), `GET|POST /tenants/:tenantId/carriers/connections`, and `POST /tenants/:tenantId/carriers/connections/:connectionId/{rotate,disconnect}`.
- One active connection per (tenant, carrier) — a second `connect` for the same carrier is a `409`, and re-configuring is `rotate`. A unique index enforces it rather than a read-then-write.
- Commands re-read the member role at entry, carry an `Idempotency-Key` with payload-hash replay, emit to the outbox and write an audit row, all in one `withTenantTransaction`, following `bin-state.command.ts`'s landmark order (outbox → audit → idempotency key).
- The new table gets its RLS policy and CHECKs in migration SQL only, no FKs, a tenant-first keyset index, and its own `wms_rls_probe` cross-tenant test — the conventions every table since 0019 follows.
- `test/architecture.spec.ts` gains a `carriers` block mirroring the outbound one, including the hard-coded reaching/allowed specifier strings its self-test needs (the module has no sibling consumers yet, so the `siblingModules.length > 0` assert cannot carry it).

**Never:**
- **No outbound network calls, and no HTTP client dependency added.** The backend makes no third-party HTTP request today and has no timeout, retry or circuit-breaker policy; introducing one inside a credential story would make it an HTTP-infrastructure story — the trap 4-2b avoided with component tests.
- No rating, no label, no manifest, no tracking writeback — rating is deferred (`deferred-work.md`, 2026-09-16), labels and manifests are `4-6c`.
- **No retroactive validation of `wave_policies.carrier_ref`.** It stays the unvalidated uuid 4.2 shipped. Tightening it now means a backfill against live policy rows for no behaviour anyone can observe until rating exists.
- No change to `dispatch`'s free-text `carrierName`/`trackingNumber`. They remain the interim shape until a story actually issues a tracking number.
- No real KMS integration — `envelope.ts`'s env-var master key stays the documented stand-in.
- No web or mobile surface. The frontend change is the capability mirror and the regenerated client only.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Connect a carrier | known `carrierCode`, all required fields | `201`; row written, secret sealed; response carries id, code, label, `credentialVersion`, never the secret | N/A |
| Unknown carrier | `carrierCode` absent from the registry | nothing written | `400 validation-failed` naming the code and listing known codes |
| Missing credential field | required field absent or blank | nothing written | `400 validation-failed` naming the missing field, never echoing supplied values |
| Duplicate connection | carrier already connected for the tenant | nothing written | `409` directing the caller to rotate |
| Rotate | new material for an existing connection | `200`; same id, `credentialVersion` + 1, `rotatedAt`/`rotatedBy` stamped | unknown id → `404` |
| Disconnect | an existing connection | `200`; the row is gone, audit row records the deletion | unknown id → `404`; repeat under a new key → `404` |
| List connections | any number configured | `200`; keyset page of public faces only — **no sealed blob, no plaintext** | malformed cursor → `400` |
| Replay | any command repeated under the same key | the stored snapshot is re-served, nothing re-written | different payload, same key → `422 idempotency-key-reuse` |
| Wrong authority | caller lacks the capability, or a foreign tenant | nothing written | `403 role-denied` / `permission-denied` |
| Master key absent | `envelope.ts` throws `MissingEncryptionKeyError` | nothing written | `503`, mirroring `device-encryption-unavailable` |
| Cross-tenant | another tenant's connection id, or an RLS probe read | invisible | `404` / zero rows |

</frozen-after-approval>

## Code Map

- `src/modules/outbound/../putaway/bin-state.command.ts` (194 lines) — **the template to copy**, the tightest complete exemplar of the landmark order: hash payload before the tx (`:52`), `withTenantTransaction` (`:59`), `assertPermission(await getMemberRoleIn(...))` (`:63`), inline replay block (`:69-87`), parent-scope assert (`:89`), row lock `.for('update')` (`:94`), guards (`:104`), write + snapshot (`:122`), `outbox.append` (`:145`), `auditEvents` insert (`:159`), `idempotencyKeys` insert with unique-violation → 409 (`:170-188`). Note `:157` documents outbox → audit → key as the current convention (3.2 has them reversed).
- `src/modules/tenancy/enrollment.command.ts` — the credential-shaped sibling: `sealOfflineStoreKey` wrapper at `:394-411` remaps `MissingEncryptionKeyError` to a `503` because a raw throw inside the tx would be a 500; `revokeDevice` at `:588-629` is the lock + guard + idempotent-repeat shape. **Its snapshot at `:79-84` is the anti-pattern** — do not copy.
- `src/shared/crypto/envelope.ts` — `seal`/`open`/`deviceMasterKey`/`MissingEncryptionKeyError`. `open()` has no production caller today. Sealed format `v1:<iv>:<tag>:<ct>`; the master key is any ≥32-char secret stretched with sha256.
- `src/modules/inventory/ledger-registry.ts:183-194` — the registry pattern to mirror: module-level `Map`, `registerLedgerEventType` throwing on duplicates, import-time registration calls, runtime `get*`/`is*` lookups. `:18-165` is the discriminated-union half.
- `src/modules/inventory/anchor-store.ts:34-51` + `inventory.module.ts:37` — the interface + string-token + `useClass` seam, if a DI seam is wanted alongside the registry. Every such seam in the repo has exactly one implementation.
- `src/modules/inventory/inventory.facade.ts:209-241` — the facade shape: `@Injectable()`, explicit `@Inject(ClassName)` ctor args, one-line passthroughs, re-exported types (`:26-35`) so siblings never import internals. Exported alone from its module (`inventory.module.ts:47-48`).
- `test/architecture.spec.ts:182-338` — the outbound block to mirror; `:206-208` the camelCase/snake_case table arrays and module root, `:226-235` the past-the-facade import regex, `:243-264` the self-test literals a module with no sibling consumers must supply by hand.
- `src/modules/tenancy/permissions.ts:8-71` (`CAPABILITIES`), `:84-120` (`ROLE_CAPABILITIES`) — a settings capability is added to `CAPABILITIES` and to `ops_manager` only; `owner` holds all automatically.
- `src/modules/tenancy/idempotency-guard.ts` — `IdempotencyKey` decorator (`:12-20`), `parseRequiredIdempotencyKey` (`:28-46`), `hashCommandPayload` (`:55-57`, sha256 of `JSON.stringify`, fixed key order). `idempotencyKeyReuse()` is imported from `registration.command.ts:147-154`.
- `src/api/devices.controller.ts` + `devices.dto.ts` — the settings controller shape: `@Controller('tenants')` with relative routes, the per-route decorator stack (`:69-81`), the per-controller `IDEMPOTENCY_HEADER` const (`:45-52`), handler order `assertOwnTenant` → `assertUuidParam` → `parseRequiredIdempotencyKey` → command → DTO, and the inline list-query DTO (`:30-43`).
- `src/shared/primitives/pagination.ts` — `buildPage`, `encodeCursor`/`decodeCursor`; keyset walk example at `enrollment.command.ts:673-702`. Offset pagination is banned; no config list anywhere skips pagination.
- `drizzle/0021_lean_george_stacy.sql` — the CREATE TABLE conventions: column order (`id`, `tenant_id`, domain, timestamps last), the `<table>_tenant_isolation` RLS policy with the load-bearing `NULLIF(current_setting('app.tenant_id', true), '')::uuid`, CHECKs as named `ALTER TABLE ... ADD CONSTRAINT`, `--> statement-breakpoint` separators. Next index is **0025**; a hand-written migration needs a hand-written `_journal.json` entry (`{idx, version, when, tag, breakpoints}`) **and** `drizzle/meta/0025_snapshot.json` — the 4.6 review caught a missing snapshot, and nothing in CI catches it.
- `src/shared/db/schema.ts:22-26` (`tenantTimestamps`), `:672-688` (a short tenant-scoped table), `:28-35` (the rule: RLS lives only in migration SQL), `:150-154` (no FKs — uuid column + index, validated in the command transaction).
- `src/modules/outbound/wave.command.ts:347-351` — the `carrierRef` shape-only guard and the comment declaring it unvalidated. **Confirm and leave alone.**
- `test/devices.spec.ts` — the e2e template: `useSuiteDatabase` first in `beforeAll` (`:36-41`), `cleanupRows` + client close in `afterAll` (`:43-66`), real-HTTP tenant registration and sign-in for seeding (`:68-79`), the `wms_rls_probe` cross-tenant role (`:655-665`), the cross-tenant idempotency-key hijack test (`:703-730`), and the OpenAPI path-list drift guard (`:695-701`).
- `.env.example` — house style is a multi-line `#` comment naming the story and AD, the consequence of leaving it unset, and the validation bound; the `DEVICE_ENCRYPTION_KEY` block is the model.
- `wms-fe/src/lib/users.ts` (`CAPABILITIES`) + `wms-fe/scripts/check-capability-mirror.ts` — the CI guard reads `permissions.ts` directly and fails naming what drifted, so the mirror must gain the new capability.

## Tasks & Acceptance

**Execution:**
- [x] `wms-be drizzle/0025_carrier_connections.sql` + `drizzle/meta/_journal.json` + `drizzle/meta/0025_snapshot.json` — create the table with RLS, CHECKs, the unique (tenant, carrier_code) index and the keyset index; hand-written journal entry and snapshot
- [x] `wms-be src/shared/db/schema.ts` — the `carrierConnections` table and its `$inferSelect` type, doc-commented in house style
- [x] `wms-be src/modules/carriers/carrier-registry.ts` — the `CarrierAdapter` shape, `registerCarrierAdapter` throwing on duplicates, the import-time registrations, and the lookup helpers
- [x] `wms-be src/modules/carriers/carrier-credentials.ts` — seal/open of the credential record and the master-key HMAC used for the payload hash; the only file that touches plaintext
- [x] `wms-be src/modules/carriers/carrier.command.ts` — connect, rotate, disconnect; `carriers.errors.ts` for the problem factories
- [x] `wms-be src/modules/carriers/carriers.facade.ts` + `carriers.module.ts` — the read seam (list, resolve-by-id, open-credential-for-adapter-use) and the module wiring, facade exported alone
- [x] `wms-be src/modules/tenancy/permissions.ts` — the new capability, owner + ops manager
- [x] `wms-be src/api/carriers.controller.ts` + `carriers.dto.ts` + `src/api/api.module.ts` — the routes, OpenAPI annotations and problem-details arms
- [x] `wms-be test/carriers.spec.ts` — the matrix e2e, the RLS probe, the cross-tenant key hijack, and the OpenAPI drift guard
- [x] `wms-be test/architecture.spec.ts` — the `carriers` ownership block with its self-test literals
- [x] `wms-be .env.example` — the `CARRIER_ENCRYPTION_KEY` entry, naming the story and AD-15, the >= 32-char bound, and that losing it is unrecoverable
- [x] `wms-be bun run openapi:export` + `wms-fe src/lib/users.ts` mirror + `wms-fe bun run api:generate`

**Acceptance Criteria:**
- Given a connected carrier, when its row, every command response, the outbox payload, the audit row and the idempotency snapshot are read, then none of them contains the plaintext credential or the sealed blob — asserted directly, not by inspection
- Given a connection, when it is rotated, then the id is unchanged, `credentialVersion` has incremented, and opening the stored blob yields the new material and not the old
- Given a connection, when it is disconnected, then the row is gone from the table and an audit row survives recording that it was
- Given a carrier whose adapter declares a required field, when connect omits that field, then the refusal names the field and the response does not echo any supplied credential value
- Given the master key is unset, when **connect or rotate** runs, then it answers `503` and writes nothing. `disconnect` is deliberately exempt: it seals nothing, and a deployment that has lost its key must still be able to remove the rows that key can no longer open (human decision, 2026-09-16)

## Implementation Notes

## Spec Change Log

**2026-09-16 — acceptance criterion narrowed (review loop 1, finding #1).** The edge-case layer found that
`disconnect` returns 200 and hard-deletes with `CARRIER_ENCRYPTION_KEY` unset, because it never invokes the
envelope. The frozen I/O matrix row is keyed on "`envelope.ts` throws `MissingEncryptionKeyError`" and so was
satisfied vacuously, but the acceptance criterion said "**any** command", which the code did not meet. Put to the
human as a genuine two-reading ambiguity; the decision was to **keep `disconnect` key-free** — deleting a
connection needs no secret, and since a lost key makes stored credentials permanently unopenable (as
`.env.example` states), disconnect is the only remedy a tenant in that state has left. Fail-closing it would
strand them with rows nothing can read and nothing can remove. **Amended:** the AC now names connect and rotate
and states the exemption. **No code was re-derived** — the implementation was already correct; only the spec's
own claim about it was wrong. **KEEP:** `disconnect`'s payload hash must stay `{tenantId, connectionId}` with no
credential term, which is precisely what makes it key-free.

## Review Triage Log

**Loop 1 — three layers (blind hunter 12, edge-case 11, verification-gap 3 + 2 others). 28 findings, each verified at
its cited location. 1 BLOCKING intent question, 13 patch, 6 defer, 8 rejected.**

| # | Finding | Layer | Verdict | Evidence |
|---|---------|-------|---------|----------|
| 1 | With `CARRIER_ENCRYPTION_KEY` unset, `disconnect` returns 200 and hard-deletes — it never calls `carrierMasterKey()` | edge (claim) | **RESOLVED — code correct, AC amended** | Confirmed at `carrier.command.ts:367`: disconnect hashes `{tenantId, connectionId}` only and deletes. The frozen matrix row is keyed on "`envelope.ts` throws `MissingEncryptionKeyError`", which disconnect never triggers, so the ROW is satisfied vacuously — but the AC "when **any** command runs, then it answers 503 and writes nothing" is not. Two defensible readings with a real operational trade-off; put to the human, who chose to KEEP disconnect key-free: deleting needs no secret, and a lost key makes disconnect the only remedy left. No code change; the AC was narrowed and the test name corrected (#2) |
| 2 | The test named "**every command** answers 503" exercises only connect and rotate | triage | **medium — patch** | Confirmed at `carriers.spec.ts:568-605`: no disconnect arm. The name is what made this row look covered in the task audit; it must say what it tests whichever way #1 is decided |
| 3 | `connect` runs the registry lookup, label check, credential validation AND the AES seal + HMAC BEFORE `assertPermission` | blind + edge + v-gap | **medium — patch** | Confirmed at `carrier.command.ts:197-211` vs the assert at `:221`. The repo states the opposite convention outright (`inventory.controller.ts:127-129`, "Permission before EVERYTHING … the capability assert precedes any validation 400"). An unauthorised member learns which carrier codes exist and whether the deployment holds a key, and drives AES work pre-authz. `rotate`/`disconnect` are already correct |
| 4 | `openCredentialForAdapterUse` calls `openCredential` bare — missing key or a failed GCM open surfaces as a raw 500 | blind + edge | **medium — patch** | Confirmed at `carriers.facade.ts:192-211`: the only key-touching path not wrapped in `withCarrierKey`, while connect/rotate are careful to produce 503 `carrier-encryption-unavailable`. Wrong-key-after-rotation is the realistic trigger |
| 5 | `409 conflict` (concurrent idempotent request) is undocumented on rotate and disconnect; connect declares only the already-connected arm | blind + edge | **medium — patch** | Confirmed: `carriers.controller.ts:136` is the only `status: 409`, yet `concurrentIdempotency()` is reachable from all three. Every sibling controller documents it (`inbound.controller.ts:69`, `outbound.controller.ts:487`). A generated client has no branch for a status these routes return |
| 6 | Credential values are unbounded at every layer | blind | **medium — patch** | Confirmed: `ConnectCarrierDto.credential` is `@IsObject()` only, `validateCredential` checks presence/type/blankness but never length, `credential_sealed` is unbounded `text`. Neighbouring fields bound themselves (`@Length(1,100)`), and 4.6 bounded carrier/tracking at 200 chars on exactly this reasoning — an append-only-ish store must not take an unbounded caller-controlled string |
| 7 | Migration 0025's four CHECK constraints are pinned by no test | v-gap | **medium — patch** | Pre-verified by demonstration: delete any `ADD CONSTRAINT` from the hand-appended half and the whole suite still passes, because the app layer never attempts a violating write. `carriers.spec.ts:254` asserts what the command WROTE, not what the DB REFUSES. The repo tests CHECKs by `23514` probe elsewhere (`orders.spec.ts:874`, `reservations.spec.ts:1040`) |
| 8 | The `accountLabel` refusal path has no test; a regression there turns a 400 into a 500 | v-gap | **medium — patch** | Pre-verified: every `accountLabel` in the suite is well-formed. `@Length(1,100)` counts characters so `'   '` passes the DTO and reaches the command; drop the `label === ''` arm and the blank label hits the DB CHECK as an unhandled error rendered `500 internal-error` |
| 9 | Two of four `CredentialValidationFailure` reasons (`not-an-object`, `non-string-value`) have no e2e arm; the three `registerCarrierAdapter` guards have no unit test; the documented 401 is never exercised | blind | **medium — patch** | Confirmed against `carriers.spec.ts` — these are the branches that keep non-string material out of `seal()` |
| 10 | The architecture guard's envelope-import scan matches only the exact relative prefix | blind | **low — patch** | Confirmed at `architecture.spec.ts`: `/from '\.\.\/\.\.\/shared\/crypto\/envelope'/` misses a deeper relative path or an alias. Direct regex correction — match the specifier suffix |
| 11 | `invalidUuidParam` has zero callers and the controller re-implements it verbatim | blind + v-gap | **low — patch** | Confirmed: `grep` returns only the definition at `carriers.errors.ts:121`; `carriers.controller.ts:242-250` copies the same title and detail inline. The errors file's own header forbids verbatim copies. Fix is a deletion or a call |
| 12 | `carrier-credentials.ts` is documented as "the only file that touches plaintext"; the command, the DTOs and the controller all hold it | edge (claim) | **low — patch** | Confirmed — unavoidably so, since plaintext must arrive over the wire. The confinement that IS real is the sealed blob and the envelope/key access. Direct comment correction so the claim matches what the architecture test actually pins |
| 13 | `rotate` hashes a coarser normalization than `connect`, so a retry adding a typo'd field answers 422 rather than 400 | blind + edge | **low — patch** | Confirmed: `asStringRecord` keeps undeclared keys because the adapter is unknown before the tx, and `replay()` runs before `acceptCredential`. Narrow, and the fix that removes it is a restructure — correct the comment's "stable for identical material" to state the coarseness is deliberate |
| 14 | `listConnections` is readable by an `accountant` with no recorded decision | blind | **low — patch** | Real: account labels, who connected each carrier and the rotation history are visible to a zero-capability role. It follows the documented repo rule (`permissions.ts:4-7`, reads are never gated), so the fix is to record that decision beside `carrier.manage` where the next reviewer looks — not a new gate |
| 15 | `openCredentialForAdapterUse` is exercised by nothing — its uuid guard, tenant predicate and not-found throw are all unpinned | v-gap | **medium — defer** | Pre-verified: delete `eq(carrierConnections.tenantId, tenantId)` and any tenant could open any other tenant's credential, with the suite still green — the e2e asserts decryption by importing `openCredential` directly, going around the seam. Deferred on the layer's own disposition: nothing calls it, so no regression ships today, and 4-6c brings the first caller and a natural end-to-end path |
| 16 | The facade's rotate/disconnect take a non-uuid `connectionId` unguarded; `listConnections` takes limit 0/negative/fractional unguarded | edge | **low — defer** | Real only for a sibling caller: over HTTP the controller's `assertUuidParam` and the DTO bounds cover both. No sibling consumer exists until 4-6c. Groups with #15 — same root cause, the unexercised seam |
| 17 | Rotating `CARRIER_ENCRYPTION_KEY` breaks idempotent replay, because `payload_hash` is a master-key HMAC | blind | **low — defer** | Real but strictly smaller than the problem beside it: rotating the master key also makes every stored blob unopenable, which `.env.example` already states. Master-key rotation/re-seal is outside this story's frozen scope ("no real KMS integration") |
| 18 | The keyset cursor is built from a millisecond-truncated instant against microsecond `created_at` | blind + edge | **low — defer** | Real and inherited: `toConnectionView`'s `canonicalInstant` runs before `buildPage`, so same-millisecond rows below the boundary are skipped. Pre-existing at every `buildPage(rows.map(toView))` site in the repo and ALREADY TRACKED as epic-2 retro action item a1 — this story adopted the pattern rather than introducing it |
| 19 | A replay under the same key after disconnect returns 201/200 naming a deleted connection | edge | **false** | The outcome occurs, but it is the specified behaviour: the frozen matrix's Replay row says the stored snapshot is re-served, and `carriers.spec.ts:512` pins it deliberately ("the row is gone, but the SAME key replays the snapshot rather than 404ing"). The proposed fix would contradict the frozen block |
| 20 | The Design Note says "a partial unique index on (tenant_id, carrier_code)"; the migration creates a plain one | edge (claim) | **false — rejected** | The migration is right: there is no soft-delete and no status column, so there is no predicate to be partial on. The only fix would edit this build's spec, which triage rejects. Recorded here so the wording is corrected at the next spec touch |
| 21 | The arch guard's allowlist permits `'../carriers/carriers.dto'`, a file that does not exist | blind | **false** | Not stale — the detector's regex is the shared `(facade\|module\|dto)` shape the outbound block uses, so allowing a `.dto` specifier is the pattern's design, not a pre-authorisation of a path nobody defined |
| 22 | `resolveConnection` has no caller, no test and no route — the same "shipped interface" the module's doc argues against | blind | **low — defer** | Accurate as an observation, and it groups with #15/#16: the read seam exists for 4-6c. Unlike a guessed `rate()` signature, returning a stored row is a shape the table already fixes. Folded into the #15 defer entry rather than removed |


## Design Notes

**Why the credential joins the payload hash as an HMAC.** Idempotency has to distinguish "the same connect replayed" from "the same key reused for a different secret" — the second must be `422`, so the credential cannot simply be dropped from the hash. But `hashCommandPayload` is sha256 over `JSON.stringify` and its output is persisted in `idempotency_keys.payload_hash`, so hashing the raw key stores a digest an attacker with DB access can brute-force against a low-entropy API key. Feeding the hash `credentialHmac = HMAC-SHA256(masterKey, canonical credential JSON)` keeps both properties: identical material hashes identically, different material collides into the 422, and the persisted digest is worthless without the master key.

**Why one connection per (tenant, carrier), enforced by index.** A read-then-insert race is exactly the shape that produced this epic's conditional-update discipline; a partial unique index on (tenant_id, carrier_code) makes a concurrent double-connect a deterministic constraint violation mapped to `409` rather than two live credential rows for one account, which would make "which key does rating use" unanswerable.

## Verification

**Commands:**
- `cd workspace/core/backend/wms-be && bun run test && bun run lint && bun run typecheck && bun run build && bun run db:migrate && bun run db:verify` — the **full** suite against a freshly reset database (drop the `public` and `drizzle` schemas, `FLUSHALL` Valkey, migrate). Whole suite, not a scoped subset: this story adds a module and `architecture.spec.ts` is what guards its boundary.
- `cd workspace/core/backend/wms-be && bun run db:generate` — expected: **no new migration emitted**. Nothing in CI compares the hand-written migration against `schema.ts`, so this is the only check that they agree.
- `cd workspace/core/frontend/wms-fe && bun run check:capability-mirror && bun run test && bun run lint && bun run typecheck && bun run build` — the mirror guard passes only once the backend change is on `main`.
- `grep -ri` the new module's responses, outbox payloads and audit inserts for the credential field names — expected: the plaintext appears only inside `carrier-credentials.ts`.
