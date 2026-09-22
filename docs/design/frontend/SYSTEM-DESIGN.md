# wms-fe — system design (high level)

The web dashboard. How the pieces fit and why they are shaped that way.

Companions: `IMPLEMENTATION-GUIDE.md` (the patterns to code by), `../SYSTEM-DESIGN.md` (the whole system), `../../repos/wms-fe/README.md` (the interface contract).

All paths below are relative to `workspace/core/frontend/wms-fe`.

---

## What this is

Next.js 16.3 App Router, React 19, Tailwind 4, TypeScript 6, bun. Four runtime dependencies total (`package.json:21-27`): `@hey-api/client-fetch`, `geist`, `next`, `react`/`react-dom`. No state library, no data-fetching library, no component library package — shadcn/ui is a *token* inheritance, not an installed dependency; the primitives in `src/components/` are hand-written against the CSS variables in `src/app/globals.css`.

Dev server is :3001 so the backend keeps :3000 (`package.json:12`).

Users: **Owner, Ops Manager, Accountant** on a desk. The floor uses `wms-mobile`; this app has no scan path, no offline queue, no service worker.

## What it deliberately does NOT do

**No business rule is decided here.** The backend re-reads the actor's role from the database on every command, so everything this app knows about permissions is cosmetic. `src/lib/users.ts:5-9` says it outright: the mirror "hides surfaces the session role cannot act on — the backend's per-command DB read stays the only authority; a stale FE role at worst shows a form whose submit answers 403 `role-denied`, never grants one."

The same posture repeats:

- **No hand-written API types.** AD-8. `src/lib/api/generated/` is produced from the backend's OpenAPI document and CI fails if it drifts (`.github/workflows/ci.yml:61-63`).
- **No client-side quantity or ATP arithmetic.** Acceptance reserves `min(qty, atp)` server-side; the client renders the shortfall the server reported (`src/lib/outbound-orders.ts:144-167`).
- **No optimistic mutation anywhere.** Every mutation awaits the server's answer, then re-reads. See IMPLEMENTATION-GUIDE §2.
- **No prose parsing.** Surfaces branch on the problem-details `code`, never on the message (`src/lib/over-receipt.ts:8-9`).
- **No "blocked" screens.** A surface a role cannot act on is hidden, or renders read-only without the affordance.
- **No infinite scroll, no offset pagination** — cursor only (`src/lib/cursor.ts:1-5`).

The auth gate in `src/proxy.ts` is explicitly *not* an enforcement boundary either (`src/proxy.ts:16-18`): it is a redirect convenience over a presence cookie.

---

## Route map

`src/app/layout.tsx` is document chrome only — the pre-paint theme script (`:16-28`) and the Geist font. Two route groups hang off it so signup never renders the app sidebar.

### `(app)` — the twelve in-shell surfaces (`src/app/(app)/layout.tsx` → `AppShell`)

| Route | Surface | State |
|---|---|---|
| `/` | Overview | **Partial.** Server component, `dynamic = 'force-dynamic'`. Four KPI tiles: three hold a literal `—`, the fourth renders a live `/health` probe behind a 3-second `AbortSignal.timeout` (`page.tsx:16-22`). Below it an intentionally empty `DataTable` |
| `/inventory` | Inventory | `SurfacePlaceholder` |
| `/inbound` | Inbound | **Real** — `InboundCards`: purchase orders, goods receipts, QC holds (place + release, gated on `qc.manage`) |
| `/outbound` | Outbound | **Real** — `Outbound`: one warehouse picker shared by the orders surface (4.2b) and the waves surface (4.2c); the order detail groups exploded kit lines parent-over-children and sums totals over top-level lines only (11.6) |
| `/moves` | Moves | `SurfacePlaceholder` |
| `/conflicts` | Conflicts & Reviews | **Real** — `OverReceiptQueue`. The only nav item that declares a capability (`review.decide`, `src/lib/navigation.ts:39`) |
| `/notifications` | Notifications | `SurfacePlaceholder` |
| `/replenishment` | Replenishment | `SurfacePlaceholder` |
| `/channels` | Channels | `SurfacePlaceholder` |
| `/compliance` | Compliance | `SurfacePlaceholder` |
| `/reports` | Reports / Audit | `SurfacePlaceholder` |
| `/settings` | Settings | **Real** — a `SurfacePlaceholder` header above nine working cards: setup checklist, warehouse create, zones/bins setup, catalog import, products (11.6), SKU table (with the kit editor, 11.6), users, warehouse list, devices (`settings/page.tsx:15-25`) |

