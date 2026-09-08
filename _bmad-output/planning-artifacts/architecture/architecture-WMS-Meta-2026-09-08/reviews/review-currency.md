# Version-Currency Review — ARCHITECTURE-SPINE.md (WMS v1 Platform)

- **Reviewer role:** version-currency (live web verification, September 2026)
- **Subject:** `_bmad-output/planning-artifacts/architecture/architecture-WMS-Meta-2026-09-08/ARCHITECTURE-SPINE.md` — Stack table + Structural Seed
- **Verdict: PASS WITH CHANGES.** The spine is substantially current. One high-severity runtime pin (Node.js 22 is now maintenance-LTS, not the going choice for a greenfield 2026 build), one stale language-version row (TypeScript "5.x" — TS 7.0 went GA July 2026), and one cluster of medium fit-risks around Valkey-on-ElastiCache Lua semantics and the under-specified OpenAPI codegen row. Everything else checks out against live sources.

---

## Verified-current (no action needed beyond pin tightening)

| Spine entry | Live status (Sept 2026) | Verdict |
| --- | --- | --- |
| NestJS 12.0 | v12 released Aug 27–28 2026 — most significant platform update in years. Fits its role perfectly; notably it adds **Standard Schema** validation (`StandardSchemaValidationPipe`) — the spine's "Zod shared with Nest Standard Schema" convention is now first-party supported, not a bolt-on. | ✅ Current |
| Drizzle ORM 0.45.x / "1.0 still RC — defer" | Latest stable is **0.45.2** (Mar 2026); 1.0 remains RC (v1.0.0-rc.4, Jun 2026) with breaking changes (casing API rework, RQB v1 removal). The spine's defer call is still correct. | ✅ Current (see F5 for pin) |
| Next.js 16.3 | 16.3.4 (Aug 31 2026); 16.3 is the current minor line, LTS-style support to ~Oct 2027. | ✅ Current |
| TanStack Query 5.x | 5.102.x is `latest` on npm. | ✅ Current |
| Expo SDK 57 / RN 0.86 | SDK 57 shipped Jun 30 2026 bundling RN 0.86 — the current SDK. expo-sqlite WAL offline store fits AD-4. | ✅ Current (low notes, F6) |
| PostgreSQL 18.6 | 18.6 released Aug 13 2026 (18.5 was skipped); **RDS supports 18.6 since Aug 25 2026**. PG 18 has native `uuidv7()` — direct support for AD-9. RDS standard support to Feb 2031. | ✅ Current |
| Valkey 9.1 | ElastiCache for Valkey 9.1 GA in all regions Jun 23 2026 (node-based). Upstream 9.1.0 May 19 2026. Redis-compatible, Lua scripting available. | ✅ Current (fit risks, F3) |
| Zod 4.x | 4.5.4 stable (Aug 29 2026); 4.5 adds `z.compile()` etc. | ✅ Current (minor note, F6) |
| AWS ap-south-1 — ECS Fargate, RDS, ElastiCache, S3 | All available in Mumbai; ECS Fargate is a sound fit for a Node monolith; nothing in the stack is unsupported on Fargate images for Node 22/24. | ✅ Fit confirmed |

---

## Findings

### F1 — HIGH · Node.js 22 is maintenance LTS; greenfield should target Node 24 LTS

- **Spine says:** "Node.js (backend runtime) | 22 LTS".
- **Live:** Node 22 ("Jod") entered **maintenance LTS on Oct 21 2025** — security/critical fixes only, **EOL Apr 30 2027**. Node 24 ("Krypton") is **Active LTS** (since Oct 28 2025) and is Node.js's *recommended production version*; maintenance starts Oct 2026, EOL Apr 30 2028. Node 26 becomes LTS Oct 28 2026.
- **Why it matters:** this is a greenfield pin for a build that will run well past Apr 2027. Pinning 22 means starting a new platform on a support line already in its final phase and forcing a runtime major-upgrade mid-project. All spine deps are compatible with 24: NestJS 12 requires ≥20.19/22.12, Expo SDK 57 requires ≥22.13, @hey-api/openapi-ts requires ≥22.13.
- **Fix:** change the Stack row to **Node.js 24 LTS** (pin a concrete minor, e.g. 24.20.x). Update any Dockerfile/CI pins derived from the spine.

### F2 — MEDIUM · TypeScript "5.x stable" is two majors behind

