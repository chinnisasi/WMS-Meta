# wms-mobile (mobile)

- Remote: https://github.com/chinnisasi/WMS-Mobile.git
- Local path: `workspace/core/mobile/wms-mobile`
- Role: mobile
- Default branch: main

Durable notes about this repo (architecture, conventions, what it consumes from `wms-be`) go here. Repo-local operational docs (setup, scripts, env) stay in the repo's own `README.md`.

## Provenance

Extracted from `wms-fe/mobile/` at Story 3.2 (7 files, expo@57.0.20 / RN 0.87.1) into a fresh repository — that history lives in `wms-fe`; the extraction commit in `wms-fe` and the initial commit here record the move. The GitHub remote is created and pushed at PR time (the catalog entry records the intended URL).

## Stack & structure (Story 3.2)

- Expo 57 / RN 0.87 with **Expo Router** (`app/` — the gate routes on the device phase: enrollment → badge-in → task inbox; full-screen revocation state). `bun` only.
- `src/scanning/` — the pure capture-agnostic decision engine: camera (`expo-camera`), HID keyboard wedge, and manual entry normalize to the same event; decisions are synchronous functions (rejection renders inside the 500 ms budget); rejected scans never queue.
- `src/offline/` — encrypted SQLite (WAL) offline store: every queued-op payload and secret is sealed AES-256-GCM under the enrollment-delivered offline-store key (pure-JS `@noble/ciphers`, byte-compatible with wms-be's `node:crypto` envelope — `v1:<iv>:<tag>:<ct>` base64 format); FIFO outbox + replay with client ULID idempotency keys (exactly-once), sync summary (settled / rejected / quarantined with session attribution). The unwrapped key lives in the device keychain (`expo-secure-store`), never in the database it decrypts.
- `src/state/device-store.ts` — the phase machine (unenrolled → enrolled → badged → revoked).
- a11y floor (UX-DR22): fill + glyph + word banner (never color-only), platform accessibility announcements, dynamic type honored (no `maxFontSizeMultiplier` caps), instant banner swaps under Reduce Motion, ≥48dp targets.
- Microcopy: verbs and numbers, no exclamation marks; the queue chip is amber depth, never red/error.

## Interface Contract (what this repo consumes from `wms-be`)

Keep this current whenever a cross-repo change lands.

- Base URL: `EXPO_PUBLIC_API_BASE_URL` (default `http://localhost:3000/api/v1`; inlined at bundle time). Hand-written API layer in `src/api.ts` (no codegen — the generated-client pipeline lives in wms-fe).
- Endpoints called (Story 3.2 scope; all RFC 9457 problem+json, branched on machine-readable `code`):
  - `GET /api/v1/health` — boot check.
  - `POST /api/v1/tenants/{tenantId}/devices/enroll` (**unauthenticated**; `Idempotency-Key` ULID) `{code, label, pin}` → `201` `{device: {id, tenantId, label}, deviceToken, expiresInSeconds, offlineStoreKeySealed}` — the one-time enrollment-code redemption; the sealed offline-store key unwraps through the KMS boundary (dev builds mirror wms-be's sha256-stretched `DEVICE_ENCRYPTION_KEY`). Unknown/expired/already-redeemed code / wrong-tenant path → one indistinguishable `400 enrollment-code-invalid`; pin shape 4–6 digits → `400 validation-failed`; same-key replay re-serves the credential.
  - `POST /api/v1/tenants/{tenantId}/devices/badge-in` (Bearer **device token**) `{operatorEmail, pin}` → `200` `{accessToken, tokenType, expiresInSeconds, operator: {id, email, role}, device: {id, label}}` — mints the revocable operator-bound device session; first-ever badge-in needs connectivity, afterwards the device restores from its sealed cache (UX-DR6). Wrong operator/PIN → indistinguishable `401 badge-invalid`; unknown/revoked device → `403 device-revoked`.
  - `POST /api/v1/tenants/{tenantId}/devices/self-test/echo` (Bearer **badge-in session**; `Idempotency-Key`) `{payload}` → `200` `{deviceId, operatorUserId, echoed, receivedAt}` — the substrate's replay target. `401 unauthenticated` on a bare (badge-in-less) device credential; `403 device-revoked` / `403 role-denied` per command (device status + operator role re-read from the DB on every call — the token is transport, never authority).
- Auth material held on device: the 30-day device token (enrollment), the badge-in session (revocable server-side — no refresh machinery), the operator email (cached for badge-in restore). Revocation surfaces as `403 device-revoked` on the next request → full-screen state + queued ops move to quarantine with session attribution.
- Queue replay semantics the backend guarantees: same key + same payload re-serves the original response (exactly-once); replay is re-authorized against device status + role at the server (AD-4) — a revoked device's remaining queue quarantines client-side.