Six of twelve are still `SurfacePlaceholder` — a two-prop component rendering a heading and a sentence (`src/components/shell/surface-placeholder.tsx`). The IA is complete; the surfaces are not.

### `(auth)` — outside the shell (`src/app/(auth)/layout.tsx`, a centred card)

| Route | Notes |
|---|---|
| `/login` | Reads `?email=` to prefill after registration |
| `/register` | Tenant + owner in one call; returns **no token**, so it routes to `/login` rather than faking a session (`auth-forms.tsx:40-42`) |

### Ungrouped

| Route | Notes |
|---|---|
| `/accept-invite` | Unauthenticated by design — `?tenant=&token=`; the invitee sets their own password. Renders **without** the auth group's layout, so it has no centring wrapper |

**There is no `[id]` route anywhere in the app.** Detail is rendered in the `DataTable`'s expanded-row slot instead (`src/lib/use-outbound-orders.ts:153-159`) — a decision, not an omission: the list rows genuinely cannot carry the detail (`OrderEntryDto` has no `lines`, no `lineCount`, no `totalUnits`), and one fetch on expand was cheaper than a route.

### The gate

`src/proxy.ts` matches everything but Next internals and static assets (`:50`). No hint cookie + a non-auth path → `/login`; hint + an auth path → `/`. The decision is extracted as a pure `gate(pathname, hasHint)` (`:29`) because `bun:test` has no Next runtime.

---

## The data layer

### Generation

```
wms-be:  bun run openapi:export        → openapi/openapi.json
wms-fe:  bun run api:generate          → src/lib/api/generated/   (openapi-ts.config.ts)
         commit the regenerated tree
```

`openapi-ts.config.ts` reads `../../backend/wms-be/openapi/openapi.json` — a **relative path into the meta-repo workspace layout**. That is why the CI `generated-client` job checks both repos out into `workspace/core/{frontend,backend}/…` (`ci.yml:39-47`) before regenerating and running `git diff --exit-code src/lib/api/generated`.

Plugins: `@hey-api/client-fetch`, `@hey-api/sdk`, `@hey-api/typescript`. The output is a fetch wrapper, which is what makes component tests able to drive a whole surface through a stubbed global `fetch`.

### Consumption — the `fetch*` wrappers

`src/lib/api/client.ts` is the only file that imports from `generated/sdk.gen`. It configures the client once and exports **47 `fetchApi*` functions**, each a ~10-line shape:

```ts
export async function fetchApiListWaves(tenantId, warehouseId, options?) {
  const { data, error } = await outboundControllerListWaves({
    path: { tenantId, warehouseId },
    query: options?.cursor === undefined ? undefined : { cursor: options.cursor },
    signal: options?.signal,
  });
  if (error || !data) throw unwrapError(error, 400);
  return data;
}
```

Two global interceptors do the session work:

- **Request** (`client.ts:126`): attaches `Authorization: Bearer` from `readSession()`, and calls `ensureSessionHint()` so a page rendered on an expired hint cookie re-asserts it rather than bouncing on the next hard navigation.
- **Response** (`client.ts:143`): a **401 clears the stored session immediately**. The backend's verdict is authoritative — expired, revoked or tampered all read the same.

Base URL: `process.env.NEXT_PUBLIC_API_BASE_URL || 'http://localhost:3000/api/v1'`. The `||` rather than `??` is deliberate (`client.ts:114`) — a set-but-empty variable still falls back.

### Error unwrapping — three distinct outcomes

`unwrapError` (`client.ts:192`) is the whole error contract, and its shape is the record of a defect:

| Input | Becomes | Why |
|---|---|---|
| problem+json (`code` present) | `ApiProblem(code, status, detail, title)` | The machine code is what every surface branches on |
| an `Error` (fetch rejected — backend down, DNS, CORS, abort) | **the Error itself**, unchanged | Wrapping it as `ApiProblem('request-failed')` put the literal `"TypeError: Failed to fetch"` on screen, because every reason mapper renders `detail` in its default arm. The house "is wms-be running?" copy was unreachable in practice (`client.ts:175-191`) |
| a non-object body (an HTML 502 page, a plain-text gateway message) | a plain `Error` with a synthetic sentence | Same reason — raw markup used to reach the banner (`client.ts:199-206`) |
| a non-problem JSON error body (`{message:'boom'}`) | `ApiProblem('request-failed')` | Still an answer from the server |

`ApiProblem` carries `title` as well as `detail` (`client.ts:157-164`) specifically because some refusals — an order cancel blocked by a committed reservation or a drawn pick line — are caused by state **invisible in every DTO this client holds**. The only honest rendering is the server's own words.

### Loaders — external store, no cache

There is no query client. Every list is a hook built from the same four parts:

1. `useSyncExternalStore(subscribeSession, () => readSession()?.tenant.id ?? null, () => null)` — the tenant id, with a server snapshot of `null` so SSR and the first client render agree.
2. A `useEffect` fetch, keyed on `[tenantId, scope…, activeCursor, revision]`, with a `cancelled` flag in the cleanup.
3. A `revision` counter bumped by a module-wide `window` event (`CATALOG_CHANGED_EVENT`, `ZONES_CHANGED_EVENT`, `OUTBOUND_CHANGED_EVENT`, `USERS_CHANGED_EVENT`, `WAREHOUSES_CHANGED_EVENT`) or by the returned `reload()`.
4. **A stale-page filter at render, never a setState in an effect.** The stored result carries the scope it was fetched for; if that no longer matches, the hook reports loading instead.

Two generations of this hook coexist, and the difference matters.

| | House hooks | Outbound hooks |
|---|---|---|
| Files | `use-catalog.ts`, `use-devices.ts`, `use-users.ts`, `use-zone-bins.ts`, `use-warehouse-zones.ts`, `use-tenant-warehouses.ts`, `use-setup-checklist.ts`, `use-inbound.ts` | `use-outbound-orders.ts`, `use-outbound-waves.ts` |
| Return | `Page | null` | `ResourceState<T> & Reloadable` — `loading | ready | failed` |
| On fetch failure | `catch {}`, returns `null` — **indistinguishable from loading** | an explicit `failed` arm carrying a reason string, plus `reload()` |

The second shape exists because the first was 4.2b's largest review finding (`use-outbound-waves.ts:20-25`): a surface rendering `null` as "Loading…" tells the viewer a fetch is still in flight *forever*. **New hooks use `ResourceState`.** The house hooks are a known debt, not a pattern to copy.

### Cursor pagination

Cursors are opaque base64url of `{createdAt, id}` (`src/lib/cursor.ts`), encoded/decoded UTF-8-safely because `btoa` is latin-1 only (`:14-22`). The client never constructs one from domain data. `buildPage` mirrors the backend's `limit + 1` primitive for symmetry, though the app currently consumes server-built pages rather than building its own.

`DataTable` owns Prev/Next as internal state (`data-table.tsx:57`) — which is why a surface that invalidates the keyset position must **remount the table** (a `pageEpoch` key) rather than just refetch; see `outbound-orders.tsx:270-285`.

For reads that need the *whole* chain — a SKU id→object map, the warehouse picker, a merge-target bin list — `fetchAllPages` (`src/lib/fetch-all-pages.ts`) follows `nextCursor` to null, **bounded at 20 hops** so a misbehaving backend cannot spin forever. `fetchAllWarehouses` is a near-duplicate that stays specialized because its fetcher carries the tenant id.

`fetchAllPages` returns what it has and says nothing when it hits the cap. `useWavePolicies` therefore walks the chain by hand (`use-outbound-waves.ts:251-269`) to return a `truncated` flag — because every wave row reads its carrier cutoff out of that list, and a silent truncation would make "policy not loaded" indistinguishable from "this policy has no cutoff."

---

## Auth and session

