# wms-mobile — system design (high level)

> The offline-first scan client warehouse floor operators hold in their hands. Enrollment → badge-in → task inbox → a task flow, over an encrypted SQLite outbox that replays FIFO and exactly once.

All paths below are relative to `workspace/core/mobile/wms-mobile`. Companions: [`IMPLEMENTATION-GUIDE.md`](IMPLEMENTATION-GUIDE.md) (the patterns to code by), [`../SYSTEM-DESIGN.md`](../SYSTEM-DESIGN.md) (the whole system), [`../../repos/wms-mobile/README.md`](../../repos/wms-mobile/README.md) (the API contract this repo consumes).

**Read this before changing the app.** It describes what is built — where something is designed but not implemented, it says so.

---

## What it is

Expo 57 / React Native 0.87 / Expo Router, TypeScript strict (`tsconfig.json:5-6`, including `noUncheckedIndexedAccess`), **Bun only**. Roughly 10k lines across 50 files — small enough that this document can cover essentially all of it.

| | |
|---|---|
| **Who uses it** | Warehouse floor operators. One shared handheld, many operators across a shift, badging in and out |
| **What it does** | Receive against a PO, put stock away into bins, pick released waves — each by scanning, each producing exactly one queued op |
| **What decides** | The **server**. The device mirrors the server's rules to stop mistakes at the operator's hands; it never overrides them (AD-4) |

### The one constraint everything is shaped by

**It must keep working through Wi-Fi dead zones, with zero scan loss.** A racking aisle is a Faraday cage; an operator who walks into one and scans twenty pallets must come out with twenty recorded receipts, not an error screen.

That forces four things, and almost every design decision below is one of them:

1. **Every decision the operator can see is made on-device, synchronously.** No scan path awaits the network. Rejections are pure functions over a cached snapshot (`src/picking/draft.ts:9-13`), which is what makes the <500 ms rejection budget structural rather than aspirational.
2. **Persistence is the only thing that waits.** A decided scan becomes a row in a WAL-mode SQLite outbox, committed *before* any send is attempted (`src/offline/sqlite.ts:26-30`).
3. **Every queued op carries a client-minted ULID** as its `Idempotency-Key`, so replay after a force-quit, a crash, or a doubled tap lands exactly once server-side (`src/lib/ulid.ts:3-9`).
4. **The UI never claims server truth it does not have.** An op sitting in the outbox is amber `↻ Recorded · queued`, never green `✓ Accepted` (`src/theme.ts:77-99`).

---

## Screen map

Expo Router file routes under `app/`. `app/_layout.tsx:16-18` initialises the device store once at mount; `app/index.tsx` is the gate.

**The gate routes purely on the device phase** (`app/index.tsx:30-43`) — there is no login form deciding anything:

```
uninitialized → (spinner, nothing yet)
unenrolled    → /enroll
enrolled      → /badge-in
badged        → /inbox
revoked       → /revoked     (full-screen, terminal)
```

| Route | File | Does |
|---|---|---|
| `/` | `app/index.tsx` | The phase gate. Replaces itself with the phase's route |
| `/enroll` | `app/enroll.tsx` | One-time code + tenant id + device label + a 4–6 digit badge-in PIN (`:17`, `:28-31`). Redeems the code for the device credential and the **sealed offline-store key**. Unknown / expired / already-redeemed codes give one indistinguishable message (`:45-46`) |
| `/badge-in` | `app/badge-in.tsx` | Operator email + PIN → an operator-bound device session. Wrong operator and wrong PIN are indistinguishable (`:44-49`). A `device-revoked` answer jumps straight to `/revoked` (`:37-41`) |
| `/inbox` | `app/inbox.tsx` | The task-type switcher: `All · Receive · Pick · Putaway · Count · Transfer` (`:26`). Three are live; Count and Transfer render the honest "arrives with later epics" empty state (`:112-121`). Also: the amber queue-depth chip, the simulated airplane-mode switch, the **Sync queued scans** button, and the sync summary |
| `/receive` | `app/receive.tsx` | PO pick (or blind receive with a reason) → scan SKU barcodes → batch/mfg-date/quantity per line → confirm. One `grn.submit` op carries the **whole GRN** |
| `/putaway` | `app/putaway.tsx` | Task pick → SKU scan verifies the pallet → quantity → bin scan → mismatch reason if the bin differs from the suggestion → confirm. One `putaway.place` op per placement |
| `/pick` | `app/pick.tsx` | Walk pick → bin scan → item scan → serials (if tracked) → confirm, plus the short-pick arm. One `pick.record` op per line |
| `/scan` | `app/scan.tsx` | The bare substrate scan surface: camera + HID + manual into `decideScan`. Today only self-test payloads are accepted there (see **Scanning**) |
| `/self-test` | `app/self-test.tsx` | The substrate's end-to-end proof: scan → decision → queue → replay → server echo, each step logged (`:38-93`) |
| `/revoked` | `app/revoked.tsx` | Full-screen terminal state. Queued work is held for review; an operator-initiated **Reset** wipes the enrollment and the queued scan data, and the button says so (`:34-37`) |
| `/health` | `app/health.tsx` | The boot API probe, kept as a route |

