---
story: 12-3-secure-locations
title: "12-3 secure locations — FR-42 authority gate on the backend"
type: 'feature'
created: '2026-09-24'
status: 'done'
baseline_commit: '4cb248c'
route: 'dispatch'
review_loop_iteration: 0
epic: 12
context:
  - '_bmad-output/implementation-artifacts/epic-12-context.md'
  - 'docs/design/SYSTEM-DESIGN.md'
  - 'docs/design/IMPLEMENTATION-GUIDE.md'
  - 'docs/design/modules/putaway.md'
  - 'docs/design/modules/tenancy.md'
  - 'docs/design/modules/outbound.md'
  - 'docs/design/modules/inbound.md'
  - 'docs/design/API-SURFACE.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** FR-42 — high-value and controlled stock is held in secure/cage-class locations, and movement into or out of them is authority-gated and audited. 12-1 made `secure` an exact-match storage class both ways (a secure SKU requires a secure bin; a secure bin refuses every non-secure SKU), so the *placement rule* exists — but the *authority* does not: an operator holding only the floor verbs places into and picks out of a secure bin today, and nothing about the movement is authority-gated beyond the base capability.

**Approach:** one new capability — `secure.move` — in the in-code capability vocabulary, granted per the decided matrix; every command whose ledger movement touches a secure-class bin asserts it beside the existing class gates (the bin row is already in hand there). The audit trail is the existing per-movement `audit_events` rows (actor + idempotency reference on every movement) — the gate adds authority, not a new event.

## Boundaries & Constraints

**Always:**
- The capability is a plain string in `CAPABILITIES` with grants in `ROLE_CAPABILITIES` (the in-code matrix, no migration) — the 22-entry list becomes 23.
- The gate keys on `bin.storageClass === 'secure'` at the **five movement writers**: placement (target bin), `mergeBin` (source **and** target), pick draw (source bin), QC-hold create (origin bin — held units leave it), QC-hold release (origin-return — units go back in). Each assert sits beside that command's existing storage-class gate, reusing the role already re-read per AD-10; a 403 `role-denied` detail names `secure.move` (the `assertPermission` detail shape).
- `stock.adjust` stays the **named bypass** — extend its PENDING entry (the 11-5/12-1/12-2 precedent) to name the secure gate.
- A **matrix-invariant test** pins the grants: any role holding one of the five movement capabilities (`putaway.execute`, `picks.execute`, `bin.retire`, `qc.manage`) must hold `secure.move` — so a future grant cannot silently break the gate (today only placement and pick can actually 403; the other three asserts are future-proofing the invariant).
- The FE capability mirror is part of this story: `wms-fe/src/lib/users.ts` + `users.test.ts` (count 22→23, every capability named) — the mirror guard rule. FE PR after the BE PR.

