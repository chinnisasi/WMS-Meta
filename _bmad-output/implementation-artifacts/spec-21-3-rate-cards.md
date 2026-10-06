---
title: 'Rate cards — versioned per-client prices with closed charge and basis vocabularies'
type: 'feature'
created: '2026-10-06'
status: 'done'
route: 'dispatch'
baseline_commit: '0edd61bea3689eee0420c78ad32aded37f884858'
review_loop_iteration: 0
context:
  - '_bmad-output/implementation-artifacts/epic-21-context.md'
  - '_bmad-output/specs/spec-3pl/SPEC.md'
  - '_bmad-output/specs/spec-3pl/schema.md'
  - '_bmad-output/specs/spec-3pl/billing-model.md'
  - '_bmad-output/specs/spec-3pl/architecture.md'
  - '_bmad-output/implementation-artifacts/spec-21-2b-client-admin-and-attribution.md'
  - 'docs/design/SYSTEM-DESIGN.md'
  - 'docs/design/IMPLEMENTATION-GUIDE.md'
  - 'docs/design/modules/clients.md'
  - 'docs/design/frontend/SYSTEM-DESIGN.md'
  - 'docs/design/frontend/IMPLEMENTATION-GUIDE.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** A 3PL charges each client for storage and handling, but nothing records what a client is charged or from when (FR-77, CAP-4). Metering (21-4) and client invoices (21-5) need a rate that is fixed for every past day, so that an issued invoice can always be reproduced.

**Approach:** Add a new `billing` module that owns **rate cards**.
- A card belongs to one client. It is drafted, then activated from an effective IST date, and is frozen after activation.
- A later card supersedes the earlier one from its own date. A card that has not taken effect yet can be cancelled.
- Each line prices one charge on a closed basis, in integer paise.
- Facade reads answer "which card is in force at this instant" and "which cards cover this period".

**Decisions (human, 2026-10-06):**
1. **Storage is priced per 1,000 units per day only.** These are SKU base units, and the rate is ₹ per 1,000 units per day in whole paise, so no fraction of a paisa exists anywhere. Pallet pricing waits for a real pallet concept (PENDING).
2. **Who edits:** a new capability, `rates.manage`, lets the **owner and accountant** create, edit, activate and cancel cards. Every member can view them.
3. **Effective dates:**
   - A client's first card may take effect today (IST) or later.
   - A card that replaces an existing one takes effect **tomorrow (IST) at the earliest**, so no past hour is ever repriced.
   - A card whose date has not arrived can be **cancelled**, and its predecessor reopens.
4. **Any subset.** A card prices only the charges in the client's contract.
   - No line means the charge is not billed.
   - ₹0 means it is billed at ₹0.
   - Each charge appears at most once per card.
5. **Any effective date is allowed.** 21-5 records the card **on each invoice line**, so a mid-period change splits the line. The 3PL `schema.md` is amended now.

## Boundaries & Constraints

**Always:**
- **Closed vocabularies**, each a TS tuple plus a migration CHECK, pinned by a test:
  - `charge_code` ∈ `storage | inbound_handling | pick | outbound_handling`.
  - `basis` ∈ `per_thousand_units_per_day | per_receipt_line | per_pick | per_order`.
  - Pairs, enforced by a CHECK: `storage` ↔ `per_thousand_units_per_day`, `inbound_handling` ↔ `per_receipt_line`, `pick` ↔ `per_pick`, `outbound_handling` ↔ `per_order`.
- **Amounts** are integer paise per unit of basis, 0 ≤ amount ≤ 10,000,000 (₹1 lakh), GST-exclusive. GST is applied on the client invoice (21-5).
- **Statuses:** `draft | active | superseded | cancelled`.
- **In force.** The card in force at `t` is the `active` or `superseded` card with `effective_from ≤ t < coalesce(effective_to, ∞)`. There is at most one per client.
- **Effective dates are IST midnights** (CHECK). `effective_from` is null exactly for drafts. The wire carries `YYYY-MM-DD`.
- **Activating card B (effective `F`)** happens under a lock on the client row and all of the client's cards:
  - `F` is ≥ today when the client has no `active` or `superseded` card, and ≥ tomorrow otherwise;
  - `F` is later than every non-cancelled card's `effective_from`;
  - B has at least one line;
  - the previous open card gets `effective_to = F` and `status = superseded` **before** B becomes `active`.
