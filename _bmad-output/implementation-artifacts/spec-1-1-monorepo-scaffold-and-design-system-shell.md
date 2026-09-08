---
title: 'Story 1.1 — Monorepo scaffold and design system shell'
type: 'feature'
created: '2026-09-08'
status: 'done'
baseline_commit: 'meta 1077681dec7d6371d4f43d2f7751d335b01c5be0 · wms-be 481739843441876a9fa7c56d4f7f3f5958af31e3 · wms-fe 9dc71cee1457db3cf807e8a7841ea310311abf94'
route: 'dispatch'
review_loop_iteration: 0
context: ['_bmad-output/implementation-artifacts/epic-1-context.md']
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** No code exists anywhere — `wms-be` and `wms-fe` are README-only repos. Every later story (and epic) depends on the scaffold, migration pipeline, OpenAPI contract generation, and design-token layer being established exactly once, so nobody re-decides structure.

**Approach:** Stand up the substrate per the architecture spine: `wms-be` as the NestJS 12 modular-monolith shell (shared primitives, 13 module folders, api/ + jobs/ shells, Drizzle migrations on Postgres, health check), `wms-fe` as the Next.js 16 App Router shell carrying the DESIGN.md token layer, sidebar IA skeleton, interaction primitives, and the responsive/WCAG contract, with an OpenAPI pipeline whose generated types the web shell consumes. Mobile (Expo 57) is scaffolded **inside `wms-fe` for now** — decision below.

**Decisions (human-owned):**
- **Mobile placement:** the Expo 57 app lives inside `wms-fe` (e.g. `mobile/` app folder in that repo) until extraction; the wms-mobile repo is NOT created or registered in this story. Extraction to its own repo is expected later — structure the `mobile/` folder so the move is mechanical.
- **wms-fe cleanup:** the accidental meta-repo commit (`6da50fc`) is cleaned by a dedicated chore commit on main removing those files, committed BEFORE any scaffold work, keeping the scaffold commit pure.

## Boundaries & Constraints

**Always:**
- Deterministic primitives from day one (AD-9): UUIDv7 ids, ISO-8601 UTC timestamps, integer base-UoM quantities, integer paise, GST basis points; RFC 9457 problem-details errors with machine-readable `code`; cursor pagination helpers.
- OpenAPI is the contract (AD-8): wms-be emits a versioned OpenAPI document; wms-fe consumes generated types (`openapi-typescript` / `@hey-api/openapi-ts`, pinned versions) — the pipeline runs end-to-end on a health/echo endpoint.
- Module skeleton = one folder per spine module, ownership boundaries as folder discipline; shared/ holds primitives (AD-9), problem-details, idempotency, event bus + outbox relay seams (empty stubs are fine).
- Drizzle migration tooling configured with spine conventions; prove it with one trivial migration. Bun as the package manager everywhere. Token layer per DESIGN.md: brand delta `#1E4E8C` / `#16794C` / `#B45309` with dark-mode foreground pairs; 28px tabular-nums `kpi` style; 4/6/8px radius scale; sidebar IA skeleton (all 12 surfaces, non-functional routes).

**Never:**
- No domain tables or business logic — tenant/zone/bin/SKU schemas start in stories 1.2–1.4; the only endpoints are health/OpenAPI/echo.
- No hand-written API types on the consuming side; no second brand hue, no gradients, no decorative color coding (UX-DR1); banned patterns list (UX-DR25: infinite scroll, hover-only touch affordances, modal stacks > 1 deep, celebratory animation, badge-count spam).
- No auth, no tenancy tables, no Valkey, no CI/CD beyond lint+test workflows; no `git add -f` of child-repo files into the meta repo.
- No wms-mobile repo creation or `docs/repo-catalog.yaml` changes — the mobile app is not registered as a separate repo in this story.

</frozen-after-approval>

## Code Map

