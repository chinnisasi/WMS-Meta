---
story: 12-1-storage-class-and-conformance
title: "12-1 storage class and conformance — FR-40 on the backend"
type: 'feature'
created: '2026-09-23'
status: 'ready-for-dev'
route: 'dispatch'
review_loop_iteration: 0
epic: 12
context:
  - '_bmad-output/implementation-artifacts/epic-12-context.md'
  - 'docs/design/SYSTEM-DESIGN.md'
  - 'docs/design/IMPLEMENTATION-GUIDE.md'
  - 'docs/design/modules/putaway.md'
  - 'docs/design/modules/tenancy.md'
  - 'docs/design/modules/catalog.md'
  - 'docs/design/modules/outbound.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** FR-40 / AD-18 — storage class exists nowhere in the system: no SKU or bin carries one, nothing refuses a non-conforming placement, and a cold-chain warehouse cannot be policed by rule. `bins.type` is free text with no constraint — exactly the pattern AD-18 replaces.

**Approach:** Add a `storage_class` controlled vocabulary (ambient, chilled, frozen, controlled, hazardous, secure) as first-class columns on `skus` and `bins`, DB CHECK-backed, with a shared validator. Enforce conformance at the command layer — putaway placement, pick draw, bin suggestion, wave allocation/replan, and bin merge — via one shared predicate, with settable class on the SKU PATCH and the catalog import, and on bin create/grid. Web and mobile surfaces ride 12-7/12-8; this is the backend contract they consume.

## Boundaries & Constraints

**Always:**
- **Matching rule (decided 2026-09-23):** the temperature hierarchy — a `frozen` bin satisfies `frozen`/`chilled`/`ambient` SKUs, `chilled` satisfies `chilled`/`ambient`, `ambient` only `ambient`; `controlled`, `hazardous` and `secure` exact-match always. Expressed as one rank table inside the shared predicate.
- **Class-edit guard (decided 2026-09-23):** an edit (bin or SKU) that would leave existing stock non-conforming refuses with 409 `storage-class-conflict`, naming the conflicting SKU(s) and bin(s) — non-conforming stock can never exist **in storage bins by way of the gated writers**. The guard scans `stock_on_hand` tenant-wide (a SKU is tenant-scoped; stock spans every warehouse), joins to bins, and **treats stock held by an open QC hold as sitting in its hold's origin bin** — this is what pins QC release (the one ungated bin→bin mover, `qc.released`): a bin edit while its stock is held 409s on the held quantity, so release can never return stock to a re-classed bin. Stock sitting in system bins (Receiving staging, QC-HOLD) is **excluded** from both edit guards — otherwise every intake SKU would refuse its first class edit.
- Conformance is a command-layer rule (AD-18); the vocabulary is DB CHECK-backed, never free text.
- The gated writers obey one shared predicate: putaway placement, merge, suggestion/task derivation (`candidateFitsSku`), pick draw, wave/replan allocation — the `SYNC HAZARD` rule at `putaway.command.ts:553` (new arms land in all sites together). `qc.released` is pinned indirectly by the edit guards above (release itself stays class-free — a 409 at release would strand held stock with no recovery path).
- **Adjustments are a named bypass** (decided 2026-09-23): `stock.adjust` with a positive delta parks stock in any bin with no class gate — consistent with the existing adjustment-bypasses-capacity gap; it is recorded in PENDING.md by this story (task below), and AC-for-AC the gated set cannot create non-conforming storage-bin stock.
- Additive migration; existing rows become `ambient` by default and behave byte-identically (a non-conforming state cannot pre-exist because the vocabulary is new).

