# wms-be (backend)

- Remote: https://github.com/chinnisasi/WMS-BE.git
- Local path: `workspace/core/backend/wms-be`
- Role: backend
- Default branch: main

Durable notes about this repo (architecture, conventions, what it exposes to `wms-fe`) go here. Repo-local operational docs (setup, scripts, etc.) stay inside the repo itself.

## Stack & structure (Story 1.2)

- NestJS 12 modular monolith (TypeScript 6, bun as package manager), api shell (`src/api/`) + jobs shell (`src/jobs/`), 13 spine module folders under `src/modules/` per ARCHITECTURE-SPINE.md §Structural Seed: tenancy, catalog, inventory, inbound, putaway, outbound, movements, replenishment, channels, compliance, reporting, carriers, notifications. **Tenancy owns the first real tables** (`tenants`, `users`, `warehouses`, `idempotency_keys` — all uuidv7 PKs with `tenant_id` stamped on every row); other spine modules are still stubs.
- Modules own their tables exclusively and talk via interfaces/domain events — the tenancy command services (registration, sign-in, warehouse create) are the command-layer precedent: validate → hash → write → emit domain event through the seam (`LoggingEventBus`, `EVENT_BUS` token).
- Shared primitives in `src/shared/`: UUIDv7 ids, ULID idempotency keys, ISO-8601 UTC timestamps, integer paise, base-UoM integer quantities, GST basis points, cursor pagination, RFC 9457 problem-details (machine-readable `code`), idempotency/event-bus/outbox seams. The `Database` DI provider (`DATABASE` token in SharedModule) is a lazy proxy — boot never requires `DATABASE_URL`; the first query connects.
- Drizzle (0.45.2) migrations on Postgres (`drizzle/`, runner `bun run db:migrate`, needs `DATABASE_URL`; dev DB via the repo's `docker-compose.yml` — postgres:18-alpine on host port 55432, user/password/db `wms`).
- **Multi-tenancy mechanism:** every table carries `tenant_id`; the app sets it per transaction via `select set_config('app.tenant_id', $1, true)` (see `src/modules/tenancy/tenant-scope.ts`) and Postgres RLS is enabled with `USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid)` policies on all four tables (migration `0001_greedy_scarecrow.sql`). **The empty-string NULLIF is load-bearing** — PG 18's `current_setting(..., true)` returns `''` (not NULL) after a transaction-local value expires, and a bare `''::uuid` cast throws. **Caveat: RLS is defense-in-depth only for non-superuser roles** — the docker-compose `wms` user is a superuser and bypasses RLS even with FORCE; the deployed app role must be a non-superuser (verified by the `wms_rls_probe` e2e test).
- **Idempotency:** real storage landed in the tenancy module (`idempotency_keys`: unique `(tenant_id, key)`, payload hash, response snapshot). Replays are de-duped **in the same transaction** as the write; same key + same payload replays the original response, same key + different payload → `422 idempotency-key-reuse`. Registration (no tenant context yet) looks up by key alone and stamps the new tenant id on the row.
- **Sessions:** 15-minute HS256 JWTs hand-signed with `node:crypto` (`src/modules/tenancy/jwt-session.ts`; claims `sub` + `tenant_id`, `exp` ≤ 900 s) — no refresh tokens. The signing secret is `JWT_SECRET` (≥ 16 chars, required at sign-in/verification time). Passwords are scrypt hashes via `node:crypto`.
- **Zero-warehouse invariant:** `TenancyService.requireActiveWarehouse(tenantId)` throws `422 no-active-warehouse` — Epic 2 consumes this before any stock write.

## Interface Contract (what this repo provides to `wms-fe`)

Keep this current whenever a cross-repo change lands — this is what lets an agent catch "this backend change breaks the frontend" *before* making the change, not after.

- API base path / version exposed: `/api/v1` (document version 1.0.0)
- Endpoints offered (Story 1.1 + 1.2 scope): `GET /api/v1/health`, `POST /api/v1/echo`, `GET /api/v1/openapi.json` (Swagger UI at `/api/docs`); plus the tenancy surface —
  - `POST /api/v1/tenants` `{name, ownerEmail, password}` → `201` tenant + owner user (no password material exposed). Requires an `Idempotency-Key` header (missing/malformed → `400`; key reuse with a different payload → `422 idempotency-key-reuse`). Owner-email uniqueness is **global** (one tenant per email); duplicate → `409 duplicate-email`.
  - `POST /api/v1/tenants/sign-in` `{email, password}` → `200` `{accessToken, tokenType: 'Bearer', expiresInSeconds: 900, tenant}`. Unknown email vs wrong password are indistinguishable → `401 unauthenticated`.
  - `POST /api/v1/tenants/{tenantId}/warehouses` `{code, name}` → `201` warehouse; requires the sign-in JWT (`Authorization: Bearer`) **and** the path tenantId must match the token's `tenant_id` (mismatch → `403 permission-denied`); requires `Idempotency-Key`; duplicate code → `409 duplicate-warehouse-code` naming the code.
  - `GET /api/v1/tenants/{tenantId}/warehouses?cursor&limit` → `200` `{items, nextCursor}` (keyset pagination, same auth + tenant-ownership rules).
  - All error responses are RFC 9457 problem+json with machine-readable `code` and `instance`.
- OpenAPI document (the contract): served at `GET /api/v1/openapi.json`; exported to `openapi/openapi.json` via `bun run openapi:export`. The frontend generates its typed client from this file — after any backend contract change run `bun run openapi:export` here, then `bun run api:generate` in wms-fe, and commit the regenerated client.
- Shared types/DTOs (source of truth, how the frontend consumes them): generated in wms-fe under `src/lib/api/generated/` via `@hey-api/openapi-ts` — no hand-written API types on the consuming side. Response DTOs live next to the controllers (`HealthResponse`, `EchoResponse`, tenancy DTOs in `src/modules/tenancy/tenancy.dto.ts`).
- Auth mechanism offered: 15-minute HS256 JWT from `POST /tenants/sign-in` (`JWT_SECRET` env, no refresh token yet — sign in again on expiry). Warehouse endpoints require it; `GET /health` and `POST /echo` stay anonymous.
- Breaking-change policy (deprecation window, versioning approach): the versioned document (`/api/v1` + doc `info.version`) is the contract; additive changes only while stories land in order — breaking changes to consumed shapes must be coordinated through the wms-fe contract update first (backend lands before the frontend that consumes it).