- `workspace/core/backend/wms-be/` -- fresh (README-only, remote `WMS-BE`); receives the NestJS scaffold. Backend lands **first** (CLAUDE.md ordering).
- `workspace/core/frontend/wms-fe/` -- fresh + accidental meta-repo commit (`6da50fc`) with uncommitted deletions; cleanup chore lands first, then the Next.js + mobile scaffold.
- `docs/repos/wms-be/README.md`, `docs/repos/wms-fe/README.md` -- update interface contracts (OpenAPI doc URL, base path) after the scaffold lands.
- `_bmad-output/planning-artifacts/ux-designs/ux-WMS-Meta-2026-09-08/DESIGN.md` -- authoritative token source (do not re-derive hues/radii from memory).
- `CLAUDE.md` (meta) -- cross-repo ordering: backend first, frontend second, meta repo last; `bun run workspace:push` enforces it.

## Tasks & Acceptance

**Execution:**
- [x] `workspace/core/frontend/wms-fe/**` (cleanup) -- chore commit on main deleting the accidentally-committed meta-repo files (already deleted in working tree) -- establishes a clean tree before scaffolding, per human decision.
- [x] `workspace/core/backend/wms-be/**` -- scaffold NestJS 12 + TS 6: `src/shared/` (primitives, problem-details filter, idempotency seam), `src/modules/<13 module folders>`, `src/api/` (health + OpenAPI controllers), `src/jobs/` shell; Drizzle ≥0.45.2 config + one trivial migration; Jest suite green -- the substrate every module drops into.
- [x] `workspace/core/backend/wms-be/src/api/**` -- health endpoint + versioned OpenAPI document (served JSON) -- makes AD-8's contract real and testable.
- [x] `workspace/core/frontend/wms-fe/**` -- scaffold Next.js 16.3 App Router: token layer from DESIGN.md (colors, `kpi` style, radius scale, dark-mode pairs), sidebar IA skeleton with 12 surface routes, ⌘K palette + Esc/Enter primitives, responsive contract (1024/768 breakpoints), cursor-pagination + data-table primitives stubbed -- the shell later stories fill, not a throwaway.
- [x] `workspace/core/frontend/wms-fe/mobile/**` -- scaffold Expo 57 app inside the wms-fe repo (structure it for mechanical extraction later): platform-theme mapping of the brand hues, health screen, boots via Expo Go / simulator -- satisfies the story's mobile-boot AC without a new repo.
- [x] `workspace/core/frontend/wms-fe/src/lib/api/**` -- generated client from wms-be's OpenAPI doc wired to the health check -- proves the AD-8 pipeline end-to-end.
- [x] `wms-be` + `wms-fe` CI configs -- lint + test workflows covering web and mobile apps -- the AC's "passes lint + tests in CI".
- [x] `docs/repos/wms-be/README.md`, `docs/repos/wms-fe/README.md` -- record the contract: OpenAPI doc path, base path, generated-client command, mobile-inside-wms-fe note -- keeps meta-repo contracts current (CLAUDE.md).

**Acceptance Criteria:**
- Given a fresh checkout, when `bun install && bun run dev` runs in each repo, then api and web boot locally, the api health check answers, and the web shell renders the sidebar IA with token styling at WCAG 2.2 AA.
- Given the api is running, when the web app fetches, then it consumes generated OpenAPI types (no hand-written API types exist in wms-fe).
- Given Drizzle is configured, when a migration runs against Postgres, then it applies and reverts cleanly using spine conventions (UUIDv7, UTC).
- Given each repo, when lint + tests run, then both pass.
- Given the Expo app in `wms-fe/mobile/`, when it boots, then it renders the platform-theme mapping of the brand hues with a health screen.
- Given wms-fe history, when the scaffold commit lands, then it contains no meta-repo files (cleanup landed as a separate preceding chore commit).

## Implementation Notes

