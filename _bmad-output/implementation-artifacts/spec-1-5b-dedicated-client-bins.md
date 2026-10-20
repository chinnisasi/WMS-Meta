---
title: '1.5b Dedicated client bins — a bin dedicated to one client refuses other clients'' stock in putaway, merge and transfers'
type: 'feature'
created: '2026-10-20'
status: 'done'
baseline_commit: '0c3962606e1468de4248189761530a653ac7ceb6'  # wms-be; wms-fe: 235701e631a5da64a4d20981fdaf9fcff2e18230; wms-mobile: 3a208c070c2bb7f9c74a274a2d36db6af028db0e
route: 'dispatch'
review_loop_iteration: 0
context:
  - 'docs/initiatives/production-readiness.md'
  - 'docs/design/SYSTEM-DESIGN.md'
  - 'docs/design/IMPLEMENTATION-GUIDE.md'
  - 'docs/design/modules/putaway.md'
  - 'docs/design/modules/movements.md'
  - 'docs/design/modules/inventory.md'
  - 'docs/design/modules/clients.md'
  - 'docs/design/modules/tenancy.md'
  - 'docs/design/frontend/IMPLEMENTATION-GUIDE.md'
  - 'docs/design/mobile/IMPLEMENTATION-GUIDE.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** A 3PL often reserves racks for one brand, but storage is commingled.
- `bins.dedicated_client_id` exists (0040) and nothing reads or writes it (PENDING clients "Dedicated bins — story 1.5b").
- So nothing stops another client's goods being put away, merged or transferred into a bin that is meant for one client.

**Approach:**
- One new bin gate, "the bin accepts this SKU's client", added beside the 12-1 storage-class gate everywhere stock is placed into a bin: putaway placement, the putaway suggestion, bin merge and transfer receive.
- Bin admin on the web sets and clears the dedication; the handheld pre-checks it on putaway and transfer from the snapshot.

**Decisions (user, 2026-10-20):**
1. **Bins only.** A bin carries an optional client; zones are unchanged. The bin generator can dedicate a whole new grid.
2. **Prefer own bins.** A dedicated bin refuses any other client's stock. The putaway suggestion tries the SKU's client's dedicated bins first, then shared bins. A client's goods may still go into shared bins.
3. **Dedicate only an empty-of-others bin.** Setting a bin's client is refused while it holds any other client's stock or open QC holds, naming those SKUs — the 12-1 class-edit rule.

**Decisions (agent):**
4. **The rule:** a bin accepts a SKU when the bin has no dedicated client, or it equals the SKU's client (`skus.client_id` is NOT NULL). Pure predicate `binClientAccepts(binClientId, skuClientId)` in `shared/primitives/client-bin.ts`.
5. **Refusal code `bin-client-mismatch`**, naming the bin, its client and the SKU's code and client: **400 from putaway placement and merge** (as their other gates), **409 from transfer receive** (as its gate runner).
6. **System bins can't be dedicated** (Receiving, QC-HOLD, In-Transit, Returns): 400 `validation-failed` on a non-null value. Their receipts stay ungated.
7. **Clearing a dedication is always allowed.** Moving a dedication from client A to B follows decision 3.
8. **Client checks on dedicate:** unknown client 404 `not-found`; departed 409 `client-departed`; suspended allowed. An existing dedication to a departed client stays and keeps refusing others.
9. **Bypasses stay named,** like the other bin gates: stock adjustments and the count corrections that post through them. QC release back to its origin bin is covered by decision 3 counting open holds.
10. **A dedication never strands queued putaways.** Placement re-derives the suggestion; a target equal to the suggestion **with or without** the own-client preference needs no mismatch reason, so a handheld that followed an older (shared-bin) suggestion is not refused for it.
11. **Device refusals on replay.** `bin-client-mismatch` joins the device's placement-gate codes: a refused putaway or transfer op is kept and re-plannable, retried, then quarantined to the web review queue — never dropped. The fix there is to clear the dedication and Apply, or Discard / Recount.
12. **Transfers are gated at receive, not at create** (as storage class). A transfer planned into a bin later dedicated to another client is refused at receive; the receive-time landing-bin override or a handheld re-plan recovers it.
13. **The bin admin screen is never filtered by 1.5a's client switcher,** and create / grid default to "Shared".