- **Cancelling** applies only to an `active` card with `effective_from > now`. It becomes `cancelled` and is never in force, and the card it superseded returns to `active` with `effective_to = null`.
- **Frozen after activation.** A non-draft card and its lines never change, except through the three transitions: supersede, cancel, and reopen-on-cancel.
  - Database triggers enforce this: on lines, `INSERT/UPDATE/DELETE` checks the parent status of both the old and new row; on cards, `UPDATE/DELETE` checks the transition; on both tables, `TRUNCATE` is refused.
  - A non-draft card is never deleted. Test teardown uses the `session_replication_role = replica` idiom.
- **Client checks.** Cards are refused for the `self` client and for a non-active client. Client RLS follows AD-24 on both tables: lines are stamped with `client_id`, and both are added to the client-isolation probe.

**Never:**
- metering or counting rules beyond naming each basis's unit (21-4);
- invoices or GST (21-5);
- tiered or volume pricing, minimum charges, proration;
- per-warehouse rates;
- pallet or bin storage;
- portal visibility (21-7);
- editing an activated card.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected | Error |
|---|---|---|---|
| Create draft | Accountant, `ACME`, lines `storage 330`, `pick 300` | 201 `draft`, no date | — |
| Bad pair, duplicate charge or out-of-range amount | — | — | 400 `validation-failed` |
| Draft for `self` or a non-active client | — | — | 400 / 409 `client-not-active` |
| Ops manager edits | — | — | 403 `role-denied` (can read) |
| Replace or discard a draft | Draft | 200 / 204 (a repeat discard → 404) | Not a draft → 409 `rate-card-not-draft` |
| First card | Effective today | `active`, in force now | Past date → 400 `rate-card-effective-date` |
| Replacing card effective today | Another card is in force | — | 400 `rate-card-effective-date` (tomorrow at the earliest) |
| Later card | A active; B effective 2026-11-01 | A `superseded`, `effective_to` 11-01 IST; B `active` | — |
| Out of order | B before A's `effective_from` | — | 409 `rate-card-effective-overlap` |
| No lines | — | — | 409 `rate-card-no-lines` |
| Cancel a scheduled card | B effective 11-01; today is 10-20 | B `cancelled`; A `active`, open-ended | B already in force → 409 `rate-card-not-cancellable` |
| In force at | 10-31 23:00 IST vs 11-01 00:00 IST | A vs B | Bad `at` → 400 |
| Cards over a period | 10-15 → 11-15 | Segments `[A: 10-15→11-01)`, `[B: 11-01→11-15)` with lines | — |
| Direct SQL tampering | INSERT, UPDATE or DELETE on a line of an active card; UPDATE of its amounts; TRUNCATE | Refused by the trigger | DB error (tested) |
| Concurrent activations | Two drafts of one client activate at once | Serialised; never overlapping | The loser is checked against the winner |
| A retry after IST midnight | Same key as a committed activation | Replays its result | — |

</frozen-after-approval>

## Code Map

- **Design source:**
  - `_bmad-output/specs/spec-3pl/schema.md:37-53` defines `rate_cards`/`rate_card_lines`. Amend it for decision 5 (the card is recorded per invoice line) and for the nullable draft `effective_from`.
  - `billing-model.md:11-38` names the wrong events. The ledger emits `dispatch.dispatched` once per order line, `pick.picked` once per batch arm or serial, and `grn.received` again on an over-receipt approval (`ledger-registry.ts:276-279,359-371,409-427`).
  - `architecture.md:57,69,74`: billing owns its tables and gets an architecture ownership block.
