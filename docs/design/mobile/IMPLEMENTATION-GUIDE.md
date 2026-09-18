# wms-mobile — implementation guide (low-level design)

**Read this before writing mobile code.** It is the set of patterns every story repeats. Most of it exists because a review caught the alternative failing — the commit that introduced each rule is usually the one that fixed the defect.

All paths are relative to `workspace/core/mobile/wms-mobile`. Companions: [`SYSTEM-DESIGN.md`](SYSTEM-DESIGN.md) (how the app fits together), [`../../repos/wms-mobile/README.md`](../../repos/wms-mobile/README.md) (the API contract), [`../IMPLEMENTATION-GUIDE.md`](../IMPLEMENTATION-GUIDE.md) (the backend's).

Bun only. `bun test` and `bun run typecheck` are the whole gate (`.github/workflows/ci.yml`).

---

## 1. Adding a task type end to end

Every task type is the same seven edits, in this order. `putaway.place` (story 3.5) is the cleanest complete example; `pick.record` (4.3 + 4.3b + 4.4) is the richest.

**1. The op type.** Extend the union in `src/offline/types.ts:19` and document the new arm in the block comment above it. The comment is load-bearing in one specific way: **`pick.task` is deliberately never an op type** because `src/state/op-dispatch.test.ts:148` fabricates that string to prove the exhaustiveness guard throws — naming a real op that would turn the proof into a live dispatch.

**2. The API surface.** In `src/api.ts`, add the payload interface, the response interface and one `fetchApi…` function. Copy the shape of `fetchApiPlacePutaway` (`:299`):

```ts
export function fetchApiRecordPick(input: {
  tenantId: string; badgeToken: string; idempotencyKey: string; payload: PickRecordPayload;
}): Promise<PickRecordResponse> {
  return request<PickRecordResponse>(`/tenants/${input.tenantId}/outbound/picks`, {
    method: 'POST',
    body: JSON.stringify(input.payload),
    deviceToken: input.badgeToken,        // the BADGE session, never the bare device credential
    idempotencyKey: input.idempotencyKey, // === the op's ULID
  });
}
```

Mirror the server's response DTO **field for field**. `PickRecordResponse` once dropped seven fields of the idempotent replay receipt; it is the record of what the server actually did (which bin the units left, which batch it re-derived, whether the hold settled) and the client type must not quietly drop half of it (`src/api.ts:377-383`).

**3. The sender dispatch.** Add the method to `OpSenders`, the entry to `defaultOpSenders`, and the branch to `sendOp` (`src/state/op-dispatch.ts`). The `never` assignment at `:91-94` means the build fails until you do. Pass `idempotencyKey: op.id` — always.

**4. The draft model.** A new `src/<domain>/draft.ts`: **pure data + pure synchronous helpers. No React, no network, no store, no `await` anywhere.** This is where every rule lives, and it is the only reason the rules are testable (nothing under `app/` has a test). Shape it like the other three:

- the draft interface and a `create…Draft(warehouseId)`
- resolvers over the snapshot returning a discriminated union, never a throw: `{kind: 'bin', bin} | {kind: 'rejected', reason}`
- `canConfirm(...)` — the gate — and, if the flow is more than two steps, `confirmBlocker(...)` returning the sentence that says *why* it is closed
- `confirmPayload(draft, occurredAt, …)` — the one op body. It may `throw` on a structurally impossible call (`picking/draft.ts:537-542`), because that is a programming error, not an operator one

**5. The screen.** `app/<type>.tsx`, registered in `app/_layout.tsx:29-39`. See §5 for the scan-step pattern.

**6. The inbox.** A tab entry in `TASK_TABS` (`app/inbox.tsx:26`), a `…TaskList` + `…TaskCard` pair, a branch in the tab switch — **and a branch in the `All` arm** (`:96-104`). `All` means every live task type; a tab that renders "No tasks" while tasks exist contradicts its own label.

**7. If the snapshot grew**, add the array's default to `parseCatalogSnapshot` (`src/state/catalog-snapshot.ts:16-21`). See §4.

Then: a `draft.test.ts` pinning every resolver arm, and a cross-type FIFO replay case in `src/offline/engine.test.ts` proving the new op queues, replays behind the other types, and reaches the right sender.

---

## 2. Enqueuing an op correctly

```ts
const op = {
  id: ulid(),                                   // ← minted HERE, at confirm
  type: 'pick.record' as const,
  tenantId: deviceStore.getSnapshot().tenantId ?? '',
  payload: confirmPayload(snapshot, draft, new Date().toISOString(), consumed)
    as unknown as Record<string, unknown>,
  enqueuedAt: new Date().toISOString(),
  source: 'manual' as const,
};
await deviceStore.enqueueOp(op);      // the append COMMITS before anything is sent
await refreshConsumed();              // the stop leaves this device's walk immediately
setBanner({ state: 'queued', detail: `Pick recorded — syncs when connected (id ${op.id})` });
if (!deviceStore.getSnapshot().offline) void deviceStore.replay().catch(() => undefined);
router.back();
```

(`app/pick.tsx:379-418` — the model for all three flows.)

### The ULID

`ulid()` (`src/lib/ulid.ts:15`) is 48 bits of millisecond timestamp + 80 random bits, Crockford base32, 26 chars, lexicographically sortable. It is **minted at capture/confirm time and never re-minted**, because that is the entire exactly-once mechanism: a force-quit between append and send, a doubled tap, a replay that ran twice — all resolve to the same `Idempotency-Key` and the server re-serves the original response. Random bytes come from `randomBytes` (`src/lib/random.ts:9`), which prefers WebCrypto and falls back to `expo-crypto` on Hermes, where `crypto.getRandomValues` is not installed globally.

Never derive a key from the payload, never reuse one across two operator intents.

### What goes in the payload

**Only what the operator observed or chose, plus the identifiers naming the work.** Concretely, for `pick.record` (`src/api.ts:323-364`):

| In | Why |
|---|---|
| `warehouseId`, `picklistId`, `picklistLineId`, `skuId` | Which unit of work |
| `binId` | **The bin the operator SCANNED** — not the task's suggestion |
| `qty` | Units actually drawn |
| `occurredAt` | ISO-8601 Z **device time**. It becomes the server's business time, deliberately distinct from its own `recordedAt` (AD-1) |
| `serials` | One per drawn unit, or `null` on an untracked SKU |
| `reasonCode` | The operator's **intent** on a short pick — and so it *is* part of the server's idempotency hash: two picks of the same line for the same quantity with different reasons are two different commands, and one key must not serve both |
| `binStateEpoch` | An **observation**, not intent: the scanned bin's epoch as the snapshot carried it. Not hashed. Opaque — captured, stored and sent verbatim |

**What must NOT go in: anything the server re-derives.** The batch is the canonical example — a pick sends no batch at all, because the server re-derives it FEFO *inside the bin that was actually scanned*, and a batch chosen against a stale cache would be a wrong answer sent confidently. Same for anything the snapshot merely suggested (`suggestedBinId`, `rationale`), any computed total the server recomputes, and anything already implied by an id.

The **honest exception** is the epoch. It looks like server state, but it is not a decision — it is a timestamped observation of what the device saw, and the server compares it under the bin's row lock to classify the conflict rather than to trust it. If you find yourself adding a second such field, it belongs in that category or it does not belong.

### `null` versus absent

Send `null` explicitly where the server's DTO expects the arm closed (`serials: null` on an untracked SKU, `poLineId: null` on a blind line, `reasonCode: null` on a full pick). Do not omit the key — the payload is sealed and replayed verbatim, and an absent key is a different hash than an explicit null.

---

## 3. The replay contract

`send` returns a `SendResult` (`src/offline/types.ts:133-154`); the mapping from a server refusal to that result lives in **one place**, `src/state/replay-classification.ts:16`, and it is pinned there by 13 tests. It is extracted from the device store precisely because deleting a branch inside the store left every test green while queued ops were silently discarded.

### The AD-14 taxonomy

| Server answer | `SendResult` | Op's fate | Surfaced as |
|---|---|---|---|
| Network failure / timeout (`ApiUnreachableError`) | `unreachable` | **Stays queued**; the walk stops here and resumes later | Nothing. Depth is not an error |
| `401 unauthenticated` | `unreachable` | **Stays queued** | Nothing — re-badge, then replay. A session expiry is *not* a refusal |
| `403 device-revoked` | `revoked` | This op **and the entire tail** quarantine; phase flips to `revoked` | `⚠ Held for review — Device revoked`, per stranded op, each with its own attribution |
| `409 pick-bin-short` (case 3) | `re-plannable` | **KEPT in the durable outbox**, attempt count incremented and persisted. Replay continues past it | `⧗ Needs re-planning — … Attempt N of 3 — it stays queued` |
| `pick-unresolvable` (case 4) | `quarantined` | Dropped from the outbox, held for review. **Strands only itself** | `⚠ Held for review` with the creating session |
| Every other 4xx — including `403 role-denied` | `rejected` | **Dropped** from the durable outbox | `✕ <reason> — <attribution>`. The summary is its only record |
| A non-`ApiProblem` throw | `rejected`, code `unknown` | Dropped | Same, with the thrown message |

**Retryable** is `unreachable` (both arms). **Terminal-but-kept** is `re-plannable`. **Terminal-and-dropped** is `rejected`. **Terminal-and-held** is `quarantined`.

### The rules underneath

- **Branch on `code`, never on prose** (AD-9). `detail` is read only to *say* something useful — which bin moved on, how much it holds now. It never decides anything (`replay-classification.ts:12-15`).
- **`re-plannable` means the server wrote nothing, consumed no idempotency key, and the operator's physical pick is still real.** Deleting it — which is what every refusal used to get — is the exact loss story 4.3b exists to stop. It is bounded at `MAX_REPLAN_ATTEMPTS = 3`, counting only attempts separated by `REPLAN_ATTEMPT_COOLDOWN_MS = 5 min`; exhausting it **quarantines with attribution**, which is giving up, never dropping (`src/offline/engine.ts:38-72`, `:135-188`).
- **Replay continues past every refusal.** Only `revoked` and `unreachable` `break` the loop. One refused stop must never block the rest of the walk.
- **A settled op can still have something to say.** `settledNote` (`replay-classification.ts:56`) turns a non-`none` `conflictClass` or a `short` line status into a summary line, so a moved-on pick does not read identically to an untouched one.

### Adding a new refusal code

1. Decide which of the four fates it has, and write the reason down in the branch comment.
2. Add the branch **above** the catch-all `return { kind: 'rejected', … }` at `:41`.
3. Add a test in `replay-classification.test.ts` — one per branch, no exceptions.
4. If the fate is `re-plannable` or `quarantined`, add the corresponding summary row in `app/inbox.tsx:144-195`, with its **own glyph**: `↻` already belongs to the queue-depth line, and sharing one reads as two separate things.

---

## 4. The catalog snapshot

### Adding a field

The snapshot has grown four times (3.3 → 3.5 → 4.3 → 4.3b) and every growth was **additive**, because a device can be running an older build against a newer server and vice versa.

1. Add the field to the interface in `src/api.ts:464-571`. **Mark it optional only when absence is a real state on a real device** — `CatalogPickTask.binStateEpoch?: number | null` is optional because a snapshot sealed before story 4.3b genuinely has no such key, and `null` separately means "this bin has no epoch row yet" (`:546-557`). Required-and-always-sent fields stay required: `conflictClass` is required on the response precisely so readers cannot treat "moved on" and "untouched" as the same answer.
2. **If it is a new array, default it in `parseCatalogSnapshot`** (`src/state/catalog-snapshot.ts:16-21`). A raw `JSON.parse` cast of an older seal hands the screens `undefined` where they iterate. With the default, a device that upgraded without refreshing shows no tasks of the new type instead of crashing.
3. Add the arm to `device-store.test.ts`'s legacy-seal test, asserting the default **by equality** — an absent key satisfies `toMatchObject`.
4. Record it in the interface contract at `docs/repos/wms-mobile/README.md`.

### The rule

> **Anything the device must be able to refuse in under 500 ms has to be IN the snapshot.**

That is why blocked and system-owned bins ride the payload rather than being filtered out server-side (`CatalogBin.blocked`/`systemOwned`, `src/api.ts:492-501`) — the device has to *reject* a scan against them, which it cannot do for a bin it cannot see. It is why the **whole** pick walk rides along and not just the current stop: a wrong-bin scan names the next walk bin holding the expected SKU with no network call (`src/picking/draft.ts:133-157`). And it is why `uomPrecision` was added to the server's snapshot DTO at all.

If a new rule means the device would otherwise have to guess, or queue-and-find-out, the input to that rule belongs in the snapshot. If the device cannot decide it even with the data (capacity, live stock, the hold), leave it to the server and do not pretend.

---

## 5. Writing a scan step

### The step machine

Each task screen holds a small `Step` union and a single `onScanEvent(event: NormalizedScanEvent)` that branches on it (`app/pick.tsx:64`, `:186-241` — `'walk' | 'bin' | 'item' | 'serials'`). Every branch is the same four lines:

```ts
const resolution = resolveBinBarcode(snapshot, event.value);            // pure, synchronous
if (resolution.kind === 'rejected') {
  setBanner({ state: 'rejected', detail: `${resolution.reason} — the scan is not recorded` });
  return;                                                              // nothing queues. ever.
}
applyBin(resolution.bin);                                              // advance the step
```

**The screen renders what the model returns and decides nothing itself.** Every handler routes through the draft model (`app/pick.tsx:243-246`), which is what keeps the rules testable without the Expo runtime.

Append `— the scan is not recorded` to every rejection detail. It is the sentence that tells an operator in a dead zone that nothing is silently pending.

### Camera and HID are interchangeable — so is manual

All three sources are wired at every step, always:

```tsx
const camera = useCameraCapture(onScanEvent);     // one hook, the same handler
…
<View style={styles.cameraBox}>{camera.cameraElement}</View>
{camera.granted ? null : <TouchableOpacity onPress={camera.request}>Enable camera</TouchableOpacity>}

<TextInput ref={hidRef} value={hidValue} onChangeText={setHidValue}
  onSubmitEditing={(e) => { const scan = hidScan(e.nativeEvent.text); setHidValue(''); onScanEvent(scan); }}
  returnKeyType="done" placeholder="Scan into this field" />

<TextInput value={manualValue} onChangeText={setManualValue} placeholder="Type the bin code" />
<TouchableOpacity onPress={() => { const scan = manualScan(manualValue); setManualValue(''); onScanEvent(scan); }}>
  Enter
</TouchableOpacity>
```

Rules that are not negotiable:

- **Camera permission is never a gate.** Denial leaves HID and manual working (`src/scanning/adapters.tsx:57-60`).
- **Manual entry is a first-class fallback at every scan step**, not a recovery mode — it is a labelled field with its own Enter button on the same screen as the camera, and it produces the identical `NormalizedScanEvent` (`manualScan`, `:19`). Every rejection message names it as the way out: *"type the SKU code instead"*, *"type the bin code instead"*.
- **The HID field's value lives in `useState`, never a ref.** A ref-held value means the post-submit clear never renders and the next wedge scan appends to stale text.
- The camera adapter already dedupes restreams (same value within 1.5 s). Do not add a second dedupe in the screen.

### Focus management

After every step transition and every accepted scan, restore focus to the HID capture field:

```ts
requestAnimationFrame(() => hidRef.current?.focus());
```

(`app/pick.tsx:163`, `:183`, `:224`, `:239`; `app/receive.tsx:159`; `app/scan.tsx:88`.) The field is **never unmounted or blurred by a state change** — focus is restored on interaction instead, so a banner swap mid-walk does not leave a wedge scanner typing into nothing. Use `keyboardShouldPersistTaps="handled"` on the `ScrollView` so tapping a button while the keyboard is up does not eat the tap.

---

## 6. Quantities — and the `uomPrecision` gap

Backend stories 10.1 and 10.2 changed quantities system-wide:

- Quantities are **fractional to 3 decimal places**, stored as scaled integers in milli-units below the HTTP edge.
- **Precision is a property of the unit, not the SKU.** Every count/packaging/container UoM declares 0 decimal places; every measured unit (mass, volume, length, area) declares 3.
- A too-precise quantity is now **refused, not rounded** — a `400 validation-failed` naming the unit and its precision, replacing 10.1's silent edge rounding.
- The catalog snapshot's SKU DTO therefore gained a required **`uomPrecision`**, added for one reason: so the device could refuse a too-precise scan on-device, offline, inside the Rejected banner, **before the op queues**.

**Nothing in this repo consumes it. State that plainly when you touch quantity code.**

`CatalogSku` (`src/api.ts:464-472`) declares `uom: string` and no precision field at all — the app is not even type-aware of it. Every quantity path is integer-only:

| Path | Code |
|---|---|
| Receive, typed quantity | `Number.parseInt(qtyManualEntry, 10)` (`app/receive.tsx:514`) |
| Receive, clamp | `Math.max(0, Math.min(Math.floor(qty), MAX_LINE_QTY))` (`app/receive.tsx:238`) |
| Putaway, clamp | `Math.max(0, Math.min(Math.floor(qty), MAX_PLACEMENT_QTY))` (`src/putaway/draft.ts:138`) |
| Pick, short quantity | `text.replace(/[^0-9]/g, '')` then `Number.parseInt` (`app/pick.tsx:303-307`); the model refuses anything failing `Number.isInteger` (`src/picking/draft.ts:344`) |

The consequence is concrete: **a too-precise scan in a dead zone queues, and is refused on replay — the exact behaviour the field was added to prevent.** `../PENDING.md:74` records it as a live gap, not a deferred nicety.

When the mobile story lands, the work is: carry `uomPrecision` on `CatalogSku`; replace the digits-only filters with a precision-aware parse driven by the drafted line's SKU; refuse an over-precise entry in the **Rejected** banner naming the unit and its precision (mirroring the server's message so the operator sees one story, not two); and keep the existing integer clamps for the units that declare 0 places. Until then, do not describe the device as validating precision.