## Boundaries & Constraints

**Always:**
- **One shared ranking.** A new exported `pickPutawayCandidate(candidates, sku, qty, skuId, { preferOwn })` does two stable passes over the existing SQL order (lowest occupancy, then code): first candidates with `dedicatedClientId === sku.clientId`, then shared ones; each through `candidateFitsSku`. One shared rationale builder ("Dedicated to GlowCo — lowest occupancy …" / the existing text). **Both** `suggestBinInTx` (`putaway.command.ts:988`) and task derivation (`putaway.facade.ts:384-421`) call them; `binCandidatesInTx` (`:1174`, select and `groupBy` `:1234`) carries `dedicatedClientId`; `PutawayBinCandidate` and `SkuPhysicalAttributes` (`:1050`) gain `dedicatedClientId` / `clientId`, filled at both call sites (`:716-737` and the facade SKU select `:325-342`).
- **Placement** (`putaway.command.ts:520-770`): the client gate beside the class gate (`:577`); the mismatch-reason check (`:760`) accepts a null reason when the target equals the suggestion with `preferOwn` true or false (decision 10). Update the gate-list comment (`:681`).
- **Merge** (`tenancy/bin.command.ts:769`): every moved SKU must be accepted by the target → 400.
- **Transfer receive** (`inventory/inventory.facade.ts:2380`): per landing bin, every SKU → 409.
- **QC release locks its origin bin** `FOR UPDATE` before writing (`qc.command.ts:827-843`, closing PENDING "releaseHold lacks .for('update')"), so the dedicate guard and a release serialise.
- **Bin admin (`PATCH …/bins/:id`):**
  - `PatchBinDto.dedicatedClientId?: string | null` — `@IsOptional() @IsUUID()` with `@ApiProperty({ type: String, format: 'uuid', nullable: true })`; `null` clears (unlike `storageClass: null`, which stays a 400).
  - Routing (`tenancy.controller.ts:605-626`): `dedicatedClientId !== undefined` (including null) makes the body an attribute edit; may combine with other attributes, never with `blocked`; the "Nothing to change" text lists it.
  - `editBinCapacity` (`bin.command.ts:1316`) hash gains `dedicatedClientId: command.dedicatedClientId` (absent drops out of `JSON.stringify`, so existing fingerprints are unchanged — pinned by a test).
  - Order: replay → bin lock → retired → system bin (non-null only) → `assertClientTakesWorkInTx` (client row `FOR KEY SHARE` after the bin lock) → class guard (existing) → client guard.
  - Client guard (decision 3), only when the value changes to a non-null client: open QC holds originating in the bin, then on-hand stock, whose SKU client differs → 409 `bin-client-conflict` naming up to 10 SKUs via `skuCodeLabelsInTx`.
  - Outbox `bin.capacity_changed` carries `dedicatedClientId`; audit as today.
