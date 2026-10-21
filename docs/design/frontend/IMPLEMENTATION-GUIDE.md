# wms-fe — implementation guide (low-level design)

**Read this before writing frontend code.** It is the set of patterns every surface repeats. Most of it exists because a review caught the alternative failing.

Companions: `SYSTEM-DESIGN.md` (how the app fits together), `../IMPLEMENTATION-GUIDE.md` (the backend's), `../../repos/wms-fe/README.md` (the interface contract).

All paths are relative to `workspace/core/frontend/wms-fe`. Package manager is **bun**; `preinstall` refuses npm/yarn/pnpm outright (`package.json:11`).

---

## 1. The loader pattern

Every list read is an external-store hook. `use-outbound-waves.ts:40` (`useOutboundWaves`) is the canonical full-shape example; `use-outbound-orders.ts:58` is its twin. **Write new hooks in this shape.**

```ts
export function useThings(warehouseId: string | null):
  ResourceState<ThingsPage> & Reloadable & { onCursor: (c: string | null) => void } {

  // 1. Session identity through the external store. The server snapshot is
  //    `null`, so SSR and the first client render agree — no hydration flash.
  const tenantId = useSyncExternalStore(
    subscribeSession,
    () => readSession()?.tenant.id ?? null,
    () => null,
  );

  // 2. The requested cursor, STAMPED with the scope it was requested for.
  //    A cursor left over from another tenant/warehouse is treated as a
  //    first-page request — never replayed against the wrong scope.
  const [requested, setRequested] = useState<{tenantId; warehouseId; cursor} | null>(null);
  const activeCursor =
    requested !== null && requested.tenantId === tenantId && requested.warehouseId === warehouseId
      ? requested.cursor
      : null;

  // 3. The revision counter — bumped by the module's window event and by reload().
  const [revision, setRevision] = useState(0);
  const [result, setResult] = useState<{tenantId; warehouseId; requested; state} | null>(null);

  useEffect(() => {
    const onChange = () => setRevision((r) => r + 1);
    window.addEventListener(OUTBOUND_CHANGED_EVENT, onChange);
    return () => window.removeEventListener(OUTBOUND_CHANGED_EVENT, onChange);
  }, []);

  // 4. The fetch. `cancelled` in the cleanup; BOTH arms stamp the scope.
  useEffect(() => {
    if (tenantId === null || warehouseId === null) return;
    let cancelled = false;
    (async () => {
      try {
        const page = await fetchApiListThings(tenantId, warehouseId,
          activeCursor === null ? undefined : { cursor: activeCursor });
        if (!cancelled) setResult({ tenantId, warehouseId, requested: activeCursor,
          state: { state: 'ready', data: { items: page.items, nextCursor: page.nextCursor ?? null } } });
      } catch (error) {
        if (!cancelled) setResult({ tenantId, warehouseId, requested: activeCursor,
          state: { state: 'failed', reason: readReason(error, 'things') } });
      }
    })();
    return () => { cancelled = true; };
  }, [tenantId, warehouseId, activeCursor, revision]);

  // 5. The stale filter — AT RENDER. Never a setState in an effect.
  const stale =
    tenantId === null || warehouseId === null || result === null ||
    result.tenantId !== tenantId || result.warehouseId !== warehouseId ||
    result.requested !== activeCursor;

  return { ...(stale ? ({ state: 'loading' } as const) : result.state), onCursor, reload };
}
```

**Why each part:**

- **Tenant-scoped cursor requests.** A cursor is an opaque keyset position in one scope's ordering. Replaying it after a warehouse switch is a request for a page that means nothing. Stamping the request with its scope makes the mismatch a first-page request rather than a wrong answer (`use-outbound-waves.ts:49-60`).
- **The stale-page render filter.** Deriving "is this result still relevant?" at render is what keeps the effect free of a synchronous `setState` — that is stated as the rule in `use-catalog.ts:20-23` and `use-zone-bins.ts:21-22`. A `setState` clearing the page in an effect renders twice and flickers.
- **`cancelled` in the cleanup** covers the ordinary in-flight case. It is **not** a seq guard — see §1.3.
- **`reload()` must clear the result first** when the hook has a `failed` arm (`use-outbound-waves.ts:119-125`): leaving the old failure on screen while the refetch is in flight renders a second identical failure as an inert button, and the viewer cannot tell Retry did anything.

### 1.1 Return shape

Use `ResourceState<T> & Reloadable` (`lib/resource-state.ts` since 21-11b; `use-outbound-orders.ts` re-exports both, so existing importers are unchanged — a portal module must import from `lib/resource-state`) — `loading | ready | failed`, with `reload()`.

**Do not write a hook that returns `Page | null`.** The seven remaining house hooks do (`use-catalog.ts`, `use-devices.ts`, `use-users.ts`, `use-zone-bins.ts`, `use-warehouse-zones.ts`, `use-setup-checklist.ts`, `use-inbound.ts`; `use-tenant-warehouses.ts` was converted by 21-11b), swallowing failures in a bare `catch {}`. A surface then renders `null` as "Loading…" forever. This was 4.2b's largest review finding (`use-outbound-waves.ts:20-25`). The old hooks are debt; converting one is fair game, copying one is not.

A failed read renders through `ReadFailure` (`components/shared/surface.tsx` since 21-11b; `components/outbound/shell.tsx` re-exports it with `Section` and the class constants, and a portal file must import from `shared/surface`) — banner plus Retry. **Progress copy is never used for a failure.**

**Warehouses: one hook, one rendering (21-11b).** `useTenantWarehouses()` (`lib/use-tenant-warehouses.ts`) is the one warehouses hook — `ResourceState<TenantWarehouses> & Reloadable`, the full cursor chain, refetch on `WAREHOUSES_CHANGED_EVENT`. `useOutboundWarehouses` is an alias, not a second implementation. Two rules of its own:

- A failed **refetch** keeps the last-good list and is **not silent** (decision 3): the ready data carries `refreshFailed: reason`, and the consumer renders `WarehousesRefreshNote({ reason, onRetry })` (`components/shared/warehouses-failure.tsx`) — one non-blocking line, "Couldn't refresh warehouses — Retry" — where it renders its picker or list (inside the switcher; inline above the list elsewhere). The next successful read clears it. The state goes to `failed` only when there is no data yet for the tenant (a failed **first** load); `reload()` clears a `failed` state first, so Retry on a first load shows loading briefly — accepted, it is a new load.
- **The four former `useOutboundWarehouses` screens** (Outbound, Overview, Replenishment, Channels) share this behaviour since 21-11b: before, any failed read — even a refresh — replaced the whole surface with a failure; now a failed refresh keeps the last-good warehouse and shows the note, and only a failed first load renders `WarehousesFailure`.
- A consumer that needs `tenantId` while loading uses `ready ? data : { tenantId: null, items: [] }` (the precedent is `outbound.tsx`); loading renders as before.

Every surface that lists warehouses renders `failed` through `WarehousesFailure({ state })` (`components/shared/warehouses-failure.tsx`) — "Warehouses not loaded" + reason + Retry; `compact` for the switcher. On a report page it takes the picker's slot and the report still reads for all warehouses. A label-only lookup (the variance and adjustment queues) degrades to the warehouse id, with no banner. The portal's `usePortalWarehouses` failure renders through the same component. Never render a failed warehouses read as an empty list or as "No warehouse yet".

### 1.2 Reading the whole chain

`fetchAllPages(fetchPage)` (`lib/fetch-all-pages.ts:19`) follows `nextCursor` to null, capped at `MAX_PAGE_HOPS = 20`. Use it for id→object maps and pickers (`useOutboundSkus`, `useVendorMap`, `useSkuMap`, `useBinCodeMap`), never for a viewer-paginated list.

It returns what it has and **says nothing when it hits the cap**. If a truncation would be indistinguishable from a legitimate absence, walk the chain inline and return a `truncated` flag instead — `useWavePolicies` does exactly this (`use-outbound-waves.ts:251-269`), because a wave row reads its carrier cutoff out of that map and a missing policy would make "not loaded" look like "no cutoff configured".

`fetchAllWarehouses` (`lib/fetch-all-warehouses.ts:22`) is a near-duplicate kept specialized because its fetcher carries the tenant id.

### 1.3 The seq guard — for fetches fired from event handlers

The `cancelled` flag only helps when React tears the effect down. A fetch started from a click has no cleanup, so a rapid second click can let the **first** response land last.

```ts
const mergeFetchSeq = useRef(0);          // zone-bin-setup.tsx:590
...
const seq = ++mergeFetchSeq.current;      // :679
const bins = await Promise.all(...);
if (seq !== mergeFetchSeq.current) return;  // :688 — superseded; drop it
setMergeTargets(...);
```

The guard belongs in **both** arms — the `catch` too (`zone-bin-setup.tsx:698`), or a superseded failure overwrites a current success with an error banner.

**A read that must not overtake a write (9-2).** The bell's status read and the panel's `opened` POST touch the same server state. A status read sent alongside an in-flight `opened` can be answered before the open commits and re-light the dot the open just cleared. `useNotificationStatus` (`lib/use-notifications.ts`) keeps the in-flight `opened` promise in a ref; a status read that starts while it is set awaits it (failure included) before sending, then re-checks its seq. A read that was already in flight when the open began is dropped by the seq guard as usual. Use the same shape whenever a background read and a user-triggered write share state.

Related but distinct: a mutation that settles after its tree unmounts. `WavesTable` keeps a `mounted` ref and returns early in both arms of `submit()` (`outbound-waves.tsx:625-634`, `:670`, `:681`) — switching warehouse remounts the outbound tables.

### 1.4 Cross-surface invalidation

Each module owns a three-line broadcaster: a `window` event constant plus a `notify*()` (`lib/outbound.ts`, `lib/catalog.ts`, `lib/zones.ts`, `lib/warehouses.ts`, `lib/users.ts:106-111`). Mutations call `notify*()`; readers subscribe and bump their revision.

**One event per module, not per mutation** (`lib/outbound.ts:6-9`): an order cancel changes the order list *and* anything downstream that grouped it, so a reader that only cared about "its own" mutation goes stale the first time a sibling surface moves the same row.

If the mutation invalidates the keyset position, the surface must also **return the table to page one and remount it** — `DataTable` holds its Prev/Next cursor as internal state:

```ts
const [pageEpoch, setPageEpoch] = useState(0);            // outbound-orders.tsx:270
const onChange = () => { onCursor(null); setPageEpoch(e => e + 1); };
...
<DataTable key={pageEpoch} … />
```

Without the remount the table still offers Prev on what is now page one, and the banner reports an acceptance the page on screen demonstrably cannot show.

**Kit-ness is a client-side join (11.6), never a flag.** The API carries no `isKit`; the SKU table, the products card and the order detail all derive it from `useKits()` over `GET /catalog/kits` (`kitOf(skuId)`), following the module broadcaster: a kit POST/PUT calls `notifyCatalogChanged()` and every reader refetches. Two rules the kit surfaces pin:

- **The kit editor's recovery is a refetch, not a local cache update.** After a kit POST that was refused `kit-already-composed`, the editor refetches the whole kits list (`fetchAllPages`) so the row's kit-ness is read from the server, then surfaces the refusal — and if even that refetch fails, the refusal STILL renders (`try/catch` falls through to the rejection banner). The refusal must never be eaten by a failed bookkeeping call.
- **The attach picker offers unattached SKUs only** (`productId === null`): the backend's attach arm has no current-attachment guard, so offering an attached SKU would let the PATCH silently move it between products. Filter the options rather than validating the submission — the §7 option-filtering rule.

### 1.5 Resetting on a scope switch — keyed state, not a reset effect

When a surface's derived scope changes (warehouse, status tab, tenant), state that belongs to the OLD scope must not survive the switch: a loaded trace re-fetched under a new warehouse answers a false 404 (12-7 review), a resolve banner persists above a queue it no longer describes. The instinct — `useEffect(() => setX(null), [scope])` — **fails the house ESLint rule `react-hooks/set-state-in-effect`**, and for good reason: the effect runs one render behind the scope change, so a downstream hook can see the stale state paired with the new scope for one pass (12-7's literal reset-effect shape would have let the trace hook fire the false 404 anyway).

