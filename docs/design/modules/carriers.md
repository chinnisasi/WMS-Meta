# Carriers module

> Which carriers a tenant can ship with, and the sealed vault holding each tenant's credentials for them — a compile-time adapter registry plus an encrypted, never-readable-back credential store.

Paths are relative to `workspace/core/backend/wms-be`. Read [`../IMPLEMENTATION-GUIDE.md`](../IMPLEMENTATION-GUIDE.md) first — the command skeleton is followed closely here and is not repeated.

**Scope, deliberately:** this module makes **no network calls** and the backend has no HTTP client. `rate()`, `label()` and `track()` are not declared anywhere — a method signature guessed before its first caller is a shipped interface to unpick. The port grows those arms in the story that consumes them (labels: 4-6c; rating: deferred). `CarriersFacade` is the seam they grow from.

The module exists for one invariant: **secret material leaves the system exactly never.**

---

## Owns

| Table | Holds | Key invariants |
|---|---|---|
| `carrier_connections` (`src/shared/db/schema.ts:1862`) | One row per configured carrier account: `carrier_code`, `account_label`, `credential_sealed`, `credential_version`, `connected_by`, `rotated_at`/`rotated_by` | See below |

CHECKs and RLS live only in `drizzle/0025_carrier_connections.sql`:

- `carrier_connections_tenant_carrier_unique` — **one live connection per (tenant, carrier)**. A second connect is a deterministic 409 off this index, never a read-then-write race.
- `carrier_connections_credential_sealed_envelope` — `credential_sealed LIKE 'v1:%'`. The DB-side backstop for the story's whole point: a code path that ever tried to store raw material fails the write instead of quietly keeping a secret in the clear.
- `carrier_connections_credential_version_positive` — `> 0`. 1 at connect, +1 per rotation, forward only.
- `carrier_connections_account_label_nonblank` — `length(btrim(…)) > 0`.
- `carrier_connections_rotation_stamp_paired` — `(rotated_at IS NULL) = (rotated_by IS NULL)`. A row that knows *when* it rotated but not *by whom* is an audit gap in the exact record AD-15 makes first-class.
- `carrier_connections_tenant_isolation` — the standard fail-closed RLS policy. The `NULLIF(current_setting('app.tenant_id', true), '')` guard is load-bearing here above all other tables: a fail-open would expose sealed credentials across tenants.
- `carrier_connections_tenant_created_at_id_idx` — the keyset list index, tenant-first, from day one.

**The registry owns no table.** `carrier_registry.ts` is a compile-time `Map` populated at import. Adding a carrier is one `registerCarrierAdapter` call and **no migration**.

The module also writes `audit_events` and `idempotency_keys` (tenancy-owned, shared).

---

---

## Schema (field level)

### `carrier_connections` — the credential vault

| Column | Type | Null | Default | Guard | Meaning |
|---|---|---|---|---|---|
| `carrier_code` | text | NO | — | registry lookup (no CHECK) | `delhivery \| blue_dart \| ecom_express`. Validated against the import-time registry, not the DB |
| `account_label` | text | NO | — | `..._account_label_nonblank` | The operator's name for this account |
| `credential_sealed` | text | NO | — | **`..._credential_sealed_envelope`** (`LIKE 'v1:%'`) | **THE SECRET.** AES-256-GCM envelope `v1:<iv>:<tag>:<ct>` over canonical credential JSON, sealed under `CARRIER_ENCRYPTION_KEY`. The CHECK is the DB-side backstop against a code path ever storing plaintext |
| `credential_version` | integer | NO | `1` | `..._credential_version_positive` | **Generation counter** — 1 at connect, +1 per rotation. Not a quantity |
| `connected_by` | uuid | NO | — | — | |
| `rotated_at` / `rotated_by` | timestamptz / uuid | **YES** | — | **`..._rotation_stamp_paired`** (`(rotated_at IS NULL) = (rotated_by IS NULL)`) | Stamped together or not at all — a row knowing *when* but not *by whom* is an audit gap in the record AD-15 makes first-class |

**`carrier_connections_tenant_carrier_unique`** on `(tenant_id, carrier_code)` — one live connection per carrier per tenant, so a concurrent double-connect is a deterministic constraint violation mapped to `409`, never two live credential rows.

