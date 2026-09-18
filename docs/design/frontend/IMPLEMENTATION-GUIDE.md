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

Use `ResourceState<T> & Reloadable` (`use-outbound-orders.ts:30-38`) — `loading | ready | failed`, with `reload()`.

**Do not write a hook that returns `Page | null`.** The eight house hooks do (`use-catalog.ts`, `use-devices.ts`, `use-users.ts`, `use-zone-bins.ts`, `use-warehouse-zones.ts`, `use-tenant-warehouses.ts`, `use-setup-checklist.ts`, `use-inbound.ts`), swallowing failures in a bare `catch {}`. A surface then renders `null` as "Loading…" forever. This was 4.2b's largest review finding (`use-outbound-waves.ts:20-25`). The old hooks are debt; converting one is fair game, copying one is not.

A failed read renders through `ReadFailure` (`components/outbound/shell.tsx:57`) — banner plus Retry. **Progress copy is never used for a failure.**

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

**The key's lifetime is the *intent*, not the HTTP attempt.** Three shapes, all correct:

| Shape | Where | Key minted |
|---|---|---|
| **Per click** | `ulid()` inline at the call site — every Settings action, the over-receipt decision, the QC release, the order cancel | at the moment of the click |
| **Per draft** | `OrderCreateForm` (`outbound-orders.tsx:110`, `:132-133`), `WavePolicyForm` / generate (`outbound-waves.tsx:179`, `:351`) | on first submit, **reused across retries of an unchanged draft**, cleared on success and on any draft edit (`editDraft` → `setIdempotencyKey(null)`, `outbound-orders.tsx:118-121`) |
| **Per confirmation** | the wave release/cancel row actions (`outbound-waves.tsx:605-616`, `:824`, `:844`) | when the confirmation opens; reused across retries of it; cleared with the confirmation |

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
| `rejectionReason` (seven **file-local** copies) | `auth-forms.tsx:257`, `warehouse-create-form.tsx:133`, `zone-bin-setup.tsx:845`, `import-catalog.tsx:266`, `sku-table.tsx:316`, `users-card.tsx:288`, `devices-card.tsx:283` | `duplicate-email`/`invite-pending`/`invite-invalid` · `duplicate-warehouse-code` · `duplicate-zone-code`/`duplicate-bin-code`/`grid-too-large`/`bin-not-empty`/`bin-retired`/`bin-merge-hold-open`/`bin-full`/`bin-blocked` · `import-too-large`/`unsupported-file-type`/`file-unreadable` · `duplicate-barcode` · `email-exists`/`last-owner` · — |

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

**Five Settings cards do not yet do this.** `zone-bin-setup.tsx:117`, `devices-card.tsx:48`, `users-card.tsx:66`, `import-catalog.tsx:56` and `warehouse-create-form.tsx:58` subscribe only to session *presence* (`() => readSession() !== null`) and then read `readSession()?.user.role` at render. A role change that the `/me` bootstrap writes back does not change presence, so those affordances do not re-render until something else does. `sku-table.tsx` is the corrected sibling in the same directory — copy that one.

### The known crash

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

- **`SkuResponse` does not carry `uomPrecision`.** Only `CatalogSnapshotSkuDto` — the mobile device snapshot — has it (`types.gen.ts:1818-1822`). The web reads `uom` and nothing else, so *today there is no way to read a SKU's declared precision from an endpoint this app calls.* Rule 2 cannot be implemented here without either the backend adding the field to `SkuResponse` (preferred — additive, and the pattern already exists) or this repo mirroring `UOM_PRECISION`, which would be a second hand-maintained mirror with all of `src/lib/users.ts`'s drift problem and none of its CI guard.
- **There is no quantity formatter in this repo.** No `Intl.NumberFormat`, no `toFixed` on any quantity. Every figure on screen is a bare interpolation — `{line.orderedQty} ord · {line.receivedQty} rec · {open} open` (`inbound-cards.tsx:179`), `{row.quantity} on hand` (`:527`), `lineQuantityLabel` (`outbound-orders.ts:125`), `orderTotalsLabel` (`:117`), `waveTotalsLabel` (`outbound-waves.ts:379`), `openQtyLabel` (`over-receipt.ts:13`).
- **The order form refuses fractional quantities outright.** `parseDraftLines` tests `^\d+$` (`outbound-orders.ts:369`) and the input is `step={1}` (`outbound-orders.tsx:208`). For a `kg`-based SKU the form refuses a body the backend would accept. The `^\d+$` shape itself is right for a different reason (`:365-368`): `Number()` accepts `1e3` → 1000 and `0x10` → 16, neither of which a number field can produce and both of which the backend refuses. **Widen the pattern, do not replace it with `Number()`.**
- **Reorder point and reorder quantity** are `type="number"` with no `step` (`sku-table.tsx:253`, `:264`), so the browser defaults to step 1 and refuses `0.5` — while `PatchSkuDto` documents both as precision-bearing quantities.

When you touch any of these, state which of the two precision-source options you took, and do it in one pass rather than per-surface.

---

## 7. Forms and validation

**What the client validates:** only what would produce a body the backend can only answer 400 to, and only where the client genuinely knows the rule.

- Native HTML validation first: `required`, `min`, `max`, `maxLength`, `type="email"`.
- Then a pure parser in `src/lib/` producing `{body|lines, problem}`: `parseDraftLines` (`outbound-orders.ts:352`) and `parsePolicyDraft` (`outbound-waves.ts:667`). Both return `problem: string` and **send nothing** when set.
- Bounds are mirrored from the backend's decorators with a comment naming which: `MAX_ORDER_LINES = 200`, `MAX_LINE_QUANTITY = 2147483647` ("the backend's `@Max` on a line quantity (int32)"), `MAX_POLICY_NAME_LENGTH = 120` ("the backend's `@Length(1, 120)`"), `MAX_POLICY_ORDERS`, `MAX_POLICY_PRIORITY`.
- Optional fields the viewer left blank are **dropped from the body**, not sent as `''` (`outbound-waves.ts:659-661`).
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