- **Create and grid:** `CreateBinDto` (`:637`) and `GenerateBinsDto` (`:750`) take optional `dedicatedClientId` (same client checks; hashed only when present).
- **Bin shapes carry the field** (`?? null` for stored pre-1.5b responses): `BinResponse` (`:993`), `normalizeBin` (`tenancy.controller.ts:775`), `listBins` and `BinRow` (`tenancy.service.ts:942-965`), the block/unblock response (`putaway/bin-state.command.ts:129-152`), `BinSnapshot['bin']` and `binFromRow` (`bin.command.ts:180,1810`).
- **API descriptions** add the new arms on the bin PATCH/create/grid, merge (`tenancy.controller.ts:681`), putaway (`api/putaway.controller.ts:65`) and transfer receive (`api/movements.controller.ts:205`).
- **Snapshot:** bin summaries (`putaway.facade.ts:439`, `receiving.facade.ts:160-172`, DTO) carry `dedicatedClientId: string | null`; `snapshotClients` (`api/receiving.controller.ts:225-230`) also includes every bin's dedicated client, so the device can name it.
- **Handheld:**
  - `CatalogBin.dedicatedClientId` optional; `parseCatalogSnapshot` defaults it to null.
  - A tested helper in `src/lib/conformance.ts` (the 12-8 `skuClassForTask` pattern) resolves a SKU's client and a client's name from the snapshot.
  - `evaluateBin` refuses when the bin's client is set and differs from the task SKU's client; `evaluateLandingBin` refuses when any line's SKU client differs, naming that SKU. Skipped when either client is unknown (legacy mode). Message: "Bin X is dedicated to <client> — choose another bin" ("another client" when the name is unknown). A pre-filled planned landing bin that is refused shows that message, not the generic prompt.
  - Callers `app/putaway.tsx:146-152` and `app/transfer.tsx:93,121` pass the snapshot-resolved clients.
  - `bin-client-mismatch` joins `TRANSFER_PLACEMENT_GATE_CODES` (`src/state/replay-classification.ts:27-37`) — decision 11.
- **Web (`components/settings/zone-bin-setup.tsx`):**
  - When `showClients`: a "Client" column (resolved from all clients, departed included); an "Edit client" inline panel on the Edit-class pattern (`:663-714`), gated on `bin.create`, inert for system and retired bins (`:858`); options "Shared" plus working clients, with a current departed client shown as a disabled current value; no PATCH when unchanged; editing disabled with a note when clients fail to load. Create and grid forms take an optional client defaulting to "Shared". All hidden for a single-client tenant.
  - Merge picker labels each target's dedicated client; the server refusal is the gate.
  - Messages for `bin-client-mismatch`, `bin-client-conflict` and `client-departed` in `rejectionReason` (`:1023-1069`) and `binClassReason` (`lib/sku-admin.ts:119`); a client `not-found` reads "That client no longer exists", not "bin".
- **Docs:** PENDING — close "Dedicated bins — story 1.5b" and "releaseHold lacks .for('update')"; add "Stock adjustments and count corrections bypass the dedicated-client gate too"; a 13-3 note that restocking from Returns must run `binClientAccepts`. Gate-list comment in `storage-class.ts:28`.

**Never:**
- No zone dedication.
- No per-client "dedicated storage only" rule.
- No gate on system-bin receipts, stock adjustments, picks, allocation or transfer create.
- No automatic move of existing stock when a bin is dedicated.
- No change to 1.5a's filters.
- No FK, no new column, no migration.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected | Error |
|---|---|---|---|
| Dedicate empty bin | PATCH `{dedicatedClientId: GLOWCO}` | 200, list and snapshot show GlowCo | N/A |
| Dedicate with other stock | bin holds a self SKU | unchanged | 409 `bin-client-conflict` naming it |
| Dedicate with own stock | only GlowCo SKUs | 200 | N/A |
| Dedicate with a self QC hold from the bin | open hold | unchanged | 409 `bin-client-conflict` |
| Clear | `{dedicatedClientId: null}` | 200, shared | N/A |
| System bin | dedicate RECEIVING | unchanged | 400 `validation-failed` |
| Unknown / departed / suspended client | random id / departed / suspended | — / — / 200 | 404 `not-found` / 409 `client-departed` / N/A |
| Class and client both change | both conflict | unchanged | the class conflict (first) |
| Hash | same key, other client | none | 422 key reuse |
| Putaway own / other / shared | GlowCo SKU → GlowCo bin; self SKU → GlowCo bin; GlowCo SKU → shared | placed / refused / placed | — / 400 `bin-client-mismatch` / — |
| Suggestion | GlowCo SKU; GlowCo bin and an emptier shared bin | task and placement both suggest the GlowCo bin, rationale names it | N/A |
| Suggestion other client | self SKU; GlowCo bin emptiest | never suggested | N/A |
| Stale suggestion followed | task suggested shared bin S before a GlowCo bin was dedicated; placed into S with no reason | placed | N/A |
| Merge | source holds self stock, target GlowCo | unchanged | 400 `bin-client-mismatch` |
| Transfer receive | self line landing in a GlowCo bin | refused; override to another bin succeeds | 409 `bin-client-mismatch` |
| QC release race | dedicate while a self hold releases into the bin | serialised: one waits; never foreign stock in a dedicated bin | — |
| Handheld putaway / transfer | GlowCo bin, self SKU (or a mixed transfer) | refused on device, names GlowCo and the SKU | N/A |
| Handheld legacy / old snapshot | no clients or no field | no local refusal; server gates | N/A |
| Device replay | server answers `bin-client-mismatch` | op kept, re-plannable, then quarantined to the review queue | N/A |
| Web single client | one client | no column, panel or client fields | N/A |