- **Spine says:** "TypeScript | 5.x stable".
- **Live:** TypeScript 7.0 (the Go-native compiler) reached **GA on Jul 8 2026** (npm `latest` = 7.0.2); TS 6.x is the last classic-compiler line; TS 5.9 is no longer the current stable. Next.js 16.3 already advertises TS 7 type-checking support.
- **Why it matters:** a fresh repo scaffolded on "5.x" would immediately be off-current, and TS 7's defaults differ (strict on, `module: esnext`, `node10` resolution removed). One caveat: **no stable programmatic API until TS 7.1**, which constrains typescript-eslint / ts-jest-style tooling — the classic 6.x line remains supported in parallel for exactly this.
- **Fix:** restating the row as "TypeScript 7.x (native `tsc`); 6.x classic as fallback where tooling needs the programmatic API" keeps the spine honest and tells the builder which trade-off applies. Also note NestJS 12 is ESM-first, which pairs naturally with TS 7 defaults.

### F3 — MEDIUM · Valkey 9.1 on ElastiCache supports AD-2's Lua, but with ElastiCache-specific constraints the spine doesn't record

- **Spine says:** "Valkey 9.1 (reservation hot state, Lua; Redis-compatible)" / AD-2 "single Lua script on Valkey reservation keys".
- **Live:** ElastiCache for Valkey 9.1 is available (Jun 2026) and Lua scripting works — but:
  - **Scripts must declare their keys upfront** — ElastiCache rejects keyless `EVAL` (`ERR Lua scripts without any input keys are not supported.`); not disableable. AD-2's reservation script must be pure `KEYS`/`ARGV` parameterized. Fine for a reservation key design, but it must be an invariant, not an accident.
  - **Cluster-mode slot co-location:** multi-key scripts need all keys in one slot → reservation keys must share a hash tag (`{...}`), which constrains the key schema.
  - **Limits:** 4 MiB max script, `lua-time-limit` 5000 ms with `SCRIPT KILL`; a script that has started **writing is unkillable** and blocks the node — so the AD-2 script must be short, non-looping, and pre-declared via `SCRIPT LOAD`/`EVALSHA`.
  - **Valkey 9.1 moved Lua into a loadable module** (`libvalkeylua.so`); ElastiCache ships it enabled, but confirm on the chosen deployment mode (node-based vs serverless — serverless has non-modifiable config) before committing AD-2 to it.
- **Fix:** one sentence in AD-2: "reservation scripts are KEYS/ARGV-parameterized, pre-loaded via EVALSHA, hash-tagged to one slot, and bounded well under the 5 s script timeout" — plus a note to verify Lua availability on the chosen ElastiCache mode at infra build time. Also worth recording the 9.1 client-facing break (`CLUSTER SHARDS/SLOTS` gained an AZ field — keep ioredis/valkey-glide clients current).

### F4 — MEDIUM · OpenAPI codegen row is underspecified and half-names the tool

- **Spine says:** "OpenAPI codegen (`@openapi-typescript` + clients) | current".
- **Live:** there is no `@openapi-typescript` package; the type-only tool is **`openapi-typescript` (v7.13.x)**, best paired with `openapi-fetch`. The 2026 ecosystem frontrunner for full typed SDKs is **`@hey-api/openapi-ts` 0.99.x** (used by Vercel/PayPal; generates SDK + Zod schemas + TanStack Query `queryOptions` plugins) — but it is **pre-1.0 with frequent breaking changes, ESM-only since 0.91, and requires Node ≥22.13**. Orval is the alternative when generated hooks/MSW mocks are wanted.
- **Why it matters:** AD-8 makes generated clients a build gate in two consumer repos; "current" plus a half-name leaves the version-drift risk AD-8 exists to prevent. Pre-1.0 churn in hey-api means the consuming repos need a pinned version and a deliberate upgrade cadence.
- **Fix:** name the toolchain per consumer — e.g. "wms-fe/wms-mobile: `@hey-api/openapi-ts` (pinned minor; ESM, Node 24) with TanStack Query + Zod plugins; types may come from `openapi-typescript` where a thin client suffices" — and add the codegen version to the `docs/repos/*` interface contracts.

### F5 — LOW · Drizzle pin should say 0.45.2 (security release)

- **Live:** 0.45.2 (Mar 2026) fixed a **SQL injection (CWE-89)** in `sql.identifier()` / `sql.as()`; 0.45.0–0.45.1 are affected. The spine's "0.45.x" range technically admits vulnerable versions.
- **Fix:** pin "≥0.45.2" in the Stack row; the "1.0 still RC — defer" note remains accurate (rc.4, Jun 2026; breaking casing API awaits you in 1.0).

### F6 — LOW · Minor currency notes to carry into build docs (no spine change required)

