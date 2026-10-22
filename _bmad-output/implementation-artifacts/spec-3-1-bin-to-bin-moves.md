---
title: '3-1 bin-to-bin moves — move stock between two bins of one warehouse, from the handheld (queued op) and the web Moves page'
type: 'feature'
created: '2026-10-22'
baseline_commit: 'e1771c7fc88b060ac998c0bf2c113058b9859c1d'  # wms-be; wms-fe: 3a5a14ff1150780d13bb002d05800a63b7e3dd3b; wms-mobile: d8df154903f908f31432e47aaaec4971a5efb3cc
status: 'done'
route: 'dispatch'
review_loop_iteration: 0
context:
  - 'docs/initiatives/production-readiness.md'
  - 'docs/design/SYSTEM-DESIGN.md'
  - 'docs/design/IMPLEMENTATION-GUIDE.md'
  - 'docs/design/API-SURFACE.md'
  - 'docs/design/PENDING.md'
  - 'docs/design/modules/movements.md'
  - 'docs/design/modules/inventory.md'
  - 'docs/design/modules/putaway.md'
  - 'docs/design/modules/tenancy.md'
  - 'docs/design/frontend/SYSTEM-DESIGN.md'
  - 'docs/design/frontend/IMPLEMENTATION-GUIDE.md'
  - 'docs/design/mobile/SYSTEM-DESIGN.md'
  - 'docs/design/mobile/IMPLEMENTATION-GUIDE.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** Stock changes bins only through putaway (from Receiving), a bin merge (the whole bin, retiring it) or a transfer (three steps through IN-TRANSIT). Floor staff cannot simply move 20 units from `A-01-01` to `B-02-03`, and the web Moves page is a placeholder.

**Approach:**
- One keyed command `MoveCommand.moveStock`, in the **movements** module, appends a new **`stock.moved`** ledger event per arm (a batch arm, or one per serial). Each event carries both bins, so the fold debits the origin and credits the target in one transaction.
- The target passes the existing ordered placement gates (`InventoryFacade.assertPlacementGatesInTx`, through the facade, as transfers do).
- One route serves the handheld (a queued `stock.move` op) and the web Moves page (a move form and the recent moves).

