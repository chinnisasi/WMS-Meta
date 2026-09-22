---
story: fix-a2-be-kit-create-write-skew
title: "Fix A2: kit-create write-skew — lock the SKU row in the adjustment and over-receipt-approval paths"
status: ready-for-dev
epic: null
retro: epic-11-retro-2026-09-22 (F2, action item epic-11-retro-a2-fix-be-kit-write-skew)
context:
  - '_bmad-output/implementation-artifacts/epic-11-retro-2026-09-22.md'
  - 'docs/design/SYSTEM-DESIGN.md'
  - 'docs/design/IMPLEMENTATION-GUIDE.md'
  - 'docs/design/modules/catalog.md'
  - 'docs/design/modules/inbound.md'
  - 'docs/design/modules/inventory.md'
---

# Fix A2 — kit-create write-skew (backend)

## Intent

Close the stranded-stock write-skew the epic-11 retro found (F2): `assertKitSkuHoldsNoStock` serializes concurrent +stock writers on the **locked SKU row**, but only the GRN path actually takes that lock. The stock-adjustment path and the over-receipt-approval path do not, so a concurrent kit create and a concurrent stock append can both commit — leaving a kit SKU with on-hand stock that no command can ever remove (all three +stock writers refuse kits; orders explode past it; the ATP and bin occupancy inflate forever).

## Verified defect (not assumed — checked against the code)

- `src/modules/inventory/inventory.command.ts:592` — the adjustment's `assertSkuInTenant` is a **plain select** (no `.for('update')`); the kit guard (`:389-395`) then reads kit-ness via `getKitSkuIdsInTx`.
- `src/modules/inbound/receiving.command.ts:895-907` — over-receipt approval locks only the `over_receipts` row (`.for('update')` at `:882`); its kit probe (`:927-938`) reads kit-ness, then the SKU **code** without a lock (`:930-934`).
- `src/modules/inbound/receiving.command.ts:1107-1120` — GRN's `loadSkus` locks the rows: tenant-scoped, `.orderBy(skus.id)`, `.for('update')` — the pattern this fix extends.
- `src/modules/catalog/kit.command.ts:509-548` — kit create locks the SKU row, then `assertKitSkuHoldsNoStock` reads `stockOnHand` + live reservations under it; the doc comment at `:515-517` assumes *"a GRN that commits stock concurrently serializes on the same `.for('update')` sku row"* — the premise holds only for the GRN.

Failing scenario (both sides verified): T_kit locks the SKU row, sees stock = 0 and no live reservations; concurrently T_adj (or the over-receipt approval) reads the SKU unlocked, reads kit-ness as not-a-kit, appends its ledger event, commits. Neither blocks the other (the kit path takes no per-warehouse advisory lock; the adjustment never touches the `skus` row). Both commit → a kit SKU with stock, permanently stranded.

## Code Map

| File | Change |
| --- | --- |
| `wms-be/src/modules/inventory/inventory.command.ts` | `assertSkuInTenant` gains `.for('update')` (single-row lock, same read it already performs — the guard order is untouched; the kit probe already runs after this read) |
| `wms-be/src/modules/inbound/receiving.command.ts` | Over-receipt approval: before the kit probe, lock the SKU row tenant-scoped (`.orderBy(skus.id).for('update')`, the `loadSkus` shape); reuse the locked row for the refusal's `code` instead of the unlocked follow-up read |
| `wms-be/src/modules/catalog/kit.command.ts` | `assertKitSkuHoldsNoStock`'s doc comment: the serialization premise now names **all three** +stock writers (GRN, stock adjustment, over-receipt approval) |
| `wms-be/test/kits.spec.ts` | Concurrency regression tests (below), including the `SKU_CODES` fixture additions they need: a kit-SKU + component pair for AC1's race, and the full over-receipt recipe (PO → GRN with excess → stock emptied via adjustment → race) for AC2, per the existing pattern at `test/kits.spec.ts:916-970` |

## Tasks & Acceptance