**Never:**
- No migration, no new column/table, no ledger-registry change, no new audit or outbox event type (a capability assertion is a guard, not a movement — the 12-2 precedent).
- No change to the 12-1 bin/SKU class-edit guards (they are class-agnostic and already rule `secure` edits), no change to `storageClassSatisfies`.
- No change to the suggestion walk, task derivation or wave pool — **decided (human, 2026-09-24):** they stay unchanged in this story; advisory suggestion, binding gate. An operator may be *suggested* a cage bin and 403 at the command; 12-7/12-8 refine the surfaces. Recorded in PENDING.
- `secure.move` is granted to **owner + ops_manager** (decided, human, 2026-09-24) — the cage is off-limits to floor staff; owner and ops managers execute cage placements and picks (badge-in sessions carry the actor's own role).
- No FE surface beyond the capability mirror; no mobile file; no Receiving/GRN change (system-bin intake staging is outside the gated set — recorded narrowing).
- No `.for('update')` fix on the release origin read (PENDING `inbound:45`, pre-existing currency — this story adds the assert on the class already read, not the lock).

</frozen-after-approval>

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Operator places into a secure bin | `putaway.execute` holder, target bin `storageClass: 'secure'` | 403, nothing written | `role-denied` naming `secure.move` |
| Capability holder places into the same bin | owner / ops_manager | Placement proceeds through the 12-1 class gate and 12-2 co-location gate unchanged | existing gates |
| Operator draws a pick from a secure bin | `picks.execute` holder, source bin `secure` | 403, nothing written | `role-denied` naming `secure.move` |
| Merge with a secure source or target | any role | Assert fires beside the class gate, inside the bin-row lock window | 403 `role-denied` |
| QC hold on stock in a secure origin bin / release back into one | any role | Assert fires on the origin bin's class | 403 `role-denied` |
| Non-secure bins | any movement, any role | Byte-for-byte today's behavior | N/A |

## Code Map

- `src/modules/tenancy/permissions.ts` — `CAPABILITIES` (:9-87) gains `secure.move`; `ROLE_CAPABILITIES` (:100-131) grants per the decided answer; new exported `assertSecureBinAuthority(role, bins: readonly { storageClass: string | null }[])` — asserts `secure.move` once if any bin's class is `secure` (reuses `assertPermission`'s 403 shape). Lives here because the primitive cannot import tenancy, and it sits next to the capability vocabulary it guards.
- `src/modules/putaway/putaway.command.ts` — placement: `assertSecureBinAuthority(role, [targetBin])` after the 12-1 class gate (:549-556), inside the bin-row `.for('update')` window (:518). The re-derivation (:506-525) is unchanged.
- `src/modules/outbound/pick.command.ts` — draw: `assertSecureBinAuthority(role, [drawBin])` after the 12-1 draw gate (:774), inside the bin-row lock window (:745); `drawBin.storageClass` is already selected (:725-740).
- `src/modules/tenancy/bin.command.ts` — `mergeBin`: `assertSecureBinAuthority(role, [source, target])` after the class gate (:723-731), before any arm moves (both rows already locked, :637).
- `src/modules/inbound/qc.command.ts` — hold: origin bin already locked (:258); release: origin read (:505-513). Both assert on the origin's class.
- `src/modules/tenancy/permissions.ts` — `assertSecureBinAuthority` helper (above); the matrix-invariant test lives in `test/users.spec.ts`.
- `wms-fe/src/lib/users.ts` (:14-77) + `wms-fe/src/lib/users.test.ts` (:32-58) — mirror the 23rd capability; bump the owner-count assertion and every name-based enumeration.
- Tests: `test/putaway.spec.ts` (operator 403 into secure bin / owner 200), `test/picking.spec.ts` (operator 403 from secure bin / owner 200), `test/bin-admin.spec.ts` (merge arm), `test/qc-holds.spec.ts` or its home (hold + release arms), `test/users.spec.ts` (matrix invariant + 403 detail names `secure.move`).
- Do NOT touch: `binCandidatesInTx`/`candidateFitsSku`/`buildStockPool`/`putaway.facade.ts` (walks unchanged — decided), `stock.adjust`, the ledger registry, `storage-class.ts`, any DTO, Receiving.

## Tasks & Acceptance

**Execution:**
- [x] `permissions.ts` — capability string, grants, `assertSecureBinAuthority`.
- [x] Five writers — placement, pick, merge, qc-hold, qc-release asserts beside their class gates.
- [x] `wms-fe/src/lib/users.ts` + `users.test.ts` — mirror (separate FE commit/PR, after the backend PR).
- [x] Tests per suite above, including the matrix-invariant test and the 403-detail shape.
- [x] `bun run openapi:export` — byte-identical (the document carries no per-route 403 arms); `docs/design/API-SURFACE.md` — 403 arms on the five routes; `docs/design/PENDING.md` — extend the adjustment-bypass entry, record the walks-unchanged narrowing.

**Acceptance Criteria:**
- Given a bin with `storageClass: 'secure'`, when an actor without `secure.move` places into it, picks from it, or (for merge/hold/release) moves it in any direction, then the command 403s `role-denied` naming `secure.move` and nothing is written.
- Given the same bin, when the owner or ops manager performs the same movements, every existing gate (class, hazard, capacity, hold-open, blocked) runs exactly as today — no behavioral change beyond the 403.
- Given `ROLE_CAPABILITIES`, the invariant test passes: every role holding a gate-relevant movement capability that the decided grants do not deliberately exempt (`bin.retire`, `qc.manage`, and the `stock.adjust` bypass containment) holds `secure.move`, and the operator's deliberate exclusion (`putaway.execute`/`picks.execute` without `secure.move`) is pinned explicitly. (Amended 2026-09-24 under the change-log entry above — the original sentence still read the five-capability way the log corrects.)
- Given a non-secure bin, every movement behaves byte-identically to the pre-12.3 build; the full suite stays green.

## Implementation Notes

## Spec Change Log

- **2026-09-24 (implementation-time spec defect, fixed in code, human informed):** the frozen block's matrix-invariant sentence was internally inconsistent with the block's own decided grants — it required every role holding `putaway.execute`/`picks.execute`/`bin.retire`/`qc.manage` to hold `secure.move`, but the decided matrix deliberately denies `secure.move` to the operator, who holds the two floor verbs by definition. The five-capability invariant is unsatisfiable; the implementer enforced the coherent subset — **every role holding `bin.retire` or `qc.manage` must hold `secure.move`** (the dead-code pair, turned enforced) — and pinned the operator exclusion explicitly in the same test (`test/users.spec.ts`). The live-code placement/pick 403s are covered by their e2e arms, not by the matrix test. The frozen-block sentence itself still reads the old way (frozen blocks change only by human renegotiation); this entry is the record of the correction and its reason.