**The flow shape is the same in all three task screens** and it is deliberate: load the sealed snapshot → pick a task → scan to verify → enter what varies → confirm enqueues exactly ONE op → `router.back()` to the inbox. Confirm also fires an un-awaited `replay()` when not in simulated-offline mode (`app/receive.tsx:263-265`, `app/putaway.tsx:215-217`, `app/pick.tsx:406-408`).

---

## The offline engine — `src/offline/`

The heart of the app. Five files, one boundary type, and an engine that is a pure function over that boundary.

### The persistence boundary

`OfflineStore` (`src/offline/types.ts:159-170`) is eight methods — an append-only FIFO outbox plus a sealed key/value cache:

```ts
appendOp(op) · listOps() /* FIFO, oldest first */ · replaceOps(ops) /* atomic swap */
getSecret(k) · setSecret(k, v) · deleteSecret(k) · purge()
```

Two implementations satisfy it: `InMemoryOutboxStore` (`src/offline/store.ts:8`) — the engine's test double and the **reference semantics every durable store must match** — and the encrypted SQLite store.

### The SQLite store

`src/offline/sqlite.ts` is deliberately tiny: it opens `wms-offline.db`, sets `PRAGMA journal_mode = WAL` (`:28`), runs the migration and hands the handle to `createOutboxStore`. **Everything else lives in `src/offline/outbox-store.ts`, and that split is itself a lesson** — importing the expo entry pulls the whole React Native runtime into a test process, so while the schema lived there it had *no coverage at all*, which is exactly how `session` came to be declared on `QueuedOp` and written by neither `appendOp` nor `replaceOps` (`outbox-store.ts:8-19`).

Two tables (`outbox-store.ts:37-56`):

| Table | Columns | Notes |
|---|---|---|
| `outbox` | `seq INTEGER PK AUTOINCREMENT`, `id TEXT UNIQUE`, `type`, `tenant_id`, `payload_sealed`, `source`, `enqueued_at`, `replan_attempts INTEGER NOT NULL DEFAULT 0`, `replan_attempt_at`, `session_sealed` | `seq` **is** the FIFO order — `listOps` reads `ORDER BY seq ASC` (`:115`). `id` unique + `INSERT OR IGNORE` (`:101`) makes a doubled append a no-op |
| `secrets` | `key TEXT PK`, `value_sealed` | Device token, device, tenant id, badge session, **catalog snapshot**, last warehouse id (`SECRET_KEYS`, `:197-206`) |

**The migration is three guarded `ADD COLUMN`s** (`:69-80`), not a version table: `CREATE TABLE IF NOT EXISTS` is a no-op on an existing outbox, so the columns' absence *is* the version signal. Only a `duplicate column name` error is swallowed (`:84-86`); **anything else rethrows**, because a swallowed failure is indistinguishable from the steady state and the very next `SELECT` — which names both new columns — would throw and take the whole outbox down, turning a recoverable schema fault into total scan loss.

### Encryption — AD-15, field-level envelope

expo-sqlite ships no SQLCipher, so there is no whole-database encryption. Instead **every secret value and every op payload is sealed individually** before it touches disk (`src/offline/crypto.ts`):

- Format `v1:<iv b64>:<tag b64>:<ct b64>`, AES-256-GCM via pure-JS `@noble/ciphers`, **byte-compatible with wms-be's `node:crypto` envelope** — proven by a round-trip test (`src/offline/engine.test.ts:605-634`). noble wants `ciphertext||tag`; the server format keeps them apart, so `openWithKeyBytes` rejoins them (`crypto.ts:47-53`).
- The offline-store key arrives **at enrollment**, itself sealed under the server's `DEVICE_ENCRYPTION_KEY`. Opening it is the KMS boundary: `unwrapOfflineStoreKey(sealed, unwrap)` takes the unwrap function as a **parameter** (`crypto.ts:61-66`) so production swaps in a KMS SDK call; dev builds use `unwrapWithDevMasterKey`, mirroring the server's sha256 stretch (`:69-76`).
- **The unwrapped key lives in the device keychain (`expo-secure-store`), never in the database it decrypts** (`OFFLINE_STORE_KEYCHAIN_KEY`, `outbox-store.ts:212`; written at `device-store.ts:135`). Losing the device loses the key: wipe by design.
- The operator's email rides in `session`, so the attribution blob is sealed like everything else (`outbox-store.ts:239`).

### The op

```ts
type OpType = 'self-test.echo' | 'grn.submit' | 'putaway.place' | 'pick.record'   // types.ts:19
```

`QueuedOp` (`types.ts:21-63`) is capture-time data plus the ULID:

| Field | Why it exists |
|---|---|
| `id` | The client ULID. Sent as `Idempotency-Key`; it is what makes replay exactly-once (AD-5) |
| `type` · `tenantId` · `payload` | The op and its whole command body |
| `enqueuedAt` · `source` | Provenance — `camera \| hid \| manual` |
| `session?` | **The badge-in session that CREATED the op** (UX-DR17). Stamped at enqueue, sealed in the outbox, because replay can run a shift later and reading the *current* session then would attribute a queued scan to whoever is badged in now. Optional so an op sealed by an older build still parses |
| `replanAttempts?` · `replanAttemptAt?` | The bounded-retry state for AD-14 case 3. **On the op, not in memory**, because a counter that reset on every launch would let a permanently-short bin queue forever — the exact thing the bound exists to prevent |

Both optional fields are optional on purpose: absent means "an older build wrote this row", and such a row must still replay rather than crash on read (`outbox-store.ts:129-140`).

### Enqueue

`deviceStore.enqueueOp` (`src/state/device-store.ts:216-230`) stamps the creating session if the caller did not, appends, and refreshes the depth. **The append commits before any send starts** — that single ordering is what makes a force-quit lossless, and it is pinned by test (`engine.test.ts:452`).

### Replay

`replayOutbox(store, send, attribution, now)` (`src/offline/engine.ts:81`) is pure over the `OfflineStore` boundary — the tests drive it with the in-memory store, the app with the encrypted one. It reads the queue once, walks it in order, and writes the survivors back:

| Send result | What happens to the op | What the summary says |
|---|---|---|
| `settled` | Dropped from the outbox | Counted. Plus a line **only if** the response carried a note (`:99-113`) |
| `rejected` (every other 4xx) | **Dropped** from the durable outbox — the summary is its only record (`:114-134`) | `✕` with code, reason and attribution. Retracted **visibly, never silently** |
| `re-plannable` (`pick-bin-short`, AD-14 case 3) | **KEPT**, with an incremented attempt count, persisted (`:135-188`) | `⧗ Needs re-planning — … Attempt N of 3 — it stays queued` |
| `quarantined` (`pick-unresolvable`, AD-14 case 4) | Dropped from the outbox, held for review. **Strands only itself** — replay continues (`:189-203`) | `⚠ Held for review` with the creating session |
| `revoked` | This op **and the whole tail behind it** quarantine; the walk `break`s (`:204-220`) | `⚠ Held for review — Device revoked` per stranded op |
| `unreachable` | Stays queued; `break` (`:221-224`) | Nothing — it is depth, never an error |

**Replay continues past every refusal.** One refused stop must never block the rest of the walk — that is why the loop keeps going on `rejected`/`re-plannable`/`quarantined` and only breaks on `revoked` and `unreachable`.

**The re-plan bound** (`engine.ts:56`, `:72`): `MAX_REPLAN_ATTEMPTS = 3`, but only attempts separated by `REPLAN_ATTEMPT_COOLDOWN_MS = 5 min` count. Three is the number because it separates the two failure shapes — a bin short because another wave got there first is usually replenished within a sync or two; a bin short because the stock is simply gone never clears, and retrying that forever means a doomed request every sync and a queue chip that never reaches zero, which reads as a *broken device* rather than as work waiting. The cooldown exists because `replay()` is a button that *also* fires after every confirm: three taps inside ten seconds would otherwise quarantine a pick that a replenishment two minutes later would have cleared. Attempts inside the window are still reported, they just do not spend the allowance. Exhausting the bound is **giving up, not dropping** — the op quarantines with its creating session, exactly like case 4.

**FIFO is safe by construction now, not by convention** (`engine.ts:29-32`): since story 4.3b each pick validates against live bin state through *its own* captured epoch, independently of what preceded it, so queue order is no longer a proxy for anything.

---

## State — `src/state/`

### The device store

`src/state/device-store.ts` is a single hand-rolled observable (`subscribe`/`getSnapshot`, bound to React with `useSyncExternalStore` at `:387-389`). No Redux, no context. The snapshot (`:40-49`) is `{phase, tenantId, device, session, offline, queueDepth, lastSummary}`.

| Method | Does |
|---|---|
| `initialize()` `:83` | Keychain → SQLite → restore enrollment and any still-valid badge session. **Any storage failure falls back to `unenrolled`** (`:114-117`) — fail-closed |
| `enroll(...)` `:121` | Redeems the code, unwraps the offline-store key through the KMS boundary, writes the keychain entry and the sealed secrets |
| `badgeIn(email, pin)` `:158` | Online mint; on `ApiUnreachableError` it restores a **still-valid cached session for the same operator**, compared case-insensitively because the server lowercases (`:189-193`). First-ever badge-in needs connectivity — there is no cache to restore from |
| `enqueueOp` `:216` / `listQueuedOps` `:240` / `refreshQueueDepth` `:249` | The outbox surface the screens use |
| `refreshCatalogSnapshot(warehouseId)` `:266` / `getCatalogSnapshot()` `:279` | Fetch-and-seal, and the parsed read. A corrupt seal **reads as absent** — refresh recovers (`:285-287`) |
| `replay()` `:305` | The FIFO drain. Returns `null` when offline, unbadged or uninitialised |
| `markRevoked()` `:348` / `reset()` `:353` | The terminal state, and the wipe. **`purge()` runs before the keychain key is dropped** (`:355-357`) — dropping the key first would leave rows nothing could ever open |

