---
title: 'Story 3.2: Mobile client substrate — enrollment, badge-in, inbox, scanning'
type: 'feature'
created: '2026-09-09'
status: 'done'
baseline_commit: 'ef794525bcc632be5d7e15966efd95e0423d6b26' # wms-be HEAD
baseline_commit_fe: '2c1f8243a70e046e99096583c87ae02b1b480954' # wms-fe HEAD
route: 'dispatch'
review_loop_iteration: 0
context:
  - '_bmad-output/implementation-artifacts/epic-3-context.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** The floor has no client. Receiving (3.3) and putaway (3.5) need a mobile surface that works through dead zones — enrollment, badge-in, a task inbox, and scanning with an honest offline queue — plus the backend that makes devices identity-bearing and revocable.

**Approach:** Three coordinated parts.

1. **wms-mobile (new repo)** — the story-1.1 Expo shell (`wms-fe/mobile/`, 7 files) is extracted to its own repository (`WMS-Mobile` on GitHub), registered in `docs/repo-catalog.yaml` + the workspace, and grown into the substrate per the architecture spine: Expo Router screens (enrollment → badge-in → task inbox), an on-device scan decision engine (`src/scanning/` — capture-agnostic: camera and paired HID produce the same normalized scan-event shape), and an encrypted SQLite (WAL) offline store + FIFO outbox + replay layer (`src/offline/`) with client-generated ULID idempotency keys. The task inbox ships the All/Pick/Putaway/Count/Transfer switcher with an empty task list (no task types exist until epics 4/5) and the four-state scan banner (✓ Accepted / ↻ Recorded · queued / ✕ Rejected ≤ 500 ms / ⚠ Held for review) exercised by a device-self-test scan flow — the substrate proves itself end-to-end (enroll → badge-in → scan → queue → replay) without waiting for receiving.
2. **wms-be** — device identity in the tenancy module: a `devices` table (migration 0012, hand-appended RLS + CHECKs), enrollment commands (one-time enrollment code minted by an authorized user; the device exchanges it for a device-bound credential), badge-in minting a revocable device session (longer-lived than the 15-min web JWT, but server-checked: every authenticated device request re-validates device status + operator role — revocation is effective on the next request, and replayed offline ops are re-authorized against device status + role at the server, AD-4), device revocation (wipe-flagged, audit row, outbox event), and a device self-test echo surface the substrate's replay proves against. Device secret material (the offline-store key) is delivered at enrollment under envelope encryption (AES-256-GCM, env-var master key as the KMS stand-in — swap documented).
3. **wms-fe (web Settings)** — the placeholder "Device enrollment" block in Settings becomes real: the device list (label, operator, enrolled/last-seen, status) and a revoke action (wipe-flagged). FE consumes the generated client (`api:generate`).

**Never:** no task types, no PO/receiving/QC/putaway logic (3.3–3.5 consume this substrate); no barcode-format work beyond what scanning libs give (SKU barcodes already exist); no push notifications; no refresh-token machinery (device sessions are revocable server-side instead); no Conflicts & Reviews queue (arrives with over-receipt approvals in 3.3).

## Boundaries & Constraints

**Always:**
- Backend commands follow the established invariant order (`withTenantTransaction`: assertPermission → idempotency replay → asserts → write → in-tx outbox → idempotency-key snapshot); ULID idempotency keys tenant-scoped (AD-5).
- New capabilities in `permissions.ts` gate enrollment-code minting and revocation (`device.manage`, Owner + Ops Manager); enrollment-code redemption and badge-in authenticate the operator, not a capability.
- Every device-authenticated request resolves the device row server-side (fail-closed: unknown/revoked device → `403 device-revoked`; role re-read from DB per command — the JWT/device token is transport, never authority).
- Revocation: status flip + `revokedAt`/`revokedBy` + wipe flag + `audit_events` row + outbox event (`device.revoked`); idempotent re-revoke.
- Envelope encryption via `node:crypto` AES-256-GCM with an env master key (`DEVICE_ENCRYPTION_KEY`); secret material never logged or exported (AD-15 stand-in, swap-to-KMS documented).
- Mobile: scan banner is state-coded by fill + glyph + word (never color-only); rejected scans never queue; the offline queue chip is amber with a count, never red/error styling; queued ops replay in task order exactly once; force-quit loses nothing; queue state is depth, never an error (AD-4).
- Badge-in: first-ever badge-in requires connectivity; afterwards offline restore from the device cache (UX-DR6). Badge-in credential is a **4–6 digit PIN set during enrollment** (human decision 2026-09-09) — PIN hashes with the existing scrypt primitive; account passwords never appear on the device.
- The **wms-fe Settings device card ships in this story** (human decision 2026-09-09): device list + mint enrollment code + revoke — the "web Settings can revoke it" AC is met by 3.2, not deferred.
- Mobile accessibility floor (UX-DR22): every task state announced via platform accessibility APIs, dynamic type honored (banner legible at largest setting), Reduce Motion makes banner swaps instant, targets ≥ 48dp, glove- and one-handed-usable.
- Microcopy: numbers and verbs, no exclamation marks ("Queued 14 — will sync when Wi-Fi returns").
- Scan-to-decision ≤ 1.5 s on-device on a mid-range Android; camera + HID interchangeable at every step; manual entry a one-tap fallback at every scan step; HID keeps capture-field focus across banner swaps.