</frozen-after-approval>

## Code Map

**Backend (`wms-be/src`)** — the file:line references live in Boundaries; the full list of touched files:
- `shared/primitives/client-bin.ts` (new): `binClientAccepts`, `binClientMismatch`, `binClientConflict`.
- `modules/putaway/putaway.command.ts` (`pickPutawayCandidate`, rationale builder, placement gate and reason rule, candidate select/groupBy, `SkuPhysicalAttributes`); `putaway.facade.ts` (task derivation through the shared helper, SKU select, bin summaries); `putaway/bin-state.command.ts`.
- `modules/tenancy/bin.command.ts` (merge gate, edit guard, create/grid, `BinSnapshot`, `binFromRow`, outbox payload), `tenancy.dto.ts`, `tenancy.controller.ts`, `tenancy.service.ts` (`listBins`).
- `modules/inventory/inventory.facade.ts` (transfer gate); `modules/inbound/qc.command.ts` (release lock); `modules/inbound/receiving.facade.ts` + `api/receiving.controller.ts` (snapshot bins and clients).
- `api/putaway.controller.ts`, `api/movements.controller.ts` (descriptions); `openapi/openapi.json` regenerated.
- Tests: new `test/dedicated-bins.spec.ts` — every matrix row, including: the bins list and the device snapshot return the field and the client; task suggestion equals the placement's re-derivation (placed with `reasonCode: null`); the stale-suggestion row; the QC release race (parked waiter); the hash pin (existing fingerprint unchanged; other client → 422). Update `bin-admin.spec.ts` (outbox payload), putaway, merge, transfer and QC suites where fixtures change.

**Web (`wms-fe/src`)** — `components/settings/zone-bin-setup.tsx`, `lib/sku-admin.ts`; `bun run api:generate` after the backend merges (no new wrapper: `fetchApiSetBinBlocked` takes `PatchBinDto`; no new capability). Tests in `zone-bin-setup.test.tsx` (add a clients stub): edit and clear; unchanged sends nothing; conflict, mismatch, departed and client-not-found messages; departed current value kept on Save; system bin inert; no affordance without `bin.create`; create and grid payloads carry the client only when chosen; merge picker labels; single client hides everything.

**Handheld (`wms-mobile`)** — `src/api.ts` `CatalogBin`; `src/state/catalog-snapshot.ts`; `src/lib/conformance.ts` helper; `src/putaway/draft.ts` (`evaluateBin` signature — update its ~14 test calls); `src/transfers/draft.ts`; `app/putaway.tsx`, `app/transfer.tsx`; `src/state/replay-classification.ts`. Tests: the conformance helper; putaway and transfer drafts (refusal, shared, unknown client, mixed transfer, unnamed client fallback); `device-store.test.ts` (the legacy-bin default pinned by equality; update `:388` and the round-trip at `:534`); `replay-classification.test.ts` (putaway and transfer ops with the new code are re-plannable).