## Review Triage Log

**2026-09-24, step-04 round 1** — three context-free layers (blind-hunter floor 7 → 11 findings, edge-case-hunter 7, verification-gap 2+2) over the wms-be + wms-fe diffs. Every claim verified against the working tree. No `intent_gap`, no `bad_spec` — no loopback. 10 patch entries (one patch round), 1 defer, 4 rejected.

| # | Finding (layer) | Verdict | Evidence | Route |
|---|-----------------|---------|----------|-------|
| 1 | `permissions.ts:78` "every ledger movement that touches one" overclaims — `stock.adjust` is an ungated bin-targeted ledger writer (blind, VG) | medium | Verified: `inventory.command.ts` adjustment writes `to_bin_id`/`from_bin_id` ledger movements and asserts only `stock.adjust`; the bypass is decided (frozen bullet + PENDING) but the code comment presents the gate as exhaustive. Developer harm: a future `stock.adjust` grant is reasoned about against a false invariant. | patch — name the bypass in the comment, enumerate the five writers |
| 2 | Matrix-invariant test omits `stock.adjust` from the dead-code set (blind) | medium | Verified: `deadCodeCapabilities = ['bin.retire','qc.manage']`; `stock.adjust` holders (owner, ops_manager) both hold `secure.move` today, so it is equally contained — and it is the one writer that can *create* stock in a secure bin. A future `stock.adjust` grant without `secure.move` opens the cage and the test stays green. | patch — add `stock.adjust` as bypass-containment |
| 3 | Invariant test hardcodes the role list (blind, EC) | medium | Verified: `const roles: UserRole[] = ['owner','ops_manager','operator','accountant']` — a future role added to the matrix is silently skipped by the very test whose job is matrix drift. | patch — derive from `Object.keys(ROLE_CAPABILITIES)` |
| 4 | Putaway authority-before-hazard precedence unpinned (VG) | medium | Verified: assert at `putaway.command.ts:565` precedes the hazard occupant loop (:578-591); the 12-3 test's cage is empty (hazard gate silent) and every 12-2 hazard test runs as owner — moving the line flips a doubly-conflicting operator placement from 403 to 400 `bin-segregation-conflict` with no test noticing. | patch — add the doubly-conflicting 403 arm |
| 5 | Pick authority-before-serial precedence unpinned (VG) | medium | Verified: assert at `pick.command.ts:784` precedes serial resolution (:814+); the 12-3 draw is non-serial and no serial-tracked test uses a secure bin — the gate could invert and leak serial-location detail to a denied role unnoticed. | patch — add a serial-tracked secure-draw 403 arm |
| 6 | Release origin read has no `.for('update')` — the secure gate may rule on a stale class (blind, EC, VG) | medium | Verified true: the read (:508) is unlocked; the in-code comment cites PENDING `inbound:45` and the frozen Never-clause explicitly declines the lock fix this story. Real race, narrow window (concurrent class edit flips the bin to `secure` before commit). Pre-existing currency, not this story's defect to fix. | defer (PENDING `inbound:45` already tracks the unlocked read) |
| 7 | QC hold/release secure assert runs after the idempotency replay; JSDoc silent on it (blind) | low | Verified: entry `assertPermission` precedes the replay; `assertSecureBinAuthority` runs after it returns, so a replayed key is exempt — defensible idempotency semantics, but the JSDoc's "decided on the SAME bin row" has this one hole unstated. | patch — one-line comment stating the replay exemption |
| 8 | Terminology drift: "dead code by the matrix" (call sites) vs "can only fire on placement and pick" (JSDoc) (blind) | low | Verified: both phrasings present (`qc.command.ts` hold/release comments, `permissions.ts` JSDoc); the asserts run at all five sites and are the future 403 for merge/hold/release — "dead code" misdescribes them. | patch — align on "non-denying today" |
| 9 | Test names in `bin-admin.spec:1756` / `qc-holds.spec:897` say "the 403 shape lives in users.spec" — no e2e 403 exists for merge/QC (blind) | low | Verified: the users.spec check is a unit-level test of the helper; the wording sends a reader hunting for an e2e arm that intentionally does not exist. | patch — reword to "unit-pinned in users.spec" |
| 10 | `'secure'` matched as a bare literal, untethered from `STORAGE_CLASSES` (blind) | medium | Verified: `assertSecureBinAuthority` compares the raw literal; a future vocabulary rename migrates `bins.storage_class` (DB CHECK) and `storageClassSatisfies` (equality, name-blind) without touching the gate — which would then silently never fire. | patch — export `SECURE_STORAGE_CLASS` from `storage-class.ts` and use it |
| 11 | Secure fixture (CSV import → PATCH to secure → find id) hand-rolled in three specs (blind) | low | Verified: putaway/picking/bin-admin each repeat the ~20-line sequence; `test/support/` exists as the shared-helper home. Any fixture change must find all three copies. | patch — extract a shared helper |
| 12 | Role promotion in the 12-3 tests not wrapped in try/finally (EC) | low | Verified in both specs (putaway ~1958-1985, picking 2462-2473): demotion runs only if the assertions between pass — one failure leaves the operator promoted for the rest of the file. | patch — wrap in try/finally |
| 13 | Trailing newlines missing on three files (blind) | false | Verified pre-existing in HEAD on main (also verified at step-03): the diff preserves the existing convention and adds no new harm; lint passes. | reject |
| 14 | Capability count asserted in three places (blind) | false | The three assertions guard different artifacts (BE vocabulary length, FE mirror owner-row, docs prose); the CI `check:capability-mirror` script owns BE/FE equality and the FE length check guards FE-only runs. By-design redundancy, no single source replaced. | reject |
| 15 | Spec Intent "every command whose ledger movement touches a secure-class bin asserts it" is false as stated (EC claim) | false | The frozen block's own Always bullet names the `stock.adjust` named bypass and enumerates the five writers two bullets away, and PENDING records the bypass — no uncorrected reader harm. | reject |
| 16 | AC criterion 3 ("every role holding a movement capability holds secure.move") contradicts the implemented subset invariant (EC claim, high confidence) | medium | Verified: `test/users.spec.ts` enforces the `bin.retire`/`qc.manage` subset with the operator exclusion; the AC sentence still reads the five-capability way. The fix is a spec edit, and the Spec Change Log already records the correction — the AC sentence is aligned under that entry (spec maintenance, not a code patch). | reject (fix edits the spec; correction already logged and applied to the AC text) |