**Never:** no hazard segregation matrix (12-2); no secure-class authority gating (12-3); no non-bin location types (12-4); no excursion events (12-5); no web UI (12-7); no mobile snapshot/conformance refusal (12-8); no storage-class gate on stock adjustments (recorded as a PENDING gap beside the existing adjustment-bypasses-capacity one); no `bins.type` CHECK (12-4 owns location types).

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Conforming placement | Target bin satisfies the SKU per the matching rule | Placement proceeds; unchanged behavior | N/A |
| Non-conforming placement | Frozen SKU placed into an ambient bin | 400 naming bin code, SKU code and both classes | 400 `bin-storage-mismatch` — device-fault, non-retryable |
| Non-conforming pick draw | Pick scans a bin whose class does not satisfy the SKU | Refusal before the ledger append | 400 `bin-storage-mismatch` |
| Suggestion | SKU with class `frozen` over a mixed warehouse | Only conforming bins suggested (gate in `candidateFitsSku`); no-fit rationale may name the class | null when none fit (existing no-fit path) |
| Wave allocation | A wave line's only stock sits in non-conforming bins | The line plans a shortfall (`unfulfillable`), never a refusal-guaranteed pick | per existing shortfall arm |
| Merge | Source bin holds SKUs the target bin does not satisfy | Merge refused before any arm moves | 400 naming the offending SKU(s) |
| Class edit with conflicting stock | Bin (or SKU) edited to a class its stock contradicts | Edit refused; nothing changes | 409 `storage-class-conflict` naming the conflicting SKU(s) and bin(s) |
| Class edit while stock is in QC hold | Origin bin of an open hold edited to a class the held SKU does not satisfy | Edit refused — held stock is attributed to the origin bin | 409 `storage-class-conflict` |
| Class edit, no conflict | Bin empty (no open hold) / SKU stock all satisfies the new class | Edit commits | N/A |
| Import row, blank `storage_class` cell | Optional column absent or blank | SKU class = `ambient` (the DB default — never an explicit null) | N/A |

</frozen-after-approval>

## Code Map