- [ ] `assertSkuInTenant` (adjustment) takes `.for('update')` — the read it already does, now locking; no other command change.
- [ ] Over-receipt approval locks the SKU row **before** the kit-ness probe; the `kitCannotHoldStock` refusal uses the locked row's code.
- [ ] Kit-create doc comment updated to name all three writers.
- [ ] **AC1 — the skew is closed:** a kit create racing a stock adjustment serializes — the test drives two transactions against the same SKU where one is a kit create and one an adjustment, and asserts the safe outcomes (the adjustment commits and the kit create answers 409 `kit-sku-holds-stock`; or the adjustment answers 409 `kit-cannot-hold-stock`), **never both committed**. Mirrors the mutual-composition race test's structure (`test/kits.spec.ts:806`).
- [ ] **AC2 — same for over-receipt approval:** kit create racing an approval on the same SKU never both commit.
- [ ] **AC3 — no behavior change for existing arms:** the full existing suites stay green (adjustment refusals, over-receipt approve/reject, GRN guards) — the lock is not observable in any sequential test.
- [ ] **AC4 — no new error arms, no openapi change** (no DTO, route or payload change): `bun run openapi:export` diffs clean; FE regen is a no-op.

## Design Notes

- **Why the lock lives on the existing reads:** the fix changes *nothing* about guard order, error arms or replay semantics — it upgrades two existing SKU reads into locking reads so every +stock writer serializes on the row the kit create already locks. The 11-4 comment's premise ("serializes on the same `.for('update')` sku row") becomes true for all writers instead of one.
- **Deadlock safety:** each path locks exactly one SKU row (the adjustment's subject; the approval's over-receipt subject); GRN's multi-SKU lock is id-ordered. No new lock-acquisition ordering is introduced — a kit create and a single-SKU stock writer contend on one row, and Postgres resolves the block; no cycle exists.
- **Why not an advisory lock or an epoch re-check:** the repo's proven serialization for this exact class is the SKU row lock (GRN, kit composition cycle guard) — the fix extends the proven mechanism, it does not introduce a second one.
- **Replay interplay:** the adjustment's order is authority → replay lookup (`inventory.command.ts:353-371`) → bin/warehouse asserts → `assertSkuInTenant` (`:381`). The lock is added to the existing read in place — it already sits **after** the replay lookup, and a replayed adjustment returns at the replay hit (`:367`) before the SKU read, so a replay takes no lock and answers exactly what it answered before. No check moves relative to replay.
- **Isolation premise (enabling condition):** the fix's correctness rests on the default **READ COMMITTED** isolation of `withTenantTransaction` (`src/shared/db/tenant-scope.ts:43-55`; only reconcile opts into repeatable read, `src/modules/inventory/reconcile.ts:731`). Under REPEATABLE READ, a kit create blocked on the SKU row would read `stockOnHand` from its pre-block snapshot and the skew would reappear despite both sides holding the lock. This premise belongs in the updated `kit.command.ts` doc comment too.
- **Lock placement on the reject arm (over-receipt):** the kit probe runs only inside `decision === 'approve'`, so **reject decisions take no SKU lock** — correct, since a reject writes nothing but status. Do not hoist the lock above the decision branch; that would needlessly serialize reject decisions against kit creates.
- **Recorded concurrency side effect:** an adjustment on a SKU now blocks behind a concurrent GRN's transaction on the same SKU (GRN's `loadSkus` holds `FOR UPDATE` for the GRN's duration) — previously the two +stock appends could interleave. Harmless (no invariant depends on their interleaving) and invisible to sequential tests, but it is a behavior change beyond the kit race itself.
- **Out of scope (recorded, not fixed here):** the adjust-side bin capacity/blocking gates (deferred-work entry from 11-5); the variant-values prototype sink (F7, action item a6, its own fix); the `kitCannotHoldStock` facade face (F10, a7 docs).

## Verification

```
cd workspace/core/backend/wms-be
bun run lint && bun run typecheck
bunx jest test/kits.spec.ts test/inventory-surfaces.spec.ts test/ledger.spec.ts test/receiving.spec.ts
bun run test        # full suite — AC3
bun run openapi:export && git diff --exit-code openapi.json   # AC4
```

## Spec Change Log

- 2026-09-22 — created from epic-11 retro F2 (action item a2). Defect claims verified against the code at the cited lines before freezing.
- 2026-09-22 — design-review triage (6 findings, none blocking substance): replay-order sentence corrected (the SKU read follows the replay lookup, not precedes it); verification suite names corrected (`inventory-surfaces`, `ledger` — `inventory.spec.ts` does not exist); `SKU_CODES` fixture additions recorded; READ COMMITTED isolation premise stated (with the reject-arm lock placement and the GRN-serialization side effect).