The int4 clamps (`MAX_LINE_QTY` / `MAX_PLACEMENT_QTY = 2_147_483_647`) stay regardless: they are the client half of a server column bound, and an oversized entry must never retract a queued op at replay (`src/receiving/draft.ts:33-38`).

---

## 7. Accessibility floor for the scan path

This is a floor, not a wish list. UX-DR22, and the scan path is the one an operator uses all shift, in gloves, in a cold aisle.

| Requirement | How it is met | Where |
|---|---|---|
| **48dp minimum touch target** | `minHeight: 48` on every `action`, `input`, tab, serial row, queue chip and stepper | `app/pick.tsx:796-843`, `app/inbox.tsx:466-541`, `app/scan.tsx:157-174` |
| **Glove use on the quantity control** | The receive/putaway steppers are **72 × 56**, not 48 × 48 — a gloved thumb on a `−`/`+` pressed dozens of times per pallet | `app/receive.tsx:700-706`, `app/putaway.tsx:566-572` |
| **Never colour-only** | Every banner state pairs fill + glyph + word | `src/theme.ts:77-100` |
| **Announcements match the visual state** | `AccessibilityInfo.announceForAccessibility` on every banner transition, using the same word and detail that render | `src/components/scan-banner.tsx:50-58` |
| **Dynamic type honoured** | **No `maxFontSizeMultiplier` anywhere** — the banner stays legible at the largest setting | `scan-banner.tsx:101-102` |
| **Reduce Motion** | Banner swaps are plain state swaps with no animation, so they are instant by construction; live-region politeness drops to `none` when it is on | `scan-banner.tsx:41-48`, `:69` |
| **Roles and state** | `accessibilityRole="alert"` on banners, `"tab"` + `accessibilityState={{selected}}` on the switcher, `"radio"` + `{checked}` on the reason list, `accessibilityHint={blocker}` on a disabled confirm | `app/inbox.tsx:76-77`, `app/pick.tsx:602-604`, `:636` |
| **Labels carry the numbers** | `` `Pick ${task.qty} of ${task.skuCode} at ${task.binCode}` ``, `Offline queue holds N items`, `Quantity N` | `app/pick.tsx:730`, `app/inbox.tsx:63` |
| **Inert at bounds, not shouting** | A stepper at 0 or at the ceiling is `disabled` with `accessibilityState`, rather than raising a rejection the operator did not ask for | `app/pick.tsx:559-560`, `:581-582` |