Badge-in fires a catalog refresh **fire-and-forget** for the last warehouse used (`:173-180`): a snapshot failure must never fail badge-in.

### Op dispatch

`src/state/op-dispatch.ts` maps op type → API sender, with the senders injected so a test can pin the mapping without the Expo runtime (`:23-56`). Every branch passes `idempotencyKey: op.id` — the ULID **is** the key, for every type. The tail is an exhaustiveness guard assigning `op.type` to `never` (`:91-94`): **a new `OpType` cannot compile until it picks a sender.**

### The catalog snapshot — the offline brain

Fetched online from `GET /tenants/{t}/devices/catalog-snapshot?warehouseId=…` (`src/api.ts:573`), sealed into `secrets`, and read back through `parseCatalogSnapshot`. What it carries, and why each part is there (`src/api.ts:464-571`):

| Field | Carries | Why the device needs it offline |
|---|---|---|
| `skus[]` | id, code, name, **barcode**, uom, `batchTracked`, `serialTracked` — and, 11.7: **`variantValues`** + **`axes`** (nullable) | Barcode → SKU resolution with no network call; the batch-required and serial-required gates — and, 11.7, so the device can **say which variant a scan holds, offline** (UX-DR28). Display only: nothing decides on them; `null` means the SKU is unattached to a product, `absent` means a pre-11-7 seal |
| `openPurchaseOrders[]` | lines with `orderedQty` / `receivedQty` / `openQty` | Which PO line a scan maps to, and the over-receipt (excess) math |
| `bins[]` | id, code, zone, type, capacity, **`blocked`**, **`systemOwned`** | Bin-code resolution — and blocked/system bins ride the payload *deliberately*, so the device can **reject a scan against them pre-queue** rather than queueing an op the server will refuse |
| `putawayTasks[]` | GRN line + placeable qty + `suggestedBin` + `rationale` | The putaway unit of work. The suggestion is advisory; the server re-gates at placement |
| `pickTasks[]` | The whole walk: picklist/line ids, sku, bin, batch, qty, `sliceSeq`, `walkSeq`, `stopCount`, `binStateEpoch?` — and, 11.7: **`kitParentSkuCode`** (nullable) | **The whole walk rides the snapshot on purpose** — that is what lets a wrong-bin scan name *the next walk bin holding the expected SKU* with no network call (`src/picking/draft.ts:133-157`). 11.7 adds the exploded kit component's parent kit SKU code, display-only (`from kit {code}` header line); no pick logic reads kit-ness |
| `binStateEpoch?` on a pick task | The bin's opaque `state_epoch` at snapshot time | AD-14: the observation a queued pick carries back so the server can tell a bin that merely *moved on* from one that is unresolvable. Opaque — captured, stored and sent verbatim; the client never interprets or compares it |

`parseCatalogSnapshot` (`src/state/catalog-snapshot.ts:13`) is the read boundary and exists because the snapshot grows additively: a cache sealed by an older build carries none of the keys a later story added, and a raw cast hands the screens `undefined` where they iterate. It defaults `bins`, `putawayTasks` and `pickTasks` to `[]`, so a device that upgraded without refreshing shows **no tasks of the new type instead of crashing**. It is kept dependency-free so it is testable without Expo.

**Story 11.7 grew the snapshot per-row instead of per-array, and `parseCatalogSnapshot` is deliberately untouched.** `variantValues`/`axes` on a SKU and `kitParentSkuCode` on a pick task are optional keys (the `binStateEpoch` precedent): **absent** means an older build sealed the cache, **`null`** means the server answered and the answer is "no variants / not a kit component" — two different facts a display helper must read differently. The display grammar lives in one pure module, `src/picking/variant.ts`: `variantLabel` (axes in declaration order, `axis: value` joined with the web's ` · `, `—` for a value that is missing — mirroring wms-fe's `variantValuesLabel` so both clients read one product the same way), `describeSku` (`label (code)`, bare code when unlabelled), `verifiedAnnouncement` (the label leads the post-scan announcement — UX-DR28) and `kitContext` (`from kit {code}`, else null). The pick screen renders these verbatim and composes nothing itself; `verifyTaskSku` composes `describeSku` on **both** sides of a wrong-item rejection, so a wrong-variant scan names both variants and a stale cache degrades to today's exact prose. Because `app/` has no test seam, `variant.test.ts` pins every operator-facing string byte-for-byte.

### Replay classification

`src/state/replay-classification.ts` is the AD-14 taxonomy, extracted from the device store for the same reason `op-dispatch` was — this mapping decides whether a queued op is kept, dropped, or held for review, and inside the store it could only be exercised through the Expo runtime. The replay engine's own suite supplies its own senders, so **deleting a branch here used to leave every test green while ops were silently discarded** (`:4-15`).

```
ApiUnreachableError        → unreachable   (stays queued)
code 'device-revoked'      → revoked       (strands the tail)
code 'unauthenticated'     → unreachable   ← 401 session expiry is NOT a refusal: re-badge, then replay
code 'pick-bin-short'      → re-plannable  (AD-14 case 3 — KEPT)
code 'pick-unresolvable'   → quarantined   (AD-14 case 4 — terminal)
anything else (incl. role-denied) → rejected
non-ApiProblem throw       → rejected, code 'unknown'
```