**The pattern is keyed derivation:** store the scope INSIDE the state, derive the visible value by comparing scopes in the same render —

```ts
const [loadedOrder, setLoadedOrder] = useState<{ warehouseId: string; orderId: string } | null>(null);
const orderId = loadedOrder !== null && loadedOrder.warehouseId === warehouseId ? loadedOrder.orderId : null;
```

A switch invalidates the state in the same render, with no effect ordering to get wrong. 12-7 uses it three times (`cold-chain-trace.tsx` loaded order + draft, `excursion-queue.tsx` outcome banner keyed by `{tab, warehouseId}`). Reach for it before reaching for a reset effect.

### 1.6 Reading a filter from the URL — the drill pattern (9-1b)

This is the house rule for any screen that takes a filter from its URL. Two cases today: an Overview tile's drill (9-1b), and a document's "View ledger" link (9-3a, §1.9) — a ledger drill with a display-only `doc`.

**Parse on the server, mount keyed.** The route's server `page.tsx` awaits `searchParams` (a Promise in Next 16; each value is `string | string[]`), which makes the route render dynamically on each request (`ƒ` in the build output) rather than being prerendered. It calls the pure `parseDrill(screen, params)` from `lib/drill.ts` and renders the screen keyed on the result:

```tsx
export default async function OutboundPage({ searchParams }: { searchParams: Promise<{ [key: string]: string | string[] | undefined }> }) {
  const drill = parseDrill('outbound', await searchParams);
  return (
    <>
      {drill === 'unsupported' && <UnsupportedDrillNotice />}
      <Outbound key={drillKey(drill)} drill={drill} />
    </>
  );
}
```

- **The parse is all or nothing, once there is a `list`.** It returns a typed drill, `null`, or `'unsupported'`. Params with **no `list`** are a plain visit, so the result is `null` and every other key is ignored (an unrelated `utm_source` must not trigger the notice). With a `list`, any of these makes the whole drill unsupported, and the screen shows its normal view plus the notice: an unknown key, a repeated key, a malformed uuid, enum or boolean, an instant that is not ISO-8601 with a zone or is not a real calendar time (30 Feb and hour 24 are both refused), a `list` the screen does not serve, or a path-scoped list without its warehouse. A partly applied filter would list rows that are not the figure's. `to` without `from` is lawful (live drills), `type` parses to a one-element list, and booleans parse only from `'true'`/`'false'`. `SPECS` in `drill.ts` is the runtime twin of the `Drill` union.
- **The remount key does the reset.** `drillKey` is canonical (`'none'` without a drill). Clear is a soft navigation to the bare route, so the key changes and the screen remounts. No drilled cursor, cached page or `DataTable` Prev/Next stack survives into the normal view. A reset effect would run one render late (§1.5) and page the unfiltered list with a cursor minted by the filtered query.
- **The router lives in drilled mode only.** `useRouter`/`usePathname` are called only in `DrillBanner` (`components/shared/drill-banner.tsx`, which also holds `DrillUnavailable` and `UnsupportedDrillNotice`) and in the shared drilled tab bar (`DrillPageTabBar`, `components/shared/page-tabs.tsx`, page-tabs — every tabbed page's), and both render only in drilled mode. `useSearchParams` (a tabbed page's live `?tab=`, read in `usePageTab`) returns null outside the App Router, where the screen falls back to its local pick. A plain in-page URL change (a tab click) uses `window.history.replaceState`, which the App Router syncs into `useSearchParams`. A screen rendered without a drill never needs an App Router context, so tests that import screens statically keep working. A test that drives Clear mocks `next/navigation` first and then imports the screen dynamically (`components/drill/drill-screens.test.tsx`, after `portal.test.tsx`). That suite also renders each real `page.tsx` with `await Page({ searchParams: Promise.resolve(…) })`.
- **Effects depend on the drill's key, not the object.** A server-component refresh passes the screen a new but equal drill object. Every list hook therefore holds its drill through `useKeyedDrill` (`lib/use-drill.ts`), which changes only when `drillKey` does. Depending on the object directly would refetch on every refresh.