- **Clients:** `ClientsFacade` (`assertClientInTenantInTx`, `CLIENT_STATUSES`) and `clients.system_owned`. RLS uses the AD-24 clause (`drizzle/0041_client_isolation_rls.sql:11-15`); the probe is `test/client-isolation.spec.ts` (`STAMPED_TABLES`, `CLIENT_POLICIES`, policy-count pin).
- **Enum pins:** `orders.spec.ts:945` (`armsOf`, which parses IN-lists). The pair CHECK needs its own every-combination insert test.
- **Precedents:**
  - triggers: ledger append-only plus a TRUNCATE guard (`drizzle/0006_curvy_nehzno.sql:98-108`); `eway_refuse_mutation` (0056) is UPDATE-only, with no session flag;
  - teardown: `test/eway.spec.ts:256-259`.
- **Time:** `IST_OFFSET_MS` (`shared/primitives/time.ts`). `istDateOf` (`invoicing/eway-threshold.ts:44`) and `isIsoDate` (`invoicing/eway-json.ts:348`) move to `shared/primitives/time.ts` and are re-exported. The e-way thresholds store an IST `date`; rate cards use an IST-midnight timestamptz because lookups are by instant.
- **The command skeleton** puts time-tightening rules ("≥ today/tomorrow") **after** the replay lookup (IMPLEMENTATION-GUIDE §1).
- **The DELETE precedent** is `channels.controller.ts:310-322` (204, and a repeat is 404).
- **Capabilities:**
  - BE `tenancy/permissions.ts` has 37 entries. The accountant has only `eway.manage` (comment at :225-230); the pins are in `test/users.spec.ts:858-872`, whose 8-1 rationale says "the accountant does not set prices", which decision 2 deliberately reverses.
  - FE `lib/users.ts:171-208` gives ops_manager all capabilities minus the owner-only list.
- **The next migration is 0060.**
- **Web:**
  - the Settings cards, `clients-card.tsx` and `useClients` (21-2b);
  - `parseRupees` in `lib/rupees.ts` (8-1c; no float; the cap is checked separately), and `formatRupees` for display;
  - the house loader and mutation patterns, with gating from `sku-table.tsx`.

## Tasks & Acceptance

**Execution:**
- [x] `wms-be/drizzle/0060_rate_cards.sql` (+ journal, snapshot, schema.ts) -- guarded; RLS with the AD-24 client clause; no FKs.
  - **`rate_cards`:** `id`, `tenant_id`, `client_id`, `status`, `effective_from` (null only for drafts), `effective_to`, `created_by`, `created_at`, `updated_at`, `activated_by`, `activated_at`, `cancelled_by`, `cancelled_at`.
    - CHECKs: the status vocabulary; IST midnight for both dates; `effective_to > effective_from`; draft ⇔ `effective_from` and `activated_at` null; superseded ⇔ `effective_to` set; cancelled ⇔ `cancelled_at` set.
    - A partial unique index: one open card (`status = 'active' AND effective_to IS NULL`) per `(tenant_id, client_id)`.
    - An index on `(tenant_id, client_id, effective_from)`.
  - **`rate_card_lines`:** `id`, `tenant_id`, `client_id`, `rate_card_id`, `charge_code`, `basis`, `amount_paise`, with CHECKs for the vocabularies, the pairs and the range, plus `UNIQUE (rate_card_id, charge_code)`.
  - **The triggers above**, with exact transition predicates. Every column except `status`, `effective_to`, the cancel stamps and `updated_at` must be `IS NOT DISTINCT FROM` its old value.
- [x] `wms-be/src/modules/billing/` -- the module:
  - `rate-cards.ts`: the vocabularies, the pair map, and the counting unit of each basis, stated for 21-4:
    - storage: the daily on-hand base milli-units ÷ 1,000,000;
    - receipt line: distinct GRN lines received, excluding over-receipt approval re-emits;
    - pick: distinct picklist lines picked;
    - order: distinct orders dispatched.
  - `rate-card.command.ts`: `createDraft`, `replaceDraftLines`, `discardDraft`, `activate`, `cancel`.
    - House skeleton: Idempotency-Key, replay first, locks, state guards after the lock.
    - Hash inputs: `{tenantId, clientId|cardId, lines sorted by chargeCode, effectiveFrom}` as applicable.
    - Audit: target type `rate_card`; actions `drafted`, `lines-replaced`, `discarded`, `activated`, `cancelled`, and `superseded`/`reopened`, each on the affected card.
    - A 23505 on the open-card index → 409.
  - `billing.facade.ts`: `listRateCards`, `getRateCard`, `rateCardInForceInTx(tx, t, client, instant)`, and **`rateCardSegmentsInTx(tx, t, client, from, to)`**, which returns `[{card, lines, from, to}]` clipped and ordered.
  - A Nest module.