**Confinement — the module's whole point.** `credential_sealed` reaches exactly three files (`schema.ts`, `carrier.command.ts`, `carriers.facade.ts`) and **none under `src/api/`**. It must never appear in a response DTO, a list row, an outbox payload, an audit row, a log line, or `idempotency_keys.response_snapshot`. The e2e suite uses the sealed blob itself as a canary alongside the plaintext.

**Rotation replaces material in place, keeping the row id** — the id is the stable handle AD-15 means by "referenced by id", so a rotation never orphans a reference.

---

## Public seam

`CarriersModule` exports `CarriersFacade` **alone** (`carriers.module.ts:40`), and the architecture test fails any sibling reaching past it.

**`CarriersFacade`** (`carriers.facade.ts:94`):

| Method | Does | Secret exposure |
|---|---|---|
| `catalogue()` `:105` | Every registered adapter, code-sorted: code, display name, credential field descriptors | None — compile-time, no DB |
| `connect(command, idempotencyKey)` `:110` | Delegates to the command service | Takes plaintext in; returns the public face |
| `rotate(command, idempotencyKey)` `:118` | Delegates | Same |
| `disconnect(command, idempotencyKey)` `:126` | Delegates | Returns the public face of the deleted row |
| `listConnections(tenantId, {cursor, limit})` `:134` | Keyset page of public faces | `CONNECTION_COLUMNS` does not select the blob |
| `resolveConnection(tenantId, connectionId)` `:162` | One public face or `null`; a non-uuid id short-circuits to `null` | None |
| `openCredentialForAdapterUse(tenantId, connectionId)` `:197` | **The only read that opens the envelope.** Request-scoped plaintext for a caller about to hand it to a carrier client | Total — see Security notes |

The facade also re-exports the types a consumer needs (`CarrierConnectionView`, the three command shapes, `CarrierAdapter`, `CarrierCredentialField`, `CarrierCredential`) so nothing imports the module's internals (`:31-38`).

**`CarrierConnectionView`** (`carrier.command.ts:60`) is the only shape that leaves the module: `{id, tenantId, carrierCode, carrierName, accountLabel, credentialVersion, connectedBy, rotatedAt, rotatedBy, createdAt, updatedAt}`. `carrierName` is resolved from the registry at read time and never stored — the code is the truth, the name a convenience, and a row whose adapter was de-registered still lists under its raw code (`:119-121`).

HTTP lives in the api shell (`src/api/carriers.controller.ts`), not here. `rotate` and `disconnect` are POST sub-resources, not PUT/DELETE — the repo has no `@Delete` route anywhere; every destructive verb is a POST carrying an `Idempotency-Key`.

---

## Commands

All three are in `CarrierCommandService` (`carrier.command.ts:180`) and all three gate on `carrier.manage` (Owner + Ops Manager; absent from `operator` and `accountant` — an API key is not a floor verb). The **reads are deliberately ungated**: the catalogue and the connection list are open to any tenant member because reads are never gated in this codebase, and those rows carry the public face only, so there is nothing for a gate to protect (`tenancy/permissions.ts:77-86`).

### `connect` (`:191`)

Guards in exact order — the order is the security property:

1. **`assertPermission(getMemberRoleIn(tx, …), 'carrier.manage')` before everything** (`:203-206`). Before any validation 400, **before the master key is touched**, before the replay pre-check. A caller without the capability must not learn which carrier codes the registry holds, must not learn whether the deployment has an encryption key, and must not be able to drive AES work with material it was never allowed to store.
2. Registry membership → 400 `validation-failed` naming the code and listing the known ones (`:210-213`).
3. `acceptAccountLabel` → 400 if blank after trim or > 100 chars (`:214`). The DTO's `@Length(1,100)` counts characters, so `'   '` clears it — this is the arm that actually holds the invariant and keeps a blank off the DB CHECK, which would surface as a 500.
4. `acceptCredential` against the adapter's declared fields → 400 naming the offending field, **never echoing a value** (`:215`).
5. Seal + HMAC under the master key; a missing `CARRIER_ENCRYPTION_KEY` → 503 `carrier-encryption-unavailable` (`:221-224`).
6. Payload hash over `{tenantId, carrierCode, accountLabel, credentialHmac}` (`:225-230`).
7. Replay (`:232`).
8. INSERT with `credential_version: 1`; a `carrier_connections_tenant_carrier_unique` violation → 409 `carrier-already-connected` telling the caller to rotate instead (`:254-256`).
9. `recordAndSettle`: outbox → audit → idempotency key.