**Drilled mode:**

1. **Filter on the server only.** The list hook takes the drill and calls its `lib/drill-fetch.ts` fetcher. That fetcher sends exactly the drill's keys minus `list` (and, for a document drill, minus the display-only `doc`/`label` — §1.9), values verbatim. A path-scoped list (ledger, orders) puts the drill's warehouse in the path. That warehouse comes from the apiPath, and `drillHref` gives no link if the query names a different one. The screen's own tab, status and kind state is ignored and its controls are hidden. Never narrow the rows on the client: the backend proves that the drill, paged to exhaustion, equals the figure, and client-side narrowing would break that.
2. **Paging.** The cursor goes back verbatim, on the screen's existing paging (`DataTable` Prev/Next, or a queue's Next). Never decode or rebuild a cursor.
3. **The warehouse is the drill's, for that view only.** `lib/warehouses` is never written. Any control that would write the active warehouse is hidden: the outbound and replenishment pickers. A drilled view renders for the drill's warehouse even when the active warehouse is unset or the warehouses read failed (the Ledger is the example). It labels that warehouse with the shared `warehouseDisplayLabel` from `lib/drill.ts`: `CODE Name`, or `Warehouse <short id>`.
4. **One section is drilled, and the drill stays on screen.** `drillFor(drill, list)` gives each section its drill or `null`. The other sections on the page render normally for the active warehouse. Hide anything that would move the drilled section off screen, such as the `/conflicts` queue tab strip. Otherwise the drill would stay applied out of sight, with no banner to clear it.
5. **The banner.** `DrillBanner({ drill })` reads the warehouse names itself and shows `describeDrill(drill, warehouses)`. That text is the list, each filter as a label, "All statuses" for a status-bearing list (over-receipts, batch alerts, e-way) whose drill names no status, the window in IST ("as of …" for `to` only), and the warehouse label. There are no editable filter controls; Clear is the only action.
6. **A gated section.** If the drilled section is behind a capability the role lacks, show "This list isn't available to you" (`DrillUnavailable`). The tile already withholds such links with `drillLinkHref(drill, can)` in `lib/drill-routes.ts`.
7. **Actions (9-1b decision 7).** A per-row action that applies to its own row stays: approve/reject an over-receipt, cancel an order, dismiss an alert, and the e-way row actions on a **pending** bill only. Bulk selection and downloads are hidden while drilled (the e-way selection and NIC download). Page-level create forms are hidden too (create order, generate invoice).

**Adding a drill target:**
- **Lists:** add the list to `DRILL_LISTS`/`SCREEN_LISTS`, with a `SPECS` entry and a `Drill` arm.
- **Banner labels:** extend `describeDrill`'s tables for any new filter value: `STATUS_LABEL`, `KIND_LABEL`, the source tables, and `STATUS_BEARING` if the list's rows carry a status.
- **Fetch and route:** add a fetcher to `drill-fetch.ts` and the route to `drill-routes.ts`. If the target section is capability-gated, set `capability` on its `RouteEntry`.
- **The page:** have it parse and mount keyed, as above. Hold the drill in the hook through `useKeyedDrill`. Apply rule 7 to the screen's actions.
- **Tests:**
  - add the shape to the round trip in `drill.test.ts`;
  - add a `CASES` entry to `drill-screens.test.tsx`, and add any new filter key to `DRILL_ONLY_KEYS`;
  - add the page to `PAGE_CASES`.

### 1.7 A discriminated union from a newer backend — drop unknown arms at the mapping (9-2)

A generated union (`NotificationListResponse['items'][number]`, discriminated on `sourceType`) describes the backend **this build was generated from**. A newer backend can add an arm before the client is regenerated, and an exhaustive `switch` that reads `entry.summary.skuId` on an unknown arm throws. The bell lives in the shell, so one unknown entry crashed the shell when the panel opened (code review FE1).

The pattern (`lib/notifications.ts`):

```ts
const KNOWN_SOURCE_TYPES = { 'stock-adjustment': true, /* …every arm… */ } as const
  satisfies Record<SourceType, true>;          // a new generated arm without a row here is a compile error

export function knownNotifications(items: readonly unknown[]): NotificationEntry[] {
  return items.filter((item): item is NotificationEntry =>
    typeof item === 'object' && item !== null &&
    Object.prototype.hasOwnProperty.call(KNOWN_SOURCE_TYPES, (item as { sourceType?: unknown }).sourceType as string));
}
```

- **Filter where the response is mapped** — in the loader (`useNotifications`), before any component sees the rows — not in each renderer.
- **Keep a `never`-checked default arm** in every switch over the discriminant (`unknownSource(entry, fallback)`): unreachable for the generated union, but a safe fallback rather than a crash if an unknown arm ever slips past.
- **Use `hasOwnProperty`**, not `in` or an index read: a `sourceType` of `"constructor"` or `"toString"` must not pass.
- Test it: a fixture carrying an unknown arm renders the rest (`notifications.test.ts`, `notification-bell.test.tsx`, `notifications-view.test.tsx`).

### 1.8 A plain URL parameter beside a drill — `?queue=` (9-2)

Not every URL parameter is a drill. `/conflicts?queue=<id>` only picks the starting tab; it filters nothing, so it does not belong in `parseDrill`'s `SPECS` (where an unknown key would make a drill unsupported). The rules (`lib/conflicts-queues.ts`, `app/(app)/conflicts/page.tsx`):

- **No `list`, so `parseDrill` reads a plain visit** (`null`) and ignores `queue`.
- **Parse to a closed vocabulary** (`CONFLICTS_QUEUES`); a repeated value or an unknown id is `null` and the page opens on its default tab. A tab the role cannot see falls back like any other.
- **Join it into the remount key** (`` `${drillKey(drill)}|${queue ?? 'default'}` ``), so following a link to another queue from the same page remounts on it — the §1.5 keyed-state rule, not an effect.
- A drill still wins: while drilled, the tab is the drill's.

### 1.8a Page tabs — one module for every tabbed page (page-tabs, 2026-10-17)

Inbound, Outbound, Replenishment, Compliance and Settings show one section at a time behind a tab bar. Never re-derive the rules per page; use the shared module:

- **Definition** — `definePageTabs({ route, tabs, label, drillTabs })` (`lib/page-tabs.ts`, pure, so the server `page.tsx` parses with it): `parse(params)` (one known id, else null), `href(tab)` (**the default tab is the bare route**, every other `?tab=<id>` — one URL per view), `initial(drill, tab)` (a drill's list wins, then `?tab=`, then the first tab). Labels equal their section's heading exactly; each page's tablist has its own `aria-label`.
- **Screen** — `usePageTab(def, initial, drilled)` (`components/shared/page-tabs.tsx`): outside a drill the tab IS the live `?tab=`; a click `replaceState`s `def.href(tab)` and clicking the open tab writes nothing. `PageTabStrip` picks `PageTabBar` or, drilled, `DrillPageTabBar` (another tab → `router.replace(def.href(tab))`, leaving the drill); `PageTabPanel` holds the one mounted section (ids `${def.id}-tab-<id>` / `${def.id}-panel`).
- **Page** — parse `tab` and key the screen on `` `${drillKey(drill)}|${tab ?? 'default'}` ``. A drilled section's `DrillBanner` gets `clearHref={def.href(<its list's tab>)}`.
- **Gate** — the bar renders only past the screen's session gate; a wrapper with no gate of its own (`ComplianceTabs`, `SettingsTabs`) renders nothing until the session is known.
- **Only the selected section mounts**, so a test of a non-default section mounts with `initialTab` (or `?tab=`) rather than clicking — a click first mounts the default tab and pollutes "mounting sends reads only" claims — and queries inside the panel or by `data-tab`, never by bare text (the label and the `<h2>` are the same words).

### 1.9 Document drills — display-only keys, one key per document (9-3a)

FR-28: every ledger event is two navigations from its document. Five document surfaces link "View ledger" to `/inventory/ledger` filtered to that document — the GRN table, the PO table ("Receipts in the ledger" — a putaway names its GRN, not the PO), the expanded order detail, an approved adjustment card and an adjusted variance card. The link is a **ledger drill** (§1.6) built by one helper, `ledgerDocHref(doc, id, warehouseId, label?)` (`lib/drill.ts`):

```
/inventory/ledger?list=ledger&warehouseId=<the document's own warehouse>&doc=grn&grnId=<id>&label=GRN-0042
```

- **`doc` and `label` are display-only and never sent.** `doc` names the kind for the banner; `label` is the human handle (the GRN or PO code, the order's channel ref), trimmed and capped at 120 characters (`MAX_DRILL_LABEL_LENGTH`; a longer one parses unsupported). `fetchLedgerDrill` (`lib/drill-fetch.ts`) strips both before the request — an unknown key would be a backend `400` (`forbidNonWhitelisted`), so a display key that reached the wire would break every document link. `DISPLAY_ONLY_DRILL_KEYS` names them; `drill-screens.test.tsx` pins that the outgoing request carries neither (its document-drill `CASES` entry, with `doc` and `label` in `DRILL_ONLY_KEYS`).
- **One key per document, exactly.** `LEDGER_DOC_KEYS` maps `grn → grnId`, `po → poId`, `order → orderId`, `adjustment → adjustmentPendingId`, `variance → countVarianceId`. `parseDrill`'s `documentDrillShapeOk` admits a drill with a `doc` only when **its** key is present and nothing but `warehouseId` and `label` sits beside it (`doc=grn&poId=X` is unsupported); a drill **without** `doc` may carry none of the document-only keys (`doc`, `label`, `grnId`, `poId`, `adjustmentPendingId`, `countVarianceId` — `orderId` is also a dashboard key). A half-document drill would list the wrong rows under the right banner.
- **The document's own warehouse.** Every link carries the document's `warehouseId` — a GRN in WH-B opens WH-B's ledger even when WH-A is active (rule 3 of §1.6). The order link uses the warehouse threaded down from `OrdersTable`.
- **Wording.** `drillBannerWord(drill)` ("Showing ledger events for GRN GRN-0042"; a PO "Showing ledger receipts for PO …"), `describeDrill`'s document arm (the document, then the warehouse label), the page description and `ledgerDrillEmptyMessage` ("No receipt events for PO … yet.") all branch on `ledgerDrillDocument(drill)`; a dashboard drill keeps its words. Without a `label` the document is named by its id tail (§1.10).
- **Link only when the document knows it has events.** An adjustment or variance links only when the row says `ledgerLinked` (the backend recorded the event its decision posted); a rejected adjustment, a recounted variance and anything decided before 9-3a get no link — never a link to an empty or a wrong list. GRNs, POs and orders always link (their events always carry the key).
- **`transferId` is API-only** — there is no transfer web surface (PENDING), so no drill key exists for it.
- **Adding a document:** a `LEDGER_DOC_KEYS` entry and noun (`LEDGER_DOC_NOUN`), the key in `SPECS.ledger.fields` and `DOCUMENT_ONLY_KEYS` (unless the dashboard already sends it), the backend filter, and the round trip in `drill.test.ts`.

### 1.10 Short ids on UUIDv7 — show the tail, not the head (9-3a)

Every id the backend mints is a **UUIDv7**, whose first 48 bits are a millisecond timestamp. The first 8 hex characters therefore change only every ~65 seconds and are near-identical across a day's rows — a short id built from the **head** (`id.slice(0, 8)`) shows the same text for every row on screen (code review FE2). **On a new surface, shorten with the tail:** `shortIdTail(id)` = `id.slice(-8)` (`lib/audit.ts`), the random part. 9-3a's surfaces use it — the audit Who and Target columns and a document drill with no `label`. The older `Warehouse <short id>` (`warehouseDisplayLabel`) and the banner's `SKU …`/`Order …` labels still take the head; changing them is a house-wide change (PENDING), not something to do piecemeal.

### 1.11 Retry must reset the cursor and the table together — the reload epoch (9-3a)

A paged hook (`useAuditTrail`, `lib/use-audit-trail.ts`) holds the requested cursor; `DataTable` holds its own Prev/Next stack. A `ReadFailure` Retry that re-fetched the **same** cursor while the table kept its stack left them disagreeing — Prev offered on what the hook now treated as a fresh read (code review FE3). The pattern:

- the hook's `reload()` clears the result **and** the requested cursor (Retry reads page 1 again) and bumps a revision it returns as **`epoch`**;
- the table is keyed on the filter tuple **and** the epoch — `` key={`${auditFilterKey(applied)}#${trail.epoch}`} `` — so a filter change or a Retry remounts it with an empty stack;
- the requested cursor is stamped with the scope (tenant + filter key, the `useQcHolds` pattern), so a stale cursor under a new filter reads as page 1, and the result is filtered at render on the same stamp (§1.5). The filter key must include **every** filter the request sends (`targetId` was missing — FE4).

### 1.12 The client filter — an explicit argument, an epoch in every stamp (1-5a)