- **Expo/RN:** SDK 57 is current, but Expo is piloting a faster SDK cadence off RN's no-breaking-change releases — plan for more frequent, low-friction RN bumps than the historical 3/yr. Known regression: importing `react-native-reanimated` with Hermes V1 can raise memory 25–30% (workaround: worklets bundle mode) — relevant to a long-lived scan session app.
- **Zod 4.5:** soundness fixes include small breaking changes (`z.iso.datetime()` now requires seconds; string length counts Unicode code points) — harmless on greenfield, but generated-client codegen (F4) and Zod must land on 4.5.x together.
- **NestJS 12:** ESM-first core packages; new CLI defaults (Vitest for ESM projects, oxlint, Rspack); `@nestjs/config` now Standard Schema-based. No change needed — just don't scaffold from v11-era templates.
- **PostgreSQL 18.6:** RDS supports it; note PG 14 goes EOL Nov 12 2026 (irrelevant here, but the extension-availability table should be checked at infra build — `plrust` is discontinued on PG 18).

---

## Summary of required edits to the spine

| Row / section | Change |
| --- | --- |
| Stack — Node.js | 22 LTS → **24 LTS** (high) |
| Stack — TypeScript | 5.x → **7.x (native tsc), 6.x classic fallback note** (medium) |
| Stack — Drizzle | 0.45.x → **0.45.2+** (low) |
| Stack — OpenAPI codegen | Name actual packages + pin (`@hey-api/openapi-ts` pre-1.0 caveat) (medium) |
| AD-2 | Add ElastiCache Lua constraints: KEYS/ARGV-only, hash-tagged single slot, pre-loaded EVALSHA, bounded runtime; verify Lua on chosen ElastiCache mode (medium) |

## Sources

- [nodejs.org — Previous releases](https://nodejs.org/en/about/previous-releases), [endoflife.date/nodejs](https://endoflife.date/nodejs), [nodejs/Release](https://github.com/nodejs/release)
- [NestJS v12 release](https://github.com/nestjs/nest/releases/tag/v12.0.0), [Trilon: NestJS 12 is now available](https://trilon.io/blog/nestjs-12-is-now-available)
- [Drizzle releases](https://github.com/drizzle-team/drizzle-orm/releases), [v1.0.0-rc.4](https://github.com/drizzle-team/drizzle-orm/releases/tag/v1.0.0-rc.4), [drizzle-orm on npm](https://www.npmjs.com/package/drizzle-orm)
- [Next.js 16.3 blog](https://nextjs.org/blog/next-16-3), [v16.3.4](https://github.com/vercel/next.js/releases/tag/v16.3.4)
- [TanStack Query releases](https://github.com/TanStack/query/releases), [@tanstack/react-query on npm](https://www.npmjs.com/package/@tanstack/react-query)
- [Expo SDK 57 changelog](https://expo.dev/changelog/sdk-57), [Expo SDK 57 page](https://expo.dev/sdk/57)
- [PG 18.6 release notes](https://www.postgresql.org/docs/18/release-18-6.html), [PG 18.6 announcement](https://www.postgresql.org/about/news/postgresql-186-1711-1615-1519-1424-and-19-beta-3-released-3365/), [RDS PG 18](https://aws.amazon.com/about-aws/whats-new/2025/11/amazon-rds-postgresql-major-version-18/), [RDS 18.6 support](https://aws.amazon.com/about-aws/whats-new/2026/08/amazon-rds-postgresql-18-6-17-11-16-15-15-19-14-24/)
- [Valkey 9.1 blog](https://valkey.io/blog/valkey-9-1-delivers-improvements-in-security-performance-and-more/), [Valkey 9.1.0 release](https://github.com/valkey-io/valkey/releases/tag/9.1.0), [ElastiCache Valkey 9.1](https://aws.amazon.com/about-aws/whats-new/2026/06/amazon-elasticache-valkey-9-1/), [ElastiCache Lua best practices](https://docs.aws.amazon.com/AmazonElastiCache/latest/dg/BestPractices.Clients.Redis.LuaScripts.html), [ElastiCache config & limits](https://docs.aws.amazon.com/AmazonElastiCache/latest/dg/RedisConfiguration.html), [ElastiCache engine versions](https://docs.aws.amazon.com/AmazonElastiCache/latest/dg/engine-versions.html)
- [Zod 4.5 blog](https://zod.dev/blog/zod-4-5), [zod on npm](https://www.npmjs.com/package/zod)
- [openapi-typescript vs hey-api vs Orval vs Kubb comparison](https://dev.to/nyaomaru/which-openapi-codegen-should-you-choose-openapi-typescript-vs-hey-api-vs-orval-vs-kubb-100p), [@hey-api/openapi-ts on npm](https://www.npmjs.com/package/@hey-api/openapi-ts), [hey-api/openapi-typescript on GitHub](https://github.com/hey-api/openapi-typescript)
- [TypeScript 7.0 GA coverage](https://devblogs.microsoft.com/typescript/announcing-typescript-7-0-beta/), [typescript-go repo](https://github.com/microsoft/typescript-go/)