**Patch round (2026-09-24):** rows 1–5, 7–12 patched by the implementation subagent as wms-be `067068e` — vocabulary-keyed gate (`SECURE_STORAGE_CLASS`), aligned wording ("non-denying today"/"LIVE arm", replay-exemption notes), invariant test widened (`stock.adjust` bypass containment, roles from `Object.keys(ROLE_CAPABILITIES)`), try/finally on both promotions, hazard-precedence + serial-precedence arms, "unit-pinned" rewording, shared `test/support/secure-sku.ts` fixture. Row 6 deferred (PENDING `inbound:45`); rows 13–16 rejected above; row 16 resolved by the AC-text amendment. Re-verification on my side: lint + typecheck clean, full suite 727/727 green, capability mirror green (23 capabilities — the patch touched no capability string); FE mirror unchanged.

## Design Notes

- **Authority, not a placement rule.** 12-1's rule is (SKU, bin) state; 12-2's is (SKU, SKU) co-location. 12-3's is (role, bin) authority: the same bin row the class gates already hold decides a *permission* question, so the assert rides the existing gate slots — no new query, no new primitive, no lock change.
- **The gate is dead code for merge/hold/release today** — `bin.retire` and `qc.manage` are held by exactly the roles that hold `secure.move` — and that is the point: the matrix-invariant test turns the implicit subset into an enforced one, so a future grant to a new role must answer the cage question in the open.
- **`assertSecureBinAuthority` runs per involved bin** (placement: target; merge: both; pick/hold/release: the single bin). One assert, not one per pair — the capability is about touching the cage at all, not about which direction.
- **Existing audit suffices for "audited":** every gated movement already writes an `audit_events` row (`putaway.placed`, `bin.merged`, `pick.picked`, `qc_hold.placed/released`) with the actor and the idempotency reference, and the outbox payloads carry the bin context. A capability denial is a guard, not a movement — 12-2's no-new-event precedent. If 12-7's admin surface wants a cage-movement filter, it rides the existing rows.
- **Walks stay unchanged (decided, 2026-09-24):** the candidate walk, task derivation and wave pool are role-blind today, and they stay so — advisory suggestion, binding gate. An operator may be *suggested* a cage bin and 403 at the command; the accepted interim until 12-7/12-8 give the surfaces the vocabulary. (The rejected alternative — thread `secureCapable` through `candidateFitsSku`/`buildStockPool` — would make suggestions role-aware while task derivation stays warehouse-level, so the two paths would disagree.)

## Verification

**Commands:**
- `cd workspace/core/backend/wms-be && bun run lint && bun run typecheck` — exit 0.
- `bunx jest test/users.spec.ts test/putaway.spec.ts test/picking.spec.ts test/bin-admin.spec.ts` — green.
- `bun run test` — full suite green, fresh-isolated, one run at a time (template-DB race); no migration this story, so global-setup is the ordinary proof.
- `cd workspace/core/frontend/wms-fe && bun run test -- users` — mirror test green with the 23rd capability (FE commit only).