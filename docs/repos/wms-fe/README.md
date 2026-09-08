# wms-fe (frontend)

- Remote: https://github.com/chinnisasi/WMS-FE.git
- Local path: `workspace/core/frontend/wms-fe`
- Role: frontend
- Default branch: main

Durable notes about this repo (architecture, conventions, how it talks to `wms-be`) go here. Repo-local operational docs (setup, scripts, etc.) stay inside the repo itself.

## Stack & structure (Story 1.2)

- Next.js 16.3 App Router (React 19, Tailwind 4, TypeScript 6, bun as package manager). Dev server runs on **:3001** (`bun run dev`) so the backend keeps :3000.
- Design-token layer in `src/app/globals.css` mirrors DESIGN.md (`_bmad-output/planning-artifacts/ux-designs/ux-WMS-Meta-2026-09-08/`): brand delta `#1E4E8C` / `#16794C` / `#B45309` with dark-mode foreground pairs, 4/6/8px radius scale, 28px semibold tabular-nums `kpi` style. Pinned by `src/lib/brand-tokens.test.ts`.
- **Route groups:** `src/app/(app)/` holds the 12 in-shell surfaces (Overview … Settings — everything rendering `AppShell`); `src/app/(auth)/` holds `/register` and `/login` outside the shell (signup must not render the app sidebar). The root layout is document chrome only.
- **Auth flow (Story 1.2):** `/register` posts tenant registration with a fresh ULID `Idempotency-Key` per submit, then routes to `/login?email=…` (registration mints no token). `/login` calls sign-in and stores the session in localStorage (`wms-session` key, contract in `src/lib/auth.ts`: token + tenant + expiry) — an expired token reads as signed-out. Errors branch on the problem-details `code` (`duplicate-email`, `unauthenticated`, `idempotency-key-reuse`), never on prose. The Settings page hosts warehouse creation (fresh ULID key per submit; duplicates surface `duplicate-warehouse-code` naming the code) and the sidebar switcher lists warehouses (code+name, "Warehouse N of M"), refreshed via the `wms-warehouses-changed` window event. The picked warehouse is a localStorage convenience (`src/lib/warehouses.ts`) — the backend has no active-warehouse concept until Epic 2. localStorage-derived UI state goes through `useSyncExternalStore` subscriptions (`subscribeSession`, `subscribeActiveWarehouse`) — never synchronous setState in effects.
- Sidebar IA skeleton: 12 surfaces (Overview, Inventory, Inbound, Outbound, Moves, Conflicts & Reviews, Notifications, Replenishment, Channels, Compliance, Reports / Audit, Settings) — placeholder routes except the tenancy features above; interaction primitives (⌘K palette: Esc closes, Enter commits; single modal layer) in `src/components/shell/`; cursor-pagination data-table primitive in `src/components/data-table/`.
- **Mobile lives in this repo for now**: `mobile/` is a self-contained Expo 57 app (own package.json/tsconfig/app.json, zero imports from the web app) so extraction to its own repo is mechanical. Story 1.1 human decision — do not register a wms-mobile repo yet.

## Interface Contract (what this repo depends on from `wms-be`)

Keep this current whenever a cross-repo change lands — this is what lets an agent catch "this backend change breaks the frontend" *before* making the change, not after.

- Backend base URL / API version consumed: `NEXT_PUBLIC_API_BASE_URL` (default `http://localhost:3000/api/v1`), api document version 1.0.0
- Endpoints called (Story 1.1 + 1.2 scope): `GET /api/v1/health` (Overview page health check, live per request); `POST /api/v1/tenants` + `POST /api/v1/tenants/sign-in` (auth pages); `POST /api/v1/tenants/{tenantId}/warehouses` (Settings) + `GET /api/v1/tenants/{tenantId}/warehouses` (sidebar switcher) — the warehouse pair requires `Authorization: Bearer <token>` from sign-in and an `Idempotency-Key` on the create. See `docs/repos/wms-be/README.md` for the full request/response/error contract.
- Shared types/DTOs: **generated, never hand-written** — `src/lib/api/generated/` via `@hey-api/openapi-ts` 0.99.0 (pinned). Pipeline: after any wms-be contract change run `bun run openapi:export` in wms-be, then `bun run api:generate` here, then commit the regenerated client. The generated client reads the spec from `../../backend/wms-be/openapi/openapi.json` (workspace-relative). Both CI pipelines guard this: wms-be fails if the committed spec doesn't match the code; wms-fe fails if the committed client doesn't match the spec.
  - **Mobile exception (temporary):** `mobile/src/api.ts` hand-writes `HealthResponse` until `mobile/` is extracted to its own repo with its own codegen (tracked in `_bmad-output/implementation-artifacts/deferred-work.md`). Until then, treat a wms-be `HealthResponse` change as also breaking mobile.
  - **Import convention:** import SDK functions via `src/lib/api/client.ts` — it applies the base-URL config to the shared generated client **and** attaches the stored bearer token from `readSession()` via a request interceptor. Importing the generated barrel (`@/lib/api/generated`) directly skips that config and calls whatever origin the bundle was served from, unauthenticated.
- Auth mechanism expected from the backend: 15-minute HS256 JWT from `POST /tenants/sign-in` (`{accessToken, tokenType: 'Bearer', expiresInSeconds, tenant}`), stored in localStorage, attached by the interceptor; **no refresh token** — when it expires the app reads as signed-out and the user signs in again.
- Env vars this repo needs pointed at `wms-be`: `NEXT_PUBLIC_API_BASE_URL` (web; see `.env.example`) and `EXPO_PUBLIC_API_BASE_URL` (mobile; same default). Both are **inlined at build time** by Next.js/Expo — setting them at deploy runtime does nothing; retargeting the backend requires a rebuild.