**Decisions (recommended, taken autonomously under the user's standing instruction, 2026-10-22; revised by the design review):**
1. **One goal, no split.**
2. **Capability.** A new capability `stock.move`, held by owner, ops_manager and operator. A secure origin or target also needs `secure.move`.
3. **Reason.** A reason is required:
   - `consolidate`, `re-slot`, `make-room`, `found-misplaced`, `client-request` or `other`;
   - a note of up to 200 characters, required with `other`;
   - validated in the command (it lives in the reference doc, not a column);
   - it rides the device snapshot as `moveReasons`.
4. **Bins.**
   - **Both bins:** must exist in this warehouse (404), be non-system (409 `bin-not-movable`) and be different (400).
   - **Origin:** must be non-retired (409 `bin-retired`). A **blocked origin is allowed**, since emptying it is the point.
   - **Target:** passes the gates (retired, blocked, class, client, secure, bulk, segregation, capacity).
5. **Refusals.**
   - Kits are refused (409 `kit-cannot-hold-stock`).
   - Catch-weight SKUs are refused (400; handling units have no location; PENDING).
   - An open reconcile quarantine on **either** (sku, origin) or (sku, target) is refused (409 `move-scope-quarantined`).
   - Open QC holds and open counts are not guards: held units sit in QC-HOLD, and a count's epoch check re-counts.
   - **Allocated stock may be moved.** Reservations have no bin, and a pick against the moved bin re-plans by bin epoch.
6. **Identity.**
   - **Batch-tracked:** the batch code is required, looked up by (tenant, sku, code): unknown is 404 `not-found`; on an untracked SKU it is 400.
   - **Serial-tracked:** serial **codes** are required, distinct, at most 500, and `qty` must equal their count. Each serial's batch, when the SKU is also batch-tracked, is derived from its latest ledger event (the merge precedent), and a `batchCode` beside serials is 400. The ledger refuses a serial elsewhere (409 `serial-elsewhere`) or unknown (404 `serial-unknown`).
   - **Short on-hand** per (sku, bin) or per (sku, bin, batch) is 409 `move-source-short`.
7. **Records.**
   - **No new table and no migration.** `moveId` (uuid v7) sits on the reference doc `{kind:'bin-move', moveId, reasonCode, note?}`, and the history is the ledger.
   - **One audit row** `stock.moved` (target `bin_move`, `targetId = moveId`, actor = the operator; on a review Apply, still the op's operator).
   - **No outbox event.** ATP is unchanged, since both quarantined scopes are refused.
8. **Not billable and not portal-visible** in 3-1. A `both`-shape event meters 0. PENDING records a billable client-requested re-slot.
9. **Handheld refusals.**
   - **Offline**, the device refuses what the snapshot shows:
     - an unknown bin (retired bins are not in the snapshot), a system bin, the same bin;
     - a blocked, other-class or other-client target;
     - kit (snapshot SKUs gain an optional `isKit`) and catch-weight SKUs;
     - a missing batch or missing serials.
   - **On replay:**
     - Gate and short codes are **re-plannable**: retried, then quarantined and reported to review. A chained earlier op may still land.
     - Identity and authority codes are **rejected**: reported to review.
     - A secure bin is server-only (PENDING).
   - **Review decisions** for `stock.move`: `apply` and `discard`. The remedy for a gate refusal is Discard, then a web move or adjustment that matches the floor.

## Boundaries & Constraints

**Always:**
- **Command order** (IMPLEMENTATION-GUIDE §1):
  1. Request shape, above the transaction: the qty/serial count, reason/note, same bin, `occurredAt` (device), and batch beside serials.
  2. Device and operator check (device session).
  3. `stock.move`.
  4. Replay.
  5. Warehouse.
  6. SKU (kit, catch-weight, tracking).
  7. Both bins locked `FOR UPDATE` **in id order**, 404 when absent.
  8. **Replay again under the locks.**
  9. Both-bin checks (system, same), then the origin's retired check.
  10. Quarantine on both scopes.
  11. `assertPlacementGatesInTx(target)`.
  12. `assertSecureBinAuthority(origin)`.
  13. `lockSerialsInTx` (serials).
  14. Batch lookup.
  15. On-hand per arm.
  16. Ledger appends.
  17. Audit.
  18. Idempotency write.
- **Hash:** tenant, `surface: 'device' | 'web'`, device or null, operator, warehouse, sku, `batchCode ?? null`, qty, fromBinId, toBinId, reasonCode, `note ?? null`, sorted serials or null, and `occurredAt` (device only; a web move uses `occurredAt = recordedAt = now`, not hashed).

**Never:**
- No cross-warehouse moves, and no system bins.
- No partial moves.
- No suggested target.
- No device task list.
- No migration.
- No billing or portal change.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|---|---|---|---|
| Plain move | 30 in A, move 20 A→B, `consolidate` | `stock.moved` 20 A→B; A 10, B 20; one audit row | — |
| Batch | L1 has 5 in A; move 5 of L1 | one event, batch arm L1 | unknown L9 → 404; batch on an untracked SKU → 400 |
| Serials | serials S1, S2 in A (batch+serial SKU) | two magnitude-1 events, each with its own batch | count ≠ qty or a duplicate → 400; S3 in C → 409 `serial-elsewhere`; unknown → 404 `serial-unknown` |
| Short | 4 in A; move 5 | — | 409 `move-source-short` |
| Same, system or retired | A = B; origin or target RECEIVING; origin retired | — | 400; 409 `bin-not-movable`; 409 `bin-retired` |
| Target gates | target retired, blocked, wrong class, other client, segregation, over capacity | — | the gate's own code |
| Secure | origin or target secure, operator without `secure.move` | — | 403 `role-denied` |
| Quarantine, kit, catch-weight | either scope quarantined; kit; catch-weight | — | 409 `move-scope-quarantined`; 409 `kit-cannot-hold-stock`; 400 |
| Blocked origin | A blocked | succeeds | — |
| Reason | none; `other` without a note | — | 400 |
| Replay | same key and payload (also racing on the locks); same key with a different payload | the cached result once; 422 `idempotency-key-reuse` | — |
| Accountant | no `stock.move` | — | 403 |

</frozen-after-approval>

## Code Map

### Backend (`workspace/core/backend/wms-be`)

**`src/modules/movements/move.command.ts` (new; `movements.md`: "stock that moves")**
- Follows the order above.
- Arms and serial locking: copied from `putaway.command.ts:858-907`.
- Bin lock order: as in merge, `bin.command.ts:722-764`.
- Serial batch derivation: as in merge, `serialsLocatedInBinInTx` (`bin.command.ts:983`).
- On-hand reads: as in `transfer.command.ts:958-1039`.
- Quarantine: an `InventoryFacade` read of open `inventory_quarantines` for both scopes (add the facade method if absent).
- Gates: `InventoryFacade.assertPlacementGatesInTx` (`inventory.facade.ts:2269`, the `transfer.command.ts:1369` precedent).
- `src/modules/movements/move-reason.ts` holds `MOVE_REASON_CODES`. It is exposed to inbound's snapshot through `MovementsFacade` (or `InventoryFacade`), never by direct import.

**Ledger** (`src/modules/inventory/ledger-registry.ts`)
- A `bin-move` reference kind (`{kind, moveId, reasonCode, note?}`).
- `stock.moved` registered with `sinceVersion: 1`, both identity arms open.

**`src/modules/inventory/inventory.dto.ts`** (`:451-490`)
- `LedgerReferenceDocDto` gains `moveId?`; the `reasonCode`/`note` descriptions name the `bin-move` arm.

**Tests that enumerate types and capabilities**
- `test/metering.spec.ts:629` SHAPES `['both']`.
- `test/bin-admin.spec.ts` and `test/clients.spec.ts` registry lists.
- `test/users.spec.ts` capability list.

**Capability and audit**
- `src/modules/tenancy/permissions.ts`: `stock.move` for owner, ops_manager and operator. It is code-only, with no seed.
- `src/shared/primitives/audit.ts`: `bin_move` in `AUDIT_TARGET_TYPES` (`:44`); `{action:'stock.moved', targetType:'bin_move'}` in `AUDIT_NEW_ACTIONS` (`:139`), pinned by `expectAuditRow`.

**Route** (`src/api/movements.controller.ts`)
- `POST /tenants/:t/warehouses/:w/inventory/moves` behind `AnySessionGuard`.
- A device session follows the inbound-confirm precedent (`:185, :222-228`): a session with no badge is 401, and `X-Op-Operator` is checked for `operator-mismatch`.
- `Idempotency-Key` is required. `MoveStockDto`: `skuId`, `fromBinId`, `toBinId`, `qty`, `batchCode?` (null), `serials?` (null), `reasonCode`, `note?`, and `occurredAt?` (device only; 400 on a web session).
- Returns `201 {moveId, events[]}`.

**Sync report** (`src/modules/tenancy/sync-report.command.ts`)
- The op type `stock.move` goes in the lists at `:84` and `:122`, with decisions `['apply','discard']` (`:169`).
- `PAYLOAD_FIELDS` includes `warehouseId`.
- The apply arm calls `MoveCommand` with the device and operator of the op.

**Snapshot** (`receiving.facade.ts:623` composition)
- Adds `moveReasons`, and SKUs gain an optional `isKit` (from the catalog facade's `isKit`).

### Mobile (`workspace/core/mobile/wms-mobile`)

**`src/moves/draft.ts` (new, pure)**
- Steps `origin → sku → entry → target`.
- Bins: `resolveBinBarcode` reused (`putaway/draft.ts:95`). An unknown bin reads "not in this warehouse (retired or unknown)".
- **Target check:** extract a draft-free `targetBinRefusal(bin, sku, clients)` from `evaluateBin` (`:175-219`). Putaway's pinned copy stays byte-identical; moves get their own copy (system, blocked, class, other client, same bin).
- **SKU scan:** scope `{workSkuIds: [], clientId: origin.dedicatedClientId ?? null}`. On `ambiguous` the operator must type the SKU code (pinned).
- **Pack scans:** add the factor, with `packScanDetail` shown and `packScanRefusal` for serial SKUs.
- **Quantity:** `parseQuantityEntry` plus precision, clamped at `MAX_PLACEMENT_QTY`.
- **Batch:** typed or scanned, trimmed and stored as given (it is hashed: decision 6, the operator's observed identity).
- **Serials:** captured like `picking/draft.ts:447-474` (distinct, capped at 500).
- **Refusals and reason:** kit and catch-weight are refused; reason chips and the note come from `moveReasons`.
- `canConfirm`, `confirmBlocker` and `confirmPayload`: explicit `null`s, and `warehouseId` carried in the queued payload but stripped from the body (the `api.ts:1048` precedent).

**`app/move.tsx` (new)**
- The putaway screen pattern: camera, hardware scanner and manual entry at every step, focus kept, the 72 × 56 stepper, and banners showing `queued`.
- The inbox button "Move stock" is gated only on `moveReasons` being present; the device has no capability mirror (a role without `stock.move` is refused on replay).

**Op wiring**
- `src/offline/types.ts:44` `OpType` gains `stock.move`.
- `src/api.ts`: the payload and response types mirror `{moveId, events}`, plus `postStockMove`.
- `src/state/op-dispatch.ts`: a sender, with the exhaustiveness test.

**`src/state/replay-classification.ts`**
- `move-source-short` gets an explicit **re-plannable** branch, and the gate codes are re-plannable (code set, pinned).
- `serial-elsewhere`, `serial-unknown`, batch `not-found`, `bin-not-movable`, `bin-retired`, `move-scope-quarantined`, `kit-cannot-hold-stock`, `role-denied` and `validation-failed` are **rejected**.
- All wording is move-specific ("Bin A no longer holds enough …", not "for this pick"). The settled note reads "Moved N <SKU> A → B".

**`src/state/catalog-snapshot.ts`**
- `moveReasons` and `isKit` default to null/false, with a legacy-seal equality pin (`device-store.test.ts:439` pattern).

### Web (`workspace/core/frontend/wms-fe`)

**`src/app/(app)/moves/page.tsx`:** `MovesScreen` replaces the placeholder (session check, then `MovesSessioned`, the `inbound-cards.tsx:95-225` pattern; no nav gate).

**`src/components/moves/move-form.tsx` (new)**
- **Origin:** a bin from `useWarehouseBins`, excluding system and retired bins. Its rows come from `fetchApiListStock({binId, nonZero: true, limit: 200})`, with loading, failed and retry states.
- **SKU facts:** from `useSkuMap` plus the kits read (the PO form pattern). Kit and catch-weight are refused before submit, and qty follows `uomPrecision`.
- **Batch:** `useBatchList(warehouseId, skuId, binId)`. The wrapper and the hook gain `binId`; only batches with quantity > 0 in that bin are shown.
- **Serials:** a typed list, deduped and capped at 500.
- **Target:** the same rules as the device (system, retired, blocked, class, client, the origin) plus secure bins for roles without `secure.move`.
- **Submit:** a per-draft key (the `po-create-form.tsx:92-167` pattern), gated by `roleHasCapability(role, 'stock.move')`, with `AllClientsNote`.
- `moveReason` mapper in `src/lib/moves.ts`, with a test per code: every code in the matrix and the gate codes, plus the house set.

**`src/components/moves/recent-moves.tsx` (new)**
- `fetchApiListLedgerEvents({type: ['stock.moved'], clientId})`, following `useActiveClient` (`ClientFilterChip`, client epoch in the key).
- Reuses the ledger table's IST formatter and `useUserMap` (`ledger.tsx:165-199`).
- Rows are grouped by `moveId`, the batch code is resolved, and the reason comes from `referenceDoc.reasonCode`.
- It reloads after a successful move.

**Other**
- `src/lib/drill.ts:65`: `stock.moved` in both lists ('Moved').
- `src/lib/audit.ts:23` `AUDIT_TARGET_LABEL.bin_move = 'Bin move'`.
- `src/lib/users.ts`: the `stock.move` mirror.
- Regenerate the client.

## Tasks & Acceptance

**Execution:**
- [x] BE: registry, DTO, capability, audit, reasons, the command, the route, the sync-report op, the snapshot fields; OpenAPI.
- [x] BE `test/moves.spec.ts`:
  - every matrix row;
  - the same-key lock race (`raceTwice`/`waitParked`);
  - opposite concurrent moves A→B and B→A do not deadlock;
  - a device pick op holding the pre-move epoch re-plans;
  - device replay and review Apply/Discard;
  - a hash golden for each surface;
  - reconcile replays to the projections.
- [x] Mobile: draft, screen, op, sender, classification, snapshot and inbox, plus tests:
  - every resolver branch and the pinned copy;
  - the payload shape with nulls;
  - the putaway copy unchanged after the extraction;
  - legacy seal;
  - FIFO across op types, including a re-plannable putaway followed by a move from the same bin.
- [x] Web: page, form, list, mapper, labels, mirror, batch `binId`, plus tests; regenerated client.
- [x] Meta docs:
  - `API-SURFACE.md`;
  - `modules/movements.md` (the move command), `inventory.md` (`stock.moved`, the reference doc), `putaway.md` (relationship);
  - frontend SYSTEM-DESIGN `:49`/`:60` (route table, placeholder count);
  - mobile SYSTEM-DESIGN (the flow);
  - the three READMEs;
  - PENDING: catch-weight moves; secure bins offline; billable client re-slot; portal visibility; a pallet move with 3.6; suggested targets.

**Acceptance Criteria:**
- Given 30 units in A, when an operator moves 20 to B on the handheld offline and later syncs, then the stock list shows A 10 and B 20, and the Moves page lists the move with its reason.
- Given a device pick op holding A's pre-move epoch, when it replays after the move, then it answers 409 `pick-bin-short` and re-plans.

## Design Notes

- **Why movements owns the command.** Transfers, counts and adjustments live there; inventory owns the ledger and the gate runner, which movements reaches through `InventoryFacade` as transfers already do.
- **Why system and retired are checked before the gate.** The gate answers a system target 400 (`inventory.facade.ts:2329`). The command checks both bins first, so the codes are uniform, and the device's classification table is exact.
- **The batch code is in the payload.** It is the operator's observed identity, not something the server re-derives (there is no FEFO default), so it is hashed as sent. Serial moves derive their batch per serial, so a batch-plus-serial SKU never asks for a batch.

## Verification

**Commands:**
- `bun run test -- test/moves.spec.ts test/metering.spec.ts test/architecture.spec.ts test/putaway.spec.ts test/users.spec.ts test/bin-admin.spec.ts test/clients.spec.ts test/review-reports.spec.ts` (wms-be, run alone): pass.
- `bun run lint && bun run typecheck` (wms-be, wms-fe); `bun test` + typecheck (wms-mobile, wms-fe); `bun run check:capability-mirror` (wms-fe): pass.

## Implementation Notes

Implemented 2026-10-22 against the frozen sections above. Where the code departs from a literal reading of the Code Map, the reason is recorded here.

- **Backend.** `MoveCommand.moveStock` follows the 18-step order exactly; the same-key race test fails with `409 conflict` when the second replay is deleted (mutation-checked). `InventoryFacade.assertPlacementGatesInTx` gained an optional `subject: 'transfer' | 'move'` that changes only the refusal WORDING (the transfer's details stay byte-identical by default); the codes and statuses are shared. New facade read `openQuarantinedBinsInTx`. `CatalogFacade.getSkuSummariesInTx` reads the tenant's kit set by tenant (never an id list) for `isKit`. `stock.move` also joins `SKU_NAMING_OP_TYPES` (`client-wind-down.ts`): its payload names a `skuId`, so an open move row blocks a client's departure like a putaway row does. Two enumeration pins grew (named, not retargeted): `test/portal.spec.ts` (4 `AnySessionGuard` routes) and `test/return-receipts.spec.ts` (`stock.move` → apply + discard).
- **Mobile.** `isKit` and `moveReasons` are OPTIONAL on the TS types (`CatalogSku`, `CatalogSnapshot`) to spare every hand-built fixture; `parseCatalogSnapshot` always sets them (false / null) and the legacy-seal tests pin both by equality. `bin-retired` is excluded from the move's re-plannable set (the decision 9 / M1 rejected list names it; a retired bin never re-opens), while every other target gate code is re-plannable. The engine's own "Attempt N of 3 — it stays queued." suffix follows the move's "The move did not land — {detail}" words. `settledNote` gained an optional `binCodeOf` lookup (device-store passes `binCodeLookup(catalog)`). The SyncReportRowPayload op-type union gained `stock.move`.
- **Web.** The form reads SKU facts through `useSkuCatalog` — the `ResourceState` twin of `useSkuMap` (`use-inventory.ts`) — rather than `useSkuMap`, whose failure reads as loading forever (guide §1.1); the kits read is `useKits` as in the PO form. The recent moves resolve batch codes with one batch read per SKU on the page (`useBatchCodes`). The review queue gained a `stock.move` summary and guidance (`lib/review-queue.ts`), and the ledger reference label shows `move …` for the `bin-move` arm.
- **Verification run.** wms-be: the full jest suite (110 suites, 2795 tests) — a first run failed only the two enumeration pins above; after updating them, a second full run passed 2794/2795, the one failure `test/sessions.spec.ts` (a badge-in rate-limit case untouched by 3-1, green in the first full run) passing alone (38/38) — a load flake; lint, typecheck, build clean; OpenAPI exported. wms-mobile: `bun test` 818 pass, typecheck clean. wms-fe: lint, typecheck, `bun run test` 2305 pass, build, `check:capability-mirror` (47 capabilities) clean.

## Spec Change Log

## Review Triage Log

Design review, 2026-10-22 (backend B, mobile M, web W). Every accepted finding is folded into the spec above; all choices are recommended, taken autonomously.

| ID | Verdict | Finding → resolution |
|---|---|---|
| B1 + M3 | high | No device route; `TenantSessionGuard` cannot take a badge token. One route behind `AnySessionGuard` (the inbound-confirm precedent). |
| B2 | high | The gate answers system 400 and secure 403, not 409. Both-bin checks in the command first; exact code table; device classification by exact code. |
| B3 | high | No replay under the locks. Step 8 added; race test. |
| B4 + M9 + W5 | high | Serial arms and codes undefined. Serial codes; the ledger's `serial-elsewhere`/`serial-unknown`; `lockSerialsInTx` placed; cap 500. |
| B5 | high | Batch+serial SKUs uncovered. Batch derived per serial (merge precedent); `batchCode` beside serials is 400. |
| M1 + M2 | high | "Kept for review" is not a real outcome, and dropping `move-source-short` loses chained moves. Gates and short re-plannable; identity and authority rejected. |
| M4 | high | `occurredAt` hashed but not in the DTO; `warehouseId` missing from the payload; null rules. Fixed; web `occurredAt` = now, unhashed. |
| W1 | high | The origin source (`useStockScopes`) truncates and lacks the system flag. Bin first, then a bounded stock-by-bin read. |
| W2 | high | Batches cannot be filtered per bin on the web. `binId` added to the wrapper and hook. |
| W3 | high | The stock row lacks SKU facts. SKU map and kits read; precision. |
| B6 | medium | A quarantined target lowers ATP. Both scopes refused. |
| B7 | medium | "CHECK" contradicted "no migration". Command validation; no migration; `users.spec`. |
| B8 + W6 | medium | Audit paths wrong, `AUDIT_NEW_ACTIONS` missing. Fixed; web label. |
| B9 | medium | Batch-by-code lookup unspecified. Lookup and codes stated. |
| B10 + M11 | medium | No review remedy; wording. `['apply','discard']`; remedy stated; move-specific copy. |
| B11 | medium | Allocated stock was implicit; the AC overstated. Decision 5; AC qualified to a device pick holding the epoch. |
| B12 + W10 | low | `moveId` missing from the reference DTO; batch id vs code; N serial events. DTO extended; grouped list. |
| B13 | low | Shape checks belong above the transaction. Step 1. |
| B14 + M5 | medium | Retired bins are absent from the snapshot; no kit flag; snapshot ownership. Unknown-bin copy; `isKit`; reasons via a facade; secure is server-only (PENDING). |
| B15 | low | `occurredAt` rules. Stated. |
| M6 | medium | `evaluateBin` is putaway-bound. A draft-free `targetBinRefusal` extracted; putaway copy pinned. |
| M7 | medium | SKU scan scope in a multi-client warehouse. Origin's client scope; ambiguous → typed code. |
| M8 | medium | Quantity, pack and serial capture rules. Stated. |
| M10 | medium | The batch in the payload breaks the "re-derived" rule. Design Note. |
| M12 | low | Recipe and checklist items. Listed in Tasks. |
| W4 | medium | The web target filter was weaker than the device's. Same rules plus secure. |
| W7 | medium | Ownership not argued against movements. The command moves to movements. |
| W8 | medium | The list's client filter was undecided. The list follows the switcher; the form shows `AllClientsNote`. |
| W9 | medium | The list would duplicate the ledger and risk local time. Reuse the IST formatter and user map. |
| W11 | medium | Billing and portal decided only implicitly. Decision 8; PENDING. |
| W12 | low | Reason vocabulary and docs. `client-request` added; mirror check; doc lines named. |

Code review, 2026-10-22 (Blind Hunter BH, Edge Case Hunter EC, Verification Gap VG). Routes were taken autonomously (recommended).

| ID | Verdict | Finding → resolution |
|---|---|---|
| BH2 + EC1 + EC13 + EC14 | medium | Patch: a concurrent debit after the on-hand read makes the ledger answer 422 `insufficient-on-hand`, which is undocumented and rejected on the device. The command maps it to 409 `move-source-short`; the device also lists `insufficient-on-hand` as re-plannable. |
| BH1 + EC2 | medium | Patch: 409 `conflict` (same key in flight) was rejected on the device. Kept queued (retry). |
| BH3 | low | Patch: `MOVE_REJECTED_CODES` was unused. Wired as the explicit rejected set, pinned per code. |
| BH5 | medium | Patch: `note`/`batchCode`/serials were hashed untrimmed and looked up untrimmed. Trimmed before both. |
| BH6 | low | Patch: the `note` DTO validated 1000 but documented 200. Aligned to 200. |
| BH7 | medium | Patch: the web silently dropped duplicate serials, changing qty. Duplicates reported, no silent dedupe. |
| BH8 | low | Patch: secure origins were offered to roles without `secure.move`. Filtered like targets. |
| BH10 | low | Patch: a new origin on the handheld kept the old reason and note. Reset. |
| BH11 | low | Patch: an orphaned doc comment. Restored. |
| BH12 (part) | medium | Patch: missing tests for a secure target, a serial-only SKU, a malformed device `occurredAt`, and ATP/reservations unchanged by a move. Added. (Capacity, weight, volume and size gates are pinned by the gate runner's own suites.) |
| EC3 + EC4 | medium | Patch: float drift in the stepper and pack-scan sums produces an over-precise qty, rejected at replay. Rounded to precision. |
| EC5 + EC6 | low | Patch: batch or serial codes over 100 characters, or a SKU barcode scanned as a serial, were not refused offline. Refused offline. |
| EC7 | low | Patch: an all-malformed `moveReasons` array offered a dead flow. Parsed as null. |
| EC8 | low | Patch: a missing tenant id at confirm. Refused with "Badge in again". |
| EC9 | low | Patch: non-array `payload.serials` on Apply was silently dropped. 400. |
| EC11 | medium | Patch: a serial move split across ledger pages showed as several rows. The list fetches until the `moveId` changes. |
| EC12 | medium | Patch: submit while the kits read is loading or failed let a kit through unseen. Submit is blocked, and the read failure is shown. |
| VG1 | medium | Patch: the bare device credential 401 is untested. Test added. |
| VG2 | medium | Patch: "an edit mints a new key" is untested. Test added. |
| VG3 | medium | Patch: Apply keeping the handheld's `occurredAt` is untested. Assertion added. |
| BH4 | medium | Deferred: moving allocated stock leaves a pick to re-plan with no warning (decision 5 allows it). A web warning and a supervisor signal go to PENDING. |
| BH14 | maybe-false | Deferred: recent moves may show raw ids for batches with no stock if the batch list omits them. Settle by checking the route's zero-quantity rows. |
| BH9 | low, rejected | A SKU the origin never held retries until the budget runs out. Bounded retries, then review; decision 9. |
| BH13 | low, rejected | The tests share fixtures in order. The repo's suite convention is `beforeAll` fixtures; no false failure was shown. |
| EC10 | low, rejected | A future `occurredAt` from device clock skew. Pre-existing class (PENDING "occurredAt drift needs a bound decision"). |