**Storage.** `localStorage['wms-session']` holds `{token, tenant, user, expiresAt}` (`src/lib/auth.ts:12`, `:38-44`). The token is the backend's 15-minute HS256 session; there is no refresh.

**`readSession()` is pure** (`auth.ts:53`) — it never writes, never dispatches. It is the `getSnapshot` of every `useSyncExternalStore` subscription, and a side effect there would run during render. It validates the shape and returns `null` for: missing row, malformed JSON, a row with no `user` (a pre-1.5 session), or `expiresAt <= Date.now()`. **An expired session simply reads as signed-out**; the stale row is cleaned up by the next write.

**The expiry watchdog.** Because `readSession` is pure, nothing in a render notices the TTL passing. `scheduleExpiryDispatch` (`auth.ts:91`) sets a timer on every write that fires `SESSION_CHANGED_EVENT` at the expiry instant, flipping every subscribed surface to signed-out without waiting for a navigation. The delay is clamped to `2**31 - 1`.

**The hint cookie.** `wms-session-hint` (`auth.ts:33`) mirrors session *presence* — never token material — because `src/proxy.ts` runs server-side and cannot see localStorage. Max-Age matches the token TTL; `Secure` only on https; `max-age=0` is the delete. If `localStorage` throws (private mode), `writeSession` **skips the cookie too** (`auth.ts:106-110`): admitting the user into pages that cannot call the API is worse than an honest `/login`.

**Bootstrap.** `AppShell` fires `refreshSessionUser()` once on mount (`app-shell.tsx:29-31`). It re-reads `/me` and rewrites the stored session **only if** id, role or status moved (`client.ts:1117-1140`). A failure is swallowed — the stored role stays, because gating is cosmetic.

**Subscription.** `subscribeSession` (`auth.ts:167`) listens to both the `storage` event (other tabs) and the local `SESSION_CHANGED_EVENT` (this tab: sign-in, sign-out, expiry).

### What happens when…

| Event | Result |
|---|---|
| **The role changes server-side** | The next mount's `/me` bootstrap rewrites the session and `SESSION_CHANGED_EVENT` fires. Surfaces that subscribed to the *role* re-render their affordances (`outbound.tsx:64-70`, `over-receipt-queue.tsx:67-73`, `inbound-cards.tsx:287-293`, `sku-table.tsx:59-68`). Five Settings cards subscribe only to session *presence* and read the role with a bare `readSession()` at render — they do not. See Gotchas |
| **The token expires while the tab is open** | The watchdog timer fires at the instant, surfaces flip to signed-out. The hint cookie expires on its own clock, so the next hard navigation redirects to `/login` |
| **The backend rejects the token (401)** | The response interceptor clears the session *and* the hint cookie immediately |
| **Sign-out** | `clearSession()` — removes the row, deletes the cookie browser-wide (so every tab closes), then `router.push('/login')` (`sign-out.tsx:26-29`) |
| **A role appears that this build does not know** | `roleHasCapability` throws. See Gotchas |

The **picked warehouse** is separate state: `localStorage['wms-active-warehouse:<tenantId>']` (`src/lib/warehouses.ts:19-23`). The tenant-id suffix is deliberate — re-signing in as another tenant can never read the previous tenant's pick. There is no server-side "active warehouse" concept yet.

---

## The capability mirror

`src/lib/users.ts` hand-mirrors the backend's `src/modules/tenancy/permissions.ts`: a `CAPABILITIES` tuple (22 entries as of story 4.6b) and `ROLE_CAPABILITIES` for the four roles.

**Why it exists.** The sidebar must decide what to render before any request is made. There is no capability endpoint; the backend answers 403 `role-denied` at command time, which is the wrong moment to learn a form should not have been offered.

**How it drifts.** Silently, and it did: `stock.adjust`, `vendor.manage` and `po.manage` were missing through epics 2–3 until story 4.2b noticed (`scripts/check-capability-mirror.ts:5-9`). `users.test.ts` cannot catch this — it only restates the file under test.

Two structural defences:

1. **The Ops Manager grant is computed, not copied.** `ops_manager: CAPABILITIES.filter(c => !OWNER_ONLY_CAPABILITIES.includes(c))` (`users.ts:88`). The comment at `:77-82` names the reason: "a copy drifts the moment a capability is added, which is exactly how this mirror fell eight entries behind in the first place."
2. **The CI guard.** `scripts/check-capability-mirror.ts` parses the backend's own source — strips comments (capability names appear in prose), pulls the `CAPABILITIES` array literal and each role's `new Set(...)` block — and exits 1 naming exactly what is missing or extra. It runs in the `generated-client` job (`ci.yml:70-72`), which already has wms-be checked out.

The guard resolves `../../../backend/wms-be/src/modules/tenancy/permissions.ts` from `scripts/`. It is coupled to both the workspace layout **and** the literal declaration syntax of the backend file: renaming the export or reshaping the role sets throws a "no longer declares" error rather than passing.

`carrier.manage` is in the mirror with **no web surface consuming it** (`users.ts:66-72`) — kept in step so the guard passes and the next surface has its gate ready.

---

## Shared components

**`DataTable`** (`src/components/data-table/data-table.tsx`) — the spine every list drops into. ~40px rows, sticky header, `overflow-x-auto`, `.data text-right` on columns flagged `numeric`. Two opt-in slots:

- `onCursor` / `nextCursor` — Prev/Next. Prev is disabled until a Next has actually happened, because the table tracks the cursor that produced the current page.
- `renderExpanded(row)` — returns a node, and a full-width `<tr>` appears beneath that row, carrying the id `expandedRowId(row.id)` so the toggle's `aria-controls` and the panel agree through one shared function rather than a magic string. Returning `null`/`undefined` renders **nothing**: a surface that does not opt in is byte-for-byte unchanged.