**Clients branch on the machine-readable `code`, never on prose** (AD-9). The problem `detail` is read only to *say* something useful — which bin moved on, how much it holds now — never to decide anything.

`settledNote` (`:56`) is the other half: a settled pick whose `conflictClass` is not `none` says the bin had changed, and a `short` line says where the remainder went (a re-planned stop, or that the order ships short). Without it a moved-on pick would read identically to an untouched one.

---

## Scanning — `src/scanning/`

### Three sources, one event

`NormalizedScanEvent` (`engine.ts:18-25`) is `{id, source, value, format, capturedAt}`, and **camera, HID and manual all produce it** (`adapters.tsx`):

| Adapter | Mechanism |
|---|---|
| `cameraScan` `:35` | `expo-camera` `onBarcodeScanned`; maps iOS/Android symbology names (`org.iso.Code128`, `org.gs1.EAN-13`, `org.iso.QRCode`) onto the engine's three (`:41-55`) |
| `hidScan` `:28` | A keyboard-wedge scanner "types" into a focused `TextInput`; the adapter strips the wedge's trailing Enter/Tab (`:30`) |
| `manualScan` `:19` | Typed entry — a one-tap fallback at every step, never a degraded mode |

`useCameraCapture` (`:61`) holds a **restream dedupe**: the same value inside 1.5 s (the decision budget) is dropped, because a scanner re-reports the same physical barcode across consecutive frames and each frame mints a fresh ULID, so ids could never match (`:68-79`). **Camera permission is never a requirement** — denial just leaves HID and manual active (`:57-60`).

### The decision model, as actually built

There are **two** decision paths, and the distinction matters:

1. **`decideScan(event, tenantId)`** (`engine.ts:74`) — the substrate's pure decision. It validates shape (empty, >128 chars, control characters → `malformed-scan`), accepts a `SELFTEST-<ulid>` payload into a `self-test.echo` op, and **rejects everything else as `unknown-scan`**. Used only by `/scan` and `/self-test`. Its rejection prose still reads "no task types are live yet" (`engine.ts:101-103`) — **that comment and message are stale**: task types exist, they simply do not route through this function.
2. **The per-flow draft models** — `src/receiving/draft.ts`, `src/putaway/draft.ts`, `src/picking/draft.ts` — which is where every real scan is decided. Each is pure data + pure synchronous helpers over the sealed snapshot: **no React, no network, no store, no awaits anywhere.** That is what makes the rejection budget structural: a wrong item or wrong bin is refused before anything can queue, and a rejected scan never enters the outbox at all (`picking/draft.ts:9-13`).

What the device decides on its own, per flow:

| Flow | On-device rejections (never queue) | Deliberately left to the server |
|---|---|---|
| Receive | Unknown barcode, ambiguous barcode, empty scan (`receiving/draft.ts:84-95`); batch code required for a batch-tracked SKU (`app/receive.tsx:224-227`); qty clamped to the server's int4 bound (`MAX_LINE_QTY`, `:38`) | Over-receipt is **not** a rejection — it shows an amber notice and the task continues; the server holds the excess for approval |
| Putaway | Wrong SKU for the task, **serial-tracked SKU** (no serial entry in v1), system bin, blocked bin, unknown bin code (`putaway/draft.ts:108-159`); a bin ≠ the suggestion requires a reason from the fixed enum before the op may queue (`:176-181`) | Capacity, remaining quantity, whether the receiving bin still holds the stock |
| Pick | Wrong item naming **both sides** — each as its variant label when it carries one, else its bare code, 11.7 (`picking/draft.ts` + `variant.ts`); system/blocked bin, a bin holding no line of this picklist — **with the next walk bin that holds the SKU named in the reason** (`picking/draft.ts:199-232`); serial duplicates and overruns; a SKU missing from a stale cache (`serialTracking → 'unknown'`, confirm closed, "refresh") | FEFO batch selection **inside the scanned bin**, live stock, the hold, the re-plan. An off-plan bin that is another stop of the same walk for the same SKU **passes** — the plan's bin is a suggestion |

---

## The four-state scan banner

`ScanBanner` (`src/components/scan-banner.tsx`) over `scanStates` (`src/theme.ts:95-100`):

| State | Fill | Glyph + word | Means |
|---|---|---|---|
| `accepted` | accent (green) | `✓ Accepted` | **The server settled the op.** Nothing else earns green |
| `queued` | warning (amber) | `↻ Recorded · queued` | Recorded on the device, sitting in the outbox |
| `rejected` | destructive (red) | `✕ Rejected` | Refused — and not recorded anywhere |
| `quarantined` | primary (blue) | `⚠ Held for review` | Terminal; a human has to look |

**Never colour-only** (WCAG 1.4.1): every state pairs a fill with a glyph *and* a word, because a colour-blind operator reads the glyph.

