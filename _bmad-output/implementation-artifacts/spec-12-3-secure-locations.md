---
story: 12-3-secure-locations
title: "12-3 secure locations — FR-42 authority gate on the backend"
type: 'feature'
created: '2026-09-24'
status: 'ready-for-dev'
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
- [ ] `permissions.ts` — capability string, grants, `assertSecureBinAuthority`.
- [ ] Five writers — placement, pick, merge, qc-hold, qc-release asserts beside their class gates.
- [ ] `wms-fe/src/lib/users.ts` + `users.test.ts` — mirror (separate FE commit/PR, after the backend PR).
- [ ] Tests per suite above, including the matrix-invariant test and the 403-detail shape.
- [ ] `bun run openapi:export` if any error arm changes; `docs/design/API-SURFACE.md` — 403 arms on the five routes; `docs/design/PENDING.md` — extend the adjustment-bypass entry, record the walks-unchanged narrowing.

**Acceptance Criteria:**
- Given a bin with `storageClass: 'secure'`, when an actor without `secure.move` places into it, picks from it, or (for merge/hold/release) moves it in any direction, then the command 403s `role-denied` naming `secure.move` and nothing is written.
- Given the same bin, when the owner or ops manager performs the same movements, every existing gate (class, hazard, capacity, hold-open, blocked) runs exactly as today — no behavioral change beyond the 403.
- Given `ROLE_CAPABILITIES`, the invariant test passes: every role holding a movement capability holds `secure.move`.
- Given a non-secure bin, every movement behaves byte-identically to the pre-12.3 build; the full suite stays green.

## Implementation Notes

## Spec Change Log

## Review Triage Log

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