**Microcopy:** verbs and numbers, no exclamation marks. Say what to do next (*"scan it again or type the code"*), name the thing (*"`SKU-9` — this line picks `SKU-4`"*). The queue chip is **amber depth, never red** — a queue is work waiting, not an error.

---

## 8. Testing conventions

- **`bun test` only**, and every test is pure. There is no React renderer, no Detox, no device harness. Tests live beside the module: `src/picking/draft.test.ts`.
- **Never import the Expo entry from a test.** `import … from './sqlite'` pulls the whole React Native runtime into the process. That is why the schema, migration and row mapping live in `outbox-store.ts` (driven by **`bun:sqlite`** in tests) and why `parseCatalogSnapshot`, `op-dispatch` and `replay-classification` are separate dependency-free modules. **This split is the single most load-bearing testing convention in the repo** — each of those three extractions followed a defect the coupling had hidden.
- **Test through the `OfflineStore` boundary.** `InMemoryOutboxStore` (`src/offline/store.ts`) is the reference semantics; `replayOutbox` takes injected `send`, `attribution` and `now` (`engine.ts:81-88`) so time-dependent behaviour is testable without sleeping.
- **A test that says "restart" must actually restart something.** Two engine tests named restart drove the in-memory store, which is exactly how the unwritten `session` column survived a whole story. A persistence claim needs `bun:sqlite` and a second `createOutboxStore` over the same handle (`outbox-store.test.ts:103-141`).
- **Pin every arm of a discriminated union**, not the happy path. `replay-classification.test.ts` has one test per branch; `op-dispatch.test.ts` has one per op type plus the exhaustiveness throw.
- **Assert defaults by equality.** `toMatchObject` is satisfied by an absent key, which defeats the point of a legacy-seal test.
- When a rejection carries operator-facing prose, assert the prose. It is the interface.