**Why "Recorded · queued" must never render green.** Green is a claim about the *server*. An op that has passed every on-device gate has still not been recorded anywhere but this handset — the network may be gone, the bin may have drained, the wave may have been cancelled. A green banner over a queued op tells the operator the work is done and lets them walk away from a scan that is about to be retracted. This was found in the epic-3 retrospective (F-2) and closed in story 4.3: putaway's bin-mismatch banner had been showing green for a purely on-device decision.

**The `word` override** (`scan-banner.tsx:19-27`) is the other half of the same rule. The amber state also carries banners that record *nothing* — a step prompt, an empty-cache notice, the health probe — and the default word would be a lie on those. So `ScanBannerModel.word` overrides it (`app/pick.tsx:426-428` "Next step", `app/health.tsx:38-43` "Checking"). It exists for banners that borrow the state's **colour** but not its **claim**, and never to soften a real outcome.

Accessibility is built into the component, not bolted on: `accessibilityRole="alert"`, an announcement on every transition so the announced state always matches the visual one (`:50-58`), no `maxFontSizeMultiplier` cap so it stays legible at the largest dynamic-type setting (`:101-102`), and — because banner swaps are plain state swaps with no animation — Reduce Motion is honoured by construction, with live-region politeness dropped to `none` when it is on (`:69`).

---

## Session and authority

Three credentials, three lifetimes:

| Credential | Minted at | Scope |
|---|---|---|
| **Device token** | Enrollment, by redeeming a one-time code minted in web Settings | Long-lived (30 days). Only good for badging in |
| **Badge-in session** (`accessToken`) | Badge-in: device token + operator email + PIN | The operator-bound session. **Every task op is sent under this**, never under the bare device credential |
| **Offline-store key** | Delivered sealed at enrollment | Decrypts the local database. Keychain-resident |

`BadgeSession` (`device-store.ts:33-38`) carries the operator, the device and an `expiresAt` derived from `expiresInSeconds` at mint (`:169`). There is **no refresh machinery** — an expired session means badge in again.

**Why every queued op re-authorises against the badge-in session that created it.** These are shared devices. Operator A scans twenty pallets in a dead zone, walks out, badges out; operator B badges in; the queue drains. Three things follow:

1. **Attribution is stamped at enqueue, never read at replay** (`types.ts:30-41`, `device-store.ts:216-230`). Reading the current session at replay time would name B for A's scans. The op's own session is used for every outcome line, with the replaying session only as the fallback for ops sealed before the field existed (`device-store.ts:328-335`).
2. **The server re-authorises on every replayed call** — device status and operator role are re-read from the database per request; the token is transport, never authority. A device revoked mid-queue answers `403 device-revoked`, and the client's response is proportionate: the op **and its whole tail** quarantine, and the phase flips to `revoked` (`engine.ts:204-220`, `device-store.ts:341-343`).
3. **A role denial is not a revocation.** `role-denied` falls through to an ordinary rejection (`replay-classification.ts:41`); only `device-revoked` strands the tail. And a 401 `unauthenticated` is neither — it is treated as unreachable so the ops stay queued for a re-badge (`:25-29`).

Shared devices never launder authority: an op queued under A's session replays as A's work, or not at all.

---

## Local decision vs server decision

| The device decides, offline | Only the server decides |
|---|---|
| Does this barcode resolve to a SKU / bin in my snapshot | Does this SKU / bin exist **now** |
| Is this bin blocked or system-owned | Does it have capacity, does it hold the stock |
| Is this the SKU the task expects | Which batch (FEFO, re-derived **inside the scanned bin**) |
| Is this a legal quantity shape (integer, within the int4 bound, below the stop on a short pick) | Is there stock to draw; is the hold still live |
| Is a reason required (bin mismatch, short pick) and has one been given | Whether the reason is acceptable and what it triggers |
| Have I already queued this pick line | Whether this line is already picked by someone else |

**The device never grants ATP.** AD-14 forbids it and this client grants none — a short pick's release, re-grant and alternate stop are all server-side at replay, which is by definition online (`picking/draft.ts:20-27`).

### When the server later disagrees

Everything visible lands in the **sync summary**, rendered in the inbox (`app/inbox.tsx:144-195`):

```
Sync summary
✓ Settled 4
✓ SKU-9 drawn from A-01-01 — the bin had changed since the task was read
✕ Batch code is required for this SKU — device Handheld-3 · operator jo@… · queued 2026-09-18T…
⧗ Needs re-planning — Bin "A-01-01" … Attempt 1 of 3 — it stays queued — device … · operator …
⚠ Held for review — Device revoked — device … · operator …
↻ 2 still queued — will sync when the network returns
```

- **Retraction is visible, never silent.** A rejected op is dropped from the durable outbox and survives only as that summary line. There is no server-side rejected-op table and no durable client-side retention either — Epic 5's story 5.5 adds the web review queue, and durable retention belongs with it (`engine.ts:114-125`).
- **Quarantine is terminal and attributed.** Case 4 and revocation both land here, with the creating session named.
- **The depth line subtracts the re-plannable rows** (`inbox.tsx:184-192`): they *are* still queued, but they are already named above, and counting them twice makes the summary look like there is more outstanding work than there is.

---

## Testing