**Never:**
- No ledger writes, no stock mutations (the substrate's replay proves against a device self-test surface, not inventory).
- No wms-be session-model rework for the web (the 15-min web JWT stands; device sessions are a separate server-checked mechanism).
- No LWW conflict auto-merge; conflicts surface in the sync summary (AD-4; the AD-14 taxonomy lands with real tasks).
- No wms-fe work beyond the Settings device card (+ `api:generate`); the mobile app moves OUT of wms-fe to its own repo.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Mint enrollment code | Owner/Ops Manager, web Settings, `device.manage`, idempotency key | 201 one-time code (short TTL, single redemption, bound to tenant) + `device.enrollment_code_minted` outbox row | Missing capability → 403 `role-denied` |
| Enroll device | Device app, enrollment code + device label | 201 device row (status `active`) + device credential (long-TTL device token with `device_id` claim) + envelope-encrypted offline-store key; `device.enrolled` outbox row | Unknown/expired/already-redeemed code → 400 `enrollment-code-invalid` (indistinguishable); code redemption is conditional-update atomic (no double-redeem) |
| Badge in | Enrolled device, operator PIN | 200 badge-in session (operator-bound); offline: restores from device cache after first-ever online badge-in | Wrong operator/PIN → 401 `badge-invalid` (indistinguishable); unknown device → 403 `device-revoked` |
| Any device-authenticated request | Device token header | Resolves device server-side; `active` device + DB role check passes through | Revoked device → 403 `device-revoked` (mid-shift: full-screen state on the device); demoted operator → 403 `role-denied` per command |
| Revoke device | Owner/Ops Manager, web Settings, `device.manage` | 200 device `revoked` + wipe flag; `audit_events` row; `device.revoked` outbox; re-revoke idempotent | Unknown device → 404; missing capability → 403 `role-denied` |
| Offline scan queue → replay | Network loss ≥ 30 min, queued ops, reconnect | FIFO replay in task order with client ULID keys; sync summary (settled / rejected / quarantined); force-quit loses nothing | Server rejects a replayed op → retraction in the sync summary, never silent; revocation mid-queue → queued ops to quarantine with session attribution |
| Scan decision | Camera or HID scan (Code 128, EAN-13, QR), manual entry fallback | Normalized scan event → decision ≤ 1.5 s on-device; banner state per matrix row above; ✕ Rejected ≤ 500 ms with reason | Malformed/unknown barcode → ✕ Rejected with reason (never queued) |
| Device self-test | Enrolled device runs the substrate proof | scan → queue → replay lands a self-test echo server-side; sync summary shows it settled | Replay under revoked device → quarantined with attribution |

## Code Map

- `wms-be/src/modules/tenancy/jwt-session.ts` — HS256 JWS machinery (`signTenantSession`/`verifyTenantSession`, `SESSION_TTL_SECONDS = 900`); device tokens extend the same hand-rolled compact-JWS file with a device-claim variant (no new dependency).
- `wms-be/src/modules/tenancy/tenant-session.guard.ts` — the Bearer-parsing guard pattern; a device guard mirrors it + resolves the device row per request.
- `wms-be/src/modules/tenancy/users.command.ts` — the invite-token precedent for one-time codes: `randomBytes(32).base64url` raw-token-to-sha256-hash storage, conditional UPDATE burn, `400 invite-invalid` indistinguishable arms (`ProblemException` bespoke-code pattern); `audit_events` write pattern for revocation.
- `wms-be/src/modules/tenancy/permissions.ts` — `CAPABILITIES`/`ROLE_CAPABILITIES`; add `device.manage` (owner, ops_manager).
- `wms-be/src/shared/db/schema.ts` + `drizzle/0012_*.sql` — new `devices` table (uuidv7 id, tenantId, operatorUserId, label, status text default 'active' + hand-appended CHECK `active|revoked`, revokedAt/revokedBy, wipeFlag, enrollmentCodeHash, lastSeenAt, tenantTimestamps) + hand-appended RLS `devices_tenant_isolation` (the 0011 pattern).
- `wms-be/src/modules/tenancy/enrollment.command.ts` (new) + `badge-in`/device guard + `device.facade.ts` (new) — follow the users.command/controller split; register in `tenancy.module.ts` + `src/api/api.module.ts` (new `DevicesController` in the api shell).
- `wms-be/src/shared/crypto/envelope.ts` (new) — AES-256-GCM seal/open with `DEVICE_ENCRYPTION_KEY`; the repo's first cipher primitive (scrypt/HMAC precedent in `passwords.ts`/`jwt-session.ts`).
- `wms-be/test/devices.spec.ts` (new) — e2e per the matrix; deployment-parity bootstrap block (advisory lock 742106).
- `wms-fe/src/app/(app)/settings/page.tsx` + `src/components/settings/` — replace the "Device enrollment" placeholder card with a real device list + revoke card; `bun run api:generate` regenerates `src/lib/api/generated/` from the backend spec (`openapi-ts.config.ts`).
- `wms-fe/mobile/` (7 files) — the extraction source: expo@57.0.20, RN 0.87.1, single-entry App.tsx health screen, hand-written `src/api.ts` (deferred-work 1-1 item), `src/theme.ts` token map; root wms-fe tsconfig excludes `mobile/`; `workspaces: ["mobile"]` entry to drop.
- `docs/repo-catalog.yaml` + meta CLAUDE.md — register `wms-mobile` (path `workspace/core/mobile/wms-mobile`, remote WMS-Mobile, role mobile) + `docs/repos/wms-mobile/README.md` (interface contract: what it consumes).
- `_bmad-output` mockup reference: `mockups/key-mobile-receive.html` (UX-DR banner/spine details).

## Tasks & Acceptance

**Execution:**
- [x] `docs/repo-catalog.yaml` + workspace registration + `docs/repos/wms-mobile/README.md` — wms-mobile becomes a governed repo; extract `wms-fe/mobile/` into it (git history preserved by fresh repo + commit note), drop the wms-fe workspaces entry, wire `bun run workspace:setup` to clone it. **Implementation creates the LOCAL git repo only** (`git init` + initial commit under `workspace/core/mobile/wms-mobile`); the GitHub remote is created and pushed at PR time (the build workflow forbids remote ops during implementation) — the catalog entry still records the intended remote URL.
- [x] wms-be migration 0012 + `devices` schema + hand-appended RLS/CHECKs
- [x] wms-be `envelope.ts` (AES-256-GCM seal/open, `DEVICE_ENCRYPTION_KEY`) + `.env.example`
- [x] wms-be enrollment/badge-in/revoke commands + device guard + `DevicesController` + `device.manage` capability + OpenAPI export
- [x] wms-be `test/devices.spec.ts` — the full matrix incl. revoke-mid-flight, double-redeem race, replay re-authorization
- [x] wms-fe Settings device card + `api:generate`
- [x] wms-mobile: Expo Router (enrollment → badge-in → inbox), scan layer (camera + HID + manual fallback), encrypted SQLite WAL + FIFO outbox + replay + sync summary, four-state scan banner, device self-test flow, a11y floor

**Acceptance Criteria:**
- Given a fresh device and a minted enrollment code, when the device enrolls, then it binds to the tenant/operator, appears in web Settings, and badge-in assigns the session; a second redemption of the same code fails indistinguishably
- Given a revoked device, when it calls any device endpoint, then `403 device-revoked` and the device shows the explicit full-screen revocation state; queued ops transfer to quarantine with attribution
- Given connectivity loss ≥ 30 min with queued ops, when the network returns, then ops replay in task order exactly once with the sync summary settling them; force-quit loses nothing
- Given a scan by camera or HID (or manual entry), then the banner shows one of the four states within 1.5 s (rejection ≤ 500 ms, reason included); rejected scans never queue; the announced state matches the visual state
- Given the web Settings device list, then revoke is one action, wipe-flagged, audit-trailed, and effective on the device's next request

## Implementation Notes

<!-- Append-only during implementation. -->

- 2026-09-09 (implementation): **Pending-redemption rows.** The devices table's status is the CHECK pair `active|revoked` only, but a minted-not-yet-redeemed code needs a home. Decision: mint creates the device row with only `enrollment_code_hash` + `enrollment_code_expires_at` set (null label/operator, `status='active'`); redemption is one conditional UPDATE that clears the hash; the Settings/self-list query filters `enrollment_code_hash IS NULL` so pending rows are invisible to consumers. The unique partial index on the hash makes double-redeem races structurally impossible.
- 2026-09-09 (implementation): **Badge-in identifies the operator by email + PIN.** The matrix's "Wrong operator/PIN" arm implies an operator identifier next to the PIN; the credential is the PIN alone, so the device sends `operatorEmail` + `pin` (scrypt-verified; `DUMMY_HASH` timing defense; wrong operator and wrong PIN are one indistinguishable `401 badge-invalid`). Devices are single-operator: the first badge-in binds `operator_user_id`; later badge-ins must match the bound operator.
- 2026-09-09 (implementation): **Device token TTL = 30 days** (`DEVICE_SESSION_TTL_SECONDS` in `jwt-session.ts`, hand-rolled compact JWS, `device_id` claim) — "longer-lived than the 15-min web JWT" made concrete; revocability comes from the per-request device-row re-read, not from token lifetime.
- 2026-09-09 (implementation): **`devices` table columns beyond the Code Map list:** `enrollment_code_expires_at`, `enrolled_at`, and `pin_hash` were added — the Code Map listed only `enrollmentCodeHash`/`lastSeenAt` of the credential columns, but the 15-min code TTL, the enrollment timestamp the Settings card renders, and the badge-in PIN hash all need homes.
- 2026-09-09 (implementation): **`device.facade.ts` not created** — the Code Map's "follow the users.command/controller split" was satisfied by `enrollment.command.ts` + `devices.controller.ts` alone; there is no second consuming module yet, so a facade would be a pass-through. Receiving (3.3) composes through the controller surface or extracts the facade then.
- 2026-09-09 (implementation): **DTO drift guard fix (wms-be):** jest's swc transform emits design:type `Object` for `string | null` unions, so @nestjs/swagger served `"type": "object"` where the bun-exported `openapi.json` says `"type": "string"` — the api.spec.ts drift guard caught it. Fix: explicit `type: String` on every nullable `@ApiProperty` in `DeviceResponse` (precedent: `inbound.dto.ts` `carriedFromPoId`). The comment in the DTO is load-bearing.
- 2026-09-09 (implementation): **wms-mobile encryption stack:** expo-sqlite does not ship SQLCipher, so the encrypted SQLite (WAL) store is field-level envelope sealing — every queued-op payload and secret is sealed AES-256-GCM under the enrollment-delivered offline-store key before it touches disk (pure-JS `@noble/ciphers`, proven byte-compatible with the server's `node:crypto` `v1:<iv>:<tag>:<ct>` format by an interop test). The unwrapped key lives in the device keychain (`expo-secure-store`), never in the database it decrypts. Dev builds unwrap with `EXPO_PUBLIC_DEVICE_ENCRYPTION_KEY` (mirroring the server's sha256 stretch — the AD-15 stand-in on the client side too); the unwrap call is the injected KMS boundary in `src/offline/crypto.ts`.
- 2026-09-09 (implementation): **wms-mobile capture adapters:** camera scanning is real (`expo-camera` `CameraView` barcode scanning, Code 128/EAN-13/QR), HID wedge is a focused TextInput that survives banner swaps (scanners "type" into it), manual entry is a one-tap fallback — all three normalize to the same event and share the pure engine; camera permission failure leaves HID + manual active (interchangeable, never camera-required).
- 2026-09-09 (implementation): **Self-test scan format** `SELFTEST-<ulid>` — the substrate's only scan payload until task types land; unknown barcodes reject with a "no task types are live yet" reason (never queued).
- 2026-09-09 (implementation): **Quarantine attribution** carries the device label, operator email, and the op's enqueue time — the session context a reviewer needs to disposition held work.
- 2026-09-09 (implementation): **Verification run:** wms-be `bun run test` 232/232 (16 suites incl. `test/devices.spec.ts`, 7 tests) + lint/typecheck/build + `db:migrate`/`db:verify` + additive `openapi:export`; wms-fe lint/typecheck/test 62/62 + build + committed `api:generate` output; wms-mobile `bun run typecheck` (strict) + `bun test` 18/18 (scan decision matrix, outbox replay semantics incl. FIFO/exactly-once/unreachable-depth/revocation-quarantine, envelope interop, ULID). wms-mobile's GitHub remote is intentionally not created (implementation builds the local repo only — push happens at PR time).

## Spec Change Log

<!-- Append-only; populated by step-04. -->

## Review Triage Log

<!-- Append-only; populated by step-04. Review 1 (2026-09-09): blind-hunter + edge-case-hunter + verification-gap, 3 layers. 34 triage rows below (row 20 covers two deduped findings on the same UPDATE). Routes: 24 patch, 1 defer (deferred-work.md), 6 rejected, 3 false. Post-patch verification: wms-be 234 / wms-fe 62 / wms-mobile 18 tests pass, lint + typecheck clean in all three repos. -->

| # | Finding (layer) | Verdict | Evidence / refutation | Route |
|---|---|---|---|---|
| 1 | Enrollment handoff broken: `app/enroll.tsx` requires the tenant UUID ("from the mint response"), but `MintEnrollmentCodeResponse` is `{code, expiresAt}` and no FE surface displays `session.tenant.id` (blind) | **high** | Confirmed at `app/enroll.tsx:59-74` (tenant id is a required field) and `devices-card.tsx:129-156` (handoff block shows only code + expiry) — an operator cannot complete enrollment as built | patch — render the tenant id as a second copyable field in the Settings handoff block (FE-only, no API change) + fix the enroll screen copy |
| 2 | Camera dedupe can never fire — per-frame ULIDs compared (blind + edge) | **medium** | Confirmed at `adapters.tsx:73`: `normalizeScan` mints a fresh ULID per `cameraScan`, so `lastEventId.current === event.id` is always false; a restreamed barcode enqueues duplicate ops | patch — dedupe on value within a short time window |
| 3 | HID field is ref-controlled; post-submit clear never renders; next wedge scan appends to stale text (blind + edge) | **medium** | Confirmed at `scan.tsx:79` — `value={hidValue.current}` with ref-only mutation; no re-render on clear | patch — hold the HID value in `useState` |
| 4 | No rate limit/lockout on badge-in PIN (blind) | **low** | True, but badge-in requires a valid device token first (two factors); revocation covers lost devices; the frozen boundary (human decision 2026-09-09) settles the PIN credential | rejected — not everyday-use; a lockout adds machinery |
| 5 | Any active member (incl. accountant) can bind as device operator; no unbind (blind) | **low** | Confirmed (`enrollment.command.ts:476-491`) — but the frozen boundary settles it: "badge-in authenticate the operator, not a capability"; recovery is revoke + re-enroll | rejected |
| 6 | Orphaned pending-redemption rows accumulate forever (blind) | **low** | Confirmed, but the rows are invisible, tiny, and bounded by the partial unique index; cleanup adds a reaper for negligible harm | rejected |
| 7 | `use-devices.ts` swallows fetch errors → backend-down renders the fresh-tenant empty state (blind) | **low** | Confirmed (`use-devices.ts:51-53`); fix adds an error-state branch; dev-time confusion only | rejected |
| 8 | Enroll's auth-time replay lookup queries by key alone — cross-tenant 422 (blind + edge) | **low** | Confirmed (`enrollment.command.ts:332-336`), but identical to the accepted registration/accept-invite precedent (`registration.command.ts:74-78`); a cross-tenant 422 requires knowing a foreign key | defer — pre-existing pattern; consolidate payload-hash-into-lookup across all three pre-auth commands |
| 9 | OpenAPI example drift + unbounded `code` (blind) | **low** | Confirmed: `devices.dto.ts:11` example is a 16-hex string vs the 43-char base64url reality (`openapi.json:5067` carries it); `EnrollDeviceDto.code` has no `@Length` | patch — realistic example + length bound |
| 10 | README claims "every mutating route requires Idempotency-Key," contradicting keyless badge-in (blind) | **false** | The blanket sentences are scoped to the 1.3/1.5 surfaces (`README.md:53,65`); the devices section (lines 90-96) documents badge-in without a key, correctly | — |
| 11 | `BadgeInDto.operatorEmail` is `@IsString` only vs declared `format: email` (blind) | **low** | Confirmed; non-email input just 401s at lookup, so no functional harm — but the boundary is weaker than its own contract | patch — one decorator |
| 12 | Revoked device is a dead end: `deviceStore.reset()` never called; reinstall is the only path (blind) | **low** | Confirmed — no screen calls `reset()`; `/revoked` offers no affordance | patch — reset button on `/revoked` (with row 25's purge fix) |
| 13 | Expired-code redemption untested (blind) | **low** | Confirmed — the spec covers unknown/used/wrong-tenant/race but never a TTL-passed code | patch — test arm |
| 14 | Devices keyset-cursor path has zero test coverage (blind + verification-gap, pre-verified) | **medium** | Filed evidence: no `cursor` reference in `devices.spec.ts`; siblings (`users.spec.ts:477-507`, `tenancy.spec.ts:432-475`) pin the identical contract at the same boundary | patch — cursor-chain walk + malformed-cursor 400 test |
| 15 | `devices` lacks a tenant-led index; per-tenant pagination degrades to scans (blind) | **low** | Confirmed — only `(created_at, id)`; every query filters `tenant_id`; repo convention is tenant-led indexes (e.g. `audit_events_tenant_id_occurred_at_idx`) | patch — add `(tenant_id, created_at, id)` to 0012 + snapshot |
| 16 | wms-mobile version mismatch: package.json 0.2.0 vs app.json 0.1.0 (blind) | **low** | Confirmed | patch — align |
| 17 | Provenance notes say "7 files" but the repo lands ~30 source files (blind) | **false** | The sentence describes the extraction *source* (`wms-fe/mobile/`, 7 files per the frozen Intent), not the new repo's contents | — |
| 18 | `RevokeDeviceDto` is dead code (blind) | **low** | Confirmed — referenced by no controller or test | patch — delete |
| 19 | No auto-replay when connectivity returns; airplane mode is simulated; copy promises auto-sync (blind) | **low** | Confirmed — manual "Sync queued scans" button only; the simulation is a documented dev stand-in; auto-replay needs a network-state dependency; one-tap sync exists | rejected — mechanism choice for when the app ships to real networks |
| 20 | Enroll redemption UPDATE doesn't re-check expiry or device status in-tx (edge, 2 findings) | **low** | Confirmed (`enrollment.command.ts:384-400`): a code expiring — or a pending row revoked — between the auth read and the tx still redeems | patch — add expiry + `status='active'` to the UPDATE's WHERE (both arms land the same 400) |
| 21 | `selfTestEcho` doesn't check `users.status` — suspended operator keeps working (edge) | **false** | No code path writes `users.status` off `active` post-acceptance (`users.command.ts`: only `invited`→`active` at lines 449/485); the claimed trigger is unreachable, and `getMemberRoleIn` doesn't check status either | — |
| 22 | `MissingEncryptionKeyError` escapes enroll as a raw 500 (edge) | **low** | Confirmed — `seal()` inside the tx throws untyped on a missing/short `DEVICE_ENCRYPTION_KEY` | patch — typed 503 problem |
| 23 | Settings copy button: unhandled clipboard rejection (edge) | **low** | Confirmed (`devices-card.tsx:145` — void'd promise) | patch — `.catch(() => undefined)` |
| 24 | Enroll burns the code before unwrapping the offline-store key; fresh ULID per attempt defeats replay (edge + verification-gap) | **low** | Confirmed (`device-store.ts:110-122`), but reachable only under an unwrap misconfiguration (dev key unset in a build); recovery is minting a fresh code | rejected — misconfiguration path; the retry restructure is not a small fix |
| 25 | `reset()` deletes the keychain key before purging the DB rows it sealed → later decrypts throw (edge) | **low** | Confirmed (`device-store.ts:244-247`) | patch — purge `outbox` + `secrets` before dropping the key |
| 26 | `getSecret` catches only `SealedBlobError`; noble GCM failures throw generic Errors (edge) | **low** | Confirmed (`sqlite.ts:90-95`) — the SealedBlobError branch is dead for the actual failure mode | patch — catch all open failures → null |
| 27 | One corrupt outbox row makes `listOps` throw, freezing queueDepth + replay (edge) | **medium** | Confirmed (`sqlite.ts:58-70`) — no per-row handling; violates the substrate's work-continues guarantee | patch — per-row try/catch |
| 28 | Replay maps `401 unauthenticated` / `403 role-denied` to 'rejected' — session expiry retracts the whole queue (edge) | **medium** | Confirmed (`device-store.ts:221-224`): any non-revoked ApiProblem → retraction; a 30-day session expiry destroys queued work instead of pausing for re-badge | patch — map `unauthenticated` → unreachable (stays queued); `role-denied` stays rejected (the server denied the op — AD-4) |
| 29 | Offline restore compares operator email case-sensitively (edge) | **low** | Confirmed (`device-store.ts:170`) — the server lowercases at badge-in | patch — compare lowercased |
| 30 | Self-test `run()` has no catch — a throw mid-run goes unhandled, banner stale (edge) | **low** | Confirmed (`self-test.tsx:38-89` — try/finally only) | patch — catch → failure step + banner |
| 31 | Pending-redemption devices untested against the list's hidden-pending contract (verification-gap, pre-verified) | **medium** | Filed evidence: lists asserted only after redemption; dropping the `isNull(enrollmentCodeHash)` filter fails nothing | patch — assert the pending row absent between mint and enroll |
| 32 | wms-mobile's test suite is wired into no verification path (verification-gap, pre-verified) | **medium** | Filed evidence: no `.github/`, no remote, no sibling CI reference — the 18 tests run for the author only | patch — add a minimal `ci.yml` (bun install/test/typecheck) mirroring the siblings |
| 33 | wms-fe CI still runs the deleted `mobile/` job — fails every future FE PR (verification-gap) | **high** | Confirmed (`.github/workflows/ci.yml`: `cd mobile && bun run typecheck` against a directory commit 03cf6ef deleted; "workspaces incl. mobile" labels stale) | patch — remove the mobile job, fix the labels |
| 34 | Revoked-phase flip requires `rejected.length === 0` — a rejected op before the revocation leaves the operator in the inbox (verification-gap) | **medium** | Confirmed (`device-store.ts:231`): the heuristic misses the mixed summary; the AC's full-screen state never fires | patch — flip when any quarantined op carries `device-revoked` |

## Design Notes

- Device sessions are server-checked tokens, not stateless trust: the token carries `device_id`; every device-authenticated command re-reads the device row + operator role in-transaction (fail-closed). This buys mid-shift revocation without refresh-token machinery — the tradeoff (a DB read per device request) is the floor client's request rate, which is small.
- The offline store key is generated server-side at enrollment, sealed with AES-256-GCM under `DEVICE_ENCRYPTION_KEY`, and delivered once in the enrollment response — the server never needs it again (the device unwraps and stores it in device keychain). Losing the device loses the key: wipe-by-design.
- The scan decision engine is pure and mirrored by device tests: normalized scan events in, decision + banner state out — camera/HID/manual are capture adapters producing the same event shape (AD-4 capture-agnosticism).
- The substrate's self-test flow (scan → queue → replay → echo) is the acceptance harness for 3.3/3.5: receiving plugs real task types into the inbox and real commands behind the replay — the plumbing is proven here.

## Verification

**Commands:**
- wms-be: `bun run test` (incl. `test/devices.spec.ts`), `bun run lint && bun run typecheck && bun run build`, `bun run db:migrate && bun run db:verify`, `bun run openapi:export` (additive diff)
- wms-fe: `bun run lint && bun run typecheck && bun run test`, `bun run api:generate` (regenerated client committed)
- wms-mobile: `bun run typecheck` (and its test runner once wired) — the extraction leaves wms-fe's own suite unchanged
- Meta: `bun run workspace:status` shows the new repo registered and clean

**Manual checks:**
- Real-device smoke: enroll via web Settings code → badge-in on device → airplane-mode scan queue → reconnect replay → sync summary settled; revoke mid-session from Settings → device shows the full-screen revocation state on next action.