- Commits: wms-fe `3330565` (cleanup chore) then `80bf90e` (web+mobile scaffold); wms-be `97d2aba` (scaffold), `d822f93` (typed health/echo DTOs so codegen produces real types instead of `unknown`), `f3c6c74` (module folders realigned to spine Structural Seed + duplicated OpenAPI block removed); meta `089a4d5` (contract docs) then `f913273` (module-list correction). Nothing pushed.
- Backend module folders initially used web-surface names (conflicts/settings/moves/reports); corrected to spine names (putaway/carriers/movements/reporting) via `git mv` in `f3c6c74`.
- Verification run by implementer: migration applied/reverted/re-applied on a real Postgres 18 container (UUIDv7 + UTC confirmed); `/api/v1/health` 200; `/api/v1/openapi.json` parses with `servers: ['/api/v1']`; unknown routes return `application/problem+json` with machine-readable code; web Overview renders `ok · wms-be` via the generated client; wms-be 11 tests (jest + bun test), wms-fe 10 bun tests, lint/tsc/next build clean, all 12 routes 200.
- Known limitations: WCAG AA verified by inspection against DESIGN.md pairs (no automated contrast test); mobile boot verified by typecheck only (no simulator run in this environment); NestJS 12 is ESM-only — jest transforms node_modules via swc, pinned toolchain required.

## Spec Change Log

## Review Triage Log

