# wms-fe (frontend)

- Remote: https://github.com/chinnisasi/WMS-FE.git
- Local path: `workspace/core/frontend/wms-fe`
- Role: frontend
- Default branch: main

Durable notes about this repo (architecture, conventions, how it talks to `wms-be`) go here. Repo-local operational docs (setup, scripts, etc.) stay inside the repo itself.

## Stack & structure (Story 1.1)

- Next.js 16.3 App Router (React 19, Tailwind 4, TypeScript 6, bun as package manager). Dev server runs on **:3001** (`bun run dev`) so the backend keeps :3000.
- Design-token layer in `src/app/globals.css` mirrors DESIGN.md (`_bmad-output/planning-artifacts/ux-designs/ux-WMS-Meta-2026-09-08/`): brand delta `#1E4E8C` / `#16794C` / `#B45309` with dark-mode foreground pairs, 4/6/8px radius scale, 28px semibold tabular-nums `kpi` style. Pinned by `src/lib/brand-tokens.test.ts`.
- Sidebar IA skeleton: 12 surfaces (Overview, Inventory, Inbound, Outbound, Moves, Conflicts & Reviews, Notifications, Replenishment, Channels, Compliance, Reports / Audit, Settings) — non-functional placeholder routes; interaction primitives (⌘K palette: Esc closes, Enter commits; single modal layer) in `src/components/shell/`; cursor-pagination data-table primitive in `src/components/data-table/`.
- **Mobile lives in this repo for now**: `mobile/` is a self-contained Expo 57 app (own package.json/tsconfig/app.json, zero imports from the web app) so extraction to its own repo is mechanical. Story 1.1 human decision — do not register a wms-mobile repo yet.

## Interface Contract (what this repo depends on from `wms-be`)

Keep this current whenever a cross-repo change lands — this is what lets an agent catch "this backend change breaks the frontend" *before* making the change, not after.

- Backend base URL / API version consumed: `NEXT_PUBLIC_API_BASE_URL` (default `http://localhost:3000/api/v1`), api document version 1.0.0
- Endpoints called (Story 1.1 scope): `GET /api/v1/health` (Overview page health check, live per request)
- Shared types/DTOs: **generated, never hand-written** — `src/lib/api/generated/` via `@hey-api/openapi-ts` 0.99.0 (pinned). Pipeline: after any wms-be contract change run `bun run openapi:export` in wms-be, then `bun run api:generate` here, then commit the regenerated client. The generated client reads the spec from `../../backend/wms-be/openapi/openapi.json` (workspace-relative).
- Auth mechanism expected from the backend: none yet (arrives with Story 1.2+ tenancy)
- Env vars this repo needs pointed at `wms-be`: `NEXT_PUBLIC_API_BASE_URL` (see `.env.example`)