## Tasks & Acceptance

**Execution:**
- [x] `wms-be` primitive, shared ranking, gates in placement, merge, transfer; QC release lock -- the rule everywhere stock lands
- [x] `wms-be` bin admin DTOs, routing, hash, guard, shapes, snapshot, descriptions, openapi -- dedicate and clear
- [x] `wms-be` `test/dedicated-bins.spec.ts` + suite updates -- the matrix
- [x] `wms-fe` column, Edit-client panel, create/grid fields, merge labels, messages + tests -- web admin
- [x] `wms-mobile` snapshot field, conformance helper, local refusals, screens, replay code + tests -- handheld refusals
- [x] Meta docs (land last): `modules/putaway.md`, `tenancy.md`, `clients.md`, `inbound.md` (release lock), `API-SURFACE.md`, mobile guide, repo READMEs, PENDING

**Acceptance Criteria:**
- Given an empty bin, when an ops manager dedicates it to GlowCo on the web, then the bin list shows GlowCo and a fresh handheld snapshot carries the bin's client and GlowCo's name.
- Given a GlowCo bin, when an operator puts away a self SKU there, then the handheld refuses before sending, and a direct server placement is refused with `bin-client-mismatch`.
- Given a GlowCo SKU awaiting putaway and a GlowCo bin with room, then the task's suggested bin is that GlowCo bin, and placing there with no reason succeeds.
- Given a bin holding self stock or a self QC hold, when someone dedicates it to GlowCo, then it is refused naming the self SKUs.
- Given a GlowCo putaway task that suggested a shared bin before a GlowCo bin was dedicated, when the operator places into that shared bin with no reason, then it is placed.

## Implementation Notes

Decisions taken in implementation where the spec left a choice (backend):

- **The recorded suggestion follows the match (decision 10).** `suggestBinInTx` returns the preferred suggestion plus the unpreferred one (`unpreferred: {binId, binCode} | null` — the same eligible set, so both are null together). When the target equals the unpreferred bin and no reason was given, the placement records THAT (with a reason it records the preferred suggestion and keeps the reason — a deliberate skip, per code review) as `suggestedBinId`/`suggestedBinCode`, so every stored row keeps "reason is null iff target = suggestion" (otherwise a followed stale suggestion would read as a mismatch with no reason in the SM-3 report).
- **The client gate lives in `candidateFitsSku`** (right after the class gate), so `pickPutawayCandidate`'s passes need no separate acceptance check; `preferOwn: false` is one stable pass over every accepting bin.
- **`assertClientTakesWorkInTx` on edit runs only when the value changes to a non-null client** — re-sending the current (since-departed) client is not refused, matching decision 8 ("an existing dedication to a departed client stays"). On create and grid it runs for any non-null value.
- **A null `dedicatedClientId` on a system bin passes** (decision 6 refuses a non-null value only); it is a no-op write.
- **Create/grid hash `dedicatedClientId ?? undefined`** — null (shared) and absent both drop out of the fingerprint, so a pre-1.5b request and an explicit-shared request hash alike. The PATCH hashes it as given (null = clear is a distinct intent).
- **The `bin-client-conflict` detail** names up to 10 distinct SKUs (holds first, then on-hand) and says which of "open QC holds that return to it" / "stock on hand" applies.
- The rationale names the client by its refusal label (`getClientLabelsInTx`: the code, or "<tenant> (your company)" for self) — `Dedicated to GLOW — lowest occupancy …`.

Web and handheld:

- **Web:** when the clients read fails the Client column and Edit client are hidden behind a note with Retry (rather than a disabled editor — with no list there is nothing to name or offer). A create/grid `not-found` with a client chosen reads "That warehouse, zone or client no longer exists" (the server does not say which).
- **Handheld:** the client argument to `evaluateBin` / `evaluateLandingBin` is optional (null = legacy mode), so the existing `evaluateBin` test calls were left unchanged; new cases cover the client arms. A refused pre-filled planned landing bin now shows any refusal reason (blocked and system bins included), not only the client one.