### `rotate` (`:280`)

Replaces the material **in place**. The row id is the stable handle AD-15 means by "referenced by id" — what rating and 4-6c's labels will store against a shipment — so a rotation minting a new id would orphan every reference.

Order: capability → coarse HMAC + payload hash over `{tenantId, connectionId, credentialHmac}` → replay → **row locked `.for('update')` scoped to `(id, tenantId)`** (404 if absent, which is also the cross-tenant answer) → adapter resolved from the *stored* `carrier_code` (a build that no longer registers it → 400, rather than sealing against a port that does not exist, `:326-331`) → `acceptCredential` → seal → UPDATE setting `credential_sealed`, `credential_version + 1`, `rotated_at`, `rotated_by`, `updated_at` → `recordAndSettle`.

The adapter is unknown until the row is read, so the credential is validated *after* the lock while the HMAC is computed *before* the replay — see Key algorithms for what that costs.

### `disconnect` (`:372`)

A **hard DELETE**. AD-15 says disconnect deletes, and a status flip would leave sealed secret material at rest after the operator asked for it to be gone. The audit row survives to record it.

Order: payload hash over `{tenantId, connectionId}` — **no credential, therefore no master key** → capability → replay → row locked → 404 if absent → `tx.delete` → `recordAndSettle` with the pre-delete public face.

A repeat under a **new** key is 404 (the row is gone). A repeat under the **same** key replays the snapshot. Because it never touches the master key, disconnect is the one command that still works with `CARRIER_ENCRYPTION_KEY` unset — pinned by `test/carriers.spec.ts:635`.

---

## Key algorithms

### The registry pattern (`carrier-registry.ts`)

An import-time `Map` populated by `registerCarrierAdapter`, following `inventory/ledger-registry.ts` — **not** a DI token. Every other port seam in the repo (`LEDGER_ANCHOR_STORE`, `WAVE_CLOCK`, the outbox seams) has exactly one production implementation, so none of them is a precedent for N providers selected by name.

An adapter is a **declarative descriptor** (`:38-45`): `code`, `displayName`, `credentialFields[]` where each field is `{name, label, required, description}`. Nothing else. `credentialFields` declaration order is wire order, and it is how any future surface learns what to ask an operator for — the credential shape is never hard-coded client-side.

Three import-time guards, which take the process down rather than produce a quietly wrong registry (`:54-72`):

- duplicate `code` → throw (a carrier is declared once);
- zero `credentialFields` → throw (connect would be a no-op sealing an empty record — nothing to rotate, nothing to protect);
- duplicate field name within one adapter → throw.

`carrier-registry.spec.ts` unit-tests these precisely because nothing in the e2e path can reach them — the module would never have loaded.

Registered: `delhivery`, `blue_dart`, `ecom_express` (human decision, 2026-09-16). **Shiprocket is deliberately excluded**: it is an aggregator fronting other carriers, so its credential shape and its eventual rate/label shape differ in kind from a direct carrier's. Absorbing that difference into the port before any consumer exists is exactly the guessing the decision was held open to avoid.

### Envelope sealing (`carrier-credentials.ts`)

**This is the only file that holds the master key or produces and opens the sealed blob.**

- `carrierMasterKey()` (`:41`) reads `CARRIER_ENCRYPTION_KEY`, requires ≥ 32 chars, and stretches it to 32 bytes with sha256 — so a deployment that swaps in a real 32-byte KMS data key keeps working unchanged. It is deliberately **not** `DEVICE_ENCRYPTION_KEY`: carrier secrets and device offline-store keys then have independent blast radii and rotate independently, at the cost of one required env var.
- `canonicalCredentialJson()` (`:55`) sorts keys, so the same logical material always produces the same JSON regardless of the order the caller sent its fields in. Both the seal and the HMAC read it — key order must not make a replay look like a different payload.
- `sealCredential` / `openCredential` (`:64`, `:73`) wrap `shared/crypto/envelope.ts`: AES-256-GCM, format `v1:<iv b64>:<tag b64>:<ct b64>`. GCM authenticates, so a wrong key or a tampered blob **fails closed** rather than returning garbage.

