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

### Review Findings

Independent code-review pass (bmad-code-review, wms-be chunk, 2026-09-08). Four layers: blind-hunter, edge-case-hunter, verification-gap, acceptance-auditor.

- [x] [Review][Patch] UUIDv7 embeds a corrupted unix-ms timestamp [src/shared/primitives/ids.ts:26] — `view.setUint16(4, now >>> 16)` writes bits 16–31 into the low-16 slot; RFC 9562 needs `now & 0xffff`. All ids within each 65,536 ms window share identical first-48-bit timestamps, so ids do not sort by creation time — breaks the AD-9 guarantee and the file's own doc. Fix: write `now & 0xffff`; add a test asserting the embedded timestamp equals the input.
- [x] [Review][Patch] OpenAPI error contract misdescribes the wire [openapi/openapi.json, src/api/echo.controller.ts] — the 400 response is documented as `application/json` but the filter always emits `application/problem+json` (e2e asserts it); /health and /echo document no 404/500 problem-details responses, so generated clients never see the universal error contract. Fix: correct the content-type key, add 404/500 responses, re-run `openapi:export` (drift guard enforces the committed doc).
- [x] [Review][Patch] No schema/migration drift guard; migrations never run in verification [src/shared/db/schema.ts, drizzle/, .github/workflows/ci.yml] — openapi.json has a drift-guard test but the DB contract has none; CI never applies migrations, so a schema.ts edit without `db:generate` ships green and fails at first runtime write (1.2+). Fix: CI step (or integration test) that boots Postgres, runs `db:migrate`, round-trips one `app_metadata` row.
- [x] [Review][Patch] Test sources are typechecked by nothing [tsconfig.json, tsconfig.build.json, .github/workflows/ci.yml] — `test/` excluded from tsconfig, `**/*.spec.ts` excluded from build, jest compiles via swc without type checking; the CI build step's "typecheck" covers src only. Fix: `tsc --noEmit` pass that includes test/ (e.g. a check tsconfig wired into CI).
- [x] [Review][Patch] `void bootstrap()` leaves startup failures as unhandled rejections [src/main.ts:13] — createApp/listen failure (invalid PORT, EADDRINUSE) produces no clean error. Same defect patched in export-openapi.ts during the build review; main.ts was missed. Fix: `bootstrap().catch(...)` with exit, mirroring that pattern.
- [x] [Review][Patch] Port derived twice: main.ts reads raw `process.env.PORT ?? 3000` while app.factory validates via `parsePort` [src/main.ts:6, src/app.factory.ts:48] — two sources of truth; the log line can print a value that was never validated. Fix: reuse parsePort's result (have createApp return it or call parsePort in main).
- [x] [Review][Patch] Problem-details filter lacks a headersSent guard [src/shared/problem-details/problem-details.filter.ts:61] — an exception after the response starts streaming makes the filter call `res.status` on a sent response (ERR_HTTP_HEADERS_SENT from inside the error filter). Fix: early-return when `res.headersSent`.
- [x] [Review][Patch] SharedModule docstring claims "Every spine module imports this module"; none do [src/shared/shared.module.ts] — comment describes a discipline the placeholder modules don't yet follow. Fix: reword to forward-looking ("spine modules import this").
- [x] [Review][Patch] Missing trailing newlines on most new files [package.json, src/main.ts, .github/workflows/ci.yml, docker-compose.yml, …] — `\ No newline at end of file` throughout. Fix: append newlines (one-shot).
- [x] [Review][Patch] README instructs `bun test` while package.json defines `test: jest` [README.md:30] — bun's runner interprets jest config differently; CI correctly uses `bun run test`. Fix: document `bun run test`.
- [x] [Review][Patch] DATABASE_URL is required at boot (db.ts throws) but drizzle.config.ts silently falls back to localhost:55432 [src/shared/db/db.ts:16, drizzle.config.ts:8] — app path and migrate path disagree about whether the variable is mandatory. Fix: align behavior (require it in both, or document the fallback in both).
- [x] [Review][Defer] decodeCursor throws a plain Error (→ 500 internal-error) and never validates createdAt as a real ISO-8601 instant [src/shared/primitives/pagination.ts:26] — deferred: zero consumers until the first list endpoint (story 1.2); where the 400 mapping belongs (primitive vs controller) is unsettled until then.