Verification: wms-be full jest suite 101 suites / 2472 tests green, lint, typecheck, build, `db:generate` no changes; mutation checks (client gate in `candidateFitsSku`, placement, merge, transfer, edit guard, the release lock, the decision-10 rule) each fail `test/dedicated-bins.spec.ts`. wms-fe lint/test (2081)/typecheck/build/capability mirror green. wms-mobile `bun test` 717 / typecheck green.

## Spec Change Log

## Review Triage Log

**Design review, 2026-10-20.** Three reviewers: backend (B1–B9), edge cases (E1–E13), web and handheld (F1–F14). 36 raw findings, 24 after merging duplicates. Load-bearing claims re-checked by hand: the replay classification is by code for every op type (`replay-classification.ts:135-160`); placement re-derives the suggestion and requires a reason on mismatch (`putaway.command.ts:715-764`). Every confirmed finding is patched above.

- D1 high (B1, E1, F2): task derivation ranks separately from `suggestBinInTx`; followed suggestions would be refused. One shared ranking and rationale for both.
- D2 high (E2): a dedication shifts the suggestion for queued putaways. Decision 10: either ranking needs no reason.
- D3 high (F1, B5): `listBins` and other bin shapes pick columns by hand; the web column would be blank. Every shape named, `?? null` for stored responses.
- D4 high (F3, E3): the spec's replay claim was wrong. Decision 11: kept, re-plannable, then quarantined.
- D5 high (B2): merge gates answer 400, not 409. Decision 5 corrected.
- D6 med (B3): `SkuPhysicalAttributes` and candidates lacked the client fields. Named at both call sites.
- D7 med (B4): a QC release committing mid-guard could slip past. Release locks its origin bin; the guard reads holds first.
- D8 med (B6, E8, F11): PATCH routing would 400 a clear; hash and nullable OpenAPI unstated. All specified; fingerprint pinned.
- D9 med (B7, E9, E13): guard order, unknown and suspended clients, SKU labels, outbox payload. Written in.
- D10 med (B8, E4, F6): the device can't name an unreferenced client. Snapshot clients include dedicated clients; fallback text.
- D11 med (E5, F5): the transfer check had no SKU and mixed transfers were undefined. Any line differing refuses; pre-fill refusal shown.
- D12 med (E6, B9): transfers can be planned into another client's bin. Decision 12: gated at receive, override recovers.
- D13 med (E7, F8): the merge picker can't see source clients. Labels only; the server is the gate.
- D14 med (F4): device screens untested and the lookup unspecified. A tested conformance helper; screens named.
- D15 med (F7): equality tests for the legacy bin. Named.
- D16 med (F9, E10, E11): Edit-client panel rules (departed value, unchanged, inert bins, single client, clients failing). Written in.
- D17 med (F10): interplay with 1.5a's switcher. Decision 13.
- D18 low (F12, E9): `not-found` read as "bin". Client copy added.
- D19 low (E12, B9): bypass entry widened to counts; 13-3 restock note.
- D20 low (B9): gate-list comments.
- D21 low (F13): no new capability or wrapper. Stated.
- D22 low (F14): verification gaps (snapshot AC, list field, ranking parity, replay, mixed transfer, web cases). Tests named.
- D23 low (B7): `bin.capacity_changed` payload. Carries the field.
- D24 low (E13): refusal order when class and client both change. Class first.

Rejected: none.

**Code review, 2026-10-20.** Three layers over the three-repo diff: blind (BH1–BH15), edge cases (EC1–EC5), verification gaps (VG1–VG5). 25 raw findings, 8 patch entries after grouping, the rest rejected. Claims checked against the code: the reason strip at `putaway.command.ts:823`, `suggestBinInTx`'s single caller (`:745`, rationale unread), `getClientLabelsInTx` short-circuiting on an empty list, the retired check ahead of the dedication arm (`bin.command.ts:1461`), the stale schema comment (`schema.ts:651`).