`bun test` — **271 tests across 15 files, all pure**; `bun run typecheck` is strict `tsc --noEmit`. CI runs exactly those two (`.github/workflows/ci.yml:21-25`).

| Suite | Tests | Covers |
|---|---|---|
| `src/receiving/draft.test.ts` | 48 | Barcode resolution, scan accumulation and increments, the SKU-switch batch reset, the int4 clamp, the over-receipt math, catch-weight weights (10.6), confirm payloads |
| `src/picking/draft.test.ts` | 42 | The walk, the next-walk-bin hint, the bin gate on/off-plan, item verification (**both rejection sides named as variants, 11.7**), serials, the epoch capture, consumed stops, the stale-snapshot arms, the whole short-pick arm |
| `src/packing/draft.test.ts` | 42 | The pack bench's decisions (10.7): count accumulation, label handling, mismatch prose, the exact-equality confirm gate |
| `src/lib/quantity-input.test.ts` | 27 | The one quantity-input statement's contract (10.6): precision-aware parse, the refusal copy byte-mirroring the server's `precisionRefusalDetail`, clamps, scale/weight entry |
| `src/offline/engine.test.ts` | 25 | FIFO exactly-once replay, unreachable-stays-queued, visible retraction, the four AD-14 arms, the attempt bound and its cooldown across simulated restarts, revocation stranding the tail, force-quit, cross-type FIFO, **plus the envelope-crypto round trip and interop with the server's sha256 stretch** |
| `src/putaway/draft.test.ts` | 19 | Bin resolution, the blocked/system pre-check, the serial refusal, the mismatch-reason gate, the clamp, the payload |
| `src/state/replay-classification.test.ts` | 18 | Every branch of the AD-14 mapping, including 401-is-not-a-refusal and role-denied-is |
| `src/picking/variant.test.ts` | 11 | The 11.7 display grammar **pinned verbatim** — `variantLabel`'s axes order / ` · ` / `—` arms, `describeSku`, `verifiedAnnouncement` (variant-led and today's unattached/legacy arms), `kitContext` |
| `src/scanning/engine.test.ts` | 8 | Capture-agnosticism (all three sources produce the same shape), format detection, the accept/reject arms |
| `src/state/replay-gate.test.ts` | 8 | The replay single-flight gate's concurrency contract (10.6) — the zero-scan-loss fix, pinned pure |
| `src/offline/outbox-store.test.ts` | 7 | The schema, migration and row mapping driven against **`bun:sqlite`** — round-tripping the attempt count and the session through both `appendOp` and `replaceOps`, upgrading a pre-4.3b database, migration idempotence, a non-duplicate-column failure rethrowing, and a corrupt-session-vs-corrupt-payload split |
| `src/state/op-dispatch.test.ts` | 7 | Op type → sender, `Idempotency-Key` = the op's ULID for every type, and the exhaustiveness throw |
| `src/state/device-store.test.ts` | 6 | Only `parseCatalogSnapshot` — a legacy seal per growth story (3.5, 10.6, 10.7, 11.7), the current round-trip, a corrupt seal |
| `src/lib/ulid.test.ts` | 2 | Shape, time-sortability, uniqueness |
| `src/api.test.ts` | 1 | `fetchApiPackOrder`'s wire shape executed against a stubbed `fetch` (10.7 review) — URL, method, idempotency key, badge token |

**What is not covered, plainly:** there are **no component or screen tests at all** — nothing under `app/` is exercised, and there is no Detox/Maestro/e2e layer. Every rule that matters was deliberately pushed *out* of the screens into pure modules for exactly this reason (`op-dispatch.ts`, `replay-classification.ts`, `catalog-snapshot.ts`, the three draft models were each extracted after a defect that the Expo-runtime coupling had hidden), but the screens' own wiring — step transitions, focus management, banner selection — is verified by hand only.

---

## Gotchas and known gaps

These have caused, or can cause, a real defect. Each is verified against the code as it stands.

1. **A concurrent enqueue during a replay is deleted without ever being sent.** `replayOutbox` snapshots the queue once (`engine.ts:89`) and finishes with `store.replaceOps(remaining)` (`:227`), which is `DELETE FROM outbox` then re-insert (`outbox-store.ts:150-158`). `deviceStore.replay()` has **no in-flight guard** (`device-store.ts:305`), and every task screen fires an un-awaited `replay()` right after `enqueueOp` (`app/pick.tsx:406-408`, `app/receive.tsx:263-265`, `app/putaway.tsx:215-217`) while the inbox offers a manual **Sync** button (`app/inbox.tsx:135`). An op appended while a replay is awaiting the network — a confirm during a 10-second request, or two overlapping replays — is inside neither `queue` nor `remaining`, so the write-back erases it. Exactly-once on the server still holds (the ULID key protects that); what is lost is a scan that was never sent. This is the one place the zero-scan-loss property is not structural.

2. **The offline switch is a simulation, and there is no connectivity detection at all.** `snapshot.offline` is set only by the inbox's Switch (`device-store.ts:204`, `app/inbox.tsx:126-130`), and no NetInfo-style listener exists anywhere in the repo. There is no background sync, no retry timer, no drain-on-reconnect: the queue drains only when an operator taps **Sync queued scans** or confirms another task. A handheld left in a dead zone and pocketed stays queued indefinitely.