---

## 9. Before you say it's done

- [ ] `bun test` green · `bun run typecheck` clean (strict, `noUncheckedIndexedAccess`)
- [ ] `git status --short` shows no untracked files
- [ ] Every new rule lives in a **pure module**, not in a screen, and has a test
- [ ] A new `OpType` has: a sender branch, an `Idempotency-Key` = `op.id`, a payload interface, a response interface mirroring the server's DTO field for field, and a cross-type FIFO replay test
- [ ] The payload carries **nothing the server re-derives** (no batch, no suggestion, no recomputed total)
- [ ] Every new `SendResult` arm has a documented fate, a branch in `classifyReplayFailure`, a test, and a summary row with its own glyph
- [ ] A new snapshot array is defaulted in `parseCatalogSnapshot` and covered by the legacy-seal test
- [ ] A new persisted `QueuedOp` field goes through `rowValuesFor` (so `appendOp` and `replaceOps` cannot drift) and round-trips in `outbox-store.test.ts`
- [ ] **No banner shows `accepted` for anything the server has not settled.** Step prompts and on-device passes use `queued` with a `word` override
- [ ] Every scan step offers camera, HID **and** manual, and every rejection names manual entry as the way out
- [ ] Focus returns to the HID field after every accepted scan and every step transition
- [ ] Touch targets ≥ 48dp (≥ 72 × 56 for a gloved stepper); no `maxFontSizeMultiplier`; announcements match the visual state
- [ ] Microcopy: verbs and numbers, no exclamation marks; rejections end with `— the scan is not recorded`
- [ ] Nothing new can queue that the device could have refused from the snapshot
- [ ] `docs/repos/wms-mobile/README.md`'s interface contract updated with the endpoints, payloads and codes this change consumes — **backend first, meta last**