**Rejected** (with refutations):

- UUIDv7 seq-exhaustion bump leaves `lastMs` stale, reordering ids (edge-case-hunter + verification-gap) — low; trigger requires 4096 uuidv7 calls within one millisecond (same reachability refutation as build-triage row 26); the 5000-id test passing on random bits is noted but collision risk is negligible.
- Clock rollback regresses id ordering (edge-case-hunter) — low; NTP rollback mid-run is an environment event and post-rollback ordering is inherent to timestamp-ordered ids; B-tree health unaffected.
- ulid() accepts a negative timestamp (edge-case-hunter) — low; no caller passes anything but the default.
- Bare (non-prefixed) paths return HTML 404 (edge-case-hunter) — carried rejection from build triage row 38: reachable only by mistyped dev URLs; fix adds prefix-less fallback complexity.
- No repeatable migration revert path (acceptance-auditor) — resolution would edit the frozen AC; the revert half was demonstrated during build verification; drizzle is conventionally forward-only.
- CI Build step exceeds the "lint+test workflows" Never line (acceptance-auditor) — false; the step was the logged fix for build-triage row 11 (CI never typechecked).
- eslint ignores *.config.* so drizzle.config.ts/jest.config.js are unlinted (acceptance-auditor) — low; conventional exclusion, no named harm.
- Idempotency seam has no unit test (blind-hunter) — low; zero callers, spec allows stubs; tests belong with the first consumer (1.2).
- docker-compose lacks healthcheck/volume (blind-hunter) — low; 1.1 persists no domain data, nothing polls readiness.
- db.ts is dead code at runtime; health never touches the DB (blind-hunter) — low; deliberate substrate state, readiness probe is out of scope for 1.1.
- postgres(url,{max:10}) lacks timeouts/SSL and UTC-session parameters (blind-hunter) — low; premature tuning, timestamptz is session-tz independent, no demonstrated failure.
- pagination.spec.ts is misnamed (covers money/quantity/time too) (blind-hunter) — low; cosmetic file naming, no caller diverges.


### Review Findings — wms-fe web chunk (2026-09-08)

Independent code-review pass, chunk 2 of 3 (web shell; 36 files). Four layers; same method as the wms-be chunk.