3. **`uomPrecision` is not in this repo at all.** Backend stories 10.1/10.2 made quantities fractional to 3 decimal places, gave every UoM a declared precision, and added a required `uomPrecision` to `CatalogSnapshotSkuDto` **specifically so the device could refuse a too-precise scan on-device, offline, before the op queues**. `CatalogSku` here declares only `uom: string` (`src/api.ts:464-472`); nothing reads a precision; every quantity path is integer-only (`Number.parseInt` at `app/receive.tsx:514`, `app/putaway.tsx:395`, `app/pick.tsx:306`; `Math.floor` at `putaway/draft.ts:138`; `Number.isInteger` at `picking/draft.ts:344`). So the field ships unconsumed, and a too-precise dead-zone scan queues and is refused on replay — **the exact behaviour it was added to prevent**. `../PENDING.md:74` flags this as a live gap, not a deferred nicety.

4. **`decideScan`'s rejection prose is stale.** `engine.ts:101-103` tells the operator "no task types are live yet". Three task types are live; they simply do not route through that function. Only `/scan` and `/self-test` can surface the message, but it is wrong wherever it appears.

5. **The session blob opens in its own `try`, separate from the payload's.** `listOps` drops a row whose *payload* will not decrypt (a torn write, a rotated key) so one corrupt row cannot freeze the whole queue (`outbox-store.ts:118-144`) — but a corrupt *attribution* blob must not discard a queued pick whose payload is perfectly readable (`openSession`, `:244-253`). Attribution is metadata; the payload **is** the pick.

6. **`appendOp` and `replaceOps` share one `rowValuesFor`** (`outbox-store.ts:226-241`). They drifted once: `session` was declared on `QueuedOp` in story 4.3 and written by neither, so attribution silently fell back to the replaying operator after every restart — green tests throughout, because the two suites naming "restart" drove the *in-memory* store. Any new persisted field goes through that one function.

7. **The attempt bound and its cooldown stamp must both be persisted.** A window a relaunch resets is no window at all (`types.ts:42-62`, `engine.ts:151-187`). The stamp only moves when the attempt actually counted (`:184`), so rapid retries cannot keep pushing it forward and starve the bound.

8. **A queued pick must leave this device's walk immediately.** The sealed snapshot does not change until it is refreshed, so offline the same stop stays pickable and a second op queues for a line already drawn — which the server refuses with a 409 and the client then drops. The screens derive a `consumed` set from the **durable outbox** (`app/pick.tsx:119-130`), so it survives a force-quit and clears itself exactly when the op settles.

9. **`evaluateBin` and `capturedBinEpoch` must ask the same question.** They share one off-plan lookup taking the same `consumed` set (`picking/draft.ts:501-510`), so the bin the gate accepted is exactly the bin whose epoch the op carries. A bin the gate allowed but the epoch lookup missed would silently send no epoch.

10. **The bin epoch is captured at confirm, never at replay.** Capturing it at replay would defeat the point entirely — it would always match (`picking/draft.ts:526-529`). It is opaque: captured, stored and sent verbatim, never interpreted or compared client-side. `null` is a legitimate absence (a bin no movement has touched, or an older snapshot) and the server reads it as a match; **guessing would be worse than sending none**, because a wrong epoch misclassifies a healthy pick.

11. **The stop readout must be derived from the walk actually rendered.** It once mixed a plan-time `walkSeq` over *all* slices with a count of only the unpicked ones, and read "Stop 4 of 2" after three of five stops. It is now an index into the rendered walk (`app/pick.tsx:370-377`).

12. **A SKU missing from a stale snapshot answers `'unknown'`, never `'untracked'`.** Silently answering "untracked" queues a serial-tracked pick with `serials: null` that the server then refuses — a scan lost to a cache that was merely out of date. Confirm is closed and the blocker says to refresh (`picking/draft.ts:417-434`, `:569-571`).

13. **The typed quantity must reach the model on every keystroke.** `onEndEditing` alone meant typing a number and tapping Confirm without leaving the field queued the *previous* one: the operator saw one figure and sent another. A data-integrity bug, not a UI nit (`app/pick.tsx:271-307`).

14. **HID capture values live in `useState`, not a ref.** A ref-held value means the post-submit clear never renders and the next wedge scan appends to stale text (`app/scan.tsx:27-29`, and the same note in all three task screens).

15. **`reset()` purges before dropping the keychain key** (`device-store.ts:355-357`). The other order leaves orphaned rows no later decrypt can ever open.

16. **`listOps` casts the stored `type` straight to `OpType`** (`outbox-store.ts:107-116`) with no validation. A row written by a *newer* build and read by an older one reaches `sendOp`'s exhaustiveness guard and throws — which `replay()` catches into `classifyReplayFailure` as a `rejected` with code `unknown`, dropping the op. Downgrades are not a supported path, but the failure mode is silent scan loss rather than a refusal to open.