- `src/shared/db/schema.ts` — add `storage_class` to `skus` (:311) and `bins` (:216) with doc comments; NOT NULL DEFAULT 'ambient'.
- `drizzle/0035_*.sql` — **run `bun run db:generate` first** (produces the ADD COLUMN statements, the `0035_snapshot.json` meta snapshot and the `_journal.json` idx-35 row — hand-authoring without generate breaks the next `db:generate`), **then hand-append the CHECKs** (`col IN (...)` — NOT NULL DEFAULT, so no null arm; the 0034 convention: CHECKs live only in migration SQL, generate is blind to them). Forward-only, no data statement.
- `src/shared/primitives/storage-class.ts` (new) — `STORAGE_CLASSES`, the temperature rank table, `storageClassSatisfies(skuClass, binClass)`, `assertStorageClass(fields)` (the `assertSkuAttributes` shape, `src/modules/catalog/sku-attributes.ts:36-73`), and the refusal factories (`binStorageMismatch` 400, `storageClassConflict` 409, `mergeClassConflict` 400). The single source both validators and all gates import.
- `src/modules/putaway/putaway.command.ts` — `candidateFitsSku` (:880) gains the class gate (first gate, before unit) — **the class rule lives here alone** (plus the placement's own locked-row guard); `binCandidatesInTx` (:924) takes NO WHERE arm (it is SKU-agnostic, called once per page) but `PutawayBinCandidate` (:834) gains a `storageClass` field; `SkuPhysicalAttributes` (:853) gains `storageClass` — all three callers supply it (placement's SKU read feeding both the inline gate and the re-derived suggestion's attr object at :588-594, `suggestBinInTx` :817, facade :343); placement command target-bin block (:474-535) — mismatch refusal after `binBlocked` (:517-520), before the capacity gates; no-fit rationale may name the class (`'No conforming storage bin has room for these units'`, facade wording at `putaway.facade.ts:344`). `suggestBinInTx` otherwise unchanged.
- `src/modules/putaway/putaway.facade.ts` — task derivation's `skus` projection (:281-296) gains `storageClass` so the per-line `candidateFitsSku` (:343) filters conformingly.
- `src/modules/outbound/replan.ts` — `StockPoolInput.binOrder` entries gain `storageClass` (via `pickableBinsInTx`'s projection :143-160); `StockPoolInput` gains a `skuClassById` map; `buildStockPool` (:71) filters stock rows per SKU by the shared predicate at the bin-rank membership point (:90). Pure function — callers feed the classes.
- `src/modules/outbound/wave.command.ts` — `planSlices` (:1124) / the `buildStockPool` call (:1151): the wave planner currently reads no SKU rows, so it gains a catalog read for the lines' `storage_class`, feeding `skuClassById`.
- `src/modules/outbound/pick.command.ts` — SKU read (:656-676) gains `storageClass`; the locked drawBin guards (:738-756) gain the mismatch refusal after `blocked` (:754). `findReplanSlices` (:1196, the short-pick replan caller) feeds the same pool-input shape.
- `src/modules/tenancy/bin.command.ts` — `CreateBinCommand` (:48), `GenerateBinsCommand` (:72), `EditBinCapacityCommand` (:119) gain optional-PATCH-semantics `storageClass` (undefined = unchanged; required only in `BinSnapshot` responses); validation via the shared `assertStorageClass`; `insertBin` (:1347) and `binFromRow` (:1392) carry it. **Bin class-edit guard** (in the edit tx, behind replay): the bin's `stock_on_hand` joined to `skus` must satisfy the new class, AND `openQcHoldsForBinsInTx` (already imported at :36) must hold nothing for the bin (held stock is attributed to its origin bin) — else 409 `storage-class-conflict` naming SKU(s). **`mergeBin`** (:528): the class gate sits immediately after the `onHandRows` read (~:633-668, whose projection gains `storageClass`), before the capacity gates — per moved SKU against the target's class, 400 naming the offending SKU(s).
- `src/modules/tenancy/tenancy.dto.ts` — bin create/grid bodies (~:390-614) gain the optional field.
- `src/modules/catalog/sku.command.ts` — `EditSkuCommand` (:85-133) gains optional-PATCH-semantics `storageClass` (undefined = unchanged; keeps the `...fields` payload-hash replay property at :267-272); it joins the empty-patch refusal list AND its message (:180-196). **SKU class-edit guard** (in the edit tx, behind the replay lookup :294): tenant-wide `stock_on_hand` joined to `bins`, EXCLUDING `system_owned` bins (Receiving staging, QC-HOLD), open-QC-hold quantities attributed to their origin bins; any non-conforming row → 409 naming warehouse, bin code and SKU. The class-changing arm takes the SKU row `.for('update')`.
- `src/modules/catalog/catalog.dto.ts` — SKU PATCH body (:308) gains the optional field.
- `src/modules/catalog/import.command.ts` — `OPTIONAL_COLUMNS` (:101-133) gains `storage_class`; `validateRow` (:1068) attribute block (:1168-1201) parses it — **a blank cell maps to `'ambient'`, never null** (NOT NULL column; the attributes' null-clears verb does not apply); per-row `assertStorageClass` beside the :1192 `assertSkuAttributes` site.
- Tests: `test/tenancy.spec.ts` + `test/bin-admin.spec.ts` (bin create/grid class, merge class gate, bin edit guards incl. the QC-hold arm) · `test/sku-attributes.spec.ts` / `test/catalog.spec.ts` (SKU edit guard + import column, blank-cell semantics) · `test/putaway.spec.ts` (placement refusals, suggestion filter, **task-derivation filter** — the `GET /putaway/tasks` suggestion, :444 area) · `test/picking.spec.ts` (pick refusal, **short-pick replan pool filter**, `replan.ts:217-241` area) · `test/waves.spec.ts` (allocation filter → `unfulfillable`). Bootstrap: `useSuiteDatabase` + `createApp(false)` (bin-admin.spec.ts:62).
- Do NOT touch: `bins.type` writers, the ledger registry (no new event), `qc.command.ts` release logic (pinned indirectly by the edit guards), the mobile snapshot (`receiving.facade.ts` snapshot is 12-8's), any FE file.

## Tasks & Acceptance

**Execution:**
- [ ] Migration `0035` — `bun run db:generate`, then hand-append the CHECKs; journal row comes from generate.
- [ ] `src/shared/primitives/storage-class.ts` — vocabulary, rank table, `storageClassSatisfies`, `assertStorageClass` (400 `validation-failed`), refusal factories.
- [ ] `schema.ts` — both columns, doc comments naming the shared primitive and the CHECKs' migration-only home.
- [ ] Putaway — class gate in `candidateFitsSku` (+ `SkuPhysicalAttributes`/`PutawayBinCandidate` fields and callers), placement refusal arm, facade projection + class-aware no-fit rationale.
- [ ] Outbound — pool input shape (`binOrder` classes + `skuClassById`), `buildStockPool` row filter, wave planner catalog read, pick draw refusal.
- [ ] Tenancy — bin create/grid/edit field (DTO + command + insert + snapshot), merge class gate after `onHandRows`, bin class-edit guard with the QC-hold arm (409 `storage-class-conflict`).
- [ ] Catalog — SKU edit field (DTO + empty-patch list) + 409 guard with `.for('update')`, import optional column with blank→ambient.
- [ ] Tests per suite above; `bun run openapi:export` (fields are additive; FE regen is NOT this story — expected FE drift-guard failure until BE merges is fine).
- [ ] `docs/design/PENDING.md` — add the adjustment-bypasses-class entry beside the adjustment-bypasses-capacity one (:54), and the residual placement/pick-vs-SKU-edit race note (both commands read the SKU unlocked).

**Acceptance Criteria:**
- Given a warehouse with mixed bins and a frozen SKU, when putaway suggests and the operator confirms the suggested bin, then the suggestion is always a conforming bin, and a deliberate placement into a non-conforming bin 400s `bin-storage-mismatch` naming both classes.
- Given a picklist whose stock sits in a non-conforming bin (reachable via the recorded adjustment gap, a QC-release across a class edit — impossible by guard — or a direct DB write), when the wave plans, then the line plans `unfulfillable` rather than a pick that always refuses.
- Given two bins of different classes where the source holds a SKU the target cannot satisfy, when `mergeBin` runs, then it refuses naming that SKU and nothing moves.
- Given a bin (and a SKU) edited to a class its current stock contradicts, when the edit runs, then it 409s `storage-class-conflict` naming the parties and nothing changes; the same edit with no conflicting stock (bin empty and hold-free, or all the SKU's stock satisfying the new class) succeeds.
- Given an open QC hold whose origin bin is edited, the edit 409s on the held quantity — a subsequent release can never return stock to a non-conforming bin.
- No existing sequential behavior changes — the full suite stays green.

## Design Notes

- **One predicate, five sites.** `storageClassSatisfies(sku, bin)` is imported by: `candidateFitsSku` (suggestion + placement re-derivation + facade task fit), the placement command's own guard (server-side truth on the locked row), the pick draw guard, the pool filter, and merge's per-SKU loop. This is the 11-5 pattern — one gate predicate behind every arm — applied to the class axis. The hierarchy is encoded ONCE, in the TS predicate — no SQL-side copy (the `binCandidatesInTx` candidate list is shared and SKU-agnostic; the per-(SKU, bin) rule can only live in TS).
- **QC release is pinned by the edit guards, not by a release gate.** `qc.released` writes `toBinId: row.binId` unguarded (`qc.command.ts:523-524`). Gating release itself (409, hold left open) would strand held stock with no recovery path; instead the bin class-edit guard counts held stock as sitting in its origin bin, so a bin holding stock in an open QC hold cannot change class until the hold closes. Release stays class-free.
- **Refusal factories in the shared primitive, not a third `binBlocked` copy.** The existing `binBlocked` is duplicated (putaway `:1220`, pick `:2003` — same code, divergent messages); tenancy imports putaway's. The new factories (`binStorageMismatch`, `storageClassConflict`) live once in `src/shared/primitives/storage-class.ts`, imported by putaway, pick and tenancy.
- **Default `ambient` is safe by construction:** no pre-existing state can become non-conforming because no non-ambient class existed before; every existing bin is ambient and every existing SKU is ambient — conforming. No data statement, no backfill.
- **System bins need no gate exemption:** placement already refuses `systemOwned` targets and pick refuses `systemOwned` draws. The QC-HOLD bin holds non-ambient stock by construction (any held SKU parks in the ambient QC bin) — that is staging, visible to no gate, and the edit guards' system-bin exclusion covers it.
- **Recorded narrowing decisions (deliberate, not silent):** (a) exact-match for `controlled`/`hazardous`/`secure` excludes the converse — an ordinary ambient SKU cannot live in a secure cage or hazmat bin; FR-40/42 demand only that those stock classes be held there, and 12-2/12-3 refine this. (b) "colder satisfies" (frozen bins hold chilled/ambient SKUs) is deliberate — it matches cold-chain practice; the quality edge (dairy frozen solid) is shelf-life/excursion territory (FR-50, 12-5), not conformance.
- **Residual races, recorded in PENDING by this story:** (a) `stock.adjust` bypasses the class gate (the capacity-gap precedent); (b) placement and pick read the SKU row unlocked, so a class edit committing between a placement's SKU read and its ledger append parks non-conforming stock — the class-changing arm takes `.for('update')` on the SKU row, but the other two commands are not given a SKU lock in this story (same class of race as 11-5's recorded adjustment-vs-placement window).
- **Sync hazard** (`putaway.command.ts:553-562`): the class arm must land in placement + `candidateFitsSku` + `mergeBin` in one commit — exactly this story's scope.

## Verification

**Commands:**
- `cd workspace/core/backend/wms-be && bun run lint && bun run typecheck`
- `bunx jest test/putaway.spec.ts test/picking.spec.ts test/waves.spec.ts test/tenancy.spec.ts test/bin-admin.spec.ts test/catalog.spec.ts test/sku-attributes.spec.ts`
- `bun run test` — full suite green; **this is also the migration proof** (test/support/global-setup.js applies `0035` to `wms_template`; a broken migration fails every suite at setup).
- Migration CHECK proof — one query per table against the template DB: `information_schema.columns` (both `storage_class` columns, NOT NULL, DEFAULT 'ambient') and `information_schema.table_constraints` (both CHECKs present), plus one live insert of `storage_class = 'tropical'` expecting a CHECK violation.
- `bun run openapi:export && git diff --stat openapi.json` — additive-only diff (new optional/required fields, no removals)

## Spec Change Log

## Review Triage Log

Design review, 2026-09-23 — three context-free lenses over the spec (claim verification, edge cases, migration/verification gaps). 22 findings consolidated, deduped, triaged; every accepted amendment cites its lens sources.

| # | Finding (lens) | Verdict | Disposition |
|---|---|---|---|
| 1 | QC release can return held stock to a re-classed bin — origin bin reads empty during a hold, edit guard passes, `qc.released` is unguarded (`qc.command.ts:523-524`) (L1-H1, L2-H2, L3-H1) | high, confirmed by three lenses | **Accepted.** Release itself stays class-free (a 409 there strands held stock with no recovery); instead both edit guards attribute open-QC-hold quantities to their origin bins — a bin under hold cannot change class, so release can never create non-conforming stock. Design Notes + I/O matrix + AC amended; `qc.command.ts` explicitly do-not-touch |
| 2 | Adjustment exemption contradicts the "every +stock writer" invariant; AC's "only via a bypass" premise false; promised PENDING record absent (L3-H2, L2-M7) | high | **Accepted.** Invariant reworded ("gated writers"; adjustments a named bypass); execution task added to write both PENDING entries; AC premise reworded |
| 3 | `binCandidatesInTx` WHERE arm unimplementable — the call is SKU-agnostic, one call per page (L2-M5, L1-M3, L3-M3) | high-medium | **Accepted.** WHERE arm deleted; the rule lives solely in `candidateFitsSku` + the placement's own guard; candidate gains the field; TS-only encoding (no SQL copy) |
| 4 | Class-edit guard scope unspecified — SKU is tenant-wide, staging bins would refuse every first class edit (L2-H1, L1-M3, L3-M4) | high | **Accepted.** Guard scans tenant-wide, EXCLUDES system bins (Receiving staging would otherwise 409 every intake SKU's first class edit — the cold-chain flow dies); held stock attributed to origin bins; `.for('update')` on the class-changing arm |
| 5 | Merge gate has no data at the pinned position — `onHandRows` is read after the QC-hold guard (L2-M4, L3-verified :610-620) | medium | **Accepted.** Gate moved immediately after the `onHandRows` read, projection gains `storageClass` |
| 6 | `buildStockPool` input carries no classes; `wave.command.ts` missing from Code Map; wave planner reads no SKUs (L1-M2, L2-M6) | medium | **Accepted.** Input shape specified (`binOrder` classes + `skuClassById`); `wave.command.ts:1124/:1151` added with its catalog read |
| 7 | No AC exercises the 409 `storage-class-conflict` arm (L3-M5) | medium | **Accepted.** New AC |
| 8 | AC4 contradicts the guard — stock conforming to the OLD class 409s the edit (L3-M6) | medium | **Accepted.** AC4 rewritten (new-class satisfaction) |
| 9 | Migration proof never proves CHECKs exist or fire (L3-M7) | medium | **Accepted.** Verification extended: `table_constraints` + live invalid insert |
| 10 | Hand-authored 0035 leaves no meta snapshot — next `db:generate` re-emits the ADD COLUMNs (L3-M8) | medium | **Accepted.** Order stated: generate first, then hand-append CHECKs |
| 11 | Import blank cell maps to null → violates NOT NULL (L3-M9, L2-L10) | medium | **Accepted.** Blank maps to `'ambient'`, never null; matrix row added |
| 12 | Exact-match converse exclusion silently narrows FR-40/42 (L3-M10) | medium | **Accepted** as a recorded decision note (Design Notes) — narrowing is intentional, 12-2/12-3 refine |
| 13 | `frozen`-satisfies-`chilled` is an unstated quality interpretation (L3-L11) | low | **Accepted** — recorded note (colder satisfies deliberately; quality edge is FR-50/12-5) |
| 14 | Test assignment omits task-derivation filter and short-pick replan filter (L3-L12) | low | **Accepted** — named in the test row |
| 15 | DTO/controller surfaces omitted (`tenancy.dto.ts`, `catalog.dto.ts`, placement suggestion attrs) (L3-L13) | low | **Accepted** — added to Code Map |
| 16 | `binBlocked` not "verbatim" — divergent messages; shared factory changes one 400 body (L1-L4) | low | **Accepted** — Design Notes reworded; new factories are single-source by design |
| 17 | Wrong path `src/catalog/sku-attributes.ts`; facade citation :317-330 → :281-296; OPTIONAL_COLUMNS :101-133; placement block :474-535; SYNC HAZARD :553-562 (L1-L5/6/7/8, L3-L14) | low | **Accepted** — all citations corrected |
| 18 | `SkuPhysicalAttributes` must gain the field; three callers named (L1-L9) | low | **Accepted** — Code Map |
| 19 | Empty-PATCH list/message must gain the field; payload-hash replay property depends on optional-with-PATCH-semantics (L2-L9) | low | **Accepted** — Code Map (both edit commands optional-PATCH, empty-patch list) |
| 20 | No-fit rationale misnames the cause once classes exist (L2-L11) | low | **Accepted** — class-aware wording allowed |
| 21 | Import row warning on blank class (L2-L10 part) | low | **Rejected for this story** — blank→ambient is documented; a warning row is 12-7 admin-surface material |
| 22 | `bun run db:migrate` on "the test DB" imprecise — global-setup applies to `wms_template` (L3-L15) | low | **Accepted** — Verification reworded |

Clean (all three lenses): vocabulary matches FR-40/AD-18 exactly; movement enumeration complete (`qc.held`/`qc.released`/`putaway.placed`/`bin.merged` are the only bin→bin movers; GRN targets only the system Receiving bin; pack/dispatch carry null bin arms; reconciliation rebuilds from ledger replay and cannot mint stock); guard positions verified in code; replay runs before every new guard (correct for a 409 edit rule); no `SELECT *` breakage from the new NOT NULL columns; merge/retire structural arms need no class-specific change; wave shortfall arm exists.

## Implementation Notes