- [x] `wms-be/src/modules/tenancy/permissions.ts` -- `rates.manage` for the owner and accountant. Update the accountant comment and the `users.spec.ts` pins (38 capabilities; accountant `['eway.manage','rates.manage']`), with a note on why 8-1's rationale is reversed.
- [x] `wms-be/src/api/rate-cards.controller.ts` + DTO -- re-export `openapi.json`. Dates are `YYYY-MM-DD`, checked in the DTO for shape and a real calendar date only.
  - `GET /tenants/{t}/clients/{c}/rate-cards`: drafts first, then `effective_from DESC`.
  - `POST /tenants/{t}/clients/{c}/rate-cards`.
  - `GET /tenants/{t}/rate-cards/{id}`.
  - `PUT /tenants/{t}/rate-cards/{id}/lines`.
  - `POST /tenants/{t}/rate-cards/{id}/activate` with `{effectiveFrom}`.
  - `POST /tenants/{t}/rate-cards/{id}/cancel`.
  - `DELETE /tenants/{t}/rate-cards/{id}`: drafts only; 204, and a repeat → 404.
  - `GET /tenants/{t}/clients/{c}/rate-cards/in-force?at=`: `at` is an optional UTC `Z` instant (default now); returns `{rateCard: RateCardDto | null, asOf}`.
  - Any unknown or foreign card or client → 404.
- [x] `wms-be/test/rate-cards.spec.ts` -- every matrix row, plus:
  - the vocabulary pins and every charge × basis combination;
  - every trigger arm, via direct SQL;
  - the IST boundaries;
  - concurrent activations;
  - a clock-faked replay after midnight;
  - the segments read;
  - RLS: the tenant policy and the client probe additions;
  - the 0060 migration block.
- [x] `wms-fe`:
  - **A `RateCardsCard` in Settings, after Clients:**
    - pick a non-`self` client;
    - its cards, with a state derived from the dates (Draft / Scheduled / In force / Ended / Cancelled). The "In force" highlight comes from the in-force endpoint, not the browser clock;
    - the next scheduled change, e.g. "₹3.30 → ₹4.00 from 1 Nov";
    - charges without a line shown as "Not billed";
    - a banner when an active client has no card in force ("This client will not be billed").
  - **For `rates.manage`:**
    - a draft editor with ₹ inputs via `parseRupees`, the cap checked, and storage labelled "per 1,000 units per day";
    - edit and discard;
    - activate, with a date minimum computed as the IST date (tomorrow when a card is in force);
    - cancel on scheduled cards.
  - **Plumbing:** `useRateCards` plus `RATE_CARDS_CHANGED_EVENT`; mappers for every code.
  - **The capability mirror:** an explicit ops-excluded set containing the owner-only capabilities plus `rates.manage`; the accountant pin moves.
  - Tests.
- [x] Meta docs:
  - a new `modules/billing.md`: the lifecycle and transitions, the in-force and segments contract, immutability, the basis counting units, and the rounding owner (21-4);
  - amend `_bmad-output/specs/spec-3pl/schema.md` and `billing-model.md` (the card per invoice line; the event names; per-1,000-unit storage);
  - `API-SURFACE.md`, the `SYSTEM-DESIGN.md` module map (billing), and both contracts;
  - `PENDING.md`: tiered pricing, minimums and proration; per-warehouse rates; portal rate visibility; pallet and bin storage; storage summing unlike base units (mixed UoM); 21-4 snapshotting the base units the per-1,000 rate needs.

**Acceptance Criteria:**
- Given client `ACME` with card A in force and card B activated effective the 1st of next month, when the in-force and segments reads run, then A applies before that IST midnight and B from it. Cancelling B before that date reopens A. No line of an activated card can be changed through any route or by direct SQL.
- Given the full BE and FE suites, when run, then they pass.