**Losing the key makes every stored credential unrecoverable**, and key rotation is unsupported today (see Gotchas).

`validateCredential` (`:145`) is the shape gate: refuses a non-object; refuses more than `MAX_CREDENTIAL_FIELDS` (16); refuses any field the adapter does not declare (a typo'd name would otherwise seal a useless credential that only fails much later at the first real carrier call); refuses a non-string value; refuses a value over `MAX_CREDENTIAL_VALUE_LENGTH` (512) — **checked before the trim, so padding cannot smuggle length past it** (`:166-169`). Values are trimmed; an optional field left blank is simply not stored; a required field blank is `missing-field`. Every failure names the **field**, never the value.

### The credential's contribution to the payload hash (`credentialHmac`, `:94`)

The subtlest piece in the module. Idempotency must distinguish "the same connect replayed" from "the same key reused for **different** material" — the second must be 422 — so the credential cannot simply be dropped from the hash. But `hashCommandPayload` is a bare sha256 over `JSON.stringify` and its output is **persisted** in `idempotency_keys.payload_hash`, a durable, tenant-readable column. Hashing a raw API key there would store a digest an attacker with DB access can brute-force against low-entropy material.

Keying the digest with the master key keeps both properties: identical material HMACs identically (replay works), different material collides into the 422, and the persisted digest is worthless without the master key.

**Rotation's HMAC is coarser than connect's** (`asStringRecord`, `:527-540`). The adapter is not known until the row is read, so rotation hashes *every string-valued key, declared or not*, dropping blanks exactly as `validateCredential` does — while connect hashes the adapter-validated record. That coarseness is deliberate (the digest only has to be stable for identical material) and it costs one thing: a caller that retries the **same** key after adding an undeclared field, or after fixing a non-string value, hashes differently and gets `422 idempotency-key-reuse` instead of the 400 that would name the field. A fresh key gets the naming 400. The alternative — dropping the credential from the hash — would make a key reused with genuinely different material look like a replay, which is worse by far.

### Rotation

`credential_version` is the generation counter: 1 at connect, +1 per rotation, forward only (CHECK-enforced). `rotated_at`/`rotated_by` stamp together (CHECK-enforced). The row id never changes, so a caller that must remember *which* credential it used stores `{connectionId, credentialVersion}` — which is exactly why rotation keeps the id.

The old sealed blob is **overwritten**, not versioned. There is no credential history and no way back to previous material.

### Disconnect deletes

Not a status flip, not a soft delete. `test/architecture.spec.ts:447` pins `.delete(carrierConnections` in the command source so a later "soft delete" refactor has to argue with the test. What survives is the `audit_events` row (`action: 'carrier.disconnected'`, `targetType: 'carrier_connection'`, `targetId` = the dead row's id) and the outbox event.

---

## Invariants

| Invariant | Enforced by |
|---|---|
| Secret material never reaches a response, outbox payload, audit row, log line or idempotency snapshot | Confinement rules + architecture test (below); `CONNECTION_COLUMNS` never selects the blob; `recordAndSettle` writes ids and the version only |
| The stored credential column holds an envelope blob, never plaintext | `carrier_connections_credential_sealed_envelope` CHECK (`LIKE 'v1:%'`) |
| One live connection per (tenant, carrier) | `carrier_connections_tenant_carrier_unique` → 409 `carrier-already-connected` |
| `credential_version` is ≥ 1 and only increases | CHECK + rotation is the only writer |
| `rotated_at` and `rotated_by` are set together or not at all | `carrier_connections_rotation_stamp_paired` CHECK |
| Only registry-known carrier codes are stored | `getCarrierAdapter` check in connect; rotate re-checks against the stored code |
| Only adapter-declared fields are sealed | `validateCredential`'s unknown-field refusal |
| `accountLabel` is non-blank and ≤ 100 chars | `acceptAccountLabel` 400, `carrier_connections_account_label_nonblank` CHECK |
| A carrier is declared exactly once, with ≥ 1 credential field | `registerCarrierAdapter` import-time throws |
| Disconnect removes the material, not just a flag | Hard DELETE + architecture test |
| A refusal never echoes a supplied credential value | Every message in `carriers.errors.ts` names the field only — the file says so at `:10-14` |
| No other module writes `carrier_connections` or imports past the facade | `test/architecture.spec.ts:380-440` |

---

## Security notes

### The confinement rules

Plaintext **does** travel: the DTO carries it inbound (write-only) and the command holds the validated record long enough to seal it. What is confined is narrower and is the part that matters — `process.env.CARRIER_ENCRYPTION_KEY` and the `envelope.ts` primitives live in exactly one file, so there is exactly one place that can turn material into storage or storage back into material (`carrier-credentials.ts:5-26`).

Past the seal, everything handles the **public face** only:

- **Response DTOs** — `src/api/carriers.dto.ts` has no `credential` field on any `…Response` class: not plaintext, not the sealed blob, **not a masked preview** (`:9-15`).
- **The select list** — `CONNECTION_COLUMNS` (`carrier.command.ts:133`) does not name `credentialSealed`, so no read path can grow a secret by accident. `openCredentialForAdapterUse` selects the column explicitly and alone.
- **Outbox payload** — `{connectionId, carrierCode, credentialVersion}` only (`carrier.command.ts:477-481`). An integration event is relayed to a bus and may be logged by its consumers.
- **Audit row** — actor and target only.
- **The idempotency snapshot** — `{connection: <public face>}`. This is the explicit break with story 3.2, which stored a device credential *and* its sealed offline-store key in `idempotency_keys.response_snapshot` (`tenancy/enrollment.command.ts:79-84`). Copying that precedent here would have defeated the whole module (`carrier.command.ts:49-56`).
- **The payload hash** — a master-key HMAC, not the secret (above).
- **Error messages** — written on the assumption that they will be logged.

### What the architecture test pins (`test/architecture.spec.ts:358-503`)

Four guards, and it is worth knowing exactly what each does **and does not** cover:

1. **No carrier-connection write outside the module** (`:380`) — Drizzle and raw-SQL write forms, scanned across all of `src`.
2. **No sibling imports past the facade** (`:396`) — allowed suffixes are `carriers.facade`, `carriers.module`, `carriers.dto`, matched as specifier *endings* so `carriers.facade.internal` is caught. No sibling consumes carriers yet, so the regex is self-tested against hard-coded specifier strings rather than relying on live offenders.
3. **The master key and the envelope live only in `carrier-credentials.ts`** (`:450`). Two arms, with different reach: the `process.env.CARRIER_ENCRYPTION_KEY` **read** is banned repo-wide, but the `crypto/envelope` **import** is banned only for files under `src/modules/carriers/` (`:466`). A file outside the module importing `envelope.ts` is not flagged by this guard — it would have to obtain a key some other way to be dangerous, but the guard is narrower than it reads.
4. **No `credentialSealed` anywhere under `src/api/`, and not in `CONNECTION_COLUMNS`** (`:488`). A leak would look exactly like a response DTO naming the column.

The e2e suite adds the behavioural half: `test/carriers.spec.ts:229` asserts nothing durable or on the wire carries the credential, `:473` that a rotation's blob no longer contains the old token, `:482`/`:891` that serialized outbox rows and responses contain neither the blob nor the field name.

### `openCredentialForAdapterUse` — the one opening

`carriers.facade.ts:197`. The rules for any caller, stated there and **not negotiable**: the returned record is request-scoped plaintext — never logged, never in a response DTO, an outbox payload, an audit row, a ledger reference doc or an idempotency snapshot, and never persisted anywhere. A caller that must remember which credential it used stores the connection id and `credentialVersion`.

It fails closed three ways: a non-uuid id or a row absent in this tenant → 404; a missing master key → 503 `carrier-encryption-unavailable`; a blob that will not open → 503 `carrier-credential-unreadable` naming the connection and telling the operator to rotate under the current key.

**It has no caller and no test today.** `../PENDING.md` records the consequence plainly: deleting its `tenantId` predicate would let any tenant open any other tenant's credential **with the full suite still green**. 4-6c brings the first caller — **pin the tenant predicate before then.**

### Key rotation is unsupported

Changing `CARRIER_ENCRYPTION_KEY` makes every stored blob unopenable *and* breaks idempotent replay (the persisted HMACs no longer match). A real fix needs a key id inside the blob and a re-seal path (`../PENDING.md` → carriers).

---

## Events

| Type | Emitted by | Payload |
|---|---|---|
| `carrier.connected` | `connect` | `{connectionId, carrierCode, credentialVersion}` |
| `carrier.credential_rotated` | `rotate` | same shape |
| `carrier.disconnected` | `disconnect` | same shape |

All three go through `recordAndSettle` (`carrier.command.ts:461`), in the order **outbox → audit → idempotency key** — the current convention (`putaway/bin-state.command.ts` documents it; story 3.2 has them reversed). The audit row uses the same three strings as `action`, with `targetType: 'carrier_connection'` and `reference` = the idempotency key.

---

## Gotchas

**`rotate` does not re-run the replay check under the row lock.** The guide's step 6 exists for the same-key race; `rotate` (`:303-320`) and `disconnect` (`:387-402`) both replay *before* locking and never again. The idempotency unique index still arbitrates — a concurrent duplicate loses at `recordAndSettle` and gets 409 `conflict` — so this is not a correctness hole, but it is a deviation from the skeleton you will be tempted to "fix" by copying the guide verbatim. Check what the e2e suite pins before changing it.

**`rotate` returns 422 where you would expect a naming 400.** Retrying the same key after adding an undeclared field, or after fixing a non-string value, changes the coarse HMAC and hits `idempotency-key-reuse` before `validateCredential` can name the field (see Key algorithms). Tell users to retry with a fresh key.

**`disconnect` works without `CARRIER_ENCRYPTION_KEY`; connect and rotate do not.** Deliberate — disconnect never touches the master key — and pinned at `test/carriers.spec.ts:635`. Do not "consistently" add a key check to disconnect: a deployment that has lost its key must still be able to delete the unusable rows.

**`toConnectionView`'s `canonicalInstant` calls are load-bearing for pagination.** `carrier.command.ts:125-128` normalizes `createdAt` to ISO-8601 `Z`, and `listConnections` builds its cursor from the **view**, not the row (`carriers.facade.ts:157`). `decodeCursorSafe` then validates against `CURSOR_INSTANT_RE`, which requires exactly that shape (`:53`, `:65-71`) — stricter than every other module's cursor check. Remove the normalization and every carrier cursor becomes a 400 `invalid-cursor`. `decodeCursorSafe` exists as eleven private copies across the repo and this is the only one that pins the instant shape — do not assume the others behave identically.

**`listConnections` deliberately does not clamp `limit`.** `carriers.facade.ts:138-141`: the route DTO bounds it 1–200, and clamping in the facade would silently rewrite a bad request instead of rejecting it. A **non-HTTP** caller therefore gets whatever it passes — including a value that makes `limit: pageSize + 1` meaningless. Every sibling facade clamps; this one does not.

**`carrierName` is resolved, not stored.** A row whose adapter is no longer registered lists under its raw `carrier_code` (`:119-121`) but **cannot be rotated** — `rotate` refuses with 400 (`:326-331`). A deployment rollback that drops an adapter therefore strands those connections in a read-and-disconnect-only state.

**A `connect` replay re-serves the ORIGINAL public face**, including `credentialVersion: 1`, even if the connection has since been rotated — the snapshot is frozen at commit. `test/carriers.spec.ts:847` pins that the replay is scoped to its own tenant (a foreign key-holder cannot hijack a connection); nothing pins the staleness, which is correct idempotency behaviour but surprising in a UI that re-issues a key.

**The credential-field ceilings are the only bound on what gets sealed.** 512 chars per value, 16 fields (`carrier-credentials.ts:108`, `:115`). Without them a `carrier.manage` holder could seal a multi-megabyte value into a row that every list query and every future adapter call has to carry.

**The `carriers` module takes no cross-module DI edge.** It imports `SharedModule` only; `assertPermission` and `getMemberRoleIn` come in as file-level functions from tenancy (`carriers.module.ts:30-35`). Nothing can cycle back into it — keep it that way when 4-6c adds the first consumer, which should import `CarriersFacade` and nothing else.