- **A list hook takes the filter as an argument** — `clientFilter: ClientFilter` (`string | null | CLIENT_PENDING`, `lib/active-client.ts`). The screen calls `useActiveClient()` **once** and passes `clientFilterOf(active)` down; a hook never reads storage itself, so a write-side screen can pass `null` and stay unfiltered. `CLIENT_PENDING` (a symbol, so no id can be mistaken for it) means "do not fetch, render loading".
- **The filter joins every scope stamp** — the requested-cursor stamp, the result stamp, the render-time stale check, the effect deps — **and the `<DataTable key>`**. Stamp with `clientFilterKey(…)` **plus `useClientEpoch`** (`lib/use-client-epoch.ts`), a counter that moves on each switch: a bare `clientId` stamp matches again on the way back (All → GlowCo → All would replay the page-2 cursor the table no longer offers).
- **Send it only when set** — `clientQuery(id)` in the `lib/api/client.ts` wrappers; `null` sends no key.
- **Exempt by passing `null`, and say so** — drills (`clientFilterForDrill`: a drill equals its tile, §1.6), write-side screens (wave generate, the pack pipeline and manifest builder, the QC-hold form), lookups and pickers (`useSkuMap`, `useVendorMap`, `useKits`, …) and partners. A filtered page's unfiltered section renders `AllClientsNote`.
- **Create forms default to the active client at render, never in a `useState` initializer** (`picked ?? defaultFormClientId(...)` — an initializer captures nothing while clients load), **pin it on the first draft edit** (the order and ASN forms' `pinClient` — a switch mid-draft must never move the client under drafted lines), and on success for another client say `hiddenByClientFilterNote` ("Created for X — hidden by the client filter").
- **A keyed action whose target derives from the active client binds its key to that target** — the client-invoice Prepare keeps `{key, clientId, month}` and mints afresh when either changes, or a Prepare for B would replay A's key.

---

## 2. Writing a mutation

```ts
async function confirmCancel(orderId: string) {
  setBusyId(orderId);
  setOutcome(null);
  try {
    const { order } = await fetchApiCancelOrder(tenantId, orderId, ulid());
    setOutcome(cancelOutcome(order));      // built from the RESPONSE
    setConfirmId(null);
    notifyOutboundChanged();               // every reader refetches
  } catch (error) {
    setOutcome({ tone: 'rejected', word: 'Not cancelled', reason: cancelReason(error) });
  } finally {
    setBusyId(null);
  }
}
```

**Everything is pessimistic. There is no optimistic mutation anywhere in this repo, and there should not be one** — the backend decides oversell, ATP, terminal transitions and role. A row painted before the answer arrives is a claim this client cannot make.

### 2.1 The Idempotency-Key

AD-5: every mutating request carries a client-minted ULID (`lib/ulid.ts:28` — hand-rolled to the backend's 26-char Crockford base32 format, no dependency). `fetchApi*` wrappers for mutations take it as a required parameter, so forgetting it does not compile.

> **Two id vocabularies — never confuse them.** Entity ids (orders, SKUs, bins, holds, excursions…) are dashed lowercase **UUIDv7** (`wms-be/src/shared/primitives/ids.ts`); ULIDs are the **Idempotency-Key vocabulary only**, never an entity id. 12-7's trace viewer shipped with the two swapped — a spec invented a "order ids are ULIDs" gate, the implementation and its tests enshrined it, and the surface could not load a single real order until three review layers caught it. Before writing any id shape check or id-input affordance, read the BE's id vocabulary first-hand (`ids.ts`, the route's own param validation) and test with a fixture in that shape — not with a fabricated value in the shape you assumed.

**The one exception (9-2):** `fetchApiMarkNotificationsOpened` (`POST …/notifications/opened`) takes no key and is deliberately **not** the keyed-POST helper — the backend documents the route as naturally idempotent (it sets last-opened to now). Do not copy this to any other write.

**The key's lifetime is the *intent*, not the HTTP attempt.** Three shapes, all correct (the per-draft shape comes in two forms since epic 21):

| Shape | Where | Key minted |
|---|---|---|
| **Per click** | `ulid()` inline at the call site — every Settings action, the over-receipt decision, the QC release, the order cancel | at the moment of the click |
| **Per draft** | `OrderCreateForm` (`outbound-orders.tsx:125`, `:178-179`), `WavePolicyForm` / generate (`outbound-waves.tsx:179`, `:351`) | on first submit, **reused across retries of an unchanged draft**, cleared on success and on any draft edit — `editDraft` (lines, including each line's rate), `editDestination`, since 8-1c `editConsigneeGstin` (the buyer GSTIN) and since 8-1d `editConsigneeLegalName` each call `setIdempotencyKey(null)` (`outbound-orders.tsx:136-153`), because every one of them is in the backend's request hash |
| **Per confirmation** | the wave release/cancel row actions (`outbound-waves.tsx:605-616`, `:824`, `:844`); since 21-10 the shared `ConfirmRow` (`components/settings/confirm-row.tsx:53`/`:62`) — mounted keyed by action and target, so a retry reuses the key and the next confirmation (a fresh mount) mints a new one; it never clears the key, it unmounts. Used by the rate-card cancel/discard and the clients card's suspend/reactivate | when the confirmation opens; reused across retries of it; cleared with the confirmation |
| **Per draft, ref form** *(epic-21)* | `keyRef.current ??= ulid()` in a `useRef<string \| null>`: `rate-cards-card.tsx` (`:335`/`:351`, `:427`/`:437`), `clients-card.tsx` (`:282`/`:300`, `:373`/`:390`, `:457`/`:477`), `client-invoices.tsx` (`:199`/`:209`, `:436`/`:444`, `:490`) | on first submit, reused across retries; set to `null` on success and on a draft edit (`clients-card.tsx:315-318`). The same lifetime as the per-draft shape, held in a ref instead of `useState` |

*(Amended 2026-10-10, epic-21 retro F4.)* The two per-draft forms coexist: `useState` + `setIdempotencyKey(null)` (outbound) and `useRef` + `keyRef.current ??= ulid()` (the epic-21 Settings and client-invoice cards). The guide states no preference between them; unifying them is a deferred cleanup (retro A9). Both must clear on every edit to a hashed field. `client-invoices.tsx:318,321` (Refresh and Issue) mint a key **per click** on purpose: an issue answered `stale` is recorded under its key, so re-sending that key would re-serve `stale`.

The per-draft and per-confirmation shapes exist because a create that times out **after the server committed** is only safe to retry if the retry replays. Re-minting would raise a second order. Conversely, sending the same key with a *changed* body is what the backend answers 422 `idempotency-key-reuse` to — hence clearing on every edit.

A per-click key is fine for an idempotent row action whose body cannot change, but it makes a double-click dangerous:

> **A pre-render double-click fires both handlers before `disabled` renders.** Guard with a synchronous ref, not React state — a second command with a fresh key 409s right after the first succeeded. `inbound-cards.tsx:299-306` (a `Set` keyed by hold id) and `:445-447` (a boolean ref).

### 2.2 What to do with the response

- **Build the outcome from the response body, never from the request.** `createOutcome(order, skuLabel)` (`outbound-orders.ts:144`) reads the accepted order's own lines, which is the only place the shortfall exists.
- **A shortfall is an acceptance, not a failure.** Acceptance reserves `min(qty, atp)`, so a 201 can carry `shortfallQty > 0` and backordered lines. Tone stays `accepted`; the word changes to "Accepted with a shortfall" (`outbound-orders.ts:162-166`). Naming is capped at `MAX_NAMED_SHORT_LINES = 5` with "…and N more" — an order carries up to 200 lines.
- **Then `notify*()`**, so every reader refetches from the server rather than being patched locally.
- Extract the sentence into `src/lib/` and test it. The rule is stated at `outbound-orders.ts:112-116`: a claim left in JSX is a claim nothing can pin, and dropping its shortfall clause stays green.

---

## 3. Error handling

**Branch on the problem-details `code`. Never on prose.** Stated at `over-receipt.ts:8-9`, `outbound-orders.ts:200-201`, and enforced by the shape of `ApiProblem` (`api/client.ts:153`), which carries `code`, `status`, `detail` and `title` and nothing derived from them.

Every mapper has the same skeleton:

```ts
export function cancelReason(error: unknown): string {
  if (error instanceof ApiProblem) {
    if (error.status === 409) return verbatim(error);   // optional verbatim arm
    switch (error.code) {
      case 'not-found':     return 'This order no longer exists — refresh the list.';
      case 'role-denied':   return 'Your role cannot cancel orders.';
      …
      default:              return error.detail ?? `Not cancelled (${error.code}).`;
    }
  }
  return UNREACHABLE_REASON;   // the transport arm — NOT an ApiProblem
}
```

Three rules inside it:

1. **The non-`ApiProblem` arm is the transport arm.** A rejected fetch is surfaced as its own Error precisely so this branch fires (`api/client.ts:175-191`). `UNREACHABLE_REASON = 'The API is unreachable — is wms-be running?'` (`outbound-orders.ts:196`) is the house copy; the older mappers inline the same sentence.
2. **`default` falls back to `error.detail`, then to a sentence naming the code.** Never to a bare code, never to silence.
3. **Render the server verbatim when the cause is invisible to this client.** `verbatim(problem)` (`outbound-orders.ts:186`) composes `title — detail`. Use it where no DTO the client holds could explain the refusal: an order cancel 409 (a committed reservation, a drawn pick line — `cancelReason`, `:237`) and the wave refusals `cutoff-passed`, `wave-cap-exceeded`, `conflict` (`outbound-waves.ts:496-620`). A `cutoff-passed` 409 is also the *server's* clock against the policy; the amber chip on the row is an estimate from a different clock and is never the ruling (`outbound-waves.tsx:686-691`).

### Where the mappers live

| Mapper | File | Codes handled beyond the house set |
|---|---|---|
| `readReason(error, subject)` | `lib/outbound-orders.ts:282` | `invalid-cursor` |
| `createReason` | `:202` | `order-source-conflict`, `conflict`, `reservation-store-unavailable` |
| `cancelReason` | `:235` | any 409 verbatim; `reservation-store-unavailable` |
| `detailReason` | `:261` | the expanded-row read |
| `generateReason` / `releaseReason` / `cancelWaveReason` / `policyReason` / `waveDetailReason` | `lib/outbound-waves.ts:496` / `:529` / `:574` / `:603` / `:557` | `no-eligible-orders`, `wave-cap-exceeded`, `cutoff-passed` (verbatim) |
| `decisionReason` | `lib/over-receipt.ts:18` | `over-receipt-decided` |
| `qcReason` | `lib/over-receipt.ts:44` | `qc-hold-open`, `qc-hold-released`, `qc-hold-origin-bin-gone` |
| `asnReason` *(21-6)* | `lib/asns.ts:209` | `duplicate-asn-code`, `sku-client-mismatch`, `mixed-client`, `asn-not-open`, `asn-line-received`, `asn-transition-invalid`, `over-receipt-pending` |
| `poReason(error, kitCodes?)` *(2-1)* | `lib/purchase-orders.ts` | `conflict` → the server's detail as sent (it names the code for a duplicate, says "retry" for a same-key race); `kit-cannot-hold-stock` → "{codes} is a kit — order its component SKUs instead." (the codes from a fresh kit read after the refusal — the kit editor's refetch recovery, never parsed from the detail); `sku-inactive` → `skuInactiveSentence`; `client-departed` → `CLIENT_DEPARTED_REASON`; `mixed-client`, `vendor-not-linked`, `vendor-inactive`, `partner-not-vendor`, `not-found`, `validation-failed` → the server's detail |
| `portalReadReason(error, subject)` / `portalAsnReason` *(21-7, 21-7b)* | `lib/portal.ts:101` / `:298` | `client-suspended`, `invalid-cursor` · `client-suspended`, `duplicate-asn-code`, `kit-cannot-hold-stock` |
| `serviceReportReason` / `portalServiceReason` *(21-8)* | `lib/service-report.ts:107` / `:134` | `report-unavailable` |
| `clientReason(error, action)` / `correctClientReason` / `importReason` / `taxDetailsReason` *(21-2b, 21-5; 21-10 widens `action` to `suspended` / `reactivated`)* | `lib/clients.ts` | `duplicate-client-code`, `client-not-active` (21-10) · `sku-has-history`, `mixed-client` · `import-too-large`, `unsupported-file-type`, `file-unreadable`, `client-required` · — |
| `prepareReason` / `clientInvoiceActionReason` / `clientInvoiceReadReason(error, subject)` *(21-5)* | `lib/client-invoices.ts:355` / `:388` / `:419` | `period-not-ended`, `client-not-billable`, `nothing-to-invoice`, `invoice-exists` · `invoice-has-gaps`, `invoice-not-draft`, `invoice-transition-invalid`, `nothing-to-invoice` · `invalid-cursor` |
| `lineRecordsReason(error, status)` *(21-5b)* | `lib/invoice-records.ts:159` | `invoice-group-changed`, `invalid-cursor` |
| `usageReason` *(21-4)* | `lib/usage.ts:227` | — |
| `auditReason` *(9-3a)* | `lib/audit.ts:246` | `role-denied` → "Only the owner can read the audit trail", `report-unavailable` → "Narrow the filters or dates", `validation-failed` → the server's detail, `invalid-cursor` |
| `rateCardReason(error, action)` *(21-3)* | `lib/rate-cards.ts:276` | `rate-card-effective-date`, `rate-card-effective-overlap`, `rate-card-no-lines`, `rate-card-not-draft`, `rate-card-not-cancellable`, `client-not-active` |
| `rejectionReason` (seven **file-local** copies) | `auth-forms.tsx:257`, `warehouse-create-form.tsx:133`, `zone-bin-setup.tsx:845`, `import-catalog.tsx:266`, `sku-table.tsx:316`, `users-card.tsx:288`, `devices-card.tsx:283` | `duplicate-email`/`invite-pending`/`invite-invalid` · `duplicate-warehouse-code` · `duplicate-zone-code`/`duplicate-bin-code`/`grid-too-large`/`bin-not-empty`/`bin-retired`/`bin-merge-hold-open`/`bin-segregation-conflict` (1-6b)/`bin-full`/`bin-blocked` · `import-too-large`/`unsupported-file-type`/`file-unreadable` · `duplicate-barcode` · `email-exists`/`last-owner` · — |

*(Amended 2026-10-10, epic-21 retro F4: the epic-21 rows were added; codes listed are those beyond the house set. Each re-words the session codes on its own — consolidating them is deferred cleanup, retro A9.)*

**Charge labels — one source (21-11b, retro F2).** Not a refusal mapper, but the same "one copy" rule: a charge's basis text comes only from `basisLabel` (`lib/rate-cards.ts`, the rate-card vocabulary — storage is "per 1,000 units per day"); a priced line renders `basisLabel(line.basis)` from its **own stored basis** (usage `usageRateLabel`, client invoice `lineRateLabel`), never a per-surface table. A charge quantity comes only from `chargeQuantityLabel(code, quantity, uom)` (`lib/usage.ts`, the one `COUNT_NOUNS`); `usageQuantityLabel` and the client-invoice `lineQuantityLabel` delegate to it. The unpriced renderings stay distinct on purpose: usage `'—'` (a preview), invoice `'Unpriced'` (a draft). `components/settings/charge-labels.test.tsx` pins the rendered rate text of a rate-card row, a usage row and an invoice line as identical per charge code. (The unrelated `lineQuantityLabel`s in `outbound-orders.ts` and `invoices.ts` are not charge labels.)

The house set every mapper handles: `not-found`, `role-denied`, `permission-denied`, `idempotency-key-reuse`, `unauthenticated`, `validation-failed`.

**New mappers go in `src/lib/`, not in the component.** The seven `rejectionReason` copies predate the convention and are each untested; the `src/lib/` ones are pinned test by test (`outbound-waves.test.ts:543-620`, `over-receipt.test.ts`).

---

## 4. Capability gating

**Hide the surface, never show a "blocked" screen.** Three levels:

1. **Nav.** A `NavItem` declares `capabilities` and `visibleNavItems(role)` filters it (`lib/navigation.ts:33-61`). A gate belongs here **only when the surface has nothing to read for a role that cannot act** — true of the Conflicts action queue and of nothing else so far (`navigation.ts:22-28`). Inbound, Inventory and Outbound are deliberately ungated: their lists and expanded detail are readable by every role.
2. **Affordance.** The component reads the role and hides the form or the button. `canManageOrders` (`outbound-orders.tsx:63`), `canManageWaves` (`outbound-waves.tsx:95`), `canDecide` (`over-receipt-queue.tsx:74`), `canManage` (`inbound-cards.tsx:294`, `devices-card.tsx:53`), `canCreateZone`/`canCreateBin`/`canBlockBin`/`canRetireBin` (`zone-bin-setup.tsx:118-121`), `canEditSku` (`sku-table.tsx:69`), `canInvite`/`canChangeRole` (`users-card.tsx:71-72`). Some gate the whole card early (`import-catalog.tsx:56`, `warehouse-create-form.tsx:58`).
3. **State.** An action the backend would refuse for a state the row already shows is not offered: `canCancelOrder(status)` is `status === 'accepted'` and nothing else (`outbound-orders.ts:62-64`); `canReleaseWave` (`outbound-waves.ts:114`); every bin action is inert on a system or retired bin (`zone-bin-setup.tsx:735-740`).

**Always read the role through the subscription, never a bare `readSession()` at render:**

```ts
const role = useSyncExternalStore(
  subscribeSession,
  () => readSession()?.user.role,
  () => undefined,
);
```

The reason is written at four call sites (`outbound.tsx:64-65`, `over-receipt-queue.tsx:67-68`, `inbound-cards.tsx:287-288`, `sku-table.tsx:59-63`): the `/me` bootstrap rewrites the role after mount, and an unsubscribed read never re-renders the affordances.

**Four Settings cards do not yet do this.** `zone-bin-setup.tsx:117`, `devices-card.tsx:48`, `users-card.tsx:66` and `warehouse-create-form.tsx:58` subscribe (`import-catalog.tsx` was converted in 21-2b; `clients-card.tsx` was written subscribed) only to session *presence* (`() => readSession() !== null`) and then read `readSession()?.user.role` at render. A role change that the `/me` bootstrap writes back does not change presence, so those affordances do not re-render until something else does. `sku-table.tsx` is the corrected sibling in the same directory — copy that one.

### A per-type affordance: the waivable review rows (1-2b, 1-6d)

Two review-queue types admit **Accept anyway** — Apply with a mandatory note: `grn.shelf-life-refused` (1-2b) and `grn.licence-refused` (1-6d). Their copy is **one table keyed by the two waivable op types** in `lib/review-queue.ts`, never hard-coded per type in `rejected-ops-queue.tsx`: note label, blank-note message, button, outcome word, fallback and ending, heading, failure word. The shelf-life values are the pre-1-6d strings copied out unchanged (pinned by the existing `review-queue.test.ts` / `rejected-ops-queue.test.tsx` cases); the licence ones read `Why accept goods without a valid licence?`, `Lines in licence review`, `Accepted anyway` `— licence waived`. `acceptAnywayNote(entry, text)` takes the entry, so the blank-note words follow its type; the summary helper is `waivedRerunSummary` (renamed from `shelfLifeRerunSummary`, identical output); `rejectedOpSummary` covers the licence type and `GRN_REFUSAL_LABEL['licence-not-covered']` (`no valid licence`) lists each `missing` need and holder, naming the site when the entry carries `siteCode` (`FSSAI licence — site W1`); the need words are a `Record` over the generated need union, so a new need fails the compile.

**The decision list is not the whole gate.** The row's `decisions` say Apply exists, but a licence Apply is owner-only on the server (`licences.manage` on top of `review.decide`), so the affordance is `canApply = canDecide && (opType !== 'grn.licence-refused' || roleHasCapability(role, 'licences.manage'))` (`canApplyRow` in `lib/review-queue.ts`). A non-owner sees Discard and `An owner can accept these`; a 403 on this type shows the server's `detail`. A future type whose Apply needs a further capability joins the same check, not a new branch.

### The known crash — closed by story 21-7

**21-7 took the fix:** `roleHasCapability` is a membership check (an unknown role answers `false`), the mirror carries the fifth role `client: []`, and `readSession` normalises `clientId`/`client`. The record below is the pre-21-7 state.

```ts
export function roleHasCapability(role: UserRole | undefined, capability: Capability): boolean {
  if (role === undefined) return false;
  return ROLE_CAPABILITIES[role].includes(capability);   // users.ts:103
}
```

`undefined` is the only guarded case. **A role string outside the four throws** — verified: `undefined is not an object (evaluating 'ROLE_CAPABILITIES[role].includes')`. `readSession` only validates `typeof user.role === 'string'` (`auth.ts:68`), so a backend that adds a fifth role before this repo regenerates and mirrors, a stale deployed build, or a hand-edited localStorage row crashes `Sidebar` — the first component that renders. `users.test.ts:236` covers `undefined` only.

The fix, when someone takes it, is a membership check rather than an index (`role in ROLE_CAPABILITIES`), plus a `readSession` guard that rejects an unknown role the way it already rejects a missing one.

### The mirror

A new backend capability must be added to `CAPABILITIES` in `src/lib/users.ts`, in the same PR that lands the surface. Do **not** hand-copy it into `ops_manager` — that grant is computed as `CAPABILITIES.filter(c => !OWNER_ONLY_CAPABILITIES.includes(c))` (`users.ts:88`), and the comment above it records that hand-copying is how the mirror fell eight entries behind. `bun run check:capability-mirror` parses the backend's own `permissions.ts` and fails naming exactly what drifted; it runs in CI's `generated-client` job.

---

## 5. Design tokens

**Where they come from.** DESIGN.md (`_bmad-output/planning-artifacts/ux-designs/ux-WMS-Meta-2026-09-08/`) is authoritative. Two mirrors implement it: `src/app/globals.css` (the CSS variables the app actually renders with) and `src/lib/brand-tokens.ts` (the same hues as TS constants, so tests can pin them). `brand-tokens.test.ts` compares them **positionally** — it slices the `:root` block and the `.dark` block out of the CSS and asserts each variable carries the right value inside the right block, so a light/dark swap fails.

**The delta on shadcn defaults is exactly three hues,** each with a dark pair:

| | Light | Dark | Dark foreground |
|---|---|---|---|
| primary | `#1e4e8c` | `#7fa7db` | `#0a1a2a` |
| accent (scan-accepted green) | `#16794c` | `#4cc38a` | `#07210f` |
| warning (amber) | `#b45309` | `#f0a860` | `#1f1002` |

Everything else is inherited zinc. `--ring` is **primary, not zinc-400** — the default fails WCAG 2.2 AA 1.4.11 at ≈2.5:1 on white where blue is ≈8:1 (`globals.css:31-33`).

**What may not be added:**

- **No second brand hue.** `brand-tokens.test.ts:63-76` scans every hex in `globals.css` against an allowlist and asserts the unknown set is empty. Adding a colour fails CI.
- **No gradients.** Same test: `expect(CSS).not.toMatch(/gradient\(/)`.
- **White on a dark fill is forbidden** — each dark hue has its own near-black foreground pair.
- **No colour-only signalling.** `FeedbackBanner` pairs its tone with a glyph, a word and `role="status"`/`role="alert"`.

**What may be added:** a semantic token that aliases an existing hue, and utility classes composed from the variables. Reference tokens as `text-(--muted-foreground)` / `border-(--border)` (Tailwind 4 arbitrary-property syntax) — that is what the whole codebase uses.

**The shape scale** is 4/6/8px, and it is semantic: **4px** inputs and table cells, **6px** buttons, cards and banners, **8px** dialogs (`globals.css:12`). `RADIUS_SCALE` in `brand-tokens.ts:20` and all three CSS variables are pinned.

**Numerals.** Two classes: `.kpi` (28px, 600, `tabular-nums`) and `.data` (`tabular-nums` only). **Every numeric column gets `.data`** — `DataTable` applies it automatically to any column flagged `numeric: true`, on both the `<th>` and the `<td>` (`data-table.tsx:72`, `:94`). Any numeric text outside a table column carries `.data` by hand.

**Banned interactions** (README:37): infinite scroll, hover-only touch affordances, modal stacks deeper than one, celebratory animation, badge-count spam. ⌘K is the palette; Esc closes the topmost layer only.

---

## 6. Quantities after stories 10.1 / 10.2

The backend's contract, as the regenerated client states it in every quantity field's description (e.g. `types.gen.ts:358`, `:894`, `:1531`):

> *A quantity in the SKU's base UoM, at the decimal precision that unit declares (each = 0 places, kg = 3). A value finer than its unit allows is refused, naming the unit and its precision — never silently rounded.*

Storage is milli-units (`QUANTITY_DECIMALS = 3`, backend `src/shared/primitives/quantity.ts:42`), converted at the HTTP edge. Precision is per-UoM, from `uomPrecision(uom)` (backend `src/modules/catalog/uom.ts:360`), over a 35-unit vocabulary in which `each`, `box`, `pallet`… declare 0 places and `kg`, `litre`, `m`, `sqm`… declare more.

### The rules

1. **Never assume a quantity is an integer.** `Number.isInteger` is no longer a safe test anywhere, and neither is `String(qty)` giving a clean cell. The only remaining legitimate integer check in this repo is `cursor.ts:60`, which validates a page *limit* — not a quantity.
2. **Render at the UoM's DECLARED precision, never at storage precision.** `3` in `each` renders `3`, not `3.000`. `2.5` in `kg` renders `2.500`. A ceiling of three decimals is a property of the representation; the unit is what the operator is entitled to see.
3. **Align on the decimal point.** `.data` (`tabular-nums`) fixes digit width but does not align the point across rows with different decimal counts — that needs each cell padded to the column's UoM precision. A column that mixes units has no single alignment and must show the unit per row.
4. **Never round on input.** The backend refuses a too-precise value naming the unit and its precision; the client must let that refusal happen rather than pre-rounding a number the operator typed.
5. **Accept the fractional shape in every quantity input.** `step` must reflect the SKU's precision (`step="0.001"` for a 3-place unit, `step="1"` only for a 0-place one), and any string-shape validator must accept a decimal.

### What is not done yet — read this before "fixing" a quantity

- ~~**`SkuResponse` does not carry `uomPrecision`.**~~ **Closed by story 10-5:** `SkuResponse` now carries `uomPrecision` (derived from the unit, never an input), so the web reads a SKU's declared precision directly and `quantityInputLabel` renders the precision hint on quantity inputs.
- **There is no quantity formatter in this repo.** No `Intl.NumberFormat`, no `toFixed` on any quantity. Every figure on screen is a bare interpolation — `{line.orderedQty} ord · {line.receivedQty} rec · {open} open` (`inbound-cards.tsx:179`), `{row.quantity} on hand` (`:527`), `lineQuantityLabel` (`outbound-orders.ts:125`), `orderTotalsLabel` (`:117`), `waveTotalsLabel` (`outbound-waves.ts:379`), `openQtyLabel` (`over-receipt.ts:13`).
- **The order form refuses fractional quantities outright.** `parseDraftLines` tests `^\d+$` (`outbound-orders.ts:369`) and the input is `step={1}` (`outbound-orders.tsx:208`). For a `kg`-based SKU the form refuses a body the backend would accept. The `^\d+$` shape itself is right for a different reason (`:365-368`): `Number()` accepts `1e3` → 1000 and `0x10` → 16, neither of which a number field can produce and both of which the backend refuses. **Widen the pattern, do not replace it with `Number()`.**
- ~~**Reorder point and reorder quantity** are `type="number"` with no `step`.~~ **Closed by 10-5:** both inputs are `step="any"` (`sku-table.tsx`) — the browser constrains nothing beyond non-negativity, and the backend's precision refusal naming unit and precision is the authority.

When you touch any of these, state which of the two precision-source options you took, and do it in one pass rather than per-surface.

---

## 7. Forms and validation

**What the client validates:** only what would produce a body the backend can only answer 400 to, and only where the client genuinely knows the rule.

- Native HTML validation first: `required`, `min`, `max`, `maxLength`, `type="email"`.
- Then a pure parser in `src/lib/` producing `{body|lines, problem}`: `parseDraftLines` (`outbound-orders.ts:352`) and `parsePolicyDraft` (`outbound-waves.ts:667`). Both return `problem: string` and **send nothing** when set.
- Bounds are mirrored from the backend's decorators with a comment naming which: `MAX_ORDER_LINES = 200`, `MAX_LINE_QUANTITY = 2147483647` ("the backend's `@Max` on a line quantity (int32)"), `MAX_POLICY_NAME_LENGTH = 120` ("the backend's `@Length(1, 120)`"), `MAX_POLICY_ORDERS`, `MAX_POLICY_PRIORITY`.
- Optional fields the viewer left blank are **dropped from the body**, not sent as `''` (`outbound-waves.ts:659-661`).
- **Money and GSTIN inputs have shared helpers (8-1c) — use them, never re-derive.** `src/lib/rupees.ts` (`parseRupees`: rupee text → exact integer paise, no float, at most two decimals; re-exported from `invoices.ts`), `src/lib/gstin.ts` (`GSTIN_RE`, a byte-for-byte mirror of the BE regex, and `parseGstinField`: trim + uppercase, blank → absent, malformed — or, since 8-1d, a prefix outside `GSTIN_STATE_CODES` — → a problem naming the field), `src/lib/gst-states.ts` (8-1d, no imports: `GST_STATE_NAMES`, `GSTIN_STATE_CODES` mirrored from wms-be, `STATE_OPTIONS` for the address `StateSelect`, `gstinStateMismatch` for the warehouse form's non-blocking warning), and `src/lib/tenancy-forms.ts` (`registerTenantBody` / `warehouseBody`: the register and warehouse-create bodies built from the parse, pure so they test without an App Router). GSTIN inputs carry no `pattern` — the parser is the only shape gate.
- One rule is refused client-side purely for the copy: a `00:00` cutoff would refuse release for the whole day, and the backend's 400 has nothing more to say than the client already knows (`outbound-waves.ts:664-666`, `:713-719`).

**What the client must let the server refuse:**

- Anything requiring state the client cannot see — ATP, a committed reservation, a drawn pick line, an open QC hold, a bin's occupancy, a cutoff against the server's clock.
- Uniqueness of any kind (warehouse code, zone code, bin code, barcode, policy name, email).
- Authority. Hiding a form is cosmetic; the 403 is the decision.
- Precision. See §6.4.

Where the client *can* cheaply avoid a guaranteed refusal without claiming authority, it filters the **options** rather than validating the submission: the QC-hold picker omits scopes already under an open hold (a guaranteed 409) and anything sitting in the system QC-HOLD bin (a guaranteed 400), and offers **nothing** until the bin codes load rather than guessing (`inbound-cards.tsx:454-464`).

---

## 8. Testing conventions

`bun test`, 234 tests across 16 files. `bunfig.toml` preloads `happydom.ts`, so a real DOM exists before any test file is evaluated.

**Pure-logic suites** (`src/lib/*.test.ts`) predate the DOM and hand-shim their globals. They must use `stubGlobal` / `restoreGlobals` (`src/lib/test/globals.ts`), never plain assignment or `delete`: `localStorage` is an accessor with no setter under happy-dom (assigning throws "Attempted to assign to readonly property") and `delete` strips the real global out from under every later file in the run. `stubGlobal` defines over a name remembering its original descriptor; `restoreGlobals` puts every one back in `afterEach`.

**Component tests** use `render` from `src/lib/test/render.ts` — `createRoot` + `act`, returning `{container, rerender, unmount}`. Assert with plain `querySelector` / `textContent`. **Call `unmount()` in `afterEach`**, or one test's DOM reaches the next.

```ts
let view: Rendered | undefined;
afterEach(() => { view?.unmount(); view = undefined; });
```

**Drive a surface through a stubbed global `fetch`, not through mocked hooks** (`outbound-waves.test.tsx:25-27`). The generated client is a fetch wrapper, so this exercises the gates, the wiring and the wrappers that actually ship. Write the session with `writeSession()` and a fixed instant, so role gating and clock-dependent copy are both deterministic.

**What a component test should pin** — claims a `src/lib` test cannot make (`outbound-waves.test.tsx:14-23`):

1. That a conditional *chrome* element renders for exactly the right rows (the amber at-risk chip, and nothing else).
2. That an affordance is **absent** for a state or a role — not merely disabled.
3. That a role without the capability still reads everything and is offered no mutating affordance at all.
4. **That pressing a button sends the verb it says.** Asserting labels alone left the `release`/`cancel` ternary in `submit()` free to be inverted with the whole repo green.
5. That a mutation refreshes the list and returns it to page one.
6. That a shared primitive's opt-in slot changes nothing for surfaces that did not opt in (`data-table.test.tsx:36-50` — `renderExpanded` absent, and returning `null`, must produce byte-identical row shapes).

**Prove your test bites.** Mutate the code it covers and watch it fail. Both component suites exist because a mutation review showed the previous coverage did not.

---

## 9. Cross-repo

Backend first, always; meta repo last.

```
wms-be   PR (additive)  →  merge
wms-be:  bun run openapi:export
wms-fe:  bun run api:generate        # openapi-ts.config.ts reads ../../backend/wms-be/openapi/openapi.json
         mirror any new capability in src/lib/users.ts
wms-fe   PR  →  merge
WMS-Meta PR  (docs + docs/repos/wms-fe/README.md contract)
```

- **Never hand-edit `src/lib/api/generated/`.** CI regenerates it and runs `git diff --exit-code` (`ci.yml:61-63`).
- **The `generated-client` job stays red until the backend PR merges** — it checks out WMS-BE's default branch. Expected on every cross-repo story, not a defect. The `web` job (lint/test/typecheck/build) must still be green.
- `api:generate` and `check:capability-mirror` both resolve relative paths **into the meta-repo workspace layout** and cannot run from a bare clone of wms-fe.
- Add a `fetchApi*` wrapper for each new endpoint you consume — the surface never calls `generated/sdk.gen` directly — and a `client.test.ts` case pinning its path, its query-on-first-page behaviour, its body and its `Idempotency-Key`.

---

## 10. Before you say it's done

```bash
bun run lint && bun run test && bun run typecheck && bun run build
bun run api:generate && git diff --exit-code src/lib/api/generated   # no drift
bun run check:capability-mirror                                      # matches wms-be
git status --short                                                   # NO untracked files
```

Then check by hand:

- [ ] Every new read hook returns `ResourceState`, with a `failed` arm and a `reload()` that clears first.
- [ ] Every mutation carries an `Idempotency-Key` whose lifetime is the intent, and a synchronous re-entry guard if it is a per-click key.
- [ ] Every refusal branches on `code`; the transport arm renders the house unreachable copy; nothing parses prose.
- [ ] Any new capability is in `src/lib/users.ts`, and `ops_manager` was **not** hand-edited.
- [ ] Gating reads the role through `useSyncExternalStore`, hides rather than blocks, and never offers an action the row's own state rules out.
- [ ] No new hex in `globals.css`; numeric columns carry `.data`.
- [ ] No quantity assumed integral; no quantity rendered at storage precision; no client-side rounding.
- [ ] Every new sentence of copy or derivation lives in `src/lib/` and is tested.
- [ ] If the surface renders conditional chrome or gated affordances, there is a component test that mutation-fails.