## Implementation Notes

- Baselines: wms-be `0edd61bea3689eee0420c78ad32aded37f884858` (frontmatter `baseline_commit`); wms-fe `738984e0232f51703aa5a330c7def7384bd667b9`. Work happens on `feat/21-3-rate-cards` in both repos. Leave changes uncommitted; do not commit, push, or open PRs. In wms-be run jest via `bun run test -- <file>` (bare `bun test` hangs) and never two jest invocations concurrently. Meta doc edits go in /Users/sasidhar/Documents/WMS-Meta (docs/ and _bmad-output/specs/spec-3pl/; you may edit existing files there).
- Shipped: WMS-BE #77 (`2b5a459`), WMS-FE #62 (`91a3769`); design PR WMS-Meta #96.

## Spec Change Log

## Review Triage Log

*Design review, 2026-10-06: two code-verified reviewers (backend/data; 3PL fit/API/FE). 30 findings merged into 22. Four went to the human (decisions 1, 3, 5 and the precision rule); the rest are folded in.*

| # | Severity | Finding | Disposition |
|---|---|---|---|
| 1 | high | "Pallet" doesn't exist: 10-3's handling units are catch-weight cases with no location, client or ledger events | Decision 1: per-unit only; pallet in PENDING |
| 2 | high | Integer paise can't hold per-unit daily storage | Rates per 1,000 units per day, in whole paise |
| 3 | high | A card activated today reprices hours already passed | Decision 3: a replacement starts tomorrow at the earliest |
| 4 | high | A scheduled card can't be withdrawn | Decision 3: cancel, which reopens the predecessor |
| 5 | high | A mid-period change conflicts with one card per invoice; one instant isn't enough for 21-4/21-5 | Decision 5: the card per invoice line; a segments facade; `schema.md` amended |
| 6 | high | The trigger misses INSERT, parent re-pointing and TRUNCATE | INSERT/UPDATE/DELETE on lines checks old and new parents; TRUNCATE guards |
| 7 | high | The supersede exception doesn't fit house updates (`updated_at`) | Exact predicate, `IS NOT DISTINCT FROM` on frozen columns |
| 8 | medium | The teardown "session flag" precedent doesn't exist; DELETE semantics contradicted | Non-draft delete refused; the teardown uses the replica idiom |
| 9 | medium | Draft `effective_from` undefined; no IST-midnight CHECK; list order undefined | Nullable for drafts; CHECKs; order defined; index |
| 10 | medium | Client RLS (AD-24) implicit | AD-24 clause; lines stamped; added to the probe |
| 11 | medium | The time-tightening rule must sit behind the replay lookup | DTO shape only; rules after the lock; clock-faked replay test |
| 12 | medium | Error arms missing (activate a non-draft, no-lines status, 23505, 404s, client status, the DELETE precedent) | Full arm set in the matrix and tasks |
| 13 | medium | Basis counting units undefined; the 3PL docs name the wrong events | Units defined in `rate-cards.ts`/`billing.md`; docs corrected |
| 14 | medium | The lock scope and draft-command locking are under-specified | The client row plus all cards; replace and discard lock their row |
| 15 | medium | BE capability pins missing; the reversed 8-1 rationale | Pins moved, with a note |
| 16 | medium | Duplicate IST helpers; diverging from the e-way `date` storage | Helpers moved to `shared`; divergence justified |
| 17 | medium | Misleading status labels; the browser-clock highlight | Labels derived from dates; highlight from the endpoint; next change shown |
| 18 | medium | A client with no card is billed nothing, silently | A banner; "Not billed"; ₹0 means billed at zero |
| 19 | medium | The `at` param, its default and the null response shape are unspecified | An optional `Z` instant, default now; `{rateCard \| null, asOf}` |
| 20 | low | The pair CHECK has no pin model | An every-combination insert test |
| 21 | low | The amount cap vs 21-4's 2⁵³ arithmetic | Cap ₹1 lakh; 21-4 owns the BigInt/rounding (`billing.md`) |
| 22 | low | Wire shapes and hash inputs; FE `parseRupees`, cap, IST minimum; the mirror; minimums, multiple drafts, activation ordering | All specified; minimums in Never/PENDING; multiple drafts allowed |