- [x] [Review][Patch] Light-mode focus ring fails WCAG 2.2 AA non-text contrast [src/app/globals.css:31,122-124] — `--ring: #a1a1aa` on white ≈2.5:1, below the 3:1 of AA 1.4.11; `:focus-visible` outlines with it, violating AC-1. DESIGN.md assigns focus indicators to Primary Blue. Fix: contrast-safe light-mode ring (primary blue or zinc-600); dark `--ring` already passes.
- [x] [Review][Patch] Brand-token guard is presence-only — cannot detect drift [src/lib/brand-tokens.test.ts:33-36] — asserts only `toContain(hex)` over the whole file: a dark-block value swap or an extra hue (the README's own "second brand hue fails CI" guarantee) passes CI. Fix: assert each variable's value inside the `:root` and `.dark` blocks, and scan for hex values outside the token set.
- [x] [Review][Patch] Theme-persistence contract between layout init script and ThemeToggle is unverified [src/app/layout.tsx:19-26, src/components/shell/sidebar.tsx:62] — the storage key and `'dark'`/`'light'` vocabulary are implicit across a server and a client component; a rename breaks persistence with CI green. Fix: extract `src/lib/theme.ts` (key + read/write helpers) consumed by both, with a round-trip unit test.
- [x] [Review][Patch] Overview health fetch has no timeout [src/app/page.tsx:15-21] — `force-dynamic` render blocks indefinitely on a hung backend. Fix: `AbortSignal.timeout(3000)` on the fetch. (Catch-all `catch` conflating programming errors with "unreachable" noted and accepted for the scaffold.)
- [x] [Review][Patch] Mobile menu ignores Esc and outside clicks [src/components/shell/app-shell.tsx:39-49] — closes only on navigation; frozen contract says Esc closes the topmost layer. Fix: pointerdown-outside + Esc effect setting `menuRef.current.open = false`.
- [x] [Review][Patch] Mobile menu dropdown has no positioned ancestor [src/components/shell/app-shell.tsx:43] — `absolute left-0 top-12` resolves against the initial containing block; correct only while the header sits at the document top. Fix: `relative` on the `<details>`.
- [x] [Review][Patch] Palette keyboard handling has edge gaps [src/components/shell/command-palette.tsx:92-103,116] — arrows/Enter die when focus leaves the overlay (click on panel padding); ArrowDown with zero matches drives `selected` to -1; the selected item never scrolls into view inside `max-h-72`. Fix: window-level arrow/Enter handling (as Esc already does), empty-list guard, `scrollIntoView({ block: 'nearest' })` on selection. (Full focus trap / listbox roles: rejected — beyond the frozen palette contract, adds complexity.)
- [x] [Review][Patch] Sidebar active state lost on nested child routes [src/components/shell/sidebar.tsx:26] — `pathname === item.href` misses `/inventory/xyz`; aria-current drops. Fix: exact match for `/`, `startsWith` otherwise.
- [x] [Review][Patch] Bun-only enforcement was deleted, not replaced [package.json, .gitignore] — no `preinstall` guard and no foreign-lockfile rejects; npm/yarn installs succeed silently against the "Bun everywhere" Always constraint. Fix: restore a preinstall bun check and `package-lock.json`/`yarn.lock`/`pnpm-lock.yaml` gitignore entries. (The build-review refutation of the *old* guard's provenance — row 40 — stands; this is about the scaffold shipping no equivalent.)
- [x] [Review][Patch] cursor.test.ts mislabeled assertion + redundant spread [src/lib/cursor.test.ts:17-20, src/app/page.tsx] — "rejects malformed cursors" first asserts a valid cursor does *not* throw; `columns={[...SURFACE_COLUMNS]}` copies a readonly array the prop already accepts. Fix: move the assertion to the round-trip test; drop the spread.
- [x] [Review][Patch] Missing trailing newlines on nearly all new files [.env.example, ci.yml, globals.css, all components/lib files, …] — same hygiene finding patched in wms-be. Fix: append newlines.
- [x] [Review][Defer] DESIGN.md token source untracked in any repo — already tracked in deferred-work.md (build-review row 16); no new entry.

**Rejected** (with refutations):

- `src/lib/api/**` absent from the diff / `api:generate` unrunnable (blind-hunter) — chunk artifact: the generated-client pipeline is chunk 3 of this review; both exist in the repo.
- DataTable Prev always returns to page 1; `activeCursor` internal state desyncs; onCursor failure corrupts state (blind-hunter + verification-gap + edge-case-hunter) — low; no real consumer until the first list surface (1.2), and back-stepping needs a cursor-history design decision, not a direct correction.
- Sticky header can never stick under `overflow-x-auto` (blind-hunter) — real CSS behavior but no vertically-scrolling consumer exists in 1.1 (Overview renders empty rows); the fix needs a scroll-container design — revisit when the first real data table lands.
- Radius tokens are circular custom properties (blind-hunter) — false: verified against compiled CSS — Tailwind's theme emission precedes the user `:root` block in the cascade, so the 4/6/8px values win and `rounded-sm/md/lg` resolve correctly (standard Tailwind v4 `@theme inline` pattern).
- Mobile dropdown "detaches on scroll" harm (blind-hunter) — folded into the positioning patch above; the detach itself is not reachable with a static document-flow header.
- Story numbers ("lands in 1.4+") leak into product UI (blind-hunter) — low; deliberate dev-facing scaffolding; no end users exist in 1.1.
- Toolchain pin consistency unverified (typescript-eslint/TS6, bun-types/bun) (blind-hunter) — no demonstrated failure: lint, typecheck, and build all ran clean in verification.
- No error/loading/not-found boundaries or permission-guard stubs (blind-hunter) — out of scope for the 1.1 scaffold; platform defaults exist; permissions arrive with 1.5.
- Test coverage stops at src/lib — no palette/DataTable interaction tests (blind-hunter) — beyond the two specific verification gaps patched above; a component test harness is a suite-structure decision.
- CI mobile job duplicates setup steps (blind-hunter) — negligible.
- Mobile app has no lint/test in CI (acceptance-auditor) — low; mobile ships no eslint config or test suite to run (its gate is `tsc`); authoring mobile tooling belongs to its first real story (3.2).
- Duplicate row ids break React keys (edge-case-hunter) — row ids are primary keys; duplicate ids are not reachable.
- Object/boolean cells render "[object Object]" (edge-case-hunter) — no current column renders non-strings; render prop exists for rich cells.

## Verification

**Commands:**
- `bun install && bun run lint && bun test` (in wms-be) -- expected: clean pass
- `bun install && bun run lint && bun test` (in wms-fe) -- expected: clean pass
- `bun run start` (wms-be) then curl `/health` + OpenAPI doc URL -- expected: 200, doc parses
- `bun run dev` (wms-fe) -- expected: shell renders; generated client type-checks against api
### Review Findings — chunk 3: mobile + generated client + meta docs (2026-09-08)

Reviewers: blind-hunter, edge-case-hunter, verification-gap (ran the real pipelines), acceptance-auditor. Chunk = wms-fe `3330565`+`80bf90e` + meta docs commits.

**Patch**

- [x] [Review][Patch] **Stale generated client (medium)** — `src/lib/api/generated/types.gen.ts` has zero `ProblemDetails`/`*Errors` types and `EchoControllerEchoData.body?: never`; it predates wms-be's `a93201e`+`27f1f06` error-contract patches (verified: `bun run api:generate` changes 3 committed files; verified by verification layer, then reverted). POST /echo is unusable through the typed SDK and error `code` is typed `unknown`. Fix: re-run `openapi:export` + `api:generate`, commit the regenerated client.
- [x] [Review][Patch] **No CI guard for OpenAPI/client drift (medium)** — neither ci.yml guards the documented contract pipeline (wms-be has only the DB `db:verify` guard; wms-fe CI never checks generated-client freshness). Fix: wms-be adds `openapi:export` + `git diff --exit-code openapi/`; wms-fe adds `api:generate` + `git diff --exit-code src/lib/api/generated`.
- [x] [Review][Patch] **Interface-contract doc gaps (low, doc-only)** — docs/repos/wms-fe/README.md: (a) env-vars list omits `EXPO_PUBLIC_API_BASE_URL` used by `mobile/`; (b) "never hand-written" claim is self-contradictory until mobile repo extraction — note the exception and point at the deferred-work entry; (c) add the SDK-import convention note (import via `src/lib/api/client.ts`, which applies the base URL — importing the generated barrel directly skips config); (d) note `NEXT_PUBLIC_*`/`EXPO_PUBLIC_*` are inlined at build time (deploy-time env needs a rebuild); (e) mobile README: device/Android-emulator base-URL note (`10.0.2.2` / LAN IP — `localhost` default only works on the iOS simulator). Plus: trailing newlines on both `docs/repos/` READMEs.
- [x] [Review][Patch] **Empty env var defeats fallback (low)** — `mobile/src/api.ts:5` and `src/lib/api/client.ts:10` use `??`, so an env var set-but-empty (`.env` with `NEXT_PUBLIC_API_BASE_URL=`) yields `''` → relative-URL fetch on device. Fix: `||` (base URL can never legitimately be empty).

**Rejected**

- [Review][Rejected] Mobile hand-written `HealthResponse` (`mobile/src/api.ts:7-11`) — already deferred by build review (row 20, tracked in deferred-work.md, until repo extraction); carried, not re-deferred. The doc self-contradiction half is patched above.
- [Review][Rejected] Mobile default base URL unreachable on physical devices — code default is correct for the documented simulator run mode with a documented override; the missing-hint half is patched above (mobile README note).
- [Review][Rejected] `quarantined` scan state unused — intentional shared scan-state vocabulary for later stories; typed, harmless.
- [Review][Rejected] Mobile boot verified only by typecheck — disclosed in the spec; no simulator in this environment; not a code defect.

Score: 4 patch / 0 defer / 4 rejected.