**`AppShell`** (`src/components/shell/app-shell.tsx`) — sidebar + header + `<main>`. Owns the `/me` bootstrap, the ⌘K binding, and layer discipline: Esc closes the topmost layer only (the header menu's Esc handler is skipped while the palette is open, `:59-68`), one palette layer ever. Responsive contract: ≥1024px full sidebar · 768–1023px monogram-only · <768px header menu, which mounts its own `WarehouseSwitcher` because the sidebar's is invisible there.

**`Sidebar`** renders `visibleNavItems(role)` — the IA filtered by capability. An **unknown/absent role sees the full list** (`navigation.ts:50-54`): the server render has no role, and hiding everything then showing it is worse than the reverse.

**`CommandPalette`** — ⌘K, Esc closes, Enter commits, arrows select. Touch users reach it from the header button; hover-only affordances are banned.

**`KpiTile`** — 28px semibold tabular numerals on the `.kpi` class. The comment (`kpi-tile.tsx:4`) states the rule the tile exists to keep: values reconcile to the ledger, and **there is no secondary "estimated" state**.

**`FeedbackBanner`** — glyph + word + one reason line, `role="status"` when accepted and `role="alert"` when rejected. Two tones only; never colour alone.

**`components/outbound/shell.tsx`** — the six shared class constants, `Section` (whose heading renders in *every* state, including a failed read) and `ReadFailure` (banner + Retry, never progress copy). Its header comment records why it exists: orders and waves each carried a byte-identical copy *and their own* `useOutboundWarehouses()` call, so `/outbound` rendered two warehouse pickers that could disagree.

---

## Testing

234 tests across 16 files, all `bun test` (`bun test v1.4.0`, ~500 ms). No Playwright, no Jest, no testing-library.

**What is tested**

| Suite | Pins |
|---|---|
| `src/lib/api/client.test.ts` (30) | The error-unwrapping taxonomy, the bearer interceptor, the 401 interceptor, `refreshSessionUser`, and per-wrapper: the path, whether a first page sends a query at all, the body, and the `Idempotency-Key` header |
| `src/lib/outbound-waves.test.ts` (70) | Cutoff arithmetic, the status/label vocabularies, every reason mapper, the policy-draft parser |
| `src/lib/outbound-orders.test.ts` (36) | Shortfall copy, totals, the draft-line parser, the page filter |
| `src/lib/users.test.ts` (14) | The mirror's grants, role by role |
| `src/lib/auth.test.ts` (17) | Session read/write/clear, expiry, the hint cookie, `ensureSessionHint` |
| `src/lib/brand-tokens.test.ts` (6) | The token layer against `globals.css` — including a scan that **fails on any hex outside the allowed set** and on `gradient(` |
| `src/lib/navigation.test.ts`, `over-receipt.test.ts`, `cursor.test.ts`, `fetch-all-*.test.ts`, `theme.test.ts`, `ulid.test.ts`, `proxy.test.ts` | IA filtering, reason mappers, cursor codec, hop caps, the gate decision |

**What is not tested: rendered screens, almost entirely.** Fourteen of the sixteen suites are pure logic. The convention that produced that — "this repo's tests all live in `src/lib/`" (`outbound-orders.ts:5-7`) — is also the reason so much copy and derivation was *extracted* out of JSX: a sentence that stays in a component is a sentence nothing can pin.

**The component-test infrastructure now exists** and is the intended path for anything screen-shaped:

- `bunfig.toml` preloads `happydom.ts`, which registers happy-dom as real globals and sets `IS_REACT_ACT_ENVIRONMENT` before any test file is evaluated.
- `src/lib/test/render.ts` — a ~30-line `createRoot` + `act` helper returning `{container, rerender, unmount}`. Hand-rolled rather than adding @testing-library, matching the repo's four-dependency posture.
- `src/lib/test/globals.ts` — `stubGlobal`/`restoreGlobals`, which **define over** a global remembering its descriptor, then put it back. Plain assignment no longer works against happy-dom (`localStorage` is an accessor with no setter) and `delete` would strip the real global out from under every later file in the run.

Two component suites use it. `data-table.test.tsx` (5) exists because 4.2b shipped `renderExpanded` with no test at all and a review proved by mutation that rendering the detail row unconditionally, or hard-coding `colSpan`, broke six surfaces while the suite stayed green. `outbound-waves.test.tsx` (21) drives the whole surface **through a stubbed global `fetch`** rather than mocked hooks — the generated client is a fetch wrapper, so the gates and wiring under test are the ones that ship. It pins, among others, that pressing Release calls RELEASE: asserting button labels alone left the verb ternary in `submit()` free to be inverted with the whole repo green.

---

## How a backend contract change reaches this repo

```
1. wms-be PR: the additive change            (backend first — always)
2. wms-be:  bun run openapi:export
3. wms-fe:  bun run api:generate  → commit src/lib/api/generated/
4. wms-fe:  mirror any new capability in src/lib/users.ts
5. wms-fe PR: the surface that consumes it
6. WMS-Meta PR: docs + interface contract     (meta last)
```

**What breaks until the backend PR merges.** The `generated-client` CI job checks out `chinnisasi/WMS-BE` at its **default branch** (`ci.yml:44-47`), then regenerates and diffs. A frontend PR carrying a client generated from an unmerged backend branch fails that diff, every time, until the backend merges. This is expected on every cross-repo story, not a defect — it is recorded in the meta guide (`../IMPLEMENTATION-GUIDE.md:182`) and in this session's memory. The web job (lint/test/typecheck/build) is unaffected and should still be green.

The capability-mirror guard is in the same job, so it goes red for the same window.

---

## Gotchas

These have all caused, or came one review short of causing, a real defect.

1. **A transport failure must not be dressed as a problem.** Wrapping the rejected fetch's own Error as `ApiProblem('request-failed')` made every reason mapper's default arm render `detail` — putting `"TypeError: Failed to fetch"` on screen and making the house "is wms-be running?" copy unreachable. Non-object bodies (an HTML 502) are the same class. `client.ts:175-207`.

2. **A hook that swallows a failed fetch into `null` renders as "Loading…" forever.** The eight house loaders still do this (`use-catalog.ts:62-64`, `use-zone-bins.ts:74-76`, and siblings). `ResourceState` exists to end it; `use-outbound-waves.ts:20-25` is the note.

3. **`roleHasCapability` throws on a role outside the four.** `ROLE_CAPABILITIES[role].includes(...)` (`users.ts:103`) guards `undefined` and nothing else; a `UserRole` outside the record indexes to `undefined` and the `.includes` call is a `TypeError`. Verified: `"undefined is not an object (evaluating 'ROLE_CAPABILITIES[role].includes')"`. `readSession` only checks `typeof role === 'string'` (`auth.ts:68`), so a backend that adds a fifth role, a stale build, or a hand-edited localStorage row crashes the **sidebar** — the first thing that renders. The test at `users.test.ts:236` covers `undefined` only.

4. **Two gating styles coexist, and one of them does not track a role change.** The four newer surfaces subscribe to the role itself through `useSyncExternalStore`. Five Settings cards — `zone-bin-setup.tsx:117`, `devices-card.tsx:48`, `users-card.tsx:66`, `import-catalog.tsx:56`, `warehouse-create-form.tsx:58` — subscribe only to session *presence* and then read `readSession()?.user.role` at render. The `/me` bootstrap's role rewrite does not change presence, so those affordances stay as they were until something else re-renders them. `sku-table.tsx:59-68` is the corrected sibling in the same directory.

5. **The ⌘K palette navigates the unfiltered IA.** It imports `NAV_ITEMS`, not `visibleNavItems` (`command-palette.tsx:6`, `:68`). An Operator with Conflicts hidden from the sidebar can still reach `/conflicts` from the palette — and then sees the queue with no decide buttons, which is a "blocked"-shaped screen the design forbids.

6. **`DataTable`'s cursor is internal state.** A mutation that lands a row at the top of page one must bump a `pageEpoch` key to remount the table, or Prev stays offered on what is now page one (`outbound-orders.tsx:269-285`, `outbound-waves.tsx:620-646`).

7. **A pre-render double-click fires both handlers before `disabled` renders.** A synchronous ref guard is the fix, not React state — a second command with a fresh Idempotency-Key 409s right after the first succeeded. `inbound-cards.tsx:299-306` (a `Set` keyed by hold id) and `:445-447`.

8. **A superseded fetch must not win the race into state.** The merge-target picker increments a `useRef` counter per fetch and drops any response whose seq is no longer current (`zone-bin-setup.tsx:588-590`, `:679`, `:688`, `:698`). The loader hooks solve the same problem differently — by comparing the stored scope at render — and the two are not interchangeable: the ref guard is for a fetch fired from an event handler, the render filter for one fired from an effect.

9. **A mutation that settles after its tree unmounts.** Switching warehouse remounts the outbound tables, so `WavesTable` carries a `mounted` ref and returns early in both arms of `submit()` (`outbound-waves.tsx:625-634`, `:670`, `:681`).

10. **`readSession()` must stay pure.** It is a `getSnapshot`; clearing storage and dispatching on expiry inside it would run a side effect during render. The expiry timer exists precisely so the purity can hold (`auth.ts:46-51`, `:82-88`).

11. **`localStorage` failing must not admit the user.** `writeSession` returns early on a storage throw **before** writing the hint cookie (`auth.ts:105-110`). Writing the cookie anyway would let the proxy gate wave the user into pages whose every API call is unauthenticated.

12. **The client is generated from a relative workspace path.** `openapi-ts.config.ts:9` points at `../../backend/wms-be/openapi/openapi.json`. Outside the meta-repo layout — a bare clone of wms-fe — `bun run api:generate` simply cannot resolve its input, and neither can `check:capability-mirror`.

13. **Quantities are fractional now and this app has not caught up.** Backend stories 10.1/10.2 made every quantity a base-UoM value at the UoM's declared precision (0 places for `each`, 3 for `kg`). The regenerated client carries that in every field description. But `SkuResponse` exposes `uom` and **not** `uomPrecision` — only the mobile `CatalogSnapshotSkuDto` carries it (`types.gen.ts:1822`) — so the web has no way to read a SKU's declared precision from the API today. Meanwhile `parseDraftLines` refuses anything but `^\d+$` (`outbound-orders.ts:369`), the order-quantity input is `step={1}` (`outbound-orders.tsx:208`), the reorder-point/qty inputs default to step 1 (`sku-table.tsx:253`, `:264`), and every quantity on screen is a bare `{value}` interpolation with no formatter anywhere in the repo. See IMPLEMENTATION-GUIDE §6 for the rule and the open sites.