- P1 med (BH1, EC1, BH8) patch: a placement into the unpreferred (shared) bin WITH a reason was recorded as followed — the reason stripped and the unpreferred bin stored as the suggestion, losing a deliberate skip of the client's own bin. The unpreferred bin counts as followed only when no reason is sent.
- P2 med (VG3) patch: `evaluateBin` / `evaluateLandingBin` default the client lookup to null, so a screen can drop it and the offline gate silently turns off; the Code Map asked for the test calls to be updated. Make it required.
- P3 low (BH2) patch: `suggestBinInTx` reads client labels to build a rationale its only caller (placement) never reads — an extra query inside the bin-row lock. Drop the rationale from that path.
- P4 low (VG1, BH10) patch: create and grid fingerprints with `dedicatedClientId` are unpinned. Same key, other client → 422, for both.
- P5 low (VG2, BH10) patch: the `normalizeBin` `?? null` for stored pre-1.5b responses is unasserted. Add `dedicatedClientId: null` to the legacy-replay expectations in `bin-admin.spec.ts`.
- P6 low (VG4) patch: the create/grid refusal copy for `client-departed` and the client `not-found` is untested. Drive a refused create.
- P7 low (BH5) patch: the `bins.dedicatedClientId` schema comment still reads "Inert until 21-2+".
- P8 low (BH9) patch: the QC race test claims "either way" but drives release-first only. Name what it drives.

Rejected:
- BH3: adjustments and counts bypass the gate — decision 9 names it; PENDING records it.
- BH4: the dedicate guard ignores in-transit transfers into the bin — decision 12 accepts refusal at receive with the override.
- BH5 (FK/index part): "No FK, no new column, no migration".
- BH6: a departed client's bins stay dedicated — decision 8; clearing is per bin.
- BH7, EC4, VG5 (other): the transfer pre-fill refusal also shows blocked/system reasons and has no scan suffix — the spec asks the refused pre-fill to show its reason; no scan happened, so no "scan not recorded" suffix; the wider arm is a clearer message than the generic prompt. Low.
- BH10 (rest): own-bins-full fallback, grid unknown client, mixed-line receive, suspended client — not matrix rows; the shared code paths are covered.
- BH11: the event name `bin.capacity_changed` is the spec's; a no-op PATCH writing an event is pre-existing.
- BH12: the rationale not saying the own bins are full — enhancement, low.
- BH13: create forms keep the chosen client after success — every other create field (type, class) sticks the same way; low.
- BH14: linear lookups on the device — a few finds per scan; negligible.
- BH15: dedicating dock/staging bins — decision 1 dedicates bins without a type rule; no defect shown.
- EC2: a client departing while a create form is open — rare, the server refuses 409 with clear copy; low, fix adds an effect.
- EC3: Edit-client panel holding a stale bin after another user's edit — rare; the server state wins on reload; low.
- EC5: clearing a retired bin is 409 — the spec's guard order puts retired first; a retired bin holds nothing to gate. False.

## Design Notes

**Why copy the storage-class gate.** It is a pure predicate on the locked bin row and the SKU row already in hand, run at exactly the four places stock lands in a bin. The client gate has the same inputs (the SKU's `client_id` is already read in placement and transfer), so it inherits the lock order and the refusal shapes for free.

**Why the edit guard counts open QC holds.** A QC release returns stock to its origin bin through the secure gate only. Refusing the dedication while another client's hold originated in the bin keeps release from ever landing foreign stock in a dedicated bin, without adding a gate to release.

**Why preference, not exclusivity.** The user chose that a client's goods may still use shared bins; the suggestion only ranks the client's own bins first, so dedicated racks fill before shared space and nothing is stranded when they are full.