| # | Finding (layer) | Verdict | Evidence / route |
|---|---|---|---|
| 1 | OpenAPI documents 200 for POST /echo but Nest @Post returns 201; e2e asserts 201 (blind) | medium | Real: `echo.controller.ts` has no `@HttpCode`; contract and behavior disagree on the pipeline-proof endpoint — patch (group A) |
| 2 | OpenAPI has no requestBody for POST /echo (blind) | medium | Real: `paths./echo.post` has `parameters: []`, no requestBody — the typed round-trip is only half-proven — patch (group A) |
| 3 | No ProblemDetails schema/error responses in OpenAPI (blind) | medium | Real: components has only Health/Echo; the error envelope clients must branch on is invisible to codegen — patch (group A) |
| 4 | Echo lacks idempotency enforcement; parseIdempotencyKey fabricates `tenantId: 'pending-story-1.2'` (blind) | low | Enforcement absence is by design (seam docstring + spec allow stubs; interceptor lands 1.2). Sentinel is real but the function has zero callers — patch (rename/remove sentinel) |
| 5 | Validation errors lose substance: filter reads `body.detail`, Nest validation carries `message`; `instance` never set (blind) | medium | Real: `problem-details.filter.ts` reads only `code`/`detail`; clients get no field errors — patch (group B) |
| 6 | FE cursor codec (btoa/atob) diverges from BE (Buffer utf8 base64url); non-ASCII breaks (blind) | medium | Real: duplicated AD-9 primitive with structural divergence; latent until non-ASCII cursor payload — patch (group C) |
| 7 | DataTable Prev enabled on first page, calls onCursor(null) (blind) | low | Real: `disabled={!onCursor}`; no history tracking — patch (group D) |
| 8 | Hand-written API types: `ApiHealth` in client.ts, `HealthResponse` in mobile (blind) | medium | Real: contradicts the spec AC "no hand-written API types exist in wms-fe" — web part patch (group E); mobile part defer (see #20) |
| 9 | api:generate sibling path undocumented (blind) | false | Refuted: wms-fe README documents the pipeline and workspace-relative spec path (lines 31, 43–44) |
| 10 | Committed openapi.json can drift silently (blind) | medium | Pre-verified by verification-gap (#19) — patch (group F) |
| 11 | Backend CI never typechecks or builds (blind) | medium | Real: be CI runs lint+jest only; swc-transformed jest hides type errors; fe CI has both steps — patch (group G) |
| 12 | No docker-compose/dev-infra for Postgres :55432 (blind) | low | Real: `.env.example` points at 55432 with nothing provisioning it — patch (group H) |
| 13 | Mobile banner hardcodes "Accepted" even on error (blind) | low | Real: `App.tsx` ignores `error` for banner state; green accepted + "api unreachable" contradict — patch (group D) |
| 14 | Mobile nav uses `<a href>`; details menu never closes (blind) | low | Real: `app-shell.tsx` MobileNavLinks uses raw anchors — patch (group D) |
| 15 | Palette: Esc dies after backdrop click (no backdrop close), no focus trap/restore (blind) | medium | Real: keydown on overlay only, autoFocus input; backdrop click leaves focus on body and doesn't close — violates frozen "Esc closes topmost layer" — patch (group D) |
| 16 | DESIGN.md token source not committed anywhere (blind) | medium | Real: `_bmad-output/` untracked in meta; the cited source of truth exists in no clone — defer (meta-repo tracking decision, pre-existing) |
| 17 | CI uses `bun-version: latest`; wms-fe lacks `packageManager` (blind) | low | Real: be pins bun@1.2.20, fe doesn't; both CI files use latest — patch (group G) |
| 18 | Problem-details tested only on the 404 path (v-gap, pre-verified) | medium | Filed evidence: no test exercises 400/internal-error branches; either can break undetected — patch (group B) |
| 19 | Committed openapi.json equality unchecked (v-gap, pre-verified) | medium | Filed evidence: served doc built fresh; committed artifact never compared — patch (group F) |
| 20 | Mobile hand-writes HealthResponse, unchecked against contract (v-gap, pre-verified) | medium (deferred) | Filed disposition defer: `mobile/` is a temporary pre-extraction folder; align types when extracted |
| 21 | client.ts hand-writes ApiHealth with unchecked cast (v-gap other) | medium | Real: generated `HealthResponse` exists; cast enforced nowhere — patch (group E) |
| 22 | PORT=NaN reaches listen() (edge) | low | Real: `Number(process.env.PORT ?? 3000)`; no validation — patch (group H) |
| 23 | Echo accepts arrays/primitives contrary to schema (edge) | low | Real: no body validation — patch (group A, folds into EchoRequest DTO) |
| 24 | export-openapi.ts: unhandled rejection on failure (edge) | low | Real: `void main()` with no catch — patch (group H) |
| 25 | migrate.ts: createDatabase outside try (edge) | low | Real: throw before try escapes the error path — patch (group H) |
| 26 | UUIDv7 seq wrap at 4097 ids/ms reorders (edge) | false | Refuted by reachability: requires 4097 ids in one millisecond; and the wrap path preserves monotonic time ordering (bump happens before next id) — not met in any realistic use |
| 27 | paise(1e308) brands Infinity (edge) | medium | Real: `paise()` checks isFinite only before multiply; no safe-integer check on the result — patch (group I) |
| 28 | gstBps(NaN) brands NaN (edge) | medium | Real: NaN fails both range comparisons — patch (group I) |
| 29 | assertUtcIso accepts impossible calendar dates (edge) | low | Real: regex shape only, no Date.parse — patch (group I) |
| 30 | BE buildPage(rows, 0) silently drops rows (edge) | low | Real: no limit guard; empty page + null cursor — patch (group I) |
| 31 | FE buildPage same (edge) | low | Real: same defect, duplicated primitive — patch (group I) |
| 32 | btoa throws InvalidCharacterError on non-Latin1 (edge) | medium | Same root as #6 — patch (group C) |
| 33 | Palette Esc/backdrop (edge) | medium | Same as #15 — patch (group D) |
| 34 | Mobile menu stays open after nav (edge) | low | Same as #14 — patch (group D) |
| 35 | ThemeToggle unreachable <768px (edge) | low | Real: sidebar (its only host) hidden below md — patch (group D) |
| 36 | Mobile health fetch has no timeout (edge) | low | Real: hanging API pins "checking api…" forever — patch (group D) |
| 37 | internal-error branch logs nothing despite comment (edge) | medium | Real: no Logger call in the filter's else branch; 500s undebuggable — patch (group B) |
| 38 | Catch-all only covers /api/v1/*; bare paths get HTML 404 (edge) | low | Real but met only by mistyped non-prefixed URLs in dev; fix (prefix exclusion) is not a direct correction — rejected |
| 39 | Hand-written ApiHealth claim (edge) | medium | Same as #8/#21 — patch (group E) |
| 40 | wms-fe "removed" preinstall bun-only guard (edge) | false | Refuted: the guard belonged to the accidentally-committed meta-repo files; wms-fe's legitimate history never had one |

## Verification

**Commands:**
- `bun install && bun run lint && bun test` (in wms-be) -- expected: clean pass
- `bun install && bun run lint && bun test` (in wms-fe) -- expected: clean pass
- `bun run start` (wms-be) then curl `/health` + OpenAPI doc URL -- expected: 200, doc parses
- `bun run dev` (wms-fe) -- expected: shell renders; generated client type-checks against api