*Code review, 2026-10-06: three layers (blind, edge-case, verification-gap); 26 findings merged into 19, each verified against the code.*

| # | Verdict | Finding | Evidence | Route |
|---|---|---|---|---|
| C1 | high | A scheduled card already superseded by a later one (B 12-01 replaced by C 01-01) can't be cancelled, contrary to decision 3 ("a card whose date has not arrived can be cancelled") | `cancel` requires `status = 'active'` | patch: cancel any non-draft, non-cancelled card with `effective_from > now`; its predecessor's `effective_to` becomes the cancelled card's `effective_to` (null ⇒ reopens `active`); the trigger permits that one transition |
| C2 | high | A client-scoped (portal) session may write its own rate cards under the copied 0041 `WITH CHECK` | `0060` RLS; `client-isolation.spec` asserts it | patch: the client clause is read-only (writes refused when `app.client_id` is set); the probe updated (0060 is not deployed) |
| C3 | high | The `…InTx` facade reads return `[]`/`null` for an unknown or foreign client (a silent "not billed"); in-force doesn't normalise its instant | `billing.facade.ts:1051-1069` | patch: both assert the client in the tenant (404) and parse the instant to UTC |
| C4 | medium | The FE next-change summary skips a superseded-but-not-started card | `rate-cards.ts:4793` | patch |
| C5 | medium | Cancel copy assumes an in-force predecessor (a first card ⇒ nothing billed; a scheduled predecessor ⇒ not "in force") | FE copy | patch: wording by case |
| C6 | medium | Siblings can read the raw tables past the facade (`rate-cards.ts` re-exports them) | the architecture allow-list | patch: stop re-exporting; add a raw-read guard |
| C7 | medium | The 500-row list bound can push dated cards out behind drafts | `rate-card.command.ts:1404-1423` | patch: dated cards unbounded; drafts capped separately |
| C8 | medium | Test gaps: segments after a cancel; activate after the client is suspended; FE Edit/Discard and refetch; cancelling a first card; the superseded-scheduled chain; cancel replayed after midnight; races (activate vs cancel; activate vs replaceDraftLines) | greps | patch: tests |
| C9 | low | FE error copy: `idempotency-key-reuse` and `conflict` mislead | FE mappers | patch |
| C10 | low | The activation date minimum uses the browser clock although `asOf` is loaded | FE | patch: derive from `asOf` |
| C11 | low | Deleting a draft by direct SQL leaves orphan lines that the line trigger then refuses to delete | 0060 | patch: refuse a card delete while lines exist |
| C12 | low | Docs: SYSTEM-DESIGN inconsistencies; IMPLEMENTATION-GUIDE lacks the new patterns (command clock; fail-closed parent triggers under RLS; primitives with module-typed wrappers); the draft-side client-status check is unserialised | docs | patch (docs, PENDING) |
| C13 | low | The tomorrow rule applies whenever any card exists, even if it is only scheduled | the frozen rule says "≥ tomorrow otherwise" | rejected: implements the frozen rule as written |
| C14 | low | A non-string `chargeCode` from a non-HTTP caller crashes the sort | `normalizeLines` | rejected: every caller goes through the validated DTO |

## Design Notes

- **A new card, never an edit.** An invoice for March, re-rendered after an April change, must still show March's numbers. Freezing activated cards (with triggers) and recording the card on each invoice line (21-5) make that true (CAP-4).
- **Why tomorrow at the earliest for a replacement.** Effective dates are IST midnights, so a replacement taking effect "today" would reprice hours that have already passed. The first card may start today, because nothing was metered against any card before it.
- **Why IST-midnight timestamptz, not `date`.** Lookups are by instant (an event's time), so the boundary is stored as the instant it starts.

## Verification

**Commands:**
- `bun run test` (wms-be) -- green, plus `typecheck`, `lint`, `build`; `db:generate` reports "No schema changes".
- `bun run lint && bun run test && bun run typecheck && bun run build && bun run check:capability-mirror` (wms-fe) -- green.
