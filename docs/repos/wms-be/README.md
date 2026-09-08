# wms-be (backend)

- Remote: https://github.com/chinnisasi/WMS-BE.git
- Local path: `workspace/core/backend/wms-be`
- Role: backend
- Default branch: main

Durable notes about this repo (architecture, conventions, what it exposes to `wms-fe`) go here. Repo-local operational docs (setup, scripts, etc.) stay inside the repo itself.

## Stack & structure (Story 1.1)

- NestJS 12 modular monolith (TypeScript 6, bun as package manager), api shell (`src/api/`) + jobs shell (`src/jobs/`), 13 spine module folders under `src/modules/` per ARCHITECTURE-SPINE.md §Structural Seed: tenancy, catalog, inventory, inbound, putaway, outbound, movements, replenishment, channels, compliance, reporting, carriers, notifications. Domain schemas start in stories 1.2–1.4 — no domain tables exist yet.
- Shared primitives in `src/shared/`: UUIDv7 ids, ULID idempotency keys, ISO-8601 UTC timestamps, integer paise, base-UoM integer quantities, GST basis points, cursor pagination, RFC 9457 problem-details (machine-readable `code`), idempotency/event-bus/outbox seams.
- Drizzle (0.45.2) migrations on Postgres (`drizzle/`, runner `bun run db:migrate`, needs `DATABASE_URL`; dev DB via the repo's `docker-compose.yml` — postgres:18-alpine on host port 55432, user/password/db `wms`).

## Interface Contract (what this repo provides to `wms-fe`)

Keep this current whenever a cross-repo change lands — this is what lets an agent catch "this backend change breaks the frontend" *before* making the change, not after.

- API base path / version exposed: `/api/v1` (document version 1.0.0)
- Endpoints offered (Story 1.1 scope only): `GET /api/v1/health`, `POST /api/v1/echo` (accepts a JSON object only — non-object or malformed bodies get a `400` problem+json with `code: validation-failed`), `GET /api/v1/openapi.json` (Swagger UI at `/api/docs`); all error responses are RFC 9457 problem+json with machine-readable `code` and `instance`
- OpenAPI document (the contract): served at `GET /api/v1/openapi.json`; exported to `openapi/openapi.json` via `bun run openapi:export`. The frontend generates its typed client from this file — after any backend contract change run `bun run openapi:export` here, then `bun run api:generate` in wms-fe, and commit the regenerated client.
- Shared types/DTOs (source of truth, how the frontend consumes them): generated in wms-fe under `src/lib/api/generated/` via `@hey-api/openapi-ts` — no hand-written API types on the consuming side. Response DTOs live next to the controllers (`HealthResponse`, `EchoResponse`).
- Auth mechanism offered: none yet (Story 1.1 has no auth; short-lived JWT + refresh arrives with tenancy work)
- Breaking-change policy (deprecation window, versioning approach): the versioned document (`/api/v1` + doc `info.version`) is the contract; additive changes only while stories land in order — breaking changes to consumed shapes must be coordinated through the wms-fe contract update first (backend lands before the frontend that consumes it).
